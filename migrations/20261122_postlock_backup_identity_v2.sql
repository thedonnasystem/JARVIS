-- POST-LOCKDOWN, round 7: closes the gaps the independent verifier found in the backup identity (20261121_postlock_backup_identity_v1.sql). Only restricts; safe to re-run; apply LAST.
--
-- D2  the guard is an ALLOW-LIST, not a name blacklist. A session passes only when its EFFECTIVE role (the role PostgREST set from the JWT, or SET ROLE, else the login role) is backup_reader, or is the
--     owner of the guard function, or is a superuser. A login role that is a member of service_role, a custom role that was granted everything, anon, authenticated, authenticator: all refused.
-- D1  a function named backup_* / redaction_* (or agent_runs_scrub) or a table / sequence named ffm_redaction_* that is created, altered or granted LATER (a migration without the lint, the SQL editor, a blanket
--     `grant execute on all functions in schema public to service_role`, a drop-and-recreate) is brought back to the catalogue's rule at the end of that very statement by an EVENT TRIGGER:
--     no PUBLIC / anon / authenticated / service_role privilege on any of them; backup_reader keeps (and gets back) EXECUTE on exactly the reader list. Same transaction, so there is no window.
--     ALTER DEFAULT PRIVILEGES cannot be limited by name pattern, so it is not used; the event trigger is the control.
-- D3  the same sweep revokes table / sequence privileges on ffm_redaction_* after any blanket grant (the lockdown's default privileges grant every new table to service_role).
-- The event trigger and its functions are owner-only: service_role cannot drop, disable or replace them (tested in sqltests/backup_identity_check.sql).

create or replace function public.backup_assert_reader() returns void
language plpgsql stable security invoker set search_path to 'pg_catalog' as $$
declare r text := coalesce(nullif(current_setting('role', true), ''), 'none'); eff text; own text;
begin
  eff := case when r = 'none' then session_user::text else r end;
  if eff = 'backup_reader' then return; end if;
  select pg_get_userbyid(p.proowner) into own from pg_proc p where p.oid = to_regprocedure('public.backup_assert_reader()');
  if eff = own then return; end if;
  if exists (select 1 from pg_roles where rolname = eff and rolsuper) then return; end if;
  raise exception 'this function is for the backup identity (role backup_reader) only' using errcode = '42501';
end $$;
revoke all on function public.backup_assert_reader() from public, anon, authenticated;
revoke all on function public.backup_assert_reader() from service_role;

-- one sweep: every internal object back to the catalogue's rule. Cheap (about 70 objects) and idempotent; it only issues a REVOKE / GRANT when a privilege is actually wrong.
create or replace function public.backup_acl_sweep() returns integer
language plpgsql volatile security definer set search_path to 'pg_catalog' as $$
declare r record; who text; n integer := 0; api text[];
begin
  if current_setting('ffm.acl_sweep', true) = '1' then return 0; end if;                 -- our own REVOKEs fire the event trigger again: once is enough
  perform set_config('ffm.acl_sweep', '1', true);
  api := array(select x from unnest(array['public', 'anon', 'authenticated', 'service_role']) x where x = 'public' or exists (select 1 from pg_roles where rolname = x));
  for r in select c.kind, c.name, c.holder from public.backup_acl_catalogue() c loop
    if r.kind = 'function' then
      foreach who in array api loop
        if has_function_privilege(who, r.name::regprocedure, 'execute') then
          execute format('revoke all on function %s from %s', r.name::regprocedure, case when who = 'public' then 'public' else quote_ident(who) end); n := n + 1;
        end if;
      end loop;
      if r.holder = 'backup_reader' and exists (select 1 from pg_roles where rolname = 'backup_reader') then
        if not has_function_privilege('backup_reader', r.name::regprocedure, 'execute') then execute format('grant execute on function %s to backup_reader', r.name::regprocedure); n := n + 1; end if;
      elsif exists (select 1 from pg_roles where rolname = 'backup_reader') and has_function_privilege('backup_reader', r.name::regprocedure, 'execute') then
        execute format('revoke all on function %s from backup_reader', r.name::regprocedure); n := n + 1;
      end if;
    else
      foreach who in array api || case when exists (select 1 from pg_roles where rolname = 'backup_reader') then array['backup_reader'] else '{}'::text[] end loop
        if r.kind = 'sequence' then
          if has_sequence_privilege(who, r.name::regclass, 'usage,select,update') then execute format('revoke all on sequence %s from %s', r.name::regclass, case when who = 'public' then 'public' else quote_ident(who) end); n := n + 1; end if;
        elsif has_table_privilege(who, r.name::regclass, 'select,insert,update,delete,truncate,references,trigger') then
          execute format('revoke all on table %s from %s', r.name::regclass, case when who = 'public' then 'public' else quote_ident(who) end); n := n + 1;
        end if;
      end loop;
    end if;
  end loop;
  perform set_config('ffm.acl_sweep', '', true);
  return n;
end $$;
revoke all on function public.backup_acl_sweep() from public, anon, authenticated;
revoke all on function public.backup_acl_sweep() from service_role;

create or replace function public.backup_acl_event() returns event_trigger
language plpgsql volatile security definer set search_path to 'pg_catalog' as $$
begin
  perform public.backup_acl_sweep();
end $$;
revoke all on function public.backup_acl_event() from public, anon, authenticated;
revoke all on function public.backup_acl_event() from service_role;

-- bring everything to the rule now, then install the event trigger. Creating an event trigger needs superuser (a hosted project may not allow it to the migration owner): then the migration says so
-- loudly and scripts/acl_manifest.py --check (a gate step) plus the guard remain the controls; the owner can have the trigger created by the platform admin role.
select public.backup_acl_sweep();
do $$
begin
  if exists (select 1 from pg_event_trigger where evtname = 'ffm_backup_acl_sweep') then drop event trigger ffm_backup_acl_sweep; end if;
  create event trigger ffm_backup_acl_sweep on ddl_command_end
    when tag in ('CREATE FUNCTION', 'ALTER FUNCTION', 'CREATE TABLE', 'CREATE TABLE AS', 'SELECT INTO', 'ALTER TABLE', 'CREATE SEQUENCE', 'ALTER SEQUENCE', 'GRANT', 'REVOKE', 'ALTER DEFAULT PRIVILEGES', 'CREATE EXTENSION')
    execute function public.backup_acl_event();
exception when insufficient_privilege then
  raise warning 'could not create event trigger ffm_backup_acl_sweep (%): ask the platform admin to run the create event trigger statement in 20261122_postlock_backup_identity_v2.sql; until then new backup_* / redaction_* objects need a manual revoke (scripts/acl_manifest.py --check catches drift)', sqlerrm;
end $$;
