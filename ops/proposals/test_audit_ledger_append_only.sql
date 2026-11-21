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
  raise notice 'audit / ledger append-only proposal: all checks passed';
end $$;
rollback;
