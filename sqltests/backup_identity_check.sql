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
  if (select count(*) from public.backup_acl_catalogue() where kind = 'function' and holder = 'backup_reader') <> 12 then raise exception 'D2 the reader list is not the expected 12 functions'; end if;
  -- the role itself: no login, no password, no bypass
  if exists (select 1 from pg_roles where rolname = 'backup_reader' and (rolcanlogin or rolbypassrls or rolsuper or rolcreaterole or rolcreatedb)) then raise exception 'D2 backup_reader has login / bypassrls / superuser / create attributes'; end if;
  if exists (select 1 from pg_authid where rolname = 'backup_reader' and rolpassword is not null) then raise exception 'D2 backup_reader has a password'; end if;
end $$;

-- D3: the guard is in every guarded function, so a blanket grant cannot expose them
do $$
declare bad text;
begin
  select string_agg(c.name, ', ') into bad from cat c join pg_proc p on p.oid = c.fn
   where c.kind = 'function' and p.prosecdef and p.prorettype <> 'trigger'::regtype and p.proname !~ '^(backup_assert_reader|backup_acl_catalogue)$'
     and p.prolang = (select oid from pg_language where lanname = 'plpgsql') and not c.guarded;
  if bad is not null then raise exception 'D3 security definer backup functions without the guard: %', bad; end if;
end $$;

-- D4: the lockdown's own statement, re-run (and a worse one: all three API roles, tables and sequences too) must not let a guarded function or a key read through
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
\ir ../migrations/20261121_postlock_backup_identity_v1.sql
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

rollback;
