-- PROPOSAL (not a migration; needs the owner's authorization: it changes the protected audit history and money tables). Makes audit_log and ledger APPEND-ONLY.
-- Why: today service_role (the bot's key) holds INSERT, UPDATE, DELETE and TRUNCATE on both tables (checked read-only in production). The M4 hash chain makes an edit
-- EVIDENT; this makes it IMPOSSIBLE for every API role, and refused even for a database session unless the owner first disables the trigger on purpose.
-- What it changes:
--   * REVOKE UPDATE, DELETE, TRUNCATE (and REFERENCES, TRIGGER) on public.audit_log and public.ledger from service_role, anon, authenticated, the scoped roles, backup_reader.
--     INSERT and SELECT stay exactly as they are.
--   * a BEFORE UPDATE OR DELETE row trigger and a BEFORE TRUNCATE trigger on both tables that refuse.
-- Code paths affected: NONE of the application's. Every writer only INSERTs (see ops/proposals/AUDIT_LEDGER_APPEND_ONLY.md, "Code paths"); no code updates or deletes a ledger or
-- audit_log row. Test: psql -f ops/proposals/test_audit_ledger_append_only.sql on a scratch replica (rolled back; deliberately not part of the gate).
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
commit;

-- UNDO (only if the owner decides to go back):
-- begin;
-- drop trigger if exists audit_log_append_only on public.audit_log; drop trigger if exists audit_log_no_truncate on public.audit_log;
-- drop trigger if exists ledger_append_only on public.ledger; drop trigger if exists ledger_no_truncate on public.ledger;
-- drop function if exists public.fz_append_only_record();
-- grant update, delete, truncate on public.audit_log, public.ledger to service_role;   -- restores today's (weaker) state
-- commit;
