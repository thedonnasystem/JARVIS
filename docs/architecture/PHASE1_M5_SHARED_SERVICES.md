# FENDEZY GROUP Phase 1, M5: Shared services re-home

Status: built and tested on a scratch replica. Not applied to production. Stacked on M4 (`build/p1-m4-security`).

## 1. What was built

- **`fz_services`**: one registry of the six shared services. Per service it records the owner office (taken from the M1 office registry), the tables it writes and reads, their data classes, how its rows are attributed to an office, the scoped identity its reads may use, and the flag that switches that on.

  | service | owner office | writes | reads | office stamp |
  |---|---|---|---|---|
  | payments | group | payment_instructions | ventures, agents | derived (protected table, not altered) |
  | comms | group | owner_messages, outbox | agents, ventures | column |
  | crm | group | leads, lead_replies, deals | ventures | column |
  | content | group | hand_actions, venture_assets | ventures, departments | column |
  | llm_routing | group | llm_calls, model_prices | agents | derived (protected table, not altered) |
  | scheduler | group | jarvis_jobs | missions, tasks, ventures, agents | column (missions and tasks already carry office_id from M1) |

  The data classes are never typed by hand. A trigger recomputes them from `fz_table_registry` on every write, and it refuses a table the registry does not know. Only the migration (a database session) or the owner can write the registry. The service key and the scoped roles cannot. Rows are never deleted: a service is retired by setting its status.
- **Office attribution.** This is attribution only. No row is refused, and no column other than `office_id` changes.
  - The eight tables that are not on the never-edit list get a nullable `office_id` and a stamp trigger, `zz_fz_service_office`. The trigger fires on insert, and on an update of the columns the office is derived from.
  - Who decides the office, in order: the venture; then the lead (outbox, replies and deals without a venture); then the mission (jobs); then the sending agent (owner messages); then the division (jobs, hand actions); then a scoped caller's own office; then a real office the caller gave; otherwise the group.
  - An update that cannot derive an office leaves it unchanged, so the service key cannot re-label a row.
  - Historical rows are not rewritten. Any UPDATE of old outbox or lead rows would fire the consent and redaction triggers on history.
- **`payment_instructions` and `llm_calls`** are on the never-edit list. They are not altered: no column and no trigger. Their office is derived from the M2 attribution, else the venture or the agent, else the group.
- **`fz_service_rows`** (view): every row of every service table, with its office and how that office was decided (`stamped`, `historical` or `derived`). It uses the same allow-list row filter as M2/M3: database sessions and the service key see every row; a scoped role sees its own office (group scope sees all); anyone else sees nothing. It is not granted to anon, authenticated or the scoped roles.
- **`fz_services_report()`** backs the **`/services`** owner command (`hq_services.py`). For each service it shows the owner office, the tables, the data classes, row counts by attribution and by office, rows left unstamped since stamping began (expected to be 0), and the scoped-read state.
- **`fz_owner_set_service()`** records the owner's decisions: scoped reads on or off, status, owner office, note. It refuses the service key, and every change goes to the audit log.
- **Scoped reads behind a flag (default off).** `hq_services.get(service, path)` reads through the service's scoped identity only when all three of these hold:
  1. the bot runs with `FZ_SERVICES_SCOPED_READS=1`;
  2. the owner switched the service's `scoped_reads` on;
  3. the M1 registry lets a scoped role read the table (`fz_read`, listed as `scoped_read_tables`).

  When all three hold, the read uses that identity's token or is not sent at all (`hq.as_identity(require=True)`). It never falls back to the service key. In every other case the call is byte-for-byte today's service-key read. The scheduler's reads (`hq_missions._get`) now go through it.

## 2. Why this architecture

- **Additive and reversible.** New table, view, functions and nullable columns only. The registry and the stamps can be archived and removed without touching any other row.
- **Never-edit list respected.** The money tables, the kill switch, mode, `authorize_action`, `action_policy`, the consent and suppression guards and the executors are not changed. The money fingerprint is identical before and after M5, after its rollback and after a re-apply. The consent guards on `leads` and `outbox` are untouched. The stamp trigger is named `zz_` so it runs after them, and it only sets `office_id`.
- **Scoped reads only where M1 supports them.** M1 marks only the org tables `fz_read` (agents, departments, ventures, missions, tasks, memory, fz_offices, fz_table_registry). The services' own tables (leads, outbox, owner messages, payments, model calls) are not scoped-readable in M1. Their reads stay on the service key, and `/services` says so for each service. Making them scoped-readable means new M1 RLS policies, which are protected roles/grants/RLS work: it is the next step, not part of this one.
- **Protected modules not edited.** `hq_payments.py`, `hq_llm.py`, `hq_mail.py`, `hq_core.py` and `hq_hands_adapters.py` are unchanged. Their rows are stamped in the database, so no writer had to change. Only `hq_missions.py` (one function body), `hq_commands.py` (the `/services` command and menu line) and the new `hq_services.py` changed.

## 3. Classification

`fz_services` is `internal` in the M1 registry and `secret` in `backup_classification()`, meaning it is not in the off-site export, like the other M1–M4 registries. It is re-seeded by the migration. The new `office_id` columns are uuids, not text, so no redaction spec is needed for them. The tables that carry them keep their existing classes (`leads`, `outbox`, `lead_replies` and `deals` remain client_pii and excluded from the export).

## 4. Test evidence

- `sqltests/shared_services_check.sql` (V1–V8, one transaction, rolled back):
  - V1: money controls identical with M5, after its rollback (run twice) and after a re-apply. The rollback leaves no M5 object behind and keeps one export record, and the owner's decision survives rollback plus re-apply.
  - V2: the six services, the group as owner office, data classes equal to M1, scoped reads off by default, and no column or trigger on any protected money table.
  - V3: stamping by venture, lead, mission, division and agent. A caller-given office is overridden by the venture. A made-up office becomes the group. The stamp changes no other column (compared with a twin row inserted with the trigger off).
  - V4: an unrelated update keeps the office; moving the venture re-derives it; a row with nothing to derive from cannot be re-labelled; a historical row is resolved by the view.
  - V5: an office agent sees only its office in the view and group scope sees all. anon and authenticated are denied, and even with a mistaken grant (and the helpers granted) anon sees no row. A scoped insert carries the caller's office.
  - V6: with RLS bypassed as on Supabase, the service key cannot insert, update or delete the registry or call the owner function, and scoped roles cannot read the report. Delete and truncate are refused. Owner changes are applied and audited. A non-scoped identity and an unknown table are refused.
  - V7: no callable write helper (the N1 lesson): the stamp and the guard are trigger functions, and the report writes nothing.
  - V8: report shape, zero unstamped rows since the start, and scoped-readable tables taken from M1 only.
- `scripts/replica/run.sh`: the M5 rollback drill (see section 6). The money fingerprint is compared around the M5 migration. M5 is rolled back first wherever M4 is rolled back. `expected_grants --check` is re-run after the re-apply: the reviewed allowlist is unchanged, because M5 grants nothing to anon, authenticated or the scoped roles.
- `test_hq_services.py` (8 tests):
  - flag off is identical to the service-key read;
  - flag, switch and table all eligible uses the identity with `require=True`;
  - every other case keeps the service key;
  - a missing token raises and nothing is sent;
  - the scheduler reads go through the service;
  - the report text;
  - `/services` is owner-only and in the menu.
- Mutation tests: 30 mutants (stamp rules, guard, owner function, row filter, report, rollback archive / classification / re-apply, the Python flag, switch, table check, fail-closed and scheduler routing). 29 are killed. The one that survives is equivalent: "view granted to anon/authenticated" is revoked again by the lockdown, and the ACL manifest pins the result.

## 5. Risks

- **The stamp adds one indexed lookup per insert** on the eight tables. The redaction-epoch perf check (50,000 leads and outbox rows) still runs in the gate within its budget.
- **After a rollback and re-apply,** rows stamped before the rollback read as `historical` and are derived again by the same rule. The original stamps stay in `fz_archive.fz_service_attribution`. They are not written back, because that UPDATE would fire the consent and redaction triggers on old rows.
- **`owner_messages` is written only by `jarvis`** (owner contact rule), so today it always resolves to the group. Per-office comms needs a protected change to that rule (owner decision).
- **Scoped reads currently cover only the org tables.** Turning a service's flag on changes nothing for its own tables until M1 policies exist for them.

## 6. Rollback

Run `ops/rollback_shared_services.sql`. It is idempotent and is the first of the Phase 1 rollbacks.
- It writes one audit_log export row.
- It archives every stamped `office_id` (table, row id, office) into `fz_archive.fz_service_attribution`, and the registry table into `fz_archive.fz_services`. The archive has no API privileges, and an older archive moves to `fz_archive_<timestamp>`.
- It then drops the stamp triggers, indexes and columns, the view and the functions.
- It restores `backup_classification()` to the exact M4 text.

A re-apply restores the owner's decisions from the archive. The drill checks that no stamp is lost, the money and consent controls are unchanged, the classification is exact, the owner's decision is kept and the checks pass again.

## 7. Owner actions

- None is needed to keep today's behaviour.
- To try scoped reads for one service: run `select public.fz_owner_set_service('scheduler', true);` in the SQL editor, install the scoped tokens (M1), then set `FZ_SERVICES_SCOPED_READS=1` on the bot. To undo, run `fz_owner_set_service('scheduler', false)` or unset the flag.
- Decide whether shared services stay owned by the group or move to an office: `fz_owner_set_service('<service>', null, null, '<office slug>')`.

## 8. Next milestone (recommended)

- M1 RLS policies that make the service tables scoped-readable per office (protected: roles, grants and RLS need owner approval). After that, move the remaining service reads (`hq_mail`, `hq_payments`, `hq_llm`; these are protected modules, so the owner approves each one) onto `hq_services.get`.
