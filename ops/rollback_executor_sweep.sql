-- Rollback of migrations/20261118_executor_sweep_v1.sql ONLY (run this BEFORE ops/rollback_executor_ffm.sql if both are to go).
-- Restores executor_complete to its 20261117_executor_gate_v1 text and removes the llm_calls guard trigger + function + index.
-- After this, finding 1 is open again: the executor registry MUST be empty/disabled (verify: select count(*) from executor_registry where enabled).
-- Refuses while any executor run is 'running' (settle with select executor_expire_stale(5) first). Idempotent. Touches no data.
do $$ begin
  if to_regclass('public.executor_runs') is not null and exists (select 1 from public.executor_runs where status = 'running') then
    raise exception 'executor runs are running: settle them first (select executor_expire_stale(5))';
  end if;
end $$;
drop trigger if exists llm_calls_executor_guard on public.llm_calls;
drop function if exists public.llm_calls_executor_guard();
drop index if exists public.executor_runs_running_call_idx;
do $do$ begin
  if to_regclass('public.executor_runs') is not null then
    if to_regprocedure('public.executor_complete(uuid,integer,text,text)') is not null then
      execute $restore$
create or replace function public.executor_complete(p_run uuid, p_actual_cents integer, p_status text, p_result_sha256 text default null)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare r public.executor_runs;
begin
  if p_status not in ('done', 'failed') then raise exception 'status must be done or failed'; end if;
  if p_actual_cents is null or p_actual_cents < 0 then raise exception 'actual cents must be >= 0'; end if;
  select * into r from public.executor_runs where id = p_run for update;
  if r.id is null then raise exception 'unknown run'; end if;
  if r.status <> 'running' then raise exception 'run is not running (status %)', r.status; end if;
  -- a failed run is still money spent: settle it as 'done' at no less than the reservation so the daily caps (which only count reserved/done) keep counting it
  perform public.settle_llm_call(r.llm_call_id, case when p_status = 'failed' then greatest(p_actual_cents, r.est_cents) else p_actual_cents end, 'done');
  update public.executor_runs set status = p_status, actual_cents = p_actual_cents, result_sha256 = p_result_sha256, finished_at = now() where id = p_run;
  insert into public.audit_log (actor, action, target, detail)
    values (r.agent_slug, 'executor_' || p_status, r.executor,
            jsonb_build_object('run', p_run, 'est_cents', r.est_cents, 'actual_cents', p_actual_cents, 'overrun', p_actual_cents > r.est_cents));
  return jsonb_build_object('ok', true, 'overrun', p_actual_cents > r.est_cents);
end $$;
      $restore$;
    end if;
  end if;
end $do$;
