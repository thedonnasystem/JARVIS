-- SQL-level checks for migrations/20261121_consent_evidence_v1.sql and 20261121_suppression_integrity_v1.sql (Priority 2: consent and suppression integrity).
-- SCRATCH replica only. ONE transaction, rolled back. Run from the repo root (it \copy's sqltests/data/phone_cases.tsv).
--   P  phone normalisation (one shared table, also run through the Python mirror by test_hq_consent.py) and the keyed-hash primitives
--   E  verifiable express-consent evidence: the bot cannot mint valid consent; unverified evidence is recorded as 'unverified' and ffm_can_contact stays false
--   S  phone suppression: withdrawal / erasure / re-import / duplicate lead / format variants / email variants
--   G  the outreach gate and the hashed suppression export: fresh DB denies; restore into an empty DB then re-contact is refused; verified checkpoint allows only after owner
--      verification; tampered / partial / wrong-key / altered-staging lists are refused; list shrinkage after verification closes the gate
--   N  nothing here authorizes or performs outreach
begin;
grant usage on schema public to anon, authenticated, service_role;
create temporary table phone_cases (input text, expected text);
\copy phone_cases from 'sqltests/data/phone_cases.tsv'

create function pg_temp.as_owner(p boolean) returns void language plpgsql as $$
begin
  if p then perform set_config('app.uid', '99999999-9999-9999-9999-999999999993', true); else perform set_config('app.uid', '', true); end if;
end $$;
-- run a statement as the bot's database role; returns 'OK:<text result>' or 'ERR:<message>'
create function pg_temp.svc(p_sql text) returns text language plpgsql as $$
declare r text;
begin
  set local role service_role;
  begin execute p_sql into r; exception when others then reset role; return 'ERR:' || sqlerrm; end;
  reset role;
  return 'OK:' || coalesce(r, '');
end $$;
create function pg_temp.expect_fail(p_sql text, p_pat text) returns void language plpgsql as $$
begin
  begin execute p_sql; exception when others then
    if sqlerrm like p_pat then return; end if;
    raise exception 'wrong error for [%]: got [%], wanted like [%]', left(p_sql, 200), sqlerrm, p_pat;
  end;
  raise exception 'NOT REFUSED: %', left(p_sql, 200);
end $$;
-- fixture helpers (superuser, triggers off): a clean key/gate state for each scenario
create function pg_temp.reset_gate() returns void language plpgsql as $$
begin
  set local session_replication_role = replica;
  delete from public.ffm_secrets; delete from public.ffm_suppression_hashes; delete from public.ffm_suppression_expected;
  update public.ffm_outreach_gate set state = 'unverified', reason = 'fresh database: the suppression list has not been verified', expected_count = null, expected_hash = null,
         expected_key_check = null, expected_staged_at = null, verified_raw_count = null, verified_at = null, verified_by = null where id = 1;
  set local session_replication_role = origin;
end $$;

do $$
declare
  K1 constant text := encode(sha256(convert_to('fixture-capture-key', 'UTF8')), 'hex');   -- derived at run time: no key-shaped literal in the repository
  K2 constant text := encode(sha256(convert_to('fixture-suppression-key', 'UTF8')), 'hex');
  K3 constant text := encode(sha256(convert_to('fixture-other-key', 'UTF8')), 'hex');
  a uuid; b uuid; l1 uuid; l2 uuid; l3 uuid; l4 uuid; l5 uuid; l6 uuid; l7 uuid; lb uuid; cap uuid; cid uuid; r text; j jsonb; e jsonb; e2 jsonb; n int; i int; t text; f text; x record;
  at timestamptz := '2026-11-01 12:00:00+00'; seal text; canon text; m jsonb; o uuid;
begin
  insert into auth.users (id, email) values ('99999999-9999-9999-9999-999999999993', 'ci-owner@example.com');
  insert into public.app_owners (email) values ('ci-owner@example.com');
  perform pg_temp.as_owner(false);
  perform pg_temp.reset_gate();

  -- ===== P: primitives =====
  if public.ffm_hmac_sha256('Jefe', 'what do ya want for nothing?') <> '5bdcc146bf60754e6a042426089575c75a003f089d2739839dec58b964ec3843' then raise exception 'P1 hmac RFC 4231 vector'; end if;
  if public.ffm_hmac_sha256(repeat('a', 100), 'long key message') <> '6fcbe469471764df18dbd2533610a340b4fa93abfcd975b046bd991b7293e347' then raise exception 'P2 hmac with a key longer than the block'; end if;
  if public.ffm_hmac_sha256(null, 'x') is not null then raise exception 'P3 null key'; end if;
  for x in select input, expected from phone_cases loop
    if public.normalize_phone(x.input) is distinct from x.expected then raise exception 'P4 normalize_phone(%) = %, expected %', x.input, public.normalize_phone(x.input), x.expected; end if;
    if public.normalize_phone(public.normalize_phone(x.input)) is distinct from public.normalize_phone(x.input) then raise exception 'P5 normalize_phone not idempotent for %', x.input; end if;
  end loop;
  if (select count(*) from phone_cases) < 40 then raise exception 'P6 phone case table not loaded'; end if;
  if public.normalize_phone(null) is not null then raise exception 'P7 null'; end if;
  if public.normalize_phone('613' || chr(8203) || '-555-0101' || chr(8206)) <> '+16135550101' then raise exception 'P8 invisible characters'; end if;

  -- ===== structure and grants =====
  foreach t in array array['ffm_secrets', 'ffm_consent_wordings', 'ffm_consent_captures', 'ffm_phone_suppressions', 'ffm_suppression_hashes', 'ffm_suppression_expected', 'ffm_outreach_gate'] loop
    if not (select relrowsecurity from pg_class where oid = ('public.' || t)::regclass) then raise exception 'G1 RLS off on %', t; end if;
    foreach f in array array['anon', 'authenticated'] loop
      if has_table_privilege(f, 'public.' || t, 'select') or has_table_privilege(f, 'public.' || t, 'insert') then raise exception 'G2 % has access to %', f, t; end if;
    end loop;
    foreach f in array array['insert', 'update', 'delete', 'truncate', 'trigger', 'references'] loop
      if has_table_privilege('service_role', 'public.' || t, f) then raise exception 'G3 service_role can % %', f, t; end if;
    end loop;
  end loop;
  foreach t in array array['ffm_secrets', 'ffm_suppression_hashes', 'ffm_suppression_expected'] loop
    if has_table_privilege('service_role', 'public.' || t, 'select') then raise exception 'G4 service_role can READ %', t; end if;   -- keys, and hash material, are not readable by the bot
  end loop;
  if exists (select 1 from pg_proc where pronamespace = 'public'::regnamespace and proname in ('ffm_secret', 'ffm_get_key', 'get_secret')) then raise exception 'G5 a function that hands out a key exists'; end if;
  for x in select p.oid::regprocedure::text as sig, p.oid, pg_get_functiondef(p.oid) as def from pg_proc p where p.pronamespace = 'public'::regnamespace
              and p.proname in ('ffm_hmac_sha256', 'normalize_phone', 'ffm_append_only', 'ffm_capture_immutable', 'ffm_contact_mac', 'ffm_set_key', 'ffm_key_fingerprint', 'ffm_register_wording',
                                'ffm_capture_canonical', 'ffm_ingest_capture', 'ffm_register_capture_owner', 'ffm_record_consent', 'ffm_gate_no_delete', 'ffm_lp', 'ffm_cc_len', 'ffm_key_problem', 'ffm_sup_message', 'outreach_send_allowed', 'outreach_recipient_problem', 'is_suppressed',
                                'ffm_is_phone_suppressed', 'ffm_outreach_gate_open', 'ffm_outreach_gate_status', 'ffm_close_outreach_gate', 'ffm_suppression_set', 'ffm_suppression_digest',
                                'backup_suppression_export', 'ffm_stage_suppression_checkpoint', 'ffm_import_suppression_hashes', 'ffm_verify_suppression', 'ffm_contact_status', 'ffm_can_contact',
                                'ffm_withdraw_consent', 'ffm_erase_lead', 'outbox_dnc_guard') loop
    foreach f in array array['anon', 'authenticated'] loop
      if has_function_privilege(f, x.oid, 'execute') then raise exception 'G6 % can execute %', f, x.sig; end if;
    end loop;
    if not has_function_privilege('service_role', x.oid, 'execute') then raise exception 'G7 service_role cannot execute %', x.sig; end if;
  end loop;
  -- the bot cannot write the secrets, captures, hashes or the gate directly, and cannot read the keys
  if pg_temp.svc($q$select value from public.ffm_secrets limit 1$q$) not like 'ERR:permission denied%' then raise exception 'G9 bot can read keys'; end if;
  if pg_temp.svc($q$insert into public.ffm_consent_captures (workspace_id, capture_ref, channel, wording_version, wording_sha256, artifact_sha256, captured_at, contact_mac, registered_via, registered_by) values (gen_random_uuid(), 'x-1-1', 'email', 'v1', repeat('a', 64), repeat('a', 64), now(), repeat('a', 64), 'form_ingest', 'bot')$q$) not like 'ERR:permission denied%' then raise exception 'G10 bot can insert captures'; end if;
  if pg_temp.svc($q$update public.ffm_outreach_gate set state = 'verified'$q$) not like 'ERR:permission denied%' then raise exception 'G11 bot can open the gate directly'; end if;
  if pg_temp.svc($q$insert into public.ffm_suppression_hashes (kind, mac, source) values ('email', repeat('a', 64), 'restore_import')$q$) not like 'ERR:permission denied%' then raise exception 'G12 bot can write hashes'; end if;
  if pg_temp.svc($q$insert into public.ffm_phone_suppressions (phone, reason, recorded_by) values ('+16135550199', 'x', 'bot')$q$) not like 'ERR:permission denied%' then raise exception 'G12b bot can write the phone list directly'; end if;
  -- classification: client_pii / never exported, by NAME RULE (so a later replacement of backup_classification() cannot re-expose them)
  j := public.backup_export_policy();
  foreach t in array array['ffm_secrets', 'ffm_consent_wordings', 'ffm_consent_captures', 'ffm_phone_suppressions', 'ffm_suppression_hashes', 'ffm_suppression_expected', 'ffm_outreach_gate', 'contact_suppressions'] loop
    if j -> 'exported' @> to_jsonb(t) then raise exception 'G13 % is exported off-site', t; end if;
    if not exists (select 1 from jsonb_array_elements(j -> 'excluded') ex where ex ->> 'table' = t and ex ->> 'class' = 'client_pii') then raise exception 'G14 % is not excluded as client_pii', t; end if;
  end loop;
  if jsonb_array_length(j -> 'unclassified') <> 0 then raise exception 'G15 unclassified tables: %', j -> 'unclassified'; end if;

  -- ===== workspaces and leads =====
  insert into public.client_workspaces (slug, name, vertical) values ('ci-mortgage', 'Integrity Test Mortgage', 'mortgage') returning id into a;
  insert into public.client_workspaces (slug, name, vertical) values ('ci-insurance', 'Integrity Test Insurance', 'insurance') returning id into b;
  l1 := public.ws_add_lead(a, null, 'Lead Alice', 'Alice@Example.com', '613-555-0101', 'web form');
  l2 := public.ws_add_lead(a, null, 'Lead Bob', 'bob@example.com', '(613) 555-0202', 'web form');
  lb := public.ws_add_lead(b, null, 'Lead Other', 'alice@example.com', '613-555-0101', 'web form');   -- same person in another workspace

  -- ===== E: evidence =====
  -- E0 the gate is closed on a fresh database, even before any consent exists
  if public.ffm_outreach_gate_open() then raise exception 'E0 gate open on a fresh database'; end if;
  perform pg_temp.as_owner(true);
  perform pg_temp.expect_fail(format($q$select public.ffm_register_capture_owner(%L,'form-abc-001','email','v1',repeat('a',64),now(),%L,null,'owner')$q$, a, l1), 'capture refused: the wording version is not registered%');
  perform public.ffm_register_wording(a, 'v1', repeat('b', 64), 'owner');
  perform public.ffm_register_wording(b, 'v1', repeat('b', 64), 'owner');
  perform pg_temp.as_owner(false);
  -- E1 the bot cannot register a wording, a capture (owner path), or set a key
  if pg_temp.svc(format($q$select public.ffm_register_wording(%L, 'v2', repeat('c', 64), 'bot')::text$q$, a)) not like 'ERR:owner approval required%' then raise exception 'E1 bot registered a wording'; end if;
  if pg_temp.svc(format($q$select public.ffm_register_capture_owner(%L,'form-bot-1','email','v1',repeat('a',64),now(),%L,null,'bot')::text$q$, a, l1)) not like 'ERR:owner approval required%' then raise exception 'E1b bot used the owner capture path'; end if;
  if pg_temp.svc($q$select public.ffm_set_key('capture_signing_key', 'bot-chosen-key-0123456789abcdef0123456789abcdef', 'bot')::text$q$) not like 'ERR:owner approval required%' then raise exception 'E1c bot set a key'; end if;
  -- E2 THE BOT ASSERTS AN EVIDENCE STRING: recorded as 'unverified', never as express; ffm_can_contact stays false (gate fixture open so the evidence rule is what is tested)
  set local session_replication_role = replica;
  insert into public.ffm_secrets (name, value, set_by) values ('suppression_hmac_key', K2, 'fixture');
  update public.ffm_outreach_gate set state = 'verified', verified_raw_count = 0, reason = 'test fixture', verified_at = clock_timestamp(), verified_epoch = 1, verified_marker_id = (select coalesce(max(id),0) from public.ffm_restore_markers), instance_fp = public.ffm_instance_fp(), attested_at = clock_timestamp() where id = 1;
  update public.ffm_gate_config set phone_outreach_enabled = true;     -- text / call are disabled by default (v3 review F1); the checks below exercise them, so enable them in this scratch transaction
  set local session_replication_role = origin;
  r := pg_temp.svc(format($q$select public.ffm_record_consent(%L,%L,'email','express','v1','web form',now(),'form-abc-001','bot')::text$q$, a, l1));
  if r not like 'OK:%' then raise exception 'E2 recording an unverified claim should be accepted as a record, got %', r; end if;
  cid := substr(r, 4)::uuid;
  if (select basis from public.ffm_consent_log where id = cid) <> 'unverified' or (select verification from public.ffm_consent_log where id = cid) <> 'no_capture' then raise exception 'E2b not recorded as unverified/no_capture'; end if;
  if (select capture_id from public.ffm_consent_log where id = cid) is not null then raise exception 'E2c capture attached to an unverified row'; end if;
  if public.ffm_can_contact(l1, 'email') then raise exception 'E3 bot-asserted evidence made the lead contactable'; end if;
  if public.ffm_contact_status(l1, 'email') ->> 'reason' <> 'evidence_unverified' then raise exception 'E3b reason %', public.ffm_contact_status(l1, 'email'); end if;
  -- E4 a direct insert of an express row without a capture is impossible whatever function writes it
  perform pg_temp.expect_fail(format($q$insert into public.ffm_consent_log (workspace_id, lead_id, channel, basis, wording_version, source, captured_at, recorded_by) values (%L,%L,'email','express','v1','web form',now(),'bot')$q$, a, l1), '%ffm_consent_log_express_needs_capture%');
  perform pg_temp.expect_fail(format($q$insert into public.ffm_consent_log (workspace_id, lead_id, channel, basis, wording_version, source, captured_at, recorded_by, capture_id) values (%L,%L,'email','unverified','v1','web form',now(),'bot',gen_random_uuid())$q$, a, l1), '%violates%');
  -- E5 form-ingest path: refused without the key, with a wrong seal, an altered field, an unregistered wording, a wrong wording hash, a bad contact, the wrong channel
  canon := public.ffm_capture_canonical(a, 'form-abc-001', 'email', 'v1', repeat('b', 64), at, 'Alice@Example.com', repeat('a', 64));
  if pg_temp.svc(format($q$select public.ffm_ingest_capture(%L,'form-abc-001','email','v1',%L,%L,'Alice@Example.com',%L,%L)::text$q$, a, repeat('b', 64), at, repeat('a', 64), repeat('0', 64))) not like 'ERR:capture refused: the capture signing key has not been set%' then raise exception 'E5 ingest without a key'; end if;
  perform pg_temp.as_owner(true);
  perform pg_temp.expect_fail($q$select public.ffm_set_key('capture_signing_key', 'short', 'owner')$q$, 'key refused%');
  perform pg_temp.expect_fail($q$select public.ffm_set_key('capture_signing_key', repeat('a', 40), 'owner')$q$, 'key refused%');
  perform pg_temp.expect_fail($q$select public.ffm_set_key('other_key', 'capture-key-0123456789abcdef0123456789abcdef', 'owner')$q$, 'unknown key name%');
  if public.ffm_set_key('capture_signing_key', K1, 'owner') <> '463f3361eb18a7c3ba64af73e7d03c4032bdd9ab4a5f58579212a34baa147b1d' then raise exception 'E5b key fingerprint differs from the Python value'; end if;
  perform pg_temp.expect_fail(format($q$select public.ffm_set_key('capture_signing_key', %L, 'owner')$q$, K3), 'key refused: capture_signing_key is already set%');
  perform pg_temp.as_owner(false);
  if exists (select 1 from public.audit_log where action = 'ffm_key_set' and detail::text like '%' || substr(K1, 1, 20) || '%') then raise exception 'E5c key value in the audit log'; end if;
  perform pg_temp.expect_fail($q$update public.ffm_secrets set value = repeat('z', 40)$q$, 'This record set is append-only%');
  perform pg_temp.expect_fail($q$delete from public.ffm_secrets where name = 'capture_signing_key'$q$, 'This record set is append-only%');
  if public.ffm_key_fingerprint('capture_signing_key') <> '463f3361eb18a7c3ba64af73e7d03c4032bdd9ab4a5f58579212a34baa147b1d' then raise exception 'E5d fingerprint'; end if;
  seal := public.ffm_hmac_sha256(K1, canon);
  -- (the Python seal in this constant was computed for workspace 11111111-2222-3333-4444-555555555555; here the workspace differs, so also compare the canonical text shape)
  if canon !~ '^cap\|v1\|36:[0-9a-f-]{36}12:form-abc-0015:email2:v164:b{64}10:179353440017:Alice@Example.com64:a{64}$' then raise exception 'E6b canonical text %', canon; end if;
  canon := public.ffm_capture_canonical('11111111-2222-3333-4444-555555555555', 'form-abc-001', 'email', 'v1', repeat('b', 64), at, 'Alice@Example.com', repeat('a', 64));
  if public.ffm_hmac_sha256(K1, canon) <> 'e448ddc5532c39f7dc2ee7714767002c7ba4fc31d175e9df71aed4de32093dec' then raise exception 'E6c SQL seal differs from the Python seal'; end if;
  seal := public.ffm_hmac_sha256(K1, public.ffm_capture_canonical(a, 'form-abc-001', 'email', 'v1', repeat('b', 64), at, 'Alice@Example.com', repeat('a', 64)));
  -- forged / altered
  if pg_temp.svc(format($q$select public.ffm_ingest_capture(%L,'form-abc-001','email','v1',%L,%L,'Alice@Example.com',%L,%L)::text$q$, a, repeat('b', 64), at, repeat('a', 64), repeat('0', 64))) not like 'ERR:capture refused: the seal does not match%' then raise exception 'E7 forged seal accepted'; end if;
  if pg_temp.svc(format($q$select public.ffm_ingest_capture(%L,'form-abc-001','email','v1',%L,%L,'mallory@example.com',%L,%L)::text$q$, a, repeat('b', 64), at, repeat('a', 64), seal)) not like 'ERR:capture refused: the seal does not match%' then raise exception 'E7b altered contact accepted'; end if;
  if pg_temp.svc(format($q$select public.ffm_ingest_capture(%L,'form-abc-002','email','v1',%L,%L,'Alice@Example.com',%L,%L)::text$q$, a, repeat('b', 64), at, repeat('a', 64), seal)) not like 'ERR:capture refused: the seal does not match%' then raise exception 'E7c altered ref accepted'; end if;
  if pg_temp.svc(format($q$select public.ffm_ingest_capture(%L,'form-abc-001','email','v1',%L,%L,'Alice@Example.com',%L,%L)::text$q$, b, repeat('b', 64), at, repeat('a', 64), seal)) not like 'ERR:capture refused: the seal does not match%' then raise exception 'E7d seal replayed in another workspace'; end if;
  if pg_temp.svc(format($q$select public.ffm_ingest_capture(%L,'form-abc-001','email','v1',%L,%L,'Alice@Example.com',%L,%L)::text$q$, a, repeat('b', 64), at + interval '1 second', repeat('a', 64), seal)) not like 'ERR:capture refused: the seal does not match%' then raise exception 'E7e altered time accepted'; end if;
  if pg_temp.svc(format($q$select public.ffm_ingest_capture(%L,'form-abc-001','email','v1',%L,%L,'Alice@Example.com',%L,%L)::text$q$, a, repeat('b', 64), at, repeat('d', 64), seal)) not like 'ERR:capture refused: the seal does not match%' then raise exception 'E7f altered artifact hash accepted'; end if;
  -- valid seal, wrong wording hash / unregistered wording
  canon := public.ffm_hmac_sha256(K1, public.ffm_capture_canonical(a, 'form-w-001', 'email', 'v1', repeat('e', 64), at, 'Alice@Example.com', repeat('a', 64)));
  if pg_temp.svc(format($q$select public.ffm_ingest_capture(%L,'form-w-001','email','v1',%L,%L,'Alice@Example.com',%L,%L)::text$q$, a, repeat('e', 64), at, repeat('a', 64), canon)) not like 'ERR:capture refused: the wording version is not registered%' then raise exception 'E8 wrong wording hash accepted'; end if;
  canon := public.ffm_hmac_sha256(K1, public.ffm_capture_canonical(a, 'form-w-002', 'email', 'v9', repeat('b', 64), at, 'Alice@Example.com', repeat('a', 64)));
  if pg_temp.svc(format($q$select public.ffm_ingest_capture(%L,'form-w-002','email','v9',%L,%L,'Alice@Example.com',%L,%L)::text$q$, a, repeat('b', 64), at, repeat('a', 64), canon)) not like 'ERR:capture refused: the wording version is not registered%' then raise exception 'E8b unregistered wording accepted'; end if;
  canon := public.ffm_hmac_sha256(K1, public.ffm_capture_canonical(a, 'form-w-003', 'email', 'v1', repeat('b', 64), at, 'not an address', repeat('a', 64)));
  if pg_temp.svc(format($q$select public.ffm_ingest_capture(%L,'form-w-003','email','v1',%L,%L,'not an address',%L,%L)::text$q$, a, repeat('b', 64), at, repeat('a', 64), canon)) not like 'ERR:capture refused: the contact is not one clean%' then raise exception 'E8c bad contact accepted'; end if;
  canon := public.ffm_hmac_sha256(K1, public.ffm_capture_canonical(a, 'form-w-004', 'mail', 'v1', repeat('b', 64), at, 'x', repeat('a', 64)));
  if pg_temp.svc(format($q$select public.ffm_ingest_capture(%L,'form-w-004','mail','v1',%L,%L,'x',%L,%L)::text$q$, a, repeat('b', 64), at, repeat('a', 64), canon)) not like 'ERR:capture refused: form ingest handles email, sms and phone only%' then raise exception 'E8d mail via ingest'; end if;
  -- E9 the genuine ingest (the form endpoint holds the key; the bot's database role may CALL the function but cannot produce the seal)
  r := pg_temp.svc(format($q$select public.ffm_ingest_capture(%L,'form-abc-001','email','v1',%L,%L,'Alice@Example.com',%L,%L)::text$q$, a, repeat('b', 64), at, repeat('a', 64), seal));
  if r not like 'OK:%' then raise exception 'E9 genuine capture refused: %', r; end if;
  cap := substr(r, 4)::uuid;
  if (select contact_mac from public.ffm_consent_captures where id = cap) <> 'cc176de0c0adc3013d93060a5d24064136f5dae6fd10be28b6c63aa773d768a0' then raise exception 'E9b contact mac differs from the Python value'; end if;
  if exists (select 1 from public.ffm_consent_captures where id = cap and (to_jsonb(ffm_consent_captures)::text ~* 'alice|example\.com')) then raise exception 'E9c the contact itself is stored in the capture'; end if;
  if pg_temp.svc(format($q$select public.ffm_ingest_capture(%L,'form-abc-001','email','v1',%L,%L,'Alice@Example.com',%L,%L)::text$q$, a, repeat('b', 64), at, repeat('a', 64), seal)) not like 'ERR:duplicate key%' then raise exception 'E9d a capture ref registered twice'; end if;
  -- E10 matching consent is recorded express and honoured (the bot cites the capture ref; it matters that the capture matches channel, wording and contact)
  r := pg_temp.svc(format($q$select public.ffm_record_consent(%L,%L,'email','express','v1','web form',now(),'form-abc-001','bot')::text$q$, a, l1));
  cid := substr(r, 4)::uuid;
  if (select basis from public.ffm_consent_log where id = cid) <> 'express' or (select capture_id from public.ffm_consent_log where id = cid) <> cap then raise exception 'E10 not recorded express with its capture: %', r; end if;
  if (select captured_at from public.ffm_consent_log where id = cid) <> at then raise exception 'E10b captured_at must come from the capture, not from the caller'; end if;
  if not public.ffm_can_contact(l1, 'email') then raise exception 'E10c verified express consent not honoured: %', public.ffm_contact_status(l1, 'email'); end if;
  if public.ffm_can_contact(l1, 'sms') then raise exception 'E10d leaked to sms'; end if;
  -- E11 the same capture does not validate other leads, channels, wordings, or other workspaces
  if public.ffm_contact_status(l2, 'email') ->> 'reason' <> 'no_consent' then raise exception 'E11 setup'; end if;
  r := pg_temp.svc(format($q$select public.ffm_record_consent(%L,%L,'email','express','v1','web form',now(),'form-abc-001','bot')::text$q$, a, l2));
  if (select verification from public.ffm_consent_log where id = substr(r, 4)::uuid) <> 'contact_mismatch' or public.ffm_can_contact(l2, 'email') then raise exception 'E11a capture reused for another person'; end if;
  r := pg_temp.svc(format($q$select public.ffm_record_consent(%L,%L,'sms','express','v1','web form',now(),'form-abc-001','bot')::text$q$, a, l1));
  if (select verification from public.ffm_consent_log where id = substr(r, 4)::uuid) <> 'channel_mismatch' or public.ffm_can_contact(l1, 'sms') then raise exception 'E11b capture reused for another channel'; end if;
  r := pg_temp.svc(format($q$select public.ffm_record_consent(%L,%L,'email','express','v2','web form',now(),'form-abc-001','bot')::text$q$, a, l1));
  if (select verification from public.ffm_consent_log where id = substr(r, 4)::uuid) <> 'wording_mismatch' then raise exception 'E11c capture reused for another wording'; end if;
  r := pg_temp.svc(format($q$select public.ffm_record_consent(%L,%L,'email','express','v1','web form',now(),'form-abc-001','bot')::text$q$, b, lb));
  if (select verification from public.ffm_consent_log where id = substr(r, 4)::uuid) <> 'no_capture' or public.ffm_can_contact(lb, 'email') then raise exception 'E11d capture of workspace A used in workspace B'; end if;
  -- E12 owner-attested capture bound to a lead (the only way to evidence a mail consent); the owner path is the only one that can do this
  perform pg_temp.as_owner(true);
  perform pg_temp.expect_fail(format($q$select public.ffm_register_capture_owner(%L,'paper-001','mail','v1',repeat('a',64),now(),null,null,'owner')$q$, a), 'capture refused: give the contact or the lead%');
  perform pg_temp.expect_fail(format($q$select public.ffm_register_capture_owner(%L,'paper-001','mail','v1',repeat('a',64),now(),null,'x','owner')$q$, a), 'capture refused: a mail capture binds to a lead id%');
  perform pg_temp.expect_fail(format($q$select public.ffm_register_capture_owner(%L,'paper 001','mail','v1',repeat('a',64),now(),%L,null,'owner')$q$, a, l2), '%capture_ref_check%');   -- the ref pattern forbids spaces and free text
  perform pg_temp.expect_fail(format($q$select public.ffm_register_capture_owner(%L,'jane@example.com','mail','v1',repeat('a',64),now(),%L,null,'owner')$q$, a, l2), '%capture_ref_check%');   -- ... and an address
  perform public.ffm_register_capture_owner(a, 'paper-001', 'mail', 'v1', repeat('a', 64), now() - interval '3 days', l2, null, 'owner');
  perform pg_temp.as_owner(false);
  r := pg_temp.svc(format($q$select public.ffm_record_consent(%L,%L,'mail','express','v1','paper form',now(),'paper-001','bot')::text$q$, a, l2));
  -- v3: the consent is recorded (the owner attested it) but 'mail' (post) has no durable suppression identifier, so it never lets anyone be contacted
  if public.ffm_can_contact(l2, 'mail') then raise exception 'E12 owner-attested mail consent allowed outreach on a prohibited channel'; end if;
  if public.ffm_contact_status(l2, 'mail') ->> 'reason' is distinct from 'channel_prohibited' then raise exception 'E12 mail reason %', public.ffm_contact_status(l2, 'mail'); end if;
  r := pg_temp.svc(format($q$select public.ffm_record_consent(%L,%L,'mail','express','v1','paper form',now(),'paper-001','bot')::text$q$, a, l1));
  if public.ffm_can_contact(l1, 'mail') then raise exception 'E12b a lead-bound capture was reused for a different lead'; end if;
  -- E13 captures are immutable
  perform pg_temp.expect_fail(format($q$update public.ffm_consent_captures set channel = 'sms' where id = %L$q$, cap), 'Consent captures are append-only%');
  perform pg_temp.expect_fail(format($q$delete from public.ffm_consent_captures where id = %L$q$, cap), 'Consent captures are append-only%');
  perform pg_temp.expect_fail('truncate public.ffm_consent_captures', '%');   -- refused (by the trigger, or earlier by the foreign key)
  perform pg_temp.expect_fail($q$update public.ffm_consent_wordings set sha256 = repeat('f', 64)$q$, 'This record set is append-only%');
  -- E14 implied consent still owner-only and unaffected
  perform pg_temp.expect_fail(format($q$select public.ffm_record_consent(%L,%L,'email','implied','v1','inquiry',now(),'inquiry-1','bot')$q$, a, l2), 'owner approval required%');

  -- ===== S: phone suppression =====
  -- S1 sms consent via a form capture bound to the lead's number (any written format of the number matches)
  canon := public.ffm_hmac_sha256(K1, public.ffm_capture_canonical(a, 'form-sms-001', 'sms', 'v1', repeat('b', 64), at, '+1 613 555 0101', repeat('a', 64)));
  perform pg_temp.svc(format($q$select public.ffm_ingest_capture(%L,'form-sms-001','sms','v1',%L,%L,'+1 613 555 0101',%L,%L)::text$q$, a, repeat('b', 64), at, repeat('a', 64), canon));
  perform pg_temp.svc(format($q$select public.ffm_record_consent(%L,%L,'sms','express','v1','web form',now(),'form-sms-001','bot')::text$q$, a, l1));
  if not public.ffm_can_contact(l1, 'sms') then raise exception 'S1 sms consent via capture not honoured: %', public.ffm_contact_status(l1, 'sms'); end if;
  -- S2 email withdrawal leaves the phone alone; the lead can still be texted
  perform public.ffm_withdraw_consent(a, l1, 'email', 'reply STOP', 'msg-1', 'bot');
  if public.ffm_can_contact(l1, 'email') then raise exception 'S2 email withdrawn but allowed'; end if;
  if not public.ffm_can_contact(l1, 'sms') then raise exception 'S2b an email withdrawal removed sms'; end if;
  if exists (select 1 from public.ffm_phone_suppressions) then raise exception 'S2c an email withdrawal suppressed the phone'; end if;
  -- S3 sms withdrawal suppresses the NUMBER (normalised), phone as well as sms
  perform public.ffm_withdraw_consent(a, l1, 'sms', 'reply STOP', 'msg-2', 'bot');
  if (select count(*) from public.ffm_phone_suppressions where phone = '+16135550101') <> 1 then raise exception 'S3 phone not suppressed'; end if;
  if public.ffm_can_contact(l1, 'sms') or public.ffm_can_contact(l1, 'phone') then raise exception 'S3b suppressed number contactable'; end if;
  -- S4 RE-IMPORT: the same person re-added (new lead id) in several phone formats, with a fresh capture, stays refused on sms and phone
  i := 0;
  foreach t in array array['613.555.0101', '+1 (613) 555-0101', '1-613-555-0101', '٦١٣٥٥٥٠١٠١', '＋１６１３５５５０１０１', '613-555-0101 x44', '(613)5550101'] loop
    i := i + 1;
    l3 := public.ws_add_lead(a, null, 'Alice Again', 'alice.again.' || chr(97 + i) || '@example.com', t, 'import');
    perform pg_temp.as_owner(true);
    perform public.ffm_register_capture_owner(a, 'imp-' || chr(97 + i), 'sms', 'v1', repeat('a', 64), now() - interval '1 hour', l3, null, 'owner');
    perform public.ffm_register_capture_owner(a, 'imq-' || chr(97 + i), 'phone', 'v1', repeat('a', 64), now() - interval '1 hour', l3, null, 'owner');
    perform pg_temp.as_owner(false);
    perform pg_temp.svc(format($q$select public.ffm_record_consent(%L,%L,'sms','express','v1','web form',now(),%L,'bot')::text$q$, a, l3, 'imp-' || chr(97 + i)));
    perform pg_temp.svc(format($q$select public.ffm_record_consent(%L,%L,'phone','express','v1','web form',now(),%L,'bot')::text$q$, a, l3, 'imq-' || chr(97 + i)));
    if public.ffm_can_contact(l3, 'sms') or public.ffm_can_contact(l3, 'phone') then raise exception 'S4 re-imported number % is contactable', t; end if;
    if public.ffm_contact_status(l3, 'sms') ->> 'reason' <> 'suppressed' then raise exception 'S4b reason % for %', public.ffm_contact_status(l3, 'sms'), t; end if;
  end loop;
  -- ... and a different number is not affected
  l3 := public.ws_add_lead(a, null, 'Carol', 'carol@example.com', '613-555-0303', 'import');
  perform pg_temp.as_owner(true); perform public.ffm_register_capture_owner(a, 'carol-sms-1', 'sms', 'v1', repeat('a', 64), now() - interval '1 hour', l3, null, 'owner'); perform pg_temp.as_owner(false);
  perform pg_temp.svc(format($q$select public.ffm_record_consent(%L,%L,'sms','express','v1','web form',now(),'carol-sms-1','bot')::text$q$, a, l3));
  if not public.ffm_can_contact(l3, 'sms') then raise exception 'S5 an unrelated number is refused'; end if;
  -- S6 a voice-call withdrawal ('phone') also blocks the number for sms; 'all' blocks both address and number; withdrawals are final per lead
  perform public.ffm_withdraw_consent(a, l3, 'phone', 'called back and said stop', null, 'bot');
  if public.ffm_can_contact(l3, 'sms') or public.ffm_can_contact(l3, 'phone') then raise exception 'S6 a phone withdrawal left sms open'; end if;
  l4 := public.ws_add_lead(a, null, 'Dan', 'Dan+news@Example.com', '613 555 0404', 'import');
  perform pg_temp.as_owner(true);
  perform public.ffm_register_capture_owner(a, 'dan-em-1', 'email', 'v1', repeat('a', 64), now() - interval '1 hour', l4, null, 'owner');
  perform public.ffm_register_capture_owner(a, 'dan-sm-1', 'sms', 'v1', repeat('a', 64), now() - interval '1 hour', l4, null, 'owner');
  perform pg_temp.as_owner(false);
  perform pg_temp.svc(format($q$select public.ffm_record_consent(%L,%L,'email','express','v1','web form',now(),'dan-em-1','bot')::text$q$, a, l4));
  perform pg_temp.svc(format($q$select public.ffm_record_consent(%L,%L,'sms','express','v1','web form',now(),'dan-sm-1','bot')::text$q$, a, l4));
  if not (public.ffm_can_contact(l4, 'email') and public.ffm_can_contact(l4, 'sms')) then raise exception 'S7 setup'; end if;
  perform public.ffm_withdraw_consent(a, l4, 'all', 'phone call', null, 'bot');
  if not exists (select 1 from public.contact_suppressions where address = 'dan@example.com') or not exists (select 1 from public.ffm_phone_suppressions where phone = '+16135550404') then raise exception 'S7b withdrawal of all did not suppress both'; end if;
  -- S8 duplicate lead / case / +tag / unicode variants of the EMAIL stay refused; an unusable address is refused (fail closed)
  i := 0;
  foreach t in array array['dan@example.com', 'DAN@EXAMPLE.COM', ' Dan+promo@Example.com ', 'dan+x+y@example.com', 'Dan <dan@example.com>', 'dan@example.com.'] loop
    i := i + 1;
    l5 := public.ws_add_lead(a, null, 'Dan dup', t, null, 'import');
    perform pg_temp.as_owner(true); perform public.ffm_register_capture_owner(a, 'dup-' || chr(97 + i), 'email', 'v1', repeat('a', 64), now() - interval '1 hour', l5, null, 'owner'); perform pg_temp.as_owner(false);
    perform pg_temp.svc(format($q$select public.ffm_record_consent(%L,%L,'email','express','v1','web form',now(),%L,'bot')::text$q$, a, l5, 'dup-' || chr(97 + i)));
    if public.ffm_can_contact(l5, 'email') then raise exception 'S8 variant % is contactable after withdrawal', t; end if;
  end loop;
  i := 10;
  foreach t in array array['dan@exаmple.com', 'ｄａｎ@example.com', 'dan@example.com' || chr(8203), 'dan @example.com'] loop   -- cyrillic a, fullwidth, zero-width, space
    i := i + 1;
    l5 := public.ws_add_lead(a, null, 'Dan odd', t, null, 'import');
    perform pg_temp.as_owner(true); perform public.ffm_register_capture_owner(a, 'odd-' || chr(97 + i), 'email', 'v1', repeat('a', 64), now() - interval '1 hour', l5, null, 'owner'); perform pg_temp.as_owner(false);
    perform pg_temp.svc(format($q$select public.ffm_record_consent(%L,%L,'email','express','v1','web form',now(),%L,'bot')::text$q$, a, l5, 'odd-' || chr(97 + i)));
    if public.ffm_can_contact(l5, 'email') then raise exception 'S9 unusable address % is contactable', t; end if;
    if public.ffm_contact_status(l5, 'email') ->> 'reason' <> 'address_unusable' then raise exception 'S9b reason % for %', public.ffm_contact_status(l5, 'email'), t; end if;
  end loop;
  -- S10 no number / unusable number / no address: refused
  l5 := public.ws_add_lead(a, null, 'No phone', 'nophone@example.com', null, 'import');
  l6 := public.ws_add_lead(a, null, 'Bad phone', 'badphone@example.com', '1-800-FLOWERS', 'import');
  perform pg_temp.as_owner(true);
  perform public.ffm_register_capture_owner(a, 'np-1', 'sms', 'v1', repeat('a', 64), now() - interval '1 hour', l5, null, 'owner');
  perform public.ffm_register_capture_owner(a, 'bp-1', 'sms', 'v1', repeat('a', 64), now() - interval '1 hour', l6, null, 'owner');
  perform pg_temp.as_owner(false);
  perform pg_temp.svc(format($q$select public.ffm_record_consent(%L,%L,'sms','express','v1','web form',now(),'np-1','bot')::text$q$, a, l5));
  perform pg_temp.svc(format($q$select public.ffm_record_consent(%L,%L,'sms','express','v1','web form',now(),'bp-1','bot')::text$q$, a, l6));
  if public.ffm_contact_status(l5, 'sms') ->> 'reason' <> 'no_phone' or public.ffm_contact_status(l6, 'sms') ->> 'reason' <> 'phone_unusable' then raise exception 'S10 reasons % %', public.ffm_contact_status(l5, 'sms'), public.ffm_contact_status(l6, 'sms'); end if;
  -- S11 ERASURE adds the number; re-adding the erased person (any format) stays refused
  l7 := public.ws_add_lead(a, null, 'Erin', 'erin@example.com', '+1 (613) 555-0707', 'import');
  perform pg_temp.as_owner(true); perform public.ffm_register_capture_owner(a, 'erin-sm-1', 'sms', 'v1', repeat('a', 64), now() - interval '1 hour', l7, null, 'owner'); perform pg_temp.as_owner(false);
  perform pg_temp.svc(format($q$select public.ffm_record_consent(%L,%L,'sms','express','v1','web form',now(),'erin-sm-1','bot')::text$q$, a, l7));
  if not public.ffm_can_contact(l7, 'sms') then raise exception 'S11 setup'; end if;
  perform pg_temp.as_owner(true);
  j := public.ffm_erase_lead(a, l7, 'erasure_request');
  perform pg_temp.as_owner(false);
  if not exists (select 1 from public.ffm_phone_suppressions where phone = '+16135550707') then raise exception 'S11b erasure did not suppress the number'; end if;
  if (select contact_mac from public.ffm_consent_captures where capture_ref = 'erin-sm-1') is not null or (select erased_at from public.ffm_consent_captures where capture_ref = 'erin-sm-1') is null then raise exception 'S11c capture not unlinked'; end if;
  if (j ->> 'captures_unlinked')::int < 1 then raise exception 'S11d erasure report %', j; end if;
  l7 := public.ws_add_lead(a, null, 'Erin back', 'erin.back@example.com', '613.555.0707', 'import');
  perform pg_temp.as_owner(true); perform public.ffm_register_capture_owner(a, 'erin-sm-2', 'sms', 'v1', repeat('a', 64), now() - interval '1 hour', l7, null, 'owner'); perform pg_temp.as_owner(false);
  perform pg_temp.svc(format($q$select public.ffm_record_consent(%L,%L,'sms','express','v1','web form',now(),'erin-sm-2','bot')::text$q$, a, l7));
  if public.ffm_can_contact(l7, 'sms') then raise exception 'S11e erased person re-added by number is contactable'; end if;
  -- S12 the phone list is append-only
  perform pg_temp.expect_fail($q$update public.ffm_phone_suppressions set reason = 'x'$q$, 'This record set is append-only%');
  perform pg_temp.expect_fail($q$delete from public.ffm_phone_suppressions$q$, 'This record set is append-only%');
  perform pg_temp.expect_fail('truncate public.ffm_phone_suppressions', 'This record set is append-only%');
  perform pg_temp.expect_fail($q$insert into public.ffm_phone_suppressions (phone, reason, recorded_by) values ('613-555-0101', 'x', 'y')$q$, '%violates check constraint%');   -- only the normalised form may be stored

  -- ===== G: the gate, the keyed-hash export, restore =====
  -- G20 the export carries keyed hashes only
  e := public.backup_suppression_export();
  if (e ->> 'included')::boolean is not true or (e ->> 'count')::int < 4 then raise exception 'G20 export %', left(e::text, 200); end if;
  if e::text ~* '@|example|\+1|613|alice|dan' then raise exception 'G21 plaintext in the suppression export'; end if;
  if (e ->> 'count')::int <> jsonb_array_length(e -> 'macs') or (e ->> 'hash') <> encode(sha256(convert_to((select string_agg((mx ->> 0) || ':' || (mx ->> 1), E'\n' order by ((mx ->> 0) || ':' || (mx ->> 1)) collate "C") from jsonb_array_elements(e -> 'macs') mx), 'UTF8')), 'hex') then raise exception 'G22 export count/hash'; end if;
  if (e -> 'macs') @> jsonb_build_array(jsonb_build_array('email', public.ffm_hmac_sha256(K2, public.ffm_sup_message('email', 'dan@example.com')))) is not true or (e -> 'macs') @> jsonb_build_array(jsonb_build_array('phone', public.ffm_hmac_sha256(K2, public.ffm_sup_message('phone', '+16135550101')))) is not true then raise exception 'G23 expected keyed hashes missing'; end if;
  if (e ->> 'key_check') <> public.ffm_hmac_sha256(K2, 'key|v1|' || public.ffm_lp('suppression_hmac_key')) then raise exception 'G24 key check'; end if;
  -- G25 the bot may fetch the export (needed by the backup job) but nothing that would let it open the gate
  if pg_temp.svc($q$select (public.backup_suppression_export() ->> 'count')$q$) not like 'OK:%' then raise exception 'G25 bot cannot export'; end if;
  foreach t in array array['select public.ffm_verify_suppression(''bot'')::text', 'select public.ffm_import_suppression_hashes()::text', 'select public.ffm_stage_suppression_checkpoint(''{}''::jsonb)::text'] loop
    if pg_temp.svc(t) not like 'ERR:owner approval required%' then raise exception 'G26 bot ran an owner-only gate function: %', t; end if;
  end loop;
  -- G27 no key = no export, no verification
  perform pg_temp.reset_gate();
  if (public.backup_suppression_export() ->> 'included')::boolean is not false then raise exception 'G27 export without a key'; end if;
  -- G28 FRESH DB / key not set / gate closed: nothing is contactable, even a lead with verified consent and no suppression
  l3 := public.ws_add_lead(a, null, 'Fresh', 'fresh@example.com', null, 'import');
  perform pg_temp.as_owner(true); perform public.ffm_register_capture_owner(a, 'fresh-1', 'email', 'v1', repeat('a', 64), now() - interval '1 hour', l3, null, 'owner'); perform pg_temp.as_owner(false);
  perform pg_temp.svc(format($q$select public.ffm_record_consent(%L,%L,'email','express','v1','web form',now(),'fresh-1','bot')::text$q$, a, l3));
  if public.ffm_can_contact(l3, 'email') or public.ffm_contact_status(l3, 'email') ->> 'reason' <> 'suppression_unverified' then raise exception 'G28 contactable while the gate is closed: %', public.ffm_contact_status(l3, 'email'); end if;

  -- G29 the legacy send path is closed too: a draft contacts nobody and is allowed; approval and send are refused while the gate is closed
  insert into public.outbox (agent, channel, to_ref, body, status) values ('donna-ops', 'email', 'gate-test@example.com', 'x unsubscribe', 'draft') returning id into o;
  update public.outbox set status = 'qa_passed', qa_agent = 'ceo' where id = o;
  perform pg_temp.expect_fail(format($q$update public.outbox set status = 'approved' where id = %L$q$, o), 'Outreach gate closed%');

  -- G30 the live database: the owner sets the suppression key, stages the export of the LIVE list as the checkpoint, verifies; only then does anything open
  perform pg_temp.as_owner(true);
  perform pg_temp.expect_fail($q$select public.ffm_stage_suppression_checkpoint('{}'::jsonb)$q$, 'checkpoint refused: set the suppression key first%');
  j := public.ffm_verify_suppression('owner');
  if (j ->> 'verified')::boolean or j ->> 'reason' not like 'no checkpoint is staged%' then raise exception 'G30 verify without a checkpoint %', j; end if;
  perform public.ffm_set_key('suppression_hmac_key', K2, 'owner');
  e := public.backup_suppression_export();
  if (e ->> 'included')::boolean is not true then raise exception 'G30b export'; end if;
  n := (e ->> 'count')::int;
  j := public.ffm_verify_suppression('owner');
  if (j ->> 'verified')::boolean then raise exception 'G30c verified with no checkpoint staged'; end if;
  perform public.ffm_stage_suppression_checkpoint(e);
  if public.ffm_outreach_gate_open() then raise exception 'G31 staging a checkpoint opened the gate'; end if;
  j := public.ffm_verify_suppression('owner');
  perform pg_temp.as_owner(false);
  if (j ->> 'verified')::boolean is not true or j ->> 'mode' <> 'exact' then raise exception 'G32 verification of the live list failed: %', j; end if;
  if not public.ffm_outreach_gate_open() or not public.ffm_can_contact(l3, 'email') then raise exception 'G33 gate not open after verification: %', public.ffm_contact_status(l3, 'email'); end if;
  -- G34 legacy approval now passes the gate (and is still subject to every other rule)
  update public.outbox set status = 'approved' where id = o;
  -- G35 a new suppression after verification keeps the gate open (the list only grows); the digest follows
  perform public.ffm_withdraw_consent(a, l3, 'email', 'late STOP', null, 'bot');
  if not public.ffm_outreach_gate_open() then raise exception 'G35 a normal withdrawal closed the gate'; end if;
  if (public.ffm_suppression_digest() ->> 'count')::int <> n + 1 then raise exception 'G35b digest did not grow'; end if;
  -- G36 the bot may CLOSE the gate (only reduces what is allowed) but never open it
  if pg_temp.svc($q$select public.ffm_close_outreach_gate('suspicious activity', 'bot')::text$q$) not like 'OK:%' then raise exception 'G36 bot cannot close the gate'; end if;
  if public.ffm_outreach_gate_open() or public.ffm_can_contact(l1, 'sms') then raise exception 'G36b gate still open after closing'; end if;
  perform pg_temp.expect_fail(format($q$update public.outbox set status = 'sent', sent_by = 'owner' where id = %L$q$, o), '%');   -- closed again: no send (other rules also apply)
  perform pg_temp.expect_fail($q$delete from public.ffm_outreach_gate$q$, 'The outreach gate row cannot be deleted%');
  perform pg_temp.expect_fail($q$truncate public.ffm_outreach_gate$q$, 'The outreach gate row cannot be deleted%');
  perform pg_temp.as_owner(true); j := public.ffm_verify_suppression('owner'); perform pg_temp.as_owner(false);   -- the staged checkpoint is still valid: a superset of it is live
  if (j ->> 'verified')::boolean is not true or j ->> 'mode' <> 'superset' then raise exception 'G36c re-verification %', j; end if;

  -- G40 RESTORE INTO AN EMPTY DATABASE: the plaintext lists, the key, the hashes and the gate state are gone (client_pii and ffm_* never travel in the off-site file)
  set local session_replication_role = replica;
  delete from public.contact_suppressions; delete from public.ffm_phone_suppressions;
  set local session_replication_role = origin;
  perform pg_temp.reset_gate();
  if public.ffm_outreach_gate_open() then raise exception 'G40 gate open after a restore'; end if;
  -- G41 attempted re-contact is refused: the lead that had verified consent, a re-added duplicate of a withdrawn person (email and phone variants)
  if public.ffm_can_contact(l3, 'email') or public.ffm_can_contact(l4, 'email') or public.ffm_can_contact(l4, 'sms') or public.ffm_can_contact(l1, 'sms') then raise exception 'G41 re-contact allowed after a restore'; end if;
  if public.ffm_contact_status(l3, 'email') ->> 'reason' <> 'suppression_unverified' then raise exception 'G41b reason'; end if;
  l5 := public.ws_add_lead(a, null, 'Dan after restore', 'DAN+again@example.com', '(613) 555-0404', 'import');
  perform pg_temp.as_owner(true); perform public.ffm_register_capture_owner(a, 'dan-after-1', 'email', 'v1', repeat('a', 64), now() - interval '1 hour', l5, null, 'owner');
  perform public.ffm_register_capture_owner(a, 'dan-after-2', 'sms', 'v1', repeat('a', 64), now() - interval '1 hour', l5, null, 'owner'); perform pg_temp.as_owner(false);
  perform pg_temp.svc(format($q$select public.ffm_record_consent(%L,%L,'email','express','v1','web form',now(),'dan-after-1','bot')::text$q$, a, l5));
  perform pg_temp.svc(format($q$select public.ffm_record_consent(%L,%L,'sms','express','v1','web form',now(),'dan-after-2','bot')::text$q$, a, l5));
  if public.ffm_can_contact(l5, 'email') or public.ffm_can_contact(l5, 'sms') then raise exception 'G41c suppressed person contactable on the restored database'; end if;
  -- G42 the owner cannot verify without the key / a checkpoint; a WRONG key is detected before anything is staged
  perform pg_temp.as_owner(true);
  j := public.ffm_verify_suppression('owner');
  if (j ->> 'verified')::boolean or j ->> 'reason' not like 'no checkpoint is staged%' then raise exception 'G42 %', j; end if;
  perform public.ffm_set_key('suppression_hmac_key', K3, 'owner');
  perform pg_temp.expect_fail(format($q$select public.ffm_stage_suppression_checkpoint(%L::jsonb)$q$, e::text), 'checkpoint refused: the export was made with a different suppression key%');
  perform pg_temp.as_owner(false);
  perform pg_temp.reset_gate();
  perform pg_temp.as_owner(true);
  perform public.ffm_set_key('suppression_hmac_key', K2, 'owner');
  -- G43 TAMPERED / PARTIAL checkpoints are refused at staging
  m := e;
  perform pg_temp.expect_fail(format($q$select public.ffm_stage_suppression_checkpoint(%L::jsonb)$q$, (m #- '{macs,0}')::text), 'checkpoint refused: the list does not match its own count/hash%');                    -- an entry removed
  perform pg_temp.expect_fail(format($q$select public.ffm_stage_suppression_checkpoint(%L::jsonb)$q$, jsonb_set(m, '{macs,0,1}', to_jsonb(repeat('0', 64)))::text), 'checkpoint refused: the list does not match%');   -- an entry altered
  perform pg_temp.expect_fail(format($q$select public.ffm_stage_suppression_checkpoint(%L::jsonb)$q$, jsonb_set(m, '{macs}', (m -> 'macs') || jsonb_build_array(m -> 'macs' -> 0))::text), 'checkpoint refused: duplicate entry%');
  perform pg_temp.expect_fail(format($q$select public.ffm_stage_suppression_checkpoint(%L::jsonb)$q$, jsonb_set(m, '{count}', to_jsonb(n + 5))::text), 'checkpoint refused: the list does not match%');
  perform pg_temp.expect_fail(format($q$select public.ffm_stage_suppression_checkpoint(%L::jsonb)$q$, jsonb_set(m, '{hash}', to_jsonb(repeat('1', 64)))::text), 'checkpoint refused: the list does not match%');
  perform pg_temp.expect_fail(format($q$select public.ffm_stage_suppression_checkpoint(%L::jsonb)$q$, jsonb_set(m, '{version}', '2')::text), 'checkpoint refused: not a suppression export%');
  perform pg_temp.expect_fail(format($q$select public.ffm_stage_suppression_checkpoint(%L::jsonb)$q$, jsonb_set(m, '{included}', 'false')::text), 'checkpoint refused: not a suppression export%');
  perform pg_temp.expect_fail(format($q$select public.ffm_stage_suppression_checkpoint(%L::jsonb)$q$, jsonb_set(m, '{macs,0,0}', '"sms"')::text), 'checkpoint refused: malformed entry%');
  perform pg_temp.expect_fail(format($q$select public.ffm_stage_suppression_checkpoint(%L::jsonb)$q$, jsonb_set(m, '{macs,0,1}', '"XYZ"')::text), 'checkpoint refused: malformed entry%');
  perform pg_temp.expect_fail($q$select public.ffm_stage_suppression_checkpoint('null'::jsonb)$q$, 'checkpoint refused%');
  if public.ffm_outreach_gate_open() or (select expected_hash from public.ffm_outreach_gate) is not null then raise exception 'G43z a refused checkpoint left state behind'; end if;
  -- G44 the genuine checkpoint stages; the lists are EMPTY (restored DB), so verification is INCOMPLETE and refused: nothing opens, nothing is contactable
  perform public.ffm_stage_suppression_checkpoint(e);
  j := public.ffm_verify_suppression('owner');
  perform pg_temp.as_owner(false);
  if (j ->> 'verified')::boolean or j ->> 'reason' not like 'incomplete: ' || n || ' of ' || n || '%' then raise exception 'G44 empty list verified or wrong reason: %', j; end if;
  if public.ffm_outreach_gate_open() or public.ffm_can_contact(l3, 'email') then raise exception 'G44b gate open after a failed verification'; end if;
  -- G45 re-establish the list from the hashes (no addresses needed), verify again: now allowed, and hash-only suppressions are honoured
  perform pg_temp.as_owner(true);
  if public.ffm_import_suppression_hashes() <> n then raise exception 'G45 import count'; end if;
  j := public.ffm_verify_suppression('owner');
  perform pg_temp.as_owner(false);
  if (j ->> 'verified')::boolean is not true or j ->> 'mode' <> 'exact' then raise exception 'G45b verification after import %', j; end if;
  if not public.ffm_outreach_gate_open() then raise exception 'G45c gate closed after a good verification'; end if;
  if not public.ffm_can_contact(l3, 'email') is false then null; end if;
  if public.ffm_can_contact(l5, 'email') or public.ffm_can_contact(l5, 'sms') then raise exception 'G46 hash-only suppression not honoured (email or phone variant)'; end if;
  if public.ffm_contact_status(l5, 'email') ->> 'reason' <> 'suppressed' or public.ffm_contact_status(l5, 'sms') ->> 'reason' <> 'suppressed' then raise exception 'G46b reason'; end if;
  if not public.is_suppressed('Dan+x@EXAMPLE.com') or public.is_suppressed('someone.else@example.com') then raise exception 'G46c is_suppressed on hashes'; end if;
  if not public.ffm_is_phone_suppressed('+1 613-555-0404') or public.ffm_is_phone_suppressed('613-555-9999') then raise exception 'G46d phone hash'; end if;
  l6 := public.ws_add_lead(a, null, 'Fine Person', 'fine.person@example.com', null, 'import');
  perform pg_temp.as_owner(true); perform public.ffm_register_capture_owner(a, 'fine-1', 'email', 'v1', repeat('a', 64), now() - interval '1 hour', l6, null, 'owner'); perform pg_temp.as_owner(false);
  perform pg_temp.svc(format($q$select public.ffm_record_consent(%L,%L,'email','express','v1','web form',now(),'fine-1','bot')::text$q$, a, l6));
  if not public.ffm_can_contact(l6, 'email') then raise exception 'G46e an unsuppressed, consented lead is refused after verification'; end if;
  -- the legacy outbox honours hash-only suppressions too
  perform pg_temp.expect_fail($q$insert into public.outbox (agent, channel, to_ref, body, status) values ('donna-ops', 'email', 'Dan+z@example.com', 'x unsubscribe', 'draft')$q$, 'Do-not-contact%');
  -- G47 shrinkage after verification closes the gate (rows removed underneath the append-only triggers)
  set local session_replication_role = replica; delete from public.ffm_suppression_hashes where kind = 'phone'; set local session_replication_role = origin;
  if public.ffm_outreach_gate_open() or public.ffm_can_contact(l6, 'email') then raise exception 'G47 gate stayed open after the list shrank'; end if;
  -- G48 PARTIAL live list: checkpoint staged, one hash missing -> verification refused with the exact count
  perform pg_temp.as_owner(true);
  j := public.ffm_verify_suppression('owner');
  perform pg_temp.as_owner(false);
  if (j ->> 'verified')::boolean or j ->> 'reason' not like 'incomplete: %' then raise exception 'G48 partial list verified: %', j; end if;
  -- G49 the staged checkpoint itself altered after staging
  perform pg_temp.as_owner(true); perform public.ffm_import_suppression_hashes();
  j := public.ffm_verify_suppression('owner');
  if (j ->> 'verified')::boolean is not true then raise exception 'G49 setup: %', j; end if;
  set local session_replication_role = replica; delete from public.ffm_suppression_expected where ctid = (select ctid from public.ffm_suppression_expected limit 1); set local session_replication_role = origin;
  j := public.ffm_verify_suppression('owner');
  perform pg_temp.as_owner(false);
  if (j ->> 'verified')::boolean or j ->> 'reason' not like 'the staged checkpoint was altered after staging%' or public.ffm_outreach_gate_open() then raise exception 'G49b altered staging accepted: %', j; end if;
  -- G50 a different key at verification time (key replaced underneath) is detected
  set local session_replication_role = replica; delete from public.ffm_secrets; insert into public.ffm_secrets (name, value, set_by) values ('suppression_hmac_key', K3, 'fixture'); set local session_replication_role = origin;
  perform pg_temp.as_owner(true); j := public.ffm_verify_suppression('owner'); perform pg_temp.as_owner(false);
  if (j ->> 'verified')::boolean or j ->> 'reason' not like 'the suppression key differs%' then raise exception 'G50 key swap accepted: %', j; end if;

  -- ===== N: nothing here authorizes or performs outreach =====
  if exists (select 1 from information_schema.columns where table_schema = 'public' and table_name in ('ffm_secrets', 'ffm_consent_wordings', 'ffm_consent_captures', 'ffm_phone_suppressions', 'ffm_suppression_hashes',
                'ffm_suppression_expected', 'ffm_outreach_gate') and column_name ~ '(sent|deliver|send)') then raise exception 'N1 sending state in the new tables'; end if;
  if exists (select 1 from public.outbox where status = 'sent') then raise exception 'N2 something was sent'; end if;
  if exists (select 1 from pg_proc where pronamespace = 'public'::regnamespace and proname in ('ffm_send', 'ffm_dispatch', 'ffm_open_gate', 'ffm_force_verify')) then raise exception 'N3 a send/open helper exists'; end if;
  foreach t in array array['ffm_ad_sets', 'ffm_creatives', 'ffm_routing_rules', 'ffm_route_log'] loop
    if not exists (select 1 from pg_constraint where conrelid = ('public.' || t)::regclass and contype = 'c' and pg_get_constraintdef(oid) ~ '^CHECK \(?dry_run\)?$') then raise exception 'N4 dry_run CHECK gone from %', t; end if;
  end loop;
  raise notice 'consent_integrity_check: all passed';
end $$;
rollback;
