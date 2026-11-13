-- ROLLBACK for the Phase 1 migrations (20261113_phase1_repair_v1 + 20261113_mission_guard_v1). Run ONLY if instructed; changes production.
-- Restores the three changed functions byte-for-byte to the Nov 12 live definitions (md5s in ops/live_functions_baseline_20261112.txt),
-- removes the new triggers/functions/cron job, and clears focus mode. Added columns, tables and unique indexes are LEFT IN PLACE:
-- they are inert without the new functions and dropping them would delete data (optional drops at the bottom, commented).
-- Safe to run twice. Then re-run migrations/20261112_lockdown_v1.sql so privileges are re-asserted, and run ops/verify_live.sql.

-- 0) focus mode off (the old reserve_llm_budget ignores it, but the engine of a newer deploy would still read it)
do $$ begin
  if exists (select 1 from information_schema.columns where table_schema = 'public' and table_name = 'system_state' and column_name = 'focus_mission') then
    update public.system_state set focus_mission = null where id = 1;
  end if;
end $$;

-- 1) stop the alert job
do $$ begin
  if exists (select 1 from pg_namespace where nspname = 'cron') then
    perform cron.unschedule(jobid) from cron.job where jobname = 'hq-ops-alerts';
  end if;
end $$;

-- 2) triggers added by Phase 1
drop trigger if exists tasks_mission_step_limit on public.tasks;
drop trigger if exists missions_plan_limit on public.missions;
drop trigger if exists audit_task_bulk_update on public.tasks;
drop trigger if exists audit_task_bulk_delete on public.tasks;

-- 3) restore changed functions to the live (Nov 12) definitions. reserve_llm_budget FIRST so the gateway no longer calls mission_guard.
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
  insert into public.llm_calls (agent_slug, model, purpose, reserved_cents)
    values (p_agent, p_model, p_purpose, p_est_cents) returning id into v_id;
  return v_id;
end $function$;

CREATE OR REPLACE FUNCTION public.queue_outreach_drafts()
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare r record; n int := 0;
begin
  for r in
    select v.id venture_id, v.slug, count(*) ready
    from leads l join ventures v on v.id = l.venture_id
    where l.status = 'new' and l.do_not_contact = false and l.email is not null and v.status = 'active'
    group by v.id, v.slug having count(*) >= 3
  loop
    -- one pending draft task per venture at a time, and only if its GM agent is active
    if exists (select 1 from tasks where venture_id = r.venture_id and title like 'Draft outreach%' and status in ('todo','doing')) then continue; end if;
    -- don't respawn a task that just failed (Nov 2026: one failing task was re-created every 30 min for 2 days)
    if exists (select 1 from tasks where venture_id = r.venture_id and title like 'Draft outreach%' and status = 'blocked' and updated_at > now() - interval '12 hours') then continue; end if;
    if (select pause_reason from system_state where id = 1) is not null then continue; end if;
    if not exists (select 1 from agents where slug = r.slug || '-division' and status = 'active') then continue; end if;
    insert into tasks (venture_id, assigned_agent, created_by, title, detail, status, priority)
    values (r.venture_id, r.slug || '-division', 'system', 'Draft outreach for new ' || r.slug || ' leads',
            format('%s emailable leads are waiting. Write one short email per lead using the venture''s offer and call to action from company knowledge. Personalize each email with one specific detail from the lead notes. Research or drafting only: nothing is sent without owner approval.', r.ready),
            'todo', 2);
    n := n + 1;
  end loop;
  return n;
end $function$;

CREATE OR REPLACE FUNCTION public.queue_valuation_task()
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_id uuid;
begin
  if not exists (select 1 from agents where slug = 'real-estate-researcher' and status = 'active') then return null; end if;
  if exists (select 1 from tasks where title like 'Value fixer leads%' and status in ('todo','doing')) then return null; end if;
  insert into tasks (venture_id, assigned_agent, created_by, title, detail, status, priority)
  values ('d50c02c1-0256-49eb-816b-c720d12944cb', 'real-estate-researcher', 'system',
          'Value fixer leads ' || to_char(now() at time zone 'America/Toronto', 'YYYY-MM-DD'),
          'Value the deal-funnel leads attached below so the funnel can tell which ones have room for a $15k assignment fee. Research only.',
          'todo', 2)
  returning id into v_id;
  return v_id;
end $function$;

-- 4) drop functions that only Phase 1 created (nothing else references them once the above is restored)
drop function if exists public.backup_snapshot(text[]);
drop function if exists public.backup_schema();
drop function if exists public.ops_alerts();
drop function if exists public._queue_alert(text, interval, text);
drop function if exists public.audit_task_bulk_update();
drop function if exists public.audit_task_bulk_delete();
drop function if exists public.enforce_mission_plan_limit();
drop function if exists public.enforce_mission_step_limit();
drop function if exists public.set_focus_mission(uuid, text);
drop function if exists public.mission_guard(text, text, integer);

-- Optional, destructive (loses the data in these columns/tables). NOT part of a normal rollback:
-- drop index if exists public.tasks_open_dedupe_key; drop index if exists public.outbox_one_draft_per_lead;
-- alter table public.tasks drop column if exists dedupe_key, drop column if exists mission_role;
-- alter table public.missions drop column if exists max_steps, drop column if exists strict_steps;
-- alter table public.system_state drop column if exists focus_mission;
-- drop table if exists public.integration_status, public.alert_state;

-- Deals / replies / do-not-contact (20261115_venture_deals_replies_v1): triggers first, then functions. venture_kpis goes back to the
-- 20261114 body here (the generic section below then drops it with the rest). Tables are LEFT IN PLACE (they hold the CASL
-- suppression list, replies and config; dropping would delete data): optional drops are commented at the end of this block.
drop trigger if exists outbox_dnc_guard on public.outbox;
drop trigger if exists leads_dnc_cascade on public.leads;
drop trigger if exists leads_suppression_guard on public.leads;
drop function if exists public.outbox_dnc_guard();
drop function if exists public.leads_dnc_cascade();
drop function if exists public.leads_suppression_guard();
create or replace function public.venture_kpis(p_venture text) returns jsonb
language plpgsql stable set search_path to 'public' as $$
declare v public.ventures;
begin
  select * into v from public.ventures where slug = p_venture;
  if not found then return null; end if;
  return jsonb_build_object(
    'venture', v.slug,
    'leads', (select count(*) from public.leads where venture_id = v.id),
    'emailable_leads', (select count(*) from public.leads where venture_id = v.id and email is not null and do_not_contact = false),
    'drafted', (select count(*) from public.outbox o left join public.leads l on l.id = o.lead_id where coalesce(o.venture_id, l.venture_id) = v.id),
    'approved', (select count(*) from public.outbox o left join public.leads l on l.id = o.lead_id where coalesce(o.venture_id, l.venture_id) = v.id and o.status in ('approved','sent')),
    'sent', (select count(*) from public.outbox o left join public.leads l on l.id = o.lead_id where coalesce(o.venture_id, l.venture_id) = v.id and o.status = 'sent'),
    'won_deals', (select count(*) from public.deals where venture_id = v.id and lower(stage) in ('won','closed','closed_won','paid')),
    'deals_by_stage', coalesce((select jsonb_object_agg(stage, n) from (select stage, count(*) n from public.deals where venture_id = v.id group by stage) d), '{}'::jsonb),
    'revenue_cents', coalesce((select sum(amount_cents) from public.ledger where venture_id = v.id and kind = 'revenue' and status = 'received' and intercompany = false), 0));
end $$;
drop function if exists public.lead_funnel(text);
drop function if exists public.set_venture_config(text, text, text, text);
drop function if exists public.venture_config_get(text);
drop function if exists public.confirm_deal_won(uuid, int, text, text, text);
drop function if exists public.set_deal_stage(uuid, text, text, text);
drop function if exists public.create_deal(uuid, int, text, text);
drop function if exists public.record_lead_reply(uuid, text, text, text);
drop function if exists public.mark_do_not_contact(uuid, text, text);
drop function if exists public.is_suppressed(text);
-- normalize_addr is referenced by the suppression table's CHECK: drop that constraint first (the table and its append-only trigger stay: legal record)
do $$ begin
  if to_regclass('public.contact_suppressions') is not null then
    alter table public.contact_suppressions drop constraint if exists contact_suppressions_address_check;
  end if;
end $$;
drop function if exists public.normalize_addr(text);
-- Optional, destructive, NOT part of a normal rollback (the suppression list is a legal record):
-- drop table if exists public.lead_replies, public.venture_config, public.contact_suppressions;

-- Venture generic loop (20261114_venture_generic_v1): new functions only, nothing else changed
drop function if exists public.ensure_venture_agents(text, text);
drop function if exists public.queue_prospect_task(text);
drop function if exists public.queue_all_prospect_tasks();
drop function if exists public.venture_kpis(text);

-- Unified Needs-you inbox (20261115_inbox_needs_you_v1): new functions only, nothing else changed
drop function if exists public.app_needs_you();
drop function if exists public.needs_you(integer);

-- Evidence verification v2 (20261116_evidence_sources_v1): derived, re-capturable snapshot cache, removed with the rest
drop table if exists public.evidence_sources;
drop function if exists public.purge_evidence_sources(integer);
drop function if exists public.evidence_sources_immutable();
