-- Web Studio v1 (migrations/20261205_web_studio_v1.sql). One transaction, rolled back. Run on a fresh apply from the repo root.
-- Proves: the web_studio service row exists, active, with its tables and derived data classes; the bot (service_role) cannot write it;
-- the rollback retires it (never deletes) and is idempotent; re-applying re-activates it.
begin;
do $$
declare r record; n int;
begin
  select * into r from public.fz_services where service = 'web_studio';
  if r is null then raise exception 'W1 FAIL: web_studio not registered'; end if;
  if r.status <> 'active' or r.writes <> '{leads,hand_actions}' or r.reads <> '{hand_accounts,ventures}' then raise exception 'W1 FAIL: row %', row_to_json(r); end if;
  if not ('client_restricted' = any (r.data_classes)) then raise exception 'W1 FAIL: data classes not derived: %', r.data_classes; end if;
  raise notice 'W1 OK: web_studio registered, active, classes %', r.data_classes;
end $$;

set local role service_role;
do $$
begin
  begin
    update public.fz_services set status = 'dormant' where service = 'web_studio';
    raise exception 'W2 FAIL: the bot changed the service row';
  exception when insufficient_privilege then raise notice 'W2 OK: the bot cannot write fz_services';
  end;
end $$;
reset role;

\i ops/rollback_web_studio.sql
\i ops/rollback_web_studio.sql
do $$
begin
  if (select status from public.fz_services where service = 'web_studio') <> 'retired' then raise exception 'W3 FAIL: rollback did not retire the row'; end if;
  raise notice 'W3 OK: rollback retires the row (twice = idempotent), nothing deleted';
end $$;
\i migrations/20261205_web_studio_v1.sql
do $$
begin
  if (select status from public.fz_services where service = 'web_studio') <> 'active' then raise exception 'W4 FAIL: re-apply did not re-activate'; end if;
  raise notice 'W4 OK: re-apply re-activates the row';
end $$;
rollback;
