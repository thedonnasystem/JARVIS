-- FENDEZY GROUP: "Heavy bridge" (Nov 23 2026). ADDITIVE. Needs nothing newer than the Phase 1 base (audit_log, owner_messages, system_state, agents).
-- Design (docs/architecture/HEAVY_BRIDGE.md): a small private queue of heavy jobs (build a site, fix an office, review quality, research) that the
-- Chairman hands to a SCHEDULED Claude Code session running on his own Claude subscription (claude.ai/code scheduled task, Anthropic's own product).
-- Jarvis never holds, sees or routes a Claude subscription credential: the bot only writes rows here; the scheduled session reads them with the
-- Chairman's own Supabase connector. The bridge is OFF until the Chairman switches it on (/heavy on), and one switch turns it off (/heavy off).
--   * fz_heavy.jobs: one row per job. kind: site-build | office-fix | qc-review | research | other. status: queued | claimed | done | failed | cancelled.
--     Never deleted. No client data, contacts, keys or personal info: heavy_text_problem() refuses e-mail addresses, phone numbers and anything that
--     looks like a secret, in the title, the instructions AND the result summary (checked again by a table constraint).
--   * fz_heavy.settings: one row. enabled (default FALSE) and max_per_day (default 2: protects the Chairman's weekly Claude limits).
--   * The schema fz_heavy has NO privilege for any API role; only the functions below reach it. So it is outside the public table registry and the
--     off-site export. Functions: service key (the bot) and database sessions (the Chairman's SQL editor / his Supabase connector) only; anon,
--     authenticated, the scoped fz roles and the backup identity are refused by grant AND in the body.
--   * Who may add a job: the bot calls heavy_enqueue ONLY from the owner-only /heavy command (hq_heavy.py; pinned by test_hq_heavy.py). No agent tool,
--     office or scoped token can reach it. A job is a task description, never a permission: the runner prompt (docs/heavy_bridge/RUNNER_PROMPT.md)
--     forbids merging, deploying, production migrations, spending, external messages and changing any safeguard, whatever a job says.
--   * heavy_claim hands out ONE job per call, never while the kill switch is on, never while another job is in progress, at most max_per_day per day
--     (America/Toronto). heavy_finish stores a one-line summary + the pull-request link and queues ONE owner message as Jarvis (the existing
--     owner_messages path), held to 17:00 on weekdays 08:00-17:00 like every non-urgent message.
-- No change to caps, the kill switch, mode, the spend gateway, authorize_action, executors, the table registry, backup classification or any money
-- control (sqltests/heavy_bridge_check.sql proves the money fingerprint is identical with it, without it and after a re-apply).
-- Function names avoid the fz_ prefix (the M1 rollback drill asserts no public fz_* survives it).
-- Ordered BEFORE the lockdown (R3). Rollback: ops/rollback_heavy_bridge.sql (moves the schema to fz_heavy_archive; a re-apply restores it). Safe to re-run.

set lock_timeout = '5s';

do $$
begin
  if to_regnamespace('fz_heavy') is null and to_regnamespace('fz_heavy_archive') is not null then
    alter schema fz_heavy_archive rename to fz_heavy;                      -- re-apply after a rollback: the kept jobs come back
  end if;
end $$;
create schema if not exists fz_heavy;
revoke all on schema fz_heavy from public;
do $$ declare r text; begin
  foreach r in array array['anon', 'authenticated', 'service_role', 'fz_jarvis', 'fz_office_agent', 'fz_auditor', 'backup_reader'] loop
    if exists (select 1 from pg_roles where rolname = r) then execute format('revoke all on schema fz_heavy from %I', r); end if;
  end loop;
end $$;

-- ---------------------------------------------------------------------------------------------------------------------------- validation
-- NULL when the text is clean; otherwise what was found (never the text itself). Best effort, fail closed: a false alarm only asks the Chairman to
-- reword. E-mail addresses (also "name (at) domain"), phone numbers (North American 3-3-4 with or without separators, +international), known key
-- prefixes, "password: ..." style pairs, private-key blocks, and long random-looking strings.
create or replace function public.heavy_text_problem(p_text text) returns text
language plpgsql immutable set search_path to 'pg_catalog' as $$
declare t text := coalesce(p_text, '');
begin
  if t ~* '[a-z0-9._%+-]+@[a-z0-9-]+(\.[a-z0-9-]+)+' or t ~* '[a-z0-9._%+-]+\s*[\[(]\s*at\s*[\])]\s*[a-z0-9-]+' then return 'an e-mail address'; end if;
  if t ~ '(^|[^0-9A-Za-z_/#.-])(\+?1[ .-]?)?\(?[0-9]{3}\)?[ .-]?[0-9]{3}[ .-]?[0-9]{4}([^0-9A-Za-z_-]|$)' or t ~ '\+[0-9][0-9 ().-]{7,}[0-9]' then return 'a phone number'; end if;
  if t ~ '(sk-[A-Za-z0-9_-]{16,}|sk_(live|test)_|rk_(live|test)_|pk_live_|gh[pousr]_[A-Za-z0-9]{20,}|github_pat_|xox[abprs]-|AKIA[0-9A-Z]{16}|AIza[0-9A-Za-z_-]{30,}|sbp_[a-f0-9]{20,}|sb_secret_|eyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}|-----BEGIN|[0-9]{8,10}:[A-Za-z0-9_-]{30,})'
     or t ~* '(password|passwd|pwd|secret|token|api[ _-]?key)\s*[:=]\s*[^[:space:]]{6,}' or t ~* 'bearer\s+[a-z0-9._~+/=-]{20,}' then return 'something that looks like a key or password'; end if;
  if exists (select 1 from regexp_matches(t, '[A-Za-z0-9_-]{40,}', 'g') m where m[1] ~ '[0-9]' and m[1] ~ '[A-Za-z]')
     or exists (select 1 from regexp_matches(t, '[A-Za-z0-9+/]{40,}', 'g') m where m[1] ~ '[0-9]' and m[1] ~ '[A-Z]' and m[1] ~ '[a-z]') then
    return 'a long random-looking string (possible key)'; end if;
  return null;
end $$;
revoke all on function public.heavy_text_problem(text) from public, anon, authenticated;

-- ---------------------------------------------------------------------------------------------------------------------------- tables
create table if not exists fz_heavy.settings (
  id integer primary key default 1 check (id = 1),
  enabled boolean not null default false,                                 -- THE switch. Off: nothing can be added, nothing is handed out.
  max_per_day integer not null default 2 check (max_per_day between 1 and 5),
  updated_at timestamptz not null default now(),
  updated_by text not null default 'migration' check (length(updated_by) <= 60)
);
insert into fz_heavy.settings (id) values (1) on conflict (id) do nothing;

create table if not exists fz_heavy.jobs (
  id bigint generated always as identity primary key,
  created_at timestamptz not null default now(),
  kind text not null check (kind in ('site-build', 'office-fix', 'qc-review', 'research', 'other')),
  title text not null check (length(title) between 3 and 120),
  instructions text not null check (length(instructions) between 10 and 4000),
  status text not null default 'queued' check (status in ('queued', 'claimed', 'done', 'failed', 'cancelled')),
  result_summary text check (result_summary is null or length(result_summary) between 3 and 300),
  result_link text check (result_link is null or result_link ~ '^https://github\.com/thedonnasystem/(JARVIS|jarvis)/pull/[0-9]{1,6}$'),
  claimed_at timestamptz,
  claimed_by text check (claimed_by is null or claimed_by ~ '^[a-z0-9][a-z0-9._-]{0,39}$'),
  finished_at timestamptz,
  check (status <> 'done' or result_link is not null)
);
create index if not exists jobs_open on fz_heavy.jobs (created_at) where status in ('queued', 'claimed');
-- Second layer: the table itself refuses contact details and secrets, whoever writes the row. Added by name so a re-apply after a rollback (which
-- removes it with the check function, keeping the rows) puts it back.
do $$
begin
  if not exists (select 1 from pg_constraint where conrelid = 'fz_heavy.jobs'::regclass and conname = 'jobs_text_clean') then
    alter table fz_heavy.jobs add constraint jobs_text_clean check (public.heavy_text_problem(title) is null and public.heavy_text_problem(instructions) is null
                                                                    and (result_summary is null or public.heavy_text_problem(result_summary) is null));
  end if;
end $$;

do $$
declare t text; r text;
begin
  foreach t in array array['settings', 'jobs'] loop
    execute format('alter table fz_heavy.%I enable row level security', t);
    execute format('revoke all on fz_heavy.%I from public', t);
    foreach r in array array['anon', 'authenticated', 'service_role', 'fz_jarvis', 'fz_office_agent', 'fz_auditor', 'backup_reader'] loop
      if exists (select 1 from pg_roles where rolname = r) then execute format('revoke all on fz_heavy.%I from %I', t, r); end if;
    end loop;
  end loop;
end $$;
revoke all on sequence fz_heavy.jobs_id_seq from public;

-- ---------------------------------------------------------------------------------------------------------------------------- helpers
-- Who may call: the bot (service key) and database sessions. Anyone else (anon, a signed-in app user, a scoped office / jarvis / auditor token,
-- the backup identity) is refused here, whatever a later grant says. The SESSION role is read (a SECURITY DEFINER caller does not change it).
create or replace function public.heavy_guard() returns void
language plpgsql stable security definer set search_path to 'pg_catalog' as $$
begin
  if coalesce(nullif(current_setting('role', true), ''), 'none') not in ('service_role', 'none', 'postgres') then
    raise exception 'heavy bridge: the bot and database sessions only' using errcode = '42501';
  end if;
end $$;
revoke all on function public.heavy_guard() from public, anon, authenticated;

create or replace function public.heavy_job_json(p_id bigint, p_full boolean default false) returns jsonb
language sql stable security definer set search_path to 'pg_catalog' as $$
  select jsonb_build_object('id', j.id, 'kind', j.kind, 'title', j.title, 'status', j.status, 'created_at', j.created_at, 'claimed_at', j.claimed_at,
                            'finished_at', j.finished_at, 'result_summary', j.result_summary, 'result_link', j.result_link)
         || case when p_full then jsonb_build_object('instructions', j.instructions) else '{}'::jsonb end
    from fz_heavy.jobs j where j.id = p_id
$$;
revoke all on function public.heavy_job_json(bigint, boolean) from public, anon, authenticated;

-- ---------------------------------------------------------------------------------------------------------------------------- the switch
create or replace function public.heavy_set_enabled(p_on boolean) returns jsonb
language plpgsql security definer set search_path to 'pg_catalog' as $$
begin
  perform public.heavy_guard();
  if p_on is null then raise exception 'heavy bridge: on or off' using errcode = '22023'; end if;
  update fz_heavy.settings set enabled = p_on, updated_at = now(), updated_by = 'owner' where id = 1 and enabled is distinct from p_on;
  if found then
    insert into public.audit_log (actor, action, target, detail) values ('owner', 'heavy_bridge_switch', 'fz_heavy.settings', jsonb_build_object('enabled', p_on));
  end if;
  return jsonb_build_object('enabled', p_on);
end $$;
revoke all on function public.heavy_set_enabled(boolean) from public, anon, authenticated;

-- ---------------------------------------------------------------------------------------------------------------------------- owner: add / cancel / list
-- Called by the bot ONLY from the owner-only /heavy command. Refused while the bridge is off, with more than 10 jobs waiting, or with text that
-- carries an e-mail address, a phone number or anything that looks like a secret. The audit row carries the id and kind only, never the text.
create or replace function public.heavy_enqueue(p_kind text, p_instructions text, p_title text default null) returns jsonb
language plpgsql security definer set search_path to 'pg_catalog' as $$
declare v_ins text := btrim(coalesce(p_instructions, '')); v_title text; v_bad text; v_id bigint;
begin
  perform public.heavy_guard();
  if not (select s.enabled from fz_heavy.settings s where s.id = 1) then
    raise exception 'heavy bridge: it is switched off (the Chairman turns it on with /heavy on)' using errcode = '55000'; end if;
  if p_kind is null or p_kind not in ('site-build', 'office-fix', 'qc-review', 'research', 'other') then
    raise exception 'heavy bridge: kind must be one of site-build, office-fix, qc-review, research, other' using errcode = '22023'; end if;
  if length(v_ins) < 10 or length(v_ins) > 4000 then raise exception 'heavy bridge: instructions need 10 to 4000 characters' using errcode = '22023'; end if;
  v_title := btrim(left(coalesce(nullif(btrim(p_title), ''), regexp_replace(split_part(v_ins, E'\n', 1), '\s+', ' ', 'g')), 120));
  if length(v_title) < 3 then raise exception 'heavy bridge: the first line of the instructions is too short to be a title' using errcode = '22023'; end if;
  v_bad := coalesce(public.heavy_text_problem(v_ins), public.heavy_text_problem(v_title));
  if v_bad is not null then
    raise exception 'heavy bridge: refused, the text contains %. Jobs never carry client data, contacts, keys or personal info', v_bad using errcode = '22023'; end if;
  if (select count(*) from fz_heavy.jobs j where j.status = 'queued') >= 10 then
    raise exception 'heavy bridge: 10 jobs are already waiting; cancel one first' using errcode = '55000'; end if;
  insert into fz_heavy.jobs (kind, title, instructions) values (p_kind, v_title, v_ins) returning id into v_id;
  insert into public.audit_log (actor, action, target, detail) values ('owner', 'heavy_enqueue', v_id::text, jsonb_build_object('kind', p_kind));
  return public.heavy_job_json(v_id);
end $$;
revoke all on function public.heavy_enqueue(text, text, text) from public, anon, authenticated;

create or replace function public.heavy_cancel(p_id bigint) returns jsonb
language plpgsql security definer set search_path to 'pg_catalog' as $$
declare v_status text;
begin
  perform public.heavy_guard();
  select j.status into v_status from fz_heavy.jobs j where j.id = p_id for update;
  if v_status is null then raise exception 'heavy bridge: no job %', p_id using errcode = '22023'; end if;
  if v_status <> 'queued' then
    raise exception 'heavy bridge: job % is % and can no longer be cancelled (a job in progress ends with a pull request you can close)', p_id, v_status using errcode = '55000'; end if;
  update fz_heavy.jobs set status = 'cancelled', finished_at = now() where id = p_id;
  insert into public.audit_log (actor, action, target, detail) values ('owner', 'heavy_cancel', p_id::text, '{}'::jsonb);
  return public.heavy_job_json(p_id);
end $$;
revoke all on function public.heavy_cancel(bigint) from public, anon, authenticated;

create or replace function public.heavy_list(p_limit integer default 10) returns jsonb
language plpgsql stable security definer set search_path to 'pg_catalog' as $$
declare v jsonb;
begin
  perform public.heavy_guard();
  select jsonb_build_object(
    'enabled', s.enabled, 'max_per_day', s.max_per_day,
    'queued', (select count(*) from fz_heavy.jobs j where j.status = 'queued'),
    'claimed', (select count(*) from fz_heavy.jobs j where j.status = 'claimed'),
    'jobs', coalesce((select jsonb_agg(public.heavy_job_json(x.id) order by x.id desc)
                        from (select j.id from fz_heavy.jobs j order by (j.status in ('queued', 'claimed')) desc, j.id desc
                               limit least(greatest(coalesce(p_limit, 10), 1), 50)) x), '[]'::jsonb))
    into v from fz_heavy.settings s where s.id = 1;
  return v;
end $$;
revoke all on function public.heavy_list(integer) from public, anon, authenticated;

-- ---------------------------------------------------------------------------------------------------------------------------- runner: claim / finish
-- Queue ONE owner message as Jarvis through the existing owner_messages path. Weekdays 08:00-17:00 America/Toronto (the Chairman's day job) it is
-- held to 17:00; the delivery job itself holds everything but emergencies overnight.
create or replace function public.heavy_tell_owner(p_body text) returns void
language plpgsql security definer set search_path to 'pg_catalog' as $$
declare v_local timestamp := now() at time zone 'America/Toronto'; v_after timestamptz;
begin
  perform public.heavy_guard();
  if extract(isodow from v_local) < 6 and extract(hour from v_local) >= 8 and extract(hour from v_local) < 17 then
    v_after := (date_trunc('day', v_local) + interval '17 hours') at time zone 'America/Toronto';
  end if;
  insert into public.owner_messages (from_agent, kind, channel, body, deliver_after) values ('jarvis', 'health', 'telegram', left(p_body, 3000), v_after);
end $$;
revoke all on function public.heavy_tell_owner(text) from public, anon, authenticated;

-- Hands out the oldest waiting job, or none with the reason. One job per call; the runner calls again after heavy_finish.
create or replace function public.heavy_claim(p_runner text default 'claude-code') returns jsonb
language plpgsql security definer set search_path to 'pg_catalog' as $$
declare s record; r record; v_id bigint; v_today integer;
        v_day timestamptz := date_trunc('day', now() at time zone 'America/Toronto') at time zone 'America/Toronto';
begin
  perform public.heavy_guard();
  if p_runner is null or p_runner !~ '^[a-z0-9][a-z0-9._-]{0,39}$' then raise exception 'heavy bridge: bad runner name' using errcode = '22023'; end if;
  select * into s from fz_heavy.settings where id = 1 for update;         -- serialises concurrent runners
  if not s.enabled then return jsonb_build_object('job', null, 'reason', 'the heavy bridge is switched off'); end if;
  if coalesce((select st.kill_switch from public.system_state st where st.id = 1), true) then
    return jsonb_build_object('job', null, 'reason', 'the kill switch is on'); end if;
  for r in select j.id, j.kind from fz_heavy.jobs j where j.status = 'claimed' and j.claimed_at < now() - interval '20 hours' for update loop
    update fz_heavy.jobs set status = 'failed', finished_at = now(), result_summary = 'No result was reported within 20 hours of the start' where id = r.id;
    insert into public.audit_log (actor, action, target, detail) values ('heavy-bridge', 'heavy_stale', r.id::text, jsonb_build_object('kind', r.kind));
    perform public.heavy_tell_owner(format('Heavy job #%s (%s) did not report back within 20 hours, so it is marked failed. Nothing was merged. Send /heavy list for the queue.', r.id, r.kind));
  end loop;
  if exists (select 1 from fz_heavy.jobs j where j.status = 'claimed') then
    return jsonb_build_object('job', null, 'reason', 'another job is still in progress'); end if;
  select count(*) into v_today from fz_heavy.jobs j where j.claimed_at >= v_day;
  if v_today >= s.max_per_day then
    return jsonb_build_object('job', null, 'reason', format('the daily limit of %s jobs is reached', s.max_per_day)); end if;
  select j.id into v_id from fz_heavy.jobs j where j.status = 'queued' order by j.id limit 1 for update skip locked;
  if v_id is null then return jsonb_build_object('job', null, 'reason', 'nothing is queued'); end if;
  update fz_heavy.jobs set status = 'claimed', claimed_at = now(), claimed_by = p_runner where id = v_id;
  insert into public.audit_log (actor, action, target, detail) values ('heavy-bridge', 'heavy_claim', v_id::text, jsonb_build_object('runner', p_runner));
  return jsonb_build_object('job', public.heavy_job_json(v_id, true), 'reason', null, 'left_today', s.max_per_day - v_today - 1);
end $$;
revoke all on function public.heavy_claim(text) from public, anon, authenticated;

-- The runner reports back: done (needs the pull-request link) or failed. One line of summary, checked like the instructions. Works while the bridge
-- is off too, so a result is never lost. Tells the Chairman once, as Jarvis.
create or replace function public.heavy_finish(p_id bigint, p_status text, p_summary text, p_link text default null) returns jsonb
language plpgsql security definer set search_path to 'pg_catalog' as $$
declare v_status text; v_kind text; v_sum text := btrim(regexp_replace(coalesce(p_summary, ''), '\s+', ' ', 'g')); v_link text := nullif(btrim(coalesce(p_link, '')), ''); v_bad text;
begin
  perform public.heavy_guard();
  if p_status is null or p_status not in ('done', 'failed') then raise exception 'heavy bridge: status must be done or failed' using errcode = '22023'; end if;
  select j.status, j.kind into v_status, v_kind from fz_heavy.jobs j where j.id = p_id for update;
  if v_status is null then raise exception 'heavy bridge: no job %', p_id using errcode = '22023'; end if;
  if v_status <> 'claimed' then raise exception 'heavy bridge: job % is %, not in progress', p_id, v_status using errcode = '55000'; end if;
  if length(v_sum) < 3 or length(v_sum) > 300 then raise exception 'heavy bridge: the summary needs 3 to 300 characters (one line)' using errcode = '22023'; end if;
  v_bad := public.heavy_text_problem(v_sum);
  if v_bad is not null then raise exception 'heavy bridge: refused, the summary contains %', v_bad using errcode = '22023'; end if;
  if v_link is not null and v_link !~ '^https://github\.com/thedonnasystem/(JARVIS|jarvis)/pull/[0-9]{1,6}$' then
    raise exception 'heavy bridge: the link must be a pull request in thedonnasystem/JARVIS' using errcode = '22023'; end if;
  if p_status = 'done' and v_link is null then raise exception 'heavy bridge: a finished job needs its pull-request link' using errcode = '22023'; end if;
  update fz_heavy.jobs set status = p_status, finished_at = now(), result_summary = v_sum, result_link = v_link where id = p_id;
  insert into public.audit_log (actor, action, target, detail) values ('heavy-bridge', 'heavy_finish', p_id::text, jsonb_build_object('status', p_status, 'kind', v_kind));
  perform public.heavy_tell_owner(
    case when p_status = 'done' then format(E'Heavy job #%s (%s) is done: %s\n%s\nNothing was merged: the pull request waits for your review.', p_id, v_kind, v_sum, v_link)
         else format('Heavy job #%s (%s) failed: %s', p_id, v_kind, v_sum) || coalesce(E'\n' || v_link, '') end);
  return public.heavy_job_json(p_id);
end $$;
revoke all on function public.heavy_finish(bigint, text, text, text) from public, anon, authenticated;
