-- READ-ONLY production verification. Safe to run any time; changes nothing. Run before and after a deployment.
-- 1) Security: every row must be 'none' (exec_leak / public_exec / service_missing / table_grants / rls_off).
-- 2) Drift: compare function_md5 to ops/live_functions_baseline_20261112.txt. Expected differences after the Phase 1 deploy:
--    queue_outreach_drafts, queue_valuation_task, reserve_llm_budget (changed), plus NEW functions listed in ops/EXPECTED_NEW_FUNCTIONS.txt.
create temp table v(k text, v text);
insert into v select 'exec_leak', coalesce(string_agg(p.proname, ','), 'none') from pg_proc p where p.pronamespace = 'public'::regnamespace and p.prokind = 'f'
  and (has_function_privilege('anon', p.oid, 'execute') or has_function_privilege('authenticated', p.oid, 'execute'))
  and p.proname not in ('is_app_owner','app_snapshot','app_messages','app_send','app_set_kill','app_set_agent','app_venture','app_venture_extras','app_office','app_payments','app_push_public_key','app_save_push','setter_apply');
insert into v select 'public_exec', coalesce(string_agg(p.proname, ','), 'none') from pg_proc p where p.pronamespace = 'public'::regnamespace and p.prokind = 'f'
  and exists (select 1 from aclexplode(coalesce(p.proacl, acldefault('f', p.proowner))) a where a.grantee = 0 and a.privilege_type = 'EXECUTE')
  and p.proname not in ('is_app_owner','app_snapshot','app_messages','app_send','app_set_kill','app_set_agent','app_venture','app_venture_extras','app_office','app_payments','app_push_public_key','app_save_push','setter_apply');
insert into v select 'service_missing', coalesce(string_agg(p.proname, ','), 'none') from pg_proc p where p.pronamespace = 'public'::regnamespace and p.prokind = 'f' and not has_function_privilege('service_role', p.oid, 'execute');
insert into v select 'table_grants_anon_auth', coalesce(string_agg(distinct table_name || ':' || grantee || ':' || privilege_type, ','), 'none') from information_schema.role_table_grants where table_schema = 'public' and grantee in ('anon', 'authenticated');
insert into v select 'rls_off', coalesce(string_agg(relname, ','), 'none') from pg_class where relnamespace = 'public'::regnamespace and relkind = 'r' and not relrowsecurity;
insert into v select 'mode_and_pause', mode || ' / pause=' || coalesce(pause_reason, 'none') || ' / kill=' || kill_switch || ' / focus=' || coalesce(to_jsonb(system_state)->>'focus_mission', 'off') from system_state where id = 1;
insert into v select 'integrations', coalesce(string_agg(key || '=' || ok || ' (' || coalesce(detail,'') || ') checked ' || checked_at, E'\n' order by key), 'integration_status not migrated yet') from (select 1) x left join public.integration_status on true;
insert into v select 'function_md5', string_agg(p.oid::regprocedure::text || ' ' || md5(pg_get_functiondef(p.oid)), E'\n' order by p.oid::regprocedure::text) from pg_proc p where p.pronamespace = 'public'::regnamespace and p.prokind = 'f';
select * from v order by k;
