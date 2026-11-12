create or replace function public.run_reconciliation() returns int
language plpgsql security definer set search_path = public as $$
declare n int := 0; r record; v_cap int; v_spent int; v_start timestamptz;
begin
  -- 1. Spend reservations stuck for over 30 minutes: release them so they stop eating the daily cap.
  for r in select id, agent_slug, reserved_cents from llm_calls where status='reserved' and started_at < now() - interval '30 minutes' loop
    update llm_calls set status='released', finished_at=now() where id=r.id;
    insert into reconciliation_flags(check_name, detail) values ('stuck_reservation', format('Released %s cents reserved by %s (call %s)', r.reserved_cents, r.agent_slug, r.id));
    n := n + 1;
  end loop;
  -- 2. Tasks stuck 'doing' for over 1 hour (engine requeues after 15 min, so this means the engine itself is down).
  for r in select id, title from tasks where status='doing' and updated_at < now() - interval '1 hour' loop
    insert into reconciliation_flags(check_name, detail) values ('task_stuck_doing', format('Task "%s" (%s) has been running over an hour', left(r.title,80), r.id));
    n := n + 1;
  end loop;
  -- 3. Blocked tasks older than 48 hours: someone has to decide.
  for r in select id, title from tasks where status='blocked' and updated_at < now() - interval '48 hours'
           and not exists (select 1 from reconciliation_flags f where f.check_name='stale_blocked' and f.detail like '%'||tasks.id::text||'%') loop
    insert into reconciliation_flags(check_name, detail) values ('stale_blocked', format('Task "%s" (%s) blocked for 2+ days', left(r.title,80), r.id));
    n := n + 1;
  end loop;
  -- 4. Expected money past its date and not received.
  for r in select id, amount_cents, note, occurred_on from ledger where status='expected' and occurred_on < current_date - 3
           and not exists (select 1 from reconciliation_flags f where f.check_name='overdue_money' and f.detail like '%'||ledger.id::text||'%') loop
    insert into reconciliation_flags(check_name, detail) values ('overdue_money', format('Expected $%s (%s) due %s not received (ledger %s)', to_char(r.amount_cents/100.0,'FM999,999,990.00'), coalesce(r.note,'no note'), r.occurred_on, r.id));
    insert into owner_messages(from_agent, kind, channel, body) values ('jarvis','money','telegram', format('Money check: $%s expected by %s has not come in (%s).', to_char(r.amount_cents/100.0,'FM999,999,990.00'), r.occurred_on, coalesce(r.note,'no note')));
    n := n + 1;
  end loop;
  -- 5. Engine heartbeat older than 20 minutes: tell the owner once per day.
  if (select last_heartbeat from system_state where id=1) < now() - interval '20 minutes'
     and not exists (select 1 from reconciliation_flags where check_name='engine_down' and created_at > now() - interval '24 hours') then
    insert into reconciliation_flags(check_name, detail) values ('engine_down', 'Engine heartbeat is older than 20 minutes');
    insert into owner_messages(from_agent, kind, channel, body) values ('jarvis','health','telegram','Health: the HQ engine has not checked in for 20+ minutes. Railway may be down or out of credit.');
    n := n + 1;
  end if;
  -- 6. Spend at 80% of today's cap: warn once per day.
  select daily_spend_cap_cents into v_cap from system_state where id=1;
  v_start := (date_trunc('day', now() at time zone 'America/Toronto') at time zone 'America/Toronto');
  select coalesce(sum(coalesce(actual_cents,reserved_cents)),0) into v_spent from llm_calls where started_at >= v_start and status in ('reserved','done');
  if v_cap > 0 and v_spent >= 0.8 * v_cap
     and not exists (select 1 from reconciliation_flags where check_name='spend_80' and created_at >= v_start) then
    insert into reconciliation_flags(check_name, detail) values ('spend_80', format('Spent %s of %s cents today', v_spent, v_cap));
    insert into owner_messages(from_agent, kind, channel, body) values ('jarvis','money','telegram', format('Money: AI spend is at $%s of today''s $%s cap. Agents pause automatically at the cap.', to_char(v_spent/100.0,'FM990.00'), to_char(v_cap/100.0,'FM990.00')));
    n := n + 1;
  end if;
  return n;
end $$;
revoke all on function public.run_reconciliation() from public, anon, authenticated;
select cron.schedule('hq-reconcile', '*/15 * * * *', $$select public.run_reconciliation()$$);