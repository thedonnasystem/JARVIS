-- Regression tests for the independent review of PR #15 (consent + suppression integrity). SCRATCH replica only. Run from the repo root (it \copy's sqltests/data/*.tsv).
-- One block per finding, each in its own transaction that is rolled back, so that against the OLD code every block reports its OWN failure (run with ON_ERROR_STOP off to see them all).
-- Every block raises 'Fn ...' on failure; with the fixes applied nothing is raised.
--   F1  HMAC oracle / key reuse / forged capture      F2  outreach path ignores the gate     F3  app_owners writable by service_role
--   F4  phone trunk-prefix variants + fail closed + 6,000-case differential corpus      F6  key handling (64 hex only, shared vectors)
--   F5b fractional-second capture time (floor, like Python)      F7  unknown / NULL outbox channel fails closed
-- (F5, the restore tool, is tested in test_restore_backup.py.)
grant usage on schema public to anon, authenticated, service_role;
create temporary table if not exists phone_cases (input text, expected text);
create temporary table if not exists key_cases (value_spec text, other_spec text, expected text);
create temporary table if not exists phone_fuzz (input text, expected text);
truncate phone_cases; truncate key_cases; truncate phone_fuzz;
\copy phone_cases from 'sqltests/data/phone_cases.tsv'
\copy key_cases from 'sqltests/data/key_cases.tsv'
\copy phone_fuzz from 'sqltests/data/phone_fuzz.tsv'

create or replace function pg_temp.as_owner(p boolean) returns void language plpgsql as $$
begin
  if p then perform set_config('app.uid', '99999999-9999-9999-9999-999999999993', true); else perform set_config('app.uid', '', true); end if;
end $$;
create or replace function pg_temp.svc(p_sql text) returns text language plpgsql as $$
declare r text;
begin
  set local role service_role;
  begin execute p_sql into r; exception when others then reset role; return 'ERR:' || sqlerrm; end;
  reset role;
  return 'OK:' || coalesce(r, '');
end $$;
create or replace function pg_temp.expect_fail(p_sql text, p_pat text) returns void language plpgsql as $$
begin
  begin execute p_sql; exception when others then
    if sqlerrm like p_pat then return; end if;
    raise exception 'wrong error for [%]: got [%], wanted like [%]', left(p_sql, 200), sqlerrm, p_pat;
  end;
  raise exception 'NOT REFUSED: %', left(p_sql, 200);
end $$;
create or replace function pg_temp.mk_owner() returns void language plpgsql as $$
begin
  insert into auth.users (id, email) values ('99999999-9999-9999-9999-999999999993', 'ci-owner@example.com') on conflict do nothing;
  insert into public.app_owners (email) values ('ci-owner@example.com') on conflict do nothing;
end $$;
-- fixture: suppression key K set directly and the gate verified (the evidence / outbox rules are what is tested, not the verification flow)
create or replace function pg_temp.open_gate(p_supp_key text, p_capture_key text default null) returns void language plpgsql as $$
begin
  set local session_replication_role = replica;
  delete from public.ffm_secrets; delete from public.ffm_suppression_hashes; delete from public.ffm_suppression_expected;
  insert into public.ffm_secrets (name, value, set_by) values ('suppression_hmac_key', p_supp_key, 'fixture');
  if p_capture_key is not null then insert into public.ffm_secrets (name, value, set_by) values ('capture_signing_key', p_capture_key, 'fixture'); end if;
  update public.ffm_outreach_gate set state = 'verified', reason = 'test fixture', verified_raw_count = 0, verified_at = clock_timestamp(), verified_epoch = 1, instance_fp = public.ffm_instance_fp(), attested_at = clock_timestamp() where id = 1;
  set local session_replication_role = origin;
end $$;
create or replace function pg_temp.close_gate() returns void language plpgsql as $$
begin
  set local session_replication_role = replica;
  update public.ffm_outreach_gate set state = 'unverified', reason = 'test fixture closed', verified_raw_count = null, verified_at = null where id = 1;
  set local session_replication_role = origin;
end $$;
create or replace function pg_temp.key(p text) returns text language sql as $$ select encode(sha256(convert_to(p, 'UTF8')), 'hex') $$;

-- ===================================================== F1: oracle, key reuse, forged capture =====================================================
begin;
do $$
declare
  KS constant text := encode(sha256(convert_to('fixture-one-key-for-both', 'UTF8')), 'hex');
  KC constant text := encode(sha256(convert_to('fixture-capture-key', 'UTF8')), 'hex');
  KP constant text := encode(sha256(convert_to('fixture-suppression-key', 'UTF8')), 'hex');
  w uuid; l uuid; at timestamptz := '2026-11-01 12:00:00+00'; asha text := repeat('a', 64); wsha text := repeat('b', 64);
  r text; seal text; scen text; kind text; norm text; forged boolean; n int; ref text := 'forged:ref1'; late text := '';   -- findings reported at the END of the block, so a failure here does not hide the attack test below
begin
  insert into public.client_workspaces (slug, name, vertical) values ('rf-1', 'Review Fix 1', 'mortgage') returning id into w;
  perform pg_temp.mk_owner(); perform pg_temp.as_owner(true);
  perform public.ffm_register_wording(w, 'v1', wsha, 'owner');
  perform pg_temp.as_owner(false);
  l := public.ws_add_lead(w, null, 'Victim', 'victim@example.com', null, 'import');

  -- F1a the owner cannot set the SAME value for both keys, nor a weak or related one
  perform pg_temp.as_owner(true);
  perform public.ffm_set_key('capture_signing_key', KS, 'owner');
  begin
    perform public.ffm_set_key('suppression_hmac_key', KS, 'owner');
    late := late || ' F1a(same value for both keys accepted)';
  exception when others then null; end;
  begin
    perform public.ffm_set_key('suppression_hmac_key', 'x' || KS, 'owner');
    late := late || ' F1a2(a key containing the other accepted)';
  exception when others then null; end;
  perform pg_temp.as_owner(false);

  -- F1b THE REVIEWER'S ATTACK, with identical keys (a misconfigured database) and with distinct keys. The attacker is service_role: it asks every HMAC oracle it can reach for a seal over the
  -- canonical capture text, splitting that text at ':' (old scheme: oracle message = kind || ':' || norm, canonical = 'ffm-capture-v1|ws|ref|...'), then registers the capture and records consent.
  foreach scen in array array['identical', 'distinct'] loop
    perform pg_temp.open_gate(case when scen = 'identical' then KS else KP end, case when scen = 'identical' then KS else KC end);
    seal := null;
    -- the old oracle (public.ffm_suppression_mac) and, defensively, any twin of it that is callable by the bot
    kind := 'ffm-capture-v1|' || w::text || '|forged';
    norm := 'ref1|email|v1|' || wsha || '|1793534400|victim@example.com|' || asha;
    r := pg_temp.svc(format($q$select public.ffm_suppression_mac(%L, %L)$q$, kind, norm));
    if r like 'OK:%' then seal := substr(r, 4); end if;
    if seal is not null then
      -- (old code only) the seal is valid for capture_ref 'forged:ref1' when the two keys are equal
      r := pg_temp.svc(format($q$select public.ffm_ingest_capture(%L,%L,'email','v1',%L,%L,'victim@example.com',%L,%L)::text$q$, w, ref, wsha, at, asha, seal));
    end if;
    select count(*) into n from public.ffm_consent_captures where capture_ref = ref;
    if n > 0 or seal is not null then
      raise exception 'F1b [%] service_role obtained a seal from an HMAC oracle (%) and forged capture % (captures=%)', scen, left(coalesce(seal, ''), 8), ref, n;
    end if;
    -- and the oracle does not exist at all, under any name: no public function takes (kind, value) and returns a keyed hash of the STORED key
    if exists (select 1 from pg_proc where pronamespace = 'public'::regnamespace and (proname ~* 'suppression_mac|sup_mac|sign|seal' or proname = 'ffm_suppression_mac')) then raise exception 'F1b2 [%] a mac/seal oracle function exists', scen; end if;
    if exists (select 1 from pg_proc p where p.pronamespace = 'public'::regnamespace and has_function_privilege('service_role', p.oid, 'execute') and pg_get_functiondef(p.oid) ~* 'ffm_secrets'
               and p.proname not in ('ffm_set_key', 'ffm_key_fingerprint', 'ffm_ingest_capture', 'ffm_register_capture_owner', 'ffm_record_consent', 'ffm_erase_lead', 'is_suppressed', 'ffm_is_phone_suppressed',
                                     'ffm_outreach_gate_open', 'ffm_outreach_gate_status', 'ffm_suppression_set', 'ffm_suppression_digest', 'backup_suppression_export', 'ffm_stage_suppression_checkpoint',
                                     'ffm_import_suppression_hashes', 'ffm_verify_suppression', 'ffm_contact_status', 'ffm_can_contact', 'ffm_withdraw_consent', 'outreach_recipient_problem')) then
      raise exception 'F1b3 [%] an unexpected service_role-callable function reads the stored keys: %', scen, (select string_agg(proname, ',') from pg_proc where pronamespace = 'public'::regnamespace and pg_get_functiondef(oid) ~* 'ffm_secrets');
    end if;
    -- even a CORRECTLY SEALED capture cannot carry a ':' or '|' in capture_ref (the canonical text could be re-split)
    seal := public.ffm_hmac_sha256(case when scen = 'identical' then KS else KC end,
                                   public.ffm_capture_canonical(w, ref, 'email', 'v1', wsha, at, 'victim@example.com', asha));
    r := pg_temp.svc(format($q$select public.ffm_ingest_capture(%L,%L,'email','v1',%L,%L,'victim@example.com',%L,%L)::text$q$, w, ref, wsha, at, asha, seal));
    if r not like 'ERR:capture refused%' then raise exception 'F1c [%] a capture_ref containing a colon was accepted: %', scen, r; end if;
    r := pg_temp.svc(format($q$select public.ffm_ingest_capture(%L,%L,'email','v1',%L,%L,'victim@example.com',%L,%L)::text$q$, w, 'a|b-1', wsha, at, asha, seal));
    if r not like 'ERR:capture refused%' then raise exception 'F1c2 [%] a capture_ref containing a bar was accepted: %', scen, r; end if;
    -- consent for the victim must stay unverified / not contactable
    r := pg_temp.svc(format($q$select public.ffm_record_consent(%L,%L,'email','express','v1','web form',now(),%L,'bot')::text$q$, w, l, ref));
    if public.ffm_can_contact(l, 'email') then raise exception 'F1d [%] the forged consent made the victim contactable', scen; end if;
  end loop;

  -- F1e domain separation + length prefixes: the same fields can never give the same message in two domains, and moving a separator between fields changes the message
  if public.ffm_contact_mac(KC, 'email', 'a@b.co') = public.ffm_hmac_sha256(KC, public.ffm_sup_message('email', 'a@b.co')) then raise exception 'F1e contact and suppression domains collide'; end if;
  if public.ffm_capture_canonical(w, 'ab-1', 'email', 'c', wsha, at, 'x', asha) = public.ffm_capture_canonical(w, 'ab-', 'email', '1c', wsha, at, 'x', asha) then raise exception 'F1e canonical text can be re-split'; end if;
  if public.ffm_capture_canonical(w, 'ref-1', 'email', 'v1', wsha, at, 'x', asha) not like 'cap|v1|%' or public.ffm_sup_message('email', 'x') not like 'sup|v1|%' then raise exception 'F1e domain prefixes'; end if;
  if public.ffm_sup_message('a', 'bc') = public.ffm_sup_message('ab', 'c') or public.ffm_sup_message('email:x', 'y') = public.ffm_sup_message('email', 'x:y') then raise exception 'F1e suppression message can be re-split'; end if;

  -- F1f the SECURITY DEFINER lookups still work for the bot with the oracle gone (is_suppressed, phone, gate, contact decision)
  perform pg_temp.open_gate(KP, KC);
  insert into public.contact_suppressions (address, reason, recorded_by) values ('opted@example.com', 'x', 'test');
  if pg_temp.svc($q$select public.is_suppressed('Opted@Example.com')::text$q$) <> 'OK:true' then raise exception 'F1f is_suppressed broken for service_role'; end if;
  insert into public.ffm_suppression_hashes (kind, mac, source) values ('email', public.ffm_hmac_sha256(KP, public.ffm_sup_message('email', 'hashonly@example.com')), 'restore_import');
  if pg_temp.svc($q$select public.is_suppressed('hashonly@example.com')::text$q$) <> 'OK:true' then raise exception 'F1f hash-only suppression not honoured for service_role'; end if;
  if pg_temp.svc($q$select public.is_suppressed('clean@example.com')::text$q$) <> 'OK:false' then raise exception 'F1f clean address reported suppressed'; end if;
  if pg_temp.svc($q$select public.ffm_outreach_gate_open()::text$q$) <> 'OK:true' then raise exception 'F1f gate lookup broken for service_role'; end if;
  if late <> '' then raise exception 'F1 FAILED:%', late; end if;
end $$;
rollback;

-- ===================================================== F2: the outreach path honours the gate =====================================================
begin;
do $$
declare
  KP constant text := encode(sha256(convert_to('fixture-suppression-key', 'UTF8')), 'hex');
  KC constant text := encode(sha256(convert_to('fixture-capture-key', 'UTF8')), 'hex');
  v uuid; ld uuid; o uuid; o2 uuid; o3 uuid; o4 uuid; j text; r text; late text := '';
begin
  select id into v from public.ventures limit 1;
  insert into public.leads (venture_id, name, email) values (v, 'Legacy Lead', 'legacy@example.com') returning id into ld;
  perform pg_temp.open_gate(KP, KC);
  insert into public.outbox (agent, channel, to_ref, body, status, lead_id) values ('donna-ops', 'email', 'legacy@example.com', 'x unsubscribe', 'draft', ld) returning id into o;
  update public.outbox set status = 'qa_passed', qa_agent = 'ceo' where id = o;
  update public.outbox set status = 'approved' where id = o;                       -- gate open: approval is fine
  if pg_temp.svc(format($q$select public.outreach_send_allowed(%L)->>'allowed'$q$, o)) <> 'OK:true' then late := late || ' F2a(send_allowed not true with the gate open: ' || pg_temp.svc(format($q$select public.outreach_send_allowed(%L)::text$q$, o)) || ')'; end if;

  -- F2b THE GATE CLOSES AFTER APPROVAL: the CLAIM (hq_mail._claim only PATCHes sent_at on the approved row) must be refused, and so must the RPC
  perform pg_temp.close_gate();
  r := pg_temp.svc(format($q$update public.outbox set sent_at = now() where id = %L and status = 'approved' and sent_at is null returning id::text$q$, o));
  if r not like 'ERR:Outreach gate closed%' then raise exception 'F2b a claim (sent_at) succeeded while the gate was closed: %', r; end if;
  if (select sent_at from public.outbox where id = o) is not null then raise exception 'F2b2 claim stored'; end if;
  if pg_temp.svc(format($q$select public.outreach_send_allowed(%L)->>'allowed'$q$, o)) <> 'OK:false' then late := late || ' F2c'; end if;
  if pg_temp.svc(format($q$select public.outreach_send_allowed(%L)->>'reason'$q$, o)) <> 'OK:suppression_unverified' then late := late || ' F2c2'; end if;
  r := pg_temp.svc(format($q$update public.outbox set status = 'sent', sent_at = now(), sent_by = 'owner' where id = %L returning id::text$q$, o));
  if r not like 'ERR:%' then raise exception 'F2d status->sent with the gate closed: %', r; end if;

  -- F2e releasing a claim is always allowed (a claim made while the gate was open, then the gate closed)
  perform pg_temp.open_gate(KP, KC);
  update public.outbox set sent_at = now() where id = o;
  perform pg_temp.close_gate();
  r := pg_temp.svc(format($q$update public.outbox set sent_at = null where id = %L returning id::text$q$, o));
  if r not like 'OK:%' then raise exception 'F2e releasing a claim was refused: %', r; end if;

  -- F2f HASH-ONLY suppression is honoured by the trigger and the RPC
  perform pg_temp.open_gate(KP, KC);
  insert into public.ffm_suppression_hashes (kind, mac, source) values ('email', public.ffm_hmac_sha256(KP, public.ffm_sup_message('email', 'hashonly@example.com')), 'restore_import');
  set local session_replication_role = replica;   -- an already-approved row whose address was suppressed LATER (only the claim path can catch it)
  insert into public.outbox (agent, channel, to_ref, body, status) values ('donna-ops', 'email', 'hashonly@example.com', 'x unsubscribe', 'approved') returning id into o2;
  set local session_replication_role = origin;
  if pg_temp.svc(format($q$select public.outreach_send_allowed(%L)->>'reason'$q$, o2)) <> 'OK:suppressed' then late := late || ' F2f(send_allowed misses a hash-only suppression)'; end if;
  r := pg_temp.svc(format($q$update public.outbox set sent_at = now() where id = %L returning id::text$q$, o2));
  if r not like 'ERR:Do-not-contact%' then raise exception 'F2f claim of a hash-only suppressed address succeeded: %', r; end if;

  -- F2g PHONE suppression for the text and call channels (plaintext and hash-only, any written format), and an unusable number
  insert into public.ffm_phone_suppressions (phone, reason, recorded_by) values ('+16135550101', 'x', 'test');
  insert into public.ffm_suppression_hashes (kind, mac, source) values ('phone', public.ffm_hmac_sha256(KP, public.ffm_sup_message('phone', '+442079460958')), 'restore_import');
  foreach j in array array['text', 'call'] loop
    r := pg_temp.svc(format($q$insert into public.outbox (agent, channel, to_ref, body, status) values ('donna-ops', %L, '(613) 555-0101', 'x', 'draft') returning id::text$q$, j));
    if r not like 'ERR:Do-not-contact%' then raise exception 'F2g % draft to a suppressed number (plaintext) accepted: %', j, r; end if;
    r := pg_temp.svc(format($q$insert into public.outbox (agent, channel, to_ref, body, status) values ('donna-ops', %L, '+44 (0)20 7946 0958', 'x', 'draft') returning id::text$q$, j));
    if r not like 'ERR:Do-not-contact%' then raise exception 'F2g2 % draft to a hash-only suppressed number (trunk variant) accepted: %', j, r; end if;
    r := pg_temp.svc(format($q$insert into public.outbox (agent, channel, to_ref, body, status) values ('donna-ops', %L, '020 7946 0000', 'x', 'approved') returning id::text$q$, j));
    if r not like 'ERR:%' then raise exception 'F2g3 % approval to an unusable number accepted: %', j, r; end if;
    r := pg_temp.svc(format($q$insert into public.outbox (agent, channel, to_ref, body, status) values ('donna-ops', %L, '+1 613 555 0199', 'x', 'approved') returning id::text$q$, j));
    if r not like 'OK:%' then raise exception 'F2g4 % approval to a clean number refused: %', j, r; end if;
    if pg_temp.svc(format($q$select public.outreach_send_allowed(%L)->>'allowed'$q$, substr(r, 4))) <> 'OK:true' then late := late || ' F2g5'; end if;
  end loop;
  -- F2h the RPC fails closed for an unknown row, a rejected row and a sent row
  if pg_temp.svc($q$select public.outreach_send_allowed(gen_random_uuid())->>'allowed'$q$) <> 'OK:false' then raise exception 'F2h unknown outbox id allowed'; end if;
  insert into public.outbox (agent, channel, to_ref, body, status) values ('donna-ops', 'email', 'rej@example.com', 'x', 'rejected') returning id into o3;
  if pg_temp.svc(format($q$select public.outreach_send_allowed(%L)->>'allowed'$q$, o3)) <> 'OK:false' then raise exception 'F2h rejected row allowed'; end if;
  -- F2i a lead flagged do-not-contact after approval
  update public.leads set do_not_contact = true where id = ld;
  if pg_temp.svc(format($q$select public.outreach_send_allowed(%L)->>'allowed'$q$, o)) <> 'OK:false' then late := late || ' F2i(dnc lead still allowed)'; end if;   -- (the flag cascade may reject the draft first: either way it is a no)
  if late <> '' then raise exception 'F2 FAILED:%', late; end if;
end $$;
rollback;

-- ===================================================== F3: app_owners =====================================================
begin;
do $$
declare r text; f text;
begin
  foreach f in array array['insert', 'update', 'delete', 'truncate', 'references', 'trigger'] loop
    if has_table_privilege('service_role', 'public.app_owners', f) then raise exception 'F3a service_role can % public.app_owners', f; end if;
    if has_table_privilege('anon', 'public.app_owners', f) or has_table_privilege('authenticated', 'public.app_owners', f) then raise exception 'F3b an API role can % app_owners', f; end if;
  end loop;
  if not has_table_privilege('service_role', 'public.app_owners', 'select') then raise exception 'F3c service_role lost SELECT on app_owners (the backup reads it)'; end if;
  r := pg_temp.svc($q$insert into public.app_owners (email) values ('minted@example.com') returning email$q$);
  if r not like 'ERR:permission denied%' then raise exception 'F3d service_role minted an owner: %', r; end if;
  perform pg_temp.mk_owner();   -- the SQL editor / owner-run path (superuser here) still works
  if not exists (select 1 from public.app_owners where email = 'ci-owner@example.com') then raise exception 'F3e owner insert by the table owner broke'; end if;
end $$;
rollback;

-- ===================================================== F4: phone trunk prefix, fail closed =====================================================
begin;
do $$
declare
  KP constant text := encode(sha256(convert_to('fixture-suppression-key', 'UTF8')), 'hex');
  KC constant text := encode(sha256(convert_to('fixture-capture-key', 'UTF8')), 'hex');
  x record; w uuid; l uuid; l2 uuid; r text; n int := 0;
begin
  for x in select input, expected from phone_cases loop
    n := n + 1;
    if public.normalize_phone(x.input) is distinct from x.expected then raise exception 'F4a normalize_phone(%) = %, expected %', x.input, public.normalize_phone(x.input), x.expected; end if;
  end loop;
  if n < 80 then raise exception 'F4a phone case table not loaded (%)', n; end if;
  -- F4a2 re-review item 3 (and 1): the differential corpus, the SAME rows test_hq_consent runs through Python. Column 2 is the Python result.
  n := 0;
  for x in select input, expected from phone_fuzz loop
    n := n + 1;
    if public.normalize_phone(x.input) is distinct from x.expected then raise exception 'F4a2 fuzz case %: normalize_phone(%) = %, python says %', n, quote_literal(x.input), public.normalize_phone(x.input), x.expected; end if;
  end loop;
  if n < 5000 then raise exception 'F4a2 fuzz corpus not loaded (%)', n; end if;
  if public.normalize_phone(E'+44\u202820 7946 0958') is not null or public.normalize_phone(E'+44\u202920 7946 0958') is not null or public.normalize_phone(E'+44\u168020 7946 0958') is not null then raise exception 'F4a3 a Unicode separator was accepted as whitespace'; end if;
  if public.normalize_phone('+44 (0)20 7946 0958') is distinct from public.normalize_phone('+44 20 7946 0958') then raise exception 'F4b UK trunk variants differ'; end if;
  if public.normalize_phone('+20 010 1234 5678') is distinct from public.normalize_phone('+20 10 1234 5678') then raise exception 'F4b Egypt trunk variants differ'; end if;

  -- F4c a withdrawn number's variant is suppressed
  perform pg_temp.open_gate(KP, KC);
  insert into public.client_workspaces (slug, name, vertical) values ('rf-4', 'Review Fix 4', 'mortgage') returning id into w;
  l := public.ws_add_lead(w, null, 'UK Person', 'uk@example.com', '613-555-0111', 'import');   -- (ws_add_lead refuses 13+ digit fields as card-like, so the '(0)' forms are set below with the guard off)
  set local session_replication_role = replica; update public.ws_leads set phone = '+44 (0)20 7946 0958' where id = l; set local session_replication_role = origin;
  perform public.ffm_withdraw_consent(w, l, 'sms', 'STOP', null, 'bot');
  if not public.ffm_is_phone_suppressed('+44 20 7946 0958') then raise exception 'F4c the variant of a withdrawn number is not suppressed'; end if;
  l2 := public.ws_add_lead(w, null, 'UK Person again', 'uk2@example.com', '613-555-0112', 'import');
  set local session_replication_role = replica; update public.ws_leads set phone = '+44 020 7946 0958' where id = l2; set local session_replication_role = origin;
  if public.ffm_can_contact(l2, 'sms') or public.ffm_contact_status(l2, 'sms') ->> 'reason' <> 'suppressed' then raise exception 'F4d a duplicate lead with the trunk variant is contactable: %', public.ffm_contact_status(l2, 'sms'); end if;

  -- F4e NULL (ambiguous) fails closed everywhere: suppressed, not contactable, cannot be recorded as consent
  if public.normalize_phone('+39 (0)6 1234 5678') is not null then raise exception 'F4e setup: ambiguous number normalised'; end if;
  if not public.ffm_is_phone_suppressed('+39 (0)6 1234 5678') then raise exception 'F4e an unusable number was reported NOT suppressed'; end if;
  if not public.is_suppressed('not an address') then raise exception 'F4e an unusable address was reported NOT suppressed'; end if;
  l2 := public.ws_add_lead(w, null, 'Ambiguous', 'amb@example.com', '613-555-0113', 'import');
  set local session_replication_role = replica; update public.ws_leads set phone = '+39 (0)6 1234 5678' where id = l2; set local session_replication_role = origin;
  if public.ffm_can_contact(l2, 'sms') or public.ffm_contact_status(l2, 'sms') ->> 'reason' <> 'phone_unusable' then raise exception 'F4f ambiguous number contactable: %', public.ffm_contact_status(l2, 'sms'); end if;
  perform pg_temp.mk_owner(); perform pg_temp.as_owner(true);
  perform public.ffm_register_wording(w, 'v1', repeat('b', 64), 'owner');
  perform public.ffm_register_capture_owner(w, 'amb-cap-1', 'sms', 'v1', repeat('a', 64), now() - interval '1 hour', l2, null, 'owner');
  perform pg_temp.as_owner(false);
  r := public.ffm_hmac_sha256(KC, public.ffm_capture_canonical(w, 'amb-cap-2', 'sms', 'v1', repeat('b', 64), '2026-11-01 12:00:00+00', '+39 (0)6 1234 5678', repeat('a', 64)));
  r := pg_temp.svc(format($q$select public.ffm_ingest_capture(%L,'amb-cap-2','sms','v1',%L,'2026-11-01 12:00:00+00','+39 (0)6 1234 5678',%L,%L)::text$q$, w, repeat('b', 64), repeat('a', 64), r));
  if r not like 'ERR:capture refused: the contact is not one clean%' then raise exception 'F4g2 a capture for an ambiguous number was registered: %', r; end if;
  perform public.ffm_record_consent(w, l2, 'sms', 'express', 'v1', 'web form', now(), 'amb-cap-1', 'bot');
  if public.ffm_can_contact(l2, 'sms') then raise exception 'F4g consent recorded for an ambiguous number'; end if;
  r := pg_temp.svc($q$select public.ffm_is_phone_suppressed('+39 (0)6 1234 5678')::text$q$);
  if r <> 'OK:true' then raise exception 'F4h service_role view of the ambiguous number: %', r; end if;
end $$;
rollback;

-- ===================================================== F6: key policy, shared vectors =====================================================
-- the spec language (decoded identically by test_hq_consent.key_spec): \N | lit:<text> | sha256:<seed> | mix:<seedA>:<seedB>:<n> | splice:<seed>:<text> | upper:<seed>
create or replace function pg_temp.keyspec(p text) returns text language plpgsql as $$
declare k text := split_part(p, ':', 1); a text := split_part(p, ':', 2); b text := split_part(p, ':', 3); c text := split_part(p, ':', 4); v text;
begin
  if p is null or p = '\N' then return null; end if;
  if k = 'lit' then return substr(p, 5); end if;
  if k = 'sha256' then return pg_temp.key(a); end if;
  if k = 'mix' then return left(pg_temp.key(a), c::int) || left(pg_temp.key(b), 64 - c::int); end if;
  if k = 'splice' then v := pg_temp.key(a); return left(v, 20) || b || substr(v, 21 + length(b)); end if;
  if k = 'upper' then return upper(pg_temp.key(a)); end if;
  raise exception 'bad key spec %', p;
end $$;
begin;
do $$
declare x record; v text; o text; got text; n int := 0;
begin
  for x in select * from key_cases loop
    n := n + 1;
    v := pg_temp.keyspec(x.value_spec);
    o := pg_temp.keyspec(x.other_spec);
    got := coalesce(public.ffm_key_problem(v, o), 'ok');
    if got <> x.expected then raise exception 'F6a key case % (%): got %, expected %', n, left(x.value_spec, 30), got, x.expected; end if;
  end loop;
  if n < 20 then raise exception 'F6a key case table not loaded'; end if;
  -- the owner path refuses a weak key and never echoes the value in the error or the audit log
  perform pg_temp.mk_owner(); perform pg_temp.as_owner(true);
  begin
    perform public.ffm_set_key('capture_signing_key', 'abcdefghijklmnopqrstuvwxyz0123456789', 'owner');
    raise exception 'F6b weak sequential key accepted';
  exception when others then
    if sqlerrm like 'F6b%' then raise; end if;
    if sqlerrm like '%abcdefghij%' then raise exception 'F6c the refusal message echoes the key: %', sqlerrm; end if;
  end;
  begin
    perform public.ffm_set_key('capture_signing_key', 'correct-horse-battery-staple-2024-correct-horse-battery', 'owner');
    raise exception 'F6e a guessable phrase was accepted as a key';
  exception when others then
    if sqlerrm like 'F6e%' then raise; end if;
  end;
  perform public.ffm_set_key('capture_signing_key', encode(sha256(convert_to('fixture-capture-key', 'UTF8')), 'hex'), 'owner');
  if exists (select 1 from public.audit_log where detail::text like '%' || substr(encode(sha256(convert_to('fixture-capture-key', 'UTF8')), 'hex'), 1, 20) || '%') then raise exception 'F6d key in the audit log'; end if;
end $$;
rollback;

-- ===================================================== F5b: fractional-second captured_at =====================================================
begin;
do $$
declare w uuid := gen_random_uuid(); a text; b text;
begin
  a := public.ffm_capture_canonical(w, 'ref-1', 'email', 'v1', repeat('b', 64), '2026-11-01 12:00:00+00', 'c', repeat('a', 64));
  b := public.ffm_capture_canonical(w, 'ref-1', 'email', 'v1', repeat('b', 64), '2026-11-01 12:00:00.75+00', 'c', repeat('a', 64));
  if a <> b then raise exception 'F5b 12:00:00.75 is not 12:00:00 (rounded, not floored): % vs %', a, b; end if;
  b := public.ffm_capture_canonical(w, 'ref-1', 'email', 'v1', repeat('b', 64), '2026-11-01 12:00:00.999999+00', 'c', repeat('a', 64));
  if a <> b then raise exception 'F5b .999999 rounds up: %', b; end if;
  b := public.ffm_capture_canonical(w, 'ref-1', 'email', 'v1', repeat('b', 64), '2026-11-01 11:59:59.999999+00', 'c', repeat('a', 64));
  if a = b then raise exception 'F5b 11:59:59.999999 equals 12:00:00'; end if;
  if a not like '%10:1793534400%' then raise exception 'F5b unexpected epoch in %', a; end if;   -- the value test_hq_consent asserts too
end $$;
rollback;

-- ===================================================== F7: unknown / NULL channel fails closed =====================================================
begin;
do $$
declare KP constant text := encode(sha256(convert_to('fixture-suppression-key', 'UTF8')), 'hex'); ch text; r text;
begin
  perform pg_temp.open_gate(KP);
  foreach ch in array array['sms', 'Email', 'EMAIL', 'whatsapp', '', ' email', 'email ', 'phone'] loop
    r := public.outreach_recipient_problem(ch, 'clean@example.com', null);
    if r is distinct from (case when ch = 'whatsapp' then 'channel_prohibited' else 'unknown_channel' end) then raise exception 'F7a channel % returned % with the gate open', quote_literal(ch), coalesce(r, 'NULL (allowed)'); end if;
  end loop;
  if public.outreach_recipient_problem(null, 'clean@example.com', null) is distinct from 'unknown_channel' then raise exception 'F7b NULL channel allowed'; end if;
  -- the five real channels (outbox_channel_check) are still allowed when the gate is open and the recipient is clean
  if public.outreach_recipient_problem('email', 'clean@example.com', null) is not null then raise exception 'F7c email refused'; end if;
  if public.outreach_recipient_problem('text', '+44 20 7946 0958', null) is not null then raise exception 'F7c text refused'; end if;
  if public.outreach_recipient_problem('call', '+44 20 7946 0958', null) is not null then raise exception 'F7c call refused'; end if;
  -- v3: post and telegram have no durable suppression identifier: refused even with the gate open, and refused (same reason) with it closed
  if public.outreach_recipient_problem('post', '1 Example Street', null) is distinct from 'channel_prohibited' then raise exception 'F7c post allowed'; end if;
  if public.outreach_recipient_problem('telegram', '@handle', null) is distinct from 'channel_prohibited' then raise exception 'F7c telegram allowed'; end if;
  perform pg_temp.close_gate();
  if public.outreach_recipient_problem('post', '1 Example Street', null) is distinct from 'channel_prohibited' then raise exception 'F7d post not refused for its channel with the gate closed'; end if;
end $$;
rollback;
select 'consent_review_fixes_check: done';
