-- READ-ONLY. Run in the Supabase SQL editor BEFORE applying the four Sprint 1-2 migrations (and again AFTER).
-- Every row has a check, the actual value, and the expected value BEFORE and AFTER. Any mismatch on the BEFORE run means production
-- changed since this package was prepared: stop and ask for a re-review. Nothing here writes anything.
select check_name, actual, expected_before, expected_after, case when actual = expected_before then 'BEFORE-OK' when actual = expected_after then 'AFTER-OK' else 'MISMATCH' end as status
from (
  select 1 as n, 'phase 1 functions present (of 8)' as check_name,
         (select count(*) from pg_proc where pronamespace = 'public'::regnamespace and proname in ('ops_alerts','mission_guard','set_focus_mission','_queue_alert','audit_task_bulk_update','audit_task_bulk_delete','enforce_mission_step_limit','enforce_mission_plan_limit'))::text as actual, '8'::text as expected_before, '8'::text as expected_after
  union all select 2, 'sprint 1-2 functions present (of 19 names)',
         (select count(*) from pg_proc where pronamespace = 'public'::regnamespace and proname in ('backup_schema','backup_snapshot','ensure_venture_agents','queue_all_prospect_tasks','venture_kpis','lead_funnel','is_suppressed','normalize_addr','mark_do_not_contact','record_lead_reply','create_deal','set_deal_stage','confirm_deal_won','venture_config_get','set_venture_config','needs_you','app_needs_you','evidence_sources_immutable','purge_evidence_sources'))::text, '0', '19'
  union all select 3, 'queue_prospect_task(text) overload present',
         (select count(*) from pg_proc where pronamespace = 'public'::regnamespace and proname = 'queue_prospect_task' and pronargs = 1)::text, '0', '1'
  union all select 4, 'new tables present (contact_suppressions, lead_replies, venture_config, evidence_sources)',
         (select count(*) from pg_class where relnamespace = 'public'::regnamespace and relkind = 'r' and relname in ('contact_suppressions','lead_replies','venture_config','evidence_sources'))::text, '0', '4'
  union all select 5, 'new triggers present (outbox_dnc_guard, leads_dnc_cascade, leads_suppression_guard)',
         (select count(*) from pg_trigger where not tgisinternal and tgname in ('outbox_dnc_guard','leads_dnc_cascade','leads_suppression_guard'))::text, '0', '3'
  union all select 6, 'existing open deals sharing a lead (blocks the unique index; must be 0 or the index is skipped)',
         (select count(*) from (select lead_id from public.deals where lower(stage) in ('pitched','negotiating') and lead_id is not null group by lead_id having count(*) > 1) d)::text, '0', '0'
  union all select 7, 'leads rows (context)', (select count(*) from public.leads)::text, (select count(*) from public.leads)::text, (select count(*) from public.leads)::text
  union all select 8, 'any anon/authenticated-executable function among the new names (must stay 0)',
         (select count(*) from pg_proc p where p.pronamespace = 'public'::regnamespace and p.proname in ('backup_schema','backup_snapshot','ensure_venture_agents','queue_all_prospect_tasks','venture_kpis','lead_funnel','is_suppressed','normalize_addr','mark_do_not_contact','record_lead_reply','create_deal','set_deal_stage','confirm_deal_won','venture_config_get','set_venture_config','needs_you','app_needs_you','evidence_sources_immutable','purge_evidence_sources')
            and (has_function_privilege('anon', p.oid, 'execute') or has_function_privilege('authenticated', p.oid, 'execute')))::text, '0', '0'
  union all select 9, 'system mode / kill switch / pause (must be unchanged by this release)',
         (select mode || ' / kill=' || kill_switch::text from public.system_state where id = 1), 'dry_run / kill=false', 'dry_run / kill=false'
) c order by n;
