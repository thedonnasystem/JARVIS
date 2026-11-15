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
--   (e) CHANNEL PROHIBITION (v3): a person-directed outbound is allowed ONLY on a channel with a durable suppression identifier: email (normalised address), text/sms and call/phone
--       (normalised number). telegram, post/mail, whatsapp and every unknown channel are refused at the database (outreach_channel_problem, outreach_recipient_problem, outbox_dnc_guard,
--       ffm_contact_status, ffm_route_preview) until a durable identifier and check exist for them (a new reviewed migration, never a data change).
--   (f) RESTORE-CLOSED GATE (v3): the gate is open only while it is bound to things a restore does not carry along: a monotonic suppression EPOCH that the SENDER process also keeps outside
--       the database (hq_gatemark.py: high-water mark), the instance fingerprint (system identifier + timeline), a RESTORE MARKER newer than the last verification, a fresh sender ATTESTATION
--       (minutes) and a maximum age since the owner's verification (days). A restored database therefore closes itself; nobody has to remember anything.
--   Replaced functions (same signatures): is_suppressed, outbox_dnc_guard, ffm_contact_status, ffm_can_contact, ffm_withdraw_consent, ffm_erase_lead, ffm_route_preview.
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
  verified_epoch bigint,          -- the suppression epoch at verification (v3)
  verified_marker_id bigint,      -- the newest restore-marker id at verification (v3): the gate is open only while it is STILL the newest (deterministic, no wall-clock comparison)
  instance_fp text,               -- the instance fingerprint at verification (v3)
  attested_at timestamptz,        -- last time the SENDER (or the owner's verification) attested the gate against its external high-water mark (v3)
  updated_at timestamptz not null default clock_timestamp()
);
insert into public.ffm_outreach_gate (id, state, reason) values (1, 'unverified', 'fresh database: the suppression list has not been verified') on conflict (id) do nothing;

-- v3: the monotonic suppression epoch, the restore markers and the gate configuration. All three are ffm_* (never in the off-site file) and writable only through definer functions.
create table if not exists public.ffm_epoch (
  id integer primary key check (id = 1),
  epoch bigint not null check (epoch >= 1),
  updated_at timestamptz not null default clock_timestamp()
);
insert into public.ffm_epoch (id, epoch) values (1, 1) on conflict (id) do nothing;
create table if not exists public.ffm_restore_markers (
  id bigint generated always as identity primary key,
  restored_at timestamptz not null default clock_timestamp(),
  source text not null,
  detail text,
  recorded_by text not null
);
create table if not exists public.ffm_gate_config (
  id integer primary key check (id = 1),
  attest_window_minutes integer not null default 15 check (attest_window_minutes between 6 and 120),   -- the engine tick is 300 s: a window below two ticks would close the gate between ticks
  max_verified_age_days integer not null default 30 check (max_verified_age_days between 1 and 90),
  phone_outreach_enabled boolean not null default false,   -- text / call (sms / phone) are DISABLED until the owner enables them: the DB gate alone cannot tell a same-instance restore inside the attestation window, and no sender attests for those channels
  updated_at timestamptz not null default clock_timestamp()
);
alter table public.ffm_gate_config add column if not exists phone_outreach_enabled boolean not null default false;
insert into public.ffm_gate_config (id) values (1) on conflict (id) do nothing;
-- the highest sender mark the DATABASE has accepted (monotonic): a forged lower mark cannot refresh the gate, and a NEW generation (an anchor) is accepted only with an owner-recorded restore (or first setup)
create table if not exists public.ffm_sender_mark (
  id integer primary key check (id = 1),
  gen bigint not null default 0 check (gen >= 0),
  epoch bigint not null default 0 check (epoch >= 0),
  owner_marker_id bigint not null default 0,
  updated_at timestamptz not null default clock_timestamp()
);
insert into public.ffm_sender_mark (id) values (1) on conflict (id) do nothing;

do $$ declare t text; begin
  foreach t in array array['ffm_phone_suppressions', 'ffm_suppression_hashes', 'ffm_suppression_expected', 'ffm_outreach_gate', 'ffm_epoch', 'ffm_restore_markers', 'ffm_gate_config', 'ffm_sender_mark'] loop
    execute format('alter table public.%I enable row level security', t);
    execute format('revoke all on public.%I from public, anon, authenticated, service_role', t);
  end loop;
  grant select on public.ffm_phone_suppressions, public.ffm_outreach_gate, public.ffm_epoch, public.ffm_restore_markers, public.ffm_gate_config, public.ffm_sender_mark to service_role;   -- the bot may READ the list and the gate state; every write goes through a definer function
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

-- v3: epoch. It only ever goes up (a direct write that lowers it is refused; a superuser can still do anything, see the policy limits). Markers are append-only. Any write to a
-- suppression list, the consent log (withdrawals), the lead do-not-contact flag, or a gate transition bumps it, so a database rolled back to an earlier point shows a LOWER epoch than
-- the one the sender last saw.
create or replace function public.ffm_epoch_guard() returns trigger
language plpgsql set search_path to 'public' as $$
begin
  if tg_op <> 'UPDATE' or new.epoch <= old.epoch or new.id <> 1 then raise exception 'The suppression epoch only increases and cannot be deleted or truncated.' using errcode = 'P0001'; end if;
  return new;
end $$;
drop trigger if exists ffm_epoch_guard on public.ffm_epoch;
create trigger ffm_epoch_guard before update or delete on public.ffm_epoch for each row execute function public.ffm_epoch_guard();
drop trigger if exists ffm_epoch_no_truncate on public.ffm_epoch;
create trigger ffm_epoch_no_truncate before truncate on public.ffm_epoch for each statement execute function public.ffm_epoch_guard();
drop trigger if exists ffm_markers_append_only on public.ffm_restore_markers;
create trigger ffm_markers_append_only before update or delete on public.ffm_restore_markers for each row execute function public.ffm_append_only();
drop trigger if exists ffm_markers_no_truncate on public.ffm_restore_markers;
create trigger ffm_markers_no_truncate before truncate on public.ffm_restore_markers for each statement execute function public.ffm_append_only();
create or replace function public.ffm_epoch_bump() returns trigger
language plpgsql security definer set search_path to 'public' as $$
begin
  update public.ffm_epoch set epoch = epoch + 1, updated_at = clock_timestamp() where id = 1;   -- (a trigger function: it cannot be called, so the service role cannot raise the epoch at will)
  return null;
end $$;
do $$ declare t text; begin
  foreach t in array array['contact_suppressions', 'ffm_phone_suppressions', 'ffm_suppression_hashes', 'ffm_consent_log'] loop
    execute format('drop trigger if exists ffm_epoch_bump on public.%I', t);
    execute format('create trigger ffm_epoch_bump after insert on public.%I for each statement execute function public.ffm_epoch_bump()', t);
  end loop;
end $$;
drop trigger if exists ffm_epoch_bump on public.leads;
create trigger ffm_epoch_bump after update of do_not_contact on public.leads for each statement execute function public.ffm_epoch_bump();
drop trigger if exists ffm_epoch_bump_ins on public.leads;
create trigger ffm_epoch_bump_ins after insert on public.leads for each row when (new.do_not_contact) execute function public.ffm_epoch_bump();     -- a lead created already flagged do-not-contact is a suppression too

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
    if not exists (select 1 from public.ffm_secrets where name = 'suppression_hmac_key') then return true; end if;     -- hash-only entries but no key to test them with: cannot show the address is NOT suppressed (fail closed)
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
    if not exists (select 1 from public.ffm_secrets where name = 'suppression_hmac_key') then return true; end if;     -- same: hashes but no key = fail closed
    return exists (select 1 from public.ffm_suppression_hashes where kind = 'phone' and mac = public.ffm_hmac_sha256((select value from public.ffm_secrets where name = 'suppression_hmac_key'), public.ffm_sup_message('phone', n)));
  end if;
  return false;
end $$;

-- 5. the gate ---------------------------------------------------------------------------------------------------------------------------------------------------------
-- Open only when: the gate row says verified, the suppression key exists, and the list has not SHRUNK since verification (the three lists are append-only, so a lower row
-- count means something removed rows underneath the triggers). Any error is "closed".
create or replace function public.ffm_instance_fp() returns text
language plpgsql stable security definer set search_path to 'public' as $$
declare sid text; tl integer; i integer;
begin
  for i in 1..3 loop     -- a transient read error is retried inside the call; only a PERSISTENT failure yields 'unavailable'
    begin
      select system_identifier::text into sid from pg_control_system();
      select timeline_id into tl from pg_control_checkpoint();
      -- sid: a dump restored into another cluster changes it. tl: a point-in-time recovery promotes a NEW timeline. dboid + the gate table's OID: NOT carried by a logical restore (pg_dump/pg_restore into a
      -- new database, or into this one after --clean, creates the database / tables afresh with new OIDs), so a same-cluster logical restore no longer looks like the original, with no sender involved.
      -- (A DATA-ONLY restore into the existing tables keeps both: the residual that only the sender's outside mark and the owner's record-restore step cover.)
      return sid || ':' || tl || ':' || (select oid::text from pg_database where datname = current_database()) || ':' || 'public.ffm_outreach_gate'::regclass::oid::text;
    exception when others then
      if i < 3 then perform pg_sleep(0.05 * i); end if;
    end;
  end loop;
  return 'unavailable';           -- this layer is then absent (and the gate closed: the stored fingerprint cannot be matched), never "open"
end $$;
-- Everything that makes the gate valid EXCEPT the freshness of the sender attestation. Used by the open decision and by the anchor rule (an owner who has just verified must be able to anchor).
-- No wall-clock comparison decides between a restore and a verification: the verification records the NEWEST restore-marker id, and the gate is valid only while that is still the newest.
create or replace function public.ffm_gate_core_ok() returns boolean
language plpgsql stable security definer set search_path to 'public' as $$
declare g public.ffm_outreach_gate; raw integer; ep bigint; cfg public.ffm_gate_config; fp text;
begin
  select * into g from public.ffm_outreach_gate where id = 1;
  if g.id is null or g.state <> 'verified' or g.verified_raw_count is null or g.verified_at is null or g.verified_epoch is null or g.verified_marker_id is null then return false; end if;
  if not exists (select 1 from public.ffm_secrets where name = 'suppression_hmac_key') then return false; end if;
  select epoch into ep from public.ffm_epoch where id = 1;
  if ep is null or ep < g.verified_epoch then return false; end if;                                             -- the epoch is missing or LOWER than at verification: rolled back or rebuilt
  fp := public.ffm_instance_fp();
  if fp = 'unavailable' or g.instance_fp is distinct from fp then return false; end if;                         -- another cluster, a recovery timeline, or an unreadable fingerprint
  if g.verified_marker_id <> (select coalesce(max(id), 0) from public.ffm_restore_markers) then return false; end if;   -- a restore was recorded after the verification (or the marker table was rolled back)
  select * into cfg from public.ffm_gate_config where id = 1;
  if g.verified_at < clock_timestamp() - make_interval(days => coalesce(cfg.max_verified_age_days, 30)) then return false; end if;   -- the owner's verification is too old
  raw := (select count(*) from public.contact_suppressions) + (select count(*) from public.ffm_phone_suppressions) + (select count(*) from public.ffm_suppression_hashes);
  return raw >= g.verified_raw_count;
exception when others then
  return false;
end $$;
create or replace function public.ffm_outreach_gate_open() returns boolean
language plpgsql stable security definer set search_path to 'public' as $$
declare g public.ffm_outreach_gate; cfg public.ffm_gate_config;
begin
  if not public.ffm_gate_core_ok() then return false; end if;
  select * into g from public.ffm_outreach_gate where id = 1;
  select * into cfg from public.ffm_gate_config where id = 1;
  return g.attested_at is not null and g.attested_at >= clock_timestamp() - make_interval(mins => coalesce(cfg.attest_window_minutes, 15));    -- no fresh sender attestation: closed by itself
exception when others then
  return false;
end $$;
create or replace function public.ffm_outreach_gate_status() returns jsonb
language plpgsql stable security definer set search_path to 'public' as $$
declare g public.ffm_outreach_gate;
begin
  select * into g from public.ffm_outreach_gate where id = 1;
  return jsonb_build_object('open', public.ffm_outreach_gate_open(), 'core_ok', public.ffm_gate_core_ok(), 'state', coalesce(g.state, 'missing'), 'reason', coalesce(g.reason, 'gate row missing'),
    'key_set', exists (select 1 from public.ffm_secrets where name = 'suppression_hmac_key'), 'checkpoint_staged', g.expected_hash is not null,
    'expected_count', g.expected_count, 'verified_at', g.verified_at, 'verified_raw_count', g.verified_raw_count,
    'raw_count_now', (select count(*) from public.contact_suppressions) + (select count(*) from public.ffm_phone_suppressions) + (select count(*) from public.ffm_suppression_hashes),
    'epoch', (select epoch from public.ffm_epoch where id = 1), 'verified_epoch', g.verified_epoch, 'attested_at', g.attested_at,
    'instance_matches', g.instance_fp is not distinct from public.ffm_instance_fp(), 'last_restore_marker_id', (select max(id) from public.ffm_restore_markers));
end $$;
-- anyone may CLOSE the gate (a restore tool, the bot on suspicion): it can only reduce what is allowed. Only ffm_verify_suppression opens it.
create or replace function public.ffm_close_outreach_gate(p_reason text, p_by text) returns void
language plpgsql security definer set search_path to 'public' as $$
begin
  insert into public.ffm_outreach_gate (id, state, reason) values (1, 'unverified', left(coalesce(nullif(btrim(p_reason), ''), 'closed'), 300))
    on conflict (id) do update set state = 'unverified', reason = left(coalesce(nullif(btrim(p_reason), ''), 'closed'), 300), verified_raw_count = null, verified_at = null, verified_by = null,
      verified_epoch = null, verified_marker_id = null, instance_fp = null, attested_at = null, updated_at = clock_timestamp();
  update public.ffm_epoch set epoch = epoch + 1, updated_at = clock_timestamp() where id = 1;
  insert into public.audit_log (actor, action, target, detail) values (coalesce(nullif(btrim(p_by), ''), 'unknown'), 'ffm_outreach_gate_closed', 'gate/1', jsonb_build_object('reason', left(coalesce(p_reason, ''), 300)));
end $$;

-- 5b. RESTORE-CLOSED GATE (v3) ------------------------------------------------------------------------------------------------------------------------------------------
-- ffm_owner_record_restore: OWNER ONLY (the SQL editor, or a restore tool running as the database owner). Writes an owner restore MARKER and closes the gate. The only things that can lower the
-- sender's mark afterwards are this marker plus a fresh owner verification plus an anchor, in that order. (The previous anyone-callable ffm_record_restore is gone: with the lockdown blanket
-- grant the bot could have called it. The sender's own detection writes its marker inline, below, with source 'detected_by_sender', which never authorises an anchor.)
create or replace function public.ffm_owner_record_restore(p_detail text) returns bigint
language plpgsql security definer set search_path to 'public' as $$
declare m bigint;
begin
  perform public.ffm_require_owner();
  insert into public.ffm_restore_markers (source, detail, recorded_by) values ('owner_restore', left(p_detail, 300), 'owner') returning id into m;
  perform public.ffm_close_outreach_gate('owner recorded a restore: the suppression list must be re-verified, then the sender anchored', 'owner');
  return m;
end $$;
-- the state the sender compares with its OUTSIDE high-water mark (read-only; no key, no list)
create or replace function public.ffm_gate_state() returns jsonb
language plpgsql stable security definer set search_path to 'public' as $$
begin
  return jsonb_build_object('epoch', (select epoch from public.ffm_epoch where id = 1), 'instance_fp', public.ffm_instance_fp(), 'open', public.ffm_outreach_gate_open(), 'core_ok', public.ffm_gate_core_ok(),
    'state', coalesce((select state from public.ffm_outreach_gate where id = 1), 'missing'), 'verified_at', (select verified_at from public.ffm_outreach_gate where id = 1),
    'last_marker_id', (select max(id) from public.ffm_restore_markers),
    'last_owner_marker_id', (select coalesce(max(id), 0) from public.ffm_restore_markers where source in ('owner_restore', 'restore_backup.py')),
    'mark_gen', (select gen from public.ffm_sender_mark where id = 1), 'mark_epoch', (select epoch from public.ffm_sender_mark where id = 1));
end $$;
-- ffm_sender_attest: the sender process (which keeps a high-water mark OUTSIDE this database) says what it last saw: (generation, epoch, instance).
--   * the database must not be BEHIND the sender (epoch lower, or another instance): the gate is closed FOR GOOD (inline marker + close), not merely refused for this call;
--   * the database remembers the highest mark it has accepted (ffm_sender_mark) and REJECTS a lower one, so a forged low mark cannot refresh a stale gate;
--   * a HIGHER generation (an anchor) is accepted only while the gate is fully valid and freshly verified (open), and only with an owner restore marker not yet consumed (or at first setup);
--   * a successful attestation only KEEPS a verified gate fresh; it can never open a closed one.
create or replace function public.ffm_sender_attest(p_hwm_gen bigint, p_hwm_epoch bigint, p_hwm_instance text) returns jsonb
language plpgsql security definer set search_path to 'public' as $$
declare ep bigint; fp text := public.ffm_instance_fp(); st text; why text; sm public.ffm_sender_mark; om bigint;
begin
  select epoch into ep from public.ffm_epoch where id = 1;
  select state into st from public.ffm_outreach_gate where id = 1;
  select * into sm from public.ffm_sender_mark where id = 1;
  if p_hwm_epoch is null or p_hwm_gen is null or p_hwm_gen < 1 or p_hwm_epoch < 1 then return jsonb_build_object('ok', false, 'reason', 'sender_unanchored'); end if;
  if fp = 'unavailable' then return jsonb_build_object('ok', false, 'reason', 'instance_unreadable'); end if;      -- a persistent read error: stay closed (the gate cannot match), write NO marker, nothing for the owner to do
  if ep is null then why := 'epoch row missing (schema rebuilt or restored)';
  elsif ep < p_hwm_epoch then why := 'rollback detected: database epoch ' || ep || ' is below the sender high-water mark ' || p_hwm_epoch;
  elsif p_hwm_instance is not null and p_hwm_instance <> fp then why := 'instance changed: the sender saw another database instance or timeline';
  end if;
  if why is not null then
    if st = 'verified' then
      insert into public.ffm_restore_markers (source, detail, recorded_by) values ('detected_by_sender', left(why, 300), 'sender');
      perform public.ffm_close_outreach_gate('rollback detected by the sender: ' || left(why, 200), 'sender');
    end if;
    return jsonb_build_object('ok', false, 'reason', 'rollback_detected', 'detail', why, 'epoch', ep);
  end if;
  if p_hwm_gen < sm.gen or (p_hwm_gen = sm.gen and p_hwm_epoch < sm.epoch) then
    return jsonb_build_object('ok', false, 'reason', 'mark_regression', 'detail', 'the sender mark is lower than the highest mark this database accepted');
  end if;
  if p_hwm_gen > sm.gen then      -- an ANCHOR
    select coalesce(max(id), 0) into om from public.ffm_restore_markers where source in ('owner_restore', 'restore_backup.py');
    if p_hwm_epoch <> ep then return jsonb_build_object('ok', false, 'reason', 'anchor_refused', 'detail', 'an anchor must carry exactly the current database epoch (' || ep || '); read ffm_gate_state and retry'); end if;
    if not public.ffm_gate_core_ok() then return jsonb_build_object('ok', false, 'reason', 'anchor_refused', 'detail', 'the gate is not freshly verified: record the restore, verify the suppression list, THEN anchor'); end if;
    if sm.gen > 0 and om <= sm.owner_marker_id then return jsonb_build_object('ok', false, 'reason', 'anchor_refused', 'detail', 'a new generation needs an owner-recorded restore (ffm_owner_record_restore) not yet used'); end if;
    update public.ffm_sender_mark set gen = p_hwm_gen, epoch = p_hwm_epoch, owner_marker_id = om, updated_at = clock_timestamp() where id = 1;
    insert into public.audit_log (actor, action, target, detail) values ('sender', 'ffm_sender_anchored', 'gate/1', jsonb_build_object('gen', p_hwm_gen, 'epoch', p_hwm_epoch));
  elsif p_hwm_epoch > sm.epoch then
    update public.ffm_sender_mark set epoch = p_hwm_epoch, updated_at = clock_timestamp() where id = 1;
  end if;
  update public.ffm_outreach_gate set attested_at = clock_timestamp() where id = 1 and state = 'verified' and public.ffm_gate_core_ok();
  return jsonb_build_object('ok', true, 'epoch', ep, 'instance_fp', fp, 'open', public.ffm_outreach_gate_open());
end $$;
create or replace function public.ffm_set_gate_config(p_attest_window_minutes integer, p_max_verified_age_days integer, p_by text) returns void
language plpgsql security definer set search_path to 'public' as $$
begin
  perform public.ffm_require_owner();
  update public.ffm_gate_config set attest_window_minutes = p_attest_window_minutes, max_verified_age_days = p_max_verified_age_days, updated_at = clock_timestamp() where id = 1;   -- the CHECKs bound both values
  insert into public.audit_log (actor, action, target, detail) values (coalesce(nullif(btrim(p_by), ''), 'owner'), 'ffm_gate_config_set', 'gate/1', jsonb_build_object('attest_window_minutes', p_attest_window_minutes, 'max_verified_age_days', p_max_verified_age_days));
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
      expected_staged_at = clock_timestamp(), verified_raw_count = null, verified_at = null, verified_by = null, verified_epoch = null, verified_marker_id = null, instance_fp = null, attested_at = null, updated_at = clock_timestamp();
  update public.ffm_epoch set epoch = epoch + 1, updated_at = clock_timestamp() where id = 1;
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
  if not exists (select 1 from public.ffm_epoch where id = 1) then
    perform public.ffm_close_outreach_gate('verification failed: the suppression epoch row is missing', p_by);
    return jsonb_build_object('verified', false, 'reason', 'the suppression epoch row is missing');
  end if;
  update public.ffm_epoch set epoch = epoch + 1, updated_at = clock_timestamp() where id = 1;
  update public.ffm_outreach_gate set state = 'verified', reason = 'verified against checkpoint (' || mode || ')', verified_raw_count = raw, verified_at = clock_timestamp(),
         verified_by = coalesce(nullif(btrim(p_by), ''), 'owner'), verified_epoch = (select epoch from public.ffm_epoch where id = 1), verified_marker_id = (select coalesce(max(id), 0) from public.ffm_restore_markers), instance_fp = public.ffm_instance_fp(),
         attested_at = clock_timestamp(), updated_at = clock_timestamp() where id = 1;     -- the owner's own verification is a fresh attestation; afterwards the SENDER must keep it fresh
  insert into public.audit_log (actor, action, target, detail) values ('owner', 'ffm_suppression_verified', 'gate/1', jsonb_build_object('mode', mode, 'expected', exp_n, 'current', cur));
  return jsonb_build_object('verified', true, 'mode', mode, 'expected', exp_n, 'current', cur);
end $$;

-- 8b. CHANNEL POLICY (v3). One immutable function, compiled into the database: changing it needs a reviewed migration, never a data write (the bot cannot flip it).
-- A person-directed outbound is allowed ONLY on a channel that has a durable suppression identifier AND a check in this file:
--   email -> normalised address (contact_suppressions + hashes); text/sms and call/phone -> normalised number (ffm_phone_suppressions + hashes).
-- telegram (a handle is not stable, not unique, and nothing here records it), post/mail (a postal address has no normaliser or list here) and whatsapp/signal/other (a phone-based
-- identity this schema does not model) are PROHIBITED. Anything else is unknown. Both give a reason code; neither is ever allowed. Owner-directed Telegram (owner_messages) is not outreach
-- and does not pass through here.
create or replace function public.outreach_channel_problem(p_channel text) returns text
language sql immutable set search_path to 'public' as $$
  select case
    when p_channel in ('email', 'text', 'call', 'sms', 'phone') then null
    when p_channel in ('telegram', 'post', 'mail', 'whatsapp', 'signal', 'other') then 'channel_prohibited'
    else 'unknown_channel' end $$;
-- text / call (sms / phone) are DISABLED until the owner enables them (ffm_set_phone_outreach). Reason: every consumer of the DB gate (owner approval, manual text/call, outbox insert) trusts DB state that a
-- same-instance restore brings back, and only the email sender (hq_mail.deliver_approved) attests against the outside high-water mark. No sender exists for text/call, so nothing external can vouch for them.
create or replace function public.outreach_channel_disabled(p_channel text) returns text
language sql stable security definer set search_path to 'public' as $$
  select case when p_channel in ('text', 'call', 'sms', 'phone') and not coalesce((select phone_outreach_enabled from public.ffm_gate_config where id = 1), false) then 'channel_disabled' else null end $$;
create or replace function public.ffm_set_phone_outreach(p_enabled boolean, p_by text) returns void
language plpgsql security definer set search_path to 'public' as $$
begin
  perform public.ffm_require_owner();
  if p_enabled is null then raise exception 'p_enabled must be true or false'; end if;
  update public.ffm_gate_config set phone_outreach_enabled = p_enabled, updated_at = clock_timestamp() where id = 1;
  insert into public.audit_log (actor, action, target, detail) values (coalesce(nullif(btrim(p_by), ''), 'owner'), 'ffm_phone_outreach_set', 'gate/1', jsonb_build_object('enabled', p_enabled));
  perform public.ffm_close_outreach_gate('phone outreach setting changed: re-verify', coalesce(nullif(btrim(p_by), ''), 'owner'));    -- any change of what may be contacted re-opens only through a fresh verification
end $$;

-- 9. the decision, replaced: gate first, then withdrawal, then address/number suppression, then consent ---------------------------------------------------------------------
create or replace function public.ffm_contact_status(p_lead uuid, p_channel text) returns jsonb
language plpgsql stable security definer set search_path to 'public' as $$
declare l public.ws_leads; wstatus text; e public.ffm_consent_log; i public.ffm_consent_log; win integer;
begin
  p_channel := case p_channel when 'text' then 'sms' when 'call' then 'phone' else p_channel end;     -- the outbox names (text, call) map to the consent log's (sms, phone) BEFORE any check
  if p_channel is null or public.outreach_channel_problem(p_channel) is not null then      -- v3: only channels with a durable suppression identifier (email, sms, phone) can ever be allowed
    return jsonb_build_object('allowed', false, 'reason', case public.outreach_channel_problem(p_channel) when 'channel_prohibited' then 'channel_prohibited' else 'invalid_channel' end);
  end if;
  if public.outreach_channel_disabled(p_channel) is not null then return jsonb_build_object('allowed', false, 'reason', 'channel_disabled'); end if;
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

-- 9b. routing preview, replaced (v3): refuses while the gate is closed (with that reason, not a vague one) and counts ONLY channels that can be contacted at all (email, sms, phone; never mail).
-- Still a dry run: sends nothing, logs only field names.
create or replace function public.ffm_route_preview(p_ws uuid, p_lead uuid) returns jsonb
language plpgsql security definer set search_path to 'public' as $$
declare l public.ws_leads; r public.ffm_routing_rules; src jsonb; pay jsonb; out_ jsonb := '[]'::jsonb; f text;
begin
  perform public.ffm_open_ws(p_ws);
  select * into l from public.ws_leads where id = p_lead and workspace_id = p_ws;
  if l.id is null then raise exception 'lead not found in this workspace'; end if;
  if not public.ffm_outreach_gate_open() then raise exception 'routing refused: the outreach gate is closed (suppression list not verified, or a restore was detected)'; end if;
  if not (public.ffm_can_contact(p_lead, 'email') or public.ffm_can_contact(p_lead, 'sms') or public.ffm_can_contact(p_lead, 'phone')) then
    raise exception 'routing refused: no current consent on a channel that can be contacted (email, sms, phone) for this lead';
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

-- 10. withdrawal and erasure also suppress the PHONE ---------------------------------------------------------------------------------------------------------------------
-- WHICH WITHDRAWALS PROPAGATE (v3, decided and tested): 'all' -> the address AND the number; email -> the address only; sms / phone (also 'text' / 'call') -> the number only, and a number-based
-- withdrawal blocks every phone-based channel (sms AND voice). Channel-specific withdrawals persist on THEIR channel by durable identifier; they are not propagated to the other identifier.
-- A withdrawal on a channel WITHOUT a durable identifier (telegram, post/mail, whatsapp, signal, other) cannot be stored by identifier, and nothing can be sent on those channels anyway;
-- but the person has objected, so it is treated as 'all' (fail closed): it is logged as channel 'all' with the original channel in the source, and suppresses the lead's address and number.
create or replace function public.ffm_withdraw_consent(p_ws uuid, p_lead uuid, p_channel text, p_source text, p_evidence_ref text, p_by text) returns uuid
language plpgsql security definer set search_path to 'public' as $$
declare v_id uuid; ch text; l public.ws_leads; src text := coalesce(nullif(btrim(p_source), ''), 'unspecified');
begin
  if p_channel is null or p_channel not in ('email', 'sms', 'phone', 'mail', 'all', 'text', 'call', 'post', 'telegram', 'whatsapp', 'signal', 'other') then
    raise exception 'withdrawal refused: channel must be one of email, sms, phone, text, call, mail, post, telegram, whatsapp, signal, other, all';
  end if;
  ch := case p_channel when 'text' then 'sms' when 'call' then 'phone' when 'post' then 'all' when 'mail' then 'all' when 'telegram' then 'all' when 'whatsapp' then 'all' when 'signal' then 'all' when 'other' then 'all' else p_channel end;
  if ch = 'all' and p_channel <> 'all' then src := left('via ' || p_channel || ': ' || src, 300); end if;
  perform pg_advisory_xact_lock(hashtextextended('ffm_consent:' || p_lead::text, 0));
  select * into l from public.ws_leads where id = p_lead and workspace_id = p_ws;
  if l.id is null then raise exception 'lead not found in this workspace'; end if;
  -- a withdrawal that would store NOTHING durable (no usable address for email, no usable number for sms/phone) is widened to 'all' and logged as such: the person objected, and the
  -- identifier trigger on ws_leads (ffm_lead_identifier_guard) suppresses any identifier that is added to this lead later.
  if (ch = 'email' and public.normalize_addr(l.email) is null) or (ch in ('sms', 'phone') and public.normalize_phone(l.phone) is null) then
    src := left('no usable identifier for ' || ch || ': ' || src, 300); ch := 'all';
  end if;
  insert into public.ffm_consent_log (workspace_id, lead_id, channel, basis, wording_version, source, captured_at, evidence_ref, recorded_by)
    values (p_ws, p_lead, ch, 'withdrawn', null, src, clock_timestamp(), nullif(btrim(p_evidence_ref), ''), coalesce(nullif(btrim(p_by), ''), 'unknown')) returning id into v_id;
  if ch in ('email', 'all') then
    insert into public.contact_suppressions (address, reason, recorded_by, source_lead)
      select public.normalize_addr(email), 'ffm consent withdrawn', coalesce(nullif(btrim(p_by), ''), 'unknown'), null from public.ws_leads where id = p_lead and public.normalize_addr(email) is not null
      on conflict do nothing;   -- a withdrawal follows the ADDRESS, not only the lead id: a re-added duplicate lead is still refused ('suppressed')
  end if;
  if ch in ('sms', 'phone', 'all') then
    insert into public.ffm_phone_suppressions (phone, reason, recorded_by, source_lead)
      select public.normalize_phone(phone), 'ffm consent withdrawn (' || p_channel || ')', coalesce(nullif(btrim(p_by), ''), 'unknown'), null from public.ws_leads where id = p_lead and public.normalize_phone(phone) is not null
      on conflict do nothing;   -- the same for the NUMBER, in any written format; a number-based withdrawal blocks every phone-based channel (sms and voice)
  end if;
  insert into public.audit_log (actor, action, target, detail) values ('ffm', 'ffm_consent_withdrawn', 'workspace/' || p_ws, jsonb_build_object('lead', p_lead, 'channel', p_channel, 'recorded_as', ch, 'consent', v_id));
  return v_id;
end $$;

-- 10b. an identifier added or changed on a lead that has WITHDRAWN is suppressed at once (v3). Without this, withdraw-then-add-email on a lead with no address stored nothing durable.
-- A withdrawal on 'email' covers the address; on 'sms'/'phone' the number; on 'all' both. Runs as the table owner (security definer) so a plain lead edit cannot skip it.
create or replace function public.ffm_lead_identifier_guard() returns trigger
language plpgsql security definer set search_path to 'public' as $$
declare a text; ph text;
begin
  if tg_op = 'UPDATE' and new.email is not distinct from old.email and new.phone is not distinct from old.phone then return new; end if;
  a := public.normalize_addr(new.email); ph := public.normalize_phone(new.phone);
  if a is not null and exists (select 1 from public.ffm_consent_log where lead_id = new.id and basis = 'withdrawn' and channel in ('email', 'all')) then
    insert into public.contact_suppressions (address, reason, recorded_by, source_lead) values (a, 'ffm consent withdrawn (identifier added later)', 'ffm', null) on conflict do nothing;
  end if;
  if ph is not null and exists (select 1 from public.ffm_consent_log where lead_id = new.id and basis = 'withdrawn' and channel in ('sms', 'phone', 'all')) then
    insert into public.ffm_phone_suppressions (phone, reason, recorded_by, source_lead) values (ph, 'ffm consent withdrawn (identifier added later)', 'ffm', null) on conflict do nothing;
  end if;
  return new;
end $$;
drop trigger if exists ws_leads_identifier_guard on public.ws_leads;
create trigger ws_leads_identifier_guard after insert or update of email, phone on public.ws_leads for each row execute function public.ffm_lead_identifier_guard();

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
  -- an unknown, differently-cased or NULL channel is a "no" (fail closed). The five channels are exactly outbox_channel_check in production (read-only check Nov 15 2026): email, text, call, post, telegram.
  -- post and telegram have no address list to consult (a postal address or a chat handle is not on contact_suppressions), so for them the gate and the lead flag are the whole check.
  -- v3: the CHANNEL comes first. outbox_channel_check still allows post and telegram, but they have no durable suppression identifier, so they are refused whatever the gate says.
  if p_channel is null then return 'unknown_channel'; end if;
  if public.outreach_channel_problem(p_channel) is not null then return public.outreach_channel_problem(p_channel); end if;
  if p_channel not in ('email', 'text', 'call') then return 'unknown_channel'; end if;      -- the outbox vocabulary; sms / phone are the consent log's names for text / call
  if public.outreach_channel_disabled(p_channel) is not null then return 'channel_disabled'; end if;
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
  -- v3: a person-directed telegram / post / whatsapp / unknown-channel row cannot be created, approved, claimed or sent AT ALL (not even as a draft): there is no durable suppression identifier.
  -- (A row that already exists and changes nothing that decides who is contacted returned above; moving it to rejected is not guarded.)
  if new.channel in ('sms', 'phone') then      -- explicit: these are the consent log's names, not outbox channels (the outbox vocabulary is text / call); never rely on the CHECK constraint to keep them out
    raise exception 'Channel prohibited (invalid_outbox_channel): % is not an outbox channel; use text or call, which are disabled until the owner enables them.', new.channel;
  end if;
  if public.outreach_channel_disabled(new.channel) is not null then
    raise exception 'Channel prohibited (channel_disabled): % outreach is disabled until the owner enables it (ffm_set_phone_outreach). No draft, approval, claim or send is allowed.', new.channel;
  end if;
  if public.outreach_channel_problem(new.channel) is not null then
    raise exception 'Channel prohibited (%): no person-directed outreach on %. There is no durable suppression identifier for it, so no draft, approval, claim or send is allowed.', public.outreach_channel_problem(new.channel), coalesce(new.channel, 'NULL') using errcode = 'P0001';
  end if;
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
revoke all on function public.ffm_epoch_guard() from public, anon, authenticated;
revoke all on function public.ffm_epoch_bump() from public, anon, authenticated;
revoke all on function public.ffm_instance_fp() from public, anon, authenticated;
revoke all on function public.ffm_gate_core_ok() from public, anon, authenticated;
revoke all on function public.outreach_channel_disabled(text) from public, anon, authenticated;
revoke all on function public.ffm_set_phone_outreach(boolean, text) from public, anon, authenticated;
revoke all on function public.ffm_owner_record_restore(text) from public, anon, authenticated;
revoke all on function public.ffm_lead_identifier_guard() from public, anon, authenticated;
revoke all on function public.ffm_gate_state() from public, anon, authenticated;
revoke all on function public.ffm_sender_attest(bigint, bigint, text) from public, anon, authenticated;
revoke all on function public.ffm_set_gate_config(integer, integer, text) from public, anon, authenticated;
revoke all on function public.outreach_channel_problem(text) from public, anon, authenticated;
revoke all on function public.ffm_route_preview(uuid, uuid) from public, anon, authenticated;
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
grant execute on function public.ffm_instance_fp() to service_role;
grant execute on function public.ffm_gate_core_ok() to service_role;
grant execute on function public.outreach_channel_disabled(text) to service_role;
grant execute on function public.ffm_set_phone_outreach(boolean, text) to service_role;
grant execute on function public.ffm_owner_record_restore(text) to service_role;
grant execute on function public.ffm_lead_identifier_guard() to service_role;
grant execute on function public.ffm_gate_state() to service_role;
grant execute on function public.ffm_sender_attest(bigint, bigint, text) to service_role;
grant execute on function public.ffm_set_gate_config(integer, integer, text) to service_role;
grant execute on function public.outreach_channel_problem(text) to service_role;
grant execute on function public.ffm_route_preview(uuid, uuid) to service_role;

-- 13. app_owners (review finding 3). In production service_role could INSERT into app_owners and so mint an owner (is_app_owner() trusts that table). Verified read-only on Nov 15 2026:
-- service_role holds every privilege, anon/authenticated none, RLS on with no policy, no trigger, and NO code in this repository writes it (owners are added by hand in the SQL editor,
-- which runs as postgres and is unaffected). The bot only reads it (hq_backup). So the writes are taken away; select stays.
revoke insert, update, delete, truncate, references, trigger on public.app_owners from public, anon, authenticated, service_role;
revoke all on public.app_owners from anon, authenticated;
grant select on public.app_owners to service_role;
