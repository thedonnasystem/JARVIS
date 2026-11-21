-- Rollback of migrations/20261203_office_os_v1.sql (FENDEZY GROUP Phase 1, M7 "Office operating system"). Idempotent. Run from the repo root:
--   psql -v ON_ERROR_STOP=1 -f ops/rollback_office_os.sql          (one transaction: it opens and commits its own)
-- (sqltests/office_os_check.sql sets fz_in_txn and runs it INSIDE its own rolled-back transaction.)
-- Order: FIRST of the Phase 1 rollbacks (before ops/rollback_shared_services.sql). M7 has no structural dependency on M1..M5, so any order works.
-- 0. keeps the record: every profile (status, manager appointed, activation) goes into ONE audit_log row;
-- 1. ARCHIVES the profile, decision and drift tables, rows intact, into fz_archive (fz_office_profiles, fz_office_decisions, fz_office_drift) (no API privileges; an older archive moves on to fz_archive_<timestamp>);
-- 2. unschedules the drift job; drops the six office_os_* functions and the empty fz_office_os schema.
-- Deletes no history. Does NOT change any M1 office status: an office activated through M7 stays active (M1 is the authority); deactivate first if wanted.
-- A re-apply re-seeds the template and restores the manager appointments from the archive.
\if :{?fz_in_txn}
\else
begin;
\endif
do $$
declare v_suffix text := to_char(clock_timestamp(), 'YYYYMMDDHH24MISSUS'); r text;
begin
  if to_regclass('fz_office_os.fz_office_profiles') is null then return; end if;
  insert into public.audit_log (actor, action, target, detail)
    select 'rollback', 'office_os_export', 'fz_office_profiles',
           jsonb_build_object('profiles', coalesce(jsonb_agg(jsonb_build_object('office', slug, 'status', status, 'manager_set', manager is not null,
                                                                                'activation_request', activation_request, 'activated_at', activated_at) order by slug), '[]'::jsonb))
      from fz_office_os.fz_office_profiles;
  create schema if not exists fz_archive;
  revoke all on schema fz_archive from public;
  foreach r in array array['anon', 'authenticated', 'service_role'] loop
    if exists (select 1 from pg_roles where rolname = r) then execute format('revoke all on schema fz_archive from %I', r); end if;
  end loop;
  if to_regclass('fz_archive.fz_office_profiles') is not null then          -- an older archive moves on (never overwritten)
    execute format('create schema if not exists %I', 'fz_archive_' || v_suffix);
    execute format('revoke all on schema %I from public', 'fz_archive_' || v_suffix);
    foreach r in array array['anon', 'authenticated', 'service_role'] loop
      if exists (select 1 from pg_roles where rolname = r) then execute format('revoke all on schema %I from %I', 'fz_archive_' || v_suffix, r); end if;
    end loop;
    execute format('alter table fz_archive.fz_office_profiles set schema %I', 'fz_archive_' || v_suffix);
    foreach r in array array['fz_office_decisions', 'fz_office_drift'] loop
      if to_regclass('fz_archive.' || r) is not null then execute format('alter table fz_archive.%I set schema %I', r, 'fz_archive_' || v_suffix); end if;
    end loop;
  end if;
  alter table fz_office_os.fz_office_profiles set schema fz_archive;
  foreach r in array array['fz_office_decisions', 'fz_office_drift'] loop
    if to_regclass('fz_office_os.' || r) is not null then
      if to_regclass('fz_archive.' || r) is not null then                 -- an older copy left by a rollback of an earlier version moves on too
        execute format('create schema if not exists %I', 'fz_archive_' || v_suffix);
        execute format('alter table fz_archive.%I set schema %I', r, 'fz_archive_' || v_suffix);
      end if;
      execute format('alter table fz_office_os.%I set schema fz_archive', r);
    end if;
  end loop;
end $$;
do $$ begin
  if exists (select 1 from pg_namespace where nspname = 'cron') then perform cron.unschedule(jobid) from cron.job where jobname = 'office-os-drift'; end if;
end $$;
drop function if exists public.office_os_status(text);
drop function if exists public.office_os_activate(text);
drop function if exists public.office_os_deactivate(text);
drop function if exists public.office_os_set_manager(text, text);
drop function if exists public.office_os_decide(text, text, boolean);
drop function if exists public.office_os_drift_check();
drop schema if exists fz_office_os;
\if :{?fz_in_txn}
\else
commit;
\endif
