-- Mission-level spend protection, enforced in the database (the spend gateway), not in Python.
--  1) A hard per-mission AI budget: a call that would push a mission's spend past its budget is refused BEFORE it is reserved.
--  2) Focus mode: while system_state.focus_mission is set, ONLY that mission's tasks may spend. All other AI work (backlog, triage,
--     cron-made tasks) is refused by the gateway itself. Only the owner can set or clear it.
-- This only ADDS checks to reserve_llm_budget; every existing check is unchanged. It never raises a limit.
alter table public.system_state add column if not exists focus_mission uuid references public.missions(id) on delete set null;

do $$ begin
  if not exists (select 1 from pg_constraint where conname = 'system_state_focus_mission_fkey') then
    alter table public.system_state add constraint system_state_focus_mission_fkey foreign key (focus_mission) references public.missions(id) on delete set null;
  end if;
end $$;

create or replace function public.mission_guard(p_agent text, p_purpose text, p_est_cents integer) returns void
language plpgsql stable set search_path to 'public' as $$
declare v_focus uuid; v_mission uuid; v_budget int; v_spent int;
begin
  select focus_mission into v_focus from public.system_state where id = 1;
  if p_purpose ~ '^task [0-9a-fA-F-]{36}$' then
    select mission_id into v_mission from public.tasks where id = substr(p_purpose, 6)::uuid;
  end if;
  -- The owner talking to Jarvis (chat) is never backlog and is not a mission task; it stays metered by the normal daily caps.
  if v_focus is not null and v_mission is distinct from v_focus and not (p_agent = 'jarvis-chat' and p_purpose !~ '^task ') then
    raise exception 'Focus mode: only mission % may use AI right now.', left(v_focus::text, 8);
  end if;
  if v_mission is not null then
    select budget_cents into v_budget from public.missions where id = v_mission;
    v_spent := public.mission_spent_cents(v_mission);
    if v_spent + coalesce(p_est_cents, 0) > coalesce(v_budget, 0) then
      raise exception 'Mission budget would be exceeded (% of % cents used).', v_spent, coalesce(v_budget, 0);
    end if;
  end if;
end $$;

CREATE OR REPLACE FUNCTION public.reserve_llm_budget(p_agent text, p_est_cents integer, p_model text, p_purpose text)
 RETURNS uuid
 LANGUAGE plpgsql
 SET search_path TO 'public'
AS $function$
declare
  v_ks boolean; v_cap_total int; v_status text; v_cap_agent int;
  v_start timestamptz; v_total int; v_agent int; v_id uuid; v_mode text;
begin
  perform pg_advisory_xact_lock(7331);
  select kill_switch, daily_spend_cap_cents into v_ks, v_cap_total from public.system_state where id = 1;
  if v_ks then raise exception 'Kill switch is on.'; end if;
  v_mode := public.capital_mode();
  if v_mode = 'hard_stop' then raise exception 'Capital hard stop: the operating fund is nearly empty. AI calls are paused.'; end if;
  if v_mode = 'low_cost' then
    v_cap_total := least(v_cap_total, (select low_cost_ai_cap_cents from public.capital_policy where id = 1));
  end if;
  select status, daily_spend_cap_cents into v_status, v_cap_agent from public.agents where slug = p_agent;
  if v_status is null then raise exception 'Unknown agent %.', p_agent; end if;
  if v_status <> 'active' then raise exception 'Agent % is paused.', p_agent; end if;
  v_start := (date_trunc('day', now() at time zone 'America/Toronto') at time zone 'America/Toronto');
  select coalesce(sum(coalesce(actual_cents, reserved_cents)), 0) into v_total
    from public.llm_calls where started_at >= v_start and status in ('reserved','done');
  select coalesce(sum(coalesce(actual_cents, reserved_cents)), 0) into v_agent
    from public.llm_calls where agent_slug = p_agent and started_at >= v_start and status in ('reserved','done');
  if v_agent + p_est_cents > v_cap_agent then raise exception 'Agent % would exceed its daily cap.', p_agent; end if;
  if v_total + p_est_cents > v_cap_total then raise exception 'The company daily spend cap would be exceeded.'; end if;
  perform public.mission_guard(p_agent, p_purpose, p_est_cents);
  insert into public.llm_calls (agent_slug, model, purpose, reserved_cents)
    values (p_agent, p_model, p_purpose, p_est_cents) returning id into v_id;
  return v_id;
end $function$;

-- Owner-only. Pass null to clear. Audited.
create or replace function public.set_focus_mission(p_mission uuid, p_by text) returns void
language plpgsql security definer set search_path to 'public' as $$
begin
  if coalesce(p_by, '') not like 'owner%' then raise exception 'Only the owner can set focus mode.'; end if;
  if p_mission is not null and not exists (select 1 from public.missions where id = p_mission) then raise exception 'No such mission.'; end if;
  update public.system_state set focus_mission = p_mission where id = 1;
  insert into public.audit_log (actor, action, target, detail)
    values (p_by, case when p_mission is null then 'focus_cleared' else 'focus_set' end, 'system_state', jsonb_build_object('mission', p_mission));
end $$;

-- ---------- step limit: a mission may not have more plan steps than its max_steps (default 8, the engine-wide ceiling) ----------
alter table public.missions add column if not exists max_steps int not null default 8 check (max_steps between 1 and 8);
-- Which part of the mission a task is: the database counts only role 'step' (or unknown/null, which is treated as a step).
-- strict_steps: the owner set an explicit ceiling. Strict = step tasks over the mission's whole life may not exceed max_steps (a re-plan after
-- a failed verification then needs the owner to raise it). Not strict = max_steps per attempt (max_steps * (1 + attempts)).
alter table public.missions add column if not exists strict_steps boolean not null default false;
alter table public.tasks add column if not exists mission_role text check (mission_role in ('eval','replan','verify','step'));

create or replace function public.enforce_mission_plan_limit() returns trigger language plpgsql set search_path to 'public' as $$
begin
  if jsonb_typeof(new.plan) = 'array' and jsonb_array_length(new.plan) > new.max_steps then
    raise exception 'Mission plan has % steps; this mission allows %.', jsonb_array_length(new.plan), new.max_steps;
  end if;
  return new;
end $$;
drop trigger if exists missions_plan_limit on public.missions;
create trigger missions_plan_limit before insert or update on public.missions for each row execute function public.enforce_mission_plan_limit();

-- Step tasks made for a mission (cancelled ones excluded, so pause/resume works) may not exceed its allowance (see strict_steps).
create or replace function public.enforce_mission_step_limit() returns trigger language plpgsql set search_path to 'public' as $$
declare v_max int; v_n int; v_strict boolean; v_att int;
begin
  if new.mission_id is null then return new; end if;
  select max_steps, strict_steps, attempts into v_max, v_strict, v_att from public.missions where id = new.mission_id;
  v_max := coalesce(v_max, 8) * case when coalesce(v_strict, false) then 1 else 1 + coalesce(v_att, 0) end;
  if coalesce(new.mission_role, 'step') = 'step' then
    select count(*) into v_n from public.tasks
      where mission_id = new.mission_id and status <> 'cancelled' and coalesce(mission_role, 'step') = 'step';
    if v_n >= v_max then
      raise exception 'Mission step limit reached (% of % steps).', v_n, v_max;
    end if;
  else
    select count(*) into v_n from public.tasks where mission_id = new.mission_id and coalesce(mission_role, 'step') <> 'step';
    if v_n >= 12 then raise exception 'Mission has too many evaluation/verification tasks (%).', v_n; end if;
  end if;
  return new;
end $$;
drop trigger if exists tasks_mission_step_limit on public.tasks;
create trigger tasks_mission_step_limit before insert on public.tasks for each row execute function public.enforce_mission_step_limit();

revoke all on function public.enforce_mission_plan_limit(), public.enforce_mission_step_limit() from public, anon, authenticated;
revoke all on function public.mission_guard(text, text, integer), public.set_focus_mission(uuid, text) from public, anon, authenticated;
grant execute on function public.mission_guard(text, text, integer), public.set_focus_mission(uuid, text) to service_role;
