# Donna Revenue Loop v1

The money loop around Donna Ops v1 (#54). It turns every inquiry into a lead, an answer, a booked audit, a proposal and follow-ups. Every email waits for the
owner's one tap in Telegram. Stacked on #60.

## The loop

```
website form ─┐                                    ┌─ reply to the inquiry ──────┐
Donna web call ├─ inbound sync ─ lead (CRM) ───────┤                             ├─ outbox draft ─ owner taps Approve ─ hq_mail sends
Donna phone ──┘   (every 5 min)                    ├─ booked? audit brief ─ owner │
                                                   └─ no reply? follow-up 2 and 3 ┘
after the audit: /donna proposal <lead #> <package> <monthly $> | findings ─ proposal email ─ outbox draft ─ owner taps Approve
```

| Step | What happens | Switch |
|---|---|---|
| Inbound sync | Pulls Netlify form submissions and Retell calls (read-only APIs), then calls `donna_ingest_inbound`. One row per source + ref, so it is idempotent. | `DONNA_INBOUND=1` |
| Reply | A plain-code reply to each new inquiry. A booked lead gets three prep questions; a lead that isn't booked gets the audit offer, its own leak number and the booking link. | `DONNA_AUTODRAFT=1` and Donna active |
| Audit brief | For each booked audit, the owner gets in Telegram: their leak check, the likely package, his price guide, the questions to ask, and the proposal command. | same |
| Follow-ups | Email 2 three days after the first send, email 3 four days later, then stop. Never sent while one is already waiting. | same |
| Proposal | The owner types the package, the price and his findings; Donna writes the email. | `/donna proposal` |

## Why it is safe

- **Nothing is sent from this code.**
  - `donna_stage_outbox` puts a draft in `public.outbox` with status `draft` and `needs_owner`, and the owner gets an Approve / Reject message.
  - Approve runs the existing gate: CASL profile, suppression, do-not-contact, kill switch, policy caps and the outreach gate. Only then can `hq_mail` send.
- **One mailing address.**
  - The footer uses `company_profile.mailing_address`, set with `/setaddress` in Telegram. That is the same address `hq_mail` requires.
  - Until it is set, drafts carry `[OWNER: mailing address]`, and staging refuses them.
- **Consent comes from what the person did:**
  - ticked the (unticked by default) marketing box → `express_web_form`, with the wording version recorded;
  - otherwise → `implied_inquiry` (CASL s.10(10)(b): an inquiry, dated in the notes);
  - a call is never express consent;
  - consent is never downgraded;
  - a suppressed address or number makes the lead do-not-contact.
  - This is not legal advice: the owner or counsel confirms.
- **No lead data reaches a model.** Templates are plain code. The module does not import `hq_llm` (static test).
- **Dormant stays dormant.**
  - Inbound sync only records inquiries the owner already gets as Telegram alerts.
  - Drafting, staging, follow-ups and briefs refuse until Donna is active, both in the database and in the code.
- **Prices are the owner's.** They are read from `donna_ops/runners.json` (`revenue.packages`) and never set by an agent. The Dec 31 free-setup line disappears on Jan 1.

## Fix included

`hq_mail.deliver_approved` selects `outbox.subject`, but the live `outbox` table never had that column (`scripts/replica/01_tables.sql`). The select failed, so no
approved email could ever be sent. The migration adds the column: nullable, at most 200 characters. The rollback keeps it.

## Owner steps (Railway variables; he pastes the values)

1. `DONNA_INBOUND=1`, `NETLIFY_TOKEN` (Netlify → User settings → Applications → new access token), `NETLIFY_SITE_ID` (Netlify → Site configuration → Site ID).
2. `RETELL_API_KEY` (the same key the site already uses) and `DONNA_AGENT_IDS` (the demo-line and website agent ids, comma-separated).
3. `/setaddress donna <P.O. box>` in Telegram, once.
4. `DONNA_BOOKING_URL` (the Cal.com audit link), optional. Without it, replies ask for two or three times.
5. Activate Donna (`office_os_activate`), then set `DONNA_AUTODRAFT=1`.
6. For sending: `RESEND_API_KEY` + `MAIL_FROM` on the new domain (`hq_mail`), live mode, and the outreach gate verified (existing runbook).

## Telegram

| Command | What it does |
|---|---|
| `/donna inbound` | Recent inquiries, booked count, emails waiting for approval, sent this week |
| `/donna sync` | Pulls the form and the calls now |
| `/donna brief <lead #>` | The audit brief |
| `/donna proposal 12 growth 797 \| misses 6 calls a week; quotes never chased` | A proposal for approval |

## Files

| File | Content |
|---|---|
| `migrations/20261210_donna_revenue_loop_v1.sql` | Schema `fz_donna_rl` (inbound, staged, briefs), 7 functions (service path only), the `outbox.subject` fix |
| `ops/rollback_donna_revenue_loop.sql` | Archives to `fz_archive.donna_rl_*` and drops the functions. Run it BEFORE `rollback_donna_ops.sql` |
| `sqltests/donna_revenue_loop_check.sql` | Rollback, ACLs, consent rules, dormant refusals, staging refusals, follow-up limits, briefs |
| `hq_donna_revenue.py`, `test_hq_donna_revenue.py` | Sync, templates, runner modes, tick, Telegram views |
| `hq_donna.py` | `outreach-prep` and `offer-pricing` dispatch the new modes |
| `hq_commands.py`, `bot.py` | `/donna inbound / sync / brief / proposal`; the 5-minute job |
| `donna_ops/runners.json` | `revenue` block: offer, packages, price guide, questions; CASL sender = Abundance AI Adoption Inc. |

**Rollback:** run `ops/rollback_donna_revenue_loop.sql`, then revert the code commit. Leads, outbox rows (the owner's decisions) and audit rows stay.
