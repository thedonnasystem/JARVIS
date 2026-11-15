-- Executor gate v1 (OPEN_SOURCE_EVALUATION.md s.4, milestone 2): the ONLY door an external executor (e.g. an Agent Swarm worker) may use.
-- HQ stays the authority for money, permissions and the kill switch; an executor can only run after executor_request() says yes.
-- Additive: two new tables, three new functions. Touches no existing table, function, policy, cap, kill switch or grant.
--   * default-deny: an executor is unregistered or enabled=false, allowed_agents empty, caps 0  -> every request is refused
--   * the bot (service_role) can READ the registry but cannot insert/update it: enabling an executor is an owner action, never Jarvis
--   * every request is recorded (refusals too) and audited; real runs reserve spend through reserve_llm_budget (kill switch, capital
--     mode, per-agent and company daily caps, mission_guard all apply); in dry_run mode nothing is reserved and the caller must not execute
create table if not exists public.executor_registry (
  slug text primary key check (slug ~ '^[a-z0-9][a-z0-9_-]{1,40}$'),
  kind text not null default 'external',
  enabled boolean not null default false,
  max_cents_per_run integer not null default 0 check (max_cents_per_run >= 0),
  max_runs_per_day integer not null default 0 check (max_runs_per_day >= 0),
  allowed_agents text[] not null default '{}',
  note text,
  created_at timestamptz not null default now()
);
create table if not exists public.executor_runs (
  id uuid primary key default gen_random_uuid(),
  executor text not null,
  agent_slug text not null,
  task_id uuid references public.tasks(id) on delete set null,
  venture_id uuid,
  purpose text not null,
  status text not null check (status in ('running', 'done', 'failed', 'refused', 'dry_run', 'expired')),
  est_cents integer not null default 0,
  actual_cents integer,
  llm_call_id uuid,
  refusal_reason text,
  result_sha256 text check (result_sha256 is null or result_sha256 ~ '^[0-9a-f]{64}$'),
  created_at timestamptz not null default now(),
  finished_at timestamptz
);
create index if not exists executor_runs_exec_day_idx on public.executor_runs (executor, created_at);
alter table public.executor_registry enable row level security;   -- no policy: default-deny
alter table public.executor_runs enable row level security;
revoke all on public.executor_registry from public, anon, authenticated;
revoke all on public.executor_runs from public, anon, authenticated;
grant select on public.executor_registry to service_role;
grant select on public.executor_runs to service_role;
revoke insert, update, delete, truncate on public.executor_registry from service_role;
revoke insert, update, delete, truncate on public.executor_runs from service_role;

create or replace function public.executor_request(p_executor text, p_agent text, p_task uuid, p_est_cents integer, p_purpose text)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare
  r public.executor_registry; ss public.system_state; v_venture uuid; v_id uuid := gen_random_uuid();
  v_reason text; v_task uuid; v_call uuid; v_start timestamptz; v_n integer;
begin
  perform pg_advisory_xact_lock(7331);
  select * into ss from public.system_state where id = 1;
  select * into r from public.executor_registry where slug = p_executor;
  if p_task is not null then select venture_id into v_venture from public.tasks where id = p_task; end if;
  if not exists (select 1 from public.tasks where id = p_task) then v_task := null; else v_task := p_task; end if;   -- a refusal for an unknown task must still be recordable
  if r.slug is null then v_reason := 'executor is not registered';
  elsif not r.enabled then v_reason := 'executor is disabled';
  elsif ss.kill_switch then v_reason := 'kill switch is on';
  elsif ss.pause_reason is not null then v_reason := 'system is paused: ' || ss.pause_reason;
  elsif p_agent is null or not (p_agent = any (r.allowed_agents)) then v_reason := 'agent is not allowed for this executor';
  elsif p_task is null or not exists (select 1 from public.tasks where id = p_task) then v_reason := 'task not found';
  elsif p_est_cents is null or p_est_cents <= 0 then v_reason := 'estimate must be positive';
  elsif p_est_cents > r.max_cents_per_run then v_reason := 'estimate exceeds the per-run cap';
  elsif p_purpose is null or length(btrim(p_purpose)) = 0 then v_reason := 'purpose is required';
  end if;
  if v_reason is null then
    v_start := (date_trunc('day', now() at time zone 'America/Toronto') at time zone 'America/Toronto');
    select count(*) into v_n from public.executor_runs
      where executor = p_executor and created_at >= v_start and status in ('running', 'done', 'failed', 'expired');
    if v_n >= r.max_runs_per_day then v_reason := 'daily run limit reached'; end if;
  end if;
  if v_reason is null and ss.mode = 'dry_run' then
    insert into public.executor_runs (id, executor, agent_slug, task_id, venture_id, purpose, status, est_cents, finished_at)
      values (v_id, p_executor, p_agent, v_task, v_venture, left(p_purpose, 500), 'dry_run', 0, now());
    insert into public.audit_log (actor, action, target, detail)
      values (p_agent, 'executor_dry_run', p_executor, jsonb_build_object('run', v_id, 'task', p_task));
    return jsonb_build_object('ok', true, 'run_id', v_id, 'dry_run', true, 'llm_call_id', null);
  end if;
  if v_reason is null then
    begin
      v_call := public.reserve_llm_budget(p_agent, p_est_cents, 'executor:' || p_executor, left(p_purpose, 200));
    exception when others then
      v_reason := 'budget gate refused: ' || left(sqlerrm, 200);
    end;
  end if;
  if v_reason is not null then
    insert into public.executor_runs (id, executor, agent_slug, task_id, venture_id, purpose, status, est_cents, refusal_reason, finished_at)
      values (v_id, left(coalesce(p_executor, '?'), 80), coalesce(p_agent, '?'), v_task, v_venture, left(coalesce(p_purpose, '?'), 500), 'refused', coalesce(p_est_cents, 0), v_reason, now());
    insert into public.audit_log (actor, action, target, detail)
      values (coalesce(p_agent, '?'), 'executor_refused', p_executor, jsonb_build_object('run', v_id, 'reason', v_reason));
    return jsonb_build_object('ok', false, 'run_id', v_id, 'dry_run', false, 'reason', v_reason);
  end if;
  insert into public.executor_runs (id, executor, agent_slug, task_id, venture_id, purpose, status, est_cents, llm_call_id)
    values (v_id, p_executor, p_agent, v_task, v_venture, left(p_purpose, 500), 'running', p_est_cents, v_call);
  insert into public.audit_log (actor, action, target, detail)
    values (p_agent, 'executor_started', p_executor, jsonb_build_object('run', v_id, 'task', p_task, 'est_cents', p_est_cents));
  return jsonb_build_object('ok', true, 'run_id', v_id, 'dry_run', false, 'llm_call_id', v_call);
end $$;

create or replace function public.executor_complete(p_run uuid, p_actual_cents integer, p_status text, p_result_sha256 text default null)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare r public.executor_runs;
begin
  if p_status not in ('done', 'failed') then raise exception 'status must be done or failed'; end if;
  if p_actual_cents is null or p_actual_cents < 0 then raise exception 'actual cents must be >= 0'; end if;
  select * into r from public.executor_runs where id = p_run for update;
  if r.id is null then raise exception 'unknown run'; end if;
  if r.status <> 'running' then raise exception 'run is not running (status %)', r.status; end if;
  perform public.settle_llm_call(r.llm_call_id, p_actual_cents, case when p_status = 'done' then 'done' else 'failed' end);
  update public.executor_runs set status = p_status, actual_cents = p_actual_cents, result_sha256 = p_result_sha256, finished_at = now() where id = p_run;
  insert into public.audit_log (actor, action, target, detail)
    values (r.agent_slug, 'executor_' || p_status, r.executor,
            jsonb_build_object('run', p_run, 'est_cents', r.est_cents, 'actual_cents', p_actual_cents, 'overrun', p_actual_cents > r.est_cents));
  return jsonb_build_object('ok', true, 'overrun', p_actual_cents > r.est_cents);
end $$;

create or replace function public.executor_expire_stale(p_minutes integer default 60) returns integer
language plpgsql security definer set search_path to 'public' as $$
declare r record; n integer := 0;
begin
  for r in select id, llm_call_id, executor, agent_slug from public.executor_runs
            where status = 'running' and created_at < now() - make_interval(mins => greatest(coalesce(p_minutes, 60), 5)) for update loop
    perform public.settle_llm_call(r.llm_call_id, 0, 'released');
    update public.executor_runs set status = 'expired', actual_cents = 0, finished_at = now() where id = r.id;
    insert into public.audit_log (actor, action, target, detail)
      values (r.agent_slug, 'executor_expired', r.executor, jsonb_build_object('run', r.id));
    n := n + 1;
  end loop;
  return n;
end $$;

revoke all on function public.executor_request(text, text, uuid, integer, text) from public, anon, authenticated;
revoke all on function public.executor_complete(uuid, integer, text, text) from public, anon, authenticated;
revoke all on function public.executor_expire_stale(integer) from public, anon, authenticated;
grant execute on function public.executor_request(text, text, uuid, integer, text) to service_role;
grant execute on function public.executor_complete(uuid, integer, text, text) to service_role;
grant execute on function public.executor_expire_stale(integer) to service_role;
