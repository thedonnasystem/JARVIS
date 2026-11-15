-- READ-ONLY pre-flight for the executor-gate + client-workspaces release (migrations 20261117_executor_gate_v1, 20261117_client_workspaces_v1).
-- Run in the Supabase SQL editor IMMEDIATELY before applying. Changes nothing. Every row must read BEFORE-OK; anything else: STOP and report.
-- Rows marked (live) only evaluate on the real project (they read supabase_migrations / cron); on a scratch DB they read n/a.
with env as (select exists (select 1 from pg_namespace where nspname = 'supabase_migrations') as live)
select n, check_name, actual, expected, case when actual = expected or actual = 'n/a (scratch)' then 'BEFORE-OK' else 'FAIL' end as status from (
  select 1 n, 'none of the 6 new tables exists' check_name,
    (select count(*) from pg_class where relnamespace = 'public'::regnamespace and relname in ('executor_registry','executor_runs','client_workspaces','ws_campaigns','ws_leads','ws_ledger'))::text actual, '0' expected
  union all select 2, 'none of the 8 new functions exists (any signature)',
    (select count(*) from pg_proc where pronamespace = 'public'::regnamespace and proname in ('executor_request','executor_complete','executor_expire_stale','ws_sensitive_hits','ws_guard','ws_add_lead','ws_record_spend','ws_summary'))::text, '0'
  union all select 3, 'prerequisite columns exist with the types the migrations use (tasks.id uuid, tasks.venture_id uuid, system_state.id/kill_switch/mode/pause_reason, audit_log.actor/action/target/detail jsonb)',
    (select string_agg(table_name || '.' || column_name || ':' || data_type, ',' order by table_name, column_name) from information_schema.columns where table_schema = 'public'
       and ((table_name = 'tasks' and column_name in ('id','venture_id')) or (table_name = 'system_state' and column_name in ('id','kill_switch','mode','pause_reason'))
         or (table_name = 'audit_log' and column_name in ('actor','action','target','detail')))),
    'audit_log.action:text,audit_log.actor:text,audit_log.detail:jsonb,audit_log.target:text,system_state.id:integer,system_state.kill_switch:boolean,system_state.mode:text,system_state.pause_reason:text,tasks.id:uuid,tasks.venture_id:uuid'
  union all select 4, 'spend functions the executor calls exist with the expected signatures and return types',
    (select string_agg(p.oid::regprocedure::text || '->' || pg_get_function_result(p.oid), ',' order by p.proname) from pg_proc p where p.pronamespace = 'public'::regnamespace and p.proname in ('reserve_llm_budget','settle_llm_call')),
    'reserve_llm_budget(text,integer,text,text)->uuid,settle_llm_call(uuid,integer,text)->void'
  union all select 5, 'Sprint 1-2 is already live (mission_guard exists): executor purpose-fixing relies on it',
    (select count(*) from pg_proc where pronamespace = 'public'::regnamespace and proname = 'mission_guard')::text, '1'
  union all select 6, 'pgcrypto-free: gen_random_uuid() and normalize() available (PG13+)',
    (select (current_setting('server_version_num')::int >= 130000)::text || '/' || pg_encoding_to_char(encoding) from pg_database where datname = current_database()), 'true/UTF8'
  union all select 7, 'security: any anon/authenticated EXECUTE outside the 13 owner-checked app functions, or any anon/authenticated table grant',
    (select coalesce(string_agg(p.proname, ','), 'none') from pg_proc p where p.pronamespace = 'public'::regnamespace and p.prokind = 'f' and (has_function_privilege('anon', p.oid, 'execute') or has_function_privilege('authenticated', p.oid, 'execute'))
       and p.proname not in ('is_app_owner','app_snapshot','app_messages','app_send','app_set_kill','app_set_agent','app_venture','app_venture_extras','app_office','app_payments','app_push_public_key','app_save_push','setter_apply'))
    || ' / ' || (select coalesce(string_agg(distinct table_name || ':' || grantee, ','), 'none') from information_schema.role_table_grants where table_schema = 'public' and grantee in ('anon','authenticated')),
    'none / none'
  union all select 8, 'protected 19 functions fingerprint (live)',
    case when (select live from env) then (select md5(string_agg(p.oid::regprocedure::text || ' ' || md5(pg_get_functiondef(p.oid)), '|' order by p.oid::regprocedure::text)) from pg_proc p where p.pronamespace = 'public'::regnamespace and p.prokind = 'f' and p.proname in ('authorize_action','outbox_send_policy','enforce_outbox_rules','reserve_spend','settle_spend','release_spend','reserve_llm_budget','settle_llm_call','guard_capital_policy','capital_check','capital_mode','prepare_payment','decide_payment','confirm_payment','mission_guard','enforce_mission_transition','app_set_kill','is_app_owner','estimate_call_cents'))
         else 'n/a (scratch)' end, 'a87bfafa3ead42601588b302c0b56d18'
  union all select 9, 'public function count (live: 123 after Sprint 1-2)',
    case when (select live from env) then (select count(*)::text from pg_proc where pronamespace = 'public'::regnamespace and prokind = 'f') else 'n/a (scratch)' end, '123'
  union all select 10, 'ledger ends with lockdown_v1 and the two new names are not there yet (live)',
    case when (select live from env) then (xpath('/row/v/text()', query_to_xml($q$select (select name from supabase_migrations.schema_migrations order by version desc limit 1) || ' / ' || (select count(*) filter (where name in ('executor_gate_v1','client_workspaces_v1')) from supabase_migrations.schema_migrations) as v$q$, false, true, '')))[1]::text else 'n/a (scratch)' end, 'lockdown_v1 / 0'
  union all select 11, 'mode / kill / focus / cap / pause (live; this release must not change any)',
    (select mode || ' / kill=' || kill_switch || ' / focus=' || coalesce(focus_mission::text, 'off') || ' / cap=' || coalesce(daily_spend_cap_cents::text, 'null') || ' / pause=' || coalesce(pause_reason, 'none') from public.system_state where id = 1),
    'dry_run / kill=false / focus=off / cap=330 / pause=api_credits'
  union all select 12, 'no reserved/running AI spend in flight (nothing half-settled before schema work)',
    (select count(*) from public.llm_calls where status = 'reserved' and started_at > now() - interval '10 minutes')::text, '0'
) c order by n;
