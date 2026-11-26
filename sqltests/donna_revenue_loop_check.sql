-- Donna Revenue Loop v1 (migrations/20261210_donna_revenue_loop_v1.sql). ONE transaction, rolled back. Fresh apply, repo root.
-- Proves: money controls unchanged by the rollback and the re-apply; the rollback archives every fz_donna_rl table with its rows and leaves nothing behind
-- (and Donna Ops' own rollback still works after it); no API role reaches fz_donna_rl or the new functions; inbound -> CRM: express consent only from the
-- website box with its wording version, implied (inquiry) otherwise, idempotent per source + ref, never a downgrade, suppression = do-not-contact, works while
-- Donna is dormant; agent side refuses while dormant; staging hands a clean email draft to public.outbox as an owner-review 'draft' exactly once and refuses
-- placeholders, do-not-contact, suppression, no consent, non-email drafts; the outbox finally has the subject column hq_mail reads; follow-ups stop at 3 emails
-- and never stack on a waiting one; a brief needs a running offer-pricing run; the queue shows replies and briefs needed.
begin;
grant usage on schema public to anon, authenticated, service_role;
create function pg_temp.as_id(p_role text, p_sql text) returns text language plpgsql as $$
declare r text;
begin
  execute format('set local role %I', p_role);
  begin execute p_sql into r; exception when others then reset role; return 'ERR:' || sqlerrm; end;
  reset role;
  return 'OK:' || coalesce(r, '');
end $$;
create function pg_temp.bot(p_sql text) returns text language plpgsql as $$
declare r text; u text := current_setting('app.uid', true);
begin
  perform set_config('app.uid', '', true);
  begin execute p_sql into r; exception when others then perform set_config('app.uid', coalesce(u, ''), true); return 'ERR:' || sqlerrm; end;
  perform set_config('app.uid', coalesce(u, ''), true);
  return 'OK:' || coalesce(r, '');
end $$;
create function pg_temp.j(p text) returns jsonb language sql as $$ select case when p like 'OK:%' then substr(p, 4)::jsonb end $$;
create function pg_temp.expect(p_tag text, p_got text, p_like text) returns void language plpgsql as $$
begin
  if p_got is null or p_got not like p_like then raise exception '% expected [%] got [%]', p_tag, p_like, p_got; end if;
end $$;
create function pg_temp.ingest(p_source text, p_ref text, p_person text, p_biz text, p_email text, p_phone text, p_express boolean, p_version text, p_booked boolean,
                               p_at timestamptz default now()) returns text language sql as $$
  select pg_temp.bot(format($q$select public.donna_ingest_inbound(%L, %L, %L, %L, %L, %L, %L, %L, %L, %L, %L, %L, %L)::text$q$,
                            p_source, p_ref, p_at, p_person, p_biz, p_email, p_phone, p_express, p_version, p_booked, case when p_booked then 'Thu 2 pm' end,
                            'Leak estimate $3,428/month', 'wants calls answered'))
$$;
create function pg_temp.activate() returns void language plpgsql as $$
begin
  perform public.fz_owner_set_office_status('donna', 'active');
  update fz_office_os.fz_office_profiles set manager = coalesce(manager, 'rl manager'), status = 'active', activated_at = now() where slug = 'donna';
end $$;
create function pg_temp.deactivate() returns void language plpgsql as $$
begin
  perform public.fz_owner_set_office_status('donna', 'dormant');
  update fz_office_os.fz_office_profiles set status = 'dormant' where slug = 'donna';
end $$;

-- the production lock: audit_log and ledger are append-only
create or replace function public.fz_append_only_record() returns trigger language plpgsql set search_path to 'pg_catalog' as $$
begin raise exception '% is append-only', tg_relname using errcode = '42501'; end $$;
drop trigger if exists audit_log_append_only on public.audit_log;
create trigger audit_log_append_only before update or delete on public.audit_log for each row execute function public.fz_append_only_record();
drop trigger if exists ledger_append_only on public.ledger;
create trigger ledger_append_only before update or delete on public.ledger for each row execute function public.fz_append_only_record();

\ir include/money_fingerprint.sql
insert into auth.users (id, email) values ('99999999-9999-9999-9999-99999999d0e3', 'rl-owner@example.invalid') on conflict do nothing;
insert into public.app_owners (email) values ('rl-owner@example.invalid') on conflict do nothing;
select set_config('app.uid', '99999999-9999-9999-9999-99999999d0e3', true);
insert into public.contact_suppressions (address, reason, recorded_by) values ('gone@unsub.example', 'unsubscribe', 'test') on conflict do nothing;
create temp table rl_txt as select
  E'Hi Al, thanks for reaching out about your free Revenue Leak Audit. Pick a time here: https://donna.example/book\n--\nDonna.AI, a service of Example Holdings Inc.\nMailing address: 100 Example Street, Ottawa ON\nTo stop these emails, reply "unsubscribe".'::text good,
  E'Hi Al, thanks for reaching out about your free Revenue Leak Audit.\n--\nDonna.AI, a service of Example Holdings Inc.\nMailing address: [OWNER: mailing address]\nTo stop these emails, reply "unsubscribe".'::text placeholder;

-- R1 rollback: archives with rows, nothing left behind, money controls identical; re-apply twice; Donna Ops' own rollback still runs after it
\set fz_in_txn 1
select pg_temp.ingest('website_form', 'r1-seed-0001', 'Seed Person', 'Seed Co', 'seed@seed.example', null, false, null, false);
create temp table rl_fp_with as select * from pg_temp.fz_money_fp();
create temp table rl_ex0 as select count(*) n from public.audit_log where action = 'donna_revenue_loop_export';
\ir ../ops/rollback_donna_revenue_loop.sql
\ir ../ops/rollback_donna_revenue_loop.sql
do $$
begin
  if to_regnamespace('fz_donna_rl') is not null then raise exception 'R1 schema left behind'; end if;
  if exists (select 1 from pg_proc where pronamespace = 'public'::regnamespace and proname in ('donna_ingest_inbound', 'donna_inbound_recent', 'donna_lead_context',
             'donna_stage_outbox', 'donna_followups_due', 'donna_save_brief', 'donna_revenue_queue')) then raise exception 'R1 functions left behind'; end if;
  if (select count(*) from fz_archive.donna_rl_inbound) < 1 or to_regclass('fz_archive.donna_rl_staged') is null or to_regclass('fz_archive.donna_rl_briefs') is null then
    raise exception 'R1 tables not archived'; end if;
  if (select count(*) from public.audit_log where action = 'donna_revenue_loop_export') - (select n from rl_ex0) <> 1 then raise exception 'R1 export rows'; end if;
  if to_regprocedure('public.donna_pipeline(integer)') is null then raise exception 'R1 removed a Donna Ops function'; end if;
  if exists (select * from rl_fp_with except select * from pg_temp.fz_money_fp()) or exists (select * from pg_temp.fz_money_fp() except select * from rl_fp_with) then
    raise exception 'R1 money fingerprint changed by the rollback'; end if;
  if (select count(*) from rl_fp_with) < 300 then raise exception 'R1 fingerprint too small'; end if;
end $$;
\ir ../migrations/20261210_donna_revenue_loop_v1.sql
\ir ../migrations/20261210_donna_revenue_loop_v1.sql
do $$
begin
  if exists (select * from rl_fp_with except select * from pg_temp.fz_money_fp()) or exists (select * from pg_temp.fz_money_fp() except select * from rl_fp_with) then
    raise exception 'R1 money fingerprint changed by the re-apply'; end if;
  if (select count(*) from pg_constraint where conname = 'outbox_subject_len') <> 1 then raise exception 'R1 subject constraint not idempotent'; end if;
end $$;

-- R2 no API role reaches fz_donna_rl or the new functions
do $$
declare r text; f regprocedure;
begin
  foreach r in array array['anon', 'authenticated', 'service_role', 'fz_jarvis', 'fz_office_agent', 'fz_auditor', 'backup_reader'] loop
    continue when not exists (select 1 from pg_roles where rolname = r);
    if has_schema_privilege(r, 'fz_donna_rl', 'usage') then raise exception 'R2 % has usage on fz_donna_rl', r; end if;
  end loop;
  for f in select p.oid::regprocedure from pg_proc p where p.pronamespace = 'public'::regnamespace and p.proname in ('donna_ingest_inbound', 'donna_inbound_recent',
             'donna_lead_context', 'donna_stage_outbox', 'donna_followups_due', 'donna_save_brief', 'donna_revenue_queue') loop
    foreach r in array array['anon', 'authenticated', 'fz_jarvis', 'fz_office_agent', 'fz_auditor', 'backup_reader'] loop
      continue when not exists (select 1 from pg_roles where rolname = r);
      if has_function_privilege(r, f, 'execute') then raise exception 'R2 % can execute %', r, f; end if;
    end loop;
  end loop;
  perform pg_temp.expect('R2 anon', pg_temp.as_id('anon', $q$select public.donna_ingest_inbound('website_form', 'x-anon-001', now(), 'a', 'b', 'a@b.example', null, false, null, false, null, null, null)::text$q$),
                         'ERR:permission denied%');
  perform pg_temp.expect('R2 authenticated', pg_temp.as_id('authenticated', $q$select public.donna_revenue_queue()::text$q$), 'ERR:permission denied%');
  if not exists (select 1 from information_schema.columns where table_schema = 'public' and table_name = 'outbox' and column_name = 'subject') then raise exception 'R2 outbox.subject missing'; end if;
end $$;

-- R3 inbound -> CRM while Donna is DORMANT
do $$
declare r jsonb; v_lead uuid; v_v uuid := (select id from public.ventures where slug = 'donna');
begin
  perform pg_temp.deactivate();
  -- an inquiry without the marketing box: implied consent, new lead
  r := pg_temp.j(pg_temp.ingest('website_form', 'form-al-0001', 'Al', 'Al''s Diner', 'Al@AlsDiner.example', '613-555-0101', false, null, false));
  if r is null or not (r ->> 'new_lead')::boolean or r ->> 'status' <> 'new' or not (r ->> 'contactable')::boolean then raise exception 'R3 new %', r; end if;
  v_lead := (r ->> 'lead')::uuid;
  if (select consent_basis from public.leads where id = v_lead) <> 'implied_inquiry' or (select email from public.leads where id = v_lead) <> 'al@alsdiner.example'
     or (select name from public.leads where id = v_lead) <> 'Al''s Diner' or (select source from public.leads where id = v_lead) <> 'donna:website_form'
     or (select venture_id from public.leads where id = v_lead) <> v_v then raise exception 'R3 lead row'; end if;
  -- the same submission again: nothing new
  r := pg_temp.j(pg_temp.ingest('website_form', 'form-al-0001', 'Al', 'Al''s Diner', 'al@alsdiner.example', null, false, null, false));
  if not (r ->> 'duplicate')::boolean or (r ->> 'lead')::uuid <> v_lead then raise exception 'R3 duplicate %', r; end if;
  if (select count(*) from fz_donna_rl.inbound where lead_id = v_lead) <> 1 then raise exception 'R3 duplicate inbound row'; end if;
  -- a second submission with the box ticked: same lead (matched by phone), upgraded to express, booked
  r := pg_temp.j(pg_temp.ingest('website_form', 'form-al-0002', 'Al', 'Al''s Diner', null, '(613) 555-0101', true, 'webstudio-consent-v1', true));
  if (r ->> 'lead')::uuid <> v_lead or (r ->> 'new_lead')::boolean or r ->> 'status' <> 'booked' then raise exception 'R3 upgrade %', r; end if;
  if (select consent_basis from public.leads where id = v_lead) <> 'express_web_form' or (select status from public.leads where id = v_lead) <> 'booked' then raise exception 'R3 upgrade row'; end if;
  -- a later inquiry without the box never downgrades express consent
  perform pg_temp.ingest('phone_call', 'call-al-0003', 'Al', null, null, '+16135550101', false, null, false);
  if (select consent_basis from public.leads where id = v_lead) <> 'express_web_form' then raise exception 'R3 downgraded'; end if;
  -- express consent only from the website box, with its wording version
  perform pg_temp.expect('R3 express from a call', pg_temp.ingest('web_call', 'call-x-0004', 'X', 'X Co', 'x@x.example', null, true, 'webstudio-consent-v1', false), 'ERR:refused: express consent comes only%');
  perform pg_temp.expect('R3 express no version', pg_temp.ingest('website_form', 'form-x-0005', 'X', 'X Co', 'x@x.example', null, true, null, false), 'ERR:refused: express consent needs%');
  -- suppressed address: recorded, do-not-contact, not contactable
  r := pg_temp.j(pg_temp.ingest('website_form', 'form-gone-0006', 'Gone', 'Gone Co', 'gone@unsub.example', null, false, null, false));
  if (r ->> 'contactable')::boolean or not (select do_not_contact from public.leads where id = (r ->> 'lead')::uuid) then raise exception 'R3 suppression %', r; end if;
  -- a call with no contact: the inbound row only
  r := pg_temp.j(pg_temp.ingest('web_call', 'call-anon-0007', null, null, null, null, false, null, false));
  if r ->> 'lead' is not null or not exists (select 1 from fz_donna_rl.inbound where ref = 'call-anon-0007') then raise exception 'R3 no-contact %', r; end if;
  -- bad input
  perform pg_temp.expect('R3 future', pg_temp.ingest('website_form', 'form-fut-0008', 'F', 'F', 'f@f.example', null, false, null, false, now() + interval '1 day'), 'ERR:refused: received_at%');
  perform pg_temp.expect('R3 source', pg_temp.ingest('sms', 'sms-x-0009', 'F', 'F', 'f@f.example', null, false, null, false), 'ERR:refused: unknown inbound source%');
  perform pg_temp.expect('R3 ref', pg_temp.ingest('website_form', 'bad ref', 'F', 'F', 'f@f.example', null, false, null, false), 'ERR:refused: bad inbound ref%');
  -- a lead that was emailed and now writes in is a reply
  insert into public.leads (venture_id, name, email, status, consent_basis) values (v_v, 'Pine Roofing', 'hi@pine.example', 'contacted', 'implied_published');
  perform pg_temp.ingest('website_form', 'form-pine-0010', 'Pat', 'Pine Roofing', 'hi@pine.example', null, false, null, false);
  if (select status from public.leads where email = 'hi@pine.example') <> 'replied' or (select consent_basis from public.leads where email = 'hi@pine.example') <> 'implied_published' then
    raise exception 'R3 reply transition'; end if;
  if jsonb_array_length(pg_temp.j(pg_temp.bot($q$select public.donna_inbound_recent(20)::text$q$))) < 6 then raise exception 'R3 recent'; end if;
end $$;

-- R4 agent side refuses while Donna is dormant
do $$
declare v_lead uuid := (select id from public.leads where email = 'al@alsdiner.example');
begin
  perform pg_temp.expect('R4 context', pg_temp.bot(format($q$select public.donna_lead_context(%L)::text$q$, v_lead)), 'ERR:refused: Donna is dormant%');
  perform pg_temp.expect('R4 followups', pg_temp.bot($q$select public.donna_followups_due()::text$q$), 'ERR:refused: Donna is dormant%');
  perform pg_temp.expect('R4 stage', pg_temp.bot(format($q$select public.donna_stage_outbox(%L)::text$q$, gen_random_uuid())), 'ERR:refused: Donna is dormant%');
  perform pg_temp.expect('R4 queue readable', pg_temp.bot($q$select public.donna_revenue_queue()::text$q$), 'OK:%"active": false%');
end $$;

-- R5 staging: one clean email draft becomes ONE owner-review outbox draft; everything else is refused
do $$
declare v_run uuid; v_lead uuid := (select id from public.leads where email = 'al@alsdiner.example'); d_good uuid; d_ph uuid; d_dm uuid; r jsonb; c jsonb; v_ob uuid;
begin
  perform pg_temp.activate();
  c := pg_temp.j(pg_temp.bot(format($q$select public.donna_lead_context(%L)::text$q$, v_lead)));
  if c ->> 'business' <> 'Al''s Diner' or c ->> 'person' <> 'Al' or not (c -> 'inbound' ->> 'booked')::boolean or (c ->> 'has_email')::boolean is not true then raise exception 'R5 context %', c; end if;
  if c::text like '%alsdiner.example%' or c::text like '%555%' then raise exception 'R5 context leaks contact data %', c; end if;
  r := pg_temp.j(pg_temp.bot($q$select public.donna_revenue_queue()::text$q$));
  if not (r -> 'reply_needed') @> to_jsonb(v_lead::text) or not (r -> 'brief_needed') @> to_jsonb(v_lead::text) then raise exception 'R5 queue %', r; end if;
  v_run := (pg_temp.j(pg_temp.bot($q$select public.donna_run_begin('outreach-prep')::text$q$)) ->> 'run')::uuid;
  d_good := (pg_temp.j(pg_temp.bot(format($q$select public.donna_save_draft(%L, 'follow_up_email', 'email', %L, 'Your free Revenue Leak Audit', %L)::text$q$, v_run, v_lead, (select good from rl_txt)))) ->> 'draft')::uuid;
  d_dm := (pg_temp.j(pg_temp.bot(format($q$select public.donna_save_draft(%L, 'dm', 'dm', %L, null, %L)::text$q$, v_run, v_lead, replace((select good from rl_txt), 'unsubscribe', 'unsubscribe')))) ->> 'draft')::uuid;
  if d_good is null or d_dm is null then raise exception 'R5 drafts not saved'; end if;
  perform pg_temp.expect('R5 dm', pg_temp.bot(format($q$select public.donna_stage_outbox(%L)::text$q$, d_dm)), 'ERR:refused: only an email draft%');
  r := pg_temp.j(pg_temp.bot(format($q$select public.donna_stage_outbox(%L, 'inbound_reply')::text$q$, d_good)));
  v_ob := (r ->> 'outbox')::uuid;
  if v_ob is null or (r ->> 'duplicate')::boolean then raise exception 'R5 stage %', r; end if;
  if (select status from public.outbox where id = v_ob) <> 'draft' or not (select needs_owner from public.outbox where id = v_ob)
     or (select to_ref from public.outbox where id = v_ob) <> 'al@alsdiner.example' or (select subject from public.outbox where id = v_ob) <> 'Your free Revenue Leak Audit'
     or (select lead_id from public.outbox where id = v_ob) <> v_lead or (select idempotency_key from public.outbox where id = v_ob) <> 'donna-draft:' || d_good then raise exception 'R5 outbox row'; end if;
  r := pg_temp.j(pg_temp.bot(format($q$select public.donna_stage_outbox(%L)::text$q$, d_good)));
  if not (r ->> 'duplicate')::boolean or (select count(*) from public.outbox where idempotency_key = 'donna-draft:' || d_good) <> 1 then raise exception 'R5 staged twice %', r; end if;
  -- a placeholder (no mailing address yet) never reaches the outbox
  d_ph := (pg_temp.j(pg_temp.bot(format($q$select public.donna_save_draft(%L, 'follow_up_email', 'email', %L, 'Your audit', %L)::text$q$, v_run,
             (select id from public.leads where email = 'hi@pine.example'), (select placeholder from rl_txt)))) ->> 'draft')::uuid;
  perform pg_temp.expect('R5 placeholder', pg_temp.bot(format($q$select public.donna_stage_outbox(%L)::text$q$, d_ph)), 'ERR:refused: the draft still has an [OWNER%');
  -- the lead lost its consent basis, then became do-not-contact (which also suppresses the address), after the draft was written
  update fz_donna.drafts set body = (select good from rl_txt) where id = d_ph;
  update public.leads set consent_basis = null where email = 'hi@pine.example';
  perform pg_temp.expect('R5 consent', pg_temp.bot(format($q$select public.donna_stage_outbox(%L)::text$q$, d_ph)), 'ERR:refused: no consent basis%');
  update public.leads set consent_basis = 'implied_published' where email = 'hi@pine.example';
  insert into public.contact_suppressions (address, reason, recorded_by) values ('hi@pine.example', 'unsubscribe', 'test');
  perform pg_temp.expect('R5 suppressed', pg_temp.bot(format($q$select public.donna_stage_outbox(%L)::text$q$, d_ph)), 'ERR:refused: the %');
  update public.leads set do_not_contact = true where email = 'hi@pine.example';
  perform pg_temp.expect('R5 dnc', pg_temp.bot(format($q$select public.donna_stage_outbox(%L)::text$q$, d_ph)), 'ERR:refused: the lead is do-not-contact%');
  if exists (select 1 from public.outbox where lead_id = (select id from public.leads where email = 'hi@pine.example') and status = 'draft') then raise exception 'R5 refused draft reached the outbox'; end if;
  -- a decided draft is not staged
  update fz_donna.drafts set status = 'owner_rejected' where id = d_ph;
  perform pg_temp.expect('R5 decided', pg_temp.bot(format($q$select public.donna_stage_outbox(%L)::text$q$, d_ph)), 'ERR:refused: only a draft waiting%');
  if not exists (select 1 from public.audit_log where action = 'donna_stage_outbox' and target = 'outbox/' || v_ob) then raise exception 'R5 audit'; end if;
  r := pg_temp.j(pg_temp.bot($q$select public.donna_revenue_queue()::text$q$));
  if (r -> 'reply_needed') @> to_jsonb(v_lead::text) or (r ->> 'outbox_waiting')::int < 1 or (r ->> 'staged_today')::int <> 1 or (r ->> 'cold_staged_today')::int <> 0 then
    raise exception 'R5 queue after staging %', r; end if;
  perform pg_temp.bot(format($q$select public.donna_run_finish(%L, 'done', 'ok', '{}'::jsonb)::text$q$, v_run));
end $$;

-- fixture (as sqltests/venture_deals_replies_check.sql): open the outreach gate so the sent history below can exist; the rules under test are this migration's
set local session_replication_role = replica;
insert into public.ffm_secrets (name, value, set_by) values ('suppression_hmac_key', repeat('fixture-key-', 4), 'fixture') on conflict do nothing;
update public.ffm_outreach_gate set state = 'verified', verified_raw_count = 0, reason = 'test fixture', verified_at = clock_timestamp(), verified_epoch = 1, verified_marker_id = (select coalesce(max(id),0) from public.ffm_restore_markers), instance_fp = public.ffm_instance_fp(), attested_at = clock_timestamp() where id = 1;
set local session_replication_role = origin;
-- R6 follow-ups: due after a send, at most 3 emails, never on top of one waiting for the owner
do $$
declare v_v uuid := (select id from public.ventures where slug = 'donna'); a uuid; b uuid; c uuid; due jsonb;
begin
  insert into public.leads (venture_id, name, email, status, consent_basis, next_followup_at, last_contact_at) values
    (v_v, 'Birch Dental', 'hi@birch.example', 'contacted', 'implied_published', current_date - 1, now() - interval '4 days') returning id into a;
  insert into public.leads (venture_id, name, email, status, consent_basis, next_followup_at, last_contact_at) values
    (v_v, 'Maple Salon', 'hi@maple.example', 'contacted', 'implied_published', current_date - 1, now() - interval '4 days') returning id into b;
  insert into public.leads (venture_id, name, email, status, consent_basis, next_followup_at, last_contact_at) values
    (v_v, 'Elm Auto', 'hi@elm.example', 'contacted', 'implied_published', current_date - 1, now() - interval '4 days') returning id into c;
  insert into public.outbox (venture_id, channel, to_ref, body, status, lead_id, sent_at) values
    (v_v, 'email', 'hi@birch.example', 'first unsubscribe', 'sent', a, now() - interval '4 days'),
    (v_v, 'email', 'hi@maple.example', 'first unsubscribe', 'sent', b, now() - interval '9 days'),
    (v_v, 'email', 'hi@maple.example', 'second unsubscribe', 'sent', b, now() - interval '6 days'),
    (v_v, 'email', 'hi@maple.example', 'third unsubscribe', 'sent', b, now() - interval '4 days'),
    (v_v, 'email', 'hi@elm.example', 'first unsubscribe', 'sent', c, now() - interval '4 days'),
    (v_v, 'email', 'hi@elm.example', 'waiting unsubscribe', 'draft', c, null);
  due := pg_temp.j(pg_temp.bot($q$select public.donna_followups_due(50)::text$q$));
  if not due @> jsonb_build_array(jsonb_build_object('lead', a, 'step', 2)) then raise exception 'R6 birch not due %', due; end if;
  if due::text like '%' || b || '%' then raise exception 'R6 maple has 3 emails already'; end if;
  if due::text like '%' || c || '%' then raise exception 'R6 elm has one waiting'; end if;
end $$;

-- R7 a brief comes from a running offer-pricing run, for a Donna lead
do $$
declare v_run uuid; v_lead uuid := (select id from public.leads where email = 'al@alsdiner.example'); r jsonb;
begin
  v_run := (pg_temp.j(pg_temp.bot($q$select public.donna_run_begin('outreach-prep')::text$q$)) ->> 'run')::uuid;
  perform pg_temp.expect('R7 wrong mission', pg_temp.bot(format($q$select public.donna_save_brief(%L, %L, 'a brief body long enough to store')::text$q$, v_run, v_lead)),
                         'ERR:refused: a brief comes from a running offer-pricing%');
  perform pg_temp.bot(format($q$select public.donna_run_finish(%L, 'done', 'ok', '{}'::jsonb)::text$q$, v_run));
  v_run := (pg_temp.j(pg_temp.bot($q$select public.donna_run_begin('offer-pricing')::text$q$)) ->> 'run')::uuid;
  r := pg_temp.j(pg_temp.bot(format($q$select public.donna_save_brief(%L, %L, 'Audit brief for Al''s Diner: biggest leak is missed calls.')::text$q$, v_run, v_lead)));
  if r ->> 'brief' is null then raise exception 'R7 brief %', r; end if;
  perform pg_temp.expect('R7 not donna', pg_temp.bot(format($q$select public.donna_save_brief(%L, %L, 'a brief body long enough to store')::text$q$, v_run, gen_random_uuid())), 'ERR:refused: not a Donna lead%');
  r := pg_temp.j(pg_temp.bot($q$select public.donna_revenue_queue()::text$q$));
  if (r -> 'brief_needed') @> to_jsonb(v_lead::text) then raise exception 'R7 still needs a brief'; end if;
  perform pg_temp.bot(format($q$select public.donna_run_finish(%L, 'done', 'ok', '{}'::jsonb)::text$q$, v_run));
  perform pg_temp.deactivate();
end $$;

-- R8 Donna Ops' own rollback still runs with this migration applied (it drops the donna_* functions; this one's schema and tables stay for its own rollback)
\ir ../ops/rollback_donna_revenue_loop.sql
\ir ../ops/rollback_donna_ops.sql
do $$
begin
  if to_regnamespace('fz_donna') is not null or to_regnamespace('fz_donna_rl') is not null then raise exception 'R8 schemas left behind'; end if;
end $$;
select 'donna_revenue_loop_check ok';
rollback;
