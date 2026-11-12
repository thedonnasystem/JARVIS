-- Phase 1 repair (owner directive Nov 12 2026). Safe to re-run. Does not touch money, limits, permissions or the kill switch.
-- 1) Duplicate-work protection: tasks.dedupe_key + unique index, and queue_outreach_drafts rewritten to use it.
-- 2) Audit of bulk task changes (one identifiable audit row per statement that changes >= 5 tasks, or any delete).
-- 3) integration_status: the bot records which optional integrations are configured; recurring work for a missing one is not created.
-- 4) ops_alerts(): actionable owner alerts with per-alert cooldowns.
-- 5) Reconciliation: captures the live-only enforce_build_rules function + trigger, and the live queue_outreach_drafts body.

-- focus mode column lives here too (also added by mission_guard_v1) so ops_alerts can reference it in either apply order
alter table public.system_state add column if not exists focus_mission uuid;

-- ---------- 1) idempotency ----------
alter table public.tasks add column if not exists dedupe_key text;
-- Only rows that carry a key are constrained, so historical rows are untouched. A key is "open" while todo/doing. (A blocked task does not hold
-- the key forever; the function below applies a 12 h cool-down after a failure and a daily circuit breaker instead.)
drop index if exists public.tasks_open_dedupe_key;
create unique index if not exists tasks_open_dedupe_key
  on public.tasks (dedupe_key) where dedupe_key is not null and status in ('todo','doing');
-- One unsent draft per lead, enforced by the database (verified: the 15 live drafts are 15 distinct leads).
create unique index if not exists outbox_one_draft_per_lead
  on public.outbox (lead_id) where lead_id is not null and status = 'draft';

create or replace function public.queue_outreach_drafts() returns integer
language plpgsql security definer set search_path to 'public' as $$
declare r record; n int := 0; got int;
begin
  if (select pause_reason from system_state where id = 1) is not null then return 0; end if;
  for r in
    select v.id venture_id, v.slug, count(*) ready
    from leads l join ventures v on v.id = l.venture_id
    where l.status = 'new' and l.do_not_contact = false and l.email is not null and v.status = 'active'
    group by v.id, v.slug having count(*) >= 3
  loop
    if exists (select 1 from tasks where venture_id = r.venture_id and title like 'Draft outreach%' and status in ('todo','doing')) then continue; end if;
    if exists (select 1 from tasks where venture_id = r.venture_id and title like 'Draft outreach%' and status = 'blocked' and updated_at > now() - interval '12 hours') then continue; end if;
    -- circuit breaker: never more than 3 draft tasks per venture per day, whatever their status (the Nov 2026 storm made 91)
    if (select count(*) from tasks where venture_id = r.venture_id and title like 'Draft outreach%' and created_at > now() - interval '24 hours') >= 3 then continue; end if;
    if not exists (select 1 from agents where slug = r.slug || '-division' and status = 'active') then continue; end if;
    -- The unique dedupe_key makes a second concurrent/repeated cron run a no-op instead of a duplicate task.
    insert into tasks (venture_id, assigned_agent, created_by, title, detail, status, priority, dedupe_key)
    values (r.venture_id, r.slug || '-division', 'system', 'Draft outreach for new ' || r.slug || ' leads',
            format('%s emailable leads are waiting. Write one short email per lead using the venture''s offer and call to action from company knowledge. Personalize each email with one specific detail from the lead notes. Research or drafting only: nothing is sent without owner approval.', r.ready),
            'todo', 2, 'draft-outreach:' || r.venture_id)
    on conflict do nothing;
    get diagnostics got = row_count;
    n := n + got;
  end loop;
  return n;
end $$;

-- ---------- 2) bulk-change audit ----------
-- Optional reason: the caller may run  select set_config('hq.reason', 'why', true)  in the same transaction.
create or replace function public.audit_task_bulk_update() returns trigger language plpgsql set search_path to 'public' as $$
declare changed int; sample jsonb; q text;
begin
  select count(*) into changed from old_rows o join new_rows n on n.id = o.id where n.status is distinct from o.status;
  if changed < 5 then return null; end if;
  select jsonb_agg(jsonb_build_object('id', id, 'from', f, 'to', t)) into sample
    from (select n.id, o.status f, n.status t from old_rows o join new_rows n on n.id = o.id
          where n.status is distinct from o.status order by n.id limit 200) s;
  q := left(coalesce(current_query(), ''), 300);
  insert into public.audit_log (actor, action, target, detail) values (
    'db:' || current_user, 'bulk_task_status_change', 'tasks',
    jsonb_build_object('rows_changed', changed,
      'transitions', (select jsonb_object_agg(k, c) from (select o.status || '->' || n.status k, count(*) c
          from old_rows o join new_rows n on n.id = o.id where n.status is distinct from o.status group by 1) z),
      'sample', coalesce(sample, '[]'::jsonb), 'txid', txid_current(), 'trigger', 'audit_task_bulk_update',
      'application', current_setting('application_name', true), 'query', q,
      'reason', coalesce(nullif(current_setting('hq.reason', true), ''), 'not stated')));
  return null;
end $$;
create or replace function public.audit_task_bulk_delete() returns trigger language plpgsql set search_path to 'public' as $$
declare c int;
begin
  select count(*) into c from old_rows;
  if c = 0 then return null; end if;
  insert into public.audit_log (actor, action, target, detail) values (
    'db:' || current_user, 'task_delete', 'tasks',
    jsonb_build_object('rows_deleted', c, 'statuses', (select jsonb_object_agg(status, n) from (select status, count(*) n from old_rows group by 1) z),
      'txid', txid_current(), 'application', current_setting('application_name', true), 'query', left(coalesce(current_query(), ''), 300),
      'reason', coalesce(nullif(current_setting('hq.reason', true), ''), 'not stated')));
  return null;
end $$;
drop trigger if exists audit_task_bulk_update on public.tasks;
create trigger audit_task_bulk_update after update on public.tasks
  referencing old table as old_rows new table as new_rows for each statement execute function public.audit_task_bulk_update();
drop trigger if exists audit_task_bulk_delete on public.tasks;
create trigger audit_task_bulk_delete after delete on public.tasks
  referencing old table as old_rows for each statement execute function public.audit_task_bulk_delete();

-- ---------- 3) integration status ----------
create table if not exists public.integration_status (
  key text primary key, ok boolean not null, detail text, checked_at timestamptz not null default now());
alter table public.integration_status enable row level security;
revoke all on public.integration_status from public, anon, authenticated;
grant all on public.integration_status to service_role;

-- Valuation work is only created when the bot has said the deal-funnel key exists (unknown counts as missing).
create or replace function public.queue_valuation_task() returns uuid
language plpgsql security definer set search_path to 'public' as $$
declare v_id uuid;
begin
  if not coalesce((select ok from integration_status where key = 'wholesale'), false) then return null; end if;
  if not exists (select 1 from agents where slug = 'real-estate-researcher' and status = 'active') then return null; end if;
  if exists (select 1 from tasks where title like 'Value fixer leads%' and status in ('todo','doing')) then return null; end if;
  insert into tasks (venture_id, assigned_agent, created_by, title, detail, status, priority)
  values ('d50c02c1-0256-49eb-816b-c720d12944cb', 'real-estate-researcher', 'system',
          'Value fixer leads ' || to_char(now() at time zone 'America/Toronto', 'YYYY-MM-DD'),
          'Value the deal-funnel leads attached below so the funnel can tell which ones have room for a $15k assignment fee. Research only.',
          'todo', 2)
  returning id into v_id;
  return v_id;
end $$;

-- ---------- 4) alerts ----------
create table if not exists public.alert_state (key text primary key, last_sent timestamptz not null default now());
alter table public.alert_state enable row level security;
revoke all on public.alert_state from public, anon, authenticated;
grant all on public.alert_state to service_role;

-- Returns how many alerts were queued. Each alert has its own cooldown so a standing problem is not repeated every run.
create or replace function public.ops_alerts() returns int
language plpgsql security definer set search_path to 'public' as $$
declare n int := 0; s record; c bigint; a record;
begin
  select * into s from system_state where id = 1;
  -- 1) credit exhaustion
  if s.pause_reason = 'api_credits' then
    n := n + public._queue_alert('credits', interval '12 hours',
      'HQ is paused: Anthropic credits are out (since ' || to_char(s.paused_at at time zone 'America/Toronto', 'Mon DD HH24:MI') || '). Add credit in the Anthropic console; HQ resumes by itself and requeues the blocked work.');
  -- 2) paused for another reason for over an hour
  elsif s.pause_reason is not null and s.paused_at < now() - interval '1 hour' then
    n := n + public._queue_alert('paused', interval '6 hours', 'HQ has been paused for over an hour (' || s.pause_reason || '). Nothing is being worked on.');
  end if;
  -- 3) engine heartbeat stale (engine or deployment is down)
  if s.last_heartbeat is null or s.last_heartbeat < now() - interval '30 minutes' then
    n := n + public._queue_alert('heartbeat', interval '6 hours', 'The HQ engine heartbeat is stale (over 30 minutes). Check the Railway deployment.');
  end if;
  -- 4) repeated failed AI calls (only when not already explained by a credit pause)
  select count(*) into c from llm_calls where status = 'failed' and started_at > now() - interval '1 hour';
  if c >= 5 and s.pause_reason is distinct from 'api_credits' then
    n := n + public._queue_alert('failed_calls', interval '3 hours', c || ' AI calls failed in the last hour. Check the provider status and the key.');
  end if;
  -- 5) cancellation spike
  select count(*) into c from tasks where status = 'cancelled' and updated_at > now() - interval '1 hour';
  if c >= 10 then
    n := n + public._queue_alert('cancel_spike', interval '6 hours', c || ' tasks were cancelled in the last hour. See audit_log bulk_task_status_change for who and why.');
  end if;
  -- 6) missions stuck
  select count(*) into c from missions where status in ('captured','evaluated','planned','executing','verifying')
    and coalesce(last_progress_at, updated_at) < now() - interval '24 hours';
  if c > 0 and s.pause_reason is null then
    n := n + public._queue_alert('mission_stall', interval '12 hours', c || ' mission(s) have made no progress for over 24 hours.');
  end if;
  -- 7) an agent failing repeatedly
  for a in select assigned_agent ag, count(*) k from tasks where status = 'blocked' and updated_at > now() - interval '24 hours'
           group by 1 having count(*) >= 3 loop
    n := n + public._queue_alert('agent_fail:' || a.ag, interval '24 hours', 'Agent ' || a.ag || ' has ' || a.k || ' blocked tasks in the last 24 hours.');
  end loop;
  -- 8) budget reservation never settled
  select count(*) into c from llm_calls where status = 'reserved' and started_at < now() - interval '30 minutes';
  if c > 0 then
    n := n + public._queue_alert('unsettled_budget', interval '12 hours', c || ' AI budget reservation(s) were never settled (older than 30 minutes). Spend accounting may be off.');
  end if;
  -- 8b) focus mode left on: it halts all other AI work, so a stale one must not go unnoticed
  if s.focus_mission is not null then
    if not exists (select 1 from missions where id = s.focus_mission and status in ('captured','evaluated','planned','executing','verifying')) then
      n := n + public._queue_alert('focus_finished', interval '12 hours',
        'Focus mode is still ON but its mission is no longer running. All other AI work is held. Send /mission focus off to resume normal work.');
    elsif exists (select 1 from missions where id = s.focus_mission and created_at < now() - interval '24 hours') then
      n := n + public._queue_alert('focus_long', interval '24 hours', 'Focus mode has been on for over 24 hours. Everything except that mission is held.');
    end if;
  end if;
  -- 9) security anomaly: the guard blocked things repeatedly
  select count(*) into c from audit_log where at > now() - interval '1 hour' and action in ('permission_denied', 'policy_denied', 'auth_failed');
  if c >= 5 then
    n := n + public._queue_alert('security', interval '3 hours', c || ' permission or authentication denials in the last hour. Review the audit log.');
  end if;
  return n;
end $$;

create or replace function public._queue_alert(p_key text, p_cooldown interval, p_body text) returns int
language plpgsql security definer set search_path to 'public' as $$
begin
  if exists (select 1 from alert_state where key = p_key and last_sent > now() - p_cooldown) then return 0; end if;
  insert into owner_messages (from_agent, kind, channel, body) values ('jarvis', 'health', 'telegram', 'ALERT: ' || p_body);
  insert into alert_state (key, last_sent) values (p_key, now()) on conflict (key) do update set last_sent = now();
  return 1;
end $$;

do $$ begin
  if exists (select 1 from pg_namespace where nspname = 'cron') then
    perform cron.unschedule(jobid) from cron.job where jobname = 'hq-ops-alerts';
    perform cron.schedule('hq-ops-alerts', '*/10 * * * *', 'select public.ops_alerts()');
  end if;
end $$;

-- ---------- 5) reconciliation: live-only objects captured as code ----------
create or replace function public.enforce_build_rules() returns trigger language plpgsql set search_path to 'public' as $$
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
do $$ begin
  if to_regclass('public.build_requests') is not null then
    drop trigger if exists build_rules on public.build_requests;
    create trigger build_rules before insert or update on public.build_requests for each row execute function public.enforce_build_rules();
  end if;
end $$;

-- Nothing here is callable by the public API; the bot and cron use the service role.
revoke all on function public.queue_outreach_drafts(), public.queue_valuation_task(), public.ops_alerts(),
  public._queue_alert(text, interval, text), public.audit_task_bulk_update(), public.audit_task_bulk_delete(),
  public.enforce_build_rules() from public, anon, authenticated;
grant execute on function public.queue_outreach_drafts(), public.queue_valuation_task(), public.ops_alerts(),
  public._queue_alert(text, interval, text) to service_role;
