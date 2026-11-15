-- Rollback for 20261119_ffm_consent_v1 AND 20261119_backup_exclude_client_pii_v1 (run with psql from the repo root: it uses \i). Idempotent.
-- Run only on a scratch DB or with a database-provider backup taken first: dropping ffm_consent_log deletes the consent history (it is append-only by design, so there is no row-level undo).
-- WARNING: after the backup rollback, backup_snapshot() is the OLD function that exports every public table INCLUDING client personal data. Do not set BACKUP_KEY / BACKUP_PUT_URL
-- (off-site backups) while this rollback is in effect. The current hq_backup.py refuses to run without backup_export_policy(), so it fails closed.
-- Afterwards delete both 20261119_* lines from migrations/APPLY_ORDER.txt and rebuild dist/APPLY_ALL.sql, or the next apply recreates them.
begin;
drop function if exists public.ffm_erase_lead(uuid, uuid, text);
drop function if exists public.ffm_can_contact(uuid, text);
drop function if exists public.ffm_contact_status(uuid, text);
drop function if exists public.ffm_withdraw_consent(uuid, uuid, text, text, text, text);
drop function if exists public.ffm_record_consent(uuid, uuid, text, text, text, text, timestamptz, text, text);
drop function if exists public.ffm_set_implied_window(uuid, integer);
drop table if exists public.ffm_consent_log;
drop table if exists public.ffm_consent_settings;
drop function if exists public.ffm_consent_immutable();
drop index if exists public.ws_leads_ws_id_uidx;
drop function if exists public.backup_export_policy();
drop function if exists public.backup_pii_column_exceptions();
drop function if exists public.backup_classification();
commit;
-- restore the previous definitions of the three functions the two migrations replaced (every migration is re-runnable; the replica gate applies each one twice)
\i migrations/20261113_backup_schema_v1.sql
\i migrations/20261117_client_workspaces_v1.sql
\i migrations/20261118_ffm_onboarding_v1.sql
