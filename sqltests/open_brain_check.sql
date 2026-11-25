-- Open brain (migrations/20261204_open_brain_v1.sql). ONE transaction, rolled back.
-- Proves: both owner switches default OFF; only the owner / a database session can turn them on (never the service key, never a scoped role, not
-- even through a direct table write); open_brain_routing() reports them; every change is audited; the money controls are identical with the migration,
-- after its rollback (twice) and after a re-apply; the rollback keeps the record and leaves nothing behind.
begin;
grant usage on schema public to anon, authenticated, service_role;
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
\set fz_in_txn 1
create temp table ob_fp_with as select * from pg_temp.fz_money_fp();
do $$
declare r jsonb; res text; n int;
begin
  -- B1 defaults off, reported by the bot's read function
  r := public.open_brain_routing();
  if r <> '{"owner_chat_free_providers": false, "allow_training_providers_nonprivate": false}'::jsonb then raise exception 'B1 defaults: %', r; end if;
  if pg_temp.svc('select public.open_brain_routing()::text') not like 'OK:%' then raise exception 'B1 the bot cannot read the routing switches'; end if;
  -- B2 the service key cannot switch anything on (function or direct write, even with RLS bypassed and a mistaken grant)
  if pg_temp.svc('select public.open_brain_set_owner_chat_free(true)::text') not like 'ERR:%owner approval required%' then raise exception 'B2 bot set owner chat'; end if;
  if pg_temp.svc('select public.open_brain_set_training_nonprivate(true)::text') not like 'ERR:%owner approval required%' then raise exception 'B2 bot set training'; end if;
  alter role service_role bypassrls; grant update on public.fz_brain_config to service_role;
  if pg_temp.svc('update public.fz_brain_config set owner_chat_free_providers = true returning 1') not like 'ERR:%owner approval required%' then raise exception 'B2 direct write'; end if;
  revoke update on public.fz_brain_config from service_role; alter role service_role nobypassrls;
  if exists (select 1 from pg_proc p where p.proname like 'open\_brain%' and (has_function_privilege('anon', p.oid, 'execute') or has_function_privilege('authenticated', p.oid, 'execute'))) then
    raise exception 'B2 anon / authenticated can call an open-brain function'; end if;
  if exists (select 1 from pg_roles where rolname = 'fz_jarvis') and exists (select 1 from pg_proc p where p.proname like 'open\_brain%' and has_function_privilege('fz_jarvis', p.oid, 'execute')) then
    raise exception 'B2 a scoped role can call an open-brain function'; end if;
  -- B3 the owner (database session) switches them, audited
  n := (select count(*) from public.audit_log where action like 'open_brain_%');
  r := public.open_brain_set_owner_chat_free(true);
  if not (r ->> 'owner_chat_free_providers')::boolean or (r ->> 'allow_training_providers_nonprivate')::boolean then raise exception 'B3 owner chat switch: %', r; end if;
  r := public.open_brain_set_training_nonprivate(true);
  if not (r ->> 'allow_training_providers_nonprivate')::boolean then raise exception 'B3 training switch: %', r; end if;
  if (select count(*) from public.audit_log where action like 'open_brain_%') <> n + 2 then raise exception 'B3 switch changes not audited'; end if;
  perform public.open_brain_set_owner_chat_free(false); perform public.open_brain_set_training_nonprivate(false);
end $$;
-- B4 rollback (twice) and re-apply: money controls identical, record kept, nothing left
select public.open_brain_set_owner_chat_free(true);
\ir ../ops/rollback_open_brain.sql
\ir ../ops/rollback_open_brain.sql
create temp table ob_fp_without as select * from pg_temp.fz_money_fp();
do $$
begin
  if exists (select 1 from pg_proc where proname like 'open\_brain%') or exists (select 1 from information_schema.columns where table_name = 'fz_brain_config'
             and column_name in ('owner_chat_free_providers', 'allow_training_providers_nonprivate')) then raise exception 'B4 the rollback left objects behind'; end if;
  if not exists (select 1 from public.audit_log where action = 'open_brain_export' and (detail ->> 'owner_chat_free_providers')::boolean) then raise exception 'B4 record not kept'; end if;
  if exists (select 1 from ob_fp_with w full join ob_fp_without o using (k) where w.v is distinct from o.v) then raise exception 'B4 the money controls differ with and without'; end if;
end $$;
\ir ../migrations/20261204_open_brain_v1.sql
create temp table ob_fp_again as select * from pg_temp.fz_money_fp();
do $$
begin
  if exists (select 1 from ob_fp_again w full join ob_fp_without o using (k) where w.v is distinct from o.v) then raise exception 'B4 applying changed the money controls'; end if;
  if public.open_brain_routing() <> '{"owner_chat_free_providers": false, "allow_training_providers_nonprivate": false}'::jsonb then raise exception 'B4 re-apply is not off'; end if;
  raise notice 'open_brain_check: all checks passed';
end $$;
rollback;
