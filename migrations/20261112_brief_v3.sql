-- Daily brief v3: the 7pm brief gains P&L, bank alerts, forecast accuracy, pending proposals and ventures awaiting activation.
-- Apply after capital_v1, bank_v1, learning_v1, org_v1, holding_v1, ventures_v1 (each section appears only if its migration exists).

CREATE OR REPLACE FUNCTION public.daily_brief_text()
 RETURNS text
 LANGUAGE plpgsql
 STABLE
 SET search_path TO 'public'
AS $function$
declare v_done text; v_todo int; v_blocked int; v_leads int; v_facts int; v_flags text; v_money text;
        v_core text; v_reason text; v_since timestamptz; v_days int; v_ext text := '';
        v_p jsonb; v_a jsonb; v_n int;
begin
  select coalesce(string_agg('- '||title||' ('||assigned_agent||')', E'\n' order by updated_at desc), '') into v_done
  from (select title, assigned_agent, updated_at from tasks where status='done' and updated_at > now()-interval '24 hours' order by updated_at desc limit 6) d;
  select count(*) filter (where status='todo'), count(*) filter (where status='blocked') into v_todo, v_blocked from tasks;
  select count(*) into v_leads from leads where created_at > now()-interval '24 hours';
  select count(*) into v_facts from memory where kind='fact' and created_at > now()-interval '24 hours';
  select string_agg('- '||check_name||': '||left(detail,120), E'\n') into v_flags
    from (select check_name, detail from reconciliation_flags where status is distinct from 'closed' and created_at > now()-interval '24 hours' order by created_at desc limit 4) f;
  select format('Money logged in 24h: +$%s in, -$%s out',
           to_char(coalesce(sum(amount_cents) filter (where kind='revenue'),0)/100.0,'FM999,990.00'),
           to_char(coalesce(sum(amount_cents) filter (where kind='expense'),0)/100.0,'FM999,990.00'))
    into v_money from ledger where created_at > now()-interval '24 hours';
  v_core := public.daily_brief_core();
  select pause_reason, paused_at into v_reason, v_since from system_state limit 1;
  if v_reason is not null then
    v_days := greatest(1, ceil(extract(epoch from now()-coalesce(v_since, now()))/86400)::int);
    v_core := regexp_replace(v_core, '^Health:[^\n]*',
      'Health: RED. HQ PAUSED for ' || v_days || ' day(s) — ' ||
      case when v_reason = 'api_credits'
           then 'the Anthropic API account is out of credit, so no agent can run. Top up at console.anthropic.com > Settings > Billing; HQ resumes on its own within the hour.'
           else 'reason: ' || v_reason end);
  end if;
  -- Optional sections: each appears only when its migration is installed, and never breaks the brief.
  begin
    if to_regprocedure('public.holding_pnl(integer)') is not null then
      execute 'select public.holding_pnl(7)' into v_p;
      v_ext := v_ext || format(E'\n\nProfit and loss, 7 days (cash received only): in $%s, out $%s, AI $%s (company overhead $%s), net $%s. Not cash: pipeline $%s, forecasts $%s.',
        to_char((v_p#>>'{total,revenue_cents}')::numeric/100,'FM99990.00'), to_char((v_p#>>'{total,expense_cents}')::numeric/100,'FM99990.00'),
        to_char((v_p#>>'{total,ai_cents}')::numeric/100,'FM99990.00'), to_char((v_p#>>'{total,holding_ai_cents}')::numeric/100,'FM99990.00'),
        to_char((v_p#>>'{total,net_after_overhead_cents}')::numeric/100,'FM99990.00'),
        to_char((v_p#>>'{total,pipeline_cents}')::numeric/100,'FM99990.00'), to_char((v_p#>>'{total,forecast_cents}')::numeric/100,'FM99990.00'));
    end if;
  exception when others then null; end;
  begin
    if to_regprocedure('public.bank_alerts()') is not null then
      execute 'select public.bank_alerts()' into v_a;
      if jsonb_array_length(coalesce(v_a, '[]'::jsonb)) > 0 then
        v_ext := v_ext || E'\n\nBank: ' || (select string_agg(x, ' | ') from jsonb_array_elements_text(v_a) x);
      end if;
    end if;
  exception when others then null; end;
  begin
    if to_regprocedure('public.forecast_bias_text()') is not null then
      execute 'select public.forecast_bias_text()' into v_reason;
      if v_reason is not null and v_reason not like 'No measured%' then v_ext := v_ext || E'\n\nForecast accuracy:\n' || v_reason; end if;
    end if;
  exception when others then null; end;
  begin
    if to_regclass('public.org_changes') is not null then
      execute $q$select count(*) from public.org_changes where status = 'proposed'$q$ into v_n;
      if v_n > 0 then v_ext := v_ext || format(E'\n\n%s proposal(s) waiting for your decision (new agents, departments, workflows, pauses).', v_n); end if;
    end if;
  exception when others then null; end;
  begin
    if to_regclass('public.ventures') is not null and exists (select 1 from public.ventures where status = 'proposed') then
      v_ext := v_ext || E'\n\nVentures waiting for activation: ' || (select string_agg(slug, ', ') from public.ventures where status = 'proposed') || '.';
    end if;
  exception when others then null; end;
  begin
    if to_regclass('public.account_requests') is not null then
      execute $q$select count(*) from public.account_requests where status = 'awaiting_owner'$q$ into v_n;
      if v_n > 0 then v_ext := v_ext || format(E'\n\n%s account request(s) waiting for your OK.', v_n); end if;
      execute $q$select count(*) from public.account_requests where status = 'approved'$q$ into v_n;
      if v_n > 0 then v_ext := v_ext || format(E'\n%s approved account(s) waiting for you to sign up (/account).', v_n); end if;
    end if;
  exception when others then null; end;
  begin
    if to_regprocedure('public.venture_over_budget(text)') is not null and exists (select 1 from public.ventures where status = 'active' and public.venture_over_budget(slug)) then
      v_ext := v_ext || E'\n\nOver their monthly AI ceiling (paused until you raise it): ' || (select string_agg(slug, ', ') from public.ventures where status = 'active' and public.venture_over_budget(slug)) || '.';
    end if;
  exception when others then null; end;
  return v_core
    || coalesce(E'\n\n' || public.capital_brief_text(), '')
    || coalesce(E'\n\n' || public.missions_brief_text(), '')
    || v_ext
    || E'\n\nDone in the last 24h:\n' || coalesce(nullif(v_done,''),'- nothing')
    || format(E'\nQueue: %s to do, %s blocked', v_todo, v_blocked)
    || format(E'\nNew: %s leads, %s verified facts saved', v_leads, v_facts)
    || E'\n' || v_money
    || E'\n' || coalesce(public.dayjob_week_text(), '')
    || coalesce(E'\nFlags:\n' || v_flags, '');
end $function$;
