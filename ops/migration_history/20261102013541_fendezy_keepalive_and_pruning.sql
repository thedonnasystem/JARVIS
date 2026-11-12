
create extension if not exists pg_cron with schema pg_catalog;

select cron.schedule('hq-heartbeat', '0 12 * * *',
  $$update public.system_state set last_heartbeat = now() where id = 1$$);

select cron.schedule('hq-prune', '0 8 * * 0',
  $$delete from public.audit_log where at < now() - interval '90 days';
    delete from public.agent_runs where started_at < now() - interval '90 days'$$);
