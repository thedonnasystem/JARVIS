-- Holding company view + earn-your-keep. Depends on org_v1 (org_changes) and capital_v1 (ledger statuses).
-- * holding_pnl(days): per-venture and total P&L. Only RECEIVED cash counts as revenue; expected/signed/qualified/estimates are reported
--   separately as pipeline and never added to cash. Intercompany rows are excluded from the total.
-- * flag_underperformers(): agents that cost money but finished nothing (or cost far more per finished task than their peers) are put
--   forward as 'shutdown' proposals. The owner decides; nothing is paused automatically.

alter table public.org_changes add column if not exists target text;

create or replace function public.holding_pnl(p_days int default 30) returns jsonb
language plpgsql stable set search_path to 'public' as $$
declare since_ timestamptz := now() - make_interval(days => greatest(1, least(coalesce(p_days, 30), 365))); r jsonb; tot jsonb; h_ai int;
begin
  select coalesce(jsonb_agg(row_to_json(x)::jsonb order by x.net_cents desc), '[]'::jsonb) into r from (
    select coalesce(v.slug, 'holding') as venture, coalesce(v.name, 'Holding / unassigned') as name,
      coalesce(sum(l.amount_cents) filter (where l.kind = 'revenue' and l.status = 'received'), 0)::int as revenue_cents,
      coalesce(sum(l.amount_cents) filter (where l.kind = 'expense' and l.status = 'received'), 0)::int as expense_cents,
      coalesce((select sum(coalesce(c.actual_cents, c.reserved_cents)) from public.llm_calls c join public.agents a on a.slug = c.agent_slug
                where a.venture_id = v.id and c.status in ('reserved','done') and c.started_at >= since_), 0)::int as ai_cents,
      (coalesce(sum(l.amount_cents) filter (where l.kind = 'revenue' and l.status = 'received'), 0)
       - coalesce(sum(l.amount_cents) filter (where l.kind = 'expense' and l.status = 'received'), 0)
       - coalesce((select sum(coalesce(c.actual_cents, c.reserved_cents)) from public.llm_calls c join public.agents a on a.slug = c.agent_slug
                where a.venture_id = v.id and c.status in ('reserved','done') and c.started_at >= since_), 0))::int as net_cents,
      coalesce(sum(l.amount_cents) filter (where l.kind = 'revenue' and l.status in ('signed','qualified')), 0)::int as pipeline_cents,
      coalesce(sum(l.amount_cents) filter (where l.kind = 'revenue' and l.status in ('expected','estimate','forecast')), 0)::int as forecast_cents
    from public.ventures v
    full join (select * from public.ledger where created_at >= since_ and not coalesce(intercompany, false)) l on l.venture_id = v.id
    group by v.id, v.slug, v.name
  ) x;
  select jsonb_build_object('revenue_cents', coalesce(sum((e->>'revenue_cents')::int), 0), 'expense_cents', coalesce(sum((e->>'expense_cents')::int), 0),
         'ai_cents', coalesce(sum((e->>'ai_cents')::int), 0), 'net_cents', coalesce(sum((e->>'net_cents')::int), 0),
         'pipeline_cents', coalesce(sum((e->>'pipeline_cents')::int), 0), 'forecast_cents', coalesce(sum((e->>'forecast_cents')::int), 0))
    into tot from jsonb_array_elements(r) e;
  -- Company-level agents (Jarvis, shared staff) belong to no venture: their AI cost is holding overhead.
  select coalesce(sum(coalesce(c.actual_cents, c.reserved_cents)), 0)::int into h_ai from public.llm_calls c
    left join public.agents a on a.slug = c.agent_slug
    where c.status in ('reserved','done') and c.started_at >= since_ and (a.venture_id is null);
  tot := tot || jsonb_build_object('holding_ai_cents', h_ai, 'net_after_overhead_cents', (tot->>'net_cents')::int - h_ai);
  return jsonb_build_object('days', greatest(1, least(coalesce(p_days, 30), 365)), 'ventures', r, 'total', tot,
    'note', 'Revenue is received cash only. Pipeline (signed/qualified) and forecasts are not cash.');
end $$;

create or replace function public.flag_underperformers() returns int
language plpgsql set search_path to 'public' as $$
declare a record; n int := 0; v_median numeric; v_msg text; v_oc uuid; v_reason text;
begin
  select percentile_cont(0.5) within group (order by cents_per_done) into v_median from (
    select spent::numeric / done as cents_per_done from (
      select ag.slug, coalesce((select sum(coalesce(c.actual_cents, c.reserved_cents)) from public.llm_calls c where c.agent_slug = ag.slug
               and c.started_at > now() - interval '14 days' and c.status in ('reserved','done')), 0) spent,
             (select count(*) from public.tasks t where t.assigned_agent = ag.slug and t.status = 'done' and t.updated_at > now() - interval '14 days') done
      from public.agents ag where ag.status = 'active') z where done > 0 and spent > 0) y;
  for a in
    select ag.slug, ag.title,
      coalesce((select sum(coalesce(c.actual_cents, c.reserved_cents)) from public.llm_calls c where c.agent_slug = ag.slug
                and c.started_at > now() - interval '14 days' and c.status in ('reserved','done')), 0) spent,
      (select count(*) from public.tasks t where t.assigned_agent = ag.slug and t.status = 'done' and t.updated_at > now() - interval '14 days') done
    from public.agents ag
    where ag.status = 'active' and ag.role <> 'owner_contact' and ag.created_at < now() - interval '14 days'
  loop
    v_reason := case
      when a.spent >= 50 and a.done = 0 then format('spent %s cents in 14 days and finished no tasks', a.spent)
      when v_median is not null and a.done > 0 and a.spent::numeric / a.done > greatest(v_median * 3, 30)
        then format('costs %s cents per finished task, over 3x the company median of %s', round(a.spent::numeric / a.done, 1), round(v_median, 1))
      else null end;
    continue when v_reason is null;
    continue when exists (select 1 from public.org_changes where kind = 'shutdown' and target = a.slug and created_at > now() - interval '14 days');
    insert into public.org_changes (kind, proposed_by, change, gain, cost, time_to_results, risk, alternatives, target)
    values ('shutdown', 'system', format('Pause agent %s (%s): %s.', a.slug, coalesce(a.title, a.slug), v_reason),
            format('Saves about %s cents per 2 weeks', a.spent), 'none (can be resumed any time)', 'immediate',
            'It may be doing work that is hard to measure', 'Keep it and fix its tasks or prompt instead', a.slug)
    returning id into v_oc;
    insert into public.owner_messages (from_agent, kind, channel, body, needs_decision, ref_table, ref_id)
    values ('jarvis', 'proposal', 'telegram',
            format('Earn-your-keep review: %s %s. Approve pauses it; Reject keeps it.', a.slug, v_reason), true, 'org_changes', v_oc);
    n := n + 1;
  end loop;
  return n;
end $$;

do $$ begin
  if exists (select 1 from pg_namespace where nspname = 'cron') then
    perform cron.unschedule(jobid) from cron.job where jobname = 'hq-keep-review';
    perform cron.schedule('hq-keep-review', '30 11 * * 1', 'select public.flag_underperformers()');
  end if;
end $$;
