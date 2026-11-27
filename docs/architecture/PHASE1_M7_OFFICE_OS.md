# FENDEZY GROUP Phase 1, M7: Office operating system (template + 8 offices)

Branch `build/p1-m7-offices`, stacked on `build/p1-m6-monitoring-brain` (M6, unmerged). Migration `migrations/20261203_office_os_v1.sql`, rollback `ops/rollback_office_os.sql`,
proof `sqltests/office_os_check.sql`, `test_hq_office_os.py`, `scripts/test_check_integrations.py`; owner statements `ops/OWNER_OFFICE_OS.sql`; connections `ops/CONNECT_SESSION_CHECKLIST.md`.
Nothing is live until the owner applies M1..M6 and M7. Every office stays DORMANT until the owner activates it.

## 1. What was built

| Piece | What it is |
|---|---|
| Profiles | `fz_office_os.fz_office_profiles`: one row per office (8, seeded dormant, no manager): mission, allowed agent roles, allowed integrations (keys of `scripts/check_integrations.py`), autonomy defaults (green / yellow / red / prohibited action lists), data class, status `dormant / prepared / active`, manager (NULL until the owner appoints one), activation approval, advisory activation rank (Donna 1, Wolf Squad 2, FF Marketing 3). |
| Owner controls | `office_os_set_manager`, `office_os_activate`, `office_os_decide`, `office_os_deactivate`: signed-in owner only (`is_app_owner()`). |
| Activation | Three owner steps. (1) `office_os_activate` (manager required) inserts an `approval_requests` item (`office_activate`, `office:<slug>`, 3-day expiry, shown in the M3 queue / `/approvals`) plus an informational Telegram note, and a single-use 64-hex nonce in `fz_office_os.fz_office_decisions` (no API privileges: the service key can neither read nor write it); the office is `prepared` (M1 still dormant, M2 still refuses spend). (2) `office_os_decide(office, nonce, true/false)` records the owner's decision there, once, and mirrors it onto the approval item for the queue. (3) `office_os_activate` again requires THAT decision (approved, unconsumed, unexpired, same request), consumes it, turns every prohibited entry that is a real `action_policy` action into an office block (`fz_set_office_policy(..., false)`: tighten only), and sets M1 active through the unchanged `fz_owner_set_office_status`. `approval_requests.status` is never read: the service key can write it (review finding 1). Rejected / expired: back to dormant. |
| One at a time | The function refuses while another office is prepared, and a unique partial index on the table allows at most one prepared row. A check constraint forbids a prepared or active office without a manager. |
| Prohibited lists | Entries that are `action_policy` actions (e.g. `sign_contract`, `financial_transfer`, `deceptive_communication`, `fabricate`, `deploy_website`) are **enforced** as office blocks at activation. The rest (e.g. `buy_streams`, `sexual_content`, `earnest_money`) are **advisory only**: in every agent prompt and in `/office`, not a database rule. `office_os_status` returns both lists. |
| Drift alert | `office_os_drift_check()` (pg_cron every 10 minutes; service path only): when M1's status and the profile disagree (for example an office set active directly with M1's function), the owner gets ONE Telegram alert per change, audited; cleared when back in sync. `/office` starts with `!!! DRIFT ALERT`. The M1 function is not changed. |
| Status | `office_os_status(office | null)` (service path): profile + M1 status + drift flag + approval state + M2 available balance. Telegram `/office <name>` (owner only; plain `/office` is unchanged). |
| Agents | `offices/TEMPLATE.json` (rules, prompt header) + `offices/<slug>.json` (3-4 core agents per office, one per allowed role, small model tier). `hq_office_os.system_prompt()` joins them with the profile. |
| Shared brain | `hq_office_os.brain_facts()`: M6's only read path, RPC `fz_brain_read(p_query, p_limit 1-50)`, through the office's identity (`office:<slug>:manager`; without installed tokens the service key reads and the database returns group facts only). Each returned fact is re-checked (scope `group` or the own office slug). Behind `FZ_BRAIN_FACTS=1` (default off: no request at all). |
| Integrations | `scripts/check_integrations.py`: 27 integrations, presence of env var names only, never a value. |

## 2. Why this architecture

- **Profiles in their own schema, not `public`.** A public table must be in the M1 registry and in `backup_classification()` (a protected backup object). In `fz_office_os` with no privilege for any API role it needs neither, and nothing can read it except the four functions. Cost: not in the off-site export; a restore re-seeds the template dormant (fail closed), and a rollback + re-apply restores manager appointments from `fz_archive`.
- **Function names `office_os_*`, not `fz_*`.** The M1 rollback drill (scripts/replica/run.sh) asserts no public `fz_*` function survives it; M7 has no structural dependency on M1..M5 (late-bound plpgsql, no views, no grants to the fz roles), so it survives every other layer's rollback without editing their protected drills.
- **M1 stays the authority for status.** Activation calls M1's own owner function; the M2 gate keeps refusing anything not active in M1. M7 adds the manager and approval steps in front; `office_os_status` flags drift if someone changes M1 directly.
- **No grants to scoped roles.** The M1/M2 tests pin each scoped role's function allowlist. `office_os_status` still refuses a scoped caller for any office but its own if a grant is ever added by mistake (tested).
- **No budgets.** The profile has no money field. Offices draw on need through M2 (`fz_owner_allocate`, office gate).

### Where I changed the brief

1. `fz_office_activate` is `office_os_activate` (naming: see above).
2. "Creates an M3 approval item": M3 has no table (it is a view), so the item is an `approval_requests` row. Its status is only a mirror for the queue; the decision that counts is the owner's nonce-bound one in `fz_office_os`.
3. `/office <name>` extends the existing `/office` (which already existed) instead of a new command.
4. Review fix 3 (M7 in `scripts/replica/run.sh`: fingerprint condition + a rollback drill + M7 rollback before M6's in every chain) was **not applied**: the permission system refused the edit to the protected harness. The same proof runs inside `sqltests/office_os_check.sql` (which run.sh executes for every sqltest): see O1. The run.sh edit needs the owner (proposal: `ops/proposals/office_os_run_sh.md`).

## 3. Test evidence

`sqltests/office_os_check.sql` (run by the replica step; one rolled-back transaction):
- **O1** (the rollback drill) money fingerprint identical with M7, after its rollback (twice) and after re-apply; nothing left (functions, schema, drift job); profiles / decisions / drift rows archived with no loss (8/1/1, manager kept); M1 / M2 / M6 functions byte-identical across the rollback; one export record; no API role reaches the archive; the manager survives rollback + re-apply, nothing pending or active is restored, the drift job is back.
- **O2** 8 profiles = the 8 M1 offices (same ids), all dormant, no manager, M1 all dormant, integration keys valid, no action in two tiers, activation order Donna / Wolf Squad / FF Marketing.
- **O3** no API role has usage on the schema or any table privilege; only service_role executes the functions; the bot cannot read or write the table.
- **O4** set-manager / activate / deactivate refused for the bot, a session without the owner uid and a scoped token; nothing changed.
- **O5** activation without a manager refused, no approval created; the table refuses an active office without a manager; bad labels / unknown office refused.
- **O6** all 8 dormant offices refused by the M2 gate (two of them funded).
- **O7** prepared: approval item + informational note + M3 queue row; the nonce appears in no service-readable table; prepared office still cannot spend; undecided does not activate; a second office is refused (function AND index); **the service key approving the request itself (and a forged approved request) does not activate**; the bot / a session without the owner cannot decide; wrong nonce, another office's nonce and a second decision are refused; the bot cannot finish; the owner finishes: decision consumed, M1 active, audited, idempotent, `deceptive_communication` applied as Donna's only office block, the gate no longer refuses as dormant; manager cannot be removed from an active office.
- **O13** drift: one alert per change (not two), shown in status, cleared and audited; anon and a scoped role (even if granted) cannot run the check; enforced vs advisory prohibited lists.
- **O8** rejected and expired decisions return the office to dormant; an expired request cannot be decided; a fresh nonce each time; no office block without activation; it still cannot spend.
- **O9** office A cannot read office B: no privilege at all; with a mistaken grant the function serves Donna's token Donna only (non-vacuous), refuses B, all, a dormant identity and anon.
- **O10** status for one / all offices, unknown office, drift. **O11** deactivate. **O12** nothing unregistered or unclassified.
- Mutation-checked: 41 mutants (30 SQL incl. rollback, 11 Python), all killed. Two first survived (a scoped grant placed before the revoke loop: equivalent, moved to the end of the file; a prompt role check masked by a missing agent file: test strengthened), one Python survivor was a stale-bytecode artefact (rerun with `PYTHONDONTWRITEBYTECODE=1`).

## 3b. Donna v1 (owner direction, config and prompts only)

- `offices/donna.json`: an owner-direction `brief` (Ottawa AI infrastructure and digital-presence agency; first milestone 3 paying clients; service lines A and B; no niche locked; prohibitions) is added to every Donna prompt. There are 4 core agents on the small tier: Market research, Offer and pricing, Outreach prep, and Delivery and onboarding. They map onto the four seeded role ids, so no SQL changed. **The database mission and prohibited list still hold the M7 seed**; the brief is advisory until a later SQL change carries it (that change needs a gate).
- `offices/donna_missions.json`: four first missions in `hq_missions.create_mission` format. Mission 1 is market VALIDATION before any niche commitment: missed-call audits and pricing checks across the top 3 researched segments (home-services trades, roofing and renovation, law firms intake only), then a ranking for the owner, who commits the niche. Then the sales kit (drafts), the demo line plan and the weekly KPI report. Pricing and the founding offer ($497 for the first month, setup waived) are included. **There is no guarantee or refund promise anywhere**: "guarantee terms TBD by owner". All budgets are 0. `hq_office_os.queue_missions('donna')` creates them only while Donna is active, in sync with M1 and not drifting, and only if the `donna` venture exists (otherwise `create_mission` would file them under the idea lab). It is idempotent by title. Each step still goes through the task board, owner approvals and `authorize_action`.
- Funding requests: `hq_office_os.request_money(office, cents, purpose, expected_return, payback, cheapest_alternative, deadline)` calls only the existing M2 `fz_propose_office_money` (kind `allocate`) through `hq_office_money.propose`. It is a proposal in `/approvals`; no money moves and no limit changes. It is refused unless the office is active. **Gap:** that dormant refusal lives in Python only. M2's SQL accepts a proposal for a dormant office by design, because allocating to a dormant office is allowed. A database-level refusal needs an M2 change.
- Tests: `test_hq_office_os` 18 tests, including no mission queued and no request filed while dormant, prepared, drifting or unreadable, and a request reaching only `fz_propose_office_money`. 10 mutants of the new gates, all killed.

## 3c. Client invoicing (Donna bills clients)

- `hq_invoices.py` is off unless `FZ_STRIPE_INVOICING=1`. With the flag off it makes no Stripe call and no database call.
- `STRIPE_SECRET_KEY` must be a test key (`sk_test_` / `rk_test_`), or a live key (`sk_live_` / `rk_live_`) together with `FZ_STRIPE_LIVE=1`. The owner sets both in Railway; the bot cannot set environment variables.
- The office must be active and in sync, and the database re-checks this, plus that `stripe` is in the office's allowed integrations. Donna's seed now includes `stripe`.
- Only these Stripe calls are allowed: invoices (create draft, read, delete a draft, finalize, send), invoice items, prices and payment links. **No refund, payout, transfer, credit-note or balance call exists or is allowed**, and a test enforces that.
- Drafting is free. A payment link is recorded but never sent by the bot; the owner shares it.
- **A one-off invoice is sent only after the owner's per-invoice decision.**
  - `office_os_invoice_request_send` puts the item in `/approvals`.
  - The owner decides with `office_os_invoice_decide(id, cents, approve)`: signed-in owner only, with the amount echoed. The decision is stored in `fz_office_os`, which the service key cannot write.
  - The bot then claims the send once. It re-checks Stripe right before finalize + send: still a draft, same amount, same currency, same mode.
  - Any failure is recorded as `send_failed`.
- **A recurring billing plan is approved once.**
  - The plan holds client label, Stripe customer id, amount, currency and interval (month or year). The owner approves it with `office_os_plan_decide(id, cents, interval, approve)`, amount and interval echoed.
  - After that, `office_os_invoice_record_plan` records this period's invoice as approved, but only for exactly the plan's amount, currency and interval, only once per period (Toronto calendar), and only while the plan is approved and the office is active.
  - A larger amount, another interval, a second invoice in the period, a one-off or a revoked plan is refused there. A revoked plan also blocks the send claim of an invoice already recorded.
  - `office_os_plan_revoke` (owner or service path; revoking only makes things safer) stops auto-send at once.
- Recording: each invoice row in `fz_office_os.fz_office_invoices` carries its `office_id`, and the database functions audit-log it. There is no ledger write and no reservation, and no cap or limit changes. Incoming money is revenue only.
- Telegram `/invoices` (owner only):
  - list;
  - `request <id>`;
  - `send <id>`;
  - `plans`;
  - `bill <office>`: this period's plan invoices.
- **Hardening (test mode first):**
  - Payment failure: `check_plans`, which also runs first inside `bill_plans`, and `/invoices check <office>` read each approved plan's last sent invoice in Stripe.
    - Paid: logged once (revenue only).
    - Uncollectible, or unpaid 7 days (`FZ_BILLING_GRACE_DAYS`) after the due date: the plan goes `past_due` (`office_os_plan_past_due`). That stops every further auto-send, tells the owner once, and only the owner can undo it with `office_os_plan_resume`.
  - Duplicate-charge protection, in addition to the once-per-period rule:
    - a Stripe `Idempotency-Key` per (plan, period) on create, item, finalize and send (`fz-<plan>-<period>-<step>`; a one-off uses `fz-inv-<invoice>-<step>`);
    - before creating, Stripe is re-checked for an invoice carrying the same plan and period metadata.
  - Billing log: `fz_office_os.fz_billing_log`, append-only (no API privileges; update, delete and truncate refused by trigger even for the table owner). It records every event: requested, drafted, approved, sent, paid, failed, cancelled, past_due, resumed. `/invoices log` shows it.
  - Cancellation: `/invoices cancel <plan>` (owner chat) is immediate, stops every future period, never refunds, and is logged. It uses the safety-only revoke. The SQL editor's `office_os_plan_cancel` is owner-signed.
- **Final review fixes:**
  - **Every invoice is bound to its Stripe customer.**
    - A one-off records its `cus_` id, which shows in the owner's decision message and in `/invoices`.
    - A plan invoice is recorded only if Stripe's customer equals the approved plan's customer, and the database refuses another.
    - `send()` refuses, and logs as failed, when Stripe's customer differs from the recorded one, or when a plan invoice's `fz_plan` / `fz_period` metadata differs from the recorded plan and period.
  - **Restricted key:** a full live secret key (`sk_live_`) is refused unless `FZ_STRIPE_ALLOW_FULL_KEY=1`. The checklist asks for a restricted key with only invoice, invoice item, price and payment link write, plus customer read.
  - **Missions follow their office** (`hq_mission_gate.py`, hooked from `hq_missions`; `hq_engine.py` unchanged):
    - `create_mission` refuses a mission whose venture's office is not active.
    - Each tick (`advance`) first pauses, not fails, the live missions of inactive offices and cancels their waiting tasks. It resumes them when the office is active again.
    - The owner's own pauses are never undone.
    - An unreadable gate moves nothing.
- **Gaps (owner decisions):**
  1. Scheduling: `ops/proposals/billing_schedule.md` gives the one-line engine change (`hq_invoices.run_due()`, once a day at 09:00 Toronto). Until it is approved, billing runs only on `/invoices bill donna`.
  2. Paid invoices are not booked automatically; there is no Stripe webhook. Book revenue with `/money in`.
  3. Stripe calls reuse the existing official-API transport (`hq_hands_adapters.http`: one no-redirect opener), so no new outbound call site is added. The invoice send route (Stripe finalize + send, then `office_os_invoice_mark_sent`) is new: add it to `AUDIT_PATHS.md` and `test_audit_paths.py`. Both are protected, so that is an owner follow-up.
  4. The M5 `payments` service registry row is unchanged. It registers `payment_instructions` (outgoing, protected), and changing what it writes is an owner-only registry change, so invoices are attributed by `office_id` in their own table instead.
- Tests:
  - `sqltests/office_os_check.sql` O14 (one-off) and O15 (plans);
  - `test_hq_invoices.py` (16 tests, all Stripe calls mocked, no network): flag off makes no call; key rules (live without the owner switch refused); dormant office refused; send without approval refused; Stripe re-check; plan invoices for the exact amount only; a database refusal deletes the draft; a revoked plan stops auto-send; no refund or payout path.

## 4. Risks

- The owner can still set an office active directly with M1's `fz_owner_set_office_status`, skipping the manager and decision steps; the drift job alerts within 10 minutes and `/office` flags it.
- The redirect OAuth connectors (Meta, TikTok, LinkedIn, X) cannot be connected without pasting into Telegram until an OAuth return page exists (a build item); the checklist defers them.
- Profiles are not in the off-site export (see 2).
- Jarvis hands call FF Marketing's division `ffm`; the M1 office slug is `ff-marketing` (`/connect ... ffm`).

## 5. Rollback

`psql -v ON_ERROR_STOP=1 -f ops/rollback_office_os.sql` (one transaction, idempotent; FIRST of the Phase 1 rollbacks, though order does not matter). It writes one audit_log export row, moves the profile, decision and drift tables (rows intact) into `fz_archive` (an older archive moves to `fz_archive_<timestamp>`), unschedules the drift job, drops the six functions and the empty schema. It does not change any M1 office status.

## 6. Next step

Owner: run the connect session, then appoint Donna's manager and activate Donna. Build: apply each office's prohibited list through `fz_set_office_policy` at activation, and wire office agents to the scoped office token once M6 lands.

## 7. Follow-up: Donna v1 profile (`migrations/20261204_donna_v1_profile_v1.sql`)

- **What it does:** a data-only change of Donna's single M7 profile row, so the database matches the v1 brief in `offices/donna.json`. It sets:
  - the mission: Ottawa AI infrastructure and digital-presence agency; 3 paying clients; service lines A and B; no locked niche; founding offer $497 first month with setup waived; guarantee terms TBD by owner;
  - the 4 v1 roles: `market-research`, `offer-pricing`, `outreach-prep`, `delivery-onboarding`;
  - the integrations and the green / yellow / red tiers;
  - a prohibited list holding all 8 mapped `action_policy` actions (`sign_contract`, `financial_transfer`, `deceptive_communication`, `fabricate`, `evade_platform_restrictions`, `spend_outside_budget`, `deploy_website`, `modify_own_permissions`; all seeded by `20261112_permissions_v1.sql`, and checked at apply time) plus advisory entries.
- **Guards:**
  - Refused unless Donna is dormant, in both the profile and M1.
  - Idempotent: a re-run with the v1 values already in place does nothing.
  - The previous values are kept once in `fz_archive.donna_profile_before_v1`, which no API role can reach.
- **What it never touches:** no other office, no money control, no protected object. `audit_log` is written by INSERT only, so it works under the production append-only lock.
- **Rollback:** `ops/rollback_donna_v1_profile.sql` (run it before `rollback_office_os.sql`). It restores the archived values exactly, only while Donna is dormant.
- **Tests:** `sqltests/donna_v1_profile_check.sql` runs with the append-only triggers on `audit_log` and `ledger` added. It covers the v1 values, the enforced and advisory split, the archive, the idempotent re-apply, the rollback restoring exactly, re-apply, refusal while active (profile or M1), the other 7 offices unchanged and the money controls unchanged.
- **Note:** re-applying M7 alone resets the template rows, including Donna. The full apply order always runs this file after M7.
