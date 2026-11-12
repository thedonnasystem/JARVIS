
create table public.ventures (
  id uuid primary key default gen_random_uuid(),
  slug text unique not null,
  name text not null,
  kind text not null check (kind in ('revenue','personal','lab')),
  status text not null default 'active' check (status in ('active','paused','parked','cut')),
  primary_metric text,
  gate_criteria text,
  gate_met boolean not null default false,
  created_at timestamptz not null default now()
);

create table public.system_state (
  id int primary key default 1 check (id = 1),
  kill_switch boolean not null default false,
  daily_spend_cap_cents int not null default 300,
  mode text not null default 'dry_run' check (mode in ('dry_run','approve_first','auto_in_caps','exceptions_only')),
  last_heartbeat timestamptz
);

create table public.agents (
  id uuid primary key default gen_random_uuid(),
  slug text unique not null,
  title text not null,
  venture_id uuid references public.ventures(id),
  charter text,
  metric text,
  daily_spend_cap_cents int not null default 50,
  status text not null default 'active' check (status in ('active','paused')),
  prompt_version int not null default 1,
  created_at timestamptz not null default now()
);

create table public.handbook (
  id uuid primary key default gen_random_uuid(),
  version int not null,
  content text not null,
  active boolean not null default false,
  created_at timestamptz not null default now()
);

create table public.tasks (
  id uuid primary key default gen_random_uuid(),
  venture_id uuid references public.ventures(id),
  assigned_agent text references public.agents(slug),
  created_by text,
  title text not null,
  detail text,
  status text not null default 'todo' check (status in ('todo','doing','blocked','done','cancelled')),
  priority int not null default 3,
  due_at timestamptz,
  result text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table public.leads (
  id uuid primary key default gen_random_uuid(),
  venture_id uuid not null references public.ventures(id),
  name text,
  phone text,
  email text,
  source text,
  score int,
  status text not null default 'new',
  consent_basis text,
  do_not_contact boolean not null default false,
  notes text,
  created_at timestamptz not null default now()
);

create table public.deals (
  id uuid primary key default gen_random_uuid(),
  venture_id uuid not null references public.ventures(id),
  lead_id uuid references public.leads(id),
  stage text not null default 'pitched',
  value_cents int,
  notes text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table public.outbox (
  id uuid primary key default gen_random_uuid(),
  venture_id uuid references public.ventures(id),
  agent text references public.agents(slug),
  channel text not null check (channel in ('text','email','call','post','telegram')),
  to_ref text,
  body text not null,
  status text not null default 'draft' check (status in ('draft','qa_passed','approved','sent','rejected')),
  needs_owner boolean not null default false,
  created_at timestamptz not null default now(),
  decided_at timestamptz
);

create table public.ledger (
  id uuid primary key default gen_random_uuid(),
  venture_id uuid references public.ventures(id),
  kind text not null check (kind in ('revenue','expense','tax_setaside','reinvestment')),
  amount_cents int not null,
  currency text not null default 'CAD',
  note text,
  occurred_on date not null default current_date,
  created_at timestamptz not null default now()
);

create table public.agent_runs (
  id uuid primary key default gen_random_uuid(),
  agent_id uuid not null references public.agents(id),
  started_at timestamptz not null default now(),
  finished_at timestamptz,
  status text not null default 'running' check (status in ('running','ok','failed','blocked')),
  cost_cents int not null default 0,
  summary text
);

create table public.audit_log (
  id bigint generated always as identity primary key,
  at timestamptz not null default now(),
  actor text not null,
  action text not null,
  target text,
  detail jsonb
);

create table public.memory (
  id uuid primary key default gen_random_uuid(),
  venture_id uuid references public.ventures(id),
  agent text,
  kind text not null check (kind in ('lesson','decision','outcome','fact')),
  content text not null,
  created_at timestamptz not null default now()
);

create table public.ideas (
  id uuid primary key default gen_random_uuid(),
  name text not null,
  description text,
  speed_to_cash int,
  startup_cost_cents int,
  effort int,
  status text not null default 'new' check (status in ('new','testing','scaled','killed','parked')),
  test_budget_cents int,
  result text,
  created_at timestamptz not null default now()
);

create index on public.tasks (status, assigned_agent);
create index on public.outbox (status);
create index on public.leads (venture_id, status);
create index on public.ledger (venture_id, occurred_on);
create index on public.agent_runs (agent_id, started_at);
create index on public.audit_log (at);
create index on public.memory (venture_id, created_at);

alter table public.ventures enable row level security;
alter table public.system_state enable row level security;
alter table public.agents enable row level security;
alter table public.handbook enable row level security;
alter table public.tasks enable row level security;
alter table public.leads enable row level security;
alter table public.deals enable row level security;
alter table public.outbox enable row level security;
alter table public.ledger enable row level security;
alter table public.agent_runs enable row level security;
alter table public.audit_log enable row level security;
alter table public.memory enable row level security;
alter table public.ideas enable row level security;

create or replace function public.agent_can_run(p_agent text)
returns boolean
language sql
stable
set search_path = public
as $$
  select (not s.kill_switch)
    and a.status = 'active'
    and coalesce((select sum(r.cost_cents) from public.agent_runs r
       where r.agent_id = a.id
         and r.started_at >= (date_trunc('day', now() at time zone 'America/Toronto') at time zone 'America/Toronto')), 0) < a.daily_spend_cap_cents
    and coalesce((select sum(r.cost_cents) from public.agent_runs r
       where r.started_at >= (date_trunc('day', now() at time zone 'America/Toronto') at time zone 'America/Toronto')), 0) < s.daily_spend_cap_cents
  from public.agents a, public.system_state s
  where a.slug = p_agent;
$$;
