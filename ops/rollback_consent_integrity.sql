-- Rollback for 20261121_consent_evidence_v1 AND 20261121_suppression_integrity_v1 (run with psql FROM THE REPO ROOT: it uses \i). Idempotent. Scratch-tested by scripts/replica/run.sh.
-- WHAT THIS DOES: drops the evidence tables, the phone suppression list, the keyed-hash tables, the outreach gate and the keys; restores the PREVIOUS definitions of the seven
-- replaced functions (is_suppressed, outbox_dnc_guard, ffm_record_consent, ffm_contact_status, ffm_can_contact, ffm_withdraw_consent, ffm_erase_lead) by re-running the earlier migrations.
-- WARNINGS (read before running anywhere that holds real data):
--   * after this rollback the bot's service role can again record 'express' consent by asserting any string (the old behaviour), and there is NO outreach gate and NO phone suppression.
--     Do not enable any outreach while it is in effect. FF Marketing stays dry-run (CHECK constraints) and the executor stays unregistered, which this file does not touch.
--   * IT DELETES the phone suppression list, the capture registry, the registered wordings, the keyed-hash tables and the stored KEYS. Phone opt-outs are lost unless you take a
--     database-provider backup first (and the owner must keep the suppression key offline; it is the only way to use a backup export of keyed hashes again).
--   * ffm_consent_log is append-only, so rows with basis 'unverified' stay and the widened basis CHECK stays (the old code ignores that basis). The columns capture_id and verification are dropped.
-- Afterwards delete both 20261121_* lines from migrations/APPLY_ORDER.txt and rebuild dist/APPLY_ALL.sql, or the next apply recreates them.
begin;
alter table public.ffm_consent_log drop constraint if exists ffm_consent_log_express_needs_capture;
alter table public.ffm_consent_log drop column if exists capture_id;
alter table public.ffm_consent_log drop column if exists verification;
drop table if exists public.ffm_suppression_expected;
drop table if exists public.ffm_suppression_hashes;
drop table if exists public.ffm_outreach_gate;
drop table if exists public.ffm_phone_suppressions;
drop table if exists public.ffm_consent_captures;
drop table if exists public.ffm_consent_wordings;
drop table if exists public.ffm_secrets;
drop function if exists public.ffm_hmac_sha256(text, text);
drop function if exists public.normalize_phone(text);
drop function if exists public.ffm_append_only();
drop function if exists public.ffm_capture_immutable();
drop function if exists public.ffm_contact_mac(text, text, text);
drop function if exists public.ffm_set_key(text, text, text);
drop function if exists public.ffm_key_fingerprint(text);
drop function if exists public.ffm_register_wording(uuid, text, text, text);
drop function if exists public.ffm_capture_canonical(uuid, text, text, text, text, timestamptz, text, text);
drop function if exists public.ffm_ingest_capture(uuid, text, text, text, text, timestamptz, text, text, text);
drop function if exists public.ffm_register_capture_owner(uuid, text, text, text, text, timestamptz, uuid, text, text);
drop function if exists public.ffm_gate_no_delete();
drop function if exists public.ffm_suppression_mac(text, text);
drop function if exists public.ffm_sup_message(text, text);
drop function if exists public.ffm_lp(text);
drop function if exists public.ffm_cc_len(text);
drop function if exists public.ffm_key_problem(text, text);
drop function if exists public.outreach_send_allowed(uuid);
drop function if exists public.outreach_recipient_problem(text, text, uuid);
drop function if exists public.ffm_is_phone_suppressed(text);
drop function if exists public.ffm_outreach_gate_open();
drop function if exists public.ffm_outreach_gate_status();
drop function if exists public.ffm_close_outreach_gate(text, text);
drop function if exists public.ffm_suppression_set();
drop function if exists public.ffm_suppression_digest();
drop function if exists public.backup_suppression_export();
drop function if exists public.ffm_stage_suppression_checkpoint(jsonb);
drop function if exists public.ffm_import_suppression_hashes();
drop function if exists public.ffm_verify_suppression(text);commit;
-- previous definitions of the replaced functions (every migration is re-runnable; the replica gate applies each one twice)
\i migrations/20261115_venture_deals_replies_v1.sql
\i migrations/20261116_audit_hardening_v1.sql
\i migrations/20261119_ffm_consent_v1.sql
