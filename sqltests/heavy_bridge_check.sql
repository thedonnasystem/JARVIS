-- Heavy bridge (migrations/20261208_heavy_bridge_v1.sql). ONE transaction, rolled back.
-- Proves: no API role holds any privilege on the fz_heavy schema or its tables, RLS is on; anon / authenticated / the scoped fz roles cannot run the
-- functions (by grant, and in the body even after a mistaken grant); the bot (service key) can; the bridge is OFF by default and then nothing can be
-- added or handed out; only clean text gets in (e-mail addresses, phone numbers and secret-looking strings are refused in instructions, title and
-- result summary, by the functions AND by the table); claim hands out one job at a time, oldest first, never with the kill switch on, never above
-- the daily limit, and fails a stale job; finish needs a pull-request link in thedonnasystem/JARVIS, tells the Chairman exactly once as Jarvis and
-- cannot be repeated; cancel only before the start; the audit rows carry no job text; the money controls are identical with the migration, after
-- its rollback (twice) and after a re-apply; the rollback keeps every job and a re-apply restores them.
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
create temp table hb_fp_with as select * from pg_temp.fz_money_fp();
do $$
declare r jsonb; res text; rl text; n int; m int; j1 bigint; j2 bigint; j3 bigint; s text;
  bad text[] := array[
    'Write to the lead at jane.doe@example.com about the new site',          -- e-mail
    'Ask jane (at) example for the logo and build the page',                 -- e-mail, spelled out
    'Call the client at 613-555-0142 and then fix the office',               -- phone
    'Call the client at (613) 555 0142 and then fix the office',
    'Their number is 6135550142, use it in the footer',
    'Reach them on +44 20 7946 0958 before building',
    -- secret-looking samples are assembled here from pieces, so no scanner (and no reader) mistakes this file for one that holds a real key
    'Use the key ' || 's' || 'k-' || repeat('ab12', 5) || ' for the build',
    'Deploy with ' || 'gh' || 'p_' || repeat('ab12', 9),
    'The login is admin, pass' || 'word: ' || repeat('zx9', 4),
    'api' || '_key=' || repeat('qw3', 4) || ' goes in the header',
    'Use ' || 'ey' || 'J' || repeat('ab12', 4) || '.' || repeat('cd34', 4) || '.x as the session',
    'The value ' || repeat('9f86d081', 8) || ' unlocks it',
    'Paste ' || repeat('-', 5) || 'BEGIN the block into the config'];
  good text[] := array[
    'Build a one-page site for the Donna office: hero, three services, booking button. Use the existing site template.',
    'Review PR 41 for quality: tests, naming, docs. Report on docs/architecture/PHASE1_M6_MONITORING_BRAIN.md and migration 20261202_monitoring_brain_v1.sql.',
    'Research three open-source booking widgets (MIT or Apache), compare cost at 100 and 1000 bookings a month, recommend one by 2026-12-01.',
    'Fix the office OS status report: on 2026-11-23 10 offices showed 0 agents. See https://github.com/thedonnasystem/JARVIS/pull/40 for context.'];
begin
  -- H1 no API privilege on the schema or the tables; RLS on; functions closed to everyone but the service key
  foreach rl in array array['anon', 'authenticated', 'service_role', 'fz_jarvis', 'fz_office_agent', 'fz_auditor', 'backup_reader'] loop
    continue when not exists (select 1 from pg_roles where rolname = rl);
    if has_schema_privilege(rl, 'fz_heavy', 'usage') or has_schema_privilege(rl, 'fz_heavy', 'create') then raise exception 'H1 % has a privilege on fz_heavy', rl; end if;
    if exists (select 1 from pg_class c where c.relnamespace = 'fz_heavy'::regnamespace and c.relkind in ('r', 'S')
               and (has_table_privilege(rl, c.oid, 'select') or has_table_privilege(rl, c.oid, 'insert') or has_table_privilege(rl, c.oid, 'update'))) then
      raise exception 'H1 % holds a table privilege in fz_heavy', rl; end if;
    if rl not in ('service_role') and exists (select 1 from pg_proc p where p.pronamespace = 'public'::regnamespace and p.proname ~ '^heavy_'
               and has_function_privilege(rl, p.oid, 'execute')) then raise exception 'H1 % can execute a heavy-bridge function', rl; end if;
  end loop;
  if (select count(*) from pg_class c where c.relnamespace = 'fz_heavy'::regnamespace and c.relkind = 'r' and c.relrowsecurity) <> 2
     or (select count(*) from pg_class c where c.relnamespace = 'fz_heavy'::regnamespace and c.relkind = 'r') <> 2 then
    raise exception 'H1 row level security is not on for both tables'; end if;
  if (select count(*) from pg_proc p where p.pronamespace = 'public'::regnamespace and p.proname ~ '^heavy_') <> 10 then raise exception 'H1 expected 10 heavy_ functions'; end if;
  if exists (select 1 from pg_proc p where p.pronamespace = 'public'::regnamespace and p.proname ~ '^heavy_' and p.proname <> 'heavy_text_problem' and not p.prosecdef) then
    raise exception 'H1 a heavy function is not security definer'; end if;
  if exists (select 1 from pg_proc p where p.pronamespace = 'public'::regnamespace and p.proname ~ '^heavy_' and (p.proconfig is null or not p.proconfig::text like '%search_path=pg_catalog%')) then
    raise exception 'H1 a heavy function has no pinned search_path'; end if;

  -- H2 the bot can; a signed-in app user and the scoped roles cannot, even with a mistaken grant (the body refuses)
  res := pg_temp.as_role('service_role', 'select public.heavy_list()::text');
  if res not like 'OK:%' then raise exception 'H2 the bot cannot call heavy_list: %', res; end if;
  if pg_temp.as_role('service_role', 'select count(*)::text from fz_heavy.jobs') not like 'ERR:%permission denied%' then raise exception 'H2 the service key reads the table directly'; end if;
  grant execute on function public.heavy_enqueue(text, text, text), public.heavy_claim(text), public.heavy_finish(bigint, text, text, text), public.heavy_list(integer),
    public.heavy_cancel(bigint), public.heavy_set_enabled(boolean), public.heavy_tell_owner(text) to authenticated, anon;
  foreach rl in array array['anon', 'authenticated'] loop
    foreach s in array array[$q$select public.heavy_enqueue('research', 'A perfectly clean research job text')::text$q$, $q$select public.heavy_claim()::text$q$,
                             $q$select public.heavy_finish(1, 'done', 'x y z', null)::text$q$, $q$select public.heavy_list()::text$q$, $q$select public.heavy_cancel(1)::text$q$,
                             $q$select public.heavy_set_enabled(true)::text$q$, $q$select public.heavy_tell_owner('hello there')::text$q$] loop
      if pg_temp.as_role(rl, s) not like 'ERR:%bot and database sessions only%' then raise exception 'H2 % ran: %', rl, s; end if;
    end loop;
  end loop;
  revoke execute on function public.heavy_enqueue(text, text, text), public.heavy_claim(text), public.heavy_finish(bigint, text, text, text), public.heavy_list(integer),
    public.heavy_cancel(bigint), public.heavy_set_enabled(boolean), public.heavy_tell_owner(text) from authenticated, anon;
  foreach rl in array array['fz_jarvis', 'fz_office_agent', 'fz_auditor', 'backup_reader'] loop
    continue when not exists (select 1 from pg_roles where rolname = rl);
    if pg_temp.as_role(rl, $q$select public.heavy_enqueue('research', 'A perfectly clean research job text')::text$q$) not like 'ERR:%' then raise exception 'H2 % enqueued', rl; end if;
    if pg_temp.as_role(rl, $q$select public.heavy_claim()::text$q$) not like 'ERR:%' then raise exception 'H2 % claimed', rl; end if;
  end loop;

  -- H3 OFF by default: nothing in, nothing out
  if (select enabled from fz_heavy.settings) then raise exception 'H3 the bridge is on by default'; end if;
  begin perform public.heavy_enqueue('research', 'A perfectly clean research job text'); raise exception 'H3 enqueued while off';
  exception when sqlstate '55000' then null; end;
  r := public.heavy_claim();
  if r -> 'job' <> 'null'::jsonb or r ->> 'reason' not like '%switched off%' then raise exception 'H3 claim while off: %', r; end if;
  n := (select count(*) from public.audit_log where action = 'heavy_bridge_switch');
  perform public.heavy_set_enabled(true); perform public.heavy_set_enabled(true);
  if (select count(*) from public.audit_log where action = 'heavy_bridge_switch') <> n + 1 then raise exception 'H3 the switch is not audited exactly once'; end if;

  -- H4 validation: kinds, lengths, contact details and secrets are refused; clean text passes; the table refuses a direct write too
  begin perform public.heavy_enqueue('send-email', 'A perfectly clean research job text'); raise exception 'H4 unknown kind accepted'; exception when sqlstate '22023' then null; end;
  begin perform public.heavy_enqueue('research', 'too short'); raise exception 'H4 short text accepted'; exception when sqlstate '22023' then null; end;
  begin perform public.heavy_enqueue('research', repeat('long words ', 400)); raise exception 'H4 long text accepted'; exception when sqlstate '22023' then null; end;
  foreach s in array bad loop
    if public.heavy_text_problem(s) is null then raise exception 'H4 not detected: %', s; end if;
    begin perform public.heavy_enqueue('other', s); raise exception 'H4 enqueued: %', s;
    exception when sqlstate '22023' then if position(right(s, 15) in sqlerrm) > 0 then raise exception 'H4 the refusal repeats the text'; end if; end;
    begin perform public.heavy_enqueue('other', 'A perfectly clean research job text', s); raise exception 'H4 enqueued by title: %', s; exception when sqlstate '22023' then null; end;
    begin insert into fz_heavy.jobs (kind, title, instructions) values ('other', 'Direct write', s); raise exception 'H4 the table took: %', s; exception when check_violation then null; end;
  end loop;
  foreach s in array good loop
    if public.heavy_text_problem(s) is not null then raise exception 'H4 false alarm (%): %', public.heavy_text_problem(s), s; end if;
  end loop;
  if exists (select 1 from fz_heavy.jobs) then raise exception 'H4 a refused job left a row'; end if;

  -- H5 enqueue (as the bot), list, cancel
  res := pg_temp.as_role('service_role', format('select public.heavy_enqueue(%L, %L)::text', 'site-build', good[1]));
  if res not like 'OK:%' then raise exception 'H5 the bot cannot enqueue: %', res; end if;
  j1 := (substr(res, 4)::jsonb ->> 'id')::bigint;
  j2 := (public.heavy_enqueue('qc-review', good[2]) ->> 'id')::bigint;
  j3 := (public.heavy_enqueue('research', good[3]) ->> 'id')::bigint;
  if (select title from fz_heavy.jobs where id = j1) <> left(good[1], 120) or (select status from fz_heavy.jobs where id = j1) <> 'queued' then raise exception 'H5 job row'; end if;
  r := public.heavy_list();
  if (r ->> 'queued')::int <> 3 or not (r ->> 'enabled')::boolean or jsonb_array_length(r -> 'jobs') <> 3 or r::text like '%instructions%' then raise exception 'H5 list: %', r; end if;
  perform public.heavy_cancel(j3);
  if (select status from fz_heavy.jobs where id = j3) <> 'cancelled' then raise exception 'H5 cancel'; end if;
  begin perform public.heavy_cancel(j3); raise exception 'H5 cancelled twice'; exception when sqlstate '55000' then null; end;
  begin perform public.heavy_cancel(999999); raise exception 'H5 cancelled a missing job'; exception when sqlstate '22023' then null; end;
  for n in 1..8 loop perform public.heavy_enqueue('other', 'Filler job number ' || n || ' for the queue limit'); end loop;   -- 2 + 8 = 10 waiting
  begin perform public.heavy_enqueue('other', 'One job more than the queue allows'); raise exception 'H5 the queue limit did not hold'; exception when sqlstate '55000' then null; end;
  update fz_heavy.jobs set status = 'cancelled', finished_at = now() where title like 'Filler job%';

  -- H6 claim: kill switch, one at a time, oldest first, finish rules, one owner message, daily limit
  if (select kill_switch from public.system_state where id = 1) then raise exception 'H6 fixture: the kill switch is on in the scratch database'; end if;
  begin                                                                   -- in a sub-transaction that is undone: the kill switch row is left exactly as it was
    update public.system_state set kill_switch = true where id = 1;
    r := public.heavy_claim();
    if r -> 'job' <> 'null'::jsonb or r ->> 'reason' not like '%kill switch%' then raise exception 'H6 claimed with the kill switch on: %', r; end if;
    raise exception using errcode = 'ZHB01';
  exception when sqlstate 'ZHB01' then null;
  end;
  if exists (select 1 from fz_heavy.jobs where status = 'claimed') then raise exception 'H6 a job was claimed with the kill switch on'; end if;
  begin perform public.heavy_claim('Bad Runner!'); raise exception 'H6 bad runner accepted'; exception when sqlstate '22023' then null; end;
  res := pg_temp.as_role('service_role', 'select public.heavy_claim()::text');
  if res not like 'OK:%' then raise exception 'H6 claim: %', res; end if;
  r := substr(res, 4)::jsonb;
  if (r -> 'job' ->> 'id')::bigint <> j1 or r -> 'job' ->> 'instructions' <> good[1] or (r ->> 'left_today')::int <> 1 then raise exception 'H6 first claim: %', r; end if;
  r := public.heavy_claim();
  if r -> 'job' <> 'null'::jsonb or r ->> 'reason' not like '%in progress%' then raise exception 'H6 two jobs at once: %', r; end if;
  begin perform public.heavy_cancel(j1); raise exception 'H6 cancelled a job in progress'; exception when sqlstate '55000' then null; end;
  begin perform public.heavy_finish(j2, 'done', 'Not started yet', 'https://github.com/thedonnasystem/JARVIS/pull/50'); raise exception 'H6 finished a queued job'; exception when sqlstate '55000' then null; end;
  begin perform public.heavy_finish(j1, 'merged', 'Site page built', 'https://github.com/thedonnasystem/JARVIS/pull/50'); raise exception 'H6 bad status'; exception when sqlstate '22023' then null; end;
  begin perform public.heavy_finish(j1, 'done', 'Site page built', null); raise exception 'H6 done without a link'; exception when sqlstate '22023' then null; end;
  foreach s in array array['https://evil.example/pull/1', 'https://github.com/someone/JARVIS/pull/1', 'https://github.com/thedonnasystem/JARVIS/pull/1/files',
                           'https://github.com/thedonnasystem/JARVIS/pull/1?x=https://evil.example', 'http://github.com/thedonnasystem/JARVIS/pull/1',
                           'https://github.com/thedonnasystem/other/pull/1'] loop
    begin perform public.heavy_finish(j1, 'done', 'Site page built', s); raise exception 'H6 link accepted: %', s; exception when sqlstate '22023' then null; end;
  end loop;
  begin perform public.heavy_finish(j1, 'done', 'Built it, ask jane.doe@example.com', 'https://github.com/thedonnasystem/JARVIS/pull/50'); raise exception 'H6 e-mail in the summary';
  exception when sqlstate '22023' then null; end;
  begin perform public.heavy_finish(j1, 'done', repeat('very long ', 40), 'https://github.com/thedonnasystem/JARVIS/pull/50'); raise exception 'H6 long summary'; exception when sqlstate '22023' then null; end;
  n := (select count(*) from public.owner_messages);
  res := pg_temp.as_role('service_role', format('select public.heavy_finish(%s, %L, %L, %L)::text', j1, 'done', E'Site page built:\n hero, services,   booking', 'https://github.com/thedonnasystem/JARVIS/pull/50'));
  if res not like 'OK:%' then raise exception 'H6 finish: %', res; end if;
  if (select count(*) from public.owner_messages) <> n + 1 then raise exception 'H6 expected exactly one owner message'; end if;
  if not exists (select 1 from public.owner_messages o where o.from_agent = 'jarvis' and o.channel = 'telegram' and o.sent_at is null and not o.needs_decision
                   and o.body like 'Heavy job #' || j1 || ' (site-build) is done: Site page built: hero, services, booking%'
                   and o.body like '%https://github.com/thedonnasystem/JARVIS/pull/50%' and o.body like '%Nothing was merged%') then raise exception 'H6 owner message text'; end if;
  if (select status || '|' || result_summary || '|' || result_link || '|' || (finished_at is not null)::text from fz_heavy.jobs where id = j1)
     <> 'done|Site page built: hero, services, booking|https://github.com/thedonnasystem/JARVIS/pull/50|true' then raise exception 'H6 job result'; end if;
  begin perform public.heavy_finish(j1, 'failed', 'Changed my mind', null); raise exception 'H6 finished twice'; exception when sqlstate '55000' then null; end;
  r := public.heavy_claim('claude-code');
  if (r -> 'job' ->> 'id')::bigint <> j2 or (r ->> 'left_today')::int <> 0 then raise exception 'H6 second claim: %', r; end if;
  perform public.heavy_finish(j2, 'failed', 'The tests could not run in the session');
  if (select count(*) from public.owner_messages) <> n + 2 or not exists (select 1 from public.owner_messages where body like 'Heavy job #' || j2 || ' (qc-review) failed:%') then
    raise exception 'H6 failed job message'; end if;
  j3 := (public.heavy_enqueue('other', 'A third clean job for the daily limit check') ->> 'id')::bigint;
  r := public.heavy_claim();
  if r -> 'job' <> 'null'::jsonb or r ->> 'reason' not like '%daily limit of 2%' then raise exception 'H6 the daily limit did not hold: %', r; end if;
  begin update fz_heavy.settings set max_per_day = 50; raise exception 'H6 the limit can be raised past 5'; exception when check_violation then null; end;

  -- H7 a stale job (the run died) is failed and reported; yesterday's claims do not count today; off stops handing out but a result still lands
  update fz_heavy.jobs set claimed_at = claimed_at - interval '2 days' where id in (j1, j2);
  r := public.heavy_claim();
  if (r -> 'job' ->> 'id')::bigint <> j3 then raise exception 'H7 claim after the day turned: %', r; end if;
  update fz_heavy.jobs set claimed_at = now() - interval '21 hours' where id = j3;
  m := (public.heavy_enqueue('other', 'A fourth clean job behind the stale one') ->> 'id')::bigint;
  n := (select count(*) from public.owner_messages);
  r := public.heavy_claim();
  if (select status from fz_heavy.jobs where id = j3) <> 'failed' or (select count(*) from public.owner_messages) <> n + 1 then raise exception 'H7 stale job not failed and reported'; end if;
  if (r -> 'job' ->> 'id')::bigint <> m then raise exception 'H7 the queue did not move on: %', r; end if;
  perform public.heavy_set_enabled(false);
  perform public.heavy_finish(m, 'done', 'Finished after the switch went off', 'https://github.com/thedonnasystem/jarvis/pull/7');
  if (select status from fz_heavy.jobs where id = m) <> 'done' then raise exception 'H7 a result was lost while off'; end if;
  begin perform public.heavy_enqueue('other', 'A clean job while the bridge is off'); raise exception 'H7 enqueued while off'; exception when sqlstate '55000' then null; end;

  -- H8 the audit trail names ids and kinds only
  if not exists (select 1 from public.audit_log where action = 'heavy_enqueue' and target = j1::text and actor = 'owner')
     or not exists (select 1 from public.audit_log where action = 'heavy_claim' and target = j1::text)
     or not exists (select 1 from public.audit_log where action = 'heavy_finish' and target = j1::text)
     or not exists (select 1 from public.audit_log where action = 'heavy_stale' and target = j3::text)
     or not exists (select 1 from public.audit_log where action = 'heavy_cancel') then raise exception 'H8 audit rows missing'; end if;
  if exists (select 1 from public.audit_log where action like 'heavy_%' and (detail::text like '%hero%' or detail::text like '%Site page%' or detail::text like '%booking%')) then
    raise exception 'H8 job text in the audit trail'; end if;
end $$;
-- H9 rollback (twice) and re-apply: money controls identical, jobs kept and restored
create temp table hb_rows as select count(*) as n from fz_heavy.jobs;
\ir ../ops/rollback_heavy_bridge.sql
\ir ../ops/rollback_heavy_bridge.sql
create temp table hb_fp_without as select * from pg_temp.fz_money_fp();
do $$
begin
  if exists (select 1 from pg_proc where pronamespace = 'public'::regnamespace and proname ~ '^heavy_') or to_regnamespace('fz_heavy') is not null then
    raise exception 'H9 the rollback left functions or the live schema behind'; end if;
  if (select count(*) from fz_heavy_archive.jobs) <> (select n from hb_rows) or (select n from hb_rows) < 13 then raise exception 'H9 the rollback lost jobs'; end if;
  if has_schema_privilege('service_role', 'fz_heavy_archive', 'usage') or has_schema_privilege('anon', 'fz_heavy_archive', 'usage') then raise exception 'H9 the archive is reachable'; end if;
  if not exists (select 1 from public.audit_log where action = 'heavy_bridge_archived') then raise exception 'H9 the rollback is not audited'; end if;
  if exists (select 1 from hb_fp_with w full join hb_fp_without o using (k) where w.v is distinct from o.v) then raise exception 'H9 the money controls differ with and without'; end if;
end $$;
\ir ../migrations/20261208_heavy_bridge_v1.sql
\ir ../migrations/20261208_heavy_bridge_v1.sql
create temp table hb_fp_again as select * from pg_temp.fz_money_fp();
do $$
begin
  if exists (select 1 from hb_fp_again w full join hb_fp_without o using (k) where w.v is distinct from o.v) then raise exception 'H9 applying changed the money controls'; end if;
  if to_regnamespace('fz_heavy_archive') is not null or (select count(*) from fz_heavy.jobs) <> (select n from hb_rows) then raise exception 'H9 re-apply did not restore the jobs'; end if;
  if (select enabled from fz_heavy.settings) then raise exception 'H9 the switch changed across rollback and re-apply'; end if;
  if not exists (select 1 from pg_constraint where conrelid = 'fz_heavy.jobs'::regclass and conname = 'jobs_text_clean') then raise exception 'H9 the text check did not come back'; end if;
  begin insert into fz_heavy.jobs (kind, title, instructions) values ('other', 'Direct write', 'mail jane.doe@example.com now please'); raise exception 'H9 the table took an e-mail';
  exception when check_violation then null; end;
  if (select count(*) from pg_proc p where p.pronamespace = 'public'::regnamespace and p.proname ~ '^heavy_') <> 10 then raise exception 'H9 functions after re-apply'; end if;
  raise notice 'heavy_bridge_check: all checks passed';
end $$;
rollback;
