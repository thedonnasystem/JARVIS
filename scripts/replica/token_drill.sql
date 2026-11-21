-- Token rotation / revocation drill (ops/TOKEN_ROTATION_RUNBOOK.md), run by scripts/replica/run.sh. ONE transaction, rolled back. Each step is the runbook's exact owner
-- statement; the claims are what PostgREST would set from a minted token.
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
insert into auth.users (id, email) values ('99999999-9999-9999-9999-99999999f005', 'fzt-owner@example.invalid') on conflict do nothing;
insert into public.app_owners (email) values ('fzt-owner@example.invalid') on conflict do nothing;
select set_config('app.uid', '99999999-9999-9999-9999-99999999f005', true);
do $$
declare I text := 'office:b2b-records:manager'; t1 jsonb; t2 jsonb; t3 jsonb; t4 jsonb; ok text := 'select (public.fz_whoami() ->> ''ok'')';
begin
  perform public.fz_owner_set_office_status('b2b-records', 'active');
  perform public.fz_owner_set_identity(I, 'active');
  t1 := pg_temp.cl(I, 'fz_office_agent', '{"jti": "rot-1"}');
  if pg_temp.as_id('fz_office_agent', t1, ok) <> 'OK:true' then raise exception 'D1 a fresh token does not work'; end if;
  -- step 1 (runbook "Rotate"): mint a new token, pin its jti -> the old token stops at once, the new one works
  perform public.fz_owner_set_identity(I, 'active', 'rot-2');
  t2 := pg_temp.cl(I, 'fz_office_agent', '{"jti": "rot-2"}');
  if pg_temp.as_id('fz_office_agent', t1, ok) <> 'OK:false' then raise exception 'D2 the old token still works after rotation'; end if;
  if pg_temp.as_id('fz_office_agent', t2, ok) <> 'OK:true' then raise exception 'D2 the new token does not work'; end if;
  -- step 2 (runbook "Void everything issued so far"): tokens issued before now are refused, a token issued after works
  perform public.fz_owner_set_identity(I, 'active', null, true);
  if pg_temp.as_id('fz_office_agent', t2, ok) <> 'OK:false' then raise exception 'D3 a voided token still works'; end if;
  t3 := pg_temp.cl(I, 'fz_office_agent', jsonb_build_object('jti', 'rot-2', 'iat', floor(extract(epoch from now())) + 2));
  if pg_temp.as_id('fz_office_agent', t3, ok) <> 'OK:true' then raise exception 'D3 a token issued after the void does not work'; end if;
  -- step 3 (runbook "Leak"): Jarvis / the bot revokes at once; the identity reads nothing; the bot can never re-activate it
  if pg_temp.svc(format($q$select public.fz_revoke_identity(%L, 'drill: token leaked')::text$q$, I)) not like 'OK:%revoked%' then raise exception 'D4 the bot cannot revoke'; end if;
  if pg_temp.as_id('fz_office_agent', t3, 'select count(*)::text from public.tasks') <> 'OK:0' then raise exception 'D4 a revoked identity still reads'; end if;
  if pg_temp.svc(format($q$select public.fz_owner_set_identity(%L, 'active')::text$q$, I)) not like 'ERR:owner approval required%' then raise exception 'D4 the bot re-activated'; end if;
  -- step 4: the owner re-activates with a NEW jti and voids the leaked ones; register its expiry so /security warns before it lapses
  perform public.fz_owner_set_identity(I, 'active', 'rot-3', true);
  t4 := pg_temp.cl(I, 'fz_office_agent', jsonb_build_object('jti', 'rot-3', 'iat', floor(extract(epoch from now())) + 2));
  if pg_temp.as_id('fz_office_agent', t3, ok) <> 'OK:false' or pg_temp.as_id('fz_office_agent', t4, ok) <> 'OK:true' then raise exception 'D5 re-activation'; end if;
  perform public.fz_owner_register_token(I, 'rot-3', now() + interval '5 days', 'drill');
  if not exists (select 1 from jsonb_array_elements(public.fz_security_report() -> 'tokens_expiring') e where e ->> 'identity' = I) then raise exception 'D5 expiry not reported'; end if;
  -- every step is in the audit log
  if (select count(*) from public.audit_log where action in ('identity_status', 'identity_revoked', 'token_registered') and target = 'fz_identities/' || I) < 5 then raise exception 'D6 steps not audited'; end if;
  raise notice 'token rotation drill OK';
end $$;
rollback;
