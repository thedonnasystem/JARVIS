-- Mission Manager v1 (additive). Persistent objectives that drive the existing task queue.
-- No existing table, column or row is changed except: tasks gains a nullable mission_id.

create table if not exists public.missions (
  id uuid primary key default gen_random_uuid(),
  venture_id uuid references public.ventures(id),
  title text not null check (length(title) between 3 and 140),
  objective text not null check (length(objective) between 10 and 4000),
  success_definition text,
  status text not null default 'captured' check (status in (
    'captured','evaluated','planned','executing','verifying','completed',
    'blocked','paused','rejected','abandoned','failed')),
  priority int not null default 3 check (priority between 1 and 5),
  budget_cents int not null default 200 check (budget_cents between 0 and 2000),  -- AI spend, CAD cents (same unit as llm_calls)
  expected_cad numeric,          -- agent estimate, never actual money
  days_to_cash int,
  verdict text check (verdict in ('GO','TEST','DEFER','REJECT')),
  verdict_reason text,
  plan jsonb not null default '[]'::jsonb,   -- [{agent,title,detail,status,task_id}]
  next_step int not null default 0,
  risks text,
  next_action text,
  owner_decision text,
  evidence jsonb not null default '[]'::jsonb,  -- [{claim, source}] from the verifier
  result text,
  attempts int not null default 0,
  checkpoint jsonb not null default '{}'::jsonb, -- engine bookkeeping that survives restarts
  created_by text not null default 'owner',
  last_progress_at timestamptz not null default now(),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  completed_at timestamptz
);
alter table public.missions enable row level security;

alter table public.tasks add column if not exists mission_id uuid references public.missions(id);
create index if not exists tasks_mission_id_idx on public.tasks(mission_id) where mission_id is not null;
create index if not exists missions_status_idx on public.missions(status);

-- Lifecycle rules live in the database, so no agent or bug can skip verification.
create or replace function public.enforce_mission_transition()
returns trigger language plpgsql set search_path to 'public' as $$
declare ok boolean;
begin
  new.updated_at := now();
  if tg_op = 'INSERT' then
    if new.status not in ('captured') then raise exception 'A new mission must start as captured.'; end if;
    return new;
  end if;
  if new.status is distinct from old.status then
    ok := case old.status
      when 'captured'  then new.status in ('evaluated','rejected','abandoned','paused','failed')
      when 'evaluated' then new.status in ('planned','rejected','abandoned','paused')
      when 'planned'   then new.status in ('executing','blocked','paused','abandoned','failed')
      when 'executing' then new.status in ('verifying','planned','blocked','paused','abandoned','failed')
      when 'verifying' then new.status in ('completed','executing','planned','blocked','failed')
      when 'blocked'   then new.status in ('planned','executing','verifying','paused','abandoned','failed')
      when 'paused'    then new.status in ('captured','evaluated','planned','executing','abandoned')
      else false  -- completed, rejected, abandoned, failed are final
    end;
    if not ok then
      raise exception 'Mission cannot go from % to %.', old.status, new.status;
    end if;
    if new.status = 'completed' then
      if jsonb_typeof(new.evidence) <> 'array' or jsonb_array_length(new.evidence) = 0 then
        raise exception 'A mission cannot be completed without verified evidence.';
      end if;
      new.completed_at := now();
    end if;
    new.last_progress_at := now();
  end if;
  return new;
end $$;

drop trigger if exists missions_lifecycle on public.missions;
create trigger missions_lifecycle before insert or update on public.missions
  for each row execute function public.enforce_mission_transition();

-- Real AI spend per mission, measured by the existing spend gateway (llm_calls.purpose = 'task <uuid>').
create or replace function public.mission_spent_cents(p_mission uuid)
returns int language sql stable set search_path to 'public' as $$
  select coalesce(sum(coalesce(c.actual_cents, c.reserved_cents)), 0)::int
  from public.llm_calls c
  join public.tasks t on c.purpose = 'task ' || t.id::text
  where t.mission_id = p_mission and c.status in ('reserved','done');
$$;

-- One line per live mission for the daily brief and /missions.
create or replace function public.missions_brief_text()
returns text language sql stable set search_path to 'public' as $$
  select case when count(*) = 0 then null else
    'Missions:' || E'\n' || string_agg(
      '- ' || m.title || ' [' || upper(m.status) || coalesce(', ' || m.verdict, '') || '] '
      || public.mission_spent_cents(m.id) || '/' || m.budget_cents || 'c'
      || coalesce(' | next: ' || left(m.next_action, 90), ''),
      E'\n' order by m.priority, m.created_at)
  end
  from public.missions m
  where m.status not in ('completed','rejected','abandoned','failed')
     or m.updated_at > now() - interval '24 hours';
$$;
