# Donna Ops v1

What Donna's own agents need to run her office once the owner activates her. Stacked on Donna Receptionist v1 (#52).

Claude built the **system**. The business work (niche research, prospects, sales kits, client intakes) is done by **Donna's agents** through these runners,
after activation. No real prospect list, sales kit or intake is in this PR.

## What runs

`hq_donna.run(<mission>, inputs)`, or `/donna run <mission>` in Telegram (owner only).

| Mission | Runner | Brain | Writes |
|---|---|---|---|
| `market-research` (`donna-m1-validation`) | Public pages from allowed hosts → free brain scores niches → every fact re-checked against the stored page text (`hq_evidence.verify_fact`). A niche is **validated** only with 2+ supported facts from 2+ hosts. Unsupported claims are dropped and listed. | `hq_llm`, small, `sources=["public_web"]`, emails/phones redacted | `niche_report` draft; prospects (see below) |
| `offer-pricing` | Cost to deliver from the receptionist cost model (deterministic), margins, plus a short review | `hq_llm`, small | `offer_review` draft |
| `outreach-prep` (`donna-m2-sales-kit`) | Cold email, DM and call-script **drafts**. The model writes the message; the CASL footer is fixed code. Per-lead drafts fill `{business}` from the lead row; no lead data reaches the model. | `hq_llm`, small, `sources=["system"]` | `cold_email` / `dm` / `call_script` drafts |
| `delivery-onboarding` | Client intake → a `fz_reception` client config (`hq_receptionist.validate`) + a Web Studio `site.json` **draft**. Open items are listed, never guessed. | none (client data stays out of the free brain) | intake |
| `weekly-report` (`donna-m4-weekly-report`) | Plain SQL KPIs: MRR, churn, CAC, conversion by stage, delivery status. Gaps are flagged, never estimated. | none, $0 | owner message (kind `brief`) |

The weekly report also runs from pg_cron (Mondays 13:05 UTC, 09:05 Ottawa). While Donna is dormant it does nothing.

**Brain dependency (#49).** The runners call `hq_llm.complete` with the base interface on this branch: `division`, `task_class`, `tier`, `max_output`,
`sources`, `contains_client_data`. The open brain (#49) adds routing and owner switches behind the same function, so the runners work with or without it.
Every call goes through the spend gateway. A call that cost anything fails the run (`spend_outside_budget`).

**Roles.** `offices/donna.json` still has the pre-#48 role names. The runners map each mission to both names (`role` / `v1_role` in
`offices/donna_runners.json`), so they work before and after #48.

## Gates (all enforced, all tested)

- **Dormant until the owner activates Donna.** `hq_donna.run` checks `office_os_status` (profile and M1 active, no drift; fails closed). Every
  database write re-checks with `fz_donna.require_active()`.
- **Fixed mission → action map** (`fz_donna.mission_actions`, no API access). A run starts only if that action is in Donna's **green** tier and not prohibited.
- **The 8 prohibited actions** are refused by name in code (`hq_donna.PROHIBITED`) and in SQL (`fz_donna.prohibited()`), even if a profile listed them as green:

| Action | Where it is stopped |
|---|---|
| `sign_contract` | No code path. Drafts asking to sign or e-sign are refused (Python and SQL). |
| `financial_transfer` | No code path (static test). Drafts asking for payment are refused. |
| `deceptive_communication` | `Re:` / `Fwd:` subjects, fake prior conversation, claiming to be human, fake urgency: refused. A call script must say it is an AI service. |
| `fabricate` | Research facts must be on the fetched page (`verify_fact`). No client counts, reviews or guarantees in drafts. |
| `evade_platform_restrictions` | Fetches use https only, follow robots.txt, send an honest User-Agent, and never follow redirects, open login pages or use proxies. Spintax or "avoid spam filter" text is refused. |
| `spend_outside_budget` | Small tier only. A paid call fails the run. `runs.llm_cents` is checked `= 0`. |
| `deploy_website` | `site.json` is a database draft. No Web Studio or hands import (static test). |
| `modify_own_permissions` | No policy, profile or grant function is called (static test). Inputs cannot carry actions, tools or permissions. |

- **Model output is data.** It is parsed as JSON and checked. It cannot name an action, a tool, a recipient or a permission.

## CASL (not legal advice: the owner or counsel confirms)

These rules apply to every outreach draft. Python (`casl_problems`) is the strict check; SQL (`fz_donna.text_problems`) is the floor, in case Python is bypassed.

- **Email and DM must carry:**
  - sender identification ("Donna, the AI receptionist service of [OWNER: legal entity name]");
  - a mailing address;
  - an unsubscribe line.
- **A call script must:**
  - say who is calling and for whom;
  - include a remove-me (do-not-call) line;
  - say it is an AI service.
- **Never allowed:** a guarantee or refund promise (guarantee terms are TBD by the owner), a payment request, a request to sign, a claim of an earlier
  conversation, a claim to be human, spam-filter evasion.
- **A draft for a lead needs** a recorded consent basis, a lead that is not do-not-contact, and an address or number that is not suppressed
  (`is_suppressed` / `ffm_is_phone_suppressed`, called, not changed).
- **A prospect is recorded only when all of these hold:**
  - market research found its contact **verbatim on its own https page**;
  - that page has no "no unsolicited messages" notice;
  - the contact is not suppressed.

  It is stored with the consent basis `implied_published` and the URL and date in the notes (CASL: conspicuous publication; the message must relate to
  the business). Duplicates are skipped.
- **Drafts are never sent.** There is no `sent` status. Owner approval (`donna_owner_decide_draft`) approves the **copy** only. Approval is refused while
  an `[OWNER: ...]` placeholder is left. The owner edits a draft with `donna_owner_edit_draft`, which re-runs the CASL check. Sending is a later, separate
  owner step through the existing outreach gate.

## CRM (existing tables)

| Data | Where |
|---|---|
| Donna's own prospects | `public.leads` / `public.deals` of the `donna` venture, read through the existing `lead_funnel` and `venture_kpis` (unchanged) |
| Donna's clients | `client_workspaces` plus `fz_reception.clients` |

- **Stages:** new → drafted → approved_to_send → contacted/sent → replied → booked → won, then onboarding (intake) → demo → live.
- **Next actions** are computed, not stored (`donna_pipeline().next_actions`). Each says who acts: owner or one of Donna's runners.
- **Twenty CRM** was evaluated as a reference only. Its pipeline/stage model matches this one, but it is AGPL, a separate Node service and a second
  database. Not added.
- **ffm_\* consent functions:** not changed.

## Receptionist deploy kit (not applied)

Files in `ops/proposals/receptionist_deploy/`:
- `Dockerfile`: python 3.12-slim, pinned requirements, non-root, `uvicorn receptionist_server:app`.
- `railway.json`: Dockerfile builder, health check `/healthz` (added to `receptionist_server.py`), one replica.

Nothing at the repo root changes, so the bot's own Railway service is unaffected.

**Env checklist and webhooks:** `/reception kit`.

**Demo → live:** `/reception golive <client>` shows each step and who does it. All live switches stay owner-only:
1. Owner sign-off `donna_owner_golive_signoff(slug, demo_tested, client_approved, webhooks_set)`, refused unless all three are true.
2. The client's Twilio number (`reception_owner_set_client`).
3. `reception_owner_set_flags(slug, 'live', ...)`.
4. `RECEPTION_SMS_LIVE=1` on the server.

**Cost (estimates):**
- Railway: about US$5/month base plus usage. Gather mode fits 0.5 GB; stream mode with Whisper and Kokoro needs about 2 GB.
- Twilio per call and per text: see `DONNA_RECEPTIONIST_V1.md`.
- Each of these is an owner spend approval.

## Files

| File | Content |
|---|---|
| `migrations/20261207_donna_ops_v1.sql` | schema `fz_donna`, the gates, CASL floor, CRM views, weekly report, owner controls |
| `ops/rollback_donna_ops.sql` | archives to `fz_archive.donna_ops_*` (run it BEFORE `rollback_donna_receptionist.sql`) |
| `ops/OWNER_DONNA_OPS.sql` | owner steps |
| `sqltests/donna_ops_check.sql` | the rules, the rollback and the money fingerprint |
| `hq_donna.py`, `offices/donna_runners.json` | runners, research tools, CASL checker, owner views, deploy kit text |
| `test_hq_donna.py` | network, database and brain mocked |
| `hq_commands.py` | `/donna`, `/donna drafts`, `/donna run <mission>`, `/donna report`, `/reception kit`, `/reception golive <client>` |

**Rollback:** run `ops/rollback_donna_ops.sql`. Then revert the code commit. Leads, deals, workspaces, receptionist clients, consent and owner messages
stay where they are.
