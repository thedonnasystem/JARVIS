-- Jarvis core v2 (Nov 16 2026). UNRELEASED dev migration (build/jarvis-core). ADDITIVE and DORMANT: nothing here runs, spends or contacts anyone until the owner activates it.
--   * jarvis_core_config: one row, every switch OFF (core, worker, self-edit, self-automation, WhatsApp, emergency call). Owner-only setter (jarvis_set_config): the bot cannot flip it.
--   * jarvis_jobs + jarvis_job_events: durable job queue with leases, retries with exponential backoff, dead-letter after max attempts, per-division queues
--     (active: donna, wolf-squad, ffm; any other division is refused = dormant). jarvis_job_events is APPEND-ONLY (trigger refuses update / delete / truncate).
--     jarvis_lease() hands out nothing while the core or the worker is off, or while the kill switch is on.
--   * jarvis_task_stats: per task class run count and AI cost (self-automation input); jarvis_automation_candidates() lists classes over the owner's thresholds that are NOT protected.
--   * jarvis_result_cache: reuse cache of prior results (class 'client_pii' for the backup: it may hold task output; never exported).
--   * jarvis_changelog (append-only), jarvis_call_log (append-only emergency-call ledger; jarvis_call_allowed() enforces enabled + daily limit + 24 h dedupe IN THE DATABASE).
--   * jarvis_large_approvals: the large model tier needs an owner-issued, single-use, expiring approval (jarvis_owner_approve_large, owner-only).
--   * jarvis_memory_search(): ranked retrieval from public.memory (never a full dump); jarvis_seed_memory(): owner seed import with dedupe and an audit row (memory kind 'owner_profile').
--   * jarvis_daily_report_data(), jarvis_cost_meter(): read-only reports (spend per day / division / mission from llm_calls purposes 'jarvis:<division>:<mission>:<class>').
--   * agent 'jarvis-core' is seeded PAUSED: the spend gateway (reserve_llm_budget) refuses every call for it until the owner sets it active. The company cap
--     (system_state.daily_spend_cap_cents), kill switch and mode are NOT touched.
--   * backup_classification() is re-created with the same rows plus the new tables, all EXCLUDED from the off-site export for now (an unclassified table would fail the backup
--     closed; exporting them needs reviewed backup_redaction_spec() rows first). PROTECTED object: owner approval needed.
-- Rollback: ops/rollback_jarvis_core.sql.

-- ---------------------------------------------------------------------------------------------------------------------------- tables
create table if not exists public.jarvis_core_config (
  id integer primary key default 1 check (id = 1),
  core_enabled boolean not null default false,
  worker_enabled boolean not null default false,
  self_edit_enabled boolean not null default false,
  self_automation_enabled boolean not null default false,
  whatsapp_enabled boolean not null default false,
  emergency_call_enabled boolean not null default false,
  active_divisions text[] not null default array['donna', 'wolf-squad', 'ffm'],
  design_daily_cap_cents integer not null default 1000 check (design_daily_cap_cents between 0 and 100000),   -- planning figure only; the enforced cap is system_state
  automation_threshold_runs integer not null default 20 check (automation_threshold_runs between 2 and 100000),
  automation_threshold_cents integer not null default 200 check (automation_threshold_cents between 1 and 1000000),
  max_calls_per_day integer not null default 2 check (max_calls_per_day between 0 and 5),
  mission_budget_cents integer not null default 50 check (mission_budget_cents between 1 and 100000),
  paid_providers_enabled boolean not null default false,                                           -- $0 stack by default: paid models / GPU stay off
  self_fund_pct integer not null default 0 check (self_fund_pct between 0 and 50),                  -- share of CONFIRMED Jarvis revenue that may pay for paid models / GPU
  updated_at timestamptz not null default now(),
  updated_by text not null default 'migration'
);
insert into public.jarvis_core_config (id) values (1) on conflict (id) do nothing;

create table if not exists public.jarvis_jobs (
  id uuid primary key default gen_random_uuid(),
  division text not null check (division ~ '^[a-z][a-z0-9-]{1,39}$'),
  kind text not null check (kind ~ '^[a-z][a-z0-9_.-]{1,59}$'),
  payload jsonb not null default '{}'::jsonb check (octet_length(payload::text) <= 20000),
  urgency text not null default 'normal' check (urgency in ('critical', 'urgent', 'normal', 'low')),
  batchable boolean not null default false,
  status text not null default 'queued' check (status in ('queued', 'leased', 'done', 'dead', 'cancelled')),
  attempts integer not null default 0,
  max_attempts integer not null default 5 check (max_attempts between 1 and 20),
  run_after timestamptz not null default now(),
  lease_owner text,
  lease_until timestamptz,
  dedupe_key text check (dedupe_key is null or length(dedupe_key) between 3 and 200),
  mission_id uuid,
  cost_cents integer not null default 0,
  last_error text check (last_error is null or length(last_error) <= 500),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  finished_at timestamptz
);
create unique index if not exists jarvis_jobs_dedupe_idx on public.jarvis_jobs (dedupe_key) where dedupe_key is not null and status in ('queued', 'leased');
create index if not exists jarvis_jobs_ready_idx on public.jarvis_jobs (status, run_after);

create table if not exists public.jarvis_job_events (
  id bigserial primary key,
  job_id uuid not null,
  at timestamptz not null default now(),
  event text not null check (event in ('enqueued', 'deduped', 'leased', 'reclaimed', 'done', 'retry', 'dead', 'cancelled', 'extended')),
  actor text not null default 'system',
  detail jsonb not null default '{}'::jsonb
);
create index if not exists jarvis_job_events_job_idx on public.jarvis_job_events (job_id);

create table if not exists public.jarvis_task_stats (
  task_class text primary key check (task_class ~ '^[a-z][a-z0-9_.-]{1,59}$'),
  runs integer not null default 0,
  ai_runs integer not null default 0,
  cost_cents integer not null default 0,
  last_run_at timestamptz,
  automation_state text not null default 'none' check (automation_state in ('none', 'proposed', 'drafted', 'rejected', 'automated'))
);

create table if not exists public.jarvis_result_cache (
  cache_key text primary key check (cache_key ~ '^[0-9a-f]{64}$'),
  task_class text not null,
  result text not null check (length(result) <= 60000),
  model text,
  created_at timestamptz not null default now(),
  expires_at timestamptz not null
);

create table if not exists public.jarvis_changelog (
  id bigserial primary key,
  at timestamptz not null default now(),
  kind text not null check (kind in ('self_edit_merge', 'self_edit_refused', 'rollback', 'automation_draft', 'config', 'deploy')),
  ref text check (ref is null or length(ref) <= 300),
  summary text not null check (length(summary) between 3 and 1000),
  actor text not null default 'jarvis'
);

create table if not exists public.jarvis_call_log (
  id bigserial primary key,
  at timestamptz not null default now(),
  event_kind text not null check (event_kind ~ '^[a-z][a-z_]{2,40}$'),
  dedupe_key text not null check (length(dedupe_key) between 3 and 200),
  outcome text not null check (outcome in ('allowed', 'refused_disabled', 'refused_criteria', 'refused_limit', 'refused_duplicate', 'placed', 'failed', 'dry_run')),
  detail jsonb not null default '{}'::jsonb
);

-- self-funding: only revenue the OWNER confirms here counts (a received revenue ledger row that bank reconciliation matched); never assumed
create table if not exists public.jarvis_self_fund_credits (
  ledger_id uuid primary key references public.ledger(id),
  amount_cents integer not null check (amount_cents > 0),
  confirmed_at timestamptz not null default now(),
  confirmed_by text not null
);

-- Only Jarvis is always on. Every other agent sleeps until Jarvis wakes it for a specific queued job, with the reason recorded; it sleeps again when its
-- queue is empty or it stops making progress. Append-only: every wake and sleep, with reason and cost.
create table if not exists public.jarvis_agent_wakes (
  id bigserial primary key,
  at timestamptz not null default now(),
  agent_slug text not null,
  event text not null check (event in ('wake', 'sleep')),
  reason text not null check (length(reason) between 5 and 300),
  job_id uuid,
  jobs_done integer not null default 0,
  cost_cents integer not null default 0
);

create table if not exists public.jarvis_large_approvals (
  id uuid primary key default gen_random_uuid(),
  mission_id uuid,
  approved_at timestamptz not null default now(),
  expires_at timestamptz not null,
  used_at timestamptz,
  approved_by text not null
);

do $$
declare t text;
begin
  foreach t in array array['jarvis_core_config', 'jarvis_jobs', 'jarvis_job_events', 'jarvis_task_stats', 'jarvis_result_cache', 'jarvis_changelog', 'jarvis_call_log', 'jarvis_large_approvals', 'jarvis_self_fund_credits', 'jarvis_agent_wakes'] loop
    execute format('alter table public.%I enable row level security', t);
    execute format('revoke all on public.%I from public, anon, authenticated, service_role', t);   -- default privileges grant them on Supabase / the replica: take them back
  end loop;
end $$;
-- the bot reads state; it writes only through the functions below
grant select on public.jarvis_core_config, public.jarvis_jobs, public.jarvis_job_events, public.jarvis_task_stats, public.jarvis_changelog, public.jarvis_call_log, public.jarvis_agent_wakes to service_role;
revoke all on sequence public.jarvis_job_events_id_seq, public.jarvis_changelog_id_seq, public.jarvis_call_log_id_seq, public.jarvis_agent_wakes_id_seq from public, anon, authenticated, service_role;

-- memory: one new kind for the owner's seeded profile (kept out of the company-knowledge prompt block, which reads decision / lesson / fact only)
alter table public.memory drop constraint if exists memory_kind_check;
alter table public.memory add constraint memory_kind_check check (kind = any (array['lesson', 'decision', 'outcome', 'fact', 'owner_profile']));
create index if not exists memory_fts_simple_idx on public.memory using gin (to_tsvector('simple', content));

-- the core's spending identity: PAUSED, so the spend gateway refuses it until the owner turns it on
insert into public.agents (slug, title, charter, metric, daily_spend_cap_cents, status, role, model_tier, can_contact_owner)
values ('jarvis-core', 'Jarvis core worker', 'Runs queued division jobs through the spend gateway (dormant until the owner activates it).', 'jobs done per dollar', 1000, 'paused', 'ops', 'cheap', false)
on conflict (slug) do nothing;

-- ---------------------------------------------------------------------------------------------------------------------------- append-only guard
create or replace function public.jarvis_append_only() returns trigger
language plpgsql set search_path to 'public' as $$
begin
  raise exception '% is append-only (audit history): % refused', tg_table_name, tg_op using errcode = '42501';
end $$;
revoke all on function public.jarvis_append_only() from public, anon, authenticated;
do $$
declare t text;
begin
  foreach t in array array['jarvis_job_events', 'jarvis_changelog', 'jarvis_call_log', 'jarvis_agent_wakes'] loop
    execute format('drop trigger if exists %I on public.%I', t || '_append_only', t);
    execute format('create trigger %I before update or delete on public.%I for each row execute function public.jarvis_append_only()', t || '_append_only', t);
    execute format('drop trigger if exists %I on public.%I', t || '_no_truncate', t);
    execute format('create trigger %I before truncate on public.%I for each statement execute function public.jarvis_append_only()', t || '_no_truncate', t);
  end loop;
end $$;

-- ---------------------------------------------------------------------------------------------------------------------------- owner check
-- The owner is: the signed-in PWA owner (is_app_owner), or a direct database session that is NOT one of the API roles (the owner in the Supabase SQL editor).
-- The bot (service_role) and the app roles are refused.
create or replace function public.jarvis_require_owner() returns void
language plpgsql stable security definer set search_path to 'public' as $$
begin
  if coalesce(public.is_app_owner(), false) then return; end if;
  if coalesce(nullif(current_setting('role', true), ''), 'none') in ('service_role', 'anon', 'authenticated', 'authenticator') or session_user in ('authenticator', 'anon', 'authenticated', 'service_role') then
    raise exception 'owner approval required: this action is refused for the bot' using errcode = '42501';
  end if;
end $$;
revoke all on function public.jarvis_require_owner() from public, anon, authenticated;

create or replace function public.jarvis_set_config(p_key text, p_value jsonb) returns jsonb
language plpgsql security definer set search_path to 'public' as $$
declare res jsonb;
begin
  perform public.jarvis_require_owner();
  if p_key in ('core_enabled', 'worker_enabled', 'self_edit_enabled', 'self_automation_enabled', 'whatsapp_enabled', 'emergency_call_enabled', 'paid_providers_enabled') then
    if jsonb_typeof(p_value) <> 'boolean' then raise exception 'jarvis_set_config: % needs true or false', p_key; end if;
    execute format('update public.jarvis_core_config set %I = $1, updated_at = now(), updated_by = %L where id = 1', p_key, 'owner') using (p_value #>> '{}')::boolean;
  elsif p_key in ('design_daily_cap_cents', 'automation_threshold_runs', 'automation_threshold_cents', 'max_calls_per_day', 'mission_budget_cents', 'self_fund_pct') then
    if jsonb_typeof(p_value) <> 'number' then raise exception 'jarvis_set_config: % needs a number', p_key; end if;
    execute format('update public.jarvis_core_config set %I = $1, updated_at = now(), updated_by = %L where id = 1', p_key, 'owner') using (p_value #>> '{}')::integer;
  elsif p_key = 'active_divisions' then
    if jsonb_typeof(p_value) <> 'array' or exists (select 1 from jsonb_array_elements_text(p_value) d where d !~ '^[a-z][a-z0-9-]{1,39}$') then raise exception 'jarvis_set_config: active_divisions needs an array of division slugs'; end if;
    update public.jarvis_core_config set active_divisions = array(select jsonb_array_elements_text(p_value)), updated_at = now(), updated_by = 'owner' where id = 1;
  else
    raise exception 'jarvis_set_config: unknown setting %', p_key;
  end if;
  insert into public.jarvis_changelog (kind, ref, summary, actor) values ('config', p_key, 'owner set ' || p_key || ' = ' || left(p_value::text, 200), 'owner');
  insert into public.audit_log (actor, action, target, detail) values ('owner', 'jarvis_config_set', 'jarvis_core_config/' || p_key, jsonb_build_object('value', p_value));
  select to_jsonb(c) into res from public.jarvis_core_config c where id = 1;
  return res;
end $$;
revoke all on function public.jarvis_set_config(text, jsonb) from public, anon, authenticated;

create or replace function public.jarvis_core_status() returns jsonb
language sql stable security definer set search_path to 'public' as $$
  select jsonb_build_object(
    'config', (select to_jsonb(c) from public.jarvis_core_config c where id = 1),
    'kill_switch', (select kill_switch from public.system_state where id = 1),
    'mode', (select mode from public.system_state where id = 1),
    'daily_cap_cents', (select daily_spend_cap_cents from public.system_state where id = 1),
    'agent_status', (select status from public.agents where slug = 'jarvis-core'),
    'queued', (select count(*) from public.jarvis_jobs where status = 'queued'),
    'leased', (select count(*) from public.jarvis_jobs where status = 'leased'),
    'dead', (select count(*) from public.jarvis_jobs where status = 'dead'));
$$;
revoke all on function public.jarvis_core_status() from public, anon, authenticated;

-- ---------------------------------------------------------------------------------------------------------------------------- queue
create or replace function public.jarvis_enqueue(p_division text, p_kind text, p_payload jsonb default '{}'::jsonb, p_urgency text default 'normal',
                                                  p_dedupe text default null, p_run_after timestamptz default null, p_mission uuid default null,
                                                  p_batchable boolean default false, p_max_attempts integer default 5) returns uuid
language plpgsql security definer set search_path to 'public' as $$
declare v_id uuid; v_active text[];
begin
  select active_divisions into v_active from public.jarvis_core_config where id = 1;
  if not (p_division = any (coalesce(v_active, '{}'))) then raise exception 'division % is dormant: its queue is not active', p_division using errcode = '22023'; end if;
  if p_dedupe is not null then
    select id into v_id from public.jarvis_jobs where dedupe_key = p_dedupe and status in ('queued', 'leased');
    if v_id is not null then
      insert into public.jarvis_job_events (job_id, event, detail) values (v_id, 'deduped', jsonb_build_object('kind', p_kind));
      return v_id;
    end if;
  end if;
  insert into public.jarvis_jobs (division, kind, payload, urgency, dedupe_key, run_after, mission_id, batchable, max_attempts)
  values (p_division, p_kind, coalesce(p_payload, '{}'::jsonb), coalesce(p_urgency, 'normal'), p_dedupe, coalesce(p_run_after, now()), p_mission, coalesce(p_batchable, false), coalesce(p_max_attempts, 5))
  returning id into v_id;
  insert into public.jarvis_job_events (job_id, event, detail) values (v_id, 'enqueued', jsonb_build_object('division', p_division, 'kind', p_kind, 'urgency', coalesce(p_urgency, 'normal')));
  return v_id;
end $$;
revoke all on function public.jarvis_enqueue(text, text, jsonb, text, text, timestamptz, uuid, boolean, integer) from public, anon, authenticated;

-- hands out up to p_n ready jobs (queued and due, or leased with an expired lease), most urgent first. Nothing while the core / worker is off or the kill switch is on.
create or replace function public.jarvis_lease(p_worker text, p_n integer default 1, p_lease_seconds integer default 300, p_divisions text[] default null)
returns setof public.jarvis_jobs
language plpgsql security definer set search_path to 'public' as $$
declare c public.jarvis_core_config; ks boolean; r public.jarvis_jobs;
begin
  if p_worker is null or p_worker !~ '^[A-Za-z0-9._:-]{2,80}$' then raise exception 'jarvis_lease: bad worker id'; end if;
  select * into c from public.jarvis_core_config where id = 1;
  select kill_switch into ks from public.system_state where id = 1;
  if not coalesce(c.core_enabled, false) or not coalesce(c.worker_enabled, false) or coalesce(ks, true) then return; end if;
  for r in
    select * from public.jarvis_jobs j
     where ((j.status = 'queued' and j.run_after <= now()) or (j.status = 'leased' and j.lease_until < now()))
       and j.division = any (c.active_divisions) and (p_divisions is null or j.division = any (p_divisions))
     order by case j.urgency when 'critical' then 0 when 'urgent' then 1 when 'normal' then 2 else 3 end, j.run_after
     limit greatest(1, least(coalesce(p_n, 1), 20))
     for update skip locked
  loop
    insert into public.jarvis_job_events (job_id, event, actor, detail)
    values (r.id, case when r.status = 'leased' then 'reclaimed' else 'leased' end, p_worker, jsonb_build_object('attempt', r.attempts + 1, 'previous_owner', r.lease_owner));
    update public.jarvis_jobs set status = 'leased', lease_owner = p_worker, lease_until = now() + make_interval(secs => greatest(30, least(coalesce(p_lease_seconds, 300), 3600))),
                                  attempts = attempts + 1, updated_at = now()
     where id = r.id returning * into r;
    return next r;
  end loop;
end $$;
revoke all on function public.jarvis_lease(text, integer, integer, text[]) from public, anon, authenticated;

create or replace function public.jarvis_extend_lease(p_job uuid, p_worker text, p_seconds integer default 300) returns boolean
language plpgsql security definer set search_path to 'public' as $$
begin
  update public.jarvis_jobs set lease_until = now() + make_interval(secs => greatest(30, least(coalesce(p_seconds, 300), 3600))), updated_at = now()
   where id = p_job and status = 'leased' and lease_owner = p_worker and lease_until >= now();
  if not found then return false; end if;
  insert into public.jarvis_job_events (job_id, event, actor) values (p_job, 'extended', p_worker);
  return true;
end $$;
revoke all on function public.jarvis_extend_lease(uuid, text, integer) from public, anon, authenticated;

-- finish a leased job. Only the lease holder may finish it. Failure: retry with backoff 30 s * 2^(attempt-1), capped at 1 h; dead after max_attempts.
create or replace function public.jarvis_finish(p_job uuid, p_worker text, p_ok boolean, p_error text default null, p_cost_cents integer default 0, p_ai boolean default false)
returns text
language plpgsql security definer set search_path to 'public' as $$
declare j public.jarvis_jobs; v_status text; v_delay integer;
begin
  select * into j from public.jarvis_jobs where id = p_job for update;
  if j.id is null then raise exception 'jarvis_finish: unknown job'; end if;
  if j.status <> 'leased' or j.lease_owner is distinct from p_worker then raise exception 'jarvis_finish: % does not hold the lease of this job', p_worker using errcode = '42501'; end if;
  if p_ok then
    v_status := 'done';
    update public.jarvis_jobs set status = 'done', lease_owner = null, lease_until = null, cost_cents = cost_cents + greatest(0, coalesce(p_cost_cents, 0)), finished_at = now(), updated_at = now(), last_error = null where id = p_job;
  elsif j.attempts >= j.max_attempts then
    v_status := 'dead';
    update public.jarvis_jobs set status = 'dead', lease_owner = null, lease_until = null, cost_cents = cost_cents + greatest(0, coalesce(p_cost_cents, 0)), finished_at = now(), updated_at = now(), last_error = left(p_error, 500) where id = p_job;
  else
    v_status := 'retry';
    v_delay := least(3600, 30 * (2 ^ greatest(0, j.attempts - 1))::integer);
    update public.jarvis_jobs set status = 'queued', lease_owner = null, lease_until = null, run_after = now() + make_interval(secs => v_delay),
                                  cost_cents = cost_cents + greatest(0, coalesce(p_cost_cents, 0)), updated_at = now(), last_error = left(p_error, 500) where id = p_job;
  end if;
  insert into public.jarvis_job_events (job_id, event, actor, detail) values (p_job, v_status, p_worker, jsonb_build_object('attempt', j.attempts, 'cost_cents', greatest(0, coalesce(p_cost_cents, 0)), 'delay_s', v_delay));
  if v_status in ('done', 'dead') then
    insert into public.jarvis_task_stats (task_class, runs, ai_runs, cost_cents, last_run_at) values (j.kind, 1, case when p_ai then 1 else 0 end, greatest(0, coalesce(p_cost_cents, 0)), now())
    on conflict (task_class) do update set runs = jarvis_task_stats.runs + 1, ai_runs = jarvis_task_stats.ai_runs + excluded.ai_runs, cost_cents = jarvis_task_stats.cost_cents + excluded.cost_cents, last_run_at = now();
  end if;
  return v_status;
end $$;
revoke all on function public.jarvis_finish(uuid, text, boolean, text, integer, boolean) from public, anon, authenticated;

-- ---------------------------------------------------------------------------------------------------------------------------- agent wake / sleep
-- A wake needs a real job: queued or leased, and a reason. No job, no wake.
create or replace function public.jarvis_wake_agent(p_agent text, p_job uuid, p_reason text) returns bigint
language plpgsql security definer set search_path to 'public' as $$
declare v bigint;
begin
  if p_agent is null or p_agent !~ '^[a-z][a-z0-9-]{1,60}$' then raise exception 'jarvis_wake_agent: bad agent'; end if;
  if p_agent = 'jarvis' then raise exception 'jarvis is always on: it is never woken'; end if;
  if coalesce(length(btrim(p_reason)), 0) < 5 then raise exception 'jarvis_wake_agent: a wake needs a reason'; end if;
  if not exists (select 1 from public.jarvis_jobs where id = p_job and status in ('queued', 'leased')) then raise exception 'jarvis_wake_agent: no queued job, no wake'; end if;
  insert into public.jarvis_agent_wakes (agent_slug, event, reason, job_id) values (p_agent, 'wake', left(btrim(p_reason), 300), p_job) returning id into v;
  return v;
end $$;
revoke all on function public.jarvis_wake_agent(text, uuid, text) from public, anon, authenticated;

create or replace function public.jarvis_sleep_agent(p_agent text, p_reason text, p_jobs_done integer default 0, p_cost_cents integer default 0) returns bigint
language plpgsql security definer set search_path to 'public' as $$
declare v bigint; last_event text;
begin
  select event into last_event from public.jarvis_agent_wakes where agent_slug = p_agent order by id desc limit 1;
  if last_event is distinct from 'wake' then raise exception 'jarvis_sleep_agent: % is not awake', p_agent; end if;
  insert into public.jarvis_agent_wakes (agent_slug, event, reason, jobs_done, cost_cents)
  values (p_agent, 'sleep', left(coalesce(nullif(btrim(p_reason), ''), 'queue empty'), 300), greatest(0, coalesce(p_jobs_done, 0)), greatest(0, coalesce(p_cost_cents, 0))) returning id into v;
  return v;
end $$;
revoke all on function public.jarvis_sleep_agent(text, text, integer, integer) from public, anon, authenticated;

-- ---------------------------------------------------------------------------------------------------------------------------- self-automation
-- p_protected: task classes that may never be automated (from ops/PROTECTED_PATHS.json "protected_task_classes", passed by the caller AND re-checked by prefix here)
create or replace function public.jarvis_automation_candidates(p_protected text[] default '{}') returns table (task_class text, runs integer, ai_runs integer, cost_cents integer)
language sql stable security definer set search_path to 'public' as $$
  select s.task_class, s.runs, s.ai_runs, s.cost_cents
    from public.jarvis_task_stats s, public.jarvis_core_config c
   where c.id = 1 and s.automation_state = 'none' and s.ai_runs > 0
     and (s.runs >= c.automation_threshold_runs or s.cost_cents >= c.automation_threshold_cents)
     and not (s.task_class = any (coalesce(p_protected, '{}')))
     and s.task_class !~ '^(money|spend|capital|bank|payment|tax|kill|mode|permission|grant|auth|secret|consent|suppression|privacy|redaction|backup|insurance|audit|ci|gate|review|protected)'
   order by s.cost_cents desc, s.runs desc;
$$;
revoke all on function public.jarvis_automation_candidates(text[]) from public, anon, authenticated;

create or replace function public.jarvis_mark_automation(p_class text, p_state text, p_ref text default null) returns void
language plpgsql security definer set search_path to 'public' as $$
begin
  if p_state not in ('proposed', 'drafted', 'rejected', 'automated') then raise exception 'jarvis_mark_automation: bad state'; end if;
  update public.jarvis_task_stats set automation_state = p_state where task_class = p_class;
  if not found then raise exception 'jarvis_mark_automation: unknown task class'; end if;
  if p_state = 'drafted' then
    insert into public.jarvis_changelog (kind, ref, summary) values ('automation_draft', p_ref, 'automation drafted for task class ' || p_class);
  end if;
end $$;
revoke all on function public.jarvis_mark_automation(text, text, text) from public, anon, authenticated;

-- ---------------------------------------------------------------------------------------------------------------------------- reuse cache
create or replace function public.jarvis_cache_get(p_key text) returns text
language sql stable security definer set search_path to 'public' as $$
  select result from public.jarvis_result_cache where cache_key = p_key and expires_at > now();
$$;
revoke all on function public.jarvis_cache_get(text) from public, anon, authenticated;

create or replace function public.jarvis_cache_put(p_key text, p_class text, p_result text, p_model text default null, p_ttl_hours integer default 24) returns void
language plpgsql security definer set search_path to 'public' as $$
begin
  delete from public.jarvis_result_cache where expires_at <= now();   -- housekeeping of expired cache rows only (not audit data)
  insert into public.jarvis_result_cache (cache_key, task_class, result, model, expires_at)
  values (p_key, p_class, left(p_result, 60000), p_model, now() + make_interval(hours => greatest(1, least(coalesce(p_ttl_hours, 24), 720))))
  on conflict (cache_key) do update set result = excluded.result, model = excluded.model, created_at = now(), expires_at = excluded.expires_at;
end $$;
revoke all on function public.jarvis_cache_put(text, text, text, text, integer) from public, anon, authenticated;

-- ---------------------------------------------------------------------------------------------------------------------------- changelog
create or replace function public.jarvis_changelog_add(p_kind text, p_ref text, p_summary text) returns bigint
language plpgsql security definer set search_path to 'public' as $$
declare v bigint;
begin
  if p_kind = 'config' then raise exception 'config entries are written by jarvis_set_config only'; end if;
  insert into public.jarvis_changelog (kind, ref, summary) values (p_kind, left(p_ref, 300), left(p_summary, 1000)) returning id into v;
  return v;
end $$;
revoke all on function public.jarvis_changelog_add(text, text, text) from public, anon, authenticated;

-- ---------------------------------------------------------------------------------------------------------------------------- emergency call ledger
-- Called by the call adapter BEFORE any vendor call. The answer is recorded either way. p_criteria_ok: the adapter's check against ops/CRITICAL_EVENTS.json (owner-approved list).
create or replace function public.jarvis_call_allowed(p_event_kind text, p_dedupe text, p_criteria_ok boolean) returns jsonb
language plpgsql security definer set search_path to 'public' as $$
declare c public.jarvis_core_config; v_today timestamptz; n integer; v_outcome text;
begin
  perform pg_advisory_xact_lock(7337);
  select * into c from public.jarvis_core_config where id = 1;
  v_today := (date_trunc('day', now() at time zone 'America/Toronto') at time zone 'America/Toronto');
  select count(*) into n from public.jarvis_call_log where outcome in ('allowed') and at >= v_today;
  if not coalesce(c.emergency_call_enabled, false) then v_outcome := 'refused_disabled';
  elsif not coalesce(p_criteria_ok, false) then v_outcome := 'refused_criteria';
  elsif exists (select 1 from public.jarvis_call_log where dedupe_key = p_dedupe and outcome = 'allowed' and at > now() - interval '24 hours') then v_outcome := 'refused_duplicate';
  elsif n >= c.max_calls_per_day then v_outcome := 'refused_limit';
  else v_outcome := 'allowed'; end if;
  insert into public.jarvis_call_log (event_kind, dedupe_key, outcome, detail) values (p_event_kind, p_dedupe, v_outcome, jsonb_build_object('calls_today', n, 'limit', c.max_calls_per_day));
  return jsonb_build_object('allowed', v_outcome = 'allowed', 'outcome', v_outcome, 'calls_today', n);
end $$;
revoke all on function public.jarvis_call_allowed(text, text, boolean) from public, anon, authenticated;

create or replace function public.jarvis_call_result(p_dedupe text, p_outcome text, p_detail jsonb default '{}'::jsonb) returns void
language plpgsql security definer set search_path to 'public' as $$
begin
  if p_outcome not in ('placed', 'failed', 'dry_run') then raise exception 'jarvis_call_result: bad outcome'; end if;
  insert into public.jarvis_call_log (event_kind, dedupe_key, outcome, detail) values ('call_result', p_dedupe, p_outcome, coalesce(p_detail, '{}'::jsonb) - 'to' - 'from' - 'number');
end $$;
revoke all on function public.jarvis_call_result(text, text, jsonb) from public, anon, authenticated;

-- ---------------------------------------------------------------------------------------------------------------------------- large-tier approvals
create or replace function public.jarvis_owner_approve_large(p_mission uuid default null, p_hours integer default 24) returns uuid
language plpgsql security definer set search_path to 'public' as $$
declare v uuid;
begin
  perform public.jarvis_require_owner();
  insert into public.jarvis_large_approvals (mission_id, expires_at, approved_by) values (p_mission, now() + make_interval(hours => greatest(1, least(coalesce(p_hours, 24), 168))), 'owner') returning id into v;
  insert into public.audit_log (actor, action, target, detail) values ('owner', 'jarvis_large_tier_approved', 'jarvis_large_approvals/' || v, jsonb_build_object('mission', p_mission, 'hours', p_hours));
  return v;
end $$;
revoke all on function public.jarvis_owner_approve_large(uuid, integer) from public, anon, authenticated;

-- single use: true once, for an unexpired approval (scoped to the mission when the approval names one)
create or replace function public.jarvis_use_large_approval(p_id uuid, p_mission uuid default null) returns boolean
language plpgsql security definer set search_path to 'public' as $$
begin
  update public.jarvis_large_approvals set used_at = now()
   where id = p_id and used_at is null and expires_at > now() and (mission_id is null or mission_id = p_mission);
  return found;
end $$;
revoke all on function public.jarvis_use_large_approval(uuid, uuid) from public, anon, authenticated;

-- ---------------------------------------------------------------------------------------------------------------------------- self-funding
-- The owner confirms that a revenue row was generated by Jarvis. Only a RECEIVED revenue row that bank reconciliation matched (bank_transactions.ledger_id) is accepted.
create or replace function public.jarvis_owner_confirm_revenue(p_ledger uuid) returns jsonb
language plpgsql security definer set search_path to 'public' as $$
declare l public.ledger;
begin
  perform public.jarvis_require_owner();
  select * into l from public.ledger where id = p_ledger;
  if l.id is null or l.kind <> 'revenue' or l.status <> 'received' or l.amount_cents <= 0 then raise exception 'only a received revenue entry can be confirmed'; end if;
  if not exists (select 1 from public.bank_transactions b where b.ledger_id = l.id and b.status = 'matched') then raise exception 'this revenue is not matched to a bank deposit yet (reconcile first: /bank)'; end if;
  insert into public.jarvis_self_fund_credits (ledger_id, amount_cents, confirmed_by) values (l.id, l.amount_cents, 'owner') on conflict (ledger_id) do nothing;
  insert into public.audit_log (actor, action, target, detail) values ('owner', 'jarvis_revenue_confirmed', 'ledger/' || l.id, jsonb_build_object('amount_cents', l.amount_cents));
  return public.jarvis_self_fund_status();
end $$;
revoke all on function public.jarvis_owner_confirm_revenue(uuid) from public, anon, authenticated;

-- budget = confirmed Jarvis revenue x owner percentage, minus everything the core agent has spent (free calls settle at 0). Paid use also needs paid_providers_enabled,
-- and every call still passes the spend gateway (company cap, agent cap, kill switch, mission budget).
create or replace function public.jarvis_self_fund_status() returns jsonb
language sql stable security definer set search_path to 'public' as $$
  with c as (select * from public.jarvis_core_config where id = 1),
       r as (select coalesce(sum(amount_cents), 0)::bigint v from public.jarvis_self_fund_credits),
       s as (select coalesce(sum(coalesce(actual_cents, reserved_cents)), 0)::bigint v from public.llm_calls where agent_slug = 'jarvis-core' and status in ('reserved', 'done'))
  select jsonb_build_object('confirmed_revenue_cents', r.v, 'pct', c.self_fund_pct, 'budget_cents', (r.v * c.self_fund_pct) / 100, 'paid_spent_cents', s.v,
                            'available_cents', greatest(0, (r.v * c.self_fund_pct) / 100 - s.v), 'paid_enabled', c.paid_providers_enabled,
                            'paid_allowed', c.paid_providers_enabled and (r.v * c.self_fund_pct) / 100 - s.v > 0)
    from c, r, s;
$$;
revoke all on function public.jarvis_self_fund_status() from public, anon, authenticated;

-- ---------------------------------------------------------------------------------------------------------------------------- memory
create or replace function public.jarvis_memory_search(p_query text, p_k integer default 8, p_kinds text[] default null)
returns table (kind text, content text, source text, rank real)
language sql stable security definer set search_path to 'public' as $$
  with q as (select plainto_tsquery('simple', left(coalesce(p_query, ''), 500)) tq)
  select m.kind, m.content, m.source, ts_rank(to_tsvector('simple', m.content), q.tq) as rank
    from public.memory m, q
   where (m.expires_at is null or m.expires_at > now())
     and (p_kinds is null or m.kind = any (p_kinds))
     and to_tsvector('simple', m.content) @@ q.tq
   order by rank desc, m.created_at desc
   limit greatest(1, least(coalesce(p_k, 8), 30));
$$;
revoke all on function public.jarvis_memory_search(text, integer, text[]) from public, anon, authenticated;

-- owner seed import. p_items: [{"section": "...", "content": "..."}]. Dedupe on the normalised content of existing owner_profile rows. One audit row (counts only, never content).
create or replace function public.jarvis_seed_memory(p_items jsonb, p_file_sha256 text, p_actor text default 'owner') returns jsonb
language plpgsql security definer set search_path to 'public' as $$
declare it jsonb; v_content text; added integer := 0; dup integer := 0; bad integer := 0;
begin
  if p_file_sha256 is null or p_file_sha256 !~ '^[0-9a-f]{64}$' then raise exception 'jarvis_seed_memory: file hash required'; end if;
  if jsonb_typeof(p_items) <> 'array' or jsonb_array_length(p_items) > 500 then raise exception 'jarvis_seed_memory: 1 to 500 items'; end if;
  for it in select * from jsonb_array_elements(p_items) loop
    v_content := btrim(coalesce(it ->> 'content', ''));
    if length(v_content) < 3 or length(v_content) > 600 then bad := bad + 1; continue; end if;
    if coalesce(it ->> 'section', '') <> '' then v_content := left(it ->> 'section', 80) || ': ' || v_content; end if;
    if exists (select 1 from public.memory where kind = 'owner_profile' and lower(regexp_replace(content, '\s+', ' ', 'g')) = lower(regexp_replace(v_content, '\s+', ' ', 'g'))) then
      dup := dup + 1; continue;
    end if;
    insert into public.memory (agent, kind, content, source, confidence) values ('jarvis', 'owner_profile', v_content, 'owner-seed:' || left(p_file_sha256, 16), 'high');
    added := added + 1;
  end loop;
  insert into public.audit_log (actor, action, target, detail)
  values (left(coalesce(p_actor, 'owner'), 40), 'jarvis_memory_seeded', 'memory/owner_profile', jsonb_build_object('file_sha256', p_file_sha256, 'added', added, 'duplicates', dup, 'rejected', bad));
  return jsonb_build_object('added', added, 'duplicates', dup, 'rejected', bad);
end $$;
revoke all on function public.jarvis_seed_memory(jsonb, text, text) from public, anon, authenticated;

-- ---------------------------------------------------------------------------------------------------------------------------- reports
-- purposes written by the core: 'jarvis:<division>:<mission id or ->:<task class>'
create or replace function public.jarvis_cost_meter(p_days integer default 7) returns jsonb
language sql stable security definer set search_path to 'public' as $$
  with calls as (
    select (started_at at time zone 'America/Toronto')::date as day, coalesce(actual_cents, reserved_cents) as cents, status,
           case when purpose like 'jarvis:%' then split_part(purpose, ':', 2) else 'other' end as division,
           case when purpose like 'jarvis:%' then nullif(split_part(purpose, ':', 3), '-') end as mission
      from public.llm_calls
     where started_at >= now() - make_interval(days => greatest(1, least(coalesce(p_days, 7), 90))) and status in ('reserved', 'done'))
  select jsonb_build_object(
    'days', greatest(1, least(coalesce(p_days, 7), 90)),
    'cap_cents', (select daily_spend_cap_cents from public.system_state where id = 1),
    'design_cap_cents', (select design_daily_cap_cents from public.jarvis_core_config where id = 1),
    'per_day', coalesce((select jsonb_object_agg(day::text, s) from (select day, sum(cents) s from calls group by day) x), '{}'::jsonb),
    'per_division', coalesce((select jsonb_object_agg(division, s) from (select division, sum(cents) s from calls group by division) x), '{}'::jsonb),
    'per_mission', coalesce((select jsonb_object_agg(mission, s) from (select mission, sum(cents) s from calls where mission is not null group by mission) x), '{}'::jsonb));
$$;
revoke all on function public.jarvis_cost_meter(integer) from public, anon, authenticated;

create or replace function public.jarvis_daily_report_data(p_day date default null) returns jsonb
language sql stable security definer set search_path to 'public' as $$
  with b as (
    select coalesce(p_day, ((now() at time zone 'America/Toronto')::date - 1)) as d),
  w as (
    select (b.d::timestamp at time zone 'America/Toronto') as t0, ((b.d + 1)::timestamp at time zone 'America/Toronto') as t1, b.d from b)
  select jsonb_build_object(
    'day', w.d::text,
    'changelog', coalesce((select jsonb_agg(jsonb_build_object('kind', kind, 'ref', ref, 'summary', summary) order by id) from public.jarvis_changelog where at >= w.t0 and at < w.t1), '[]'::jsonb),
    'spend_cents', (select coalesce(sum(coalesce(actual_cents, reserved_cents)), 0) from public.llm_calls where started_at >= w.t0 and started_at < w.t1 and status in ('reserved', 'done')),
    'cap_cents', (select daily_spend_cap_cents from public.system_state where id = 1),
    'cost_per_division', coalesce((select jsonb_object_agg(dv, s) from (
        select case when purpose like 'jarvis:%' then split_part(purpose, ':', 2) else 'other' end dv, sum(coalesce(actual_cents, reserved_cents)) s
          from public.llm_calls where started_at >= w.t0 and started_at < w.t1 and status in ('reserved', 'done') group by 1) x), '{}'::jsonb),
    'missions', coalesce((select jsonb_object_agg(status, n) from (select status, count(*) n from public.missions group by status) x), '{}'::jsonb),
    'missions_active', coalesce((select jsonb_agg(title order by priority, created_at) from (select title, priority, created_at from public.missions where status in ('approved', 'running', 'active') order by priority, created_at limit 5) x), '[]'::jsonb),
    'approvals_waiting', (select count(*) from public.owner_messages where needs_decision and decision is null),
    'jobs', coalesce((select jsonb_object_agg(status, n) from (select status, count(*) n from public.jarvis_jobs group by status) x), '{}'::jsonb),
    'kill_switch', (select kill_switch from public.system_state where id = 1),
    'mode', (select mode from public.system_state where id = 1),
    'revenue_cents', (select coalesce(sum(amount_cents), 0) from public.ledger where kind = 'revenue' and status = 'received' and occurred_on = w.d),
    'expense_cents', (select coalesce(sum(amount_cents), 0) from public.ledger where kind = 'expense' and occurred_on = w.d),
    'self_fund', public.jarvis_self_fund_status(),
    'wakes', coalesce((select jsonb_object_agg(agent_slug, x) from (
        select agent_slug, jsonb_build_object('wakes', count(*) filter (where event = 'wake'), 'sleeps', count(*) filter (where event = 'sleep'),
                                              'jobs', coalesce(sum(jobs_done), 0), 'cost_cents', coalesce(sum(cost_cents), 0),
                                              'reasons', (array_agg(reason order by id) filter (where event = 'wake'))[1:3]) x
          from public.jarvis_agent_wakes where at >= w.t0 and at < w.t1 group by agent_slug) q), '{}'::jsonb),
    'capital', (select public.capital_snapshot()))
  from w;
$$;
revoke all on function public.jarvis_daily_report_data(date) from public, anon, authenticated;

-- ---------------------------------------------------------------------------------------------------------------------------- backup classification (PROTECTED: owner approval)
-- Same rows as 20261119_backup_exclude_client_pii_v1 (unchanged, in the same order) plus the eight new tables.
create or replace function public.backup_classification() returns table (table_name text, data_class text, note text)
language sql immutable set search_path to 'pg_catalog', 'public' as $$
  select * from (values
    -- public: non-personal reference data
    ('model_prices', 'public', 'published model prices'),
    -- secret: never exported, never in any backup
    ('push_config', 'secret', 'private push keys'),
    ('push_subscriptions', 'secret', 'push endpoints and keys'),
    -- client_pii: third-party personal data (leads, prospects, replies, setters, suppression list). EXCLUDED until retention, access, deletion and key policy are set.
    ('leads', 'client_pii', 'prospect name, phone, email, notes'),
    ('outbox', 'client_pii', 'drafts and recipients (to_ref) for leads'),
    ('lead_replies', 'client_pii', 'free-text notes about replies from leads'),
    ('deals', 'client_pii', 'notes about leads; references leads'),
    ('contact_suppressions', 'client_pii', 'opted-out email addresses. After a restore from an off-site backup this list is EMPTY: restore it from the database provider backup before any outreach is ever enabled'),
    ('setters', 'client_pii', 'sales partner name and contact'),
    ('setter_events', 'client_pii', 'client names per setter event'),
    ('setter_payouts', 'client_pii', 'references setters'),
    ('client_workspaces', 'client_pii', 'client company names'),
    -- internal: operating data of the owner and the ventures
    ('account_requests', 'internal', 'vendor sign-up requests; login name only, never a password'),
    ('accounts_registry', 'internal', 'which service accounts exist; vault reference only'),
    ('action_log', 'internal', 'action audit'), ('action_policy', 'internal', 'autonomy tiers'), ('agent_runs', 'internal', 'run summaries (free text)'),
    ('agents', 'internal', 'agent definitions'), ('alert_state', 'internal', 'alert throttling'), ('app_owners', 'internal', 'owner login emails'),
    ('approval_requests', 'internal', 'approvals'), ('audit_log', 'internal', 'audit trail (free text in detail)'), ('bank_accounts', 'internal', 'owner own bank labels and last4'),
    ('bank_balances', 'internal', 'owner own balances'), ('bank_transactions', 'internal', 'owner own transactions'), ('build_requests', 'internal', 'build queue'),
    ('capital_policy', 'internal', 'spend limits'), ('company_profile', 'internal', 'sender identity of the owner ventures'), ('dayjob_days', 'internal', 'day job counters'),
    ('dayjob_targets', 'internal', 'day job targets'), ('departments', 'internal', 'org'), ('escalations', 'internal', 'escalations (free text)'),
    ('evidence_sources', 'internal', 'fetched public web pages'), ('executor_registry', 'internal', 'executor limits'), ('executor_runs', 'internal', 'executor audit'),
    ('handbook', 'internal', 'handbook'), ('human_handoffs', 'internal', 'tasks for the owner (free text)'), ('ideas', 'internal', 'ideas'),
    ('integration_status', 'internal', 'integration health'), ('ledger', 'internal', 'books'), ('llm_calls', 'internal', 'model call meter'),
    ('memory', 'internal', 'agent memory (free text)'), ('mission_outcomes', 'internal', 'outcomes'), ('missions', 'internal', 'missions (free text)'),
    ('org_changes', 'internal', 'org proposals'), ('owner_messages', 'internal', 'messages to the owner (free text)'), ('payment_instructions', 'internal', 'payment requests; payee may be a person'),
    ('predictions', 'internal', 'predictions'), ('reconciliation_flags', 'internal', 'reconciliation'), ('setter_terms', 'internal', 'setter commission terms'),
    ('spend_reservations', 'internal', 'spend gateway'), ('system_state', 'internal', 'kill switch and modes'), ('systems', 'internal', 'registered systems'),
    ('tasks', 'internal', 'tasks (free text)'), ('tool_registry', 'internal', 'tools'), ('venture_assets', 'internal', 'assets'), ('venture_config', 'internal', 'venture offer config'),
    ('venture_goals', 'internal', 'goals'), ('venture_procedures', 'internal', 'procedures'), ('ventures', 'internal', 'ventures'), ('waterfall_policy', 'internal', 'money waterfall'),
    ('web_messages', 'internal', 'owner chat (free text)'),
    -- Jarvis core v2 (20261123). Class 'secret' = NOT in the off-site export (the database provider's own backups still hold them). Reason: the leak-redaction
    -- export needs a reviewed backup_redaction_spec() entry for every exported text column; until those are written (follow-up, protected) the safe choice is to keep
    -- these operational tables out of the off-site file. They hold no client data by design; jarvis_result_cache may.
    ('jarvis_core_config', 'secret', 'Jarvis core switches; off-site export pending a reviewed redaction spec'), ('jarvis_jobs', 'secret', 'job queue; off-site export pending a reviewed redaction spec'),
    ('jarvis_job_events', 'secret', 'append-only queue audit; off-site export pending a reviewed redaction spec'), ('jarvis_task_stats', 'secret', 'run counts per task class; off-site export pending'),
    ('jarvis_changelog', 'secret', 'append-only changelog; off-site export pending'), ('jarvis_call_log', 'secret', 'append-only emergency-call ledger (no phone numbers); off-site export pending'),
    ('jarvis_large_approvals', 'secret', 'owner approvals for the large model tier; off-site export pending'), ('jarvis_self_fund_credits', 'secret', 'owner-confirmed Jarvis revenue (amounts only); off-site export pending'),
    ('jarvis_agent_wakes', 'secret', 'append-only agent wake / sleep log; off-site export pending'),
    ('jarvis_result_cache', 'secret', 'cached task output; may contain client data, never exported (rebuilt on demand)')
  ) v (table_name, data_class, note)
$$;
revoke all on function public.backup_classification() from public, anon, authenticated;
