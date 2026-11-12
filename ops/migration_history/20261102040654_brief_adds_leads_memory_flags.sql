create or replace function public.daily_brief_text() returns text
language plpgsql stable set search_path to 'public' as $function$
declare v_done text; v_todo int; v_blocked int; v_leads int; v_facts int; v_flags text; v_money text;
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
  return public.daily_brief_core()
    || E'\n\nDone in the last 24h:\n' || coalesce(nullif(v_done,''),'- nothing')
    || format(E'\nQueue: %s to do, %s blocked', v_todo, v_blocked)
    || format(E'\nNew: %s leads, %s verified facts saved', v_leads, v_facts)
    || E'\n' || v_money
    || coalesce(E'\nFlags:\n' || v_flags, '');
end $function$;