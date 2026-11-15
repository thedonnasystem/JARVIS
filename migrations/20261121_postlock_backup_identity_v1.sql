-- POST-LOCKDOWN: the backup identity (owner directive D). Ordered AFTER 20261112_lockdown_v1.sql on purpose: the lockdown ends with
--   grant execute on all functions in schema public to service_role   (+ default privileges for future functions)
-- which hands every backup / redaction helper to the bot's service key. This file takes them back. It only ever RESTRICTS (scripts/lint_migrations.py R3: nothing but `postlock` files may follow the lockdown, and R4/R5 apply to them).
--
-- Who may do what afterwards (one catalogue: select * from public.backup_acl_catalogue(); owner-only):
--   backup_reader  a NOLOGIN database role, created here, NO password anywhere. It alone may EXECUTE the "reader" functions (what hq_backup.py calls) and it holds NO table privilege at all: the reader
--                  functions are SECURITY DEFINER and read the data themselves, so it needs no SELECT (and no BYPASSRLS). PostgREST reaches it with a JWT whose `role` claim is backup_reader (OWNER DECISION
--                  how to mint it, DATA_CLASSIFICATION_AND_BACKUP_POLICY.md rule 12). hq_backup.py sends that JWT (env BACKUP_READER_JWT) for its RPC calls and never the service key.
--   service_role  (the bot) / anon / authenticated: EXECUTE on NONE of the backup_* / redaction_* functions, no privilege on ffm_redaction_keys / _denylist / _found / the epoch sequence.
--   owner         everything (the migration owner, psql, the SQL editor, pg_cron).
-- Defence in depth against a later blanket `grant execute on all functions in schema public to service_role` (the lockdown does exactly that): every SECURITY DEFINER backup function that reads a key,
-- the deny-list, the cache, the epoch or the exported data starts with `perform public.backup_assert_reader()`, which refuses any session whose role is anon / authenticated / service_role even when EXECUTE is
-- granted. The pure text helpers (fold, normalise, detectors, regexes, spec) read no data and no key; for them the revoke below is the control and scripts/acl_manifest.py --check (a gate step) catches drift.
-- Safe to re-run. Apply LAST (after the lockdown).

do $$
begin
  if not exists (select 1 from pg_roles where rolname = 'backup_reader') then
    create role backup_reader nologin noinherit nobypassrls nocreatedb nocreaterole noreplication;
  end if;
  alter role backup_reader set statement_timeout = '300s';      -- the whole-export scan is one call; the API roles' short default timeouts would cut it
  if exists (select 1 from pg_roles where rolname = 'authenticator') then
    begin
      grant backup_reader to authenticator;                       -- PostgREST switches to the JWT's role through authenticator
    exception when others then
      raise notice 'could not grant backup_reader to authenticator (%): the owner must run: grant backup_reader to authenticator;', sqlerrm;
    end;
  end if;
end $$;
grant usage on schema public to backup_reader;

-- The guard. SECURITY INVOKER on purpose: it reads the SESSION role (current_setting('role') is what PostgREST sets from the JWT and what SET ROLE sets), which a SECURITY DEFINER caller does not change.
create or replace function public.backup_assert_reader() returns void
language plpgsql stable security invoker set search_path to 'pg_catalog' as $$
declare r text := coalesce(nullif(current_setting('role', true), ''), 'none');
begin
  if r = 'backup_reader' then return; end if;
  if r in ('anon', 'authenticated', 'service_role', 'authenticator') or session_user in ('anon', 'authenticated', 'service_role', 'authenticator') then
    raise exception 'this function is for the backup identity (role backup_reader) only' using errcode = '42501';
  end if;
end $$;
revoke all on function public.backup_assert_reader() from public, anon, authenticated;
revoke all on function public.backup_assert_reader() from service_role;

-- The single catalogue of owner-only / backup-identity objects. The RULE is the catalogue: every public function whose name starts with backup_ or redaction_ (plus agent_runs_scrub) and every
-- public relation whose name starts with ffm_redaction_ is internal; the reader list below is the only exception. A new helper that follows the naming rule is covered without editing this file.
create or replace function public.backup_acl_catalogue() returns table (kind text, name text, holder text, guarded boolean)
language sql stable security invoker set search_path to 'pg_catalog' as $$
  select 'function'::text, p.oid::regprocedure::text,
         case when p.proname in ('backup_schema', 'backup_export_policy', 'backup_snapshot', 'backup_snapshot_page', 'backup_table_digest', 'backup_snapshot_cost', 'backup_redaction_meta',
                                 'backup_epoch', 'backup_deny_prepare', 'backup_deny_release', 'backup_redaction_status', 'redaction_denylist_status') then 'backup_reader' else 'owner only' end,
         pg_get_functiondef(p.oid) like '%perform public.backup_assert_reader()%'
    from pg_proc p where p.pronamespace = 'public'::regnamespace and p.prokind = 'f' and (p.proname ~ '^(backup_|redaction_)' or p.proname = 'agent_runs_scrub')
  union all
  select case c.relkind when 'S' then 'sequence' else 'table' end, 'public.' || c.relname, 'owner only', false
    from pg_class c where c.relnamespace = 'public'::regnamespace and c.relkind in ('r', 'p', 'S') and c.relname like 'ffm\_redaction\_%'
  order by 1, 2
$$;
revoke all on function public.backup_acl_catalogue() from public, anon, authenticated;
revoke all on function public.backup_acl_catalogue() from service_role;

-- 1) the guard goes into every plpgsql SECURITY DEFINER backup function that is not a trigger function (trigger functions cannot be called directly and must keep working for every writer)
do $$
declare r record; def text; new text;
begin
  for r in select p.oid, p.oid::regprocedure::text as sig from pg_proc p join pg_language l on l.oid = p.prolang
            where p.pronamespace = 'public'::regnamespace and p.prokind = 'f' and p.prosecdef and l.lanname = 'plpgsql' and p.prorettype <> 'trigger'::regtype
              and p.proname ~ '^(backup_|redaction_)' and p.proname <> 'backup_assert_reader'
  loop
    def := pg_get_functiondef(r.oid);
    continue when def like '%backup_assert_reader()%';
    new := regexp_replace(def, '(\$function\$(?:.|\n)*?)\mbegin\M', E'\\1begin\n  perform public.backup_assert_reader();', 'i');
    if new = def then raise exception 'could not add the backup guard to %', r.sig; end if;
    execute new;
  end loop;
end $$;

-- 1b) the two status functions are one-statement SQL (counts only, but they read the key table and the deny-list): re-create them as plpgsql with the guard in front of the same statement
do $$
declare r record; def text; b1 int; b2 int; body text;
begin
  for r in select p.oid, p.oid::regprocedure::text as sig from pg_proc p join pg_language l on l.oid = p.prolang
            where p.pronamespace = 'public'::regnamespace and p.prokind = 'f' and p.prosecdef and l.lanname = 'sql' and p.prorettype = 'jsonb'::regtype and p.proname in ('backup_redaction_status', 'redaction_denylist_status')
  loop
    def := pg_get_functiondef(r.oid);
    b1 := position('$function$' in def); b2 := b1 + 10 + position('$function$' in substr(def, b1 + 10)) - 1;
    body := btrim(substr(def, b1 + 10, b2 - b1 - 10), E' \n\t;');
    execute replace(substr(def, 1, b1 - 1), 'LANGUAGE sql', 'LANGUAGE plpgsql') || '$function$ begin perform public.backup_assert_reader(); return (' || body || '); end $function$';
  end loop;
end $$;

-- 2) take the lockdown's blanket grant back from every internal object; then give the reader list to backup_reader (and nothing to anyone else)
do $$
declare r record;
begin
  for r in select p.oid::regprocedure::text as sig, c.holder from public.backup_acl_catalogue() c join pg_proc p on p.oid = c.name::regprocedure where c.kind = 'function' loop
    execute format('revoke all on function %s from public, anon, authenticated, service_role, backup_reader', r.sig);
    if r.holder = 'backup_reader' then execute format('grant execute on function %s to backup_reader', r.sig); end if;
  end loop;
  for r in select c.kind, c.name from public.backup_acl_catalogue() c where c.kind in ('table', 'sequence') loop
    if r.kind = 'sequence' then execute format('revoke all on sequence %s from public, anon, authenticated, service_role, backup_reader', r.name);
    else execute format('revoke all on table %s from public, anon, authenticated, service_role, backup_reader', r.name); end if;
  end loop;
end $$;
-- 3) search_path: three older definers still had `pg_catalog, public`; with CREATE on public revoked the hijack was already closed, this removes the dependency on that revoke
alter function public.backup_schema() set search_path to 'pg_catalog';
alter function public.backup_classification() set search_path to 'pg_catalog';
alter function public.backup_pii_column_exceptions() set search_path to 'pg_catalog';
-- future helpers created after this file still get the lockdown's default grant to service_role; R4 forces a revoke after each new function, and the ACL manifest check fails the gate on any drift
