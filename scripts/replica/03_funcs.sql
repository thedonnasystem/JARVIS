CREATE OR REPLACE FUNCTION public.agent_can_run(p_agent text) RETURNS boolean LANGUAGE sql STABLE SET search_path TO 'public' AS $function$
  select (not s.kill_switch) and a.status = 'active'
    and coalesce((select sum(coalesce(c.actual_cents, c.reserved_cents)) from public.llm_calls c where c.agent_slug = a.slug and c.status in ('reserved','done') and c.started_at >= (date_trunc('day', now() at time zone 'America/Toronto') at time zone 'America/Toronto')), 0) < a.daily_spend_cap_cents
    and coalesce((select sum(coalesce(c.actual_cents, c.reserved_cents)) from public.llm_calls c where c.status in ('reserved','done') and c.started_at >= (date_trunc('day', now() at time zone 'America/Toronto') at time zone 'America/Toronto')), 0) < s.daily_spend_cap_cents
  from public.agents a, public.system_state s where a.slug = p_agent;
$function$;
CREATE OR REPLACE FUNCTION public.enforce_max_active_ventures() RETURNS trigger LANGUAGE plpgsql SET search_path TO 'public' AS $function$
declare v_active int;
begin
  if new.status in ('testing','scaled') and (tg_op = 'INSERT' or old.status is distinct from new.status) then
    select (select count(*) from ventures where status = 'active' and slug not in ('idea-lab','day-job-sales')) + (select count(*) from ideas where status in ('testing','scaled') and id <> new.id) into v_active;
    if v_active >= 3 then raise exception 'Max 3 revenue ventures at once (owner rule). Park or kill one first.'; end if;
    if new.status = 'testing' then new.test_started_on := coalesce(new.test_started_on, current_date); new.test_ends_on := coalesce(new.test_ends_on, current_date + 7); end if;
  end if;
  return new;
end $function$;
CREATE OR REPLACE FUNCTION public.enforce_mission_transition() RETURNS trigger LANGUAGE plpgsql SET search_path TO 'public' AS $function$
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
      else false end;
    if not ok then raise exception 'Mission cannot go from % to %.', old.status, new.status; end if;
    if new.status = 'completed' then
      if jsonb_typeof(new.evidence) <> 'array' or jsonb_array_length(new.evidence) = 0 then raise exception 'A mission cannot be completed without verified evidence.'; end if;
      new.completed_at := now();
    end if;
    new.last_progress_at := now();
  end if;
  return new;
end $function$;
CREATE OR REPLACE FUNCTION public.enforce_owner_contact() RETURNS trigger LANGUAGE plpgsql SET search_path TO 'public' AS $function$
begin
  if not exists (select 1 from public.agents where slug = new.from_agent and can_contact_owner and status = 'active') then
    raise exception 'Only Jarvis may contact the owner. Agent % must write to escalations instead.', new.from_agent;
  end if;
  return new;
end $function$;
CREATE OR REPLACE FUNCTION public.reserve_llm_budget(p_agent text, p_est_cents integer, p_model text, p_purpose text) RETURNS uuid LANGUAGE plpgsql SET search_path TO 'public' AS $function$
declare v_ks boolean; v_cap_total int; v_status text; v_cap_agent int; v_start timestamptz; v_total int; v_agent int; v_id uuid;
begin
  perform pg_advisory_xact_lock(7331);
  select kill_switch, daily_spend_cap_cents into v_ks, v_cap_total from public.system_state where id = 1;
  if v_ks then raise exception 'Kill switch is on.'; end if;
  select status, daily_spend_cap_cents into v_status, v_cap_agent from public.agents where slug = p_agent;
  if v_status is null then raise exception 'Unknown agent %.', p_agent; end if;
  if v_status <> 'active' then raise exception 'Agent % is paused.', p_agent; end if;
  v_start := (date_trunc('day', now() at time zone 'America/Toronto') at time zone 'America/Toronto');
  select coalesce(sum(coalesce(actual_cents, reserved_cents)), 0) into v_total from public.llm_calls where started_at >= v_start and status in ('reserved','done');
  select coalesce(sum(coalesce(actual_cents, reserved_cents)), 0) into v_agent from public.llm_calls where agent_slug = p_agent and started_at >= v_start and status in ('reserved','done');
  if v_agent + p_est_cents > v_cap_agent then raise exception 'Agent % would exceed its daily cap.', p_agent; end if;
  if v_total + p_est_cents > v_cap_total then raise exception 'The company daily spend cap would be exceeded.'; end if;
  insert into public.llm_calls (agent_slug, model, purpose, reserved_cents) values (p_agent, p_model, p_purpose, p_est_cents) returning id into v_id;
  return v_id;
end $function$;
CREATE OR REPLACE FUNCTION public.settle_llm_call(p_id uuid, p_actual_cents integer, p_status text DEFAULT 'done'::text) RETURNS void LANGUAGE sql SET search_path TO 'public' AS $function$
  update public.llm_calls set actual_cents = p_actual_cents, status = p_status, finished_at = now() where id = p_id;
$function$;
CREATE TRIGGER owner_contact_rule BEFORE INSERT ON public.owner_messages FOR EACH ROW EXECUTE FUNCTION enforce_owner_contact();
CREATE TRIGGER trg_max_active_ventures BEFORE INSERT OR UPDATE OF status ON public.ideas FOR EACH ROW EXECUTE FUNCTION enforce_max_active_ventures();
CREATE TRIGGER missions_lifecycle BEFORE INSERT OR UPDATE ON public.missions FOR EACH ROW EXECUTE FUNCTION enforce_mission_transition();
-- stubs for live functions that migrations call but do not define
create function public.daily_brief_core() returns text language sql as $$ select 'core brief'::text $$;
create function public.missions_brief_text() returns text language sql as $$ select 'missions brief'::text $$;
create function public.daily_brief_text() returns text language sql as $$ select 'brief'::text $$;
create function public.queue_weekly_review() returns uuid language sql as $$ select null::uuid $$;
create function public.run_reconciliation() returns void language sql as $$ select 1 $$;
create function public.station_snapshot() returns jsonb language sql as $$ select '{}'::jsonb $$;
-- Supabase stand-ins
create schema if not exists auth; create table if not exists auth.users (id uuid primary key default gen_random_uuid(), email text, email_confirmed_at timestamptz default now());
create or replace function auth.uid() returns uuid language sql as $$ select nullif(current_setting('app.uid', true), '')::uuid $$;
create or replace function auth.jwt() returns jsonb language sql as $$ select jsonb_build_object('email', current_setting('app.email', true)) $$;
create or replace function auth.email() returns text language sql as $$ select current_setting('app.email', true) $$;
create schema if not exists cron; create table if not exists cron.job (jobid serial, jobname text, schedule text, command text);
create or replace function cron.schedule(n text, s text, c text) returns int language sql as $$ insert into cron.job(jobname, schedule, command) values (n, s, c) returning jobid $$;
create or replace function cron.unschedule(j int) returns boolean language sql as $$ delete from cron.job where jobid = j; select true $$;
create extension if not exists pgcrypto;
-- seed agents the migrations expect
insert into public.ventures (slug, name, kind) values ('donna','Donna','revenue'),('idea-lab','Idea Lab','lab'),('day-job-sales','Day-job Sales','revenue'),('real-estate','Real Estate','revenue');
insert into public.departments (slug, name, kind) values ('holding','Holding','holding'),('research','Research','shared');
insert into public.agents (slug, title, role, department_slug, can_contact_owner, model_tier, status) values
 ('jarvis','Jarvis','owner_contact','holding',true,'strong','active'),('ceo','CEO','ceo','holding',false,'strong','active'),('coo','COO','coo','holding',false,'standard','active'),
 ('cfo','CFO','cfo','holding',false,'standard','active'),('hr','HR','hr','holding',false,'cheap','active'),('builder','Builder','builder','holding',false,'standard','active'),
 ('research','Research','researcher','research',false,'cheap','active'),('donna-ops','Donna Ops','ops','holding',false,'cheap','active');
insert into public.system_state (id) values (1);
create function public.dayjob_week_text() returns text language sql as $$ select 'Week: 0/5'::text $$;
create function public.night_shift_report(p_since timestamptz) returns text language sql as $$ select ''::text $$;
create function public.post_daily_brief() returns void language sql as $$ select 1 $$;
create function public.queue_daily_planning() returns void language sql as $$ select 1 $$;
create function public.queue_followup_digest() returns void language sql as $$ select 1 $$;
create function public.queue_outreach_drafts() returns void language sql as $$ select 1 $$;
create function public.queue_prospect_task() returns void language sql as $$ select 1 $$;
create function public.queue_valuation_task() returns void language sql as $$ select 1 $$;
create function public.estimate_call_cents(p_model text, p_input_tokens int, p_max_output_tokens int) returns int language sql as $$ select 1 $$;
create function public.mission_spent_cents(p_mission uuid) returns int language sql as $$ select 0 $$;
