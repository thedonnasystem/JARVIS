-- Rollback for 20261118_ffm_onboarding_v1 ONLY. Removes its views, functions and tables; idempotent. Does not touch client_workspaces, ws_* or the executor objects
-- (use ops/rollback_executor_ffm.sql for those, AFTER this file). Run only if the ffm_* tables are empty or you accept losing their rows; back up first (backup_snapshot).
-- Then delete 20261118_ffm_onboarding_v1.sql from migrations/APPLY_ORDER.txt and rebuild dist/APPLY_ALL.sql, or the next apply recreates it.
drop view if exists public.ffm_funnel_v;
drop view if exists public.ffm_spend_v;
drop table if exists public.ffm_route_log;
drop table if exists public.ffm_approvals;
drop table if exists public.ffm_routing_rules;
drop table if exists public.ffm_creatives;
drop table if exists public.ffm_ad_sets;
drop table if exists public.ffm_onboarding_items;
drop table if exists public.ffm_onboarding_templates;
drop function if exists public.ffm_guard();
drop function if exists public.ffm_require_owner();
drop function if exists public.ffm_open_ws(uuid);
drop function if exists public.ffm_instantiate_onboarding(uuid);
drop function if exists public.ffm_provide_input(uuid, text, text, text);
drop function if exists public.ffm_block_input(uuid, text, text);
drop function if exists public.ffm_set_budget(uuid, integer);
drop function if exists public.ffm_owner_approve(uuid, text, uuid, text);
drop function if exists public.ffm_revoke_approval(uuid);
drop function if exists public.ffm_readiness(uuid);
drop function if exists public.ffm_activate(uuid);
drop function if exists public.ffm_add_campaign(uuid, text, text);
drop function if exists public.ffm_add_ad_set(uuid, uuid, text, text, integer);
drop function if exists public.ffm_add_creative(uuid, uuid, uuid, text, text, text);
drop function if exists public.ffm_set_creative_status(uuid, uuid, text);
drop function if exists public.ffm_add_routing_rule(uuid, text, text, text, text[]);
drop function if exists public.ffm_route_preview(uuid, uuid);
drop function if exists public.ffm_funnel(uuid, timestamptz, timestamptz);
drop function if exists public.ffm_lead_booked_rate(uuid, timestamptz, timestamptz);
drop function if exists public.ffm_spend_report(uuid);
drop function if exists public.ffm_weekly_report(uuid, timestamptz, timestamptz);
