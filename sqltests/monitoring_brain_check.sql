-- Monitoring + shared brain M6 (migrations/20261202_monitoring_brain_v1.sql). ONE transaction, rolled back. Fresh apply, repo root.
-- Proves: money controls unchanged (with / without / re-applied M6); the rollback archives everything and restores the M3 queue + M5 classification; the health report
-- covers every check and writes nothing; alerts are OFF by default, and when on fire only on a status change, once (dedupe), never from the service key; the brain is
-- read only through fz_brain_read (group facts + the caller's own office, nothing else), is append-only with supersede, and an office fact reaches the group only
-- redacted, through an M3 queue item decided by the owner (Jarvis only if the owner allowed it, never its own request); scoped roles get nothing new.
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
insert into auth.users (id, email) values ('99999999-9999-9999-9999-99999999f006', 'fzh-owner@example.invalid') on conflict do nothing;
insert into public.app_owners (email) values ('fzh-owner@example.invalid') on conflict do nothing;
select set_config('app.uid', '99999999-9999-9999-9999-99999999f006', true);

-- H1 money controls unchanged: with M6 == after its rollback (twice) == after re-applying it; nothing left behind; data archived and restored
\set fz_in_txn 1
create temp table fzh_fp_with as select * from pg_temp.fz_money_fp();
create temp table fzh_ex0 as select count(*) n from public.audit_log where action = 'monitoring_brain_export';
create temp table fzh_q0 as select md5(pg_get_viewdef('public.fz_approval_queue'::regclass)) h;
select public.fz_brain_add('policy', 'net terms are thirty days', 'owner', 0.5);
select public.fz_owner_set_brain_jarvis_approval(true);
\ir ../ops/rollback_monitoring_brain.sql
\ir ../ops/rollback_monitoring_brain.sql
create temp table fzh_fp_without as select * from pg_temp.fz_money_fp();
do $$
begin
  if to_regclass('public.fz_brain_facts') is not null or to_regclass('public.fz_health_alerts') is not null
     or exists (select 1 from pg_proc where pronamespace = 'public'::regnamespace and (proname like 'fz\_brain%' or proname like 'fz\_health%' or proname like 'fz\_m6%'))
     or exists (select 1 from cron.job where jobname = 'fz-health-check') then raise exception 'H1 the rollback left M6 objects behind'; end if;
  if to_regclass('fz_archive.fz_brain_facts') is null or not exists (select 1 from fz_archive.fz_brain_facts where fact = 'net terms are thirty days') then raise exception 'H1 facts not archived'; end if;
  if pg_get_viewdef('public.fz_approval_queue'::regclass) like '%brain%' then raise exception 'H1 the M3 queue was not restored'; end if;
  if exists (select 1 from public.backup_classification() where table_name like 'fz\_brain%' or table_name like 'fz\_health%') then raise exception 'H1 classification not restored to M5'; end if;
  if (select prosrc from pg_proc where oid = 'public.fz_service_stamp_office()'::regprocedure) like '%fz_m6_owner_session%' then raise exception 'H1 the M5 office stamp was not restored'; end if;
  if public.backup_export_policy() -> 'unclassified' <> '[]'::jsonb then raise exception 'H1 unclassified after the rollback'; end if;
  if (select count(*) from public.audit_log where action = 'monitoring_brain_export') <> (select n from fzh_ex0) + 1 then raise exception 'H1 export record missing or doubled'; end if;
  if to_regclass('public.fz_services') is null or to_regclass('public.fz_audit_chain') is null then raise exception 'H1 the rollback damaged M5 / M4'; end if;
  if exists (select 1 from fzh_fp_with w full join fzh_fp_without o using (k) where w.v is distinct from o.v) then raise exception 'H1 the money controls differ with and without M6'; end if;
end $$;
\ir ../migrations/20261202_monitoring_brain_v1.sql
create temp table fzh_fp_again as select * from pg_temp.fz_money_fp();
do $$
begin
  if exists (select 1 from fzh_fp_again w full join fzh_fp_without o using (k) where w.v is distinct from o.v) then raise exception 'H1 applying M6 changed the money controls'; end if;
  if not exists (select 1 from public.fz_brain_facts where fact = 'net terms are thirty days' and office_id is null) then raise exception 'H1 the archived facts did not come back'; end if;
  if not (select jarvis_may_approve from public.fz_brain_config) then raise exception 'H1 the owner setting was lost across rollback + re-apply'; end if;
  if md5(pg_get_viewdef('public.fz_approval_queue'::regclass)) <> (select h from fzh_q0) then raise exception 'H1 the re-applied queue view differs'; end if;
  perform public.fz_owner_set_brain_jarvis_approval(false);
end $$;

do $$
declare A uuid := 'f0000000-0000-4000-8000-000000000001'; B uuid := 'f0000000-0000-4000-8000-000000000002'; G uuid := 'f0000000-0000-4000-8000-000000000000';
        r jsonb; r2 jsonb; res text; ca jsonb; cb jsonb; cj jsonb; fa uuid; fa2 uuid; fb uuid; fg uuid; p uuid; p2 uuid; n int; n2 int; h text;
begin
  -- H2 health report: every check present, statuses valid, read-only; scoped roles refused
  n := (select count(*) from public.audit_log); n2 := (select count(*) from public.owner_messages);
  h := (select md5(coalesce(string_agg(to_jsonb(x)::text, ',' order by x.check_key), '')) from public.fz_health_state x);
  r := public.fz_health_report();
  if (select string_agg(c ->> 'check', ',' order by c ->> 'check') from jsonb_array_elements(r -> 'checks') c)
     <> 'ai_cap_day,approval_backlog,audit_chain,failed_jobs,job_backlog,kill_switch,security,spend_week' then raise exception 'H2 checks: %', r; end if;
  if exists (select 1 from jsonb_array_elements(r -> 'checks') c where c ->> 'status' not in ('ok', 'warn', 'bad')) or r ->> 'overall' not in ('ok', 'warn', 'bad') then raise exception 'H2 status'; end if;
  if (select count(*) from public.audit_log) <> n or (select count(*) from public.owner_messages) <> n2 or (select md5(coalesce(string_agg(to_jsonb(x)::text, ',' order by x.check_key), '')) from public.fz_health_state x) <> h then raise exception 'H2 the report wrote'; end if;
  -- (in-transaction only) the alert checks below start from no recorded state and no earlier alerts (a replica drill may have left some)
  delete from public.fz_health_state;
  alter table public.fz_health_alerts disable trigger fz_health_alerts_append_only; delete from public.fz_health_alerts; alter table public.fz_health_alerts enable trigger fz_health_alerts_append_only;
  if (r ->> 'alerts_enabled')::boolean then raise exception 'H2 alerts must default OFF'; end if;
  -- the kill switch is reflected (read only; the test flips it in-transaction)
  update public.system_state set kill_switch = true where id = 1;
  if (select c ->> 'status' from jsonb_array_elements(public.fz_health_report() -> 'checks') c where c ->> 'check' = 'kill_switch') <> 'warn' then raise exception 'H2 kill switch not reported'; end if;
  update public.system_state set kill_switch = false where id = 1;
  -- a dead job shows up
  insert into public.jarvis_jobs (division, kind, status, finished_at) values ('research', 'fzh_dead', 'dead', now());
  if (select (c ->> 'dead_24h')::int from jsonb_array_elements(public.fz_health_report() -> 'checks') c where c ->> 'check' = 'failed_jobs') < 1 then raise exception 'H2 dead jobs not reported'; end if;
  ca := pg_temp.cl('jarvis', 'fz_jarvis');
  if pg_temp.as_id('fz_jarvis', ca, 'select public.fz_health_report()::text') not like 'ERR:permission denied%' then raise exception 'H2 a scoped role reads the health report'; end if;

  -- H3 alerts: OFF = nothing; the service key can neither run the check nor switch alerts; ON = one alert per status change, deduped, no repeat while unchanged
  if (public.fz_health_check() ->> 'enabled')::boolean or exists (select 1 from public.fz_health_alerts) then raise exception 'H3 alerts fired while off'; end if;
  if pg_temp.svc('select public.fz_health_check()::text') not like 'ERR:%scheduler or the owner%' then raise exception 'H3 the service key ran the check'; end if;
  if pg_temp.svc('select public.fz_owner_set_health_alerts(true)::text') not like 'ERR:%owner approval required%' then raise exception 'H3 the service key switched alerts on'; end if;
  alter role service_role bypassrls;
  grant update on public.fz_health_config to service_role;
  if pg_temp.svc('update public.fz_health_config set alerts_enabled = true returning 1') not like 'ERR:%owner approval required%' then raise exception 'H3 the bot flipped the flag (guard)'; end if;
  revoke update on public.fz_health_config from service_role;
  alter role service_role nobypassrls;
  perform public.fz_owner_set_health_alerts(true);
  n2 := (select count(*) from public.owner_messages where kind = 'health');
  r := public.fz_health_check();
  n := (select count(*) from public.fz_health_alerts);
  if n <> (select count(*) from jsonb_array_elements(public.fz_health_report() -> 'checks') c where c ->> 'status' <> 'ok') then raise exception 'H3 first run must alert exactly the non-ok checks: % %', n, r; end if;
  if n > 0 and (select count(*) from public.owner_messages where kind = 'health') <> n2 + 1 then raise exception 'H3 one Telegram message per run with changes'; end if;
  r := public.fz_health_check();
  if (r ->> 'alerts_sent')::int <> 0 or (select count(*) from public.fz_health_alerts) <> n then raise exception 'H3 an unchanged status alerted again: %', r; end if;
  update public.system_state set kill_switch = true where id = 1;
  r := public.fz_health_check();
  if (r ->> 'alerts_sent')::int <> 1 or not exists (select 1 from public.fz_health_alerts where check_key = 'kill_switch' and status = 'warn') then raise exception 'H3 a change was not alerted: %', r; end if;
  if (public.fz_health_check() ->> 'alerts_sent')::int <> 0 then raise exception 'H3 repeat'; end if;
  -- a replayed transition (state rolled back to the previous status, e.g. a lost update or a re-run) must not alert twice: the dedupe key is stable
  update public.fz_health_state set status = 'ok', generation = generation - 1 where check_key = 'kill_switch';
  if (public.fz_health_check() ->> 'alerts_sent')::int <> 0 then raise exception 'H3/dedupe a replayed transition alerted again'; end if;
  update public.system_state set kill_switch = false where id = 1;
  if (public.fz_health_check() ->> 'alerts_sent')::int <> 1 then raise exception 'H3 the recovery was not alerted'; end if;
  update public.system_state set kill_switch = true where id = 1;
  if (public.fz_health_check() ->> 'alerts_sent')::int <> 1 then raise exception 'H3 the second flip must alert again (new generation)'; end if;
  update public.system_state set kill_switch = false where id = 1;
  if exists (select dedupe_key from public.fz_health_alerts group by 1 having count(*) > 1) then raise exception 'H3 duplicate dedupe keys'; end if;
  begin delete from public.fz_health_alerts; raise exception 'H3 alerts deleted'; exception when others then if sqlerrm like 'H3%' then raise; end if; end;
  perform public.fz_owner_set_health_alerts(false);

  -- H8 (M5 review #6) the office stamp ignores a caller-given office unless the caller is the owner / a database session
  alter role service_role bypassrls; grant insert on public.venture_assets to service_role;
  res := pg_temp.svc(format('insert into public.venture_assets (kind, name, office_id) values (%L, %L, %L) returning office_id', 'asset', 'bot says office B', B));
  if res <> 'OK:' || G then raise exception 'H8 the service key chose the office of a row: %', res; end if;
  revoke insert on public.venture_assets from service_role; alter role service_role nobypassrls;
  insert into public.venture_assets (kind, name, office_id) values ('asset', 'owner says office B', B) returning office_id into fb;
  if fb <> B then raise exception 'H8 the owner session may still choose the office'; end if;
  fb := null;

  -- H4 brain: group facts + own office only; nothing else; no direct table access
  perform public.fz_owner_set_office_status('b2b-records', 'active'); perform public.fz_owner_set_identity('office:b2b-records:manager', 'active');
  perform public.fz_owner_set_office_status('donna', 'active');       perform public.fz_owner_set_identity('office:donna:manager', 'active');
  ca := pg_temp.cl('office:b2b-records:manager', 'fz_office_agent'); cb := pg_temp.cl('office:donna:manager', 'fz_office_agent'); cj := pg_temp.cl('jarvis', 'fz_jarvis');
  -- scoped roles get NO grant on M6 (M1 allowlist unchanged); grant in-transaction only, to prove the scoping logic itself
  if pg_temp.as_id('fz_office_agent', ca, 'select public.fz_brain_read()::text') not like 'ERR:permission denied%' then raise exception 'H4 a scoped role holds an M6 grant'; end if;
  grant execute on function public.fz_brain_read(text, integer), public.fz_brain_add(text, text, text, numeric, jsonb, uuid, text, text), public.fz_brain_propose_promotion(uuid, text) to fz_office_agent, fz_jarvis;
  grant execute on function public.fz_identity_now(), public.is_group_scope(), public.current_office_id() to anon;
  res := pg_temp.as_id('fz_office_agent', ca, 'select public.fz_brain_add(''pricing'', ''Client Alice Smith at alice@example.com pays 30 days late'', ''call notes'', 0.8, ''{"kind": "note", "client_email": "alice@example.com"}'')::text');
  if res not like 'OK:%' then raise exception 'H4 office A could not add: %', res; end if;
  fa := substr(res, 4)::uuid;
  res := pg_temp.as_id('fz_office_agent', cb, 'select public.fz_brain_add(''pricing'', ''Donna office secret fact'', ''notes'', 0.6)::text');
  fb := substr(res, 4)::uuid;
  fg := public.fz_brain_add('policy', 'Group-wide fact', 'owner', 0.9);
  if (select office_id from public.fz_brain_facts where id = fa) <> A or (select created_by_office from public.fz_brain_facts where id = fa) <> A then raise exception 'H4 office A fact scope'; end if;
  if pg_temp.svc('select public.fz_brain_add(''t'', ''bot group fact'', ''s'', 0.5)::text') not like 'ERR:%group-wide facts come only from the owner%' then raise exception 'H4 the service key wrote a group fact'; end if;
  res := pg_temp.svc('select public.fz_brain_add(''t'', ''bot fact for donna'', ''s'', 0.5, ''{}'', null, ''jarvis'', ''donna'')::text');
  if res not like 'OK:%' or (select office_id from public.fz_brain_facts where id = substr(res, 4)::uuid) <> B then raise exception 'H4 the service key could not write for a named office: %', res; end if;
  if pg_temp.svc('select public.fz_brain_add(''t'', ''x'', ''s'', 0.5, ''{}'', null, ''jarvis'', ''group'')::text') not like 'ERR:%group-wide%' then raise exception 'H4 p_office group'; end if;
  res := pg_temp.as_id('fz_office_agent', ca, 'select public.fz_brain_add(''t'', ''x'', ''s'', 0.5, ''{}'', null, ''x'', ''donna'')::text');
  if res not like 'OK:%' or (select office_id from public.fz_brain_facts where id = substr(res, 4)::uuid) <> A then raise exception 'H4 a scoped caller wrote into another office: %', res; end if;
  if (select office_id from public.fz_brain_facts where id = fg) is not null then raise exception 'H4 a database-session fact must be group-wide'; end if;
  res := pg_temp.as_id('fz_office_agent', ca, 'select string_agg(x ->> ''id'', '','') from jsonb_array_elements(public.fz_brain_read(null, 50)) x');
  if res not like '%' || fa || '%' or res not like '%' || fg || '%' or res like '%' || fb || '%' then raise exception 'H4 office A read the wrong facts: %', res; end if;
  res := pg_temp.as_id('fz_office_agent', cb, 'select string_agg(x ->> ''id'', '','') from jsonb_array_elements(public.fz_brain_read(null, 50)) x');
  if res like '%' || fa || '%' or res not like '%' || fb || '%' then raise exception 'H4 office B read the wrong facts: %', res; end if;
  r := public.fz_brain_read(null, 50);                                     -- the database session / service key act for the group: group facts only
  if exists (select 1 from jsonb_array_elements(r) x where x ->> 'scope' <> 'group') then raise exception 'H4 the group read saw office facts'; end if;
  res := pg_temp.svc('select string_agg(x ->> ''scope'', '','') from jsonb_array_elements(public.fz_brain_read(null, 50)) x');
  if res like '%b2b-records%' or res like '%donna%' then raise exception 'H4 the service key read office facts: %', res; end if;
  res := pg_temp.as_id('fz_jarvis', cj, 'select count(*) from jsonb_array_elements(public.fz_brain_read(null, 50)) x where x ->> ''scope'' <> ''group''');
  if res <> 'OK:0' then raise exception 'H4 group-scope Jarvis read office facts: %', res; end if;
  if pg_temp.as_id('fz_office_agent', ca, 'select count(*) from public.fz_brain_facts') not like 'ERR:permission denied%' then raise exception 'H4 direct table read'; end if;
  if pg_temp.svc('select count(*) from public.fz_brain_facts') not like 'ERR:permission denied%' then raise exception 'H4 the service key reads the table directly'; end if;
  if pg_temp.as_id('anon', null, 'select public.fz_brain_read()::text') not like 'ERR:permission denied%' then raise exception 'H4 anon reads the brain'; end if;
  grant execute on function public.fz_brain_read(text, integer) to anon;
  if pg_temp.as_id('anon', null, 'select public.fz_brain_read()::text') not like 'ERR:%not readable by this role%' then raise exception 'H4 anon (mistakenly granted) reads the brain'; end if;
  revoke execute on function public.fz_brain_read(text, integer) from anon;
  -- search escapes LIKE wildcards
  if jsonb_array_length(public.fz_brain_read('%', 50)) <> 0 then raise exception 'H4 a wildcard query matched everything'; end if;
  if jsonb_array_length(public.fz_brain_read('Group-wide', 50)) < 1 then raise exception 'H4 search'; end if;

  -- H5 append-only + supersede
  begin update public.fz_brain_facts set fact = 'edited' where id = fg; raise exception 'H5 edited'; exception when insufficient_privilege then null; end;
  begin delete from public.fz_brain_facts where id = fg; raise exception 'H5 deleted'; exception when insufficient_privilege then null; end;
  begin truncate public.fz_brain_facts cascade; raise exception 'H5 truncated'; exception when others then if sqlerrm like 'H5%' then raise; end if; end;
  begin update public.fz_brain_facts set superseded_by = fg, fact = 'sneaky' where id = fa; raise exception 'H5 supersede + edit'; exception when insufficient_privilege then null; end;
  res := pg_temp.as_id('fz_office_agent', ca, format('select public.fz_brain_add(''pricing'', ''Net 45 now'', ''call notes'', 0.9, ''{}'', %L)::text', fa));
  if res not like 'OK:%' then raise exception 'H5 supersede failed: %', res; end if;
  fa2 := substr(res, 4)::uuid;
  if (select superseded_by from public.fz_brain_facts where id = fa) <> fa2 or (select fact from public.fz_brain_facts where id = fa) not like 'Client Alice%' then raise exception 'H5 supersede'; end if;
  res := pg_temp.as_id('fz_office_agent', ca, 'select string_agg(x ->> ''id'', '','') from jsonb_array_elements(public.fz_brain_read(null, 50)) x');
  if res like '%' || fa || '%' or res not like '%' || fa2 || '%' then raise exception 'H5 a superseded fact is still read'; end if;
  res := pg_temp.as_id('fz_office_agent', cb, format('select public.fz_brain_add(''x'', ''x'', ''x'', 0.5, ''{}'', %L)::text', fa2));
  if res not like 'ERR:%own scope%' then raise exception 'H5 office B superseded an office A fact: %', res; end if;
  begin update public.fz_brain_facts set superseded_by = fg where id = fa; raise exception 'H5 re-superseded'; exception when insufficient_privilege then null; end;

  insert into public.leads (venture_id, name, email) values ((select id from public.ventures order by created_at limit 1), 'Alice Smith', 'alice@example.com');
  -- H6 promotion: redacted, queued in M3, owner decides; Jarvis only if allowed and not its own; office B cannot propose A's fact; scoped/service cannot decide as owner
  insert into public.fz_brain_facts (office_id, topic, fact, source, confidence, provenance, created_by_office, created_by)
    values (A, 'collections', 'Call Alice Smith on 416-555-0199 or alice@example.com; she pays late', 'notes', 0.7, '{"kind": "note", "client_email": "alice@example.com", "url": "https://x.invalid/a"}', A, 'test')
    returning id into fa;
  res := pg_temp.as_id('fz_office_agent', cb, format('select public.fz_brain_propose_promotion(%L)::text', fa));
  if res not like 'ERR:%own facts%' then raise exception 'H6 office B proposed office A''s fact: %', res; end if;
  res := pg_temp.as_id('fz_office_agent', ca, format('select public.fz_brain_propose_promotion(%L, ''office:b2b-records:manager'')::text', fa));
  if res not like 'OK:%' then raise exception 'H6 propose: %', res; end if;
  p := substr(res, 4)::uuid;
  select redacted_fact into h from public.fz_brain_promotions where id = p;
  if h like '%alice@example.com%' or h like '%416-555-0199%' or h = (select fact from public.fz_brain_facts where id = fa) then raise exception 'H6 the promotion text is not redacted: %', h; end if;
  if (select redaction_level from public.fz_brain_promotions where id = p) <> 'patterns' then raise exception 'H6 a scoped caller cannot have the full redaction'; end if;
  if h like '%Alice%' or h like '%Smith%' then raise exception 'H6 a client name is in the request text: %', h; end if;   -- (outside the backup identity the redaction is the strict pattern level, often [redacted:uncertain])
  if (select redacted_provenance from public.fz_brain_promotions where id = p) ? 'client_email' then raise exception 'H6 a client field was promoted'; end if;
  if not exists (select 1 from public.fz_approval_queue where request_type = 'brain_promotion' and source_id = p and status = 'pending' and office = 'b2b-records') then raise exception 'H6 not in the M3 queue'; end if;
  res := pg_temp.as_id('fz_office_agent', cb, format('select count(*) from public.fz_approval_queue where source_id = %L', p));
  if res <> 'OK:0' then raise exception 'H6 office B sees office A''s queue item: %', res; end if;
  res := pg_temp.as_id('fz_office_agent', ca, format('select public.fz_brain_propose_promotion(%L)::text', fa));
  if res not like 'ERR:%already waiting%' then raise exception 'H6 duplicate request: %', res; end if;
  if pg_temp.svc(format('select public.fz_owner_decide_brain_promotion(%L, true)::text', p)) not like 'ERR:%owner approval required%' then raise exception 'H6 the service key decided as owner'; end if;
  if pg_temp.svc(format('select public.fz_brain_decide(%L, true, ''owner'')::text', p)) not like 'ERR:%owner approval required%' then raise exception 'H6 the inner function decided as owner'; end if;
  if pg_temp.svc(format('select public.fz_jarvis_decide_brain_promotion(%L, true)::text', p)) not like 'ERR:%owner setting off%' then raise exception 'H6 Jarvis decided with the setting off'; end if;
  if pg_temp.svc('select public.fz_owner_set_brain_jarvis_approval(true)::text') not like 'ERR:%owner approval required%' then raise exception 'H6 the service key enabled Jarvis approval'; end if;
  if exists (select 1 from public.fz_brain_facts where office_id is null and provenance ->> 'promotion' = p::text) then raise exception 'H6 promoted before approval'; end if;
  r := public.fz_owner_decide_brain_promotion(p, true);                  -- the owner session runs the full pass first (client names from the leak-redaction context)
  h := public.backup_redact_text((select fact from public.fz_brain_facts where id = fa), public.backup_redaction_context(), 2000, 'strict');
  select id into fg from public.fz_brain_facts where office_id is null and provenance ->> 'promotion' = p::text;
  if (select redaction_level from public.fz_brain_promotions where id = p) <> 'full' then raise exception 'H6 approved without the full redaction'; end if;
  if (select fact from public.fz_brain_facts where id = fg) like '%Alice%' then raise exception 'H6 a client name was promoted: %', (select fact from public.fz_brain_facts where id = fg); end if;
  if fg is null or (select fact from public.fz_brain_facts where id = fg) <> h or (select created_by_office from public.fz_brain_facts where id = fg) <> A
     or (select provenance ? 'client_email' from public.fz_brain_facts where id = fg) then raise exception 'H6 the group fact is not the redacted request: %', r; end if;
  if (select status from public.fz_brain_promotions where id = p) <> 'approved' or not exists (select 1 from public.audit_log where action = 'brain_promotion_approved' and target = 'fz_brain_promotions:' || p) then
    raise exception 'H6 decision not recorded'; end if;
  begin perform public.fz_owner_decide_brain_promotion(p, false); raise exception 'H6 decided twice'; exception when others then if sqlerrm like 'H6%' then raise; end if; end;
  begin update public.fz_brain_promotions set redacted_fact = 'x' where id = p; raise exception 'H6 edited'; exception when insufficient_privilege then null; end;
  begin update public.fz_brain_promotions set status = 'rejected', decided_by = 'x' where id = p; raise exception 'H6 a decided request was changed directly'; exception when insufficient_privilege then null; end;
  -- Jarvis: only with the owner setting, never its own request
  insert into public.fz_brain_facts (office_id, topic, fact, source, confidence, created_by_office, created_by) values (A, 't2', 'second fact', 's', 0.5, A, 'test') returning id into fa;
  p := public.fz_brain_propose_promotion(fa, 'jarvis');
  res := pg_temp.as_id('fz_office_agent', ca, format('select public.fz_brain_propose_promotion(%L, ''office:b2b-records:manager'')::text', fa2));   -- pattern-level redaction only
  p2 := substr(res, 4)::uuid;
  perform public.fz_owner_set_brain_jarvis_approval(true);
  if pg_temp.svc(format('select public.fz_jarvis_decide_brain_promotion(%L, true)::text', p2)) not like 'ERR:%full redaction pass%' then raise exception 'H6 Jarvis approved a pattern-only redaction'; end if;
  if pg_temp.svc('select public.fz_brain_redact_pending()::text') not like 'ERR:%scheduler or the owner%' then raise exception 'H6 the service key ran the redaction pass'; end if;
  if public.fz_brain_redact_pending() < 1 then raise exception 'H6 the full pass did nothing'; end if;
  if (select redaction_level from public.fz_brain_promotions where id = p2) <> 'full' then raise exception 'H6 full pass'; end if;
  begin update public.fz_brain_promotions set redaction_level = 'patterns' where id = p2; raise exception 'H6 redaction weakened'; exception when insufficient_privilege then null; end;
  if pg_temp.svc(format('select public.fz_jarvis_decide_brain_promotion(%L, true)::text', p)) not like 'ERR:%its own request%' then raise exception 'H6 Jarvis approved its own request'; end if;
  res := pg_temp.svc(format('select public.fz_jarvis_decide_brain_promotion(%L, false)::text', p2));
  if res not like 'OK:%rejected%' or (select decided_by from public.fz_brain_promotions where id = p2) <> 'jarvis' then raise exception 'H6 Jarvis (allowed) could not decide an office request: %', res; end if;
  perform public.fz_owner_set_brain_jarvis_approval(false);
  -- an expired request is never approved
  update public.fz_brain_promotions set status = status where id = p;   -- (no-op allowed)
  alter table public.fz_brain_promotions disable trigger fz_brain_promotions_guard;
  update public.fz_brain_promotions set expires_at = now() - interval '1 minute' where id = p;
  alter table public.fz_brain_promotions enable trigger fz_brain_promotions_guard;
  r := public.fz_owner_decide_brain_promotion(p, true);
  if r ->> 'status' <> 'expired' or exists (select 1 from public.fz_brain_facts where provenance ->> 'promotion' = p::text) then raise exception 'H6 an expired request was approved: %', r; end if;

  -- H7 the owner report: group facts + per-office counts only (never another office's text)
  r := public.fz_brain_report(null);
  if exists (select 1 from jsonb_array_elements(r -> 'facts') x where x ->> 'scope' <> 'group') or (r -> 'by_office' ->> 'b2b-records')::int < 1 then raise exception 'H7 report: %', r; end if;
  if pg_temp.as_id('fz_jarvis', cj, 'select public.fz_brain_report()::text') not like 'ERR:%' then raise exception 'H7 a scoped role reads the owner report'; end if;
  raise notice 'monitoring_brain_check: all checks passed';
end $$;
rollback;
