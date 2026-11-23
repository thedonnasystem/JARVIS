-- Linked memory + free-provider quota (migrations/20261205_linked_memory_v1.sql). ONE transaction, rolled back.
-- Proves: no API role holds any privilege on the fz_memory schema or its tables; anon / authenticated / the scoped fz roles cannot run the functions
-- (by grant, and in the body even after a mistaken grant); the bot (service key) can; office isolation (an office sees only its own rows; another office
-- cannot read, update or retract them; an agent is pinned to its own office; a cross-office link is impossible by foreign key); client rows only for the
-- office's own self-hosted path and never for the group; the class never goes down on an update; dedupe (exact and near), update keeps history, retract,
-- forget (soft, audited with ids only); entity links; quota counters (hourly slot reuse, bad values refused); the money controls are identical with the
-- migration, after its rollback (twice) and after a re-apply; the rollback keeps every row and a re-apply restores them.
begin;
grant usage on schema public to anon, authenticated, service_role;
create function pg_temp.as_role(p_role text, p_sql text) returns text language plpgsql as $$
declare r text;
begin
  execute format('set local role %I', p_role);
  begin execute p_sql into r; exception when others then reset role; return 'ERR:' || sqlerrm; end;
  reset role;
  return 'OK:' || coalesce(r, '');
end $$;
\ir include/money_fingerprint.sql
\set fz_in_txn 1
create temp table lm_fp_with as select * from pg_temp.fz_money_fp();
insert into public.agents (slug, title, office_id) values ('lm-donna-agent', 'LM test agent', 'f0000000-0000-4000-8000-000000000002') on conflict (slug) do nothing;
do $$
declare r jsonb; res text; n int; v1 text := '[1,0,0,0,0,0,0,0]'; v2 text := '[0,1,0,0,0,0,0,0]'; v3 text := '[0,0,1,0,0,0,0,0]'; m_donna uuid; m_client uuid; m_new uuid;
        rl text;
begin
  -- L1 no API privilege on the schema or the tables
  foreach rl in array array['anon', 'authenticated', 'service_role', 'fz_jarvis', 'fz_office_agent', 'fz_auditor', 'backup_reader'] loop
    continue when not exists (select 1 from pg_roles where rolname = rl);
    if has_schema_privilege(rl, 'fz_memory', 'usage') then raise exception 'L1 % has usage on fz_memory', rl; end if;
    if exists (select 1 from pg_class c where c.relnamespace = 'fz_memory'::regnamespace and c.relkind in ('r', 'S')
               and (has_table_privilege(rl, c.oid, 'select') or has_table_privilege(rl, c.oid, 'insert') or has_table_privilege(rl, c.oid, 'update'))) then
      raise exception 'L1 % holds a table privilege in fz_memory', rl; end if;
    if rl not in ('service_role') and exists (select 1 from pg_proc p where p.pronamespace = 'public'::regnamespace and p.proname ~ '^(jmem_|jquota_)'
               and has_function_privilege(rl, p.oid, 'execute')) then raise exception 'L1 % can execute a linked-memory function', rl; end if;
  end loop;
  if not exists (select 1 from pg_class c where c.relnamespace = 'fz_memory'::regnamespace and c.relkind = 'r' and c.relrowsecurity having count(*) = 6) then
    raise exception 'L1 row level security is not on for all six tables'; end if;

  -- L2 the bot can; a signed-in app user cannot, even with a mistaken grant (the body refuses)
  res := pg_temp.as_role('service_role', 'select public.jmem_stats()::text');
  if res not like 'OK:%' then raise exception 'L2 the bot cannot call jmem_stats: %', res; end if;
  grant execute on function public.jmem_search(text, text, real[], text, integer, text, text), public.jmem_apply(text, jsonb, text, text, text) to authenticated;
  if pg_temp.as_role('authenticated', $q$select count(*)::text from public.jmem_search('group', 'x')$q$) not like 'ERR:%bot and database sessions only%' then
    raise exception 'L2 authenticated read memory'; end if;
  if pg_temp.as_role('authenticated', $q$select public.jmem_apply('group', '[]')::text$q$) not like 'ERR:%bot and database sessions only%' then
    raise exception 'L2 authenticated wrote memory'; end if;
  revoke execute on function public.jmem_search(text, text, real[], text, integer, text, text), public.jmem_apply(text, jsonb, text, text, text) from authenticated;

  -- L3 office isolation
  r := public.jmem_apply('donna', format('[{"op":"add","content":"Donna targets HVAC contractors in Ottawa","kind":"decision","data_class":"owner","importance":0.9,"embedding":%s,
         "entities":[{"name":"Donna","kind":"office"},{"name":"HVAC","kind":"project"}],"relations":[["Donna","targets","HVAC"]]}]', v1)::jsonb, 'sqltest', 'test-v1');
  if (r ->> 'added')::int <> 1 then raise exception 'L3 add: %', r; end if;
  select id into m_donna from fz_memory.memories where content like 'Donna targets%';
  if exists (select 1 from public.jmem_search('wolf-squad', 'Donna HVAC contractors', translate(v1, '[]', '{}')::real[], 'test-v1', 10)) then raise exception 'L3 another office read donna'; end if;
  if not exists (select 1 from public.jmem_search('donna', 'HVAC contractors', translate(v1, '[]', '{}')::real[], 'test-v1', 10) s where s.id = m_donna) then raise exception 'L3 own office cannot read'; end if;
  if not exists (select 1 from public.jmem_search('group', 'HVAC contractors', null, null, 10) s where s.id = m_donna and s.office = 'donna') then raise exception 'L3 group cannot read an office owner fact'; end if;
  r := public.jmem_apply('wolf-squad', format('[{"op":"update","id":"%s","content":"hijacked","kind":"fact","data_class":"owner","embedding":%s},{"op":"retract","id":"%s"}]', m_donna, v2, m_donna)::jsonb, 'sqltest', 'test-v1');
  if (r ->> 'skipped')::int <> 2 or (select status from fz_memory.memories where id = m_donna) <> 'active' then raise exception 'L3 another office changed donna: %', r; end if;
  if not exists (select 1 from public.jmem_search(null, 'HVAC contractors', null, null, 10, 'external', 'lm-donna-agent') s where s.id = m_donna) then raise exception 'L3 agent office not derived'; end if;
  begin
    perform public.jmem_search('wolf-squad', 'x', null, null, 5, 'external', 'lm-donna-agent');
    raise exception 'L3 an agent reached another office';
  exception when sqlstate '42501' then null; end;
  begin
    perform public.jmem_search('nowhere', 'x');
    raise exception 'L3 unknown office accepted';
  exception when sqlstate '22023' then null; end;
  begin
    insert into fz_memory.entities (office_id, kind, name, norm) values ('f0000000-0000-4000-8000-000000000004', 'person', 'Wolf', 'wolf');
    insert into fz_memory.memory_entities (office_id, memory_id, entity_id)
      select 'f0000000-0000-4000-8000-000000000004', m_donna, e.id from fz_memory.entities e where e.norm = 'wolf';
    raise exception 'L3 a cross-office link was stored';
  exception when foreign_key_violation then null; end;

  -- L4 client rows: own office + self-hosted only; never the group; class never goes down
  r := public.jmem_apply('donna', format('[{"op":"add","content":"Client Jane Roe 613-555-0199 wants a furnace quote","kind":"person","data_class":"client","embedding":%s}]', v3)::jsonb, 'sqltest', 'test-v1');
  select id into m_client from fz_memory.memories where content like 'Client Jane%';
  if exists (select 1 from public.jmem_search('donna', 'Jane furnace quote', translate(v3, '[]', '{}')::real[], 'test-v1', 10) s where s.id = m_client) then raise exception 'L4 client row for an external destination'; end if;
  if not exists (select 1 from public.jmem_search('donna', 'Jane furnace quote', translate(v3, '[]', '{}')::real[], 'test-v1', 10, 'selfhost') s where s.id = m_client) then raise exception 'L4 own self-hosted path cannot read client row'; end if;
  if exists (select 1 from public.jmem_search('group', 'Jane furnace quote', translate(v3, '[]', '{}')::real[], 'test-v1', 10, 'selfhost') s where s.data_class = 'client') then raise exception 'L4 group got client data'; end if;
  if exists (select 1 from public.jmem_search('wolf-squad', 'Jane furnace quote', translate(v3, '[]', '{}')::real[], 'test-v1', 10, 'selfhost')) then raise exception 'L4 another office got client data'; end if;
  if exists (select 1 from public.jmem_list('donna') l where l.id = m_client and l.content <> '[client data: hidden]') then raise exception 'L4 list shows client content'; end if;
  r := public.jmem_apply('donna', format('[{"op":"update","id":"%s","content":"Jane Roe wants a furnace quote next week","kind":"person","data_class":"owner","embedding":%s}]', m_client, v3)::jsonb, 'sqltest', 'test-v1');
  if (select data_class from fz_memory.memories where supersedes = m_client) <> 'client' then raise exception 'L4 class went down on update'; end if;
  r := public.jmem_apply('donna', format('[{"op":"add","content":"no class given","kind":"fact","embedding":%s}]', '[0,0,0,1,0,0,0,0]')::jsonb, 'sqltest', 'test-v1');
  if (select data_class from fz_memory.memories where content = 'no class given') <> 'client' then raise exception 'L4 a missing class is not client'; end if;

  -- L5 dedupe, update with history, retract, forget
  r := public.jmem_apply('donna', format('[{"op":"add","content":"  donna TARGETS hvac contractors in ottawa! ","kind":"decision","data_class":"owner","embedding":%s},
                                            {"op":"add","content":"Donna is aiming at Ottawa HVAC contractors","kind":"decision","data_class":"owner","embedding":%s}]', v2, v1)::jsonb, 'sqltest', 'test-v1');
  if (r ->> 'deduped')::int <> 2 or (select seen_count from fz_memory.memories where id = m_donna) <> 3 then raise exception 'L5 dedupe: % / %', r, (select seen_count from fz_memory.memories where id = m_donna); end if;
  r := public.jmem_apply('donna', format('[{"op":"update","id":"%s","content":"Donna targets HVAC and plumbing contractors in Ottawa","kind":"decision","data_class":"owner","importance":1,"embedding":%s}]',
                                         m_donna, '[0.6,0.8,0,0,0,0,0,0]')::jsonb, 'sqltest', 'test-v1');
  select id into m_new from fz_memory.memories where supersedes = m_donna;
  if m_new is null or (select status || '/' || superseded_by::text from fz_memory.memories where id = m_donna) <> 'superseded/' || m_new::text then raise exception 'L5 update history'; end if;
  if exists (select 1 from fz_memory.relations where memory_id = m_donna and status = 'active') then raise exception 'L5 old relations still live'; end if;
  r := public.jmem_apply('donna', format('[{"op":"retract","id":"%s"}]', m_new)::jsonb, 'sqltest', 'test-v1');
  if (select status from fz_memory.memories where id = m_new) <> 'retracted' then raise exception 'L5 retract'; end if;
  r := public.jmem_apply('donna', format('[{"op":"add","content":"Moe runs Donna with Sam","kind":"fact","data_class":"owner","embedding":%s,"entities":[{"name":"Sam","kind":"person"}],
                                            "relations":[["Moe","runs","Donna"],["Sam","works_at","Donna"]]}]', '[0,0,0,0,1,0,0,0]')::jsonb, 'sqltest', 'test-v1');
  if not exists (select 1 from public.jmem_links('donna', 'sam') l where l.rel = 'works_at' and l.dst = 'Donna') then raise exception 'L6 links'; end if;
  n := (select count(*) from public.audit_log where action = 'memory_forget');
  begin perform public.jmem_forget('donna', '12'); raise exception 'L5 short id accepted'; exception when sqlstate '22023' then null; end;
  r := public.jmem_forget('donna', null, 'Sam');
  if (r ->> 'forgotten')::int <> 1 or exists (select 1 from public.jmem_search('donna', 'Moe runs Donna with Sam', null, null, 10) s where s.content like 'Moe runs%') then raise exception 'L5 forget by entity: %', r; end if;
  if (select count(*) from public.audit_log where action = 'memory_forget') <> n + 1
     or exists (select 1 from public.audit_log where action = 'memory_forget' and detail::text like '%Moe runs%') then raise exception 'L5 forget audit'; end if;
  if (select count(*) from fz_memory.memories where office_id = 'f0000000-0000-4000-8000-000000000002') < 6 then raise exception 'L5 history rows were removed'; end if;

  -- L7 quota counters
  perform public.jquota_record('lmtest-p', 3, 900, now() + interval '2 minutes', 1);
  perform public.jquota_record('lmtest-p', 2, 100, null, 0);
  r := public.jquota_load();
  if (select (h ->> 'requests')::int from jsonb_array_elements(r -> 'hours') h where h ->> 'provider' = 'lmtest-p') <> 5 or (r -> 'state' -> 'lmtest-p' ->> 'fails')::int <> 0 then raise exception 'L7 load: %', r; end if;
  update fz_memory.provider_quota set hour = hour - interval '1 day' where provider = 'lmtest-p';   -- the slot is from yesterday: restarted, not added to
  perform public.jquota_record('lmtest-p', 1, 10, null, 0);
  if (select requests from fz_memory.provider_quota where provider = 'lmtest-p') <> 1 then raise exception 'L7 slot reuse'; end if;
  begin perform public.jquota_record('Bad Name', 1, 1); raise exception 'L7 bad provider accepted'; exception when sqlstate '22023' then null; end;
  begin perform public.jquota_record('lmtest-p', -1, 1); raise exception 'L7 negative accepted'; exception when sqlstate '22023' then null; end;
  if pg_temp.as_role('service_role', $q$select public.jquota_load()::text$q$) not like 'OK:%' then raise exception 'L7 the bot cannot load quota'; end if;
end $$;
-- L8 rollback (twice) and re-apply: money controls identical, rows kept and restored
\ir ../ops/rollback_linked_memory.sql
\ir ../ops/rollback_linked_memory.sql
create temp table lm_fp_without as select * from pg_temp.fz_money_fp();
do $$
begin
  if exists (select 1 from pg_proc where pronamespace = 'public'::regnamespace and proname ~ '^(jmem_|jquota_)') or to_regnamespace('fz_memory') is not null then
    raise exception 'L8 the rollback left functions or the live schema behind'; end if;
  if (select count(*) from fz_memory_archive.memories) < 6 then raise exception 'L8 the rollback lost memories'; end if;
  if exists (select 1 from lm_fp_with w full join lm_fp_without o using (k) where w.v is distinct from o.v) then raise exception 'L8 the money controls differ with and without'; end if;
end $$;
\ir ../migrations/20261205_linked_memory_v1.sql
create temp table lm_fp_again as select * from pg_temp.fz_money_fp();
do $$
begin
  if exists (select 1 from lm_fp_again w full join lm_fp_without o using (k) where w.v is distinct from o.v) then raise exception 'L8 applying changed the money controls'; end if;
  if to_regnamespace('fz_memory_archive') is not null or (select count(*) from fz_memory.memories) < 6 then raise exception 'L8 re-apply did not restore the memories'; end if;
  raise notice 'linked_memory_check: all checks passed';
end $$;
rollback;
