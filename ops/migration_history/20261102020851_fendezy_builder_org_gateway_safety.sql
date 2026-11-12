
-- ===== 1. SELF-BUILDING LAYER =====
create table public.build_requests (
  id uuid primary key default gen_random_uuid(),
  requested_by text not null,
  title text not null,
  spec text not null,
  risk text not null default 'low' check (risk in ('low','medium','high')),
  touches_money_or_messages boolean not null default false,
  status text not null default 'proposed' check (status in ('proposed','approved','building','testing','live','rejected','rolled_back')),
  approved_by text,
  qa_agent text,
  test_result text,
  rollback_plan text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table public.tool_registry (
  slug text primary key,
  kind text not null check (kind in ('api','saas','bot','workflow','number','domain','other')),
  purpose text not null,
  owner_agent text references public.agents(slug),
  venture_id uuid references public.ventures(id),
  monthly_cost_cents int not null default 0,
  currency text not null default 'CAD',
  status text not null default 'active' check (status in ('active','idle','cancelled','trial')),
  last_used_at timestamptz,
  review_by date,
  notes text
);

-- Locations of secrets only. Passwords and keys live in the vault, never here.
create table public.accounts_registry (
  id uuid primary key default gen_random_uuid(),
  service text not null,
  purpose text,
  venture_id uuid references public.ventures(id),
  login_email text,
  vault_ref text,
  created_by text not null default 'moe' check (created_by in ('moe','agent')),
  verified boolean not null default false,
  status text not null default 'active' check (status in ('active','pending','suspended','closed')),
  notes text,
  created_at timestamptz not null default now()
);

create table public.human_handoffs (
  id uuid primary key default gen_random_uuid(),
  requested_by text not null references public.agents(slug),
  task text not null,
  why_human text not null,
  url text,
  status text not null default 'open' check (status in ('open','done','cancelled')),
  created_at timestamptz not null default now(),
  completed_at timestamptz
);

-- ===== 2. ORG STRUCTURE =====
create table public.departments (
  slug text primary key,
  name text not null,
  venture_id uuid references public.ventures(id),
  kind text not null default 'venture' check (kind in ('venture','shared','holding')),
  status text not null default 'active' check (status in ('active','paused','parked'))
);

alter table public.agents
  add column department_slug text references public.departments(slug),
  add column role text not null default 'specialist' check (role in ('owner_contact','ceo','coo','cfo','hr','builder','gm','ops','finance','auditor','researcher','specialist','compliance','shared')),
  add column model_tier text not null default 'cheap' check (model_tier in ('cheap','standard','strong')),
  add column can_contact_owner boolean not null default false;

create table public.escalations (
  id uuid primary key default gen_random_uuid(),
  from_agent text not null references public.agents(slug),
  department_slug text references public.departments(slug),
  kind text not null check (kind in ('conflict','uncertain','cross_department','owner_decision','failure')),
  summary text not null,
  evidence jsonb,
  status text not null default 'open' check (status in ('open','resolved_by_auditor','with_jarvis','sent_to_owner','closed')),
  resolution text,
  created_at timestamptz not null default now(),
  resolved_at timestamptz
);

create table public.owner_messages (
  id uuid primary key default gen_random_uuid(),
  from_agent text not null references public.agents(slug),
  kind text not null check (kind in ('brief','money','health','contract','proposal','emergency')),
  channel text not null default 'telegram' check (channel in ('telegram','text','call')),
  body text not null,
  created_at timestamptz not null default now(),
  sent_at timestamptz
);

-- ===== 3. GATEWAY AND SELF-AWARENESS =====
create table public.llm_calls (
  id uuid primary key default gen_random_uuid(),
  agent_slug text not null references public.agents(slug),
  model text,
  purpose text,
  reserved_cents int not null,
  actual_cents int,
  status text not null default 'reserved' check (status in ('reserved','done','failed','released')),
  started_at timestamptz not null default now(),
  finished_at timestamptz
);

create table public.predictions (
  id uuid primary key default gen_random_uuid(),
  agent_slug text not null references public.agents(slug),
  action_ref text,
  expected text not null,
  confidence numeric not null check (confidence >= 0 and confidence <= 1),
  outcome text,
  correct boolean,
  created_at timestamptz not null default now(),
  resolved_at timestamptz
);

create table public.reconciliation_flags (
  id uuid primary key default gen_random_uuid(),
  check_name text not null,
  detail text not null,
  status text not null default 'open' check (status in ('open','explained','fixed')),
  created_at timestamptz not null default now()
);

-- Extend existing tables
alter table public.outbox
  add column lead_id uuid references public.leads(id),
  add column idempotency_key text,
  add column qa_agent text,
  add column qa_notes text,
  add column sources jsonb,
  add column sent_at timestamptz;
create unique index outbox_idem_key on public.outbox (idempotency_key) where idempotency_key is not null;

alter table public.ledger
  add column status text not null default 'received' check (status in ('expected','received')),
  add column intercompany boolean not null default false,
  add column original_currency text,
  add column original_amount_cents int,
  add column fx_rate numeric;

alter table public.memory
  add column source text,
  add column confidence text not null default 'unverified' check (confidence in ('high','medium','low','unverified')),
  add column verified_at timestamptz,
  add column expires_at timestamptz,
  add constraint memory_fact_needs_source check (kind <> 'fact' or source is not null);

alter table public.ideas
  add column revisit_trigger text,
  add column verdict text;

create index on public.llm_calls (started_at);
create index on public.llm_calls (agent_slug, started_at);
create index on public.escalations (status);
create index on public.owner_messages (created_at);

-- ===== 4. RLS ON EVERYTHING NEW =====
alter table public.build_requests enable row level security;
alter table public.tool_registry enable row level security;
alter table public.accounts_registry enable row level security;
alter table public.human_handoffs enable row level security;
alter table public.departments enable row level security;
alter table public.escalations enable row level security;
alter table public.owner_messages enable row level security;
alter table public.llm_calls enable row level security;
alter table public.predictions enable row level security;
alter table public.reconciliation_flags enable row level security;

-- ===== 5. FUNCTIONS AND INVARIANTS =====
create or replace function public.enforce_owner_contact()
returns trigger language plpgsql set search_path = public as $$
begin
  if not exists (select 1 from public.agents where slug = new.from_agent and can_contact_owner and status = 'active') then
    raise exception 'Only Jarvis may contact the owner. Agent % must write to escalations instead.', new.from_agent;
  end if;
  return new;
end $$;
create trigger owner_contact_rule before insert on public.owner_messages
  for each row execute function public.enforce_owner_contact();

create or replace function public.enforce_outbox_rules()
returns trigger language plpgsql set search_path = public as $$
declare v_mode text; v_ks boolean;
begin
  select mode, kill_switch into v_mode, v_ks from public.system_state where id = 1;

  if tg_op = 'INSERT' and new.status <> 'draft' then
    raise exception 'New outbox rows must start as draft.';
  end if;

  if exists (select 1 from public.leads l
             where l.do_not_contact
               and (l.id = new.lead_id or (new.to_ref is not null and (l.phone = new.to_ref or l.email = new.to_ref)))) then
    raise exception 'Recipient is on the do-not-contact list.';
  end if;

  if tg_op = 'UPDATE' and new.status is distinct from old.status then
    if new.status = 'qa_passed' then
      if old.status <> 'draft' then raise exception 'Only a draft can pass QA.'; end if;
      if new.qa_agent is null or new.qa_agent = new.agent then
        raise exception 'QA must be done by a different agent than the one who wrote the message.';
      end if;
    elsif new.status = 'approved' then
      if old.status <> 'qa_passed' then raise exception 'A message must pass QA before approval.'; end if;
    elsif new.status = 'sent' then
      if old.status <> 'approved' then raise exception 'A message must be approved before sending.'; end if;
      if v_ks then raise exception 'Kill switch is on: nothing may be sent.'; end if;
      if v_mode = 'dry_run' then raise exception 'Dry run mode: nothing may be sent.'; end if;
      if new.lead_id is not null and exists (
           select 1 from public.outbox o
           where o.lead_id = new.lead_id and o.status = 'sent' and o.id <> new.id
             and o.sent_at >= (date_trunc('day', now() at time zone 'America/Toronto') at time zone 'America/Toronto')) then
        raise exception 'Daily contact limit reached for this lead.';
      end if;
      new.sent_at := now();
    end if;
  end if;
  return new;
end $$;
create trigger outbox_rules before insert or update on public.outbox
  for each row execute function public.enforce_outbox_rules();

create or replace function public.enforce_build_rules()
returns trigger language plpgsql set search_path = public as $$
begin
  new.updated_at := now();
  if new.status in ('approved','building','testing','live')
     and (new.risk <> 'low' or new.touches_money_or_messages)
     and new.approved_by is distinct from 'moe' then
    raise exception 'This build touches money, messages or carries risk: it needs Moe''s approval first.';
  end if;
  if new.status = 'live' and (new.test_result is null or new.qa_agent is null or new.rollback_plan is null) then
    raise exception 'A build needs a test result, a QA agent and a rollback plan before going live.';
  end if;
  return new;
end $$;
create trigger build_rules before insert or update on public.build_requests
  for each row execute function public.enforce_build_rules();

create or replace function public.reserve_llm_budget(p_agent text, p_est_cents int, p_model text, p_purpose text)
returns uuid language plpgsql set search_path = public as $$
declare
  v_ks boolean; v_cap_total int; v_status text; v_cap_agent int;
  v_start timestamptz; v_total int; v_agent int; v_id uuid;
begin
  perform pg_advisory_xact_lock(7331);
  select kill_switch, daily_spend_cap_cents into v_ks, v_cap_total from public.system_state where id = 1;
  if v_ks then raise exception 'Kill switch is on.'; end if;
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
  insert into public.llm_calls (agent_slug, model, purpose, reserved_cents)
    values (p_agent, p_model, p_purpose, p_est_cents) returning id into v_id;
  return v_id;
end $$;

create or replace function public.settle_llm_call(p_id uuid, p_actual_cents int, p_status text default 'done')
returns void language sql set search_path = public as $$
  update public.llm_calls set actual_cents = p_actual_cents, status = p_status, finished_at = now() where id = p_id;
$$;

create or replace function public.agent_can_run(p_agent text)
returns boolean language sql stable set search_path = public as $$
  select (not s.kill_switch)
    and a.status = 'active'
    and coalesce((select sum(coalesce(c.actual_cents, c.reserved_cents)) from public.llm_calls c
        where c.agent_slug = a.slug and c.status in ('reserved','done')
          and c.started_at >= (date_trunc('day', now() at time zone 'America/Toronto') at time zone 'America/Toronto')), 0) < a.daily_spend_cap_cents
    and coalesce((select sum(coalesce(c.actual_cents, c.reserved_cents)) from public.llm_calls c
        where c.status in ('reserved','done')
          and c.started_at >= (date_trunc('day', now() at time zone 'America/Toronto') at time zone 'America/Toronto')), 0) < s.daily_spend_cap_cents
  from public.agents a, public.system_state s
  where a.slug = p_agent;
$$;
