-- Rollback of migrations/20261202_monitoring_brain_v1.sql (FENDEZY GROUP Phase 1, M6 "Monitoring + shared brain"). Idempotent. Run from the repo root:
--   psql -v ON_ERROR_STOP=1 -f ops/rollback_monitoring_brain.sql          (one transaction: it opens and commits its own)
-- (the sqltests set fz_in_txn and run it INSIDE their own rolled-back transaction.)
-- Order: FIRST of the Phase 1 rollbacks (before ops/rollback_shared_services.sql).
-- 0. keeps the record (counts) in ONE audit_log row; unschedules the health check;
-- 1. restores the M3 fz_approval_queue view exactly (the brain branch goes; the M3 decision paths were never changed);
-- 2. ARCHIVES the six tables (rows intact) into schema fz_archive (no API privileges; an older archive moves to fz_archive_<timestamp>); removes their registry rows;
-- 3. drops the M6 functions; restores backup_classification() INLINE to the exact 20261201_shared_services_v1 text.
-- Deletes no history.
\if :{?fz_in_txn}
\else
begin;
\endif
-- 1. the M3 queue, exactly (it must not reference fz_brain_promotions once that table is archived)
do $m3$
begin
  -- only while the M6 view is in place (a later rollback of M3 / M2 may already have removed the queue or its tables)
  if to_regclass('public.fz_approval_queue') is not null and pg_get_viewdef(to_regclass('public.fz_approval_queue')) like '%fz_brain_promotions%' then
    execute $v$create or replace view public.fz_approval_queue with (security_barrier = true) as
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
)
select q.request_type, q.source_id, q.office_id, o.slug as office, q.requester, q.action, q.amount_cents, q.risk, q.status, q.created_at, q.expires_at, q.decided_at,
       q.decided_by_path
  from q
  left join public.fz_offices o on o.id = q.office_id
 where coalesce(nullif(current_setting('role', true), ''), 'none') in ('none', 'postgres', 'service_role')      -- review fix 7: an allowlist of who sees everything
    or (coalesce(nullif(current_setting('role', true), ''), 'none') in ('fz_jarvis', 'fz_office_agent', 'fz_auditor')
        and ((select public.is_group_scope()) or q.office_id = (select public.current_office_id())));   -- scoped: own office (group scope: all); anyone else: nothing

revoke all on public.fz_approval_queue from public, anon, authenticated, service_role, fz_jarvis, fz_office_agent, fz_auditor;
grant select on public.fz_approval_queue to service_role, fz_jarvis, fz_office_agent, fz_auditor;$v$;
  end if;
end $m3$;
do $$
declare t text; tr record; v_suffix text := to_char(clock_timestamp(), 'YYYYMMDDHH24MISSUS'); c record;
begin
  if to_regclass('public.fz_brain_facts') is not null then
    insert into public.audit_log (actor, action, target, detail) values ('rollback', 'monitoring_brain_export', 'fz_brain_facts', jsonb_build_object(
      'facts', (select count(*) from public.fz_brain_facts), 'promotions', (select count(*) from public.fz_brain_promotions),
      'health_alerts', (select count(*) from public.fz_health_alerts), 'alerts_enabled', (select alerts_enabled from public.fz_health_config where id = 1)));
  end if;
  if exists (select 1 from pg_namespace where nspname = 'cron') then
    perform cron.unschedule(jobid) from cron.job where jobname = 'fz-health-check';
  end if;
  create schema if not exists fz_archive;
  revoke all on schema fz_archive from public;
  execute 'revoke all on schema fz_archive from anon, authenticated, service_role';
  foreach t in array array['fz_health_config', 'fz_health_state', 'fz_health_alerts', 'fz_brain_config', 'fz_brain_facts', 'fz_brain_promotions'] loop
    continue when to_regclass('public.' || t) is null;
    for tr in select tgname from pg_trigger where tgrelid = ('public.' || t)::regclass and not tgisinternal loop
      execute format('drop trigger %I on public.%I', tr.tgname, t);
    end loop;
    execute format('revoke all on public.%I from public, anon, authenticated, service_role', t);
    if exists (select 1 from pg_roles where rolname = 'fz_jarvis') then execute format('revoke all on public.%I from fz_jarvis, fz_office_agent, fz_auditor', t); end if;
    -- foreign keys to tables that stay in public (fz_offices) would tie the archive to them: drop those constraints (the self-references move with the table)
    for c in select conname from pg_constraint where conrelid = ('public.' || t)::regclass and contype = 'f' and confrelid = 'public.fz_offices'::regclass loop
      execute format('alter table public.%I drop constraint %I', t, c.conname);
    end loop;
    if to_regclass('fz_archive.' || t) is not null then
      execute format('create schema if not exists %I', 'fz_archive_' || v_suffix);
      execute format('revoke all on schema %I from public, anon, authenticated, service_role', 'fz_archive_' || v_suffix);
      execute format('alter table fz_archive.%I set schema %I', t, 'fz_archive_' || v_suffix);
    end if;
  end loop;
  -- promotions reference facts: move them together (facts last is fine: a schema move keeps the constraint)
  foreach t in array array['fz_health_config', 'fz_health_state', 'fz_health_alerts', 'fz_brain_config', 'fz_brain_facts', 'fz_brain_promotions'] loop
    continue when to_regclass('public.' || t) is null;
    execute format('alter table public.%I set schema fz_archive', t);
  end loop;
  if to_regclass('public.fz_table_registry') is not null then
    delete from public.fz_table_registry where relname = any (array['fz_health_config', 'fz_health_state', 'fz_health_alerts', 'fz_brain_config', 'fz_brain_facts', 'fz_brain_promotions']);
  end if;
end $$;
-- the M5 office stamp, exactly (M6 tightened its caller-given-office rule; it must not depend on fz_m6_owner_session once that is dropped)
do $m5$ begin if to_regprocedure('public.fz_service_stamp_office()') is not null then execute $f$create or replace function public.fz_service_stamp_office() returns trigger
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
  if v is null and tg_op = 'INSERT' and (j ->> 'office_id') is not null then         -- a caller-given office, only if it is a real office
    select o.id into v from public.fz_offices o where o.id = (j ->> 'office_id')::uuid;
  end if;
  new.office_id := coalesce(v, (select o.id from public.fz_offices o where o.slug = 'group'));
  return new;
end $$;$f$; end if; end $m5$;
drop function if exists public.fz_brain_report(text), public.fz_owner_set_brain_jarvis_approval(boolean), public.fz_jarvis_decide_brain_promotion(uuid, boolean),
  public.fz_owner_decide_brain_promotion(uuid, boolean), public.fz_brain_decide(uuid, boolean, text), public.fz_brain_propose_promotion(uuid, text),
  public.fz_brain_add(text, text, text, numeric, jsonb, uuid, text, text), public.fz_brain_read(text, integer), public.fz_brain_caller_office(),
  public.fz_brain_redact_pending(), public.fz_brain_clean_provenance(jsonb), public.fz_brain_redact(text, integer),
  public.fz_owner_set_health_alerts(boolean), public.fz_health_check(), public.fz_health_report(), public.fz_brain_promotions_guard(), public.fz_brain_facts_guard(),
  public.fz_m6_config_guard(), public.fz_m6_owner_session();
-- 3. backup classification: the exact 20261201_shared_services_v1 text
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
    ('fz_services', 'secret', 'shared services registry and the owner scoped-read decisions; re-seeded by the migration')
  ) v (table_name, data_class, note)
$$;
revoke all on function public.backup_classification() from public, anon, authenticated;
\if :{?fz_in_txn}
\else
commit;
\endif
