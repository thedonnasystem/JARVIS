# Proposal: make audit_log and ledger append-only (needs your authorization)

**What:** `ops/proposals/audit_ledger_append_only.sql`. It revokes UPDATE, DELETE and TRUNCATE on `audit_log` and `ledger` from the API roles (service_role, anon, authenticated, the scoped roles, backup_reader) and adds triggers that refuse any update, delete or truncate, even from a database session. INSERT and SELECT stay as they are.

**Why:** production today: service_role, the bot's key, holds INSERT, UPDATE, DELETE and TRUNCATE on **both** tables (checked read-only; anon and authenticated hold nothing). Anyone with that key could rewrite the audit history or the books. The M4 hash chain makes such an edit **evident** (alerted within 15 minutes); this proposal makes it **impossible**. It is not in a migration because both tables are on the never-edit list.

**Code paths affected:** none of the application's. Every writer only inserts:
- `ledger`: `settle_spend` (insert of the expense), `/money` and `/paid` (`hq_commands.py`, REST POST), venture deal confirmation (insert). No code updates or deletes a ledger row; reconciliation and the waterfall only read. The backup drill deletes ledger rows only in its own scratch databases, which are built from migrations, so the proposal is not applied there.
- `audit_log`: about 60 SQL functions and `hq_commands.py`, `hq_mail.py`, `hq_gatemark.py`, `hq_backup.py` (REST POST) insert; `hq_backup.py` and the drills read. No code updates or deletes an audit row; every rollback script only inserts its export row.
- `ws_ledger` (FF Marketing client ledger) is a different table and is not touched.

**Tested:** `psql -v ON_ERROR_STOP=1 -f ops/proposals/test_audit_ledger_append_only.sql` on a scratch replica (rolled back; deliberately not part of the gate). The service key can still insert into both tables and cannot update, delete or truncate either one; the table owner is refused too; `reserve_spend`, `settle_spend`, `authorize_action` and an audited policy change still work.

**To apply:** paste the file into the Supabase SQL editor in a release window (it is one transaction). Afterwards `/security` stops listing the standing findings "service_role UPDATE/DELETE/TRUNCATE on audit_log / ledger".

**To undo:** the commented block at the end of the file.
