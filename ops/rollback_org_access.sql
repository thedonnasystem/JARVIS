-- Rollback of migrations/20261127_org_access_v1.sql (FENDEZY GROUP Phase 1, M1 "Org & Access core"). Idempotent. Run from the repo root (psql -f ops/rollback_org_access.sql).
-- What it does, in order:
--   1. un-archives: every agent / department the re-seed archived gets its PRIOR status back (only if nobody changed it since) and its archived_at stamp cleared;
--   2. removes the scoped-role policies, grants and the tasks stamp trigger; RLS goes back OFF only on the tables this migration switched it on for (marked by its
--      fz_service_all policy; on Supabase those tables already had RLS on, so nothing changes there);
--   3. drops the office_id / archived_at columns, the fz_* functions and tables, and the three roles;
--   4. restores backup_classification() INLINE to the exact 20261124_jarvis_hands_v1 text, then re-runs the post-lockdown files (search_path and grants).
-- DESTRUCTIVE only for what M1 added: office assignments (office_id), the identity registry, office rules and the re-seed log. While every office is dormant that is nothing
-- the owner entered. If offices are already in use, first keep a copy:  \copy (select public.fz_org_status()) to 'org_status.json'
-- Nothing else is touched: no pre-existing row is deleted; authorize_action / action_policy were never changed by M1.
begin;
do $$
declare r record; t regclass;
begin
  -- 1. un-archive
  if to_regclass('public.fz_org_archive') is not null then
    if exists (select 1 from pg_attribute where attrelid = 'public.agents'::regclass and attname = 'archived_at' and not attisdropped) then
      for r in select * from public.fz_org_archive where decision = 'archived' and entity in ('agent', 'department', 'venture') loop
        if r.entity = 'agent' then
          execute 'update public.agents set status = $1, archived_at = null where slug = $2 and status = $3' using r.prior_status, r.key, r.new_status;
        elsif r.entity = 'department' then
          execute 'update public.departments set status = $1, archived_at = null where slug = $2 and status = $3' using r.prior_status, r.key, r.new_status;
        end if;
      end loop;
    end if;
  end if;
  -- 2. policies, RLS, grants
  for r in select c.oid::regclass t, c.relname from pg_class c where c.relnamespace = 'public'::regnamespace and c.relkind in ('r', 'p') loop
    execute format('drop policy if exists fz_scope_read on %s', r.t);
    execute format('drop policy if exists fz_scope_insert on %s', r.t);
    execute format('drop policy if exists fz_scope_update on %s', r.t);
    if exists (select 1 from pg_policy p where p.polrelid = r.t and p.polname = 'fz_service_all') then
      execute format('drop policy fz_service_all on %s', r.t);
      execute format('alter table %s disable row level security', r.t);
    end if;
  end loop;
  drop trigger if exists tasks_fz_stamp on public.tasks;
  if exists (select 1 from pg_roles where rolname = 'fz_jarvis') then
    revoke all on all tables in schema public from fz_jarvis, fz_office_agent, fz_auditor;
    revoke all on all sequences in schema public from fz_jarvis, fz_office_agent, fz_auditor;
    revoke all on all functions in schema public from fz_jarvis, fz_office_agent, fz_auditor;
    revoke all on schema public from fz_jarvis, fz_office_agent, fz_auditor;
  end if;
end $$;
-- 3. columns, functions, tables (the roles are dropped at the end; roles are cluster-wide, so a role still used by ANOTHER database on the same server is kept with no privilege here)
drop index if exists public.agents_office_id, public.departments_office_id, public.ventures_office_id, public.missions_office_id, public.tasks_office_id, public.memory_office_id;
alter table public.agents drop column if exists office_id, drop column if exists archived_at;
alter table public.departments drop column if exists office_id, drop column if exists archived_at;
alter table public.ventures drop column if exists office_id, drop column if exists archived_at;
alter table public.missions drop column if exists office_id;
alter table public.tasks drop column if exists office_id;
alter table public.memory drop column if exists office_id;
drop function if exists public.fz_authorize_action(text, integer, text, text, text, uuid, uuid, jsonb), public.fz_set_office_policy(text, text, boolean, integer, integer, text),
  public.fz_owner_set_office_status(text, text), public.fz_owner_set_identity(text, text, text, boolean), public.fz_owner_set_workspace_office(uuid, text),
  public.fz_revoke_identity(text, text), public.fz_org_status(), public.fz_unregistered_tables(), public.fz_whoami(), public.fz_stamp_scoped_write(),
  public.fz_readable_workspaces(text), public.fz_writable_offices(text), public.fz_readable_offices(text), public.is_group_scope(), public.current_office_id(),
  public.current_office(), public.current_identity();
drop table if exists public.fz_office_action_policy, public.fz_workspace_offices, public.fz_org_archive, public.fz_table_registry, public.fz_identities, public.fz_offices;
drop function if exists public.fz_office_policy_guard(), public.fz_append_only(), public.fz_identity_now(), public.fz_claims();
do $$
declare r text;
begin
  foreach r in array array['fz_jarvis', 'fz_office_agent', 'fz_auditor'] loop
    continue when not exists (select 1 from pg_roles where rolname = r);
    begin
      if exists (select 1 from pg_roles where rolname = 'authenticator') then execute format('revoke %I from authenticator', r); end if;
      execute format('drop role %I', r);
    exception when others then
      raise notice 'role % kept (%): it holds no privilege in this database any more; drop it by hand where it still has one', r, sqlerrm;
    end;
  end loop;
end $$;
-- 4. backup classification: the exact 20261124_jarvis_hands_v1 text
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
    ('hand_actions', 'internal', 'action and content queue (payload free text is not exported)'), ('hand_standing', 'internal', 'owner standing approvals')
  ) v (table_name, data_class, note)
$$;
revoke all on function public.backup_classification() from public, anon, authenticated;
commit;
\i migrations/20261121_postlock_backup_identity_v1.sql
\i migrations/20261122_postlock_backup_identity_v2.sql
