-- Security hardening M4 (migrations/20261130_security_hardening_v1.sql), as rebuilt after the second review. ONE transaction, rolled back. Fresh apply, repo root.
-- Proves: money controls unchanged (with / without / re-applied); the chain is strictly by id, ignores audit_log.at and catches the re-date-then-edit attack, deletions,
-- holes (reported as gaps), rows filled into holes, rows below genesis and chain edits; verify is incremental and only the cron job / owner gets a full rescan; the reviewed
-- allowlist (= ops/expected_grants.tsv) decides what is unexpected and nothing is silently baselined; standing findings are always reported and cannot be acknowledged; a
-- revoked item that returns alerts again and an acknowledgement ends with the item; a SECURITY DEFINER body swap alerts; alerts dedupe; grants in every schema are watched;
-- rollback + re-apply seeds the chain back and tells the owner; the rollback archives.
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
-- the reviewed allowlist as committed
create temp table fzs_tsv (item text, note text);
\copy fzs_tsv from 'ops/expected_grants.tsv' with (format text, delimiter E'\t')
delete from fzs_tsv where item like '#%';

-- S1 money controls unchanged: with M4 == after its rollback (twice) == after re-applying it
\set fz_in_txn 1
create temp table fzs_fp_with as select * from pg_temp.fz_money_fp();
\ir ../ops/rollback_shared_services.sql
\ir ../ops/rollback_security_hardening.sql
\ir ../ops/rollback_shared_services.sql
\ir ../ops/rollback_security_hardening.sql
create temp table fzs_fp_without as select * from pg_temp.fz_money_fp();
do $$
begin
  if to_regclass('public.fz_audit_chain') is not null or exists (select 1 from pg_proc where proname in ('fz_audit_verify', 'fz_security_watch', 'fz_security_report'))
     or exists (select 1 from cron.job where jobname = 'fz-security-watch') then raise exception 'S1 the rollback left M4 objects behind'; end if;
  if to_regclass('public.fz_office_money') is null or to_regclass('public.fz_approval_queue') is null then raise exception 'S1 the rollback damaged M2 / M3'; end if;
  if public.backup_export_policy() -> 'unclassified' <> '[]'::jsonb then raise exception 'S1 unclassified after the rollback'; end if;
  if exists (select 1 from fzs_fp_with w full join fzs_fp_without o using (k) where w.v is distinct from o.v) then raise exception 'S1 the money controls differ with and without M4'; end if;
end $$;
\ir ../migrations/20261130_security_hardening_v1.sql
create temp table fzs_fp_again as select * from pg_temp.fz_money_fp();
do $$
begin
  if exists (select 1 from fzs_fp_again w full join fzs_fp_without o using (k) where w.v is distinct from o.v) then raise exception 'S1 applying M4 changed the money controls'; end if;
end $$;

do $$
declare cj jsonb; ca jsonb; v jsonb; w jsonb; n int; res text; d jsonb; r1 bigint; r2 bigint; r3 bigint; r4 bigint; r5 bigint; g bigint; mid bigint;
begin
  cj := pg_temp.cl('jarvis', 'fz_jarvis');
  perform public.fz_owner_set_office_status('b2b-records', 'active');
  perform public.fz_owner_set_identity('office:b2b-records:manager', 'active');
  ca := pg_temp.cl('office:b2b-records:manager', 'fz_office_agent');
  -- S0 the reviewed allowlist in the database is exactly the committed ops/expected_grants.tsv; no callable alert helper exists (N1 lesson)
  if exists (select x from public.fz_expected_grants() x except select item from fzs_tsv) or exists (select item from fzs_tsv except select x from public.fz_expected_grants() x) then
    raise exception 'S0 fz_expected_grants() differs from ops/expected_grants.tsv'; end if;
  if (select count(*) from fzs_tsv) < 50 then raise exception 'S0 allowlist suspiciously small'; end if;
  if exists (select 1 from fzs_tsv where item ~ '^table:[^:]+:(anon|authenticated):' or item ~ ':rls-off$' or item like '%audit_log:service_role%' or item like '%fz_archive%') then
    raise exception 'S0 the allowlist contains a standing or forbidden item'; end if;
  if exists (select 1 from pg_proc where proname = 'fz_security_alert') then raise exception 'S0 a callable alert helper exists'; end if;

  -- S2 (review 1) the chain is by id, uses OUR first-seen time, ignores audit_log.at
  perform public.fz_audit_chain_extend();                                -- observes everything that exists now
  update public.fz_audit_pending set first_seen = now() - interval '10 minutes';   -- (test clock) the existing rows were seen 10 minutes ago
  perform public.fz_audit_chain_extend();
  select genesis_id into g from public.fz_audit_state;
  if g is null or (select count(*) from public.fz_audit_chain) < 10 then raise exception 'S2 nothing chained'; end if;
  v := public.fz_audit_verify(true);
  if not (v ->> 'ok')::boolean then raise exception 'S2 clean chain does not verify: %', v; end if;
  -- the attack: five fresh rows; re-date the first to 2999, edit the third, delete the fourth, reset the date
  insert into public.audit_log (actor, action, target, detail) values ('fzs', 'fzs_new', 'r1', '{}') returning id into r1;
  insert into public.audit_log (actor, action, target, detail) values ('fzs', 'fzs_new', 'r2', '{}') returning id into r2;
  insert into public.audit_log (actor, action, target, detail) values ('fzs', 'fzs_new', 'r3', '{}') returning id into r3;
  insert into public.audit_log (actor, action, target, detail) values ('fzs', 'fzs_new', 'r4', '{}') returning id into r4;
  insert into public.audit_log (actor, action, target, detail) values ('fzs', 'fzs_new', 'r5', '{}') returning id into r5;
  if pg_temp.svc('select public.fz_audit_chain_extend()::text') <> 'OK:0' then raise exception 'S2 fresh rows chained at once'; end if;   -- observed, not chained
  update public.audit_log set at = '2999-01-01' where id = r1;
  update public.audit_log set detail = '{"forged": true}' where id = r3;
  delete from public.audit_log where id = r4;
  update public.audit_log set at = now() where id = r1;
  v := public.fz_audit_verify(false);
  if (v ->> 'ok')::boolean or not (v -> 'breaks') @> '[{"problem": "changed"}]' or not (v -> 'breaks') @> '[{"problem": "deleted"}]' then raise exception 'S2 the re-date attack is not caught before chaining: %', v; end if;
  update public.fz_audit_pending set first_seen = now() - interval '10 minutes';
  perform public.fz_audit_chain_extend();
  if not exists (select 1 from public.fz_audit_chain where audit_id = r4 and kind = 'row') then raise exception 'S2 an observed, then deleted row was not chained with its observed hash'; end if;
  v := public.fz_audit_verify(true);
  if (v ->> 'ok')::boolean or not (v -> 'breaks') @> jsonb_build_array(jsonb_build_object('audit_id', r3, 'problem', 'changed')) or not (v -> 'breaks') @> jsonb_build_array(jsonb_build_object('audit_id', r4, 'problem', 'deleted')) then
    raise exception 'S2 the re-date attack verifies after chaining: %', v; end if;
  update public.audit_log set detail = '{}' where id = r3;                -- (put r3 back; r4 stays deleted for later checks? no: re-insert it identically)
  insert into public.audit_log (id, actor, action, target, detail, at) select r4, 'fzs', 'fzs_new', 'r4', '{}', (select at from public.audit_log where id = r3);
  -- a hole: a row deleted before it was ever seen becomes a 'gap' (reported, not a break); a row that later appears in the hole is caught; so is one below genesis
  insert into public.audit_log (actor, action, target, detail) values ('fzs', 'fzs_hole', 'h', '{}') returning id into mid;
  delete from public.audit_log where id = mid;
  insert into public.audit_log (actor, action, target, detail) values ('fzs', 'fzs_after', 'a', '{}');
  perform public.fz_audit_chain_extend(); update public.fz_audit_pending set first_seen = now() - interval '10 minutes'; perform public.fz_audit_chain_extend();
  if not exists (select 1 from public.fz_audit_chain where audit_id = mid and kind = 'gap') then raise exception 'S2 the hole is not a gap link'; end if;
  begin
    insert into public.audit_log (id, actor, action, target, detail) values (mid, 'x', 'filled later', 'x', '{}');
    v := public.fz_audit_verify(true); raise exception using errcode = 'ZFZ01';
  exception when sqlstate 'ZFZ01' then null; end;
  if not (v -> 'breaks') @> jsonb_build_array(jsonb_build_object('audit_id', mid, 'problem', 'gap_filled')) then raise exception 'S2 a row filled into a hole is not caught: %', v; end if;
  begin
    insert into public.audit_log (id, actor, action, target, detail) values (g - 1000000, 'x', 'below genesis', 'x', '{}');
    v := public.fz_audit_verify(false); raise exception using errcode = 'ZFZ01';
  exception when sqlstate 'ZFZ01' then null; end;
  if not (v -> 'breaks') @> '[{"problem": "below_genesis"}]' then raise exception 'S2 a row below genesis is not caught: %', v; end if;
  begin
    alter table public.fz_audit_chain disable trigger fz_audit_chain_append_only;
    update public.fz_audit_chain set row_hash = repeat('0', 64) where seq = (select max(seq) - 2 from public.fz_audit_chain);
    v := public.fz_audit_verify(true); raise exception using errcode = 'ZFZ01';
  exception when sqlstate 'ZFZ01' then null; end;
  if not (v -> 'breaks') @> '[{"problem": "chain_edited"}]' then raise exception 'S2 an edited chain was not detected: %', v; end if;
  v := public.fz_audit_verify(true);
  if not (v ->> 'ok')::boolean or (v ->> 'gaps')::int < 1 then raise exception 'S2 the repaired chain should verify with its gap reported: %', v; end if;
  -- (review 6) verify is incremental; only the cron job / owner gets a full rescan; the key cannot force one
  update public.fz_audit_state set checkpoint_seq = (select max(seq) from public.fz_audit_chain), checkpoint_hash = (select chain_hash from public.fz_audit_chain order by seq desc limit 1);
  if pg_temp.svc('select (public.fz_audit_verify(true) ->> ''full'')') <> 'OK:false' then raise exception 'S2/6 the service key forced a full rescan'; end if;
  if (public.fz_audit_verify(true) ->> 'full') <> 'true' then raise exception 'S2/6 the database session cannot run a full rescan'; end if;
  begin update public.fz_audit_chain set row_hash = 'x'; raise exception 'S2 chain updatable'; exception when insufficient_privilege then null; end;
  if pg_temp.svc($q$insert into public.fz_audit_chain (audit_id, row_hash, chain_hash) values (-1, 'x', 'x')$q$) not like 'ERR:permission denied%' then raise exception 'S2 the bot writes the chain'; end if;
  if pg_temp.svc($q$update public.fz_audit_pending set row_hash = 'x'$q$) not like 'ERR:permission denied%' then raise exception 'S2 the bot rewrites observed hashes'; end if;
  foreach res in array array['fz_jarvis', 'fz_office_agent', 'fz_auditor', 'anon', 'authenticated'] loop
    if pg_temp.as_id(res, cj, 'select count(*)::text from public.fz_audit_chain') not like 'ERR:permission denied%' then raise exception 'S2 % reads the chain', res; end if;
    if exists (select 1 from pg_proc p where p.pronamespace = 'public'::regnamespace and p.proname in ('fz_audit_chain_extend', 'fz_audit_verify', 'fz_privileged_items', 'fz_expected_grants',
                'fz_security_watch', 'fz_owner_ack_security', 'fz_owner_register_token', 'fz_security_report') and has_function_privilege(res, p.oid, 'execute')) then raise exception 'S2 % executes an M4 function', res; end if;
  end loop;

  -- S3 (review 2) no silent baseline: the first run already reports every item not on the reviewed list; standing findings are reported (and alerted once) every time
  select count(*) into n from public.owner_messages;
  -- (after a rollback + re-apply the baseline is seeded from the archive: items it already holds as alerted / acknowledged are not new, but none may be 'expected')
  select count(*) into g from public.fz_privileged_items() x where x.category = 'grant' and not x.item in (select public.fz_expected_grants())
     and not exists (select 1 from public.fz_security_baseline b where b.item = x.item and b.status in ('alerted', 'acknowledged'));
  w := public.fz_security_watch();
  if (w ->> 'new_items')::int <> g then raise exception 'S3 first run: % (want % new)', w, g; end if;
  if exists (select 1 from public.fz_privileged_items() x where x.category = 'grant' and not x.item in (select public.fz_expected_grants())
               and not exists (select 1 from public.fz_security_baseline b where b.item = x.item and b.status in ('alerted', 'acknowledged'))) then
    raise exception 'S3 an item not on the reviewed list was silently baselined'; end if;
  if (w ->> 'standing')::int < 1 or not exists (select 1 from public.fz_security_alerts where kind = 'standing') then raise exception 'S3 standing findings not reported: %', w; end if;
  if not exists (select 1 from jsonb_array_elements_text(public.fz_security_report() -> 'standing') x where x = 'table:public.audit_log:service_role:UPDATE') then raise exception 'S3 service_role UPDATE on audit_log not standing'; end if;
  if (public.fz_security_watch() ->> 'alerts_sent')::int <> 0 then raise exception 'S3/5 a quiet run alerted again (dedupe)'; end if;
  -- (review 3) a new grant alerts; revoked, it is remembered; granted again, it alerts again; an acknowledgement ends with the item
  grant delete on public.memory to fz_jarvis;
  if (public.fz_security_watch() ->> 'alerts_sent')::int <> 1 then raise exception 'S3 new grant not alerted'; end if;
  if (select status from public.fz_security_baseline where item = 'table:public.memory:fz_jarvis:DELETE') <> 'alerted' then raise exception 'S3 baseline status'; end if;
  perform public.fz_owner_ack_security('table:public.memory:fz_jarvis:DELETE');
  revoke delete on public.memory from fz_jarvis;
  perform public.fz_security_watch();
  if (select status || '|' || coalesce(acknowledged_by, '-') from public.fz_security_baseline where item = 'table:public.memory:fz_jarvis:DELETE') <> 'revoked|-' then raise exception 'S3 revoke not recorded or acknowledgement kept'; end if;
  grant delete on public.memory to fz_jarvis;
  w := public.fz_security_watch();
  if (w ->> 'returned_items')::int <> 1 or (w ->> 'alerts_sent')::int <> 1 then raise exception 'S3 a re-granted item stayed muted: %', w; end if;
  if (select generation from public.fz_security_baseline where item = 'table:public.memory:fz_jarvis:DELETE') <> 2 then raise exception 'S3 generation'; end if;
  revoke delete on public.memory from fz_jarvis;
  -- standing findings cannot be acknowledged
  begin perform public.fz_owner_ack_security('table:public.audit_log:service_role:UPDATE'); raise exception 'S3 a standing finding was acknowledged';
  exception when others then if sqlerrm not like '%standing finding cannot be acknowledged%' then raise; end if; end;
  -- (review 3) a SECURITY DEFINER body swap alerts once
  execute replace(pg_get_functiondef('public.fz_money_report()'::regprocedure), 'Virtual sub-ledgers:', 'Virtual sub-ledgers (swapped):');
  w := public.fz_security_watch();
  if (w ->> 'alerts_sent')::int <> 1 or not exists (select 1 from public.fz_security_alerts where kind = 'definer_changed' and item like '%fz_money_report()%') then raise exception 'S3 a definer body swap was not caught: %', w; end if;
  if (public.fz_security_watch() ->> 'alerts_sent')::int <> 0 then raise exception 'S3/5 the body swap alerted twice'; end if;
  -- (review 6) grants in other schemas, including the archive, are watched
  create schema if not exists fz_archive;
  create table fz_archive.fzs_leak (id int);
  grant select on fz_archive.fzs_leak to anon;
  w := public.fz_security_watch();
  if (w ->> 'alerts_sent')::int <> 1 or not exists (select 1 from public.fz_security_baseline where item like 'table-read:fz_archive.fzs_leak:anon%') then raise exception 'S3/6 a grant in fz_archive was not watched: %', w; end if;
  drop table fz_archive.fzs_leak;
  -- (review 5) a chain break alerts once per first id, even as it grows
  update public.audit_log set detail = '{"tampered": true}' where id = r2;
  if not (public.fz_security_watch() ->> 'chain_ok')::boolean then raise exception 'S3/6 (expected) an incremental run sees only links after the checkpoint'; end if;
  update public.fz_audit_state set last_full_at = now() - interval '1 day';   -- (test clock) the nightly full rescan is due
  w := public.fz_security_watch();
  if (w ->> 'chain_ok')::boolean or (w ->> 'alerts_sent')::int <> 1 or not exists (select 1 from public.owner_messages where body like 'SECURITY: the audit log hash chain is broken%') then raise exception 'S3 chain break not alerted: %', w; end if;
  update public.audit_log set detail = '{"tampered": true}' where id = r5;
  update public.fz_audit_state set last_full_at = now() - interval '1 day';
  w := public.fz_security_watch();
  if (w ->> 'chain_ok')::boolean or (w ->> 'alerts_sent')::int <> 0 then raise exception 'S3/5 the same break (first id unchanged) alerted again: %', w; end if;
  update public.audit_log set detail = '{}' where id in (r2, r5);
  if exists (select 1 from public.owner_messages where kind = 'emergency' and body like 'SECURITY%') then raise exception 'S3 a security alert can trigger a call'; end if;
  if pg_temp.svc($q$insert into public.fz_security_alerts (kind, item, dedupe_key) values ('standing', 'x', 'chain_break:changed:999')$q$) not like 'ERR:permission denied%' then raise exception 'S3 the bot can pre-empt an alert key'; end if;
  begin update public.fz_security_alerts set item = 'x'; raise exception 'S3 alerts updatable'; exception when insufficient_privilege then null; end;
  if pg_temp.as_id('fz_jarvis', cj, 'select public.fz_security_watch()::text') not like 'ERR:permission denied%' then raise exception 'S3 scoped watch'; end if;

  -- S4 the report: standing + unexpected shown; read-only, service / owner only
  create function public.fzs_bad_definer() returns int language sql security definer as $f$ select 1 $f$;
  create table public.fzs_rls_off (id int);
  perform public.fz_owner_register_token('office:b2b-records:manager', 'jti-soon', now() + interval '3 days', 'drill');
  perform public.fz_owner_register_token('auditor', 'jti-later', now() + interval '90 days', 'drill');
  if pg_temp.svc($q$select public.fz_owner_register_token('jarvis', 'jti-bot', now() + interval '3 days')::text$q$) not like 'ERR:%' then raise exception 'S4 the bot registered a token'; end if;
  if pg_temp.svc($q$insert into public.fz_token_registry (jti, identity, expires_at) values ('jti-bot2', 'jarvis', now() + interval '3 days')$q$) not like 'ERR:permission denied%' then raise exception 'S4 the bot inserts tokens'; end if;
  if pg_temp.noowner($q$insert into public.fz_token_registry (jti, identity, expires_at) values ('jti-bot3', 'jarvis', now() + interval '3 days')$q$) not like 'ERR:owner approval required%' then raise exception 'S4 the table accepted a non-owner token'; end if;
  d := public.fz_security_report();
  if jsonb_array_length(d -> 'standing') < 1 or (d ->> 'expected_count')::int <> (select count(*) from fzs_tsv) then raise exception 'S4 standing / expected'; end if;
  if not (d -> 'definer_without_search_path') ? 'public.fzs_bad_definer()' then raise exception 'S4 definer without search_path not reported'; end if;
  if not (d -> 'rls_off') ? 'fzs_rls_off' then raise exception 'S4 RLS-off table not reported'; end if;
  if jsonb_array_length(d -> 'tokens_expiring') <> 1 or d -> 'tokens_expiring' -> 0 ->> 'identity' <> 'office:b2b-records:manager' then raise exception 'S4 tokens near expiry: %', d -> 'tokens_expiring'; end if;
  if jsonb_array_length(d -> 'definer_changed') < 1 then raise exception 'S4 definer change not shown'; end if;
  if pg_temp.svc('select (public.fz_security_report() ? ''standing'')::text') <> 'OK:true' then raise exception 'S4 the bot cannot read the report'; end if;
  foreach res in array array['fz_jarvis', 'fz_office_agent', 'anon', 'authenticated'] loop
    if pg_temp.as_id(res, case when res like 'fz%' then cj else ca end, 'select public.fz_security_report()::text') not like 'ERR:permission denied%' then raise exception 'S4 % reads the report', res; end if;
  end loop;
  grant execute on function public.fz_security_report(integer) to fz_jarvis;
  if pg_temp.as_id('fz_jarvis', cj, 'select public.fz_security_report()::text') not like 'ERR:the security report is for the owner%' then raise exception 'S4 scoped report with a mistaken grant'; end if;
  revoke execute on function public.fz_security_report(integer) from fz_jarvis;
  drop function public.fzs_bad_definer(); drop table public.fzs_rls_off;
  -- S5 owner-only acknowledge
  if pg_temp.svc($q$select public.fz_owner_ack_security('column-write:public.tasks:fz_jarvis')::text$q$) not like 'ERR:owner approval required%' then raise exception 'S5 the bot acknowledged'; end if;
  if pg_temp.svc($q$insert into public.fz_security_baseline (item) values ('x')$q$) not like 'ERR:permission denied%' then raise exception 'S5 the bot writes the baseline'; end if;
  -- S6 registry, backup, money / audit tables untouched
  if exists (select 1 from public.fz_unregistered_tables()) or public.backup_export_policy() -> 'unclassified' <> '[]'::jsonb then raise exception 'S6 registry / backup'; end if;
  if (select count(*) from public.backup_classification() where table_name like 'fz\_audit%' or table_name like 'fz\_security%' or table_name = 'fz_token_registry') <> 7 then raise exception 'S6 classes'; end if;
  if (select string_agg(g2.tgrelid::regclass::text || '.' || g2.tgname, ' ' order by g2.tgrelid::regclass::text, g2.tgname) from pg_trigger g2 where not g2.tgisinternal and g2.tgrelid::regclass::text in
        ('ledger', 'llm_calls', 'spend_reservations', 'capital_policy', 'action_policy', 'system_state', 'approval_requests', 'action_log', 'audit_log', 'bank_accounts', 'bank_balances',
         'bank_transactions', 'payment_instructions', 'waterfall_policy', 'model_prices', 'tool_registry', 'executor_registry', 'executor_runs'))
     <> 'action_policy.action_policy_audit action_policy.action_policy_no_delete bank_balances.bank_balance_guard capital_policy.capital_policy_guard llm_calls.llm_calls_executor_guard waterfall_policy.waterfall_policy_guard' then
    raise exception 'S6 the triggers on the money / audit tables changed'; end if;
  if not exists (select 1 from cron.job where jobname = 'fz-security-watch') then raise exception 'S6 watch not scheduled'; end if;
  raise notice 'security_hardening_check: behaviour checks passed';
end $$;

-- S7 the rollback archives (no row lost); (review 4) a re-apply seeds the chain / baseline back from the archive and tells the owner
create temp table fzs_rows as select (select count(*) from public.fz_audit_chain) c, (select count(*) from public.fz_security_alerts) a, (select count(*) from public.fz_security_baseline) b,
  (select count(*) from public.fz_token_registry) t, (select count(*) from public.fz_security_fingerprints) f, (select chain_hash from public.fz_audit_chain order by seq desc limit 1) head;
create temp table fzs_fp_test as select * from pg_temp.fz_money_fp();
\ir ../ops/rollback_shared_services.sql
\ir ../ops/rollback_security_hardening.sql
create temp table fzs_fp_test_without as select * from pg_temp.fz_money_fp();
do $$
begin
  if exists (select 1 from fzs_fp_test w full join fzs_fp_test_without o using (k) where w.v is distinct from o.v) then raise exception 'S7 the rollback changed the money controls'; end if;
  if (select c from fzs_rows) < 20 or (select c from fzs_rows) <> (select count(*) from fz_archive.fz_audit_chain) or (select a from fzs_rows) <> (select count(*) from fz_archive.fz_security_alerts)
     or (select b from fzs_rows) <> (select count(*) from fz_archive.fz_security_baseline) or (select t from fzs_rows) <> (select count(*) from fz_archive.fz_token_registry)
     or (select f from fzs_rows) <> (select count(*) from fz_archive.fz_security_fingerprints) then raise exception 'S7 the rollback lost rows'; end if;
  if not exists (select 1 from public.audit_log where action = 'security_hardening_export') then raise exception 'S7 no export record'; end if;
end $$;
\ir ../migrations/20261130_security_hardening_v1.sql
do $$
begin
  if (select count(*) from public.fz_audit_chain) <> (select c from fzs_rows) or (select chain_hash from public.fz_audit_chain order by seq desc limit 1) <> (select head from fzs_rows) then
    raise exception 'S7/4 the chain was reset by rollback + re-apply'; end if;
  if (select count(*) from public.fz_security_baseline) <> (select b from fzs_rows) then raise exception 'S7/4 the baseline was reset'; end if;
  if not exists (select 1 from public.owner_messages where body like 'SECURITY: the audit chain and the security baseline were re-initialised%') or (select reinitialised_at from public.fz_audit_state) is null then
    raise exception 'S7/4 the owner was not told about the re-initialisation'; end if;
  if not (public.fz_audit_verify(true) ->> 'ok')::boolean then raise exception 'S7/4 the re-seeded chain does not verify: %', public.fz_audit_verify(true); end if;
  raise notice 'security_hardening_check: all checks passed';
end $$;
rollback;
