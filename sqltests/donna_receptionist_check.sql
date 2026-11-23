-- Donna Receptionist v1 (migrations/20261206_donna_receptionist_v1.sql). ONE transaction, rolled back. Fresh apply, repo root.
-- Proves: money controls unchanged (with / without / re-applied) under the append-only audit_log + ledger lock; the rollback archives every table and leaves
-- nothing behind; no API role reaches fz_reception; owner-only controls; callers become leads of the client's workspace (existing CRM); NO text leaves demo mode;
-- live texts need the owner (per text, or his standing rule for text-back), the Donna office active, the business name + STOP, a missed call (text-back), consent
-- (follow-up) or a booking (confirmation); STOP withdraws consent through ffm_withdraw_consent and cancels queued texts; the send re-checks the suppression list.
begin;
grant usage on schema public to anon, authenticated, service_role;
create function pg_temp.as_id(p_role text, p_sql text) returns text language plpgsql as $$
declare r text; u text := current_setting('app.uid', true);
begin
  perform set_config('app.uid', '', true);
  execute format('set local role %I', p_role);
  begin execute p_sql into r; exception when others then reset role; perform set_config('app.uid', coalesce(u, ''), true); return 'ERR:' || sqlerrm; end;
  reset role;
  perform set_config('app.uid', coalesce(u, ''), true);
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
create function pg_temp.owner(p_sql text) returns text language plpgsql as $$
declare r text;
begin
  begin execute p_sql into r; exception when others then return 'ERR:' || sqlerrm; end;
  return 'OK:' || coalesce(r, '');
end $$;
create function pg_temp.j(p text) returns jsonb language sql as $$ select case when p like 'OK:%' then substr(p, 4)::jsonb end $$;
create function pg_temp.expect(p_tag text, p_got text, p_like text) returns void language plpgsql as $$
begin
  if p_got is null or p_got not like p_like then raise exception '% expected [%] got [%]', p_tag, p_like, p_got; end if;
end $$;
create function pg_temp.queue(p_sid text, p_kind text, p_body text) returns text language sql as $$
  select pg_temp.bot(format($q$select public.reception_queue_sms(%L, %L, %L)::text$q$, p_sid, p_kind, p_body))
$$;

-- the production lock: audit_log and ledger are append-only; this migration and its rollback only INSERT
create or replace function public.fz_append_only_record() returns trigger language plpgsql set search_path to 'pg_catalog' as $$
begin raise exception '% is append-only', tg_relname using errcode = '42501'; end $$;
drop trigger if exists audit_log_append_only on public.audit_log;
create trigger audit_log_append_only before update or delete on public.audit_log for each row execute function public.fz_append_only_record();
drop trigger if exists ledger_append_only on public.ledger;
create trigger ledger_append_only before update or delete on public.ledger for each row execute function public.fz_append_only_record();

\ir include/money_fingerprint.sql
insert into auth.users (id, email) values ('99999999-9999-9999-9999-99999999d0e1', 'fzr-owner@example.invalid') on conflict do nothing;
insert into public.app_owners (email) values ('fzr-owner@example.invalid') on conflict do nothing;
select set_config('app.uid', '99999999-9999-9999-9999-99999999d0e1', true);
insert into public.client_workspaces (slug, name, status) values ('fzr-dental', 'Maple Dental Demo', 'active'), ('fzr-salon', 'Birch Salon Demo', 'active');
create temp table fzr as select (select id from public.client_workspaces where slug = 'fzr-dental') ws1, (select id from public.client_workspaces where slug = 'fzr-salon') ws2;
create function pg_temp.cfg(p_name text) returns jsonb language sql as $$
  select jsonb_build_object('business_name', p_name, 'timezone', 'America/Toronto', 'hours', '{"mon": [["09:00", "17:00"]]}'::jsonb, 'services', '[]'::jsonb, 'faqs', '[]'::jsonb,
                            'escalation_number', '+15555550100', 'booking', '{"provider": "none"}'::jsonb, 'voice', '{"tts": "kokoro"}'::jsonb)
$$;

-- R1 money controls unchanged: with == after the rollback (twice) == re-applied; every table archived with its rows; nothing left behind
\set fz_in_txn 1
select public.reception_owner_set_client('dental', (select ws1 from fzr), pg_temp.cfg('Maple Dental'));
create temp table fzr_fp_with as select * from pg_temp.fz_money_fp();
create temp table fzr_ex0 as select count(*) n from public.audit_log where action = 'reception_export';
\ir ../ops/rollback_donna_receptionist.sql
\ir ../ops/rollback_donna_receptionist.sql
do $$
begin
  if to_regnamespace('fz_reception') is not null or exists (select 1 from pg_proc where proname like 'reception\_%') then raise exception 'R1 the rollback left objects behind'; end if;
  if (select count(*) from fz_archive.reception_clients) < 1 then raise exception 'R1 clients not archived'; end if;
  if (select count(*) from public.audit_log where action = 'reception_export') - (select n from fzr_ex0) <> 1 then raise exception 'R1 export rows'; end if;
  if exists (select * from fzr_fp_with except select * from pg_temp.fz_money_fp()) or exists (select * from pg_temp.fz_money_fp() except select * from fzr_fp_with) then
    raise exception 'R1 money fingerprint changed by the rollback'; end if;
end $$;
\ir ../migrations/20261206_donna_receptionist_v1.sql
\ir ../migrations/20261206_donna_receptionist_v1.sql
do $$
begin
  if exists (select * from fzr_fp_with except select * from pg_temp.fz_money_fp()) or exists (select * from pg_temp.fz_money_fp() except select * from fzr_fp_with) then
    raise exception 'R1 money fingerprint changed by the re-apply'; end if;
end $$;

-- R2 no API role reaches fz_reception or the reception_* functions
do $$
declare r text; f regprocedure;
begin
  foreach r in array array['anon', 'authenticated', 'service_role', 'fz_jarvis', 'fz_office_agent', 'fz_auditor'] loop
    continue when not exists (select 1 from pg_roles where rolname = r);
    if has_schema_privilege(r, 'fz_reception', 'usage') then raise exception 'R2 % has usage on fz_reception', r; end if;
  end loop;
  for f in select p.oid::regprocedure from pg_proc p where p.pronamespace = 'public'::regnamespace and p.proname like 'reception\_%' loop
    foreach r in array array['anon', 'authenticated', 'fz_jarvis', 'fz_office_agent', 'fz_auditor', 'backup_reader'] loop
      continue when not exists (select 1 from pg_roles where rolname = r);
      if has_function_privilege(r, f, 'execute') then raise exception 'R2 % can execute %', r, f; end if;
    end loop;
  end loop;
  perform pg_temp.expect('R2 anon', pg_temp.as_id('anon', $q$select public.reception_report()::text$q$), 'ERR:permission denied%');
  perform pg_temp.expect('R2 authenticated', pg_temp.as_id('authenticated', $q$select public.reception_call_event('dental', 'CA0000000001', '+15555550111', 'ringing')::text$q$), 'ERR:permission denied%');
end $$;

-- R3 owner-only controls
do $$
begin
  perform pg_temp.expect('R3 set client', pg_temp.bot(format($q$select public.reception_owner_set_client('dental', %L, %L)::text$q$, (select ws1 from fzr), pg_temp.cfg('Maple Dental'))), 'ERR:owner approval required%');
  perform pg_temp.expect('R3 flags', pg_temp.bot($q$select public.reception_owner_set_flags('dental', 'live', true, true)::text$q$), 'ERR:owner approval required%');
  perform pg_temp.expect('R3 decide', pg_temp.bot(format($q$select public.reception_owner_decide_sms(%L, true)::text$q$, gen_random_uuid())), 'ERR:owner approval required%');
  perform pg_temp.expect('R3 bad config', pg_temp.owner(format($q$select public.reception_owner_set_client('dental', %L, '{"business_name": "x"}')::text$q$, (select ws1 from fzr))), 'ERR:%clients_config_check%');
  perform public.reception_owner_set_client('dental', (select ws1 from fzr), pg_temp.cfg('Maple Dental'));
  perform public.reception_owner_set_client('salon', (select ws2 from fzr), pg_temp.cfg('Birch Salon'), '+15555550199');
  perform pg_temp.expect('R3 live needs a number', pg_temp.owner($q$select public.reception_owner_set_flags('dental', 'live', true, false)::text$q$), 'ERR:refused: set the client''s Twilio number first%');
end $$;

-- R4 callers become leads of the client's workspace (the existing CRM); the call belongs to one client
do $$
declare r jsonb; v_lead uuid;
begin
  r := pg_temp.j(pg_temp.bot($q$select public.reception_call_event('dental', 'CA0000000001', '+1 (555) 555-0111', 'ringing')::text$q$));
  v_lead := (r ->> 'lead')::uuid;
  if (select workspace_id from public.ws_leads where id = v_lead) is distinct from (select ws1 from fzr) or r ->> 'mode' <> 'demo' then raise exception 'R4 lead/mode %', r; end if;
  r := pg_temp.j(pg_temp.bot($q$select public.reception_call_event('dental', 'CA0000000002', '+15555550111', 'missed')::text$q$));
  if (r ->> 'lead')::uuid is distinct from v_lead then raise exception 'R4 the same caller got a second lead'; end if;
  perform pg_temp.expect('R4 other client', pg_temp.bot($q$select public.reception_call_event('salon', 'CA0000000001', '+15555550111', 'completed')::text$q$), 'ERR:refused: call belongs to another client%');
  r := pg_temp.j(pg_temp.bot($q$select public.reception_call_event('dental', 'CA0000000001', null, 'missed', 12)::text$q$));
  if r ->> 'status' <> 'missed' then raise exception 'R4 status %', r; end if;
  perform pg_temp.bot($q$select public.reception_call_event('dental', 'CA0000000001', null, 'completed', 12)::text$q$);
  if (select status from fz_reception.calls where call_sid = 'CA0000000001') <> 'missed' then raise exception 'R4 completed overwrote missed'; end if;
  perform pg_temp.bot($q$select public.reception_call_event('dental', 'CA0000000003', '+15555550111', 'answered', 95)::text$q$);
end $$;

-- R5 text-back rules in demo mode: off -> refused; on -> dry_run only (never sendable)
do $$
declare ok text := 'Hi, sorry we missed your call at Maple Dental. Want us to book you in? Reply STOP to opt out.'; r jsonb;
begin
  perform pg_temp.expect('R5 off', pg_temp.queue('CA0000000001', 'text_back', ok), 'ERR:refused: missed-call text-back is off%');
  perform public.reception_owner_set_flags('dental', 'demo', true, true);
  perform pg_temp.expect('R5 no business name', pg_temp.queue('CA0000000001', 'text_back', 'Sorry we missed you. Reply STOP to opt out.'), 'ERR:refused: a text must name the business%');
  perform pg_temp.expect('R5 no STOP', pg_temp.queue('CA0000000001', 'text_back', 'Sorry we missed you at Maple Dental.'), 'ERR:refused: a text must name the business%');
  perform pg_temp.expect('R5 answered call', pg_temp.queue('CA0000000003', 'text_back', ok), 'ERR:refused: a text-back answers a missed call%');
  r := pg_temp.j(pg_temp.queue('CA0000000001', 'text_back', ok));
  if r ->> 'status' <> 'dry_run' then raise exception 'R5 demo text is %', r; end if;
  perform pg_temp.expect('R5 one per call', pg_temp.queue('CA0000000001', 'text_back', ok), 'ERR:%reception_one_text_back%');
  perform pg_temp.expect('R5 claim dry_run', pg_temp.bot(format($q$select public.reception_claim_sms(%L)::text$q$, r ->> 'message')), 'ERR:refused: message is dry_run%');
  perform pg_temp.expect('R5 owner cannot approve dry_run', pg_temp.owner(format($q$select public.reception_owner_decide_sms(%L, true)::text$q$, r ->> 'message')), 'ERR:refused: no pending text%');
  perform pg_temp.expect('R7 follow-up without consent', pg_temp.queue('CA0000000003', 'follow_up', 'Thanks for calling Maple Dental. Reply STOP to opt out.'), 'ERR:refused: no current SMS consent%');
  perform pg_temp.expect('R7 confirm without booking', pg_temp.queue('CA0000000003', 'booking_confirm', 'Maple Dental: booked. Reply STOP to opt out.'), 'ERR:refused: no booking on this call%');
  perform pg_temp.bot($q$select public.reception_booking_record('CA0000000003', 'cal:bk_123')::text$q$);
  perform pg_temp.expect('R7 confirm', pg_temp.queue('CA0000000003', 'booking_confirm', 'Maple Dental: you are booked for Tue 10:00. Reply STOP to opt out.'), 'OK:%dry_run%');
end $$;

-- R6 live: per-text owner approval (or his standing rule), Donna active, re-check at send
do $$
declare r jsonb; m uuid; ok text := 'Hi, Birch Salon here: sorry we missed your call. Reply STOP to opt out.';
begin
  perform public.reception_owner_set_flags('salon', 'live', true, false);
  perform pg_temp.bot($q$select public.reception_call_event('salon', 'CA0000000101', '+15555550122', 'missed')::text$q$);
  r := pg_temp.j(pg_temp.queue('CA0000000101', 'text_back', ok));
  if r ->> 'status' <> 'dry_run' then raise exception 'R6 Donna dormant must stay dry_run: %', r; end if;
  -- Donna active (M1 + M7 profile)
  perform public.fz_owner_set_office_status('donna', 'active');
  update fz_office_os.fz_office_profiles set manager = coalesce(manager, 'fzr manager'), status = 'active', activated_at = now() where slug = 'donna';
  perform pg_temp.bot($q$select public.reception_call_event('salon', 'CA0000000102', '+15555550122', 'missed')::text$q$);
  r := pg_temp.j(pg_temp.queue('CA0000000102', 'text_back', ok));
  if r ->> 'status' <> 'pending_approval' then raise exception 'R6 live text must wait for the owner: %', r; end if;
  m := (r ->> 'message')::uuid;
  perform pg_temp.expect('R6 claim pending', pg_temp.bot(format($q$select public.reception_claim_sms(%L)::text$q$, m)), 'ERR:refused: message is pending_approval%');
  perform public.reception_owner_decide_sms(m, true);
  if not (pg_temp.j(pg_temp.bot($q$select public.reception_pending_sends()::text$q$)) @> to_jsonb(array[m::text])) then raise exception 'R6 approved text not in the send list'; end if;
  perform pg_temp.expect('R6 claim', pg_temp.bot(format($q$select public.reception_claim_sms(%L)::text$q$, m)), 'OK:{"to": "+15555550122"%"from": "+15555550199"%');
  perform pg_temp.expect('R6 mark', pg_temp.bot(format($q$select public.reception_mark_sms(%L, true, 'SM0000000000001')::text$q$, m)), 'OK:%sent%');
  perform pg_temp.expect('R6 mark twice', pg_temp.bot(format($q$select public.reception_mark_sms(%L, true, 'SM0000000000001')::text$q$, m)), 'ERR:refused: message is not sending%');
  -- the owner's standing rule for text-back: approved without a per-text decision
  perform public.reception_owner_set_flags('salon', 'live', true, true);
  perform pg_temp.bot($q$select public.reception_call_event('salon', 'CA0000000103', '+15555550133', 'missed')::text$q$);
  r := pg_temp.j(pg_temp.queue('CA0000000103', 'text_back', ok));
  if r ->> 'status' <> 'approved' or (select decided_by from fz_reception.messages where id = (r ->> 'message')::uuid) <> 'owner:standing' then raise exception 'R6 standing %', r; end if;
  -- the send re-checks consent: a withdrawal recorded elsewhere cancels the approved text
  perform public.ffm_withdraw_consent((select ws2 from fzr), (select lead_id from fz_reception.calls where call_sid = 'CA0000000103'), 'sms', 'fzr test', 'ev-1', 'fzr');
  perform pg_temp.expect('R6 re-check at send', pg_temp.bot(format($q$select public.reception_claim_sms(%L)::text$q$, r ->> 'message')), 'OK:%"status": "cancelled"%');
  if (select status from fz_reception.messages where id = (r ->> 'message')::uuid) <> 'cancelled' then raise exception 'R6 not cancelled'; end if;
  -- standing never applies to follow-ups; standing is off when text-back is off
  perform public.reception_owner_set_flags('salon', 'live', false, true);
  if (select text_back_standing from fz_reception.clients where slug = 'salon') then raise exception 'R6 standing without text-back'; end if;
  -- Donna goes inactive: a live call's text is only a dry run, and an approved text can no longer be claimed
  perform public.reception_owner_set_flags('salon', 'live', true, false);
  perform pg_temp.bot($q$select public.reception_call_event('salon', 'CA0000000105', '+15555550166', 'missed')::text$q$);
  perform pg_temp.bot($q$select public.reception_call_event('salon', 'CA0000000106', '+15555550177', 'missed')::text$q$);
  m := (pg_temp.j(pg_temp.queue('CA0000000105', 'text_back', ok)) ->> 'message')::uuid;
  perform public.reception_owner_decide_sms(m, true);
  perform public.fz_owner_set_office_status('donna', 'dormant');
  perform pg_temp.expect('R6 claim with Donna dormant', pg_temp.bot(format($q$select public.reception_claim_sms(%L)::text$q$, m)), 'ERR:refused: client is not live (or the Donna office%');
  perform pg_temp.expect('R6 queue with Donna dormant', pg_temp.queue('CA0000000106', 'text_back', ok), 'OK:%"status": "dry_run"%');
  perform public.fz_owner_set_office_status('donna', 'active');
  -- paused: nothing is queued
  perform public.reception_owner_set_flags('salon', 'paused', true, false);
  perform pg_temp.expect('R6 paused', pg_temp.queue('CA0000000102', 'text_back', ok), 'ERR:refused: client salon is paused%');
  perform public.reception_owner_set_flags('salon', 'live', true, false);
end $$;

-- R8 STOP withdraws SMS consent through the existing CASL path and cancels queued texts; later texts refuse
do $$
declare r jsonb; v_lead uuid := (select lead_id from fz_reception.calls where call_sid = 'CA0000000101');
begin
  perform pg_temp.bot($q$select public.reception_call_event('salon', 'CA0000000104', '+15555550122', 'missed')::text$q$);
  r := pg_temp.j(pg_temp.queue('CA0000000104', 'text_back', 'Birch Salon: sorry we missed you. Reply STOP to opt out.'));
  if r ->> 'status' <> 'pending_approval' then raise exception 'R8 setup %', r; end if;
  if (pg_temp.j(pg_temp.bot($q$select public.reception_inbound_sms('salon', '+15555550122', 'thanks!', 'SM0000000000002')::text$q$)) ->> 'opted_out')::boolean then raise exception 'R8 not a STOP'; end if;
  r := pg_temp.j(pg_temp.bot($q$select public.reception_inbound_sms('salon', '+1 555 555 0122', ' Stop. ', 'SM0000000000003')::text$q$));
  if not (r ->> 'opted_out')::boolean or (r ->> 'cancelled')::int < 1 then raise exception 'R8 STOP %', r; end if;
  if exists (select 1 from fz_reception.messages where to_phone = '+15555550122' and status in ('pending_approval', 'approved', 'dry_run')) then raise exception 'R8 queued texts survived STOP'; end if;
  if not exists (select 1 from public.ffm_consent_log where lead_id = v_lead and basis = 'withdrawn' and channel = 'sms') then raise exception 'R8 no withdrawal in the consent log'; end if;
  perform pg_temp.expect('R8 after STOP', pg_temp.queue('CA0000000104', 'text_back', 'Birch Salon: sorry we missed you. Reply STOP to opt out.'), 'ERR:refused: the number is suppressed or opted out%');
  -- ARRET (French) is a STOP too; a STOP is honoured while the client is paused
  perform public.reception_owner_set_flags('salon', 'paused', false, false);
  perform pg_temp.expect('R8 paused STOP', pg_temp.bot($q$select public.reception_inbound_sms('salon', '+15555550144', 'ARRÊT', 'SM0000000000004')::text$q$), 'OK:%"opted_out": true%');
end $$;

-- R10 daily ceiling; R11 report
do $$
declare r jsonb;
begin
  perform public.reception_owner_set_flags('dental', 'demo', true, false, 1);
  perform pg_temp.bot($q$select public.reception_call_event('dental', 'CA0000000005', '+15555550155', 'missed')::text$q$);
  perform pg_temp.expect('R10 ceiling', pg_temp.queue('CA0000000005', 'text_back', 'Maple Dental: sorry we missed you. Reply STOP to opt out.'), 'ERR:refused: daily text ceiling%');
  r := pg_temp.j(pg_temp.bot($q$select public.reception_report()::text$q$));
  if (select (x ->> 'calls_7d')::int from jsonb_array_elements(r) x where x ->> 'client' = 'dental') <> 4 then raise exception 'R11 report %', r; end if;
  if (select (x ->> 'booked_7d')::int from jsonb_array_elements(r) x where x ->> 'client' = 'dental') <> 1 then raise exception 'R11 booked %', r; end if;
  perform pg_temp.expect('R11 scoped', pg_temp.as_id('authenticated', $q$select public.reception_report()::text$q$), 'ERR:permission denied%');
end $$;
select 'donna_receptionist_check ok';
rollback;
