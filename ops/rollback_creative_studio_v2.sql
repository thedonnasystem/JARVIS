-- Rollback of migrations/20261207_creative_studio_v2.sql ONLY (M8c: templates, job templates, platform metrics, ranking). M8a/b (v1) keeps working.
-- Idempotent. Run from the repo root:
--   psql -v ON_ERROR_STOP=1 -f ops/rollback_creative_studio_v2.sql          (one transaction: it opens and commits its own)
-- (sqltests/creative_studio_v2_check.sql sets fz_in_txn and runs it INSIDE its own rolled-back transaction.)
-- 1. ONE audit_log export row (counts); 2. ARCHIVES the three M8c tables, rows intact, into fz_archive (an older archive moves on to fz_archive_<timestamp>);
-- 3. drops the five M8c functions; 4. switches the 'local-edit' provider OFF (the row stays; nothing is deleted) and restores the v1 model list of the two
--    self-hosted ComfyUI slots. Python falls back by itself: without creative_job_template the worker runs jobs without a template (v1 behaviour).
-- Whole studio: ops/rollback_creative_studio.sql (it includes these tables).
\if :{?fz_in_txn}
\else
begin;
\endif
do $$
declare v_suffix text := to_char(clock_timestamp(), 'YYYYMMDDHH24MISSUS'); t text; r text; v_counts jsonb := '{}'::jsonb; n bigint;
begin
  if to_regnamespace('fz_creative') is null or to_regclass('fz_creative.templates') is null then return; end if;
  foreach t in array array['platform_metrics', 'job_templates', 'templates'] loop
    if to_regclass('fz_creative.' || t) is not null then execute format('select count(*) from fz_creative.%I', t) into n; v_counts := v_counts || jsonb_build_object(t, n); end if;
  end loop;
  insert into public.audit_log (actor, action, target, detail) values ('rollback', 'creative_studio_v2_export', 'fz_creative', v_counts);
  create schema if not exists fz_archive;
  revoke all on schema fz_archive from public;
  foreach r in array array['anon', 'authenticated', 'service_role'] loop
    if exists (select 1 from pg_roles where rolname = r) then execute format('revoke all on schema fz_archive from %I', r); end if;
  end loop;
  foreach t in array array['platform_metrics', 'job_templates', 'templates'] loop
    continue when to_regclass('fz_creative.' || t) is null;
    if to_regclass('fz_archive.creative_' || t) is not null then
      execute format('create schema if not exists %I', 'fz_archive_' || v_suffix);
      execute format('revoke all on schema %I from public', 'fz_archive_' || v_suffix);
      execute format('alter table fz_archive.%I set schema %I', 'creative_' || t, 'fz_archive_' || v_suffix);
    end if;
    execute format('alter table fz_creative.%I rename to %I', t, 'creative_' || t);
    execute format('alter table fz_creative.%I set schema fz_archive', 'creative_' || t);
  end loop;
end $$;
drop function if exists public.creative_templates(text, text);
drop function if exists public.creative_job_set_template(uuid, text, text, text, uuid[], text);
drop function if exists public.creative_job_template(uuid);
drop function if exists public.creative_metrics_import(text, jsonb, text, text);
drop function if exists public.creative_rank(text, text, integer);
drop function if exists public.creative_owner_set_template(text, text, text, text, text, text[], jsonb, text);
do $$ begin
  if to_regclass('fz_creative.providers') is null then return; end if;
  update fz_creative.providers set enabled = false, updated_by = 'rollback', updated_at = now() where slug = 'local-edit' and enabled;
  update fz_creative.providers
     set models = array['wan-2.2-ti2v-5b', 'wan-2.2-t2v-a14b', 'ltx-2', 'hunyuanvideo-1.5', 'flux.1-dev', 'flux.1-schnell', 'flux.1-dev-lora', 'sdxl-1.0', 'kokoro-tts', 'ace-step', 'flux-lora-trainer'],
         modules = array['video', 'image', 'ugc', 'voice', 'music', 'train']
   where slug in ('runpod-comfyui', 'modal-comfyui') and 'ltx-video' = any (models);
end $$;
\if :{?fz_in_txn}
\else
commit;
\endif
