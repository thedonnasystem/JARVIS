-- Backup support (Phase 1.5). READ-ONLY: one function that describes the public schema so a backup can rebuild it exactly.
-- Why: the repo cannot rebuild the live schema byte-for-byte (Nov 12 2026 check: 58 of 91 live functions identical, 33 differ in body, and
-- indexes/triggers differ), so a disaster recovery from git alone would silently change behaviour. The backup therefore carries the live definitions.
-- Reads only the system catalogs. Writes nothing. Service role only. Safe to re-run.
create or replace function public.backup_schema() returns jsonb
language plpgsql stable security definer set search_path to 'pg_catalog', 'public' as $$
declare base jsonb; ledger jsonb := '[]'::jsonb; jobs jsonb := '[]'::jsonb;
begin
base := jsonb_build_object(
  'format', 2,
  'server_version', current_setting('server_version'),
  'extensions', (select coalesce(jsonb_agg(jsonb_build_object('name', e.extname, 'schema', n.nspname, 'version', e.extversion) order by e.extname), '[]'::jsonb)
                 from pg_extension e join pg_namespace n on n.oid = e.extnamespace),
  'enums', (select coalesce(jsonb_agg(jsonb_build_object('name', t.typname, 'labels', (select jsonb_agg(l.enumlabel order by l.enumsortorder) from pg_enum l where l.enumtypid = t.oid)) order by t.typname), '[]'::jsonb)
            from pg_type t where t.typnamespace = 'public'::regnamespace and t.typtype = 'e'),
  'domains', (select coalesce(jsonb_agg(jsonb_build_object('name', t.typname, 'base', format_type(t.typbasetype, t.typtypmod), 'notnull', t.typnotnull,
                'default', t.typdefault, 'checks', (select coalesce(jsonb_agg(pg_get_constraintdef(c.oid) order by c.conname), '[]'::jsonb) from pg_constraint c where c.contypid = t.oid)) order by t.typname), '[]'::jsonb)
              from pg_type t where t.typnamespace = 'public'::regnamespace and t.typtype = 'd'),
  'sequences', (select coalesce(jsonb_agg(jsonb_build_object('name', s.sequencename, 'type', s.data_type::text, 'start', s.start_value, 'increment', s.increment_by,
                'min', s.min_value, 'max', s.max_value, 'cycle', s.cycle, 'last_value', s.last_value) order by s.sequencename), '[]'::jsonb)
                from pg_sequences s where s.schemaname = 'public'),
  'tables', (select coalesce(jsonb_agg(jsonb_build_object('name', c.relname, 'rls', c.relrowsecurity, 'force_rls', c.relforcerowsecurity,
                'columns', (select jsonb_agg(jsonb_build_object('name', a.attname, 'type', format_type(a.atttypid, a.atttypmod), 'notnull', a.attnotnull,
                              'default', pg_get_expr(d.adbin, d.adrelid), 'identity', nullif(a.attidentity, ''), 'generated', nullif(a.attgenerated, '')) order by a.attnum)
                            from pg_attribute a left join pg_attrdef d on d.adrelid = a.attrelid and d.adnum = a.attnum
                            where a.attrelid = c.oid and a.attnum > 0 and not a.attisdropped)) order by c.relname), '[]'::jsonb)
             from pg_class c where c.relnamespace = 'public'::regnamespace and c.relkind in ('r', 'p')),
  'constraints', (select coalesce(jsonb_agg(jsonb_build_object('table', c.relname, 'name', k.conname, 'type', k.contype::text, 'def', pg_get_constraintdef(k.oid))
                  order by c.relname, k.conname), '[]'::jsonb)
                  from pg_constraint k join pg_class c on c.oid = k.conrelid where k.connamespace = 'public'::regnamespace and k.conrelid <> 0),
  'indexes', (select coalesce(jsonb_agg(jsonb_build_object('table', tc.relname, 'name', ic.relname, 'def', pg_get_indexdef(i.indexrelid)) order by tc.relname, ic.relname), '[]'::jsonb)
              from pg_index i join pg_class ic on ic.oid = i.indexrelid join pg_class tc on tc.oid = i.indrelid
              where tc.relnamespace = 'public'::regnamespace and not exists (select 1 from pg_constraint k where k.conindid = i.indexrelid and k.contype in ('p', 'u', 'x'))),
  'triggers', (select coalesce(jsonb_agg(jsonb_build_object('table', c.relname, 'name', g.tgname, 'def', pg_get_triggerdef(g.oid), 'enabled', g.tgenabled::text) order by c.relname, g.tgname), '[]'::jsonb)
               from pg_trigger g join pg_class c on c.oid = g.tgrelid where not g.tgisinternal and c.relnamespace = 'public'::regnamespace),
  'functions', (select coalesce(jsonb_agg(jsonb_build_object('sig', p.oid::regprocedure::text, 'def', pg_get_functiondef(p.oid), 'md5', md5(pg_get_functiondef(p.oid)),
                  'acl', (select coalesce(jsonb_agg(distinct coalesce(nullif(r.rolname, ''), 'PUBLIC') ), '[]'::jsonb) from aclexplode(coalesce(p.proacl, acldefault('f', p.proowner))) a
                          left join pg_roles r on r.oid = a.grantee where a.privilege_type = 'EXECUTE')) order by p.oid::regprocedure::text), '[]'::jsonb)
                from pg_proc p where p.pronamespace = 'public'::regnamespace and p.prokind in ('f', 'p')
                  and not exists (select 1 from pg_depend d where d.objid = p.oid and d.deptype = 'e')),
  'views', (select coalesce(jsonb_agg(jsonb_build_object('name', c.relname, 'kind', c.relkind::text, 'def', pg_get_viewdef(c.oid, true), 'options', coalesce(to_jsonb(c.reloptions), '[]'::jsonb)) order by c.relname), '[]'::jsonb)
            from pg_class c where c.relnamespace = 'public'::regnamespace and c.relkind in ('v', 'm')),
  'policies', (select coalesce(jsonb_agg(jsonb_build_object('table', tablename, 'name', policyname, 'permissive', permissive, 'roles', roles, 'cmd', cmd, 'using', qual, 'check', with_check)
                order by tablename, policyname), '[]'::jsonb) from pg_policies where schemaname = 'public'),
  'table_grants', (select coalesce(jsonb_agg(jsonb_build_object('table', c.relname, 'kind', c.relkind::text, 'grantee', coalesce(nullif(r.rolname, ''), 'PUBLIC'), 'privilege', a.privilege_type)
                   order by c.relname, r.rolname, a.privilege_type), '[]'::jsonb)
                   from pg_class c cross join lateral aclexplode(c.relacl) a left join pg_roles r on r.oid = a.grantee
                   where c.relnamespace = 'public'::regnamespace and c.relkind in ('r', 'p', 'v', 'm', 'S') and c.relacl is not null),
  'default_privileges', (select coalesce(jsonb_agg(jsonb_build_object('role', pg_get_userbyid(d.defaclrole), 'objtype', d.defaclobjtype::text, 'acl', d.defaclacl::text) order by d.defaclobjtype::text, d.defaclacl::text), '[]'::jsonb)
                         from pg_default_acl d where d.defaclnamespace = 'public'::regnamespace),
  'schema_acl', (select coalesce(to_jsonb(n.nspacl::text[]), '[]'::jsonb) from pg_namespace n where n.nspname = 'public'),
  'comments', (select coalesce(jsonb_agg(x order by x->>'kind', x->>'name', x->>'column'), '[]'::jsonb) from (
      select jsonb_build_object('kind', case c.relkind when 'v' then 'view' when 'm' then 'matview' when 'S' then 'sequence' else 'table' end, 'name', c.relname, 'column', null, 'text', d.description) x
        from pg_description d join pg_class c on c.oid = d.objoid and d.classoid = 'pg_class'::regclass and d.objsubid = 0
        where c.relnamespace = 'public'::regnamespace and c.relkind in ('r', 'p', 'v', 'm', 'S')
      union all
      select jsonb_build_object('kind', 'column', 'name', c.relname, 'column', a.attname, 'text', d.description)
        from pg_description d join pg_class c on c.oid = d.objoid and d.classoid = 'pg_class'::regclass and d.objsubid > 0
        join pg_attribute a on a.attrelid = c.oid and a.attnum = d.objsubid
        where c.relnamespace = 'public'::regnamespace and c.relkind in ('r', 'p', 'v', 'm')
      union all
      select jsonb_build_object('kind', 'function', 'name', p.oid::regprocedure::text, 'column', null, 'text', d.description)
        from pg_description d join pg_proc p on p.oid = d.objoid and d.classoid = 'pg_proc'::regclass
        where p.pronamespace = 'public'::regnamespace and p.prokind in ('f', 'p') and not exists (select 1 from pg_depend e where e.objid = p.oid and e.deptype = 'e')) q),
  'unsupported', jsonb_build_object(
      'column_acls', (select count(*) from pg_attribute a join pg_class c on c.oid = a.attrelid where c.relnamespace = 'public'::regnamespace and a.attacl is not null),
      'nondefault_owners', (select (select count(*) from pg_class c where c.relnamespace = 'public'::regnamespace and c.relkind in ('r', 'p', 'v', 'm', 'S') and pg_get_userbyid(c.relowner) <> 'postgres')
                                 + (select count(*) from pg_proc p where p.pronamespace = 'public'::regnamespace and pg_get_userbyid(p.proowner) <> 'postgres'
                                      and not exists (select 1 from pg_depend e where e.objid = p.oid and e.deptype = 'e'))),
      'other_comments', (select (select count(*) from pg_description d join pg_class c on c.oid = d.objoid and d.classoid = 'pg_class'::regclass
                                   where c.relnamespace = 'public'::regnamespace and c.relkind not in ('r', 'p', 'v', 'm', 'S'))
                               + (select count(*) from pg_description d join pg_constraint k on k.oid = d.objoid and d.classoid = 'pg_constraint'::regclass where k.connamespace = 'public'::regnamespace)
                               + (select count(*) from pg_description d join pg_type t on t.oid = d.objoid and d.classoid = 'pg_type'::regclass where t.typnamespace = 'public'::regnamespace)
                               + (select count(*) from pg_description d join pg_trigger g on g.oid = d.objoid and d.classoid = 'pg_trigger'::regclass join pg_class c on c.oid = g.tgrelid where c.relnamespace = 'public'::regnamespace)),
      'json_columns', (select count(*) from pg_attribute a join pg_class c on c.oid = a.attrelid where c.relnamespace = 'public'::regnamespace and c.relkind in ('r', 'p') and a.attnum > 0 and not a.attisdropped and a.atttypid = 'json'::regtype),
      'composite_types', (select count(*) from pg_type t join pg_class c on c.oid = t.typrelid where t.typnamespace = 'public'::regnamespace and t.typtype = 'c' and c.relkind = 'c'),
      'rules', (select count(*) from pg_rewrite w join pg_class c on c.oid = w.ev_class where c.relnamespace = 'public'::regnamespace and c.relkind = 'r'),
      'inherited_tables', (select count(*) from pg_inherits i join pg_class c on c.oid = i.inhrelid where c.relnamespace = 'public'::regnamespace)));
-- Optional pieces, resolved at run time so the function also exists on a database without these schemas.
if to_regclass('supabase_migrations.schema_migrations') is not null then
  execute 'select coalesce(jsonb_agg(jsonb_build_object(''version'', m.version, ''name'', m.name, ''statements'', m.statements) order by m.version), ''[]''::jsonb) from supabase_migrations.schema_migrations m' into ledger;
end if;
if to_regclass('cron.job') is not null then
  execute 'select coalesce(jsonb_agg(to_jsonb(j) order by j.jobname), ''[]''::jsonb) from cron.job j' into jobs;
end if;
return base || jsonb_build_object('migration_ledger', ledger, 'cron', jobs);
end $$;
revoke all on function public.backup_schema() from public, anon, authenticated;
grant execute on function public.backup_schema() to service_role;

-- One-statement consistent snapshot of every table (except the secret-bearing ones) plus the schema description.
-- A single SQL statement sees one database snapshot, and STABLE functions called from it use that same snapshot, so rows of all tables and the
-- schema are mutually consistent (no half-finished transaction can show in one table and not another). Read-only. Service role only.
create or replace function public.backup_snapshot(skip text[] default array['push_config', 'push_subscriptions']) returns jsonb
language plpgsql stable security definer set search_path to 'pg_catalog', 'public' as $$  -- the effective time limit is whatever PostgREST/the role applies; on any failure the client falls back to the two-read method
declare q text; res jsonb;
begin
  -- UNION ALL of per-table subselects (jsonb_build_object cannot take more than 100 arguments, i.e. about 49 tables)
  select 'select jsonb_build_object(''data'', (select coalesce(jsonb_object_agg(k, v), ''{}''::jsonb) from (' ||
         string_agg(format('select %L::text as k, (select coalesce(jsonb_agg(to_jsonb(t)), ''[]''::jsonb) from public.%I t) as v', c.relname, c.relname), ' union all ' order by c.relname) ||
         ') s), ''schema'', public.backup_schema(), ''method'', ''single statement snapshot'')'
    into q
    from pg_class c where c.relnamespace = 'public'::regnamespace and c.relkind in ('r', 'p') and c.relname <> all (skip);
  execute q into res;
  return res;
end $$;
revoke all on function public.backup_snapshot(text[]) from public, anon, authenticated;
grant execute on function public.backup_snapshot(text[]) to service_role;
