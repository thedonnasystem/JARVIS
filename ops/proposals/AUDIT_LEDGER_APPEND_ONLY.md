# Proposal: make audit_log and ledger append-only (needs your authorization)

**What:** `ops/proposals/audit_ledger_append_only.sql`. It revokes UPDATE, DELETE and TRUNCATE on `audit_log` and `ledger` from the API roles (service_role, anon, authenticated, the scoped roles, backup_reader) and adds triggers that refuse any update, delete or truncate, even from a database session. INSERT and SELECT stay as they are.

**Why:** production today: service_role, the bot's key, holds INSERT, UPDATE, DELETE and TRUNCATE on **both** tables (checked read-only; anon and authenticated hold nothing). Anyone with that key could rewrite the audit history or the books. The M4 hash chain makes such an edit **evident** (alerted within 15 minutes); this proposal makes it **impossible**. It is not in a migration because both tables are on the never-edit list.

**Correction (Nov 22):** the earlier claim that "no code path deletes audit_log" was wrong. The production cron job `hq-prune` (jobid 2, `0 8 * * 0`) runs `delete from public.audit_log where at < now() - interval '90 days'; delete from public.agent_runs where started_at < now() - interval '90 days'`. Under the lock that job would fail every week, and it deletes history anyway. The proposal now rewrites it, in the same transaction, with `cron.alter_job` so it keeps **only** the `agent_runs` delete. It refuses to apply if the job is not jobid 2 on that schedule, or if any cron job still touches audit_log or ledger. It ends with an `audit_log` row recording your approval.

**Code paths affected:** the cron job above (rewritten). Apart from it, every application writer only inserts:
- `ledger`: `settle_spend` (insert of the expense), `/money` and `/paid` (`hq_commands.py`, REST POST), venture deal confirmation (insert). No code updates or deletes a ledger row; reconciliation and the waterfall only read. The backup drill deletes ledger rows only in its own scratch databases, which are built from migrations, so the proposal is not applied there.
- `audit_log`: about 60 SQL functions and `hq_commands.py`, `hq_mail.py`, `hq_gatemark.py`, `hq_backup.py` (REST POST) insert; `hq_backup.py` and the drills read. No code updates or deletes an audit row; every rollback script only inserts its export row.
- `ws_ledger` (FF Marketing client ledger) is a different table and is not touched.

**Tested:** `psql -v ON_ERROR_STOP=1 -f ops/proposals/test_audit_ledger_append_only.sql` on a scratch replica (rolled back; deliberately not part of the gate). The service key can still insert into both tables and cannot update, delete or truncate either one; the table owner is refused too; `reserve_spend`, `settle_spend`, `authorize_action` and an audited policy change still work; `hq-prune` keeps only the agent_runs delete (and it runs), the old audit_log delete is refused, the approval row is written.

**To apply:** paste the file into the Supabase SQL editor in a release window (it is one transaction). Afterwards `/security` stops listing the standing findings "service_role UPDATE/DELETE/TRUNCATE on audit_log / ledger".

**To undo:** the commented block at the end of the file.
