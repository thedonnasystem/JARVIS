-- SQL-level checks for migrations/20261115_inbox_needs_you_v1.sql (unified Needs-you inbox). Run against a SCRATCH replica database only:
--   psql "$REPLICA_URL" -v ON_ERROR_STOP=1 -f sqltests/inbox_needs_you_check.sql      (scripts/replica/run.sh runs every sqltests/*.sql)
-- One transaction, rolled back. Any failed assertion raises. Rows are seeded with a unique tag so leftovers from other tests cannot interfere.
begin;
do $$
declare r jsonb; ids text[]; e jsonb; msg_a1 uuid; msg_a2 uuid; msg_q uuid; msg_stale uuid; msg_dec uuid; msg_esc uuid; esc_pending uuid; esc_free uuid;
        ar_live uuid; ar_dead uuid; mis uuid; pay uuid; t_ok uuid; t_credit uuid; t_old uuid; t_mis uuid; n int; kinds text[]; denied boolean; ob_done uuid; ob_live uuid;
begin
  delete from owner_messages; delete from escalations; delete from payment_instructions; delete from approval_requests;
  update tasks set status = 'cancelled' where status = 'blocked'; update missions set status = 'paused' where status = 'blocked';

  grant usage on schema public to anon, authenticated;   -- as on Supabase; without it every call below would fail on the schema, not on the function
  -- who may call it ---------------------------------------------------------------------------------------------------------------
  if has_function_privilege('anon', 'public.needs_you(int)', 'execute') then raise exception 'T1 anon can execute needs_you'; end if;
  if has_function_privilege('anon', 'public.app_needs_you()', 'execute') then raise exception 'T2 anon can execute app_needs_you'; end if;
  if has_function_privilege('authenticated', 'public.needs_you(int)', 'execute') then raise exception 'T3 signed-in users can bypass the owner check via needs_you'; end if;
  if not has_function_privilege('service_role', 'public.needs_you(int)', 'execute') then raise exception 'T4 the bot (service role) cannot call needs_you'; end if;
  if exists (select 1 from aclexplode(coalesce((select proacl from pg_proc where oid = 'public.needs_you(int)'::regprocedure), acldefault('f', 10))) a where a.grantee = 0 and a.privilege_type = 'EXECUTE') then
    raise exception 'T5 PUBLIC can execute needs_you'; end if;
  set local role anon;
  begin perform public.needs_you(5); denied := false; exception when insufficient_privilege then denied := true; end;
  if not denied then raise exception 'T6 anon call returned data'; end if;
  begin perform public.app_needs_you(); denied := false; exception when insufficient_privilege then denied := true; end;
  if not denied then raise exception 'T7 anon app call returned data'; end if;
  reset role;
  -- a signed-in stranger (not in app_owners) is refused whether or not the function is opened to authenticated
  set local role authenticated;
  begin perform public.app_needs_you(); denied := false; exception when insufficient_privilege then denied := true; end;
  if not denied then raise exception 'T8 non-owner call returned data'; end if;
  reset role;

  -- the owner check itself, with the function temporarily opened to signed-in users (this is exactly what the sign-off change does; rolled back below)
  insert into auth.users (id, email) values ('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'inbox-owner@example.com'), ('bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb', 'inbox-stranger@example.com');
  insert into app_owners (email) values ('inbox-owner@example.com');
  grant execute on function public.app_needs_you() to authenticated;
  set local role authenticated;
  perform set_config('app.uid', 'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb', true); perform set_config('app.email', 'inbox-stranger@example.com', true);
  begin perform public.app_needs_you(); denied := false; exception when insufficient_privilege then denied := true; end;
  if not denied then raise exception 'T8b a signed-in non-owner got the inbox'; end if;
  perform set_config('app.uid', 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', true); perform set_config('app.email', 'inbox-owner@example.com', true);
  if jsonb_typeof(public.app_needs_you()) <> 'array' then raise exception 'T8c owner did not get the inbox'; end if;
  begin perform public.needs_you(5); denied := false; exception when insufficient_privilege then denied := true; end;
  if not denied then raise exception 'T8d the owner can call the internal needs_you directly'; end if;
  reset role;
  revoke execute on function public.app_needs_you() from authenticated;

  -- seed: one of every kind ---------------------------------------------------------------------------------------------------------
  insert into approval_requests (actor, action, cents, recommendation, status, expires_at) values ('jarvis', 'inbox-live', 0, 'rec live', 'pending', now() + interval '10 hours') returning id into ar_live;
  insert into approval_requests (actor, action, cents, recommendation, status, expires_at) values ('jarvis', 'inbox-dead', 0, 'rec dead', 'expired', now() - interval '1 hour') returning id into ar_dead;
  insert into owner_messages (from_agent, kind, body, needs_decision, created_at) values ('jarvis', 'proposal', 'INBOX-A1 old plain approval', true, now() - interval '30 hours') returning id into msg_a1;
  insert into owner_messages (from_agent, kind, body, needs_decision, ref_table, ref_id) values ('jarvis', 'proposal', 'INBOX-A2 red action expiring', true, 'approval_requests', ar_live) returning id into msg_a2;
  insert into owner_messages (from_agent, kind, body, needs_decision, ref_table, ref_id) values ('jarvis', 'proposal', 'INBOX-STALE expired request', true, 'approval_requests', ar_dead) returning id into msg_stale;
  insert into owner_messages (from_agent, kind, body, needs_decision, decision, decided_at) values ('jarvis', 'proposal', 'INBOX-DECIDED already decided', true, 'approved', now()) returning id into msg_dec;
  insert into owner_messages (from_agent, kind, body, options, created_at) values ('jarvis', 'proposal', E'INBOX-Q which way?\nlong text', '["Go left","Go right"]'::jsonb, now() - interval '72 hours') returning id into msg_q;
  insert into owner_messages (from_agent, kind, body) values ('jarvis', 'emergency', 'INBOX-E on fire');
  insert into owner_messages (from_agent, kind, body, created_at) values ('jarvis', 'health', 'ALERT: INBOX-H heartbeat stale', now() - interval '2 hours'), ('jarvis', 'health', 'ALERT: INBOX-H heartbeat stale', now() - interval '1 hour');
  insert into owner_messages (from_agent, kind, body, created_at) values ('jarvis', 'health', 'ALERT: INBOX-OLDALERT', now() - interval '3 days');
  insert into missions (title, objective) values ('Mission: INBOX-M stuck', 'objective long enough here') returning id into mis;
  update missions set status = 'evaluated' where id = mis; update missions set status = 'planned' where id = mis; update missions set status = 'executing' where id = mis;
  update missions set status = 'blocked', next_action = 'Blocked: step failed' where id = mis;
  insert into escalations (from_agent, kind, summary, status) values ('jarvis', 'uncertain', 'INBOX-ES free escalation', 'sent_to_owner') returning id into esc_free;
  insert into escalations (from_agent, kind, summary, status) values ('jarvis', 'uncertain', 'INBOX-ES2 escalation that has buttons', 'sent_to_owner') returning id into esc_pending;
  insert into owner_messages (from_agent, kind, body, needs_decision, created_at) values ('jarvis', 'proposal', 'INBOX-TIE-NEW same score, newer', true, now() - interval '1 hour'), ('jarvis', 'proposal', 'INBOX-TIE-OLD same score, older', true, now() - interval '2 hours');
  insert into owner_messages (from_agent, kind, body, needs_decision, ref_table, ref_id) values ('jarvis', 'proposal', 'INBOX-A3 escalation buttons', true, 'escalations', esc_pending) returning id into msg_esc;
  insert into payment_instructions (payee, amount_cents, purpose, status, requested_by) values ('INBOX-PAYEE', 1500, 'inbox test purpose', 'approved', 'jarvis') returning id into pay;
  insert into tasks (title, status, result) values ('INBOX-T blocked task', 'blocked', 'error: boom') returning id into t_ok;
  insert into tasks (title, status, result) values ('INBOX-T-CREDIT', 'blocked', 'credit balance is too low') returning id into t_credit;
  insert into tasks (title, status, result, updated_at) values ('INBOX-T-OLD', 'blocked', 'old', now() - interval '5 days') returning id into t_old;
  insert into tasks (title, status, result, mission_id) values ('INBOX-T-MISSION', 'blocked', 'in a mission', mis) returning id into t_mis;

  -- approval messages whose referenced row is gone or no longer pending are hidden (random ref_id, an outbox row already approved, an account already created)
  insert into owner_messages (from_agent, kind, body, needs_decision, ref_table, ref_id) values ('jarvis', 'proposal', 'INBOX-GHOST-OUTBOX missing row', true, 'outbox', gen_random_uuid());
  insert into outbox (channel, body, status, created_at) values ('email', 'INBOX-OB approved already', 'approved', now() - interval '1 day') returning id into ob_done;
  insert into owner_messages (from_agent, kind, body, needs_decision, ref_table, ref_id) values ('jarvis', 'proposal', 'INBOX-GHOST-OUTBOX2 not pending', true, 'outbox', ob_done);
  insert into outbox (channel, body, status) values ('email', 'INBOX-OB draft', 'draft') returning id into ob_live;
  insert into owner_messages (from_agent, kind, body, needs_decision, ref_table, ref_id, created_at) values ('jarvis', 'proposal', 'INBOX-LIVE-OUTBOX pending draft', true, 'outbox', ob_live, now() - interval '10 minutes');
  insert into owner_messages (from_agent, kind, body, needs_decision, ref_table, ref_id) values ('jarvis', 'proposal', 'INBOX-GHOST-ACCT missing row', true, 'account_requests', gen_random_uuid());
  insert into owner_messages (from_agent, kind, body, needs_decision, ref_table) values ('jarvis', 'proposal', 'INBOX-GHOST-VENT no such venture', true, 'activate_venture:no-such-venture-xyz');
  insert into owner_messages (from_agent, kind, body, needs_decision, ref_table, created_at) values ('jarvis', 'proposal', 'INBOX-CAP set_cap has no row to check', true, 'set_cap:500', now() - interval '5 minutes');
  -- NULL payee / vendor must never give a NULL title
  alter table payment_instructions alter column payee drop not null; alter table account_requests alter column vendor drop not null;
  insert into payment_instructions (payee, amount_cents, purpose, status, requested_by) values (null, 2000, 'null payee purpose', 'approved', 'jarvis');
  insert into account_requests (vendor, purpose, status, requested_by) values (null, 'null vendor purpose', 'approved', 'jarvis');

  r := public.needs_you(200);
  if exists (select 1 from jsonb_array_elements(r) x where x->>'title' is null) then raise exception 'T24 a NULL title was produced: %', r; end if;
  if not exists (select 1 from jsonb_array_elements(r) x where x->>'title' = '$20.00 to unknown payee') then raise exception 'T25 null payee not handled'; end if;
  if not exists (select 1 from jsonb_array_elements(r) x where x->>'kind' = 'account' and x->>'title' like 'unknown vendor: null vendor%') then raise exception 'T26 null vendor not handled'; end if;
  if jsonb_typeof(r) <> 'array' then raise exception 'T9 not an array: %', r; end if;
  select array_agg(x->>'title' order by (x->>'rank')::int) into ids from jsonb_array_elements(r) x where x->>'title' like '%INBOX-%' or x->>'title' like '$15.00 to INBOX%';

  -- present exactly once, in this order (scores: A2 105 incl. expiry, E 100, A1 82 incl. age, A3 and the two TIE rows 80 (equal scores: oldest first), payment 75, question 65+6 for 72h of age (so it outranks the fresh health alert at 70), mission 60, escalation 55, task 30)
  if ids is distinct from array[
       'INBOX-A2 red action expiring', 'INBOX-E on fire', 'INBOX-A1 old plain approval', 'INBOX-TIE-OLD same score, older', 'INBOX-TIE-NEW same score, newer', 'INBOX-LIVE-OUTBOX pending draft', 'INBOX-CAP set_cap has no row to check', 'INBOX-A3 escalation buttons', '$15.00 to INBOX-PAYEE',
       'INBOX-Q which way?', 'INBOX-H heartbeat stale', 'To unknown: INBOX-OB approved already', 'INBOX-M stuck', 'INBOX-ES free escalation', 'INBOX-T blocked task']
  then raise exception 'T10 wrong list/order: %', ids; end if;

  -- ranks are 1..n without gaps, sorted by score desc
  select count(*) into n from jsonb_array_elements(r) x; if (select max((x->>'rank')::int) from jsonb_array_elements(r) x) <> n then raise exception 'T11 rank gap'; end if;
  if exists (select 1 from jsonb_array_elements(r) a join jsonb_array_elements(r) b on (a->>'rank')::int + 1 = (b->>'rank')::int where (a->>'score')::int < (b->>'score')::int) then raise exception 'T12 not sorted by score'; end if;

  -- exact actions
  select x into e from jsonb_array_elements(r) x where x->>'title' like 'INBOX-A1%';
  if e->>'action' <> 'approve_or_reject' or e->>'ref_id' <> msg_a1::text or jsonb_array_length(e->'actions') <> 2
     or e#>>'{actions,0,kind}' <> 'decision' or (e#>>'{actions,0,payload,approved}')::boolean is not true or e#>>'{actions,0,payload,msg_id}' <> msg_a1::text
     or (e#>>'{actions,1,payload,approved}')::boolean is not false then raise exception 'T13 approval actions wrong: %', e; end if;
  select x into e from jsonb_array_elements(r) x where x->>'title' like 'INBOX-Q%';
  if e->>'title' like '%long text%' then raise exception 'T14 title is not the first line'; end if;
  if e->>'action' <> 'answer' or jsonb_array_length(e->'actions') <> 2 or e#>>'{actions,1,label}' <> 'Go right' or e#>>'{actions,1,kind}' <> 'answer'
     or (e#>>'{actions,1,payload,idx}')::int <> 1 or e#>>'{actions,1,payload,msg_id}' <> msg_q::text then raise exception 'T15 answer actions wrong: %', e; end if;
  select x into e from jsonb_array_elements(r) x where x->>'title' like 'INBOX-M%';
  if e->>'title' like 'Mission:%' or e->>'action' <> 'resume_or_abandon' or e#>>'{actions,0,kind}' <> 'mission' or e#>>'{actions,0,payload,verb}' <> 'resume'
     or e#>>'{actions,0,payload,id}' <> mis::text or e->>'command' <> '/mission retry ' || left(mis::text, 8) then raise exception 'T16 mission actions wrong: %', e; end if;
  select x into e from jsonb_array_elements(r) x where x->>'title' like '$15.00 to INBOX-PAYEE';
  if e->>'action' <> 'pay' or jsonb_array_length(e->'actions') <> 0 or e->>'command' not like '/pay done %' then raise exception 'T17 payment wrong: %', e; end if;
  select x into e from jsonb_array_elements(r) x where x->>'title' like 'INBOX-A2%';
  if e->>'expires_at' is null or (e->>'score')::int < 105 then raise exception 'T18 expiry bump missing: %', e; end if;

  -- dropped on purpose
  if exists (select 1 from jsonb_array_elements(r) x where x->>'title' in ('INBOX-STALE expired request', 'INBOX-DECIDED already decided', 'INBOX-ES2 escalation that has buttons',
        'INBOX-T-CREDIT', 'INBOX-T-OLD', 'INBOX-T-MISSION', 'INBOX-OLDALERT heartbeat') or x->>'title' like 'INBOX-OLDALERT%') then raise exception 'T19 something that should be hidden is listed: %', r; end if;
  -- an expired request that has no message appears as 'expiring' only while pending
  insert into approval_requests (actor, action, cents, recommendation, status, expires_at) values ('jarvis', 'inbox-solo', 0, 'solo rec', 'pending', now() + interval '30 hours');
  select count(*) into n from jsonb_array_elements(public.needs_you(200)) x where x->>'kind' = 'expiring' and x->>'title' like 'inbox-solo%';
  if n <> 1 then raise exception 'T20 expiring item missing (%).', n; end if;

  -- the limit applies and is clamped
  if jsonb_array_length(public.needs_you(3)) <> 3 then raise exception 'T21 limit ignored'; end if;
  if jsonb_array_length(public.needs_you(0)) <> 1 or jsonb_array_length(public.needs_you(null)) < 10 then raise exception 'T22 limit clamp wrong'; end if;
  -- read-only: running it changed nothing
  select count(*) into n from owner_messages where decision is not null and body like 'INBOX-%'; if n <> 1 then raise exception 'T23 inbox mutated decisions'; end if;
  raise notice 'inbox_needs_you checks passed';
end $$;
select 'inbox_needs_you_ok';
rollback;
