-- Donna Client Agents v1 (migrations/20261211_donna_client_agents_v1.sql). ONE transaction, rolled back. Fresh apply, repo root.
-- Proves: rollback archives both tables with rows and leaves nothing behind, then re-applies twice; no API role reaches fz_donna_ca or the functions; everything
-- refuses while Donna is dormant (the list reads only); an intake is found by id or label, a rejected one is refused; one agent per intake and per Retell id;
-- one report per agent and month.
begin;
create function pg_temp.bot(p_sql text) returns text language plpgsql as $$
declare r text;
begin
  begin execute p_sql into r; exception when others then return 'ERR:' || sqlerrm; end;
  return 'OK:' || coalesce(r, '');
end $$;
create function pg_temp.j(p text) returns jsonb language sql as $$ select case when p like 'OK:%' then substr(p, 4)::jsonb end $$;
create function pg_temp.expect(p_tag text, p_got text, p_like text) returns void language plpgsql as $$
begin
  if p_got is null or p_got not like p_like then raise exception '% expected [%] got [%]', p_tag, p_like, p_got; end if;
end $$;
insert into auth.users (id, email) values ('99999999-9999-9999-9999-99999999ca01', 'ca-owner@example.invalid') on conflict do nothing;
insert into public.app_owners (email) values ('ca-owner@example.invalid') on conflict do nothing;
select set_config('app.uid', '99999999-9999-9999-9999-99999999ca01', true);
create temp table ca_fix as
  select gen_random_uuid() intake_ok, gen_random_uuid() intake_rej, (select id from public.ventures where slug = 'donna') v;
insert into fz_donna.intakes (id, client_label, reception_config, site_json, status)
  select intake_ok, 'Pine Plumbing', '{"business_name":"Pine Plumbing","timezone":"America/Toronto","hours":{},"services":[],"faqs":[],"escalation_number":"+16135550111","booking":{},"voice":{}}'::jsonb, '{}'::jsonb, 'draft' from ca_fix
  union all
  select intake_rej, 'Rejected Co', '{"business_name":"Rejected Co","timezone":"America/Toronto","hours":{},"services":[],"faqs":[],"escalation_number":"","booking":{},"voice":{}}'::jsonb, '{}'::jsonb, 'owner_rejected' from ca_fix;

-- C1 dormant: every write and the intake read refuse; the list reads
do $$
begin
  perform public.fz_owner_set_office_status('donna', 'dormant');
  update fz_office_os.fz_office_profiles set status = 'dormant' where slug = 'donna';
  perform pg_temp.expect('C1 intake', pg_temp.bot($q$select public.donna_intake_for_agent('Pine Plumbing')::text$q$), 'ERR:refused: Donna is dormant%');
  perform pg_temp.expect('C1 record', pg_temp.bot(format($q$select public.donna_record_client_agent(%L, 'agent_abc123', 'llm_abc123', %L)::text$q$,
                         (select intake_ok from ca_fix), repeat('a', 64))), 'ERR:refused: Donna is dormant%');
  perform pg_temp.expect('C1 list', pg_temp.bot($q$select public.donna_client_agents()::text$q$), 'OK:[]');
end $$;

-- C2 active: find, refuse rejected, record once, report once a month
do $$
declare r jsonb; a uuid;
begin
  perform public.fz_owner_set_office_status('donna', 'active');
  update fz_office_os.fz_office_profiles set manager = coalesce(manager, 'ca manager'), status = 'active', activated_at = now() where slug = 'donna';
  r := pg_temp.j(pg_temp.bot($q$select public.donna_intake_for_agent('pine plumbing')::text$q$));
  if (r ->> 'intake')::uuid <> (select intake_ok from ca_fix) or r -> 'agent' <> 'null'::jsonb then raise exception 'C2 by label %', r; end if;
  r := pg_temp.j(pg_temp.bot(format($q$select public.donna_intake_for_agent(%L)::text$q$, (select intake_ok from ca_fix))));
  if r ->> 'client_label' <> 'Pine Plumbing' then raise exception 'C2 by id %', r; end if;
  perform pg_temp.expect('C2 rejected', pg_temp.bot($q$select public.donna_intake_for_agent('Rejected Co')::text$q$), 'ERR:refused: that intake was rejected%');
  perform pg_temp.expect('C2 unknown', pg_temp.bot($q$select public.donna_intake_for_agent('Nobody')::text$q$), 'ERR:refused: no intake%');
  a := (pg_temp.j(pg_temp.bot(format($q$select public.donna_record_client_agent(%L, 'agent_abc123', 'llm_abc123', %L)::text$q$, (select intake_ok from ca_fix), repeat('a', 64)))) ->> 'agent')::uuid;
  if a is null then raise exception 'C2 not recorded'; end if;
  perform pg_temp.expect('C2 twice', pg_temp.bot(format($q$select public.donna_record_client_agent(%L, 'agent_def456', 'llm_def456', %L)::text$q$,
                         (select intake_ok from ca_fix), repeat('b', 64))), 'ERR:refused: this client already has an agent%');
  perform pg_temp.expect('C2 bad id', pg_temp.bot(format($q$select public.donna_record_client_agent(%L, 'x y', 'llm_def456', %L)::text$q$,
                         (select intake_rej from ca_fix), repeat('b', 64))), 'ERR:refused: unknown or rejected%');
  if not (pg_temp.j(pg_temp.bot($q$select public.donna_intake_for_agent('Pine Plumbing')::text$q$)) -> 'agent' ? 'retell_agent_id') then raise exception 'C2 agent not shown'; end if;
  r := pg_temp.j(pg_temp.bot(format($q$select public.donna_record_client_report(%L, '2026-11', null, '{"calls": 3}')::text$q$, a)));
  if (r ->> 'duplicate')::boolean then raise exception 'C2 first report %', r; end if;
  r := pg_temp.j(pg_temp.bot(format($q$select public.donna_record_client_report(%L, '2026-11', null, '{"calls": 3}')::text$q$, a)));
  if not (r ->> 'duplicate')::boolean then raise exception 'C2 second report %', r; end if;
  if (pg_temp.j(pg_temp.bot($q$select public.donna_client_agents()::text$q$)) -> 0 ->> 'last_report') <> '2026-11' then raise exception 'C2 list'; end if;
  if not exists (select 1 from public.audit_log where action = 'donna_client_agent') then raise exception 'C2 audit'; end if;
end $$;

-- C3 no API role reaches the schema or the functions
do $$
declare r text; f regprocedure;
begin
  foreach r in array array['anon', 'authenticated', 'service_role', 'fz_jarvis', 'fz_office_agent', 'fz_auditor', 'backup_reader'] loop
    continue when not exists (select 1 from pg_roles where rolname = r);
    if has_schema_privilege(r, 'fz_donna_ca', 'usage') then raise exception 'C3 % has usage on fz_donna_ca', r; end if;
  end loop;
  for f in select p.oid::regprocedure from pg_proc p where p.pronamespace = 'public'::regnamespace
             and p.proname in ('donna_intake_for_agent', 'donna_record_client_agent', 'donna_client_agents', 'donna_record_client_report') loop
    foreach r in array array['anon', 'authenticated', 'fz_jarvis', 'fz_office_agent', 'fz_auditor', 'backup_reader'] loop
      continue when not exists (select 1 from pg_roles where rolname = r);
      if has_function_privilege(r, f, 'execute') then raise exception 'C3 % can execute %', r, f; end if;
    end loop;
  end loop;
end $$;

-- C4 rollback archives with rows, leaves nothing; re-apply twice
\set fz_in_txn 1
\ir ../ops/rollback_donna_client_agents.sql
\ir ../ops/rollback_donna_client_agents.sql
do $$
begin
  if to_regnamespace('fz_donna_ca') is not null then raise exception 'C4 schema left'; end if;
  if exists (select 1 from pg_proc where proname in ('donna_intake_for_agent', 'donna_record_client_agent', 'donna_client_agents', 'donna_record_client_report')) then
    raise exception 'C4 functions left'; end if;
  if (select count(*) from fz_archive.donna_ca_agents) <> 1 or (select count(*) from fz_archive.donna_ca_reports) <> 1 then raise exception 'C4 not archived'; end if;
end $$;
\ir ../migrations/20261211_donna_client_agents_v1.sql
\ir ../migrations/20261211_donna_client_agents_v1.sql
do $$ begin
  if to_regprocedure('public.donna_client_agents()') is null then raise exception 'C4 re-apply'; end if;
  perform public.fz_owner_set_office_status('donna', 'dormant');
end $$;
select 'donna_client_agents_check ok';
rollback;
