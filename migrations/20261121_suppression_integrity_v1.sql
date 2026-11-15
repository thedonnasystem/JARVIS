-- FF Marketing consent integrity, part 2: SUPPRESSION INTEGRITY, SURVIVAL ACROSS RESTORE, AND THE OUTREACH GATE (Priority 2, Nov 2026).
-- Additive except for the replaced functions listed below. Nothing here sends, enables or authorizes outreach: every change can only make a "no" more likely.
--   (b) PHONE SUPPRESSION: ffm_phone_suppressions (append-only, normalised with normalize_phone) is the phone twin of contact_suppressions. A withdrawal on sms, phone or all
--       and an erasure add the lead's phone. ffm_can_contact for sms and phone refuses a suppressed number, and refuses a lead whose address/number is missing or unusable.
--       A re-imported or duplicate lead with the same number (any format) therefore stays refused.
--   (c) SURVIVAL: contact_suppressions is client PII and must stay out of the plain off-site file. What may travel is a KEYED hash: HMAC-SHA256(suppression key, kind:normalised value).
--       The key (ffm_secrets.suppression_hmac_key) is separate from BACKUP_KEY, set once by the owner, kept offline by the owner, and never in the backup. backup_suppression_export()
--       returns only keyed hashes + a count + a digest + a key fingerprint: without the key a hash cannot be reversed or tested against a guessed address.
--       After a restore the owner re-supplies the key, stages the exported list as the EXPECTED CHECKPOINT and may import it as hash-only suppressions that is_suppressed /
--       ffm_can_contact honour (a re-contact of a suppressed address is refused even though no plaintext list exists).
--   (d) OUTREACH GATE: ffm_outreach_gate is DEFAULT-DENY (a fresh database, a restored one, a missing row, a missing key, or a shrunken list all give "closed").
--       Only the owner-only ffm_verify_suppression can open it, and only when every expected checkpoint entry is present in the live list. ffm_can_contact returns false while closed,
--       and outbox_dnc_guard refuses to approve or send a drafted message while closed. Closing the gate (ffm_close_outreach_gate) is allowed to anyone: it only reduces what is allowed.
--   Replaced functions (same signatures): is_suppressed, outbox_dnc_guard, ffm_contact_status, ffm_can_contact, ffm_withdraw_consent, ffm_erase_lead.
--   The tables are named ffm_* ON PURPOSE: backup_export_policy() denies ffm_* by NAME PATTERN, so these tables stay out of the off-site file even if a later migration replaces
--   backup_classification() without them. (contact_suppressions itself stays client_pii in that list.)

-- 1. phone suppression (append-only, like the email list) ---------------------------------------------------------------------------------------------------------------
create table if not exists public.ffm_phone_suppressions (
  phone text primary key check (coalesce(phone = public.normalize_phone(phone), false)),
  reason text not null,
  recorded_by text not null,
  source_lead uuid,
  recorded_at timestamptz not null default now()
);
-- 2. keyed-hash suppressions (what a restore re-establishes) and the staged checkpoint -----------------------------------------------------------------------------------
create table if not exists public.ffm_suppression_hashes (
  kind text not null check (kind in ('email', 'phone')),
  mac text not null check (mac ~ '^[0-9a-f]{64}$'),
  source text not null check (source in ('restore_import')),
  imported_at timestamptz not null default clock_timestamp(),
  primary key (kind, mac)
);
create table if not exists public.ffm_suppression_expected (
  kind text not null check (kind in ('email', 'phone')),
  mac text not null check (mac ~ '^[0-9a-f]{64}$'),
  primary key (kind, mac)
);
-- 3. the gate: ONE row. A missing row, or any state other than 'verified', is CLOSED. ----------------------------------------------------------------------------------
create table if not exists public.ffm_outreach_gate (
  id integer primary key check (id = 1),
  state text not null check (state in ('unverified', 'verified')),
  reason text not null,
  expected_count integer,
  expected_hash text,
  expected_key_check text,
  expected_staged_at timestamptz,
  verified_raw_count integer,
  verified_at timestamptz,
  verified_by text,
  updated_at timestamptz not null default clock_timestamp()
);
insert into public.ffm_outreach_gate (id, state, reason) values (1, 'unverified', 'fresh database: the suppression list has not been verified') on conflict (id) do nothing;

do $$ declare t text; begin
  foreach t in array array['ffm_phone_suppressions', 'ffm_suppression_hashes', 'ffm_suppression_expected', 'ffm_outreach_gate'] loop
    execute format('alter table public.%I enable row level security', t);
    execute format('revoke all on public.%I from public, anon, authenticated, service_role', t);
  end loop;
  grant select on public.ffm_phone_suppressions, public.ffm_outreach_gate to service_role;   -- the bot may READ the list and the gate state; every write goes through a definer function
end $$;
drop trigger if exists ffm_phone_supp_append_only on public.ffm_phone_suppressions;
create trigger ffm_phone_supp_append_only before update or delete on public.ffm_phone_suppressions for each row execute function public.ffm_append_only();
drop trigger if exists ffm_phone_supp_no_truncate on public.ffm_phone_suppressions;
create trigger ffm_phone_supp_no_truncate before truncate on public.ffm_phone_suppressions for each statement execute function public.ffm_append_only();
drop trigger if exists ffm_hashes_append_only on public.ffm_suppression_hashes;
create trigger ffm_hashes_append_only before update or delete on public.ffm_suppression_hashes for each row execute function public.ffm_append_only();
drop trigger if exists ffm_hashes_no_truncate on public.ffm_suppression_hashes;
create trigger ffm_hashes_no_truncate before truncate on public.ffm_suppression_hashes for each statement execute function public.ffm_append_only();
-- the gate row can be updated only through the functions below; it can never be deleted
create or replace function public.ffm_gate_no_delete() returns trigger
language plpgsql set search_path to 'public' as $$
begin
  raise exception 'The outreach gate row cannot be deleted or truncated.' using errcode = 'P0001';
end $$;
drop trigger if exists ffm_gate_no_delete on public.ffm_outreach_gate;
create trigger ffm_gate_no_delete before delete on public.ffm_outreach_gate for each row execute function public.ffm_gate_no_delete();
drop trigger if exists ffm_gate_no_truncate on public.ffm_outreach_gate;
create trigger ffm_gate_no_truncate before truncate on public.ffm_outreach_gate for each statement execute function public.ffm_gate_no_delete();

-- 4. the suppression lookups -----------------------------------------------------------------------------------------------------------------------------------------
-- The keyed hash of a normalised value is HMAC-SHA256(suppression key, 'sup|v1|' || lp(kind) || lp(norm)): domain-separated and length-prefixed, so it can never equal a capture seal.
-- Review finding 1: the previous public.ffm_suppression_mac(kind, norm), executable by service_role, was an HMAC ORACLE on the suppression key (kind was free text). It no longer exists:
-- the hash is computed INLINE inside the SECURITY DEFINER functions that need it (is_suppressed, ffm_is_phone_suppressed, ffm_suppression_set), so there is nothing for a role to call.
-- (A revoke on a public function would not hold: the lockdown migration, applied last and re-runnable, grants execute on EVERY public function to service_role. A separate schema would not
-- survive a restore, which rebuilds schema public only.) The message builder below is a pure function with no key and may stay callable.
drop function if exists public.ffm_suppression_mac(text, text);
create or replace function public.ffm_sup_message(p_kind text, p_norm text) returns text
language sql immutable strict set search_path to 'public' as $$ select 'sup|v1|' || public.ffm_lp(p_kind) || public.ffm_lp(p_norm) $$;

-- email: plaintext list first, then hash-only entries (needs the key). Same name/signature as before; callers (outbox_dnc_guard, deals, ffm_contact_status) are unchanged.
create or replace function public.is_suppressed(p_address text) returns boolean
language plpgsql stable security definer set search_path to 'public' as $$
declare n text := public.normalize_addr(p_address);
begin
  if p_address is null then return false; end if;
  if n is null then return true; end if;     -- not one clean address: cannot be shown to be NOT suppressed, so it counts as suppressed (fail closed)
  if exists (select 1 from public.contact_suppressions where address = n) then return true; end if;
  if exists (select 1 from public.ffm_suppression_hashes where kind = 'email') then
    return exists (select 1 from public.ffm_suppression_hashes where kind = 'email' and mac = public.ffm_hmac_sha256((select value from public.ffm_secrets where name = 'suppression_hmac_key'), public.ffm_sup_message('email', n)));
  end if;
  return false;
end $$;
create or replace function public.ffm_is_phone_suppressed(p_phone text) returns boolean
language plpgsql stable security definer set search_path to 'public' as $$
declare n text := public.normalize_phone(p_phone);
begin
  if p_phone is null then return false; end if;
  if n is null then return true; end if;     -- not one clean number (including an ambiguous trunk-prefix form): fail closed, never 'not suppressed'
  if exists (select 1 from public.ffm_phone_suppressions where phone = n) then return true; end if;
  if exists (select 1 from public.ffm_suppression_hashes where kind = 'phone') then
    return exists (select 1 from public.ffm_suppression_hashes where kind = 'phone' and mac = public.ffm_hmac_sha256((select value from public.ffm_secrets where name = 'suppression_hmac_key'), public.ffm_sup_message('phone', n)));
  end if;
  return false;
end $$;

-- 5. the gate ---------------------------------------------------------------------------------------------------------------------------------------------------------
-- Open only when: the gate row says verified, the suppression key exists, and the list has not SHRUNK since verification (the three lists are append-only, so a lower row
-- count means something removed rows underneath the triggers). Any error is "closed".
create or replace function public.ffm_outreach_gate_open() returns boolean
language plpgsql stable security definer set search_path to 'public' as $$
declare g public.ffm_outreach_gate; raw integer;
begin
  select * into g from public.ffm_outreach_gate where id = 1;
  if g.id is null or g.state <> 'verified' or g.verified_raw_count is null then return false; end if;
  if not exists (select 1 from public.ffm_secrets where name = 'suppression_hmac_key') then return false; end if;
  raw := (select count(*) from public.contact_suppressions) + (select count(*) from public.ffm_phone_suppressions) + (select count(*) from public.ffm_suppression_hashes);
  return raw >= g.verified_raw_count;
exception when others then
  return false;
end $$;
create or replace function public.ffm_outreach_gate_status() returns jsonb
language plpgsql stable security definer set search_path to 'public' as $$
declare g public.ffm_outreach_gate;
begin
  select * into g from public.ffm_outreach_gate where id = 1;
  return jsonb_build_object('open', public.ffm_outreach_gate_open(), 'state', coalesce(g.state, 'missing'), 'reason', coalesce(g.reason, 'gate row missing'),
    'key_set', exists (select 1 from public.ffm_secrets where name = 'suppression_hmac_key'), 'checkpoint_staged', g.expected_hash is not null,
    'expected_count', g.expected_count, 'verified_at', g.verified_at, 'verified_raw_count', g.verified_raw_count,
    'raw_count_now', (select count(*) from public.contact_suppressions) + (select count(*) from public.ffm_phone_suppressions) + (select count(*) from public.ffm_suppression_hashes));
end $$;
-- anyone may CLOSE the gate (a restore tool, the bot on suspicion): it can only reduce what is allowed. Only ffm_verify_suppression opens it.
create or replace function public.ffm_close_outreach_gate(p_reason text, p_by text) returns void
language plpgsql security definer set search_path to 'public' as $$
begin
  insert into public.ffm_outreach_gate (id, state, reason) values (1, 'unverified', left(coalesce(nullif(btrim(p_reason), ''), 'closed'), 300))
    on conflict (id) do update set state = 'unverified', reason = left(coalesce(nullif(btrim(p_reason), ''), 'closed'), 300), verified_raw_count = null, verified_at = null, verified_by = null, updated_at = clock_timestamp();
  insert into public.audit_log (actor, action, target, detail) values (coalesce(nullif(btrim(p_by), ''), 'unknown'), 'ffm_outreach_gate_closed', 'gate/1', jsonb_build_object('reason', left(coalesce(p_reason, ''), 300)));
end $$;

-- 6. the digest of "what is suppressed", as keyed hashes ---------------------------------------------------------------------------------------------------------------
-- set = plaintext email list + plaintext phone list + imported hashes, each reduced to (kind, mac), de-duplicated.
create or replace function public.ffm_suppression_set() returns table (kind text, mac text)
language plpgsql stable security definer set search_path to 'public' as $$
declare k text := (select value from public.ffm_secrets where name = 'suppression_hmac_key');
begin
  if k is null then raise exception 'the suppression key has not been set by the owner'; end if;
  return query
    select s.kind, s.mac from (
      select 'email'::text as kind, public.ffm_hmac_sha256(k, public.ffm_sup_message('email', c.address)) as mac from public.contact_suppressions c
      union select 'phone'::text, public.ffm_hmac_sha256(k, public.ffm_sup_message('phone', p.phone)) from public.ffm_phone_suppressions p
      union select h.kind, h.mac from public.ffm_suppression_hashes h) s;
end $$;
create or replace function public.ffm_suppression_digest() returns jsonb
language plpgsql stable security definer set search_path to 'public' as $$
declare cnt int; ec int; pc int; h text;
begin
  select count(*), count(*) filter (where kind = 'email'), count(*) filter (where kind = 'phone') into cnt, ec, pc from public.ffm_suppression_set();
  select encode(sha256(convert_to(coalesce(string_agg(kind || ':' || mac, E'\n' order by (kind || ':' || mac) collate "C"), ''), 'UTF8')), 'hex') into h from public.ffm_suppression_set();
  return jsonb_build_object('count', cnt, 'email_count', ec, 'phone_count', pc, 'hash', h, 'key_check', public.ffm_key_fingerprint('suppression_hmac_key'));
end $$;

-- 7. the backup export: keyed hashes only, safe for the encrypted off-site file ------------------------------------------------------------------------------------------
create or replace function public.backup_suppression_export() returns jsonb
language plpgsql stable security definer set search_path to 'public' as $$
declare d jsonb; macs jsonb;
begin
  if not exists (select 1 from public.ffm_secrets where name = 'suppression_hmac_key') then
    return jsonb_build_object('version', 1, 'included', false, 'reason', 'the owner has not set the suppression key, so no keyed hashes can be exported');
  end if;
  d := public.ffm_suppression_digest();
  select coalesce(jsonb_agg(jsonb_build_array(kind, mac) order by kind collate "C", mac collate "C"), '[]'::jsonb) into macs from public.ffm_suppression_set();
  return jsonb_build_object('version', 1, 'included', true, 'key_check', d ->> 'key_check', 'count', (d ->> 'count')::int, 'email_count', (d ->> 'email_count')::int,
                            'phone_count', (d ->> 'phone_count')::int, 'hash', d ->> 'hash', 'macs', macs);
end $$;

-- 8. owner-only: stage the checkpoint, optionally import it, verify ----------------------------------------------------------------------------------------------------
-- p_export = the "suppression" section of a backup (what backup_suppression_export() returned). The checks here are about the export itself; ffm_verify_suppression checks it against the live list.
create or replace function public.ffm_stage_suppression_checkpoint(p_export jsonb) returns jsonb
language plpgsql security definer set search_path to 'public' as $$
declare e jsonb; n int := 0; seen text[] := '{}'; kind text; mac text; lines text; calc text; fp text;
begin
  perform public.ffm_require_owner();
  fp := public.ffm_key_fingerprint('suppression_hmac_key');
  if fp is null then raise exception 'checkpoint refused: set the suppression key first (ffm_set_key)'; end if;
  if p_export is null or coalesce((p_export ->> 'version')::int, 0) <> 1 or coalesce((p_export ->> 'included')::boolean, false) is not true or jsonb_typeof(p_export -> 'macs') <> 'array' then
    raise exception 'checkpoint refused: not a suppression export (version 1, included, with a macs list)';
  end if;
  if p_export ->> 'key_check' is distinct from fp then raise exception 'checkpoint refused: the export was made with a different suppression key'; end if;
  for e in select * from jsonb_array_elements(p_export -> 'macs') loop
    if jsonb_typeof(e) <> 'array' or jsonb_array_length(e) <> 2 then raise exception 'checkpoint refused: malformed entry'; end if;
    kind := e ->> 0; mac := e ->> 1;
    if kind is null or kind not in ('email', 'phone') or mac is null or mac !~ '^[0-9a-f]{64}$' then raise exception 'checkpoint refused: malformed entry'; end if;
    if (kind || ':' || mac) = any (seen) then raise exception 'checkpoint refused: duplicate entry'; end if;
    seen := seen || (kind || ':' || mac);
    n := n + 1;
  end loop;
  select string_agg(x, E'\n' order by x collate "C") into lines from unnest(seen) x;
  calc := encode(sha256(convert_to(coalesce(lines, ''), 'UTF8')), 'hex');
  if n <> (p_export ->> 'count')::int or calc <> p_export ->> 'hash' then raise exception 'checkpoint refused: the list does not match its own count/hash (altered or partial)'; end if;
  delete from public.ffm_suppression_expected;
  insert into public.ffm_suppression_expected (kind, mac) select split_part(x, ':', 1), split_part(x, ':', 2) from unnest(seen) x;
  insert into public.ffm_outreach_gate (id, state, reason, expected_count, expected_hash, expected_key_check, expected_staged_at)
    values (1, 'unverified', 'checkpoint staged: run ffm_verify_suppression', n, calc, fp, clock_timestamp())
    on conflict (id) do update set state = 'unverified', reason = 'checkpoint staged: run ffm_verify_suppression', expected_count = n, expected_hash = calc, expected_key_check = fp,
      expected_staged_at = clock_timestamp(), verified_raw_count = null, verified_at = null, verified_by = null, updated_at = clock_timestamp();
  insert into public.audit_log (actor, action, target, detail) values ('owner', 'ffm_suppression_checkpoint_staged', 'gate/1', jsonb_build_object('count', n));
  return jsonb_build_object('staged', n);
end $$;
-- restore path for a database that has no plaintext suppression list: make the staged hashes effective (is_suppressed / ffm_can_contact honour them)
create or replace function public.ffm_import_suppression_hashes() returns integer
language plpgsql security definer set search_path to 'public' as $$
declare n int;
begin
  perform public.ffm_require_owner();
  if not exists (select 1 from public.ffm_outreach_gate where id = 1 and expected_hash is not null) then raise exception 'import refused: no checkpoint is staged'; end if;
  insert into public.ffm_suppression_hashes (kind, mac, source) select kind, mac, 'restore_import' from public.ffm_suppression_expected on conflict do nothing;
  get diagnostics n = row_count;
  insert into public.audit_log (actor, action, target, detail) values ('owner', 'ffm_suppression_hashes_imported', 'gate/1', jsonb_build_object('imported', n));
  return n;
end $$;
create or replace function public.ffm_verify_suppression(p_by text) returns jsonb
language plpgsql security definer set search_path to 'public' as $$
declare g public.ffm_outreach_gate; fp text; have int; exp_n int; exp_h text; missing int; cur int; raw int; why text; mode text;
begin
  perform public.ffm_require_owner();
  select * into g from public.ffm_outreach_gate where id = 1;
  fp := public.ffm_key_fingerprint('suppression_hmac_key');
  if g.id is null or g.expected_hash is null then why := 'no checkpoint is staged (ffm_stage_suppression_checkpoint)';
  elsif fp is null then why := 'the suppression key is not set';
  elsif g.expected_key_check is distinct from fp then why := 'the suppression key differs from the one that made the checkpoint';
  else
    select count(*), encode(sha256(convert_to(coalesce(string_agg(kind || ':' || mac, E'\n' order by (kind || ':' || mac) collate "C"), ''), 'UTF8')), 'hex') into exp_n, exp_h from public.ffm_suppression_expected;
    if exp_n <> g.expected_count or exp_h <> g.expected_hash then why := 'the staged checkpoint was altered after staging';
    else
      create temporary table if not exists pg_temp.ffm_live_set (kind text, mac text) on commit drop;
      truncate pg_temp.ffm_live_set;
      insert into pg_temp.ffm_live_set select * from public.ffm_suppression_set();   -- one pass of keyed hashing, not one per expected entry
      select count(*) into missing from public.ffm_suppression_expected e where not exists (select 1 from pg_temp.ffm_live_set s where s.kind = e.kind and s.mac = e.mac);
      select count(*) into cur from pg_temp.ffm_live_set;
      if missing > 0 then why := 'incomplete: ' || missing || ' of ' || exp_n || ' expected suppression entries are not in the live list';
      else mode := case when cur = exp_n then 'exact' else 'superset' end; end if;
    end if;
  end if;
  if why is not null then
    perform public.ffm_close_outreach_gate('verification failed: ' || why, p_by);
    return jsonb_build_object('verified', false, 'reason', why);
  end if;
  raw := (select count(*) from public.contact_suppressions) + (select count(*) from public.ffm_phone_suppressions) + (select count(*) from public.ffm_suppression_hashes);
  update public.ffm_outreach_gate set state = 'verified', reason = 'verified against checkpoint (' || mode || ')', verified_raw_count = raw, verified_at = clock_timestamp(),
         verified_by = coalesce(nullif(btrim(p_by), ''), 'owner'), updated_at = clock_timestamp() where id = 1;
  insert into public.audit_log (actor, action, target, detail) values ('owner', 'ffm_suppression_verified', 'gate/1', jsonb_build_object('mode', mode, 'expected', exp_n, 'current', cur));
  return jsonb_build_object('verified', true, 'mode', mode, 'expected', exp_n, 'current', cur);
end $$;

-- 9. the decision, replaced: gate first, then withdrawal, then address/number suppression, then consent ---------------------------------------------------------------------
create or replace function public.ffm_contact_status(p_lead uuid, p_channel text) returns jsonb
language plpgsql stable security definer set search_path to 'public' as $$
declare l public.ws_leads; wstatus text; e public.ffm_consent_log; i public.ffm_consent_log; win integer;
begin
  if p_channel is null or p_channel not in ('email', 'sms', 'phone', 'mail') then return jsonb_build_object('allowed', false, 'reason', 'invalid_channel'); end if;
  if not public.ffm_outreach_gate_open() then return jsonb_build_object('allowed', false, 'reason', 'suppression_unverified'); end if;
  select * into l from public.ws_leads where id = p_lead;
  if l.id is null then return jsonb_build_object('allowed', false, 'reason', 'unknown_lead'); end if;
  select status into wstatus from public.client_workspaces where id = l.workspace_id;
  if wstatus is null or wstatus not in ('draft', 'active') then return jsonb_build_object('allowed', false, 'reason', 'workspace_not_open'); end if;
  if exists (select 1 from public.ffm_consent_log where lead_id = p_lead and basis = 'withdrawn' and channel in (p_channel, 'all')) then
    return jsonb_build_object('allowed', false, 'reason', 'withdrawn');
  end if;
  if p_channel = 'email' then
    if l.email is null then return jsonb_build_object('allowed', false, 'reason', 'no_address'); end if;
    if public.normalize_addr(l.email) is null then return jsonb_build_object('allowed', false, 'reason', 'address_unusable'); end if;
    if public.is_suppressed(l.email) then return jsonb_build_object('allowed', false, 'reason', 'suppressed'); end if;
  elsif p_channel in ('sms', 'phone') then
    if l.phone is null then return jsonb_build_object('allowed', false, 'reason', 'no_phone'); end if;
    if public.normalize_phone(l.phone) is null then return jsonb_build_object('allowed', false, 'reason', 'phone_unusable'); end if;
    if public.ffm_is_phone_suppressed(l.phone) then return jsonb_build_object('allowed', false, 'reason', 'suppressed'); end if;
  end if;
  select * into e from public.ffm_consent_log where lead_id = p_lead and basis = 'express' and capture_id is not null and channel = p_channel
     and exists (select 1 from public.ffm_consent_captures c where c.id = capture_id and c.erased_at is null)
     order by captured_at desc, created_at desc limit 1;
  if e.id is not null then return jsonb_build_object('allowed', true, 'reason', 'express', 'consent', e.id, 'captured_at', e.captured_at, 'wording_version', e.wording_version); end if;
  select * into i from public.ffm_consent_log where lead_id = p_lead and basis = 'implied' and channel = p_channel order by captured_at desc, created_at desc limit 1;
  if i.id is not null then
    select implied_window_days into win from public.ffm_consent_settings where workspace_id = l.workspace_id;
    if win is null then return jsonb_build_object('allowed', false, 'reason', 'implied_not_accepted'); end if;
    if i.captured_at + make_interval(days => win) <= clock_timestamp() then return jsonb_build_object('allowed', false, 'reason', 'implied_expired', 'captured_at', i.captured_at); end if;
    return jsonb_build_object('allowed', true, 'reason', 'implied', 'consent', i.id, 'captured_at', i.captured_at, 'expires_at', i.captured_at + make_interval(days => win));
  end if;
  if exists (select 1 from public.ffm_consent_log where lead_id = p_lead and basis = 'unverified' and channel = p_channel) then
    return jsonb_build_object('allowed', false, 'reason', 'evidence_unverified');
  end if;
  return jsonb_build_object('allowed', false, 'reason', 'no_consent');
end $$;

create or replace function public.ffm_can_contact(p_lead uuid, p_channel text) returns boolean
language plpgsql stable security definer set search_path to 'public' as $$
begin
  return coalesce((public.ffm_contact_status(p_lead, p_channel) ->> 'allowed')::boolean, false);
exception when others then
  return false;   -- fail closed: any error is a no
end $$;

-- 10. withdrawal and erasure also suppress the PHONE ---------------------------------------------------------------------------------------------------------------------
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
  if p_channel in ('sms', 'phone', 'all') then
    insert into public.ffm_phone_suppressions (phone, reason, recorded_by, source_lead)
      select public.normalize_phone(phone), 'ffm consent withdrawn (' || p_channel || ')', coalesce(nullif(btrim(p_by), ''), 'unknown'), null from public.ws_leads where id = p_lead and public.normalize_phone(phone) is not null
      on conflict do nothing;   -- the same for the NUMBER, in any written format; a number-based withdrawal blocks every phone-based channel (sms and voice)
  end if;
  insert into public.audit_log (actor, action, target, detail) values ('ffm', 'ffm_consent_withdrawn', 'workspace/' || p_ws, jsonb_build_object('lead', p_lead, 'channel', p_channel, 'consent', v_id));
  return v_id;
end $$;

create or replace function public.ffm_erase_lead(p_ws uuid, p_lead uuid, p_reason text) returns jsonb
language plpgsql security definer set search_path to 'public' as $$
declare n_ev integer; n_cap integer := 0; k text := (select value from public.ffm_secrets where name = 'capture_signing_key'); l public.ws_leads;
begin
  perform public.ffm_require_owner();
  if p_reason is null or p_reason not in ('erasure_request', 'withdrawal', 'retention_expired', 'other') then raise exception 'erasure refused: reason must be erasure_request, withdrawal, retention_expired or other'; end if;
  perform pg_advisory_xact_lock(hashtextextended('ffm_consent:' || p_lead::text, 0));
  select * into l from public.ws_leads where id = p_lead and workspace_id = p_ws;
  if l.id is null then raise exception 'lead not found in this workspace'; end if;
  insert into public.ffm_consent_log (workspace_id, lead_id, channel, basis, source, captured_at, recorded_by)
    values (p_ws, p_lead, 'all', 'withdrawn', 'erasure:' || p_reason, clock_timestamp(), 'owner');
  insert into public.contact_suppressions (address, reason, recorded_by, source_lead)
    select public.normalize_addr(l.email), 'ffm erasure/withdrawal', 'owner', null where public.normalize_addr(l.email) is not null
    on conflict do nothing;   -- the address stays blocked after the lead row is redacted, so re-adding the same person cannot restore contact
  insert into public.ffm_phone_suppressions (phone, reason, recorded_by, source_lead)
    select public.normalize_phone(l.phone), 'ffm erasure/withdrawal', 'owner', null where public.normalize_phone(l.phone) is not null
    on conflict do nothing;   -- and the number
  perform set_config('app.ffm_erasure', 'on', true);
  update public.ws_leads set name = '[erased]', email = null, phone = null, source = null, note = null where id = p_lead;
  update public.ffm_consent_log set evidence_ref = null, source = '[erased]', evidence_erased_at = clock_timestamp() where lead_id = p_lead and (evidence_ref is not null or source <> '[erased]');
  get diagnostics n_ev = row_count;
  -- captures bound to this person (by lead id, or by the keyed hash of the contact they used) lose the hash that could re-identify them; the opaque capture_ref stays
  update public.ffm_consent_captures set contact_mac = null, erased_at = clock_timestamp()
    where erased_at is null and (lead_id = p_lead
       or (k is not null and contact_mac is not null and contact_mac in (
            select public.ffm_contact_mac(k, 'email', public.normalize_addr(l.email)) where public.normalize_addr(l.email) is not null
            union select public.ffm_contact_mac(k, 'phone', public.normalize_phone(l.phone)) where public.normalize_phone(l.phone) is not null)));
  get diagnostics n_cap = row_count;
  perform set_config('app.ffm_erasure', 'off', true);
  insert into public.audit_log (actor, action, target, detail) values ('owner', 'ffm_lead_erased', 'workspace/' || p_ws, jsonb_build_object('lead', p_lead, 'reason', p_reason, 'evidence_refs_blanked', n_ev, 'captures_unlinked', n_cap));
  return jsonb_build_object('lead', p_lead, 'evidence_refs_blanked', n_ev, 'captures_unlinked', n_cap, 'note', 'copies in external backups are handled by key rotation or expiry, see DATA_CLASSIFICATION_AND_BACKUP_POLICY.md');
end $$;

-- 11. the legacy send path (review finding 2). ONE decision function, used by the trigger, by the RPC the Python senders call, and by the owner approval check.
-- NULL = nothing against it; otherwise a reason code. It fails closed: the gate closed, a do-not-contact lead, an unusable or suppressed address / number, or any error is a "no".
-- email: is_suppressed (plaintext list AND hash-only entries). text / call: the PHONE suppression list (plaintext AND hash-only). telegram / post: the gate and the lead flag only.
create or replace function public.outreach_recipient_problem(p_channel text, p_to text, p_lead uuid) returns text
language plpgsql stable security definer set search_path to 'public' as $$
declare dnc boolean := false;
begin
  if not public.ffm_outreach_gate_open() then return 'suppression_unverified'; end if;
  if p_lead is not null then select do_not_contact into dnc from public.leads where id = p_lead; end if;
  if coalesce(dnc, false) then return 'lead_do_not_contact'; end if;
  if p_channel = 'email' then
    if p_to is null or public.normalize_addr(p_to) is null then return 'address_unusable'; end if;
    if public.is_suppressed(p_to) then return 'suppressed'; end if;
  elsif p_channel in ('text', 'call') then
    if p_to is null or public.normalize_phone(p_to) is null then return 'phone_unusable'; end if;
    if public.ffm_is_phone_suppressed(p_to) then return 'suppressed'; end if;
  end if;
  return null;
exception when others then
  return 'error';
end $$;

-- What the senders (hq_mail._claim / deliver_approved, hq_venture_ops.dnc_problem) ask BEFORE claiming and again IMMEDIATELY before the provider call. Only {"allowed": true} is a yes.
create or replace function public.outreach_send_allowed(p_outbox uuid) returns jsonb
language plpgsql stable security definer set search_path to 'public' as $$
declare o public.outbox; why text;
begin
  select * into o from public.outbox where id = p_outbox;
  if o.id is null then return jsonb_build_object('allowed', false, 'reason', 'unknown_outbox'); end if;
  if o.status not in ('draft', 'qa_passed', 'approved') then return jsonb_build_object('allowed', false, 'reason', 'not_sendable_status'); end if;
  why := public.outreach_recipient_problem(o.channel, o.to_ref, o.lead_id);
  if why is not null then return jsonb_build_object('allowed', false, 'reason', why); end if;
  return jsonb_build_object('allowed', true, 'reason', 'ok');
exception when others then
  return jsonb_build_object('allowed', false, 'reason', 'error');
end $$;

-- The trigger. A row that is, or becomes, approved / sent, or that carries a claim (sent_at set), is DELIVERY-BOUND: it needs the gate open and an allowed recipient, EVERY time it is written
-- (the old early return let a claim, which only sets sent_at, through with the gate closed). The one write that is always allowed is releasing a claim (sent_at back to null, nothing else changed).
create or replace function public.outbox_dnc_guard() returns trigger
language plpgsql set search_path to 'public' as $$
declare dnc boolean := false; bound boolean; why text;
begin
  if new.status not in ('draft','qa_passed','approved','sent') then return new; end if;
  if tg_op = 'UPDATE' and new.status is not distinct from old.status
     and new.to_ref is not distinct from old.to_ref and new.channel is not distinct from old.channel and new.lead_id is not distinct from old.lead_id then
    if new.sent_at is not distinct from old.sent_at then return new; end if;     -- nothing that decides WHO is contacted or WHETHER it advances changed
    if new.sent_at is null then return new; end if;                                -- releasing a claim only reduces what happens
  end if;
  bound := new.status in ('approved', 'sent') or new.sent_at is not null;
  if bound and not public.ffm_outreach_gate_open() then
    raise exception 'Outreach gate closed: the suppression list has not been verified (default-deny after a restore or on a fresh database). No approval, claim or send is allowed.' using errcode = 'P0001';
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
  if new.channel in ('text', 'call') and public.normalize_phone(new.to_ref) is not null and public.ffm_is_phone_suppressed(new.to_ref) then   -- (an unusable number is refused below, once the row is delivery-bound)
    raise exception 'Do-not-contact: this phone number has opted out. No draft, approval or send is allowed.' using errcode = 'P0001';
  end if;
  if coalesce(dnc, false) or (new.channel = 'email' and public.is_suppressed(new.to_ref)) then
    raise exception 'Do-not-contact: this lead or address has opted out (CASL). No draft, approval or send is allowed.' using errcode = 'P0001';
  end if;
  if bound then   -- the single shared decision (also what outreach_send_allowed answers): unusable phone numbers, hash-only entries, any error
    why := public.outreach_recipient_problem(new.channel, new.to_ref, new.lead_id);
    if why is not null then
      raise exception 'Do-not-contact or unusable recipient (%): no approval, claim or send is allowed.', why using errcode = 'P0001';
    end if;
  end if;
  return new;
end $$;

-- 12. grants ----------------------------------------------------------------------------------------------------------------------------------------------------------
revoke all on function public.ffm_gate_no_delete() from public, anon, authenticated;
revoke all on function public.ffm_sup_message(text, text) from public, anon, authenticated;
revoke all on function public.outreach_recipient_problem(text, text, uuid) from public, anon, authenticated;
revoke all on function public.outreach_send_allowed(uuid) from public, anon, authenticated;
revoke all on function public.is_suppressed(text) from public, anon, authenticated;
revoke all on function public.ffm_is_phone_suppressed(text) from public, anon, authenticated;
revoke all on function public.ffm_outreach_gate_open() from public, anon, authenticated;
revoke all on function public.ffm_outreach_gate_status() from public, anon, authenticated;
revoke all on function public.ffm_close_outreach_gate(text, text) from public, anon, authenticated;
revoke all on function public.ffm_suppression_set() from public, anon, authenticated;   -- returns keyed hashes only
revoke all on function public.ffm_suppression_digest() from public, anon, authenticated;
revoke all on function public.backup_suppression_export() from public, anon, authenticated;
revoke all on function public.ffm_stage_suppression_checkpoint(jsonb) from public, anon, authenticated;
revoke all on function public.ffm_import_suppression_hashes() from public, anon, authenticated;
revoke all on function public.ffm_verify_suppression(text) from public, anon, authenticated;
revoke all on function public.ffm_contact_status(uuid, text) from public, anon, authenticated;
revoke all on function public.ffm_can_contact(uuid, text) from public, anon, authenticated;
revoke all on function public.ffm_withdraw_consent(uuid, uuid, text, text, text, text) from public, anon, authenticated;
revoke all on function public.ffm_erase_lead(uuid, uuid, text) from public, anon, authenticated;
revoke all on function public.outbox_dnc_guard() from public, anon, authenticated;
grant execute on function public.ffm_gate_no_delete() to service_role;
grant execute on function public.ffm_sup_message(text, text) to service_role;
grant execute on function public.outreach_recipient_problem(text, text, uuid) to service_role;
grant execute on function public.outreach_send_allowed(uuid) to service_role;
grant execute on function public.ffm_suppression_set() to service_role;
grant execute on function public.is_suppressed(text) to service_role;
grant execute on function public.ffm_is_phone_suppressed(text) to service_role;
grant execute on function public.ffm_outreach_gate_open() to service_role;
grant execute on function public.ffm_outreach_gate_status() to service_role;
grant execute on function public.ffm_close_outreach_gate(text, text) to service_role;
grant execute on function public.ffm_suppression_digest() to service_role;
grant execute on function public.backup_suppression_export() to service_role;
grant execute on function public.ffm_stage_suppression_checkpoint(jsonb) to service_role;
grant execute on function public.ffm_import_suppression_hashes() to service_role;
grant execute on function public.ffm_verify_suppression(text) to service_role;
grant execute on function public.ffm_contact_status(uuid, text) to service_role;
grant execute on function public.ffm_can_contact(uuid, text) to service_role;
grant execute on function public.ffm_withdraw_consent(uuid, uuid, text, text, text, text) to service_role;
grant execute on function public.ffm_erase_lead(uuid, uuid, text) to service_role;
grant execute on function public.outbox_dnc_guard() to service_role;

-- 13. app_owners (review finding 3). In production service_role could INSERT into app_owners and so mint an owner (is_app_owner() trusts that table). Verified read-only on Nov 15 2026:
-- service_role holds every privilege, anon/authenticated none, RLS on with no policy, no trigger, and NO code in this repository writes it (owners are added by hand in the SQL editor,
-- which runs as postgres and is unaffected). The bot only reads it (hq_backup). So the writes are taken away; select stays.
revoke insert, update, delete, truncate, references, trigger on public.app_owners from public, anon, authenticated, service_role;
revoke all on public.app_owners from anon, authenticated;
grant select on public.app_owners to service_role;
