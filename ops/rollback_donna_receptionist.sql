-- Rollback of migrations/20261206_donna_receptionist_v1.sql (Donna Receptionist v1). Idempotent. Run from the repo root:
--   psql -v ON_ERROR_STOP=1 -f ops/rollback_donna_receptionist.sql           (one transaction: it opens and commits its own)
-- (sqltests/donna_receptionist_check.sql sets fz_in_txn and runs it INSIDE its own rolled-back transaction.)
-- 1. ONE audit_log export row (counts); 2. ARCHIVES every fz_reception table, rows intact, into fz_archive (an older archive moves to fz_archive_<timestamp>);
-- 3. drops the reception_* functions, the helpers and the empty schema. Leads, consent rows and withdrawals stay in the CRM (they were never ours to remove).
\if :{?fz_in_txn}
\else
begin;
\endif
do $$
declare v_suffix text := to_char(clock_timestamp(), 'YYYYMMDDHH24MISSUS'); t text; r text; v_counts jsonb := '{}'::jsonb; n bigint; f regprocedure;
begin
  if to_regnamespace('fz_reception') is null then return; end if;
  foreach t in array array['messages', 'calls', 'clients'] loop
    if to_regclass('fz_reception.' || t) is not null then execute format('select count(*) from fz_reception.%I', t) into n; v_counts := v_counts || jsonb_build_object(t, n); end if;
  end loop;
  insert into public.audit_log (actor, action, target, detail) values ('rollback', 'reception_export', 'fz_reception', v_counts);
  create schema if not exists fz_archive;
  revoke all on schema fz_archive from public;
  foreach r in array array['anon', 'authenticated', 'service_role'] loop
    if exists (select 1 from pg_roles where rolname = r) then execute format('revoke all on schema fz_archive from %I', r); end if;
  end loop;
  foreach t in array array['messages', 'calls', 'clients'] loop
    continue when to_regclass('fz_reception.' || t) is null;
    if to_regclass('fz_archive.reception_' || t) is not null then
      execute format('create schema if not exists %I', 'fz_archive_' || v_suffix);
      execute format('revoke all on schema %I from public', 'fz_archive_' || v_suffix);
      execute format('alter table fz_archive.%I set schema %I', 'reception_' || t, 'fz_archive_' || v_suffix);
    end if;
    execute format('alter table fz_reception.%I rename to %I', t, 'reception_' || t);
    execute format('alter table fz_reception.%I set schema fz_archive', 'reception_' || t);
  end loop;
  for f in select p.oid::regprocedure from pg_proc p where p.pronamespace = 'public'::regnamespace and p.proname like 'reception\_%' loop
    execute format('drop function %s', f);
  end loop;
  for f in select p.oid::regprocedure from pg_proc p where p.pronamespace = 'fz_reception'::regnamespace loop
    execute format('drop function %s', f);
  end loop;
  drop schema fz_reception;
end $$;
\if :{?fz_in_txn}
\else
commit;
\endif
