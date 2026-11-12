create table if not exists public.dayjob_days (
  day date primary key,
  dials int not null default 0,
  pitches int not null default 0,
  submissions int not null default 0,
  paid_deals int not null default 0,
  updated_at timestamptz not null default now()
);
alter table public.dayjob_days enable row level security;
create table if not exists public.dayjob_targets (
  id int primary key default 1 check (id = 1),
  dials_per_day int not null default 250,
  pitches_per_day int not null default 6,
  submissions_per_day int not null default 2,
  paid_deals_per_week int not null default 5,
  payout_cents_per_deal int not null default 100000
);
alter table public.dayjob_targets enable row level security;
insert into public.dayjob_targets (id) values (1) on conflict do nothing;
create or replace function public.dayjob_week_text() returns text
language sql stable set search_path = public as $$
  with wk as (
    select coalesce(sum(dials),0) d, coalesce(sum(pitches),0) p, coalesce(sum(submissions),0) s, coalesce(sum(paid_deals),0) pd,
           count(*) filter (where dials > 0 or pitches > 0) days_logged
    from dayjob_days where day >= date_trunc('week', (now() at time zone 'America/Toronto')::date)::date
  ), t as (select * from dayjob_targets where id = 1)
  select format('Sales week so far: %s dials, %s pitches, %s submissions, %s paid of %s target ($%s). Days logged: %s.',
                wk.d, wk.p, wk.s, wk.pd, t.paid_deals_per_week, to_char(wk.pd * t.payout_cents_per_deal / 100.0, 'FM999,990'), wk.days_logged)
  from wk, t;
$$;