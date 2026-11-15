-- Rollback for 20261117_executor_gate_v1 and 20261117_client_workspaces_v1. Removes ONLY their objects; idempotent. Touches no existing table,
-- function, policy, cap, kill switch, cron job or grant (neither migration changed any), so protected fingerprints are unaffected.
-- ORDER (code first): 1) if the schedule patch (patches/schedule_expire_stale.patch) was deployed, redeploy without it (it no-ops safely if the
-- function is gone, but do not leave it running); 2) /kill or confirm no executor is enabled; 3) run this file; 4) verify (end of file).
-- Data lost: executor_runs history, executor_registry rows, all workspace/campaign/lead/ledger rows. audit_log rows stay (append-only).
-- Run backup_snapshot first if any of those tables hold anything you want.
-- Guard: refuses while an executor run is still 'running' (its AI reservation would be orphaned). Settle first: select executor_expire_stale(5);
do $$
begin
  if to_regclass('public.executor_runs') is not null and exists (select 1 from public.executor_runs where status = 'running') then
    raise exception 'rollback refused: executor_runs has running rows. Run select public.executor_expire_stale(5); (or wait for them to finish), then retry.';
  end if;
end $$;
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
-- Ledger (live only, run separately, only after the objects are gone): delete from supabase_migrations.schema_migrations where name in ('executor_gate_v1','client_workspaces_v1');
-- Repo: delete both lines from migrations/APPLY_ORDER.txt, `scripts/build_bundle.sh`, regenerate ops/EXPECTED_NEW_FUNCTIONS.txt, or the next apply recreates them.
-- Verify: select count(*) from pg_proc where pronamespace='public'::regnamespace and proname ~ '^(executor_|ws_)';  -- 0
--         select count(*) from pg_class where relnamespace='public'::regnamespace and relname ~ '^(executor_|ws_|client_workspaces)'; -- 0
--         then re-run ops/verify_post_release.sql row 2 (function count back to the pre-release number) and the protected fingerprint row.
