-- Office operating system M7 (migrations/20261203_office_os_v1.sql). ONE transaction, rolled back. Fresh apply, repo root.
-- Proves: money controls unchanged (with / without / re-applied M7); the rollback archives every profile and leaves nothing behind, a re-apply keeps the owner's
-- manager appointments; the 8 offices are seeded dormant with no manager and match M1; no API role reaches the profile table; only the signed-in owner appoints,
-- activates or deactivates; activation needs a manager, goes through ONE M3 approval item, is one office at a time, and only an approved, unexpired, matching
-- request activates; dormant and prepared offices cannot spend (M2 gate), an activated one is no longer refused for being dormant; office A cannot read office B.
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
create function pg_temp.noowner(p_sql text) returns text language plpgsql as $$
declare r text; u text := current_setting('app.uid', true);
begin
  perform set_config('app.uid', '', true);
  begin execute p_sql into r; exception when others then perform set_config('app.uid', coalesce(u, ''), true); return 'ERR:' || sqlerrm; end;
  perform set_config('app.uid', coalesce(u, ''), true);
  return 'OK:' || coalesce(r, '');
end $$;
create function pg_temp.owner(p_sql text) returns text language plpgsql as $$
declare r text;
begin
  begin execute p_sql into r; exception when others then return 'ERR:' || sqlerrm; end;
  return 'OK:' || coalesce(r, '');
end $$;
create function pg_temp.dr(p text) returns text language sql as $$
  select case when p like 'OK:{%' then (substr(p, 4)::jsonb ->> 'decision') || '|' || coalesce(substr(p, 4)::jsonb ->> 'reason', '') else p end
$$;
create function pg_temp.res_args(p_office text, p_cents int) returns text language sql as $$
  select format('%L, ''fzo-actor'', ''routine_expense'', ''fzo-vendor'', ''office os check'', ''proves the gate'', ''none'', %s', p_office, p_cents)
$$;
create function pg_temp.st(p_office text) returns text language sql as $$ select status from fz_office_os.fz_office_profiles where slug = p_office $$;
create function pg_temp.m1(p_office text) returns text language sql as $$ select status from public.fz_offices where slug = p_office $$;
\ir include/money_fingerprint.sql
insert into auth.users (id, email) values ('99999999-9999-9999-9999-99999999f007', 'fzo-owner@example.invalid') on conflict do nothing;
insert into public.app_owners (email) values ('fzo-owner@example.invalid') on conflict do nothing;
select set_config('app.uid', '99999999-9999-9999-9999-99999999f007', true);

-- O1 money controls unchanged: with M7 == after its rollback (twice) == after re-applying it; nothing left behind; profiles archived; the manager comes back
\set fz_in_txn 1
create temp table fzo_fp_with as select * from pg_temp.fz_money_fp();
create temp table fzo_ex0 as select count(*) n from public.audit_log where action = 'office_os_export';
select public.office_os_set_manager('fruition-factory', 'drill manager');
\ir ../ops/rollback_office_os.sql
\ir ../ops/rollback_office_os.sql
create temp table fzo_fp_without as select * from pg_temp.fz_money_fp();
do $$
begin
  if to_regnamespace('fz_office_os') is not null or exists (select 1 from pg_proc where proname like 'office\_os\_%') then raise exception 'O1 the rollback left M7 objects behind'; end if;
  if to_regclass('fz_archive.fz_office_profiles') is null or (select count(*) from fz_archive.fz_office_profiles) <> 8
     or (select manager from fz_archive.fz_office_profiles where slug = 'fruition-factory') is distinct from 'drill manager' then raise exception 'O1 the profiles were not archived intact'; end if;
  if (select count(*) from public.audit_log where action = 'office_os_export') <> (select n from fzo_ex0) + 1 then raise exception 'O1 the export record is missing or doubled'; end if;
  if exists (select 1 from pg_namespace n cross join unnest(array['anon', 'authenticated', 'service_role']) r(r) where n.nspname like 'fz\_archive%' and has_schema_privilege(r.r, n.oid, 'usage')) then
    raise exception 'O1 an API role reaches the archive'; end if;
  if to_regclass('public.fz_offices') is null or to_regclass('public.fz_office_money') is null or to_regclass('public.fz_services') is null then raise exception 'O1 the rollback damaged M1 / M2 / M5'; end if;
  if exists (select 1 from fzo_fp_with w full join fzo_fp_without o using (k) where w.v is distinct from o.v) then raise exception 'O1 the money controls differ with and without M7'; end if;
end $$;
\ir ../migrations/20261203_office_os_v1.sql
create temp table fzo_fp_again as select * from pg_temp.fz_money_fp();
do $$
begin
  if exists (select 1 from fzo_fp_again w full join fzo_fp_without o using (k) where w.v is distinct from o.v) then raise exception 'O1 applying M7 changed the money controls'; end if;
  if (select manager from fz_office_os.fz_office_profiles where slug = 'fruition-factory') is distinct from 'drill manager' then raise exception 'O1 the manager appointment was lost across rollback + re-apply'; end if;
  if pg_temp.st('fruition-factory') <> 'dormant' then raise exception 'O1 a re-apply activated an office'; end if;
end $$;
select public.office_os_set_manager('fruition-factory', null);

do $$
declare j jsonb; r text; f text; v_req uuid; v_req2 uuid; n0 bigint; ca jsonb; d text; s text;
  ROLES text[] := array['anon', 'authenticated', 'service_role', 'fz_jarvis', 'fz_office_agent', 'fz_auditor'];
  KEYS text[] := array['telegram', 'supabase', 'scoped_tokens', 'anthropic', 'railway', 'vault', 'llm_free', 'openai_voice', 'resend', 'google', 'meta', 'tiktok', 'linkedin', 'x',
                       'automation', 'wholesale_db', 'github', 'backup', 'whatsapp', 'emergency_call', 'rbc', 'stripe', 'meta_ads', 'elevenlabs', 'gmail', 'google_drive', 'airtable'];
begin
  -- O2 seed: the 8 M1 offices, same ids, all dormant, no manager, valid template
  if (select count(*) from fz_office_os.fz_office_profiles) <> 8 then raise exception 'O2 not 8 profiles'; end if;
  if exists (select 1 from fz_office_os.fz_office_profiles p full join (select * from public.fz_offices where kind = 'office') o on o.id = p.office_id and o.slug = p.slug
              where p.slug is null or o.slug is null) then raise exception 'O2 profiles do not match the M1 offices'; end if;
  if exists (select 1 from fz_office_os.fz_office_profiles where status <> 'dormant' or manager is not null or activation_request is not null) then raise exception 'O2 an office is not seeded dormant without a manager'; end if;
  if exists (select 1 from public.fz_offices where kind = 'office' and status <> 'dormant') then raise exception 'O2 an M1 office is not dormant'; end if;
  if exists (select 1 from fz_office_os.fz_office_profiles, unnest(integrations) i where not i = any (KEYS)) then raise exception 'O2 an unknown integration key'; end if;
  if exists (select 1 from fz_office_os.fz_office_profiles p, lateral (select a, count(*) from jsonb_each(p.autonomy) t(tier, l), jsonb_array_elements_text(l) a group by a having count(*) > 1) x) then
    raise exception 'O2 an action is in two autonomy tiers'; end if;
  if (select string_agg(slug || ':' || activation_rank, ',' order by activation_rank) from fz_office_os.fz_office_profiles where activation_rank is not null) <> 'donna:1,wolf-squad:2,ff-marketing:3' then
    raise exception 'O2 activation order'; end if;
  if exists (select 1 from fz_office_os.fz_office_profiles where cardinality(agent_roles) = 0 or not ('telegram' = any (integrations))) then raise exception 'O2 template incomplete'; end if;

  -- O3 privileges: no API role reaches the schema or the table; nobody but the service path executes the functions
  foreach r in array ROLES loop
    if has_schema_privilege(r, 'fz_office_os', 'usage') or has_schema_privilege(r, 'fz_office_os', 'create') then raise exception 'O3 % reaches the schema', r; end if;
    if has_table_privilege(r, 'fz_office_os.fz_office_profiles', 'select,insert,update,delete,truncate,references,trigger') then raise exception 'O3 % holds a privilege on the profiles', r; end if;
    foreach f in array array['office_os_set_manager(text,text)', 'office_os_activate(text)', 'office_os_deactivate(text)', 'office_os_status(text)'] loop
      if r <> 'service_role' and has_function_privilege(r, ('public.' || f)::regprocedure, 'execute') then raise exception 'O3 % executes %', r, f; end if;
    end loop;
  end loop;
  if pg_temp.svc('select count(*)::text from fz_office_os.fz_office_profiles') not like 'ERR:permission denied%' then raise exception 'O3 the bot reads the table'; end if;
  if pg_temp.svc($q$update fz_office_os.fz_office_profiles set manager = 'x'$q$) not like 'ERR:permission denied%' then raise exception 'O3 the bot writes the table'; end if;

  -- O4 owner only: the bot, a session without the owner uid and the scoped roles are refused
  foreach f in array array[$q$select public.office_os_set_manager('donna', 'x')::text$q$, $q$select public.office_os_activate('donna')::text$q$, $q$select public.office_os_deactivate('donna')::text$q$] loop
    if pg_temp.svc(f) not like 'ERR:owner approval required%' then raise exception 'O4 the bot ran %', f; end if;
    if pg_temp.noowner(f) not like 'ERR:owner approval required%' then raise exception 'O4 a session without the owner ran %', f; end if;
    if pg_temp.as_id('fz_office_agent', pg_temp.cl('office:donna:manager', 'fz_office_agent'), f) not like 'ERR:permission denied%' then raise exception 'O4 a scoped role ran %', f; end if;
  end loop;
  if pg_temp.st('donna') <> 'dormant' or (select manager from fz_office_os.fz_office_profiles where slug = 'donna') is not null then raise exception 'O4 a refused call changed the profile'; end if;

  -- O5 activation needs a manager: refused, nothing created; the table itself refuses an active / prepared office without one
  n0 := (select count(*) from public.approval_requests);
  if pg_temp.owner($q$select public.office_os_activate('donna')::text$q$) not like 'ERR:refused: appoint a manager%' then raise exception 'O5 activated without a manager'; end if;
  if (select count(*) from public.approval_requests) <> n0 or pg_temp.st('donna') <> 'dormant' then raise exception 'O5 the refused activation left something'; end if;
  begin update fz_office_os.fz_office_profiles set status = 'active' where slug = 'donna'; raise exception 'O5-x';
  exception when check_violation then null; when others then if sqlerrm = 'O5-x' then raise exception 'O5 the table accepts an active office without a manager'; end if; raise; end;
  if pg_temp.owner($q$select public.office_os_set_manager('donna', 'bad;label')::text$q$) not like 'ERR:manager label%' then raise exception 'O5 bad manager label accepted'; end if;
  if pg_temp.owner($q$select public.office_os_set_manager('nowhere', 'x')::text$q$) not like 'ERR:unknown office%' then raise exception 'O5 unknown office'; end if;

  -- O6 dormant offices cannot spend: allocate (owner, M2) to two dormant offices; the gate refuses all 8 dormant offices
  update public.capital_policy set operating_fund_cents = operating_fund_cents + 1000000, updated_by = 'owner:test' where id = 1;   -- room for the fixtures (rolled back)
  perform public.fz_owner_allocate('donna', 5000, 'fzo fixture');
  perform public.fz_owner_allocate('wolf-squad', 5000, 'fzo fixture');
  for s in select slug from fz_office_os.fz_office_profiles loop
    if pg_temp.dr(pg_temp.svc(format('select public.fz_reserve_office_spend(%s)::text', pg_temp.res_args(s, 50)))) not like 'deny|%dormant%' then raise exception 'O6 dormant office % can spend', s; end if;
  end loop;

  -- O7 the activation flow: request -> prepared (M1 still dormant, still no spend) -> approve -> active
  perform public.office_os_set_manager('donna', 'Donna lead');
  perform public.office_os_set_manager('wolf-squad', 'Wolf lead');
  j := public.office_os_activate('donna');
  v_req := (j ->> 'approval')::uuid;
  if j ->> 'status' <> 'prepared' or pg_temp.st('donna') <> 'prepared' or pg_temp.m1('donna') <> 'dormant' then raise exception 'O7 not prepared: %', j; end if;
  if (select action || '|' || ref || '|' || status || '|' || cents from public.approval_requests where id = v_req) <> 'office_activate|office:donna|pending|0' then raise exception 'O7 approval item'; end if;
  if not exists (select 1 from public.owner_messages where ref_table = 'approval_requests' and ref_id = v_req and needs_decision and kind = 'proposal') then raise exception 'O7 no Telegram approval message'; end if;
  if not exists (select 1 from public.fz_approval_queue where source_id = v_req and status = 'pending' and action = 'office_activate') then raise exception 'O7 not in the M3 queue'; end if;
  if pg_temp.dr(pg_temp.svc(format('select public.fz_reserve_office_spend(%s)::text', pg_temp.res_args('donna', 50)))) not like 'deny|%dormant%' then raise exception 'O7 a prepared office can spend'; end if;
  if public.office_os_activate('donna') ->> 'status' <> 'prepared' then raise exception 'O7 a pending approval activated'; end if;
  -- one at a time
  if pg_temp.owner($q$select public.office_os_activate('wolf-squad')::text$q$) not like 'ERR:refused: one office at a time: donna%' then raise exception 'O7 two offices prepared at once'; end if;
  begin update fz_office_os.fz_office_profiles set status = 'prepared', activation_request = v_req where slug = 'wolf-squad'; raise exception 'O7-x';
  exception when unique_violation then null; when others then if sqlerrm = 'O7-x' then raise exception 'O7 the table accepts two prepared offices'; end if; raise; end;
  -- a forged approved request (not the recorded one) does not count; the bot cannot activate
  insert into public.approval_requests (actor, action, cents, ref, recommendation, status) values ('jarvis', 'office_activate', 0, 'office:donna', 'forged', 'approved');
  if public.office_os_activate('donna') ->> 'status' <> 'prepared' then raise exception 'O7 a forged approval activated'; end if;
  -- the owner's tap (hq_policy.decide_approval: pending -> approved; the service key bypasses RLS on Supabase, so this runs as the database session, as approvals_kernel_check)
  update public.approval_requests set status = 'approved', decided_at = now() where id = v_req and status = 'pending';
  if pg_temp.svc($q$select public.office_os_activate('donna')::text$q$) not like 'ERR:owner approval required%' then raise exception 'O7 the bot activated after approval'; end if;
  if pg_temp.st('donna') <> 'prepared' then raise exception 'O7 the bot changed the state'; end if;
  j := public.office_os_activate('donna');
  if j ->> 'status' <> 'active' or pg_temp.st('donna') <> 'active' or pg_temp.m1('donna') <> 'active' then raise exception 'O7 not activated: %', j; end if;
  if not exists (select 1 from public.audit_log where action = 'office_activated' and target = 'fz_office_profiles/donna') then raise exception 'O7 not audited'; end if;
  if public.office_os_activate('donna') ->> 'note' <> 'already active' then raise exception 'O7 not idempotent'; end if;
  d := pg_temp.dr(pg_temp.svc(format('select public.fz_reserve_office_spend(%s)::text', pg_temp.res_args('donna', 50))));
  if d like '%dormant%' or d like 'ERR:%' then raise exception 'O7 an active office is still refused as dormant: %', d; end if;
  if pg_temp.owner($q$select public.office_os_set_manager('donna', null)::text$q$) not like 'ERR:refused: donna is active%' then raise exception 'O7 manager removed from an active office'; end if;

  -- O8 a rejected or expired approval puts the office back to dormant; a fresh request is needed
  v_req2 := (public.office_os_activate('wolf-squad') ->> 'approval')::uuid;
  update public.approval_requests set status = 'rejected', decided_at = now() where id = v_req2;
  j := public.office_os_activate('wolf-squad');
  if j ->> 'status' <> 'dormant' or pg_temp.st('wolf-squad') <> 'dormant' or pg_temp.m1('wolf-squad') <> 'dormant' then raise exception 'O8 rejected approval: %', j; end if;
  v_req2 := (public.office_os_activate('wolf-squad') ->> 'approval')::uuid;
  update public.approval_requests set status = 'approved', expires_at = now() - interval '1 minute' where id = v_req2;
  if public.office_os_activate('wolf-squad') ->> 'status' <> 'dormant' or pg_temp.m1('wolf-squad') <> 'dormant' then raise exception 'O8 an expired approval activated'; end if;
  if pg_temp.dr(pg_temp.svc(format('select public.fz_reserve_office_spend(%s)::text', pg_temp.res_args('wolf-squad', 50)))) not like 'deny|%dormant%' then raise exception 'O8 wolf-squad can spend'; end if;

  -- O9 office A cannot read office B: no privilege at all; with a grant added by mistake the function still serves only the caller's own office
  perform public.fz_owner_set_identity('office:donna:manager', 'active');
  ca := pg_temp.cl('office:donna:manager', 'fz_office_agent');
  if pg_temp.as_id('fz_office_agent', ca, $q$select public.office_os_status('donna')::text$q$) not like 'ERR:permission denied%' then raise exception 'O9 scoped role executes the status without a grant'; end if;
  if pg_temp.as_id('fz_office_agent', ca, 'select count(*)::text from fz_office_os.fz_office_profiles') not like 'ERR:permission denied%' then raise exception 'O9 scoped role reads the table'; end if;
  grant execute on function public.office_os_status(text) to fz_office_agent, anon;     -- the mistake (rolled back)
  if pg_temp.as_id('fz_office_agent', ca, $q$select public.office_os_status('donna') ->> 'office'$q$) <> 'OK:donna' then raise exception 'O9 own office not served (non-vacuous check)'; end if;
  foreach s in array array['wolf-squad', 'b2b-records', 'ff-marketing'] loop
    if pg_temp.as_id('fz_office_agent', ca, format('select public.office_os_status(%L)::text', s)) not like 'ERR:refused: a scoped identity may only read its own office%' then raise exception 'O9 donna reads %', s; end if;
  end loop;
  if pg_temp.as_id('fz_office_agent', ca, 'select public.office_os_status(null)::text') not like 'ERR:refused%' then raise exception 'O9 donna reads every office'; end if;
  if pg_temp.as_id('fz_office_agent', pg_temp.cl('office:wolf-squad:manager', 'fz_office_agent'), $q$select public.office_os_status('donna')::text$q$) not like 'ERR:refused%' then raise exception 'O9 a dormant identity reads donna'; end if;
  if pg_temp.as_id('anon', null, $q$select public.office_os_status('donna')::text$q$) not like 'ERR:refused%' then raise exception 'O9 anon reads'; end if;
  revoke execute on function public.office_os_status(text) from fz_office_agent, anon;

  -- O10 status read model for the owner's /office: service path; one office or all 8; drift when M1 is changed behind M7's back
  j := (substr(pg_temp.svc($q$select public.office_os_status('donna')::text$q$), 4))::jsonb;
  if j ->> 'status' <> 'active' or j ->> 'manager' <> 'Donna lead' or (j ->> 'drift')::boolean or j ->> 'approval_status' <> 'approved' or (j ->> 'available_cents') is null then raise exception 'O10 status: %', j; end if;
  if jsonb_array_length((substr(pg_temp.svc('select public.office_os_status()::text'), 4))::jsonb) <> 8 then raise exception 'O10 list'; end if;
  if pg_temp.svc($q$select public.office_os_status('nowhere')::text$q$) not like 'ERR:unknown office%' then raise exception 'O10 unknown office'; end if;
  perform public.fz_owner_set_office_status('b2b-records', 'active');
  if not (public.office_os_status('b2b-records') ->> 'drift')::boolean then raise exception 'O10 drift not reported'; end if;

  -- O11 deactivate: M1 back to dormant, spend refused again
  j := public.office_os_deactivate('donna');
  if pg_temp.st('donna') <> 'dormant' or pg_temp.m1('donna') <> 'dormant' then raise exception 'O11 deactivate: %', j; end if;
  if pg_temp.dr(pg_temp.svc(format('select public.fz_reserve_office_spend(%s)::text', pg_temp.res_args('donna', 50)))) not like 'deny|%dormant%' then raise exception 'O11 a deactivated office can spend'; end if;

  -- O12 nothing outside M7 changed shape: the profile table is not in public, not registered, nothing unregistered / unclassified
  if exists (select 1 from public.fz_unregistered_tables()) then raise exception 'O12 unregistered table'; end if;
  if public.backup_export_policy() -> 'unclassified' <> '[]'::jsonb then raise exception 'O12 unclassified'; end if;
  raise notice 'office_os_check: all checks passed';
end $$;
rollback;
