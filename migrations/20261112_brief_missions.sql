-- Daily brief gains a Missions section (depends on 20261112_missions_v1.sql).
-- Same body as the live daily_brief_text (incl. the Nov 11 paused-RED fix) plus one line.
CREATE OR REPLACE FUNCTION public.daily_brief_text()
 RETURNS text
 LANGUAGE plpgsql
 STABLE
 SET search_path TO 'public'
AS $function$
declare v_done text; v_todo int; v_blocked int; v_leads int; v_facts int; v_flags text; v_money text;
        v_core text; v_reason text; v_since timestamptz; v_days int;
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
  return v_core
    || coalesce(E'\n\n' || public.missions_brief_text(), '')
    || E'\n\nDone in the last 24h:\n' || coalesce(nullif(v_done,''),'- nothing')
    || format(E'\nQueue: %s to do, %s blocked', v_todo, v_blocked)
    || format(E'\nNew: %s leads, %s verified facts saved', v_leads, v_facts)
    || E'\n' || v_money
    || E'\n' || coalesce(public.dayjob_week_text(), '')
    || coalesce(E'\nFlags:\n' || v_flags, '');
end $function$;
