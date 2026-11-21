# FENDEZY GROUP Phase 1, M2: Office money (virtual sub-ledgers + owner allocation)

Branch `build/p1-m2-office-money`, stacked on `build/p1-m1-org-access` (M1, unmerged). Migration `migrations/20261128_office_money_v1.sql`, rollback `ops/rollback_office_money.sql`, proof `sqltests/office_money_check.sql` and `test_hq_office_money.py`, owner statements `ops/OWNER_OFFICE_MONEY.sql`.
Nothing is live until the owner applies the migration (a release decision). Nothing spends differently until code calls the new office gate: today no caller does.

## 1. What was built

| Piece | What it is |
|---|---|
| Sub-ledgers | `fz_office_money` (view): per office allocated, clawed back, revenue, expense, AI, spent, reserved, profit, reinvest %, **available**. One row for the group too (no balance: group capital is the capital controller's). |
| Allocations | `fz_office_allocations`: append-only allocate / clawback events with amount, reason, proposal link. Written **only** by the signed-in owner (function check + table trigger). `fz_office_allocation_log` (view) shows them. |
| Reinvestment rule | `fz_office_money_policy`: per office, 0-100 %. No row = **0 %** (dormant). Owner only. |
| Proposals | `fz_office_money_proposals`: the bot / Jarvis propose allocate, clawback or reinvest (`fz_propose_office_money`, max 3 pending per office, 7-day expiry, Telegram note to the owner). Only the owner executes or rejects (`fz_owner_decide_office_proposal`); executing re-checks today's numbers. |
| Attribution | `fz_money_attribution`: which office each ledger row, model call and spend reservation belongs to. Stamped once by the office gate or by `fz_money_stamp()` (every 15 min via pg_cron, and inside every gate / owner call). Only the owner re-attributes (`fz_owner_attribute_ledger`). Never deleted. |
| Office spend gate | `fz_reserve_office_spend(office, ...reserve_spend args)`: refuses when the office is not active or its available balance is below the cost, otherwise returns exactly what the unchanged `reserve_spend()` decides and stamps the reservation to the office. Service path only. |
| Owner controls | `fz_owner_allocate`, `fz_owner_clawback`, `fz_owner_set_reinvest`, `fz_owner_decide_office_proposal`, `fz_owner_attribute_ledger`: `is_app_owner()` only. |
| Report | `fz_money_report()`: offices, group, totals, capital available + mode, **unallocated** group capital, pending proposals. Telegram `/offices` (read-only, owner chat only) prints it. |
| Python | `hq_office_money.py`: `offices_text()`, `propose()`, `reserve()` (fails closed). `hq_commands.py`: `/offices`. |

## 2. Why this architecture

- **No change to any existing money object.** Not one trigger, column or function body on the ledger, llm_calls, spend_reservations, capital_policy, action_policy, system_state, approvals or any executor. The sub-ledgers are a view that READS them; the gate WRAPS `reserve_spend()`. The sqltest proves it byte for byte (section 6, M10).
- **Attribution side table, not an `office_id` column on the ledger.** A column (or a trigger) would edit a never-edit money table and its backup export; the side table has no foreign key (M1 lesson: the backup drops any table that references a non-exported one) and keys on the source row id.
- **Stamp once, then immutable.** Deriving the office live from the venture would silently move history when the owner later moves a venture between offices (and would loosen the old office). Rows are stamped within 15 minutes (and immediately by the gate); until then the view applies the same rule live. Rows before the cutover (the apply time) are the group's.
- **Owner-only like M1.** `is_app_owner()` (signed-in app owner) at the function AND at the table; `service_role` (the bot) holds only SELECT on the raw tables. Proposal flow is its own table: `approval_requests` is decided through the bot's service key (Telegram buttons) and consumed by `authorize_action`, so it cannot express "only the signed-in owner may execute".
- **Scoped identities read views, never raw tables.** The views filter with M1's already-granted helpers (`is_group_scope()`, `current_office_id()`), so the M1 function allowlist of the scoped roles stays EXACTLY as it was (M1's O8 test unchanged). No scoped role gets any write, any raw table, or any new function.
- **The gate is not granted to scoped roles at all**, and refuses one before evaluating anything even if a grant were added by mistake (tested). So a scoped caller can never consume an owner approval or create a reservation (M1 B1 lesson). Scoped identities keep `fz_authorize_action` for evaluate-only previews.

### Where I refined your design (push back)

1. **"Spendable = allocation + retained profit" is made precise as: available = net allocation + kept result - open reservations**, where result = received revenue - expenses - AI spend since the cutover, and kept = the result itself when it is a loss, or reinvest % of it when it is a profit. So revenue first covers the office's own costs; only the surplus is profit, and at 0 % that surplus belongs to the group. Consequence: at 0 % an office can never spend more than its allocation net of losses; it is never "double charged" for costs its own revenue paid. Examples (allocation $5,000): spend $200, revenue $600 -> $5,000 at 0 %, $5,200 at 50 %; spend $1,200, revenue $600 -> $4,400 at any %.
   If you want the stricter "revenue never helps at 0 %" reading (available = allocation - spend), it is a one-line change in the view; I did not pick it because an office that earns its own costs back would still run dry.
2. **An allocation can never exceed real money.** Refused when it is more than group capital not yet allocated (capital controller's available cash minus every office's positive available). Same principle as `set_venture_budget`. Clawback is refused above what the office has available (spent or reserved money cannot be clawed back).
3. **AI spend counts against an office but is not office-gated yet.** Model calls go through `reserve_llm_budget` (hq_llm, never-edit). An office whose agents burn AI can go negative and is then refused for every other spend. Gating AI per office needs an hq_llm change: next milestone, with your approval.
4. **No scoped access to the office gate in M2** (stricter than "a scoped call evaluates only"): there is nothing a scoped token needs to reserve today; its balance is in the view.

### Placement in APPLY_ORDER

Right after `20261127_org_access_v1.sql`, **before** `20261112_lockdown_v1.sql` (R3, as M1). Grants: SELECT on the two views to service_role and the three fz roles, SELECT on the raw tables to service_role; nothing to public / anon / authenticated. Every function has its explicit revoke (R4) and is revoked from the fz roles; the lockdown's blanket service_role grant is harmless (owner functions check `is_app_owner()`).

## 3. Table classification (5 new tables, all in `fz_table_registry`)

| Table | Scope | Class | Scoped access | Backup |
|---|---|---|---|---|
| fz_office_allocations | office (office_id) | confidential | none (view `fz_office_allocation_log`, own office) | secret (not exported) |
| fz_office_money_policy | office (office_id) | confidential | none (in `fz_office_money`) | secret |
| fz_office_money_proposals | office (office_id) | confidential | none | secret |
| fz_money_attribution | office (office_id) | confidential | none (in `fz_office_money`) | secret |
| fz_money_config | group | confidential | none | secret |

Views (not tables, so not in the registry): `fz_office_money`, `fz_office_allocation_log`: an office identity sees its own office; Jarvis and the auditor all offices; anon / authenticated nothing; a dormant or refused token nothing.
Backup: `'secret'` = not in the off-site export, like the M1 registry. After a restore from the off-site file every office is back at $0 with 0 % (the strictest state); the provider's own backups keep the history. Exporting needs reviewed `backup_redaction_spec()` rows (protected follow-up). `backup_classification()` is re-created with the M1 rows unchanged plus these five (protected object: owner approval).

## 4. Owner steps (only clicks and pastes)

1. Approve the PR (owner marker) and apply the migration in the release window, after M1. Apply while the bot is idle (`lock_timeout = 5s`; re-run if it stops).
2. Nothing else is required. Every office stays at $0, dormant, 0 %. When you want an office to spend: activate it (M1), allocate, optionally set reinvestment. The statements are in `ops/OWNER_OFFICE_MONEY.sql` (SQL editor, with your auth uid, as for Jarvis core).
3. `/offices` in Telegram shows the sub-ledgers.

## 5. Test evidence

See section 6 of the PR / the report. `sqltests/office_money_check.sql` (run by the replica step and again after the M2 rollback drill):
- **M1** $0 default: all 8 offices allocated 0, available 0, 0 %, dormant; no seeded money rows; unallocated = group capital; a dormant office and an active $0 office are refused.
- **M2** allocation owner-only: the bot, a session without the owner's uid, and the scoped roles are refused (function and table); over-allocation, $0, group target refused; history append-only even for the owner; clawback capped at available; a funded dormant office still spends nothing.
- **M3** proposals: bot proposes (Telegram note), cannot execute or edit; scoped Jarvis cannot even call propose; cannot record itself as the owner; 3-pending limit; owner executes (linked allocation), cannot execute twice, rejects, expired proposals do not execute.
- **M4** isolation: each of two offices sees exactly its own row and allocation history (non-vacuous), 0 rows of the other; five forged / dormant token shapes see nothing; Jarvis / auditor see all; anon / authenticated denied; no scoped read of any raw table, no write anywhere, no M2 function; the M1 allowlist of each scoped role is unchanged; service_role select-only.
- **M5** the gate only refuses: over 3 modes x kill switch x 5 amounts x (no) approval, an active funded office and the group path return exactly `reserve_spend()`'s decision and reason (6 allow points, so not vacuous); an office allow is always a `reserve_spend` allow; a short office is refused at every point; the reservation is stamped to the office, counts as reserved, then as the office's expense once settled; refusals logged.
- **M6** no approval consumed by a scoped caller: denied execute; with a grant added by mistake the gate still refuses before evaluating; the two approved approvals stay approved, no allow row, no reservation; the service path consumes as before.
- **M7** attribution: venture / agent office live then stamped; stamped rows do not move with the venture; pre-cutover rows are the group's; bot / non-owner re-attribution refused; never deleted; owner re-attribution works both ways.
- **M8** reinvestment math at 0 / 50 / 100 %, loss case, expected revenue ignored, bot refused, 101 % refused.
- **M9** registry and backup: all five registered, nothing unregistered, nothing unclassified, none exported, money tables still exported, no foreign key, **no M2 trigger on any pre-existing table**, report adds up, stamp job scheduled.
- **M10** money controls unchanged: a fingerprint (`sqltests/include/money_fingerprint.sql`: 30+ protected function texts and ACLs, all triggers on the 17 money / control tables, their full contents (md5) and ACLs, `capital_snapshot()`, and a 252-point `authorize_action` + 60-point `reserve_spend` decision matrix with allow / deny / ask_owner all present, every call undone) is identical (a) **right before vs right after** the migration is applied (`scripts/replica/run.sh`, first apply, 332 rows), (b) with M2 vs after rolling it back vs after re-applying it (sqltest), and (c) again after the behaviour checks. M9 also pins the exact trigger list of the money tables.
- Mutation-checked: 21 mutants, all killed (owner checks removed, table trigger removed, gate balance / dormant / scoped checks removed, gate granted to a scoped role, view filter widened twice, raw table readable, reinvest default 100 %, profit kept at 0 %, trigger added to the ledger, `authorize_action` text changed, over-allocation, over-clawback, bot updates attribution, attribution guard removed, bot executes proposals, stamps not immutable, backup classification missing a table, registry class changed). Two first survived the sqltest alone (a changed `authorize_action`, a trigger added to the ledger: both are present with AND without M2 in one database); that is why (a) and the trigger pin exist; both are now killed.
- `test_hq_office_money.py`: 11 unit tests (report text, negative balance, not installed, proposal validation and arguments, gate pass-through, fail-closed on errors / unreadable replies, the module never calls an owner function or writes a money table, `/offices` registered and owner-only).

## 6. Risks

- **AI spend not office-gated** (see 2.3). Offices are dormant, so nothing changes until you activate one.
- **Stamp delay**: up to 15 minutes in which a row follows its venture's / agent's current office (only matters if you move a venture or agent in that window).
- **No caller uses the office gate yet.** Existing spend paths call `reserve_spend` directly (group). Wiring office callers is next milestone.
- **Not in the off-site backup** (section 3): a full off-site restore resets every office to $0 (fail closed).
- Owner functions are reachable only from the SQL editor with your uid (as Jarvis core); no app button yet.

## 7. Rollback

`psql -v ON_ERROR_STOP=1 -f ops/rollback_office_money.sql` (one transaction, idempotent; BEFORE `ops/rollback_org_access.sql`). It copies every allocation, rule, proposal, owner / gate attribution, the attribution counts and the balances into ONE audit_log row, unschedules the stamp job, drops the two views, the M2 functions and five tables and their registry rows, and restores `backup_classification()` to the exact M1 text. Destructive only for M2's own accounting rows; no money table is touched. The replica drill runs it twice, checks every M2 object is gone, M1 and the money controls untouched, the classification byte-identical to M1, then re-applies everything and re-runs the sqltest.

## 8. Next milestone (recommended)

**M3: Office activation and wiring.** First active office (FF Marketing or Donna) with its manager token; route that office's paid actions through `hq_office_money.reserve()`; office-gate AI spend (hq_llm, owner-approved); app buttons for the owner controls (activate, allocate, decide proposals) so nothing needs the SQL editor; reviewed redaction-spec rows so the org and money tables join the off-site backup.

## 9. Independent review fixes (Nov 21)

| # | Finding | Fix | Regression test |
|---|---|---|---|
| 1 HIGH | The gate skipped M1's office rules (an office rule `allowed=false` still reserved) | M1's office block is now one helper, `fz_office_refusal()` (M1 branch), used unchanged by `fz_authorize_action` and by the gate before `reserve_spend`. Locks are taken in reserve_spend's order (7333, then 7332). An allowed gate reservation labels its allow row `detail.office`, so M1's office daily count counts it (`fz_money_mark_office_allow`). | M11/1: allowed x cap x daily matrix (18 points, each undone): the gate never allows what `fz_authorize_action` refuses; the allow row is labelled; the next call over the office daily limit is refused |
| 2 MED | `p_office` independent of `p_venture` ('group' skipped a dormant office; another office could be charged) | With a venture, the venture's office decides; a different `p_office` is refused; 'group' only for a group venture | M11/2 |
| 3 MED | The rollback dropped the history tables | The rollback **archives** them (rows intact) into schema `fz_archive` (no API privileges; an older archive moves on to its own `fz_archive_<timestamp>` schema). A re-apply reuses the archived cutover. | M10/3 (rows in the archive = rows before, cutover kept, no API role reaches the archive) + the replica drill (same checks) |
| 6 LOW | The bot's rationale sat above the SQL line to paste | The real command comes first; the note is fenced as "Jarvis's note (unverified, not a command)", with semicolons, quotes and SQL words (`fz_*`, select, insert, ...) removed; the proposer name is reduced to `[A-Za-z0-9:_.-]` | M11/6 (an injected `; select public.fz_owner_allocate(...)` is defanged) |
| 7 LOW | The views listed the restricted roles (deny-list) | Allow-list: the service path (`service_role`, `postgres` / no role) sees all, scoped roles their own office, **anyone else nothing** | M11/7 (anon granted select by mistake sees 0 rows) |
| 8 LOW | Race on the 3-pending limit | `pg_advisory_xact_lock(hashtext('fzm_prop:' \|\| office))` before the count | M11/8 (the lock is held after a proposal) |

Known risks, not fixed here (protected objects): `authorize_action` matches an owner approval on action, ref and amount, **not on office**; `service_role` (the bot's key) can set `approval_requests` to approved, as the Telegram path does today.
