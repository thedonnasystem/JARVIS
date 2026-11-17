-- Rollback of migrations/20261123_jarvis_core_v1.sql (Jarvis core v2). Idempotent. Run from the repo root.
-- DESTRUCTIVE for the Jarvis core tables only (queue, events, stats, cache, changelog, call log, large-tier approvals): export them first if they hold anything you want
-- (e.g. \copy public.jarvis_changelog to 'jarvis_changelog.csv' csv header). Owner-seeded memory rows (kind 'owner_profile') are KEPT; delete them by hand only if wanted.
-- The previous backup_classification() is restored INLINE (exact text of 20261119_backup_exclude_client_pii_v1; re-running that whole file would also revert other PRs' functions,
-- integration rehearsal finding S2), then the post-lockdown files restore its search_path and grants.
begin;
drop function if exists public.jarvis_set_config(text, jsonb), public.jarvis_core_status(), public.jarvis_enqueue(text, text, jsonb, text, text, timestamptz, uuid, boolean, integer),
  public.jarvis_lease(text, integer, integer, text[]), public.jarvis_extend_lease(uuid, text, integer), public.jarvis_finish(uuid, text, boolean, text, integer, boolean),
  public.jarvis_automation_candidates(text[]), public.jarvis_mark_automation(text, text, text), public.jarvis_cache_get(text), public.jarvis_cache_put(text, text, text, text, integer),
  public.jarvis_changelog_add(text, text, text), public.jarvis_call_allowed(text, text, boolean), public.jarvis_call_result(text, text, jsonb),
  public.jarvis_owner_approve_large(uuid, integer), public.jarvis_use_large_approval(uuid, uuid), public.jarvis_memory_search(text, integer, text[], text), public.jarvis_seed_stage(jsonb, text), public.jarvis_seed_apply(uuid),
  public.jarvis_seed_memory(jsonb, text, text), public.jarvis_cost_meter(integer), public.jarvis_daily_report_data(date),
  public.jarvis_owner_confirm_revenue(uuid), public.jarvis_self_fund_status(), public.jarvis_wake_agent(text, uuid, text),
  public.jarvis_sleep_agent(text, text, integer, integer);
drop table if exists public.jarvis_job_events, public.jarvis_jobs, public.jarvis_task_stats, public.jarvis_result_cache, public.jarvis_changelog, public.jarvis_call_log,
  public.jarvis_large_approvals, public.jarvis_self_fund_credits, public.jarvis_agent_wakes, public.jarvis_core_config, public.jarvis_call_criteria, public.jarvis_seed_staging;
drop function if exists public.jarvis_append_only(), public.jarvis_require_owner();
-- mission budgets: the exact previous bodies (20261112_missions_v1 / 20261113_mission_guard_v1); CREATE OR REPLACE keeps their grants
create or replace function public.mission_spent_cents(p_mission uuid)
returns int language sql stable set search_path to 'public' as $$
  select coalesce(sum(coalesce(c.actual_cents, c.reserved_cents)), 0)::int
  from public.llm_calls c
  join public.tasks t on c.purpose = 'task ' || t.id::text
  where t.mission_id = p_mission and c.status in ('reserved','done');
$$;
create or replace function public.mission_guard(p_agent text, p_purpose text, p_est_cents integer) returns void
language plpgsql stable set search_path to 'public' as $$
declare v_focus uuid; v_mission uuid; v_budget int; v_spent int;
begin
  select focus_mission into v_focus from public.system_state where id = 1;
  if p_purpose ~ '^task [0-9a-fA-F-]{36}$' then
    select mission_id into v_mission from public.tasks where id = substr(p_purpose, 6)::uuid;
  end if;
  -- The owner talking to Jarvis (chat) is never backlog and is not a mission task; it stays metered by the normal daily caps.
  -- Two narrow exemptions from focus mode, both tiny and both needed to keep control: owner chat (not backlog), and the
  -- 1-cent hourly credit probe (without it a paused engine could never notice that credit is back while focus is on).
  if v_focus is not null and v_mission is distinct from v_focus
     and not (p_agent = 'jarvis-chat' and p_purpose !~ '^task ')
     and not (p_agent = 'jarvis' and p_purpose = 'credit probe') then
    raise exception 'Focus mode: only mission % may use AI right now.', left(v_focus::text, 8);
  end if;
  if v_mission is not null then
    select budget_cents into v_budget from public.missions where id = v_mission;
    v_spent := public.mission_spent_cents(v_mission);
    if v_spent + coalesce(p_est_cents, 0) > coalesce(v_budget, 0) then
      raise exception 'Mission budget would be exceeded (% of % cents used).', v_spent, coalesce(v_budget, 0);
    end if;
  end if;
end $$;
drop index if exists public.memory_fts_simple_idx;
-- the agent row stays if it has spend history (llm_calls references it); otherwise it is removed
delete from public.agents a where a.slug = 'jarvis-core' and not exists (select 1 from public.llm_calls c where c.agent_slug = a.slug);
commit;
-- memory kind: kept permissive while owner_profile rows exist; restored exactly when none do
do $$ begin
  if not exists (select 1 from public.memory where kind = 'owner_profile') then
    alter table public.memory drop constraint if exists memory_kind_check;
    alter table public.memory add constraint memory_kind_check check (kind = any (array['lesson', 'decision', 'outcome', 'fact']));
  end if;
end $$;
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
    ('web_messages', 'internal', 'owner chat (free text)')
  ) v (table_name, data_class, note)
$$;
revoke all on function public.backup_classification() from public, anon, authenticated;
\i migrations/20261121_postlock_backup_identity_v1.sql
\i migrations/20261122_postlock_backup_identity_v2.sql
