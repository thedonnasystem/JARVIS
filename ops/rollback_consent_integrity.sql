-- Rollback for 20261121_consent_evidence_v1 AND 20261121_suppression_integrity_v1 (plain psql; no \i, so it runs from any directory). Idempotent. Scratch-tested by scripts/replica/run.sh.
-- WHAT THIS DOES: drops the evidence tables, the phone suppression list, the keyed-hash tables, the outreach gate and the keys; restores the PREVIOUS definitions of the seven
-- replaced functions (is_suppressed, outbox_dnc_guard, ffm_record_consent, ffm_contact_status, ffm_can_contact, ffm_withdraw_consent, ffm_erase_lead) plus ffm_route_preview, which
-- 20261121_suppression_integrity_v1 also replaces, and NOTHING ELSE. The previous definitions are inlined below verbatim from the earlier migrations (one transaction, no \i).
-- It deliberately does NOT re-run 20261115_venture_deals_replies_v1 / 20261116_audit_hardening_v1 / 20261119_ffm_consent_v1 wholesale: those files also define functions
-- that other PRs replace later (PR #16 leak redaction replaces record_lead_reply, mark_do_not_contact, set_deal_stage and confirm_deal_won so client text stays out of audit_log),
-- and re-running them would silently undo that. Verified by sqltests-style drill: a consent-only rollback on a tree with PR #16 applied leaves every non-consent function
-- byte-identical (definition, ACL, security, search_path) and the leak writers still keep client text out of audit_log.
-- ACLs: CREATE OR REPLACE keeps each function's privileges; the grants of these eight are the same before and after 20261121 (service_role EXECUTE only), checked by the drill.
-- WARNINGS (read before running anywhere that holds real data):
--   * after this rollback the bot's service role can again record 'express' consent by asserting any string (the old behaviour), and there is NO outreach gate and NO phone suppression.
--     Do not enable any outreach while it is in effect. FF Marketing stays dry-run (CHECK constraints) and the executor stays unregistered, which this file does not touch.
--   * IT DELETES the phone suppression list, the capture registry, the registered wordings, the keyed-hash tables and the stored KEYS. Phone opt-outs are lost unless you take a
--     database-provider backup first (and the owner must keep the suppression key offline; it is the only way to use a backup export of keyed hashes again).
--   * ffm_consent_log is append-only, so rows with basis 'unverified' stay and the widened basis CHECK stays (the old code ignores that basis). The columns capture_id and verification are dropped.
--   * app_owners keeps the tightened privileges (service_role SELECT only); restore the old grants by hand only if something really needs them (nothing in this repository does).
-- Afterwards delete both 20261121_* lines from migrations/APPLY_ORDER.txt and rebuild dist/APPLY_ALL.sql, or the next apply recreates them.
begin;
alter table public.ffm_consent_log drop constraint if exists ffm_consent_log_express_needs_capture;
alter table public.ffm_consent_log drop column if exists capture_id;
alter table public.ffm_consent_log drop column if exists verification;
drop trigger if exists ffm_epoch_bump on public.contact_suppressions;
drop trigger if exists ffm_epoch_bump on public.leads;
drop trigger if exists ffm_epoch_bump_ins on public.leads;
drop trigger if exists ffm_epoch_bump on public.ffm_consent_log;
drop table if exists public.ffm_restore_markers;
drop table if exists public.ffm_epoch;
drop table if exists public.ffm_gate_config;
drop table if exists public.ffm_sender_mark;
drop trigger if exists ws_leads_identifier_guard on public.ws_leads;
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
drop function if exists public.ffm_verify_suppression(text);
drop function if exists public.ffm_epoch_guard();
drop function if exists public.ffm_gate_core_ok();
drop function if exists public.outreach_channel_disabled(text);
drop function if exists public.ffm_set_phone_outreach(boolean, text);
drop function if exists public.ffm_owner_record_restore(text);
drop function if exists public.ffm_lead_identifier_guard();
drop function if exists public.ffm_epoch_bump();
drop function if exists public.ffm_instance_fp();
drop function if exists public.ffm_gate_state();
drop function if exists public.ffm_sender_attest(bigint, bigint, text);
drop function if exists public.ffm_set_gate_config(integer, integer, text);
drop function if exists public.outreach_channel_problem(text);
-- previous definitions of the eight replaced functions, VERBATIM from the migrations that last defined them before 20261121 (same signatures, so privileges are kept) ---------
-- is_suppressed: verbatim from migrations/20261115_venture_deals_replies_v1.sql lines 80-83
create or replace function public.is_suppressed(p_address text) returns boolean
language sql stable set search_path to 'public' as $$
  select public.normalize_addr(p_address) is not null and exists (select 1 from public.contact_suppressions where address = public.normalize_addr(p_address))
$$;
-- outbox_dnc_guard: verbatim from migrations/20261116_audit_hardening_v1.sql lines 40-63
create or replace function public.outbox_dnc_guard() returns trigger
language plpgsql set search_path to 'public' as $$
declare dnc boolean := false;
begin
  if new.status not in ('draft','qa_passed','approved','sent') then return new; end if;
  if tg_op = 'UPDATE' and new.status is not distinct from old.status
     and new.to_ref is not distinct from old.to_ref and new.channel is not distinct from old.channel
     and new.lead_id is not distinct from old.lead_id then
    return new;   -- nothing that decides WHO is contacted or WHETHER it advances changed
  end if;
  if new.lead_id is not null then
    select do_not_contact into dnc from public.leads where id = new.lead_id;
  end if;
  if new.channel = 'email' and new.to_ref ~ '[;,]' then
    raise exception 'One recipient per email: a list of addresses is not allowed.' using errcode = 'P0001';
  end if;
  if new.channel = 'email' and new.to_ref is not null and public.normalize_addr(new.to_ref) is null then
    raise exception 'The recipient is not one clean email address (CASL check cannot be done). Fix the address first.' using errcode = 'P0001';
  end if;
  if coalesce(dnc, false) or (new.channel = 'email' and public.is_suppressed(new.to_ref)) then
    raise exception 'Do-not-contact: this lead or address has opted out (CASL). No draft, approval or send is allowed.' using errcode = 'P0001';
  end if;
  return new;
end $$;
-- ffm_record_consent: verbatim from migrations/20261119_ffm_consent_v1.sql lines 123-145
create or replace function public.ffm_record_consent(p_ws uuid, p_lead uuid, p_channel text, p_basis text, p_wording_version text, p_source text,
                                                      p_captured_at timestamptz, p_evidence_ref text, p_by text) returns uuid
language plpgsql security definer set search_path to 'public' as $$
declare v_id uuid;
begin
  perform public.ffm_open_ws(p_ws);
  if p_basis is null or p_basis not in ('express', 'implied') then raise exception 'consent refused: basis must be express or implied (use ffm_withdraw_consent to withdraw)'; end if;
  if p_channel is null or p_channel not in ('email', 'sms', 'phone', 'mail') then raise exception 'consent refused: channel must be one of email, sms, phone, mail'; end if;
  if p_basis = 'implied' then perform public.ffm_require_owner(); end if;
  if coalesce(btrim(p_wording_version), '') = '' then raise exception 'consent refused: the wording version the person saw is required'; end if;
  if coalesce(btrim(p_source), '') = '' then raise exception 'consent refused: a source is required'; end if;
  if coalesce(length(btrim(p_evidence_ref)), 0) < 3 then raise exception 'consent refused: an evidence reference (form or message id) is required'; end if;
  if p_captured_at is null or p_captured_at > clock_timestamp() + interval '5 minutes' then raise exception 'consent refused: captured_at is missing or in the future'; end if;
  perform pg_advisory_xact_lock(hashtextextended('ffm_consent:' || p_lead::text, 0));
  if not exists (select 1 from public.ws_leads where id = p_lead and workspace_id = p_ws) then raise exception 'lead not found in this workspace'; end if;
  if exists (select 1 from public.ffm_consent_log where lead_id = p_lead and basis = 'withdrawn' and channel in (p_channel, 'all')) then
    raise exception 'consent refused: this lead withdrew consent for this channel; a withdrawal is final in v1 (re-opt-in is an owner decision)';
  end if;
  insert into public.ffm_consent_log (workspace_id, lead_id, channel, basis, wording_version, source, captured_at, evidence_ref, recorded_by)
    values (p_ws, p_lead, p_channel, p_basis, p_wording_version, p_source, p_captured_at, p_evidence_ref, coalesce(nullif(btrim(p_by), ''), 'unknown')) returning id into v_id;
  insert into public.audit_log (actor, action, target, detail) values ('ffm', 'ffm_consent_recorded', 'workspace/' || p_ws, jsonb_build_object('lead', p_lead, 'channel', p_channel, 'basis', p_basis, 'consent', v_id));
  return v_id;
end $$;
-- ffm_withdraw_consent: verbatim from migrations/20261119_ffm_consent_v1.sql lines 148-164
create or replace function public.ffm_withdraw_consent(p_ws uuid, p_lead uuid, p_channel text, p_source text, p_evidence_ref text, p_by text) returns uuid
language plpgsql security definer set search_path to 'public' as $$
declare v_id uuid;
begin
  if p_channel is null or p_channel not in ('email', 'sms', 'phone', 'mail', 'all') then raise exception 'withdrawal refused: channel must be one of email, sms, phone, mail, all'; end if;
  perform pg_advisory_xact_lock(hashtextextended('ffm_consent:' || p_lead::text, 0));
  if not exists (select 1 from public.ws_leads where id = p_lead and workspace_id = p_ws) then raise exception 'lead not found in this workspace'; end if;
  insert into public.ffm_consent_log (workspace_id, lead_id, channel, basis, wording_version, source, captured_at, evidence_ref, recorded_by)
    values (p_ws, p_lead, p_channel, 'withdrawn', null, coalesce(nullif(btrim(p_source), ''), 'unspecified'), clock_timestamp(), nullif(btrim(p_evidence_ref), ''), coalesce(nullif(btrim(p_by), ''), 'unknown')) returning id into v_id;
  if p_channel in ('email', 'all') then
    insert into public.contact_suppressions (address, reason, recorded_by, source_lead)
      select public.normalize_addr(email), 'ffm consent withdrawn', coalesce(nullif(btrim(p_by), ''), 'unknown'), null from public.ws_leads where id = p_lead and public.normalize_addr(email) is not null
      on conflict do nothing;   -- a withdrawal follows the ADDRESS, not only the lead id: a re-added duplicate lead is still refused ('suppressed')
  end if;
  insert into public.audit_log (actor, action, target, detail) values ('ffm', 'ffm_consent_withdrawn', 'workspace/' || p_ws, jsonb_build_object('lead', p_lead, 'channel', p_channel, 'consent', v_id));
  return v_id;
end $$;
-- ffm_contact_status: verbatim from migrations/20261119_ffm_consent_v1.sql lines 167-190
create or replace function public.ffm_contact_status(p_lead uuid, p_channel text) returns jsonb
language plpgsql stable security definer set search_path to 'public' as $$
declare l public.ws_leads; wstatus text; e public.ffm_consent_log; i public.ffm_consent_log; win integer;
begin
  if p_channel is null or p_channel not in ('email', 'sms', 'phone', 'mail') then return jsonb_build_object('allowed', false, 'reason', 'invalid_channel'); end if;
  select * into l from public.ws_leads where id = p_lead;
  if l.id is null then return jsonb_build_object('allowed', false, 'reason', 'unknown_lead'); end if;
  select status into wstatus from public.client_workspaces where id = l.workspace_id;
  if wstatus is null or wstatus not in ('draft', 'active') then return jsonb_build_object('allowed', false, 'reason', 'workspace_not_open'); end if;
  if exists (select 1 from public.ffm_consent_log where lead_id = p_lead and basis = 'withdrawn' and channel in (p_channel, 'all')) then
    return jsonb_build_object('allowed', false, 'reason', 'withdrawn');
  end if;
  if p_channel = 'email' and l.email is not null and public.is_suppressed(l.email) then return jsonb_build_object('allowed', false, 'reason', 'suppressed'); end if;
  select * into e from public.ffm_consent_log where lead_id = p_lead and basis = 'express' and channel = p_channel order by captured_at desc, created_at desc limit 1;
  if e.id is not null then return jsonb_build_object('allowed', true, 'reason', 'express', 'consent', e.id, 'captured_at', e.captured_at, 'wording_version', e.wording_version); end if;
  select * into i from public.ffm_consent_log where lead_id = p_lead and basis = 'implied' and channel = p_channel order by captured_at desc, created_at desc limit 1;
  if i.id is not null then
    select implied_window_days into win from public.ffm_consent_settings where workspace_id = l.workspace_id;
    if win is null then return jsonb_build_object('allowed', false, 'reason', 'implied_not_accepted'); end if;
    if i.captured_at + make_interval(days => win) <= clock_timestamp() then return jsonb_build_object('allowed', false, 'reason', 'implied_expired', 'captured_at', i.captured_at); end if;
    return jsonb_build_object('allowed', true, 'reason', 'implied', 'consent', i.id, 'captured_at', i.captured_at, 'expires_at', i.captured_at + make_interval(days => win));
  end if;
  return jsonb_build_object('allowed', false, 'reason', 'no_consent');
end $$;
-- ffm_can_contact: verbatim from migrations/20261119_ffm_consent_v1.sql lines 192-198
create or replace function public.ffm_can_contact(p_lead uuid, p_channel text) returns boolean
language plpgsql stable security definer set search_path to 'public' as $$
begin
  return coalesce((public.ffm_contact_status(p_lead, p_channel) ->> 'allowed')::boolean, false);
exception when others then
  return false;   -- fail closed: any error is a no
end $$;
-- ffm_erase_lead: verbatim from migrations/20261119_ffm_consent_v1.sql lines 201-221
create or replace function public.ffm_erase_lead(p_ws uuid, p_lead uuid, p_reason text) returns jsonb
language plpgsql security definer set search_path to 'public' as $$
declare n_ev integer;
begin
  perform public.ffm_require_owner();
  if p_reason is null or p_reason not in ('erasure_request', 'withdrawal', 'retention_expired', 'other') then raise exception 'erasure refused: reason must be erasure_request, withdrawal, retention_expired or other'; end if;
  perform pg_advisory_xact_lock(hashtextextended('ffm_consent:' || p_lead::text, 0));
  if not exists (select 1 from public.ws_leads where id = p_lead and workspace_id = p_ws) then raise exception 'lead not found in this workspace'; end if;
  insert into public.ffm_consent_log (workspace_id, lead_id, channel, basis, source, captured_at, recorded_by)
    values (p_ws, p_lead, 'all', 'withdrawn', 'erasure:' || p_reason, clock_timestamp(), 'owner');
  insert into public.contact_suppressions (address, reason, recorded_by, source_lead)
    select public.normalize_addr(email), 'ffm erasure/withdrawal', 'owner', null from public.ws_leads where id = p_lead and public.normalize_addr(email) is not null
    on conflict do nothing;   -- the address stays blocked after the lead row is redacted, so re-adding the same person cannot restore contact
  perform set_config('app.ffm_erasure', 'on', true);
  update public.ws_leads set name = '[erased]', email = null, phone = null, source = null, note = null where id = p_lead;
  update public.ffm_consent_log set evidence_ref = null, source = '[erased]', evidence_erased_at = clock_timestamp() where lead_id = p_lead and (evidence_ref is not null or source <> '[erased]');
  get diagnostics n_ev = row_count;
  perform set_config('app.ffm_erasure', 'off', true);
  insert into public.audit_log (actor, action, target, detail) values ('owner', 'ffm_lead_erased', 'workspace/' || p_ws, jsonb_build_object('lead', p_lead, 'reason', p_reason, 'evidence_refs_blanked', n_ev));
  return jsonb_build_object('lead', p_lead, 'evidence_refs_blanked', n_ev, 'note', 'copies in external backups are handled by key rotation or expiry, see DATA_CLASSIFICATION_AND_BACKUP_POLICY.md');
end $$;
-- ffm_route_preview: verbatim from migrations/20261119_ffm_consent_v1.sql lines 224-247
create or replace function public.ffm_route_preview(p_ws uuid, p_lead uuid) returns jsonb
language plpgsql security definer set search_path to 'public' as $$
declare l public.ws_leads; r public.ffm_routing_rules; src jsonb; pay jsonb; out_ jsonb := '[]'::jsonb; f text;
begin
  perform public.ffm_open_ws(p_ws);
  select * into l from public.ws_leads where id = p_lead and workspace_id = p_ws;
  if l.id is null then raise exception 'lead not found in this workspace'; end if;
  -- consent gate (20261119): no current consent on any channel = refused. A dry run still touches personal data, so it needs the same permission.
  if not (public.ffm_can_contact(p_lead, 'email') or public.ffm_can_contact(p_lead, 'sms') or public.ffm_can_contact(p_lead, 'phone') or public.ffm_can_contact(p_lead, 'mail')) then
    raise exception 'routing refused: no current consent on record for this lead';
  end if;
  src := jsonb_build_object('name', l.name, 'email', l.email, 'phone', l.phone, 'source', l.source, 'campaign_id', l.campaign_id, 'stage', l.stage, 'created_at', l.created_at);
  for r in select * from public.ffm_routing_rules where workspace_id = p_ws and status = 'approved' and dry_run order by created_at loop
    pay := '{}'::jsonb;
    foreach f in array r.allowed_fields loop pay := pay || jsonb_build_object(f, src -> f); end loop;
    if cardinality(r.allowed_fields) = 0 then continue; end if;
    if array_length(public.ws_sensitive_hits((select string_agg(value #>> '{}', ' ') from jsonb_each(pay) where key not in ('campaign_id', 'created_at'))), 1) > 0 then
      raise exception 'routing refused: payload for rule % looks sensitive', r.name;
    end if;
    insert into public.ffm_route_log (workspace_id, rule_id, lead_id, fields) values (p_ws, r.id, p_lead, r.allowed_fields);
    out_ := out_ || jsonb_build_array(jsonb_build_object('rule', r.name, 'destination_kind', r.destination_kind, 'dry_run', true, 'payload', pay));
  end loop;
  return out_;
end $$;
commit;
