-- FF Marketing consent integrity, part 1: VERIFIABLE EXPRESS-CONSENT EVIDENCE (Priority 2, Nov 2026). Additive; nothing here sends, enables or authorizes outreach.
--   The problem: ffm_record_consent (20261119) accepted ANY string as evidence_ref, so the bot's service role could mint 'express' valid consent by asserting a form id.
--   The model (full text: DATA_CLASSIFICATION_AND_BACKUP_POLICY.md section 4):
--     * a consent CAPTURE is a registered, immutable record: workspace, opaque capture_ref, channel, the approved wording version AND its sha256, the sha256 of the stored raw
--       artifact (the form submission), the capture time, and a keyed hash binding it to the contact (or, for a hand-attested capture, to one lead id).
--     * captures are written ONLY by two paths the bot cannot use on its own:
--         ffm_ingest_capture        form-ingest: the caller must present a SEAL = HMAC-SHA256 over the capture fields with the capture signing key. The key lives in
--                                   ffm_secrets (no grant to any API role) and in the form endpoint; the bot does not hold it, so it cannot produce a valid seal.
--         ffm_register_capture_owner  owner-only (ffm_require_owner refuses the bot): consent the owner personally attests (paper, phone with a record).
--     * ffm_record_consent (replaced, same signature) records basis 'express' ONLY when evidence_ref names a registered capture that matches the channel, the wording version and
--       the lead's contact (or lead id). Anything else is recorded as basis 'unverified': it is kept for the audit trail and ffm_can_contact ignores it (false).
--       A CHECK constraint makes it impossible to store an 'express' row without a capture_id, whatever function writes it.
--   WHAT THE DATABASE CANNOT KNOW: that the form really showed the wording to a real person who ticked it. That is the owner's job (hold the signing key, keep the raw artifacts,
--   sample-check them). See the policy document, "what a human must still do".
--   Also here: normalize_phone (E.164-like), a dependency-free HMAC-SHA256 (no pgcrypto needed; tested against Python's hmac), and the secrets table.

-- 1. primitives ------------------------------------------------------------------------------------------------------------------------------------------------------
create or replace function public.ffm_hmac_sha256(p_key text, p_msg text) returns text
language plpgsql immutable strict set search_path to 'pg_catalog' as $$
declare k bytea := convert_to(p_key, 'UTF8'); ip bytea; op bytea; i int; b int;
begin
  if length(k) > 64 then k := sha256(k); end if;
  k := k || decode(repeat('00', 64 - length(k)), 'hex');
  ip := k; op := k;
  for i in 0..63 loop
    b := get_byte(k, i);
    ip := set_byte(ip, i, b # 54);    -- 0x36
    op := set_byte(op, i, b # 92);    -- 0x5c
  end loop;
  return encode(sha256(op || sha256(ip || convert_to(p_msg, 'UTF8'))), 'hex');
end $$;

-- ONE phone normaliser for SQL and Python (hq_consent.normalize_phone mirrors it; a test runs one table of inputs through both).
-- Output '+<digits>' or NULL ("not one clean phone number": every caller treats NULL as "do not contact by phone").
--   handled: spaces, dots, dashes, parentheses, +1 / 1 / 001 prefixes, fullwidth digits and plus (NFKC), Arabic-Indic and Persian digits, zero-width and bidi marks,
--            unicode dashes, a trailing extension (x123, ext 4, #5) which is dropped (the main line is what is suppressed).
--   a number with no + sign: 10 digits = North American (+1), 11 digits starting with 1 = North American, 00<cc>... = international. Anything else without a + is NULL (ambiguous).
--   North American numbers must have an area code and exchange that start 2-9. Letters (vanity numbers), several numbers in one field, or 7-digit local numbers give NULL.
create or replace function public.normalize_phone(p text) returns text
language plpgsql immutable set search_path to 'pg_catalog', 'public' as $$
declare t text; d text;
begin
  if p is null then return null; end if;
  t := translate(normalize(regexp_replace(p, '[​-‏⁠﻿‪-‮]', '', 'g'), NFKC),
                 '٠١٢٣٤٥٦٧٨٩۰۱۲۳۴۵۶۷۸۹‐‑‒–—―−', '01234567890123456789-------');
  t := btrim(t);
  t := regexp_replace(t, '\s*(ext\.?|extension|x|#)\s*[0-9]{1,6}$', '', 'i');
  if t = '' or t ~ '[^0-9+()\-.\s]' or position('+' in t) > 1 or length(t) - length(replace(t, '+', '')) > 1 then return null; end if;
  d := regexp_replace(t, '[^0-9]', '', 'g');
  if left(t, 1) = '+' then
    null;
  elsif d ~ '^00' then
    d := substr(d, 3); t := '+';
  elsif d ~ '^[2-9][0-9]{9}$' then
    d := '1' || d; t := '+';
  elsif d ~ '^1[0-9]{10}$' then
    t := '+';
  else
    return null;
  end if;
  if d ~ '^0' or length(d) < 8 or length(d) > 15 then return null; end if;
  if d ~ '^1' and d !~ '^1[2-9][0-9]{2}[2-9][0-9]{6}$' then return null; end if;
  return '+' || d;
end $$;

-- 2. secrets (keys). NO privileges for any API role: only the SECURITY DEFINER functions below read them. Set once, owner-only, never updated or deleted.
create table if not exists public.ffm_secrets (
  name text primary key check (name in ('capture_signing_key', 'suppression_hmac_key')),
  value text not null check (length(value) between 32 and 200),
  set_by text not null,
  set_at timestamptz not null default clock_timestamp()
);
create or replace function public.ffm_append_only() returns trigger
language plpgsql set search_path to 'public' as $$
begin
  raise exception 'This record set is append-only: rows cannot be changed or removed.' using errcode = 'P0001';
end $$;
create table if not exists public.ffm_consent_wordings (
  workspace_id uuid not null references public.client_workspaces(id) on delete restrict,
  version text not null check (version ~ '^[A-Za-z0-9][A-Za-z0-9._:-]{0,59}$'),
  sha256 text not null check (sha256 ~ '^[0-9a-f]{64}$'),
  registered_by text not null,
  registered_at timestamptz not null default clock_timestamp(),
  primary key (workspace_id, version)
);
create table if not exists public.ffm_consent_captures (
  id uuid primary key default gen_random_uuid(),
  workspace_id uuid not null references public.client_workspaces(id) on delete restrict,
  capture_ref text not null check (capture_ref ~ '^[A-Za-z0-9][A-Za-z0-9._:-]{2,99}$'),   -- opaque id of the form submission: never a name, an address or free text (the pattern forbids it)
  channel text not null check (channel in ('email', 'sms', 'phone', 'mail')),
  wording_version text not null check (wording_version ~ '^[A-Za-z0-9][A-Za-z0-9._:-]{0,59}$'),
  wording_sha256 text not null check (wording_sha256 ~ '^[0-9a-f]{64}$'),
  artifact_sha256 text not null check (artifact_sha256 ~ '^[0-9a-f]{64}$'),
  captured_at timestamptz not null,
  contact_mac text check (contact_mac is null or contact_mac ~ '^[0-9a-f]{64}$'),   -- keyed hash of the normalised contact; blanked on erasure
  lead_id uuid,                                                                     -- owner-attested captures may bind to one lead instead (needed for 'mail')
  registered_via text not null check (registered_via in ('form_ingest', 'owner_attested')),
  registered_by text not null check (registered_by ~ '^[A-Za-z0-9][A-Za-z0-9 ._@:-]{0,79}$'),
  created_at timestamptz not null default clock_timestamp(),
  erased_at timestamptz,
  unique (workspace_id, capture_ref),
  check (contact_mac is not null or lead_id is not null or erased_at is not null),
  foreign key (workspace_id, lead_id) references public.ws_leads (workspace_id, id) on delete restrict
);
create index if not exists ffm_captures_lead_idx on public.ffm_consent_captures (lead_id);
do $$ declare t text; begin
  foreach t in array array['ffm_secrets', 'ffm_consent_wordings', 'ffm_consent_captures'] loop
    execute format('alter table public.%I enable row level security', t);
    execute format('revoke all on public.%I from public, anon, authenticated, service_role', t);   -- default privileges on the replica / Supabase grant them; take them back
  end loop;
  grant select on public.ffm_consent_wordings, public.ffm_consent_captures to service_role;       -- readable (no secrets inside); never writable by an API role
end $$;
drop trigger if exists ffm_secrets_append_only on public.ffm_secrets;
create trigger ffm_secrets_append_only before update or delete on public.ffm_secrets for each row execute function public.ffm_append_only();
drop trigger if exists ffm_secrets_no_truncate on public.ffm_secrets;
create trigger ffm_secrets_no_truncate before truncate on public.ffm_secrets for each statement execute function public.ffm_append_only();
drop trigger if exists ffm_wordings_append_only on public.ffm_consent_wordings;
create trigger ffm_wordings_append_only before update or delete on public.ffm_consent_wordings for each row execute function public.ffm_append_only();
drop trigger if exists ffm_wordings_no_truncate on public.ffm_consent_wordings;
create trigger ffm_wordings_no_truncate before truncate on public.ffm_consent_wordings for each statement execute function public.ffm_append_only();

-- captures are immutable except the owner-only erasure path, which may only blank contact_mac and stamp erased_at
create or replace function public.ffm_capture_immutable() returns trigger
language plpgsql set search_path to 'public' as $$
begin
  if tg_op = 'UPDATE' and current_setting('app.ffm_erasure', true) = 'on' and new.contact_mac is null and new.erased_at is not null
     and (to_jsonb(new) - 'contact_mac' - 'erased_at') = (to_jsonb(old) - 'contact_mac' - 'erased_at') then
    return new;
  end if;
  raise exception 'Consent captures are append-only: rows cannot be changed or removed.' using errcode = 'P0001';
end $$;
drop trigger if exists ffm_capture_immutable on public.ffm_consent_captures;
create trigger ffm_capture_immutable before update or delete on public.ffm_consent_captures for each row execute function public.ffm_capture_immutable();
drop trigger if exists ffm_capture_no_truncate on public.ffm_consent_captures;
create trigger ffm_capture_no_truncate before truncate on public.ffm_consent_captures for each statement execute function public.ffm_capture_immutable();

-- 3. the consent log learns 'unverified' and carries its capture ---------------------------------------------------------------------------------------------------
alter table public.ffm_consent_log add column if not exists capture_id uuid references public.ffm_consent_captures (id) on delete restrict;
alter table public.ffm_consent_log add column if not exists verification text check (verification is null or verification ~ '^[a-z_]{2,40}$');
alter table public.ffm_consent_log drop constraint if exists ffm_consent_log_basis_check;
alter table public.ffm_consent_log add constraint ffm_consent_log_basis_check check (basis in ('express', 'implied', 'withdrawn', 'unverified'));
alter table public.ffm_consent_log drop constraint if exists ffm_consent_log_express_needs_capture;
alter table public.ffm_consent_log add constraint ffm_consent_log_express_needs_capture check ((basis <> 'express' or capture_id is not null) and (basis <> 'unverified' or capture_id is null)) not valid;   -- NOT VALID: rows from before this migration are not re-checked, every new row is
create index if not exists ffm_consent_capture_idx on public.ffm_consent_log (capture_id);

-- 4. helpers. NOTE: no function returns a stored key. (The lockdown migration grants execute on EVERY public function to service_role, now and by default privilege, so a function that handed out a key
--    could not be protected by a revoke. Keys are only ever read INSIDE the SECURITY DEFINER functions that use them, and the table has no grant to any API role.) --------------------------------------------------------------------------
-- keyed contact binding: same for the form side (see hq_consent.contact_mac) and the database side
create or replace function public.ffm_contact_mac(p_key text, p_kind text, p_norm text) returns text
language sql immutable strict set search_path to 'public' as $$
  select public.ffm_hmac_sha256(p_key, 'contact|' || p_kind || ':' || p_norm)
$$;

-- 5. owner-only setup: keys and approved wordings ---------------------------------------------------------------------------------------------------------------------
-- Set once. The owner generates the value offline (e.g. python3 -c "import secrets;print(secrets.token_hex(32))"), stores it in a password manager, gives the capture key to the form
-- endpoint only, and runs this call from the SQL editor with the owner session (see ops/OWNER_CONSENT_INTEGRITY.sql). A key cannot be changed afterwards (rotation = new design + owner decision).
create or replace function public.ffm_set_key(p_name text, p_value text, p_by text) returns text
language plpgsql security definer set search_path to 'public' as $$
begin
  perform public.ffm_require_owner();
  if p_name is null or p_name not in ('capture_signing_key', 'suppression_hmac_key') then raise exception 'unknown key name'; end if;
  if p_value is null or length(p_value) < 32 or length(p_value) > 200 or (select count(distinct c) from regexp_split_to_table(p_value, '') c) < 12 then
    raise exception 'key refused: at least 32 characters and not a repeated pattern (use 64 random hex characters)';
  end if;
  if exists (select 1 from public.ffm_secrets where name = p_name) then raise exception 'key refused: % is already set and cannot be replaced', p_name; end if;
  insert into public.ffm_secrets (name, value, set_by) values (p_name, p_value, coalesce(nullif(btrim(p_by), ''), 'owner'));
  insert into public.audit_log (actor, action, target, detail) values ('owner', 'ffm_key_set', 'key/' || p_name, jsonb_build_object('name', p_name));   -- never the value
  return public.ffm_hmac_sha256(p_value, 'fendezy-key-check-v1:' || p_name);
end $$;
-- a fingerprint is HMAC(key, constant): it lets the owner and the form endpoint confirm they hold the same key without revealing it
create or replace function public.ffm_key_fingerprint(p_name text) returns text
language sql stable security definer set search_path to 'public' as $$
  select public.ffm_hmac_sha256(value, 'fendezy-key-check-v1:' || name) from public.ffm_secrets where name = p_name
$$;
create or replace function public.ffm_register_wording(p_ws uuid, p_version text, p_sha256 text, p_by text) returns void
language plpgsql security definer set search_path to 'public' as $$
begin
  perform public.ffm_require_owner();
  perform public.ffm_open_ws(p_ws);
  insert into public.ffm_consent_wordings (workspace_id, version, sha256, registered_by) values (p_ws, p_version, lower(p_sha256), coalesce(nullif(btrim(p_by), ''), 'owner'));
  insert into public.audit_log (actor, action, target, detail) values ('owner', 'ffm_wording_registered', 'workspace/' || p_ws, jsonb_build_object('version', p_version));
end $$;

-- 6. capture registration ---------------------------------------------------------------------------------------------------------------------------------------------
-- canonical text that the form endpoint signs (hq_consent.capture_seal builds the same string)
create or replace function public.ffm_capture_canonical(p_ws uuid, p_ref text, p_channel text, p_wv text, p_wsha text, p_at timestamptz, p_contact text, p_asha text) returns text
language sql immutable set search_path to 'public' as $$
  select 'ffm-capture-v1|' || p_ws::text || '|' || p_ref || '|' || p_channel || '|' || p_wv || '|' || p_wsha || '|' || (extract(epoch from p_at))::bigint::text || '|' || p_contact || '|' || p_asha
$$;

create or replace function public.ffm_ingest_capture(p_ws uuid, p_capture_ref text, p_channel text, p_wording_version text, p_wording_sha256 text, p_captured_at timestamptz,
                                                     p_contact text, p_artifact_sha256 text, p_seal text) returns uuid
language plpgsql security definer set search_path to 'public' as $$
declare k text := (select value from public.ffm_secrets where name = 'capture_signing_key'); kind text; norm text; v_id uuid; ws_sha text;
begin
  perform public.ffm_open_ws(p_ws);
  if k is null then raise exception 'capture refused: the capture signing key has not been set by the owner'; end if;
  if p_channel is null or p_channel not in ('email', 'sms', 'phone') then raise exception 'capture refused: form ingest handles email, sms and phone only (use the owner path for mail)'; end if;
  if p_capture_ref is null or p_wording_version is null or p_wording_sha256 is null or p_captured_at is null or p_contact is null or p_artifact_sha256 is null or p_seal is null
     or position('|' in p_capture_ref || p_wording_version || p_contact) > 0 then raise exception 'capture refused: missing field or a field contains the separator'; end if;
  if p_captured_at > clock_timestamp() + interval '5 minutes' then raise exception 'capture refused: captured_at is in the future'; end if;
  if public.ffm_hmac_sha256(k, public.ffm_capture_canonical(p_ws, p_capture_ref, p_channel, p_wording_version, lower(p_wording_sha256), p_captured_at, p_contact, lower(p_artifact_sha256))) is distinct from lower(p_seal) then
    raise exception 'capture refused: the seal does not match (wrong signing key or altered fields)';
  end if;
  select sha256 into ws_sha from public.ffm_consent_wordings where workspace_id = p_ws and version = p_wording_version;
  if ws_sha is null or ws_sha <> lower(p_wording_sha256) then raise exception 'capture refused: the wording version is not registered for this workspace, or its hash differs'; end if;
  kind := case when p_channel = 'email' then 'email' else 'phone' end;
  norm := case when p_channel = 'email' then public.normalize_addr(p_contact) else public.normalize_phone(p_contact) end;
  if norm is null then raise exception 'capture refused: the contact is not one clean address or phone number'; end if;
  insert into public.ffm_consent_captures (workspace_id, capture_ref, channel, wording_version, wording_sha256, artifact_sha256, captured_at, contact_mac, registered_via, registered_by)
    values (p_ws, p_capture_ref, p_channel, p_wording_version, lower(p_wording_sha256), lower(p_artifact_sha256), p_captured_at, public.ffm_contact_mac(k, kind, norm), 'form_ingest', 'form-ingest')
    returning id into v_id;
  insert into public.audit_log (actor, action, target, detail) values ('ffm', 'ffm_capture_registered', 'workspace/' || p_ws, jsonb_build_object('capture', v_id, 'via', 'form_ingest', 'channel', p_channel));
  return v_id;
end $$;

create or replace function public.ffm_register_capture_owner(p_ws uuid, p_capture_ref text, p_channel text, p_wording_version text, p_artifact_sha256 text, p_captured_at timestamptz,
                                                             p_lead uuid, p_contact text, p_by text) returns uuid
language plpgsql security definer set search_path to 'public' as $$
declare k text := (select value from public.ffm_secrets where name = 'capture_signing_key'); kind text; norm text; mac text; v_id uuid; ws_sha text;
begin
  perform public.ffm_require_owner();
  perform public.ffm_open_ws(p_ws);
  if p_channel is null or p_channel not in ('email', 'sms', 'phone', 'mail') then raise exception 'capture refused: channel must be one of email, sms, phone, mail'; end if;
  if p_captured_at is null or p_captured_at > clock_timestamp() + interval '5 minutes' then raise exception 'capture refused: captured_at is missing or in the future'; end if;
  select sha256 into ws_sha from public.ffm_consent_wordings where workspace_id = p_ws and version = p_wording_version;
  if ws_sha is null then raise exception 'capture refused: the wording version is not registered for this workspace'; end if;
  if p_contact is not null then
    if k is null then raise exception 'capture refused: the capture signing key has not been set by the owner'; end if;
    kind := case when p_channel = 'email' then 'email' when p_channel in ('sms', 'phone') then 'phone' else null end;
    if kind is null then raise exception 'capture refused: a mail capture binds to a lead id, not a contact'; end if;
    norm := case when kind = 'email' then public.normalize_addr(p_contact) else public.normalize_phone(p_contact) end;
    if norm is null then raise exception 'capture refused: the contact is not one clean address or phone number'; end if;
    mac := public.ffm_contact_mac(k, kind, norm);
  end if;
  if mac is null and p_lead is null then raise exception 'capture refused: give the contact or the lead it belongs to'; end if;
  if p_lead is not null and not exists (select 1 from public.ws_leads where id = p_lead and workspace_id = p_ws) then raise exception 'lead not found in this workspace'; end if;
  insert into public.ffm_consent_captures (workspace_id, capture_ref, channel, wording_version, wording_sha256, artifact_sha256, captured_at, contact_mac, lead_id, registered_via, registered_by)
    values (p_ws, p_capture_ref, p_channel, p_wording_version, ws_sha, lower(p_artifact_sha256), p_captured_at, mac, p_lead, 'owner_attested', coalesce(nullif(btrim(p_by), ''), 'owner'))
    returning id into v_id;
  insert into public.audit_log (actor, action, target, detail) values ('owner', 'ffm_capture_registered', 'workspace/' || p_ws, jsonb_build_object('capture', v_id, 'via', 'owner_attested', 'channel', p_channel));
  return v_id;
end $$;

-- 7. ffm_record_consent, replaced (same signature) --------------------------------------------------------------------------------------------------------------------
create or replace function public.ffm_record_consent(p_ws uuid, p_lead uuid, p_channel text, p_basis text, p_wording_version text, p_source text,
                                                      p_captured_at timestamptz, p_evidence_ref text, p_by text) returns uuid
language plpgsql security definer set search_path to 'public' as $$
declare v_id uuid; l public.ws_leads; cap public.ffm_consent_captures; verdict text := 'not_applicable'; v_basis text := p_basis; v_at timestamptz := p_captured_at;
        v_ref text := btrim(p_evidence_ref); k text; kind text; norm text;
begin
  perform public.ffm_open_ws(p_ws);
  if p_basis is null or p_basis not in ('express', 'implied') then raise exception 'consent refused: basis must be express or implied (use ffm_withdraw_consent to withdraw)'; end if;
  if p_channel is null or p_channel not in ('email', 'sms', 'phone', 'mail') then raise exception 'consent refused: channel must be one of email, sms, phone, mail'; end if;
  if p_basis = 'implied' then perform public.ffm_require_owner(); end if;
  if coalesce(btrim(p_wording_version), '') = '' then raise exception 'consent refused: the wording version the person saw is required'; end if;
  if coalesce(btrim(p_source), '') = '' then raise exception 'consent refused: a source is required'; end if;
  if coalesce(length(v_ref), 0) < 3 then raise exception 'consent refused: an evidence reference (form or message id) is required'; end if;
  if p_captured_at is null or p_captured_at > clock_timestamp() + interval '5 minutes' then raise exception 'consent refused: captured_at is missing or in the future'; end if;
  perform pg_advisory_xact_lock(hashtextextended('ffm_consent:' || p_lead::text, 0));
  select * into l from public.ws_leads where id = p_lead and workspace_id = p_ws;
  if l.id is null then raise exception 'lead not found in this workspace'; end if;
  if exists (select 1 from public.ffm_consent_log where lead_id = p_lead and basis = 'withdrawn' and channel in (p_channel, 'all')) then
    raise exception 'consent refused: this lead withdrew consent for this channel; a withdrawal is final in v1 (re-opt-in is an owner decision)';
  end if;
  if p_basis = 'express' then
    select * into cap from public.ffm_consent_captures where workspace_id = p_ws and capture_ref = v_ref;
    if cap.id is null then verdict := 'no_capture';
    elsif cap.erased_at is not null then verdict := 'capture_erased';
    elsif cap.channel <> p_channel then verdict := 'channel_mismatch';
    elsif cap.wording_version <> btrim(p_wording_version) then verdict := 'wording_mismatch';
    elsif cap.lead_id is not null then verdict := case when cap.lead_id = p_lead then 'ok' else 'lead_mismatch' end;
    elsif cap.contact_mac is null then verdict := 'unbound';
    else
      k := (select value from public.ffm_secrets where name = 'capture_signing_key');
      kind := case when p_channel = 'email' then 'email' when p_channel in ('sms', 'phone') then 'phone' else null end;
      norm := case when kind = 'email' then public.normalize_addr(l.email) when kind = 'phone' then public.normalize_phone(l.phone) else null end;
      if k is null then verdict := 'capture_key_missing';
      elsif norm is null then verdict := 'no_contact';
      elsif public.ffm_contact_mac(k, kind, norm) = cap.contact_mac then verdict := 'ok';
      else verdict := 'contact_mismatch'; end if;
    end if;
    if verdict = 'ok' then v_at := cap.captured_at; else v_basis := 'unverified'; end if;
  end if;
  insert into public.ffm_consent_log (workspace_id, lead_id, channel, basis, wording_version, source, captured_at, evidence_ref, recorded_by, capture_id, verification)
    values (p_ws, p_lead, p_channel, v_basis, p_wording_version, p_source, v_at, v_ref, coalesce(nullif(btrim(p_by), ''), 'unknown'),
            case when v_basis = 'express' then cap.id end, verdict) returning id into v_id;
  insert into public.audit_log (actor, action, target, detail) values ('ffm', 'ffm_consent_recorded', 'workspace/' || p_ws,
    jsonb_build_object('lead', p_lead, 'channel', p_channel, 'basis', v_basis, 'asked_basis', p_basis, 'verification', verdict, 'consent', v_id));
  return v_id;
end $$;

-- 8. grants -----------------------------------------------------------------------------------------------------------------------------------------------------------
revoke all on function public.ffm_hmac_sha256(text, text) from public, anon, authenticated;
revoke all on function public.normalize_phone(text) from public, anon, authenticated;
revoke all on function public.ffm_append_only() from public, anon, authenticated;
revoke all on function public.ffm_capture_immutable() from public, anon, authenticated;
revoke all on function public.ffm_contact_mac(text, text, text) from public, anon, authenticated;   -- takes the key as an ARGUMENT (a pure function): it never reads or returns the stored key
revoke all on function public.ffm_set_key(text, text, text) from public, anon, authenticated;
revoke all on function public.ffm_key_fingerprint(text) from public, anon, authenticated;
revoke all on function public.ffm_register_wording(uuid, text, text, text) from public, anon, authenticated;
revoke all on function public.ffm_capture_canonical(uuid, text, text, text, text, timestamptz, text, text) from public, anon, authenticated;
revoke all on function public.ffm_ingest_capture(uuid, text, text, text, text, timestamptz, text, text, text) from public, anon, authenticated;
revoke all on function public.ffm_register_capture_owner(uuid, text, text, text, text, timestamptz, uuid, text, text) from public, anon, authenticated;
revoke all on function public.ffm_record_consent(uuid, uuid, text, text, text, text, timestamptz, text, text) from public, anon, authenticated;
grant execute on function public.ffm_hmac_sha256(text, text) to service_role;
grant execute on function public.ffm_contact_mac(text, text, text) to service_role;
grant execute on function public.normalize_phone(text) to service_role;
grant execute on function public.ffm_append_only() to service_role;
grant execute on function public.ffm_capture_immutable() to service_role;
grant execute on function public.ffm_set_key(text, text, text) to service_role;
grant execute on function public.ffm_key_fingerprint(text) to service_role;
grant execute on function public.ffm_register_wording(uuid, text, text, text) to service_role;
grant execute on function public.ffm_capture_canonical(uuid, text, text, text, text, timestamptz, text, text) to service_role;
grant execute on function public.ffm_ingest_capture(uuid, text, text, text, text, timestamptz, text, text, text) to service_role;
grant execute on function public.ffm_register_capture_owner(uuid, text, text, text, text, timestamptz, uuid, text, text) to service_role;
grant execute on function public.ffm_record_consent(uuid, uuid, text, text, text, text, timestamptz, text, text) to service_role;
