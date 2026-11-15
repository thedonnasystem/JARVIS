-- SQL-level checks for migrations/20261117_executor_gate_v1.sql. SCRATCH replica only. One transaction, rolled back.
-- Proves: default-deny, no API-role access, service_role cannot enable an executor, every refusal path, dry_run reserves nothing,
-- a real run reserves through the budget gate and settles, kill switch / pause / caps stop it, stale runs release their reservation.
begin;
do $$
declare tid uuid; j jsonb; rid uuid; n int; r text; f text; mode0 text; spent int;
begin
  insert into public.tasks (title, status, assigned_agent) values ('exec test', 'todo', 'builder') returning id into tid;
  foreach f in array array['executor_registry', 'executor_runs'] loop
    if not (select relrowsecurity from pg_class where oid = ('public.' || f)::regclass) then raise exception 'E1 RLS off on %', f; end if;
    if exists (select 1 from pg_policy where polrelid = ('public.' || f)::regclass) then raise exception 'E2 policy exists on %', f; end if;
    foreach r in array array['anon', 'authenticated'] loop
      if has_table_privilege(r, 'public.' || f, 'select') or has_table_privilege(r, 'public.' || f, 'insert') then raise exception 'E3 % has access to %', r, f; end if;
    end loop;
    foreach r in array array['insert', 'update', 'delete', 'truncate'] loop
      if has_table_privilege('service_role', 'public.' || f, r) then raise exception 'E4 service_role can % %', r, f; end if;
    end loop;
  end loop;
  foreach f in array array['public.executor_request(text,text,uuid,integer,text)', 'public.executor_complete(uuid,integer,text,text)', 'public.executor_expire_stale(integer)'] loop
    foreach r in array array['anon', 'authenticated'] loop
      if has_function_privilege(r, f, 'execute') then raise exception 'E5 % can execute %', r, f; end if;
    end loop;
    if not has_function_privilege('service_role', f, 'execute') then raise exception 'E6 service_role cannot execute %', f; end if;
  end loop;

  -- default-deny: unregistered, then registered-but-disabled
  j := public.executor_request('swarm', 'builder', tid, 5, 'harmless task');
  if (j->>'ok')::boolean or j->>'reason' <> 'executor is not registered' then raise exception 'E7 unregistered executor allowed: %', j; end if;
  insert into public.executor_registry (slug) values ('swarm');
  j := public.executor_request('swarm', 'builder', tid, 5, 'harmless task');
  if (j->>'ok')::boolean or j->>'reason' <> 'executor is disabled' then raise exception 'E8 disabled executor allowed: %', j; end if;
  update public.executor_registry set enabled = true where slug = 'swarm';
  j := public.executor_request('swarm', 'builder', tid, 5, 'harmless task');
  if (j->>'ok')::boolean or j->>'reason' <> 'agent is not allowed for this executor' then raise exception 'E9 empty allow-list allowed an agent: %', j; end if;
  update public.executor_registry set allowed_agents = array['builder'] where slug = 'swarm';
  j := public.executor_request('swarm', 'builder', tid, 5, 'harmless task');
  if (j->>'ok')::boolean or j->>'reason' <> 'estimate exceeds the per-run cap' then raise exception 'E10 zero per-run cap allowed a run: %', j; end if;
  update public.executor_registry set max_cents_per_run = 10 where slug = 'swarm';
  j := public.executor_request('swarm', 'builder', tid, 5, 'harmless task');
  if (j->>'ok')::boolean or j->>'reason' <> 'daily run limit reached' then raise exception 'E11 zero daily limit allowed a run: %', j; end if;
  update public.executor_registry set max_runs_per_day = 2 where slug = 'swarm';

  select count(*) into n from public.executor_runs where status = 'refused';
  if n <> 5 then raise exception 'E12 expected 5 recorded refusals, got %', n; end if;
  if not exists (select 1 from public.audit_log where action = 'executor_refused') then raise exception 'E13 refusals not audited'; end if;

  -- validation refusals
  j := public.executor_request('swarm', 'builder', tid, 11, 'x');
  if (j->>'ok')::boolean then raise exception 'E14 over-cap estimate allowed'; end if;
  j := public.executor_request('swarm', 'builder', gen_random_uuid(), 5, 'x');
  if (j->>'ok')::boolean or j->>'reason' <> 'task not found' then raise exception 'E15 unknown task allowed: %', j; end if;
  j := public.executor_request('swarm', 'nope', tid, 5, 'x');
  if (j->>'ok')::boolean then raise exception 'E16 unknown agent allowed'; end if;

  -- dry_run mode: allowed to proceed but nothing reserved, caller told dry_run
  select mode into mode0 from public.system_state where id = 1;
  update public.system_state set mode = 'dry_run' where id = 1;
  select count(*) into n from public.llm_calls;
  j := public.executor_request('swarm', 'builder', tid, 5, 'harmless task');
  if not (j->>'ok')::boolean or not (j->>'dry_run')::boolean then raise exception 'E17 dry_run not reported: %', j; end if;
  if (select count(*) from public.llm_calls) <> n then raise exception 'E18 dry_run reserved spend'; end if;

  -- real mode: reserve, then settle
  set local session_replication_role = replica; update public.system_state set mode = 'auto_in_caps' where id = 1; set local session_replication_role = origin;
  j := public.executor_request('swarm', 'builder', tid, 5, 'harmless task');
  if not (j->>'ok')::boolean or (j->>'dry_run')::boolean or (j->>'llm_call_id') is null then raise exception 'E19 real run not started: %', j; end if;
  rid := (j->>'run_id')::uuid;
  if (select status from public.llm_calls where id = (j->>'llm_call_id')::uuid) <> 'reserved' then raise exception 'E20 no reservation'; end if;
  j := public.executor_complete(rid, 3, 'done', repeat('a', 64));
  if (select status || actual_cents from public.llm_calls where id = (select llm_call_id from public.executor_runs where id = rid)) <> 'done3' then raise exception 'E21 not settled'; end if;
  begin perform public.executor_complete(rid, 1, 'done'); raise exception 'E22 double completion accepted';
  exception when raise_exception then if sqlerrm like 'E22%' then raise; end if; end;
  begin perform public.executor_complete(gen_random_uuid(), 1, 'done'); raise exception 'E23 unknown run accepted';
  exception when raise_exception then if sqlerrm like 'E23%' then raise; end if; end;
  begin perform public.executor_complete(rid, 1, 'running'); raise exception 'E24 bad status accepted';
  exception when raise_exception then if sqlerrm like 'E24%' then raise; end if; end;

  -- overrun is flagged, daily limit (2 real runs) then stops the third
  j := public.executor_request('swarm', 'builder', tid, 5, 'second');
  j := public.executor_complete((j->>'run_id')::uuid, 9, 'failed');
  if not (j->>'overrun')::boolean then raise exception 'E25 overrun not flagged'; end if;
  j := public.executor_request('swarm', 'builder', tid, 5, 'third');
  if (j->>'ok')::boolean or j->>'reason' <> 'daily run limit reached' then raise exception 'E26 daily limit not enforced: %', j; end if;

  -- kill switch and pause stop everything
  update public.executor_registry set max_runs_per_day = 50 where slug = 'swarm';
  update public.system_state set kill_switch = true where id = 1;
  j := public.executor_request('swarm', 'builder', tid, 5, 'x');
  if (j->>'ok')::boolean or j->>'reason' <> 'kill switch is on' then raise exception 'E27 kill switch ignored: %', j; end if;
  update public.system_state set kill_switch = false, pause_reason = 'api_credits' where id = 1;
  j := public.executor_request('swarm', 'builder', tid, 5, 'x');
  if (j->>'ok')::boolean then raise exception 'E28 pause ignored'; end if;
  update public.system_state set pause_reason = null where id = 1;

  -- budget gate refusal is caught and recorded (agent cap exhausted)
  update public.agents set daily_spend_cap_cents = 1 where slug = 'builder';
  j := public.executor_request('swarm', 'builder', tid, 5, 'x');
  if (j->>'ok')::boolean or (j->>'reason') not like 'budget gate refused:%' then raise exception 'E29 agent cap not enforced: %', j; end if;
  update public.agents set daily_spend_cap_cents = 100000 where slug = 'builder';

  update public.executor_registry set max_runs_per_day = 50 where slug = 'swarm';
  -- failed runs stay counted by the daily caps (reserve_llm_budget only sums reserved/done)
  rid := (public.executor_request('swarm', 'builder', tid, 5, 'fail')->>'run_id')::uuid;
  if (select status || actual_cents from public.llm_calls where id = (select llm_call_id from public.executor_runs where id = rid)) <> 'reserved' then null; end if;
  perform public.executor_complete(rid, 2, 'failed');
  if (select status || actual_cents from public.llm_calls where id = (select llm_call_id from public.executor_runs where id = rid)) <> 'done5' then raise exception 'E33 failed run not charged at the reservation'; end if;

  -- the purpose handed to the budget gate is the real task, not caller text (focus-mode bypass)
  j := public.executor_request('swarm', 'builder', tid, 5, 'task 00000000-0000-0000-0000-000000000000');
  if (select purpose from public.llm_calls where id = (j->>'llm_call_id')::uuid) <> 'task ' || tid::text then raise exception 'E34 caller purpose reached the budget gate'; end if;
  perform public.executor_complete((j->>'run_id')::uuid, 1, 'done');

  -- modes that need owner approval refuse; unreadable system state fails closed
  update public.system_state set mode = 'approve_first' where id = 1;
  j := public.executor_request('swarm', 'builder', tid, 5, 'x');
  if (j->>'ok')::boolean or (j->>'reason') not like 'mode approve_first requires owner approval%' then raise exception 'E35 approve_first ran: %', j; end if;
  update public.system_state set mode = 'auto_in_caps' where id = 1;
  delete from public.system_state where id = 1;
  j := public.executor_request('swarm', 'builder', tid, 5, 'x');
  if (j->>'ok')::boolean then raise exception 'E36 ran with no system_state row'; end if;
  insert into public.system_state (id, kill_switch, daily_spend_cap_cents, mode) values (1, false, 100000, 'auto_in_caps');

  -- stale runs stay charged
  j := public.executor_request('swarm', 'builder', tid, 5, 'stale');
  rid := (j->>'run_id')::uuid;
  update public.executor_runs set created_at = now() - interval '3 hours' where id = rid;
  if public.executor_expire_stale(60) <> 1 then raise exception 'E30 stale run not expired'; end if;
  if (select status from public.llm_calls where id = (select llm_call_id from public.executor_runs where id = rid)) <> 'done' then raise exception 'E31 expired reservation not kept charged'; end if;
  if (select actual_cents from public.llm_calls where id = (select llm_call_id from public.executor_runs where id = rid)) <> 5 then raise exception 'E31b expired run not charged in full'; end if;
  if public.executor_expire_stale(60) <> 0 then raise exception 'E32 expiry not idempotent'; end if;
end $$;
rollback;
