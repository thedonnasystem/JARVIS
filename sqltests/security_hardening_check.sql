-- Security hardening M4 (migrations/20261130_security_hardening_v1.sql). ONE transaction, rolled back. Run on a fresh apply from the repo root (scripts/replica/run.sh does).
-- Proves: money controls unchanged (fingerprint with M4 == after rollback == after re-apply); the audit hash chain detects a changed, deleted or late-inserted audit row and an
-- edited chain, and is append-only; the watch alerts the owner's own chat ONCE per chain break / new privileged grant (never a call); the report lists privileged grants,
-- definer functions without search_path, RLS-off tables, identities and tokens near expiry, read-only and owner/service only; owner-only acknowledge / token registry;
-- the rollback archives (loses no row).
begin;
grant usage on schema public to anon, authenticated, service_role;
create function pg_temp.as_id(p_role text, p_claims jsonb, p_sql text) returns text language plpgsql as $$
declare r text; u text := current_setting('app.uid', true);
begin
  perform set_config('app.uid', '', true);
  perform set_config('request.jwt.claims', coalesce(p_claims::text, ''), true);
  execute format('set local role %I', p_role);
  begin execute p_sql into r;
  exception when others then reset role; perform set_config('request.jwt.claims', '', true); perform set_config('app.uid', coalesce(u, ''), true); return 'ERR:' || sqlerrm; end;
  reset role;
  perform set_config('request.jwt.claims', '', true);
  perform set_config('app.uid', coalesce(u, ''), true);
  return 'OK:' || coalesce(r, '');
end $$;
create function pg_temp.cl(p_identity text, p_role text, p_extra jsonb default '{}'::jsonb) returns jsonb language sql as $$
  select jsonb_build_object('role', p_role, 'identity', p_identity, 'iat', floor(extract(epoch from now())), 'exp', floor(extract(epoch from now())) + 3600) || p_extra
$$;
create function pg_temp.svc(p_sql text) returns text language plpgsql as $$
declare r text; u text := current_setting('app.uid', true);
begin
  perform set_config('app.uid', '', true);
  set local role service_role;
  begin execute p_sql into r; exception when others then reset role; perform set_config('app.uid', coalesce(u, ''), true); return 'ERR:' || sqlerrm; end;
  reset role;
  perform set_config('app.uid', coalesce(u, ''), true);
  return 'OK:' || coalesce(r, '');
end $$;
\ir include/money_fingerprint.sql

create function pg_temp.noowner(p_sql text) returns text language plpgsql as $$
declare r text; u text := current_setting('app.uid', true);
begin
  perform set_config('app.uid', '', true);
  begin execute p_sql into r; exception when others then perform set_config('app.uid', coalesce(u, ''), true); return 'ERR:' || sqlerrm; end;
  perform set_config('app.uid', coalesce(u, ''), true);
  return 'OK:' || coalesce(r, '');
end $$;
insert into auth.users (id, email) values ('99999999-9999-9999-9999-99999999f004', 'fzs-owner@example.invalid') on conflict do nothing;
insert into public.app_owners (email) values ('fzs-owner@example.invalid') on conflict do nothing;
select set_config('app.uid', '99999999-9999-9999-9999-99999999f004', true);

-- S1 money controls unchanged: with M4 == after its rollback (twice) == after re-applying it
\set fz_in_txn 1
create temp table fzs_fp_with as select * from pg_temp.fz_money_fp();
\ir ../ops/rollback_security_hardening.sql
\ir ../ops/rollback_security_hardening.sql
create temp table fzs_fp_without as select * from pg_temp.fz_money_fp();
do $$
begin
  if to_regclass('public.fz_audit_chain') is not null or exists (select 1 from pg_proc where proname in ('fz_audit_verify', 'fz_security_watch', 'fz_security_report'))
     or exists (select 1 from cron.job where jobname = 'fz-security-watch') then raise exception 'S1 the rollback left M4 objects behind'; end if;
  if to_regclass('public.fz_office_money') is null or to_regclass('public.fz_approval_queue') is null then raise exception 'S1 the rollback damaged M2 / M3'; end if;
  if public.backup_export_policy() -> 'unclassified' <> '[]'::jsonb then raise exception 'S1 unclassified after the rollback'; end if;
  if exists (select 1 from fzs_fp_with w full join fzs_fp_without o using (k) where w.v is distinct from o.v) then
    raise exception 'S1 the money controls differ with and without M4: %', (select string_agg(coalesce(w.k, o.k), ', ') from fzs_fp_with w full join fzs_fp_without o using (k) where w.v is distinct from o.v); end if;
end $$;
\ir ../migrations/20261130_security_hardening_v1.sql
create temp table fzs_fp_again as select * from pg_temp.fz_money_fp();
do $$
begin
  if exists (select 1 from fzs_fp_again w full join fzs_fp_without o using (k) where w.v is distinct from o.v) then raise exception 'S1 applying M4 changed the money controls'; end if;
end $$;

do $$
declare cj jsonb; ca jsonb; v jsonb; w jsonb; n int; n2 int; h bigint; res text; d jsonb; mid bigint;
begin
  cj := pg_temp.cl('jarvis', 'fz_jarvis');
  perform public.fz_owner_set_office_status('b2b-records', 'active');
  perform public.fz_owner_set_identity('office:b2b-records:manager', 'active');
  ca := pg_temp.cl('office:b2b-records:manager', 'fz_office_agent');
  -- S2 the chain: aged audit rows are chained (fresh ones wait 5 minutes); verify is clean
  insert into public.audit_log (actor, action, target, detail, at) select 'fzs', 'fzs_fixture', 'fzs/' || g, jsonb_build_object('n', g), now() - interval '1 hour' + make_interval(secs => g) from generate_series(1, 20) g;
  select id into mid from public.audit_log where action = 'fzs_fixture' order by id offset 9 limit 1;
  delete from public.audit_log where id = mid;                            -- a gap below the future head (used for the late-insert check)
  insert into public.audit_log (actor, action, target, detail) values ('fzs', 'fzs_fresh', 'fzs/fresh', '{}');
  update public.audit_log set at = least(at, now() - interval '10 minutes') where action <> 'fzs_fresh';   -- everything before the fixtures is old enough (rolled back)
  if pg_temp.svc('select public.fz_audit_chain_extend()::text') !~ '^OK:[1-9]' then raise exception 'S2 nothing chained'; end if;
  if exists (select 1 from public.fz_audit_chain c join public.audit_log a on a.id = c.audit_id where a.action = 'fzs_fresh') then raise exception 'S2 a fresh row was chained (late commits would look inserted)'; end if;
  v := public.fz_audit_verify();
  if not (v ->> 'ok')::boolean or (v ->> 'checked')::int < 20 then raise exception 'S2 clean chain does not verify: %', v; end if;
  if pg_temp.svc('select public.fz_audit_chain_extend()::text') <> 'OK:0' then raise exception 'S2 extend not idempotent'; end if;
  select max(audit_id) into h from public.fz_audit_chain;
  -- each tamper in its own undone sub-transaction
  begin update public.audit_log set detail = '{"n": 999}' where id = (select audit_id from public.fz_audit_chain order by seq desc offset 3 limit 1); v := public.fz_audit_verify(); raise exception using errcode = 'ZFZ01';
  exception when sqlstate 'ZFZ01' then null; end;
  if (v ->> 'ok')::boolean or v -> 'breaks' -> 0 ->> 'problem' <> 'changed' then raise exception 'S2 a changed audit row was not detected: %', v; end if;
  begin delete from public.audit_log where id = (select audit_id from public.fz_audit_chain order by seq desc offset 5 limit 1); v := public.fz_audit_verify(); raise exception using errcode = 'ZFZ01';
  exception when sqlstate 'ZFZ01' then null; end;
  if (v ->> 'ok')::boolean or v -> 'breaks' -> 0 ->> 'problem' <> 'deleted' then raise exception 'S2 a deleted audit row was not detected: %', v; end if;
  begin
    alter table public.fz_audit_chain disable trigger fz_audit_chain_append_only;
    update public.fz_audit_chain set row_hash = repeat('0', 64) where seq = (select max(seq) - 2 from public.fz_audit_chain);
    v := public.fz_audit_verify(); raise exception using errcode = 'ZFZ01';
  exception when sqlstate 'ZFZ01' then null; end;
  if (v ->> 'ok')::boolean or not (v -> 'breaks') @> '[{"problem": "chain_edited"}]' then raise exception 'S2 an edited chain was not detected: %', v; end if;
  -- the chain is append-only (even for the table owner) and nobody but the service path reads it
  begin update public.fz_audit_chain set row_hash = 'x'; raise exception 'S2 chain updatable'; exception when insufficient_privilege then null; end;
  begin delete from public.fz_audit_chain; raise exception 'S2 chain deletable'; exception when insufficient_privilege then null; end;
  if pg_temp.svc($q$insert into public.fz_audit_chain (audit_id, row_hash, chain_hash) values (-1, 'x', 'x')$q$) not like 'ERR:permission denied%' then raise exception 'S2 the bot writes the chain'; end if;
  foreach res in array array['fz_jarvis', 'fz_office_agent', 'fz_auditor', 'anon', 'authenticated'] loop
    if pg_temp.as_id(res, cj, 'select count(*)::text from public.fz_audit_chain') not like 'ERR:permission denied%' then raise exception 'S2 % reads the chain', res; end if;
    if exists (select 1 from pg_proc p where p.pronamespace = 'public'::regnamespace and p.proname in ('fz_audit_chain_extend', 'fz_audit_verify', 'fz_privileged_items', 'fz_security_alert',
                'fz_security_watch', 'fz_owner_ack_security', 'fz_owner_register_token', 'fz_security_report', 'fz_audit_row_hash', 'fz_audit_link') and has_function_privilege(res, p.oid, 'execute')) then
      raise exception 'S2 % executes an M4 function', res; end if;
  end loop;
  -- an audit row inserted later with an id below the head
  begin
    insert into public.audit_log (id, actor, action, target, detail, at) values (mid, 'x', 'late insert', 'x', '{}', now() - interval '2 hours');
    v := public.fz_audit_verify(); raise exception using errcode = 'ZFZ01';
  exception when sqlstate 'ZFZ01' then null; end;
  if (v ->> 'ok')::boolean or not (v -> 'breaks') @> '[{"problem": "unchained"}]' then raise exception 'S2 a late-inserted audit row was not detected: %', v; end if;

  -- S3 the watch: first run takes the baseline (no alert); a NEW privileged grant alerts the owner's own chat once; a chain break alerts once; never an emergency call
  select count(*) into n from public.owner_messages;
  w := public.fz_security_watch();
  if not (w ->> 'baseline_taken')::boolean or (w ->> 'alerts_sent')::int <> 0 then raise exception 'S3 first run: %', w; end if;
  if pg_temp.svc('select (public.fz_security_watch() ->> ''alerts_sent'')') <> 'OK:0' then raise exception 'S3 a quiet run alerted'; end if;
  grant delete on public.memory to fz_jarvis;
  w := public.fz_security_watch();
  if (w ->> 'alerts_sent')::int <> 1 or not exists (select 1 from public.fz_security_alerts where kind = 'new_privilege' and item = 'table:memory:fz_jarvis:DELETE') then raise exception 'S3 new grant not alerted: %', w; end if;
  if (select count(*) from public.owner_messages) <> n + 1 or not exists (select 1 from public.owner_messages where kind = 'health' and channel = 'telegram' and body like 'SECURITY: a new privileged grant appeared: table:memory:fz_jarvis:DELETE%') then
    raise exception 'S3 owner not told in Telegram'; end if;
  if (public.fz_security_watch() ->> 'alerts_sent')::int <> 0 then raise exception 'S3 the same grant alerted twice'; end if;
  revoke delete on public.memory from fz_jarvis;
  grant execute on function public.fz_money_report() to authenticated;            -- a definer function opened to the app role
  if (public.fz_security_watch() ->> 'alerts_sent')::int <> 1 then raise exception 'S3 definer grant not alerted'; end if;
  revoke execute on function public.fz_money_report() from authenticated;
  update public.audit_log set detail = '{"tampered": true}' where id = (select audit_id from public.fz_audit_chain order by seq desc offset 2 limit 1);
  w := public.fz_security_watch();
  if (w ->> 'chain_ok')::boolean or (w ->> 'alerts_sent')::int <> 1 or not exists (select 1 from public.owner_messages where body like 'SECURITY: the audit log hash chain is broken%') then raise exception 'S3 chain break not alerted: %', w; end if;
  if (public.fz_security_watch() ->> 'alerts_sent')::int <> 0 then raise exception 'S3 the chain break alerted twice'; end if;
  if exists (select 1 from public.owner_messages where kind = 'emergency' and created_at >= now() and body like 'SECURITY%') then raise exception 'S3 a security alert can trigger a call'; end if;
  begin update public.fz_security_alerts set item = 'x'; raise exception 'S3 alerts updatable'; exception when insufficient_privilege then null; end;
  if pg_temp.as_id('fz_jarvis', cj, 'select public.fz_security_watch()::text') not like 'ERR:permission denied%' then raise exception 'S3 scoped watch'; end if;

  -- S4 the report: read-only, service / owner only; lists what it should
  create function public.fzs_bad_definer() returns int language sql security definer as $f$ select 1 $f$;
  create table public.fzs_rls_off (id int);
  perform public.fz_owner_register_token('office:b2b-records:manager', 'jti-soon', now() + interval '3 days', 'drill');
  perform public.fz_owner_register_token('auditor', 'jti-later', now() + interval '90 days', 'drill');
  if pg_temp.svc($q$select public.fz_owner_register_token('jarvis', 'jti-bot', now() + interval '3 days')::text$q$) not like 'ERR:%' then raise exception 'S4 the bot registered a token'; end if;
  if pg_temp.svc($q$insert into public.fz_token_registry (jti, identity, expires_at) values ('jti-bot2', 'jarvis', now() + interval '3 days')$q$) not like 'ERR:permission denied%' then raise exception 'S4 the bot inserts tokens'; end if;
  if pg_temp.noowner($q$insert into public.fz_token_registry (jti, identity, expires_at) values ('jti-bot3', 'jarvis', now() + interval '3 days')$q$) not like 'ERR:owner approval required%' then raise exception 'S4 the table accepted a non-owner token'; end if;
  d := public.fz_security_report();
  if not (d -> 'definer_without_search_path') ? 'public.fzs_bad_definer()' then raise exception 'S4 definer without search_path not reported'; end if;
  if not (d -> 'rls_off') ? 'fzs_rls_off' then raise exception 'S4 RLS-off table not reported'; end if;
  if jsonb_array_length(d -> 'tokens_expiring') <> 1 or d -> 'tokens_expiring' -> 0 ->> 'identity' <> 'office:b2b-records:manager' then raise exception 'S4 tokens near expiry: %', d -> 'tokens_expiring'; end if;
  if not exists (select 1 from jsonb_array_elements(d -> 'identities') e where e ->> 'identity' = 'office:b2b-records:manager' and e ->> 'status' = 'active') then raise exception 'S4 identities'; end if;
  if (d -> 'chain' ->> 'ok')::boolean then raise exception 'S4 the report hides the chain break'; end if;
  if jsonb_array_length(d -> 'privileged') < 1 or jsonb_array_length(d -> 'alerts') < 3 then raise exception 'S4 privileged / alerts missing'; end if;
  if pg_temp.svc('select (public.fz_security_report() ? ''privileged'')::text') <> 'OK:true' then raise exception 'S4 the bot cannot read the report'; end if;
  foreach res in array array['fz_jarvis', 'fz_office_agent', 'anon', 'authenticated'] loop
    if pg_temp.as_id(res, case when res like 'fz%' then cj else ca end, 'select public.fz_security_report()::text') not like 'ERR:permission denied%' then raise exception 'S4 % reads the report', res; end if;
  end loop;
  grant execute on function public.fz_security_report(integer) to fz_jarvis;
  if pg_temp.as_id('fz_jarvis', cj, 'select public.fz_security_report()::text') not like 'ERR:the security report is for the owner%' then raise exception 'S4 scoped report with a mistaken grant'; end if;
  revoke execute on function public.fz_security_report(integer) from fz_jarvis;
  drop function public.fzs_bad_definer(); drop table public.fzs_rls_off;
  -- S5 owner-only acknowledge
  if pg_temp.svc($q$select public.fz_owner_ack_security('table:memory:fz_jarvis:DELETE')::text$q$) not like 'ERR:owner approval required%' then raise exception 'S5 the bot acknowledged'; end if;
  perform public.fz_owner_ack_security('table:memory:fz_jarvis:DELETE');
  if (select status from public.fz_security_baseline where item = 'table:memory:fz_jarvis:DELETE') <> 'acknowledged' then raise exception 'S5 acknowledge'; end if;
  if pg_temp.svc($q$insert into public.fz_security_baseline (item) values ('x')$q$) not like 'ERR:permission denied%' then raise exception 'S5 the bot writes the baseline'; end if;
  -- S6 registry, backup, money tables untouched
  if exists (select 1 from public.fz_unregistered_tables()) or public.backup_export_policy() -> 'unclassified' <> '[]'::jsonb then raise exception 'S6 registry / backup'; end if;
  if (select count(*) from public.backup_classification() where table_name in ('fz_audit_chain', 'fz_security_baseline', 'fz_security_alerts', 'fz_token_registry') and data_class = 'secret') <> 4 then raise exception 'S6 classes'; end if;
  if (select string_agg(g.tgrelid::regclass::text || '.' || g.tgname, ' ' order by g.tgrelid::regclass::text, g.tgname) from pg_trigger g where not g.tgisinternal and g.tgrelid::regclass::text in
        ('ledger', 'llm_calls', 'spend_reservations', 'capital_policy', 'action_policy', 'system_state', 'approval_requests', 'action_log', 'audit_log', 'bank_accounts', 'bank_balances',
         'bank_transactions', 'payment_instructions', 'waterfall_policy', 'model_prices', 'tool_registry', 'executor_registry', 'executor_runs'))
     <> 'action_policy.action_policy_audit action_policy.action_policy_no_delete bank_balances.bank_balance_guard capital_policy.capital_policy_guard llm_calls.llm_calls_executor_guard waterfall_policy.waterfall_policy_guard' then
    raise exception 'S6 the triggers on the money / audit tables changed'; end if;
  if not exists (select 1 from cron.job where jobname = 'fz-security-watch') then raise exception 'S6 watch not scheduled'; end if;
  raise notice 'security_hardening_check: behaviour checks passed';
end $$;

-- S7 the rollback archives: no chain / alert / baseline / token row lost, money controls unchanged
create temp table fzs_rows as select (select count(*) from public.fz_audit_chain) c, (select count(*) from public.fz_security_alerts) a, (select count(*) from public.fz_security_baseline) b, (select count(*) from public.fz_token_registry) t;
create temp table fzs_fp_test as select * from pg_temp.fz_money_fp();
\ir ../ops/rollback_security_hardening.sql
create temp table fzs_fp_test_without as select * from pg_temp.fz_money_fp();
do $$
begin
  if exists (select 1 from fzs_fp_test w full join fzs_fp_test_without o using (k) where w.v is distinct from o.v) then raise exception 'S7 the rollback changed the money controls'; end if;
  if (select c from fzs_rows) < 20 or (select c from fzs_rows) <> (select count(*) from fz_archive.fz_audit_chain) or (select a from fzs_rows) <> (select count(*) from fz_archive.fz_security_alerts)
     or (select b from fzs_rows) <> (select count(*) from fz_archive.fz_security_baseline) or (select t from fzs_rows) <> (select count(*) from fz_archive.fz_token_registry) then
    raise exception 'S7 the rollback lost rows'; end if;
  if not exists (select 1 from public.audit_log where action = 'security_hardening_export') then raise exception 'S7 no export record'; end if;
  raise notice 'security_hardening_check: all checks passed';
end $$;
rollback;
