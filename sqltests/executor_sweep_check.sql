-- SQL-level checks for migrations/20261118_executor_sweep_v1.sql. SCRATCH replica only. One transaction, rolled back.
-- Defect reproduced (RELEASE_PLAN_executor_ffm.md finding 1): hq_engine._recover_stale() runs, on the first tick after every bot start,
--   update llm_calls set status='released' where status='reserved' and started_at < cutoff
-- which also hit the reservation of a still-running executor run, so it counted 0 against the daily caps.
-- Proves: that statement no longer releases a running executor reservation (cap still counts it), still releases ordinary orphans,
-- the restart scenario end to end (request -> simulated restart -> cap still counts -> expire_stale settles), the sweep charges the
-- full reservation / is idempotent / survives a bad row, and finding 3 (failed run: executor_runs.actual_cents = charged amount).
begin;
do $$
declare
  tid uuid; j jsonb; rid uuid; cid uuid; orphan uuid; n int; spent int; v_start timestamptz; refused boolean; rid2 uuid; cid2 uuid;
  recover text := $q$update public.llm_calls set status = 'released', finished_at = now() where status = 'reserved' and started_at < now() + interval '1 second'$q$;
begin
  insert into public.tasks (title, status, assigned_agent) values ('sweep test', 'todo', 'builder') returning id into tid;
  insert into public.executor_registry (slug, enabled, max_cents_per_run, max_runs_per_day, allowed_agents)
    values ('swarm', true, 50, 50, array['builder']);
  set local session_replication_role = replica; update public.system_state set mode = 'auto_in_caps' where id = 1; set local session_replication_role = origin;
  v_start := (date_trunc('day', now() at time zone 'America/Toronto') at time zone 'America/Toronto');
  delete from public.llm_calls where started_at >= v_start;   -- clean slate inside this rolled-back transaction

  -- ordinary orphan reservation (not an executor run): engine restart recovery must still release it
  insert into public.llm_calls (agent_slug, model, purpose, reserved_cents) values ('builder', 'm', 'task orphan', 7) returning id into orphan;

  -- S1: the restart scenario. request -> simulated _recover_stale -> reservation still counts -> expire_stale settles
  j := public.executor_request('swarm', 'builder', tid, 5, 'long run');
  if not (j->>'ok')::boolean then raise exception 'S0 run not started: %', j; end if;
  rid := (j->>'run_id')::uuid; cid := (j->>'llm_call_id')::uuid;
  execute recover;   -- what hq_engine._recover_stale does at bot start
  if (select status from public.llm_calls where id = cid) <> 'reserved' then raise exception 'S1 restart recovery released a running executor reservation (status %)', (select status from public.llm_calls where id = cid); end if;
  if (select status from public.llm_calls where id = orphan) <> 'released' then raise exception 'S2 ordinary orphan reservation no longer released'; end if;
  select coalesce(sum(coalesce(actual_cents, reserved_cents)), 0) into spent from public.llm_calls where started_at >= v_start and status in ('reserved', 'done');
  if spent <> 5 then raise exception 'S3 daily total should count the running reservation (5), got %', spent; end if;
  -- ...and the real gate sees it: with the company cap set to exactly that spend, one more cent is refused
  update public.system_state set daily_spend_cap_cents = 5 where id = 1;
  refused := false;
  begin perform public.reserve_llm_budget('builder', 1, 'm', 'task x'); exception when others then refused := true; end;
  if not refused then raise exception 'S4 daily cap does not count the running executor reservation'; end if;
  update public.system_state set daily_spend_cap_cents = 100000 where id = 1;
  -- the run is still running; a restart a second time changes nothing
  execute recover;
  if (select status from public.llm_calls where id = cid) <> 'reserved' then raise exception 'S5 second restart released it'; end if;
  -- the sweep (executor_expire_stale) then settles it at the full reservation
  update public.executor_runs set created_at = now() - interval '3 hours' where id = rid;
  if public.executor_expire_stale(60) <> 1 then raise exception 'S6 stale run not swept'; end if;
  if (select status || actual_cents from public.llm_calls where id = cid) <> 'done5' then raise exception 'S7 sweep did not charge the full reservation'; end if;
  if (select status || actual_cents from public.executor_runs where id = rid) <> 'expired5' then raise exception 'S8 run not expired at 5'; end if;
  if public.executor_expire_stale(60) <> 0 then raise exception 'S9 sweep not idempotent'; end if;
  if (select actual_cents from public.llm_calls where id = cid) <> 5 then raise exception 'S9b second sweep changed the charge'; end if;
  execute recover;   -- settled spend stays counted after yet another restart
  if (select status from public.llm_calls where id = cid) <> 'done' then raise exception 'S10 settled call changed'; end if;

  -- S11: a run whose reservation was already wrongly released (state left behind by the old bug) is still charged in full by the sweep
  j := public.executor_request('swarm', 'builder', tid, 6, 'legacy');
  rid2 := (j->>'run_id')::uuid; cid2 := (j->>'llm_call_id')::uuid;
  set local session_replication_role = replica; update public.llm_calls set status = 'released' where id = cid2; set local session_replication_role = origin;
  update public.executor_runs set created_at = now() - interval '3 hours' where id = rid2;
  if public.executor_expire_stale(60) <> 1 then raise exception 'S11 legacy released run not swept'; end if;
  if (select status || actual_cents from public.llm_calls where id = cid2) <> 'done6' then raise exception 'S11b legacy run not charged in full'; end if;

  -- S12: the sweep survives a bad row (dangling llm_call_id) and still settles the others
  j := public.executor_request('swarm', 'builder', tid, 4, 'good');
  rid := (j->>'run_id')::uuid; cid := (j->>'llm_call_id')::uuid;
  j := public.executor_request('swarm', 'builder', tid, 3, 'dangling');
  rid2 := (j->>'run_id')::uuid;
  set local session_replication_role = replica; update public.executor_runs set llm_call_id = gen_random_uuid() where id = rid2; set local session_replication_role = origin;
  update public.executor_runs set created_at = now() - interval '3 hours' where id in (rid, rid2);
  if public.executor_expire_stale(60) <> 2 then raise exception 'S12 sweep did not process both rows'; end if;
  if (select status || actual_cents from public.llm_calls where id = cid) <> 'done4' then raise exception 'S12b good row not settled'; end if;
  if exists (select 1 from public.executor_runs where status = 'running') then raise exception 'S12c a run is still running'; end if;

  -- S13: a run that is NOT running no longer protects anything; releasing its (non-executor) rows is unaffected
  insert into public.llm_calls (agent_slug, model, purpose, reserved_cents) values ('builder', 'm', 'task orphan2', 2) returning id into orphan;
  execute recover;
  if (select status from public.llm_calls where id = orphan) <> 'released' then raise exception 'S13 guard blocks unrelated releases'; end if;

  -- S14: normal completion is unaffected by the guard (settle to done)
  j := public.executor_request('swarm', 'builder', tid, 5, 'normal');
  perform public.executor_complete((j->>'run_id')::uuid, 3, 'done');
  if (select status || actual_cents from public.llm_calls where id = (j->>'llm_call_id')::uuid) <> 'done3' then raise exception 'S14 normal completion broken'; end if;

  -- F3 (finding 3): a failed run reports the amount actually charged (greatest(actual, est)), not the caller figure
  j := public.executor_request('swarm', 'builder', tid, 5, 'fails cheap');
  rid := (j->>'run_id')::uuid; cid := (j->>'llm_call_id')::uuid;
  perform public.executor_complete(rid, 2, 'failed');
  if (select actual_cents from public.llm_calls where id = cid) <> 5 then raise exception 'F1 failed run not charged 5'; end if;
  if (select actual_cents from public.executor_runs where id = rid) <> 5 then raise exception 'F2 executor_runs.actual_cents (%) <> charged 5', (select actual_cents from public.executor_runs where id = rid); end if;
  j := public.executor_request('swarm', 'builder', tid, 5, 'fails dear');   -- overrun on a failed run: charged and reported at the larger figure
  rid := (j->>'run_id')::uuid;
  j := public.executor_complete(rid, 9, 'failed');
  if (select actual_cents from public.executor_runs where id = rid) <> 9 or not (j->>'overrun')::boolean then raise exception 'F3 failed overrun not reported at 9'; end if;
  j := public.executor_request('swarm', 'builder', tid, 5, 'done cheap');   -- done runs keep the caller figure
  rid := (j->>'run_id')::uuid;
  perform public.executor_complete(rid, 2, 'done');
  if (select actual_cents from public.executor_runs where id = rid) <> 2 then raise exception 'F4 done run actual changed'; end if;

  -- security properties of the new/replaced objects
  if not (select prosecdef from pg_proc where oid = 'public.executor_complete(uuid,integer,text,text)'::regprocedure) then raise exception 'P1 executor_complete not security definer'; end if;
  if not (select 'search_path=public' = any (proconfig) from pg_proc where oid = 'public.executor_complete(uuid,integer,text,text)'::regprocedure) then raise exception 'P2 executor_complete search_path not pinned'; end if;
  if has_function_privilege('anon', 'public.executor_complete(uuid,integer,text,text)', 'execute') or has_function_privilege('authenticated', 'public.executor_complete(uuid,integer,text,text)', 'execute')
     or has_function_privilege('public', 'public.executor_complete(uuid,integer,text,text)', 'execute') then raise exception 'P3 executor_complete exposed'; end if;
  if not has_function_privilege('service_role', 'public.executor_complete(uuid,integer,text,text)', 'execute') then raise exception 'P4 service_role lost executor_complete'; end if;
  if has_function_privilege('anon', 'public.llm_calls_executor_guard()', 'execute') or has_function_privilege('authenticated', 'public.llm_calls_executor_guard()', 'execute')
     or has_function_privilege('public', 'public.llm_calls_executor_guard()', 'execute') then raise exception 'P5 guard function exposed'; end if;
  if (select count(*) from pg_trigger where tgrelid = 'public.llm_calls'::regclass and tgname = 'llm_calls_executor_guard' and not tgisinternal) <> 1 then raise exception 'P6 guard trigger missing'; end if;
end $$;
rollback;
