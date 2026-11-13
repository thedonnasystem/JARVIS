-- SQL-level checks for migrations/20261116_evidence_sources_v1.sql. SCRATCH replica only (scripts/replica/run.sh runs it).
-- One transaction, rolled back. Proves: RLS on with no policy, anon/authenticated have no table or function access, service_role can
-- select+insert but not update/delete/truncate, UPDATE trigger raises, bad hash / oversized text / untrusted=false / no owner refused,
-- FK to missions, dedupe, the FK detach exception, purge only deletes old snapshots of FINISHED missions.
begin;
do $$
declare mid uuid; mid2 uuid; tid uuid; h text := repeat('a', 64); n int; r text; f text; ok boolean;
begin
  set local session_replication_role = replica;   -- fixtures only: skip the mission state-machine trigger
  insert into public.missions (title, objective, status) values ('ev test', 'objective for the evidence sql test', 'completed') returning id into mid;
  insert into public.missions (title, objective, status) values ('ev test live', 'objective for the evidence sql test two', 'executing') returning id into mid2;
  set local session_replication_role = origin;
  insert into public.tasks (title, status, mission_id) values ('t', 'done', mid) returning id into tid;

  if not (select relrowsecurity from pg_class where oid = 'public.evidence_sources'::regclass) then raise exception 'E1 RLS is off'; end if;
  if exists (select 1 from pg_policy where polrelid = 'public.evidence_sources'::regclass) then raise exception 'E2 a policy exists (default-deny broken)'; end if;
  foreach r in array array['anon','authenticated'] loop
    foreach f in array array['select','insert','update','delete','truncate'] loop
      if has_table_privilege(r, 'public.evidence_sources', f) then raise exception 'E3 % can % evidence_sources', r, f; end if;
    end loop;
  end loop;
  if not (has_table_privilege('service_role', 'public.evidence_sources', 'select') and has_table_privilege('service_role', 'public.evidence_sources', 'insert')) then
    raise exception 'E4 service_role lost select/insert'; end if;
  foreach f in array array['update','delete','truncate'] loop
    if has_table_privilege('service_role', 'public.evidence_sources', f) then raise exception 'E5 service_role can % evidence_sources', f; end if;
  end loop;
  foreach f in array array['public.evidence_sources_immutable()','public.purge_evidence_sources(integer)'] loop
    foreach r in array array['anon','authenticated'] loop
      if has_function_privilege(r, f, 'execute') then raise exception 'E6 % can execute %', r, f; end if;
    end loop;
    if not has_function_privilege('service_role', f, 'execute') then raise exception 'E7 service_role cannot execute %', f; end if;
  end loop;

  insert into public.evidence_sources (mission_id, task_id, kind, url, final_url, host_norm, content_sha256, text) values (mid, tid, 'page', 'https://a.example/x', 'https://a.example/x', 'a.example', h, 'hello');
  begin insert into public.evidence_sources (mission_id, task_id, kind, url, final_url, host_norm, content_sha256, text) values (mid, tid, 'page', 'https://a.example/x', 'https://a.example/x', 'a.example', h, 'hello'); raise exception 'E8 duplicate accepted';
  exception when unique_violation then null; end;
  begin insert into public.evidence_sources (mission_id, kind, url, final_url, host_norm, content_sha256, text) values (mid, 'page', 'u', 'u', 'h', 'nothex', 'x'); raise exception 'E9 bad hash accepted';
  exception when check_violation then null; end;
  begin insert into public.evidence_sources (mission_id, kind, url, final_url, host_norm, content_sha256, text) values (mid, 'page', 'u', 'u', 'h', h, repeat('x', 40001)); raise exception 'E10 oversized text accepted';
  exception when check_violation then null; end;
  begin insert into public.evidence_sources (mission_id, kind, url, final_url, host_norm, content_sha256, text, untrusted) values (mid, 'page', 'u', 'u', 'h', h, 'x', false); raise exception 'E11 untrusted=false accepted';
  exception when check_violation then null; end;
  begin insert into public.evidence_sources (kind, url, final_url, host_norm, content_sha256, text) values ('page', 'u', 'u', 'h', h, 'x'); raise exception 'E12 row with no mission or task accepted';
  exception when check_violation then null; end;
  begin insert into public.evidence_sources (mission_id, kind, url, final_url, host_norm, content_sha256, text) values (gen_random_uuid(), 'page', 'u', 'u', 'h', h, 'x'); raise exception 'E13 unknown mission accepted';
  exception when foreign_key_violation then null; end;
  begin insert into public.evidence_sources (mission_id, kind, url, final_url, host_norm, content_sha256, text) values (mid, 'video', 'u', 'u', 'h', h, 'x'); raise exception 'E14 bad kind accepted';
  exception when check_violation then null; end;

  begin update public.evidence_sources set text = 'tampered'; raise exception 'E15 stored text was updated';
  exception when sqlstate 'P0001' then if sqlerrm like 'E15%' then raise; end if; end;
  begin update public.evidence_sources set content_sha256 = repeat('b', 64); raise exception 'E16 stored hash was updated';
  exception when sqlstate 'P0001' then if sqlerrm like 'E16%' then raise; end if; end;

  -- purge: old snapshot of a finished mission goes; recent ones and snapshots of live missions stay; minimum 7 days
  insert into public.evidence_sources (mission_id, kind, url, final_url, host_norm, content_sha256, text, created_at) values (mid, 'page', 'https://old.example/', 'https://old.example/', 'old.example', repeat('c', 64), 'old finished', now() - interval '100 days');
  insert into public.evidence_sources (mission_id, kind, url, final_url, host_norm, content_sha256, text, created_at) values (mid2, 'page', 'https://old2.example/', 'https://old2.example/', 'old2.example', repeat('d', 64), 'old live', now() - interval '100 days');
  n := public.purge_evidence_sources(90);
  if n <> 1 then raise exception 'E17 purge removed % rows, expected 1', n; end if;
  if not exists (select 1 from public.evidence_sources where text = 'old live') then raise exception 'E18 purge removed a live mission snapshot'; end if;
  if not exists (select 1 from public.evidence_sources where text = 'hello') then raise exception 'E19 purge removed a recent snapshot'; end if;
  n := public.purge_evidence_sources(0);
  if not exists (select 1 from public.evidence_sources where text = 'hello') then raise exception 'E20 purge(0) ignored the 7-day minimum'; end if;

  -- deleting the researching task detaches the row instead of failing or losing it
  delete from public.tasks where id = tid;
  if not exists (select 1 from public.evidence_sources where text = 'hello' and task_id is null) then raise exception 'E21 snapshot lost or not detached when its task was deleted'; end if;
end $$;
set local role anon;
do $$ begin
  begin perform 1 from public.evidence_sources; raise exception 'E22 anon read evidence_sources';
  exception when insufficient_privilege then null; end;
end $$;
reset role;
set local role authenticated;
do $$ begin
  begin perform 1 from public.evidence_sources; raise exception 'E23 authenticated read evidence_sources';
  exception when insufficient_privilege then null; end;
end $$;
reset role;
rollback;
