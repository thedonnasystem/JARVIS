-- READ-ONLY post-release verification for the Sprint 1-2 release (Supabase SQL editor; changes nothing, no temp tables).
-- Run AFTER migrations (gate 3) and again AFTER the Railway deploy (gate 4). Expected values were captured from production on 2026-11-13
-- (see PRODUCTION_INSPECTION_20261113.md); the fingerprints prove the protected controls are byte-identical to that capture.
-- Any row with status FAIL: STOP, report it, do NOT repair protected settings automatically.
select n, check_name, actual, expected, case when actual = expected then 'PASS' else 'FAIL' end as status from (
  select 1 n, 'migration ledger: the 6 new names present, lockdown_v1 is the LAST applied' check_name,
    (select (count(*) filter (where name in ('backup_schema_v1','venture_generic_v1','venture_deals_replies_v1','inbox_needs_you_v1','audit_hardening_v1','evidence_sources_v1')))::text
        || ' / last=' || (select name from supabase_migrations.schema_migrations order by version desc limit 1)
     from supabase_migrations.schema_migrations) actual, '6 / last=lockdown_v1' expected
  union all select 2, 'public function count (99 live + 24 new)', (select count(*) from pg_proc where pronamespace='public'::regnamespace and prokind='f')::text, '123'
  union all select 3, 'new tables / new triggers / anon+authenticated EXECUTE on new functions',
    (select count(*) from pg_class where relnamespace='public'::regnamespace and relkind='r' and relname in ('contact_suppressions','lead_replies','venture_config','evidence_sources'))::text
    || ' / ' || (select count(*) from pg_trigger where not tgisinternal and tgname in ('outbox_dnc_guard','leads_dnc_cascade','leads_suppression_guard'))::text
    || ' / ' || (select count(*) from pg_proc p where p.pronamespace='public'::regnamespace and p.proname in ('backup_schema','backup_snapshot','ensure_venture_agents','queue_all_prospect_tasks','venture_kpis','lead_funnel','is_suppressed','normalize_addr','mark_do_not_contact','record_lead_reply','create_deal','set_deal_stage','confirm_deal_won','venture_config_get','set_venture_config','needs_you','app_needs_you','evidence_sources_immutable','purge_evidence_sources') and (has_function_privilege('anon',p.oid,'execute') or has_function_privilege('authenticated',p.oid,'execute')))::text,
    '4 / 3 / 0'
  union all select 4, 'security: exec_leak / public_exec / service_missing / table_grants_anon_auth / rls_off',
    (select coalesce(string_agg(p.proname, ','), 'none') from pg_proc p where p.pronamespace='public'::regnamespace and p.prokind='f' and (has_function_privilege('anon',p.oid,'execute') or has_function_privilege('authenticated',p.oid,'execute')) and p.proname not in ('is_app_owner','app_snapshot','app_messages','app_send','app_set_kill','app_set_agent','app_venture','app_venture_extras','app_office','app_payments','app_push_public_key','app_save_push','setter_apply'))
    || ' / ' || (select coalesce(string_agg(p.proname, ','), 'none') from pg_proc p where p.pronamespace='public'::regnamespace and p.prokind='f' and exists (select 1 from aclexplode(coalesce(p.proacl, acldefault('f', p.proowner))) a where a.grantee=0 and a.privilege_type='EXECUTE') and p.proname not in ('is_app_owner','app_snapshot','app_messages','app_send','app_set_kill','app_set_agent','app_venture','app_venture_extras','app_office','app_payments','app_push_public_key','app_save_push','setter_apply'))
    || ' / ' || (select coalesce(string_agg(p.proname, ','), 'none') from pg_proc p where p.pronamespace='public'::regnamespace and p.prokind='f' and not has_function_privilege('service_role', p.oid, 'execute'))
    || ' / ' || (select coalesce(string_agg(distinct table_name||':'||grantee||':'||privilege_type, ','), 'none') from information_schema.role_table_grants where table_schema='public' and grantee in ('anon','authenticated'))
    || ' / ' || (select coalesce(string_agg(relname, ','), 'none') from pg_class where relnamespace='public'::regnamespace and relkind='r' and not relrowsecurity),
    'none / none / none / none / none'
  union all select 5, 'protected function bodies unchanged vs 2026-11-13 capture (19 functions, md5 of all)',
    (select md5(string_agg(p.oid::regprocedure::text||' '||md5(pg_get_functiondef(p.oid)), '|' order by p.oid::regprocedure::text)) from pg_proc p where p.pronamespace='public'::regnamespace and p.prokind='f' and p.proname in ('authorize_action','outbox_send_policy','enforce_outbox_rules','reserve_spend','settle_spend','release_spend','reserve_llm_budget','settle_llm_call','guard_capital_policy','capital_check','capital_mode','prepare_payment','decide_payment','confirm_payment','mission_guard','enforce_mission_transition','app_set_kill','is_app_owner','estimate_call_cents')),
    'a87bfafa3ead42601588b302c0b56d18'
  union all select 6, 'mode / kill switch / focus / daily AI cap (cents) / pause reason',
    (select mode||' / kill='||kill_switch||' / focus='||coalesce(focus_mission::text,'off')||' / cap='||coalesce(daily_spend_cap_cents::text,'null')||' / pause='||coalesce(pause_reason,'none') from public.system_state where id=1),
    'dry_run / kill=false / focus=off / cap=330 / pause=api_credits'
  union all select 7, 'financial framework: fund / reserve / hard stop / low-cost threshold+cap / per-txn / weekly (cents)',
    (select operating_fund_cents||' / '||min_reserve_cents||' / '||hard_stop_cents||' / '||low_cost_threshold_cents||'+'||low_cost_ai_cap_cents||' / '||per_transaction_limit_cents||' / '||weekly_limit_cents from public.capital_policy limit 1),
    '30000 / 5000 / 2000 / 10000+100 / 2500 / 7500'
  union all select 8, 'action_policy fingerprint (default-deny table, 42 rows) and capital_policy fingerprint',
    (select md5(string_agg(to_jsonb(p)::text, '|' order by action)) from public.action_policy p) || ' / ' || (select md5(to_jsonb(c)::text) from public.capital_policy c limit 1),
    '6ef239a26c16f27d7edca4ac67411940 / 3db891d49e609b522cc8107e6caf9750'
  union all select 9, 'cron jobs (count / fingerprint) and agents (count / fingerprint) unchanged',
    (select count(*) from cron.job)||' / '||(select md5(string_agg(jobname||schedule||active::text, '|' order by jobname)) from cron.job)||' / '||(select count(*) from public.agents)||' / '||(select md5(string_agg(slug||status, '|' order by slug)) from public.agents),
    '18 / f6eb18792b4e40e83e8184e344ab20c3 / 32 / 951eebac619c42163388eddf3a623292'
  union all select 10, 'outbox sent rows / send_email allow rows / deals / missions (nothing external, nothing started)',
    (select count(*) from public.outbox where status='sent')||' / '||(select count(*) from public.action_log where action='send_email' and decision='allow')||' / '||(select count(*) from public.deals)||' / '||(select count(*) from public.missions),
    '0 / 0 / 0 / 0'
  union all select 11, 'suppression list covers every do-not-contact lead (distinct clean addresses of flagged leads missing from contact_suppressions)',
    (select count(*) from (select distinct public.normalize_addr(email) a from public.leads where do_not_contact and public.normalize_addr(email) is not null) d where not exists (select 1 from public.contact_suppressions s where s.address = d.a))::text, '0'
  union all select 12, 'Needs You inbox runs (read-only) and returns a JSON array; backup schema helper returns an object',
    (select jsonb_typeof(public.needs_you(5))||' / '||jsonb_typeof(public.backup_schema())), 'array / object'
  union all select 13, 'heartbeat is fresh (< 180 s) after the Railway deploy',
    (select (now() - last_heartbeat < interval '180 seconds')::text from public.system_state where id=1), 'true'
) c order by n;
