# Audit: send, outbox and spend paths

Branch `hardening/audit-paths`, from `integration/sprint2` (de70be17). Scratch Postgres only; nothing merged, deployed or sent. Protected controls
(authorize_action, outbox_send_policy, enforce_outbox_rules, spend gateway, capital, kill switch, dry-run, default-deny, permissions) are NOT changed in
`migrations/`; proposals are in `ops/pending_signoff/audit_spend_send_hardening.sql` (not applied, tested on scratch).

Gates: AZ = authorize_action, SG = spend gateway (reserve_llm_budget / reserve_spend), KS = kill switch, DR = dry-run, CASL = is_suppressed + normalize_addr
(lead flag, address list, outbox guard), VS = venture suppression (per-address across ventures, venture profile and mailing-address check).

## 1. Route table

| # | Route | Enforced | Missing / weak | Evidence | Test |
|---|---|---|---|---|---|
| A1 | Auto email send `hq_mail.deliver_approved` (a) | AZ send_email, KS+DR (inside AZ), CASL (refusal, suppressed, lead flag), VS (profile_refusal, footer, address), claim-first; DB triggers outbox_dnc_guard, enforce_outbox_rules, outbox_send_policy on the sent flip | `live()` needs mode `live`, which the CHECK constraint forbids, so it never sends (fails closed). AZ is counted twice (Python and trigger), so the effective daily cap is about half | hq_mail.py:28, 86, 129, 202-250; 20261112_permissions_v1.sql:240 | test_hq_mail, test_audit_paths.Delivery, sqltests/audit_paths_check.sql C |
| A2 | Owner mark-sent `hq_commands.mark_sent`, web `sent` verb (a) | CASL via outbox_dnc_guard (F1 fix); owner-only caller | By design skips KS, DR and send policy (`sent_by='owner'`). Any service-key writer can claim it (F2, pending) | hq_commands.py:311-328; hq_web.py:104 | audit_paths_check B, pending_signoff_check P7-P9 |
| A3 | Approve outbox row `hq_commands.apply_decision`, `draft_decision` (b) | owner tap, `_outbox_casl_gate` (dnc_problem, profile, config), DB guards | Owner identity is a caller string (F10) | hq_commands.py:331, 684, 705 | test_hq_commands, audit_paths_check C |
| A4 | Create drafts `hq_engine._store_drafts` (b) | status draft only; lead DNC and existing-draft checks; DB guards (one draft per lead, daily contact limit) | none beyond DB guards | hq_engine.py:328 | test_hq_engine, audit_paths_check B, C |
| A5 | Direct INSERT/UPDATE of outbox by any API role (b) | outbox_dnc_guard, enforce_outbox_rules, outbox_send_policy fire on every writer. anon/authenticated have no grants and no policies | Unclean address used to slip through guard (F1, fixed). sent to draft flip allowed (F3, pending) | 20261115_venture_deals_replies_v1.sql, 20261116_audit_hardening_v1.sql | audit_paths_check B, C, E |
| A6 | Unsubscribe `mark_do_not_contact` and DNC flag cascade (a, b) | suppression list is append-only; drafts rejected; leads flagged | Raised on leads with open drafts under the live trigger, so opt-outs could be lost (F13, fixed) | 20261116_audit_hardening_v1.sql:73 | audit_paths_check B14, B15 |
| A7 | LLM spend: `hq_meter.metered_create`, `metered_call`, `begin_session`, `record_spent_usd`, `hq_engine.run_turn_sync`, `_credit_probe` (c) | SG reserve_llm_budget (caps, KS, hard stop, mission budget, focus); static allowlist test | Gateway accepts negative estimates and actuals (F7, pending; no caller passes them) | hq_meter.py:155-250; hq_engine.py:696 | test_no_bypass, test_spend_paths, audit_paths_check F |
| A8 | Capital `hq_capital.reserve/settle`, `reserve_spend` (c) | AZ (tier, limits), KS, DR, owner approval above limit | settle accepts any amount (F8); green action label accepted in dry-run (F9). Both pending. No caller in code today | hq_capital.py:47, 62; 20261112_capital_v1.sql:107 | audit_paths_check G, pending_signoff_check P4-P6 |
| A9 | Payments `hq_payments.prepare/decide/confirm`, setter payout (c) | owner decision, confirm with typed amount, AZ | Owner identity string (F10) | hq_payments.py:33-70 | audit_paths_check G |
| A10 | `bot.py` Make webhook, n8n trigger (a, c external) | owner-only, KS (F5 fix), per-call approval for Make (F5 fix) | DR not enforced for owner-initiated triggers | bot.py:864, 889, 1063, 2046 | test_audit_paths.BuildSandbox |
| A11 | `/build` agent sessions with Bash (c, a) | owner-only, metered | Bash inherited all secrets (F4, fixed via `_build_env`). ANTHROPIC key still present | bot.py:858, 2273, 2414 | test_audit_paths.BuildSandbox |
| A12 | PWA RPCs `app_send`, `app_set_kill`, `app_set_agent`, `app_venture*`, `app_payments`, `app_office`, `app_snapshot`, `app_messages`, `app_save_push` | `is_app_owner` (verified email), security definer, fixed search_path; `app_send` only writes `web_messages`, handled by owner-verified `hq_web.handle` | none found. `app_needs_you` not yet granted (pending file exists) | 20261112_webapp_v1.sql; hq_web.py:134; webapp/app.js | audit_paths_check E |
| A13 | Deals `create_deal`, `confirm_deal_won` (revenue) | one open deal per lead, money cap, idempotent confirm, ledger row once | direct `deals.stage='won'` records no revenue (F17, count only) | 20261115_venture_deals_replies_v1.sql:147, 187 | audit_paths_check H |
| A14 | Missions `hq_missions` spawn, recurrence, recovery | mission_guard budget, due date, blocked steps | claim left behind by a crash stopped recurrence (F16, fixed) | hq_missions.py | test_hq_missions, audit_paths_check H |

## 2. Bypass verdicts (anon / authenticated / agent roles)

- Spend gateway: anon and authenticated cannot execute it. API (service) role can only call it, and the callers meter correctly. Refuted for non-service roles; service role can pass odd numbers (F7, F8, pending).
- Permissions and default-deny: refuted for anon/authenticated (function allowlist, no table grants, no policies, RLS on, tested). A service-key holder can edit policy or insert already-approved approvals (F10, F12): structural.
- Kill switch and dry-run: enforced inside AZ and the send policy, for every writer except `sent_by='owner'` (F2).
- Unsubscribe suppression: bypass PROVEN before the fix with trailing dot, quoted local part, comments, NBSP, zero-width and fullwidth characters (F1). Now refused. Tested with alternate address forms, multiple ventures, direct inserts, direct status flips, retargeting and channel flips. The old functions fail the new test (mutation check).
- Approval flow: status cannot advance without the guards; owner decision remains a trusted-string path (F10, F11).

## 3. Findings

| ID | Severity | Finding | Status |
|---|---|---|---|
| F1 | Medium | normalize_addr and the outbox guard let alternate address forms past the suppression list; guard did not re-check on retarget | Fixed (migration 20261116, hq_mail.py, shared SQL/Python table) |
| F2 | Medium (protected) | `sent_by='owner'` marker skips KS, DR and policy for any API writer | Pending sign-off (`owner_mark_sent` + GUC); needs a Python change |
| F3 | Low | `sent` can be flipped back to draft and re-sent | Pending (`outbox_sent_is_final`) |
| F4 | High | `/build` Bash session inherited the service key, mail key and other secrets | Fixed (`_build_env`) |
| F5 | Medium | Make and n8n triggers ignored the kill switch; Make had no per-call approval | Fixed |
| F6 | Low | Sprint rollback (DROP FUNCTION ... CASCADE) silently drops the suppression address CHECK | Fixed (restored in migration) |
| F7 | High, latent | reserve_llm_budget accepts negative estimate; settle_llm_call accepts negative actuals and re-settling | Pending sign-off |
| F8 | Medium, latent | settle_spend accepts any actual; refused send rolls back its own action_log row | Pending (first part); second is observability only |
| F9 | Medium, latent | reserve_spend accepts a green action label in dry-run | Pending (`spend_reservation_action_guard`) |
| F10 | Medium, structural | owner identity is a caller string; any service-key holder can act as owner | Not fixable in code; needs per-owner auth |
| F11 | Low | decide_approval depends on trusted calling code | Residual |
| F12 | Low | API role can INSERT new action_policy rows | Pending (`action_policy_api_insert_guard`) |
| F13 | High | `mark_do_not_contact` raised under the live outbox_rules trigger when the lead had an open draft, losing the opt-out | Fixed |
| F14 | Medium | send-then-mark: DB refusing the sent flip after the provider accepted caused a duplicate email next day | Fixed (claim first, release on failure, flag unrecorded) |
| F15 | Info | `hq_mail.live()` never true (mode `live` not allowed) | Not changed |
| F16 | Low | crashed recurrence claim blocks the series forever | Fixed (`_heal_stale_claim`, 15 min) |
| F17 | Low | `deals.stage='won'` set directly records no revenue | Documented, asserted |

## 4. Tests added

- `sqltests/audit_paths_check.sql` (sections B to H, one rolled-back transaction); `sqltests/pending_signoff_check.sql` (applies the pending file inside a rolled-back transaction; before and after asserts); extra normalize cases in `sqltests/venture_deals_replies_check.sql`.
- `test_audit_paths.py` (normalize, delivery at-most-once, build env, Make/n8n gates, route inventory); new stale-claim and recurrence-end tests in `test_hq_missions.py`; updated `test_hq_mail.py`.

## 5. Residual risk

- One shared service key is both the engine and the owner: owner strings can be forged by anyone holding it (F10).
- `ANTHROPIC_API_KEY` stays in the `/build` environment, so a builder could call the model outside the gateway. The Bash blocklist is substring-based.
- Dots in local parts are not folded (gmail-only); the migration notes why.
- Replica fidelity gaps: no `outbox_rules` trigger, no RLS on core tables, service_role has no BYPASSRLS or sequence grants. The sqltests compensate inside rolled-back transactions; live RLS is proven by `ops/verify_live.sql`.
- Make/n8n triggers do not check dry-run.
- Double authorize count halves the effective send cap.
- Pending sign-off items need a human decision before use; F2 also needs a coordinated Python change.


## Final-review addendum (2026-11-13)
F4 status: MITIGATED, not fixed. The Bash/Read gates and env scrub raise the bar, but the build session shares a uid with the bot; real isolation needs a separate uid/container (owner/infra decision). `ANTHROPIC_API_KEY` is intentionally still passed.
