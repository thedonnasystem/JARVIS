-- Rollback of migrations/20261211_donna_client_agents_v1.sql. Idempotent. Run BEFORE ops/rollback_donna_revenue_loop.sql and ops/rollback_donna_ops.sql:
--   psql -v ON_ERROR_STOP=1 -f ops/rollback_donna_client_agents.sql      (one transaction; sqltests set fz_in_txn and run it inside theirs)
-- One audit_log export row; the two tables ARCHIVED with their rows into fz_archive as donna_ca_<table>; the four functions and the schema dropped.
-- The Retell agents themselves stay on the owner's Retell account (delete them there if wanted); their ids are in the archive.
\if :{?fz_in_txn}
\else
begin;
\endif
do $$
declare v_suffix text := to_char(clock_timestamp(), 'YYYYMMDDHH24MISSUS'); t text; r text; v_counts jsonb := '{}'::jsonb; n bigint; f text;
  fns text[] := array['donna_intake_for_agent(text)', 'donna_record_client_agent(uuid, text, text, text)', 'donna_client_agents()', 'donna_record_client_report(uuid, text, uuid, jsonb)'];
begin
  if to_regnamespace('fz_donna_ca') is not null then
    foreach t in array array['reports', 'agents'] loop
      if to_regclass('fz_donna_ca.' || t) is not null then execute format('select count(*) from fz_donna_ca.%I', t) into n; v_counts := v_counts || jsonb_build_object(t, n); end if;
    end loop;
    insert into public.audit_log (actor, action, target, detail) values ('rollback', 'donna_client_agents_export', 'fz_donna_ca', v_counts);
    create schema if not exists fz_archive;
    revoke all on schema fz_archive from public;
    foreach r in array array['anon', 'authenticated', 'service_role'] loop
      if exists (select 1 from pg_roles where rolname = r) then execute format('revoke all on schema fz_archive from %I', r); end if;
    end loop;
    foreach t in array array['reports', 'agents'] loop
      continue when to_regclass('fz_donna_ca.' || t) is null;
      if to_regclass('fz_archive.donna_ca_' || t) is not null then
        execute format('create schema if not exists %I', 'fz_archive_' || v_suffix);
        execute format('revoke all on schema %I from public', 'fz_archive_' || v_suffix);
        execute format('alter table fz_archive.%I set schema %I', 'donna_ca_' || t, 'fz_archive_' || v_suffix);
      end if;
      execute format('alter table fz_donna_ca.%I rename to %I', t, 'donna_ca_' || t);
      execute format('alter table fz_donna_ca.%I set schema fz_archive', 'donna_ca_' || t);
    end loop;
  end if;
  foreach f in array fns loop
    if to_regprocedure('public.' || f) is not null then execute 'drop function public.' || f; end if;
  end loop;
  if to_regnamespace('fz_donna_ca') is not null then drop schema fz_donna_ca; end if;
end $$;
\if :{?fz_in_txn}
\else
commit;
\endif
