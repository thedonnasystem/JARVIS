-- READ-ONLY pre-flight for the Phase 1 migrations. Changes nothing (temp table only). Run immediately before gate 3 and again right after.
-- Each row states what the Nov 12 2026 audit saw on production and what it means. Any difference => stop and re-review.
create temp table t(k text, v text);
-- A) Would a unique index fail on live data?  expect: none
insert into t select 'outbox_dup_drafts_per_lead', coalesce(string_agg(lead_id::text||'x'||n, ','), 'none')
  from (select lead_id, count(*) n from public.outbox where lead_id is not null and status='draft' group by 1 having count(*)>1) d;
-- B) Anything the migrations create already exists?  expect (before): none for both. After gate 3 these are populated by design.
insert into t select 'cols_present', coalesce(string_agg(table_name||'.'||column_name, ','), 'none') from information_schema.columns
  where table_schema='public' and ((table_name='system_state' and column_name='focus_mission') or (table_name='tasks' and column_name in ('dedupe_key','mission_role')) or (table_name='missions' and column_name in ('max_steps','strict_steps')));
insert into t select 'objects_present', coalesce(string_agg(n, ','), 'none') from (
  select relname::text n from pg_class where relnamespace='public'::regnamespace and relname in ('integration_status','alert_state','tasks_open_dedupe_key','outbox_one_draft_per_lead')
  union all select proname::text from pg_proc where pronamespace='public'::regnamespace and proname in ('ops_alerts','_queue_alert','audit_task_bulk_update','audit_task_bulk_delete','mission_guard','set_focus_mission','enforce_mission_plan_limit','enforce_mission_step_limit')
  union all select tgname::text from pg_trigger where not tgisinternal and tgname in ('audit_task_bulk_update','audit_task_bulk_delete','missions_plan_limit','tasks_mission_step_limit')) z;
-- C) Triggers already on the tables we add triggers to.  expect (before): build_requests:build_rules, missions:missions_lifecycle (nothing on tasks / system_state)
insert into t select 'existing_triggers', string_agg(c.relname||':'||g.tgname, ', ' order by c.relname, g.tgname) from pg_trigger g join pg_class c on c.oid=g.tgrelid
  where not g.tgisinternal and c.relnamespace='public'::regnamespace and c.relname in ('tasks','missions','system_state','build_requests');
-- D) The four functions that get replaced or captured must still be the Nov 12 baseline.  expect md5s from ops/live_functions_baseline_20261112.txt
insert into t select 'replaced_fn_md5', string_agg(p.oid::regprocedure::text||' '||md5(pg_get_functiondef(p.oid)), E'\n' order by p.oid::regprocedure::text)
  from pg_proc p where p.pronamespace='public'::regnamespace and p.proname in ('queue_outreach_drafts','queue_valuation_task','reserve_llm_budget','enforce_build_rules');
-- E) What lockdown_v1 would change on live.  expect: none / none (it is a no-op on current privileges)
insert into t select 'lockdown_would_revoke', coalesce(string_agg(p.proname, ','), 'none') from pg_proc p where p.pronamespace='public'::regnamespace and p.prokind='f'
  and p.proname not in ('is_app_owner','app_snapshot','app_messages','app_send','app_set_kill','app_set_agent','app_venture','app_venture_extras','app_office','app_payments','app_push_public_key','app_save_push','setter_apply')
  and (has_function_privilege('anon',p.oid,'execute') or has_function_privilege('authenticated',p.oid,'execute')
       or exists (select 1 from aclexplode(coalesce(p.proacl, acldefault('f',p.proowner))) a where a.grantee=0 and a.privilege_type='EXECUTE'));
insert into t select 'lockdown_would_grant_service_role', coalesce(string_agg(p.proname, ','), 'none') from pg_proc p where p.pronamespace='public'::regnamespace and p.prokind='f' and not has_function_privilege('service_role',p.oid,'execute');
-- F) The 13 functions lockdown deliberately leaves open must exist and keep their access.  expect: 12 app_*/is_app_owner = anon false, authenticated true; setter_apply = both true
insert into t select 'allowlist_13_state', string_agg(a.n||': exists='||(p.oid is not null)||' anon='||coalesce(has_function_privilege('anon',p.oid,'execute')::text,'-')||' auth='||coalesce(has_function_privilege('authenticated',p.oid,'execute')::text,'-'), E'\n')
  from unnest(array['is_app_owner','app_snapshot','app_messages','app_send','app_set_kill','app_set_agent','app_venture','app_venture_extras','app_office','app_payments','app_push_public_key','app_save_push','setter_apply']) a(n)
  left join pg_proc p on p.pronamespace='public'::regnamespace and p.proname=a.n;
-- G) Policies and table grants (lockdown touches neither).  expect: policy_count = none (RLS on, no policies = deny for anon/authenticated); grants only postgres + service_role
insert into t select 'policy_count_by_table', coalesce(string_agg(tablename||'='||n, ',' order by tablename),'none') from (select tablename, count(*) n from pg_policies where schemaname='public' group by 1) q;
insert into t select 'table_grants_summary', coalesce((select string_agg(grantee||':'||n, ',') from (select grantee, count(*) n from information_schema.role_table_grants where table_schema='public' group by 1) g), 'none');
-- H) The six independent spend/send controls, as they stand.  expect: dry_run / kill false / cap 330 / capital_mode normal / pause api_credits
insert into t select 'controls', 'mode='||mode||' kill='||kill_switch||' global_cap_cents='||daily_spend_cap_cents||' pause='||coalesce(pause_reason,'none')||' capital_mode='||public.capital_mode()||' sent_ever='||(select count(*) from public.outbox where status='sent')
  from public.system_state where id=1;
insert into t select 'counts', (select count(*) from public.tasks)||' tasks / '||(select count(*) from public.missions)||' missions / '||(select count(*) from public.outbox where status='draft')||' drafts';
select * from t order by k;
