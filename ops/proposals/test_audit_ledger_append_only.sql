-- Test of the PROPOSAL ops/proposals/audit_ledger_append_only.sql on a scratch replica (scripts/replica/run.sh state). Rolled back. NOT part of the gate (the proposal is not
-- applied by any migration). Run from the repo root:  psql -v ON_ERROR_STOP=1 -f ops/proposals/test_audit_ledger_append_only.sql
begin;
grant usage on schema public to service_role;
grant usage on sequence public.audit_log_id_seq to service_role;   -- as on Supabase (default sequence privileges)
create function pg_temp.svc(p_sql text) returns text language plpgsql as $$
declare r text;
begin
  set local role service_role;
  begin execute p_sql into r; exception when others then reset role; return 'ERR:' || sqlerrm; end;
  reset role;
  return 'OK:' || coalesce(r, '');
end $$;
-- a pg_cron stand-in with the production job (the replica stub has cron.job but no alter_job)
create schema if not exists cron;
create table if not exists cron.job (jobid serial, jobname text, schedule text, command text);
update cron.job set jobid = jobid + 1000 where jobid = 2 and jobname is distinct from 'hq-prune';
delete from cron.job where jobname = 'hq-prune';
insert into cron.job (jobid, jobname, schedule, command) values (2, 'hq-prune', '0 8 * * 0',
  'delete from public.audit_log where at < now() - interval ''90 days''; delete from public.agent_runs where started_at < now() - interval ''90 days''');
create or replace function cron.alter_job(job_id bigint, schedule text default null, command text default null, database text default null, username text default null, active boolean default null)
returns void language sql as $$ update cron.job set schedule = coalesce(alter_job.schedule, cron.job.schedule), command = coalesce(alter_job.command, cron.job.command) where jobid = job_id $$;
create temp table fzp_audit0 as select count(*) n from public.audit_log;
-- the proposal body (without its own begin / commit, so this transaction rolls it back)
revoke update, delete, truncate, references, trigger on public.audit_log, public.ledger from service_role, anon, authenticated;
do $$
declare r text;
begin
  foreach r in array array['fz_jarvis', 'fz_office_agent', 'fz_auditor', 'backup_reader'] loop
    if exists (select 1 from pg_roles where rolname = r) then
      execute format('revoke update, delete, truncate, references, trigger on public.audit_log, public.ledger from %I', r);
    end if;
  end loop;
end $$;
create or replace function public.fz_append_only_record() returns trigger
language plpgsql set search_path to 'pg_catalog' as $$
begin
  raise exception '% is append-only: rows are never changed or deleted (owner proposal audit_ledger_append_only)', tg_relname using errcode = '42501';
end $$;
revoke all on function public.fz_append_only_record() from public, anon, authenticated;
drop trigger if exists audit_log_append_only on public.audit_log;
create trigger audit_log_append_only before update or delete on public.audit_log for each row execute function public.fz_append_only_record();
drop trigger if exists audit_log_no_truncate on public.audit_log;
create trigger audit_log_no_truncate before truncate on public.audit_log for each statement execute function public.fz_append_only_record();
drop trigger if exists ledger_append_only on public.ledger;
create trigger ledger_append_only before update or delete on public.ledger for each row execute function public.fz_append_only_record();
drop trigger if exists ledger_no_truncate on public.ledger;
create trigger ledger_no_truncate before truncate on public.ledger for each statement execute function public.fz_append_only_record();
-- the weekly prune job deletes audit_log history: under the lock it would fail every Sunday, and deleting audit history is exactly what this proposal forbids.
-- hq-prune (jobid 2, '0 8 * * 0') keeps ONLY its agent_runs delete. Refuses (rolls everything back) if the job is not where we expect it.
do $$
declare j record;
begin
  if not exists (select 1 from pg_namespace where nspname = 'cron') then return; end if;
  select * into j from cron.job where jobname = 'hq-prune';
  if not found or j.jobid <> 2 or j.schedule <> '0 8 * * 0' then raise exception 'hq-prune is not jobid 2 / 0 8 * * 0: stop and check cron.job before applying'; end if;
  perform cron.alter_job(2, command := 'delete from public.agent_runs where started_at < now() - interval ''90 days''');
  if exists (select 1 from cron.job where command ilike '%audit_log%' or command ilike '%public.ledger%') then
    raise exception 'a cron job still touches audit_log / ledger: stop and check cron.job'; end if;
end $$;
insert into public.audit_log (actor, action, target, detail)
  values ('owner', 'audit_ledger_append_only_applied', 'audit_log,ledger',
          jsonb_build_object('proposal', 'ops/proposals/audit_ledger_append_only.sql', 'approved_by', 'owner', 'cron_hq_prune', 'agent_runs delete only'));
do $$
declare v uuid; r jsonb; n int;
begin
  -- the API role: insert yes, change / delete / truncate no
  if pg_temp.svc($q$insert into public.audit_log (actor, action, target, detail) values ('t', 'proposal_test', 't', '{}') returning id::text$q$) not like 'OK:%' then raise exception 'P1 insert into audit_log refused'; end if;
  if pg_temp.svc($q$insert into public.ledger (kind, amount_cents, status) values ('expense', 1, 'received') returning id::text$q$) not like 'OK:%' then raise exception 'P1 insert into ledger refused'; end if;
  foreach r in array array[to_jsonb('update public.audit_log set detail = ''{}'''::text), to_jsonb('delete from public.audit_log'::text), to_jsonb('truncate public.audit_log'::text),
                           to_jsonb('update public.ledger set amount_cents = 0'::text), to_jsonb('delete from public.ledger'::text), to_jsonb('truncate public.ledger'::text)] loop
    if pg_temp.svc(r #>> '{}') not like 'ERR:permission denied%' then raise exception 'P2 the service key ran: %', r; end if;
  end loop;
  -- even the table owner is refused (the owner would have to disable the trigger on purpose)
  begin update public.audit_log set detail = '{}' where action = 'proposal_test'; raise exception 'P3 owner update allowed'; exception when insufficient_privilege then null; end;
  begin delete from public.ledger where amount_cents = 1; raise exception 'P3 owner delete allowed'; exception when insufficient_privilege then null; end;
  -- the application's real write paths still work (they only insert)
  update public.system_state set mode = 'auto_in_caps', kill_switch = false where id = 1;
  r := public.reserve_spend('jarvis', 'routine_expense', 'proposal-test', 'proposal test', 'proposal test', 'none', 100);
  if r ->> 'decision' = 'allow' then
    if (public.settle_spend((r ->> 'reservation_id')::uuid, 90, 'receipt-1') ->> 'ok')::boolean is not true then raise exception 'P4 settle_spend failed under the proposal'; end if;
  end if;
  perform public.authorize_action('jarvis', 'research');
  update public.capital_policy set reinvest_pct = reinvest_pct, updated_by = 'owner:test' where id = 1;   -- audited policy change (inserts into audit_log)
  -- the prune job keeps only the agent_runs delete, same schedule; the owner approval is recorded; running the new command works under the lock
  if (select command || '|' || schedule from cron.job where jobid = 2) <> 'delete from public.agent_runs where started_at < now() - interval ''90 days''|0 8 * * 0' then
    raise exception 'P5 hq-prune not rewritten: %', (select command from cron.job where jobid = 2); end if;
  if exists (select 1 from cron.job where command ilike '%audit_log%') then raise exception 'P5 a cron job still deletes audit_log'; end if;
  execute (select command from cron.job where jobid = 2);
  insert into public.audit_log (actor, action, target, detail, at) values ('t', 'proposal_test_old', 't', '{}', now() - interval '200 days');
  begin delete from public.audit_log where at < now() - interval '90 days'; raise exception 'P5 the old prune still works'; exception when insufficient_privilege then null; end;
  if not exists (select 1 from public.audit_log where action = 'audit_ledger_append_only_applied' and actor = 'owner') then raise exception 'P6 owner approval not recorded'; end if;
  raise notice 'audit / ledger append-only proposal: all checks passed';
end $$;
rollback;
