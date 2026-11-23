-- Rollback of migrations/20261207_donna_ops_v1.sql (Donna Ops v1). Idempotent. Run from the repo root, BEFORE rolling back Donna Receptionist v1:
--   psql -v ON_ERROR_STOP=1 -f ops/rollback_donna_ops.sql           (one transaction: it opens and commits its own)
-- (sqltests/donna_ops_check.sql sets fz_in_txn and runs it INSIDE its own rolled-back transaction.)
-- 1. ONE audit_log export row (counts); 2. ARCHIVES every fz_donna table, rows intact, into fz_archive as donna_ops_<table> (an older archive moves to
-- fz_archive_<timestamp>); 3. unschedules the weekly report; 4. drops the donna_* functions, the helpers and the empty schema.
-- Leads, deals, client workspaces, receptionist clients, consent rows and owner_messages stay where they are (they were never this migration's to remove).
\if :{?fz_in_txn}
\else
begin;
\endif
do $$
declare v_suffix text := to_char(clock_timestamp(), 'YYYYMMDDHH24MISSUS'); t text; r text; v_counts jsonb := '{}'::jsonb; n bigint; f regprocedure;
begin
  if to_regnamespace('fz_donna') is null then return; end if;
  foreach t in array array['reports', 'golive', 'intakes', 'drafts', 'runs', 'mission_actions'] loop
    if to_regclass('fz_donna.' || t) is not null then execute format('select count(*) from fz_donna.%I', t) into n; v_counts := v_counts || jsonb_build_object(t, n); end if;
  end loop;
  insert into public.audit_log (actor, action, target, detail) values ('rollback', 'donna_ops_export', 'fz_donna', v_counts);
  if exists (select 1 from pg_namespace where nspname = 'cron') then
    perform cron.unschedule(jobid) from cron.job where jobname = 'donna-weekly-report';
  end if;
  create schema if not exists fz_archive;
  revoke all on schema fz_archive from public;
  foreach r in array array['anon', 'authenticated', 'service_role'] loop
    if exists (select 1 from pg_roles where rolname = r) then execute format('revoke all on schema fz_archive from %I', r); end if;
  end loop;
  foreach t in array array['reports', 'golive', 'intakes', 'drafts', 'runs', 'mission_actions'] loop
    continue when to_regclass('fz_donna.' || t) is null;
    if to_regclass('fz_archive.donna_ops_' || t) is not null then
      execute format('create schema if not exists %I', 'fz_archive_' || v_suffix);
      execute format('revoke all on schema %I from public', 'fz_archive_' || v_suffix);
      execute format('alter table fz_archive.%I set schema %I', 'donna_ops_' || t, 'fz_archive_' || v_suffix);
    end if;
    execute format('alter table fz_donna.%I rename to %I', t, 'donna_ops_' || t);
    execute format('alter table fz_donna.%I set schema fz_archive', 'donna_ops_' || t);
  end loop;
  for f in select p.oid::regprocedure from pg_proc p where p.pronamespace = 'public'::regnamespace and p.proname like 'donna\_%' loop
    execute format('drop function %s', f);
  end loop;
  for f in select p.oid::regprocedure from pg_proc p where p.pronamespace = 'fz_donna'::regnamespace loop
    execute format('drop function %s', f);
  end loop;
  drop schema fz_donna;
end $$;
\if :{?fz_in_txn}
\else
commit;
\endif
