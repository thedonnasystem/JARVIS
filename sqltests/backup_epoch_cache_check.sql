-- Owner directive B (redaction-source epoch) and C (redaction cache ffm_redaction_found). SCRATCH replica only; one transaction, rolled back.
begin;
\ir include/legacy_spec.sql
do $$
declare
  v uuid; e0 jsonb; e1 jsonb; r text; n int; run1 uuid; run2 uuid; res jsonb; sres text; paged jsonb; ag text; src record; ok boolean; i int;
begin
  select id into v from public.ventures order by slug limit 1;
  select slug into ag from public.agents order by slug limit 1;
  grant usage on schema public to service_role;

  -- ============================================================ B. epoch: every source write changes the vector
  for src in select distinct table_name from public.redaction_sources() where to_regclass('public.' || table_name) is not null loop
    if (select count(*) from pg_trigger t where t.tgrelid = ('public.' || src.table_name)::regclass and t.tgname = 'redaction_epoch' and not t.tgisinternal) <> 1
       or (select count(*) from pg_trigger t where t.tgrelid = ('public.' || src.table_name)::regclass and t.tgname = 'redaction_epoch_trunc' and not t.tgisinternal) <> 1 then
      raise exception 'B1 source table % has no epoch triggers (insert/update/delete + truncate)', src.table_name; end if;
  end loop;
  if not exists (select 1 from pg_trigger where tgrelid = 'public.ffm_redaction_denylist'::regclass and tgname = 'redaction_epoch') then raise exception 'B2 the deny-list has no epoch trigger'; end if;
  e0 := public.backup_epoch();
  insert into public.leads (venture_id, name, email, phone, status) values (v, 'Epoch Fixturename', 'epoch-1@example.test', '613-555-0366', 'new');
  e1 := public.backup_epoch(); if e1 = e0 then raise exception 'B3 inserting a lead did not change the epoch'; end if;
  e0 := e1; update public.leads set name = 'Epoch Renamed' where email = 'epoch-1@example.test';
  e1 := public.backup_epoch(); if e1 = e0 then raise exception 'B4 renaming a lead did not change the epoch'; end if;
  e0 := e1; update public.leads set name = '[erased]', email = null, phone = null where name = 'Epoch Renamed';
  e1 := public.backup_epoch(); if e1 = e0 then raise exception 'B5 erasing a lead did not change the epoch'; end if;
  e0 := e1; delete from public.leads where name = '[erased]' and phone is null;
  e1 := public.backup_epoch(); if e1 = e0 then raise exception 'B6 deleting a lead did not change the epoch'; end if;
  e0 := e1; perform public.redaction_capture('n', 'Epochdeny Fixture');
  e1 := public.backup_epoch(); if e1 = e0 or (e1 ->> 'denylist_rows') = (e0 ->> 'denylist_rows') then raise exception 'B7 a deny-list entry did not change the epoch / row count'; end if;
  e0 := e1; insert into public.contact_suppressions (address, reason, recorded_by) values ('epoch-sup@example.test', 'unsubscribe', 'test');
  e1 := public.backup_epoch(); if e1 = e0 then raise exception 'B8 a suppression did not change the epoch'; end if;
  e0 := e1; truncate public.setter_events;
  e1 := public.backup_epoch(); if e1 = e0 then raise exception 'B9 a truncate did not change the epoch'; end if;
  e0 := e1; set local session_replication_role = replica; insert into public.leads (venture_id, name, status) values (v, 'Epoch Bypass', 'new'); set local session_replication_role = origin;
  e1 := public.backup_epoch(); if e1 = e0 then raise exception 'B10 a trigger-bypassing write changed no count'; end if;
  e0 := public.backup_epoch(); if public.backup_epoch() <> e0 then raise exception 'B11 the epoch changes without a write'; end if;

  -- owner-only: no API role can read or write the epoch / cache tables, none is exported, the trigger function cannot be called
  if has_sequence_privilege('service_role', 'public.ffm_redaction_epoch_seq', 'usage,select,update') or has_sequence_privilege('anon', 'public.ffm_redaction_epoch_seq', 'usage,select,update') or has_sequence_privilege('authenticated', 'public.ffm_redaction_epoch_seq', 'usage,select,update') then raise exception 'B12a an API role has a privilege on the epoch sequence'; end if;
  foreach r in array array['ffm_redaction_found', 'ffm_redaction_denylist', 'ffm_redaction_keys'] loop
    if has_table_privilege('service_role', 'public.' || r, 'select,insert,update,delete,truncate') or has_table_privilege('anon', 'public.' || r, 'select,insert,update,delete')
       or has_table_privilege('authenticated', 'public.' || r, 'select,insert,update,delete') then raise exception 'B12 an API role has a privilege on %', r; end if;
    if (public.backup_export_policy() -> 'exported') ? r then raise exception 'B13 % is in the export policy', r; end if;
  end loop;
  set local role service_role;
  begin perform nextval('public.ffm_redaction_epoch_seq'); reset role; raise exception 'B14 service_role can move the epoch sequence'; exception when others then reset role; if sqlerrm like 'B14%' then raise; end if; end;
  set local role service_role;
  begin perform public.redaction_epoch_bump(); reset role; raise exception 'B15 the bump trigger function is callable'; exception when others then reset role; if sqlerrm like 'B15%' then raise; end if; end;
  set local role service_role;
  begin e1 := public.backup_epoch(); reset role; exception when others then reset role; raise exception 'B16 service_role cannot read the epoch vector (the backup needs it): %', sqlerrm; end;
  if (select relpersistence from pg_class where oid = 'public.ffm_redaction_found'::regclass) <> 'u' then raise exception 'C0 the cache table is not UNLOGGED'; end if;

  -- ============================================================ C. run-specific cache
  insert into public.leads (venture_id, name, phone, status) values (v, 'Cachelynn Wexcombe', '613-555-0377', 'new');
  delete from public.leads where name = 'Cachelynn Wexcombe';
  set local session_replication_role = replica;
  insert into public.tasks (assigned_agent, title, detail, status, result, created_by) values (ag, 'zzc cache', 'x', 'done', 'call cachelynn about it', 'owner');
  set local session_replication_role = origin;
  delete from public.ffm_redaction_found;
  run1 := (public.backup_deny_prepare() ->> 'run')::uuid; run2 := (public.backup_deny_prepare() ->> 'run')::uuid;
  if run1 = run2 or (select count(*) from public.ffm_redaction_found) <> 2 then raise exception 'C1 two concurrent runs must have two rows and different ids'; end if;
  -- release deletes only the caller's own run
  set local role service_role;
  begin res := public.backup_deny_release(run1); exception when others then res := jsonb_build_object('err', sqlerrm); end;
  reset role;
  if (select count(*) from public.ffm_redaction_found) <> 2 then raise exception 'C2 another caller released a run it does not own: %', res; end if;
  perform public.backup_deny_release(run1);
  if (select count(*) from public.ffm_redaction_found where run = run1) <> 0 or (select count(*) from public.ffm_redaction_found where run = run2) <> 1 then raise exception 'C3 release did not delete exactly its own run'; end if;
  perform public.backup_deny_release(gen_random_uuid());       -- a forged / unknown id deletes nothing
  if (select count(*) from public.ffm_redaction_found where run = run2) <> 1 then raise exception 'C4 a forged run id deleted another run'; end if;
  perform public.backup_deny_release(null);
  if (select count(*) from public.ffm_redaction_found where run = run2) <> 1 then raise exception 'C5 a null release deleted a live run'; end if;

  -- the cache is used by its own caller, never by another caller, never when expired, never when forged: those rescan (a missing cache can only make it slower)
  sres := (select x ->> 'result' from jsonb_array_elements(public.backup_snapshot() -> 'data' -> 'tasks') x where x ->> 'title' = 'zzc cache');
  if sres like '%cachelynn%' then raise exception 'C6 control: the single statement did not redact the deleted name: %', sres; end if;
  update public.ffm_redaction_found set found = jsonb_build_object('names', '[]'::jsonb, 'chains', '[]'::jsonb, 'emails', '[]'::jsonb, 'phones', '[]'::jsonb) where run = run2;      -- a stale / empty cached result
  paged := public.backup_snapshot_page('tasks', (select count(*)::int from public.tasks where id < (select id from public.tasks where title = 'zzc cache')), 1, run2);
  if paged -> 'rows' -> 0 ->> 'result' not like '%cachelynn%' then raise exception 'C7 control: the owner caller did not use its own cached result (the test cannot tell cache from rescan)'; end if;
  set local role service_role;
  paged := public.backup_snapshot_page('tasks', (select count(*)::int from public.tasks where id < (select id from public.tasks where title = 'zzc cache')), 1, run2);
  reset role;
  if paged -> 'rows' -> 0 ->> 'result' like '%cachelynn%' then raise exception 'C8 a run id belonging to another caller was used: %', paged -> 'rows' -> 0 ->> 'result'; end if;
  paged := public.backup_snapshot_page('tasks', (select count(*)::int from public.tasks where id < (select id from public.tasks where title = 'zzc cache')), 1, gen_random_uuid());
  if paged -> 'rows' -> 0 ->> 'result' like '%cachelynn%' then raise exception 'C9 a forged run id skipped the scan'; end if;
  update public.ffm_redaction_found set at = now() - interval '21 minutes' where run = run2;
  paged := public.backup_snapshot_page('tasks', (select count(*)::int from public.tasks where id < (select id from public.tasks where title = 'zzc cache')), 1, run2);
  if paged -> 'rows' -> 0 ->> 'result' like '%cachelynn%' then raise exception 'C10 an expired run id skipped the scan'; end if;
  -- expiry and crash recovery: the next prepare / release purges every expired row
  perform public.backup_deny_release(null);
  if exists (select 1 from public.ffm_redaction_found where run = run2) then raise exception 'C11 an expired row survived a release'; end if;
  insert into public.ffm_redaction_found (run, caller, found, at) values (gen_random_uuid(), 'crashed|run|', '{}'::jsonb, now() - interval '3 hours');
  perform public.backup_deny_prepare();
  if exists (select 1 from public.ffm_redaction_found where at < now() - interval '20 minutes') then raise exception 'C12 a crashed run row survived the next prepare'; end if;
  -- run ids come from the database's random source, unique per run
  select count(distinct (public.backup_deny_prepare() ->> 'run')) into n from generate_series(1, 20);
  if n <> 20 then raise exception 'C13 run ids repeat'; end if;
  raise notice 'EPOCH / CACHE CHECKS PASSED';
end $$;
rollback;
select 'backup_epoch_cache_check_ok';
