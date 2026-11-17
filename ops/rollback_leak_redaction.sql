-- Rollback for 20261120_leak_source_prevention_v1 AND 20261120_backup_redact_leak_paths_v1 (run with psql from the repo root: it uses \i). Idempotent. Drops nothing that holds data: the deny-list (ffm_redaction_denylist) and its key (ffm_redaction_keys) STAY, and so do the capture triggers on the client tables and the functions they call (redaction_capture*, redaction_h, redaction_pads, backup_fold_text, backup_stopwords): a name erased or deleted while the rollback is in force is still captured, so the list has no gap when the migrations are applied again.
-- After this: the six writers and backup_snapshot() are the definitions that were in force before (ops/rollback_leak_redaction_writers.sql: those seven definitions only, nothing else of the older migrations is touched). Rows already written stay as they are (codes in audit_log, ids in ledger.note: nothing is "un-redacted").
-- WARNING: with this in force the off-site export again carries client text from audit_log.detail, ledger.note, tasks.result and agent_runs.summary. hq_backup.py REFUSES a snapshot without the
-- redaction block, so the backup stops working (fails closed) until the migrations are applied again. Do not set BACKUP_KEY / BACKUP_PUT_URL while this rollback is in effect.
-- Afterwards delete both 20261120_* lines (backup_redact_leak_paths, leak_source_prevention) from migrations/APPLY_ORDER.txt and rebuild dist/APPLY_ALL.sql, or the next apply recreates them.
begin;
drop trigger if exists agent_runs_scrub on public.agent_runs;
drop function if exists public.agent_runs_scrub();
drop function if exists public.backup_redaction_status();
commit;
-- Round 8 (integration rehearsal S2): ONLY this PR's own objects are restored (five writers, backup_export_policy, backup_snapshot), from one generated file. The older migration files are no longer
-- re-run: they also hold functions that other migrations replace (is_suppressed, outbox_dnc_guard), and re-running them reverted those. This script is therefore safe to run on its own.
\i ops/rollback_leak_redaction_writers.sql
begin;
drop function if exists public.backup_redact_row(text, jsonb, jsonb);
drop function if exists public.backup_redact_slug_array(text[], jsonb);
drop function if exists public.backup_redact_slug(text, jsonb);
drop function if exists public.backup_slug_h(text, text);
drop function if exists public.backup_ordinary_words();
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
drop function if exists public.backup_snapshot_page(text, integer, integer, uuid);
drop function if exists public.backup_table_digest(text);
drop function if exists public.backup_snapshot_cost();
commit;
begin;
drop function if exists public.backup_type_ok(oid);
drop function if exists public.backup_deny_prepare();
drop function if exists public.backup_deny_release(uuid);
drop function if exists public.backup_deny_release();
drop function if exists public.backup_deny_caller();
drop function if exists public.backup_epoch();
drop table if exists public.ffm_redaction_found;
commit;
-- The post-lockdown backup identity (20261121_postlock_backup_identity_v1.sql: role backup_reader, backup_assert_reader(), backup_acl_catalogue(), the revokes) is deliberately NOT rolled back: it only restricts,
-- and a function that still carries the guard (e.g. backup_schema) must keep finding backup_assert_reader(). To hand a function back to service_role, grant it explicitly (an owner decision).
-- Round 7: 20261122_postlock_backup_identity_v2.sql (the allow-list guard and the event trigger ffm_backup_acl_sweep) is kept too. Consequences, on purpose: (1) backup_schema() is NOT handed back to service_role (it keeps the guard
-- and stays revoked), and any backup_* / redaction_* grant that a re-applied older migration issues is revoked again at the end of that GRANT by the event trigger, so the old service-key backup client cannot run after this
-- rollback (hq_backup.py no longer has a service-key path in any case). (2) To hand a function back deliberately, an owner first runs `alter event trigger ffm_backup_acl_sweep disable;`, grants, and re-enables it.
