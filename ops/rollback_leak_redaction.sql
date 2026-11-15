-- Rollback for 20261120_leak_source_prevention_v1 AND 20261120_backup_redact_leak_paths_v1 (run with psql from the repo root: it uses \i). Idempotent. Drops nothing that holds data.
-- After this: the six writers and backup_snapshot() are the definitions that were in force before (the 20261112 / 20261115 / 20261116 / 20261119 migrations, re-applied in their original order;
-- every migration is re-runnable, the replica gate applies each one twice). Rows already written stay as they are (codes in audit_log, ids in ledger.note: nothing is "un-redacted").
-- WARNING: with this in force the off-site export again carries client text from audit_log.detail, ledger.note, tasks.result and agent_runs.summary. hq_backup.py REFUSES a snapshot without the
-- redaction block, so the backup stops working (fails closed) until the migrations are applied again. Do not set BACKUP_KEY / BACKUP_PUT_URL while this rollback is in effect.
-- Afterwards delete both 20261120_* lines (backup_redact_leak_paths, leak_source_prevention) from migrations/APPLY_ORDER.txt and rebuild dist/APPLY_ALL.sql, or the next apply recreates them.
begin;
drop trigger if exists agent_runs_scrub on public.agent_runs;
drop function if exists public.agent_runs_scrub();
drop function if exists public.backup_redaction_status();
commit;
\i migrations/20261112_setters_v1.sql
\i migrations/20261115_venture_deals_replies_v1.sql
\i migrations/20261116_audit_hardening_v1.sql
\i migrations/20261119_backup_exclude_client_pii_v1.sql
begin;
drop function if exists public.backup_redact_row(text, jsonb, jsonb);
drop function if exists public.backup_redaction_spec();
drop function if exists public.backup_redact_json(jsonb, jsonb, integer, text);
drop function if exists public.backup_redact_text(text, jsonb, integer, text);
drop function if exists public.backup_probe_encoded(text, jsonb, integer);
drop function if exists public.backup_redact_patterns(text, jsonb);
drop function if exists public.backup_redaction_context();
drop function if exists public.backup_unescape_text(text);
drop function if exists public.backup_fold_text(text);
commit;
