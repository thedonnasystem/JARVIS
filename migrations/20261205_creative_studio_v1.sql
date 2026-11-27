-- FENDEZY GROUP Phase 1, milestone M8a "FENDEZY AI CREATIVE STUDIO" (slug creative-studio; fz_services key creative_studio): data model, router gates, asset
-- registry, pipeline skeleton. ADDITIVE. Needs M1..M7. Design: docs/architecture/PHASE1_M8_CREATIVE_STUDIO.md.
--   ONE shared group studio for all 8 offices, with a separate brand environment per office. Schema fz_creative has NO privilege for any API role; everything goes
--   through the creative_* definer functions below (service path = the Jarvis service key / a db session; owner controls = is_app_owner()).
--   * jobs walk the pipeline Brief -> Research -> Strategy -> Script -> Creative direction -> Generation -> Editing -> QA -> Approval -> Publishing -> Analytics.
--   * every generation ATTEMPT is opened here first (creative_attempt_begin): provider enabled by the owner for that module; at most max_attempts per job (hard
--     ceiling 5); a premium provider only after QA failed an open-source attempt AND the owner allowed premium for the job or the office; the office's OPTIONAL
--     owner-set weekly creative limit (default none: offices draw on need, Chairman rule of Nov 19); a daily job ceiling per office (no runaway loops).
--   * money: a paid attempt is reserved through the EXISTING office spend gate (fz_reserve_office_spend -> reserve_spend: caps, per-transaction and weekly limits,
--     owner approval rules) by hq_creative_studio.py BEFORE it runs; creative_attempt_end accepts a paid result only with a reservation attributed to the same
--     office (fz_money_attribution). Nothing here moves money; there is no new money path.
--   * assets: metadata here, files in ONE private Supabase Storage bucket 'creative-studio' under <office>/ (owner release step; signed URLs, no public listing).
--     Every generated asset carries meta.ai_generated = true; captions carry the AI-generated disclosure; a real person's likeness or voice needs an owner-recorded
--     consent. Version history: a new file under the same name is version n+1 pointing at version n.
--   * publishing: calendar entries are DRAFT posts linked to the Jarvis hands pipeline (owner approval -> official APIs). Nothing is published from here.
-- Function names avoid the fz_ prefix (the M1 rollback drill). The fz_services row is an OWNER release step (ops/OWNER_CREATIVE_STUDIO.sql): M5's protected
-- sqltest pins exactly six services (proposal: ops/proposals/creative_studio_registry.md). Until that row is active every service-path write refuses.
-- Ordered BEFORE the lockdown (R3). Rollback: ops/rollback_creative_studio.sql (archives to fz_archive). Safe to re-run.

set lock_timeout = '5s';

create schema if not exists fz_creative;
revoke all on schema fz_creative from public;
do $$ declare r text; begin
  foreach r in array array['anon', 'authenticated', 'service_role', 'fz_jarvis', 'fz_office_agent', 'fz_auditor', 'backup_reader'] loop
    if exists (select 1 from pg_roles where rolname = r) then execute format('revoke all on schema fz_creative from %I', r); end if;
  end loop;
end $$;

-- ---------------------------------------------------------------------------------------------------------------------------- provider registry
-- kind: local (free, on the Jarvis host) | serverless (open models in our ComfyUI workflows on a pay-per-second GPU) | hosted (open models through a
--       per-generation API) | aggregator (generic slot) | premium (fallback only). est_cents = ESTIMATE in CAD cents per unit (USD list price x 1.40, rounded);
--       read the real price on the provider's page before enabling. Every provider starts OFF; hq_creative_studio also needs its env key set.
create table if not exists fz_creative.providers (
  slug text primary key check (slug ~ '^[a-z][a-z0-9-]{1,39}$'),
  title text not null,
  kind text not null check (kind in ('local', 'serverless', 'hosted', 'aggregator', 'premium')),
  modules text[] not null check (modules <@ array['video', 'image', 'ugc', 'voice', 'music', 'copy', 'edit', 'train']),
  models text[] not null default '{}',
  env_key text not null default '',
  est_cents numeric(10,4) not null check (est_cents >= 0),
  unit text not null check (unit in ('job', 'gpu-second', 'image', 'video-second', 'minute', 'output')),
  enabled boolean not null default false,
  note text not null default '',
  updated_at timestamptz not null default now(),
  updated_by text not null default 'migration'
);
revoke all on fz_creative.providers from public;
insert into fz_creative.providers (slug, title, kind, modules, models, env_key, est_cents, unit, note) values
  ('sandbox', 'Sandbox: deterministic local test media (ffmpeg lavfi), no network', 'local', array['video', 'image', 'ugc', 'voice', 'music'], array['sandbox-testsrc'], '', 0, 'job', 'tests and demo only'),
  ('copy-llm', 'Copy and scripts through hq_llm (free open-model router first)', 'local', array['copy'], array['hq_llm'], '', 0, 'job', 'inside the daily AI cap'),
  ('runpod-comfyui', 'RunPod serverless running our ComfyUI workflows (later cost optimisation; no adapter yet)', 'serverless', array['video', 'image', 'ugc', 'voice', 'music', 'train'],
     array['wan-2.2-ti2v-5b', 'wan-2.2-t2v-a14b', 'ltx-2', 'hunyuanvideo-1.5', 'flux.1-dev', 'flux.1-schnell', 'flux.1-dev-lora', 'sdxl-1.0', 'kokoro-tts', 'ace-step', 'flux-lora-trainer'], 'RUNPOD_API_KEY', 0.0750, 'gpu-second',
     'estimate: 48GB-class GPU about US$0.00053/s; H100-class about 2x'),
  ('modal-comfyui', 'Modal serverless running our ComfyUI workflows (later cost optimisation; no adapter yet)', 'serverless', array['video', 'image', 'ugc', 'voice', 'music', 'train'],
     array['wan-2.2-ti2v-5b', 'wan-2.2-t2v-a14b', 'ltx-2', 'hunyuanvideo-1.5', 'flux.1-dev', 'flux.1-schnell', 'flux.1-dev-lora', 'sdxl-1.0', 'kokoro-tts', 'ace-step', 'flux-lora-trainer'], 'MODAL_TOKEN_ID', 0.0800, 'gpu-second',
     'estimate: L40S about US$0.00054/s; H100 about US$0.0011/s'),
  ('fal-hosted', 'fal.ai per-call API (hosted open-weight models): the v1 generation path', 'hosted', array['video', 'image', 'ugc', 'train'],
     array['flux.1-schnell', 'flux.1-dev', 'flux.1-dev-lora', 'wan-2.2-ti2v-5b', 'wan-2.2-t2v-a14b', 'ltx-2', 'flux-lora-trainer'], 'FAL_KEY', 3.5000, 'output',
     'estimate; per-model prices in creative_studio/hosted_models.json (Flux schnell about US$0.003/image, Wan 2.2 5B about US$0.03 per video-second)'),
  ('replicate-hosted', 'Replicate per-call API (hosted open-weight models): slot, no adapter yet (owner allow-list decision)', 'hosted', array['video', 'image', 'ugc'],
     array['flux.1-schnell', 'flux.1-dev', 'wan-2.2-ti2v-5b'], 'REPLICATE_API_TOKEN', 0.4200, 'output', 'estimate: Flux schnell about US$0.003/image'),
  ('aggregator-slot', 'Generic aggregator slot (reserved for the service the owner calls "Treg": not identified yet)', 'aggregator', array['video', 'image', 'ugc', 'voice', 'music'], '{}',
     'CREATIVE_AGGREGATOR_KEY', 7.0000, 'output', 'unknown service: identify and price it before enabling'),
  ('veo', 'Google Veo 3.1 (premium video with audio)', 'premium', array['video', 'ugc'], array['veo-3.1', 'veo-3.1-fast'], 'GOOGLE_API_KEY', 56.0000, 'video-second', 'estimate: about US$0.40/s (fast tier lower); fallback only'),
  ('kling', 'Kling 3.0 (premium video)', 'premium', array['video', 'ugc'], array['kling-3.0'], 'KLING_API_KEY', 15.0000, 'video-second', 'estimate; fallback only'),
  ('runway', 'Runway (premium video)', 'premium', array['video', 'ugc'], array['gen-4', 'gen-4-turbo'], 'RUNWAY_API_KEY', 14.0000, 'video-second', 'estimate: about US$0.05-0.12/s; fallback only'),
  ('elevenlabs', 'ElevenLabs (premium voice)', 'premium', array['voice'], array['multilingual-v2'], 'ELEVENLABS_API_KEY', 42.0000, 'minute', 'estimate; fallback only'),
  ('music-premium-slot', 'Premium music API slot (provider not chosen: check its licence / ownership terms for generated music first)', 'premium', array['music'], '{}',
     'CREATIVE_MUSIC_API_KEY', 14.0000, 'minute', 'estimate; ownership of generated music differs per provider')
on conflict (slug) do update set title = excluded.title, kind = excluded.kind, modules = excluded.modules, models = excluded.models, env_key = excluded.env_key,
  est_cents = excluded.est_cents, unit = excluded.unit, note = excluded.note;   -- 'enabled' stays the owner's

-- ---------------------------------------------------------------------------------------------------------------------------- brand environments
-- one kit for the group + one per office (tone, colours, fonts, do / dont lists, required disclaimers, logo asset names, voice notes)
create table if not exists fz_creative.brand_kits (
  scope text primary key check (scope ~ '^[a-z][a-z0-9-]{1,39}$'),
  kit jsonb not null check (jsonb_typeof(kit) = 'object' and kit - array['tone', 'colours', 'fonts', 'do', 'dont', 'disclaimers', 'logos', 'voice'] = '{}'::jsonb),
  updated_at timestamptz not null default now(),
  updated_by text not null default 'owner'
);
revoke all on fz_creative.brand_kits from public;

-- per office: premium allowed? OPTIONAL weekly creative limit (null = none; the spend gate's caps always apply); retries; daily job ceiling
create table if not exists fz_creative.office_settings (
  office_id uuid primary key,
  allow_premium boolean not null default false,
  weekly_limit_cents integer check (weekly_limit_cents is null or weekly_limit_cents >= 0),
  max_attempts integer not null default 3 check (max_attempts between 1 and 5),
  max_jobs_day integer not null default 20 check (max_jobs_day between 0 and 200),
  updated_at timestamptz not null default now()
);
revoke all on fz_creative.office_settings from public;

create table if not exists fz_creative.likeness_consents (
  id uuid primary key default gen_random_uuid(),
  office_id uuid not null,
  person_label text not null check (person_label ~ '^[A-Za-z0-9][A-Za-z0-9 ._-]{0,59}$'),
  scope text not null check (length(scope) between 3 and 300),
  evidence_ref text not null check (length(evidence_ref) between 3 and 300),
  recorded_at timestamptz not null default now(),
  revoked_at timestamptz
);
revoke all on fz_creative.likeness_consents from public;

-- per-office presets (quality tiers are draft < standard < high < hero). hero_premium: a 'hero' job of this office/module may go to a premium provider directly,
-- but ONLY when the owner also allowed premium for the office or the job. Everything else: cheapest qualified model -> QA -> escalate.
create table if not exists fz_creative.presets (
  scope text not null check (scope ~ '^[a-z][a-z0-9-]{1,39}$'),
  module text not null check (module in ('video', 'image', 'ugc', 'voice', 'music', 'copy', 'edit', 'train')),
  default_tier text not null default 'standard' check (default_tier in ('draft', 'standard', 'high', 'hero')),
  models text[] not null default '{}',                                          -- preferred models, cheapest-qualified first
  hero_premium boolean not null default false,
  note text not null default '',
  primary key (scope, module)
);
revoke all on fz_creative.presets from public;
insert into fz_creative.presets (scope, module, default_tier, models, hero_premium, note) values
  ('b2b-records', 'image', 'high', array['flux.1-dev-lora', 'flux.1-schnell'], false, 'cover art / visualizer stills with the artist LoRA (artist looks only with consent)'),
  ('b2b-records', 'video', 'high', array['wan-2.2-t2v-a14b', 'ltx-2'], false, 'lyric and visualizer video'),
  ('b2b-records', 'music', 'high', array['ace-step'], false, 'open music model first; premium music slot only if allowed; never imitate a named real artist'),
  ('pimp-ai', 'image', 'high', array['flux.1-dev-lora'], false, 'character consistency through the character''s registered LoRA'),
  ('pimp-ai', 'video', 'high', array['wan-2.2-t2v-a14b', 'ltx-2'], false, 'character video from LoRA stills'),
  ('pimp-ai', 'train', 'high', array['flux-lora-trainer'], false, 'one FLUX LoRA per registered character'),
  ('the-trap', 'image', 'high', array['flux.1-dev', 'flux.1-schnell'], false, 'product photography: product reference (IP-adapter), background and relight workflows'),
  ('the-trap', 'video', 'standard', array['wan-2.2-ti2v-5b', 'ltx-2'], false, 'short product videos'),
  ('ff-marketing', 'video', 'hero', array['kling-3.0', 'veo-3.1', 'gen-4', 'wan-2.2-t2v-a14b'], true, 'hero ads go premium (pay per use, owner-allowed); open models for variations'),
  ('ff-marketing', 'image', 'high', array['flux.1-dev', 'flux.1-schnell'], false, 'ad stills and variations')
on conflict (scope, module) do nothing;                                         -- the owner's later edits stay

-- characters (Pimp AI and others): consistent identities, each with its LoRA asset. A real person needs a recorded consent; otherwise it is a fictional character.
create table if not exists fz_creative.characters (
  id uuid primary key default gen_random_uuid(),
  office_id uuid not null,
  slug text not null,
  name text not null check (name ~ '^[a-z0-9][a-z0-9._-]{0,59}$'),
  trigger_word text not null check (trigger_word ~ '^[a-z0-9_]{3,40}$'),
  real_person boolean not null default false,
  consent_id uuid references fz_creative.likeness_consents (id),
  lora_asset_id uuid,
  status text not null default 'draft' check (status in ('draft', 'training', 'ready', 'retired')),
  created_at timestamptz not null default now(),
  unique (slug, name),
  check (not real_person or consent_id is not null)
);
revoke all on fz_creative.characters from public;

-- ---------------------------------------------------------------------------------------------------------------------------- jobs, attempts, assets
create table if not exists fz_creative.jobs (
  id uuid primary key default gen_random_uuid(),
  office_id uuid not null,
  slug text not null,
  module text not null check (module in ('video', 'image', 'ugc', 'voice', 'music', 'copy', 'edit', 'train')),   -- train = a character / artist LoRA on the GPU runner
  brief text not null check (length(brief) between 10 and 4000),
  quality text not null default 'standard' check (quality in ('draft', 'standard', 'high', 'hero')),
  character_id uuid,                                                            -- a registered character (consistency via its LoRA)
  platforms text[] not null default array['9:16'] check (platforms <@ array['9:16', '1:1', '16:9'] and cardinality(platforms) between 1 and 3),
  consent_id uuid,
  reuse_of uuid,                                                                -- an approved earlier asset of the same office this job builds on
  allow_premium boolean not null default false,                                 -- owner only
  stage text not null default 'brief' check (stage in ('brief', 'research', 'strategy', 'script', 'direction', 'generation', 'editing', 'qa', 'approval', 'publishing', 'analytics')),
  status text not null default 'queued' check (status in ('queued', 'running', 'awaiting_approval', 'approved', 'rejected', 'failed', 'refused')),
  plan jsonb not null default '{}'::jsonb,                                      -- research / strategy / script / direction outputs (short)
  caption text,
  qa jsonb not null default '{}'::jsonb,
  created_by text not null,
  created_at timestamptz not null default now(),
  started_at timestamptz,
  finished_at timestamptz,
  updated_at timestamptz not null default now()
);
revoke all on fz_creative.jobs from public;
create index if not exists creative_jobs_office on fz_creative.jobs (office_id, created_at);

create table if not exists fz_creative.attempts (
  id uuid primary key default gen_random_uuid(),
  job_id uuid not null references fz_creative.jobs (id),
  office_id uuid not null,
  n integer not null,
  provider text not null,
  model text not null,
  kind text not null,
  est_cents integer not null check (est_cents >= 0),
  actual_cents integer check (actual_cents >= 0),
  reservation_id uuid,
  outcome text not null default 'open' check (outcome in ('open', 'ok', 'qa_failed', 'error')),
  qa_score numeric(4,3),
  ms integer,
  error text,
  created_at timestamptz not null default now(),
  ended_at timestamptz,
  unique (job_id, n)
);
revoke all on fz_creative.attempts from public;

create table if not exists fz_creative.assets (
  id uuid primary key default gen_random_uuid(),
  office_id uuid not null,
  slug text not null,
  job_id uuid references fz_creative.jobs (id),
  kind text not null check (kind in ('brand_guideline', 'logo', 'graphic', 'character', 'product_photo', 'voice', 'video_template', 'campaign', 'generated', 'lora')),
  name text not null check (name ~ '^[a-z0-9][a-z0-9._-]{0,79}$'),
  version integer not null default 1,
  previous_id uuid,
  path text not null check (path ~ '^[a-z][a-z0-9-]{1,39}/[A-Za-z0-9._/-]+$' and length(path) <= 340 and path !~ '\.\.'),
  mime text not null check (mime ~ '^(image|video|audio|text|application)/[a-z0-9.+-]{1,60}$'),
  bytes bigint not null check (bytes >= 0),
  sha256 text not null check (sha256 ~ '^[0-9a-f]{64}$'),
  platform text check (platform is null or platform in ('9:16', '1:1', '16:9')),
  meta jsonb not null default '{}'::jsonb,
  source text not null default 'studio' check (source ~ '^[a-z][a-z0-9._-]{1,39}$'),   -- 'studio' or the external tool of a manual import (e.g. higgsfield)
  external_cost_cents integer not null default 0 check (external_cost_cents >= 0),      -- what the owner paid outside (manual imports), for analytics
  status text not null default 'draft' check (status in ('draft', 'approved', 'rejected', 'archived')),
  created_at timestamptz not null default now(),
  unique (slug, name, version),
  check (path like slug || '/%')
);
revoke all on fz_creative.assets from public;

create table if not exists fz_creative.performance (
  id uuid primary key default gen_random_uuid(),
  asset_id uuid not null references fz_creative.assets (id),
  metric text not null check (metric in ('impressions', 'engagement', 'clicks', 'leads', 'conversions', 'revenue_cents')),
  value numeric(14,2) not null check (value >= 0),
  source text not null check (length(source) between 2 and 80),
  recorded_at timestamptz not null default now()
);
revoke all on fz_creative.performance from public;

create table if not exists fz_creative.calendar (
  id uuid primary key default gen_random_uuid(),
  office_id uuid not null,
  slug text not null,
  job_id uuid not null references fz_creative.jobs (id),
  asset_id uuid not null references fz_creative.assets (id),
  connector text not null check (connector ~ '^[a-z][a-z0-9-]{1,39}$'),
  account_id uuid not null,
  scheduled_at timestamptz not null,
  caption text not null check (length(caption) between 1 and 2200),
  hand_action_id uuid,
  status text not null default 'planned' check (status in ('planned', 'drafted', 'cancelled')),
  created_at timestamptz not null default now()
);
revoke all on fz_creative.calendar from public;

-- ---------------------------------------------------------------------------------------------------------------------------- helpers (private schema)
create or replace function fz_creative.office_active(p_slug text) returns uuid
language sql stable set search_path to 'pg_catalog' as $$
  select o.id from public.fz_offices o
   where o.slug = p_slug and o.kind = 'office' and o.status = 'active'
     and (to_regclass('fz_office_os.fz_office_profiles') is null
          or exists (select 1 from fz_office_os.fz_office_profiles p where p.office_id = o.id and p.status = 'active'))
$$;
revoke all on function fz_creative.office_active(text) from public, anon, authenticated;
create or replace function fz_creative.studio_on() returns boolean
language sql stable set search_path to 'pg_catalog' as $$
  select to_regclass('public.fz_services') is not null and exists (select 1 from public.fz_services where service = 'creative_studio' and status = 'active')
$$;
revoke all on function fz_creative.studio_on() from public, anon, authenticated;
create or replace function fz_creative.service_path() returns boolean
language sql stable set search_path to 'pg_catalog' as $$
  select coalesce(nullif(current_setting('role', true), ''), 'none') in ('none', 'postgres', 'service_role')
$$;
revoke all on function fz_creative.service_path() from public, anon, authenticated;
create or replace function fz_creative.guard() returns void
language plpgsql stable set search_path to 'pg_catalog' as $$
begin
  if not fz_creative.service_path() then raise exception 'refused' using errcode = '42501'; end if;
  if not fz_creative.studio_on() then raise exception 'refused: the creative studio is not registered or not active (fz_services creative_studio)' using errcode = '42501'; end if;
end $$;
revoke all on function fz_creative.guard() from public, anon, authenticated;
create or replace function fz_creative.clean(p text, p_max integer) returns text
language sql immutable set search_path to 'pg_catalog' as $$ select left(regexp_replace(coalesce(p, ''), '[[:cntrl:]]+', ' ', 'g'), p_max) $$;
revoke all on function fz_creative.clean(text, integer) from public, anon, authenticated;
create or replace function fz_creative.owner_only(p_what text) returns void
language plpgsql stable set search_path to 'pg_catalog' as $$
begin
  if not coalesce(public.is_app_owner(), false) then raise exception 'owner approval required: % is the owner''s decision', p_what using errcode = '42501'; end if;
end $$;
revoke all on function fz_creative.owner_only(text) from public, anon, authenticated;

-- ---------------------------------------------------------------------------------------------------------------------------- service path: offices submit
create or replace function public.creative_submit(p_office text, p_module text, p_brief text, p_quality text default 'standard', p_platforms text[] default array['9:16'],
                                                 p_consent uuid default null, p_reuse_of uuid default null, p_character uuid default null, p_by text default 'jarvis') returns jsonb
language plpgsql security definer set search_path to 'pg_catalog' as $$
declare v_office uuid; v_id uuid; v_day int;
begin
  perform fz_creative.guard();
  v_office := fz_creative.office_active(p_office);
  if v_office is null then raise exception 'refused: office % is not active', p_office using errcode = '42501'; end if;
  v_day := coalesce((select max_jobs_day from fz_creative.office_settings where office_id = v_office), 20);
  if (select count(*) from fz_creative.jobs where office_id = v_office and created_at > now() - interval '1 day') >= v_day then
    raise exception 'refused: office % reached its daily creative job ceiling (%)', p_office, v_day using errcode = '42501'; end if;
  if p_consent is not null and not exists (select 1 from fz_creative.likeness_consents where id = p_consent and office_id = v_office and revoked_at is null) then
    raise exception 'refused: no recorded consent % for this office (a real person''s likeness or voice needs one)', p_consent using errcode = '42501'; end if;
  if p_reuse_of is not null and not exists (select 1 from fz_creative.assets where id = p_reuse_of and office_id = v_office and status = 'approved') then
    raise exception 'refused: reuse needs an approved asset of the same office' using errcode = '42501'; end if;
  if p_character is not null and not exists (select 1 from fz_creative.characters c where c.id = p_character and c.office_id = v_office and c.status <> 'retired'
                                               and (not c.real_person or exists (select 1 from fz_creative.likeness_consents l where l.id = c.consent_id and l.revoked_at is null))) then
    raise exception 'refused: unknown character for this office (or its consent was revoked)' using errcode = '42501'; end if;
  insert into fz_creative.jobs (office_id, slug, module, brief, quality, platforms, consent_id, reuse_of, character_id, created_by)
    values (v_office, p_office, p_module, fz_creative.clean(p_brief, 4000), coalesce(p_quality, 'standard'), coalesce(p_platforms, array['9:16']), p_consent, p_reuse_of, p_character,
            left(regexp_replace(coalesce(p_by, 'jarvis'), '[^A-Za-z0-9:_.-]', '', 'g'), 60))
    returning id into v_id;
  insert into public.audit_log (actor, action, target, detail) values ('creative_studio', 'creative_job_submitted', 'fz_creative.jobs/' || v_id,
    jsonb_build_object('office', p_office, 'module', p_module, 'quality', coalesce(p_quality, 'standard')));
  return jsonb_build_object('job', v_id, 'status', 'queued');
end $$;
revoke all on function public.creative_submit(text, text, text, text, text[], uuid, uuid, uuid, text) from public, anon, authenticated;

-- the pipeline worker claims a queued job and gets the brief, both brand kits, the office's rules and the providers enabled for the module
create or replace function public.creative_claim(p_job uuid) returns jsonb
language plpgsql security definer set search_path to 'pg_catalog' as $$
declare j fz_creative.jobs; s fz_creative.office_settings;
begin
  perform fz_creative.guard();
  select * into j from fz_creative.jobs where id = p_job for update;
  if not found then raise exception 'unknown job'; end if;
  if j.status <> 'queued' then raise exception 'refused: job is %', j.status; end if;
  if fz_creative.office_active(j.slug) is null then raise exception 'refused: office % is not active', j.slug using errcode = '42501'; end if;
  select * into s from fz_creative.office_settings where office_id = j.office_id;
  update fz_creative.jobs set status = 'running', started_at = now(), updated_at = now() where id = j.id;
  return jsonb_build_object('job', j.id, 'office', j.slug, 'module', j.module, 'brief', j.brief, 'quality', j.quality, 'platforms', to_jsonb(j.platforms),
    'consent', j.consent_id, 'reuse_of', (select jsonb_build_object('id', a.id, 'path', a.path, 'mime', a.mime, 'name', a.name) from fz_creative.assets a where a.id = j.reuse_of),
    'preset', (select jsonb_build_object('default_tier', p.default_tier, 'models', to_jsonb(p.models), 'hero_premium', p.hero_premium) from fz_creative.presets p where p.scope = j.slug and p.module = j.module),
    'character', (select jsonb_build_object('id', c.id, 'name', c.name, 'trigger_word', c.trigger_word, 'lora', (select a.path from fz_creative.assets a where a.id = c.lora_asset_id))
                    from fz_creative.characters c where c.id = j.character_id),
    'premium_allowed', j.allow_premium or coalesce(s.allow_premium, false), 'max_attempts', least(coalesce(s.max_attempts, 3), 5),
    'brand_kit', jsonb_build_object('group', (select kit from fz_creative.brand_kits where scope = 'group'), 'office', (select kit from fz_creative.brand_kits where scope = j.slug)),
    'providers', coalesce((select jsonb_agg(jsonb_build_object('slug', slug, 'kind', kind, 'models', to_jsonb(models), 'est_cents', est_cents, 'unit', unit, 'env_key', env_key) order by est_cents, slug)
                             from fz_creative.providers where enabled and j.module = any (modules)), '[]'::jsonb));
end $$;
revoke all on function public.creative_claim(uuid) from public, anon, authenticated;

create or replace function public.creative_stage(p_job uuid, p_stage text, p_plan jsonb default null) returns jsonb
language plpgsql security definer set search_path to 'pg_catalog' as $$
declare j fz_creative.jobs; v_order text[] := array['brief', 'research', 'strategy', 'script', 'direction', 'generation', 'editing', 'qa', 'approval', 'publishing', 'analytics'];
begin
  perform fz_creative.guard();
  select * into j from fz_creative.jobs where id = p_job for update;
  if not found then raise exception 'unknown job'; end if;
  if j.status <> 'running' then raise exception 'refused: job is %', j.status; end if;
  if array_position(v_order, p_stage) is null or array_position(v_order, p_stage) < array_position(v_order, j.stage) or p_stage in ('approval', 'publishing', 'analytics') then
    raise exception 'refused: stage % after %', p_stage, j.stage; end if;
  if p_plan is not null and (jsonb_typeof(p_plan) <> 'object' or length(p_plan::text) > 8000) then raise exception 'plan must be a small object'; end if;
  update fz_creative.jobs set stage = p_stage, plan = plan || coalesce(p_plan, '{}'::jsonb), updated_at = now() where id = j.id;
  return jsonb_build_object('job', j.id, 'stage', p_stage);
end $$;
revoke all on function public.creative_stage(uuid, text, jsonb) from public, anon, authenticated;

-- router gate: one generation attempt. The worker asks BEFORE reserving money or calling a provider.
create or replace function public.creative_attempt_begin(p_job uuid, p_provider text, p_model text, p_est_cents integer) returns jsonb
language plpgsql security definer set search_path to 'pg_catalog' as $$
declare j fz_creative.jobs; pr fz_creative.providers; s fz_creative.office_settings; v_n int; v_id uuid; v_week bigint;
begin
  perform fz_creative.guard();
  select * into j from fz_creative.jobs where id = p_job for update;
  if not found then raise exception 'unknown job'; end if;
  if j.status <> 'running' then raise exception 'refused: job is %', j.status; end if;
  if fz_creative.office_active(j.slug) is null then raise exception 'refused: office % is not active', j.slug using errcode = '42501'; end if;
  if coalesce(p_est_cents, -1) < 0 then raise exception 'refused: an estimate is required' using errcode = '42501'; end if;
  select * into pr from fz_creative.providers where slug = p_provider;
  if not found or not pr.enabled or not (j.module = any (pr.modules)) then
    raise exception 'refused: provider % is not enabled for %', p_provider, j.module using errcode = '42501'; end if;
  if cardinality(pr.models) > 0 and not (coalesce(p_model, '') = any (pr.models)) then
    raise exception 'refused: model % is not registered for %', p_model, p_provider using errcode = '42501'; end if;
  select * into s from fz_creative.office_settings where office_id = j.office_id;
  if exists (select 1 from fz_creative.attempts where job_id = j.id and outcome = 'open') then raise exception 'refused: an attempt is still open' using errcode = '42501'; end if;
  v_n := coalesce((select max(n) from fz_creative.attempts where job_id = j.id), 0) + 1;
  if v_n > least(coalesce(s.max_attempts, 3), 5) then raise exception 'refused: retry limit reached (% attempts)', v_n - 1 using errcode = '42501'; end if;
  if pr.kind = 'premium' then
    if not (j.allow_premium or coalesce(s.allow_premium, false)) then raise exception 'refused: premium provider % is not allowed for this job or office', p_provider using errcode = '42501'; end if;
    if not exists (select 1 from fz_creative.attempts where job_id = j.id and outcome = 'qa_failed' and kind <> 'premium')
       and not (j.quality = 'hero' and coalesce((select hero_premium from fz_creative.presets where scope = j.slug and module = j.module), false)) then
      raise exception 'refused: premium is used only after QA failed an open-source attempt (or for a hero job whose office preset says so)' using errcode = '42501'; end if;
  end if;
  if s.weekly_limit_cents is not null then
    v_week := coalesce((select sum(coalesce(actual_cents, est_cents)) from fz_creative.attempts where office_id = j.office_id and created_at > now() - interval '7 days'), 0);
    if v_week + p_est_cents > s.weekly_limit_cents then
      raise exception 'refused: over the owner-set weekly creative limit for % (% + % > %)', j.slug, v_week, p_est_cents, s.weekly_limit_cents using errcode = '42501'; end if;
  end if;
  insert into fz_creative.attempts (job_id, office_id, n, provider, model, kind, est_cents) values (j.id, j.office_id, v_n, pr.slug, left(coalesce(p_model, ''), 120), pr.kind, p_est_cents)
    returning id into v_id;
  update fz_creative.jobs set stage = 'generation', updated_at = now() where id = j.id and stage in ('brief', 'research', 'strategy', 'script', 'direction', 'qa');
  return jsonb_build_object('attempt', v_id, 'n', v_n, 'kind', pr.kind);
end $$;
revoke all on function public.creative_attempt_begin(uuid, text, text, integer) from public, anon, authenticated;

-- the attempt's result: actual cost (a paid result names a reservation attributed to the same office), QA score, time
create or replace function public.creative_attempt_end(p_attempt uuid, p_outcome text, p_actual_cents integer, p_reservation uuid, p_qa_score numeric, p_ms integer,
                                                      p_error text default null) returns jsonb
language plpgsql security definer set search_path to 'pg_catalog' as $$
declare t fz_creative.attempts;
begin
  if not fz_creative.service_path() then raise exception 'refused' using errcode = '42501'; end if;
  select * into t from fz_creative.attempts where id = p_attempt for update;
  if not found then raise exception 'unknown attempt'; end if;
  if t.outcome <> 'open' then raise exception 'refused: attempt already ended'; end if;
  if p_outcome is null or p_outcome not in ('ok', 'qa_failed', 'error') then raise exception 'bad outcome %', p_outcome; end if;
  if coalesce(p_actual_cents, -1) < 0 then raise exception 'refused: the actual cost is required (0 when free)' using errcode = '42501'; end if;
  if p_actual_cents > 0 and (p_reservation is null or not exists (
       select 1 from public.spend_reservations r join public.fz_money_attribution m on m.source = 'reservation' and m.source_id = r.id
        where r.id = p_reservation and m.office_id = t.office_id)) then
    raise exception 'refused: a paid attempt must name its office spend-gate reservation' using errcode = '42501'; end if;
  update fz_creative.attempts set outcome = p_outcome, actual_cents = p_actual_cents, reservation_id = p_reservation, qa_score = p_qa_score,
         ms = greatest(coalesce(p_ms, 0), 0), error = nullif(fz_creative.clean(p_error, 300), ''), ended_at = now() where id = t.id;
  insert into public.audit_log (actor, action, target, detail) values ('creative_studio', 'creative_attempt_' || p_outcome, 'fz_creative.attempts/' || t.id,
    jsonb_build_object('job', t.job_id, 'provider', t.provider, 'model', t.model, 'est_cents', t.est_cents, 'actual_cents', p_actual_cents, 'reservation', p_reservation));
  return jsonb_build_object('attempt', t.id, 'outcome', p_outcome);
end $$;
revoke all on function public.creative_attempt_end(uuid, text, integer, uuid, numeric, integer, text) from public, anon, authenticated;

-- register a stored file (already uploaded to the bucket under <office>/). The same name again = the next version.
create or replace function public.creative_asset_add(p_office text, p_job uuid, p_kind text, p_name text, p_path text, p_mime text, p_bytes bigint, p_sha256 text,
                                                    p_platform text default null, p_meta jsonb default '{}') returns jsonb
language plpgsql security definer set search_path to 'pg_catalog' as $$
declare v_office uuid; j fz_creative.jobs; prev fz_creative.assets; v_id uuid; v_meta jsonb := coalesce(p_meta, '{}'::jsonb);
begin
  perform fz_creative.guard();
  v_office := fz_creative.office_active(p_office);
  if v_office is null then raise exception 'refused: office % is not active', p_office using errcode = '42501'; end if;
  if coalesce(p_path, '') not like p_office || '/%' then raise exception 'refused: asset path must be under %/', p_office using errcode = '42501'; end if;
  if p_job is not null then
    select * into j from fz_creative.jobs where id = p_job;
    if not found or j.office_id <> v_office then raise exception 'refused: job belongs to another office' using errcode = '42501'; end if;
  end if;
  if jsonb_typeof(v_meta) <> 'object' then raise exception 'meta must be an object'; end if;
  if p_kind in ('generated', 'lora') and p_job is null then raise exception 'refused: a generated asset belongs to a job' using errcode = '42501'; end if;
  if p_kind = 'generated' and coalesce(v_meta ->> 'ai_generated', '') <> 'true' then raise exception 'refused: a generated asset must carry ai_generated = true' using errcode = '42501'; end if;
  select * into prev from fz_creative.assets where slug = p_office and name = p_name order by version desc limit 1;
  insert into fz_creative.assets (office_id, slug, job_id, kind, name, version, previous_id, path, mime, bytes, sha256, platform, meta)
    values (v_office, p_office, p_job, p_kind, p_name, coalesce(prev.version, 0) + 1, prev.id, p_path, p_mime, p_bytes, lower(p_sha256), p_platform, v_meta) returning id into v_id;
  return jsonb_build_object('asset', v_id, 'version', coalesce(prev.version, 0) + 1);
end $$;
revoke all on function public.creative_asset_add(text, uuid, text, text, text, text, bigint, text, text, jsonb) from public, anon, authenticated;

-- QA verdict; a passing job then waits for the owner (nothing is "approved" without the owner)
create or replace function public.creative_finish(p_job uuid, p_passed boolean, p_caption text, p_qa jsonb) returns jsonb
language plpgsql security definer set search_path to 'pg_catalog' as $$
declare j fz_creative.jobs; v_status text;
begin
  perform fz_creative.guard();
  select * into j from fz_creative.jobs where id = p_job for update;
  if not found then raise exception 'unknown job'; end if;
  if j.status <> 'running' then raise exception 'refused: job is %', j.status; end if;
  if exists (select 1 from fz_creative.attempts where job_id = j.id and outcome = 'open') then raise exception 'refused: an attempt is still open' using errcode = '42501'; end if;
  if coalesce(p_passed, false) then
    if not exists (select 1 from fz_creative.assets where job_id = j.id and kind in ('generated', 'lora')) then raise exception 'refused: no generated asset to approve' using errcode = '42501'; end if;
    if j.module not in ('copy', 'train') and coalesce(p_caption, '') !~* 'ai-generated' then
      raise exception 'refused: the caption must carry the AI-generated disclosure' using errcode = '42501'; end if;
    v_status := 'awaiting_approval';
  else
    v_status := 'failed';
  end if;
  update fz_creative.jobs set status = v_status, stage = case when v_status = 'failed' then 'qa' else 'approval' end, caption = fz_creative.clean(p_caption, 2200),
         qa = qa || coalesce(p_qa, '{}'::jsonb), finished_at = case when v_status = 'failed' then now() end, updated_at = now() where id = j.id;
  insert into public.audit_log (actor, action, target, detail) values ('creative_studio', 'creative_job_' || v_status, 'fz_creative.jobs/' || j.id, jsonb_build_object('office', j.slug));
  return jsonb_build_object('job', j.id, 'status', v_status);
end $$;
revoke all on function public.creative_finish(uuid, boolean, text, jsonb) from public, anon, authenticated;

-- content calendar: DRAFT posts of APPROVED assets; the Jarvis hands pipeline (owner approval) decides any publishing
create or replace function public.creative_calendar_add(p_asset uuid, p_connector text, p_account uuid, p_scheduled_at timestamptz, p_caption text) returns jsonb
language plpgsql security definer set search_path to 'pg_catalog' as $$
declare a fz_creative.assets; v_id uuid;
begin
  perform fz_creative.guard();
  select * into a from fz_creative.assets where id = p_asset;
  if not found or a.status <> 'approved' or a.job_id is null then raise exception 'refused: only an owner-approved generated asset goes on the calendar' using errcode = '42501'; end if;
  if fz_creative.office_active(a.slug) is null then raise exception 'refused: office % is not active', a.slug using errcode = '42501'; end if;
  if coalesce(p_caption, '') !~* 'ai-generated' then raise exception 'refused: the post must carry the AI-generated disclosure' using errcode = '42501'; end if;
  insert into fz_creative.calendar (office_id, slug, job_id, asset_id, connector, account_id, scheduled_at, caption)
    values (a.office_id, a.slug, a.job_id, a.id, p_connector, p_account, p_scheduled_at, fz_creative.clean(p_caption, 2200)) returning id into v_id;
  return jsonb_build_object('entry', v_id, 'status', 'planned');
end $$;
revoke all on function public.creative_calendar_add(uuid, text, uuid, timestamptz, text) from public, anon, authenticated;

create or replace function public.creative_calendar_link(p_entry uuid, p_hand_action uuid) returns jsonb
language plpgsql security definer set search_path to 'pg_catalog' as $$
begin
  perform fz_creative.guard();
  if not exists (select 1 from public.hand_actions where id = p_hand_action) then raise exception 'refused: unknown hands draft'; end if;
  update fz_creative.calendar set hand_action_id = p_hand_action, status = 'drafted' where id = p_entry and status = 'planned';
  if not found then raise exception 'refused: no planned entry %', p_entry; end if;
  update fz_creative.jobs set stage = 'publishing', updated_at = now() where id = (select job_id from fz_creative.calendar where id = p_entry) and stage = 'approval';
  return jsonb_build_object('entry', p_entry, 'status', 'drafted', 'hand_action', p_hand_action);
end $$;
revoke all on function public.creative_calendar_link(uuid, uuid) from public, anon, authenticated;

-- a finished, owner-approved LoRA training job's file becomes the character's LoRA
create or replace function public.creative_character_lora(p_character uuid, p_asset uuid) returns jsonb
language plpgsql security definer set search_path to 'pg_catalog' as $$
declare c fz_creative.characters; a fz_creative.assets;
begin
  perform fz_creative.guard();
  select * into c from fz_creative.characters where id = p_character for update;
  select * into a from fz_creative.assets where id = p_asset;
  if c.id is null or a.id is null or a.office_id <> c.office_id or a.kind <> 'lora' or a.status <> 'approved' then
    raise exception 'refused: needs an owner-approved LoRA asset of the character''s office' using errcode = '42501'; end if;
  update fz_creative.characters set lora_asset_id = a.id, status = 'ready' where id = c.id;
  return jsonb_build_object('character', c.id, 'status', 'ready');
end $$;
revoke all on function public.creative_character_lora(uuid, uuid) from public, anon, authenticated;

create or replace function public.creative_perf_record(p_asset uuid, p_metric text, p_value numeric, p_source text) returns jsonb
language plpgsql security definer set search_path to 'pg_catalog' as $$
declare a fz_creative.assets;
begin
  perform fz_creative.guard();
  select * into a from fz_creative.assets where id = p_asset;
  if not found then raise exception 'unknown asset'; end if;
  insert into fz_creative.performance (asset_id, metric, value, source) values (a.id, p_metric, p_value, fz_creative.clean(p_source, 80));
  update fz_creative.jobs set stage = 'analytics', updated_at = now() where id = a.job_id and stage in ('approval', 'publishing');
  return jsonb_build_object('asset', a.id, 'metric', p_metric);
end $$;
revoke all on function public.creative_perf_record(uuid, text, numeric, text) from public, anon, authenticated;

-- an office's assets (newest first), or with p_best its approved generated assets ranked by recorded performance (reuse). The service path reads any office;
-- a scoped identity (only if granted by mistake) reads its own office only.
create or replace function public.creative_assets(p_office text, p_best boolean default false, p_limit integer default 20) returns jsonb
language plpgsql stable security definer set search_path to 'pg_catalog' as $$
declare v_role text := coalesce(nullif(current_setting('role', true), ''), 'none'); v_lim int := least(greatest(coalesce(p_limit, 20), 1), 100); v_best boolean := coalesce(p_best, false);
begin
  if v_role in ('fz_jarvis', 'fz_office_agent', 'fz_auditor') then
    if public.current_office_id() is distinct from (select id from public.fz_offices where slug = p_office and kind = 'office') then
      raise exception 'refused: a scoped identity reads its own office''s assets only' using errcode = '42501'; end if;
  elsif v_role not in ('none', 'postgres', 'service_role') then
    raise exception 'refused' using errcode = '42501';
  end if;
  return coalesce((select jsonb_agg(to_jsonb(y) order by y.score desc nulls last, y.created_at desc) from (
    select a.id, a.kind, a.name, a.version, a.path, a.mime, a.platform, a.status, a.job_id as job, a.created_at, s.score
      from fz_creative.assets a
      left join lateral (select coalesce(sum(case p.metric when 'engagement' then p.value when 'clicks' then 2 * p.value when 'leads' then 10 * p.value
                                                       when 'conversions' then 50 * p.value when 'revenue_cents' then p.value / 100 else 0 end), 0) as score
                           from fz_creative.performance p where p.asset_id = a.id) s on v_best
     where a.slug = p_office and (not v_best or (a.status = 'approved' and a.kind = 'generated'))
     order by s.score desc nulls last, a.created_at desc limit v_lim) y), '[]'::jsonb);
end $$;
revoke all on function public.creative_assets(text, boolean, integer) from public, anon, authenticated;

-- ---------------------------------------------------------------------------------------------------------------------------- owner controls
create or replace function public.creative_owner_set_provider(p_slug text, p_enabled boolean) returns jsonb
language plpgsql security definer set search_path to 'pg_catalog' as $$
begin
  perform fz_creative.owner_only('enabling a provider');
  update fz_creative.providers set enabled = coalesce(p_enabled, false), updated_at = now(), updated_by = 'owner' where slug = p_slug;
  if not found then raise exception 'unknown provider %', p_slug; end if;
  insert into public.audit_log (actor, action, target, detail) values ('owner', 'creative_provider', 'fz_creative.providers/' || p_slug, jsonb_build_object('enabled', coalesce(p_enabled, false)));
  return jsonb_build_object('provider', p_slug, 'enabled', coalesce(p_enabled, false));
end $$;
revoke all on function public.creative_owner_set_provider(text, boolean) from public, anon, authenticated;

-- p_weekly_limit_cents null = no creative limit (offices draw on need; the spend gate's caps still apply)
create or replace function public.creative_owner_set_office(p_office text, p_allow_premium boolean, p_weekly_limit_cents integer default null, p_max_attempts integer default 3,
                                                           p_max_jobs_day integer default 20) returns jsonb
language plpgsql security definer set search_path to 'pg_catalog' as $$
declare v uuid := (select id from public.fz_offices where slug = p_office and kind = 'office');
begin
  perform fz_creative.owner_only('office creative settings');
  if v is null then raise exception 'unknown office %', p_office; end if;
  insert into fz_creative.office_settings (office_id, allow_premium, weekly_limit_cents, max_attempts, max_jobs_day)
    values (v, coalesce(p_allow_premium, false), p_weekly_limit_cents, coalesce(p_max_attempts, 3), coalesce(p_max_jobs_day, 20))
    on conflict (office_id) do update set allow_premium = excluded.allow_premium, weekly_limit_cents = excluded.weekly_limit_cents, max_attempts = excluded.max_attempts,
       max_jobs_day = excluded.max_jobs_day, updated_at = now();
  insert into public.audit_log (actor, action, target, detail) values ('owner', 'creative_office_settings', 'fz_creative.office_settings/' || p_office,
    jsonb_build_object('allow_premium', coalesce(p_allow_premium, false), 'weekly_limit_cents', p_weekly_limit_cents, 'max_attempts', coalesce(p_max_attempts, 3)));
  return jsonb_build_object('office', p_office, 'allow_premium', coalesce(p_allow_premium, false), 'weekly_limit_cents', p_weekly_limit_cents);
end $$;
revoke all on function public.creative_owner_set_office(text, boolean, integer, integer, integer) from public, anon, authenticated;

create or replace function public.creative_owner_allow_premium(p_job uuid) returns jsonb
language plpgsql security definer set search_path to 'pg_catalog' as $$
begin
  perform fz_creative.owner_only('premium for a job');
  update fz_creative.jobs set allow_premium = true, updated_at = now() where id = p_job;
  if not found then raise exception 'unknown job'; end if;
  insert into public.audit_log (actor, action, target, detail) values ('owner', 'creative_job_premium', 'fz_creative.jobs/' || p_job, '{}'::jsonb);
  return jsonb_build_object('job', p_job, 'allow_premium', true);
end $$;
revoke all on function public.creative_owner_allow_premium(uuid) from public, anon, authenticated;

create or replace function public.creative_owner_decide(p_job uuid, p_approved boolean, p_note text default '') returns jsonb
language plpgsql security definer set search_path to 'pg_catalog' as $$
declare j fz_creative.jobs; v_status text := case when coalesce(p_approved, false) then 'approved' else 'rejected' end;
begin
  perform fz_creative.owner_only('approving a creative');
  select * into j from fz_creative.jobs where id = p_job for update;
  if not found then raise exception 'unknown job'; end if;
  if j.status <> 'awaiting_approval' then raise exception 'refused: job is %', j.status; end if;
  update fz_creative.jobs set status = v_status, finished_at = now(), updated_at = now(), qa = qa || jsonb_build_object('owner_note', fz_creative.clean(p_note, 300)) where id = j.id;
  update fz_creative.assets set status = v_status where job_id = j.id and kind in ('generated', 'lora') and status = 'draft';
  insert into public.audit_log (actor, action, target, detail) values ('owner', 'creative_job_' || v_status, 'fz_creative.jobs/' || j.id, jsonb_build_object('office', j.slug));
  return jsonb_build_object('job', j.id, 'status', v_status);
end $$;
revoke all on function public.creative_owner_decide(uuid, boolean, text) from public, anon, authenticated;

create or replace function public.creative_owner_set_brand_kit(p_scope text, p_kit jsonb) returns jsonb
language plpgsql security definer set search_path to 'pg_catalog' as $$
begin
  perform fz_creative.owner_only('a brand kit');
  if p_scope <> 'group' and not exists (select 1 from public.fz_offices where slug = p_scope and kind = 'office') then raise exception 'unknown office %', p_scope; end if;
  insert into fz_creative.brand_kits (scope, kit) values (p_scope, p_kit) on conflict (scope) do update set kit = excluded.kit, updated_at = now(), updated_by = 'owner';
  insert into public.audit_log (actor, action, target, detail) values ('owner', 'creative_brand_kit', 'fz_creative.brand_kits/' || p_scope,
    jsonb_build_object('keys', (select jsonb_agg(k) from jsonb_object_keys(p_kit) k)));
  return jsonb_build_object('scope', p_scope, 'ok', true);
end $$;
revoke all on function public.creative_owner_set_brand_kit(text, jsonb) from public, anon, authenticated;

create or replace function public.creative_owner_record_consent(p_office text, p_person_label text, p_scope text, p_evidence_ref text) returns jsonb
language plpgsql security definer set search_path to 'pg_catalog' as $$
declare v uuid := (select id from public.fz_offices where slug = p_office and kind = 'office'); v_id uuid;
begin
  perform fz_creative.owner_only('a likeness consent');
  if v is null then raise exception 'unknown office %', p_office; end if;
  insert into fz_creative.likeness_consents (office_id, person_label, scope, evidence_ref) values (v, p_person_label, p_scope, p_evidence_ref) returning id into v_id;
  insert into public.audit_log (actor, action, target, detail) values ('owner', 'creative_likeness_consent', 'fz_creative.likeness_consents/' || v_id, jsonb_build_object('office', p_office));
  return jsonb_build_object('consent', v_id);
end $$;
revoke all on function public.creative_owner_record_consent(text, text, text, text) from public, anon, authenticated;

-- manual import: an asset the owner made by hand in ANY outside tool (e.g. Higgsfield) goes into the library with its source and what it cost, so analytics include
-- it. The cost was paid outside the studio (nothing is spent here). The file is already uploaded under <office>/.
create or replace function public.creative_owner_import(p_office text, p_kind text, p_name text, p_path text, p_mime text, p_bytes bigint, p_sha256 text,
                                                       p_source text, p_cost_cents integer, p_ai_generated boolean, p_platform text default null) returns jsonb
language plpgsql security definer set search_path to 'pg_catalog' as $$
declare v uuid := (select id from public.fz_offices where slug = p_office and kind = 'office'); prev fz_creative.assets; v_id uuid;
begin
  perform fz_creative.owner_only('a manual import');
  if v is null then raise exception 'unknown office %', p_office; end if;
  if p_ai_generated is null then raise exception 'refused: say whether the asset is AI-generated'; end if;
  if coalesce(p_source, '') = 'studio' then raise exception 'refused: name the outside tool'; end if;
  if coalesce(p_path, '') not like p_office || '/%' then raise exception 'refused: asset path must be under %/', p_office using errcode = '42501'; end if;
  select * into prev from fz_creative.assets where slug = p_office and name = p_name order by version desc limit 1;
  insert into fz_creative.assets (office_id, slug, kind, name, version, previous_id, path, mime, bytes, sha256, platform, meta, source, external_cost_cents, status)
    values (v, p_office, p_kind, p_name, coalesce(prev.version, 0) + 1, prev.id, p_path, p_mime, p_bytes, lower(p_sha256), p_platform,
            jsonb_build_object('ai_generated', p_ai_generated, 'imported', true), p_source, coalesce(p_cost_cents, 0), 'approved') returning id into v_id;
  insert into public.audit_log (actor, action, target, detail) values ('owner', 'creative_import', 'fz_creative.assets/' || v_id,
    jsonb_build_object('office', p_office, 'source', p_source, 'cost_cents', coalesce(p_cost_cents, 0)));
  return jsonb_build_object('asset', v_id, 'version', coalesce(prev.version, 0) + 1);
end $$;
revoke all on function public.creative_owner_import(text, text, text, text, text, bigint, text, text, integer, boolean, text) from public, anon, authenticated;

create or replace function public.creative_owner_set_preset(p_scope text, p_module text, p_default_tier text, p_models text[], p_hero_premium boolean, p_note text default '') returns jsonb
language plpgsql security definer set search_path to 'pg_catalog' as $$
begin
  perform fz_creative.owner_only('an office preset');
  if not exists (select 1 from public.fz_offices where slug = p_scope and kind = 'office') then raise exception 'unknown office %', p_scope; end if;
  insert into fz_creative.presets (scope, module, default_tier, models, hero_premium, note) values (p_scope, p_module, p_default_tier, coalesce(p_models, '{}'), coalesce(p_hero_premium, false), coalesce(p_note, ''))
    on conflict (scope, module) do update set default_tier = excluded.default_tier, models = excluded.models, hero_premium = excluded.hero_premium, note = excluded.note;
  insert into public.audit_log (actor, action, target, detail) values ('owner', 'creative_preset', 'fz_creative.presets/' || p_scope || '/' || p_module,
    jsonb_build_object('tier', p_default_tier, 'hero_premium', coalesce(p_hero_premium, false)));
  return jsonb_build_object('scope', p_scope, 'module', p_module);
end $$;
revoke all on function public.creative_owner_set_preset(text, text, text, text[], boolean, text) from public, anon, authenticated;

-- a character for consistent content; real_person needs a live recorded consent of the same office
create or replace function public.creative_owner_add_character(p_office text, p_name text, p_trigger_word text, p_real_person boolean, p_consent uuid default null) returns jsonb
language plpgsql security definer set search_path to 'pg_catalog' as $$
declare v uuid := (select id from public.fz_offices where slug = p_office and kind = 'office'); v_id uuid;
begin
  perform fz_creative.owner_only('a character');
  if v is null then raise exception 'unknown office %', p_office; end if;
  if coalesce(p_real_person, true) and not exists (select 1 from fz_creative.likeness_consents where id = p_consent and office_id = v and revoked_at is null) then
    raise exception 'refused: a real person''s likeness needs a recorded consent of this office' using errcode = '42501'; end if;
  insert into fz_creative.characters (office_id, slug, name, trigger_word, real_person, consent_id) values (v, p_office, p_name, p_trigger_word, coalesce(p_real_person, true), p_consent)
    returning id into v_id;
  insert into public.audit_log (actor, action, target, detail) values ('owner', 'creative_character', 'fz_creative.characters/' || v_id, jsonb_build_object('office', p_office, 'real_person', coalesce(p_real_person, true)));
  return jsonb_build_object('character', v_id);
end $$;
revoke all on function public.creative_owner_add_character(text, text, text, boolean, uuid) from public, anon, authenticated;

-- ---------------------------------------------------------------------------------------------------------------------------- /creative (owner) report
create or replace function public.creative_report() returns jsonb
language plpgsql stable security definer set search_path to 'pg_catalog' as $$
begin
  if not fz_creative.service_path() then raise exception 'refused' using errcode = '42501'; end if;
  return jsonb_build_object(
    'registered', fz_creative.studio_on(),
    'queue', coalesce((select jsonb_object_agg(status, n) from (select status, count(*) n from fz_creative.jobs group by status) x), '{}'::jsonb),
    'cost', coalesce((select jsonb_agg(jsonb_build_object('module', module, 'jobs', jobs, 'approved', approved, 'cents', cents,
                       'cents_per_approved', case when approved > 0 then round(cents::numeric / approved, 1) end,
                       'success_rate', case when jobs > 0 then round(approved::numeric / jobs, 3) end,
                       'attempts_per_job', case when jobs > 0 then round(att::numeric / jobs, 2) end,
                       'avg_minutes', round(mins::numeric, 1)) order by module)
               from (select j.module, count(*) jobs, count(*) filter (where j.status = 'approved') approved,
                            coalesce(sum((select sum(coalesce(t.actual_cents, 0)) from fz_creative.attempts t where t.job_id = j.id)), 0) cents,
                            coalesce(sum((select count(*) from fz_creative.attempts t where t.job_id = j.id)), 0) att,
                            avg(extract(epoch from (j.finished_at - j.started_at)) / 60) filter (where j.finished_at is not null) mins
                       from fz_creative.jobs j group by j.module) y), '[]'::jsonb),
    'offices', coalesce((select jsonb_agg(jsonb_build_object('office', o.slug, 'week_cents', w.c, 'all_cents', w.a, 'weekly_limit_cents', s.weekly_limit_cents,
                          'allow_premium', coalesce(s.allow_premium, false)) order by o.slug)
                 from (select office_id, coalesce(sum(c) filter (where at > now() - interval '7 days'), 0) c, coalesce(sum(c), 0) a
                         from (select office_id, actual_cents c, created_at at from fz_creative.attempts
                               union all select office_id, external_cost_cents, created_at from fz_creative.assets where source <> 'studio') u group by office_id) w
                 join public.fz_offices o on o.id = w.office_id left join fz_creative.office_settings s on s.office_id = w.office_id), '[]'::jsonb),
    'providers', coalesce((select jsonb_agg(jsonb_build_object('slug', p.slug, 'kind', p.kind, 'enabled', p.enabled, 'env_key', p.env_key, 'est_cents', p.est_cents, 'unit', p.unit,
                            'attempts', (select count(*) from fz_creative.attempts t where t.provider = p.slug),
                            'qa_pass', (select count(*) from fz_creative.attempts t where t.provider = p.slug and t.outcome = 'ok'),
                            'cents', (select coalesce(sum(t.actual_cents), 0) from fz_creative.attempts t where t.provider = p.slug)) order by p.kind, p.slug)
                    from fz_creative.providers p), '[]'::jsonb));
end $$;
revoke all on function public.creative_report() from public, anon, authenticated;

-- none of these is for a scoped identity (the M1 allowlist stays exact)
do $$ declare r text; f regprocedure; begin
  foreach r in array array['fz_jarvis', 'fz_office_agent', 'fz_auditor', 'backup_reader'] loop
    continue when not exists (select 1 from pg_roles where rolname = r);
    for f in select p.oid::regprocedure from pg_proc p where p.pronamespace = 'public'::regnamespace and p.proname like 'creative\_%' loop
      execute format('revoke all on function %s from %I', f, r);
    end loop;
  end loop;
end $$;
