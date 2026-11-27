-- Rollback of migrations/20261210_donna_revenue_loop_v1.sql (Donna Revenue Loop v1). Idempotent. Run from the repo root, BEFORE ops/rollback_donna_ops.sql:
--   psql -v ON_ERROR_STOP=1 -f ops/rollback_donna_revenue_loop.sql           (one transaction: it opens and commits its own)
-- (sqltests/donna_revenue_loop_check.sql sets fz_in_txn and runs it INSIDE its own rolled-back transaction.)
-- 1. ONE audit_log export row (counts); 2. ARCHIVES every fz_donna_rl table, rows intact, into fz_archive as donna_rl_<table> (an older archive moves to
-- fz_archive_<timestamp>); 3. drops this migration's seven functions and the empty schema.
-- Kept: leads it created or updated, outbox rows it staged (their status is the owner's decision record), audit_log rows, and the nullable outbox.subject column
-- (a column of a live table that hq_mail reads; removing it would break sending again).
\if :{?fz_in_txn}
\else
begin;
\endif
do $$
declare v_suffix text := to_char(clock_timestamp(), 'YYYYMMDDHH24MISSUS'); t text; r text; v_counts jsonb := '{}'::jsonb; n bigint; f text;
begin
  if to_regnamespace('fz_donna_rl') is null then
    foreach f in array array['donna_ingest_inbound(text, text, timestamptz, text, text, text, text, boolean, text, boolean, text, text, text)',
                           'donna_ingest_inbound(text, text, timestamptz, text, text, text, text, boolean, text, boolean, text, text, text, timestamptz)', 'donna_inbound_recent(integer)',
                             'donna_lead_context(uuid)', 'donna_stage_outbox(uuid, text)', 'donna_followups_due(integer)', 'donna_save_brief(uuid, uuid, text)', 'donna_revenue_queue(integer)'] loop
      if to_regprocedure('public.' || f) is not null then execute 'drop function public.' || f; end if;
    end loop;
    return;
  end if;
  foreach t in array array['briefs', 'staged', 'inbound'] loop
    if to_regclass('fz_donna_rl.' || t) is not null then execute format('select count(*) from fz_donna_rl.%I', t) into n; v_counts := v_counts || jsonb_build_object(t, n); end if;
  end loop;
  insert into public.audit_log (actor, action, target, detail) values ('rollback', 'donna_revenue_loop_export', 'fz_donna_rl', v_counts);
  create schema if not exists fz_archive;
  revoke all on schema fz_archive from public;
  foreach r in array array['anon', 'authenticated', 'service_role'] loop
    if exists (select 1 from pg_roles where rolname = r) then execute format('revoke all on schema fz_archive from %I', r); end if;
  end loop;
  foreach t in array array['briefs', 'staged', 'inbound'] loop
    continue when to_regclass('fz_donna_rl.' || t) is null;
    if to_regclass('fz_archive.donna_rl_' || t) is not null then
      execute format('create schema if not exists %I', 'fz_archive_' || v_suffix);
      execute format('revoke all on schema %I from public', 'fz_archive_' || v_suffix);
      execute format('alter table fz_archive.%I set schema %I', 'donna_rl_' || t, 'fz_archive_' || v_suffix);
    end if;
    execute format('alter table fz_donna_rl.%I rename to %I', t, 'donna_rl_' || t);
    execute format('alter table fz_donna_rl.%I set schema fz_archive', 'donna_rl_' || t);
  end loop;
  foreach f in array array['donna_ingest_inbound(text, text, timestamptz, text, text, text, text, boolean, text, boolean, text, text, text)',
                           'donna_ingest_inbound(text, text, timestamptz, text, text, text, text, boolean, text, boolean, text, text, text, timestamptz)', 'donna_inbound_recent(integer)',
                           'donna_lead_context(uuid)', 'donna_stage_outbox(uuid, text)', 'donna_followups_due(integer)', 'donna_save_brief(uuid, uuid, text)', 'donna_revenue_queue(integer)'] loop
    if to_regprocedure('public.' || f) is not null then execute 'drop function public.' || f; end if;
  end loop;
  drop schema fz_donna_rl;
end $$;
\if :{?fz_in_txn}
\else
commit;
\endif
