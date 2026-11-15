-- READ-ONLY post-release verification for the executor-gate + client-workspaces release. Changes nothing (only calls the immutable
-- ws_sensitive_hits() on literals; never calls executor_request, which writes). Run in the Supabase SQL editor after the migrations,
-- and again after any later deploy. Every row must read PASS. Any FAIL: STOP, report, do NOT repair protected settings automatically.
-- Rows 9-14 read live-only objects (supabase_migrations, cron, capital) through query_to_xml so the same file also runs on a scratch DB, where they read n/a.
with env as (select exists (select 1 from pg_namespace where nspname = 'supabase_migrations') as live)
select n, check_name, actual, expected,
       case when actual = expected then 'PASS' when actual = 'n/a (scratch)' then 'N/A' else 'FAIL' end as status from (
  select 1 n, 'the 8 new functions exist (3 executor + 5 workspace), nothing else named executor_%/ws_%' check_name,
    (select count(*) from pg_proc where pronamespace = 'public'::regnamespace and proname in ('executor_request','executor_complete','executor_expire_stale','ws_sensitive_hits','ws_guard','ws_add_lead','ws_record_spend','ws_summary'))::text
    || ' / ' || (select count(*) from pg_proc where pronamespace = 'public'::regnamespace and (proname like 'executor\_%' or proname like 'ws\_%'))::text actual, '8 / 8' expected
  union all select 2, 'the 6 new tables exist, RLS on for all, none FORCE (owner functions must still work), zero policies',
    (select count(*) from pg_class where relnamespace = 'public'::regnamespace and relkind = 'r' and relname in ('executor_registry','executor_runs','client_workspaces','ws_campaigns','ws_leads','ws_ledger') and relrowsecurity and not relforcerowsecurity)::text
    || ' / ' || (select count(*) from pg_policies where schemaname = 'public' and tablename in ('executor_registry','executor_runs','client_workspaces','ws_campaigns','ws_leads','ws_ledger'))::text, '6 / 0'
  union all select 3, 'anon/authenticated/PUBLIC: table grants on the 6 tables / EXECUTE on the 8 functions',
    (select count(*) from information_schema.role_table_grants where table_schema = 'public' and table_name in ('executor_registry','executor_runs','client_workspaces','ws_campaigns','ws_leads','ws_ledger') and grantee in ('anon','authenticated','PUBLIC'))::text
    || ' / ' || (select count(*) from pg_proc p where p.pronamespace = 'public'::regnamespace and p.proname in ('executor_request','executor_complete','executor_expire_stale','ws_sensitive_hits','ws_guard','ws_add_lead','ws_record_spend','ws_summary')
         and (has_function_privilege('anon', p.oid, 'execute') or has_function_privilege('authenticated', p.oid, 'execute')
              or exists (select 1 from aclexplode(coalesce(p.proacl, acldefault('f', p.proowner))) a where a.grantee = 0 and a.privilege_type = 'EXECUTE')))::text, '0 / 0'
  union all select 4, 'service_role: table privileges on the 6 tables are exactly SELECT; EXECUTE on all 8 functions',
    (select coalesce(string_agg(distinct privilege_type, ','), 'none') from information_schema.role_table_grants where table_schema = 'public' and grantee = 'service_role' and table_name in ('executor_registry','executor_runs','client_workspaces','ws_campaigns','ws_leads','ws_ledger'))
    || ' / ' || (select count(*) from pg_proc p where p.pronamespace = 'public'::regnamespace and p.proname in ('executor_request','executor_complete','executor_expire_stale','ws_sensitive_hits','ws_guard','ws_add_lead','ws_record_spend','ws_summary') and has_function_privilege('service_role', p.oid, 'execute'))::text, 'SELECT / 8'
  union all select 5, 'the 3 SECURITY DEFINER executor functions + 2 workspace writers pin search_path=public; ws_sensitive_hits/ws_guard are not definer',
    (select count(*) from pg_proc p where p.pronamespace = 'public'::regnamespace and p.proname in ('executor_request','executor_complete','executor_expire_stale','ws_add_lead','ws_record_spend','ws_summary') and p.prosecdef and p.proconfig::text like '%search_path=public%')::text
    || ' / ' || (select count(*) from pg_proc p where p.pronamespace = 'public'::regnamespace and p.proname in ('ws_sensitive_hits','ws_guard') and not p.prosecdef)::text, '6 / 2'
  union all select 6, 'ws_guard trigger is on all 4 workspace tables (before insert or update, enabled)',
    (select count(*) from pg_trigger t where not t.tgisinternal and t.tgname = 'ws_guard' and t.tgenabled = 'O' and t.tgtype & 2 = 2 and t.tgtype & 4 = 4 and t.tgtype & 16 = 16
        and t.tgrelid in ('public.client_workspaces'::regclass, 'public.ws_campaigns'::regclass, 'public.ws_leads'::regclass, 'public.ws_ledger'::regclass))::text, '4'
  union all select 7, 'inert: registry rows / enabled executors / runs / workspaces (nothing registered, nothing run, no client data)',
    (select count(*) from public.executor_registry)::text || ' / ' || (select count(*) filter (where enabled) from public.executor_registry)::text || ' / ' || (select count(*) from public.executor_runs)::text || ' / ' || (select count(*) from public.client_workspaces)::text, '0 / 0 / 0 / 0'
  union all select 8, 'sensitive-data guard behaves (pure function on literals; zero-width characters built with chr() so file encoding cannot hide a regression)',
    (select (public.ws_sensitive_hits('SIN 123 456 789') @> array['sin_like_number'])::text || '/' || (public.ws_sensitive_hits('123' || chr(8203) || '456' || chr(8205) || '789') @> array['sin_like_number'])::text
        || '/' || (public.ws_sensitive_hits('my credit score and bank statement') @> array['credit','banking'])::text || '/' || (public.ws_sensitive_hits('Looking for a 2 bedroom in Kanata') = '{}'::text[])::text), 'true/true/true/true'
  union all select 9, 'migration ledger: both new names present, lockdown_v1 is the LAST applied (live)',
    case when (select live from env) then (xpath('/row/v/text()', query_to_xml($q$select (select count(*) filter (where name in ('executor_gate_v1','client_workspaces_v1')) from supabase_migrations.schema_migrations)::text || ' / last=' || (select name from supabase_migrations.schema_migrations order by version desc limit 1) as v$q$, false, true, '')))[1]::text
         else 'n/a (scratch)' end, '2 / last=lockdown_v1'
  union all select 10, 'public function count: 123 live before + 8 = 131 (live; valid only when Sprint 1-2 was already live)',
    case when (select live from env) then (select count(*)::text from pg_proc where pronamespace = 'public'::regnamespace and prokind = 'f') else 'n/a (scratch)' end, '131'
  union all select 11, 'protected 19 functions: md5 unchanged (live)',
    case when (select live from env) then (select md5(string_agg(p.oid::regprocedure::text || ' ' || md5(pg_get_functiondef(p.oid)), '|' order by p.oid::regprocedure::text)) from pg_proc p where p.pronamespace = 'public'::regnamespace and p.prokind = 'f' and p.proname in ('authorize_action','outbox_send_policy','enforce_outbox_rules','reserve_spend','settle_spend','release_spend','reserve_llm_budget','settle_llm_call','guard_capital_policy','capital_check','capital_mode','prepare_payment','decide_payment','confirm_payment','mission_guard','enforce_mission_transition','app_set_kill','is_app_owner','estimate_call_cents'))
         else 'n/a (scratch)' end, 'a87bfafa3ead42601588b302c0b56d18'
  union all select 12, 'mode / kill / focus / daily AI cap / pause reason unchanged (live)',
    case when (select live from env) then (select mode || ' / kill=' || kill_switch || ' / focus=' || coalesce(focus_mission::text, 'off') || ' / cap=' || coalesce(daily_spend_cap_cents::text, 'null') || ' / pause=' || coalesce(pause_reason, 'none') from public.system_state where id = 1) else 'n/a (scratch)' end,
    'dry_run / kill=false / focus=off / cap=330 / pause=api_credits'
  union all select 13, 'capital framework + policy fingerprints unchanged (live)',
    case when (select live from env) then (select (select operating_fund_cents || ' / ' || min_reserve_cents || ' / ' || hard_stop_cents || ' / ' || low_cost_threshold_cents || '+' || low_cost_ai_cap_cents || ' / ' || per_transaction_limit_cents || ' / ' || weekly_limit_cents from public.capital_policy limit 1)
         || ' / ' || (select md5(string_agg(to_jsonb(p)::text, '|' order by action)) from public.action_policy p) || ' / ' || (select md5(to_jsonb(c)::text) from public.capital_policy c limit 1)) else 'n/a (scratch)' end,
    '30000 / 5000 / 2000 / 10000+100 / 2500 / 7500 / 6ef239a26c16f27d7edca4ac67411940 / 3db891d49e609b522cc8107e6caf9750'
  union all select 14, 'cron jobs and agents unchanged (live): count / fingerprint / agents count / fingerprint',
    case when (select live from env) then (xpath('/row/v/text()', query_to_xml($q$select (select count(*) from cron.job)::text || ' / ' || (select md5(string_agg(jobname||schedule||active::text, '|' order by jobname)) from cron.job) || ' / ' || (select count(*) from public.agents)::text || ' / ' || (select md5(string_agg(slug||status, '|' order by slug)) from public.agents) as v$q$, false, true, '')))[1]::text
         else 'n/a (scratch)' end, '18 / f6eb18792b4e40e83e8184e344ab20c3 / 32 / 951eebac619c42163388eddf3a623292'
  union all select 15, 'security rows (live-equivalent of verify_post_release row 4): exec leak / PUBLIC exec / service_role missing / anon+auth table grants / RLS off',
    (select coalesce(string_agg(p.proname, ','), 'none') from pg_proc p where p.pronamespace = 'public'::regnamespace and p.prokind = 'f' and (has_function_privilege('anon', p.oid, 'execute') or has_function_privilege('authenticated', p.oid, 'execute')) and p.proname not in ('is_app_owner','app_snapshot','app_messages','app_send','app_set_kill','app_set_agent','app_venture','app_venture_extras','app_office','app_payments','app_push_public_key','app_save_push','setter_apply'))
    || ' / ' || (select coalesce(string_agg(p.proname, ','), 'none') from pg_proc p where p.pronamespace = 'public'::regnamespace and p.prokind = 'f' and exists (select 1 from aclexplode(coalesce(p.proacl, acldefault('f', p.proowner))) a where a.grantee = 0 and a.privilege_type = 'EXECUTE') and p.proname not in ('is_app_owner','app_snapshot','app_messages','app_send','app_set_kill','app_set_agent','app_venture','app_venture_extras','app_office','app_payments','app_push_public_key','app_save_push','setter_apply'))
    || ' / ' || (select coalesce(string_agg(p.proname, ','), 'none') from pg_proc p where p.pronamespace = 'public'::regnamespace and p.prokind = 'f' and not has_function_privilege('service_role', p.oid, 'execute'))
    || ' / ' || (select coalesce(string_agg(distinct table_name || ':' || grantee || ':' || privilege_type, ','), 'none') from information_schema.role_table_grants where table_schema = 'public' and grantee in ('anon','authenticated'))
    || ' / ' || (select coalesce(string_agg(relname, ','), 'none') from pg_class where relnamespace = 'public'::regnamespace and relkind = 'r' and not relrowsecurity), 'none / none / none / none / none'
) c order by n;
