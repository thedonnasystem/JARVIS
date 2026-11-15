-- Rollback for 20261120_leak_source_prevention_v1 AND 20261120_backup_redact_leak_paths_v1 (run with psql from the repo root: it uses \i). Idempotent. Drops nothing that holds data: the deny-list (ffm_redaction_denylist) and its key (ffm_redaction_keys) STAY, and so do the capture triggers on the client tables and the functions they call (redaction_capture*, redaction_h, redaction_pads, backup_fold_text, backup_stopwords): a name erased or deleted while the rollback is in force is still captured, so the list has no gap when the migrations are applied again.
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
drop function if exists public.backup_redact_json_k(jsonb, text, jsonb, integer, text);
drop function if exists public.backup_redact_array(text[], jsonb, integer, text);
drop function if exists public.backup_redact_text(text, jsonb, integer, text);
drop function if exists public.backup_redact_text_full(text, jsonb, integer, text);
drop function if exists public.backup_probe_encoded(text, jsonb, integer);
drop function if exists public.backup_redact_patterns(text, jsonb);
drop function if exists public.backup_redaction_context();
drop function if exists public.backup_unescape_text(text);
drop function if exists public.backup_normalise(text);
drop function if exists public.backup_re_escape(text);
drop function if exists public.backup_windows(text);
drop function if exists public.backup_ctx_build(text[], text[], text[], text[], jsonb);
drop function if exists public.backup_ctx_add(jsonb, jsonb);
drop function if exists public.backup_ctx_hot(jsonb, jsonb);
drop function if exists public.backup_ctx_blob(jsonb, jsonb);
drop function if exists public.backup_topic_hits(text);
drop function if exists public.backup_topic_core(text, text);
drop function if exists public.backup_topic_fast(text, text);
drop function if exists public.backup_detector_pins();
drop function if exists public.backup_deny_query(text);
drop function if exists public.backup_deny_run(text, text);
drop function if exists public.backup_deny_terms(text, jsonb);
drop function if exists public.backup_deny_scan(jsonb, jsonb, text, integer, integer);
drop function if exists public.backup_effective_spec(jsonb);
drop function if exists public.backup_table_expr(text, jsonb);
drop function if exists public.backup_pk_order(text);
drop function if exists public.backup_redaction_meta(jsonb);
drop function if exists public.backup_snapshot_page(text, integer, integer);
drop function if exists public.backup_table_digest(text);
drop function if exists public.backup_snapshot_cost();
commit;
