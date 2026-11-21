-- Approvals kernel M3 (migrations/20261129_approvals_kernel_v1.sql). ONE transaction, rolled back. Run on a fresh apply from the repo root (scripts/replica/run.sh does).
-- Proves: the money controls are unchanged (fingerprint with M3 == after its rollback == after re-apply); both request types land in ONE queue with office, requester,
-- amount, risk, expiry and status; office identities see only their office, Jarvis / auditor all, anon / authenticated and forged / dormant tokens nothing; no scoped role
-- can approve, consume or modify a decision; decisions go only through the existing owner paths; one expiry rule + a per-office-per-type cap, every change audited,
-- nothing deleted; the office payment gate only refuses and otherwise equals prepare_payment().
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

insert into auth.users (id, email) values ('99999999-9999-9999-9999-99999999f003', 'fzq-owner@example.invalid') on conflict do nothing;
insert into public.app_owners (email) values ('fzq-owner@example.invalid') on conflict do nothing;
select set_config('app.uid', '99999999-9999-9999-9999-99999999f003', true);

-- K1 the money controls are UNCHANGED by M3: fingerprint with M3 == after its rollback == after re-applying it
\set fz_in_txn 1
create temp table fzq_fp_with as select * from pg_temp.fz_money_fp();
\ir ../ops/rollback_approvals_kernel.sql
\ir ../ops/rollback_approvals_kernel.sql
create temp table fzq_fp_without as select * from pg_temp.fz_money_fp();
do $$
begin
  if to_regclass('public.fz_approval_queue') is not null or exists (select 1 from pg_proc where proname in ('fz_queue_expire', 'fz_queue_audit_proposal', 'fz_prepare_office_payment'))
     or exists (select 1 from pg_trigger where tgname = 'fz_office_money_proposals_audit') or exists (select 1 from cron.job where jobname = 'fz-queue-expire') then
    raise exception 'K1 the rollback left M3 objects behind'; end if;
  if to_regclass('public.fz_office_money') is null or to_regclass('public.fz_offices') is null then raise exception 'K1 the rollback damaged M2 / M1'; end if;
  if exists (select 1 from fzq_fp_with w full join fzq_fp_without o using (k) where w.v is distinct from o.v) then
    raise exception 'K1 the money controls differ with and without M3: %', (select string_agg(coalesce(w.k, o.k), ', ') from fzq_fp_with w full join fzq_fp_without o using (k) where w.v is distinct from o.v); end if;
  if (select count(*) from fzq_fp_without) < 300 then raise exception 'K1 fingerprint too small'; end if;
end $$;
\ir ../migrations/20261129_approvals_kernel_v1.sql
create temp table fzq_fp_again as select * from pg_temp.fz_money_fp();
do $$
begin
  if exists (select 1 from fzq_fp_again w full join fzq_fp_without o using (k) where w.v is distinct from o.v) then
    raise exception 'K1 applying M3 changed the money controls: %', (select string_agg(coalesce(w.k, o.k), ', ') from fzq_fp_again w full join fzq_fp_without o using (k) where w.v is distinct from o.v); end if;
end $$;

do $$
declare
  A uuid := 'f0000000-0000-4000-8000-000000000001'; B uuid := 'f0000000-0000-4000-8000-000000000002'; G uuid := 'f0000000-0000-4000-8000-000000000000';
  AI text := 'office:b2b-records:manager'; BI text := 'office:donna:manager';
  ca jsonb; cb jsonb; cj jsonb; cu jsonb; res text; r record; d jsonb; d2 jsonb; ra uuid; rb uuid; rg uuid; pa uuid; pb uuid; n int; n2 int; c int; st text;
  allow_a text[] := array['current_identity()', 'current_office()', 'current_office_id()', 'fz_claims()', 'fz_identity_now()', 'fz_readable_offices(text)', 'fz_readable_workspaces(text)',
                          'fz_whoami()', 'fz_writable_offices(text)', 'is_group_scope()', 'fz_agent_in_office(text,uuid)'];
  got text[];
begin
  ca := pg_temp.cl(AI, 'fz_office_agent'); cb := pg_temp.cl(BI, 'fz_office_agent'); cj := pg_temp.cl('jarvis', 'fz_jarvis'); cu := pg_temp.cl('auditor', 'fz_auditor');
  perform public.fz_owner_set_office_status(s, 'active') from unnest(array['b2b-records', 'donna']) s;
  perform public.fz_owner_set_identity(s, 'active') from unnest(array[AI, BI]) s;
  insert into public.agents (slug, title, office_id) values ('fzq-agent-a', 'Office A agent', A), ('fzq-agent-b', 'Office B agent', B);
  insert into public.ventures (slug, name, kind, office_id) values ('fzq-ven-a', 'Queue A', 'lab', A), ('fzq-ven-b', 'Queue B', 'lab', B), ('fzq-ven-c', 'Queue C', 'lab', 'f0000000-0000-4000-8000-000000000006'),
                                                                   ('fzq-ven-g', 'Queue G', 'lab', G);
  update public.system_state set mode = 'auto_in_caps', kill_switch = false where id = 1;
  update public.capital_policy set operating_fund_cents = operating_fund_cents + 1000000, updated_by = 'owner:test' where id = 1;
  -- both request types, in two offices and the group
  insert into public.approval_requests (actor, action, cents, ref, recommendation) values ('fzq-agent-a', 'take_loan', 0, 'fzq-a', 'office A loan') returning id into ra;
  insert into public.approval_requests (actor, action, cents, ref, recommendation) values ('fzq-agent-b', 'sign_contract', 0, 'fzq-b', 'office B contract') returning id into rb;
  insert into public.approval_requests (actor, action, cents, ref, recommendation) values ('jarvis', 'financial_transfer', 5000, 'fzq-g', 'group transfer') returning id into rg;
  pa := (public.fz_propose_office_money('b2b-records', 'allocate', 2500, null, 'office A needs a test budget', 'jarvis') ->> 'proposal')::uuid;
  pb := (public.fz_propose_office_money('donna', 'reinvest', null, 20, 'Donna keeps a fifth of its profit', 'jarvis') ->> 'proposal')::uuid;

  -- K2 ONE queue: both types, with office, requester, amount, risk, expiry, status and the decision path; no free text
  select * into r from public.fz_approval_queue where source_id = ra;
  if r.request_type <> 'action_approval' or r.office <> 'b2b-records' or r.requester <> 'fzq-agent-a' or r.risk <> 'red' or r.status <> 'pending' or r.expires_at is null or r.decided_by_path not like '%Telegram%' then
    raise exception 'K2 action approval row: %', to_jsonb(r); end if;
  select * into r from public.fz_approval_queue where source_id = rg;
  if r.office <> 'group' or r.amount_cents <> 5000 then raise exception 'K2 group row: %', to_jsonb(r); end if;
  select * into r from public.fz_approval_queue where source_id = pa;
  if r.request_type <> 'office_money_allocate' or r.office <> 'b2b-records' or r.amount_cents <> 2500 or r.risk <> 'money' or r.decided_by_path not like '%fz_owner_decide_office_proposal%' then
    raise exception 'K2 money row: %', to_jsonb(r); end if;
  if (select count(*) from public.fz_approval_queue) <> (select count(*) from public.approval_requests) + (select count(*) from public.fz_office_money_proposals) then raise exception 'K2 queue is not complete'; end if;
  if exists (select 1 from information_schema.columns where table_schema = 'public' and table_name = 'fz_approval_queue' and column_name in ('recommendation', 'rationale', 'ref')) then
    raise exception 'K2 free text in the queue'; end if;

  -- K3 office-scoped read: each office sees exactly its own rows (both types: non-vacuous); refused / dormant / forged tokens see nothing; Jarvis / auditor all; anon / authenticated denied
  for r in select * from (values (ca, A), (cb, B)) x (c, o) loop
    select count(*) into n from public.fz_approval_queue where office_id = r.o;
    if n < 2 or pg_temp.as_id('fz_office_agent', r.c, 'select count(*)::text from public.fz_approval_queue') <> 'OK:' || n then raise exception 'K3 office % sees a different queue (own %)', r.o, n; end if;
    if pg_temp.as_id('fz_office_agent', r.c, format('select count(*)::text from public.fz_approval_queue where office_id <> %L', r.o)) <> 'OK:0' then raise exception 'K3 LEAK: office % sees another office', r.o; end if;
    if pg_temp.as_id('fz_office_agent', r.c, 'select count(distinct request_type)::text from public.fz_approval_queue') <> 'OK:2' then raise exception 'K3 office % does not see both types', r.o; end if;
  end loop;
  foreach d in array array[jsonb_build_object('r', 'fz_office_agent', 'c', pg_temp.cl('office:wolf-squad:manager', 'fz_office_agent')), jsonb_build_object('r', 'fz_office_agent', 'c', pg_temp.cl(AI, 'fz_jarvis')),
                           jsonb_build_object('r', 'fz_office_agent', 'c', pg_temp.cl(AI, 'fz_office_agent', '{"sub": "99999999-9999-9999-9999-99999999f003"}')),
                           jsonb_build_object('r', 'fz_office_agent', 'c', pg_temp.cl(AI, 'fz_office_agent', '{"office": "donna"}')),
                           jsonb_build_object('r', 'fz_jarvis', 'c', pg_temp.cl(AI, 'fz_jarvis')), jsonb_build_object('r', 'fz_office_agent', 'c', pg_temp.cl('nobody', 'fz_office_agent'))] loop
    if pg_temp.as_id(d ->> 'r', d -> 'c', 'select count(*)::text from public.fz_approval_queue') <> 'OK:0' then raise exception 'K3 refused token reads the queue: %', d; end if;
  end loop;
  foreach res in array array['fz_jarvis', 'fz_auditor'] loop
    if pg_temp.as_id(res, case res when 'fz_jarvis' then cj else cu end, 'select count(*)::text from public.fz_approval_queue') <> 'OK:' || (select count(*) from public.fz_approval_queue) then raise exception 'K3 % does not see all', res; end if;
  end loop;
  foreach res in array array['anon', 'authenticated'] loop
    if pg_temp.as_id(res, ca, 'select count(*)::text from public.fz_approval_queue') not like 'ERR:permission denied%' then raise exception 'K3 % reads the queue', res; end if;
    if has_table_privilege(res, 'public.fz_approval_queue', 'select') then raise exception 'K3 % holds select on the queue', res; end if;
  end loop;

  -- K4 no scoped role (valid, dormant or forged token) can approve, consume or modify a decision
  foreach d in array array[jsonb_build_object('r', 'fz_office_agent', 'c', ca), jsonb_build_object('r', 'fz_jarvis', 'c', cj), jsonb_build_object('r', 'fz_auditor', 'c', cu),
                           jsonb_build_object('r', 'fz_office_agent', 'c', pg_temp.cl('office:wolf-squad:manager', 'fz_office_agent')),
                           jsonb_build_object('r', 'fz_office_agent', 'c', pg_temp.cl(AI, 'fz_office_agent', '{"sub": "99999999-9999-9999-9999-99999999f003"}'))] loop
    foreach res in array array[format($q$update public.approval_requests set status = 'approved' where id = %L$q$, ra), format($q$update public.fz_office_money_proposals set status = 'executed' where id = %L$q$, pa),
                               format($q$update public.fz_approval_queue set status = 'approved' where source_id = %L$q$, ra), format($q$delete from public.approval_requests where id = %L$q$, ra),
                               format($q$insert into public.approval_requests (actor, action, recommendation, status) values ('x', 'take_loan', 'x', 'approved')$q$),
                               format($q$select public.fz_owner_decide_office_proposal(%L, true)::text$q$, pa), $q$select public.fz_queue_expire()::text$q$,
                               $q$select public.fz_prepare_office_payment('x', 'Payee', 100, 'a purpose', 'none', null, 'fzq-ven-a')::text$q$,
                               format($q$select public.fz_propose_office_money('b2b-records', 'allocate', 100, null, 'scoped proposal attempt', 'x')::text$q$)] loop
      if pg_temp.as_id(d ->> 'r', d -> 'c', res) not like 'ERR:%' then raise exception 'K4 % ran: %', d, res; end if;
    end loop;
  end loop;
  -- even with a grant added by mistake, the scoped roles are refused before anything runs
  grant execute on function public.fz_queue_expire(integer), public.fz_prepare_office_payment(text, text, integer, text, text, date, text) to fz_jarvis;
  if pg_temp.as_id('fz_jarvis', cj, $q$select public.fz_queue_expire()::text$q$) not like 'ERR:the approval queue is maintained on the service path only%' then raise exception 'K4 scoped expiry'; end if;
  if pg_temp.as_id('fz_jarvis', cj, $q$select public.fz_prepare_office_payment('x', 'Payee', 100, 'a purpose', 'none', null, 'fzq-ven-a')::text$q$) not like 'ERR:the office payment gate is service-path only%' then raise exception 'K4 scoped payment'; end if;
  revoke execute on function public.fz_queue_expire(integer), public.fz_prepare_office_payment(text, text, integer, text, text, date, text) from fz_jarvis;
  -- a scoped preview of an APPROVED request never consumes it
  update public.approval_requests set status = 'approved', decided_at = now() where id = ra;
  if pg_temp.as_id('fz_jarvis', cj, $q$select public.fz_authorize_action('take_loan', 0, 'fzq-a')::text$q$) not like '%ask_owner%' then raise exception 'K4 scoped preview'; end if;
  if (select status from public.approval_requests where id = ra) <> 'approved' then raise exception 'K4 a scoped call consumed an approval'; end if;
  if (select status from public.fz_office_money_proposals where id = pa) <> 'pending' then raise exception 'K4 a scoped call changed a proposal'; end if;
  -- M1 allowlist unchanged; no M3 function for anyone but the service path
  foreach res in array array['fz_jarvis', 'fz_office_agent', 'fz_auditor'] loop
    got := array(select p.oid::regprocedure::text from pg_proc p where p.pronamespace = 'public'::regnamespace and has_function_privilege(res, p.oid, 'execute') order by 1);
    if got <> array(select x from unnest(case res when 'fz_auditor' then allow_a else allow_a || array['fz_authorize_action(text,integer,text,text,text,uuid,uuid,jsonb)'] end) x order by 1) then
      raise exception 'K4 the M1 allowlist of % changed: %', res, got; end if;
  end loop;
  foreach res in array array['anon', 'authenticated', 'fz_jarvis', 'fz_office_agent', 'fz_auditor'] loop
    if exists (select 1 from pg_proc p where p.pronamespace = 'public'::regnamespace and p.proname in ('fz_queue_expire', 'fz_queue_audit_proposal', 'fz_prepare_office_payment') and has_function_privilege(res, p.oid, 'execute')) then
      raise exception 'K4 % executes an M3 function', res; end if;
    if has_table_privilege(res, 'public.fz_approval_queue', 'insert,update,delete,truncate,references,trigger') then raise exception 'K4 % can write the queue', res; end if;
  end loop;

  -- K5 decisions only through the existing owner paths, and the queue reflects them: the Telegram tap's update (hq_policy.decide_approval) then authorize_action consumes it
  -- once; a money proposal through fz_owner_decide_office_proposal (the bot is refused)
  if (select status from public.fz_approval_queue where source_id = ra) <> 'approved' then raise exception 'K5 approved not shown'; end if;
  update public.system_state set mode = 'auto_in_caps' where id = 1;
  d := public.authorize_action('fzq-agent-a', 'take_loan', 0, 'fzq-a');
  if d ->> 'decision' <> 'allow' or (select status from public.fz_approval_queue where source_id = ra) <> 'used' then raise exception 'K5 consumed approval not shown as used: % / %', d, (select to_jsonb(q) from public.fz_approval_queue q where source_id = ra); end if;
  if pg_temp.svc(format($q$select public.fz_owner_decide_office_proposal(%L, true)::text$q$, pa)) not like 'ERR:owner approval required%' then raise exception 'K5 the bot decided a money proposal'; end if;
  perform public.fz_owner_decide_office_proposal(pa, true);
  if (select status from public.fz_approval_queue where source_id = pa) <> 'executed' then raise exception 'K5 executed proposal not shown'; end if;
  if not exists (select 1 from public.audit_log where action = 'office_money_executed' and target = 'fz_office_money_proposals/' || pa and detail ->> 'from' = 'pending') then raise exception 'K5 execution not audited by the queue trigger'; end if;
  perform public.fz_owner_decide_office_proposal(pb, false, 'no');
  if (select status from public.fz_approval_queue where source_id = pb) <> 'rejected' or not exists (select 1 from public.audit_log where action = 'office_money_rejected' and target = 'fz_office_money_proposals/' || pb) then raise exception 'K5 rejection'; end if;

  -- K6 one expiry rule + cap, every change audited, nothing deleted
  select count(*) into n from public.approval_requests; select count(*) into n2 from public.fz_office_money_proposals;
  update public.approval_requests set expires_at = now() - interval '1 minute' where id = rb;
  if (select status from public.fz_approval_queue where source_id = rb) <> 'expired' then raise exception 'K6 an overdue request is not shown expired before the job runs'; end if;
  if public.authorize_action('fzq-agent-b', 'sign_contract', 0, 'fzq-b') ->> 'decision' <> 'ask_owner' then raise exception 'K6 (control) an expired request was usable'; end if;
  pa := (public.fz_propose_office_money('donna', 'allocate', 100, null, 'will expire before the owner looks', 'jarvis') ->> 'proposal')::uuid;
  update public.fz_office_money_proposals set expires_at = now() - interval '1 minute' where id = pa;
  for c in 1..7 loop
    insert into public.approval_requests (actor, action, cents, ref, recommendation, created_at) values ('fzq-agent-a', 'acquire_business', 0, 'fzq-cap-' || c, 'cap test', now() - make_interval(mins => 10 - c));
  end loop;
  res := pg_temp.svc('select public.fz_queue_expire()::text');
  if res !~ '^OK:\d+$' or substr(res, 4)::int < 4 then raise exception 'K6 expire count (at least 1 overdue request + 1 overdue proposal + 2 over the cap): %', res; end if;
  if (select status from public.approval_requests where id = rb) <> 'expired' or (select status from public.fz_office_money_proposals where id = pa) <> 'expired' then raise exception 'K6 overdue not expired'; end if;
  if (select string_agg(ref || ':' || status, ',' order by ref) from public.approval_requests where ref like 'fzq-cap-%')
     <> 'fzq-cap-1:expired,fzq-cap-2:expired,fzq-cap-3:pending,fzq-cap-4:pending,fzq-cap-5:pending,fzq-cap-6:pending,fzq-cap-7:pending' then raise exception 'K6 cap kept the wrong requests'; end if;
  if (select count(*) from public.audit_log where action = 'approval_expired' and target in (select 'approval_requests/' || id from public.approval_requests where ref in ('fzq-b', 'fzq-cap-1', 'fzq-cap-2'))) <> 3 then raise exception 'K6 expiry not audited per request'; end if;
  if not exists (select 1 from public.audit_log where action = 'office_money_expired' and target = 'fz_office_money_proposals/' || pa) then raise exception 'K6 proposal expiry not audited'; end if;
  if (select count(*) from public.approval_requests) <> n + 7 or (select count(*) from public.fz_office_money_proposals) <> n2 + 1 then raise exception 'K6 history deleted'; end if;
  if pg_temp.svc('select public.fz_queue_expire()::text') <> 'OK:0' then raise exception 'K6 expiry not idempotent'; end if;
  if pg_temp.svc($q$select count(*)::text from public.fz_approval_queue where status = 'pending'$q$) not like 'OK:%' then raise exception 'K6 the bot cannot read the queue'; end if;
  if not exists (select 1 from cron.job where jobname = 'fz-queue-expire') then raise exception 'K6 expiry job not scheduled'; end if;

  -- K7 office payment gate only refuses: dormant / short refused; a funded office and the group get exactly prepare_payment()'s decision (modes x amounts, each undone)
  if pg_temp.svc($q$select public.fz_prepare_office_payment('fzq', 'Payee', 100, 'a purpose', 'none', null, 'fzq-ven-c')::text$q$) !~ 'is dormant: its actions are refused' then raise exception 'K7 dormant office paid (or refused for another reason)'; end if;
  if pg_temp.svc($q$select public.fz_prepare_office_payment('fzq', 'Payee', 100, 'a purpose', 'none', null, 'fzq-ven-b')::text$q$) !~ 'has \$0.00 available' then raise exception 'K7 office at $0 paid'; end if;
  perform public.fz_owner_allocate('b2b-records', 500000, 'payment matrix');
  n := 0;
  foreach st in array array['dry_run', 'approve_first', 'auto_in_caps'] loop
    foreach c in array array[0, 100, 2000, 2600, 999999] loop
      foreach res in array array['fzq-ven-a', 'fzq-ven-g', null] loop
        begin update public.system_state set mode = st where id = 1; d := public.prepare_payment('fzq', 'Payee', c, 'a purpose', 'none', null, res); raise exception using errcode = 'ZFZ01';
        exception when sqlstate 'ZFZ01' then null; end;
        begin update public.system_state set mode = st where id = 1; d2 := public.fz_prepare_office_payment('fzq', 'Payee', c, 'a purpose', 'none', null, res); raise exception using errcode = 'ZFZ01';
        exception when sqlstate 'ZFZ01' then null; end;
        if c > 500000 and res = 'fzq-ven-a' then
          if d2 ->> 'decision' <> 'deny' then raise exception 'K7 over the office balance not refused'; end if;
        elsif (d ->> 'decision', d ->> 'reason') is distinct from (d2 ->> 'decision', d2 ->> 'reason') then raise exception 'K7 differs from prepare_payment at %/%/%: % vs %', st, c, res, d, d2; end if;
        if d2 ->> 'decision' = 'allow' and d ->> 'decision' <> 'allow' then raise exception 'K7 the office path allowed more'; end if;
        if d ->> 'decision' = 'allow' then n := n + 1; end if;
      end loop;
    end loop;
  end loop;
  if n < 3 then raise exception 'K7 vacuous: % allow points', n; end if;
  raise notice 'K7 % prepare_payment allow points matched by the office path', n;
  -- a real one: reserved, waiting for the owner, and counted against the office
  select reserved_cents into n from public.fz_office_money where office = 'b2b-records';
  d := public.fz_prepare_office_payment('fzq', 'Payee', 1500, 'a purpose', 'none', null, 'fzq-ven-a');
  if d ->> 'decision' <> 'allow' or (select reserved_cents from public.fz_office_money where office = 'b2b-records') <> n + 1500 then raise exception 'K7 office payment not reserved against the office: %', d; end if;
  if not exists (select 1 from public.owner_messages where ref_table = 'payment_instructions' and ref_id = (d ->> 'instruction_id')::uuid and needs_decision) then raise exception 'K7 the owner was not asked (existing path)'; end if;
  -- the money tables keep exactly their triggers
  if (select string_agg(g.tgrelid::regclass::text || '.' || g.tgname, ' ' order by g.tgrelid::regclass::text, g.tgname) from pg_trigger g where not g.tgisinternal and g.tgrelid::regclass::text in
        ('ledger', 'llm_calls', 'spend_reservations', 'capital_policy', 'action_policy', 'system_state', 'approval_requests', 'action_log', 'bank_accounts', 'bank_balances',
         'bank_transactions', 'payment_instructions', 'waterfall_policy', 'model_prices', 'tool_registry', 'executor_registry', 'executor_runs'))
     <> 'action_policy.action_policy_audit action_policy.action_policy_no_delete bank_balances.bank_balance_guard capital_policy.capital_policy_guard llm_calls.llm_calls_executor_guard waterfall_policy.waterfall_policy_guard' then
    raise exception 'K7 the triggers on the money tables changed'; end if;
  if public.backup_export_policy() -> 'unclassified' <> '[]'::jsonb or exists (select 1 from public.fz_unregistered_tables()) then raise exception 'K7 backup / registry'; end if;
  raise notice 'approvals_kernel_check: behaviour checks passed';
end $$;

-- K9 review fixes (each fails on the version before the fix)
do $$
declare A uuid := 'f0000000-0000-4000-8000-000000000001'; d1 jsonb; d2 jsonb; al boolean; cap int; dl int; n int; c0 int; res text; msg text; pid uuid; c int;
begin
  update public.system_state set mode = 'auto_in_caps', kill_switch = false where id = 1;
  update public.action_policy set max_count_per_day = 50, updated_by = 'owner:test' where action = 'payment_instruction';   -- room at group level (rolled back)
  -- fix 1: the payment gate applies M1's office layer: never allows what fz_authorize_action refuses (allowed x cap x daily), each point undone
  n := 0;
  foreach al in array array[true, false] loop
    foreach cap in array array[null, 50, 20000] loop
      foreach dl in array array[null, 0, 5] loop
        perform public.fz_set_office_policy('b2b-records', 'payment_instruction', al, cap, dl, 'owner');
        begin d1 := public.fz_authorize_action('payment_instruction', 100, 'fzq-k9', 'b2b-records', 'fzq'); raise exception using errcode = 'ZFZ01'; exception when sqlstate 'ZFZ01' then null; end;
        begin d2 := public.fz_prepare_office_payment('fzq', 'Payee', 100, 'a purpose', 'none', null, 'fzq-ven-a'); raise exception using errcode = 'ZFZ01'; exception when sqlstate 'ZFZ01' then null; end;
        if d2 ->> 'decision' = 'allow' and d1 ->> 'decision' <> 'allow' then raise exception 'K9/1 the payment gate allowed what fz_authorize_action refused (allowed %, cap %, daily %): % vs %', al, cap, dl, d2, d1; end if;
        if d1 ->> 'decision' <> 'allow' then n := n + 1; end if;
      end loop;
    end loop;
  end loop;
  if n < 10 then raise exception 'K9/1 vacuous: % refused points', n; end if;
  -- fix 1: an allowed office payment is labelled with the office, so the office daily count counts it
  delete from public.fz_office_action_policy where office_id = A and action = 'payment_instruction';
  select count(*) into c0 from public.action_log where action = 'payment_instruction' and decision = 'allow' and detail ->> 'office' = 'b2b-records'
     and at >= date_trunc('day', now() at time zone 'America/Toronto') at time zone 'America/Toronto';
  perform public.fz_set_office_policy('b2b-records', 'payment_instruction', true, null, c0 + 1, 'owner');
  d2 := public.fz_prepare_office_payment('fzq', 'Payee', 100, 'a purpose', 'none', null, 'fzq-ven-a');
  if d2 ->> 'decision' <> 'allow' then raise exception 'K9/1 first payment refused: %', d2; end if;
  if (select a.how from public.payment_instructions i join public.fz_money_attribution a on a.source = 'reservation' and a.source_id = i.reservation_id where i.id = (d2 ->> 'instruction_id')::uuid) <> 'office_gate' then
    raise exception 'K9/1 payment reservation not stamped to the office'; end if;
  d2 := public.fz_prepare_office_payment('fzq', 'Payee', 100, 'a purpose', 'none', null, 'fzq-ven-a');
  if d2 ->> 'decision' <> 'deny' or d2 ->> 'reason' not like '%daily limit%' then raise exception 'K9/1 office daily count does not see gate payments: %', d2; end if;
  delete from public.fz_office_action_policy where office_id = A and action = 'payment_instruction';
  -- fix 4: the bot's key cannot choose the cap (5 stays); the owner / database session can
  for c in 1..3 loop
    insert into public.approval_requests (actor, action, cents, ref, recommendation, created_at) values ('fzq-agent-a', 'close_venture', 0, 'fzq-k9-' || c, 'cap 1 test', now() - make_interval(mins => 10 - c));
  end loop;
  perform pg_temp.svc('select public.fz_queue_expire(1)::text');
  if (select count(*) from public.approval_requests where ref like 'fzq-k9-%' and status = 'pending') <> 3 then raise exception 'K9/4 the bot mass-expired requests with its own cap'; end if;
  perform public.fz_queue_expire(1);                                       -- the database session (as the cron job)
  if (select count(*) from public.approval_requests where ref like 'fzq-k9-%' and status = 'pending') <> 1 then raise exception 'K9/4 the owner cap was not honoured'; end if;
  -- fix 5: a rejection is audited exactly once
  pid := (public.fz_propose_office_money('donna', 'clawback', 100, null, 'rejection audit count check', 'jarvis') ->> 'proposal')::uuid;
  perform public.fz_owner_decide_office_proposal(pid, false, 'no');
  if (select count(*) from public.audit_log where target = 'fz_office_money_proposals/' || pid and action = 'office_money_rejected') <> 1 then raise exception 'K9/5 rejection not audited exactly once'; end if;
  -- fix 7: anyone who is neither the service path nor scoped sees nothing, even with a mistaken grant
  grant select on public.fz_approval_queue to anon;
  grant execute on function public.is_group_scope(), public.current_office_id() to anon;   -- so the check cannot pass on a 'permission denied for function'
  msg := pg_temp.as_id('anon', null, 'select count(*)::text from public.fz_approval_queue');
  if msg <> 'OK:0' then raise exception 'K9/7 anon with a mistaken grant sees rows: %', msg; end if;
  revoke select on public.fz_approval_queue from anon;
  revoke execute on function public.is_group_scope(), public.current_office_id() from anon;
  raise notice 'approvals_kernel_check: review fixes 1, 4, 5, 7 checked';
end $$;

-- K8 on the state the checks left: rolling M3 back changes no money control, deletes no request / proposal, keeps a queue snapshot
create temp table fzq_fp_test as select * from pg_temp.fz_money_fp();
create temp table fzq_counts as select (select count(*) from public.approval_requests) a, (select count(*) from public.fz_office_money_proposals) p, (select count(*) from public.fz_approval_queue) q;
\ir ../ops/rollback_approvals_kernel.sql
create temp table fzq_fp_test_without as select * from pg_temp.fz_money_fp();
do $$
begin
  if exists (select 1 from fzq_fp_test w full join fzq_fp_test_without o using (k) where w.v is distinct from o.v) then raise exception 'K8 the rollback changed the money controls'; end if;
  if (select a from fzq_counts) <> (select count(*) from public.approval_requests) or (select p from fzq_counts) <> (select count(*) from public.fz_office_money_proposals) then raise exception 'K8 the rollback deleted history'; end if;
  if not exists (select 1 from public.audit_log where action = 'approval_queue_export' and jsonb_array_length(detail -> 'rows') = (select q from fzq_counts)) then raise exception 'K8 no queue snapshot'; end if;
  raise notice 'approvals_kernel_check: all checks passed';
end $$;
rollback;
