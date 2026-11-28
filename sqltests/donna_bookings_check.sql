-- Donna Bookings v1 (migrations/20261214_donna_bookings_v1.sql). ONE transaction, rolled back. Fresh apply, repo root.
-- Proves: a website-calendar booking becomes a booked lead with implied consent and a "booked on the website calendar" note; a booking can never carry express
-- consent; the same booking twice is a duplicate; a booking for an existing lead moves it to booked; the old sources still work; unknown sources are still refused;
-- rollback restores the old function, keeps the booking rows (never deleted) and so keeps the widened check; with no booking rows it restores the original check.
begin;
do $$
declare r jsonb; l public.leads; ok boolean;
begin
  r := public.donna_ingest_inbound('booking', 'cal-aud1', now() - interval '1 hour', 'Pat Lee', 'Pine Plumbing', 'pat@pine.example', '613 555 0142', false, null, true,
                                   'Thu Dec 3, 10 AM', null, 'We miss calls on jobs');
  if not (r ->> 'new_lead')::boolean or r ->> 'status' <> 'booked' then raise exception 'B1 booking did not make a booked lead %', r; end if;
  select * into l from public.leads where id = (r ->> 'lead')::uuid;
  if l.consent_basis <> 'implied_inquiry' or l.source <> 'donna:booking' or l.notes !~ 'booked on the website calendar' or l.notes !~ 'booked the audit Thu Dec 3' then
    raise exception 'B1 lead wrong: % % %', l.consent_basis, l.source, l.notes; end if;
  if not (public.donna_ingest_inbound('booking', 'cal-aud1', now() - interval '1 hour', 'Pat Lee', null, 'pat@pine.example', null, false, null, true, null, null, null) ->> 'duplicate')::boolean then
    raise exception 'B2 same booking twice is not a duplicate'; end if;
  begin
    perform public.donna_ingest_inbound('booking', 'cal-aud2', now(), 'X', null, 'x@ex.example', null, true, 'v1', true, null, null, null);
    raise exception 'B3 express consent accepted from a booking';
  exception when others then
    if sqlerrm !~ 'express consent comes only from the website form' then raise; end if;
  end;
  r := public.donna_ingest_inbound('website_form', 'nf-sam1', now() - interval '2 days', 'Sam', 'Oak Dental', 'sam@oak.example', null, false, null, false, null, null, 'hi');
  if r ->> 'status' <> 'new' then raise exception 'B4 form lead %', r; end if;
  r := public.donna_ingest_inbound('booking', 'cal-sam1', now(), 'Sam', 'Oak Dental', 'sam@oak.example', null, false, null, true, 'Fri Dec 4, 2 PM', null, null);
  if (r ->> 'new_lead')::boolean or r ->> 'status' <> 'booked' then raise exception 'B4 existing lead not moved to booked %', r; end if;
  begin
    perform public.donna_ingest_inbound('fax', 'fx-1', now(), 'X', null, 'y@ex.example', null, false, null, false, null, null, null);
    raise exception 'B5 unknown source accepted';
  exception when others then
    if sqlerrm !~ 'unknown inbound source' then raise; end if;
  end;
  -- B9 a calendar booking made now for an audit in 5 days: its time is kept, and it is not "stuck" until a day after the audit
  r := public.donna_ingest_inbound('booking', 'cal-fut1', now() - interval '3 days', 'Kim', 'Fir Salon', 'kim@fir.example', null, false, null, true, 'Wed', null, null,
                                   now() + interval '5 days');
  if (select appointment_at from fz_donna_rl.inbound where ref = 'cal-fut1') is null then raise exception 'B9 appointment_at not kept'; end if;
  if exists (select 1 from jsonb_array_elements(public.donna_stuck_deals(50)) e where e ->> 'name' = 'Fir Salon') then raise exception 'B9 future audit listed as stuck'; end if;
  update fz_donna_rl.inbound set appointment_at = now() - interval '2 days' where ref = 'cal-fut1';
  if not exists (select 1 from jsonb_array_elements(public.donna_stuck_deals(50)) e where e ->> 'name' = 'Fir Salon' and e ->> 'kind' = 'audit_no_proposal') then
    raise exception 'B9 past audit without a proposal not listed'; end if;
  perform public.donna_ingest_inbound('booking', 'cal-odd1', now(), 'Q', null, 'q@ex.example', null, false, null, true, null, null, null, now() + interval '5 years');
  if (select appointment_at from fz_donna_rl.inbound where ref = 'cal-odd1') is not null then raise exception 'B9 absurd appointment time kept'; end if;
end $$;
\set fz_in_txn 1
\ir ../ops/rollback_donna_bookings.sql
\ir ../ops/rollback_donna_bookings.sql
do $$
begin
  if (select count(*) from fz_donna_rl.inbound where source = 'booking') <> 4 then raise exception 'B6 rollback lost booking rows'; end if;
  if not exists (select 1 from pg_constraint where conrelid = 'fz_donna_rl.inbound'::regclass and contype = 'c' and pg_get_constraintdef(oid) like '%booking%') then
    raise exception 'B6 check narrowed under existing booking rows'; end if;
  if (select count(*) from public.audit_log where action = 'donna_bookings_rollback') <> 1 then raise exception 'B6 rollback audit rows: second run must be a no-op'; end if;
  if to_regprocedure('public.donna_ingest_inbound(text, text, timestamptz, text, text, text, text, boolean, text, boolean, text, text, text, timestamptz)') is not null then
    raise exception 'B6 new signature left behind'; end if;
  begin
    perform public.donna_ingest_inbound('booking', 'cal-aud9', now(), 'Z', null, 'z@ex.example', null, false, null, true, null, null, null);
    raise exception 'B6 old function still takes bookings';
  exception when others then
    if sqlerrm !~ 'unknown inbound source' then raise; end if;
  end;
end $$;
\ir ../migrations/20261214_donna_bookings_v1.sql
\ir ../migrations/20261214_donna_bookings_v1.sql
do $$ begin
  if (select count(*) from pg_constraint where conrelid = 'fz_donna_rl.inbound'::regclass and contype = 'c' and pg_get_constraintdef(oid) like '%source%') <> 1 then
    raise exception 'B7 re-apply left two source checks'; end if;
  delete from fz_donna_rl.inbound where source = 'booking';          -- inside the rolled-back test transaction only: the no-booking-rows rollback path
end $$;
\ir ../ops/rollback_donna_bookings.sql
do $$ begin
  if exists (select 1 from pg_constraint where conrelid = 'fz_donna_rl.inbound'::regclass and contype = 'c' and pg_get_constraintdef(oid) like '%booking%') then
    raise exception 'B8 original check not restored'; end if;
end $$;
\ir ../migrations/20261214_donna_bookings_v1.sql
select 'donna_bookings_check ok';
rollback;
