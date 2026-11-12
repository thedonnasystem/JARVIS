-- Phase 7 learning loop (deterministic, no model spend): compare what each completed mission PROMISED with what happened.
-- Promised = expected_cad and days_to_cash from the evaluation. Actual = cash RECEIVED in the venture's ledger since the mission
-- completed (attribution is approximate: it is venture cash, not proven mission cash; the lesson says so).
-- The result is written as a 'lesson' into memory, which every agent prompt already reads, so forecasts calibrate over time.

create table if not exists public.mission_outcomes (
  mission_id uuid primary key references public.missions(id) on delete cascade,
  venture_id uuid,
  expected_cad numeric,
  expected_days int,
  actual_cad numeric not null default 0,
  ratio numeric,                      -- actual / expected, null when nothing was expected
  verdict text,                       -- hit (>=0.8), partial (0.3-0.8), miss (<0.3), no_forecast
  measured_at timestamptz not null default now()
);
alter table public.mission_outcomes enable row level security;

create or replace function public.measure_mission_outcomes() returns int
language plpgsql set search_path to 'public' as $$
declare m record; v_actual numeric; v_ratio numeric; v_verdict text; n int := 0;
begin
  for m in select * from public.missions mi
           where mi.status = 'completed' and mi.completed_at is not null
             and now() >= mi.completed_at + make_interval(days => coalesce(mi.days_to_cash, 0) + 7)
             and not exists (select 1 from public.mission_outcomes o where o.mission_id = mi.id)
           limit 20 loop
    select coalesce(sum(amount_cents), 0) / 100.0 into v_actual from public.ledger
      where venture_id = m.venture_id and kind = 'revenue' and status = 'received' and not coalesce(intercompany, false)
        and occurred_on >= m.completed_at::date;
    v_ratio := case when coalesce(m.expected_cad, 0) > 0 then round(v_actual / m.expected_cad, 2) else null end;
    v_verdict := case when v_ratio is null then 'no_forecast' when v_ratio >= 0.8 then 'hit' when v_ratio >= 0.3 then 'partial' else 'miss' end;
    insert into public.mission_outcomes (mission_id, venture_id, expected_cad, expected_days, actual_cad, ratio, verdict)
    values (m.id, m.venture_id, m.expected_cad, m.days_to_cash, round(v_actual, 2), v_ratio, v_verdict);
    insert into public.memory (venture_id, agent, kind, content, confidence)
    values (m.venture_id, 'system', 'lesson',
      format('Forecast check: mission "%s" %s; venture cash received since completion is $%s CAD (%s). %s',
             left(m.title, 80),
             case when m.expected_cad is null then 'gave no dollar forecast'
                  else 'expected $' || round(m.expected_cad, 2) || ' CAD in ' || coalesce(m.days_to_cash::text, '?') || ' days' end,
             round(v_actual, 2), v_verdict,
             case v_verdict when 'miss' then 'Treat similar forecasts as optimistic; ask for evidence of demand before counting on this number.'
                            when 'no_forecast' then 'No dollar forecast was given: always state expected CAD and days to cash.'
                            when 'partial' then 'Forecast was directionally right but high; discount similar forecasts.'
                            else 'Forecast held; the method is worth repeating.' end),
      'medium');
    n := n + 1;
  end loop;
  return n;
end $$;

-- How optimistic are we? One line per venture, shown in the weekly review and the brief.
create or replace function public.forecast_bias_text() returns text language sql stable set search_path to 'public' as $$
  select coalesce(string_agg(format('%s: %s of %s forecasts held (avg actual/expected %s)', coalesce(v.slug, 'company'), x.hits, x.n, coalesce(x.avg_ratio::text, 'n/a')), E'\n'),
                  'No measured forecasts yet.')
  from (select venture_id, count(*) n, count(*) filter (where verdict = 'hit') hits, round(avg(ratio), 2) avg_ratio
        from public.mission_outcomes where verdict <> 'no_forecast' group by venture_id) x
  left join public.ventures v on v.id = x.venture_id
$$;

-- Run every 6 hours (pg_cron). Safe to re-run: each mission is measured once.
do $$ begin
  if exists (select 1 from pg_namespace where nspname = 'cron') then
    perform cron.unschedule(jobid) from cron.job where jobname = 'hq-learning';
    perform cron.schedule('hq-learning', '15 */6 * * *', 'select public.measure_mission_outcomes()');
  end if;
end $$;
