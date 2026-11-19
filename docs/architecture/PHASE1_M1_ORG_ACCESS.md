# FENDEZY GROUP Phase 1, M1: Org & Access core (tenancy + identity)

Branch `build/p1-m1-org-access`. Migration `migrations/20261127_org_access_v1.sql`, rollback `ops/rollback_org_access.sql`, proof `sqltests/org_access_check.sql` and `test_hq_scoped.py`.
Nothing is live until the owner applies the migration (a release decision). Nothing changes for the bot until he also installs the tokens.

## 1. What was built

| Piece | What it is |
|---|---|
| Offices | `fz_offices` (slug, title, status): the parent **group** scope plus eight offices, all **dormant**: b2b-records, donna, the-trap, wolf-squad, pimp-ai, monopoly, ff-marketing, fruition-factory. Fixed ids (`f0000000-...-000000000000` = group, `...01` to `...08` = offices). |
| Office scope on rows | `office_id uuid not null` (default = group) on agents, departments, ventures, missions, tasks, memory. Client workspaces map to an office in `fz_workspace_offices` (no row = FF Marketing); every `ws_*` / `ffm_*` row follows its workspace. |
| Table registry | `fz_table_registry` (keyed by `relname`): **every** table in `public` (120 today + the 6 new ones) has a scope (group / office / shared), a data class (public / internal / confidential / client_restricted) and what the scoped roles may do. Grants and RLS policies for the scoped roles are generated from it. `fz_unregistered_tables()` lists any table a later migration forgets (the sqltest fails on one). |
| Identities | `fz_identities`: owner, jarvis (+ jarvis-chat, jarvis-core, jarvis-hands), one manager per office, auditor, backup-reader (existing, unchanged), release. Status dormant / active / revoked, optional pinned token id, `tokens_valid_after`. |
| Database roles | `fz_jarvis` (group scope), `fz_office_agent` (one office), `fz_auditor` (group, read-only). NOLOGIN, no BYPASSRLS, granted to `authenticator` exactly like `backup_reader`, so PostgREST switches to them from the JWT's `role` claim. |
| Helpers | `current_identity()`, `current_office()`, `current_office_id()`, `is_group_scope()`, `fz_whoami()`; policy helpers `fz_readable_offices(t)`, `fz_writable_offices(t)`, `fz_readable_workspaces(t)`. |
| Office permissions | `fz_office_action_policy` + `fz_authorize_action()`: an office layer in front of the **unchanged** `authorize_action()`. |
| Owner controls | `fz_owner_set_office_status`, `fz_owner_set_identity`, `fz_owner_set_workspace_office` (signed-in owner only). `fz_revoke_identity` (the bot may only make an identity safer). `fz_set_office_policy` (anyone may tighten, only the owner relaxes). |
| Re-seed | Done once, every decision in the append-only `fz_org_archive`; summary in `audit_log` (`org_reseed`). `fz_org_status()` shows offices, identities, archive counts, unregistered tables, orphans. |
| Python | `hq.py`: `hq.as_identity(identity)` / `hq._request(..., identity=...)` / `hq.scoped_check()`. |
| Token minter | `ops/mint_scoped_tokens.html`: offline page, paste the JWT secret, get one value to paste. |

## 2. Why this architecture

- **One database, `office_id` + RLS keyed on the identity.** A schema or database per office multiplies every migration, breaks the shared services (suppression list, consent gate, redaction keys, spend gateway) and the backup. RLS on a column keeps one copy of every rule.
- **The JWT only names an identity; the registry decides.** `fz_identity_now()` accepts a request only if: the session role is an fz role and equals the token's `role`; the token has **no `sub`** (so it can never pass for the signed-in owner through `is_app_owner()`); the identity exists, is active and is bound to that role; its office is active; the `office` claim (if any) matches; a pinned `jti` (if set) matches; the token was issued after `tokens_valid_after`. Consequence: the owner can switch off any token at once without rotating the project secret.
- **Policies apply only to the three new roles.** `service_role` (the bot today) keeps every row. On Supabase it has BYPASSRLS; where this migration had to switch RLS on (six tables that are RLS-off on the scratch replica, already RLS-on in production) a `fz_service_all` policy keeps "all rows" for it on any Postgres. anon / authenticated get no policy and no grant from this migration.
- **Policies are cheap:** each helper is evaluated once per statement (`= any (coalesce((select helper('t')), '{}'))` becomes an InitPlan), not per row.
- **Office permissions can only tighten.** `fz_authorize_action()` refuses for a dormant office, an office rule (not allowed, lower per-action cap, lower daily count), then calls `authorize_action()` unchanged for kill switch, mode, tiers, owner approvals and caps. A scoped caller cannot choose its actor or another office.

### Where I changed the plan (and why)

1. **`authorize_action` / `action_policy` are NOT modified.** They are money controls on the never-edit list. The office scope is a wrapper (`fz_authorize_action`) plus an overlay table; existing callers are untouched (backwards compatible by construction).
2. **No `office_id` column on `client_workspaces`.** Found by the sqltest: `ws_guard` (never-edit list) screens every column of a workspace row and refuses a uuid full of digits as an account number, so every FF Marketing insert would have failed. The workspace -> office map is its own table; no row = FF Marketing.
3. **No foreign key from `office_id` to `fz_offices`.** The off-site backup drops any table that references a non-exported table; agents, tasks, missions etc. would have silently left the backup. Unknown office ids are invisible to every office (fail closed) and `fz_org_status()` reports them.
4. **Group scope does not read `client_restricted` rows** (client leads, routing log, run leads). Only the office that serves the client does. Jarvis keeps working on them through the existing guarded functions with the service key.
5. **Archive is data-driven and keeps anything live** (see section 5), instead of pausing the whole old org.
6. **The FF Marketing client tables get no scoped access in M1.** They are mapped to their office (ff-marketing) and classified, but keep their reviewed design: RLS on, **no policy**, service key only, every access through the guarded FFM functions. Three existing tests assert exactly that (`client_workspaces_check` W2, `ffm_onboarding_check` F2, `insurance_classifier_check` G2); adding an fz policy would have meant loosening them, which is not allowed without the owner. `fz_readable_workspaces()` and the map are ready, so opening scoped read on them is a small M2 step with the owner's sign-off.
7. **Write access in M1 is `tasks` only** (no mission columns, no delete). Everything else is read. Each further write path is its own reviewed step.

### Placement in APPLY_ORDER

Right after `20261126_ffm_run_v1.sql` and **before** `20261112_lockdown_v1.sql` (lint rule R3: only `postlock` files may follow the lockdown, and those may only restrict). This file grants only to the new fz roles, never to public / anon / authenticated; the lockdown's blanket `grant execute ... to service_role` is harmless here because every `fz_owner_*` function checks `is_app_owner()` itself. In production the lockdown is already applied, so default privileges give the new functions to service_role only, and each function also has its explicit revoke (R4).

## 3. Table classification (126 tables)

Scope: **group** = owner / holding / Jarvis; **office** = rows belong to one office; **shared** = one service every office relies on, owned by the group. (R) = scoped identities may read their rows; (R/W) = read + write.

| Scope | Class | Tables |
|---|---|---|
| office (by `office_id`) | internal | agents (R), departments (R), ventures (R), missions (R), memory (R), tasks (R/W) |
| office (by workspace) | confidential | client_workspaces, ws_campaigns, ws_ledger, ffm_ad_sets, ffm_creatives, ffm_approvals, ffm_onboarding_items, ffm_engine_briefs, ffm_engine_packs, ffm_routing_rules, ffm_run_launches, ffm_run_settings |
| office (by workspace) | internal | ws_approved_terms |
| office (by workspace) | client_restricted | ws_leads, ffm_route_log, ffm_run_leads; consent: ffm_consent_captures, ffm_consent_log, ffm_consent_settings, ffm_consent_wordings (never-edit list) |
| office (via parent row) | confidential / client_restricted | ffm_run_budgets, ffm_run_email_batches, ffm_run_metrics, ffm_run_objects, ffm_run_receipts, ffm_run_emails, ffm_run_touches (no scoped access in M1) |
| shared | public | model_prices, ffm_onboarding_templates, ws_place_catalog |
| shared | internal | jarvis_jobs, jarvis_task_stats, hand_connectors, ws_fixed_phrases, ws_marketing_vocab |
| shared | confidential | ffm_secrets, ffm_redaction_keys, ffm_redaction_denylist, ffm_redaction_found, ffm_epoch, ffm_outreach_gate, ffm_gate_config, ffm_sender_mark, ffm_restore_markers, jarvis_result_cache |
| shared | client_restricted | contact_suppressions, ffm_phone_suppressions, ffm_suppression_hashes, ffm_suppression_expected |
| group | public | fz_offices (R) |
| group | internal | agent_runs, alert_state, build_requests, company_profile, escalations, evidence_sources, handbook, human_handoffs, ideas, integration_status, jarvis_agent_wakes, mission_outcomes, predictions, systems, tool_registry, venture_assets, venture_config, venture_goals, venture_procedures, fz_org_archive, fz_table_registry (R) |
| group | confidential | money (bank_*, ledger, payment_instructions, capital_policy, waterfall_policy, spend_reservations, llm_calls, reconciliation_flags, setter_payouts, setter_terms, jarvis_self_fund_credits), controls (system_state, action_policy, executor_registry, jarvis_core_config, jarvis_call_criteria), approvals (approval_requests, jarvis_large_approvals, hand_standing), audit (action_log, audit_log, jarvis_changelog, jarvis_job_events, jarvis_call_log, executor_runs), owner (app_owners, owner_messages, web_messages, push_config, push_subscriptions, jarvis_seed_staging, dayjob_days, dayjob_targets, org_changes), accounts (accounts_registry, account_requests, hand_accounts, hand_actions), fz_identities, fz_workspace_offices, fz_office_action_policy |
| group | client_restricted | leads, outbox, lead_replies, deals, setters, setter_events (the pre-office pipeline) |

Totals: group 71, office 33 (6 readable by scoped identities) (6 by office_id, 19 by workspace, 1 workspace itself, 7 via parent), shared 22. `select * from public.fz_table_registry` is the authoritative list (one line note per table).

Who reads what: an office identity reads its own office's rows in every (R) table (the six office_id tables); Jarvis and the auditor read every office's rows except `client_restricted`; nobody scoped reads a group or shared table except the office list and the registry; nobody scoped can delete or truncate anything, call an owner / approval / money / consent / backup function, or touch `approval_requests`.

## 4. Owner steps (only clicks and pastes; nothing changes until step 3)

1. Approve the PR (owner marker), then apply the migration in the release window (the release sheet lists it like the others). If the output says `could not grant fz_... to authenticator`, paste the one line it prints into the SQL editor.
2. Open `ops/mint_scoped_tokens.html` from your computer. Supabase: Project Settings, JWT Keys, copy the legacy JWT secret, paste it in the page, press **Mint tokens**, press **Copy**.
3. Railway, Variables: paste as `FZ_SCOPED_TOKENS`; set `FZ_GATEWAY_APIKEY` to the anon / publishable key (same value as `BACKUP_GATEWAY_APIKEY`). Redeploy.

That is all. Jarvis then runs `hq.scoped_check("jarvis")` and reports; until a token is installed or if it is unusable, every call keeps the service key. Offices stay dormant (and their tokens inert) until you activate one, which is a later decision (M2 gives it a button).
If a token ever leaks: `select public.fz_revoke_identity('<identity>', 'leaked')` (Jarvis may run it; it can only revoke), or mint again and the old ones stop working after `fz_owner_set_identity(..., p_void_tokens => true)`.

## 5. Org re-seed (what happens on apply)

- Every existing client workspace -> **ff-marketing** (and all its `ws_*` / `ffm_*` rows). Everything else -> **group**.
- Archive rule, decided once and logged per row in `fz_org_archive` with the reason:
  - **agents** kept if named by live code (jarvis, jarvis-chat, jarvis-core, jarvis-hands, builder, research, auditor, compliance-qa, mission-manager, donna-ops, the mission-engine researchers / auditors of idea-lab, donna, real-estate, day-job-sales), or with open tasks, or a model call in the last 14 days, or in / managing a kept venture. Otherwise paused + `archived_at`.
  - **ventures** kept if a mission-engine team, active, proposed (an open owner decision), or with open tasks / live missions. Otherwise only stamped `archived_at` (status untouched).
  - **departments** kept if holding / research, a kept agent works there, or its venture is kept. Otherwise paused (if active) + `archived_at`.
- On the scratch replica's seed: 4 archived (ceo, coo, cfo, hr), 13 kept. In production the counts depend on recent activity; `select public.fz_org_status()` shows them right after apply. Nothing is deleted; the rollback restores every prior status.
- Suggested later office mapping (owner decision, not done): donna venture -> donna office, real-estate -> monopoly, day-job-sales -> wolf-squad, idea-lab -> fruition-factory.

## 6. Test evidence

- `sqltests/org_access_check.sql` (run by the replica step, again after the rollback drill): for **every** office-owned table: the readable ones (6) give each of two offices exactly its own rows and **0** rows of the other (12 non-empty pairs, so it is not vacuous), every other office-owned table (27, incl. all client and consent tables) refuses the scoped roles outright and carries no policy; Jarvis / auditor see all but client_restricted; the scoped roles execute **exactly** an allowlist of 10-11 functions (no owner, approval, money, consent or backup function); no privilege on any non-readable table; no delete / truncate anywhere; Jarvis cannot write approvals, a red action still returns `ask_owner`, over-limit spend `ask_owner`, dry run and kill switch still deny; dormant office, office mismatch, office rules (tighten by bot, relax only by owner), office daily cap; seven forged / mismatched token shapes refused, jti pinning, token voiding, bot revoke-only; anon / authenticated hold nothing on fz objects and no fz policy names them; service_role row counts and writes unchanged; registry covers every table and grants equal the registry; re-seed ran once, Jarvis kept, archived rows paused + stamped, nothing deleted; backup: nothing unclassified, org tables still exported, every exported text column classified. Mutation-checked: a leaking policy, an extra function grant, a grant on approvals, a widened client-data policy and a pre-activated office each make it fail.
- `test_hq_scoped.py`: 11 unit tests (token choice, fallback, refusal of service / backup / anon roles, sub, expiry, wrong identity, gateway key refusal, never replaces the backup override, a refused scoped call is not retried with the service key) + 4 DB tests through the real `hq._request` path against the replica's RLS (run by `scripts/replica/run.sh`).
- `webtests/mint.test.mjs`: the minter's tokens verify as HS256 with the expected claims and no `sub`.
- Rollback drill in `scripts/replica/run.sh` (see 8).

## 7. Risks

- **Supabase gateway + custom role JWT is unverified against the real project** (same open point as the backup identity, G5). Step 3 plus `scoped_check` is the first real test; until it passes nothing uses the tokens.
- **The legacy JWT secret** is what mints the tokens. Projects moved to asymmetric signing keys may need the legacy secret re-enabled or a different minting path; the page refuses nothing it cannot sign. Treat the secret like the service key; the page never stores or sends it.
- **Archive could pause an agent that only a cron job uses** without tasks or model calls in 14 days. Mitigation: the rule keeps anything with recent spend or open work, the log says exactly what was paused, and `fz_org_status()` + the rollback restore it.
- **New tables added by later migrations are unregistered** until classified: they get no scoped access (fail closed) and the sqltest fails, as with backup classification.
- **RLS policy cost** on large tables: helpers run once per statement; indexes on `office_id` are added.
- The ACL manifest (`ops/ACL_MANIFEST_public.tsv`) does not have columns for the fz roles; their exact privileges are asserted by the sqltest instead (O8, O14).

## 8. Rollback

`psql -f ops/rollback_org_access.sql` (idempotent). It restores every archived agent / department to its prior status, removes the fz policies, grants, trigger and the `fz_service_all` policies (switching RLS back off only where this migration switched it on), drops the `office_id` / `archived_at` columns, the fz functions, tables and roles, and restores `backup_classification()` to the exact 20261124_jarvis_hands_v1 text. Destructive only for what M1 added (office assignments, identity registry, office rules, re-seed log); keep `select public.fz_org_status()` first if offices are in use. The replica drill runs it twice, checks every object is gone, the archived rows are back, the classification is byte-identical to the hands version, then re-applies every migration and re-runs the sqltest.

## 9. Next milestone (recommended)

**M2: Office activation + Jarvis on its token.** Owner app button to activate an office and move a workspace (`fz_owner_set_office_status`, `fz_owner_set_workspace_office`); move Jarvis's read paths (org, tasks, missions) onto `as_identity("jarvis")` one module at a time; `hq_policy.authorize(office=...)` calling `fz_authorize_action`; FF Marketing as the first active office with its manager token; reviewed redaction-spec rows so the org registry joins the off-site backup; grants for the via-parent FF tables.
