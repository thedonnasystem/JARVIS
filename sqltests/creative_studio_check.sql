-- FENDEZY AI CREATIVE STUDIO M8a (migrations/20261205_creative_studio_v1.sql). ONE transaction, rolled back. Fresh apply, repo root.
-- Proves: money controls unchanged (with / without / re-applied M8a) under the append-only audit_log + ledger lock; the rollback archives every table and leaves
-- nothing behind; no API role reaches fz_creative; nothing runs until the studio is registered (fz_services) and the office is active; dormant offices are refused;
-- owner-only controls; router gates (provider enabled, model registered, retry limit, open attempt, premium only after an open-source QA failure + owner permission,
-- hero tier direct premium only with the office preset AND the owner's permission, optional weekly creative limit); a paid attempt needs an office-attributed
-- spend-gate reservation; office asset isolation; AI label + disclosure; consent for real likenesses; owner approval before the calendar; manual import; report.
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
create function pg_temp.cl(p_identity text, p_role text) returns jsonb language sql as $$
  select jsonb_build_object('role', p_role, 'identity', p_identity, 'iat', floor(extract(epoch from now())), 'exp', floor(extract(epoch from now())) + 3600)
$$;
-- the bot: the service key (simulated as a db session without the owner: service_role has no BYPASSRLS here), or service_role itself
create function pg_temp.bot(p_sql text) returns text language plpgsql as $$
declare r text; u text := current_setting('app.uid', true);
begin
  perform set_config('app.uid', '', true);
  begin execute p_sql into r; exception when others then perform set_config('app.uid', coalesce(u, ''), true); return 'ERR:' || sqlerrm; end;
  perform set_config('app.uid', coalesce(u, ''), true);
  return 'OK:' || coalesce(r, '');
end $$;
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
create function pg_temp.owner(p_sql text) returns text language plpgsql as $$
declare r text;
begin
  begin execute p_sql into r; exception when others then return 'ERR:' || sqlerrm; end;
  return 'OK:' || coalesce(r, '');
end $$;
create function pg_temp.j(p text) returns jsonb language sql as $$ select case when p like 'OK:%' then substr(p, 4)::jsonb end $$;
create function pg_temp.expect(p_tag text, p_got text, p_like text) returns void language plpgsql as $$
begin
  if p_got is null or p_got not like p_like then raise exception '% expected [%] got [%]', p_tag, p_like, p_got; end if;
end $$;

-- the production lock (owner proposal audit_ledger_append_only): audit_log and ledger are append-only; this migration and its rollback only INSERT
create or replace function public.fz_append_only_record() returns trigger language plpgsql set search_path to 'pg_catalog' as $$
begin raise exception '% is append-only', tg_relname using errcode = '42501'; end $$;
drop trigger if exists audit_log_append_only on public.audit_log;
create trigger audit_log_append_only before update or delete on public.audit_log for each row execute function public.fz_append_only_record();
drop trigger if exists ledger_append_only on public.ledger;
create trigger ledger_append_only before update or delete on public.ledger for each row execute function public.fz_append_only_record();

\ir include/money_fingerprint.sql
insert into auth.users (id, email) values ('99999999-9999-9999-9999-99999999c508', 'fzc-owner@example.invalid') on conflict do nothing;
insert into public.app_owners (email) values ('fzc-owner@example.invalid') on conflict do nothing;
select set_config('app.uid', '99999999-9999-9999-9999-99999999c508', true);

-- C1 money controls unchanged: with M8a == after its rollback (twice) == after re-applying it; every table archived with its rows; nothing left behind
\set fz_in_txn 1
select public.creative_owner_set_brand_kit('group', '{"tone": "confident", "dont": ["guaranteed results"]}');
select public.creative_owner_set_provider('sandbox', true);
create temp table fzc_rows0 as select (select count(*) from fz_creative.providers) p, (select count(*) from fz_creative.brand_kits) b, (select count(*) from fz_creative.presets) s;
create temp table fzc_fp_with as select * from pg_temp.fz_money_fp();
create temp table fzc_ex0 as select count(*) n from public.audit_log where action = 'creative_studio_export';
\ir ../ops/rollback_creative_studio.sql
\ir ../ops/rollback_creative_studio.sql
create temp table fzc_fp_without as select * from pg_temp.fz_money_fp();
do $$
begin
  if to_regnamespace('fz_creative') is not null or exists (select 1 from pg_proc where proname like 'creative\_%') then raise exception 'C1 the rollback left M8a objects behind'; end if;
  if (select (p, b, s)::text from fzc_rows0) is distinct from ((select count(*) from fz_archive.creative_providers), (select count(*) from fz_archive.creative_brand_kits),
                                                              (select count(*) from fz_archive.creative_presets))::text then raise exception 'C1 archive rows differ'; end if;
  if (select count(*) from public.audit_log where action = 'creative_studio_export') - (select n from fzc_ex0) <> 1 then raise exception 'C1 export rows'; end if;
  if exists (select * from fzc_fp_with except select * from fzc_fp_without) or exists (select * from fzc_fp_without except select * from fzc_fp_with) then
    raise exception 'C1 money fingerprint changed by the rollback'; end if;
end $$;
\ir ../migrations/20261205_creative_studio_v1.sql
\ir ../migrations/20261205_creative_studio_v1.sql
do $$
begin
  if exists (select * from fzc_fp_with except select * from pg_temp.fz_money_fp()) or exists (select * from pg_temp.fz_money_fp() except select * from fzc_fp_with) then
    raise exception 'C1 money fingerprint changed by the re-apply'; end if;
  if (select count(*) from fz_creative.providers) <> 12 or exists (select 1 from fz_creative.providers where enabled) then raise exception 'C1 providers must be seeded OFF'; end if;
  if (select count(*) from fz_creative.presets) <> 10 then raise exception 'C1 presets %', (select count(*) from fz_creative.presets); end if;
  if exists (select 1 from fz_creative.providers where kind = 'premium' and est_cents = 0) then raise exception 'C1 a premium provider estimated free'; end if;
end $$;

-- C2 no API role reaches fz_creative or the creative_* functions (service_role only through the definer functions it is granted)
do $$
declare r text; f regprocedure;
begin
  foreach r in array array['anon', 'authenticated', 'service_role', 'fz_jarvis', 'fz_office_agent', 'fz_auditor'] loop
    continue when not exists (select 1 from pg_roles where rolname = r);
    if has_schema_privilege(r, 'fz_creative', 'usage') then raise exception 'C2 % has usage on fz_creative', r; end if;
  end loop;
  for f in select p.oid::regprocedure from pg_proc p where p.pronamespace = 'public'::regnamespace and p.proname like 'creative\_%' loop
    foreach r in array array['anon', 'authenticated', 'fz_jarvis', 'fz_office_agent', 'fz_auditor', 'backup_reader'] loop
      continue when not exists (select 1 from pg_roles where rolname = r);
      if has_function_privilege(r, f, 'execute') then raise exception 'C2 % can execute %', r, f; end if;
    end loop;
  end loop;
  for f in select p.oid::regprocedure from pg_proc p where p.pronamespace = 'fz_creative'::regnamespace loop
    if has_function_privilege('service_role', f, 'execute') then raise exception 'C2 service_role can execute the private %', f; end if;
  end loop;
  perform pg_temp.expect('C2 anon', pg_temp.as_id('anon', null, $q$select public.creative_report()::text$q$), 'ERR:permission denied%');
  perform pg_temp.expect('C2 table', pg_temp.svc($q$select count(*)::text from fz_creative.jobs$q$), 'ERR:permission denied%');
end $$;

-- C3 nothing runs until the studio is registered + active; C4 a dormant office is refused
do $$
begin
  perform pg_temp.expect('C3 unregistered', pg_temp.bot($q$select public.creative_submit('the-trap', 'image', 'a product photo of the new hoodie')::text$q$), 'ERR:refused: the creative studio is not registered%');
  insert into public.fz_services (service, title, owner_office, writes, reads, attribution, scoped_identity, modules, note)
    values ('creative_studio', 'FENDEZY AI CREATIVE STUDIO', (select id from public.fz_offices where slug = 'group'), '{hand_actions}', '{}', 'derived', 'jarvis', 'hq_creative_studio.py', 'sqltest');
  perform pg_temp.expect('C4 dormant', pg_temp.bot($q$select public.creative_submit('the-trap', 'image', 'a product photo of the new hoodie')::text$q$), 'ERR:refused: office the-trap is not active%');
  -- M1 active but the M7 profile dormant: still refused
  perform public.fz_owner_set_office_status('the-trap', 'active');
  perform pg_temp.expect('C4 profile dormant', pg_temp.bot($q$select public.creative_submit('the-trap', 'image', 'a product photo of the new hoodie')::text$q$), 'ERR:refused: office the-trap is not active%');
  update fz_office_os.fz_office_profiles set manager = 'fzc test manager', status = 'active', activated_at = now() where slug in ('the-trap', 'ff-marketing', 'pimp-ai');
  perform public.fz_owner_set_office_status('ff-marketing', 'active');
  perform public.fz_owner_set_office_status('pimp-ai', 'active');
  update public.fz_services set status = 'dormant' where service = 'creative_studio';
  perform pg_temp.expect('C3 dormant service', pg_temp.bot($q$select public.creative_submit('the-trap', 'image', 'a product photo of the new hoodie')::text$q$), 'ERR:refused: the creative studio is not registered or not active%');
  update public.fz_services set status = 'active' where service = 'creative_studio';
  perform pg_temp.expect('C2 authenticated owner', pg_temp.as_id('authenticated', null, $q$select public.creative_submit('the-trap', 'image', 'a product photo of the new hoodie')::text$q$), 'ERR:permission denied%');
end $$;

-- C5 owner-only controls
do $$
declare q text;
begin
  foreach q in array array[$q$select public.creative_owner_set_provider('veo', true)::text$q$, $q$select public.creative_owner_set_office('the-trap', true)::text$q$,
                           $q$select public.creative_owner_set_brand_kit('the-trap', '{}')::text$q$, $q$select public.creative_owner_record_consent('the-trap', 'Model A', 'ads', 'signed form ref 1')::text$q$,
                           $q$select public.creative_owner_set_preset('the-trap', 'image', 'hero', '{}', true)::text$q$,
                           $q$select public.creative_owner_add_character('pimp-ai', 'nova', 'nova_char', false)::text$q$,
                           $q$select public.creative_owner_import('the-trap', 'graphic', 'x', 'the-trap/x.png', 'image/png', 1, repeat('a', 64), 'higgsfield', 100, true)::text$q$] loop
    perform pg_temp.expect('C5 bot ' || q, pg_temp.bot(q), 'ERR:owner approval required%');
  end loop;
  if (select count(*) from fz_creative.office_settings) <> 0 or exists (select 1 from fz_creative.providers where enabled and slug <> 'sandbox') then raise exception 'C5 a bot write landed'; end if;
  perform pg_temp.expect('C5 bad kit key', pg_temp.owner($q$select public.creative_owner_set_brand_kit('the-trap', '{"secret": 1}')::text$q$), 'ERR:%brand_kits_kit_check%');
end $$;

-- C6 router gates and C7 retries (sandbox + a paid open provider + premium)
create temp table fzc as select null::uuid job, null::uuid att, null::uuid job2, null::uuid job3, null::uuid res_trap, null::uuid res_ffm, null::uuid asset;
do $$
declare v_job uuid; v_att uuid; r text;
begin
  perform public.creative_owner_set_provider('runpod-comfyui', true);
  perform public.creative_owner_set_provider('sandbox', true);
  v_job := (pg_temp.j(pg_temp.bot($q$select public.creative_submit('the-trap', 'video', 'a 10 second product video of the new hoodie', 'standard', array['9:16', '1:1'])::text$q$)) ->> 'job')::uuid;
  update fzc set job = v_job;
  perform pg_temp.expect('C6 attempt before claim', pg_temp.bot(format($q$select public.creative_attempt_begin(%L, 'runpod-comfyui', 'wan-2.2-ti2v-5b', 40)::text$q$, v_job)), 'ERR:refused: job is queued%');
  perform pg_temp.expect('C6 claim', pg_temp.bot(format($q$select public.creative_claim(%L)::text$q$, v_job)), 'OK:%"providers": [{"kind": "local", "slug": "sandbox"%"slug": "runpod-comfyui"%');
  perform pg_temp.expect('C6 claim twice', pg_temp.bot(format($q$select public.creative_claim(%L)::text$q$, v_job)), 'ERR:refused: job is running%');
  perform pg_temp.expect('C6 disabled provider', pg_temp.bot(format($q$select public.creative_attempt_begin(%L, 'fal-hosted', 'wan-2.2', 40)::text$q$, v_job)), 'ERR:refused: provider fal-hosted is not enabled%');
  perform pg_temp.expect('C6 wrong module', pg_temp.bot(format($q$select public.creative_attempt_begin(%L, 'copy-llm', 'hq_llm', 0)::text$q$, v_job)), 'ERR:refused: provider copy-llm is not enabled%');
  perform pg_temp.expect('C6 unregistered model', pg_temp.bot(format($q$select public.creative_attempt_begin(%L, 'runpod-comfyui', 'some-model', 40)::text$q$, v_job)), 'ERR:refused: model some-model is not registered%');
  perform pg_temp.expect('C6 no estimate', pg_temp.bot(format($q$select public.creative_attempt_begin(%L, 'runpod-comfyui', 'wan-2.2-ti2v-5b', null)::text$q$, v_job)), 'ERR:refused: an estimate is required%');
  perform public.creative_owner_set_provider('kling', true);
  perform pg_temp.expect('C6 premium not allowed', pg_temp.bot(format($q$select public.creative_attempt_begin(%L, 'kling', 'kling-3.0', 150)::text$q$, v_job)), 'ERR:refused: premium provider kling is not allowed%');
  perform public.creative_owner_allow_premium(v_job);
  perform pg_temp.expect('C6 premium before QA failure', pg_temp.bot(format($q$select public.creative_attempt_begin(%L, 'kling', 'kling-3.0', 150)::text$q$, v_job)), 'ERR:refused: premium is used only after QA failed%');
  r := pg_temp.bot(format($q$select public.creative_attempt_begin(%L, 'sandbox', 'sandbox-testsrc', 0)::text$q$, v_job));
  perform pg_temp.expect('C6 open attempt', r, 'OK:%"n": 1%');
  v_att := (pg_temp.j(r) ->> 'attempt')::uuid;
  perform pg_temp.expect('C7 attempt still open', pg_temp.bot(format($q$select public.creative_attempt_begin(%L, 'sandbox', 'sandbox-testsrc', 0)::text$q$, v_job)), 'ERR:refused: an attempt is still open%');
  perform pg_temp.expect('C6 premium while open', pg_temp.bot(format($q$select public.creative_finish(%L, true, 'x', '{}')::text$q$, v_job)), 'ERR:refused: an attempt is still open%');
  perform pg_temp.expect('C6 bad outcome', pg_temp.bot(format($q$select public.creative_attempt_end(%L, 'great', 0, null, 0.2, 10)::text$q$, v_att)), 'ERR:bad outcome%');
  perform pg_temp.expect('C6 no actual', pg_temp.bot(format($q$select public.creative_attempt_end(%L, 'qa_failed', null, null, 0.2, 10)::text$q$, v_att)), 'ERR:refused: the actual cost is required%');
  perform pg_temp.expect('C6 end', pg_temp.bot(format($q$select public.creative_attempt_end(%L, 'qa_failed', 0, null, 0.2, 10)::text$q$, v_att)), 'OK:%qa_failed%');
  perform pg_temp.expect('C6 end twice', pg_temp.bot(format($q$select public.creative_attempt_end(%L, 'ok', 0, null, 0.9, 10)::text$q$, v_att)), 'ERR:refused: attempt already ended%');
  -- open-source QA failed + owner allowed premium for this job -> premium may run
  r := pg_temp.bot(format($q$select public.creative_attempt_begin(%L, 'kling', 'kling-3.0', 150)::text$q$, v_job));
  perform pg_temp.expect('C6 premium after QA failure', r, 'OK:%"kind": "premium"%');
  update fzc set att = (pg_temp.j(r) ->> 'attempt')::uuid;
end $$;

-- C8 money: a paid attempt needs a spend-gate reservation attributed to the SAME office
do $$
declare v_att uuid := (select att from fzc); v_r1 uuid; v_r2 uuid; r jsonb;
begin
  -- the REAL office gate (M2 -> reserve_spend) on funded, active offices; it stamps fz_money_attribution itself
  perform public.fz_owner_allocate('the-trap', 10000, 'creative check');
  perform public.fz_owner_allocate('ff-marketing', 10000, 'creative check');
  update public.system_state set mode = 'auto_in_caps', kill_switch = false where id = 1;
  r := public.fz_reserve_office_spend('the-trap', 'creative_studio', 'routine_expense', 'kling', 'creative check', 'proves the gate', 'open models failed QA', 100);
  if r ->> 'decision' is distinct from 'allow' then raise exception 'C8 fixture reservation %', r; end if;
  v_r1 := (r ->> 'reservation_id')::uuid;
  r := public.fz_reserve_office_spend('ff-marketing', 'creative_studio', 'routine_expense', 'kling', 'creative check', 'proves the gate', 'none', 100);
  if r ->> 'decision' is distinct from 'allow' then raise exception 'C8 fixture reservation 2 %', r; end if;
  v_r2 := (r ->> 'reservation_id')::uuid;
  update public.system_state set mode = 'dry_run' where id = 1;
  perform pg_temp.expect('C8 paid without reservation', pg_temp.bot(format($q$select public.creative_attempt_end(%L, 'ok', 90, null, 0.9, 10)::text$q$, v_att)), 'ERR:refused: a paid attempt must name%');
  perform pg_temp.expect('C8 unknown reservation', pg_temp.bot(format($q$select public.creative_attempt_end(%L, 'ok', 90, gen_random_uuid(), 0.9, 10)::text$q$, v_att)), 'ERR:refused: a paid attempt must name%');
  perform pg_temp.expect('C8 other office reservation', pg_temp.bot(format($q$select public.creative_attempt_end(%L, 'ok', 90, %L, 0.9, 10)::text$q$, v_att, v_r2)), 'ERR:refused: a paid attempt must name%');
  perform pg_temp.expect('C8 own reservation', pg_temp.bot(format($q$select public.creative_attempt_end(%L, 'ok', 90, %L, 0.9, 10)::text$q$, v_att, v_r1)), 'OK:%');
  if (select (actual_cents, reservation_id)::text from fz_creative.attempts where id = v_att) is distinct from (90, v_r1)::text then raise exception 'C8 cost not recorded'; end if;
  update fzc set res_trap = v_r1, res_ffm = v_r2;
end $$;

-- C7 retry limit (office max_attempts 2)
do $$
declare v_job uuid := (select job from fzc);
begin
  perform public.creative_owner_set_office('the-trap', false, null, 2);
  perform pg_temp.expect('C7 retry limit', pg_temp.bot(format($q$select public.creative_attempt_begin(%L, 'sandbox', 'sandbox-testsrc', 0)::text$q$, v_job)), 'ERR:refused: retry limit reached (2 attempts)%');
  update fz_creative.office_settings set max_attempts = 5;
  perform pg_temp.expect('C7 ceiling', pg_temp.bot(format($q$select public.creative_attempt_begin(%L, 'sandbox', 'sandbox-testsrc', 0)::text$q$, v_job)), 'OK:%"n": 3%');
  perform public.creative_attempt_end((select id from fz_creative.attempts where job_id = v_job and n = 3), 'ok', 0, null, 0.95, 5);
end $$;

-- C6b hero tier: direct premium only when the office preset says so AND the owner allowed premium for the office
do $$
declare v_job uuid; v_t uuid;
begin
  v_job := (pg_temp.j(pg_temp.bot($q$select public.creative_submit('ff-marketing', 'video', 'hero commercial for the spring campaign', 'hero')::text$q$)) ->> 'job')::uuid;
  perform public.creative_claim(v_job);
  perform pg_temp.expect('C6b hero without office permission', pg_temp.bot(format($q$select public.creative_attempt_begin(%L, 'kling', 'kling-3.0', 150)::text$q$, v_job)), 'ERR:refused: premium provider kling is not allowed%');
  perform public.creative_owner_set_office('ff-marketing', true);
  perform pg_temp.expect('C6b hero direct premium', pg_temp.bot(format($q$select public.creative_attempt_begin(%L, 'kling', 'kling-3.0', 150)::text$q$, v_job)), 'OK:%premium%');
  -- the same office, a non-hero job: escalate only after QA
  v_t := (pg_temp.j(pg_temp.bot($q$select public.creative_submit('ff-marketing', 'video', 'variation of the spring commercial', 'high')::text$q$)) ->> 'job')::uuid;
  perform public.creative_claim(v_t);
  perform pg_temp.expect('C6b non-hero', pg_temp.bot(format($q$select public.creative_attempt_begin(%L, 'kling', 'kling-3.0', 150)::text$q$, v_t)), 'ERR:refused: premium is used only after QA failed%');
  -- an open-source attempt that ERRORED (or passed) is not a QA failure: premium stays closed
  perform public.creative_attempt_begin(v_t, 'sandbox', 'sandbox-testsrc', 0);
  perform public.creative_attempt_end((select id from fz_creative.attempts where job_id = v_t and outcome = 'open'), 'error', 0, null, null, 1, 'timeout');
  perform pg_temp.expect('C6b error is not a QA failure', pg_temp.bot(format($q$select public.creative_attempt_begin(%L, 'kling', 'kling-3.0', 150)::text$q$, v_t)), 'ERR:refused: premium is used only after QA failed%');
  -- hero in an office whose preset does not say hero_premium (the-trap video), even with the office allowing premium
  perform public.creative_owner_set_office('the-trap', true, null, 3);
  v_t := (pg_temp.j(pg_temp.bot($q$select public.creative_submit('the-trap', 'video', 'hero product film for the hoodie', 'hero')::text$q$)) ->> 'job')::uuid;
  perform public.creative_claim(v_t);
  perform pg_temp.expect('C6b preset says no', pg_temp.bot(format($q$select public.creative_attempt_begin(%L, 'kling', 'kling-3.0', 150)::text$q$, v_t)), 'ERR:refused: premium is used only after QA failed%');
  perform public.creative_owner_set_office('the-trap', false, null, 3);
end $$;

-- C9 optional weekly creative limit (default none)
do $$
declare v_job uuid;
begin
  v_job := (pg_temp.j(pg_temp.bot($q$select public.creative_submit('the-trap', 'image', 'product still of the hoodie on white')::text$q$)) ->> 'job')::uuid;
  perform public.creative_claim(v_job);
  perform public.creative_owner_set_office('the-trap', false, 100, 3);
  perform pg_temp.expect('C9 over limit', pg_temp.bot(format($q$select public.creative_attempt_begin(%L, 'runpod-comfyui', 'flux.1-schnell', 11)::text$q$, v_job)), 'ERR:refused: over the owner-set weekly creative limit for the-trap (90 + 11 > 100)%');
  perform pg_temp.expect('C9 under limit', pg_temp.bot(format($q$select public.creative_attempt_begin(%L, 'runpod-comfyui', 'flux.1-schnell', 10)::text$q$, v_job)), 'OK:%');
  perform public.creative_attempt_end((select id from fz_creative.attempts where job_id = v_job), 'error', 0, null, null, 3, 'endpoint timeout');
  perform public.creative_owner_set_office('the-trap', false, null, 3);
  perform pg_temp.expect('C9 no limit', pg_temp.bot(format($q$select public.creative_attempt_begin(%L, 'runpod-comfyui', 'flux.1-schnell', 500)::text$q$, v_job)), 'OK:%');
  perform public.creative_attempt_end((select id from fz_creative.attempts where job_id = v_job and outcome = 'open'), 'error', 0, null, null, 3);
end $$;

-- C10 office asset isolation, AI label; C11 disclosure, owner approval, calendar via hands, performance, reuse
do $$
declare v_job uuid := (select job from fzc); v_a uuid; v_h uuid; v_e uuid; r text; v_ffm uuid;
begin
  perform pg_temp.expect('C10 other office path', pg_temp.bot(format($q$select public.creative_asset_add('the-trap', %L, 'generated', 'hoodie-916', 'ff-marketing/x.mp4', 'video/mp4', 10, %L, '9:16', '{"ai_generated": true}')::text$q$, v_job, repeat('a', 64))), 'ERR:refused: asset path must be under the-trap/%');
  perform pg_temp.expect('C10 traversal', pg_temp.bot(format($q$select public.creative_asset_add('the-trap', %L, 'generated', 'hoodie-916', 'the-trap/../ff-marketing/x.mp4', 'video/mp4', 10, %L, '9:16', '{"ai_generated": true}')::text$q$, v_job, repeat('a', 64))), 'ERR:%assets_path_check%');
  perform pg_temp.expect('C10 other office job', pg_temp.bot(format($q$select public.creative_asset_add('ff-marketing', %L, 'generated', 'hoodie-916', 'ff-marketing/x.mp4', 'video/mp4', 10, %L, '9:16', '{"ai_generated": true}')::text$q$, v_job, repeat('a', 64))), 'ERR:refused: job belongs to another office%');
  perform pg_temp.expect('C10 no AI label', pg_temp.bot(format($q$select public.creative_asset_add('the-trap', %L, 'generated', 'hoodie-916', 'the-trap/j/hoodie-916.mp4', 'video/mp4', 10, %L, '9:16', '{}')::text$q$, v_job, repeat('a', 64))), 'ERR:refused: a generated asset must carry ai_generated = true%');
  r := pg_temp.bot(format($q$select public.creative_asset_add('the-trap', %L, 'generated', 'hoodie-916', 'the-trap/j/hoodie-916.mp4', 'video/mp4', 10, %L, '9:16', '{"ai_generated": true}')::text$q$, v_job, repeat('a', 64)));
  perform pg_temp.expect('C10 add', r, 'OK:%"version": 1%');
  v_a := (pg_temp.j(r) ->> 'asset')::uuid;
  perform pg_temp.expect('C10 version 2', pg_temp.bot(format($q$select public.creative_asset_add('the-trap', %L, 'generated', 'hoodie-916', 'the-trap/j/hoodie-916-v2.mp4', 'video/mp4', 11, %L, '9:16', '{"ai_generated": true}')::text$q$, v_job, repeat('b', 64))), 'OK:%"version": 2%');
  if (select previous_id from fz_creative.assets where slug = 'the-trap' and name = 'hoodie-916' and version = 2) is distinct from v_a then raise exception 'C10 version history'; end if;
  -- ff-marketing sees nothing of the-trap, and a scoped identity cannot call the read at all
  if pg_temp.j(pg_temp.bot($q$select public.creative_assets('ff-marketing')::text$q$)) <> '[]'::jsonb then raise exception 'C10 ff-marketing sees another office''s assets'; end if;
  if jsonb_array_length(pg_temp.j(pg_temp.bot($q$select public.creative_assets('the-trap')::text$q$))) <> 2 then raise exception 'C10 the-trap assets'; end if;
  if exists (select 1 from pg_roles where rolname = 'fz_office_agent') then
    perform pg_temp.expect('C10 scoped', pg_temp.as_id('fz_office_agent', pg_temp.cl('office:ff-marketing:manager', 'fz_office_agent'), $q$select public.creative_assets('the-trap')::text$q$), 'ERR:permission denied%');
    -- even with a mistaken grant, a scoped identity reads its own office only
    grant execute on function public.creative_assets(text, boolean, integer) to fz_office_agent;
    perform public.fz_owner_set_identity('office:ff-marketing:manager', 'active');
    perform pg_temp.expect('C10 scoped other office', pg_temp.as_id('fz_office_agent', pg_temp.cl('office:ff-marketing:manager', 'fz_office_agent'), $q$select public.creative_assets('the-trap')::text$q$), 'ERR:refused: a scoped identity reads its own%');
    perform pg_temp.expect('C10 scoped own office', pg_temp.as_id('fz_office_agent', pg_temp.cl('office:ff-marketing:manager', 'fz_office_agent'), $q$select public.creative_assets('ff-marketing')::text$q$), 'OK:[]');
    revoke execute on function public.creative_assets(text, boolean, integer) from fz_office_agent;
  end if;
  -- QA verdict: the caption must carry the disclosure; then the job waits for the owner
  perform pg_temp.expect('C11 no disclosure', pg_temp.bot(format($q$select public.creative_finish(%L, true, 'New hoodie drop', '{}')::text$q$, v_job)), 'ERR:refused: the caption must carry the AI-generated disclosure%');
  perform pg_temp.expect('C11 finish', pg_temp.bot(format($q$select public.creative_finish(%L, true, 'New hoodie drop. AI-generated content.', '{"score": 0.95}')::text$q$, v_job)), 'OK:%awaiting_approval%');
  perform pg_temp.expect('C11 calendar before approval', pg_temp.bot(format($q$select public.creative_calendar_add(%L, 'tiktok', gen_random_uuid(), now() + interval '1 day', 'Drop. AI-generated content.')::text$q$, v_a)), 'ERR:refused: only an owner-approved%');
  perform pg_temp.expect('C11 bot approves', pg_temp.bot(format($q$select public.creative_owner_decide(%L, true)::text$q$, v_job)), 'ERR:owner approval required%');
  perform pg_temp.expect('C11 owner approves', pg_temp.owner(format($q$select public.creative_owner_decide(%L, true, 'good')::text$q$, v_job)), 'OK:%approved%');
  if exists (select 1 from fz_creative.assets where job_id = v_job and status <> 'approved') then raise exception 'C11 assets not approved with the job'; end if;
  perform pg_temp.expect('C11 calendar without disclosure', pg_temp.bot(format($q$select public.creative_calendar_add(%L, 'tiktok', gen_random_uuid(), now() + interval '1 day', 'Drop')::text$q$, v_a)), 'ERR:refused: the post must carry%');
  v_e := (pg_temp.j(pg_temp.bot(format($q$select public.creative_calendar_add(%L, 'tiktok', gen_random_uuid(), now() + interval '1 day', 'Drop. AI-generated content.')::text$q$, v_a))) ->> 'entry')::uuid;
  perform pg_temp.expect('C11 unknown hands draft', pg_temp.bot(format($q$select public.creative_calendar_link(%L, gen_random_uuid())::text$q$, v_e)), 'ERR:refused: unknown hands draft%');
  insert into public.hand_actions (connector, division, action, payload) values ('tiktok', 'ffm', 'post', '{"caption": "Drop. AI-generated content."}') returning id into v_h;
  perform pg_temp.expect('C11 link', pg_temp.bot(format($q$select public.creative_calendar_link(%L, %L)::text$q$, v_e, v_h)), 'OK:%drafted%');
  if (select status from public.hand_actions where id = v_h) <> 'draft' then raise exception 'C11 the studio changed the hands draft'; end if;
  perform pg_temp.expect('C11 perf', pg_temp.bot(format($q$select public.creative_perf_record(%L, 'leads', 3, 'tiktok insights')::text$q$, v_a)), 'OK:%');
  if (select stage from fz_creative.jobs where id = v_job) <> 'analytics' then raise exception 'C11 stage %', (select stage from fz_creative.jobs where id = v_job); end if;
  if (pg_temp.j(pg_temp.bot($q$select public.creative_assets('the-trap', true)::text$q$)) -> 0 ->> 'id')::uuid is distinct from v_a then raise exception 'C11 best asset'; end if;
  -- reuse: own office's approved asset only
  perform pg_temp.expect('C11 reuse other office', pg_temp.bot(format($q$select public.creative_submit('ff-marketing', 'video', 'remix of the hoodie video', 'standard', array['16:9'], null, %L)::text$q$, v_a)), 'ERR:refused: reuse needs an approved asset of the same office%');
  perform pg_temp.expect('C11 reuse', pg_temp.bot(format($q$select public.creative_submit('the-trap', 'video', 'remix of the hoodie video', 'standard', array['16:9'], null, %L)::text$q$, v_a)), 'OK:%queued%');
  update fzc set asset = v_a;
end $$;

-- C12 consent for real likenesses; characters
do $$
declare v_c uuid; v_ch uuid;
begin
  perform pg_temp.expect('C12 unknown consent', pg_temp.bot(format($q$select public.creative_submit('pimp-ai', 'ugc', 'presenter demo of the app', 'high', array['9:16'], %L)::text$q$, gen_random_uuid())), 'ERR:refused: no recorded consent%');
  perform pg_temp.expect('C12 real person without consent', pg_temp.owner($q$select public.creative_owner_add_character('pimp-ai', 'ava', 'ava_char', true)::text$q$), 'ERR:refused: a real person''s likeness needs%');
  perform pg_temp.expect('C12 default is real', pg_temp.owner($q$select public.creative_owner_add_character('pimp-ai', 'ava', 'ava_char', null)::text$q$), 'ERR:refused: a real person''s likeness needs%');
  v_c := (public.creative_owner_record_consent('pimp-ai', 'Model A', 'AI presenter for app ads', 'signed release ref PA-1') ->> 'consent')::uuid;
  perform pg_temp.expect('C12 other office consent', pg_temp.owner(format($q$select public.creative_owner_add_character('the-trap', 'ava', 'ava_char', true, %L)::text$q$, v_c)), 'ERR:refused: a real person''s likeness needs%');
  v_ch := (public.creative_owner_add_character('pimp-ai', 'ava', 'ava_char', true, v_c) ->> 'character')::uuid;
  perform pg_temp.expect('C12 character other office', pg_temp.bot(format($q$select public.creative_submit('the-trap', 'image', 'ava wearing the hoodie', 'high', array['1:1'], null, null, %L)::text$q$, v_ch)), 'ERR:refused: unknown character%');
  update fz_creative.likeness_consents set revoked_at = now() where id = v_c;
  perform pg_temp.expect('C12 revoked consent', pg_temp.bot(format($q$select public.creative_submit('pimp-ai', 'image', 'ava portrait series', 'high', array['1:1'], null, null, %L)::text$q$, v_ch)), 'ERR:refused: unknown character%');
  perform pg_temp.expect('C12 fictional', pg_temp.owner($q$select public.creative_owner_add_character('pimp-ai', 'nova', 'nova_char', false)::text$q$), 'OK:%');
end $$;

-- C13 manual import (any outside tool) with source and cost; the report counts it per office
do $$
declare r jsonb;
begin
  perform pg_temp.expect('C13 no AI answer', pg_temp.owner($q$select public.creative_owner_import('ff-marketing', 'campaign', 'hero-cut', 'ff-marketing/imports/hero.mp4', 'video/mp4', 99, repeat('c', 64), 'higgsfield', 1200, null)::text$q$), 'ERR:refused: say whether%');
  perform pg_temp.expect('C13 wrong office path', pg_temp.owner($q$select public.creative_owner_import('ff-marketing', 'campaign', 'hero-cut', 'the-trap/hero.mp4', 'video/mp4', 99, repeat('c', 64), 'higgsfield', 1200, true)::text$q$), 'ERR:refused: asset path must be under ff-marketing/%');
  perform pg_temp.expect('C13 import', pg_temp.owner($q$select public.creative_owner_import('ff-marketing', 'campaign', 'hero-cut', 'ff-marketing/imports/hero.mp4', 'video/mp4', 99, repeat('c', 64), 'higgsfield', 1200, true)::text$q$), 'OK:%');
  if (select (source, external_cost_cents, status, meta ->> 'ai_generated')::text from fz_creative.assets where name = 'hero-cut') is distinct from ('higgsfield', 1200, 'approved', 'true')::text then raise exception 'C13 import row'; end if;
  r := pg_temp.j(pg_temp.bot($q$select public.creative_report()::text$q$));
  if (select (x ->> 'all_cents')::int from jsonb_array_elements(r -> 'offices') x where x ->> 'office' = 'ff-marketing') is distinct from 1200 then raise exception 'C13 report ff-marketing %', r -> 'offices'; end if;
  if (select (x ->> 'all_cents')::int from jsonb_array_elements(r -> 'offices') x where x ->> 'office' = 'the-trap') is distinct from 90 then raise exception 'C13 report the-trap %', r -> 'offices'; end if;
  if (r ->> 'registered')::boolean is distinct from true or (r -> 'queue' ->> 'approved')::int is distinct from 1 then raise exception 'C13 report %', r; end if;
  perform pg_temp.expect('C13 scoped report', pg_temp.as_id('authenticated', null, $q$select public.creative_report()::text$q$), 'ERR:permission denied%');
end $$;

-- C14 a dormant office again: claim, attempts and asset writes refuse; nothing touched the audit trail except inserts (lock held)
do $$
declare v_job uuid;
begin
  v_job := (pg_temp.j(pg_temp.bot($q$select public.creative_submit('the-trap', 'image', 'one more product still of the hoodie')::text$q$)) ->> 'job')::uuid;
  perform public.fz_owner_set_office_status('the-trap', 'dormant');
  perform pg_temp.expect('C14 claim dormant', pg_temp.bot(format($q$select public.creative_claim(%L)::text$q$, v_job)), 'ERR:refused: office the-trap is not active%');
  perform pg_temp.expect('C14 asset dormant', pg_temp.bot(format($q$select public.creative_asset_add('the-trap', null, 'logo', 'logo', 'the-trap/logo.png', 'image/png', 1, %L)::text$q$, repeat('d', 64))), 'ERR:refused: office the-trap is not active%');
  if not exists (select 1 from pg_trigger where tgname = 'audit_log_append_only' and tgrelid = 'public.audit_log'::regclass) then raise exception 'C14 lock missing'; end if;
end $$;
select 'creative_studio_check ok';
rollback;
