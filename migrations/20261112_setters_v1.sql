-- Donna setter program (commission-only appointment setters). Terms as decided Sep 30 2026:
-- $120 per closed deal; $50/month per active client once a setter has 3 closes; recurring pauses after 90 days with no
-- activity unless the setter told the owner in advance (notified_until). Paid Fridays by the OWNER (nothing here moves money).
-- Service-key only: RLS on, no policies, functions revoked from public/anon/authenticated.
create table if not exists public.setter_terms (
  id int primary key check (id = 1),
  close_cents int not null default 12000 check (close_cents >= 0),
  recurring_cents int not null default 5000 check (recurring_cents >= 0),
  recurring_after_closes int not null default 3 check (recurring_after_closes >= 1),
  lapse_days int not null default 90 check (lapse_days >= 1),
  updated_at timestamptz not null default now());
insert into public.setter_terms (id) values (1) on conflict do nothing;

create table if not exists public.setters (
  id uuid primary key default gen_random_uuid(),
  name text not null check (length(trim(name)) >= 2),
  contact text, niche text,
  status text not null default 'applied' check (status in ('applied','active','paused','removed')),
  first_booking_at timestamptz,
  notified_until date,
  notes text,
  created_at timestamptz not null default now());
create unique index if not exists setters_name_uq on public.setters (lower(trim(name)));

create table if not exists public.setter_events (
  id uuid primary key default gen_random_uuid(),
  setter_id uuid not null references public.setters(id) on delete cascade,
  kind text not null check (kind in ('booked','closed','client_cancelled')),
  client text, note text,
  at timestamptz not null default now());
create index if not exists setter_events_setter on public.setter_events (setter_id, at desc);

create table if not exists public.setter_payouts (
  id uuid primary key default gen_random_uuid(),
  setter_id uuid not null references public.setters(id) on delete cascade,
  kind text not null check (kind in ('close','recurring','bonus')),
  cents int not null check (cents > 0),
  period text,            -- 'YYYY-MM' for recurring, so a month is paid once
  reference text,
  paid_at timestamptz not null default now());
create unique index if not exists setter_payouts_period_uq on public.setter_payouts (setter_id, kind, period) where period is not null;

alter table public.setter_terms enable row level security;
alter table public.setters enable row level security;
alter table public.setter_events enable row level security;
alter table public.setter_payouts enable row level security;

create or replace view public.setter_standing as
with e as (
  select s.id, s.name, s.status, s.niche, s.contact, s.first_booking_at, s.notified_until,
         count(*) filter (where ev.kind = 'booked') booked,
         count(*) filter (where ev.kind = 'closed') closes,
         count(*) filter (where ev.kind = 'client_cancelled') cancels,
         max(ev.at) last_activity
  from public.setters s left join public.setter_events ev on ev.setter_id = s.id group by s.id),
t as (select * from public.setter_terms where id = 1)
select e.id, e.name, e.status, e.niche, e.contact, e.booked, e.closes, greatest(e.closes - e.cancels, 0) active_clients, e.last_activity,
  (e.closes >= t.recurring_after_closes
     and (coalesce(e.last_activity, e.first_booking_at) > now() - make_interval(days => t.lapse_days) or coalesce(e.notified_until, date '1970-01-01') >= current_date)) recurring_on,
  greatest(e.closes * t.close_cents - coalesce((select sum(p.cents) from public.setter_payouts p where p.setter_id = e.id and p.kind = 'close'), 0), 0) owed_close_cents,
  case when e.closes >= t.recurring_after_closes
        and (coalesce(e.last_activity, e.first_booking_at) > now() - make_interval(days => t.lapse_days) or coalesce(e.notified_until, date '1970-01-01') >= current_date)
        and not exists (select 1 from public.setter_payouts p where p.setter_id = e.id and p.kind = 'recurring' and p.period = to_char(now() at time zone 'America/Toronto', 'YYYY-MM'))
       then greatest(e.closes - e.cancels, 0) * t.recurring_cents else 0 end owed_recurring_cents
from e cross join t;

create or replace function public.setter_add(p_name text, p_contact text default null, p_niche text default null) returns jsonb
language plpgsql security definer set search_path to 'public' as $$
declare v_id uuid;
begin
  if length(trim(coalesce(p_name, ''))) < 2 then raise exception 'A setter needs a name.'; end if;
  insert into public.setters (name, contact, niche) values (trim(p_name), nullif(trim(p_contact), ''), nullif(trim(p_niche), ''))
    on conflict (lower(trim(name))) do update set contact = coalesce(nullif(trim(p_contact), ''), setters.contact), niche = coalesce(nullif(trim(p_niche), ''), setters.niche)
    returning id into v_id;
  return jsonb_build_object('id', v_id);
end $$;

create or replace function public.setter_log(p_name text, p_kind text, p_client text default null, p_note text default null) returns jsonb
language plpgsql security definer set search_path to 'public' as $$
declare s public.setters%rowtype; n int;
begin
  select * into s from public.setters where lower(trim(name)) = lower(trim(p_name));
  if not found then
    select count(*) into n from public.setters where lower(name) like lower(trim(p_name)) || '%';
    if n = 1 then select * into s from public.setters where lower(name) like lower(trim(p_name)) || '%';
    else return jsonb_build_object('error', case when n = 0 then 'No setter with that name.' else 'More than one setter matches; use the full name.' end); end if;
  end if;
  if s.status = 'removed' then return jsonb_build_object('error', 'That setter was removed.'); end if;
  if p_kind not in ('booked','closed','client_cancelled') then return jsonb_build_object('error', 'Kind must be booked, closed or client_cancelled.'); end if;
  insert into public.setter_events (setter_id, kind, client, note) values (s.id, p_kind, nullif(trim(p_client), ''), nullif(trim(p_note), ''));
  if p_kind = 'booked' and s.first_booking_at is null then
    update public.setters set first_booking_at = now(), status = 'active' where id = s.id;
    return jsonb_build_object('ok', true, 'name', s.name, 'first_booking', true);
  end if;
  return jsonb_build_object('ok', true, 'name', s.name, 'first_booking', false);
end $$;

create or replace function public.setter_record_payout(p_name text, p_kind text, p_cents int, p_reference text default null, p_period text default null) returns jsonb
language plpgsql security definer set search_path to 'public' as $$
declare s public.setters%rowtype; v_owed int; v_venture uuid;
begin
  select * into s from public.setters where lower(trim(name)) = lower(trim(p_name));
  if not found then return jsonb_build_object('error', 'No setter with that name.'); end if;
  if p_kind not in ('close','recurring','bonus') or coalesce(p_cents, 0) <= 0 then return jsonb_build_object('error', 'Need a kind (close, recurring, bonus) and an amount above zero.'); end if;
  if p_kind = 'close' then
    select owed_close_cents into v_owed from public.setter_standing where id = s.id;
    if p_cents > v_owed then return jsonb_build_object('error', format('Only $%s is owed for closed deals.', v_owed / 100.0)); end if;
  elsif p_kind = 'recurring' then
    p_period := coalesce(p_period, to_char(now() at time zone 'America/Toronto', 'YYYY-MM'));
    select owed_recurring_cents into v_owed from public.setter_standing where id = s.id;
    if p_cents > v_owed then return jsonb_build_object('error', format('Only $%s is owed as recurring this month.', v_owed / 100.0)); end if;
  end if;
  insert into public.setter_payouts (setter_id, kind, cents, period, reference) values (s.id, p_kind, p_cents, p_period, nullif(trim(p_reference), ''));
  select id into v_venture from public.ventures where slug = 'donna' limit 1;
  insert into public.ledger (venture_id, kind, amount_cents, currency, note, status)
    values (v_venture, 'expense', p_cents, 'CAD', format('Setter payout (%s): %s', p_kind, s.name), 'received');
  return jsonb_build_object('ok', true, 'name', s.name);
end $$;

revoke all on public.setter_terms, public.setters, public.setter_events, public.setter_payouts, public.setter_standing from public, anon, authenticated;
revoke all on function public.setter_add(text, text, text), public.setter_log(text, text, text, text), public.setter_record_payout(text, text, int, text, text) from public, anon, authenticated;
