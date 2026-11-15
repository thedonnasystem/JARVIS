-- FF Marketing onboarding v1 (builds on 20261117_client_workspaces_v1). Additive: 7 tables, 2 views, 28 functions (21 ffm_* + 7 closed app_ffm_* owner wrappers). Touches no existing object.
--   * onboarding: a template per vertical is copied into per-workspace checklist items; a workspace cannot be activated until every
--     REQUIRED item holds an owner/client-supplied value, a monthly budget is set, AND an owner approval row exists that is still current
--     (any later change to an item or to the budget makes the approval stale)
--   * owner-only actions (set budget, approve, revoke) call ffm_require_owner() = is_app_owner(): the bot (service_role) has no auth.uid() and is refused
--   * campaign architecture: campaign -> ad sets -> creatives as plain non-sensitive text. dry_run is a CHECK-constrained true in v1:
--     NOTHING in this file launches a campaign, calls an ad platform, sends a message or moves money
--   * lead routing: a rule starts with an EMPTY field list (default deny); only fields on a fixed allow-list can ever be added, free-text
--     notes are not on it, and the built payload is re-screened with ws_sensitive_hits before it is returned
--   * SENSITIVE DATA: ffm_guard() runs ws_sensitive_hits() (the same detector as ws_guard) on every text column of every new table
--   * reporting is per workspace: every function takes a workspace id and filters every table by it; views group by workspace_id
create table if not exists public.ffm_onboarding_templates (
  vertical text not null check (vertical in ('generic', 'mortgage', 'insurance')),
  key text not null check (key ~ '^[a-z0-9_]{2,60}$'),
  title text not null,
  provider text not null check (provider in ('owner', 'client', 'ai')),
  required boolean not null default true,
  input_hint text,
  sort integer not null default 100,
  primary key (vertical, key)
);
create table if not exists public.ffm_onboarding_items (
  id uuid primary key default gen_random_uuid(),
  workspace_id uuid not null references public.client_workspaces(id) on delete restrict,
  template_key text not null check (template_key ~ '^[a-z0-9_]{2,60}$'),
  title text not null,
  provider text not null check (provider in ('owner', 'client', 'ai')),
  required boolean not null default true,
  status text not null default 'pending' check (status in ('pending', 'provided', 'blocked')),
  value_text text check (value_text is null or length(value_text) <= 500),
  provided_by text,
  blocked_until text check (blocked_until is null or length(blocked_until) <= 300),
  created_at timestamptz not null default clock_timestamp(),
  updated_at timestamptz not null default clock_timestamp(),
  unique (workspace_id, template_key),
  unique (workspace_id, id),
  check (status <> 'provided' or (value_text is not null and length(btrim(value_text)) > 0))
);
create table if not exists public.ffm_ad_sets (
  id uuid primary key default gen_random_uuid(),
  workspace_id uuid not null references public.client_workspaces(id) on delete restrict,
  campaign_id uuid not null,
  name text not null check (length(name) between 2 and 160),
  audience_note text check (audience_note is null or length(audience_note) <= 500),
  daily_budget_cents integer check (daily_budget_cents is null or daily_budget_cents >= 0),
  status text not null default 'draft' check (status in ('draft', 'approved', 'rejected')),
  dry_run boolean not null default true check (dry_run),
  created_at timestamptz not null default clock_timestamp(),
  unique (workspace_id, id),
  foreign key (workspace_id, campaign_id) references public.ws_campaigns (workspace_id, id)
);
create table if not exists public.ffm_creatives (
  id uuid primary key default gen_random_uuid(),
  workspace_id uuid not null references public.client_workspaces(id) on delete restrict,
  campaign_id uuid not null,
  ad_set_id uuid not null,
  headline text not null check (length(headline) between 2 and 120),
  body text not null check (length(body) between 2 and 1000),
  cta text check (cta is null or length(cta) <= 60),
  status text not null default 'draft' check (status in ('draft', 'in_review', 'approved', 'rejected')),
  dry_run boolean not null default true check (dry_run),
  created_at timestamptz not null default clock_timestamp(),
  unique (workspace_id, id),
  foreign key (workspace_id, campaign_id) references public.ws_campaigns (workspace_id, id),
  foreign key (workspace_id, ad_set_id) references public.ffm_ad_sets (workspace_id, id)
);
create table if not exists public.ffm_routing_rules (
  id uuid primary key default gen_random_uuid(),
  workspace_id uuid not null references public.client_workspaces(id) on delete restrict,
  name text not null check (length(name) between 2 and 120),
  destination_kind text not null check (destination_kind in ('email', 'webhook', 'crm')),
  destination_ref text check (destination_ref is null or length(destination_ref) <= 300),
  allowed_fields text[] not null default '{}'
    check (allowed_fields <@ array['name', 'email', 'phone', 'source', 'campaign_id', 'stage', 'created_at']::text[]),
  status text not null default 'draft' check (status in ('draft', 'approved', 'disabled')),
  dry_run boolean not null default true check (dry_run),
  created_at timestamptz not null default clock_timestamp(),
  unique (workspace_id, id)
);
create table if not exists public.ffm_approvals (
  id uuid primary key default gen_random_uuid(),
  workspace_id uuid not null references public.client_workspaces(id) on delete restrict,
  kind text not null check (kind in ('activation', 'campaign', 'routing')),
  ref_id uuid,
  approved_by text not null,
  note text check (note is null or length(note) <= 300),
  budget_cents_at_approval integer,
  created_at timestamptz not null default clock_timestamp(),
  revoked_at timestamptz,
  unique (workspace_id, id)
);
create table if not exists public.ffm_route_log (
  id uuid primary key default gen_random_uuid(),
  workspace_id uuid not null references public.client_workspaces(id) on delete restrict,
  rule_id uuid not null,
  lead_id uuid not null,
  fields text[] not null,
  dry_run boolean not null default true check (dry_run),
  created_at timestamptz not null default clock_timestamp(),
  foreign key (workspace_id, rule_id) references public.ffm_routing_rules (workspace_id, id)
);
create index if not exists ffm_items_ws_idx on public.ffm_onboarding_items (workspace_id, status);
create index if not exists ffm_approvals_ws_idx on public.ffm_approvals (workspace_id, kind, created_at);
create index if not exists ffm_creatives_ws_idx on public.ffm_creatives (workspace_id, status);
do $$ declare t text; begin
  foreach t in array array['ffm_onboarding_templates', 'ffm_onboarding_items', 'ffm_ad_sets', 'ffm_creatives', 'ffm_routing_rules', 'ffm_approvals', 'ffm_route_log'] loop
    execute format('alter table public.%I enable row level security', t);
    execute format('revoke all on public.%I from public, anon, authenticated', t);
    execute format('grant select on public.%I to service_role', t);
    execute format('revoke insert, update, delete, truncate, trigger, references on public.%I from service_role', t);
  end loop;
end $$;

-- starter templates. Wording avoids the detector's trigger words on purpose (they are copied into guarded item rows).
insert into public.ffm_onboarding_templates (vertical, key, title, provider, required, input_hint, sort) values
  ('generic', 'monthly_budget', 'Monthly ad budget (owner sets it in the workspace)', 'owner', true, 'amount in dollars; recorded via the owner-only budget action', 10),
  ('generic', 'service_geography', 'Service geography (where the client may advertise and take leads)', 'client', true, 'cities/regions, as the client states them', 20),
  ('generic', 'crm_destination', 'Client''s own CRM or inbox that receives leads', 'client', true, 'name of the system and the intake address; credentials stay with the client', 30),
  ('generic', 'booking_link', 'Booking calendar link', 'client', true, 'public booking URL', 40),
  ('generic', 'consent_wording', 'Consent wording for lead forms, approved by the client', 'client', true, 'exact text shown next to the form', 50),
  ('generic', 'compliance_contact', 'Client''s compliance contact for ad review', 'client', true, 'name and role', 60),
  ('generic', 'brand_assets', 'Logo, brand colours and approved photos', 'client', false, 'link to a shared folder', 70),
  ('generic', 'ad_account_access', 'Ad account access granted by the client (client does the connecting)', 'client', true, 'confirm yes and which account name; never share passwords in chat', 80),
  ('generic', 'launch_deadline', 'Target launch date, if any', 'owner', false, 'date, or leave pending', 90),
  ('mortgage', 'licence_details', 'Brokerage and broker licence details to show in ads', 'client', true, 'as they must appear in advertising', 100),
  ('mortgage', 'ad_review_signoff', 'Brokerage sign-off route for ad copy before launch', 'client', true, 'who approves, and how', 110),
  ('mortgage', 'no_sensitive_files_confirmed', 'Client confirmed no applications, banking, credit or ID files are ever sent to the AI', 'client', true, 'client says yes in writing', 120),
  ('mortgage', 'lead_fields_agreed', 'Agreed list of lead fields passed to the broker''s own systems', 'client', true, 'subset of: name, email, phone, source, campaign_id, stage, created_at', 130),
  ('insurance', 'recruiting_model', 'Recruiting model (NOT finalised: owner and client decide)', 'owner', true, 'describe once decided; do not assume', 100),
  ('insurance', 'licensing_status', 'Licensing and sponsoring-agency status for ads', 'client', true, 'as the client states it', 110),
  ('insurance', 'ad_review_signoff', 'Agency or MGA sign-off route for ad copy before launch', 'client', true, 'who approves, and how', 120),
  ('insurance', 'lead_fields_agreed', 'Agreed list of lead fields passed to the client''s own systems', 'client', true, 'subset of: name, email, phone, source, campaign_id, stage, created_at', 130)
on conflict (vertical, key) do nothing;

-- guard: same detector as ws_guard (ws_sensitive_hits). Only columns whose DATABASE TYPE is uuid or timestamptz are skipped (a random uuid or
-- timestamp can compact into a long digit run and would cause random false refusals); the type guarantees the value cannot be free text.
-- Every other string column is scanned whatever the value looks like: there is NO value-shape skip (a regex skip on the value was bypassable,
-- e.g. '2026-01-01 123456789'). Numbers/booleans/arrays are constrained by their own types and CHECKs.
create or replace function public.ffm_guard() returns trigger
language plpgsql set search_path to 'public' as $$
declare k text; v text; hits text[]; allv text := ''; j jsonb := to_jsonb(new);
begin
  for k, v in select e.key, e.value #>> '{}' from jsonb_each(j) e
              where jsonb_typeof(e.value) = 'string'
                and not exists (select 1 from pg_attribute a where a.attrelid = tg_relid and a.attname = e.key and a.attnum > 0 and not a.attisdropped
                                  and a.atttypid in ('uuid'::regtype, 'timestamptz'::regtype)) loop
    hits := public.ws_sensitive_hits(v);
    if array_length(hits, 1) > 0 then
      raise exception 'Sensitive data refused in %.% (%). Applications, banking, credit, ID and sensitive financial data must never be stored here.', tg_table_name, k, array_to_string(hits, ', ') using errcode = 'P0001';
    end if;
    allv := allv || ' ' || v;
  end loop;
  hits := public.ws_sensitive_hits(allv);   -- a value split across columns
  if array_length(hits, 1) > 0 then
    raise exception 'Sensitive data refused in % (%). Applications, banking, credit, ID and sensitive financial data must never be stored here.', tg_table_name, array_to_string(hits, ', ') using errcode = 'P0001';
  end if;
  return new;
end $$;
do $$ declare t text; begin
  foreach t in array array['ffm_onboarding_items', 'ffm_ad_sets', 'ffm_creatives', 'ffm_routing_rules', 'ffm_approvals'] loop
    execute format('drop trigger if exists ffm_guard on public.%I', t);
    execute format('create trigger ffm_guard before insert or update on public.%I for each row execute function public.ffm_guard()', t);
  end loop;
end $$;

create or replace function public.ffm_require_owner() returns void
language plpgsql stable security definer set search_path to 'public' as $$
begin
  if not coalesce(public.is_app_owner(), false) then raise exception 'owner approval required: this action is refused for the bot'; end if;
end $$;

create or replace function public.ffm_open_ws(p_ws uuid) returns void
language plpgsql stable security definer set search_path to 'public' as $$
begin
  if not exists (select 1 from public.client_workspaces where id = p_ws and status in ('draft', 'active')) then raise exception 'workspace not found or not open'; end if;
end $$;

create or replace function public.ffm_instantiate_onboarding(p_ws uuid) returns integer
language plpgsql security definer set search_path to 'public' as $$
declare v_vert text; n integer;
begin
  perform public.ffm_open_ws(p_ws);
  select vertical into v_vert from public.client_workspaces where id = p_ws;
  insert into public.ffm_onboarding_items (workspace_id, template_key, title, provider, required)
    select p_ws, t.key, t.title, t.provider, t.required from public.ffm_onboarding_templates t
    where t.vertical = 'generic' or t.vertical = coalesce(v_vert, '-')
    on conflict (workspace_id, template_key) do nothing;
  get diagnostics n = row_count;
  insert into public.audit_log (actor, action, target, detail) values ('ffm', 'ffm_onboarding_instantiated', 'workspace/' || p_ws, jsonb_build_object('items_added', n));
  return n;
end $$;

create or replace function public.ffm_provide_input(p_ws uuid, p_key text, p_value text, p_by text) returns void
language plpgsql security definer set search_path to 'public' as $$
begin
  perform public.ffm_open_ws(p_ws);
  if p_value is null or lower(btrim(p_value)) in ('', 'unset', 'tbd', 'n/a', 'na', 'none', 'unknown', 'pending', 'todo') then
    raise exception 'a real value is required; placeholders like unset/tbd do not count';
  end if;
  if p_by is null or length(btrim(p_by)) = 0 then raise exception 'say who supplied this value'; end if;
  update public.ffm_onboarding_items set status = 'provided', value_text = p_value, provided_by = p_by, blocked_until = null, updated_at = clock_timestamp()
    where workspace_id = p_ws and template_key = p_key;
  if not found then raise exception 'unknown onboarding item for this workspace'; end if;
  insert into public.audit_log (actor, action, target, detail) values ('ffm', 'ffm_input_provided', 'workspace/' || p_ws, jsonb_build_object('key', p_key, 'by', p_by));
end $$;

create or replace function public.ffm_block_input(p_ws uuid, p_key text, p_until text) returns void
language plpgsql security definer set search_path to 'public' as $$
begin
  perform public.ffm_open_ws(p_ws);
  update public.ffm_onboarding_items set status = 'blocked', blocked_until = p_until, value_text = null, provided_by = null, updated_at = clock_timestamp()
    where workspace_id = p_ws and template_key = p_key;
  if not found then raise exception 'unknown onboarding item for this workspace'; end if;
end $$;

create or replace function public.ffm_set_budget(p_ws uuid, p_cents integer) returns void
language plpgsql security definer set search_path to 'public' as $$
begin
  perform public.ffm_require_owner();
  perform public.ffm_open_ws(p_ws);
  if p_cents is null or p_cents < 0 then raise exception 'budget must be zero or more'; end if;
  update public.client_workspaces set monthly_budget_cents = p_cents where id = p_ws;
  insert into public.audit_log (actor, action, target, detail) values ('owner', 'ffm_budget_set', 'workspace/' || p_ws, jsonb_build_object('cents', p_cents));
end $$;

create or replace function public.ffm_owner_approve(p_ws uuid, p_kind text, p_ref uuid default null, p_note text default null) returns uuid
language plpgsql security definer set search_path to 'public' as $$
declare v_id uuid; v_budget integer; v_email text;
begin
  perform public.ffm_require_owner();
  perform public.ffm_open_ws(p_ws);
  if p_kind not in ('activation', 'campaign', 'routing') then raise exception 'unknown approval kind'; end if;
  if p_kind = 'campaign' and not exists (select 1 from public.ws_campaigns where id = p_ref and workspace_id = p_ws) then raise exception 'campaign not found in this workspace'; end if;
  if p_kind = 'routing' and not exists (select 1 from public.ffm_routing_rules where id = p_ref and workspace_id = p_ws) then raise exception 'routing rule not found in this workspace'; end if;
  if p_kind = 'campaign' then
    if not exists (select 1 from public.client_workspaces where id = p_ws and status = 'active') then raise exception 'workspace is not active'; end if;
    if not exists (select 1 from public.ffm_creatives where campaign_id = p_ref and workspace_id = p_ws and status = 'approved') then raise exception 'campaign has no approved creative'; end if;
  end if;
  select monthly_budget_cents into v_budget from public.client_workspaces where id = p_ws;
  v_email := coalesce((select u.email from auth.users u where u.id = auth.uid()), 'owner');
  insert into public.ffm_approvals (workspace_id, kind, ref_id, approved_by, note, budget_cents_at_approval) values (p_ws, p_kind, p_ref, v_email, p_note, v_budget) returning id into v_id;
  if p_kind = 'campaign' then update public.ws_campaigns set status = 'approved' where id = p_ref and workspace_id = p_ws and status = 'draft'; end if;   -- 'approved' only; nothing here can set 'running'
  if p_kind = 'routing' then update public.ffm_routing_rules set status = 'approved' where id = p_ref and workspace_id = p_ws and status = 'draft'; end if;
  insert into public.audit_log (actor, action, target, detail) values ('owner', 'ffm_approved', 'workspace/' || p_ws, jsonb_build_object('kind', p_kind, 'ref', p_ref, 'approval', v_id));
  return v_id;
end $$;

create or replace function public.ffm_revoke_approval(p_approval uuid) returns void
language plpgsql security definer set search_path to 'public' as $$
declare a public.ffm_approvals;
begin
  perform public.ffm_require_owner();
  update public.ffm_approvals set revoked_at = clock_timestamp() where id = p_approval and revoked_at is null returning * into a;
  if a.id is null then raise exception 'approval not found or already revoked'; end if;
  if a.kind = 'campaign' then update public.ws_campaigns set status = 'draft' where id = a.ref_id and workspace_id = a.workspace_id and status = 'approved'; end if;
  if a.kind = 'routing' then update public.ffm_routing_rules set status = 'draft' where id = a.ref_id and workspace_id = a.workspace_id and status = 'approved'; end if;
  insert into public.audit_log (actor, action, target, detail) values ('owner', 'ffm_approval_revoked', 'workspace/' || a.workspace_id, jsonb_build_object('approval', p_approval));
end $$;

create or replace function public.ffm_readiness(p_ws uuid) returns jsonb
language plpgsql stable security definer set search_path to 'public' as $$
declare w public.client_workspaces; v_missing text[]; v_items integer; v_last_change timestamptz; ap public.ffm_approvals; v_approved boolean := false; v_stale boolean := false;
begin
  select * into w from public.client_workspaces where id = p_ws;
  if w.id is null then return jsonb_build_object('ready', false, 'reasons', jsonb_build_array('workspace not found')); end if;
  select count(*), coalesce(array_agg(template_key order by template_key) filter (where required and status <> 'provided'), '{}'), max(updated_at)
    into v_items, v_missing, v_last_change from public.ffm_onboarding_items where workspace_id = p_ws;
  select * into ap from public.ffm_approvals where workspace_id = p_ws and kind = 'activation' and revoked_at is null order by created_at desc limit 1;
  if ap.id is not null then
    v_approved := true;
    v_stale := (v_last_change is not null and v_last_change > ap.created_at) or ap.budget_cents_at_approval is distinct from w.monthly_budget_cents;
  end if;
  return jsonb_build_object(
    'workspace', w.slug, 'status', w.status, 'items', v_items, 'missing_required', to_jsonb(v_missing),
    'budget_set', w.monthly_budget_cents is not null, 'owner_approved', v_approved and not v_stale, 'approval_stale', v_stale,
    'ready', w.status = 'draft' and v_items > 0 and cardinality(v_missing) = 0 and w.monthly_budget_cents is not null and v_approved and not v_stale);
end $$;

create or replace function public.ffm_activate(p_ws uuid) returns jsonb
language plpgsql security definer set search_path to 'public' as $$
declare r jsonb; why text[] := '{}';
begin
  perform pg_advisory_xact_lock(hashtext('ffm_activate:' || p_ws::text));
  r := public.ffm_readiness(p_ws);
  if r ->> 'status' is distinct from 'draft' then raise exception 'activation refused: workspace is not in draft'; end if;
  if (r ->> 'items')::int = 0 then why := why || array['onboarding not started']; end if;
  if jsonb_array_length(r -> 'missing_required') > 0 then why := why || array['missing required inputs: ' || (select string_agg(x, ', ') from jsonb_array_elements_text(r -> 'missing_required') x)]; end if;
  if not (r ->> 'budget_set')::boolean then why := why || array['no monthly budget set']; end if;
  if (r ->> 'approval_stale')::boolean then why := why || array['owner approval is stale (inputs or budget changed since)'];
  elsif not (r ->> 'owner_approved')::boolean then why := why || array['no owner approval']; end if;
  if array_length(why, 1) > 0 then raise exception 'activation refused: %', array_to_string(why, '; '); end if;
  update public.client_workspaces set status = 'active' where id = p_ws and status = 'draft';
  insert into public.audit_log (actor, action, target, detail) values ('ffm', 'ffm_workspace_activated', 'workspace/' || p_ws, '{}'::jsonb);
  return public.ffm_readiness(p_ws);
end $$;

create or replace function public.ffm_add_campaign(p_ws uuid, p_name text, p_channel text default null) returns uuid
language plpgsql security definer set search_path to 'public' as $$
declare v_id uuid;
begin
  perform public.ffm_open_ws(p_ws);
  insert into public.ws_campaigns (workspace_id, name, channel) values (p_ws, p_name, p_channel) returning id into v_id;
  insert into public.audit_log (actor, action, target, detail) values ('ffm', 'ffm_campaign_drafted', 'workspace/' || p_ws, jsonb_build_object('campaign', v_id));
  return v_id;
end $$;

create or replace function public.ffm_add_ad_set(p_ws uuid, p_campaign uuid, p_name text, p_audience text default null, p_daily_cents integer default null) returns uuid
language plpgsql security definer set search_path to 'public' as $$
declare v_id uuid;
begin
  perform public.ffm_open_ws(p_ws);
  insert into public.ffm_ad_sets (workspace_id, campaign_id, name, audience_note, daily_budget_cents) values (p_ws, p_campaign, p_name, p_audience, p_daily_cents) returning id into v_id;
  return v_id;
end $$;

create or replace function public.ffm_add_creative(p_ws uuid, p_campaign uuid, p_ad_set uuid, p_headline text, p_body text, p_cta text default null) returns uuid
language plpgsql security definer set search_path to 'public' as $$
declare v_id uuid;
begin
  perform public.ffm_open_ws(p_ws);
  insert into public.ffm_creatives (workspace_id, campaign_id, ad_set_id, headline, body, cta) values (p_ws, p_campaign, p_ad_set, p_headline, p_body, p_cta) returning id into v_id;
  return v_id;
end $$;

-- the bot may move a creative to review or reject it; only the owner may approve it
create or replace function public.ffm_set_creative_status(p_ws uuid, p_creative uuid, p_status text) returns void
language plpgsql security definer set search_path to 'public' as $$
begin
  perform public.ffm_open_ws(p_ws);
  if p_status not in ('draft', 'in_review', 'approved', 'rejected') then raise exception 'unknown creative status'; end if;
  if p_status = 'approved' then perform public.ffm_require_owner(); end if;
  update public.ffm_creatives set status = p_status where id = p_creative and workspace_id = p_ws;
  if not found then raise exception 'creative not found in this workspace'; end if;
end $$;

create or replace function public.ffm_add_routing_rule(p_ws uuid, p_name text, p_kind text, p_ref text, p_fields text[]) returns uuid
language plpgsql security definer set search_path to 'public' as $$
declare v_id uuid;
begin
  perform public.ffm_open_ws(p_ws);
  insert into public.ffm_routing_rules (workspace_id, name, destination_kind, destination_ref, allowed_fields) values (p_ws, p_name, p_kind, p_ref, coalesce(p_fields, '{}')) returning id into v_id;
  return v_id;
end $$;

-- DRY RUN ONLY. Builds what WOULD be passed on: allow-listed fields of one lead, for approved rules of the same workspace. Sends nothing.
create or replace function public.ffm_route_preview(p_ws uuid, p_lead uuid) returns jsonb
language plpgsql security definer set search_path to 'public' as $$
declare l public.ws_leads; r public.ffm_routing_rules; src jsonb; pay jsonb; out_ jsonb := '[]'::jsonb; f text;
begin
  perform public.ffm_open_ws(p_ws);
  select * into l from public.ws_leads where id = p_lead and workspace_id = p_ws;
  if l.id is null then raise exception 'lead not found in this workspace'; end if;
  src := jsonb_build_object('name', l.name, 'email', l.email, 'phone', l.phone, 'source', l.source, 'campaign_id', l.campaign_id, 'stage', l.stage, 'created_at', l.created_at);
  for r in select * from public.ffm_routing_rules where workspace_id = p_ws and status = 'approved' and dry_run order by created_at loop
    pay := '{}'::jsonb;
    foreach f in array r.allowed_fields loop pay := pay || jsonb_build_object(f, src -> f); end loop;
    if cardinality(r.allowed_fields) = 0 then continue; end if;
    if array_length(public.ws_sensitive_hits((select string_agg(value #>> '{}', ' ') from jsonb_each(pay) where key not in ('campaign_id', 'created_at'))), 1) > 0 then
      raise exception 'routing refused: payload for rule % looks sensitive', r.name;
    end if;
    insert into public.ffm_route_log (workspace_id, rule_id, lead_id, fields) values (p_ws, r.id, p_lead, r.allowed_fields);
    out_ := out_ || jsonb_build_array(jsonb_build_object('rule', r.name, 'destination_kind', r.destination_kind, 'dry_run', true, 'payload', pay));
  end loop;
  return out_;
end $$;

-- ---- reporting (every function filters every table by workspace_id) ----
create or replace function public.ffm_funnel(p_ws uuid, p_from timestamptz default null, p_to timestamptz default null) returns jsonb
language sql stable security definer set search_path to 'public' as $$
  select jsonb_build_object(
    'workspace', (select slug from public.client_workspaces where id = p_ws),
    'leads', (select count(*) from public.ws_leads where workspace_id = p_ws and (p_from is null or created_at >= p_from) and (p_to is null or created_at < p_to)),
    'by_stage', coalesce((select jsonb_object_agg(stage, n) from (select stage, count(*) n from public.ws_leads where workspace_id = p_ws
                  and (p_from is null or created_at >= p_from) and (p_to is null or created_at < p_to) group by stage) s), '{}'::jsonb));
$$;

create or replace function public.ffm_lead_booked_rate(p_ws uuid, p_from timestamptz default null, p_to timestamptz default null) returns jsonb
language sql stable security definer set search_path to 'public' as $$
  select jsonb_build_object('leads', count(*), 'booked', count(*) filter (where stage in ('booked', 'handed_off')),
    'rate', case when count(*) = 0 then null else round((count(*) filter (where stage in ('booked', 'handed_off')))::numeric / count(*), 4) end)
  from public.ws_leads where workspace_id = p_ws and (p_from is null or created_at >= p_from) and (p_to is null or created_at < p_to);
$$;

create or replace function public.ffm_spend_report(p_ws uuid) returns jsonb
language sql stable security definer set search_path to 'public' as $$
  with m as (select date_trunc('month', now() at time zone 'America/Toronto') at time zone 'America/Toronto' as s),
       w as (select slug, monthly_budget_cents b from public.client_workspaces where id = p_ws),
       sp as (select coalesce(sum(amount_cents), 0)::integer used from public.ws_ledger, m where workspace_id = p_ws and created_at >= m.s)
  select jsonb_build_object('workspace', w.slug, 'budget_cents', w.b, 'budget', case when w.b is null then 'unset' else 'set' end,
    'spent_cents', sp.used, 'remaining_cents', case when w.b is null then null else w.b - sp.used end,
    'pct_used', case when coalesce(w.b, 0) = 0 then null else round(sp.used::numeric / w.b, 4) end)
  from w cross join sp;
$$;

create or replace function public.ffm_weekly_report(p_ws uuid, p_from timestamptz default null, p_to timestamptz default null) returns jsonb
language plpgsql stable security definer set search_path to 'public' as $$
declare v_to timestamptz := coalesce(p_to, date_trunc('day', now() at time zone 'America/Toronto') at time zone 'America/Toronto');
        v_from timestamptz; v_slug text; v_spend_week integer;
begin
  v_from := coalesce(p_from, v_to - interval '7 days');
  select slug into v_slug from public.client_workspaces where id = p_ws;
  if v_slug is null then raise exception 'workspace not found'; end if;
  select coalesce(sum(amount_cents), 0)::integer into v_spend_week from public.ws_ledger where workspace_id = p_ws and created_at >= v_from and created_at < v_to;
  return jsonb_build_object(
    'workspace', v_slug, 'from', v_from, 'to', v_to,
    'readiness', public.ffm_readiness(p_ws),
    'funnel', public.ffm_funnel(p_ws, v_from, v_to),
    'lead_to_booked', public.ffm_lead_booked_rate(p_ws, v_from, v_to),
    'spend', public.ffm_spend_report(p_ws) || jsonb_build_object('spent_in_period_cents', v_spend_week),
    'campaigns_by_status', coalesce((select jsonb_object_agg(status, n) from (select status, count(*) n from public.ws_campaigns where workspace_id = p_ws group by status) c), '{}'::jsonb),
    'creatives_awaiting_review', (select count(*) from public.ffm_creatives where workspace_id = p_ws and status in ('draft', 'in_review')));
end $$;

create or replace view public.ffm_funnel_v with (security_invoker = true) as
  select workspace_id, count(*) as leads, count(*) filter (where stage = 'booked') as booked, count(*) filter (where stage = 'handed_off') as handed_off,
         count(*) filter (where stage = 'lost') as lost
  from public.ws_leads group by workspace_id;
create or replace view public.ffm_spend_v with (security_invoker = true) as
  select w.id as workspace_id, w.slug, w.monthly_budget_cents, coalesce(sum(l.amount_cents), 0)::integer as spent_all_time_cents
  from public.client_workspaces w left join public.ws_ledger l on l.workspace_id = w.id group by w.id, w.slug, w.monthly_budget_cents;
revoke all on public.ffm_funnel_v from public, anon, authenticated;
revoke all on public.ffm_spend_v from public, anon, authenticated;
revoke insert, update, delete, truncate, trigger, references on public.ffm_funnel_v from service_role;
revoke insert, update, delete, truncate, trigger, references on public.ffm_spend_v from service_role;
grant select on public.ffm_funnel_v to service_role;
grant select on public.ffm_spend_v to service_role;

revoke all on function public.ffm_guard() from public, anon, authenticated;
revoke all on function public.ffm_require_owner() from public, anon, authenticated;
revoke all on function public.ffm_open_ws(uuid) from public, anon, authenticated;
revoke all on function public.ffm_instantiate_onboarding(uuid) from public, anon, authenticated;
revoke all on function public.ffm_provide_input(uuid, text, text, text) from public, anon, authenticated;
revoke all on function public.ffm_block_input(uuid, text, text) from public, anon, authenticated;
revoke all on function public.ffm_set_budget(uuid, integer) from public, anon, authenticated;
revoke all on function public.ffm_owner_approve(uuid, text, uuid, text) from public, anon, authenticated;
revoke all on function public.ffm_revoke_approval(uuid) from public, anon, authenticated;
revoke all on function public.ffm_readiness(uuid) from public, anon, authenticated;
revoke all on function public.ffm_activate(uuid) from public, anon, authenticated;
revoke all on function public.ffm_add_campaign(uuid, text, text) from public, anon, authenticated;
revoke all on function public.ffm_add_ad_set(uuid, uuid, text, text, integer) from public, anon, authenticated;
revoke all on function public.ffm_add_creative(uuid, uuid, uuid, text, text, text) from public, anon, authenticated;
revoke all on function public.ffm_set_creative_status(uuid, uuid, text) from public, anon, authenticated;
revoke all on function public.ffm_add_routing_rule(uuid, text, text, text, text[]) from public, anon, authenticated;
revoke all on function public.ffm_route_preview(uuid, uuid) from public, anon, authenticated;
revoke all on function public.ffm_funnel(uuid, timestamptz, timestamptz) from public, anon, authenticated;
revoke all on function public.ffm_lead_booked_rate(uuid, timestamptz, timestamptz) from public, anon, authenticated;
revoke all on function public.ffm_spend_report(uuid) from public, anon, authenticated;
revoke all on function public.ffm_weekly_report(uuid, timestamptz, timestamptz) from public, anon, authenticated;
grant execute on function public.ffm_guard() to service_role;
grant execute on function public.ffm_require_owner() to service_role;
grant execute on function public.ffm_open_ws(uuid) to service_role;
grant execute on function public.ffm_instantiate_onboarding(uuid) to service_role;
grant execute on function public.ffm_provide_input(uuid, text, text, text) to service_role;
grant execute on function public.ffm_block_input(uuid, text, text) to service_role;
grant execute on function public.ffm_set_budget(uuid, integer) to service_role;
grant execute on function public.ffm_owner_approve(uuid, text, uuid, text) to service_role;
grant execute on function public.ffm_revoke_approval(uuid) to service_role;
grant execute on function public.ffm_readiness(uuid) to service_role;
grant execute on function public.ffm_activate(uuid) to service_role;
grant execute on function public.ffm_add_campaign(uuid, text, text) to service_role;
grant execute on function public.ffm_add_ad_set(uuid, uuid, text, text, integer) to service_role;
grant execute on function public.ffm_add_creative(uuid, uuid, uuid, text, text, text) to service_role;
grant execute on function public.ffm_set_creative_status(uuid, uuid, text) to service_role;
grant execute on function public.ffm_add_routing_rule(uuid, text, text, text, text[]) to service_role;
grant execute on function public.ffm_route_preview(uuid, uuid) to service_role;
grant execute on function public.ffm_funnel(uuid, timestamptz, timestamptz) to service_role;
grant execute on function public.ffm_lead_booked_rate(uuid, timestamptz, timestamptz) to service_role;
grant execute on function public.ffm_spend_report(uuid) to service_role;
grant execute on function public.ffm_weekly_report(uuid, timestamptz, timestamptz) to service_role;

-- ---- owner wrappers for the PWA (pattern: app_needs_you -> created CLOSED) ----
-- Each re-checks is_app_owner() itself and fails closed (42501) for anon, signed-in strangers and the bot (service_role has no auth.uid()).
-- They only read, set the budget, approve/revoke the ACTIVATION approval, or approve a creative. There is deliberately NO wrapper for
-- ffm_activate, campaign/routing approval or anything that launches: activation stays a dry-run service path and nothing here spends or sends.
-- Opening them to the signed-in owner means adding the names to the lockdown keep-open list (an applied migration): owner sign-off, see
-- ops/pending_signoff/ffm_open_app_ffm.txt. Until then they are service_role only, exactly like app_needs_you.
create or replace function public.app_ffm_workspaces() returns jsonb
language plpgsql stable security definer set search_path to 'public' as $$
begin
  if not public.is_app_owner() then raise exception 'not authorized' using errcode = '42501'; end if;
  return coalesce((select jsonb_agg(jsonb_build_object('id', w.id, 'slug', w.slug, 'name', w.name, 'vertical', w.vertical, 'status', w.status,
           'monthly_budget_cents', w.monthly_budget_cents, 'readiness', public.ffm_readiness(w.id)) order by w.created_at)
         from public.client_workspaces w where w.status in ('draft', 'active')), '[]'::jsonb);
end $$;

create or replace function public.app_ffm_inputs(p_ws uuid) returns jsonb
language plpgsql stable security definer set search_path to 'public' as $$
begin
  if not public.is_app_owner() then raise exception 'not authorized' using errcode = '42501'; end if;
  return coalesce((select jsonb_agg(jsonb_build_object('key', i.template_key, 'title', i.title, 'provider', i.provider, 'required', i.required,
           'status', i.status, 'provided_by', i.provided_by, 'blocked_until', i.blocked_until, 'value', i.value_text) order by i.template_key)
         from public.ffm_onboarding_items i where i.workspace_id = p_ws), '[]'::jsonb);
end $$;

create or replace function public.app_ffm_set_budget(p_ws uuid, p_cents integer) returns void
language plpgsql security definer set search_path to 'public' as $$
begin
  if not public.is_app_owner() then raise exception 'not authorized' using errcode = '42501'; end if;
  perform public.ffm_set_budget(p_ws, p_cents);
end $$;

create or replace function public.app_ffm_approve_activation(p_ws uuid, p_note text default null) returns uuid
language plpgsql security definer set search_path to 'public' as $$
begin
  if not public.is_app_owner() then raise exception 'not authorized' using errcode = '42501'; end if;
  return public.ffm_owner_approve(p_ws, 'activation', null, p_note);   -- kind is fixed: this wrapper cannot approve a campaign or a routing rule
end $$;

create or replace function public.app_ffm_revoke_approval(p_approval uuid) returns void
language plpgsql security definer set search_path to 'public' as $$
begin
  if not public.is_app_owner() then raise exception 'not authorized' using errcode = '42501'; end if;
  perform public.ffm_revoke_approval(p_approval);
end $$;

create or replace function public.app_ffm_approve_creative(p_ws uuid, p_creative uuid) returns void
language plpgsql security definer set search_path to 'public' as $$
begin
  if not public.is_app_owner() then raise exception 'not authorized' using errcode = '42501'; end if;
  perform public.ffm_set_creative_status(p_ws, p_creative, 'approved');   -- status only; approving a creative launches nothing
end $$;

create or replace function public.app_ffm_weekly_report(p_ws uuid, p_from timestamptz default null, p_to timestamptz default null) returns jsonb
language plpgsql stable security definer set search_path to 'public' as $$
begin
  if not public.is_app_owner() then raise exception 'not authorized' using errcode = '42501'; end if;
  return public.ffm_weekly_report(p_ws, p_from, p_to);
end $$;

revoke all on function public.app_ffm_workspaces() from public, anon, authenticated;
revoke all on function public.app_ffm_inputs(uuid) from public, anon, authenticated;
revoke all on function public.app_ffm_set_budget(uuid, integer) from public, anon, authenticated;
revoke all on function public.app_ffm_approve_activation(uuid, text) from public, anon, authenticated;
revoke all on function public.app_ffm_revoke_approval(uuid) from public, anon, authenticated;
revoke all on function public.app_ffm_approve_creative(uuid, uuid) from public, anon, authenticated;
revoke all on function public.app_ffm_weekly_report(uuid, timestamptz, timestamptz) from public, anon, authenticated;
grant execute on function public.app_ffm_workspaces() to service_role;
grant execute on function public.app_ffm_inputs(uuid) to service_role;
grant execute on function public.app_ffm_set_budget(uuid, integer) to service_role;
grant execute on function public.app_ffm_approve_activation(uuid, text) to service_role;
grant execute on function public.app_ffm_revoke_approval(uuid) to service_role;
grant execute on function public.app_ffm_approve_creative(uuid, uuid) to service_role;
grant execute on function public.app_ffm_weekly_report(uuid, timestamptz, timestamptz) to service_role;
