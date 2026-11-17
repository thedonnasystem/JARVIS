-- Owner directive D: the backup identity. Direct calls as service_role / anon / authenticated (SET ROLE, the same role switch PostgREST makes from the JWT) must be refused for every backup function,
-- every internal helper and every key / deny-list / cache / epoch object, also after a blanket `grant execute on all functions in schema public to service_role` is re-run; backup_reader can run the
-- backup functions and nothing else. Runs in one transaction that is rolled back.
begin;

create function pg_temp.refused(p_role text, p_sql text) returns boolean language plpgsql as $$
begin
  execute 'set local role ' || quote_ident(p_role);
  begin
    execute p_sql;
  exception when insufficient_privilege then
    reset role; return true;
  when others then
    reset role; raise exception 'D-ERR % as %: not a permission error: % %', p_sql, p_role, sqlstate, sqlerrm;
  end;
  reset role;
  return false;
end $$;

create temp table cat as select c.*, case when c.kind = 'function' then c.name::regprocedure end as fn from public.backup_acl_catalogue() c;

create temp table cases (what text, sql text, guarded boolean);
insert into cases values
  ('reader fn', 'select public.backup_epoch()', true),
  ('reader fn', 'select public.backup_deny_prepare()', true),
  ('reader fn', 'select public.backup_deny_release()', true),
  ('reader fn', 'select public.backup_deny_release(gen_random_uuid())', true),
  ('reader fn', 'select public.backup_snapshot()', true),
  ('reader fn', 'select public.backup_snapshot_page(''tasks'', 0, 10, null)', true),
  ('reader fn', 'select public.backup_table_digest(''tasks'')', true),
  ('reader fn', 'select public.backup_schema()', true),
  ('reader fn', 'select public.backup_export_policy()', true),
  ('reader fn', 'select public.backup_snapshot_cost()', true),
  ('reader fn', 'select public.backup_redaction_meta(null)', true),
  ('reader fn', 'select public.backup_redaction_status()', true),
  ('reader fn', 'select public.redaction_denylist_status()', true),
  ('internal fn', 'select public.backup_redaction_context()', true),
  ('internal fn', 'select public.redaction_h(''k'', ''a'', ''b'')', false),
  ('internal fn', 'select public.redaction_pads()', false),
  ('internal fn', 'select public.redaction_capture(''name'', ''Zed Quuxington'')', false),
  ('internal fn', 'select public.backup_deny_terms(''x'', ''{}''::jsonb)', false),
  ('internal fn', 'select public.backup_deny_scan(''[]''::jsonb, ''{}''::jsonb)', false),
  ('internal fn', 'select public.backup_deny_caller()', false),
  ('internal fn', 'select public.backup_fold_text(''x'')', false),
  ('internal fn', 'select public.backup_normalise(''x'')', false),
  ('internal fn', 'select public.backup_redact_text(''x'')', false),
  ('internal fn', 'select public.backup_redaction_spec()', false),
  ('internal fn', 'select public.backup_stopwords()', false),
  ('internal fn', 'select public.backup_acl_catalogue()', false),
  ('internal fn', 'select public.backup_assert_reader()', false),
  ('key table', 'select * from public.ffm_redaction_keys', false),
  ('key table', 'select * from public.ffm_redaction_denylist', false),
  ('cache table', 'select * from public.ffm_redaction_found', false),
  ('cache table', 'delete from public.ffm_redaction_found', false),
  ('deny-list write', 'insert into public.ffm_redaction_denylist (kind, h) values (''name'', ''x'')', false),
  ('epoch seq', 'select last_value from public.ffm_redaction_epoch_seq', false),
  ('epoch seq', 'select nextval(''public.ffm_redaction_epoch_seq'')', false);

-- D1: refused for every API role, every case
do $$
declare r record; ro text;
begin
  foreach ro in array array['service_role', 'anon', 'authenticated'] loop
    for r in select * from cases loop
      if not pg_temp.refused(ro, r.sql) then raise exception 'D1 % was NOT refused for % : %', r.what, ro, r.sql; end if;
    end loop;
  end loop;
end $$;

-- D2: the effective ACL (what has_*_privilege answers, PUBLIC and inheritance included) holds for every catalogue object
do $$
declare r record; ro text; bad text;
begin
  foreach ro in array array['service_role', 'anon', 'authenticated'] loop
    select string_agg(c.name, ', ') into bad from cat c where c.kind = 'function' and has_function_privilege(ro, c.fn, 'execute');
    if bad is not null then raise exception 'D2 % can execute: %', ro, bad; end if;
    select string_agg(c.name, ', ') into bad from cat c where c.kind = 'table' and exists (select 1 from unnest(array['select','insert','update','delete','truncate','references','trigger']) p where has_table_privilege(ro, case when c.kind = 'table' then c.name end, p));
    if bad is not null then raise exception 'D2 % has a table privilege on: %', ro, bad; end if;
    select string_agg(c.name, ', ') into bad from cat c where c.kind = 'sequence' and has_sequence_privilege(ro, case when c.kind = 'sequence' then c.name end, 'usage,select,update');
    if bad is not null then raise exception 'D2 % has a sequence privilege on: %', ro, bad; end if;
  end loop;
  -- backup_reader holds exactly the reader list, nothing else, and no table or sequence privilege anywhere in public
  select string_agg(c.name, ', ') into bad from cat c where c.kind = 'function' and (c.holder = 'backup_reader') <> has_function_privilege('backup_reader', c.fn, 'execute');
  if bad is not null then raise exception 'D2 backup_reader function ACL differs from the catalogue: %', bad; end if;
  select string_agg(c.relname, ', ') into bad from pg_class c where c.relnamespace = 'public'::regnamespace and c.relkind in ('r', 'p', 'v')
    and exists (select 1 from unnest(array['select','insert','update','delete','truncate','references','trigger']) p where has_table_privilege('backup_reader', c.oid, p));
  if bad is not null then raise exception 'D2 backup_reader holds table privileges (it needs none, the reader functions are security definer): %', bad; end if;
  if (select count(*) from public.backup_acl_catalogue() where kind = 'function' and holder = 'backup_reader') <> 12 + (to_regprocedure('public.backup_suppression_export()') is not null)::int then raise exception 'D2 the reader list is not the expected 12 functions (13 once the consent migration adds backup_suppression_export)'; end if;
  -- the role itself: no login, no password, no bypass
  if exists (select 1 from pg_roles where rolname = 'backup_reader' and (rolcanlogin or rolbypassrls or rolsuper or rolcreaterole or rolcreatedb)) then raise exception 'D2 backup_reader has login / bypassrls / superuser / create attributes'; end if;
  if exists (select 1 from pg_authid where rolname = 'backup_reader' and rolpassword is not null) then raise exception 'D2 backup_reader has a password'; end if;
end $$;

-- D3: the guard is in every guarded function, so a blanket grant cannot expose them
do $$
declare bad text;
begin
  select string_agg(c.name, ', ') into bad from cat c join pg_proc p on p.oid = c.fn
   where c.kind = 'function' and p.prosecdef and p.prorettype <> 'trigger'::regtype and p.proname !~ '^(backup_assert_reader|backup_acl_catalogue|backup_acl_sweep|backup_acl_event)$'
     and p.prolang = (select oid from pg_language where lanname = 'plpgsql') and not c.guarded;
  if bad is not null then raise exception 'D3 security definer backup functions without the guard: %', bad; end if;
end $$;

-- D4: the lockdown's own statement, re-run (and a worse one: all three API roles, tables and sequences too) must not let a guarded function or a key read through
grant execute on all functions in schema public to service_role, anon, authenticated;
grant all on all tables in schema public to service_role;
grant all on all sequences in schema public to service_role;
-- D1 (round 7): with the event trigger installed the blanket grants above exposed NOTHING: the sweep ran at the end of each GRANT
do $$
declare bad text; ro text;
begin
  if not exists (select 1 from pg_event_trigger where evtname = 'ffm_backup_acl_sweep' and evtenabled = 'O') then raise exception 'D1 the ACL event trigger is not installed and enabled'; end if;
  foreach ro in array array['service_role', 'anon', 'authenticated'] loop
    select string_agg(c.name, ', ') into bad from cat c where c.kind = 'function' and has_function_privilege(ro, c.fn, 'execute');
    if bad is not null then raise exception 'D1 a blanket grant exposed % to %', bad, ro; end if;
    select string_agg(c.name, ', ') into bad from cat c where c.kind = 'table' and has_table_privilege(ro, case when c.kind = 'table' then c.name::regclass end, 'select,insert,update,delete');
    if bad is not null then raise exception 'D1 a blanket grant exposed table % to %', bad, ro; end if;
    select string_agg(c.name, ', ') into bad from cat c where c.kind = 'sequence' and has_sequence_privilege(ro, case when c.kind = 'sequence' then c.name::regclass end, 'usage,select,update');
    if bad is not null then raise exception 'D1 a blanket grant exposed sequence % to %', bad, ro; end if;
  end loop;
  if has_function_privilege('backup_reader', 'public.backup_epoch()'::regprocedure, 'execute') is not true then raise exception 'D1 the sweep took the reader its own function away'; end if;
end $$;
-- D1b a function / table / sequence created LATER by the owner (SQL editor, a migration without the lint, drop-and-recreate) is closed in the same statement
create function public.backup_zz_newhelper() returns int language sql security definer as $f$ select 1 $f$;
create table public.ffm_redaction_zznew (x int);
create sequence public.ffm_redaction_zznewseq;
create function public.redaction_zz_newhelper() returns int language sql as $f$ select 1 $f$;
do $$
declare ro text;
begin
  foreach ro in array array['public', 'service_role', 'anon', 'authenticated', 'backup_reader'] loop
    if has_function_privilege(ro, 'public.backup_zz_newhelper()'::regprocedure, 'execute') or has_function_privilege(ro, 'public.redaction_zz_newhelper()'::regprocedure, 'execute') then raise exception 'D1b new internal function is executable by %', ro; end if;
    if has_table_privilege(ro, 'public.ffm_redaction_zznew', 'select,insert,update,delete') then raise exception 'D1b new internal table is readable by %', ro; end if;
    if has_sequence_privilege(ro, 'public.ffm_redaction_zznewseq', 'usage,select,update') then raise exception 'D1b new internal sequence is usable by %', ro; end if;
  end loop;
end $$;
-- ... and an ALTER (rename into the internal namespace) does too
create table public.zz_plain (x int);
grant all on public.zz_plain to service_role;
alter table public.zz_plain rename to ffm_redaction_zzrenamed;
do $$ begin if has_table_privilege('service_role', 'public.ffm_redaction_zzrenamed', 'select') then raise exception 'D1c a table renamed into the internal namespace stays readable by service_role'; end if; end $$;
-- D1d the trigger and its functions are owner-only: service_role cannot disable, drop or replace them, and cannot call them
do $$
declare s text; ro text;
begin
  foreach s in array array['alter event trigger ffm_backup_acl_sweep disable', 'drop event trigger ffm_backup_acl_sweep', 'create or replace function public.backup_acl_sweep() returns integer language sql as ''select 0''',
                           'select public.backup_acl_sweep()', 'alter function public.backup_acl_sweep() owner to service_role', 'drop function public.backup_acl_event() cascade'] loop
    foreach ro in array array['service_role', 'anon', 'authenticated'] loop
      if pg_temp.refused(ro, s) is not true then raise exception 'D1d % could run: %', ro, s; end if;
    end loop;
  end loop;
  if not exists (select 1 from pg_event_trigger where evtname = 'ffm_backup_acl_sweep' and evtenabled = 'O') then raise exception 'D1d the event trigger changed'; end if;
end $$;
-- D4 defence in depth: even with the event trigger OFF (owner action) and the grants wrong, every guarded function still refuses the API roles
alter event trigger ffm_backup_acl_sweep disable;
grant execute on all functions in schema public to service_role, anon, authenticated;
grant all on all tables in schema public to service_role;
grant all on all sequences in schema public to service_role;
do $$
declare r record; ro text; n int := 0;
begin
  foreach ro in array array['service_role', 'anon', 'authenticated'] loop
    for r in select * from cases where guarded loop
      if not pg_temp.refused(ro, r.sql) then raise exception 'D4 after a blanket grant, % could run a guarded function: %', ro, r.sql; end if;
      n := n + 1;
    end loop;
  end loop;
  raise notice 'D4 % guarded calls refused after the blanket grant', n;
end $$;
-- the unguarded helpers (pure text functions; the ones that read the key table fail on the table privilege or are revoked) ARE exposed by a blanket grant until the post-lockdown migration is applied again:
-- that is what the ACL manifest check in the gate detects. Re-applying the migration restores the catalogue exactly.
do $$
begin
  if not exists (select 1 from cat c where c.kind = 'function' and has_function_privilege('service_role', c.fn, 'execute')) then
    raise exception 'D4 test premise: the blanket grant should have exposed some unguarded helpers';
  end if;
end $$;
-- D2 (round 7): the guard is an allow-list. A member of service_role, a custom role that was granted everything and the platform's authenticator are refused although EXECUTE is granted
create role zz_member nologin; grant service_role to zz_member; grant usage on schema public to zz_member;
create role zz_custom nologin; grant usage on schema public to zz_custom; grant execute on all functions in schema public to zz_custom; grant all on all tables in schema public to zz_custom;
do $$
declare r record; ro text; n int := 0;
begin
  foreach ro in array array['zz_member', 'zz_custom'] loop
    for r in select * from cases where guarded and what = 'reader fn' loop
      if not pg_temp.refused(ro, r.sql) then raise exception 'D2 % passed the guard: %', ro, r.sql; end if;
      n := n + 1;
    end loop;
  end loop;
  -- the intended identities still pass: the owner (this session) and backup_reader
  perform public.backup_epoch();
  set local role backup_reader; perform public.backup_epoch(); reset role;
  raise notice 'D2 % calls refused for non-allow-listed roles', n;
end $$;
\ir ../migrations/20261121_postlock_backup_identity_v1.sql
\ir ../migrations/20261122_postlock_backup_identity_v2.sql
do $$
declare bad text; ro text;
begin
  foreach ro in array array['service_role', 'anon', 'authenticated'] loop
    select string_agg(c.name, ', ') into bad from cat c where c.kind = 'function' and has_function_privilege(ro, c.fn, 'execute');
    if bad is not null then raise exception 'D4 the post-lockdown migration did not take the grant back from %: %', ro, bad; end if;
    select string_agg(c.name, ', ') into bad from cat c where c.kind = 'table' and has_table_privilege(ro, case when c.kind = 'table' then c.name end, 'select');
    if bad is not null then raise exception 'D4 % can still read %', ro, bad; end if;
  end loop;
end $$;

-- D5: backup_reader can do the backup, and only that
do $$
declare r record; run text; pg jsonb; q text;
begin
  set local role backup_reader;
  foreach q in array array['select public.backup_epoch()', 'select public.backup_export_policy()', 'select public.backup_snapshot_cost()', 'select public.backup_redaction_status()', 'select public.redaction_denylist_status()',
    'select public.backup_redaction_meta(null)', 'select public.backup_table_digest(''tasks'')', 'select public.backup_schema()', 'select public.backup_snapshot()'] loop
    begin execute q; exception when others then reset role; raise exception 'D5 backup_reader could not run % : % %', q, sqlstate, sqlerrm; end;
  end loop;
  select public.backup_deny_prepare() ->> 'run' into run;
  pg := public.backup_snapshot_page('tasks', 0, 10, run::uuid);
  if pg -> 'rows' is null then reset role; raise exception 'D5 paged read as backup_reader returned no rows key'; end if;
  perform public.backup_deny_release(run::uuid);
  reset role;
  -- and nothing else: no internal helper, no key, no tables
  for r in select * from cases where what <> 'reader fn' loop
    if not pg_temp.refused('backup_reader', r.sql) then raise exception 'D5 backup_reader could do: %', r.sql; end if;
  end loop;
  if not pg_temp.refused('backup_reader', 'select count(*) from public.tasks') then raise exception 'D5 backup_reader can read a table directly'; end if;
end $$;

-- ===== Round 8 (S4): sweep completeness, the unforgeable marker, and detection of a missing / disabled event trigger. Each case: EXPECTED = no API role holds the privilege at the end of the statement.
do $$ begin if not (public.backup_acl_event_status() ->> 'ok')::boolean then raise exception 'S4 premise: the event trigger is not reported as in place: %', public.backup_acl_event_status(); end if; end $$;
create procedure public.backup_zz_proc() language sql as 'select 1';
create aggregate public.backup_zz_agg(integer) (sfunc = int4pl, stype = integer);
create view public.zz_keys_view as select * from public.ffm_redaction_keys;
create view public.zz_keys_view2 as select value from public.zz_keys_view;
create materialized view public.ffm_redaction_zzmv as select * from public.ffm_redaction_keys;
create schema zz_other; grant usage on schema zz_other to service_role, anon, authenticated;
create view zz_other.keys_elsewhere as select d.h from public.ffm_redaction_denylist d; grant select on zz_other.keys_elsewhere to service_role, anon;
grant select on public.zz_keys_view, public.zz_keys_view2, public.ffm_redaction_zzmv to service_role, anon, authenticated;
create table public."ffm_redaction_ZZupper" (x integer);                                    -- N7: a mixed-case name used to make the sweep fail on its regclass cast
grant select (value) on public.ffm_redaction_keys to service_role;                           -- column-level grant
grant update (found) on public.ffm_redaction_found to anon;
do $$
declare ro text; bad text;
begin
  foreach ro in array array['service_role', 'anon', 'authenticated'] loop
    if has_function_privilege(ro, 'public.backup_zz_proc()', 'execute') then raise exception 'S4a % may call a new backup_* PROCEDURE', ro; end if;
    if has_function_privilege(ro, 'public.backup_zz_agg(integer)', 'execute') then raise exception 'S4b % may call a new backup_* AGGREGATE', ro; end if;
    select string_agg(v, ', ') into bad from unnest(array['public.zz_keys_view', 'public.zz_keys_view2', 'public.ffm_redaction_zzmv', 'zz_other.keys_elsewhere', 'public."ffm_redaction_ZZupper"']) v where has_table_privilege(ro, v, 'select');
    if bad is not null then raise exception 'S4c % can read a view / materialized view / table over the key tables: %', ro, bad; end if;
    if has_any_column_privilege(ro, 'public.ffm_redaction_keys', 'select') or has_any_column_privilege(ro, 'public.ffm_redaction_found', 'update') then raise exception 'S4d % kept a COLUMN-level grant on a key table', ro; end if;
    if not pg_temp.refused(ro, 'select value from public.zz_keys_view') then raise exception 'S4c % read the key through a view', ro; end if;
  end loop;
  if (select count(*) from public.backup_acl_catalogue() c where c.name in ('public.backup_zz_proc()', 'public.backup_zz_agg(integer)', 'public.zz_keys_view', 'public.zz_keys_view2', 'public.ffm_redaction_zzmv', 'zz_other.keys_elsewhere', 'public."ffm_redaction_ZZupper"')) <> 7 then
    raise exception 'S4 the catalogue does not list all seven new objects: %', (select string_agg(c.name, ', ') from public.backup_acl_catalogue() c where c.name ~* 'zz');
  end if;
end $$;
-- the marker cannot be forged: with the OLD marker value set in the session, a blanket grant is still swept in the same statement
set local ffm.acl_sweep = '1';
grant select on public.ffm_redaction_keys to anon; grant execute on function public.redaction_pads() to anon;
do $$ begin
  if has_table_privilege('anon', 'public.ffm_redaction_keys', 'select') or has_function_privilege('anon', 'public.redaction_pads()', 'execute') then raise exception 'S4e setting ffm.acl_sweep switched the sweep off'; end if;
end $$;
set local ffm.acl_sweep = 'ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff';
grant select on public.ffm_redaction_denylist to service_role;
do $$ begin if has_table_privilege('service_role', 'public.ffm_redaction_denylist', 'select') then raise exception 'S4e a guessed marker switched the sweep off'; end if; end $$;
set local ffm.acl_sweep = '';
-- nobody but the owner can call the sweep; the marker is computed inline (no function returns it)
do $$
declare ro text;
begin
  foreach ro in array array['service_role', 'anon', 'authenticated', 'backup_reader'] loop
    if not pg_temp.refused(ro, 'select public.backup_acl_sweep()') then raise exception 'S4f % can call the sweep', ro; end if;
  end loop;
end $$;
-- a statement on temporary objects only does not error and does not need the sweep (N8)
create temporary table zz_tmp_only (x integer); drop table zz_tmp_only;
-- detection: a disabled or dropped trigger is REPORTED (the manifest check and the preflight read this; scripts/replica/acl_detect_check.sh proves both fail)
alter event trigger ffm_backup_acl_sweep disable;
do $$ begin if (public.backup_acl_event_status() ->> 'ok')::boolean or (public.backup_acl_event_status() ->> 'enabled')::boolean then raise exception 'S4g a DISABLED event trigger is reported as fine'; end if; end $$;
drop event trigger ffm_backup_acl_sweep;
do $$ begin if (public.backup_acl_event_status() ->> 'ok')::boolean or (public.backup_acl_event_status() ->> 'present')::boolean then raise exception 'S4g a MISSING event trigger is reported as fine'; end if; end $$;
-- the hosted case: a role that is not a superuser cannot create the event trigger, and the error class is the one the migration turns into its WARNING (insufficient_privilege)
do $$
begin
  set local role zz_custom;
  begin
    execute 'create event trigger zz_not_allowed on ddl_command_end execute function public.backup_acl_event()';
    reset role; raise exception 'S4h a non-superuser created an event trigger';
  exception when insufficient_privilege then reset role;
  end;
end $$;

-- ===== Round 8 (integration rehearsal S1): the consent PR's backup_suppression_export() must be reachable by backup_reader, and only by it. The function does not exist on this branch, so a stand-in
-- with the same name, signature and attributes (plpgsql, security definer, search_path public: PR #20 head 1899251) is created and the two post-lockdown files are applied again, as a release would.
select to_regprocedure('public.backup_suppression_export()') is null as need_standin \gset
\if :need_standin
create function public.backup_suppression_export() returns jsonb language plpgsql stable security definer set search_path to 'public' as $b$ begin return jsonb_build_object('ok', true, 'count', 0); end $b$;
grant execute on function public.backup_suppression_export() to service_role;
\endif
\ir ../migrations/20261121_postlock_backup_identity_v1.sql
\ir ../migrations/20261122_postlock_backup_identity_v2.sql
do $$
declare ro text;
begin
  if (select count(*) from public.backup_acl_catalogue() where kind = 'function' and holder = 'backup_reader') <> 13 then raise exception 'S1x expected 13 reader functions with the suppression export installed'; end if;
  if not has_function_privilege('backup_reader', 'public.backup_suppression_export()', 'execute') then raise exception 'S1x backup_reader cannot execute backup_suppression_export()'; end if;
  foreach ro in array array['service_role', 'anon', 'authenticated'] loop
    if has_function_privilege(ro, 'public.backup_suppression_export()', 'execute') then raise exception 'S1x % can execute backup_suppression_export()', ro; end if;
  end loop;
  if not (select guarded from public.backup_acl_catalogue() where name = 'public.backup_suppression_export()') then raise exception 'S1x the export did not get the reader guard'; end if;
  if not exists (select 1 from pg_proc p where p.oid = 'public.backup_suppression_export()'::regprocedure and p.proconfig @> array['search_path=pg_catalog']) then raise exception 'S1x the export keeps a search_path with public in it'; end if;
  set local role backup_reader;
  -- rc1 integration fix-up F1: with PR #20 merged the REAL export runs here (it answers {version, included, ...}, not the stand-in's {ok: true}); either shape proves backup_reader can run it
  if not (coalesce(public.backup_suppression_export() ->> 'ok', '') = 'true' or public.backup_suppression_export() ? 'included') then reset role; raise exception 'S1x backup_reader could not run the export'; end if;
  reset role;
end $$;

rollback;
