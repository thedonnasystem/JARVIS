-- SQL-level checks for consent integrity v3 (migrations/20261121_suppression_integrity_v1.sql sections 3, 5b, 8b, 9b, 10, 11): CHANNEL PROHIBITION and the RESTORE-CLOSED GATE.
-- SCRATCH replica only. ONE transaction, rolled back. Run from the repo root.
--   A  channel policy: telegram, post/mail, whatsapp, signal, other and unknown channels are refused at every DB gate (outreach_channel_problem, outreach_recipient_problem, outbox_dnc_guard,
--      ffm_contact_status / ffm_can_contact, ffm_route_preview), with the gate OPEN and with it closed, with consent on record, and through every outbox write shape
--   W  which withdrawals propagate (matrix), including withdrawals on channels that have no durable identifier
--   D  the owner directive's scenarios: duplicate lead creation, re-import under a new id, phone normalisation (trunk zero, +1), email change on an existing lead, SMS withdrawal persists
--      after re-add, cross-channel withdrawal, erasure
--   R  restore-closed gate: epoch, instance fingerprint, restore marker, sender attestation freshness, maximum verification age, "old gate OPEN + old checkpoint restored together",
--      restore without verified suppression state, config bounds, nobody but the owner can open it
--   S  service-key powers: every new function called as service_role with hostile arguments (post-lockdown)
-- Each expectation is "expected X, got Y" in the failure message.
begin;
grant usage on schema public to anon, authenticated, service_role;
create function pg_temp.as_owner(p boolean) returns void language plpgsql as $$
begin
  if p then perform set_config('app.uid', '99999999-9999-9999-9999-999999999995', true); else perform set_config('app.uid', '', true); end if;
end $$;
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
create function pg_temp.express(p_ws uuid, p_lead uuid, p_ch text, p_ref text) returns uuid language plpgsql as $$
declare prev text := current_setting('app.uid', true);
begin
  perform pg_temp.as_owner(true);
  if not exists (select 1 from public.ffm_consent_wordings where workspace_id = p_ws and version = 'v1') then perform public.ffm_register_wording(p_ws, 'v1', repeat('b', 64), 'test'); end if;
  perform public.ffm_register_capture_owner(p_ws, p_ref, p_ch, 'v1', repeat('a', 64), now() - interval '2 hours', p_lead, null, 'test');
  perform set_config('app.uid', coalesce(prev, ''), true);
  return public.ffm_record_consent(p_ws, p_lead, p_ch, 'express', 'v1', 'web form', now(), p_ref, 'bot');
end $$;
-- the REAL verification flow: owner sets the key, stages the checkpoint exported from the live list, verifies. (Fixture keys are derived at run time.)
create function pg_temp.verify_gate() returns jsonb language plpgsql as $$
declare j jsonb;
begin
  perform pg_temp.as_owner(true);
  if not exists (select 1 from public.ffm_secrets where name = 'suppression_hmac_key') then
    perform public.ffm_set_key('suppression_hmac_key', encode(sha256(convert_to('v3-fixture-suppression-key-' || clock_timestamp()::text, 'UTF8')), 'hex') || '', 'owner');
  end if;
  perform public.ffm_stage_suppression_checkpoint(public.backup_suppression_export());
  j := public.ffm_verify_suppression('owner');
  perform pg_temp.as_owner(false);
  return j;
end $$;
-- fixture helper: shift stored timestamps back (a superuser edit with triggers off; this is what "time passing" or "an older copy" looks like)
create function pg_temp.age_gate(p_attested interval, p_verified interval default interval '0') returns void language plpgsql as $$
begin
  set local session_replication_role = replica;
  update public.ffm_outreach_gate set attested_at = attested_at - p_attested, verified_at = verified_at - p_verified where id = 1;
  update public.ffm_restore_markers set restored_at = restored_at - p_verified;      -- the whole past moves together (a marker older than the verification stays older)
  set local session_replication_role = origin;
end $$;

do $$
declare
  a uuid; l1 uuid; l2 uuid; l3 uuid; l4 uuid; l5 uuid; l6 uuid; l7 uuid; l8 uuid; ld uuid; x record; r text; j jsonb; n int; e0 bigint; e1 bigint; t text; ch text; ob uuid; why text; i int;
  fp text := public.ffm_instance_fp();
begin
  insert into auth.users (id, email) values ('99999999-9999-9999-9999-999999999995', 'v3-owner@example.com');
  insert into public.app_owners (email) values ('v3-owner@example.com');
  insert into public.client_workspaces (slug, name, vertical) values ('v3-ws', 'V3 Workspace', 'mortgage') returning id into a;
  perform pg_temp.as_owner(false);

  -- ======================================================= A: channel policy =======================================================
  -- A1 the policy function itself (immutable, in the database, not data)
  for x in select * from (values ('email', null), ('text', null), ('call', null), ('sms', null), ('phone', null), ('telegram', 'channel_prohibited'), ('post', 'channel_prohibited'), ('mail', 'channel_prohibited'),
     ('whatsapp', 'channel_prohibited'), ('signal', 'channel_prohibited'), ('other', 'channel_prohibited'), ('fax', 'unknown_channel'), ('Telegram', 'unknown_channel'), ('EMAIL', 'unknown_channel'), (' email', 'unknown_channel'), ('', 'unknown_channel')) v(c, w) loop
    if public.outreach_channel_problem(x.c) is distinct from x.w then raise exception 'A1 outreach_channel_problem(%) = %, expected %', x.c, public.outreach_channel_problem(x.c), x.w; end if;
  end loop;
  if public.outreach_channel_problem(null) is distinct from 'unknown_channel' then raise exception 'A1b NULL channel'; end if;
  if (select provolatile from pg_proc where proname = 'outreach_channel_problem') <> 'i' then raise exception 'A1c the channel policy must be immutable (compiled in, not a table)'; end if;
  if pg_temp.svc($q$select public.outreach_channel_problem('telegram')$q$) <> 'OK:channel_prohibited' then raise exception 'A1d bot cannot even read the policy'; end if;
  if exists (select 1 from information_schema.tables where table_schema = 'public' and table_name ilike '%channel%polic%') then raise exception 'A1e a channel-policy TABLE exists: the policy must not be data'; end if;

  -- A2 with the gate OPEN (real verification) and a clean recipient, prohibited channels are still refused; the three real channels are allowed
  l1 := public.ws_add_lead(a, null, 'Alice', 'alice@example.com', '+1 613 555 0101', 'web');
  perform pg_temp.express(a, l1, 'email', 'form-a-001'); perform pg_temp.express(a, l1, 'sms', 'form-a-002'); perform pg_temp.express(a, l1, 'phone', 'form-a-003'); perform pg_temp.express(a, l1, 'mail', 'form-a-004');
  j := pg_temp.verify_gate();
  if (j ->> 'verified')::boolean is not true then raise exception 'A2 setup: gate did not verify: %', j; end if;
  if not public.ffm_outreach_gate_open() then raise exception 'A2 setup: gate not open after real verification: %', public.ffm_outreach_gate_status(); end if;
  foreach ch in array array['telegram', 'post', 'whatsapp', 'signal', 'other'] loop
    if public.outreach_recipient_problem(ch, '@someone', null) is distinct from 'channel_prohibited' then raise exception 'A2 % allowed by outreach_recipient_problem: %', ch, public.outreach_recipient_problem(ch, '@someone', null); end if;
  end loop;
  if public.outreach_recipient_problem('email', 'fresh@example.com', null) is not null or public.outreach_recipient_problem('text', '+1 613 555 0199', null) is not null or public.outreach_recipient_problem('call', '+1 613 555 0199', null) is not null then
    raise exception 'A2b a clean email / text / call recipient is refused with the gate open'; end if;
  -- ffm_can_contact: consent is on record for mail (owner-attested capture) and the gate is open, yet mail is refused with its own reason
  if public.ffm_can_contact(l1, 'mail') then raise exception 'A3 mail allowed with consent and an open gate'; end if;
  if public.ffm_contact_status(l1, 'mail') ->> 'reason' is distinct from 'channel_prohibited' then raise exception 'A3b mail reason %', public.ffm_contact_status(l1, 'mail'); end if;
  foreach ch in array array['telegram', 'post', 'whatsapp', 'other'] loop
    if public.ffm_can_contact(l1, ch) or public.ffm_contact_status(l1, ch) ->> 'reason' is distinct from 'channel_prohibited' then raise exception 'A3c % : %', ch, public.ffm_contact_status(l1, ch); end if;
  end loop;
  if public.ffm_contact_status(l1, 'fax') ->> 'reason' is distinct from 'invalid_channel' then raise exception 'A3d unknown channel reason'; end if;
  if not public.ffm_can_contact(l1, 'email') or not public.ffm_can_contact(l1, 'sms') or not public.ffm_can_contact(l1, 'phone') then raise exception 'A3e the three real channels must work with consent + open gate: % / % / %', public.ffm_contact_status(l1, 'email'), public.ffm_contact_status(l1, 'sms'), public.ffm_contact_status(l1, 'phone'); end if;

  -- A4 outbox: no write shape can create, advance, claim or send a prohibited-channel row, as a draft either
  foreach ch in array array['telegram', 'post'] loop
    perform pg_temp.expect_fail(format($q$insert into public.outbox (channel, to_ref, body, status) values (%L, '@someone', 'hi', 'draft')$q$, ch), 'Channel prohibited%');
    perform pg_temp.expect_fail(format($q$insert into public.outbox (channel, to_ref, body, status) values (%L, '@someone', 'hi', 'approved')$q$, ch), 'Channel prohibited%');
    perform pg_temp.expect_fail(format($q$insert into public.outbox (channel, to_ref, body, status, sent_at) values (%L, '@someone', 'hi', 'approved', now())$q$, ch), 'Channel prohibited%');
    perform pg_temp.expect_fail(format($q$insert into public.outbox (channel, to_ref, body, status) values (%L, '@someone', 'hi', 'sent')$q$, ch), 'Channel prohibited%');
    if pg_temp.svc(format($q$insert into public.outbox (channel, to_ref, body, status) values (%L, '@someone', 'hi', 'draft')$q$, ch)) not like 'ERR:Channel prohibited%' then raise exception 'A4b the bot role could create a % draft', ch; end if;
  end loop;
  insert into public.outbox (channel, to_ref, body, status) values ('email', 'alice@example.com', 'hi', 'draft') returning id into ob;
  perform pg_temp.expect_fail(format($q$update public.outbox set channel = 'telegram' where id = %L$q$, ob), 'Channel prohibited%');     -- a draft cannot be turned into a telegram message
  perform pg_temp.expect_fail(format($q$update public.outbox set channel = 'post', to_ref = '1 Example St' where id = %L$q$, ob), 'Channel prohibited%');
  -- a LEGACY prohibited row (it existed before this migration; created here with triggers off) can be rejected but never approved / claimed / sent
  set local session_replication_role = replica;
  insert into public.outbox (channel, to_ref, body, status) values ('telegram', '@legacy', 'hi', 'draft') returning id into ob;
  set local session_replication_role = origin;
  perform pg_temp.expect_fail(format($q$update public.outbox set status = 'approved' where id = %L$q$, ob), 'Channel prohibited%');
  perform pg_temp.expect_fail(format($q$update public.outbox set sent_at = now() where id = %L$q$, ob), '%');
  update public.outbox set body = 'edited' where id = ob;                                      -- nothing that decides who is contacted changed: allowed (it contacts nobody)
  update public.outbox set status = 'rejected' where id = ob;                                  -- cleaning up is always allowed
  if (select status from public.outbox where id = ob) <> 'rejected' then raise exception 'A4c could not reject a legacy row'; end if;
  -- outreach_send_allowed for a (legacy) approved telegram row
  set local session_replication_role = replica;
  insert into public.outbox (channel, to_ref, body, status) values ('post', '1 Example St', 'hi', 'approved') returning id into ob;
  set local session_replication_role = origin;
  if public.outreach_send_allowed(ob) ->> 'reason' is distinct from 'channel_prohibited' or (public.outreach_send_allowed(ob) ->> 'allowed')::boolean then raise exception 'A5 outreach_send_allowed for an approved post row: %', public.outreach_send_allowed(ob); end if;
  -- marking a legacy approved telegram row as sent (a manual send by the owner, or anything else) is refused too
  set local session_replication_role = replica;
  insert into public.outbox (channel, to_ref, body, status) values ('telegram', '@legacy2', 'hi', 'approved') returning id into ob;
  set local session_replication_role = origin;
  perform pg_temp.expect_fail(format($q$update public.outbox set status = 'sent', sent_at = now() where id = %L$q$, ob), 'Channel prohibited%');
  -- A7 routing preview: refused with gate closed (own reason); with consent on mail only it is refused; with an allowed channel it works (dry run)
  l2 := public.ws_add_lead(a, null, 'Mailonly', null, null, 'web');
  if pg_temp.svc(format($q$select public.ffm_route_preview(%L, %L)::text$q$, a, l2)) not like 'ERR:routing refused: no current consent%' then raise exception 'A7 route preview for a lead with no contactable channel: %', pg_temp.svc(format($q$select public.ffm_route_preview(%L, %L)::text$q$, a, l2)); end if;
  if pg_temp.svc(format($q$select public.ffm_route_preview(%L, %L)::text$q$, a, l1)) not like 'OK:%' then raise exception 'A7b route preview refused with consent and an open gate: %', pg_temp.svc(format($q$select public.ffm_route_preview(%L, %L)::text$q$, a, l1)); end if;
  perform public.ffm_close_outreach_gate('test', 'test');
  if pg_temp.svc(format($q$select public.ffm_route_preview(%L, %L)::text$q$, a, l1)) not like 'ERR:routing refused: the outreach gate is closed%' then raise exception 'A7c route preview with the gate closed: %', pg_temp.svc(format($q$select public.ffm_route_preview(%L, %L)::text$q$, a, l1)); end if;
  -- A8 closed gate: the channel reason still wins, so a log shows WHY (prohibited) instead of the generic closed reason
  if public.outreach_recipient_problem('telegram', '@x', null) is distinct from 'channel_prohibited' or public.outreach_recipient_problem('email', 'x@example.com', null) is distinct from 'suppression_unverified' then raise exception 'A8 closed-gate reasons'; end if;

  -- ======================================================= W: which withdrawals propagate =======================================================
  perform pg_temp.verify_gate();
  -- columns: withdrawal channel, address suppressed?, number suppressed?
  for x in select * from (values ('email', true, false), ('sms', false, true), ('phone', false, true), ('text', false, true), ('call', false, true), ('all', true, true),
                                 ('telegram', true, true), ('post', true, true), ('mail', true, true), ('whatsapp', true, true), ('signal', true, true), ('other', true, true)) v(c, em, ph) loop
    i := coalesce(i, 0) + 1;
    l3 := public.ws_add_lead(a, null, 'W' || i, 'w' || i || '@example.com', '+1 613 555 ' || lpad((1000 + i)::text, 4, '0'), 'web');
    perform public.ffm_withdraw_consent(a, l3, x.c, 'test', null, 'test');
    if public.is_suppressed('w' || i || '@example.com') is distinct from x.em then raise exception 'W1 withdrawal on % : address suppressed = %, expected %', x.c, public.is_suppressed('w' || i || '@example.com'), x.em; end if;
    if public.ffm_is_phone_suppressed('+1 613 555 ' || lpad((1000 + i)::text, 4, '0')) is distinct from x.ph then raise exception 'W2 withdrawal on % : number suppressed = %, expected %', x.c, public.ffm_is_phone_suppressed('+1 613 555 ' || lpad((1000 + i)::text, 4, '0')), x.ph; end if;
    -- a re-added duplicate lead (new id, address in another case with a +tag, number in another format) is refused on exactly the suppressed identifiers
    l4 := public.ws_add_lead(a, null, 'Dup', upper('w' || i) || '+promo@Example.com', '(613) 555-' || lpad((1000 + i)::text, 4, '0'), 'reimport');
    if x.em and public.outreach_recipient_problem('email', upper('w' || i) || '+promo@Example.com', null) is distinct from 'suppressed' then raise exception 'W3 duplicate address not refused after % withdrawal', x.c; end if;
    if not x.em and public.outreach_recipient_problem('email', 'w' || i || '@example.com', null) is not null then raise exception 'W3b an unrelated email was suppressed by a % withdrawal', x.c; end if;
    if x.ph and public.outreach_recipient_problem('text', '613.555.' || lpad((1000 + i)::text, 4, '0'), null) is distinct from 'suppressed' then raise exception 'W4 duplicate number not refused after % withdrawal', x.c; end if;
    if x.ph and public.outreach_recipient_problem('call', '+16135551000'::text || '', null) is null and (1000 + i) = 1000 then null; end if;
    if not x.ph and public.outreach_recipient_problem('text', '+1 613 555 ' || lpad((1000 + i)::text, 4, '0'), null) is not null then raise exception 'W4b number suppressed by a % withdrawal', x.c; end if;
  end loop;
  -- W5 the withdrawal row is logged on the channel (or as 'all' with the original channel in the source when that channel has no durable identifier)
  if (select channel from public.ffm_consent_log where source like 'via telegram:%' limit 1) is distinct from 'all' then raise exception 'W5 telegram withdrawal not logged as all'; end if;
  if (select count(*) from public.ffm_consent_log where basis = 'withdrawn' and channel = 'sms') <> 2 then raise exception 'W5b sms / text withdrawals logged as sms: %', (select count(*) from public.ffm_consent_log where basis = 'withdrawn' and channel = 'sms'); end if;
  perform pg_temp.expect_fail(format($q$select public.ffm_withdraw_consent(%L, %L, 'fax', 'x', null, 'x')$q$, a, l3), 'withdrawal refused%');
  -- W6 the bot role records withdrawals on any channel (it must always be able to)
  if pg_temp.svc(format($q$select public.ffm_withdraw_consent(%L, %L, 'telegram', 'reply', null, 'bot')::text$q$, a, l3)) not like 'OK:%' then raise exception 'W6 bot could not record a telegram withdrawal'; end if;

  -- ======================================================= D: the owner directive's scenarios =======================================================
  -- D1 duplicate lead creation: same person, same address and number, created twice; withdrawal on one, the twin is refused on every identifier
  l5 := public.ws_add_lead(a, null, 'Dina', 'dina@example.com', '+1 613 555 0150', 'web');
  l6 := public.ws_add_lead(a, null, 'Dina again', 'DINA@Example.com', '1-613-555-0150', 'web');
  perform pg_temp.express(a, l5, 'email', 'form-d-001'); perform pg_temp.express(a, l5, 'sms', 'form-d-002'); perform pg_temp.express(a, l6, 'email', 'form-d-003'); perform pg_temp.express(a, l6, 'sms', 'form-d-004');
  perform pg_temp.verify_gate();
  if not public.ffm_can_contact(l5, 'email') or not public.ffm_can_contact(l6, 'email') then raise exception 'D1 setup: both twins contactable first: % / %', public.ffm_contact_status(l5, 'email'), public.ffm_contact_status(l6, 'email'); end if;
  perform public.ffm_withdraw_consent(a, l5, 'all', 'reply STOP', null, 'bot');
  if public.ffm_can_contact(l6, 'email') or public.ffm_can_contact(l6, 'sms') or public.ffm_can_contact(l6, 'phone') then raise exception 'D1 the duplicate lead is still contactable after the other twin withdrew (all)'; end if;
  if public.ffm_contact_status(l6, 'email') ->> 'reason' <> 'suppressed' or public.ffm_contact_status(l6, 'sms') ->> 'reason' <> 'suppressed' then raise exception 'D1b reasons % / %', public.ffm_contact_status(l6, 'email'), public.ffm_contact_status(l6, 'sms'); end if;
  -- D2 re-import under a NEW id (new workspace even), same email / phone in case, +tag and format variants
  insert into public.client_workspaces (slug, name, vertical) values ('v3-ws2', 'V3 Workspace 2', 'insurance') returning id into ld;
  for x in select * from (values ('Dina@EXAMPLE.com', '(613) 555-0150'), ('dina+newsletter@example.com.', '+1 613 555 0150 x5'), ('<dina@example.com>', '613.555.0150'), ('dina@example.com', '+16135550150')) v(em, ph) loop
    l7 := public.ws_add_lead(ld, null, 'Reimport', x.em, x.ph, 'csv import');
    perform pg_temp.express(ld, l7, 'email', 'form-d2-' || substr(md5(x.em || x.ph), 1, 8));
    if public.ffm_can_contact(l7, 'email') then raise exception 'D2 re-imported lead (%, %) is contactable by email', x.em, x.ph; end if;
    if public.outreach_recipient_problem('email', x.em, null) is distinct from 'suppressed' then raise exception 'D2b outreach_recipient_problem allowed re-imported address %', x.em; end if;
    if public.outreach_recipient_problem('text', x.ph, null) is distinct from 'suppressed' then raise exception 'D2c outreach_recipient_problem allowed re-imported number % (%)', x.ph, public.outreach_recipient_problem('text', x.ph, null); end if;
  end loop;
  -- D2e trunk zero (UK): the number is on the list as +442079460958; every written form of it is refused, and a bare national number (no country) is unusable, never "not suppressed"
  insert into public.ffm_phone_suppressions (phone, reason, recorded_by) values ('+442079460958', 'fixture', 'test');
  foreach t in array array['+44 (0)20 7946 0958', '0044 20 7946 0958', '+44 20 7946 0958', '+442079460958', '+44-(0)-20-7946-0958'] loop
    if public.outreach_recipient_problem('call', t, null) is distinct from 'suppressed' then raise exception 'D2e UK number % (%): %', t, public.normalize_phone(t), public.outreach_recipient_problem('call', t, null); end if;
  end loop;
  if public.outreach_recipient_problem('call', '020 7946 0958', null) is distinct from 'phone_unusable' then raise exception 'D2f bare national number: %', public.outreach_recipient_problem('call', '020 7946 0958', null); end if;
  -- D3 phone normalisation: trunk zero and +1 forms all land on ONE number
  foreach t in array array['+1 613 555 0150', '1-613-555-0150', '001 613 555 0150', '(613) 555-0150', '613.555.0150', '+1 (613) 555 0150 x12'] loop
    if public.normalize_phone(t) is distinct from '+16135550150' then raise exception 'D3 normalize_phone(%) = %', t, public.normalize_phone(t); end if;
  end loop;
  -- D3c BARE 10-DIGIT numbers: documented default is +1 (Canada/US, the NANP), so a suppressed +16135550150 also blocks '6135550150'; any other bare length (7, 9, 11 without a leading 1) is unusable
  if public.normalize_phone('6135550150') is distinct from '+16135550150' or public.normalize_phone('613 555 0150') is distinct from '+16135550150' then raise exception 'D3c bare 10-digit number is not read as +1'; end if;
  if public.ffm_is_phone_suppressed('6135550150') is not true or public.outreach_recipient_problem('call', '6135550150', null) is distinct from 'suppressed' then raise exception 'D3d a bare 10-digit number is not matched against its +1 suppression'; end if;
  foreach t in array array['5550150', '613555015', '61355501500', '0613555015'] loop
    if public.normalize_phone(t) is not null or public.outreach_recipient_problem('call', t, null) is distinct from 'phone_unusable' then raise exception 'D3e bare number % is not refused as unusable', t; end if;
  end loop;
  foreach t in array array['+44 (0)20 7946 0958', '020 7946 0958 ', '0044 20 7946 0958', '+44 20 7946 0958'] loop
    if public.normalize_phone(t) is distinct from (case when t = '020 7946 0958 ' then null else '+442079460958' end) then raise exception 'D3b normalize_phone(%) = %', t, public.normalize_phone(t); end if;   -- a bare national number is ambiguous without a country: NULL = refused
  end loop;
  -- D4 email CHANGE on an existing lead: the old address stays suppressed, and editing the lead cannot re-activate it
  l8 := public.ws_add_lead(a, null, 'Evan', 'evan@example.com', '+1 613 555 0177', 'web');
  perform pg_temp.express(a, l8, 'email', 'form-e-001'); perform pg_temp.express(a, l8, 'sms', 'form-e-002');
  perform public.ffm_withdraw_consent(a, l8, 'email', 'unsubscribe link', null, 'bot');
  update public.ws_leads set email = 'evan.new@example.com' where id = l8;                       -- the edit
  if public.is_suppressed('evan@example.com') is not true then raise exception 'D4 the OLD address is no longer suppressed after the lead was edited'; end if;
  if public.ffm_can_contact(l8, 'email') then raise exception 'D4b editing the lead email re-activated it: %', public.ffm_contact_status(l8, 'email'); end if;
  if public.ffm_contact_status(l8, 'email') ->> 'reason' <> 'withdrawn' then raise exception 'D4c reason %', public.ffm_contact_status(l8, 'email'); end if;
  perform pg_temp.expect_fail(format($q$select public.ffm_record_consent(%L,%L,'email','implied','v1','x',now(),'x','owner')$q$, a, l8), '%');             -- no new consent for a withdrawn channel (final in v1)
  if public.outreach_recipient_problem('email', 'evan@example.com', null) is distinct from 'suppressed' then raise exception 'D4d old address allowed through the outbox decision'; end if;
  if public.outreach_recipient_problem('email', 'evan.new@example.com', null) is distinct from 'suppressed' then raise exception 'D4e the NEW address of a withdrawn lead was not suppressed at once by the identifier trigger'; end if;
  if public.outreach_recipient_problem('email', 'unrelated.person@example.com', null) is not null then raise exception 'D4g an unrelated clean address is refused for no reason'; end if;
  update public.ws_leads set email = 'evan@example.com' where id = l8;                           -- editing it BACK does not help either
  if public.ffm_can_contact(l8, 'email') then raise exception 'D4f editing the address back re-activated it'; end if;
  -- D4h a withdrawal recorded with NO usable identifier stores nothing durable by itself: it is widened to 'all' (logged so), and an identifier added later is suppressed immediately
  l7 := public.ws_add_lead(a, null, 'Phone only', null, '+1 613 555 0188', 'web');
  j := to_jsonb((select c from public.ffm_consent_log c where c.id = public.ffm_withdraw_consent(a, l7, 'email', 'reply STOP by email', null, 'bot')));
  if j ->> 'channel' <> 'all' or j ->> 'source' not like 'no usable identifier for email:%' then raise exception 'D4h withdrawal on a lead with no address was not widened to all and logged: %', j; end if;
  if not public.ffm_is_phone_suppressed('+1 613 555 0188') then raise exception 'D4i the widened withdrawal did not suppress the number'; end if;
  update public.ws_leads set email = 'late.add@example.com' where id = l7;                       -- re-add an address to the withdrawn lead
  if not public.is_suppressed('late.add@example.com') then raise exception 'D4j an address ADDED to a withdrawn lead is not suppressed'; end if;
  l6 := public.ws_add_lead(a, null, 'Duplicate of the late add', 'LATE.ADD@example.com', null, 'import');   -- and the duplicate lead (new id, other casing) is refused too
  if public.ffm_can_contact(l6, 'email') or public.outreach_recipient_problem('email', 'LATE.ADD@example.com', null) is distinct from 'suppressed' then raise exception 'D4k duplicate of the late-added address is contactable'; end if;
  l7 := public.ws_add_lead(a, null, 'Mail only', 'mailonly@example.com', null, 'web');
  perform public.ffm_withdraw_consent(a, l7, 'sms', 'STOP', null, 'bot');                         -- no number on file: widened to all
  if (select channel from public.ffm_consent_log where lead_id = l7 and basis = 'withdrawn') <> 'all' or not public.is_suppressed('mailonly@example.com') then raise exception 'D4l sms withdrawal without a number did not widen to all'; end if;
  update public.ws_leads set phone = '+1 613 555 0189' where id = l7;
  if not public.ffm_is_phone_suppressed('+16135550189') then raise exception 'D4m a number ADDED to a withdrawn lead is not suppressed'; end if;
  l6 := public.ws_add_lead(a, null, 'Duplicate number', null, '(613) 555-0189', 'import');
  if public.outreach_recipient_problem('call', '613-555-0189', null) is distinct from 'suppressed' then raise exception 'D4n duplicate of the late-added number is contactable'; end if;
  -- D4o text / call map to sms / phone BEFORE the checks (an sms withdrawal blocks 'text' and 'call')
  l7 := public.ws_add_lead(a, null, 'Text caller', 'textcaller@example.com', '+1 613 555 0190', 'web');
  perform pg_temp.express(a, l7, 'sms', 'form-t-001');
  if not public.ffm_can_contact(l7, 'text') or public.ffm_contact_status(l7, 'text') ->> 'reason' <> 'express' then raise exception 'D4o text is not mapped to sms: %', public.ffm_contact_status(l7, 'text'); end if;
  perform public.ffm_withdraw_consent(a, l7, 'sms', 'STOP', null, 'bot');
  if public.ffm_can_contact(l7, 'text') or public.ffm_can_contact(l7, 'call') or public.ffm_can_contact(l7, 'sms') then raise exception 'D4p sms withdrawal left text/call/sms contactable'; end if;
  if public.ffm_contact_status(l7, 'text') ->> 'reason' <> 'withdrawn' then raise exception 'D4q text status is not withdrawn: %', public.ffm_contact_status(l7, 'text'); end if;

  -- D5 SMS withdrawal persists after the lead is re-added (new id, number in another format), and it blocks voice too; it does NOT suppress the email
  if not public.ffm_can_contact(l8, 'sms') then raise exception 'D5 setup: the sms consent of Evan should be intact (email withdrawal is channel-specific)'; end if;
  perform public.ffm_withdraw_consent(a, l8, 'sms', 'reply STOP', null, 'bot');
  l4 := public.ws_add_lead(a, null, 'Evan re-added', 'evan.other@example.com', '613-555-0177', 'web');
  perform pg_temp.express(a, l4, 'sms', 'form-e-003'); perform pg_temp.express(a, l4, 'phone', 'form-e-004');
  if public.ffm_can_contact(l4, 'sms') or public.ffm_can_contact(l4, 'phone') then raise exception 'D5b SMS withdrawal did not persist after re-add'; end if;
  if public.outreach_recipient_problem('call', '+1 (613) 555-0177', null) is distinct from 'suppressed' then raise exception 'D5c voice not blocked by an sms withdrawal'; end if;
  if public.is_suppressed('evan.other@example.com') then raise exception 'D5d an sms withdrawal suppressed an unrelated address'; end if;
  -- D6 cross-channel: an 'all' withdrawal made through a channel with no identifier (telegram) still suppresses address AND number
  l3 := public.ws_add_lead(a, null, 'Fay', 'fay@example.com', '+1 613 555 0188', 'web');
  perform public.ffm_withdraw_consent(a, l3, 'telegram', 'said stop in a DM', null, 'bot');
  if not (public.is_suppressed('fay@example.com') and public.ffm_is_phone_suppressed('613 555 0188')) then raise exception 'D6 telegram withdrawal did not propagate'; end if;
  -- D7 erasure: address and number suppressed, the lead is redacted, re-adding the person (any format) stays refused
  l3 := public.ws_add_lead(a, null, 'Gus', 'gus@example.com', '+1 613 555 0199', 'web');
  perform pg_temp.as_owner(true); perform public.ffm_erase_lead(a, l3, 'erasure_request'); perform pg_temp.as_owner(false);
  l4 := public.ws_add_lead(a, null, 'Gus back', 'GUS+x@example.com', '1 (613) 555-0199', 'web');
  if public.outreach_recipient_problem('email', 'GUS+x@example.com', null) is distinct from 'suppressed' or public.outreach_recipient_problem('text', '1 (613) 555-0199', null) is distinct from 'suppressed' then raise exception 'D7 erased person can be contacted again'; end if;

  -- ======================================================= R: restore-closed gate =======================================================
  -- R0 structure: nobody but definer functions can write the new tables; the bot may read
  foreach t in array array['ffm_epoch', 'ffm_restore_markers', 'ffm_gate_config'] loop
    if not (select relrowsecurity from pg_class where oid = ('public.' || t)::regclass) then raise exception 'R0 RLS off on %', t; end if;
    if has_table_privilege('anon', 'public.' || t, 'select') or has_table_privilege('authenticated', 'public.' || t, 'select') then raise exception 'R0b API roles read %', t; end if;
    foreach ch in array array['insert', 'update', 'delete', 'truncate', 'trigger', 'references'] loop
      if has_table_privilege('service_role', 'public.' || t, ch) then raise exception 'R0c service_role can % %', ch, t; end if;
    end loop;
  end loop;
  if pg_temp.svc($q$update public.ffm_epoch set epoch = 999999$q$) not like 'ERR:permission denied%' then raise exception 'R0d bot wrote the epoch'; end if;
  if pg_temp.svc($q$select public.ffm_set_gate_config(5, 5, 'bot')::text$q$) not like 'ERR:owner approval required%' then raise exception 'R0e bot set the gate config'; end if;
  if pg_temp.svc($q$select public.ffm_verify_suppression('bot')::text$q$) not like 'ERR:owner approval required%' then raise exception 'R0f bot verified the gate'; end if;
  foreach t in array array['public.ffm_epoch_guard()', 'public.ffm_epoch_bump()', 'public.ffm_lead_identifier_guard()'] loop
    if has_function_privilege('anon', t, 'execute') or has_function_privilege('authenticated', t, 'execute') then raise exception 'R0g API roles can run %', t; end if;
  end loop;
  foreach t in array array['public.ffm_owner_record_restore(text)', 'public.ffm_gate_core_ok()', 'public.ffm_gate_state()', 'public.ffm_sender_attest(bigint,bigint,text)', 'public.ffm_set_gate_config(integer,integer,text)', 'public.ffm_instance_fp()', 'public.outreach_channel_problem(text)'] loop
    if has_function_privilege('anon', t, 'execute') or has_function_privilege('authenticated', t, 'execute') then raise exception 'R0h API roles can run %', t; end if;
  end loop;

  -- R1 epoch: only goes up, and every suppression-relevant write moves it
  e0 := (select epoch from public.ffm_epoch where id = 1);
  perform pg_temp.expect_fail($q$update public.ffm_epoch set epoch = epoch - 1$q$, 'The suppression epoch only increases%');
  perform pg_temp.expect_fail($q$update public.ffm_epoch set epoch = epoch$q$, 'The suppression epoch only increases%');
  perform pg_temp.expect_fail($q$delete from public.ffm_epoch$q$, 'The suppression epoch only increases%');
  perform pg_temp.expect_fail($q$truncate public.ffm_epoch$q$, 'The suppression epoch only increases%');
  perform pg_temp.as_owner(true); perform public.ffm_owner_record_restore('append-only check'); perform pg_temp.as_owner(false);
  perform pg_temp.expect_fail($q$delete from public.ffm_restore_markers$q$, 'This record set is append-only%');
  perform pg_temp.expect_fail($q$update public.ffm_restore_markers set source = 'x'$q$, 'This record set is append-only%');
  perform pg_temp.expect_fail($q$truncate public.ffm_restore_markers$q$, 'This record set is append-only%');
  l3 := public.ws_add_lead(a, null, 'Hal', 'hal@example.com', '+1 613 555 0166', 'web');
  e0 := (select epoch from public.ffm_epoch where id = 1);
  perform public.ffm_withdraw_consent(a, l3, 'email', 'unsubscribe link', null, 'bot'); e1 := (select epoch from public.ffm_epoch where id = 1);
  if e1 <= e0 then raise exception 'R1 a withdrawal did not move the epoch (% -> %)', e0, e1; end if;
  insert into public.contact_suppressions (address, reason, recorded_by) values ('epoch-test@example.com', 'x', 'test'); if (select epoch from public.ffm_epoch where id = 1) <= e1 then raise exception 'R1b address suppression did not move the epoch'; end if;
  e1 := (select epoch from public.ffm_epoch where id = 1);
  insert into public.ffm_phone_suppressions (phone, reason, recorded_by) values ('+16135550999', 'x', 'test'); if (select epoch from public.ffm_epoch where id = 1) <= e1 then raise exception 'R1c phone suppression did not move the epoch'; end if;
  e1 := (select epoch from public.ffm_epoch where id = 1);
  update public.leads set do_not_contact = true where id = (select id from public.leads limit 1);
  if (select epoch from public.ffm_epoch where id = 1) <= e1 and exists (select 1 from public.leads) then raise exception 'R1d do-not-contact flag did not move the epoch'; end if;
  e1 := (select epoch from public.ffm_epoch where id = 1);
  perform public.ffm_close_outreach_gate('epoch test', 'test'); if (select epoch from public.ffm_epoch where id = 1) <= e1 then raise exception 'R1e closing the gate did not move the epoch'; end if;

  -- R2 a verified gate is OPEN, and the verification records the epoch, the instance and a first attestation
  j := pg_temp.verify_gate();
  if (j ->> 'verified')::boolean is not true or not public.ffm_outreach_gate_open() then raise exception 'R2 verified gate not open: % / %', j, public.ffm_outreach_gate_status(); end if;
  if (select verified_epoch from public.ffm_outreach_gate where id = 1) <> (select epoch from public.ffm_epoch where id = 1) or (select instance_fp from public.ffm_outreach_gate where id = 1) is distinct from fp or (select attested_at from public.ffm_outreach_gate where id = 1) is null then raise exception 'R2b verification did not bind epoch / instance / attestation'; end if;

  -- R3 the SENDER ATTESTATION must stay fresh: with none for longer than the window the gate closes BY ITSELF; a fresh attestation from a sender whose mark is NOT BELOW the stored mark keeps it open.
  -- The DB keeps the highest mark it accepted (ffm_sender_mark) and refuses a lower one, so a stolen service key cannot refresh a stale gate with a forged low mark.
  e0 := (select epoch from public.ffm_epoch where id = 1);
  r := pg_temp.svc(format($q$select public.ffm_sender_attest(1, %s, %L)::text$q$, e0, fp));            -- first anchor (stored generation 0): allowed because the gate was just verified
  if r not like 'OK:%"ok": true%' or (select gen from public.ffm_sender_mark where id = 1) <> 1 then raise exception 'R3 first anchor refused: %', r; end if;
  perform pg_temp.age_gate(interval '14 minutes');
  if not public.ffm_outreach_gate_open() then raise exception 'R3a gate closed too early (14 min < 15 min window)'; end if;
  perform pg_temp.age_gate(interval '2 minutes');
  if public.ffm_outreach_gate_open() then raise exception 'R3b gate still open 16 minutes after the last attestation'; end if;
  if public.outreach_recipient_problem('email', 'clean@example.com', null) is distinct from 'suppression_unverified' then raise exception 'R3c stale-attestation gate allowed a send'; end if;
  -- R3b2 THE DATABASE CLAIM GUARD requires a fresh attestation (no live sender = nothing can be approved or claimed, whatever the verification says)
  ob := (select id from public.outbox where channel = 'email' and status = 'draft' limit 1);
  perform pg_temp.expect_fail(format($q$update public.outbox set status = 'approved' where id = %L$q$, ob), 'Outreach gate closed%');
  if (public.outreach_send_allowed(ob) ->> 'allowed')::boolean is not false or public.outreach_send_allowed(ob) ->> 'reason' <> 'suppression_unverified' then raise exception 'R3b3 outreach_send_allowed with a stale attestation: %', public.outreach_send_allowed(ob); end if;
  perform pg_temp.expect_fail($q$insert into public.outbox (channel, to_ref, body, status) values ('email', 'fresh.person@example.com', 'hi', 'approved')$q$, 'Outreach gate closed%');
  r := pg_temp.svc(format($q$select public.ffm_sender_attest(1, %s, %L)::text$q$, e0 - 5, fp));        -- a LOWER mark than the stored one (forged / stale sender) must not refresh anything
  if r not like '%mark_regression%' or public.ffm_outreach_gate_open() then raise exception 'R3d a lower mark refreshed the attestation or was not refused: %', r; end if;
  r := pg_temp.svc(format($q$select public.ffm_sender_attest(0, %s, %L)::text$q$, e0 + 1000, fp));     -- generation 0 / lower generation likewise
  if r not like '%sender_unanchored%' or public.ffm_outreach_gate_open() then raise exception 'R3d2 generation 0 accepted: %', r; end if;
  r := pg_temp.svc(format($q$select public.ffm_sender_attest(1, %s, %L)::text$q$, e0, fp));            -- the real sender (mark == stored mark) keeps it open
  if r not like 'OK:%"ok": true%' or not public.ffm_outreach_gate_open() then raise exception 'R3e a sender whose mark equals the stored mark could not refresh the attestation: %', r; end if;
  r := pg_temp.svc($q$select public.ffm_sender_attest(NULL, NULL, NULL)::text$q$);
  if r not like '%sender_unanchored%' then raise exception 'R3f an unanchored sender was treated as anchored: %', r; end if;
  -- the attestation can only KEEP a verified gate; it can never open one
  perform public.ffm_close_outreach_gate('test', 'test');
  perform pg_temp.svc(format($q$select public.ffm_sender_attest(1, %s, %L)::text$q$, (select epoch from public.ffm_epoch where id = 1), fp));
  if public.ffm_outreach_gate_open() then raise exception 'R3g an attestation opened a closed gate'; end if;
  -- a higher generation (an anchor) with the gate closed, or without a new owner-recorded restore, is refused
  r := pg_temp.svc(format($q$select public.ffm_sender_attest(2, %s, %L)::text$q$, (select epoch from public.ffm_epoch where id = 1), fp));
  if r not like '%anchor_refused%' or (select gen from public.ffm_sender_mark where id = 1) <> 1 then raise exception 'R3h anchor accepted on a closed gate: %', r; end if;
  perform pg_temp.verify_gate();
  r := pg_temp.svc(format($q$select public.ffm_sender_attest(2, %s, %L)::text$q$, (select epoch from public.ffm_epoch where id = 1), fp));
  if r not like '%owner-recorded restore%' or (select gen from public.ffm_sender_mark where id = 1) <> 1 then raise exception 'R3i anchor accepted with no unused owner restore marker: %', r; end if;

  -- R4 ROLLBACK DETECTED: the sender's mark is ahead of the database -> the database closes its own gate for good (state, marker), the call says so
  perform pg_temp.verify_gate();
  e0 := (select epoch from public.ffm_epoch where id = 1);
  n := (select count(*) from public.ffm_restore_markers);
  r := pg_temp.svc(format($q$select public.ffm_sender_attest(1, %s, %L)::text$q$, e0 + 40, fp));
  if r not like '%rollback_detected%' then raise exception 'R4 rollback not reported: %', r; end if;
  if public.ffm_outreach_gate_open() or (select state from public.ffm_outreach_gate where id = 1) <> 'unverified' then raise exception 'R4b gate not closed by the detection: %', public.ffm_outreach_gate_status(); end if;
  if (select count(*) from public.ffm_restore_markers) <> n + 1 or not exists (select 1 from public.ffm_restore_markers where source = 'detected_by_sender') then raise exception 'R4c no marker written'; end if;
  -- ...and it STAYS closed when the sender later presents a lower mark (a detection is not undone by a calmer second opinion); only the owner's verification, after the marker, opens it
  perform pg_temp.svc(format($q$select public.ffm_sender_attest(1, %s, %L)::text$q$, (select epoch from public.ffm_epoch where id = 1), fp));
  if public.ffm_outreach_gate_open() then raise exception 'R4d gate re-opened without verification'; end if;
  j := pg_temp.verify_gate();
  if (j ->> 'verified')::boolean is not true or not public.ffm_outreach_gate_open() then raise exception 'R4e owner re-verification after the marker did not open the gate: % / %', j, public.ffm_outreach_gate_status(); end if;
  -- R4f repeated detections do not pile markers up on an already closed gate
  perform pg_temp.svc(format($q$select public.ffm_sender_attest(1, %s, %L)::text$q$, (select epoch from public.ffm_epoch where id = 1) + 100, fp));
  n := (select count(*) from public.ffm_restore_markers);
  perform pg_temp.svc(format($q$select public.ffm_sender_attest(1, %s, %L)::text$q$, (select epoch from public.ffm_epoch where id = 1) + 100, fp));
  if (select count(*) from public.ffm_restore_markers) <> n then raise exception 'R4f marker spam on a closed gate'; end if;

  -- R5 INSTANCE: another cluster / timeline. (a) detected by the sender, (b) detected by the database alone from the stored fingerprint
  perform pg_temp.verify_gate();
  r := pg_temp.svc($q$select public.ffm_sender_attest(1, 1, '999:7')::text$q$);
  if r not like '%rollback_detected%' or public.ffm_outreach_gate_open() then raise exception 'R5 other instance not detected by the sender check: %', r; end if;
  perform pg_temp.verify_gate();
  set local session_replication_role = replica; update public.ffm_outreach_gate set instance_fp = '999:7' where id = 1; set local session_replication_role = origin;
  if public.ffm_outreach_gate_open() then raise exception 'R5b gate stayed open with a fingerprint from another cluster (a dump restored elsewhere)'; end if;
  set local session_replication_role = replica; update public.ffm_outreach_gate set instance_fp = null where id = 1; set local session_replication_role = origin;
  if public.ffm_outreach_gate_open() then raise exception 'R5c gate open with no recorded fingerprint'; end if;

  -- R6 MAXIMUM AGE of the owner's verification, and the config bounds
  perform pg_temp.verify_gate();
  perform pg_temp.age_gate(interval '0', interval '29 days');
  if not public.ffm_outreach_gate_open() then raise exception 'R6 gate closed at 29 days (limit 30)'; end if;
  perform pg_temp.age_gate(interval '0', interval '2 days');
  if public.ffm_outreach_gate_open() then raise exception 'R6b gate open 31 days after the owner verified it'; end if;
  perform pg_temp.as_owner(true);
  perform public.ffm_set_gate_config(15, 60, 'owner'); perform pg_temp.as_owner(false);
  if not public.ffm_outreach_gate_open() then raise exception 'R6c raising the maximum age did not apply'; end if;
  perform pg_temp.as_owner(true);
  perform pg_temp.expect_fail($q$select public.ffm_set_gate_config(1, 30, 'owner')$q$, '%attest_window_minutes%');
  perform pg_temp.expect_fail($q$select public.ffm_set_gate_config(5, 30, 'owner')$q$, '%attest_window_minutes%');      -- the engine tick is 300 s: a window of two ticks or less would flap
  perform public.ffm_set_gate_config(6, 30, 'owner');
  perform pg_temp.expect_fail($q$select public.ffm_set_gate_config(121, 30, 'owner')$q$, '%attest_window_minutes%');
  perform pg_temp.expect_fail($q$select public.ffm_set_gate_config(15, 91, 'owner')$q$, '%max_verified_age_days%');
  perform pg_temp.expect_fail($q$select public.ffm_set_gate_config(15, 0, 'owner')$q$, '%max_verified_age_days%');
  perform public.ffm_set_gate_config(15, 30, 'owner'); perform pg_temp.as_owner(false);

  -- R7 RESTORE MARKER (deterministic, no wall-clock comparison): the verification records the newest marker id; a marker recorded AFTER it closes the gate; only a verification after it opens it again.
  -- Only the OWNER can record a restore (the bot role cannot); the ordered flow is: owner-recorded restore -> verify -> anchor.
  perform pg_temp.verify_gate();
  if pg_temp.svc($q$select public.ffm_owner_record_restore('provider PITR')::text$q$) not like 'ERR:owner approval required%' then raise exception 'R7 the bot role could record an owner restore marker'; end if;
  if not public.ffm_outreach_gate_open() then raise exception 'R7a a refused call closed the gate'; end if;
  perform pg_temp.as_owner(true); perform public.ffm_owner_record_restore('owner ran a point-in-time recovery'); perform pg_temp.as_owner(false);
  if public.ffm_outreach_gate_open() or public.ffm_gate_core_ok() then raise exception 'R7b gate open after an owner restore marker'; end if;
  r := pg_temp.svc(format($q$select public.ffm_sender_attest(2, %s, %L)::text$q$, (select epoch from public.ffm_epoch where id = 1), fp));      -- anchor BEFORE the verification: refused
  if r not like '%anchor_refused%' then raise exception 'R7b2 anchor accepted before the verification: %', r; end if;
  perform pg_temp.verify_gate();
  if not public.ffm_outreach_gate_open() then raise exception 'R7c verification after the marker did not open the gate'; end if;
  r := pg_temp.svc(format($q$select public.ffm_sender_attest(2, %s, %L)::text$q$, (select epoch from public.ffm_epoch where id = 1), fp));      -- record -> verify -> anchor, in that order: accepted
  if r not like 'OK:%"ok": true%' or (select gen from public.ffm_sender_mark where id = 1) <> 2 then raise exception 'R7d the ordered anchor was refused: %', r; end if;
  r := pg_temp.svc(format($q$select public.ffm_sender_attest(3, %s, %L)::text$q$, (select epoch from public.ffm_epoch where id = 1), fp));      -- the marker is consumed: a second anchor needs a new one
  if r not like '%anchor_refused%' then raise exception 'R7e one owner marker authorised two anchors: %', r; end if;
  -- a marker inserted by any means closes the gate whatever its timestamp says (a restored table can carry any clock): ids, not times, decide
  set local session_replication_role = replica; insert into public.ffm_restore_markers (restored_at, source, recorded_by) values (now() - interval '3 years', 'fixture', 'test'); set local session_replication_role = origin;
  if public.ffm_outreach_gate_open() then raise exception 'R7f an OLD-dated marker with a newer id did not close the gate'; end if;
  perform pg_temp.verify_gate();
  if not public.ffm_outreach_gate_open() then raise exception 'R7g could not re-verify immediately after a marker (no clock dependence): %', public.ffm_outreach_gate_status(); end if;
  set local session_replication_role = replica; insert into public.ffm_restore_markers (restored_at, source, recorded_by) values (now() + interval '1 day', 'fixture', 'test'); set local session_replication_role = origin;
  if public.ffm_outreach_gate_open() then raise exception 'R7h a future-dated marker did not close the gate'; end if;
  perform pg_temp.verify_gate();
  if not public.ffm_outreach_gate_open() then raise exception 'R7i could not re-verify after the future-dated marker: %', public.ffm_outreach_gate_status(); end if;
  -- the marker table rolled BACK (fewer markers than at verification): closed as well
  set local session_replication_role = replica; delete from public.ffm_restore_markers where id = (select max(id) from public.ffm_restore_markers); set local session_replication_role = origin;
  if public.ffm_outreach_gate_open() then raise exception 'R7j a rolled-back marker table left the gate open'; end if;
  perform pg_temp.verify_gate();

  -- R8 EPOCH ROW MISSING (a restored schema without it) or LOWER than at verification: closed, and verification itself refuses without the row
  set local session_replication_role = replica; update public.ffm_epoch set epoch = epoch - 1 where id = 1; set local session_replication_role = origin;
  if public.ffm_outreach_gate_open() then raise exception 'R8 epoch lower than at verification but the gate is open'; end if;
  set local session_replication_role = replica; update public.ffm_epoch set epoch = epoch + 1 where id = 1; delete from public.ffm_epoch; set local session_replication_role = origin;
  if public.ffm_outreach_gate_open() then raise exception 'R8b epoch row missing but the gate is open'; end if;
  j := pg_temp.verify_gate();
  if (j ->> 'verified')::boolean is not false then raise exception 'R8c verification succeeded without an epoch row: %', j; end if;
  if pg_temp.svc($q$select public.ffm_sender_attest(1, 1, NULL)::text$q$) not like '%rollback_detected%' then raise exception 'R8d attest with no epoch row'; end if;
  set local session_replication_role = replica; insert into public.ffm_epoch (id, epoch) values (1, 1000); set local session_replication_role = origin;
  perform pg_temp.verify_gate();

  -- R9 OLD GATE (OPEN) + OLD CHECKPOINT RESTORED TOGETHER (the scenario of the owner directive).
  -- t0: gate verified, checkpoint staged, epoch e0. Later: a person opts out (epoch e1), the sender sees e1. Then the database is restored to t0: gate row, checkpoint, lists and epoch all come back.
  create temporary table snap_gate as select * from public.ffm_outreach_gate;
  create temporary table snap_exp as select * from public.ffm_suppression_expected;
  create temporary table snap_epoch as select * from public.ffm_epoch;
  create temporary table snap_mark as select * from public.ffm_sender_mark;
  create temporary table snap_addr as select * from public.contact_suppressions;
  create temporary table snap_phone as select * from public.ffm_phone_suppressions;
  create temporary table snap_log as select id from public.ffm_consent_log;
  if not public.ffm_outreach_gate_open() then raise exception 'R9 setup: gate not open at t0'; end if;
  l3 := public.ws_add_lead(a, null, 'Late optout', 'late-optout@example.com', '+1 613 555 0140', 'web');
  perform public.ffm_withdraw_consent(a, l3, 'all', 'reply STOP after t0', null, 'bot');
  e1 := (select epoch from public.ffm_epoch where id = 1);                                   -- the mark the sender kept OUTSIDE the database
  if e1 <= (select epoch from snap_epoch) then raise exception 'R9 setup: epoch did not move'; end if;
  if public.outreach_recipient_problem('email', 'late-optout@example.com', null) is distinct from 'suppressed' then raise exception 'R9 setup: late opt-out not suppressed'; end if;
  -- ---- RESTORE to t0 (triggers off: this is what a provider restore does, it is not a SQL statement anyone runs) ----
  set local session_replication_role = replica;
  delete from public.contact_suppressions where address not in (select address from snap_addr);
  delete from public.ffm_phone_suppressions where phone not in (select phone from snap_phone);
  delete from public.ffm_suppression_expected; insert into public.ffm_suppression_expected select * from snap_exp;
  delete from public.ffm_outreach_gate; insert into public.ffm_outreach_gate select * from snap_gate;
  delete from public.ffm_epoch; insert into public.ffm_epoch select * from snap_epoch;
  delete from public.ffm_sender_mark; insert into public.ffm_sender_mark select * from snap_mark;      -- the stored mark is rolled back too (it is in the same database)
  delete from public.ffm_restore_markers where id > (select verified_marker_id from snap_gate);
  delete from public.ffm_consent_log where id not in (select id from snap_log);
  set local session_replication_role = origin;
  if public.is_suppressed('late-optout@example.com') then raise exception 'R9 setup: the restore did not drop the late opt-out'; end if;
  -- R9a (a) THE EXPOSURE, stated honestly: with a fresh attestation inside the window and the restore within it, the DATABASE ALONE cannot tell. The old gate is OPEN and the lost opt-out is contactable.
  if not public.ffm_outreach_gate_open() or public.outreach_recipient_problem('email', 'late-optout@example.com', null) is not null then
    raise exception 'R9a the DB-only exposure window no longer behaves as documented (open + lost opt-out allowed) - re-read the policy section before changing this: gate_open=%', public.ffm_outreach_gate_open(); end if;
  -- R9b (b) the SENDER's first attestation closes it for good: its mark (e1) is ahead of the restored epoch
  r := pg_temp.svc(format($q$select public.ffm_sender_attest(2, %s, %L)::text$q$, e1, fp));
  if r not like '%rollback_detected%' then raise exception 'R9b the sender did not detect the restore: %', r; end if;
  if public.ffm_outreach_gate_open() or public.outreach_recipient_problem('email', 'late-optout@example.com', null) is distinct from 'suppression_unverified' or public.outreach_recipient_problem('email', 'anyone@example.com', null) is distinct from 'suppression_unverified' then
    raise exception 'R9c gate not closed for everyone after detection'; end if;
  -- R9c the old checkpoint is staged and the old list is a superset of it, so the OWNER'S verify would pass: that is why the sender (not the checkpoint) is the independent party, and why
  -- re-opening needs a verification made after the marker. The marker is in place, so the old verified_at no longer counts.
  if not exists (select 1 from public.ffm_restore_markers where source = 'detected_by_sender') then raise exception 'R9d no marker'; end if;
  -- R9d THE EXACT PITR SCENARIO for the anchor. The owner verifies the restored database (its OLD checkpoint passes: the old list is a superset of it) and the sender is then asked to anchor to the
  -- LOWER epoch. Without an owner-recorded restore after that, the database refuses (the detection marker does not count). Only record -> verify -> anchor lowers the mark.
  j := pg_temp.verify_gate();
  if not public.ffm_outreach_gate_open() then raise exception 'R9d setup: owner verification after the detection did not open the gate: %', j; end if;
  r := pg_temp.svc(format($q$select public.ffm_sender_attest(3, %s, %L)::text$q$, (select epoch from public.ffm_epoch where id = 1), fp));
  if r not like '%anchor_refused%' then raise exception 'R9d the anchor lowered the mark after an UNDETECTED/unrecorded restore: %', r; end if;
  r := pg_temp.svc(format($q$select public.ffm_sender_attest(2, %s, %L)::text$q$, (select epoch from public.ffm_epoch where id = 1) + 50, fp));      -- and a sender whose OUTSIDE mark is still ahead (the verification itself moved the epoch) sees the rollback: the old sender mark still sees the rollback (the gate closes again)
  if r not like '%rollback_detected%' or public.ffm_outreach_gate_open() then raise exception 'R9d2 the old mark no longer detects the restore: %', r; end if;
  perform pg_temp.as_owner(true); perform public.ffm_owner_record_restore('PITR to t0, owner confirmed'); perform pg_temp.as_owner(false);
  perform pg_temp.verify_gate();
  r := pg_temp.svc(format($q$select public.ffm_sender_attest(3, %s, %L)::text$q$, (select epoch from public.ffm_epoch where id = 1), fp));
  if r not like 'OK:%"ok": true%' or (select gen from public.ffm_sender_mark where id = 1) <> 3 or not public.ffm_outreach_gate_open() then raise exception 'R9e record -> verify -> anchor did not re-open: %', r; end if;
  -- R9f the same restore with NO sender running (or one that is down): the stale attestation closes it by itself once the window has passed
  set local session_replication_role = replica;
  delete from public.ffm_outreach_gate; insert into public.ffm_outreach_gate select * from snap_gate;
  delete from public.ffm_restore_markers where id > (select verified_marker_id from snap_gate);
  set local session_replication_role = origin;
  if not public.ffm_outreach_gate_open() then raise exception 'R9f setup: re-restored gate should be open inside the window: %', public.ffm_outreach_gate_status(); end if;
  perform pg_temp.age_gate(interval '16 minutes');
  if public.ffm_outreach_gate_open() or public.outreach_recipient_problem('email', 'late-optout@example.com', null) is distinct from 'suppression_unverified' then raise exception 'R9g a restored OPEN gate with no sender stayed open past the attestation window'; end if;

  -- R10 RESTORE WITHOUT VERIFIED SUPPRESSION STATE (what ops/restore_backup.py leaves behind): gate unverified, no key, empty lists, a checkpoint staged from the file
  perform pg_temp.as_owner(true); perform public.ffm_owner_record_restore('fixture: restore_backup.py'); perform pg_temp.as_owner(false);
  set local session_replication_role = replica;
  delete from public.ffm_secrets; delete from public.ffm_suppression_hashes; delete from public.contact_suppressions; delete from public.ffm_phone_suppressions;
  set local session_replication_role = origin;
  if public.ffm_outreach_gate_open() then raise exception 'R10 gate open after a restore with empty lists'; end if;
  foreach ch in array array['email', 'sms', 'phone', 'mail', 'telegram'] loop
    if public.ffm_can_contact(l1, ch) then raise exception 'R10b % contactable after a restore without verified suppression state', ch; end if;
  end loop;
  if public.outreach_recipient_problem('email', 'late-optout@example.com', null) is distinct from 'suppression_unverified' then raise exception 'R10c send decision after a restore'; end if;
  if (public.outreach_send_allowed((select id from public.outbox where channel = 'email' limit 1)) ->> 'allowed')::boolean then raise exception 'R10d outreach_send_allowed after a restore'; end if;
  -- the owner's verification with the key re-set but the LIST EMPTY must fail (incomplete) and the gate stays closed
  perform pg_temp.as_owner(true);
  perform public.ffm_set_key('suppression_hmac_key', encode(sha256(convert_to('v3-fixture-second-key', 'UTF8')), 'hex'), 'owner');
  j := public.ffm_verify_suppression('owner'); perform pg_temp.as_owner(false);
  if (j ->> 'verified')::boolean is not false or public.ffm_outreach_gate_open() then raise exception 'R10e verification passed on an empty list: %', j; end if;
  -- a database with NO gate row at all is closed (a wiped table)
  set local session_replication_role = replica; delete from public.ffm_outreach_gate; set local session_replication_role = origin;
  if public.ffm_outreach_gate_open() or public.outreach_recipient_problem('email', 'x@example.com', null) is distinct from 'suppression_unverified' then raise exception 'R10f missing gate row is open'; end if;

  -- S SERVICE KEY POWERS (post-lockdown: lockdown_v1 re-grants execute on every public function to service_role, so the safety is in the BODIES). Every new function is called as service_role with
  -- hostile arguments; each call must be refused or harmless, and the gate / epoch / stored mark must not have been moved by anything but the documented fail-closed paths.
  perform pg_temp.verify_gate();
  r := pg_temp.svc(format($q$select public.ffm_sender_attest(3, %s, %L)::text$q$, (select epoch from public.ffm_epoch where id = 1), fp));
  if not public.ffm_outreach_gate_open() then raise exception 'S0 setup: gate not open'; end if;
  create temporary table s_before as select (select epoch from public.ffm_sender_mark where id = 1) as me, (select gen from public.ffm_sender_mark where id = 1) as mg, (select count(*) from public.ffm_restore_markers) as mk,
                                           (select verified_at from public.ffm_outreach_gate where id = 1) as va, (select count(*) from public.app_owners) as ow;
  if exists (select 1 from pg_proc where proname in ('ffm_epoch_bump_now', 'ffm_record_restore') and pronamespace = 'public'::regnamespace) then raise exception 'S1b a removed bot-callable function exists again'; end if;
  foreach t in array array['select public.ffm_epoch_guard()', 'select public.ffm_epoch_bump()', 'select public.ffm_lead_identifier_guard()'] loop
    if pg_temp.svc(t) not like 'ERR:%trigger%' then raise exception 'S2 a trigger function is callable by service_role: % -> %', t, pg_temp.svc(t); end if;
  end loop;
  -- owner-only functions with hostile arguments
  foreach t in array array[$q$select public.ffm_owner_record_restore(NULL)$q$, $q$select public.ffm_owner_record_restore(repeat('x', 100000))$q$, $q$select public.ffm_owner_record_restore('''); drop table public.ffm_epoch; --')$q$,
                           $q$select public.ffm_set_gate_config(NULL, NULL, NULL)$q$, $q$select public.ffm_set_gate_config(120, 90, 'x')$q$, $q$select public.ffm_set_gate_config(-1, -1, NULL)$q$] loop
    if pg_temp.svc(t) not like 'ERR:owner approval required%' then raise exception 'S3 service_role ran an owner-only function: % -> %', t, pg_temp.svc(t); end if;
  end loop;
  -- ffm_sender_attest with hostile mark values: never opens, never lowers the stored mark, never lets a bot raise it past the database epoch
  foreach t in array array[$q$select public.ffm_sender_attest(-1, -1, 'x')$q$, $q$select public.ffm_sender_attest(0, 0, NULL)$q$, $q$select public.ffm_sender_attest(9223372036854775807, 1, 'x')$q$,
                           $q$select public.ffm_sender_attest(3, -9223372036854775807, NULL)$q$, $q$select public.ffm_sender_attest(1, 1, '')$q$, $q$select public.ffm_sender_attest(1, 1, repeat('9', 100000))$q$,
                           $q$select public.ffm_sender_attest(9223372036854775807, 9223372036854775807, NULL)$q$, $q$select public.ffm_sender_attest(4, 5, NULL)$q$] loop
    perform pg_temp.svc(t);
    perform pg_temp.verify_gate();
    r := pg_temp.svc(format($q$select public.ffm_sender_attest(3, %s, %L)::text$q$, (select epoch from public.ffm_epoch where id = 1), fp));
    if (select gen from public.ffm_sender_mark where id = 1) <> (select mg from s_before) then raise exception 'S4 hostile attest moved the stored generation: %', t; end if;
    if (select epoch from public.ffm_sender_mark where id = 1) > (select epoch from public.ffm_epoch where id = 1) then raise exception 'S4b hostile attest pushed the stored mark above the database epoch: %', t; end if;
  end loop;
  -- closing is the one thing the bot MAY do (it only reduces what is allowed); it must be audited, and it clears the verification so only the owner can re-open
  perform pg_temp.verify_gate();
  r := pg_temp.svc($q$select public.ffm_close_outreach_gate(NULL, NULL)$q$);
  if r not like 'OK:%' or public.ffm_outreach_gate_open() or (select verified_at from public.ffm_outreach_gate where id = 1) is not null then raise exception 'S5 bot close did not close cleanly: %', r; end if;
  if pg_temp.svc($q$select public.ffm_close_outreach_gate(repeat('z', 100000), '''; select 1; --')$q$) not like 'OK:%' then raise exception 'S5b hostile close text broke the call'; end if;
  if (select count(*) from public.app_owners) <> (select ow from s_before) then raise exception 'S6 owners changed'; end if;
  -- the bot cannot reopen it: verification is owner-only, and neither attest nor record_consent nor withdraw opens anything
  if pg_temp.svc($q$select public.ffm_verify_suppression('bot')$q$) not like 'ERR:owner approval required%' or public.ffm_outreach_gate_open() then raise exception 'S7 bot opened the gate'; end if;
  r := pg_temp.svc(format($q$select public.ffm_sender_attest(3, %s, %L)::text$q$, (select epoch from public.ffm_epoch where id = 1), fp));
  if public.ffm_outreach_gate_open() then raise exception 'S7b attest opened a closed gate'; end if;
  -- read-only helpers with hostile args are harmless
  if pg_temp.svc($q$select public.outreach_channel_problem(NULL)$q$) not like 'OK:%' or pg_temp.svc($q$select public.outreach_channel_problem(repeat('é', 100000))$q$) is distinct from 'OK:unknown_channel' then raise exception 'S8 outreach_channel_problem hostile args'; end if;
  perform pg_temp.verify_gate();

  -- N nothing here sent or authorised anything
  if exists (select 1 from public.outbox where status = 'sent') then raise exception 'N1 something was marked sent'; end if;
  if exists (select 1 from public.ws_campaigns where status = 'running') then raise exception 'N2 a campaign is running'; end if;
end $$;
rollback;
select 'consent_restore_gate_check: done';
