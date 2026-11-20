-- Office money M2 (migrations/20261128_office_money_v1.sql). Everything in ONE transaction, rolled back. Run on a fresh apply from the repo root (scripts/replica/run.sh does).
-- Proves: every office starts at $0 with 0 % reinvestment; allocation / clawback / reinvestment are owner-only (the bot and every API role are refused, also at the table);
-- the bot can only PROPOSE and only the owner executes; scoped identities read only their own office's money views (Jarvis / auditor all; anon / authenticated nothing)
-- and write nothing; the office spend gate only refuses (an active funded office gets exactly reserve_spend's decision; dormant / short is refused); a scoped caller can
-- never reach the gate, so it never consumes an owner approval; attribution is stamped once and only the owner moves it; the money controls are UNCHANGED: functions,
-- triggers, grants, table contents and the decisions of authorize_action / reserve_spend are identical with M2, after rolling M2 back, and after re-applying it.
begin;
grant usage on schema public to anon, authenticated, service_role;   -- as on Supabase (inside the rolled-back transaction)

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
-- a database session WITHOUT the owner's auth uid (e.g. the SQL editor, or the migration role)
create function pg_temp.noowner(p_sql text) returns text language plpgsql as $$
declare r text; u text := current_setting('app.uid', true);
begin
  perform set_config('app.uid', '', true);
  begin execute p_sql into r; exception when others then perform set_config('app.uid', coalesce(u, ''), true); return 'ERR:' || sqlerrm; end;
  perform set_config('app.uid', coalesce(u, ''), true);
  return 'OK:' || coalesce(r, '');
end $$;
-- 'decision|reason' of a gate reply returned by svc() / as_id() ('ERR:...' unchanged)
create function pg_temp.dr(p text) returns text language sql as $$
  select case when p like 'OK:{%' then (substr(p, 4)::jsonb ->> 'decision') || '|' || coalesce(substr(p, 4)::jsonb ->> 'reason', '') else p end
$$;
create function pg_temp.avail(p_office text) returns bigint language sql as $$ select available_cents from public.fz_office_money where office = p_office $$;
create function pg_temp.res_args(p_office text, p_cents int, p_vendor text default 'fzm-vendor') returns text language sql as $$
  select format('%L, ''fzm-actor'', ''routine_expense'', %L, ''office money check'', ''proves the gate'', ''none'', %s', p_office, p_vendor, p_cents)
$$;

-- the money-control fingerprint pg_temp.fz_money_fp() (also used by scripts/replica/run.sh right before vs right after M2 is applied)
\ir include/money_fingerprint.sql

-- the signed-in owner (synthetic auth user, as the other sqltests)
insert into auth.users (id, email) values ('99999999-9999-9999-9999-99999999f002', 'fzm-owner@example.invalid') on conflict do nothing;
insert into public.app_owners (email) values ('fzm-owner@example.invalid') on conflict do nothing;
select set_config('app.uid', '99999999-9999-9999-9999-99999999f002', true);

-- M10 (a) the money controls are UNCHANGED by M2, on the state the replica applied it to: the fingerprint WITH M2 == after M2 is rolled back (in this transaction) ==
-- after it is re-applied. Fingerprint: protected functions + ACLs, triggers on the money tables, their full contents + ACLs, capital_snapshot() and the authorize_action /
-- reserve_spend decision matrix (service path). (b) at the end: the same comparison once more on the state the behaviour checks left (allocations, proposals, stamps).
\set fz_in_txn 1
create temp table fzm_fp_with as select * from pg_temp.fz_money_fp();
\ir ../ops/rollback_office_money.sql
create temp table fzm_fp_without as select * from pg_temp.fz_money_fp();
\ir ../ops/rollback_office_money.sql
do $$
begin
  if (select count(*) from pg_proc where pronamespace = 'public'::regnamespace and (proname like 'fz\_money%' or proname in ('fz_reserve_office_spend', 'fz_unallocated_cents', 'fz_office_available_cents',
        'fz_propose_office_money', 'fz_owner_allocate', 'fz_owner_clawback', 'fz_owner_set_reinvest', 'fz_owner_decide_office_proposal', 'fz_owner_attribute_ledger'))) <> 0
     or to_regclass('public.fz_office_money') is not null or to_regclass('public.fz_office_allocation_log') is not null
     or exists (select 1 from pg_class where relnamespace = 'public'::regnamespace and relname in ('fz_money_config', 'fz_office_allocations', 'fz_office_money_policy', 'fz_office_money_proposals', 'fz_money_attribution'))
     or exists (select 1 from public.fz_table_registry where relname like 'fz\_money%' or relname like 'fz\_office\_money%' or relname = 'fz_office_allocations') then
    raise exception 'M10 the rollback left M2 objects behind'; end if;
  if to_regclass('public.fz_offices') is null or not exists (select 1 from pg_proc where proname = 'fz_authorize_action') then raise exception 'M10 the rollback damaged M1'; end if;
  if public.backup_export_policy() -> 'unclassified' <> '[]'::jsonb then raise exception 'M10 unclassified after the rollback: %', public.backup_export_policy() -> 'unclassified'; end if;
  if exists (select 1 from cron.job where jobname = 'fz-money-stamp') then raise exception 'M10 stamp job left behind'; end if;
  if exists (select 1 from fzm_fp_with w full join fzm_fp_without o using (k) where w.v is distinct from o.v) then
    raise exception 'M10 the money controls differ with and without M2: %', (select string_agg(coalesce(w.k, o.k), ', ') from fzm_fp_with w full join fzm_fp_without o using (k) where w.v is distinct from o.v);
  end if;
  if (select count(*) from fzm_fp_without where k like 'authorize_action:%') < 252 or (select count(*) from fzm_fp_without where k like 'reserve_spend:%') < 60 then raise exception 'M10 matrix too small'; end if;
  if (select count(distinct split_part(v, '|', 1)) from fzm_fp_without where k like 'authorize_action:%') < 3 or (select count(distinct split_part(v, '|', 1)) from fzm_fp_without where k like 'reserve_spend:%') < 3 then
    raise exception 'M10 vacuous matrix (needs allow, deny and ask_owner)'; end if;
end $$;
\ir ../migrations/20261128_office_money_v1.sql
create temp table fzm_fp_again as select * from pg_temp.fz_money_fp();
do $$
begin
  if exists (select 1 from fzm_fp_again w full join fzm_fp_without o using (k) where w.v is distinct from o.v) then
    raise exception 'M10 applying M2 changed the money controls: %', (select string_agg(coalesce(w.k, o.k), ', ') from fzm_fp_again w full join fzm_fp_without o using (k) where w.v is distinct from o.v);
  end if;
end $$;

do $$
declare
  A uuid := 'f0000000-0000-4000-8000-000000000001'; B uuid := 'f0000000-0000-4000-8000-000000000002'; CM uuid := 'f0000000-0000-4000-8000-000000000006';   -- b2b-records, donna, monopoly
  AI text := 'office:b2b-records:manager'; BI text := 'office:donna:manager';
  ca jsonb; cb jsonb; cj jsonb; cu jsonb; cd jsonb; res text; r record; d jsonb; d2 jsonb; d3 jsonb; v_free bigint; pid uuid; pid2 uuid; va uuid; vb uuid; vc uuid; lid uuid; lid2 uuid; rid uuid;
  n int; n2 int; c int; st text; ks boolean; mt text[] := array['fz_money_config', 'fz_office_allocations', 'fz_office_money_policy', 'fz_office_money_proposals', 'fz_money_attribution'];
  m2_funcs text[] := array['fz_money_owner_only', 'fz_money_proposal_guard', 'fz_money_attribution_guard', 'fz_money_stamp', 'fz_office_available_cents', 'fz_unallocated_cents', 'fz_money_report',
                           'fz_money_require_owner', 'fz_money_office', 'fz_money_do_allocate', 'fz_money_do_clawback', 'fz_money_do_reinvest', 'fz_owner_allocate', 'fz_owner_clawback',
                           'fz_owner_set_reinvest', 'fz_owner_decide_office_proposal', 'fz_owner_attribute_ledger', 'fz_propose_office_money', 'fz_reserve_office_spend'];
  allow_a text[] := array['current_identity()', 'current_office()', 'current_office_id()', 'fz_claims()', 'fz_identity_now()', 'fz_readable_offices(text)', 'fz_readable_workspaces(text)',
                          'fz_whoami()', 'fz_writable_offices(text)', 'is_group_scope()', 'fz_agent_in_office(text,uuid)'];
  got text[];
begin
  ca := pg_temp.cl(AI, 'fz_office_agent'); cb := pg_temp.cl(BI, 'fz_office_agent'); cj := pg_temp.cl('jarvis', 'fz_jarvis'); cu := pg_temp.cl('auditor', 'fz_auditor');
  cd := pg_temp.cl('office:wolf-squad:manager', 'fz_office_agent');

  -- M1 $0 default and dormant: every office starts with nothing allocated, nothing available, 0 % reinvestment, and dormant
  if (select count(*) from public.fz_office_money where kind = 'office') <> 8 then raise exception 'M1 expected 8 office rows'; end if;
  if exists (select 1 from public.fz_office_money where kind = 'office' and (allocated_cents <> 0 or clawed_back_cents <> 0 or available_cents <> 0 or reinvest_pct <> 0 or status <> 'dormant')) then
    raise exception 'M1 an office does not start at $0 / 0 %% / dormant: %', (select jsonb_agg(to_jsonb(m)) from public.fz_office_money m where kind = 'office' and (available_cents <> 0 or allocated_cents <> 0)); end if;
  if exists (select 1 from public.fz_office_allocations) or exists (select 1 from public.fz_office_money_policy) or exists (select 1 from public.fz_office_money_proposals) then raise exception 'M1 seeded money rows'; end if;
  if (select available_cents from public.fz_office_money where kind = 'group') is not null then raise exception 'M1 the group has an office balance'; end if;
  if (public.fz_money_report() -> 'totals' ->> 'allocated_cents')::bigint <> 0 then raise exception 'M1 report totals'; end if;
  if public.fz_unallocated_cents() <> (public.capital_snapshot() ->> 'available_cents')::bigint then raise exception 'M1 unallocated <> group capital at $0'; end if;

  -- fixtures: offices A, B, C active (owner), their managers active; one venture per office; live mode, kill switch off
  perform public.fz_owner_set_office_status(s, 'active') from unnest(array['b2b-records', 'donna', 'monopoly']) s;
  perform public.fz_owner_set_identity(s, 'active') from unnest(array[AI, BI]) s;
  insert into public.ventures (slug, name, kind, office_id) values ('fzm-ven-a', 'Money A', 'lab', A) returning id into va;
  insert into public.ventures (slug, name, kind, office_id) values ('fzm-ven-b', 'Money B', 'lab', B) returning id into vb;
  insert into public.ventures (slug, name, kind, office_id) values ('fzm-ven-c', 'Money C', 'lab', CM) returning id into vc;
  insert into public.agents (slug, title, office_id) values ('fzm-agent-a', 'Office A money agent', A);
  update public.system_state set mode = 'auto_in_caps', kill_switch = false where id = 1;
  update public.capital_policy set operating_fund_cents = operating_fund_cents + 1000000, updated_by = 'owner:test' where id = 1;   -- room for the fixtures (rolled back)
  -- a dormant office still has $0: the gate refuses it whatever the amount
  if pg_temp.dr(pg_temp.svc(format('select public.fz_reserve_office_spend(%s)::text', pg_temp.res_args('wolf-squad', 50)))) not like 'deny|%dormant%' then raise exception 'M1 dormant office not refused'; end if;
  if pg_temp.dr(pg_temp.svc(format('select public.fz_reserve_office_spend(%s)::text', pg_temp.res_args('b2b-records', 50)))) not like 'deny|%has $0.00 available%' then raise exception 'M1 an active office at $0 can spend'; end if;

  -- M2 allocation is OWNER-ONLY: the bot (service_role), a session without the owner's uid, and every scoped role are refused; the tables refuse direct writes
  if pg_temp.svc($q$select public.fz_owner_allocate('b2b-records', 100, 'bot tries')::text$q$) not like 'ERR:owner approval required%' then raise exception 'M2 the bot allocated'; end if;
  if pg_temp.svc($q$select public.fz_owner_clawback('b2b-records', 100, 'bot tries')::text$q$) not like 'ERR:owner approval required%' then raise exception 'M2 the bot clawed back'; end if;
  if pg_temp.svc($q$select public.fz_owner_set_reinvest('b2b-records', 100)::text$q$) not like 'ERR:owner approval required%' then raise exception 'M2 the bot set a reinvestment rule'; end if;
  if pg_temp.noowner($q$select public.fz_owner_allocate('b2b-records', 100, 'no uid')::text$q$) not like 'ERR:owner approval required%' then raise exception 'M2 a session without the owner allocated'; end if;
  if pg_temp.svc(format($q$insert into public.fz_office_allocations (office_id, kind, cents, reason) values (%L, 'allocate', 100, 'direct')$q$, A)) not like 'ERR:permission denied%' then raise exception 'M2 the bot inserts allocations'; end if;
  if pg_temp.svc(format($q$insert into public.fz_office_money_policy (office_id, reinvest_pct) values (%L, 100)$q$, A)) not like 'ERR:permission denied%' then raise exception 'M2 the bot inserts a reinvestment rule'; end if;
  if pg_temp.noowner(format($q$insert into public.fz_office_allocations (office_id, kind, cents, reason) values (%L, 'allocate', 100, 'direct')$q$, A)) not like 'ERR:owner approval required%' then raise exception 'M2 the table accepted a non-owner allocation'; end if;
  if pg_temp.noowner(format($q$insert into public.fz_office_money_policy (office_id, reinvest_pct) values (%L, 100)$q$, A)) not like 'ERR:owner approval required%' then raise exception 'M2 the table accepted a non-owner reinvestment rule'; end if;
  foreach res in array array['fz_jarvis', 'fz_office_agent'] loop
    if pg_temp.as_id(res, case res when 'fz_jarvis' then cj else ca end, $q$select public.fz_owner_allocate('b2b-records', 100, 'scoped')::text$q$) not like 'ERR:permission denied%' then raise exception 'M2 % can call the owner allocation', res; end if;
  end loop;
  d := public.fz_owner_allocate('b2b-records', 5000, 'seed A');
  if (d ->> 'available_cents')::bigint <> 5000 or pg_temp.avail('b2b-records') <> 5000 then raise exception 'M2 owner allocation: %', d; end if;
  if (select by || '|' || kind from public.fz_office_allocations where office_id = A) <> 'owner|allocate' then raise exception 'M2 allocation not recorded as the owner'; end if;
  if not exists (select 1 from public.audit_log where action = 'office_allocate' and actor = 'owner' and target = 'fz_offices/b2b-records') then raise exception 'M2 allocation not audited'; end if;
  v_free := public.fz_unallocated_cents();
  if v_free <> (public.capital_snapshot() ->> 'available_cents')::bigint - 5000 then raise exception 'M2 unallocated capital does not subtract the allocation'; end if;
  begin perform public.fz_owner_allocate('donna', (v_free + 1)::int, 'too much'); raise exception 'M2 over-allocation accepted';
  exception when others then if sqlerrm not like 'Refused:%never exceed real money%' then raise; end if; end;
  begin perform public.fz_owner_allocate('group', 100, 'the group'); raise exception 'M2 allocated to the group';
  exception when others then if sqlerrm not like 'unknown office%' then raise; end if; end;
  begin perform public.fz_owner_allocate('donna', 0, 'zero'); raise exception 'M2 $0 allocation accepted';
  exception when others then if sqlerrm not like 'allocation must be above%' then raise; end if; end;
  -- the history is append-only, even for the owner
  begin update public.fz_office_allocations set cents = 1; raise exception 'M2 allocation history updatable'; exception when insufficient_privilege then null; end;
  begin delete from public.fz_office_allocations; raise exception 'M2 allocation history deletable'; exception when insufficient_privilege then null; end;
  -- clawback: owner only, never more than is available
  begin perform public.fz_owner_clawback('b2b-records', 5001, 'too much'); raise exception 'M2 clawback above available accepted';
  exception when others then if sqlerrm not like 'Refused:%only $50.00 available%' then raise; end if; end;
  d := public.fz_owner_clawback('b2b-records', 1000, 'take some back');
  if pg_temp.avail('b2b-records') <> 4000 or (select clawed_back_cents from public.fz_office_money where office = 'b2b-records') <> 1000 then raise exception 'M2 clawback: %', d; end if;
  d := public.fz_owner_allocate('b2b-records', 1000, 'give it back');
  -- a dormant office can be funded, but it still spends nothing
  perform public.fz_owner_allocate('wolf-squad', 100, 'dormant office');
  if pg_temp.dr(pg_temp.svc(format('select public.fz_reserve_office_spend(%s)::text', pg_temp.res_args('wolf-squad', 50)))) not like 'deny|%dormant%' then raise exception 'M2 funded dormant office spends'; end if;
  perform public.fz_owner_clawback('wolf-squad', null, 'all of it');
  if pg_temp.avail('wolf-squad') <> 0 then raise exception 'M2 clawback of everything'; end if;

  -- M3 proposals: the bot / Jarvis propose; only the owner executes or rejects; nothing changes until then
  d := public.fz_propose_office_money('donna', 'allocate', 3000, null, 'Donna needs ad budget for the first client test', 'jarvis');
  pid := (d ->> 'proposal')::uuid;
  if pg_temp.avail('donna') <> 0 then raise exception 'M3 a proposal moved money'; end if;
  if not exists (select 1 from public.owner_messages where kind = 'money' and body like '%' || pid || '%' and body like '%allocate $30.00 to Donna%') then raise exception 'M3 owner not told about the proposal'; end if;
  if pg_temp.svc(format($q$select public.fz_propose_office_money('donna', 'allocate', 100, null, 'service path proposal works', 'jarvis')::text$q$)) not like 'OK:%pending%' then raise exception 'M3 the bot cannot propose'; end if;
  if pg_temp.svc(format($q$select public.fz_owner_decide_office_proposal(%L, true)::text$q$, pid)) not like 'ERR:owner approval required%' then raise exception 'M3 the bot executed a proposal'; end if;
  if pg_temp.svc(format($q$update public.fz_office_money_proposals set status = 'executed' where id = %L$q$, pid)) not like 'ERR:permission denied%' then raise exception 'M3 the bot updates proposals'; end if;
  if pg_temp.noowner(format($q$update public.fz_office_money_proposals set status = 'executed' where id = %L$q$, pid)) not like 'ERR:owner approval required%' then raise exception 'M3 the table accepted a non-owner decision'; end if;
  if pg_temp.as_id('fz_jarvis', cj, $q$select public.fz_propose_office_money('donna', 'allocate', 100, null, 'scoped jarvis proposal', 'jarvis')::text$q$) not like 'ERR:permission denied%' then raise exception 'M3 scoped jarvis can call propose'; end if;
  if (select proposed_by from public.fz_office_money_proposals where id = (public.fz_propose_office_money('the-trap', 'allocate', 100, null, 'pretending to be the owner', 'owner') ->> 'proposal')::uuid) <> 'bot:owner' then
    raise exception 'M3 the bot recorded itself as the owner'; end if;
  perform public.fz_propose_office_money('donna', 'allocate', 100, null, 'third pending proposal', 'jarvis');
  begin perform public.fz_propose_office_money('donna', 'allocate', 100, null, 'fourth pending proposal', 'jarvis'); raise exception 'M3 the pending limit is not enforced';
  exception when others then if sqlerrm not like '%already has 3 pending%' then raise; end if; end;
  d := public.fz_owner_decide_office_proposal(pid, true);
  if d ->> 'status' <> 'executed' or pg_temp.avail('donna') <> 3000 then raise exception 'M3 owner execute: %', d; end if;
  if (select proposal_id from public.fz_office_allocations where office_id = B) <> pid then raise exception 'M3 allocation not linked to the proposal'; end if;
  begin perform public.fz_owner_decide_office_proposal(pid, true); raise exception 'M3 a proposal executed twice';
  exception when others then if sqlerrm not like '%already executed%' then raise; end if; end;
  pid2 := (public.fz_propose_office_money('donna', 'reinvest', null, 50, 'Donna keeps half of its profit', 'jarvis') ->> 'proposal')::uuid;
  perform public.fz_owner_decide_office_proposal(pid2, false, 'not yet');
  if (select status from public.fz_office_money_proposals where id = pid2) <> 'rejected' or exists (select 1 from public.fz_office_money_policy where office_id = B) then raise exception 'M3 reject changed something'; end if;
  pid2 := (public.fz_propose_office_money('donna', 'clawback', 500, null, 'Donna over-funded for this week', 'jarvis') ->> 'proposal')::uuid;
  update public.fz_office_money_proposals set expires_at = now() - interval '1 minute' where id = pid2;   -- (the owner may edit a pending proposal)
  if public.fz_owner_decide_office_proposal(pid2, true) ->> 'status' <> 'expired' or pg_temp.avail('donna') <> 3000 then raise exception 'M3 an expired proposal executed'; end if;
  if pg_temp.svc($q$select count(*)::text from public.fz_office_money_proposals$q$) not like 'OK:%' then raise exception 'M3 the bot cannot read proposals'; end if;

  -- M4 read access: an office identity reads ONLY its own office in both money views; dormant / forged tokens read nothing; Jarvis and the auditor read all; anon / authenticated
  -- nothing; no scoped role reads a raw money table, writes anything, or executes any M2 function; the M1 function allowlist is unchanged
  for r in select * from (values (ca, 'b2b-records', A), (cb, 'donna', B)) x (c, o, oid) loop
    if pg_temp.as_id('fz_office_agent', r.c, 'select count(*)::text || ''|'' || min(office) from public.fz_office_money') <> 'OK:1|' || r.o then raise exception 'M4 % does not see exactly its own office row', r.o; end if;
    if pg_temp.as_id('fz_office_agent', r.c, format('select count(*)::text from public.fz_office_money where office_id <> %L', r.oid)) <> 'OK:0' then raise exception 'M4 LEAK: % sees another office', r.o; end if;
    if pg_temp.as_id('fz_office_agent', r.c, format('select count(*)::text from public.fz_office_allocation_log where office_id <> %L', r.oid)) <> 'OK:0' then raise exception 'M4 LEAK: % sees another office allocation', r.o; end if;
    select count(*) into n from public.fz_office_allocations where office_id = r.oid;
    if n = 0 or pg_temp.as_id('fz_office_agent', r.c, 'select count(*)::text from public.fz_office_allocation_log') <> 'OK:' || n then raise exception 'M4 % allocation log (non-vacuous)', r.o; end if;
    if pg_temp.as_id('fz_office_agent', r.c, 'select available_cents::text from public.fz_office_money') <> 'OK:' || pg_temp.avail(r.o) then raise exception 'M4 % sees a different balance', r.o; end if;
  end loop;
  foreach d in array array[jsonb_build_object('r', 'fz_office_agent', 'c', cd), jsonb_build_object('r', 'fz_office_agent', 'c', pg_temp.cl(AI, 'fz_jarvis')),
                           jsonb_build_object('r', 'fz_office_agent', 'c', pg_temp.cl(AI, 'fz_office_agent', '{"sub": "99999999-9999-9999-9999-99999999f002"}')),
                           jsonb_build_object('r', 'fz_jarvis', 'c', pg_temp.cl(AI, 'fz_jarvis')), jsonb_build_object('r', 'fz_office_agent', 'c', pg_temp.cl('nobody', 'fz_office_agent'))] loop
    if pg_temp.as_id(d ->> 'r', d -> 'c', 'select count(*)::text from public.fz_office_money') <> 'OK:0' then raise exception 'M4 refused token reads office money: %', d; end if;
    if pg_temp.as_id(d ->> 'r', d -> 'c', 'select count(*)::text from public.fz_office_allocation_log') <> 'OK:0' then raise exception 'M4 refused token reads allocations: %', d; end if;
  end loop;
  foreach res in array array['fz_jarvis', 'fz_auditor'] loop
    if pg_temp.as_id(res, case res when 'fz_jarvis' then cj else cu end, 'select count(*)::text from public.fz_office_money') <> 'OK:9' then raise exception 'M4 % does not see every office', res; end if;
    if pg_temp.as_id(res, case res when 'fz_jarvis' then cj else cu end, 'select count(*)::text from public.fz_office_allocation_log') <> 'OK:' || (select count(*) from public.fz_office_allocations) then raise exception 'M4 % allocation log', res; end if;
  end loop;
  foreach res in array array['anon', 'authenticated'] loop
    if pg_temp.as_id(res, ca, 'select count(*)::text from public.fz_office_money') not like 'ERR:permission denied%' then raise exception 'M4 % reads office money', res; end if;
    if pg_temp.as_id(res, ca, 'select count(*)::text from public.fz_office_allocation_log') not like 'ERR:permission denied%' then raise exception 'M4 % reads allocations', res; end if;
  end loop;
  for r in select x.rl, x.c, t from (values ('fz_office_agent', ca), ('fz_jarvis', cj), ('fz_auditor', cu)) x (rl, c) cross join unnest(mt) t loop
    if pg_temp.as_id(r.rl, r.c, format('select count(*)::text from public.%I', r.t)) not like 'ERR:permission denied%' then raise exception 'M4 % reads raw %', r.rl, r.t; end if;
  end loop;
  foreach res in array array['fz_jarvis', 'fz_office_agent', 'fz_auditor', 'anon', 'authenticated'] loop
    if exists (select 1 from unnest(mt || array['fz_office_money', 'fz_office_allocation_log']) t where has_table_privilege(res, ('public.' || t)::regclass, 'insert,update,delete,truncate,references,trigger'))
      then raise exception 'M4 % can write a money object', res; end if;
    if exists (select 1 from unnest(mt) t where has_table_privilege(res, ('public.' || t)::regclass, 'select')) then raise exception 'M4 % can read a raw money table', res; end if;
    if exists (select 1 from pg_proc p where p.pronamespace = 'public'::regnamespace and p.proname = any (m2_funcs) and has_function_privilege(res, p.oid, 'execute')) then raise exception 'M4 % executes an M2 function', res; end if;
  end loop;
  if pg_temp.as_id('fz_office_agent', ca, $q$update public.fz_office_money set available_cents = 999999$q$) not like 'ERR:%' then raise exception 'M4 view writable'; end if;
  foreach res in array array['fz_jarvis', 'fz_office_agent', 'fz_auditor'] loop
    got := array(select p.oid::regprocedure::text from pg_proc p where p.pronamespace = 'public'::regnamespace and has_function_privilege(res, p.oid, 'execute') order by 1);
    if got <> array(select x from unnest(case res when 'fz_auditor' then allow_a else allow_a || array['fz_authorize_action(text,integer,text,text,text,uuid,uuid,jsonb)'] end) x order by 1) then
      raise exception 'M4 the M1 allowlist of % changed: %', res, got; end if;
  end loop;
  -- service_role: select on the raw tables and the views, nothing else
  foreach res in array mt loop
    if not has_table_privilege('service_role', ('public.' || res)::regclass, 'select') or has_table_privilege('service_role', ('public.' || res)::regclass, 'insert,update,delete,truncate') then
      raise exception 'M4 service_role privileges on %', res; end if;
  end loop;

  -- M5 the office gate ONLY REFUSES. For every mode x kill switch x amount x approval: an ACTIVE, FUNDED office gets exactly reserve_spend()'s decision and reason; the
  -- group path too; an allow from the office path is always an allow of reserve_spend(); a short office is refused whatever reserve_spend() would say.
  perform public.fz_owner_allocate('monopoly', 500000, 'large balance for the matrix');
  n := 0;
  foreach st in array array['dry_run', 'approve_first', 'auto_in_caps'] loop
    foreach ks in array array[false, true] loop
      foreach c in array array[0, 100, 2000, 2600, 999999] loop
        foreach res in array array['plain', 'approved'] loop
          begin
            update public.system_state set mode = st, kill_switch = ks where id = 1;
            if res = 'approved' then insert into public.approval_requests (actor, action, cents, ref, recommendation, status, decided_at) values ('fzm-actor', 'routine_expense', c, 'fzm-vendor', 'matrix', 'approved', now()); end if;
            d := public.reserve_spend('fzm-actor', 'routine_expense', 'fzm-vendor', 'office money check', 'proves the gate', 'none', c);
            raise exception using errcode = 'ZFZ01';
          exception when sqlstate 'ZFZ01' then null; end;
          begin
            update public.system_state set mode = st, kill_switch = ks where id = 1;
            if res = 'approved' then insert into public.approval_requests (actor, action, cents, ref, recommendation, status, decided_at) values ('fzm-actor', 'routine_expense', c, 'fzm-vendor', 'matrix', 'approved', now()); end if;
            d2 := public.fz_reserve_office_spend('monopoly', 'fzm-actor', 'routine_expense', 'fzm-vendor', 'office money check', 'proves the gate', 'none', c);
            raise exception using errcode = 'ZFZ01';
          exception when sqlstate 'ZFZ01' then null; end;
          begin
            update public.system_state set mode = st, kill_switch = ks where id = 1;
            if res = 'approved' then insert into public.approval_requests (actor, action, cents, ref, recommendation, status, decided_at) values ('fzm-actor', 'routine_expense', c, 'fzm-vendor', 'matrix', 'approved', now()); end if;
            d3 := public.fz_reserve_office_spend('group', 'fzm-actor', 'routine_expense', 'fzm-vendor', 'office money check', 'proves the gate', 'none', c);
            raise exception using errcode = 'ZFZ01';
          exception when sqlstate 'ZFZ01' then null; end;
          if c > pg_temp.avail('monopoly') then
            if d2 ->> 'decision' <> 'deny' or d2 ->> 'reason' not like '%available%' then raise exception 'M5 office over its balance not refused: %', d2; end if;
          elsif (d ->> 'decision', d ->> 'reason') is distinct from (d2 ->> 'decision', d2 ->> 'reason') then raise exception 'M5 funded office differs from reserve_spend at %/%/%/%: % vs %', st, ks, c, res, d, d2; end if;
          if (d ->> 'decision', d ->> 'reason') is distinct from (d3 ->> 'decision', d3 ->> 'reason') then raise exception 'M5 group path differs from reserve_spend at %/%/%/%: % vs %', st, ks, c, res, d, d3; end if;
          if d2 ->> 'decision' = 'allow' and d ->> 'decision' <> 'allow' then raise exception 'M5 the office path allowed what reserve_spend refused'; end if;
          if d ->> 'decision' = 'allow' then n := n + 1; end if;
          -- a short office (b2b-records has $50) is refused at every point, including where reserve_spend would allow
          begin
            update public.system_state set mode = st, kill_switch = ks where id = 1;
            d2 := public.fz_reserve_office_spend('b2b-records', 'fzm-actor', 'routine_expense', 'fzm-vendor', 'office money check', 'proves the gate', 'none', c + 5001);
            raise exception using errcode = 'ZFZ01';
          exception when sqlstate 'ZFZ01' then null; end;
          if d2 ->> 'decision' <> 'deny' or d2 ->> 'reason' not like '%available%' then raise exception 'M5 short office not refused: %', d2; end if;
        end loop;
      end loop;
    end loop;
  end loop;
  if n < 4 then raise exception 'M5 vacuous: reserve_spend allowed only % matrix points', n; end if;
  raise notice 'M5 % matrix points where reserve_spend allowed; the funded office matched every point', n;
  -- an allowed office reservation is stamped to the office and counts against it; settled, its ledger row is the office's expense (no venture needed)
  d := public.fz_reserve_office_spend('b2b-records', 'fzm-actor', 'routine_expense', 'fzm-vendor', 'office money check', 'proves the gate', 'none', 1500);
  if d ->> 'decision' <> 'allow' then raise exception 'M5 funded office refused: %', d; end if;
  rid := (d ->> 'reservation_id')::uuid;
  if (select office_id::text || '|' || how from public.fz_money_attribution where source = 'reservation' and source_id = rid) <> A || '|office_gate' then raise exception 'M5 reservation not stamped to the office'; end if;
  if pg_temp.avail('b2b-records') <> 3500 or (select reserved_cents from public.fz_office_money where office = 'b2b-records') <> 1500 then raise exception 'M5 reservation does not count: %', pg_temp.avail('b2b-records'); end if;
  d := public.settle_spend(rid, 1200, 'fzm-receipt');
  if pg_temp.avail('b2b-records') <> 3800 or (select expense_cents from public.fz_office_money where office = 'b2b-records') <> 1200 then raise exception 'M5 settled spend not the office expense'; end if;
  perform public.fz_money_stamp();
  if (select office_id::text || '|' || how from public.fz_money_attribution where source = 'ledger' and source_id = (d ->> 'ledger_id')::uuid) <> A || '|reservation' then raise exception 'M5 settled ledger row stamped wrong'; end if;
  begin perform public.fz_reserve_office_spend('nowhere', 'fzm-actor', 'routine_expense', 'fzm-vendor', 'office money check', 'proves the gate', 'none', 1); raise exception 'M5 unknown office accepted';
  exception when others then if sqlerrm not like 'unknown office%' then raise; end if; end;
  if not exists (select 1 from public.action_log where detail ->> 'layer' = 'office_money' and decision = 'deny' and detail ->> 'office' = 'wolf-squad') then raise exception 'M5 office refusals not logged'; end if;

  -- M6 a scoped caller NEVER consumes an owner approval: it cannot execute the gate, and even with a grant added by mistake the gate refuses it before anything runs.
  -- The service path consumes exactly as reserve_spend does.
  update public.system_state set mode = 'approve_first', kill_switch = false where id = 1;
  insert into public.approval_requests (actor, action, cents, ref, recommendation, status, decided_at) values ('fzm-actor', 'routine_expense', 100, 'fzm-appr-1', 'x', 'approved', now()),
                                                                                                        ('fzm-actor', 'take_loan', 0, 'fzm-appr-2', 'x', 'approved', now());
  select count(*) into n from public.action_log where decision = 'allow';
  select count(*) into n2 from public.spend_reservations;
  foreach res in array array['fz_jarvis', 'fz_office_agent'] loop
    if pg_temp.as_id(res, case res when 'fz_jarvis' then cj else ca end, format('select public.fz_reserve_office_spend(%s)::text', pg_temp.res_args('b2b-records', 100, 'fzm-appr-1'))) not like 'ERR:permission denied%' then
      raise exception 'M6 % can execute the office gate', res; end if;
  end loop;
  grant execute on function public.fz_reserve_office_spend(text, text, text, text, text, text, text, integer, boolean, integer, integer, uuid, uuid) to fz_jarvis, fz_office_agent;   -- the mistake
  foreach res in array array['fz_jarvis', 'fz_office_agent'] loop
    foreach d in array array[to_jsonb('b2b-records'::text), to_jsonb('group'::text)] loop
      if pg_temp.as_id(res, case res when 'fz_jarvis' then cj else ca end, format('select public.fz_reserve_office_spend(%s)::text', pg_temp.res_args(d #>> '{}', 100, 'fzm-appr-1'))) not like 'ERR:the office spend gate is service-path only%' then
        raise exception 'M6 % reached the gate (office %)', res, d; end if;
    end loop;
  end loop;
  revoke execute on function public.fz_reserve_office_spend(text, text, text, text, text, text, text, integer, boolean, integer, integer, uuid, uuid) from fz_jarvis, fz_office_agent;
  if pg_temp.as_id('fz_jarvis', cj, $q$select public.fz_authorize_action('take_loan', 0, 'fzm-appr-2')::text$q$) not like '%ask_owner%' then raise exception 'M6 scoped preview'; end if;
  if (select count(*) from public.approval_requests where ref in ('fzm-appr-1', 'fzm-appr-2') and status = 'approved') <> 2 then raise exception 'M6 a scoped call consumed an owner approval'; end if;
  if (select count(*) from public.action_log where decision = 'allow') <> n or (select count(*) from public.spend_reservations) <> n2 then raise exception 'M6 a scoped call wrote an allow or a reservation'; end if;
  res := pg_temp.svc(format('select public.fz_reserve_office_spend(%s)::text', pg_temp.res_args('b2b-records', 100, 'fzm-appr-1')));
  if res not like '%"decision": "allow"%' or (select status from public.approval_requests where ref = 'fzm-appr-1') <> 'used' then raise exception 'M6 service path changed: %', res; end if;
  update public.system_state set mode = 'auto_in_caps' where id = 1;

  -- M7 attribution: a new ledger row / model call follows its venture / agent office, is stamped once, and does not move when the venture later moves; rows before the
  -- cutover are the group's; only the owner re-attributes; nothing is ever deleted
  insert into public.ledger (venture_id, kind, amount_cents, status) values (va, 'revenue', 700, 'received') returning id into lid;
  if (select revenue_cents from public.fz_office_money where office = 'b2b-records') <> 700 then raise exception 'M7 revenue of the office venture not attributed (live)'; end if;
  insert into public.ledger (venture_id, kind, amount_cents, status, created_at) values (vb, 'expense', 999, 'received', (select cutover_at from public.fz_money_config) - interval '1 day') returning id into lid2;
  insert into public.llm_calls (agent_slug, model, purpose, reserved_cents, actual_cents, status) values ('fzm-agent-a', 'x', 'office money check', 40, 30, 'done');
  if (select ai_cents from public.fz_office_money where office = 'b2b-records') <> 30 then raise exception 'M7 AI spend of the office agent not attributed'; end if;
  perform public.fz_money_stamp();
  if (select how from public.fz_money_attribution where source = 'ledger' and source_id = lid) <> 'venture' then raise exception 'M7 ledger stamp'; end if;
  if exists (select 1 from public.fz_money_attribution where source = 'ledger' and source_id = lid2) then raise exception 'M7 a pre-cutover row was stamped'; end if;
  if (select expense_cents from public.fz_office_money where office = 'donna') <> 0 then raise exception 'M7 a pre-cutover row counts for an office'; end if;
  if (select how from public.fz_money_attribution a join public.llm_calls l on l.id = a.source_id where a.source = 'llm_call' and l.agent_slug = 'fzm-agent-a') <> 'agent' then raise exception 'M7 llm stamp'; end if;
  update public.ventures set office_id = B where id = va;
  if (select revenue_cents from public.fz_office_money where office = 'b2b-records') <> 700 or (select revenue_cents from public.fz_office_money where office = 'donna') <> 0 then raise exception 'M7 a stamped row moved with its venture'; end if;
  update public.ventures set office_id = A where id = va;
  if pg_temp.svc(format($q$update public.fz_money_attribution set office_id = %L where source_id = %L$q$, B, lid)) not like 'ERR:permission denied%' then raise exception 'M7 the bot re-attributes'; end if;
  if pg_temp.noowner(format($q$update public.fz_money_attribution set office_id = %L where source_id = %L$q$, B, lid)) not like 'ERR:owner approval required%' then raise exception 'M7 the table accepted a non-owner re-attribution'; end if;
  if pg_temp.svc(format($q$select public.fz_owner_attribute_ledger(%L, 'donna', 'bot')::text$q$, lid)) not like 'ERR:owner approval required%' then raise exception 'M7 the bot called re-attribution'; end if;
  begin delete from public.fz_money_attribution where source_id = lid; raise exception 'M7 attribution deletable'; exception when insufficient_privilege then null; end;
  perform public.fz_owner_attribute_ledger(lid2, 'donna', 'old expense belongs to Donna');
  if (select expense_cents from public.fz_office_money where office = 'donna') <> 999 then raise exception 'M7 owner re-attribution of a pre-cutover row'; end if;
  perform public.fz_owner_attribute_ledger(lid2, 'group', 'back to the group');
  if (select expense_cents from public.fz_office_money where office = 'donna') <> 0 then raise exception 'M7 owner re-attribution back'; end if;

  -- M8 the reinvestment rule: dormant (0 %) until the owner sets it; a loss uses up the allocation; a profit is kept only at the owner's percentage
  -- monopoly C: 500000 allocated (M5). Revenue 600, expense 200 -> profit 400.
  insert into public.ledger (venture_id, kind, amount_cents, status) values (vc, 'revenue', 600, 'received'), (vc, 'expense', 200, 'received');
  if pg_temp.avail('monopoly') <> 500000 then raise exception 'M8 at 0 %% a profit must not raise the balance: %', pg_temp.avail('monopoly'); end if;
  if (select profit_cents from public.fz_office_money where office = 'monopoly') <> 400 then raise exception 'M8 profit'; end if;
  perform public.fz_owner_set_reinvest('monopoly', 50);
  if pg_temp.avail('monopoly') <> 500200 then raise exception 'M8 50 %% of the profit is not kept: %', pg_temp.avail('monopoly'); end if;
  perform public.fz_owner_set_reinvest('monopoly', 100);
  if pg_temp.avail('monopoly') <> 500400 then raise exception 'M8 100 %%: %', pg_temp.avail('monopoly'); end if;
  insert into public.ledger (venture_id, kind, amount_cents, status) values (vc, 'expense', 1000, 'received');   -- now a loss of 600
  if pg_temp.avail('monopoly') <> 499400 then raise exception 'M8 a loss does not use up the allocation: %', pg_temp.avail('monopoly'); end if;
  insert into public.ledger (venture_id, kind, amount_cents, status) values (vc, 'revenue', 5000, 'expected');   -- not cash: does not count
  if pg_temp.avail('monopoly') <> 499400 then raise exception 'M8 expected revenue counted'; end if;
  if pg_temp.svc($q$select public.fz_owner_set_reinvest('monopoly', 0)::text$q$) not like 'ERR:owner approval required%' then raise exception 'M8 the bot changed the rule'; end if;
  begin perform public.fz_owner_set_reinvest('monopoly', 101); raise exception 'M8 101 %% accepted'; exception when others then if sqlerrm not like 'reinvestment must be%' then raise; end if; end;

  -- M9 registry + backup: every new table registered with its class, nothing unregistered; nothing unclassified for the backup, the new tables are not exported;
  -- no foreign key from them; NO trigger of M2 on any pre-existing table; the report adds up
  if (select count(*) from public.fz_table_registry where relname = any (mt) and data_class = 'confidential' and not fz_read and fz_write = '{}') <> 5 then raise exception 'M9 registry rows'; end if;
  if (select count(*) from public.fz_table_registry where relname = any (mt) and scope = 'office' and scope_column = 'office_id') <> 4 then raise exception 'M9 registry scope'; end if;
  if exists (select 1 from public.fz_unregistered_tables()) then raise exception 'M9 unregistered: %', (select string_agg(x, ',') from public.fz_unregistered_tables() x); end if;
  if public.backup_export_policy() -> 'unclassified' <> '[]'::jsonb then raise exception 'M9 unclassified: %', public.backup_export_policy() -> 'unclassified'; end if;
  if (select count(*) from public.backup_classification() where table_name = any (mt) and data_class = 'secret') <> 5 then raise exception 'M9 backup classes'; end if;
  if (public.backup_export_policy() -> 'exported') ?| mt then raise exception 'M9 a money attribution table is exported'; end if;
  if not (public.backup_export_policy() -> 'exported') @> '["ledger", "llm_calls", "spend_reservations"]'::jsonb then raise exception 'M9 a money table left the export'; end if;
  if exists (select 1 from pg_constraint where contype = 'f' and (conrelid::regclass::text = any (mt) or confrelid::regclass::text = any (mt))) then raise exception 'M9 foreign key on a money attribution table'; end if;
  if exists (select 1 from pg_trigger g join pg_proc p on p.oid = g.tgfoid where not g.tgisinternal and (p.proname = any (m2_funcs) or p.proname = 'fz_append_only')
              and not g.tgrelid::regclass::text = any (mt || array['fz_org_archive'])) then raise exception 'M9 an M2 trigger on a pre-existing table'; end if;
  -- tripwire: the triggers on the money / control tables are exactly the ones before M2 (a new one there is a money-control change and needs its own reviewed step)
  if (select string_agg(g.tgrelid::regclass::text || '.' || g.tgname, ' ' order by g.tgrelid::regclass::text, g.tgname) from pg_trigger g where not g.tgisinternal and g.tgrelid::regclass::text in
        ('ledger', 'llm_calls', 'spend_reservations', 'capital_policy', 'action_policy', 'system_state', 'approval_requests', 'action_log', 'bank_accounts', 'bank_balances',
         'bank_transactions', 'payment_instructions', 'waterfall_policy', 'model_prices', 'tool_registry', 'executor_registry', 'executor_runs'))
     <> 'action_policy.action_policy_audit action_policy.action_policy_no_delete bank_balances.bank_balance_guard capital_policy.capital_policy_guard llm_calls.llm_calls_executor_guard waterfall_policy.waterfall_policy_guard' then
    raise exception 'M9 the triggers on the money tables changed'; end if;
  d := public.fz_money_report();
  if jsonb_array_length(d -> 'offices') <> 8 or (d -> 'totals' ->> 'allocated_cents')::bigint <> (select sum(net_allocation_cents) from public.fz_office_money where kind = 'office')
     or (d ->> 'unallocated_cents')::bigint <> public.fz_unallocated_cents() or (d -> 'totals' ->> 'spent_cents')::bigint <> (select sum(spent_cents) from public.fz_office_money) then raise exception 'M9 report: %', d; end if;
  if jsonb_array_length(d -> 'pending_proposals') <> (select count(*) from public.fz_office_money_proposals where status = 'pending' and expires_at > now()) then raise exception 'M9 pending proposals in the report'; end if;
  if pg_temp.svc('select (public.fz_money_report() ? ''offices'')::text') <> 'OK:true' then raise exception 'M9 the bot cannot read the report'; end if;
  if not exists (select 1 from cron.job where jobname = 'fz-money-stamp') then raise exception 'M9 stamp job not scheduled'; end if;
  raise notice 'office_money_check: behaviour checks passed';
end $$;

-- M10 (b) on the state the behaviour checks left: rolling M2 back changes no money control and no money table
create temp table fzm_fp_test as select * from pg_temp.fz_money_fp();
\ir ../ops/rollback_office_money.sql
create temp table fzm_fp_test_without as select * from pg_temp.fz_money_fp();
do $$
begin
  if exists (select 1 from fzm_fp_test w full join fzm_fp_test_without o using (k) where w.v is distinct from o.v) then
    raise exception 'M10 the rollback changed the money controls: %', (select string_agg(coalesce(w.k, o.k), ', ') from fzm_fp_test w full join fzm_fp_test_without o using (k) where w.v is distinct from o.v);
  end if;
  if not exists (select 1 from public.audit_log where action = 'office_money_export' and jsonb_array_length(detail -> 'allocations') >= 5) then raise exception 'M10 the rollback did not keep the allocation record'; end if;
  raise notice 'office_money_check: all checks passed (money controls identical with M2, without it, and after re-applying it)';
end $$;
rollback;
