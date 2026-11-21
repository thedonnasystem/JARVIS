-- Rollback of migrations/20261130_security_hardening_v1.sql (FENDEZY GROUP Phase 1, M4 "Audit and security hardening"). Idempotent. Run from the repo root:
--   psql -v ON_ERROR_STOP=1 -f ops/rollback_security_hardening.sql          (one transaction: it opens and commits its own)
-- (the sqltests set fz_in_txn and run it INSIDE their own rolled-back transaction.)
-- Order: FIRST of the Phase 1 rollbacks (before ops/rollback_approvals_kernel.sql and ops/rollback_office_money.sql: it uses M2's owner check).
-- 0. keeps the record: the chain head, the verify result and the alert / baseline / token counts go into ONE audit_log row; unschedules the watch job;
-- 1. ARCHIVES the seven tables (rows intact) into schema fz_archive (no API privileges; an older archive moves on to fz_archive_<timestamp>); removes their registry rows;
-- 2. drops the M4 functions; restores backup_classification() INLINE to the exact 20261128_office_money_v1 text.
-- Deletes no history. audit_log was never touched by M4.
\if :{?fz_in_txn}
\else
begin;
\endif
do $$
declare t text; tr record; v_suffix text := to_char(clock_timestamp(), 'YYYYMMDDHH24MISSUS');
begin
  if to_regclass('public.fz_audit_chain') is not null then
    insert into public.audit_log (actor, action, target, detail)
      select 'rollback', 'security_hardening_export', 'fz_audit_chain', jsonb_build_object(
        'chain_rows', (select count(*) from public.fz_audit_chain), 'head', (select to_jsonb(c) from public.fz_audit_chain c order by seq desc limit 1),
        'verify', case when to_regprocedure('public.fz_audit_verify(boolean)') is not null then public.fz_audit_verify(true) end,
        'alerts', (select count(*) from public.fz_security_alerts), 'baseline', (select count(*) from public.fz_security_baseline), 'tokens', (select count(*) from public.fz_token_registry));
  end if;
  if exists (select 1 from pg_namespace where nspname = 'cron') then
    perform cron.unschedule(jobid) from cron.job where jobname = 'fz-security-watch';
  end if;
  create schema if not exists fz_archive;
  revoke all on schema fz_archive from public;
  execute 'revoke all on schema fz_archive from anon, authenticated, service_role';
  foreach t in array array['fz_audit_chain', 'fz_audit_pending', 'fz_audit_state', 'fz_security_baseline', 'fz_security_fingerprints', 'fz_security_alerts', 'fz_token_registry'] loop
    continue when to_regclass('public.' || t) is null;
    for tr in select tgname from pg_trigger where tgrelid = ('public.' || t)::regclass and not tgisinternal loop
      execute format('drop trigger %I on public.%I', tr.tgname, t);
    end loop;
    execute format('revoke all on public.%I from public, anon, authenticated, service_role', t);
    if exists (select 1 from pg_roles where rolname = 'fz_jarvis') then execute format('revoke all on public.%I from fz_jarvis, fz_office_agent, fz_auditor', t); end if;
    if to_regclass('fz_archive.' || t) is not null then
      execute format('create schema if not exists %I', 'fz_archive_' || v_suffix);
      execute format('revoke all on schema %I from public, anon, authenticated, service_role', 'fz_archive_' || v_suffix);
      execute format('alter table fz_archive.%I set schema %I', t, 'fz_archive_' || v_suffix);
    end if;
    execute format('alter table public.%I set schema fz_archive', t);
  end loop;
  if to_regclass('public.fz_table_registry') is not null then
    delete from public.fz_table_registry where relname in ('fz_audit_chain', 'fz_audit_pending', 'fz_audit_state', 'fz_security_baseline', 'fz_security_fingerprints', 'fz_security_alerts', 'fz_token_registry');
  end if;
end $$;
drop function if exists public.fz_security_report(integer), public.fz_owner_register_token(text, text, timestamptz, text), public.fz_owner_ack_security(text),
  public.fz_security_watch(), public.fz_security_alert(text, text, jsonb, text), public.fz_privileged_items(), public.fz_expected_grants(), public.fz_audit_verify(boolean),
  public.fz_audit_verify(), public.fz_audit_chain_extend(integer), public.fz_audit_link(text, text), public.fz_audit_row_hash(bigint, timestamptz, text, text, text, jsonb);
-- 2. backup classification: the exact 20261128_office_money_v1 text
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
    ('fz_money_attribution', 'secret', 'office of each ledger row / model call / reservation; off-site export pending')
  ) v (table_name, data_class, note)
$$;
revoke all on function public.backup_classification() from public, anon, authenticated;
\if :{?fz_in_txn}
\else
commit;
\endif
