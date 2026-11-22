-- PROPOSAL (not a migration; needs the owner's authorization: it changes the protected audit history and money tables). Makes audit_log and ledger APPEND-ONLY.
-- Why: today service_role (the bot's key) holds INSERT, UPDATE, DELETE and TRUNCATE on both tables (checked read-only in production). The M4 hash chain makes an edit
-- EVIDENT; this makes it IMPOSSIBLE for every API role, and refused even for a database session unless the owner first disables the trigger on purpose.
-- What it changes:
--   * REVOKE UPDATE, DELETE, TRUNCATE (and REFERENCES, TRIGGER) on public.audit_log and public.ledger from service_role, anon, authenticated, the scoped roles, backup_reader.
--     INSERT and SELECT stay exactly as they are.
--   * a BEFORE UPDATE OR DELETE row trigger and a BEFORE TRUNCATE trigger on both tables that refuse.
-- Code paths affected: the application only INSERTs (see ops/proposals/AUDIT_LEDGER_APPEND_ONLY.md, "Code paths"). ONE scheduled path deleted audit_log rows: the production
-- cron job hq-prune (jobid 2) also ran "delete from public.audit_log where at < now() - interval '90 days'"; this file rewrites it (cron.alter_job) to keep only its agent_runs delete. Test: psql -f ops/proposals/test_audit_ledger_append_only.sql on a scratch replica (rolled back; deliberately not part of the gate).
-- Apply: in the Supabase SQL editor, as one transaction, in a release window. Undo: the block at the end (commented).
begin;
revoke update, delete, truncate, references, trigger on public.audit_log, public.ledger from service_role, anon, authenticated;
do $$
declare r text;
begin
  foreach r in array array['fz_jarvis', 'fz_office_agent', 'fz_auditor', 'backup_reader'] loop
    if exists (select 1 from pg_roles where rolname = r) then
      execute format('revoke update, delete, truncate, references, trigger on public.audit_log, public.ledger from %I', r);
    end if;
  end loop;
end $$;
create or replace function public.fz_append_only_record() returns trigger
language plpgsql set search_path to 'pg_catalog' as $$
begin
  raise exception '% is append-only: rows are never changed or deleted (owner proposal audit_ledger_append_only)', tg_relname using errcode = '42501';
end $$;
revoke all on function public.fz_append_only_record() from public, anon, authenticated;
drop trigger if exists audit_log_append_only on public.audit_log;
create trigger audit_log_append_only before update or delete on public.audit_log for each row execute function public.fz_append_only_record();
drop trigger if exists audit_log_no_truncate on public.audit_log;
create trigger audit_log_no_truncate before truncate on public.audit_log for each statement execute function public.fz_append_only_record();
drop trigger if exists ledger_append_only on public.ledger;
create trigger ledger_append_only before update or delete on public.ledger for each row execute function public.fz_append_only_record();
drop trigger if exists ledger_no_truncate on public.ledger;
create trigger ledger_no_truncate before truncate on public.ledger for each statement execute function public.fz_append_only_record();
-- the weekly prune job deletes audit_log history: under the lock it would fail every Sunday, and deleting audit history is exactly what this proposal forbids.
-- hq-prune (jobid 2, '0 8 * * 0') keeps ONLY its agent_runs delete. Refuses (rolls everything back) if the job is not where we expect it.
do $$
declare j record;
begin
  if not exists (select 1 from pg_namespace where nspname = 'cron') then return; end if;
  select * into j from cron.job where jobname = 'hq-prune';
  if not found or j.jobid <> 2 or j.schedule <> '0 8 * * 0' then raise exception 'hq-prune is not jobid 2 / 0 8 * * 0: stop and check cron.job before applying'; end if;
  perform cron.alter_job(2, command := 'delete from public.agent_runs where started_at < now() - interval ''90 days''');
  if exists (select 1 from cron.job where command ilike '%audit_log%' or command ilike '%public.ledger%') then
    raise exception 'a cron job still touches audit_log / ledger: stop and check cron.job'; end if;
end $$;
insert into public.audit_log (actor, action, target, detail)
  values ('owner', 'audit_ledger_append_only_applied', 'audit_log,ledger',
          jsonb_build_object('proposal', 'ops/proposals/audit_ledger_append_only.sql', 'approved_by', 'owner', 'cron_hq_prune', 'agent_runs delete only'));
commit;

-- UNDO (only if the owner decides to go back):
-- begin;
-- drop trigger if exists audit_log_append_only on public.audit_log; drop trigger if exists audit_log_no_truncate on public.audit_log;
-- drop trigger if exists ledger_append_only on public.ledger; drop trigger if exists ledger_no_truncate on public.ledger;
-- drop function if exists public.fz_append_only_record();
-- grant update, delete, truncate on public.audit_log, public.ledger to service_role;   -- restores today's (weaker) state
-- select cron.alter_job(2, command := 'delete from public.audit_log where at < now() - interval ''90 days''; delete from public.agent_runs where started_at < now() - interval ''90 days''');   -- old prune (deletes history)
-- commit;
