
create or replace function public.daily_brief_text()
returns text language plpgsql stable set search_path = public as $$
declare
  v_start timestamptz := (date_trunc('day', now() at time zone 'America/Toronto') at time zone 'America/Toronto');
  v_week_date date := ((now() at time zone 'America/Toronto')::date - 6);
  s public.system_state;
  v_spend int; v_open_esc int; v_handoffs int; v_failed int; v_health text; v_why text := '';
  v_money text; v_deals text; v_pending numeric;
begin
  select * into s from public.system_state where id = 1;
  select coalesce(sum(coalesce(actual_cents, reserved_cents)),0) into v_spend
    from public.llm_calls where started_at >= v_start and status in ('reserved','done');
  select count(*) into v_open_esc from public.escalations where status in ('open','with_jarvis');
  select count(*) into v_handoffs from public.human_handoffs where status = 'open';
  select count(*) into v_failed from public.llm_calls where started_at >= v_start and status = 'failed';

  v_health := 'GREEN';
  if v_open_esc > 0 or v_handoffs > 0 or v_spend >= s.daily_spend_cap_cents * 0.8 or v_failed > 2 then v_health := 'YELLOW'; end if;
  if s.kill_switch then v_health := 'RED'; v_why := v_why || ' Kill switch is ON.'; end if;
  if v_open_esc > 0 then v_why := v_why || format(' %s open escalation(s).', v_open_esc); end if;
  if v_handoffs > 0 then v_why := v_why || format(' %s item(s) waiting on you.', v_handoffs); end if;
  if v_spend >= s.daily_spend_cap_cents * 0.8 then v_why := v_why || ' Spend is near today''s cap.'; end if;
  if v_failed > 2 then v_why := v_why || format(' %s failed model calls today.', v_failed); end if;

  select coalesce(string_agg(format('%s: in $%s, out $%s, net $%s', t.name,
           to_char(t.rev/100.0,'FM999990.00'), to_char(t.exp/100.0,'FM999990.00'), to_char((t.rev - t.exp)/100.0,'FM999990.00')),
           E'\n' order by t.name), '')
    into v_money
  from (
    select v.name,
           coalesce(sum(l.amount_cents) filter (where l.kind = 'revenue'), 0) as rev,
           coalesce(sum(l.amount_cents) filter (where l.kind = 'expense'), 0) as exp
    from public.ventures v
    left join public.ledger l on l.venture_id = v.id and l.status = 'received' and l.occurred_on >= v_week_date
    where v.kind = 'revenue'
    group by v.name
  ) t;

  select coalesce(sum(amount_cents),0)/100.0 into v_pending from public.ledger where status = 'expected' and kind = 'revenue';

  select coalesce(string_agg(format('%s: %s', d.stage, d.n), ', ' order by d.stage), 'none') into v_deals
  from (select stage, count(*) as n from public.deals group by stage) d;

  return format(E'Health: %s.%s\n\nLast 7 days, money received (CAD):\n%s\nExpected but not yet received: $%s\n\nDeals by stage: %s\n\nAI spend today: $%s of $%s cap\nMode: %s%s\nWaiting on you: %s',
    v_health, coalesce(nullif(v_why,''), ' All clear.'),
    v_money,
    to_char(v_pending,'FM999990.00'), v_deals,
    to_char(v_spend/100.0,'FM990.00'), to_char(s.daily_spend_cap_cents/100.0,'FM990.00'),
    s.mode, case when s.kill_switch then ' (KILL SWITCH ON)' else '' end,
    case when v_handoffs = 0 then 'nothing' else v_handoffs || ' item(s)' end);
end $$;
