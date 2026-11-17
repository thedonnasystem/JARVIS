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
    if (select count(*) from pg_trigger t where t.tgrelid = ('public.' || src.table_name)::regclass and t.tgname = 'redaction_epoch_ins' and not t.tgisinternal) <> 1
       or (select count(*) from pg_trigger t where t.tgrelid = ('public.' || src.table_name)::regclass and t.tgname = 'redaction_epoch_upd' and not t.tgisinternal) <> 1
       or (select count(*) from pg_trigger t where t.tgrelid = ('public.' || src.table_name)::regclass and t.tgname = 'redaction_epoch_del' and not t.tgisinternal) <> 1
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

  -- ---- round 6, B2: noise writes do not move the epoch, real source changes do
  insert into public.leads (venture_id, name, email, phone, status, score) values (v, 'Noise Fixturename', 'noise-1@example.test', '613-555-0377', 'new', 1);
  e0 := public.backup_epoch();
  update public.leads set name = 'zz' where false;
  e1 := public.backup_epoch(); if e1 <> e0 then raise exception 'B20 a 0-row update moved the epoch'; end if;
  update public.leads set score = score + 1, status = 'contacted' where email = 'noise-1@example.test';
  e1 := public.backup_epoch(); if e1 <> e0 then raise exception 'B21 an update of non-source columns moved the epoch'; end if;
  update public.leads set name = name, email = email where email = 'noise-1@example.test';
  e1 := public.backup_epoch(); if e1 <> e0 then raise exception 'B22 an update that changed no source value moved the epoch'; end if;
  delete from public.leads where false;
  e1 := public.backup_epoch(); if e1 <> e0 then raise exception 'B23 a 0-row delete moved the epoch'; end if;
  update public.leads set phone = '613-555-0378' where email = 'noise-1@example.test';
  e1 := public.backup_epoch(); if e1 = e0 then raise exception 'B24 changing a source column did not move the epoch'; end if;
  e0 := e1; update public.leads set email = 'noise-2@example.test' where email = 'noise-1@example.test';
  e1 := public.backup_epoch(); if e1 = e0 then raise exception 'B25 changing the email did not move the epoch'; end if;
  e0 := e1; delete from public.leads where email = 'noise-2@example.test';
  e1 := public.backup_epoch(); if e1 = e0 then raise exception 'B26 deleting a row did not move the epoch'; end if;

  -- ---- round 7, B2b: INSERT / DELETE bump only when the set of DISTINCT source values changes (a drafted outbox email to a known address is noise), and every real change is still seen
  insert into public.outbox (agent, channel, to_ref, body, venture_id) values ('donna-ops', 'email', 'b2b-known@example.test', 'first draft', v);
  e0 := public.backup_epoch();
  insert into public.outbox (agent, channel, to_ref, body, venture_id) values ('donna-ops', 'email', 'b2b-known@example.test', 'second draft', v);
  e1 := public.backup_epoch(); if e1 <> e0 then raise exception 'B30 an outbox row to an already-known address moved the epoch'; end if;
  insert into public.outbox (agent, channel, to_ref, body, venture_id) values ('donna-ops', 'email', null, 'no recipient yet', v);
  e1 := public.backup_epoch(); if e1 <> e0 then raise exception 'B31 an outbox row with a NULL to_ref moved the epoch'; end if;
  insert into public.outbox (agent, channel, to_ref, body, venture_id) select 'donna-ops', 'email', 'b2b-known@example.test', 'batch ' || g, v from generate_series(1, 25) g;
  e1 := public.backup_epoch(); if e1 <> e0 then raise exception 'B32 a batch of outbox rows to a known address moved the epoch'; end if;
  for i in 1..20 loop insert into public.outbox (agent, channel, to_ref, body, venture_id) values ('donna-ops', 'email', 'b2b-known@example.test', 'noise ' || i, v); end loop;
  e1 := public.backup_epoch(); if e1 <> e0 then raise exception 'B33 continuous outbox noise moved the epoch'; end if;
  insert into public.leads (venture_id, name, email, phone, status) values (v, 'B2b Twin', 'b2b-twin@example.test', '613-555-0391', 'new');
  e0 := public.backup_epoch();
  insert into public.leads (venture_id, name, email, phone, status) values (v, 'B2b Twin', 'b2b-twin@example.test', '613-555-0391', 'new');
  e1 := public.backup_epoch(); if e1 <> e0 then raise exception 'B34 a second lead row with every value already known moved the epoch'; end if;
  delete from public.leads where id = (select id from public.leads where email = 'b2b-twin@example.test' order by id limit 1);
  e1 := public.backup_epoch(); if e1 <> e0 then raise exception 'B35 deleting one of two rows with the same values moved the epoch'; end if;
  delete from public.outbox where body like 'noise %';
  e1 := public.backup_epoch(); if e1 <> e0 then raise exception 'B36 deleting outbox rows whose address is still held by another row moved the epoch'; end if;
  -- the other direction: every real change is seen
  insert into public.outbox (agent, channel, to_ref, body, venture_id) values ('donna-ops', 'email', 'b2b-new@example.test', 'to a new address', v);
  e1 := public.backup_epoch(); if e1 = e0 then raise exception 'B37 an outbox row to a NEW address did not move the epoch'; end if;
  e0 := e1; insert into public.leads (venture_id, name, email, phone, status) values (v, 'B2b Twin', 'b2b-twin-2@example.test', '613-555-0391', 'new');
  e1 := public.backup_epoch(); if e1 = e0 then raise exception 'B38 a lead with a known name but a NEW email did not move the epoch'; end if;
  e0 := e1; delete from public.outbox where to_ref = 'b2b-new@example.test';
  e1 := public.backup_epoch(); if e1 = e0 then raise exception 'B39 deleting the last row that holds an address did not move the epoch'; end if;
  e0 := e1; insert into public.outbox (agent, channel, to_ref, body, venture_id) select 'donna-ops', 'email', 'b2b-bulk-' || g || '@example.test', 'bulk', v from generate_series(1, 250) g;
  e1 := public.backup_epoch(); if e1 = e0 then raise exception 'B40 a bulk insert of 250 new addresses did not move the epoch'; end if;
  e0 := e1; delete from public.outbox where body = 'bulk';
  e1 := public.backup_epoch(); if e1 = e0 then raise exception 'B41 a bulk delete did not move the epoch'; end if;
  -- a write that skips the triggers is still caught by the distinct-value digest, a duplicate-only one is not (nothing changed)
  e0 := public.backup_epoch(); set local session_replication_role = replica;
  insert into public.outbox (agent, channel, to_ref, body, venture_id) values ('donna-ops', 'email', 'b2b-known@example.test', 'bypass duplicate', v);
  e1 := public.backup_epoch(); if e1 <> e0 then set local session_replication_role = origin; raise exception 'B42 a trigger-bypassing duplicate moved the epoch'; end if;
  insert into public.outbox (agent, channel, to_ref, body, venture_id) values ('donna-ops', 'email', 'b2b-bypass@example.test', 'bypass new', v);
  set local session_replication_role = origin;
  e1 := public.backup_epoch(); if e1 = e0 then raise exception 'B43 a trigger-bypassing write of a new address was not detected'; end if;

  -- B1b (round 7): a COMMENT or an owner change of a function of the export path moves the code hash too (they are not in pg_get_functiondef)
  e0 := public.backup_epoch(); comment on function public.backup_fold_text(text) is 'epoch probe';
  e1 := public.backup_epoch(); if e1 ->> 'code' = e0 ->> 'code' then raise exception 'B44 a COMMENT on an export-path function did not change the code hash'; end if;
  comment on function public.backup_fold_text(text) is null;

  -- ---- round 6, B1: redefining ANY function of the export path (every backup_* / redaction_* function, the detector twin, the writer trigger) or changing the spec moves the epoch
  declare fr record; cnt int := 0; def text;
  begin
    for fr in select p.oid, p.oid::regprocedure::text sig from pg_proc p where p.pronamespace = 'public'::regnamespace and p.prokind in ('f', 'p') and (p.proname ~ '^(backup_|redaction_)' or p.proname in ('ws_sensitive_hits', 'agent_runs_scrub')) order by 2 loop
      e0 := public.backup_epoch();
      def := pg_get_functiondef(fr.oid);
      execute replace(def, 'AS $function$', 'AS $function$ ');
      e1 := public.backup_epoch();
      if e1 ->> 'code' = e0 ->> 'code' then raise exception 'B27 redefining % did not change the epoch code hash', fr.sig; end if;
      cnt := cnt + 1;
    end loop;
    if cnt < 55 then raise exception 'B27b only % functions are hashed (expected the whole export path, 55+)', cnt; end if;
  end;
  e0 := public.backup_epoch(); alter table public.memory add column zz_probe text;
  e1 := public.backup_epoch(); if e1 ->> 'policy' = e0 ->> 'policy' then raise exception 'B28 a new column on an exported table did not change the policy hash'; end if;

  -- ---- B4 (verifier round 5): a table that is NOT exported and has a name / contact / address-like text column must be a redaction source, or be on this reviewed list (it is not a person's identifier). A new client table with a
  -- name-like column fails here until it is added to redaction_sources() (which also feeds the context and the epoch) or reviewed onto the list on purpose.
  declare offenders text;
  begin
    select string_agg(c.table_name || '.' || c.column_name, ', ' order by 1) into offenders
      from information_schema.columns c join pg_class r on r.relname = c.table_name and r.relnamespace = 'public'::regnamespace and r.relkind = 'r'
     where c.table_schema = 'public' and c.table_name not in (select jsonb_array_elements_text(public.backup_export_policy() -> 'exported'))
       and c.data_type in ('text', 'character varying', 'jsonb') and c.column_name ~ '(^|_)(name|email|phone|contact|to_ref|address|client|payee|tel|mobile|cell)($|_)'
       and not exists (select 1 from public.redaction_sources() s where s.table_name = c.table_name and s.column_name = c.column_name)
       and (c.table_name || '.' || c.column_name) not in ('ffm_ad_sets.name', 'ffm_routing_rules.name', 'ws_campaigns.name', 'ffm_redaction_keys.name',   -- reviewed: campaign / ad set / rule / key LABELS set by the workspace operator, not a person's identifier
           -- round 8 (integration rehearsal S3), columns of tables that other open PRs add (consent integrity #20, insurance classifier #17); listed here so the three merge without a red test:
           'ffm_secrets.name',                 -- the LABEL of a secret (which key it is), never a person
           'ffm_consent_captures.contact_mac', -- a keyed hash (MAC) of the contact, not the contact
           'ws_place_catalog.name_norm', 'ws_place_catalog.display_name',   -- PLACE names (towns, regions) of the insurance catalogue, not people
           -- OWNER DECISION (policy rule 15, OWNER_DECISIONS G8): opted-out phone numbers in PLAIN TEXT. Deliberately NOT a redaction source: a source's values are hashed into the deny-list and read by
           -- the redaction context on every backup, which would spread a number whose owner asked not to be contacted into more places; and the capture triggers are attached before this table
           -- exists. Consequence: a number that exists ONLY here is removed from exported text by the generic phone patterns, not by known-number matching (a 7-digit local form in a LIGHT column can pass).
           'ffm_phone_suppressions.phone');
    if offenders is not null then raise exception 'B30 name-like columns that are neither redaction sources nor reviewed: %', offenders; end if;
  end;


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
  set local role backup_reader;
  begin e1 := public.backup_epoch(); reset role; exception when others then reset role; raise exception 'B16 backup_reader cannot read the epoch vector (the backup needs it): %', sqlerrm; end;
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
  set local role backup_reader;      -- a different caller identity (role differs from the owner's)
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
  n := (select count(*)::int from public.tasks where id < (select id from public.tasks where title = 'zzc cache'));
  set local role backup_reader;
  paged := public.backup_snapshot_page('tasks', n, 1, run2);
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
-- ===== Round 8: S5 (write-path cost), N3 (renamed source column), N5 / N6 (epoch digest)
do $$
declare bad text; v uuid; e0 jsonb; e1 jsonb; plan text; ok boolean := false;
begin
  select id into v from public.ventures order by slug limit 1;
  -- S5 expected: every redaction-source column has its hash index, and the "is this value new" probe uses it (no sequential scan of the source table)
  select string_agg(s.table_name || '.' || s.column_name, ', ') into bad from public.redaction_sources() s
   where to_regclass('public.' || s.table_name) is not null
     and not exists (select 1 from pg_index i join pg_class ic on ic.oid = i.indexrelid join pg_am am on am.oid = ic.relam join pg_attribute a on a.attrelid = i.indrelid and a.attnum = i.indkey[0]
                      where i.indrelid = to_regclass('public.' || s.table_name) and am.amname = 'hash' and a.attname = s.column_name and i.indnatts = 1);
  if bad is not null then raise exception 'S5 redaction-source columns without a hash index: %', bad; end if;
  set local enable_seqscan = off;
  for plan in explain select 1 from public.leads t where t.name = 'x' limit 2 loop if plan ~ 'redaction_src_leads_name_idx' then ok := true; end if; end loop;
  reset enable_seqscan;
  if not ok then raise exception 'S5 the equality probe on leads.name cannot use the hash index'; end if;
  -- a value longer than a btree row may hold must still insert (why the index is a hash index)
  insert into public.leads (venture_id, name, status) values (v, repeat('Zzlongname ', 400), 'new');
  -- N5 expected: the source digest tells {"a<US>b"} from {"a","b"} (it used to join the values with chr(31))
  e0 := public.backup_epoch();
  set local session_replication_role = replica;
  insert into public.setter_events (setter_id, kind, client) select id, 'booked', 'zzn5a' || chr(31) || 'zzn5b' from public.setters limit 1;
  e0 := public.backup_epoch();
  delete from public.setter_events where client = 'zzn5a' || chr(31) || 'zzn5b';
  insert into public.setter_events (setter_id, kind, client) select id, 'booked', x from public.setters, unnest(array['zzn5a', 'zzn5b']) x where setters.id = (select id from public.setters order by id limit 1);
  e1 := public.backup_epoch();
  reset session_replication_role;
  if exists (select 1 from public.setters) and (e0 -> 'sources' ->> 'setter_events.client') = (e1 -> 'sources' ->> 'setter_events.client') then raise exception 'N5 the source digest cannot tell one value with a separator from two values'; end if;
  -- N6 expected: the epoch names the key row (creation time, never the value)
  if (public.backup_epoch() ->> 'key') is null or (public.backup_epoch())::text ~ (select value from public.ffm_redaction_keys limit 1) then raise exception 'N6 the epoch must carry the key row marker and never the key'; end if;
  -- N3 expected: after a source column is renamed, inserts still work, the epoch moves, and the next backup is REFUSED with the reason (it used to fail every insert and skip the column silently)
  e0 := public.backup_epoch();
  alter table public.leads rename column name to zz_renamed_name;
  begin
    insert into public.leads (venture_id, zz_renamed_name, status) values (v, 'Zzafter Rename', 'new');
  exception when others then raise exception 'N3 an insert into a table whose source column was renamed failed: %', sqlerrm; end;
  if (public.backup_epoch() ->> 'seq') = (e0 ->> 'seq') then raise exception 'N3 the epoch did not move after a write to a table with a missing source column'; end if;
  begin
    perform public.backup_redaction_context();
    raise exception 'N3 the context was built although leads.name is gone (its names would no longer be redacted)';
  exception when raise_exception then
    if sqlerrm !~ 'redaction source column leads.name does not exist' then raise; end if;
  end;
  begin
    perform public.backup_snapshot();
    raise exception 'N3 a snapshot was produced although a redaction source column is gone';
  exception when raise_exception then
    if sqlerrm !~ 'redaction source column' then raise; end if;
  end;
  alter table public.leads rename column zz_renamed_name to name;
  perform public.backup_redaction_context();
  -- B1 expected: the cost function reports how many rows one statement would hold (hq_backup pages above its row limit)
  if (public.backup_snapshot_cost() ->> 'rows_total')::bigint is distinct from (select sum((public.backup_table_digest(x) ->> 'rows')::bigint) from jsonb_array_elements_text(public.backup_export_policy() -> 'exported') x where x not in ('push_config', 'push_subscriptions')) then
    raise exception 'B1 backup_snapshot_cost().rows_total is not the number of exported rows: %', public.backup_snapshot_cost();
  end if;
  raise notice 'ROUND 8 EPOCH CHECKS PASSED';
end $$;

rollback;
select 'backup_epoch_cache_check_ok';
