-- Rollback for 20261117_executor_gate_v1 and 20261117_client_workspaces_v1. Removes ONLY their objects; idempotent.
-- Run only if the tables are empty or you accept losing their rows (executor_runs history, workspace data). Back up first (backup_snapshot).
-- Then delete both lines from migrations/APPLY_ORDER.txt and rebuild dist/APPLY_ALL.sql, or the next apply recreates them.
drop function if exists public.executor_request(text, text, uuid, integer, text);
drop function if exists public.executor_complete(uuid, integer, text, text);
drop function if exists public.executor_expire_stale(integer);
drop table if exists public.executor_runs;
drop table if exists public.executor_registry;
drop function if exists public.ws_add_lead(uuid, uuid, text, text, text, text, text);
drop function if exists public.ws_record_spend(uuid, uuid, integer, text);
drop function if exists public.ws_summary(uuid);
drop table if exists public.ws_ledger;
drop table if exists public.ws_leads;
drop table if exists public.ws_campaigns;
drop table if exists public.client_workspaces;
drop function if exists public.ws_guard();
drop function if exists public.ws_sensitive_hits(text);
