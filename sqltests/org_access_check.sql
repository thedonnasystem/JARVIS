-- Org & Access M1 (migrations/20261127_org_access_v1.sql). Everything in one transaction, rolled back. Run on a fresh apply (scripts/replica/run.sh does).
-- Proves: office A sees 0 rows of office B on EVERY office-owned table (and exactly its own); office identities cannot call owner-only or money functions; Jarvis cannot
-- approve; anon / authenticated gain nothing; service_role keeps all rows; the registry covers every table; the re-seed archived without deleting; tokens are checked.
begin;
grant usage on schema public to anon, authenticated, service_role;   -- as on Supabase (inside the rolled-back transaction)

-- run p_sql as a scoped identity: the role PostgREST would switch to + the JWT claims it would set. No signed-in owner (app.uid cleared).
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
-- claims of a freshly minted token for an identity
create function pg_temp.cl(p_identity text, p_role text, p_extra jsonb default '{}'::jsonb) returns jsonb language sql as $$
  select jsonb_build_object('role', p_role, 'identity', p_identity, 'iat', floor(extract(epoch from now())), 'exp', floor(extract(epoch from now())) + 3600) || p_extra
$$;
-- the client workspaces an office serves (no row in fz_workspace_offices = ff-marketing)
create function pg_temp.ws_of(p_office uuid) returns uuid[] language sql as $$
  select coalesce(array(select w.id from public.client_workspaces w left join public.fz_workspace_offices m on m.workspace_id = w.id
                         where coalesce(m.office_id, 'f0000000-0000-4000-8000-000000000007') = p_office), '{}')
$$;
-- the bot: service_role, no signed-in user
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
-- the signed-in owner (synthetic auth user, as the other sqltests)
insert into auth.users (id, email) values ('99999999-9999-9999-9999-99999999f001', 'fz-owner@example.invalid') on conflict do nothing;
insert into public.app_owners (email) values ('fz-owner@example.invalid') on conflict do nothing;
select set_config('app.uid', '99999999-9999-9999-9999-99999999f001', true);

do $$
declare
  A uuid := 'f0000000-0000-4000-8000-000000000001';   -- b2b-records
  B uuid := 'f0000000-0000-4000-8000-000000000002';   -- donna
  AI text := 'office:b2b-records:manager'; BI text := 'office:donna:manager';
  ca jsonb; cb jsonb; cj jsonb; cu jsonb; res text; r record; vis bigint; exp bigint; oth bigint; ins text; n int; wa uuid; wb uuid; ta uuid; tb uuid; cpa uuid; cpb uuid;
  allow_j text[]; allow_o text[]; allow_a text[]; got text[]; d jsonb; tested int := 0; nonvacuous int := 0;
begin
  ca := pg_temp.cl(AI, 'fz_office_agent'); cb := pg_temp.cl(BI, 'fz_office_agent'); cj := pg_temp.cl('jarvis', 'fz_jarvis'); cu := pg_temp.cl('auditor', 'fz_auditor');

  -- O1 seed: the group + eight dormant offices; office identities dormant
  if (select count(*) from public.fz_offices where kind = 'office') <> 8 then raise exception 'O1 expected 8 offices'; end if;
  if exists (select 1 from public.fz_offices where kind = 'office' and status <> 'dormant') then raise exception 'O1 an office does not start dormant'; end if;
  if (select string_agg(slug, ',' order by slug) from public.fz_offices where kind = 'office') <> 'b2b-records,donna,ff-marketing,fruition-factory,monopoly,pimp-ai,the-trap,wolf-squad' then raise exception 'O1 office slugs'; end if;
  if exists (select 1 from public.fz_identities where kind = 'office_manager' and status <> 'dormant') then raise exception 'O1 an office identity does not start dormant'; end if;
  if exists (select 1 from public.fz_identities where slug in ('jarvis-chat', 'jarvis-core', 'jarvis-hands') and status <> 'dormant') then raise exception 'O1 unminted Jarvis helper identities must start dormant'; end if;
  if (select count(*) from public.fz_identities where slug in ('owner', 'jarvis', 'jarvis-chat', 'jarvis-core', 'jarvis-hands', 'auditor', 'backup-reader', 'release')) <> 8 then raise exception 'O1 core identities missing'; end if;

  -- O2 a dormant office identity gets nothing
  res := pg_temp.as_id('fz_office_agent', ca, 'select public.fz_whoami()::text');
  if res not like 'OK:%"ok": false%' then raise exception 'O2 dormant identity accepted: %', res; end if;
  if pg_temp.as_id('fz_office_agent', ca, 'select count(*)::text from public.agents') <> 'OK:0' then raise exception 'O2 dormant identity sees agents'; end if;

  -- O3 only the signed-in owner activates offices / identities (bot refused; scoped roles cannot even call it)
  if pg_temp.svc($q$select public.fz_owner_set_office_status('b2b-records', 'active')::text$q$) not like 'ERR:owner approval required%' then raise exception 'O3 bot activated an office'; end if;
  if pg_temp.svc($q$select public.fz_owner_set_identity('office:b2b-records:manager', 'active')::text$q$) not like 'ERR:owner approval required%' then raise exception 'O3 bot activated an identity'; end if;
  if pg_temp.as_id('fz_jarvis', cj, $q$select public.fz_owner_set_office_status('b2b-records', 'active')::text$q$) not like 'ERR:permission denied%' then raise exception 'O3 jarvis can call an owner function'; end if;
  perform public.fz_owner_set_office_status(s, 'active') from unnest(array['b2b-records', 'donna', 'ff-marketing']) s;
  perform public.fz_owner_set_identity(s, 'active') from unnest(array[AI, BI, 'office:ff-marketing:manager']) s;
  if (select count(*) from public.audit_log where action in ('office_status', 'identity_status') and actor = 'owner') < 6 then raise exception 'O3 owner changes not audited'; end if;
  res := pg_temp.as_id('fz_office_agent', ca, 'select public.fz_whoami()::text');
  if res not like 'OK:%"ok": true%' or res not like '%"office": "b2b-records"%' or res not like '%"scope": "office"%' then raise exception 'O3 active identity not resolved: %', res; end if;
  if pg_temp.as_id('fz_jarvis', cj, 'select public.current_office() || public.is_group_scope()::text') <> 'OK:grouptrue' then raise exception 'O3 jarvis is not group scope'; end if;

  -- O4 fixtures in office A and office B on every office_id table, plus two client workspaces with children
  insert into public.agents (slug, title, office_id) values ('fz-test-a', 'Office A agent', A), ('fz-test-b', 'Office B agent', B);
  insert into public.departments (slug, name, kind, office_id) values ('fz-dept-a', 'Dept A', 'shared', A), ('fz-dept-b', 'Dept B', 'shared', B);
  insert into public.ventures (slug, name, kind, office_id) values ('fz-ven-a', 'Venture A', 'lab', A), ('fz-ven-b', 'Venture B', 'lab', B);
  insert into public.missions (title, objective, office_id) values ('Mission A', 'Office A mission objective', A), ('Mission B', 'Office B mission objective', B);
  insert into public.tasks (title, office_id) values ('Task A', A) returning id into ta;
  insert into public.tasks (title, office_id) values ('Task B', B) returning id into tb;
  insert into public.memory (kind, content, office_id) values ('lesson', 'office A lesson', A), ('lesson', 'office B lesson', B);
  insert into public.client_workspaces (slug, name, vertical, status) values ('fz-ws-a', 'Office A Client', 'mortgage', 'active') returning id into wa;
  insert into public.client_workspaces (slug, name, vertical, status) values ('fz-ws-b', 'Office B Client', 'mortgage', 'active') returning id into wb;
  if pg_temp.svc(format($q$select public.fz_owner_set_workspace_office(%L, 'b2b-records')::text$q$, wa)) not like 'ERR:owner approval required%' then raise exception 'O4 bot moved a workspace'; end if;
  perform public.fz_owner_set_workspace_office(wa, 'b2b-records');
  perform public.fz_owner_set_workspace_office(wb, 'donna');
  insert into public.ws_campaigns (workspace_id, name) values (wa, 'A campaign') returning id into cpa;
  insert into public.ws_campaigns (workspace_id, name) values (wb, 'Spring promo') returning id into cpb;
  insert into public.ws_leads (workspace_id, campaign_id, name, source) values (wa, cpa, 'Pat Example', 'web form'), (wb, cpb, 'Sam Example', 'web form');
  insert into public.ws_ledger (workspace_id, campaign_id, amount_cents) values (wa, cpa, 100), (wb, cpb, 200);

  -- O5 isolation on EVERY office-owned table of the registry: each office sees exactly its own rows and 0 rows of any other office; tables without scoped read are refused
  for r in select g.*, to_regclass('public.' || quote_ident(g.relname)) t from public.fz_table_registry g where g.scope = 'office' order by g.relname loop
    continue when r.t is null;
    if not r.fz_read then
      if pg_temp.as_id('fz_office_agent', ca, format('select count(*)::text from %s', r.t)) not like 'ERR:permission denied%' then raise exception 'O5 % has no scoped read but office A can select it', r.relname; end if;
      if pg_temp.as_id('fz_jarvis', cj, format('select count(*)::text from %s', r.t)) not like 'ERR:permission denied%' then raise exception 'O5 % has no scoped read but jarvis can select it', r.relname; end if;
      continue;
    end if;
    tested := tested + 1;
    for d in select jsonb_build_object('claims', x.c, 'office', x.o) from (values (ca, A), (cb, B)) x (c, o) loop
      ins := case r.scope_column when 'office_id' then 'office_id = ' || quote_literal(d ->> 'office')
                                 when 'workspace_self' then 'id = any (' || quote_literal(pg_temp.ws_of((d ->> 'office')::uuid)) || '::uuid[])'
                                 else 'workspace_id = any (' || quote_literal(pg_temp.ws_of((d ->> 'office')::uuid)) || '::uuid[])' end;   -- computed here: the scoped role cannot read the map
      execute format('select count(*) from %s where %s', r.t, ins) into exp;
      res := pg_temp.as_id('fz_office_agent', d -> 'claims', format('select count(*)::text from %s', r.t));
      if res !~ '^OK:\d+$' then raise exception 'O5 % select failed: %', r.relname, res; end if;
      vis := substr(res, 4)::bigint;
      res := pg_temp.as_id('fz_office_agent', d -> 'claims', format('select count(*)::text from %s where not (%s)', r.t, ins));
      oth := substr(res, 4)::bigint;
      if oth <> 0 then raise exception 'O5 LEAK: office % sees % rows of another office in %', d ->> 'office', oth, r.relname; end if;
      if vis <> exp then raise exception 'O5 office % sees % rows of % but owns %', d ->> 'office', vis, r.relname, exp; end if;
      if exp > 0 then nonvacuous := nonvacuous + 1; end if;
    end loop;
  end loop;
  if tested < 6 then raise exception 'O5 only % office tables tested', tested; end if;
  if nonvacuous < 12 then raise exception 'O5 vacuous: only % (table, office) pairs had rows', nonvacuous; end if;
  raise notice 'O5 isolation: % office-owned readable tables x 2 offices, % non-empty pairs, 0 cross-office rows', tested, nonvacuous;

  -- O6 group scope: Jarvis and the auditor read every office's rows, except client personal data (client_restricted)
  for r in select g.*, to_regclass('public.' || quote_ident(g.relname)) t from public.fz_table_registry g where g.scope = 'office' and g.fz_read order by g.relname loop
    continue when r.t is null;
    if r.scope_column = 'workspace_id' then execute format('select count(*) from %s where workspace_id in (select id from public.client_workspaces)', r.t) into exp;
    else execute format('select count(*) from %s', r.t) into exp; end if;
    if r.data_class = 'client_restricted' then exp := 0; end if;
    if pg_temp.as_id('fz_jarvis', cj, format('select count(*)::text from %s', r.t)) <> 'OK:' || exp then raise exception 'O6 jarvis on % expected %', r.relname, exp; end if;
    if pg_temp.as_id('fz_auditor', cu, format('select count(*)::text from %s', r.t)) <> 'OK:' || exp then raise exception 'O6 auditor on % expected %', r.relname, exp; end if;
  end loop;
  -- the FF Marketing client tables keep their reviewed design in M1 (RLS on, no policy, service key only): no scoped identity reads them, the workspace map is ready for M2
  foreach res in array array['client_workspaces', 'ws_leads', 'ws_campaigns', 'ffm_creatives', 'ffm_consent_captures'] loop
    if pg_temp.as_id('fz_office_agent', ca, format('select count(*)::text from public.%I', res)) not like 'ERR:permission denied%' then raise exception 'O6 office A reads %', res; end if;
    if pg_temp.as_id('fz_jarvis', cj, format('select count(*)::text from public.%I', res)) not like 'ERR:permission denied%' then raise exception 'O6 jarvis reads %', res; end if;
    if exists (select 1 from pg_policy where polrelid = ('public.' || res)::regclass) then raise exception 'O6 a policy on %', res; end if;
  end loop;
  if pg_temp.ws_of(A) <> array[wa] or pg_temp.ws_of(B) <> array[wb] or not wa <> all (pg_temp.ws_of('f0000000-0000-4000-8000-000000000007')) then raise exception 'O6 workspace map'; end if;
  if pg_temp.as_id('fz_office_agent', ca, $q$select coalesce(array_length(public.fz_readable_workspaces('ws_leads'), 1), 0)::text$q$) <> 'OK:0' then raise exception 'O6 workspace helper opens a closed table'; end if;
  -- every scoped identity reads the office list and the registry; nobody scoped reads identities
  if pg_temp.as_id('fz_office_agent', ca, 'select count(*)::text from public.fz_offices') <> 'OK:9' then raise exception 'O6 office list'; end if;
  if pg_temp.as_id('fz_office_agent', ca, 'select (count(*) > 100)::text from public.fz_table_registry') <> 'OK:true' then raise exception 'O6 registry not readable'; end if;
  if pg_temp.as_id('fz_jarvis', cj, 'select count(*)::text from public.fz_identities') not like 'ERR:permission denied%' then raise exception 'O6 identities readable'; end if;

  -- O7 writes: tasks only; office stamped; author stamped; no cross-office write, no delete, no protected columns
  res := pg_temp.as_id('fz_office_agent', ca, format($q$insert into public.tasks (title, office_id) values ('A writes into B', %L) returning office_id::text || '|' || created_by || '|' || status$q$, B));
  if res <> 'OK:' || A || '|' || AI || '|todo' then raise exception 'O7 office A insert was not pinned to office A: %', res; end if;
  if pg_temp.as_id('fz_office_agent', ca, format($q$with u as (update public.tasks set detail = 'x' where id = %L returning 1) select count(*)::text from u$q$, tb)) <> 'OK:0' then raise exception 'O7 office A updated office B task'; end if;
  if pg_temp.as_id('fz_office_agent', ca, format($q$with u as (update public.tasks set detail = 'more detail', priority = 2 where id = %L returning 1) select count(*)::text from u$q$, ta)) <> 'OK:1' then raise exception 'O7 office A cannot update its own task'; end if;
  -- S1: no status / result writes (a "done" task with a crafted result is engine input), no task for an agent of another office or the group, no mission tasks
  if pg_temp.as_id('fz_office_agent', ca, format($q$update public.tasks set status = 'done' where id = %L$q$, ta)) not like 'ERR:permission denied%' then raise exception 'O7 status writable'; end if;
  if pg_temp.as_id('fz_office_agent', ca, format($q$update public.tasks set result = 'x' where id = %L$q$, ta)) not like 'ERR:permission denied%' then raise exception 'O7 result writable'; end if;
  if pg_temp.as_id('fz_office_agent', ca, $q$insert into public.tasks (title, status, result) values ('pre-done', 'done', 'x')$q$) not like 'ERR:permission denied%' then raise exception 'O7 status / result insertable'; end if;
  foreach res in array array['builder', 'jarvis-hands', 'fz-test-b'] loop
    if pg_temp.as_id('fz_office_agent', ca, format($q$insert into public.tasks (title, assigned_agent) values ('deputy', %L)$q$, res)) not like 'ERR:new row violates row-level security%' then raise exception 'O7 office A assigned a task to %', res; end if;
    if pg_temp.as_id('fz_office_agent', ca, format($q$update public.tasks set assigned_agent = %L where id = %L$q$, res, ta)) not like 'ERR:new row violates row-level security%' then raise exception 'O7 office A reassigned its task to %', res; end if;
  end loop;
  if pg_temp.as_id('fz_office_agent', ca, $q$insert into public.tasks (title, assigned_agent) values ('own agent', 'fz-test-a') returning assigned_agent$q$) <> 'OK:fz-test-a' then raise exception 'O7 office A cannot assign its own agent'; end if;
  if pg_temp.as_id('fz_jarvis', cj, format($q$insert into public.tasks (title, office_id, assigned_agent) values ('cross', %L, 'builder')$q$, B)) not like 'ERR:new row violates row-level security%' then raise exception 'O7 jarvis put a group agent on an office task'; end if;
  if pg_temp.as_id('fz_jarvis', cj, $q$insert into public.tasks (title, office_id) values ('dormant office', 'f0000000-0000-4000-8000-000000000004')$q$) not like 'ERR:new row violates row-level security%' then raise exception 'O7 jarvis wrote into a dormant office (N2)'; end if;
  insert into public.missions (title, objective) values ('Mission G', 'Group mission objective') returning id into wb;
  insert into public.tasks (title, mission_id) values ('mission step', wb) returning id into tb;
  if pg_temp.as_id('fz_jarvis', cj, format($q$update public.tasks set detail = 'injected' where id = %L$q$, tb)) not like 'ERR:scoped write refused: mission tasks%' then raise exception 'O7 jarvis edited a mission task'; end if;
  select id into tb from public.tasks where title = 'Task B';
  select id into wb from public.client_workspaces where slug = 'fz-ws-b';
  if pg_temp.as_id('fz_office_agent', ca, format($q$update public.tasks set office_id = %L where id = %L$q$, B, ta)) not like 'ERR:permission denied%' then raise exception 'O7 office_id updatable'; end if;
  if pg_temp.as_id('fz_office_agent', ca, format($q$update public.tasks set mission_id = null where id = %L$q$, ta)) not like 'ERR:permission denied%' then raise exception 'O7 mission_id updatable'; end if;
  if pg_temp.as_id('fz_office_agent', ca, format($q$delete from public.tasks where id = %L$q$, ta)) not like 'ERR:permission denied%' then raise exception 'O7 delete allowed'; end if;
  if pg_temp.as_id('fz_office_agent', ca, $q$insert into public.agents (slug, title) values ('fz-evil', 'x')$q$) not like 'ERR:permission denied%' then raise exception 'O7 agents writable'; end if;
  if pg_temp.as_id('fz_office_agent', ca, $q$update public.missions set budget_cents = 2000$q$) not like 'ERR:permission denied%' then raise exception 'O7 mission budget writable'; end if;
  if pg_temp.as_id('fz_office_agent', ca, $q$truncate public.tasks$q$) not like 'ERR:permission denied%' then raise exception 'O7 truncate allowed'; end if;
  res := pg_temp.as_id('fz_jarvis', cj, format($q$insert into public.tasks (title, office_id) values ('Jarvis assigns B', %L) returning office_id::text || '|' || created_by$q$, B));
  if res <> 'OK:' || B || '|jarvis' then raise exception 'O7 jarvis group insert: %', res; end if;
  if pg_temp.as_id('fz_auditor', cu, $q$insert into public.tasks (title) values ('auditor writes')$q$) not like 'ERR:permission denied%' then raise exception 'O7 auditor can write'; end if;
  if pg_temp.as_id('fz_jarvis', cj, $q$insert into public.memory (kind, content) values ('fact', 'x')$q$) not like 'ERR:permission denied%' then raise exception 'O7 memory writable'; end if;

  -- O8 owner-only and money functions: the scoped roles execute EXACTLY the allowlist (nothing inherited, nothing else)
  allow_a := array['current_identity()', 'current_office()', 'current_office_id()', 'fz_claims()', 'fz_identity_now()', 'fz_readable_offices(text)', 'fz_readable_workspaces(text)',
                   'fz_whoami()', 'fz_writable_offices(text)', 'is_group_scope()', 'fz_agent_in_office(text,uuid)'];
  allow_o := allow_a || array['fz_authorize_action(text,integer,text,text,text,uuid,uuid,jsonb)'];
  allow_j := allow_o;
  foreach res in array array['fz_jarvis', 'fz_office_agent', 'fz_auditor'] loop
    got := array(select p.oid::regprocedure::text from pg_proc p where p.pronamespace = 'public'::regnamespace and has_function_privilege(res, p.oid, 'execute') order by 1);
    if got <> array(select x from unnest(case res when 'fz_jarvis' then allow_j when 'fz_office_agent' then allow_o else allow_a end) x order by 1) then
      raise exception 'O8 % executes %', res, got;
    end if;
  end loop;
  foreach res in array array[$q$select public.app_set_kill(true)::text$q$, $q$select public.authorize_action('x', 'research')::text$q$,
                             $q$select public.reserve_llm_budget('jarvis', 1, null, null)::text$q$, $q$select public.fz_set_office_policy('b2b-records', 'research', true)::text$q$,
                             $q$select public.fz_owner_set_identity('auditor', 'active')::text$q$, $q$select public.fz_revoke_identity('auditor', 'x')::text$q$,
                             $q$select public.jarvis_set_config('x', '1'::jsonb)::text$q$, $q$select public.backup_snapshot()::text$q$] loop
    if pg_temp.as_id('fz_office_agent', ca, res) not like 'ERR:%' then raise exception 'O8 office identity ran: %', res; end if;
    if pg_temp.as_id('fz_jarvis', cj, res) not like 'ERR:%' then raise exception 'O8 jarvis ran: %', res; end if;
  end loop;
  -- no scoped role holds any privilege on a money / approval / owner / audit / consent / backup table
  for r in select g.relname, to_regclass('public.' || quote_ident(g.relname)) t from public.fz_table_registry g where not g.fz_read loop
    continue when r.t is null;
    foreach res in array array['fz_jarvis', 'fz_office_agent', 'fz_auditor'] loop
      if has_table_privilege(res, r.t, 'select,insert,update,delete,truncate,references,trigger') or has_any_column_privilege(res, r.t, 'select,insert,update,references') then
        raise exception 'O8 % holds a privilege on %', res, r.relname;
      end if;
    end loop;
  end loop;
  -- nobody scoped can delete or truncate anything, anywhere
  if exists (select 1 from pg_class c cross join unnest(array['fz_jarvis', 'fz_office_agent', 'fz_auditor']) x where c.relnamespace = 'public'::regnamespace and c.relkind in ('r', 'p', 'v', 'm')
              and has_table_privilege(x, c.oid, 'delete,truncate,references,trigger')) then raise exception 'O8 a scoped role can delete / truncate'; end if;

  -- O9 Jarvis cannot approve: no write on approvals, approval functions refused, the gate still asks the owner and obeys the kill switch
  if pg_temp.as_id('fz_jarvis', cj, $q$update public.approval_requests set status = 'approved'$q$) not like 'ERR:permission denied%' then raise exception 'O9 jarvis updates approvals'; end if;
  if pg_temp.as_id('fz_jarvis', cj, $q$insert into public.approval_requests (actor, action, recommendation, status) values ('jarvis', 'take_loan', 'x', 'approved')$q$) not like 'ERR:permission denied%' then raise exception 'O9 jarvis inserts approvals'; end if;
  foreach res in array array['jarvis_owner_approve_large', 'ffm_owner_approve', 'app_ffm_approve_activation', 'app_ffm_approve_creative', 'jarvis_owner_confirm_revenue', 'app_set_kill', 'setter_apply'] loop
    if exists (select 1 from pg_proc p where p.pronamespace = 'public'::regnamespace and p.proname = res and has_function_privilege('fz_jarvis', p.oid, 'execute')) then raise exception 'O9 jarvis can execute %', res; end if;
  end loop;
  update public.system_state set mode = 'auto_in_caps' where id = 1;              -- live mode: a red action must still go to the owner
  res := pg_temp.as_id('fz_jarvis', cj, $q$select public.fz_authorize_action('take_loan', 0, 'fz-loan-1')::text$q$);
  if res not like '%"decision": "ask_owner"%' then raise exception 'O9 red action not sent to the owner: %', res; end if;
  res := pg_temp.as_id('fz_jarvis', cj, $q$select public.fz_authorize_action('advertising', 999999, 'fz-ads-1')::text$q$);
  if res not like '%"decision": "ask_owner"%' then raise exception 'O9 over-limit spend not sent to the owner: %', res; end if;
  update public.system_state set mode = 'dry_run' where id = 1;
  res := pg_temp.as_id('fz_jarvis', cj, $q$select public.fz_authorize_action('advertising', 100, 'fz-ads-2')::text$q$);
  if res not like '%"decision": "deny"%' or res not like '%Dry-run%' then raise exception 'O9 dry-run ignored: %', res; end if;
  if exists (select 1 from public.approval_requests where ref = 'fz-loan-1') then raise exception 'O9 the gate created an approval'; end if;
  -- B1: a scoped call never consumes an owner approval and never writes an allow row (allows count toward the caps); the service path keeps today's behaviour
  insert into public.approval_requests (actor, action, cents, ref, recommendation, status, decided_at) values ('donna-ops', 'send_email', 0, 'fz-ref-1', 'x', 'approved', now()),
                                                                                                           ('donna-ops', 'take_loan', 0, 'fz-ref-2', 'x', 'approved', now());
  update public.system_state set mode = 'approve_first' where id = 1;
  select count(*) into n from public.action_log where decision = 'allow';
  foreach res in array array[$q$select public.fz_authorize_action('send_email', 0, 'fz-ref-1')::text$q$, $q$select public.fz_authorize_action('take_loan', 0, 'fz-ref-2')::text$q$,
                             $q$select public.fz_authorize_action('research', 0, 'fz-ref-3')::text$q$] loop
    if pg_temp.as_id('fz_jarvis', cj, res) like '%"decision": "allow"%' and res not like '%research%' then raise exception 'B1 jarvis got allow: %', res; end if;
    perform pg_temp.as_id('fz_office_agent', ca, res);
  end loop;
  if pg_temp.as_id('fz_jarvis', cj, $q$select public.fz_authorize_action('research')::text$q$) not like '%"evaluated_only": true%' then raise exception 'B1 scoped allow not marked evaluated_only'; end if;
  if (select count(*) from public.approval_requests where ref in ('fz-ref-1', 'fz-ref-2') and status = 'approved') <> 2 then raise exception 'B1 a scoped call consumed an owner approval'; end if;
  if (select count(*) from public.action_log where decision = 'allow') <> n then raise exception 'B1 a scoped call wrote an allow row (counts toward caps)'; end if;
  if not exists (select 1 from public.action_log where ref = 'fz-ref-1' and decision = 'ask_owner' and actor = 'jarvis') then raise exception 'B1 the ask was not logged'; end if;
  res := pg_temp.svc($q$select public.fz_authorize_action('send_email', 0, 'fz-ref-1', null, 'donna-ops', null, null, '{"identity": "owner"}')::text$q$);   -- the service path: unchanged
  if res not like '%"decision": "allow"%' or (select status from public.approval_requests where ref = 'fz-ref-1') <> 'used' then raise exception 'B1 service path changed: %', res; end if;
  if (select detail ->> 'identity' from public.action_log where ref = 'fz-ref-1' and decision = 'allow' order by id desc limit 1) <> 'service' then raise exception 'S3 service caller set detail.identity'; end if;
  update public.system_state set kill_switch = true where id = 1;      -- (mode is restored by the rollback)
  res := pg_temp.as_id('fz_jarvis', cj, $q$select public.fz_authorize_action('research')::text$q$);
  if res not like '%"decision": "deny"%' or res not like '%Kill switch%' then raise exception 'O9 kill switch ignored: %', res; end if;
  update public.system_state set kill_switch = false where id = 1;

  -- O10 the office layer: dormant office refused, office mismatch refused, office rules tighten only, actor cannot be spoofed
  res := pg_temp.svc($q$select public.fz_authorize_action('research', 0, null, 'wolf-squad', 'jarvis')::text$q$);
  if res not like '%"decision": "deny"%' or res not like '%dormant%' then raise exception 'O10 dormant office allowed: %', res; end if;
  if pg_temp.as_id('fz_office_agent', ca, $q$select public.fz_authorize_action('research', 0, null, 'donna')::text$q$) not like 'ERR:office mismatch%' then raise exception 'O10 office A acted for donna'; end if;
  res := pg_temp.as_id('fz_office_agent', ca, $q$select public.fz_authorize_action('research', 0, 'fz-r1', null, 'owner')::text$q$);
  if res not like '%"decision": "allow"%' or res not like '%"office": "b2b-records"%' then raise exception 'O10 green research refused for office A: %', res; end if;
  if exists (select 1 from public.action_log where ref = 'fz-r1') then raise exception 'O10 a scoped allow was logged'; end if;
  if pg_temp.svc($q$select public.fz_set_office_policy('b2b-records', 'research', false, null, null, 'owner')::text$q$) not like 'OK:%' then raise exception 'O10 bot cannot tighten'; end if;
  if (select updated_by from public.fz_office_action_policy where action = 'research') <> 'bot:owner' then raise exception 'S3 the bot recorded itself as the owner'; end if;
  res := pg_temp.as_id('fz_office_agent', ca, $q$select public.fz_authorize_action('research', 0, 'fz-r1b', null, 'owner')::text$q$);
  if res not like '%"decision": "deny"%' or res not like '%office rule%' then raise exception 'O10 office rule ignored: %', res; end if;
  if (select actor || '|' || (detail ->> 'office') from public.action_log where ref = 'fz-r1b' order by id desc limit 1) <> AI || '|b2b-records' then raise exception 'O10 actor spoofed or office not logged'; end if;
  if pg_temp.as_id('fz_office_agent', cb, $q$select public.fz_authorize_action('research')::text$q$) not like '%"decision": "allow"%' then raise exception 'O10 office B affected by office A rule'; end if;
  if pg_temp.svc($q$select public.fz_set_office_policy('b2b-records', 'research', true)::text$q$) not like 'ERR:only the owner can relax%' then raise exception 'O10 bot relaxed an office rule'; end if;
  if pg_temp.svc($q$select public.fz_set_office_policy('b2b-records', 'advertising', true, 999999)::text$q$) not like 'ERR:office limit%above the group limit%' then raise exception 'O10 office limit above group accepted'; end if;
  if pg_temp.svc($q$select public.fz_set_office_policy('b2b-records', 'no_such_action', false)::text$q$) not like 'ERR:unknown action%' then raise exception 'O10 unknown action accepted'; end if;
  perform public.fz_set_office_policy('b2b-records', 'research', true, null, 1, 'x');   -- the signed-in owner relaxes (and sets a 1-per-day office cap)
  if (select updated_by from public.fz_office_action_policy where action = 'research') <> 'owner' then raise exception 'S3 owner change not recorded as owner'; end if;
  if pg_temp.svc($q$select public.fz_authorize_action('research', 0, 'fz-r2', 'b2b-records', 'jarvis')::text$q$) not like '%"decision": "allow"%' then raise exception 'O10 service path for the office'; end if;   -- counted (service path)
  if pg_temp.as_id('fz_office_agent', ca, $q$select public.fz_authorize_action('research')::text$q$) not like '%office%daily limit%' then raise exception 'O10 office daily cap ignored'; end if;
  if pg_temp.as_id('fz_auditor', cu, $q$select public.fz_authorize_action('research')::text$q$) not like 'ERR:%' then raise exception 'O10 auditor used the gate'; end if;

  -- O11 token checks (each refused token sees 0 rows and whoami says no)
  foreach d in array array[
      jsonb_build_object('r', 'fz_office_agent', 'c', pg_temp.cl(AI, 'fz_jarvis')),                                  -- role claim differs from the session role
      jsonb_build_object('r', 'fz_office_agent', 'c', pg_temp.cl(AI, 'fz_office_agent', '{"sub": "99999999-9999-9999-9999-99999999f001"}')),   -- carries a sub
      jsonb_build_object('r', 'fz_office_agent', 'c', pg_temp.cl(AI, 'fz_office_agent', '{"office": "donna"}')),     -- office claim mismatch
      jsonb_build_object('r', 'fz_office_agent', 'c', pg_temp.cl('jarvis', 'fz_office_agent')),                    -- group identity on the office role
      jsonb_build_object('r', 'fz_jarvis', 'c', pg_temp.cl(AI, 'fz_jarvis')),                                        -- office identity on the group role
      jsonb_build_object('r', 'fz_office_agent', 'c', pg_temp.cl('office:monopoly:manager', 'fz_office_agent')),    -- dormant office
      jsonb_build_object('r', 'fz_office_agent', 'c', pg_temp.cl('nobody', 'fz_office_agent'))] loop                -- unknown identity
    if pg_temp.as_id(d ->> 'r', d -> 'c', 'select (public.fz_whoami() ->> ''ok'')') <> 'OK:false' then raise exception 'O11 token accepted: %', d; end if;
    if pg_temp.as_id(d ->> 'r', d -> 'c', 'select count(*)::text from public.tasks') <> 'OK:0' then raise exception 'O11 refused token sees tasks: %', d; end if;
  end loop;
  update public.fz_identities set token_jti = 'jti-1' where slug = AI;
  if pg_temp.as_id('fz_office_agent', ca, 'select (public.fz_whoami() ->> ''ok'')') <> 'OK:false' then raise exception 'O11 pinned jti not enforced'; end if;
  if pg_temp.as_id('fz_office_agent', pg_temp.cl(AI, 'fz_office_agent', '{"jti": "jti-1"}'), 'select (public.fz_whoami() ->> ''ok'')') <> 'OK:true' then raise exception 'O11 pinned jti refused'; end if;
  update public.fz_identities set token_jti = null, tokens_valid_after = now() - interval '1 hour' where slug = AI;
  if pg_temp.as_id('fz_office_agent', pg_temp.cl(AI, 'fz_office_agent', jsonb_build_object('iat', floor(extract(epoch from now() - interval '2 hours')))), 'select (public.fz_whoami() ->> ''ok'')') <> 'OK:false' then raise exception 'O11 voided token accepted'; end if;
  if pg_temp.as_id('fz_office_agent', ca, 'select (public.fz_whoami() ->> ''ok'')') <> 'OK:true' then raise exception 'O11 new token refused'; end if;
  -- the bot can only make an identity SAFER: revoke works, re-activation does not
  if pg_temp.svc(format($q$select public.fz_revoke_identity(%L, 'test')::text$q$, BI)) not like 'OK:%revoked%' then raise exception 'O11 bot cannot revoke'; end if;
  if pg_temp.as_id('fz_office_agent', cb, 'select count(*)::text from public.tasks') <> 'OK:0' then raise exception 'O11 revoked identity still reads'; end if;
  if pg_temp.svc(format($q$select public.fz_owner_set_identity(%L, 'active')::text$q$, BI)) not like 'ERR:owner approval required%' then raise exception 'O11 bot re-activated'; end if;
  if pg_temp.svc($q$select public.fz_revoke_identity('owner', 'x')::text$q$) not like 'ERR:unknown identity%' then raise exception 'O11 owner identity revocable by the bot'; end if;

  -- O12 anon / authenticated: nothing on any fz object; no policy of this migration names them; a scoped claim does not help them
  foreach res in array array['anon', 'authenticated'] loop
    if exists (select 1 from pg_proc p where p.pronamespace = 'public'::regnamespace and (p.proname like 'fz\_%' or p.proname in ('current_identity', 'current_office', 'current_office_id', 'is_group_scope'))
                and has_function_privilege(res, p.oid, 'execute')) then raise exception 'O12 % executes an fz function', res; end if;
    if exists (select 1 from pg_class c where c.relnamespace = 'public'::regnamespace and c.relname like 'fz\_%' and c.relkind in ('r', 'v', 'm', 'S')
                and (case when c.relkind = 'S' then has_sequence_privilege(res, c.oid, 'select,usage,update') else has_table_privilege(res, c.oid, 'select,insert,update,delete,truncate,references,trigger') end)) then
      raise exception 'O12 % holds a privilege on an fz table', res; end if;
    if pg_temp.as_id(res, ca, 'select count(*)::text from public.tasks') <> 'OK:0' and pg_temp.as_id(res, ca, 'select count(*)::text from public.tasks') not like 'ERR:permission denied%' then raise exception 'O12 % reads tasks with a scoped claim', res; end if;
  end loop;
  if exists (select 1 from pg_policies where schemaname = 'public' and policyname like 'fz\_%' and not (roles <@ array['fz_jarvis', 'fz_office_agent', 'fz_auditor', 'service_role']::name[])) then
    raise exception 'O12 an fz policy names an API role'; end if;
  if exists (select 1 from pg_policies where schemaname = 'public' and policyname = 'fz_service_all' and (roles <> array['service_role']::name[] or qual <> 'true')) then raise exception 'O12 service policy shape'; end if;

  -- O13 service_role (the bot today) keeps every row and its writes
  execute 'select count(*) from public.tasks' into exp;
  if pg_temp.svc('select count(*)::text from public.tasks') <> 'OK:' || exp then raise exception 'O13 service_role lost tasks rows'; end if;
  execute 'select count(*) from public.agents' into exp;
  if pg_temp.svc('select count(*)::text from public.agents') <> 'OK:' || exp then raise exception 'O13 service_role lost agents rows'; end if;
  res := pg_temp.svc($q$insert into public.tasks (title, created_by) values ('bot task', 'jarvis') returning office_id::text || '|' || created_by$q$);
  if res <> 'OK:f0000000-0000-4000-8000-000000000000|jarvis' then raise exception 'O13 bot insert changed: %', res; end if;
  insert into public.client_workspaces (slug, name, vertical) values ('fz-ws-new', 'New Client', 'mortgage') returning id into wa;   -- existing FFM code: unchanged insert, no office
  if not wa = any (pg_temp.ws_of('f0000000-0000-4000-8000-000000000007')) then raise exception 'O13 a new client workspace is not FF Marketing'; end if;
  res := pg_temp.svc(format($q$with u as (update public.tasks set status = 'done' where id = %L returning 1) select count(*)::text from u$q$, tb));
  if res <> 'OK:1' then raise exception 'O13 bot update: %', res; end if;

  -- O14 the registry covers every table, and the grants are exactly the registry's
  if exists (select 1 from public.fz_unregistered_tables()) then raise exception 'O14 unregistered tables: %', (select string_agg(x, ',') from public.fz_unregistered_tables() x); end if;
  for r in select g.*, to_regclass('public.' || quote_ident(g.relname)) t from public.fz_table_registry g loop
    continue when r.t is null;
    if has_table_privilege('fz_office_agent', r.t, 'select') <> r.fz_read then raise exception 'O14 select grant on % differs from the registry', r.relname; end if;
    if has_any_column_privilege('fz_office_agent', r.t, 'insert') <> ('insert' = any (r.fz_write)) then raise exception 'O14 insert grant on % differs from the registry', r.relname; end if;
    if has_any_column_privilege('fz_office_agent', r.t, 'update') <> ('update' = any (r.fz_write)) then raise exception 'O14 update grant on % differs from the registry', r.relname; end if;
    if r.fz_read and not (select c.relrowsecurity from pg_class c where c.oid = r.t) then raise exception 'O14 % is readable by scoped roles but RLS is off', r.relname; end if;
  end loop;

  -- O15 re-seed: ran once, Jarvis kept, archived rows paused + stamped, nothing deleted, client workspaces in FF Marketing
  if (select count(*) from public.fz_org_archive where entity = 'reseed') <> 1 then raise exception 'O15 re-seed marker'; end if;
  if exists (select 1 from public.fz_org_archive a where a.entity = 'agent' and a.key in ('jarvis', 'jarvis-chat', 'jarvis-core', 'jarvis-hands') and a.decision <> 'kept') then raise exception 'O15 a Jarvis agent was archived'; end if;
  if exists (select 1 from public.fz_org_archive a join public.agents g on g.slug = a.key where a.entity = 'agent' and a.decision = 'kept' and g.archived_at is not null) then
    raise exception 'O15 a kept agent was stamped archived'; end if;
  if exists (select 1 from public.fz_org_archive a join public.agents g on g.slug = a.key where a.entity = 'agent' and a.decision = 'archived' and g.archived_at is null) then raise exception 'O15 archived agent not stamped'; end if;
  if exists (select 1 from public.fz_org_archive a where a.entity in ('agent', 'department', 'venture') and a.new_status is distinct from a.prior_status) then raise exception 'S4 the re-seed changed a status'; end if;
  if (select (detail ->> 'status_changes')::int from public.audit_log where action = 'org_reseed' order by id desc limit 1) <> 0 then raise exception 'S4 re-seed audit'; end if;
  -- the preview is read-only and agrees with the rule; it lists exactly what the log archived (for rows that existed at the re-seed)
  if exists (select 1 from public.fz_reseed_preview() p where p.already_logged and not exists (select 1 from public.fz_org_archive a where a.entity = p.entity and a.key = p.key and a.decision = 'archived')) then raise exception 'S4 preview disagrees with the log'; end if;
  if exists (select 1 from public.fz_org_archive a where a.entity = 'agent' and not exists (select 1 from public.agents g where g.slug = a.key)) then raise exception 'O15 an agent row was deleted'; end if;
  if exists (select 1 from public.fz_org_archive a where a.entity = 'venture' and not exists (select 1 from public.ventures g where g.slug = a.key)) then raise exception 'O15 a venture row was deleted'; end if;
  if exists (select 1 from public.fz_org_archive a where a.entity = 'department' and not exists (select 1 from public.departments g where g.slug = a.key)) then raise exception 'O15 a department row was deleted'; end if;
  if exists (select 1 from public.fz_org_archive a where a.entity = 'venture' and a.decision = 'archived' and a.prior_status in ('active', 'proposed')) then raise exception 'O15 a live / proposed venture was archived'; end if;
  if exists (select 1 from public.client_workspaces w where w.slug not like 'fz-ws-%' and not w.id = any (pg_temp.ws_of('f0000000-0000-4000-8000-000000000007'))) then raise exception 'O15 a client workspace is not FF Marketing'; end if;
  if pg_temp.svc($q$update public.fz_org_archive set reason = 'x'$q$) not like 'ERR:%' then raise exception 'O15 archive log writable by the bot'; end if;
  begin delete from public.fz_org_archive; raise exception 'O15 archive log deletable'; exception when insufficient_privilege then null; end;
  if (public.fz_org_status() -> 'orphan_office_ids') <> '{}'::jsonb then raise exception 'O15 orphan office ids: %', public.fz_org_status() -> 'orphan_office_ids'; end if;

  -- O16 backups unaffected: nothing unclassified, the org tables still exported (no foreign key to a non-exported table)
  if public.backup_export_policy() -> 'unclassified' <> '[]'::jsonb then raise exception 'O16 unclassified: %', public.backup_export_policy() -> 'unclassified'; end if;
  if not (public.backup_export_policy() -> 'exported') @> '["agents", "departments", "ventures", "missions", "tasks", "memory"]'::jsonb then raise exception 'O16 an org table left the export: %', public.backup_export_policy() -> 'excluded'; end if;
  if exists (select 1 from public.backup_effective_spec(public.backup_export_policy() -> 'exported') where not classified) then raise exception 'O16 an exported text column is unclassified'; end if;
  if has_function_privilege('fz_jarvis', 'public.backup_assert_reader()', 'execute') then raise exception 'O16 backup guard executable'; end if;
  raise notice 'org_access_check: all checks passed';
end $$;
rollback;
