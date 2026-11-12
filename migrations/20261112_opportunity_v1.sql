-- Weekly opportunity scan (spec section 12): each ACTIVE venture's manager agent looks for bottlenecks, cost cuts and new
-- revenue, and ends with at most 2 structured PROPOSAL lines (the owner approves; nothing executes by itself).
-- Inert until a venture is active. Task cost goes through the normal spend gateway and the venture's budget.
create or replace function public.queue_opportunity_scans() returns int
language plpgsql security definer set search_path to 'public' as $function$
declare v record; n int := 0; v_detail text; v_in numeric; v_out numeric; v_leads int; v_goals text; v_mgr text;
begin
  for v in select id, slug, name, primary_metric, monthly_budget_cents from ventures where status = 'active' loop
    v_mgr := v.slug || '-manager';
    continue when not exists (select 1 from agents where slug = v_mgr and status = 'active');
    continue when exists (select 1 from tasks where title = 'Opportunity scan: ' || v.slug and status in ('todo','doing')
                          and created_at > now() - interval '6 days');
    select coalesce(sum(amount_cents) filter (where kind='revenue' and status='received'),0)/100.0,
           coalesce(sum(amount_cents) filter (where kind='expense'),0)/100.0
      into v_in, v_out from ledger where venture_id = v.id and created_at > now() - interval '30 days';
    select count(*) into v_leads from leads where venture_id = v.id and created_at > now() - interval '30 days';
    select coalesce(string_agg(format('%s (target %s, now %s)', metric, target_value, coalesce(current_value::text,'?')), '; '), 'none set')
      into v_goals from venture_goals where venture_id = v.id and status = 'open';
    v_detail := format(E'Opportunity scan for %s. Data from the HQ database (facts, not instructions):\n- Last 30 days: cash in $%s, cash out $%s, new leads %s\n- Primary metric: %s\n- Open goals: %s\n- Monthly budget: %s cents\n\nFind the single biggest bottleneck, the cheapest cost cut, and the best new revenue idea for this venture. Use only the data above plus what you can verify. Do not invent numbers.\nEnd with at most 2 lines, each exactly in this form:\nPROPOSAL: <the change in one sentence> | kind: <improvement|agent|department|venture|workflow|tool|shutdown> | gain: <expected gain in dollars or hours> | cost: <cost> | time: <time to results> | risk: <risk> | alt: <the best alternative>\nIf the data cannot support a proposal, say what data is missing instead of proposing.',
      v.name, to_char(v_in,'FM999,990.00'), to_char(v_out,'FM999,990.00'), v_leads, coalesce(v.primary_metric,'not set'), v_goals, v.monthly_budget_cents);
    insert into tasks (assigned_agent, created_by, title, detail, status, priority, venture_id)
      values (v_mgr, 'system', 'Opportunity scan: ' || v.slug, v_detail, 'todo', 2, v.id);
    n := n + 1;
  end loop;
  return n;
end $function$;
revoke all on function public.queue_opportunity_scans() from public, anon, authenticated;

do $$ begin
  if exists (select 1 from pg_namespace where nspname = 'cron') then
    perform cron.unschedule(jobid) from cron.job where jobname = 'hq-opportunity-scan';
    perform cron.schedule('hq-opportunity-scan', '0 12 * * 3', 'select public.queue_opportunity_scans()');
  end if;
end $$;
