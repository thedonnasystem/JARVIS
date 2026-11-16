-- SQL-level checks for migrations/20261119_backup_exclude_client_pii_v1.sql. SCRATCH replica only. One transaction, rolled back.
-- Proves: client personal-data tables are not in the off-site snapshot (including a real marker value that is searched for in the whole snapshot), unclassified and
-- drifting tables fail closed, foreign-key closure, the skip parameter cannot widen the export, grants.
begin;
do $$
declare pol jsonb; snap jsonb; t text; r text; f text; n int; v uuid; a uuid; ca uuid; keys text[]; txt text;
begin
  -- B1 grants
  foreach f in array array['public.backup_classification()', 'public.backup_pii_column_exceptions()', 'public.backup_export_policy()', 'public.backup_snapshot(text[])'] loop
    foreach r in array array['anon', 'authenticated'] loop
      if has_function_privilege(r, f, 'execute') then raise exception 'B1 % can execute %', r, f; end if;
    end loop;
    if not has_function_privilege('service_role', f, 'execute') then raise exception 'B2 service_role cannot execute %', f; end if;
  end loop;

  pol := public.backup_export_policy();
  -- B3 every table is decided exactly once
  select count(*) into n from pg_class where relnamespace = 'public'::regnamespace and relkind in ('r', 'p');
  if jsonb_array_length(pol -> 'exported') + jsonb_array_length(pol -> 'excluded') <> n then raise exception 'B3 policy does not cover every table (% + % <> %)', jsonb_array_length(pol -> 'exported'), jsonb_array_length(pol -> 'excluded'), n; end if;
  if exists (select 1 from jsonb_array_elements_text(pol -> 'exported') e join jsonb_array_elements(pol -> 'excluded') x on x ->> 'table' = e) then raise exception 'B4 a table is both exported and excluded'; end if;
  -- B5 no unclassified table exists in the repo today (a new table must be classified in the same change, or this test fails)
  if jsonb_array_length(pol -> 'unclassified') <> 0 then raise exception 'B5 unclassified tables: %', pol -> 'unclassified'; end if;
  -- B6 the client personal-data tables are excluded
  foreach t in array array['leads', 'outbox', 'lead_replies', 'deals', 'contact_suppressions', 'setters', 'setter_events', 'setter_payouts', 'client_workspaces', 'ws_campaigns', 'ws_leads', 'ws_ledger',
                           'ffm_onboarding_items', 'ffm_ad_sets', 'ffm_creatives', 'ffm_routing_rules', 'ffm_approvals', 'ffm_route_log', 'ffm_consent_log', 'ffm_consent_settings', 'ffm_onboarding_templates', 'push_config', 'push_subscriptions'] loop
    if t = any (array(select jsonb_array_elements_text(pol -> 'exported'))) then raise exception 'B6 % is exported', t; end if;
  end loop;
  -- B7 and the operating tables still are exported (the backup keeps working)
  foreach t in array array['audit_log', 'ledger', 'missions', 'tasks', 'ventures', 'agents', 'system_state', 'action_policy', 'memory'] loop
    if not (t = any (array(select jsonb_array_elements_text(pol -> 'exported')))) then raise exception 'B7 % is not exported', t; end if;
  end loop;
  -- B8 every exported table is on the explicit list as public or internal, and no exported table holds an unreviewed contact-looking column
  if exists (select 1 from jsonb_array_elements_text(pol -> 'exported') e where not exists (select 1 from public.backup_classification() k where k.table_name = e and k.data_class in ('public', 'internal'))) then raise exception 'B8 exported table not on the allow list'; end if;
  if exists (select 1 from pg_attribute at join pg_class c on c.oid = at.attrelid where c.relnamespace = 'public'::regnamespace and c.relname in (select jsonb_array_elements_text(pol -> 'exported'))
             and at.attnum > 0 and not at.attisdropped and at.attname ~* '(^|_)(email|e_mail|phone|mobile|first_?name|last_?name|full_?name|to_ref|address|payee|dob|birth[a-z]*)($|_)'
             and not exists (select 1 from public.backup_pii_column_exceptions() x where x.table_name = c.relname and x.column_name = at.attname)) then raise exception 'B8b exported table has an unreviewed contact column'; end if;
  -- B9 classification names only real classes
  if exists (select 1 from public.backup_classification() where data_class not in ('public', 'internal', 'client_pii', 'client_sensitive', 'secret')) then raise exception 'B9 unknown class'; end if;
  if (select count(*) from public.backup_classification()) <> (select count(distinct table_name) from public.backup_classification()) then raise exception 'B10 a table is classified twice'; end if;

  -- B11 real data: marker values in excluded tables must not appear ANYWHERE in the snapshot (data or schema)
  select id into v from public.ventures limit 1;
  insert into public.leads (venture_id, name, email, phone, notes) values (v, 'ZZMARKERNAME Prospect', 'zzmarker-lead@example.com', '613-555-0199', 'ZZMARKERNOTE');
  insert into public.contact_suppressions (address, reason, recorded_by) values ('zzmarker-suppressed@example.com', 'unsubscribe', 'test');
  insert into public.client_workspaces (slug, name, vertical) values ('zz-marker', 'ZZMARKERCLIENT Ltd', 'mortgage') returning id into a;   -- (a workspace without a vertical gets the insurance wording screen since 20261122; the marker strings are not vocabulary, and the classifier is not under test here)
  insert into public.ws_campaigns (workspace_id, name) values (a, 'zz camp') returning id into ca;
  perform public.ws_add_lead(a, ca, 'ZZMARKERWS Person', 'zzmarker-ws@example.com', '613-555-0188', 'web form');
  insert into public.ventures (slug, name, kind) values ('zz-visible', 'ZZVISIBLE venture', 'lab');   -- an exported table: the marker MUST be present, or the test proves nothing
  snap := public.backup_snapshot();
  txt := snap::text;
  if txt like '%ZZMARKER%' or txt like '%zzmarker%' then raise exception 'B11 client marker data found in the snapshot'; end if;
  if txt not like '%ZZVISIBLE%' then raise exception 'B12 the control marker is missing: the snapshot is not reading exported tables'; end if;
  keys := array(select jsonb_object_keys(snap -> 'data'));
  if 'leads' = any (keys) or 'ws_leads' = any (keys) or 'push_config' = any (keys) or 'ffm_consent_log' = any (keys) then raise exception 'B13 excluded table has a data key'; end if;
  if not ('audit_log' = any (keys)) then raise exception 'B14 audit_log missing'; end if;
  if (select count(*) from jsonb_array_elements(snap -> 'schema' -> 'tables') x where x ->> 'name' in ('leads', 'ws_leads', 'ffm_consent_log')) <> 3 then raise exception 'B15 structure of excluded tables should still be in schema.json'; end if;
  if snap -> 'policy' <> public.backup_export_policy() then raise exception 'B16 policy not returned with the snapshot'; end if;
  -- B17 the skip parameter can only narrow the export, never widen it
  snap := public.backup_snapshot(array[]::text[]);
  keys := array(select jsonb_object_keys(snap -> 'data'));
  if 'leads' = any (keys) or 'push_config' = any (keys) or 'push_subscriptions' = any (keys) or 'ws_leads' = any (keys) then raise exception 'B17 an empty skip list widened the export'; end if;
  snap := public.backup_snapshot(array['audit_log']);
  if 'audit_log' = any (array(select jsonb_object_keys(snap -> 'data'))) then raise exception 'B18 skip no longer narrows'; end if;

  -- B19 FAIL CLOSED: a brand-new table is excluded until it is classified
  create table public.zz_new_table (id int, note text);
  insert into public.zz_new_table values (1, 'ZZNEWTABLEROW');
  pol := public.backup_export_policy();
  if 'zz_new_table' = any (array(select jsonb_array_elements_text(pol -> 'exported'))) then raise exception 'B19 a new unclassified table is exported'; end if;
  if not ('zz_new_table' = any (array(select jsonb_array_elements_text(pol -> 'unclassified')))) then raise exception 'B20 a new table is not reported as unclassified'; end if;
  if public.backup_snapshot()::text like '%ZZNEWTABLEROW%' then raise exception 'B21 data of an unclassified table is in the snapshot'; end if;
  -- B22 column drift: a classified table that gains a contact-looking column drops out of the export
  alter table public.handbook add column contact_email text;
  if 'handbook' = any (array(select jsonb_array_elements_text(public.backup_export_policy() -> 'exported'))) then raise exception 'B22 column drift not detected'; end if;
  alter table public.handbook drop column contact_email;
  if not ('handbook' = any (array(select jsonb_array_elements_text(public.backup_export_policy() -> 'exported')))) then raise exception 'B23 handbook did not come back'; end if;
  -- B24 foreign-key closure: a table pointing at an excluded table is excluded too
  alter table public.handbook add column lead_ref uuid references public.leads (id);
  if 'handbook' = any (array(select jsonb_array_elements_text(public.backup_export_policy() -> 'exported'))) then raise exception 'B24 foreign-key closure not applied'; end if;
  -- B25 rule beats list: a table that looks like a client table is excluded by prefix even if someone lists it
  create table public.ws_zz_extra (id int);
  if 'ws_zz_extra' = any (array(select jsonb_array_elements_text(public.backup_export_policy() -> 'exported'))) then raise exception 'B25 ws_ table exported'; end if;
  raise notice 'backup_exclude_check: all passed';
end $$;
rollback;
