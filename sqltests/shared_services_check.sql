-- Shared services M5 (migrations/20261201_shared_services_v1.sql). ONE transaction, rolled back. Fresh apply, repo root.
-- Proves: the money controls are unchanged (with / without / re-applied M5); the protected money tables are not altered; the registry lists the six shared services with
-- the group as owner office, data classes equal to the M1 registry, scoped reads OFF by default; every new row of a stamped service table carries office_id, decided by
-- the venture / lead / mission / agent / division, else a scoped caller's office, else the group, and the stamp changes NOTHING else and refuses nothing; history is not
-- rewritten; the view isolates offices; only the owner (or a database session) changes the registry, never the service key or a scoped role; no callable write helper;
-- the rollback archives every stamp and the registry and a re-apply keeps the owner's decisions.
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
create function pg_temp.cl(p_identity text, p_role text) returns jsonb language sql as $$
  select jsonb_build_object('role', p_role, 'identity', p_identity, 'iat', floor(extract(epoch from now())), 'exp', floor(extract(epoch from now())) + 3600)
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
insert into auth.users (id, email) values ('99999999-9999-9999-9999-99999999f005', 'fzv-owner@example.invalid') on conflict do nothing;
insert into public.app_owners (email) values ('fzv-owner@example.invalid') on conflict do nothing;
select set_config('app.uid', '99999999-9999-9999-9999-99999999f005', true);

-- V1 money controls unchanged: with M5 == after its rollback (twice) == after re-applying it; the rollback leaves nothing behind
\set fz_in_txn 1
create temp table fzv_fp_with as select * from pg_temp.fz_money_fp();
create temp table fzv_ex0 as select count(*) n from public.audit_log where action = 'shared_services_export';
select public.fz_owner_set_service('crm', true, null, null, 'drill: owner decision kept across rollback');
insert into public.venture_assets (kind, name) values ('asset', 'fzv stamped before rollback');
create temp table fzv_stamps as
  select 'leads' tbl, id, office_id from public.leads where office_id is not null union all select 'lead_replies', id, office_id from public.lead_replies where office_id is not null
  union all select 'deals', id, office_id from public.deals where office_id is not null union all select 'outbox', id, office_id from public.outbox where office_id is not null
  union all select 'owner_messages', id, office_id from public.owner_messages where office_id is not null union all select 'jarvis_jobs', id, office_id from public.jarvis_jobs where office_id is not null
  union all select 'hand_actions', id, office_id from public.hand_actions where office_id is not null union all select 'venture_assets', id, office_id from public.venture_assets where office_id is not null;
\ir ../ops/rollback_monitoring_brain.sql
\ir ../ops/rollback_shared_services.sql
\ir ../ops/rollback_monitoring_brain.sql
\ir ../ops/rollback_shared_services.sql
create temp table fzv_fp_without as select * from pg_temp.fz_money_fp();
do $$
begin
  if to_regclass('public.fz_services') is not null or to_regclass('public.fz_service_rows') is not null
     or exists (select 1 from pg_proc where proname in ('fz_services_report', 'fz_owner_set_service', 'fz_service_stamp_office', 'fz_services_guard'))
     or exists (select 1 from pg_attribute where attrelid in ('public.leads'::regclass, 'public.outbox'::regclass, 'public.owner_messages'::regclass, 'public.jarvis_jobs'::regclass)
                and attname = 'office_id' and not attisdropped)
     or exists (select 1 from pg_trigger where tgname = 'zz_fz_service_office') then raise exception 'V1 the rollback left M5 objects behind'; end if;
  if to_regclass('fz_archive.fz_services') is null or (select count(*) from fz_archive.fz_services) <> 7 then raise exception 'V1 the registry was not archived'; end if;
  if to_regclass('public.fz_audit_chain') is null or to_regclass('public.fz_office_money') is null then raise exception 'V1 the rollback damaged M4 / M2'; end if;
  if public.backup_export_policy() -> 'unclassified' <> '[]'::jsonb then raise exception 'V1 unclassified after the rollback'; end if;
  if exists (select 1 from public.backup_classification() where table_name = 'fz_services') then raise exception 'V1 the rollback did not restore the M4 classification'; end if;
  if (select count(*) from fzv_stamps) = 0 or exists (select tbl, id, office_id from fzv_stamps except select tbl, row_id, office_id from fz_archive.fz_service_attribution) then
    raise exception 'V1 a stamped office_id was not archived'; end if;
  if (select count(*) from public.audit_log where action = 'shared_services_export') <> (select n from fzv_ex0) + 1 then raise exception 'V1 the export record is missing or doubled'; end if;
  if exists (select 1 from fzv_fp_with w full join fzv_fp_without o using (k) where w.v is distinct from o.v) then raise exception 'V1 the money controls differ with and without M5'; end if;
end $$;
\ir ../migrations/20261201_shared_services_v1.sql
create temp table fzv_fp_again as select * from pg_temp.fz_money_fp();
do $$
begin
  if exists (select 1 from fzv_fp_again w full join fzv_fp_without o using (k) where w.v is distinct from o.v) then raise exception 'V1 applying M5 changed the money controls'; end if;
  if not (select scoped_reads from public.fz_services where service = 'crm') then raise exception 'V1 the owner decision was lost across rollback + re-apply'; end if;
  perform public.fz_owner_set_service('crm', false);
end $$;

do $$
declare A uuid := 'f0000000-0000-4000-8000-000000000001'; B uuid := 'f0000000-0000-4000-8000-000000000002'; G uuid := 'f0000000-0000-4000-8000-000000000000';
        va uuid; vb uuid; la uuid; lb uuid; m uuid; x uuid; o uuid; res text; j1 jsonb; j2 jsonb; n int; ca jsonb; cj jsonb; r jsonb;
begin
  -- V2 the registry: the six M5 services plus web_studio (20261205), owner office = the group (M1 registry), data classes == the M1 registry, scoped reads OFF, tables known
  if (select count(*) from public.fz_services) <> 7 or exists (select 1 from public.fz_services where owner_office <> G) then raise exception 'V2 registry rows / owner office'; end if;
  if (select string_agg(service, ',' order by service) from public.fz_services) <> 'comms,content,crm,llm_routing,payments,scheduler,web_studio' then raise exception 'V2 services'; end if;
  if exists (select 1 from public.fz_services where scoped_reads) then raise exception 'V2 scoped reads must default OFF'; end if;
  if exists (select 1 from public.fz_services s where s.data_classes is distinct from
               array(select distinct r.data_class from public.fz_table_registry r where r.relname = any (s.writes || s.reads) order by 1)) then raise exception 'V2 data classes drift from M1'; end if;
  if exists (select 1 from public.fz_services s, unnest(s.writes || s.reads) t where not exists (select 1 from public.fz_table_registry r where r.relname = t)) then
    raise exception 'V2 unknown table in the registry'; end if;
  if (select count(*) from public.fz_table_registry where relname = 'fz_services') <> 1 then raise exception 'V2 fz_services not in the M1 registry'; end if;
  -- the protected money tables are not altered
  if exists (select 1 from pg_attribute where attrelid in ('public.payment_instructions'::regclass, 'public.llm_calls'::regclass, 'public.ledger'::regclass) and attname = 'office_id') then
    raise exception 'V2 a protected money table got a column'; end if;
  if exists (select 1 from pg_trigger where tgname = 'zz_fz_service_office' and tgrelid in ('public.payment_instructions'::regclass, 'public.llm_calls'::regclass)) then
    raise exception 'V2 a protected money table got a trigger'; end if;
  if (select count(*) from pg_trigger where tgname = 'zz_fz_service_office') <> 8 then raise exception 'V2 stamp triggers'; end if;

  -- V3 stamping on insert (service key, as the bot): the venture decides, else lead / mission / agent / division, else the group
  insert into public.ventures (slug, name, kind, office_id) values ('fzv-ven-a', 'Svc A', 'lab', A) returning id into va;
  insert into public.ventures (slug, name, kind, office_id) values ('fzv-ven-b', 'Svc B', 'lab', B) returning id into vb;
  insert into public.departments (slug, name, kind, status, office_id) values ('fzv-dept-b', 'Svc dept B', 'shared', 'active', B);
  insert into public.leads (venture_id, name, email, office_id) values (va, 'Svc lead', 'svc-lead@example.invalid', B) returning id into la;   -- (the replica bot lacks the short_id sequence)
  if (select office_id from public.leads where id = la) <> A then raise exception 'V3 the venture must decide the office (a caller-given other office is overridden)'; end if;
  alter table public.leads disable trigger zz_fz_service_office;
  insert into public.leads (venture_id, name, email) values (va, 'Svc lead', 'svc-lead@example.invalid') returning id into lb;
  alter table public.leads enable trigger zz_fz_service_office;
  if (select to_jsonb(l) - 'office_id' - 'id' - 'created_at' - 'short_id' from public.leads l where id = la) <> (select to_jsonb(l) - 'office_id' - 'id' - 'created_at' - 'short_id' from public.leads l where id = lb) then
    raise exception 'V3 the stamp changed another column'; end if;
  delete from public.leads where id = lb;
  res := pg_temp.svc(format('insert into public.outbox (agent, channel, to_ref, body, lead_id) values (%L, %L, %L, %L, %L) returning id', 'donna-ops', 'email', 'svc-lead@example.invalid', 'hello', la));
  if res not like 'OK:%' then raise exception 'V3 the bot could not insert an outbox draft: %', res; end if;
  if (select office_id from public.outbox where id = substr(res, 4)::uuid) <> A then raise exception 'V3 outbox without venture: the lead decides'; end if;
  res := pg_temp.svc(format('insert into public.deals (venture_id, lead_id, stage) values (%L, %L, %L) returning id', vb, la, 'new'));
  if res like 'OK:%' and (select office_id from public.deals where id = substr(res, 4)::uuid) <> B then raise exception 'V3 deal: the venture decides'; end if;
  insert into public.lead_replies (lead_id, venture_id, kind, recorded_by) values (la, va, 'question', 'test') returning office_id into x;
  if x <> A then raise exception 'V3 lead reply office'; end if;
  insert into public.missions (title, objective, budget_cents, office_id) values ('Svc mission', 'objective long enough to pass', 0, B) returning id into m;
  insert into public.jarvis_jobs (division, kind, mission_id) values ('research', 'svc_test', m) returning office_id into x;
  if x <> B then raise exception 'V3 job: the mission decides'; end if;
  insert into public.jarvis_jobs (division, kind) values ('fzv-dept-b', 'svc_test') returning office_id into x;
  if x <> B then raise exception 'V3 job without mission: the division decides'; end if;
  insert into public.jarvis_jobs (division, kind) values ('research', 'svc_test') returning office_id into x;
  if x <> G then raise exception 'V3 job: nothing to derive from -> the group'; end if;
  res := pg_temp.svc(format('insert into public.owner_messages (from_agent, kind, body) values (%L, %L, %L) returning id', 'jarvis', 'brief', 'svc test'));
  if res not like 'OK:%' then raise exception 'V3 the bot could not write an owner message: %', res; end if;
  o := substr(res, 4)::uuid;
  if (select office_id from public.owner_messages where id = o) <> G then raise exception 'V3 owner message office'; end if;
  insert into public.venture_assets (kind, name, office_id) values ('asset', 'no venture', B) returning office_id into x;   -- (the replica bot has no RLS bypass here)
  res := 'OK:' || x;
  if res <> 'OK:' || B then raise exception 'V3 a real caller-given office is kept when nothing derives one: %', res; end if;
  insert into public.venture_assets (kind, name, office_id) values ('asset', 'no venture', gen_random_uuid()) returning office_id into x;
  res := 'OK:' || x;
  if res <> 'OK:' || G then raise exception 'V3 a made-up office id must become the group: %', res; end if;
  insert into public.venture_assets (venture_id, kind, name) values (vb, 'asset', 'Svc asset') returning office_id into x;
  if x <> B then raise exception 'V3 venture asset office'; end if;
  insert into public.hand_actions (connector, division, action, payload) values ((select slug from public.hand_connectors order by slug limit 1), 'fzv-dept-b', 'post', '{}') returning office_id into x;
  if x <> B then raise exception 'V3 hand action: the division decides'; end if;

  -- V4 updates: an unrelated change keeps the office; moving the venture re-derives it; the service key cannot re-label a row it cannot derive
  res := pg_temp.svc(format('update public.leads set notes = %L where id = %L returning office_id', 'n', la));
  if res <> 'OK:' || A then raise exception 'V4 an unrelated update moved the office: %', res; end if;
  update public.leads set venture_id = vb where id = la;
  if (select office_id from public.leads where id = la) <> B then raise exception 'V4 moving the venture must re-derive the office'; end if;
  res := pg_temp.svc(format('update public.owner_messages set office_id = %L where id = %L returning office_id', A, o));
  if res <> 'OK:' || G then raise exception 'V4 the service key re-labelled an owner message: %', res; end if;
  insert into public.venture_assets (kind, name) values ('asset', 'no venture 2') returning id into x;
  update public.venture_assets set office_id = A where id = x;
  if (select office_id from public.venture_assets where id = x) <> G then raise exception 'V4 a row with nothing to derive from was re-labelled'; end if;
  -- history is not rewritten: a row with no stamp stays unstamped and the view derives it
  alter table public.owner_messages disable trigger zz_fz_service_office;
  insert into public.owner_messages (from_agent, kind, body, created_at) values ('jarvis', 'brief', 'old', now() - interval '400 days') returning id into o;
  alter table public.owner_messages enable trigger zz_fz_service_office;
  if (select how from public.fz_service_rows where tbl = 'owner_messages' and row_id = o) <> 'historical' or (select office_id from public.fz_service_rows where row_id = o) <> G then
    raise exception 'V4 a historical row is not resolved by the view'; end if;

  -- V5 a scoped office caller: rows it reads in the view are its own office only; group scope sees all; anon / authenticated see nothing
  perform public.fz_owner_set_office_status('b2b-records', 'active');
  perform public.fz_owner_set_identity('office:b2b-records:manager', 'active');
  ca := pg_temp.cl('office:b2b-records:manager', 'fz_office_agent'); cj := pg_temp.cl('jarvis', 'fz_jarvis');
  grant select on public.fz_service_rows to fz_office_agent, fz_jarvis;      -- in-transaction only: prove the row filter, not the grant
  res := pg_temp.as_id('fz_office_agent', ca, 'select count(*) filter (where office_id <> ''f0000000-0000-4000-8000-000000000001'') || ''/'' || count(*) from public.fz_service_rows');
  if res not like 'OK:0/%' or res = 'OK:0/0' then raise exception 'V5 the office agent saw another office: %', res; end if;
  res := pg_temp.as_id('fz_jarvis', cj, 'select count(distinct office_id) from public.fz_service_rows');
  if res not like 'OK:%' or substr(res, 4)::int < 3 then raise exception 'V5 group scope must see every office: %', res; end if;
  revoke select on public.fz_service_rows from fz_office_agent, fz_jarvis;
  if pg_temp.as_id('anon', null, 'select count(*) from public.fz_service_rows') not like 'ERR:permission denied%' then raise exception 'V5 anon reads the view'; end if;
  if pg_temp.as_id('authenticated', null, 'select count(*) from public.fz_service_rows') not like 'ERR:permission denied%' then raise exception 'V5 authenticated reads the view'; end if;
  grant select on public.fz_service_rows to anon;                             -- strict: even if granted by mistake (with the helpers), anon sees no row
  grant execute on function public.is_group_scope(), public.current_office_id() to anon;
  if pg_temp.as_id('anon', null, 'select count(*) from public.fz_service_rows') <> 'OK:0' then raise exception 'V5 the row filter lets anon through: %', pg_temp.as_id('anon', null, 'select count(*) from public.fz_service_rows'); end if;
  revoke select on public.fz_service_rows from anon;
  -- a scoped caller's insert gets its own office (nothing else to derive from): granted in-transaction only
  grant insert, select on public.venture_assets to fz_office_agent;
  create policy fzv_tmp on public.venture_assets for all to fz_office_agent using (true) with check (true);   -- in-transaction only
  res := pg_temp.as_id('fz_office_agent', ca, 'insert into public.venture_assets (kind, name, office_id) values (''asset'', ''scoped'', ''f0000000-0000-4000-8000-000000000002'') returning office_id');
  if res <> 'OK:' || A then raise exception 'V5 a scoped insert must carry the caller office: %', res; end if;
  drop policy fzv_tmp on public.venture_assets;
  revoke insert, select on public.venture_assets from fz_office_agent;

  -- V6 only the owner / a database session changes the registry; never the service key or a scoped role; never deleted; tables fixed for the owner
  alter role service_role bypassrls;                                       -- as on Supabase (in-transaction): the guard, not RLS, must refuse
  grant insert, update, delete on public.fz_services to service_role;       -- in-transaction: even with a mistaken grant, the guard refuses
  if pg_temp.svc('update public.fz_services set scoped_reads = true where service = ''crm'' returning service') not like 'ERR:%' then raise exception 'V6 the bot changed the registry'; end if;
  if pg_temp.svc('select public.fz_owner_set_service(''crm'', true)') not like 'ERR:%only the signed-in owner changes a shared service%' then raise exception 'V6 the bot used the owner function (its own check, not only the guard)'; end if;
  if pg_temp.svc('insert into public.fz_services (service, title, owner_office, attribution) values (''x_svc'', ''x'', ''f0000000-0000-4000-8000-000000000000'', ''column'') returning service') not like 'ERR:%' then
    raise exception 'V6 the bot added a service'; end if;
  if pg_temp.svc('delete from public.fz_services where service = ''crm'' returning service') not like 'ERR:%' then raise exception 'V6 the bot deleted a service'; end if;
  alter role service_role nobypassrls;
  revoke insert, update, delete on public.fz_services from service_role;
  if pg_temp.svc('update public.fz_services set note = ''x'' returning service') not like 'ERR:permission denied%' then raise exception 'V6 the bot holds a write grant on the registry'; end if;
  if pg_temp.as_id('fz_jarvis', cj, 'select public.fz_services_report()::text') not like 'ERR:permission denied%' then raise exception 'V6 a scoped role reads the report'; end if;
  if pg_temp.as_id('fz_jarvis', cj, 'select public.fz_owner_set_service(''crm'', true)::text') not like 'ERR:permission denied%' then raise exception 'V6 a scoped role calls the owner function'; end if;
  begin delete from public.fz_services where service = 'crm'; raise exception 'V6 deleted'; exception when insufficient_privilege then null; end;
  begin truncate public.fz_services; raise exception 'V6 truncated'; exception when others then if sqlerrm like 'V6%' then raise; end if; end;
  -- the owner (a database session, as in the SQL editor): allowed changes, audited
  r := public.fz_owner_set_service('crm', true, null, 'the-trap', 'owner test');
  if not (r ->> 'scoped_reads')::boolean or (select o2.slug from public.fz_services s join public.fz_offices o2 on o2.id = s.owner_office where service = 'crm') <> 'the-trap' then
    raise exception 'V6 owner change not applied: %', r; end if;
  if not exists (select 1 from public.audit_log where action = 'service_registry_change' and target = 'fz_services:crm') then raise exception 'V6 owner change not audited'; end if;
  begin update public.fz_services set scoped_identity = 'owner', scoped_reads = true where service = 'comms'; raise exception 'V6 a non-scoped identity was accepted';
  exception when check_violation then null; end;
  begin update public.fz_services set writes = '{no_such_table}' where service = 'comms'; raise exception 'V6 an unknown table was accepted';
  exception when check_violation then null; end;
  perform public.fz_owner_set_service('crm', false, null, 'group');

  -- V7 no callable write helper (the N1 lesson): the stamp and the guard are trigger functions; the report writes nothing
  if pg_temp.svc('select public.fz_service_stamp_office()::text') not like 'ERR:%' then raise exception 'V7 the stamp helper is callable'; end if;
  if exists (select 1 from pg_proc p where p.pronamespace = 'public'::regnamespace and p.prosecdef and p.proname in ('fz_services_report', 'fz_owner_set_service', 'fz_service_stamp_office', 'fz_services_guard')
             and p.proname not in ('fz_service_stamp_office', 'fz_services_guard') and p.prorettype = 'trigger'::regtype) then raise exception 'V7 unexpected trigger function'; end if;
  if (select count(*) from pg_proc p where p.pronamespace = 'public'::regnamespace and p.prosecdef and (p.proname like 'fz\_service%' or p.proname = 'fz_owner_set_service')) <> 4 then
    raise exception 'V7 an unexpected fz_service definer function exists: %', (select string_agg(proname, ',') from pg_proc where proname like 'fz\_service%'); end if;
  j1 := (select to_jsonb(array_agg(s order by s.service)) from public.fz_services s);
  j2 := public.fz_services_report();
  if (select to_jsonb(array_agg(s order by s.service)) from public.fz_services s) <> j1 then raise exception 'V7 the report wrote'; end if;

  -- V8 the report: every service, rows counted, no unstamped row since stamping started, scoped-readable tables from the M1 registry only
  if jsonb_array_length(j2 -> 'services') <> 7 or (j2 ->> 'scoped_reads_on')::int <> 0 then raise exception 'V8 report shape: %', j2; end if;
  if exists (select 1 from jsonb_array_elements(j2 -> 'services') e where (e ->> 'unstamped_since_start')::int <> 0) then raise exception 'V8 unstamped rows since the start: %', j2; end if;
  if (select e -> 'scoped_read_tables' from jsonb_array_elements(j2 -> 'services') e where e ->> 'service' = 'crm') <> '["ventures"]'::jsonb then raise exception 'V8 crm scoped tables'; end if;
  if (select e -> 'scoped_read_tables' from jsonb_array_elements(j2 -> 'services') e where e ->> 'service' = 'payments') <> '["agents", "ventures"]'::jsonb then raise exception 'V8 payments scoped tables'; end if;
  if exists (select 1 from jsonb_array_elements(j2 -> 'services') e, jsonb_array_elements_text(e -> 'scoped_read_tables') t
             where not (select fz_read from public.fz_table_registry where relname = t)) then raise exception 'V8 a table M1 does not let a scoped role read'; end if;
  if (select (e -> 'rows' ->> 'derived')::int from jsonb_array_elements(j2 -> 'services') e where e ->> 'service' = 'payments') is distinct from (select nullif(count(*), 0)::int from public.payment_instructions) then
    raise exception 'V8 payments rows'; end if;
  raise notice 'shared_services_check: all checks passed';
end $$;
rollback;
