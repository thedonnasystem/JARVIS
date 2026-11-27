-- Rollback of migrations/20261213_donna_nudges_v1.sql. Idempotent. Run BEFORE ops/rollback_donna_replies.sql:
--   psql -v ON_ERROR_STOP=1 -f ops/rollback_donna_nudges.sql        (one transaction; sqltests set fz_in_txn and run it inside theirs)
-- The migration only added one read-only function, so the rollback drops it. No data to archive.
\if :{?fz_in_txn}
\else
begin;
\endif
do $$
begin
  if to_regprocedure('public.donna_stuck_deals(integer)') is not null then
    drop function public.donna_stuck_deals(integer);
    insert into public.audit_log (actor, action, target, detail) values ('rollback', 'donna_nudges_rollback', 'public.donna_stuck_deals', '{}'::jsonb);
  end if;
end $$;
\if :{?fz_in_txn}
\else
commit;
\endif
