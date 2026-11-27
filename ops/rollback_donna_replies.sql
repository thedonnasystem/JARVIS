-- Rollback of migrations/20261212_donna_replies_v1.sql. Idempotent. Run BEFORE ops/rollback_donna_ops.sql:
--   psql -v ON_ERROR_STOP=1 -f ops/rollback_donna_replies.sql        (one transaction; sqltests set fz_in_txn and run it inside theirs)
-- One audit_log export row; fz_donna_rp.seen ARCHIVED with its rows into fz_archive.donna_rp_seen; the function and the schema dropped.
-- Kept: lead statuses it set and do-not-contact marks (the suppression list is append-only by design).
\if :{?fz_in_txn}
\else
begin;
\endif
do $$
declare v_suffix text := to_char(clock_timestamp(), 'YYYYMMDDHH24MISSUS'); r text; n bigint;
begin
  if to_regnamespace('fz_donna_rp') is not null then
    if to_regclass('fz_donna_rp.seen') is not null then
      select count(*) into n from fz_donna_rp.seen;
      insert into public.audit_log (actor, action, target, detail) values ('rollback', 'donna_replies_export', 'fz_donna_rp', jsonb_build_object('seen', n));
      create schema if not exists fz_archive;
      revoke all on schema fz_archive from public;
      foreach r in array array['anon', 'authenticated', 'service_role'] loop
        if exists (select 1 from pg_roles where rolname = r) then execute format('revoke all on schema fz_archive from %I', r); end if;
      end loop;
      if to_regclass('fz_archive.donna_rp_seen') is not null then
        execute format('create schema if not exists %I', 'fz_archive_' || v_suffix);
        execute format('revoke all on schema %I from public', 'fz_archive_' || v_suffix);
        execute format('alter table fz_archive.donna_rp_seen set schema %I', 'fz_archive_' || v_suffix);
      end if;
      alter table fz_donna_rp.seen rename to donna_rp_seen;
      alter table fz_donna_rp.donna_rp_seen set schema fz_archive;
    end if;
  end if;
  if to_regprocedure('public.donna_record_email_reply(text, text, timestamptz, boolean)') is not null then
    drop function public.donna_record_email_reply(text, text, timestamptz, boolean);
  end if;
  if to_regprocedure('public.donna_unseen_messages(text[])') is not null then drop function public.donna_unseen_messages(text[]); end if;
  if to_regnamespace('fz_donna_rp') is not null then drop schema fz_donna_rp; end if;
end $$;
\if :{?fz_in_txn}
\else
commit;
\endif
