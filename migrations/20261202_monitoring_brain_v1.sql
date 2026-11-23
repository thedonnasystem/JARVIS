-- FENDEZY GROUP Phase 1, milestone M6 "Monitoring + shared brain". ADDITIVE. Needs M1 (20261127) .. M5 (20261201).
-- Design (docs/architecture/PHASE1_M6_MONITORING_BRAIN.md):
--   Monitoring
--   * fz_health_report(): one read-only report: AI cap headroom (day and week), kill switch / mode, job queue backlog, failed (dead) jobs, the M3 approval backlog,
--     the M4 audit-chain verify and security findings. Each check has a status (ok / warn / bad).
--   * fz_health_check(): the scheduled check (cron, every 10 minutes). Behind fz_health_config.alerts_enabled (default FALSE: it does nothing). When on, it alerts Jarvis
--     on Telegram (owner_messages, kind 'health') ONLY when a check's status changes, once per change (dedupe key check:status:generation, unique). Run only by the cron
--     job / a database session / the owner: the service key cannot trigger alerts.
--   Shared brain
--   * fz_brain_facts: office_id NULL = group-wide, otherwise office-scoped; source, confidence, provenance, created_by_office. APPEND-ONLY: no edit, no delete; a fact is
--     replaced by a new one that supersedes it (the only change ever made to a row is setting superseded_by / superseded_at, once).
--   * fz_brain_read(): the ONLY read path: active group facts plus the caller's OWN office facts, nothing else (the table has no API privileges at all).
--   * promotion office -> group: only through fz_brain_propose_promotion(), which stores the text through the existing leak redaction (backup_redact_text, strict) and
--     keeps only allowlisted provenance keys, and an approval item in the M3 queue (fz_approval_queue gains a 'brain_promotion' branch). Decided by the owner
--     (fz_owner_decide_brain_promotion) or, only if the owner switched it on (fz_brain_config.jarvis_may_approve, default FALSE), by Jarvis for a request it did not make.
--   No LLM call here (hq_llm untouched). No change to any protected object: money tables, caps, kill switch, mode, authorize_action, action_policy, executors, the
--   redaction functions (only called), the M3 approval paths (the view only gains a branch).
-- Ordered BEFORE the lockdown (R3). Rollback: ops/rollback_monitoring_brain.sql (archives, restores the M3 view and the M5 classification exactly). Safe to re-run.

set lock_timeout = '5s';

-- ---------------------------------------------------------------------------------------------------------------------------- tables
create table if not exists public.fz_health_config (
  id int primary key default 1 check (id = 1),
  alerts_enabled boolean not null default false,
  updated_at timestamptz not null default now(),
  updated_by text not null default 'migration'
);
create table if not exists public.fz_health_state (                     -- last seen status per check (written only by fz_health_check)
  check_key text primary key,
  status text not null check (status in ('ok', 'warn', 'bad')),
  generation int not null default 1,
  detail jsonb not null default '{}',
  changed_at timestamptz not null default now(),
  seen_at timestamptz not null default now(),
  pending_status text check (pending_status in ('ok', 'warn', 'bad')),   -- review LOW 3: a new status must hold for 2 consecutive runs
  pending_runs int not null default 0,
  last_alert_at timestamptz                                              -- review LOW 3: at most one alert per check per hour
);
create table if not exists public.fz_health_alerts (                    -- append-only
  id bigint generated always as identity primary key,
  check_key text not null,
  status text not null,
  dedupe_key text not null unique,
  detail jsonb not null default '{}',
  at timestamptz not null default now()
);
create table if not exists public.fz_brain_config (
  id int primary key default 1 check (id = 1),
  jarvis_may_approve boolean not null default false,
  updated_at timestamptz not null default now(),
  updated_by text not null default 'migration'
);
create table if not exists public.fz_brain_facts (
  id uuid primary key default gen_random_uuid(),
  office_id uuid references public.fz_offices (id),                      -- NULL = group-wide
  topic text not null check (length(topic) between 1 and 120),
  fact text not null check (length(fact) between 1 and 2000),
  source text not null check (length(source) between 1 and 200),
  confidence numeric(3, 2) not null check (confidence >= 0 and confidence <= 1),
  provenance jsonb not null default '{}' check (jsonb_typeof(provenance) = 'object' and octet_length(provenance::text) <= 4000),
  created_by_office uuid not null references public.fz_offices (id),
  created_by text not null,
  created_at timestamptz not null default now(),
  supersedes uuid references public.fz_brain_facts (id),
  superseded_by uuid references public.fz_brain_facts (id),
  superseded_at timestamptz
);
create index if not exists fz_brain_facts_scope_idx on public.fz_brain_facts (office_id, topic) where superseded_by is null;
create table if not exists public.fz_brain_promotions (
  id uuid primary key default gen_random_uuid(),
  fact_id uuid not null references public.fz_brain_facts (id),
  office_id uuid not null references public.fz_offices (id),             -- the office the fact comes from
  redacted_topic text not null,
  redacted_fact text not null,
  redacted_provenance jsonb not null default '{}',
  redaction_level text not null default 'patterns' check (redaction_level in ('patterns', 'full')),   -- full = with the client-name context (owner session / scheduler)
  requested_by text not null,                                            -- review MED 1: derived from the caller's role, never from a parameter
  requested_via text not null default 'service' check (requested_via in ('service', 'scoped', 'owner')),
  status text not null default 'pending' check (status in ('pending', 'approved', 'rejected', 'expired')),
  created_at timestamptz not null default now(),
  expires_at timestamptz not null default now() + interval '7 days',
  decided_at timestamptz,
  decided_by text,
  group_fact_id uuid references public.fz_brain_facts (id)
);
do $$
declare t text;
begin
  foreach t in array array['fz_health_config', 'fz_health_state', 'fz_health_alerts', 'fz_brain_config', 'fz_brain_facts', 'fz_brain_promotions'] loop
    execute format('alter table public.%I enable row level security', t);
    execute format('revoke all on public.%I from public, anon, authenticated, service_role', t);
    if exists (select 1 from pg_roles where rolname = 'fz_jarvis') then execute format('revoke all on public.%I from fz_jarvis, fz_office_agent, fz_auditor', t); end if;
  end loop;
end $$;
-- the bot reads the monitoring tables; it never reads the brain tables directly (fz_brain_read is the only read path) and writes nothing directly
grant select on public.fz_health_config, public.fz_health_state, public.fz_health_alerts, public.fz_brain_config to service_role;
insert into public.fz_health_config (id) values (1) on conflict do nothing;
insert into public.fz_brain_config (id) values (1) on conflict do nothing;

-- ---------------------------------------------------------------------------------------------------------------------------- guards
create or replace function public.fz_m6_owner_session() returns boolean
language sql stable security definer set search_path to 'pg_catalog' as $$
  select coalesce(public.is_app_owner(), false) or coalesce(nullif(current_setting('role', true), ''), 'none') in ('none', 'postgres')
$$;
revoke all on function public.fz_m6_owner_session() from public, anon, authenticated;

-- M5 review LOW #6 (M5 is frozen, fixed here): the office stamp ignores a caller-given office_id unless the caller is the owner (or a database session);
-- otherwise the row's office is derived as before, else the group. Only that one condition differs from 20261201 (the rollback restores the M5 text exactly).
create or replace function public.fz_service_stamp_office() returns trigger
language plpgsql security definer set search_path to 'pg_catalog' as $$
declare j jsonb := to_jsonb(new); v uuid; i record; v_role text := coalesce(nullif(current_setting('role', true), ''), 'none');
begin
  if (j ->> 'venture_id') is not null then select x.office_id into v from public.ventures x where x.id = (j ->> 'venture_id')::uuid; end if;
  if v is null and (j ->> 'lead_id') is not null then
    select coalesce(l.office_id, x.office_id) into v from public.leads l left join public.ventures x on x.id = l.venture_id where l.id = (j ->> 'lead_id')::uuid;
  end if;
  if v is null and (j ->> 'mission_id') is not null then select m.office_id into v from public.missions m where m.id = (j ->> 'mission_id')::uuid; end if;
  if v is null and tg_table_name = 'owner_messages' and (j ->> 'from_agent') is not null then select a.office_id into v from public.agents a where a.slug = j ->> 'from_agent'; end if;
  if v is null and (j ->> 'division') is not null then select d.office_id into v from public.departments d where d.slug = j ->> 'division'; end if;
  if v is null and v_role in ('fz_jarvis', 'fz_office_agent', 'fz_auditor') then
    select * into i from public.fz_identity_now();
    if i.slug is not null and not i.is_group then v := i.office_id; end if;
  end if;
  if v is null and tg_op = 'UPDATE' then v := old.office_id; end if;               -- nothing to derive from: the office does not move
  if v is null and tg_op = 'INSERT' and (j ->> 'office_id') is not null and public.fz_m6_owner_session() then   -- M5 review #6: a caller-given office only from the owner
    select o.id into v from public.fz_offices o where o.id = (j ->> 'office_id')::uuid;
  end if;
  new.office_id := coalesce(v, (select o.id from public.fz_offices o where o.slug = 'group'));
  return new;
end $$;
revoke all on function public.fz_service_stamp_office() from public, anon, authenticated;

-- config rows: only the owner / a database session; never deleted
create or replace function public.fz_m6_config_guard() returns trigger
language plpgsql security definer set search_path to 'pg_catalog' as $$
begin
  if tg_op = 'DELETE' then raise exception '% is never deleted', tg_table_name using errcode = '42501'; end if;
  if not public.fz_m6_owner_session() then raise exception 'owner approval required: % is changed by the owner only', tg_table_name using errcode = '42501'; end if;
  new.updated_at := now();
  return new;
end $$;
revoke all on function public.fz_m6_config_guard() from public, anon, authenticated;

-- brain facts: append-only. The only allowed change: superseded_by / superseded_at set once (null -> value), nothing else.
create or replace function public.fz_brain_facts_guard() returns trigger
language plpgsql security definer set search_path to 'pg_catalog' as $$
begin
  if tg_op = 'DELETE' then raise exception 'brain facts are never deleted (supersede them)' using errcode = '42501'; end if;
  if tg_op = 'UPDATE' then
    if old.superseded_by is not null or new.superseded_by is null
       or (to_jsonb(new) - 'superseded_by' - 'superseded_at') is distinct from (to_jsonb(old) - 'superseded_by' - 'superseded_at') then
      raise exception 'brain facts are append-only: a fact is replaced by a new fact that supersedes it' using errcode = '42501';
    end if;
  end if;
  return new;
end $$;
revoke all on function public.fz_brain_facts_guard() from public, anon, authenticated;

-- promotions: never deleted; the request text never changes; a decision is made once
create or replace function public.fz_brain_promotions_guard() returns trigger
language plpgsql security definer set search_path to 'pg_catalog' as $$
begin
  if tg_op = 'DELETE' then raise exception 'promotion requests are never deleted' using errcode = '42501'; end if;
  if tg_op = 'INSERT' and (new.status <> 'pending' or new.decided_at is not null or new.group_fact_id is not null) then
    raise exception 'a promotion request starts pending' using errcode = '42501';
  end if;
  if tg_op = 'UPDATE' then
    if old.status <> 'pending' then raise exception 'a promotion request is decided once' using errcode = '42501'; end if;
    if (new.fact_id, new.office_id, new.redacted_provenance, new.requested_by, new.requested_via, new.created_at, new.expires_at)
       is distinct from (old.fact_id, old.office_id, old.redacted_provenance, old.requested_by, old.requested_via, old.created_at, old.expires_at)
       or (old.redaction_level = 'full' and new.redaction_level <> 'full')                            -- never back to the weaker redaction
       or ((new.redacted_topic, new.redacted_fact) is distinct from (old.redacted_topic, old.redacted_fact)
           and not (old.redaction_level = 'patterns' and new.redaction_level = 'full' and new.status = 'pending')) then
      raise exception 'a promotion request is not edited (only its one full redaction pass)' using errcode = '42501';
    end if;
  end if;
  return new;
end $$;
revoke all on function public.fz_brain_promotions_guard() from public, anon, authenticated;

drop trigger if exists fz_health_config_guard on public.fz_health_config;
create trigger fz_health_config_guard before update or delete on public.fz_health_config for each row execute function public.fz_m6_config_guard();
drop trigger if exists fz_brain_config_guard on public.fz_brain_config;
create trigger fz_brain_config_guard before update or delete on public.fz_brain_config for each row execute function public.fz_m6_config_guard();
drop trigger if exists fz_brain_facts_guard on public.fz_brain_facts;
create trigger fz_brain_facts_guard before update or delete on public.fz_brain_facts for each row execute function public.fz_brain_facts_guard();
drop trigger if exists fz_brain_promotions_guard on public.fz_brain_promotions;
create trigger fz_brain_promotions_guard before insert or update or delete on public.fz_brain_promotions for each row execute function public.fz_brain_promotions_guard();
drop trigger if exists fz_health_alerts_append_only on public.fz_health_alerts;
create trigger fz_health_alerts_append_only before update or delete on public.fz_health_alerts for each row execute function public.fz_append_only();
do $$
declare t text;
begin
  foreach t in array array['fz_health_config', 'fz_health_alerts', 'fz_brain_config', 'fz_brain_facts', 'fz_brain_promotions'] loop
    execute format('drop trigger if exists %I on public.%I', t || '_no_truncate', t);
    execute format('create trigger %I before truncate on public.%I for each statement execute function public.fz_append_only()', t || '_no_truncate', t);
  end loop;
end $$;

-- ---------------------------------------------------------------------------------------------------------------------------- monitoring
create or replace function public.fz_health_report() returns jsonb
language plpgsql stable security definer set search_path to 'pg_catalog' as $$
declare st public.system_state; cap jsonb; sec jsonb; v_day bigint; v_day_cap bigint; v_week bigint; v_week_cap bigint; checks jsonb := '[]'::jsonb;
        q_overdue int; q_queued int; q_lease int; dead24 int; appr int; s text;
begin
  if coalesce(nullif(current_setting('role', true), ''), 'none') in ('fz_jarvis', 'fz_office_agent', 'fz_auditor') then
    raise exception 'the health report is for the owner' using errcode = '42501';
  end if;
  select * into st from public.system_state where id = 1;
  cap := public.capital_snapshot();
  v_day_cap := coalesce(st.daily_spend_cap_cents, 0);                   -- the company daily AI cap (enforced by reserve_llm_budget; only read here)
  if cap ->> 'mode' = 'low_cost' then v_day_cap := least(v_day_cap, coalesce((select low_cost_ai_cap_cents from public.capital_policy where id = 1), v_day_cap)); end if;
  -- review LOW 4: the same Toronto-day boundary as reserve_llm_budget
  select coalesce(sum(coalesce(c.actual_cents, c.reserved_cents, 0)), 0) into v_day from public.llm_calls c
   where c.status in ('reserved', 'done') and c.started_at >= (date_trunc('day', now() at time zone 'America/Toronto') at time zone 'America/Toronto');
  v_week_cap := coalesce((cap ->> 'weekly_limit_cents')::bigint, 0); v_week := coalesce((cap ->> 'week_spend_cents')::bigint, 0);
  s := case when v_day_cap <= 0 or v_day >= v_day_cap then 'bad' when v_day * 5 >= v_day_cap * 4 then 'warn' else 'ok' end;
  checks := checks || jsonb_build_object('check', 'ai_cap_day', 'status', s, 'used_cents', v_day, 'cap_cents', v_day_cap, 'headroom_cents', greatest(v_day_cap - v_day, 0));
  s := case when v_week_cap <= 0 or v_week >= v_week_cap then 'bad' when v_week * 5 >= v_week_cap * 4 then 'warn' else 'ok' end;
  checks := checks || jsonb_build_object('check', 'spend_week', 'status', s, 'used_cents', v_week, 'cap_cents', v_week_cap, 'headroom_cents', greatest(v_week_cap - v_week, 0));
  checks := checks || jsonb_build_object('check', 'kill_switch', 'status', case when coalesce(st.kill_switch, false) then 'warn' else 'ok' end,
                                         'on', coalesce(st.kill_switch, false), 'mode', st.mode, 'pause_reason', st.pause_reason, 'capital_mode', cap ->> 'mode');
  select count(*) filter (where status = 'queued'), count(*) filter (where status = 'queued' and run_after < now() - interval '15 minutes'),
         count(*) filter (where status = 'leased' and lease_until < now()), count(*) filter (where status = 'dead' and coalesce(finished_at, updated_at) >= now() - interval '24 hours')
    into q_queued, q_overdue, q_lease, dead24 from public.jarvis_jobs;
  checks := checks || jsonb_build_object('check', 'job_backlog', 'status', case when q_overdue >= 50 or q_lease >= 10 then 'bad' when q_overdue >= 10 or q_lease > 0 then 'warn' else 'ok' end,
                                         'queued', q_queued, 'overdue', q_overdue, 'stale_leases', q_lease);
  checks := checks || jsonb_build_object('check', 'failed_jobs', 'status', case when dead24 >= 10 then 'bad' when dead24 > 0 then 'warn' else 'ok' end, 'dead_24h', dead24);
  select count(*) into appr from public.fz_approval_queue where status = 'pending';
  checks := checks || jsonb_build_object('check', 'approval_backlog', 'status', case when appr >= 20 then 'warn' else 'ok' end, 'pending', appr);
  sec := public.fz_security_report();
  checks := checks || jsonb_build_object('check', 'audit_chain', 'status', case when coalesce((sec -> 'chain' ->> 'ok')::boolean, false) then 'ok' else 'bad' end,
                                         'checked', sec -> 'chain' -> 'checked', 'breaks', sec -> 'chain' -> 'break_count', 'gaps', sec -> 'chain' -> 'gaps');
  checks := checks || jsonb_build_object('check', 'security', 'status',
                                         case when jsonb_array_length(coalesce(sec -> 'definer_changed', '[]')) > 0
                                                or exists (select 1 from jsonb_array_elements(coalesce(sec -> 'unexpected', '[]')) e where e ->> 'status' not in ('acknowledged')) then 'bad'
                                              when jsonb_array_length(coalesce(sec -> 'standing', '[]')) > 0 then 'warn' else 'ok' end,
                                         'standing', jsonb_array_length(coalesce(sec -> 'standing', '[]')), 'unexpected', jsonb_array_length(coalesce(sec -> 'unexpected', '[]')),
                                         'definer_changed', jsonb_array_length(coalesce(sec -> 'definer_changed', '[]')));
  return jsonb_build_object('at', now(), 'overall', case when exists (select 1 from jsonb_array_elements(checks) c where c ->> 'status' = 'bad') then 'bad'
                                                          when exists (select 1 from jsonb_array_elements(checks) c where c ->> 'status' = 'warn') then 'warn' else 'ok' end,
                            'checks', checks, 'alerts_enabled', (select alerts_enabled from public.fz_health_config where id = 1),
                            'note', 'Read-only. Changes nothing.');
end $$;
revoke all on function public.fz_health_report() from public, anon, authenticated;

-- the scheduled check: records each check's status and, when alerts are on, tells Jarvis / the owner ONLY on a change (once per change)
create or replace function public.fz_health_check() returns jsonb
language plpgsql security definer set search_path to 'pg_catalog' as $$
declare r jsonb; c jsonb; old public.fz_health_state; n_changed int := 0; n_alerts int := 0; n_held int := 0; n_quiet int := 0; v_gen int; v_key text; v_lines text := '';
        v_new text; v_runs int;
begin
  if not public.fz_m6_owner_session() then
    raise exception 'the health check runs from the scheduler or the owner only' using errcode = '42501';
  end if;
  if not coalesce((select alerts_enabled from public.fz_health_config where id = 1), false) then
    return jsonb_build_object('enabled', false);
  end if;
  perform pg_advisory_xact_lock(hashtext('fz_health_check'));
  r := public.fz_health_report();
  for c in select * from jsonb_array_elements(r -> 'checks') loop
    v_new := c ->> 'status';
    select * into old from public.fz_health_state where check_key = c ->> 'check' for update;
    if not found then                                                     -- a new check starts from ok; a non-ok status then has to hold like any change
      insert into public.fz_health_state (check_key, status, detail, pending_status, pending_runs)
        values (c ->> 'check', 'ok', c, case when v_new <> 'ok' then v_new end, case when v_new <> 'ok' then 1 else 0 end);
      if v_new <> 'ok' then n_held := n_held + 1; end if;
      continue;
    end if;
    if old.status = v_new then                                            -- unchanged (or a flap that came back): nothing pending, no alert
      update public.fz_health_state set seen_at = now(), detail = c, pending_status = null, pending_runs = 0 where check_key = old.check_key;
      continue;
    end if;
    v_runs := case when old.pending_status = v_new then old.pending_runs + 1 else 1 end;
    if v_runs < 2 then                                                    -- review LOW 3: not yet held for 2 consecutive runs
      update public.fz_health_state set seen_at = now(), detail = c, pending_status = v_new, pending_runs = v_runs where check_key = old.check_key;
      n_held := n_held + 1;
      continue;
    end if;
    v_gen := old.generation + 1;
    n_changed := n_changed + 1;
    if old.last_alert_at is not null and old.last_alert_at > now() - interval '1 hour' then   -- review LOW 3: at most one alert per check per hour
      update public.fz_health_state set status = v_new, generation = v_gen, detail = c, changed_at = now(), seen_at = now(), pending_status = null, pending_runs = 0
       where check_key = old.check_key;
      n_quiet := n_quiet + 1;
      continue;
    end if;
    update public.fz_health_state set status = v_new, generation = v_gen, detail = c, changed_at = now(), seen_at = now(), pending_status = null, pending_runs = 0,
           last_alert_at = now() where check_key = old.check_key;
    v_key := 'health:' || (c ->> 'check') || ':' || v_new || ':' || v_gen;
    insert into public.fz_health_alerts (check_key, status, dedupe_key, detail) values (c ->> 'check', v_new, v_key, c) on conflict (dedupe_key) do nothing;
    if found then
      n_alerts := n_alerts + 1;
      v_lines := v_lines || E'\n- ' || (c ->> 'check') || ': ' || old.status || ' -> ' || upper(v_new);
    end if;
  end loop;
  if n_alerts > 0 and exists (select 1 from public.agents where slug = 'jarvis') then
    insert into public.owner_messages (from_agent, kind, channel, body) values ('jarvis', 'health', 'telegram', 'HEALTH changed (' || (r ->> 'overall') || '):' || v_lines || E'\nSend /health for details.');
  end if;
  return jsonb_build_object('enabled', true, 'changed', n_changed, 'alerts_sent', n_alerts, 'held', n_held, 'quiet', n_quiet, 'overall', r ->> 'overall');
end $$;
revoke all on function public.fz_health_check() from public, anon, authenticated;

create or replace function public.fz_owner_set_health_alerts(p_on boolean) returns jsonb
language plpgsql security definer set search_path to 'pg_catalog' as $$
begin
  if not public.fz_m6_owner_session() then raise exception 'owner approval required: only the owner switches health alerts' using errcode = '42501'; end if;
  update public.fz_health_config set alerts_enabled = coalesce(p_on, false), updated_by = case when coalesce(public.is_app_owner(), false) then 'owner' else 'owner:sql' end where id = 1;
  insert into public.audit_log (actor, action, target, detail) values ('owner', 'health_alerts_switch', 'fz_health_config', jsonb_build_object('on', coalesce(p_on, false)));
  return jsonb_build_object('ok', true, 'alerts_enabled', coalesce(p_on, false));
end $$;
revoke all on function public.fz_owner_set_health_alerts(boolean) from public, anon, authenticated;

-- ---------------------------------------------------------------------------------------------------------------------------- shared brain
-- the caller's office: a scoped identity's own office; the service key and a database session act for the group (so they read group facts only)
create or replace function public.fz_brain_caller_office() returns uuid
language plpgsql stable security definer set search_path to 'pg_catalog' as $$
declare i record;
begin
  if coalesce(nullif(current_setting('role', true), ''), 'none') in ('fz_jarvis', 'fz_office_agent', 'fz_auditor') then
    select * into i from public.fz_identity_now();
    if i.slug is null then raise exception 'no valid identity' using errcode = '42501'; end if;
    return i.office_id;
  end if;
  if coalesce(nullif(current_setting('role', true), ''), 'none') in ('none', 'postgres', 'service_role') then
    return (select id from public.fz_offices where slug = 'group');
  end if;
  raise exception 'the shared brain is not readable by this role' using errcode = '42501';
end $$;
revoke all on function public.fz_brain_caller_office() from public, anon, authenticated;

-- THE read path: active group facts + the caller's own office facts. Nothing else.
create or replace function public.fz_brain_read(p_query text default null, p_limit integer default 20) returns jsonb
language plpgsql stable security definer set search_path to 'pg_catalog' as $$
declare v_office uuid := public.fz_brain_caller_office(); v_q text := nullif(btrim(coalesce(p_query, '')), ''); v_lim int := least(greatest(coalesce(p_limit, 20), 1), 50);
begin
  v_q := replace(replace(replace(v_q, '\', '\\'), '%', '\%'), '_', '\_');
  return coalesce((select jsonb_agg(jsonb_build_object('id', f.id, 'scope', coalesce(o.slug, 'group'), 'topic', f.topic, 'fact', f.fact, 'source', f.source,
                                                       'confidence', f.confidence, 'provenance', f.provenance, 'created_by_office', co.slug, 'created_at', f.created_at)
                                    order by f.created_at desc)
                     from (select * from public.fz_brain_facts x
                            where x.superseded_by is null
                              and (x.office_id is null or x.office_id = v_office)
                              and (v_q is null or x.topic ilike '%' || v_q || '%' or x.fact ilike '%' || v_q || '%')
                            order by x.created_at desc limit v_lim) f
                     left join public.fz_offices o on o.id = f.office_id left join public.fz_offices co on co.id = f.created_by_office), '[]'::jsonb);
end $$;
revoke all on function public.fz_brain_read(text, integer) from public, anon, authenticated;

-- the existing leak redaction (backup_redact_text, strict). The client-name context (backup_redaction_context) is reserved to the backup identity and database sessions
-- (backup_assert_reader); elsewhere the pattern-level redaction is used and the result says so ('patterns'), so it is never taken for a full redaction.
create or replace function public.fz_brain_redact(p_text text, p_max integer, out redacted text, out level text)
language plpgsql stable security definer set search_path to 'pg_catalog' as $$
declare ctx jsonb;
begin
  begin
    ctx := public.backup_redaction_context(); level := 'full';
  exception when insufficient_privilege then
    ctx := null; level := 'patterns';
  end;
  redacted := public.backup_redact_text(p_text, ctx, p_max, 'strict');
end $$;
revoke all on function public.fz_brain_redact(text, integer) from public, anon, authenticated;

-- review MED 2: provenance that reaches the group: only allowlisted keys, every value through the strict redaction, URLs without query string or fragment
create or replace function public.fz_brain_clean_provenance(p jsonb) returns jsonb
language plpgsql stable security definer set search_path to 'pg_catalog' as $$
declare k text; v jsonb; t text; rr record; out_ jsonb := '{}'::jsonb;
begin
  for k, v in select e.key, e.value from jsonb_each(coalesce(p, '{}'::jsonb)) e where e.key in ('kind', 'source_table', 'source_id', 'url') loop
    continue when jsonb_typeof(v) not in ('string', 'number');
    t := left(v #>> '{}', 500);
    if k = 'url' then t := regexp_replace(t, '[?#].*$', ''); end if;
    select * into rr from public.fz_brain_redact(t, 500);
    out_ := out_ || jsonb_build_object(k, rr.redacted);
  end loop;
  return out_;
end $$;
revoke all on function public.fz_brain_clean_provenance(jsonb) from public, anon, authenticated;

-- append a fact. Scope: a scoped identity writes to its OWN office (p_office ignored). The service key writes for an office it names (p_office: an office slug,
-- never 'group'): office knowledge stays office-scoped. A GROUP-wide fact is written only by the owner / a database session (fully redacted) or by an approved promotion.
-- p_supersedes: an active fact in the same scope that this one replaces.
create or replace function public.fz_brain_add(p_topic text, p_fact text, p_source text, p_confidence numeric, p_provenance jsonb default '{}',
                                               p_supersedes uuid default null, p_by text default 'jarvis', p_office text default null) returns uuid
language plpgsql security definer set search_path to 'pg_catalog' as $$
declare v_role text := coalesce(nullif(current_setting('role', true), ''), 'none'); v_group uuid := (select id from public.fz_offices where slug = 'group');
        v_office uuid := public.fz_brain_caller_office(); v_scope uuid; v_id uuid; r record;
        v_topic text := left(btrim(coalesce(p_topic, '')), 120); v_fact text := left(btrim(coalesce(p_fact, '')), 2000); old public.fz_brain_facts; v_prov jsonb := coalesce(p_provenance, '{}'::jsonb);
begin
  if v_role in ('service_role', 'none', 'postgres') and p_office is not null and p_office <> 'group' then
    select id into v_office from public.fz_offices where slug = p_office and kind = 'office';
    if v_office is null then raise exception 'unknown office %', p_office using errcode = '22023'; end if;
  end if;
  v_scope := case when v_office = v_group then null else v_office end;
  if v_scope is null then
    if not public.fz_m6_owner_session() then
      raise exception 'group-wide facts come only from the owner or an approved promotion (name an office: p_office)' using errcode = '42501';
    end if;
    select * into r from public.fz_brain_redact(v_topic, 120); v_topic := r.redacted;
    select * into r from public.fz_brain_redact(v_fact, 2000); v_fact := r.redacted;
    v_prov := public.fz_brain_clean_provenance(v_prov);
  end if;
  if p_supersedes is not null then
    select * into old from public.fz_brain_facts where id = p_supersedes for update;
    if not found or old.superseded_by is not null or old.office_id is distinct from v_scope then
      raise exception 'can supersede only an active fact in your own scope' using errcode = '42501';
    end if;
  end if;
  insert into public.fz_brain_facts (office_id, topic, fact, source, confidence, provenance, created_by_office, created_by, supersedes)
    values (v_scope, v_topic, v_fact, left(coalesce(nullif(btrim(p_source), ''), 'unknown'), 200), p_confidence, v_prov, v_office,
            left(regexp_replace(coalesce(p_by, ''), '[^A-Za-z0-9:_.-]', '', 'g'), 60), p_supersedes)
    returning id into v_id;
  if p_supersedes is not null then
    update public.fz_brain_facts set superseded_by = v_id, superseded_at = now() where id = p_supersedes;
  end if;
  return v_id;
end $$;
revoke all on function public.fz_brain_add(text, text, text, numeric, jsonb, uuid, text, text) from public, anon, authenticated;

-- ask for an office fact to become group-wide: the request holds the REDACTED text only; it waits in the M3 approval queue
create or replace function public.fz_brain_propose_promotion(p_fact_id uuid, p_by text default 'jarvis') returns uuid
language plpgsql security definer set search_path to 'pg_catalog' as $$
declare f public.fz_brain_facts; v_id uuid; v_by text := left(regexp_replace(coalesce(p_by, ''), '[^A-Za-z0-9:_.-]', '', 'g'), 60); v_office uuid := public.fz_brain_caller_office(); rt record; rf record;
        v_group uuid := (select id from public.fz_offices where slug = 'group'); v_role text := coalesce(nullif(current_setting('role', true), ''), 'none');
        v_req text; v_via text; i record;
begin
  -- review MED 1: who asked is decided by the caller's role, never by p_by (kept only as an unverified label in the audit row)
  if v_role in ('fz_jarvis', 'fz_office_agent', 'fz_auditor') then
    select * into i from public.fz_identity_now();
    v_req := coalesce(i.slug, 'unknown'); v_via := 'scoped';
  elsif v_role in ('none', 'postgres') or coalesce(public.is_app_owner(), false) then
    v_req := 'owner'; v_via := 'owner';
  else
    v_req := 'jarvis'; v_via := 'service';                              -- the service key / any bot caller is Jarvis-side
  end if;
  select * into f from public.fz_brain_facts where id = p_fact_id;
  if not found or f.office_id is null or f.superseded_by is not null then raise exception 'only an active office fact can be promoted' using errcode = '22023'; end if;
  if v_office <> v_group and v_office <> f.office_id then raise exception 'an office proposes only its own facts' using errcode = '42501'; end if;
  perform pg_advisory_xact_lock(hashtext('fz_brain_prom:' || f.office_id::text));
  if exists (select 1 from public.fz_brain_promotions where fact_id = f.id and status = 'pending' and expires_at > now()) then
    raise exception 'a promotion of this fact is already waiting' using errcode = '23505';
  end if;
  if (select count(*) from public.fz_brain_promotions where office_id = f.office_id and status = 'pending' and expires_at > now()) >= 10 then
    raise exception 'too many promotion requests waiting for this office (10)' using errcode = '54000';
  end if;
  select * into rt from public.fz_brain_redact(f.topic, 120);
  select * into rf from public.fz_brain_redact(f.fact, 2000);
  insert into public.fz_brain_promotions (fact_id, office_id, redacted_topic, redacted_fact, redacted_provenance, redaction_level, requested_by, requested_via)
    values (f.id, f.office_id, rt.redacted, rf.redacted,
            public.fz_brain_clean_provenance(f.provenance),
            case when rt.level = 'full' and rf.level = 'full' then 'full' else 'patterns' end,
            v_req, v_via)
    returning id into v_id;
  insert into public.audit_log (actor, action, target, detail) values (v_req, 'brain_promotion_requested', 'fz_brain_promotions:' || v_id,
    jsonb_build_object('fact', f.id, 'office', f.office_id, 'via', v_via, 'claimed_by', nullif(v_by, '')));
  return v_id;
end $$;
revoke all on function public.fz_brain_propose_promotion(uuid, text) from public, anon, authenticated;

-- the full redaction pass (with the client-name context): the scheduler (cron) and the owner run it; it only ever replaces a 'patterns' redaction of a pending request
create or replace function public.fz_brain_redact_pending() returns integer
language plpgsql security definer set search_path to 'pg_catalog' as $$
declare p record; rt record; rf record; n int := 0;
begin
  if not public.fz_m6_owner_session() then raise exception 'the full redaction pass runs from the scheduler or the owner only' using errcode = '42501'; end if;
  for p in select b.id, f.topic, f.fact from public.fz_brain_promotions b join public.fz_brain_facts f on f.id = b.fact_id
            where b.status = 'pending' and b.redaction_level = 'patterns' for update of b loop
    select * into rt from public.fz_brain_redact(p.topic, 120);
    select * into rf from public.fz_brain_redact(p.fact, 2000);
    continue when rt.level <> 'full' or rf.level <> 'full';
    update public.fz_brain_promotions set redacted_topic = rt.redacted, redacted_fact = rf.redacted, redaction_level = 'full' where id = p.id;
    n := n + 1;
  end loop;
  return n;
end $$;
revoke all on function public.fz_brain_redact_pending() from public, anon, authenticated;

-- the decision (one body for both deciders; NOT callable on its own: it checks who may decide)
create or replace function public.fz_brain_decide(p_id uuid, p_approve boolean, p_decider text) returns jsonb
language plpgsql security definer set search_path to 'pg_catalog' as $$
declare p public.fz_brain_promotions; v_fact uuid; v_owner boolean := public.fz_m6_owner_session();
begin
  if p_decider = 'owner' then
    if not v_owner then raise exception 'owner approval required: only the signed-in owner decides here' using errcode = '42501'; end if;
  elsif p_decider = 'jarvis' then
    if coalesce(nullif(current_setting('role', true), ''), 'none') not in ('service_role', 'none', 'postgres') then raise exception 'not the Jarvis path' using errcode = '42501'; end if;
    if not coalesce((select jarvis_may_approve from public.fz_brain_config where id = 1), false) then
      raise exception 'Jarvis may not approve brain promotions (owner setting off): the owner decides' using errcode = '42501';
    end if;
  else
    raise exception 'unknown decider' using errcode = '22023';
  end if;
  select * into p from public.fz_brain_promotions where id = p_id for update;
  if not found then raise exception 'unknown promotion request' using errcode = '22023'; end if;
  if p.status <> 'pending' then raise exception 'already decided (%)', p.status using errcode = '22023'; end if;
  if p.expires_at <= now() then
    update public.fz_brain_promotions set status = 'expired', decided_at = now(), decided_by = 'expiry' where id = p.id;
    return jsonb_build_object('ok', false, 'status', 'expired');
  end if;
  -- review MED 1: Jarvis decides only requests an OFFICE identity made (requested_via = 'scoped'); anything that came through the service path is Jarvis-side
  if p_decider = 'jarvis' and (p.requested_via <> 'scoped' or p.requested_by like 'jarvis%') then
    raise exception 'Jarvis does not approve its own request (it came through the service path): the owner decides' using errcode = '42501';
  end if;
  if p_approve and p.redaction_level <> 'full' then
    if v_owner then perform public.fz_brain_redact_pending(); select * into p from public.fz_brain_promotions where id = p_id; end if;
    if p.redaction_level <> 'full' then
      raise exception 'this request has only the pattern-level redaction so far: the full redaction pass (scheduler, every 10 minutes) must run before it is approved' using errcode = '55000';
    end if;
  end if;
  if p_approve then
    insert into public.fz_brain_facts (office_id, topic, fact, source, confidence, provenance, created_by_office, created_by, supersedes)
      select null, p.redacted_topic, p.redacted_fact, 'promotion', f.confidence, p.redacted_provenance || jsonb_build_object('promoted_from', f.id, 'promotion', p.id),
             f.office_id, p_decider, null
        from public.fz_brain_facts f where f.id = p.fact_id
      returning id into v_fact;
  end if;
  update public.fz_brain_promotions set status = case when p_approve then 'approved' else 'rejected' end, decided_at = now(), decided_by = p_decider, group_fact_id = v_fact
   where id = p.id;
  insert into public.audit_log (actor, action, target, detail) values (p_decider, case when p_approve then 'brain_promotion_approved' else 'brain_promotion_rejected' end,
    'fz_brain_promotions:' || p.id, jsonb_build_object('group_fact', v_fact));
  return jsonb_build_object('ok', true, 'status', case when p_approve then 'approved' else 'rejected' end, 'group_fact', v_fact);
end $$;
revoke all on function public.fz_brain_decide(uuid, boolean, text) from public, anon, authenticated;

create or replace function public.fz_owner_decide_brain_promotion(p_id uuid, p_approve boolean) returns jsonb
language sql security definer set search_path to 'pg_catalog' as $$ select public.fz_brain_decide(p_id, p_approve, 'owner') $$;
revoke all on function public.fz_owner_decide_brain_promotion(uuid, boolean) from public, anon, authenticated;
create or replace function public.fz_jarvis_decide_brain_promotion(p_id uuid, p_approve boolean) returns jsonb
language sql security definer set search_path to 'pg_catalog' as $$ select public.fz_brain_decide(p_id, p_approve, 'jarvis') $$;
revoke all on function public.fz_jarvis_decide_brain_promotion(uuid, boolean) from public, anon, authenticated;

create or replace function public.fz_owner_set_brain_jarvis_approval(p_on boolean) returns jsonb
language plpgsql security definer set search_path to 'pg_catalog' as $$
begin
  if not public.fz_m6_owner_session() then raise exception 'owner approval required: only the owner lets Jarvis approve promotions' using errcode = '42501'; end if;
  update public.fz_brain_config set jarvis_may_approve = coalesce(p_on, false), updated_by = 'owner' where id = 1;
  insert into public.audit_log (actor, action, target, detail) values ('owner', 'brain_jarvis_approval_switch', 'fz_brain_config', jsonb_build_object('on', coalesce(p_on, false)));
  return jsonb_build_object('ok', true, 'jarvis_may_approve', coalesce(p_on, false));
end $$;
revoke all on function public.fz_owner_set_brain_jarvis_approval(boolean) from public, anon, authenticated;

-- the owner's /brain view: what the bot may read (group facts) plus per-office COUNTS only (never another office's text)
create or replace function public.fz_brain_report(p_query text default null) returns jsonb
language plpgsql stable security definer set search_path to 'pg_catalog' as $$
begin
  if coalesce(nullif(current_setting('role', true), ''), 'none') in ('fz_jarvis', 'fz_office_agent', 'fz_auditor') then
    raise exception 'the brain report is for the owner' using errcode = '42501';
  end if;
  return jsonb_build_object('facts', public.fz_brain_read(p_query, 15),
    'by_office', coalesce((select jsonb_object_agg(coalesce(o.slug, 'group'), n) from (select office_id, count(*) n from public.fz_brain_facts where superseded_by is null group by 1) x
                             left join public.fz_offices o on o.id = x.office_id), '{}'::jsonb),
    'promotions_pending', (select count(*) from public.fz_brain_promotions where status = 'pending' and expires_at > now()),
    'jarvis_may_approve', (select jarvis_may_approve from public.fz_brain_config where id = 1));
end $$;
revoke all on function public.fz_brain_report(text) from public, anon, authenticated;

-- ---------------------------------------------------------------------------------------------------------------------------- the M3 queue gains the brain promotions
create or replace view public.fz_approval_queue with (security_barrier = true) as
with q as (
  select 'action_approval'::text as request_type, r.id as source_id,
         coalesce(g.office_id, 'f0000000-0000-4000-8000-000000000000'::uuid) as office_id,
         r.actor as requester, r.action, r.cents::bigint as amount_cents, coalesce(p.tier, 'unknown') as risk,
         case when r.status = 'pending' and r.expires_at <= now() then 'expired' else r.status end as status,
         r.created_at, r.expires_at, r.decided_at,
         'owner Telegram tap (approval message)'::text as decided_by_path
    from public.approval_requests r
    left join public.agents g on g.slug = r.actor
    left join public.action_policy p on p.action = r.action
  union all
  -- every column named in both branches: the off-site restore re-creates the view from pg_get_viewdef(), which is only a fixed point with named columns
  select 'office_money_' || m.kind as request_type, m.id as source_id, m.office_id as office_id, m.proposed_by as requester, m.kind as action,
         m.cents::bigint as amount_cents, 'money'::text as risk,
         case when m.status = 'pending' and m.expires_at <= now() then 'expired' else m.status end as status,
         m.created_at as created_at, m.expires_at as expires_at, m.decided_at as decided_at,
         'owner session: fz_owner_decide_office_proposal'::text as decided_by_path
    from public.fz_office_money_proposals m
  union all
  -- M6: brain promotions (office fact -> group-wide), redacted text only
  select 'brain_promotion'::text as request_type, b.id as source_id, b.office_id as office_id, b.requested_by as requester, 'brain_promote'::text as action,
         0::bigint as amount_cents, 'knowledge'::text as risk,
         case when b.status = 'pending' and b.expires_at <= now() then 'expired' else b.status end as status,
         b.created_at as created_at, b.expires_at as expires_at, b.decided_at as decided_at,
         'owner session: fz_owner_decide_brain_promotion (or Jarvis if the owner allowed it)'::text as decided_by_path
    from public.fz_brain_promotions b
)
select q.request_type, q.source_id, q.office_id, o.slug as office, q.requester, q.action, q.amount_cents, q.risk, q.status, q.created_at, q.expires_at, q.decided_at,
       q.decided_by_path
  from q
  left join public.fz_offices o on o.id = q.office_id
 where coalesce(nullif(current_setting('role', true), ''), 'none') in ('none', 'postgres', 'service_role')      -- review fix 7: an allowlist of who sees everything
    or (coalesce(nullif(current_setting('role', true), ''), 'none') in ('fz_jarvis', 'fz_office_agent', 'fz_auditor')
        and ((select public.is_group_scope()) or q.office_id = (select public.current_office_id())));   -- scoped: own office (group scope: all); anyone else: nothing

revoke all on public.fz_approval_queue from public, anon, authenticated, service_role, fz_jarvis, fz_office_agent, fz_auditor;
grant select on public.fz_approval_queue to service_role, fz_jarvis, fz_office_agent, fz_auditor;

-- ---------------------------------------------------------------------------------------------------------------------------- scoped roles get nothing new (M1 allowlist); the schedule
do $$
declare f regprocedure;
begin
  if exists (select 1 from pg_roles where rolname = 'fz_jarvis') then
    for f in select p.oid::regprocedure from pg_proc p where p.pronamespace = 'public'::regnamespace and (p.proname like 'fz\_health%' or p.proname like 'fz\_brain%'
               or p.proname in ('fz_m6_owner_session', 'fz_m6_config_guard', 'fz_owner_set_health_alerts', 'fz_owner_decide_brain_promotion', 'fz_jarvis_decide_brain_promotion',
                                'fz_owner_set_brain_jarvis_approval')) loop
      execute format('revoke all on function %s from fz_jarvis, fz_office_agent, fz_auditor', f);
    end loop;
  end if;
  if exists (select 1 from pg_namespace where nspname = 'cron') then
    perform cron.unschedule(jobid) from cron.job where jobname = 'fz-health-check';
    perform cron.schedule('fz-health-check', '*/10 * * * *', 'select public.fz_health_check(); select public.fz_brain_redact_pending()');
  end if;
end $$;

-- re-apply after a rollback: the archived brain (facts, promotions) and settings come back; nothing is lost
do $$
begin
  if to_regclass('fz_archive.fz_brain_facts') is not null and not exists (select 1 from public.fz_brain_facts) then
    alter table public.fz_brain_facts disable trigger fz_brain_facts_guard;
    insert into public.fz_brain_facts (id, office_id, topic, fact, source, confidence, provenance, created_by_office, created_by, created_at, supersedes, superseded_by, superseded_at)
      select id, office_id, topic, fact, source, confidence, provenance, created_by_office, created_by, created_at, null, null, null from fz_archive.fz_brain_facts;
    update public.fz_brain_facts f set supersedes = a.supersedes, superseded_by = a.superseded_by, superseded_at = a.superseded_at from fz_archive.fz_brain_facts a where a.id = f.id;
    alter table public.fz_brain_facts enable trigger fz_brain_facts_guard;
  end if;
  -- an archive made by an earlier M6 build may lack the review columns: add them with the strictest default (a request of unknown origin is Jarvis-side)
  if to_regclass('fz_archive.fz_brain_promotions') is not null then
    alter table fz_archive.fz_brain_promotions add column if not exists requested_via text not null default 'service';
  end if;
  if to_regclass('fz_archive.fz_health_state') is not null then
    alter table fz_archive.fz_health_state add column if not exists pending_status text, add column if not exists pending_runs int not null default 0,
      add column if not exists last_alert_at timestamptz;
  end if;
  if to_regclass('fz_archive.fz_brain_promotions') is not null and not exists (select 1 from public.fz_brain_promotions) then
    alter table public.fz_brain_promotions disable trigger fz_brain_promotions_guard;
    insert into public.fz_brain_promotions (id, fact_id, office_id, redacted_topic, redacted_fact, redacted_provenance, redaction_level, requested_by, requested_via, status, created_at, expires_at, decided_at, decided_by, group_fact_id) select id, fact_id, office_id, redacted_topic, redacted_fact, redacted_provenance, redaction_level, requested_by, requested_via, status, created_at, expires_at, decided_at, decided_by, group_fact_id from fz_archive.fz_brain_promotions;
    alter table public.fz_brain_promotions enable trigger fz_brain_promotions_guard;
  end if;
  if to_regclass('fz_archive.fz_health_alerts') is not null and not exists (select 1 from public.fz_health_alerts) then
    insert into public.fz_health_alerts (check_key, status, dedupe_key, detail, at)
      select check_key, status, dedupe_key, detail, at from fz_archive.fz_health_alerts on conflict do nothing;
  end if;
  if to_regclass('fz_archive.fz_health_state') is not null and not exists (select 1 from public.fz_health_state) then
    insert into public.fz_health_state (check_key, status, generation, detail, changed_at, seen_at, pending_status, pending_runs, last_alert_at) select check_key, status, generation, detail, changed_at, seen_at, pending_status, pending_runs, last_alert_at from fz_archive.fz_health_state;
  end if;
  if to_regclass('fz_archive.fz_brain_config') is not null then
    update public.fz_brain_config c set jarvis_may_approve = a.jarvis_may_approve, updated_by = 'migration (restored)' from fz_archive.fz_brain_config a where a.id = c.id;
  end if;
  if to_regclass('fz_archive.fz_health_config') is not null then
    update public.fz_health_config c set alerts_enabled = a.alerts_enabled, updated_by = 'migration (restored)' from fz_archive.fz_health_config a where a.id = c.id;
  end if;
end $$;

-- ---------------------------------------------------------------------------------------------------------------------------- registry (M1) + backup classification
insert into public.fz_table_registry (relname, scope, scope_column, data_class, fz_read, fz_write, fz_insert_columns, fz_update_columns, note) values
  ('fz_health_config',    'group', null, 'internal', false, '{}', null, null, 'monitoring: alerts switch (owner)'),
  ('fz_health_state',     'group', null, 'internal', false, '{}', null, null, 'monitoring: last status per check'),
  ('fz_health_alerts',    'group', null, 'internal', false, '{}', null, null, 'monitoring: append-only alerts'),
  ('fz_brain_config',     'group', null, 'internal', false, '{}', null, null, 'shared brain: owner settings'),
  ('fz_brain_facts',      'office', 'office_id', 'confidential', false, '{}', null, null, 'shared brain: append-only facts (NULL office = group); read only via fz_brain_read'),
  ('fz_brain_promotions', 'office', 'office_id', 'confidential', false, '{}', null, null, 'shared brain: office -> group promotion requests (redacted text)')
on conflict (relname) do update set scope = excluded.scope, scope_column = excluded.scope_column, data_class = excluded.data_class, fz_read = excluded.fz_read,
  fz_write = excluded.fz_write, fz_insert_columns = excluded.fz_insert_columns, fz_update_columns = excluded.fz_update_columns, note = excluded.note;

-- backup classification (PROTECTED: owner approval): same rows as 20261201_shared_services_v1 plus the six M6 tables ('secret': not in the off-site export)
create or replace function public.backup_classification() returns table (table_name text, data_class text, note text)
language sql immutable set search_path to 'pg_catalog' as $$
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
    ('jarvis_result_cache', 'secret', 'cached task output; may contain client data, never exported (rebuilt on demand)'),
    ('jarvis_call_criteria', 'secret', 'the owner-approved emergency-call events (copy of ops/CRITICAL_EVENTS.json); off-site export pending'),
    ('jarvis_seed_staging', 'secret', 'owner profile import staged by the bot until the owner applies it; private, never exported'),
    -- Jarvis hands v1 (20261124): metadata only, no secrets (vault references are ids; tokens and passwords live only in the vault)
    ('hand_connectors', 'internal', 'connector registry and owner settings'), ('hand_accounts', 'internal', 'which accounts exist; vault references only, no secrets'),
    ('hand_actions', 'internal', 'action and content queue (payload free text is not exported)'), ('hand_standing', 'internal', 'owner standing approvals'),
    -- Org & Access M1 (20261127): org registry. Class 'secret' = not in the off-site export (as Jarvis core): the offices, identities and table registry are re-seeded by the
    -- migration (statuses come back DORMANT, which is the safe state); exporting them needs reviewed backup_redaction_spec() rows first (follow-up, protected).
    ('fz_offices', 'secret', 'the group and the eight offices; re-seeded by the migration; off-site export pending a reviewed redaction spec'),
    ('fz_identities', 'secret', 'identity registry (status, pinned token ids); re-seeded by the migration'),
    ('fz_table_registry', 'secret', 'table classification; re-seeded by the migration'),
    ('fz_workspace_offices', 'secret', 'which office serves each client workspace; off-site export pending'),
    ('fz_office_action_policy', 'secret', 'per-office tighten-only permission overlay; off-site export pending'),
    ('fz_org_archive', 'secret', 'append-only log of the org re-seed decisions; off-site export pending'),
    -- Office money M2 (20261128): virtual sub-ledgers. 'secret' = not in the off-site export, like the M1 registry. After a restore from the off-site file every office is
    -- back at $0 with no reinvestment (the strictest state); the database provider's own backups keep the history. Exporting needs reviewed redaction-spec rows (protected).
    ('fz_money_config', 'secret', 'office money attribution cutover; re-created by the migration'),
    ('fz_office_allocations', 'secret', 'owner allocations / clawbacks per office (amounts and reasons); off-site export pending'),
    ('fz_office_money_policy', 'secret', 'per-office reinvestment rule; off-site export pending'),
    ('fz_office_money_proposals', 'secret', 'bot money proposals and owner decisions; off-site export pending'),
    ('fz_money_attribution', 'secret', 'office of each ledger row / model call / reservation; off-site export pending'),
    -- Security hardening M4 (20261130): 'secret' = not in the off-site export (as the M1 / M2 registries); after a restore the chain is rebuilt from the restored audit_log.
    ('fz_audit_chain', 'secret', 'append-only hash chain over audit_log; rebuilt after a restore'),
    ('fz_audit_pending', 'secret', 'audit rows seen but not chained yet'),
    ('fz_audit_state', 'secret', 'chain genesis / checkpoint / last full scan'),
    ('fz_security_baseline', 'secret', 'privileged items seen and their status'),
    ('fz_security_fingerprints', 'secret', 'SECURITY DEFINER body + settings fingerprints'),
    ('fz_security_alerts', 'secret', 'append-only security alerts sent to the owner'),
    ('fz_token_registry', 'secret', 'minted scoped token ids and expiry (never a token)'),
    -- Shared services M5 (20261201): the services registry ('secret' = not in the off-site export, as the M1 registries; re-seeded by the migration)
    ('fz_services', 'secret', 'shared services registry and the owner scoped-read decisions; re-seeded by the migration'),
    -- Monitoring + shared brain M6 (20261202): 'secret' = not in the off-site export (brain facts may hold office knowledge; exporting needs reviewed redaction-spec rows)
    ('fz_health_config', 'secret', 'health alerts switch'),
    ('fz_health_state', 'secret', 'last status per health check'),
    ('fz_health_alerts', 'secret', 'append-only health alerts'),
    ('fz_brain_config', 'secret', 'shared brain owner settings'),
    ('fz_brain_facts', 'secret', 'shared brain facts (office knowledge); off-site export pending a reviewed redaction spec'),
    ('fz_brain_promotions', 'secret', 'office -> group promotion requests (redacted text)')
  ) v (table_name, data_class, note)
$$;
revoke all on function public.backup_classification() from public, anon, authenticated;
reset lock_timeout;
