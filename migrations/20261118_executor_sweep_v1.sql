-- Executor sweep v1: fixes the two findings of RELEASE_PLAN_executor_ffm.md that must be closed before any executor is enabled.
-- Does NOT edit 20261117_executor_gate_v1.sql / 20261117_client_workspaces_v1.sql (PR #5, not yet applied). Requires executor_gate_v1 first (APPLY_ORDER).
--   1. finding 1 (reservation accounting): the bot's _recover_stale() releases EVERY llm_calls row still 'reserved' at restart, which hid the
--      spend of a running executor run from the daily caps. A BEFORE UPDATE trigger on llm_calls now keeps a reservation that belongs to a
--      'running' executor_run reserved (the update of that one row is skipped; every other row, and every other status change such as
--      settle_llm_call -> 'done', is untouched). The sweep executor_expire_stale (unchanged) settles it at the full reservation.
--      The trigger tolerates a missing executor_runs table (rollback order), so it can never break llm_calls updates.
--   2. finding 3: executor_complete is re-created so executor_runs.actual_cents for a FAILED run equals the amount charged
--      (greatest(actual, est), same as llm_calls). Same signature, security definer, search_path, revoke/grant as before.
create index if not exists executor_runs_running_call_idx on public.executor_runs (llm_call_id) where status = 'running';

create or replace function public.llm_calls_executor_guard() returns trigger
language plpgsql security definer set search_path to 'public' as $$
begin
  if to_regclass('public.executor_runs') is not null
     and exists (select 1 from public.executor_runs where llm_call_id = old.id and status = 'running') then
    return null;   -- keep the reservation: a running executor run's spend must keep counting against the daily caps
  end if;
  return new;
end $$;
revoke all on function public.llm_calls_executor_guard() from public, anon, authenticated;

drop trigger if exists llm_calls_executor_guard on public.llm_calls;
create trigger llm_calls_executor_guard before update of status on public.llm_calls
  for each row when (old.status = 'reserved' and new.status in ('released', 'failed'))
  execute function public.llm_calls_executor_guard();

create or replace function public.executor_complete(p_run uuid, p_actual_cents integer, p_status text, p_result_sha256 text default null)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare r public.executor_runs; v_charge integer;
begin
  if p_status not in ('done', 'failed') then raise exception 'status must be done or failed'; end if;
  if p_actual_cents is null or p_actual_cents < 0 then raise exception 'actual cents must be >= 0'; end if;
  select * into r from public.executor_runs where id = p_run for update;
  if r.id is null then raise exception 'unknown run'; end if;
  if r.status <> 'running' then raise exception 'run is not running (status %)', r.status; end if;
  -- a failed run is still money spent: settle it as 'done' at no less than the reservation so the daily caps (which only count reserved/done) keep counting it
  v_charge := case when p_status = 'failed' then greatest(p_actual_cents, r.est_cents) else p_actual_cents end;
  perform public.settle_llm_call(r.llm_call_id, v_charge, 'done');
  update public.executor_runs set status = p_status, actual_cents = v_charge, result_sha256 = p_result_sha256, finished_at = now() where id = p_run;   -- reports what was charged
  insert into public.audit_log (actor, action, target, detail)
    values (r.agent_slug, 'executor_' || p_status, r.executor,
            jsonb_build_object('run', p_run, 'est_cents', r.est_cents, 'actual_cents', p_actual_cents, 'charged_cents', v_charge, 'overrun', p_actual_cents > r.est_cents));
  return jsonb_build_object('ok', true, 'overrun', p_actual_cents > r.est_cents);
end $$;

revoke all on function public.executor_complete(uuid, integer, text, text) from public, anon, authenticated;
grant execute on function public.executor_complete(uuid, integer, text, text) to service_role;
