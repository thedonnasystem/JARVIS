-- Rollback of migrations/20261129_approvals_kernel_v1.sql (FENDEZY GROUP Phase 1, M3 "Approvals kernel + office wiring"). Idempotent. Run from the repo root:
--   psql -v ON_ERROR_STOP=1 -f ops/rollback_approvals_kernel.sql          (one transaction: it opens and commits its own)
-- (the sqltests set fz_in_txn and run it INSIDE their own rolled-back transaction.)
-- Order: BEFORE ops/rollback_office_money.sql (M3 reads M2's proposals table).
-- 0. keeps the record: a snapshot of the queue (every row, metadata only) goes into ONE audit_log row; unschedules the expiry job;
-- 1. drops the view, the proposal audit trigger and the three functions.
-- Destroys nothing: M3 owns no table and no data. Requests, proposals, decisions and audit rows stay as they are. Set FZ_OFFICE_SPEND_GATE back to 0 (or remove it)
-- in Railway first if it was turned on: with the gate function gone, the bot's office payment path refuses (fails closed) until then.
\if :{?fz_in_txn}
\else
begin;
\endif
do $$
begin
  if to_regclass('public.fz_approval_queue') is not null then
    insert into public.audit_log (actor, action, target, detail)
      select 'rollback', 'approval_queue_export', 'fz_approval_queue',
             jsonb_build_object('rows', coalesce(jsonb_agg(to_jsonb(q) order by q.created_at), '[]'::jsonb)) from public.fz_approval_queue q;
  end if;
  if exists (select 1 from pg_namespace where nspname = 'cron') then
    perform cron.unschedule(jobid) from cron.job where jobname = 'fz-queue-expire';
  end if;
  if to_regclass('public.fz_office_money_proposals') is not null then
    drop trigger if exists fz_office_money_proposals_audit on public.fz_office_money_proposals;
  end if;
end $$;
drop view if exists public.fz_approval_queue;
drop function if exists public.fz_prepare_office_payment(text, text, integer, text, text, date, text), public.fz_queue_expire(integer), public.fz_queue_audit_proposal();
\if :{?fz_in_txn}
\else
commit;
\endif
