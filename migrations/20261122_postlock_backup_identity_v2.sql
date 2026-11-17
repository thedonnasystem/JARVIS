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
-- Round 8 (S4):
--   * the sweep also covers PROCEDURES and AGGREGATES named backup_* / redaction_*, VIEWS and MATERIALIZED VIEWS over the key / deny-list / cache tables (any schema, through other views too) and
--     COLUMN-level grants on those tables (`grant select (value) on ffm_redaction_keys to ...`); the event trigger also fires on the statements that create or alter them.
--   * the "already sweeping" marker can no longer be forged. It used to be `set ffm.acl_sweep = '1'`, which any session could set to switch the sweep off. It is now a value derived from the deny-list key
--     (which only the owner can read), this transaction and this backend: a session that sets the setting to anything else is ignored, and the sweep runs.
--   * presence is CHECKED: public.backup_acl_event_status() says whether the event trigger exists, is enabled and still calls backup_acl_event(); scripts/acl_manifest.py (a gate step) carries that as a
--     manifest row and FAILS when it is missing or disabled, and ops/backup_activation_preflight.sh reports it as a BLOCKING OWNER ACTION. A project where the migration owner may not create event triggers
--     still gets the WARNING below; the activation checks are what stop it from going unnoticed.

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

-- one sweep: every internal object back to the catalogue's rule. Cheap (about 75 objects) and idempotent; it only issues a REVOKE / GRANT when a privilege is actually wrong.
create or replace function public.backup_acl_sweep() returns integer
language plpgsql volatile security definer set search_path to 'pg_catalog' as $$
declare r record; who text; n integer := 0; api text[]; mark text := coalesce(current_setting('ffm.acl_sweep', true), ''); k text; tok text; rdr boolean; tp constant text := 'select,insert,update,delete,truncate,references,trigger';
begin
  -- Our own REVOKEs fire the event trigger again: once is enough. The marker is honoured only when it is the keyed value of THIS transaction and backend, which nobody but the owner can compute:
  -- sha256 over the deny-list key (owner-only table), the transaction id and the backend pid. It is computed here, inline: there is no function that returns it.
  select value into k from public.ffm_redaction_keys where name = 'denylist_hmac';
  if k is null then            -- no key row (never the case after 20261120_redaction_denylist_v1): make one, exactly as redaction_capture() does
    insert into public.ffm_redaction_keys (name, value) select 'denylist_hmac', replace(gen_random_uuid()::text || gen_random_uuid()::text, '-', '') where not exists (select 1 from public.ffm_redaction_keys where name = 'denylist_hmac');
    select value into k from public.ffm_redaction_keys where name = 'denylist_hmac';
  end if;
  tok := encode(sha256(convert_to('acl-sweep|' || k || '|' || txid_current()::text || '|' || pg_backend_pid()::text, 'UTF8')), 'hex');
  if mark = tok then return 0; end if;
  perform set_config('ffm.acl_sweep', tok, true);
  rdr := exists (select 1 from pg_roles where rolname = 'backup_reader');
  api := array(select x from unnest(array['public', 'anon', 'authenticated', 'service_role']) x where x = 'public' or exists (select 1 from pg_roles where rolname = x));
  for r in select c.kind, c.name, c.holder from public.backup_acl_catalogue() c loop
    if r.kind = 'function' then
      foreach who in array api loop
        if has_function_privilege(who, r.name::regprocedure, 'execute') then
          execute format('revoke all on routine %s from %s', r.name::regprocedure, case when who = 'public' then 'public' else quote_ident(who) end); n := n + 1;
        end if;
      end loop;
      if r.holder = 'backup_reader' and rdr then
        if not has_function_privilege('backup_reader', r.name::regprocedure, 'execute') then execute format('grant execute on routine %s to backup_reader', r.name::regprocedure); n := n + 1; end if;
      elsif rdr and has_function_privilege('backup_reader', r.name::regprocedure, 'execute') then
        execute format('revoke all on routine %s from backup_reader', r.name::regprocedure); n := n + 1;
      end if;
    else
      foreach who in array api || case when rdr then array['backup_reader'] else '{}'::text[] end loop
        if r.kind = 'sequence' then
          if has_sequence_privilege(who, r.name::regclass, 'usage,select,update') then execute format('revoke all on sequence %s from %s', r.name::regclass, case when who = 'public' then 'public' else quote_ident(who) end); n := n + 1; end if;
        elsif has_table_privilege(who, r.name::regclass, tp) or has_any_column_privilege(who, r.name::regclass, 'select,insert,update,references') then      -- table-level OR any single column
          execute format('revoke all on table %s from %s', r.name::regclass, case when who = 'public' then 'public' else quote_ident(who) end); n := n + 1;     -- REVOKE ... ON TABLE also removes the column privileges
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
  -- a statement that only touched temporary objects (create temp table ...) cannot change an internal object's ACL: skip the sweep (it used to cost every such statement about 2 ms)
  if exists (select 1 from pg_event_trigger_ddl_commands()) and not exists (select 1 from pg_event_trigger_ddl_commands() c where coalesce(c.schema_name, '') !~ '^pg_temp') then return; end if;
  perform public.backup_acl_sweep();
end $$;
revoke all on function public.backup_acl_event() from public, anon, authenticated;
revoke all on function public.backup_acl_event() from service_role;

-- is the control in place? Read by scripts/acl_manifest.py and ops/backup_activation_preflight.sh (facts from the catalog, nothing a caller can set).
create or replace function public.backup_acl_event_status() returns jsonb
language sql stable security invoker set search_path to 'pg_catalog' as $$
  select jsonb_build_object(
    'present', exists (select 1 from pg_event_trigger where evtname = 'ffm_backup_acl_sweep'),
    'enabled', coalesce((select evtenabled in ('O', 'A') from pg_event_trigger where evtname = 'ffm_backup_acl_sweep'), false),
    'calls_sweep', coalesce((select evtfoid = to_regprocedure('public.backup_acl_event()') and evtevent = 'ddl_command_end' from pg_event_trigger where evtname = 'ffm_backup_acl_sweep'), false),
    'tags', coalesce((select array_length(evttags, 1) from pg_event_trigger where evtname = 'ffm_backup_acl_sweep'), 0),
    'ok', coalesce((select evtenabled in ('O', 'A') and evtfoid = to_regprocedure('public.backup_acl_event()') and evtevent = 'ddl_command_end' and array_length(evttags, 1) >= 22
                      from pg_event_trigger where evtname = 'ffm_backup_acl_sweep'), false))
$$;
revoke all on function public.backup_acl_event_status() from public, anon, authenticated;
revoke all on function public.backup_acl_event_status() from service_role;

-- bring everything to the rule now, then install the event trigger. Creating an event trigger needs superuser (a hosted project may not allow it to the migration owner): then the migration says so
-- loudly and succeeds, and the two activation checks FAIL until the platform admin has created it: scripts/acl_manifest.py --check ("event trigger ffm_backup_acl_sweep is missing or disabled") and
-- ops/backup_activation_preflight.sh ("BLOCKING OWNER ACTION"). The guard (backup_assert_reader) remains the control for the reader functions in the meantime.
select public.backup_acl_sweep();
do $$
begin
  if exists (select 1 from pg_event_trigger where evtname = 'ffm_backup_acl_sweep') then drop event trigger ffm_backup_acl_sweep; end if;
  create event trigger ffm_backup_acl_sweep on ddl_command_end
    when tag in ('CREATE FUNCTION', 'ALTER FUNCTION', 'CREATE PROCEDURE', 'ALTER PROCEDURE', 'ALTER ROUTINE', 'CREATE AGGREGATE', 'ALTER AGGREGATE', 'CREATE TABLE', 'CREATE TABLE AS', 'SELECT INTO', 'ALTER TABLE',
                 'CREATE VIEW', 'ALTER VIEW', 'CREATE MATERIALIZED VIEW', 'ALTER MATERIALIZED VIEW', 'CREATE SEQUENCE', 'ALTER SEQUENCE', 'GRANT', 'REVOKE', 'ALTER DEFAULT PRIVILEGES', 'CREATE EXTENSION', 'CREATE SCHEMA')
    execute function public.backup_acl_event();
exception when insufficient_privilege then
  raise warning 'could not create event trigger ffm_backup_acl_sweep (%): BLOCKING OWNER ACTION before the backup is activated: ask the platform admin to run the create event trigger statement in 20261122_postlock_backup_identity_v2.sql. Until then new backup_* / redaction_* objects need a manual revoke, and scripts/acl_manifest.py --check and ops/backup_activation_preflight.sh FAIL on purpose', sqlerrm;
end $$;
