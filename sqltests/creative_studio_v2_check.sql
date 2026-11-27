-- FENDEZY AI CREATIVE STUDIO M8c (migrations/20261207_creative_studio_v2.sql). ONE transaction, rolled back. Fresh apply, repo root.
-- Proves: money controls unchanged (with / without / re-applied M8c) under the append-only audit_log + ledger lock; the v2 rollback archives its three tables,
-- drops its functions, leaves v1 working and nothing of v2 behind; no API role reaches the new functions or tables; nothing runs until the studio is registered;
-- templates cannot carry provider / model / price keys or deceptive framing; template, hook and edit inputs are same-office only and a LoRA template needs a
-- character; the v1 router gates still apply to a templated job (premium refused before an open-source QA failure); metrics import is same-office, validated
-- and idempotent (hand actions map through the calendar); ranking is office-scoped with a prior; the owner-only template control.
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
-- one approved generated asset of an office (the v1 path: claim -> free sandbox attempt -> asset -> finish -> owner approval)
create function pg_temp.approved_asset(p_office text, p_module text, p_name text) returns uuid language plpgsql as $$
declare v_job uuid; v_att uuid; v_a uuid;
begin
  v_job := (pg_temp.j(pg_temp.bot(format($q$select public.creative_submit(%L, %L, 'fixture content for the ranking check')::text$q$, p_office, p_module))) ->> 'job')::uuid;
  perform public.creative_claim(v_job);
  v_att := (public.creative_attempt_begin(v_job, 'sandbox', 'sandbox-testsrc', 0) ->> 'attempt')::uuid;
  perform public.creative_attempt_end(v_att, 'ok', 0, null, 1, 10);
  v_a := (public.creative_asset_add(p_office, v_job, 'generated', p_name, p_office || '/jobs/' || p_name || '.mp4', 'video/mp4', 10, repeat('e', 64), '9:16', '{"ai_generated": true}') ->> 'asset')::uuid;
  perform public.creative_finish(v_job, true, 'fixture. AI-generated content.', '{}');
  perform public.creative_owner_decide(v_job, true, 'fixture');
  return v_a;
end $$;

create or replace function public.fz_append_only_record() returns trigger language plpgsql set search_path to 'pg_catalog' as $$
begin raise exception '% is append-only', tg_relname using errcode = '42501'; end $$;
drop trigger if exists audit_log_append_only on public.audit_log;
create trigger audit_log_append_only before update or delete on public.audit_log for each row execute function public.fz_append_only_record();
drop trigger if exists ledger_append_only on public.ledger;
create trigger ledger_append_only before update or delete on public.ledger for each row execute function public.fz_append_only_record();

\ir include/money_fingerprint.sql
insert into auth.users (id, email) values ('99999999-9999-9999-9999-99999999c509', 'fzc2-owner@example.invalid') on conflict do nothing;
insert into public.app_owners (email) values ('fzc2-owner@example.invalid') on conflict do nothing;
select set_config('app.uid', '99999999-9999-9999-9999-99999999c509', true);

-- V1 money controls unchanged: with M8c == after its rollback (twice) == after re-applying it; the three tables archived with rows; v1 intact; nothing left behind
\set fz_in_txn 1
create temp table fzc2_rows0 as select (select count(*) from fz_creative.templates) t;
create temp table fzc2_fp_with as select * from pg_temp.fz_money_fp();
create temp table fzc2_ex0 as select count(*) n from public.audit_log where action = 'creative_studio_v2_export';
\ir ../ops/rollback_creative_studio_v2.sql
\ir ../ops/rollback_creative_studio_v2.sql
create temp table fzc2_fp_without as select * from pg_temp.fz_money_fp();
do $$
begin
  if to_regclass('fz_creative.templates') is not null or to_regclass('fz_creative.job_templates') is not null or to_regclass('fz_creative.platform_metrics') is not null
     or exists (select 1 from pg_proc where proname in ('creative_templates', 'creative_job_set_template', 'creative_job_template', 'creative_metrics_import', 'creative_rank', 'creative_owner_set_template')) then
    raise exception 'V1 the rollback left M8c objects behind'; end if;
  if to_regprocedure('public.creative_submit(text,text,text,text,text[],uuid,uuid,uuid,text)') is null or to_regclass('fz_creative.jobs') is null then raise exception 'V1 the v2 rollback touched v1'; end if;
  if (select t from fzc2_rows0) <> (select count(*) from fz_archive.creative_templates) or (select t from fzc2_rows0) < 21 then raise exception 'V1 archive rows differ'; end if;
  if (select count(*) from public.audit_log where action = 'creative_studio_v2_export') - (select n from fzc2_ex0) <> 1 then raise exception 'V1 export rows'; end if;
  if exists (select 1 from fz_creative.providers where slug = 'local-edit' and enabled) or exists (select 1 from fz_creative.providers where slug = 'runpod-comfyui' and 'ltx-video' = any (models)) then
    raise exception 'V1 provider rows not restored'; end if;
  if exists (select * from fzc2_fp_with except select * from fzc2_fp_without) or exists (select * from fzc2_fp_without except select * from fzc2_fp_with) then
    raise exception 'V1 money fingerprint changed by the rollback'; end if;
end $$;
\ir ../migrations/20261207_creative_studio_v2.sql
\ir ../migrations/20261207_creative_studio_v2.sql
do $$
begin
  if exists (select * from fzc2_fp_with except select * from pg_temp.fz_money_fp()) or exists (select * from pg_temp.fz_money_fp() except select * from fzc2_fp_with) then
    raise exception 'V1 money fingerprint changed by the re-apply'; end if;
  if (select count(*) from fz_creative.templates) <> 21 then raise exception 'V1 templates %', (select count(*) from fz_creative.templates); end if;
  if exists (select 1 from fz_creative.providers where enabled) then raise exception 'V1 providers must be seeded OFF'; end if;
  if exists (select 1 from fz_creative.providers where kind = 'serverless' and models && array['flux.1-dev', 'flux.1-dev-lora', 'hunyuanvideo-1.5']) then
    raise exception 'V1 a non-commercial self-host weight is routable'; end if;
end $$;

-- V2 no API role reaches the new tables or functions
do $$
declare r text; f regprocedure;
begin
  foreach f in array array['public.creative_templates(text,text)'::regprocedure, 'public.creative_job_set_template(uuid,text,text,text,uuid[],text)'::regprocedure,
                           'public.creative_job_template(uuid)'::regprocedure, 'public.creative_metrics_import(text,jsonb,text,text)'::regprocedure,
                           'public.creative_rank(text,text,integer)'::regprocedure, 'public.creative_owner_set_template(text,text,text,text,text,text[],jsonb,text)'::regprocedure] loop
    foreach r in array array['anon', 'authenticated', 'fz_jarvis', 'fz_office_agent', 'fz_auditor', 'backup_reader'] loop
      continue when not exists (select 1 from pg_roles where rolname = r);
      if has_function_privilege(r, f, 'execute') then raise exception 'V2 % can execute %', r, f; end if;
    end loop;
  end loop;
  foreach r in array array['anon', 'authenticated', 'service_role'] loop
    if has_table_privilege(r, 'fz_creative.templates', 'select') or has_table_privilege(r, 'fz_creative.platform_metrics', 'insert') then raise exception 'V2 % reaches a table', r; end if;
  end loop;
  perform pg_temp.expect('V2 anon', pg_temp.as_id('anon', null, $q$select public.creative_rank('the-trap')::text$q$), 'ERR:permission denied%');
  perform pg_temp.expect('V2 authenticated', pg_temp.as_id('authenticated', null, $q$select public.creative_templates('the-trap')::text$q$), 'ERR:permission denied%');
  perform pg_temp.expect('V2 table', pg_temp.svc($q$select count(*)::text from fz_creative.templates$q$), 'ERR:permission denied%');
end $$;

-- V3 nothing runs until the studio is registered; then set up offices and the sandbox
do $$
begin
  perform pg_temp.expect('V3 unregistered', pg_temp.bot($q$select public.creative_templates('the-trap')::text$q$), 'ERR:refused: the creative studio is not registered%');
  insert into public.fz_services (service, title, owner_office, writes, reads, attribution, scoped_identity, modules, note)
    values ('creative_studio', 'FENDEZY AI CREATIVE STUDIO', (select id from public.fz_offices where slug = 'group'), '{hand_actions}', '{}', 'derived', 'jarvis', 'hq_creative_studio.py', 'sqltest');
  perform pg_temp.expect('V3 dormant office', pg_temp.bot($q$select public.creative_templates('the-trap')::text$q$), 'ERR:refused: office the-trap is not active%');
  perform public.fz_owner_set_office_status('the-trap', 'active');
  perform public.fz_owner_set_office_status('b2b-records', 'active');
  perform public.fz_owner_set_office_status('ff-marketing', 'active');
  update fz_office_os.fz_office_profiles set manager = 'fzc2 test manager', status = 'active', activated_at = now() where slug in ('the-trap', 'b2b-records', 'ff-marketing');
  perform public.creative_owner_set_provider('sandbox', true);
  perform pg_temp.expect('V3 list', pg_temp.bot($q$select public.creative_templates('the-trap', 'video')::text$q$), 'OK:%trap-turntable%group-short-explainer%');
  if pg_temp.bot($q$select public.creative_templates('the-trap')::text$q$) like '%b2b-cover-art%' then raise exception 'V3 another office''s template is listed'; end if;
end $$;

-- V4 template rules (DB CHECKs + owner only)
do $$
begin
  perform pg_temp.expect('V4 bot', pg_temp.bot($q$select public.creative_owner_set_template('trap-x', 'the-trap', 'image', 'shot', 'An extra still', '{}', '{"prompt": {"base": "x"}}')::text$q$), 'ERR:owner approval required%');
  perform pg_temp.expect('V4 provider key', pg_temp.owner($q$select public.creative_owner_set_template('trap-x', 'the-trap', 'video', 'shot', 'An extra clip', '{}', '{"prompt": {"base": "x"}, "provider": "kling"}')::text$q$), 'ERR:%templates_spec_check%');
  perform pg_temp.expect('V4 price key', pg_temp.owner($q$select public.creative_owner_set_template('trap-x', 'the-trap', 'video', 'shot', 'An extra clip', '{}', '{"prompt": {"base": "x"}, "est_cents": 0}')::text$q$), 'ERR:%templates_spec_check%');
  perform pg_temp.expect('V4 testimonial', pg_temp.owner($q$select public.creative_owner_set_template('trap-x', 'the-trap', 'ugc', 'ugc', 'Customer testimonial', '{}', '{"prompt": {"base": "x"}}')::text$q$), 'ERR:%templates_no_deceptive_framing%');
  perform pg_temp.expect('V4 imitation', pg_temp.owner($q$select public.creative_owner_set_template('trap-x', 'b2b-records', 'music', 'visualizer', 'A beat', '{}', '{"prompt": {"base": "in the style of a famous rapper"}}')::text$q$), 'ERR:%templates_no_deceptive_framing%');
  perform pg_temp.expect('V4 unknown office', pg_temp.owner($q$select public.creative_owner_set_template('trap-x', 'nowhere', 'image', 'shot', 'An extra still', '{}', '{"prompt": {"base": "x"}}')::text$q$), 'ERR:unknown office%');
  perform pg_temp.expect('V4 owner add', pg_temp.owner($q$select public.creative_owner_set_template('trap-x', 'the-trap', 'image', 'shot', 'An extra still', array['drop-reveal'], '{"prompt": {"base": "{product} on concrete"}}')::text$q$), 'OK:%');
  -- the seed never overwrites an owner edit
  perform public.creative_owner_set_template('trap-flat-lay', 'the-trap', 'image', 'product', 'Flat lay (owner edit)', array['drop-reveal'], '{"prompt": {"base": "{product} flat lay"}}');
end $$;
\ir ../migrations/20261207_creative_studio_v2.sql
do $$
begin
  if (select title from fz_creative.templates where slug = 'trap-flat-lay') <> 'Flat lay (owner edit)' then raise exception 'V4 the seed overwrote the owner''s edit'; end if;
end $$;

-- V5 job templates: same office, same module, hook in the template, LoRA templates need a character, edit inputs same office and approved / library only
create temp table fzc2 as select null::uuid job, null::uuid ejob, null::uuid a_trap, null::uuid a_b2b, null::uuid a_trap2, null::uuid a_draft;
do $$
declare v_job uuid; v_ejob uuid; v_a uuid; v_b uuid; v_a2 uuid; v_d uuid; v_att uuid; v_ch uuid;
begin
  v_a := pg_temp.approved_asset('the-trap', 'video', 'trap-clip-a');
  v_a2 := pg_temp.approved_asset('the-trap', 'video', 'trap-clip-b');
  v_b := pg_temp.approved_asset('b2b-records', 'video', 'b2b-clip');
  v_d := (public.creative_asset_add('the-trap', null, 'video_template', 'raw-broll', 'the-trap/library/raw.mp4', 'video/mp4', 10, repeat('f', 64)) ->> 'asset')::uuid;   -- a library upload (draft)
  v_job := (pg_temp.j(pg_temp.bot($q$select public.creative_submit('the-trap', 'video', 'turntable of the black hoodie')::text$q$)) ->> 'job')::uuid;
  perform pg_temp.expect('V5 other office template', pg_temp.bot(format($q$select public.creative_job_set_template(%L, 'b2b-performance-clip')::text$q$, v_job)), 'ERR:refused: template b2b-performance-clip is not available%');
  perform pg_temp.expect('V5 module', pg_temp.bot(format($q$select public.creative_job_set_template(%L, 'trap-product-hero-still')::text$q$, v_job)), 'ERR:refused: template trap-product-hero-still is for image%');
  perform pg_temp.expect('V5 hook', pg_temp.bot(format($q$select public.creative_job_set_template(%L, 'trap-turntable', 'stop-scroll')::text$q$, v_job)), 'ERR:refused: hook stop-scroll is not in%');
  perform pg_temp.expect('V5 deceptive hook text', pg_temp.bot(format($q$select public.creative_job_set_template(%L, 'trap-turntable', 'drop-reveal', 'Real customer says wow')::text$q$, v_job)), 'ERR:%job_templates_hook_text_check%');
  perform pg_temp.expect('V5 ok', pg_temp.bot(format($q$select public.creative_job_set_template(%L, 'trap-turntable', 'drop-reveal', 'New drop: the black hoodie')::text$q$, v_job)), 'OK:%trap-turntable%');
  perform pg_temp.expect('V5 group template', pg_temp.bot(format($q$select public.creative_job_set_template(%L, 'group-short-explainer', 'pov', null, '{}', 'explore')::text$q$, v_job)), 'OK:%');
  perform pg_temp.expect('V5 read', pg_temp.bot(format($q$select public.creative_job_template(%L)::text$q$, v_job)), 'OK:%"template": "group-short-explainer"%"chosen_by": "explore"%');
  -- LoRA template without a character
  perform pg_temp.expect('V5 lora', pg_temp.bot(format($q$select public.creative_job_set_template(%L, 'b2b-performance-clip')::text$q$,
                         (pg_temp.j(pg_temp.bot($q$select public.creative_submit('b2b-records', 'video', 'performance clip of our artist')::text$q$)) ->> 'job'))), 'ERR:refused: template b2b-performance-clip needs a registered character%');
  -- edit inputs
  v_ejob := (pg_temp.j(pg_temp.bot($q$select public.creative_submit('the-trap', 'edit', 'hyper motion beat cut of the hoodie clips')::text$q$)) ->> 'job')::uuid;
  perform pg_temp.expect('V5 edit without inputs', pg_temp.bot(format($q$select public.creative_job_set_template(%L, 'trap-hyper-motion-edit')::text$q$, v_ejob)), 'ERR:refused: an edit job needs input clips%');
  perform pg_temp.expect('V5 other office input', pg_temp.bot(format($q$select public.creative_job_set_template(%L, 'trap-hyper-motion-edit', null, null, array[%L, %L]::uuid[])::text$q$, v_ejob, v_a, v_b)), 'ERR:refused: every input must be%');
  perform pg_temp.expect('V5 unknown input', pg_temp.bot(format($q$select public.creative_job_set_template(%L, 'trap-hyper-motion-edit', null, null, array[%L]::uuid[])::text$q$, v_ejob, gen_random_uuid())), 'ERR:refused: every input must be%');
  perform pg_temp.expect('V5 edit ok', pg_temp.bot(format($q$select public.creative_job_set_template(%L, 'trap-hyper-motion-edit', 'countdown', null, array[%L, %L, %L]::uuid[])::text$q$, v_ejob, v_a, v_a2, v_d)), 'OK:%');
  perform pg_temp.expect('V5 inputs read', pg_temp.bot(format($q$select public.creative_job_template(%L)::text$q$, v_ejob)), 'OK:%trap-clip-a%trap-clip-b%raw-broll%');
  -- a rejected generated asset is not an input
  update fz_creative.assets set status = 'rejected' where id = v_a2;
  perform pg_temp.expect('V5 rejected input', pg_temp.bot(format($q$select public.creative_job_set_template(%L, 'trap-hyper-motion-edit', null, null, array[%L]::uuid[])::text$q$, v_ejob, v_a2)), 'ERR:refused: every input must be%');
  update fz_creative.assets set status = 'approved' where id = v_a2;
  -- the v1 router gates still apply to a templated job: premium before an open-source QA failure is refused; local-edit only when the owner enabled it
  perform public.creative_owner_set_provider('kling', true);
  perform public.creative_owner_set_office('the-trap', true);
  perform public.creative_claim(v_job);
  perform pg_temp.expect('V5 premium gate', pg_temp.bot(format($q$select public.creative_attempt_begin(%L, 'kling', 'kling-3.0', 150)::text$q$, v_job)), 'ERR:refused: premium is used only after QA failed%');
  perform public.creative_claim(v_ejob);
  perform pg_temp.expect('V5 local-edit off', pg_temp.bot(format($q$select public.creative_attempt_begin(%L, 'local-edit', 'ffmpeg-edit', 0)::text$q$, v_ejob)), 'ERR:refused: provider local-edit is not enabled%');
  perform public.creative_owner_set_provider('local-edit', true);
  v_att := (pg_temp.j(pg_temp.bot(format($q$select public.creative_attempt_begin(%L, 'local-edit', 'ffmpeg-edit', 0)::text$q$, v_ejob))) ->> 'attempt')::uuid;
  perform pg_temp.expect('V5 paid local edit refused', pg_temp.bot(format($q$select public.creative_attempt_end(%L, 'ok', 5, null, 1, 10)::text$q$, v_att)), 'ERR:refused: a paid attempt must name%');
  perform public.creative_attempt_end(v_att, 'ok', 0, null, 1, 10);
  perform pg_temp.expect('V5 after a passing attempt', pg_temp.bot(format($q$select public.creative_job_set_template(%L, 'ffm-broll-stitch')::text$q$, v_ejob)), 'ERR:refused:%');
  update fzc2 set job = v_job, ejob = v_ejob, a_trap = v_a, a_b2b = v_b, a_trap2 = v_a2, a_draft = v_d;
end $$;

-- V6 metrics import: same office, validated, idempotent; hand actions map through the calendar
do $$
declare r jsonb; v_a uuid := (select a_trap from fzc2); v_a2 uuid := (select a_trap2 from fzc2); v_b uuid := (select a_b2b from fzc2); v_hand uuid := gen_random_uuid(); v_acct uuid;
begin
  -- tag the two trap assets' jobs with templates / hooks (ranking groups by them)
  insert into fz_creative.job_templates (job_id, office_id, template_slug, hook_id, chosen_by)
    select a.job_id, a.office_id, x.t, x.h, 'request' from fz_creative.assets a join (values (v_a, 'trap-turntable', 'drop-reveal'), (v_a2, 'trap-unboxing-ugc', 'pov')) x(id, t, h) on x.id = a.id
    on conflict (job_id) do update set template_slug = excluded.template_slug, hook_id = excluded.hook_id;
  update fz_creative.jobs set module = 'ugc' where id = (select job_id from fz_creative.assets where id = v_a2);
  insert into fz_creative.calendar (office_id, slug, job_id, asset_id, connector, account_id, scheduled_at, caption, hand_action_id, status)
    select office_id, slug, job_id, id, 'tiktok', gen_random_uuid(), now(), 'post. AI-generated content.', v_hand, 'drafted' from fz_creative.assets where id = v_a2;
  r := pg_temp.j(pg_temp.bot(format($q$select public.creative_metrics_import('the-trap', %L::jsonb, 'manual', 'export-2026-11.csv')::text$q$, jsonb_build_array(
         jsonb_build_object('asset', v_a, 'connector', 'tiktok', 'metric', 'views', 'value', 1000, 'window_end', '2026-11-20'),
         jsonb_build_object('asset', v_a, 'connector', 'tiktok', 'metric', 'likes', 'value', 80, 'window_end', '2026-11-20'),
         jsonb_build_object('asset', v_a, 'connector', 'tiktok', 'metric', 'leads', 'value', 2, 'window_end', '2026-11-20'),
         jsonb_build_object('asset', v_b, 'connector', 'tiktok', 'metric', 'views', 'value', 5, 'window_end', '2026-11-20'),
         jsonb_build_object('asset', v_a, 'connector', 'tiktok', 'metric', 'vibes', 'value', 5, 'window_end', '2026-11-20'),
         jsonb_build_object('asset', v_a, 'connector', 'tiktok', 'metric', 'completion_rate', 'value', 1.5, 'window_end', '2026-11-20'),
         jsonb_build_object('asset', v_a, 'connector', 'tiktok', 'metric', 'likes', 'value', -1, 'window_end', '2026-11-20'),
         jsonb_build_object('hand_action', v_hand, 'connector', 'tiktok', 'metric', 'views', 'value', 2000, 'window_end', '2026-11-20'),
         jsonb_build_object('hand_action', v_hand, 'connector', 'tiktok', 'metric', 'likes', 'value', 40, 'window_end', '2026-11-20'),
         jsonb_build_object('hand_action', gen_random_uuid(), 'connector', 'tiktok', 'metric', 'views', 'value', 9, 'window_end', '2026-11-20')))));
  if r is null or (r ->> 'inserted')::int <> 5 or jsonb_array_length(r -> 'rejected') <> 5 then raise exception 'V6 import %', r; end if;
  if exists (select 1 from fz_creative.platform_metrics where asset_id = v_b) then raise exception 'V6 another office''s asset was written'; end if;
  -- idempotent: the same window again updates
  r := public.creative_metrics_import('the-trap', jsonb_build_array(jsonb_build_object('asset', v_a, 'connector', 'tiktok', 'metric', 'likes', 'value', 90, 'window_end', '2026-11-20')), 'manual');
  if (r ->> 'updated')::int <> 1 or (select value from fz_creative.platform_metrics where asset_id = v_a and metric = 'likes') <> 90 then raise exception 'V6 re-import %', r; end if;
  perform pg_temp.expect('V6 bad source', pg_temp.bot($q$select public.creative_metrics_import('the-trap', '[]', 'scraper')::text$q$), 'ERR:bad source%');
  perform pg_temp.expect('V6 too many', pg_temp.bot(format($q$select public.creative_metrics_import('the-trap', %L::jsonb, 'manual')::text$q$, (select jsonb_agg('{}'::jsonb) from generate_series(1, 501)))), 'ERR:refused: rows must be%');
  perform pg_temp.expect('V6 scoped', pg_temp.as_id('authenticated', null, $q$select public.creative_metrics_import('the-trap', '[]', 'manual')::text$q$), 'ERR:permission denied%');
end $$;

-- V7 ranking: office-scoped; Bayesian average per template / hook; feeds reuse
do $$
declare r jsonb;
begin
  r := pg_temp.j(pg_temp.bot($q$select public.creative_rank('the-trap')::text$q$));
  -- trap-clip-a: 1000*(90 + 40 leads*... ) / 1000 views -> higher than trap-clip-b (40 likes / 2000 views)
  if r is null or jsonb_array_length(r -> 'assets') <> 2 or (r -> 'assets' -> 0 ->> 'asset')::uuid is distinct from (select a_trap from fzc2) then raise exception 'V7 assets %', r; end if;
  if r -> 'templates' -> 0 ->> 'template' <> 'trap-turntable' or r -> 'hooks' -> 0 ->> 'hook' <> 'drop-reveal' then raise exception 'V7 order %', r; end if;
  if (r -> 'templates' -> 0 ->> 'rank_score')::numeric >= (r -> 'templates' -> 0 ->> 'avg')::numeric then raise exception 'V7 the prior must pull a single post towards the mean %', r; end if;
  r := pg_temp.j(pg_temp.bot($q$select public.creative_rank('the-trap', 'ugc')::text$q$));
  if jsonb_array_length(r -> 'assets') <> 1 then raise exception 'V7 module filter %', r; end if;
  r := pg_temp.j(pg_temp.bot($q$select public.creative_rank('b2b-records')::text$q$));
  if jsonb_array_length(r -> 'assets') <> 0 then raise exception 'V7 office leak %', r; end if;
  perform pg_temp.expect('V7 scoped', pg_temp.as_id('authenticated', null, $q$select public.creative_rank('the-trap')::text$q$), 'ERR:permission denied%');
end $$;

-- V8 dormant office: the new writes refuse; the audit lock is still held
do $$
begin
  perform public.fz_owner_set_office_status('the-trap', 'dormant');
  perform pg_temp.expect('V8 dormant import', pg_temp.bot($q$select public.creative_metrics_import('the-trap', '[]', 'manual')::text$q$), 'ERR:refused: office the-trap is not active%');
  perform pg_temp.expect('V8 dormant template', pg_temp.bot(format($q$select public.creative_job_set_template(%L, 'trap-turntable')::text$q$, (select job from fzc2))), 'ERR:refused:%');
  if not exists (select 1 from pg_trigger where tgname = 'audit_log_append_only' and tgrelid = 'public.audit_log'::regclass) then raise exception 'V8 lock missing'; end if;
end $$;
select 'creative_studio_v2_check ok';
rollback;
