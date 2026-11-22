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
select public.office_os_set_manager('fruition-factory', 'drill manager');
select public.office_os_activate('fruition-factory') ->> 'status';                        -- a decision row (nonce) to archive
select public.fz_owner_set_office_status('b2b-records', 'active');
select public.office_os_drift_check();                                                   -- a drift row to archive
select public.fz_owner_set_office_status('b2b-records', 'dormant');
create temp table fzo_rows0 as select (select count(*) from fz_office_os.fz_office_profiles) p, (select count(*) from fz_office_os.fz_office_decisions) d,
  (select count(*) from fz_office_os.fz_office_drift) r, (select count(*) from fz_office_os.fz_office_profiles where manager is not null) m;
create temp table fzo_money0 as select md5(string_agg(p.oid::regprocedure::text || md5(pg_get_functiondef(p.oid)) || coalesce(p.proacl::text, ''), ',' order by p.oid::regprocedure::text)) h
  from pg_proc p where p.pronamespace = 'public'::regnamespace and p.proname in ('fz_owner_set_office_status', 'fz_set_office_policy', 'fz_reserve_office_spend', 'fz_brain_read');
create temp table fzo_fp_with as select * from pg_temp.fz_money_fp();
create temp table fzo_ex0 as select count(*) n from public.audit_log where action = 'office_os_export';
\ir ../ops/rollback_office_os.sql
\ir ../ops/rollback_office_os.sql
create temp table fzo_fp_without as select * from pg_temp.fz_money_fp();
do $$
begin
  if to_regnamespace('fz_office_os') is not null or exists (select 1 from pg_proc where proname like 'office\_os\_%') then raise exception 'O1 the rollback left M7 objects behind'; end if;
  if (select (p, d, r, m)::text from fzo_rows0) <> ((select count(*) from fz_archive.fz_office_profiles), (select count(*) from fz_archive.fz_office_decisions),
      (select count(*) from fz_archive.fz_office_drift), (select count(*) from fz_archive.fz_office_profiles where manager is not null))::text
     or (select (p, d, r, m)::text from fzo_rows0) is distinct from '(8,1,1,1)' then raise exception 'O1 rows lost in the archive: %', (select (p, d, r, m)::text from fzo_rows0); end if;
  if exists (select 1 from pg_namespace where nspname = 'cron') and exists (select 1 from cron.job where jobname = 'office-os-drift') then raise exception 'O1 the drift job survived the rollback'; end if;
  if (select h from fzo_money0) is distinct from (select md5(string_agg(p.oid::regprocedure::text || md5(pg_get_functiondef(p.oid)) || coalesce(p.proacl::text, ''), ',' order by p.oid::regprocedure::text))
        from pg_proc p where p.pronamespace = 'public'::regnamespace and p.proname in ('fz_owner_set_office_status', 'fz_set_office_policy', 'fz_reserve_office_spend', 'fz_brain_read')) then
    raise exception 'O1 the rollback changed an M1 / M2 / M6 function'; end if;
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
  if pg_temp.st('fruition-factory') is distinct from 'dormant' or exists (select 1 from fz_office_os.fz_office_profiles where status <> 'dormant' or activation_request is not null) then raise exception 'O1 a re-apply restored a pending or active state'; end if;
  if exists (select 1 from pg_namespace where nspname = 'cron') and not exists (select 1 from cron.job where jobname = 'office-os-drift') then raise exception 'O1 the drift job is not scheduled'; end if;
end $$;
select public.office_os_set_manager('fruition-factory', null);

do $$
declare j jsonb; r text; f text; v_req uuid; v_req2 uuid; v_n text; v_n2 text; n0 bigint; ca jsonb; d text; s text;
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
  if (select string_agg(slug || ':' || activation_rank, ',' order by activation_rank) from fz_office_os.fz_office_profiles where activation_rank is not null) is distinct from 'donna:1,wolf-squad:2,ff-marketing:3' then
    raise exception 'O2 activation order'; end if;
  if exists (select 1 from fz_office_os.fz_office_profiles where cardinality(agent_roles) = 0 or not ('telegram' = any (integrations))) then raise exception 'O2 template incomplete'; end if;

  -- O3 privileges: no API role reaches the schema or the table; nobody but the service path executes the functions
  foreach r in array ROLES loop
    if has_schema_privilege(r, 'fz_office_os', 'usage') or has_schema_privilege(r, 'fz_office_os', 'create') then raise exception 'O3 % reaches the schema', r; end if;
    foreach f in array array['fz_office_profiles', 'fz_office_decisions', 'fz_office_drift', 'fz_office_invoices', 'fz_billing_plans'] loop
      if has_table_privilege(r, ('fz_office_os.' || f)::regclass, 'select,insert,update,delete,truncate,references,trigger') then raise exception 'O3 % holds a privilege on %', r, f; end if;
    end loop;
    foreach f in array array['office_os_set_manager(text,text)', 'office_os_activate(text)', 'office_os_decide(text,text,boolean)', 'office_os_deactivate(text)', 'office_os_status(text)', 'office_os_drift_check()', 'office_os_invoice_record(text,text,text,text,integer,text,text)', 'office_os_invoice_request_send(uuid)', 'office_os_invoice_decide(uuid,integer,boolean)', 'office_os_invoice_claim_send(uuid)', 'office_os_invoice_mark_sent(uuid,boolean)', 'office_os_invoices(integer)', 'office_os_plan_propose(text,text,text,integer,text,text)', 'office_os_plan_decide(uuid,integer,text,boolean)', 'office_os_plan_revoke(uuid)', 'office_os_invoice_record_plan(uuid,text,text,integer,text,text)', 'office_os_plans()'] loop
      if r <> 'service_role' and has_function_privilege(r, ('public.' || f)::regprocedure, 'execute') then raise exception 'O3 % executes %', r, f; end if;
    end loop;
  end loop;
  if pg_temp.svc('select count(*)::text from fz_office_os.fz_office_profiles') not like 'ERR:permission denied%' then raise exception 'O3 the bot reads the table'; end if;
  if pg_temp.svc($q$update fz_office_os.fz_office_profiles set manager = 'x'$q$) not like 'ERR:permission denied%' then raise exception 'O3 the bot writes the table'; end if;
  if pg_temp.svc('select count(*)::text from fz_office_os.fz_office_decisions') not like 'ERR:permission denied%' then raise exception 'O3 the bot reads the decisions (nonces)'; end if;
  if pg_temp.svc($q$update fz_office_os.fz_office_decisions set approved = true$q$) not like 'ERR:permission denied%' then raise exception 'O3 the bot writes a decision'; end if;

  -- O4 owner only: the bot, a session without the owner uid and the scoped roles are refused
  foreach f in array array[$q$select public.office_os_set_manager('donna', 'x')::text$q$, $q$select public.office_os_activate('donna')::text$q$, $q$select public.office_os_deactivate('donna')::text$q$,
                           $q$select public.office_os_decide('donna', repeat('a', 64), true)::text$q$] loop
    if pg_temp.svc(f) not like 'ERR:owner approval required%' then raise exception 'O4 the bot ran %', f; end if;
    if pg_temp.noowner(f) not like 'ERR:owner approval required%' then raise exception 'O4 a session without the owner ran %', f; end if;
    if pg_temp.as_id('fz_office_agent', pg_temp.cl('office:donna:manager', 'fz_office_agent'), f) not like 'ERR:permission denied%' then raise exception 'O4 a scoped role ran %', f; end if;
  end loop;
  if pg_temp.st('donna') is distinct from 'dormant' or (select manager from fz_office_os.fz_office_profiles where slug = 'donna') is not null then raise exception 'O4 a refused call changed the profile'; end if;

  -- O5 activation needs a manager: refused, nothing created; the table itself refuses an active / prepared office without one
  n0 := (select count(*) from public.approval_requests);
  if pg_temp.owner($q$select public.office_os_activate('donna')::text$q$) not like 'ERR:refused: appoint a manager%' then raise exception 'O5 activated without a manager'; end if;
  if (select count(*) from public.approval_requests) <> n0 or pg_temp.st('donna') is distinct from 'dormant' then raise exception 'O5 the refused activation left something'; end if;
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

  -- O7 the activation flow: request (nonce) -> prepared (M1 still dormant, still no spend) -> owner decision -> active
  perform public.office_os_set_manager('donna', 'Donna lead');
  perform public.office_os_set_manager('wolf-squad', 'Wolf lead');
  j := public.office_os_activate('donna');
  v_req := (j ->> 'approval')::uuid; v_n := j ->> 'nonce';
  if j ->> 'status' is distinct from 'prepared' or pg_temp.st('donna') is distinct from 'prepared' or pg_temp.m1('donna') is distinct from 'dormant' or v_n !~ '^[0-9a-f]{64}$' then raise exception 'O7 not prepared: %', j; end if;
  if (select action || '|' || ref || '|' || status || '|' || cents from public.approval_requests where id = v_req) is distinct from 'office_activate|office:donna|pending|0' then raise exception 'O7 approval item'; end if;
  if not exists (select 1 from public.owner_messages where ref_table = 'approval_requests' and ref_id = v_req and not needs_decision and kind = 'proposal') then raise exception 'O7 no (informational) Telegram note'; end if;
  if exists (select 1 from public.owner_messages where ref_id = v_req and body like '%' || v_n || '%') or exists (select 1 from public.approval_requests where id = v_req and recommendation like '%' || v_n || '%')
     or exists (select 1 from public.audit_log where detail::text like '%' || v_n || '%') then raise exception 'O7 the nonce leaked into a service-readable table'; end if;
  if not exists (select 1 from public.fz_approval_queue where source_id = v_req and status = 'pending' and action = 'office_activate') then raise exception 'O7 not in the M3 queue'; end if;
  if pg_temp.dr(pg_temp.svc(format('select public.fz_reserve_office_spend(%s)::text', pg_temp.res_args('donna', 50)))) not like 'deny|%dormant%' then raise exception 'O7 a prepared office can spend'; end if;
  if public.office_os_activate('donna') ->> 'status' is distinct from 'prepared' then raise exception 'O7 an undecided request activated'; end if;
  if public.office_os_activate('donna') ->> 'nonce' <> v_n then raise exception 'O7 the owner cannot see the nonce again'; end if;
  -- one at a time
  if pg_temp.owner($q$select public.office_os_activate('wolf-squad')::text$q$) not like 'ERR:refused: one office at a time: donna%' then raise exception 'O7 two offices prepared at once'; end if;
  begin update fz_office_os.fz_office_profiles set status = 'prepared', activation_request = v_req where slug = 'wolf-squad'; raise exception 'O7-x';
  exception when unique_violation then null; when others then if sqlerrm = 'O7-x' then raise exception 'O7 the table accepts two prepared offices'; end if; raise; end;
  -- the review finding: the service key approves the request itself (approval_requests is writable by it on Supabase) -> it does NOT count
  update public.approval_requests set status = 'approved', decided_at = now() where id = v_req and status = 'pending';
  insert into public.approval_requests (actor, action, cents, ref, recommendation, status) values ('jarvis', 'office_activate', 0, 'office:donna', 'forged', 'approved');
  if public.office_os_activate('donna') ->> 'status' is distinct from 'prepared' or pg_temp.m1('donna') is distinct from 'dormant' then raise exception 'O7 a service-key approval activated the office'; end if;
  update public.approval_requests set status = 'pending', decided_at = null where id = v_req;
  -- the decision: owner only, right nonce only, once
  if pg_temp.svc(format($q$select public.office_os_decide('donna', %L, true)::text$q$, v_n)) not like 'ERR:owner approval required%' then raise exception 'O7 the bot decided'; end if;
  if pg_temp.noowner(format($q$select public.office_os_decide('donna', %L, true)::text$q$, v_n)) not like 'ERR:owner approval required%' then raise exception 'O7 a session without the owner decided'; end if;
  if pg_temp.owner($q$select public.office_os_decide('donna', repeat('0', 64), true)::text$q$) not like 'ERR:refused: wrong nonce%' then raise exception 'O7 wrong nonce accepted'; end if;
  if pg_temp.owner(format($q$select public.office_os_decide('wolf-squad', %L, true)::text$q$, v_n)) not like 'ERR:refused: wolf-squad has no activation waiting%' then raise exception 'O7 nonce reused for another office'; end if;
  if (select approved from fz_office_os.fz_office_decisions where request_id = v_req) is not null then raise exception 'O7 a refused decision was recorded'; end if;
  j := public.office_os_decide('donna', v_n, true);
  if not (j ->> 'ok')::boolean or (select status from public.approval_requests where id = v_req) is distinct from 'approved' then raise exception 'O7 decision: %', j; end if;
  if (public.office_os_decide('donna', v_n, false) ->> 'reason') is distinct from 'already decided' then raise exception 'O7 decision not single-use'; end if;
  if pg_temp.svc($q$select public.office_os_activate('donna')::text$q$) not like 'ERR:owner approval required%' then raise exception 'O7 the bot activated after the decision'; end if;
  j := public.office_os_activate('donna');
  if j ->> 'status' is distinct from 'active' or pg_temp.st('donna') is distinct from 'active' or pg_temp.m1('donna') is distinct from 'active' then raise exception 'O7 not activated: %', j; end if;
  if (select consumed_at from fz_office_os.fz_office_decisions where request_id = v_req) is null then raise exception 'O7 decision not consumed'; end if;
  if not exists (select 1 from public.audit_log where action = 'office_activated' and target = 'fz_office_profiles/donna') then raise exception 'O7 not audited'; end if;
  if public.office_os_activate('donna') ->> 'note' is distinct from 'already active' then raise exception 'O7 not idempotent'; end if;
  -- the prohibited defaults that are real actions are now office blocks; the rest are advisory
  if (select string_agg(action || '=' || allowed, ',' order by action) from public.fz_office_action_policy where office_id = 'f0000000-0000-4000-8000-000000000002') is distinct from 'deceptive_communication=false' then
    raise exception 'O7 donna office blocks: %', (select string_agg(action || '=' || allowed, ',') from public.fz_office_action_policy where office_id = 'f0000000-0000-4000-8000-000000000002'); end if;
  if j -> 'office_blocks' <> '["deceptive_communication"]'::jsonb then raise exception 'O7 office_blocks %', j; end if;
  d := pg_temp.dr(pg_temp.svc(format('select public.fz_reserve_office_spend(%s)::text', pg_temp.res_args('donna', 50))));
  if d like '%dormant%' or d like 'ERR:%' then raise exception 'O7 an active office is still refused as dormant: %', d; end if;
  if pg_temp.owner($q$select public.office_os_set_manager('donna', null)::text$q$) not like 'ERR:refused: donna is active%' then raise exception 'O7 manager removed from an active office'; end if;
  if pg_temp.owner($q$select public.office_os_decide('donna', repeat('a', 64), true)::text$q$) not like 'ERR:refused: donna has no activation waiting%' then raise exception 'O7 decide on an active office'; end if;

  -- O8 a rejected or expired decision puts the office back to dormant; a fresh request is needed
  j := public.office_os_activate('wolf-squad'); v_req2 := (j ->> 'approval')::uuid; v_n2 := j ->> 'nonce';
  perform public.office_os_decide('wolf-squad', v_n2, false);
  if (select status from public.approval_requests where id = v_req2) is distinct from 'rejected' then raise exception 'O8 rejection not mirrored'; end if;
  j := public.office_os_activate('wolf-squad');
  if j ->> 'status' is distinct from 'dormant' or pg_temp.st('wolf-squad') is distinct from 'dormant' or pg_temp.m1('wolf-squad') is distinct from 'dormant' then raise exception 'O8 rejected: %', j; end if;
  j := public.office_os_activate('wolf-squad'); v_req2 := (j ->> 'approval')::uuid; v_n2 := j ->> 'nonce';
  if v_n2 is null or v_n2 = v_n then raise exception 'O8 no fresh nonce'; end if;
  perform public.office_os_decide('wolf-squad', v_n2, true);
  update fz_office_os.fz_office_decisions set expires_at = now() - interval '1 minute' where request_id = v_req2;
  if public.office_os_activate('wolf-squad') ->> 'status' is distinct from 'dormant' or pg_temp.m1('wolf-squad') is distinct from 'dormant' then raise exception 'O8 an expired decision activated'; end if;
  j := public.office_os_activate('wolf-squad'); v_n2 := j ->> 'nonce';
  update fz_office_os.fz_office_decisions set expires_at = now() - interval '1 minute' where request_id = (j ->> 'approval')::uuid;
  if pg_temp.owner(format($q$select public.office_os_decide('wolf-squad', %L, true)::text$q$, v_n2)) not like 'ERR:refused: the activation request for wolf-squad expired%' then raise exception 'O8 decided an expired request'; end if;
  perform public.office_os_deactivate('wolf-squad');
  if pg_temp.dr(pg_temp.svc(format('select public.fz_reserve_office_spend(%s)::text', pg_temp.res_args('wolf-squad', 50)))) not like 'deny|%dormant%' then raise exception 'O8 wolf-squad can spend'; end if;
  if exists (select 1 from public.fz_office_action_policy where office_id = 'f0000000-0000-4000-8000-000000000004') then raise exception 'O8 office blocks applied without activation'; end if;

  -- O9 office A cannot read office B: no privilege at all; with a grant added by mistake the function still serves only the caller's own office
  perform public.fz_owner_set_identity('office:donna:manager', 'active');
  ca := pg_temp.cl('office:donna:manager', 'fz_office_agent');
  if pg_temp.as_id('fz_office_agent', ca, $q$select public.office_os_status('donna')::text$q$) not like 'ERR:permission denied%' then raise exception 'O9 scoped role executes the status without a grant'; end if;
  if pg_temp.as_id('fz_office_agent', ca, 'select count(*)::text from fz_office_os.fz_office_profiles') not like 'ERR:permission denied%' then raise exception 'O9 scoped role reads the table'; end if;
  grant execute on function public.office_os_status(text) to fz_office_agent, anon;     -- the mistake (rolled back)
  if pg_temp.as_id('fz_office_agent', ca, $q$select public.office_os_status('donna') ->> 'office'$q$) is distinct from 'OK:donna' then raise exception 'O9 own office not served (non-vacuous check)'; end if;
  foreach s in array array['wolf-squad', 'b2b-records', 'ff-marketing'] loop
    if pg_temp.as_id('fz_office_agent', ca, format('select public.office_os_status(%L)::text', s)) not like 'ERR:refused: a scoped identity may only read its own office%' then raise exception 'O9 donna reads %', s; end if;
  end loop;
  if pg_temp.as_id('fz_office_agent', ca, 'select public.office_os_status(null)::text') not like 'ERR:refused%' then raise exception 'O9 donna reads every office'; end if;
  if pg_temp.as_id('fz_office_agent', pg_temp.cl('office:wolf-squad:manager', 'fz_office_agent'), $q$select public.office_os_status('donna')::text$q$) not like 'ERR:refused%' then raise exception 'O9 a dormant identity reads donna'; end if;
  if pg_temp.as_id('anon', null, $q$select public.office_os_status('donna')::text$q$) not like 'ERR:refused%' then raise exception 'O9 anon reads'; end if;
  revoke execute on function public.office_os_status(text) from fz_office_agent, anon;

  -- O10 status read model for the owner's /office: service path; one office or all 8; drift when M1 is changed behind M7's back
  j := (substr(pg_temp.svc($q$select public.office_os_status('donna')::text$q$), 4))::jsonb;
  if j ->> 'status' is distinct from 'active' or j ->> 'manager' is distinct from 'Donna lead' or (j ->> 'drift')::boolean or j ->> 'approval_status' is distinct from 'approved' or (j ->> 'available_cents') is null then raise exception 'O10 status: %', j; end if;
  if jsonb_array_length((substr(pg_temp.svc('select public.office_os_status()::text'), 4))::jsonb) <> 8 then raise exception 'O10 list'; end if;
  if pg_temp.svc($q$select public.office_os_status('nowhere')::text$q$) not like 'ERR:unknown office%' then raise exception 'O10 unknown office'; end if;
  perform public.fz_owner_set_office_status('b2b-records', 'active');
  if not (public.office_os_status('b2b-records') ->> 'drift')::boolean then raise exception 'O10 drift not reported'; end if;

  -- O13 drift alert: change-only, once per change, cleared when back in sync; only the service path / cron runs it
  n0 := (select count(*) from public.owner_messages where kind = 'health' and body like 'DRIFT: office B2B Records%');
  perform public.office_os_drift_check();
  if (select count(*) from public.owner_messages where kind = 'health' and body like 'DRIFT: office B2B Records%') <> n0 + 1 then raise exception 'O13 no drift alert'; end if;
  n0 := n0 + 1;
  perform public.office_os_drift_check();
  if (select count(*) from public.owner_messages where kind = 'health' and body like 'DRIFT: office B2B Records%') <> n0 then raise exception 'O13 drift alerted twice'; end if;
  if (public.office_os_status('b2b-records') ->> 'drift_alerted_at') is null then raise exception 'O13 status does not show the alert'; end if;
  if pg_temp.as_id('anon', null, 'select public.office_os_drift_check()::text') not like 'ERR:permission denied%' then raise exception 'O13 anon runs the drift check'; end if;
  grant execute on function public.office_os_drift_check() to fz_office_agent;
  if pg_temp.as_id('fz_office_agent', ca, 'select public.office_os_drift_check()::text') not like 'ERR:refused%' then raise exception 'O13 a scoped role runs the drift check'; end if;
  revoke execute on function public.office_os_drift_check() from fz_office_agent;
  perform public.fz_owner_set_office_status('b2b-records', 'dormant');
  perform public.office_os_drift_check();
  if (select state from fz_office_os.fz_office_drift where slug = 'b2b-records') is not null or not exists (select 1 from public.audit_log where action = 'office_drift_cleared') then raise exception 'O13 drift not cleared'; end if;
  if (public.office_os_status('b2b-records') -> 'prohibited_enforced') is distinct from '["evade_platform_restrictions", "fabricate"]'::jsonb
     or not (public.office_os_status('b2b-records') -> 'prohibited_advisory') ? 'buy_streams' then raise exception 'O13 enforced / advisory split'; end if;

  -- O11 deactivate: M1 back to dormant, spend refused again
  j := public.office_os_deactivate('donna');
  if pg_temp.st('donna') is distinct from 'dormant' or pg_temp.m1('donna') is distinct from 'dormant' then raise exception 'O11 deactivate: %', j; end if;
  if pg_temp.dr(pg_temp.svc(format('select public.fz_reserve_office_spend(%s)::text', pg_temp.res_args('donna', 50)))) not like 'deny|%dormant%' then raise exception 'O11 a deactivated office can spend'; end if;

  -- O14 client invoicing: drafts only for an ACTIVE office with stripe allowed; a send needs the owner's per-invoice decision (amount echoed); no money row is written
  n0 := (select count(*) from public.ledger);
  if pg_temp.svc($q$select public.office_os_invoice_record('donna', 'invoice', 'in_fzotest0001', 'test', 49700, 'cad', 'Answer setup')::text$q$) not like 'ERR:refused: donna is not active%' then raise exception 'O14 a dormant office recorded an invoice'; end if;
  if pg_temp.svc($q$select public.office_os_invoice_record('wolf-squad', 'invoice', 'in_fzotest0002', 'test', 100, 'cad', 'x')::text$q$) not like 'ERR:refused: wolf-squad is not active%' then raise exception 'O14 wolf-squad recorded'; end if;
  j := public.office_os_activate('donna'); perform public.office_os_decide('donna', j ->> 'nonce', true); perform public.office_os_activate('donna');
  if pg_temp.st('donna') is distinct from 'active' then raise exception 'O14 donna not re-activated'; end if;
  if pg_temp.as_id('fz_office_agent', ca, $q$select public.office_os_invoice_record('donna', 'invoice', 'in_fzotest0003', 'test', 100, 'cad', 'x')::text$q$) not like 'ERR:permission denied%' then raise exception 'O14 a scoped role recorded'; end if;
  j := (substr(pg_temp.svc($q$select public.office_os_invoice_record('donna', 'invoice', 'in_fzotest0001', 'test', 49700, 'CAD', 'Answer setup')::text$q$), 4))::jsonb;
  v_req := (j ->> 'invoice')::uuid;
  if j ->> 'status' is distinct from 'draft' or (select office_id::text || '|' || currency from fz_office_os.fz_office_invoices where id = v_req) <> 'f0000000-0000-4000-8000-000000000002|cad' then raise exception 'O14 draft %', j; end if;
  if pg_temp.svc(format('select public.office_os_invoice_claim_send(%L)::text', v_req)) not like 'ERR:refused: invoice in_fzotest0001 has no owner send approval%' then raise exception 'O14 a draft was sent'; end if;
  j := (substr(pg_temp.svc(format('select public.office_os_invoice_request_send(%L)::text', v_req)), 4))::jsonb;
  if j ->> 'status' is distinct from 'send_requested' or not exists (select 1 from public.fz_approval_queue where source_id = (j ->> 'approval')::uuid and action = 'client_invoice_send' and amount_cents = 49700) then raise exception 'O14 send request %', j; end if;
  -- the service key approving the queue item does not count; the bot cannot decide; a wrong amount is refused
  update public.approval_requests set status = 'approved' where id = (j ->> 'approval')::uuid;
  if pg_temp.svc(format('select public.office_os_invoice_claim_send(%L)::text', v_req)) not like 'ERR:refused%no owner send approval%' then raise exception 'O14 a service-key approval sent the invoice'; end if;
  if pg_temp.svc(format('select public.office_os_invoice_decide(%L, 49700, true)::text', v_req)) not like 'ERR:owner approval required%' then raise exception 'O14 the bot decided'; end if;
  if pg_temp.noowner(format('select public.office_os_invoice_decide(%L, 49700, true)::text', v_req)) not like 'ERR:owner approval required%' then raise exception 'O14 no-owner decided'; end if;
  if pg_temp.owner(format('select public.office_os_invoice_decide(%L, 99700, true)::text', v_req)) not like 'ERR:refused: amount does not match%' then raise exception 'O14 wrong amount approved'; end if;
  if pg_temp.svc($q$update fz_office_os.fz_office_invoices set status = 'approved'$q$) not like 'ERR:permission denied%' then raise exception 'O14 the bot wrote the invoice table'; end if;
  perform public.office_os_invoice_decide(v_req, 49700, true);
  j := (substr(pg_temp.svc(format('select public.office_os_invoice_claim_send(%L)::text', v_req)), 4))::jsonb;
  if j ->> 'stripe_id' is distinct from 'in_fzotest0001' then raise exception 'O14 claim %', j; end if;
  if pg_temp.svc(format('select public.office_os_invoice_claim_send(%L)::text', v_req)) not like 'ERR:refused%status sending%' then raise exception 'O14 claimed twice'; end if;
  if pg_temp.svc(format('select public.office_os_invoice_mark_sent(%L, true)::text', v_req)) not like 'OK:%sent%' then raise exception 'O14 mark sent'; end if;
  if (select status from fz_office_os.fz_office_invoices where id = v_req) is distinct from 'sent' then raise exception 'O14 not sent'; end if;
  -- a payment link is recorded but never sent by the bot; a deactivated office cannot send an approved invoice
  j := (substr(pg_temp.svc($q$select public.office_os_invoice_record('donna', 'payment_link', 'plink_fzotest0004', 'test', 79700, 'cad', 'Capture')::text$q$), 4))::jsonb;
  if pg_temp.svc(format('select public.office_os_invoice_request_send(%L)::text', j ->> 'invoice')) not like 'ERR:refused: a payment link is never sent%' then raise exception 'O14 a payment link was sent'; end if;
  v_req2 := ((substr(pg_temp.svc($q$select public.office_os_invoice_record('donna', 'invoice', 'in_fzotest0005', 'test', 14900, 'cad', 'Site support')::text$q$), 4))::jsonb ->> 'invoice')::uuid;
  perform pg_temp.svc(format('select public.office_os_invoice_request_send(%L)::text', v_req2));
  perform public.office_os_invoice_decide(v_req2, 14900, true);
  perform public.office_os_deactivate('donna');
  if pg_temp.svc(format('select public.office_os_invoice_claim_send(%L)::text', v_req2)) not like 'ERR:refused: donna is not active%' then raise exception 'O14 a dormant office sent'; end if;
  if jsonb_array_length((substr(pg_temp.svc('select public.office_os_invoices(10)::text'), 4))::jsonb) <> 3 then raise exception 'O14 list'; end if;
  if pg_temp.as_id('anon', null, 'select public.office_os_invoices(10)::text') not like 'ERR:permission denied%' then raise exception 'O14 anon lists invoices'; end if;
  if (select count(*) from public.ledger) <> n0 then raise exception 'O14 invoicing wrote a ledger row'; end if;
  if exists (select 1 from pg_proc where proname ~* '(refund|payout|transfer)' and proname like 'office\_os%') then raise exception 'O14 a refund / payout function exists'; end if;

  -- O15 billing plans: approved once, then that plan's period invoice is auto-approved; a larger amount, another interval, a second one in the period or a revoked plan: refused
  if pg_temp.svc($q$select public.office_os_plan_propose('donna', 'Fzo Plumbing', 'cus_fzotest01', 49700, 'cad', 'month')::text$q$) not like 'ERR:refused: donna is not active%' then raise exception 'O15 dormant office proposed a plan'; end if;
  j := public.office_os_activate('donna'); perform public.office_os_decide('donna', j ->> 'nonce', true); perform public.office_os_activate('donna');
  j := (substr(pg_temp.svc($q$select public.office_os_plan_propose('donna', 'Fzo Plumbing', 'cus_fzotest01', 49700, 'cad', 'month')::text$q$), 4))::jsonb;
  v_req := (j ->> 'plan')::uuid;
  if pg_temp.svc(format($q$select public.office_os_invoice_record_plan(%L, 'in_fzoplan0001', 'test', 49700, 'cad', 'month')::text$q$, v_req)) not like 'ERR:refused: plan is proposed%' then raise exception 'O15 an unapproved plan billed'; end if;
  if pg_temp.svc(format('select public.office_os_plan_decide(%L, 49700, %L, true)::text', v_req, 'month')) not like 'ERR:owner approval required%' then raise exception 'O15 the bot approved a plan'; end if;
  if pg_temp.owner(format('select public.office_os_plan_decide(%L, 49700, %L, true)::text', v_req, 'year')) not like 'ERR:refused: amount or interval does not match%' then raise exception 'O15 decided a different interval'; end if;
  if pg_temp.owner(format('select public.office_os_plan_decide(%L, 99700, %L, true)::text', v_req, 'month')) not like 'ERR:refused: amount or interval does not match%' then raise exception 'O15 decided a different amount'; end if;
  perform public.office_os_plan_decide(v_req, 49700, 'month', true);
  if pg_temp.svc(format($q$select public.office_os_invoice_record_plan(%L, 'in_fzoplan0002', 'test', 49800, 'cad', 'month')::text$q$, v_req)) not like 'ERR:refused: amount differs from the approved plan%' then raise exception 'O15 an amount above the plan was accepted'; end if;
  if pg_temp.svc(format($q$select public.office_os_invoice_record_plan(%L, 'in_fzoplan0003', 'test', 49700, 'usd', 'month')::text$q$, v_req)) not like 'ERR:refused: amount differs%' then raise exception 'O15 another currency was accepted'; end if;
  if pg_temp.svc(format($q$select public.office_os_invoice_record_plan(%L, 'in_fzoplan0009', 'test', 49600, 'cad', 'month')::text$q$, v_req)) not like 'ERR:refused: amount differs%' then raise exception 'O15 a lower amount was accepted (exact plan amount only)'; end if;
  if pg_temp.svc(format($q$select public.office_os_invoice_record_plan(%L, 'in_fzoplan0004', 'test', 49700, 'cad', 'year')::text$q$, v_req)) not like 'ERR:refused: interval differs%' then raise exception 'O15 a changed interval was accepted'; end if;
  j := (substr(pg_temp.svc(format($q$select public.office_os_invoice_record_plan(%L, 'in_fzoplan0005', 'test', 49700, 'cad', 'month')::text$q$, v_req)), 4))::jsonb;
  if j ->> 'status' is distinct from 'approved' or j ->> 'period' !~ '^\d{4}-\d{2}$' then raise exception 'O15 plan invoice %', j; end if;
  if pg_temp.svc(format($q$select public.office_os_invoice_record_plan(%L, 'in_fzoplan0006', 'test', 49700, 'cad', 'month')::text$q$, v_req)) not like 'ERR:refused: plan already invoiced%' then raise exception 'O15 billed twice in one period'; end if;
  -- the auto-approved invoice can be claimed, until the plan is revoked
  v_req2 := (j ->> 'invoice')::uuid;
  perform public.office_os_plan_revoke(v_req);
  if pg_temp.svc(format('select public.office_os_invoice_claim_send(%L)::text', v_req2)) not like 'ERR:refused: the billing plan of invoice in_fzoplan0005 is no longer approved%' then raise exception 'O15 a revoked plan still sends'; end if;
  if pg_temp.svc(format($q$select public.office_os_invoice_record_plan(%L, 'in_fzoplan0007', 'test', 49700, 'cad', 'month')::text$q$, v_req)) not like 'ERR:refused: plan is revoked%' then raise exception 'O15 a revoked plan billed'; end if;
  if pg_temp.as_id('anon', null, format('select public.office_os_plan_revoke(%L)::text', v_req)) not like 'ERR:permission denied%' then raise exception 'O15 anon revokes'; end if;
  -- a fresh plan: the auto invoice claims once
  j := (substr(pg_temp.svc($q$select public.office_os_plan_propose('donna', 'Fzo Electric', 'cus_fzotest02', 79700, 'cad', 'month')::text$q$), 4))::jsonb;
  perform public.office_os_plan_decide((j ->> 'plan')::uuid, 79700, 'month', true);
  j := (substr(pg_temp.svc(format($q$select public.office_os_invoice_record_plan(%L, 'in_fzoplan0008', 'test', 79700, 'cad', 'month')::text$q$, j ->> 'plan')), 4))::jsonb;
  if pg_temp.svc(format('select public.office_os_invoice_claim_send(%L)::text', j ->> 'invoice')) not like 'OK:%in_fzoplan0008%' then raise exception 'O15 an approved plan invoice cannot be sent'; end if;
  if jsonb_array_length((substr(pg_temp.svc('select public.office_os_plans()::text'), 4))::jsonb) <> 2 then raise exception 'O15 plans list'; end if;
  perform public.office_os_deactivate('donna');

  -- O12 nothing outside M7 changed shape: the profile table is not in public, not registered, nothing unregistered / unclassified
  if exists (select 1 from public.fz_unregistered_tables()) then raise exception 'O12 unregistered table'; end if;
  if public.backup_export_policy() -> 'unclassified' <> '[]'::jsonb then raise exception 'O12 unclassified'; end if;
  raise notice 'office_os_check: all checks passed';
end $$;
rollback;
