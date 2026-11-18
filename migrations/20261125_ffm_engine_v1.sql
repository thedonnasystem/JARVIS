-- FF Marketing engine v1 (builds on 20261117_client_workspaces_v1, 20261118_ffm_onboarding_v1, 20261122_insurance_classifier_v1). Additive: 2 tables, 6 functions.
-- Touches no existing table, function, control or grant.
--   * Why a migration: production has no function that creates a client workspace (client_workspaces is select-only for the bot) and no place to keep
--     a generated campaign pack. Both are added here, nothing else.
--   * ffm_engine_create_workspace: a DRAFT workspace only. monthly_budget_cents stays NULL (the owner-only ffm_set_budget is unchanged), status stays
--     'draft', activation still needs every required input plus a current owner approval (ffm_readiness / ffm_activate, unchanged).
--   * ffm_engine_briefs / ffm_engine_packs: the owner's brief and the generated pack (JSON), DRAFT only: dry_run is a
--     CHECK-constrained true and there is no status that means launched / published / sent.
--   * Every string written is screened; a hit refuses the whole write (nothing is stored partially):
--       - each brief value and every FREE-TEXT leaf of the pack (keys listed in ffm_engine_save_pack) by ws_classify_text(text, workspace), the same
--         classifier ffm_guard applies to ffm_creatives / ffm_ad_sets (insurance-context workspaces keep its vocabulary allow-list);
--       - every other string leaf must be a short code (letters, digits, _ . : [ ] + -, at most 60 characters) and pass the strict screen
--         (ws_classify_text(text) without a workspace): no free text can hide in a structural field.
--   * The landing page is NOT stored as HTML: it is rendered on demand from the screened copy in the pack (hq_ffm_engine.render_landing_html).
--   * RLS on with no policy; anon/authenticated get nothing; service_role may select only; writes only through the functions below.
--   * Backups: tables named ffm_* are client workspace tables, which backup_export_policy() denies by rule (never exported). No classification change.
create table if not exists public.ffm_engine_briefs (
  workspace_id uuid primary key references public.client_workspaces(id) on delete restrict,
  brief jsonb not null check (jsonb_typeof(brief) = 'object' and octet_length(brief::text) <= 8000),
  updated_by text not null check (length(updated_by) between 2 and 60),
  updated_at timestamptz not null default now()
);
create table if not exists public.ffm_engine_packs (
  id uuid primary key default gen_random_uuid(),
  workspace_id uuid not null references public.client_workspaces(id) on delete restrict,
  version integer not null check (version >= 1),
  vertical text not null check (vertical in ('generic', 'mortgage', 'insurance', 'home_services', 'real_estate')),
  status text not null default 'draft' check (status in ('draft', 'superseded')),
  dry_run boolean not null default true check (dry_run),
  campaign_id uuid,
  pack jsonb not null check (jsonb_typeof(pack) = 'object' and octet_length(pack::text) <= 120000),
  cost_cents integer not null default 0 check (cost_cents >= 0),
  model text check (model is null or model ~ '^[a-z0-9._-]{2,60}$'),
  created_by text not null check (length(created_by) between 2 and 60),
  created_at timestamptz not null default now(),
  unique (workspace_id, version),
  foreign key (workspace_id, campaign_id) references public.ws_campaigns (workspace_id, id)
);
create index if not exists ffm_engine_packs_ws_idx on public.ffm_engine_packs (workspace_id, version desc);
do $$ declare t text; begin
  foreach t in array array['ffm_engine_briefs', 'ffm_engine_packs'] loop
    execute format('alter table public.%I enable row level security', t);
    execute format('revoke all on public.%I from public, anon, authenticated', t);
    execute format('grant select on public.%I to service_role', t);
    execute format('revoke insert, update, delete, truncate, trigger, references on public.%I from service_role', t);
  end loop;
end $$;

-- one screen for every string the engine stores (the insurance-aware detector, with the workspace's own approved terms; strict otherwise)
create or replace function public.ffm_engine_screen(p_ws uuid, p_text text, p_where text) returns void
language plpgsql stable security definer set search_path to 'public' as $$
declare r jsonb;
begin
  if p_text is null or btrim(p_text) = '' then return; end if;
  r := public.ws_classify_text(p_text, p_ws);
  if r is null or coalesce((r ->> 'allowed')::boolean, false) is not true then
    raise exception 'Sensitive data refused in % (%). Applications, banking, credit, ID and sensitive financial data must never be stored here.',
      left(coalesce(p_where, '?'), 80), coalesce((select string_agg(x, ', ') from jsonb_array_elements_text(r -> 'reasons') x), 'unexpected reply') using errcode = 'P0001';
  end if;
end $$;
revoke all on function public.ffm_engine_screen(uuid, text, text) from public, anon, authenticated;
grant execute on function public.ffm_engine_screen(uuid, text, text) to service_role;   -- a pure check (raises or returns): harmless to expose

-- pre-check for the engine: which of these texts WOULD be refused (index from 0, reason codes only; the text is never echoed). Stores nothing.
create or replace function public.ffm_engine_screen_texts(p_ws uuid, p_texts text[]) returns jsonb
language plpgsql stable security definer set search_path to 'public' as $$
declare i integer; r jsonb; out_ jsonb := '[]'::jsonb;
begin
  if coalesce(cardinality(p_texts), 0) > 400 then raise exception 'too many texts (at most 400)'; end if;
  for i in 1 .. coalesce(cardinality(p_texts), 0) loop
    continue when p_texts[i] is null or btrim(p_texts[i]) = '';
    r := public.ws_classify_text(p_texts[i], p_ws);
    if r is null or coalesce((r ->> 'allowed')::boolean, false) is not true then
      out_ := out_ || jsonb_build_array(jsonb_build_object('i', i - 1, 'reasons', coalesce(r -> 'reasons', '["unexpected_reply"]'::jsonb)));
    end if;
  end loop;
  return out_;
end $$;
revoke all on function public.ffm_engine_screen_texts(uuid, text[]) from public, anon, authenticated;
grant execute on function public.ffm_engine_screen_texts(uuid, text[]) to service_role;

create or replace function public.ffm_engine_create_workspace(p_slug text, p_name text, p_vertical text, p_by text) returns uuid
language plpgsql security definer set search_path to 'public' as $$
declare v_id uuid;
begin
  if p_vertical is null or p_vertical not in ('generic', 'mortgage', 'insurance', 'home_services', 'real_estate') then raise exception 'unknown vertical'; end if;
  if p_by is null or length(btrim(p_by)) < 2 then raise exception 'say who created this workspace'; end if;
  if exists (select 1 from public.client_workspaces where slug = p_slug) then raise exception 'workspace slug already exists'; end if;
  perform public.ffm_engine_screen(null, p_name, 'workspace name');
  -- draft, no budget: the owner-only budget, approval and activation gates are unchanged
  insert into public.client_workspaces (slug, name, vertical) values (p_slug, p_name, p_vertical) returning id into v_id;
  perform public.ffm_instantiate_onboarding(v_id);
  insert into public.audit_log (actor, action, target, detail) values (left(p_by, 60), 'ffm_engine_workspace_drafted', 'workspace/' || v_id, jsonb_build_object('vertical', p_vertical));
  return v_id;
end $$;
revoke all on function public.ffm_engine_create_workspace(text, text, text, text) from public, anon, authenticated;
grant execute on function public.ffm_engine_create_workspace(text, text, text, text) to service_role;

create or replace function public.ffm_engine_save_brief(p_ws uuid, p_brief jsonb, p_by text) returns void
language plpgsql security definer set search_path to 'public' as $$
declare k text; v jsonb;
begin
  perform public.ffm_open_ws(p_ws);
  if p_brief is null or jsonb_typeof(p_brief) <> 'object' then raise exception 'brief must be an object'; end if;
  if p_by is null or length(btrim(p_by)) < 2 then raise exception 'say who supplied this brief'; end if;
  for k, v in select key, value from jsonb_each(p_brief) loop
    if k not in ('offer', 'service_area', 'target_customer', 'goal', 'monthly_budget_stated') then raise exception 'unknown brief field %', left(k, 40); end if;
    if jsonb_typeof(v) <> 'string' or length(v #>> '{}') > 500 then raise exception 'brief field % must be text of at most 500 characters', k; end if;
    perform public.ffm_engine_screen(p_ws, v #>> '{}', 'brief.' || k);
  end loop;
  insert into public.ffm_engine_briefs (workspace_id, brief, updated_by) values (p_ws, p_brief, left(p_by, 60))
  on conflict (workspace_id) do update set brief = excluded.brief, updated_by = excluded.updated_by, updated_at = now();
  insert into public.audit_log (actor, action, target, detail) values (left(p_by, 60), 'ffm_engine_brief_saved', 'workspace/' || p_ws, '{}'::jsonb);
end $$;
revoke all on function public.ffm_engine_save_brief(uuid, jsonb, text) from public, anon, authenticated;
grant execute on function public.ffm_engine_save_brief(uuid, jsonb, text) to service_role;

-- every string leaf of a jsonb value with the key it sits under (array elements inherit the key of their array)
create or replace function public.ffm_engine_leaves(p jsonb, p_key text default null) returns table (k text, v text)
language plpgsql immutable set search_path to 'public' as $$
declare e record;
begin
  if jsonb_typeof(p) = 'object' then
    for e in select key, value from jsonb_each(p) loop return query select * from public.ffm_engine_leaves(e.value, e.key); end loop;
  elsif jsonb_typeof(p) = 'array' then
    for e in select value from jsonb_array_elements(p) loop return query select * from public.ffm_engine_leaves(e.value, p_key); end loop;
  elsif jsonb_typeof(p) = 'string' then
    k := p_key; v := p #>> '{}'; return next;
  end if;
end $$;
revoke all on function public.ffm_engine_leaves(jsonb, text) from public, anon, authenticated;
grant execute on function public.ffm_engine_leaves(jsonb, text) to service_role;

create or replace function public.ffm_engine_save_pack(p_ws uuid, p_vertical text, p_pack jsonb, p_campaign uuid, p_cost_cents integer, p_model text, p_by text) returns jsonb
language plpgsql security definer set search_path to 'public' as $$
declare r record; n integer := 0; v_ver integer; v_id uuid;
  free_keys constant text[] := array['statement', 'offer_angle', 'differentiators', 'name', 'description', 'pain_point', 'audience_description', 'placement_note',
    'headline', 'primary_text', 'cta', 'prompt', 'metric', 'target', 'note', 'subheadline', 'bullets', 'cta_text', 'q', 'a', 'trust_note', 'subject', 'body', 'hook',
    'caption', 'offer', 'service_area', 'target_customer', 'goal', 'monthly_budget_stated'];
begin
  perform public.ffm_open_ws(p_ws);
  if p_pack is null or jsonb_typeof(p_pack) <> 'object' then raise exception 'pack must be an object'; end if;
  if p_by is null or length(btrim(p_by)) < 2 then raise exception 'say who generated this pack'; end if;
  -- one leaf at a time (joining them would compact unrelated digits into false number runs)
  for r in select * from public.ffm_engine_leaves(p_pack) loop
    if r.k = any (free_keys) then
      perform public.ffm_engine_screen(p_ws, r.v, 'pack.' || r.k);
    else
      if r.v !~ '^[A-Za-z0-9_.:+\[\]-]{0,60}$' then raise exception 'pack field % must be a short code, not free text', left(coalesce(r.k, '?'), 40); end if;
      perform public.ffm_engine_screen(null, r.v, 'pack.' || coalesce(r.k, '?'));
    end if;
    n := n + 1;
  end loop;
  perform pg_advisory_xact_lock(hashtext('ffm_engine_pack:' || p_ws::text));
  select coalesce(max(version), 0) + 1 into v_ver from public.ffm_engine_packs where workspace_id = p_ws;
  update public.ffm_engine_packs set status = 'superseded' where workspace_id = p_ws and status = 'draft';
  insert into public.ffm_engine_packs (workspace_id, version, vertical, campaign_id, pack, cost_cents, model, created_by)
  values (p_ws, v_ver, p_vertical, p_campaign, p_pack, greatest(coalesce(p_cost_cents, 0), 0), p_model, left(p_by, 60)) returning id into v_id;
  insert into public.audit_log (actor, action, target, detail) values (left(p_by, 60), 'ffm_engine_pack_drafted', 'workspace/' || p_ws,
    jsonb_build_object('pack', v_id, 'version', v_ver, 'strings_screened', n, 'cost_cents', greatest(coalesce(p_cost_cents, 0), 0)));
  return jsonb_build_object('id', v_id, 'version', v_ver, 'strings_screened', n, 'status', 'draft', 'dry_run', true);
end $$;
revoke all on function public.ffm_engine_save_pack(uuid, text, jsonb, uuid, integer, text, text) from public, anon, authenticated;
grant execute on function public.ffm_engine_save_pack(uuid, text, jsonb, uuid, integer, text, text) to service_role;
