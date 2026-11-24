-- Rollback of migrations/20261205_creative_studio_v1.sql (M8 FENDEZY AI CREATIVE STUDIO). Idempotent. Run from the repo root:
--   psql -v ON_ERROR_STOP=1 -f ops/rollback_creative_studio.sql          (one transaction: it opens and commits its own)
-- (sqltests/creative_studio_check.sql sets fz_in_txn and runs it INSIDE its own rolled-back transaction.)
-- Order: FIRST of the Phase 1 rollbacks (before ops/rollback_donna_v1_profile.sql / ops/rollback_office_os.sql). No structural dependency on M1..M7.
-- 1. ONE audit_log export row (counts); 2. ARCHIVES every fz_creative table, rows intact, into fz_archive (an older archive moves on to fz_archive_<timestamp>);
-- 3. drops the creative_* functions, the schema's helpers and the empty schema. The owner-added fz_services row is left for the owner (set it to retired).
\if :{?fz_in_txn}
\else
begin;
\endif
do $$
declare v_suffix text := to_char(clock_timestamp(), 'YYYYMMDDHH24MISSUS'); t text; r text; v_counts jsonb := '{}'::jsonb; n bigint;
begin
  if to_regnamespace('fz_creative') is null then return; end if;
  foreach t in array array['calendar', 'performance', 'assets', 'attempts', 'jobs', 'characters', 'presets', 'providers', 'office_settings', 'brand_kits', 'likeness_consents'] loop
    if to_regclass('fz_creative.' || t) is not null then execute format('select count(*) from fz_creative.%I', t) into n; v_counts := v_counts || jsonb_build_object(t, n); end if;
  end loop;
  insert into public.audit_log (actor, action, target, detail) values ('rollback', 'creative_studio_export', 'fz_creative', v_counts);
  create schema if not exists fz_archive;
  revoke all on schema fz_archive from public;
  foreach r in array array['anon', 'authenticated', 'service_role'] loop
    if exists (select 1 from pg_roles where rolname = r) then execute format('revoke all on schema fz_archive from %I', r); end if;
  end loop;
  foreach t in array array['calendar', 'performance', 'assets', 'attempts', 'jobs', 'characters', 'presets', 'providers', 'office_settings', 'brand_kits', 'likeness_consents'] loop
    continue when to_regclass('fz_creative.' || t) is null;
    if to_regclass('fz_archive.creative_' || t) is not null then
      execute format('create schema if not exists %I', 'fz_archive_' || v_suffix);
      execute format('revoke all on schema %I from public', 'fz_archive_' || v_suffix);
      execute format('alter table fz_archive.%I set schema %I', 'creative_' || t, 'fz_archive_' || v_suffix);
    end if;
    execute format('alter table fz_creative.%I rename to %I', t, 'creative_' || t);
    execute format('alter table fz_creative.%I set schema fz_archive', 'creative_' || t);
  end loop;
end $$;
do $$ declare f regprocedure; begin
  for f in select p.oid::regprocedure from pg_proc p where p.pronamespace = 'public'::regnamespace and p.proname like 'creative\_%' loop
    execute format('drop function %s', f);
  end loop;
end $$;
drop function if exists fz_creative.office_active(text);
drop function if exists fz_creative.studio_on();
drop function if exists fz_creative.service_path();
drop function if exists fz_creative.guard();
drop function if exists fz_creative.clean(text, integer);
drop function if exists fz_creative.owner_only(text);
drop schema if exists fz_creative;
\if :{?fz_in_txn}
\else
commit;
\endif
