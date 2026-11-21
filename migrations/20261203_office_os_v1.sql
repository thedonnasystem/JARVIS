-- FENDEZY GROUP Phase 1, milestone M7 "Office operating system". ADDITIVE. Needs M1 (20261127) .. M5 (20261201).
-- Design (docs/architecture/PHASE1_M7_OFFICE_OS.md):
--   * fz_office_os.fz_office_profiles: ONE template row per office (the 8 M1 offices): mission, allowed agent roles, allowed integrations (keys of
--     scripts/check_integrations.py), autonomy tier defaults (green / yellow / red / prohibited action lists), data-confidentiality class, status
--     (dormant | prepared | active) and the manager (NULL until the owner appoints one; never set by the migration or the bot).
--     It lives in its own schema with NO privilege for any API role (anon, authenticated, service_role, the fz roles): only the functions below reach it.
--     So it is outside the public table registry and the off-site export (like M2's 'secret' tables); a restore re-seeds the 8 offices dormant.
--   * office_os_set_manager / office_os_activate / office_os_deactivate: signed-in owner only (is_app_owner()).
--     Activation, one office at a time: 1st call (manager required) creates an approval item in the M3 queue (approval_requests + the Telegram approval
--     message) and marks the office 'prepared'; the owner taps Approve; 2nd call (manager still required, approval approved and unexpired) sets the M1 office
--     status to active through the unchanged fz_owner_set_office_status() and the profile to 'active'. Rejected / expired -> back to dormant.
--     A table constraint allows at most ONE prepared office, and no active or prepared office without a manager.
--   * office_os_status(office | null): read model for the owner's Telegram /office <name>. Service path only; refuses scoped roles except for their own office.
--   No budgets: offices draw on need through the M2 money functions (allocation, office gate). Dormant / prepared offices are refused by the M2 gate (M1 status).
--   No change to any protected object: money tables, authorize_action, action_policy, kill switch, mode, approval_requests' structure or triggers, consent,
--   redaction, backup classification, the table registry. Function names avoid the fz_ prefix (the M1 rollback drill asserts no public fz_* survives it).
-- Ordered BEFORE the lockdown (R3). Rollback: ops/rollback_office_os.sql (archives the profiles to fz_archive). Safe to re-run.

set lock_timeout = '5s';

create schema if not exists fz_office_os;
revoke all on schema fz_office_os from public;
do $$ declare r text; begin
  foreach r in array array['anon', 'authenticated', 'service_role', 'fz_jarvis', 'fz_office_agent', 'fz_auditor', 'backup_reader'] loop
    if exists (select 1 from pg_roles where rolname = r) then execute format('revoke all on schema fz_office_os from %I', r); end if;
  end loop;
end $$;

create table if not exists fz_office_os.fz_office_profiles (
  office_id uuid primary key,                                             -- M1 fz_offices.id (no foreign key: the M1 / backup lesson)
  slug text not null unique check (slug ~ '^[a-z][a-z0-9-]{1,39}$'),
  mission text not null check (length(mission) between 10 and 600),
  agent_roles text[] not null check (cardinality(agent_roles) between 1 and 12),
  integrations text[] not null check (cardinality(integrations) between 1 and 30),
  autonomy jsonb not null check (jsonb_typeof(autonomy) = 'object' and autonomy - array['green', 'yellow', 'red', 'prohibited'] = '{}'::jsonb
                                 and jsonb_typeof(autonomy -> 'green') = 'array' and jsonb_typeof(autonomy -> 'yellow') = 'array'
                                 and jsonb_typeof(autonomy -> 'red') = 'array' and jsonb_typeof(autonomy -> 'prohibited') = 'array'),
  confidentiality text not null check (confidentiality in ('internal', 'confidential', 'client_restricted')),
  activation_rank integer check (activation_rank between 1 and 8),        -- the owner's approved order (Donna 1, Wolf Squad 2, FF Marketing 3); advisory only
  status text not null default 'dormant' check (status in ('dormant', 'prepared', 'active')),
  manager text check (manager ~ '^[A-Za-z0-9][A-Za-z0-9 ._:-]{0,59}$'),  -- owner-set label; NULL = none appointed
  activation_request uuid,                                                -- approval_requests.id of the current / last activation
  prepared_at timestamptz,
  activated_at timestamptz,
  updated_at timestamptz not null default now(),
  updated_by text not null default 'migration',
  constraint fz_office_profiles_manager_first check (status = 'dormant' or manager is not null),
  constraint fz_office_profiles_prepared_has_request check (status <> 'prepared' or activation_request is not null)
);
create unique index if not exists fz_office_profiles_one_prepared on fz_office_os.fz_office_profiles ((true)) where status = 'prepared';
revoke all on fz_office_os.fz_office_profiles from public;

-- the template for the 8 offices. Owner fields (status, manager, activation) are never touched by a re-run.
insert into fz_office_os.fz_office_profiles (office_id, slug, mission, agent_roles, integrations, autonomy, confidentiality, activation_rank) values
  ('f0000000-0000-4000-8000-000000000001', 'b2b-records', 'Run the B2B Records music label: release planning, catalog and artist content, rollout calendars and distribution prep.', array['label-manager', 'release-planner', 'content-producer', 'ar-scout'], array['telegram', 'supabase', 'anthropic', 'google', 'tiktok', 'meta'], '{"green": ["research", "draft_content", "plan_release"], "yellow": ["schedule_post"], "red": ["publish_content", "sign_artist", "spend", "external_message"], "prohibited": ["buy_streams", "fake_engagement", "unlicensed_samples"]}', 'confidential', null),
  ('f0000000-0000-4000-8000-000000000002', 'donna', 'Run Donna, the AI agency: scope, build and maintain automations for clients, from proposal to delivery and support.', array['agency-manager', 'solutions-architect', 'automation-builder', 'client-success'], array['telegram', 'supabase', 'anthropic', 'vault', 'resend', 'google', 'automation', 'meta'], '{"green": ["research", "draft_proposal", "build_in_sandbox"], "yellow": ["book_meeting"], "red": ["send_email", "client_deliverable", "spend", "contract"], "prohibited": ["email_without_consent", "client_data_outside_office"]}', 'client_restricted', 1),
  ('f0000000-0000-4000-8000-000000000003', 'the-trap', 'Run The Trap: e-commerce product development, sourcing research, listings and store operations.', array['store-manager', 'product-developer', 'merchandiser', 'listing-writer'], array['telegram', 'supabase', 'anthropic', 'meta', 'tiktok'], '{"green": ["research_product", "draft_listing"], "yellow": ["propose_price_test"], "red": ["publish_listing", "supplier_order", "spend", "run_ads"], "prohibited": ["ip_infringing_product", "fake_reviews"]}', 'confidential', null),
  ('f0000000-0000-4000-8000-000000000004', 'wolf-squad', 'Run Wolf Squad: prospecting and sales for the group, from research and lead scoring to booked calls and follow-up.', array['sales-manager', 'prospector', 'sdr', 'closer-assist'], array['telegram', 'supabase', 'anthropic', 'resend', 'google', 'linkedin'], '{"green": ["research_prospect", "score_lead", "draft_outreach"], "yellow": ["log_call", "schedule_follow_up"], "red": ["send_email", "send_dm", "spend"], "prohibited": ["contact_suppressed", "contact_without_consent_basis", "buy_contact_list"]}', 'client_restricted', 2),
  ('f0000000-0000-4000-8000-000000000005', 'pimp-ai', 'Run Pimp AI: AI model brands with compliant content monetization, clearly disclosed as AI and within every platform''s terms.', array['brand-manager', 'persona-designer', 'content-producer', 'compliance-reviewer'], array['telegram', 'supabase', 'anthropic', 'meta', 'tiktok', 'x', 'google'], '{"green": ["persona_research", "draft_content"], "yellow": ["schedule_post"], "red": ["publish_content", "monetization_setup", "spend"], "prohibited": ["sexual_content", "real_person_likeness", "minor_likeness", "undisclosed_ai_persona", "platform_terms_violation"]}', 'confidential', null),
  ('f0000000-0000-4000-8000-000000000006', 'monopoly', 'Run Monopoly, the real estate office: deal research and analysis, offer preparation and buyer and seller pipelines.', array['acquisitions-manager', 'deal-analyst', 'lead-researcher', 'dispositions-assist'], array['telegram', 'supabase', 'anthropic', 'wholesale_db', 'resend', 'google'], '{"green": ["research_property", "analyze_deal"], "yellow": ["draft_offer"], "red": ["send_offer", "contact_seller", "spend"], "prohibited": ["sign_contract", "earnest_money", "misrepresent_authority"]}', 'client_restricted', null),
  ('f0000000-0000-4000-8000-000000000007', 'ff-marketing', 'Run FF Marketing: ads, campaigns and content for the group and its clients, from briefs to approved launches and reporting.', array['marketing-manager', 'campaign-strategist', 'creative-producer', 'analyst'], array['telegram', 'supabase', 'anthropic', 'resend', 'google', 'meta', 'tiktok', 'linkedin', 'x'], '{"green": ["draft_creative", "report_metrics"], "yellow": ["schedule_organic_post"], "red": ["launch_campaign", "ad_spend", "publish_content", "client_message"], "prohibited": ["unapproved_ad_spend", "misleading_claims"]}', 'client_restricted', 3),
  ('f0000000-0000-4000-8000-000000000008', 'fruition-factory', 'Run Fruition Factory: innovation and research, testing new venture ideas cheaply and writing up what to build next.', array['research-lead', 'venture-analyst', 'prototype-builder'], array['telegram', 'supabase', 'anthropic', 'llm_free', 'github'], '{"green": ["research", "write_memo", "build_prototype_in_sandbox"], "yellow": ["open_dev_pr"], "red": ["spend", "launch_venture", "external_message"], "prohibited": ["merge_or_deploy", "production_change"]}', 'internal', null)
on conflict (slug) do update set mission = excluded.mission, agent_roles = excluded.agent_roles, integrations = excluded.integrations, autonomy = excluded.autonomy,
  confidentiality = excluded.confidentiality, activation_rank = excluded.activation_rank, updated_at = now();

-- after a rollback + re-apply: the owner's manager appointments come back from the archive; status follows M1 (active only with a manager), never 'prepared'
do $$ begin
  if to_regclass('fz_archive.fz_office_profiles') is not null then
    execute $q$update fz_office_os.fz_office_profiles p set manager = a.manager, activated_at = a.activated_at, updated_by = 'migration:restore'
                 from fz_archive.fz_office_profiles a where a.slug = p.slug and p.manager is null and a.manager is not null$q$;
  end if;
  update fz_office_os.fz_office_profiles p set status = 'active', updated_by = 'migration:restore'
    from public.fz_offices o where o.id = p.office_id and o.status = 'active' and p.status = 'dormant' and p.manager is not null and p.updated_by = 'migration:restore';
end $$;

-- ---------------------------------------------------------------------------------------------------------------------------- owner: appoint / clear a manager
create or replace function public.office_os_set_manager(p_office text, p_manager text) returns jsonb
language plpgsql security definer set search_path to 'pg_catalog' as $$
declare p fz_office_os.fz_office_profiles; v_m text := nullif(btrim(coalesce(p_manager, '')), '');
begin
  if not coalesce(public.is_app_owner(), false) then raise exception 'owner approval required: managers are appointed by the owner only' using errcode = '42501'; end if;
  perform pg_advisory_xact_lock(hashtext('fz_office_os'));
  select * into p from fz_office_os.fz_office_profiles where slug = p_office for update;
  if not found then raise exception 'unknown office %', p_office; end if;
  if v_m is null and p.status <> 'dormant' then raise exception 'refused: % is %; deactivate it before removing its manager', p.slug, p.status; end if;
  if v_m is not null and v_m !~ '^[A-Za-z0-9][A-Za-z0-9 ._:-]{0,59}$' then raise exception 'manager label: letters, digits, space . _ : - (max 60)'; end if;
  update fz_office_os.fz_office_profiles set manager = v_m, updated_at = now(), updated_by = 'owner' where slug = p.slug;
  insert into public.audit_log (actor, action, target, detail) values ('owner', 'office_manager', 'fz_office_profiles/' || p.slug, jsonb_build_object('appointed', v_m is not null));
  return jsonb_build_object('office', p.slug, 'manager', v_m, 'status', p.status);
end $$;
revoke all on function public.office_os_set_manager(text, text) from public, anon, authenticated;

-- ---------------------------------------------------------------------------------------------------------------------------- owner: activate (two calls around one approval)
create or replace function public.office_os_activate(p_office text) returns jsonb
language plpgsql security definer set search_path to 'pg_catalog' as $$
declare p fz_office_os.fz_office_profiles; o public.fz_offices; r public.approval_requests; v_other text; v_req uuid;
begin
  if not coalesce(public.is_app_owner(), false) then raise exception 'owner approval required: offices are activated by the owner only' using errcode = '42501'; end if;
  perform pg_advisory_xact_lock(hashtext('fz_office_os'));
  select * into p from fz_office_os.fz_office_profiles where slug = p_office for update;
  if not found then raise exception 'unknown office %', p_office; end if;
  select * into o from public.fz_offices where id = p.office_id and kind = 'office';
  if not found then raise exception 'office % is not in the M1 office registry', p.slug; end if;
  if p.status = 'active' and o.status = 'active' then return jsonb_build_object('office', p.slug, 'status', 'active', 'note', 'already active'); end if;
  if p.manager is null then raise exception 'refused: appoint a manager for % first (office_os_set_manager)', p.slug; end if;

  if p.status = 'prepared' then
    select * into r from public.approval_requests where id = p.activation_request;
    if found and r.status = 'approved' and r.expires_at > now() and r.action = 'office_activate' and r.ref = 'office:' || p.slug and r.created_at >= p.prepared_at then
      perform public.fz_owner_set_office_status(p.slug, 'active');          -- M1, unchanged (audited there)
      update fz_office_os.fz_office_profiles set status = 'active', activated_at = now(), updated_at = now(), updated_by = 'owner' where slug = p.slug;
      insert into public.audit_log (actor, action, target, detail)
        values ('owner', 'office_activated', 'fz_office_profiles/' || p.slug, jsonb_build_object('approval', r.id, 'manager_set', true));
      return jsonb_build_object('office', p.slug, 'status', 'active', 'approval', r.id);
    elsif found and r.status = 'pending' and r.expires_at > now() then
      return jsonb_build_object('office', p.slug, 'status', 'prepared', 'approval', r.id, 'next', 'tap Approve on the Telegram approval message, then call office_os_activate again');
    end if;
    update fz_office_os.fz_office_profiles set status = 'dormant', updated_at = now(), updated_by = 'owner' where slug = p.slug;
    insert into public.audit_log (actor, action, target, detail)
      values ('owner', 'office_activation_lapsed', 'fz_office_profiles/' || p.slug, jsonb_build_object('approval', p.activation_request, 'approval_status', coalesce(r.status, 'missing')));
    return jsonb_build_object('office', p.slug, 'status', 'dormant', 'note', 'the activation approval was ' || coalesce(r.status, 'missing') || ' or expired; call again to ask again');
  end if;

  -- dormant (or active in the profile but not in M1): one office at a time
  select slug into v_other from fz_office_os.fz_office_profiles where status = 'prepared' and slug <> p.slug limit 1;
  if v_other is not null then raise exception 'refused: one office at a time: % is waiting on its activation approval', v_other; end if;
  insert into public.approval_requests (actor, action, cents, ref, recommendation, expires_at)
    values ('jarvis', 'office_activate', 0, 'office:' || p.slug,
            format('Activate office %s (%s). Manager: %s. Mission: %s Activation only opens the office; every spend still needs an allocation and every red action your approval.',
                   o.title, p.slug, p.manager, p.mission), now() + interval '3 days')
    returning id into v_req;
  insert into public.owner_messages (from_agent, kind, channel, body, needs_decision, ref_table, ref_id)
    values ('jarvis', 'proposal', 'telegram', format('Activate office %s? Manager: %s. Approve, then run office_os_activate(%L) again in the SQL editor.', o.title, p.manager, p.slug),
            true, 'approval_requests', v_req);
  update fz_office_os.fz_office_profiles set status = 'prepared', activation_request = v_req, prepared_at = now(), updated_at = now(), updated_by = 'owner' where slug = p.slug;
  insert into public.audit_log (actor, action, target, detail)
    values ('owner', 'office_activation_requested', 'fz_office_profiles/' || p.slug, jsonb_build_object('approval', v_req));
  return jsonb_build_object('office', p.slug, 'status', 'prepared', 'approval', v_req, 'next', 'tap Approve on the Telegram approval message, then call office_os_activate again');
end $$;
revoke all on function public.office_os_activate(text) from public, anon, authenticated;

-- ---------------------------------------------------------------------------------------------------------------------------- owner: deactivate / cancel
create or replace function public.office_os_deactivate(p_office text) returns jsonb
language plpgsql security definer set search_path to 'pg_catalog' as $$
declare p fz_office_os.fz_office_profiles;
begin
  if not coalesce(public.is_app_owner(), false) then raise exception 'owner approval required: offices are deactivated by the owner only' using errcode = '42501'; end if;
  perform pg_advisory_xact_lock(hashtext('fz_office_os'));
  select * into p from fz_office_os.fz_office_profiles where slug = p_office for update;
  if not found then raise exception 'unknown office %', p_office; end if;
  if exists (select 1 from public.fz_offices where id = p.office_id and status = 'active') then perform public.fz_owner_set_office_status(p.slug, 'dormant'); end if;
  update fz_office_os.fz_office_profiles set status = 'dormant', updated_at = now(), updated_by = 'owner' where slug = p.slug;
  insert into public.audit_log (actor, action, target, detail) values ('owner', 'office_deactivated', 'fz_office_profiles/' || p.slug, jsonb_build_object('was', p.status));
  return jsonb_build_object('office', p.slug, 'status', 'dormant');
end $$;
revoke all on function public.office_os_deactivate(text) from public, anon, authenticated;

-- ---------------------------------------------------------------------------------------------------------------------------- read model (/office <name>)
-- p_office NULL = one line per office. Service path (bot, database session). A scoped role (only if granted by mistake) sees its own office, nothing else.
create or replace function public.office_os_status(p_office text default null) returns jsonb
language plpgsql stable security definer set search_path to 'pg_catalog' as $$
declare v_role text := coalesce(nullif(current_setting('role', true), ''), 'none'); v_own uuid; out jsonb := '[]'::jsonb; x record; v_av bigint; r public.approval_requests;
begin
  if v_role in ('fz_jarvis', 'fz_office_agent', 'fz_auditor') then
    v_own := public.current_office_id();
    if v_own is null or p_office is null or not exists (select 1 from fz_office_os.fz_office_profiles where slug = p_office and office_id = v_own) then
      raise exception 'refused: a scoped identity may only read its own office' using errcode = '42501';
    end if;
  elsif v_role not in ('none', 'postgres', 'service_role') then
    raise exception 'refused' using errcode = '42501';
  end if;
  for x in select p.*, o.title, o.status as m1_status from fz_office_os.fz_office_profiles p left join public.fz_offices o on o.id = p.office_id
            where p_office is null or p.slug = p_office order by coalesce(p.activation_rank, 99), p.slug loop
    v_av := null;
    begin
      execute 'select available_cents from public.fz_office_money where office = $1' into v_av using x.slug;   -- M2, late-bound: absent = null
    exception when others then v_av := null; end;
    select * into r from public.approval_requests where id = x.activation_request;
    out := out || jsonb_build_object('office', x.slug, 'title', x.title, 'status', x.status, 'm1_status', x.m1_status,
             'drift', (x.m1_status = 'active') <> (x.status = 'active'),
             'manager', x.manager, 'activation_rank', x.activation_rank, 'approval_status', r.status,
             'available_cents', v_av, 'mission', x.mission, 'agent_roles', to_jsonb(x.agent_roles), 'integrations', to_jsonb(x.integrations),
             'autonomy', x.autonomy, 'confidentiality', x.confidentiality, 'activated_at', x.activated_at);
  end loop;
  if p_office is not null and jsonb_array_length(out) = 0 then raise exception 'unknown office %', p_office; end if;
  return case when p_office is null then out else out -> 0 end;
end $$;
revoke all on function public.office_os_status(text) from public, anon, authenticated;
do $$ declare r text; begin
  foreach r in array array['fz_jarvis', 'fz_office_agent', 'fz_auditor', 'backup_reader'] loop
    if exists (select 1 from pg_roles where rolname = r) then
      execute format('revoke all on function public.office_os_set_manager(text, text) from %I', r);
      execute format('revoke all on function public.office_os_activate(text) from %I', r);
      execute format('revoke all on function public.office_os_deactivate(text) from %I', r);
      execute format('revoke all on function public.office_os_status(text) from %I', r);
    end if;
  end loop;
end $$;
