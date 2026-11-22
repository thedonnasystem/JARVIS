-- FENDEZY GROUP Phase 1, milestone M7 "Office operating system". ADDITIVE. Needs M1 (20261127) .. M6 (20261202).
-- Design (docs/architecture/PHASE1_M7_OFFICE_OS.md):
--   * fz_office_os.fz_office_profiles: ONE template row per office (the 8 M1 offices): mission, allowed agent roles, allowed integrations (keys of
--     scripts/check_integrations.py), autonomy tier defaults (green / yellow / red / prohibited action lists), data-confidentiality class, status
--     (dormant | prepared | active) and the manager (NULL until the owner appoints one; never set by the migration or the bot).
--     The schema fz_office_os has NO privilege for any API role (anon, authenticated, service_role, the fz roles): only the functions below reach it.
--     So it is outside the public table registry and the off-site export (like M2's 'secret' tables); a restore re-seeds the 8 offices dormant.
--   * office_os_set_manager / office_os_activate / office_os_decide / office_os_deactivate: signed-in owner only (is_app_owner()).
--     Activation, one office at a time, three owner steps:
--       1. office_os_activate (manager required): an approval item in the M3 queue (approval_requests + an informational Telegram note) and a single-use
--          64-hex nonce in fz_office_os.fz_office_decisions (no API privileges: the service key can neither read nor write it); the office is 'prepared'.
--       2. office_os_decide(office, nonce, approve): records the owner's decision there (once); mirrors it onto the approval item for the queue.
--       3. office_os_activate again: requires THAT decision (approved, unconsumed, unexpired, same request), consumes it, applies every prohibited entry
--          that is a real action_policy action as an office block (fz_set_office_policy, tighten only), sets M1 active through the unchanged
--          fz_owner_set_office_status(). The approval_requests status is never trusted (the service key can write it). Rejected / expired -> dormant.
--     Constraints: at most ONE prepared office; no prepared or active office without a manager.
--   * office_os_status(office | null): read model for the owner's /office <name> (service path; a scoped role only its own office).
--   * office_os_drift_check() (pg_cron, every 10 minutes): alerts the owner ONCE per change when M1's office status and the profile disagree
--     (e.g. an office set active directly with fz_owner_set_office_status, skipping the manager / decision steps); the M1 function is not changed.
--   * client invoicing (fz_office_invoices, office_os_invoice_*): drafts recorded per office; a send needs the owner's per-invoice decision; no refund / payout path.
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

create table if not exists fz_office_os.fz_office_decisions (            -- the owner's activation decisions; no API privileges
  request_id uuid primary key,                                            -- approval_requests.id of the activation item
  slug text not null,
  nonce text not null check (nonce ~ '^[0-9a-f]{64}$'),
  created_at timestamptz not null default now(),
  expires_at timestamptz not null,
  approved boolean,                                                       -- NULL until the owner decides
  decided_at timestamptz,
  consumed_at timestamptz,
  constraint fz_office_decisions_consumed_needs_approval check (consumed_at is null or approved)
);
revoke all on fz_office_os.fz_office_decisions from public;
create table if not exists fz_office_os.fz_office_drift (                -- change-only drift alert state
  slug text primary key,
  state text,                                                             -- 'm1=<status>/profile=<status>' while drifting, NULL when in sync
  changed_at timestamptz not null default now(),
  alerts integer not null default 0
);
revoke all on fz_office_os.fz_office_drift from public;

-- the template for the 8 offices. Owner fields (status, manager, activation) are never touched by a re-run.
insert into fz_office_os.fz_office_profiles (office_id, slug, mission, agent_roles, integrations, autonomy, confidentiality, activation_rank) values
  ('f0000000-0000-4000-8000-000000000001', 'b2b-records', 'Run the B2B Records music label: release planning, catalog and artist content, rollout calendars and distribution prep.', array['label-manager', 'release-planner', 'content-producer', 'ar-scout'], array['telegram', 'supabase', 'anthropic', 'google', 'tiktok', 'meta'], '{"green": ["research", "draft_content", "plan_release"], "yellow": ["schedule_post"], "red": ["publish_content", "sign_artist", "spend", "external_message"], "prohibited": ["buy_streams", "fake_engagement", "unlicensed_samples", "fabricate", "evade_platform_restrictions"]}', 'confidential', null),
  ('f0000000-0000-4000-8000-000000000002', 'donna', 'Run Donna, the AI agency: scope, build and maintain automations for clients, from proposal to delivery and support.', array['agency-manager', 'solutions-architect', 'automation-builder', 'client-success'], array['telegram', 'supabase', 'anthropic', 'vault', 'resend', 'google', 'automation', 'meta', 'stripe'], '{"green": ["research", "draft_proposal", "build_in_sandbox"], "yellow": ["book_meeting"], "red": ["send_email", "client_deliverable", "spend", "contract"], "prohibited": ["email_without_consent", "client_data_outside_office", "deceptive_communication"]}', 'client_restricted', 1),
  ('f0000000-0000-4000-8000-000000000003', 'the-trap', 'Run The Trap: e-commerce product development, sourcing research, listings and store operations.', array['store-manager', 'product-developer', 'merchandiser', 'listing-writer'], array['telegram', 'supabase', 'anthropic', 'meta', 'tiktok'], '{"green": ["research_product", "draft_listing"], "yellow": ["propose_price_test"], "red": ["publish_listing", "supplier_order", "spend", "run_ads"], "prohibited": ["ip_infringing_product", "fake_reviews", "fabricate"]}', 'confidential', null),
  ('f0000000-0000-4000-8000-000000000004', 'wolf-squad', 'Run Wolf Squad: prospecting and sales for the group, from research and lead scoring to booked calls and follow-up.', array['sales-manager', 'prospector', 'sdr', 'closer-assist'], array['telegram', 'supabase', 'anthropic', 'resend', 'google', 'linkedin'], '{"green": ["research_prospect", "score_lead", "draft_outreach"], "yellow": ["log_call", "schedule_follow_up"], "red": ["send_email", "send_dm", "spend"], "prohibited": ["contact_suppressed", "contact_without_consent_basis", "buy_contact_list", "deceptive_communication"]}', 'client_restricted', 2),
  ('f0000000-0000-4000-8000-000000000005', 'pimp-ai', 'Run Pimp AI: AI model brands with compliant content monetization, clearly disclosed as AI and within every platform''s terms.', array['brand-manager', 'persona-designer', 'content-producer', 'compliance-reviewer'], array['telegram', 'supabase', 'anthropic', 'meta', 'tiktok', 'x', 'google'], '{"green": ["persona_research", "draft_content"], "yellow": ["schedule_post"], "red": ["publish_content", "monetization_setup", "spend"], "prohibited": ["sexual_content", "real_person_likeness", "minor_likeness", "undisclosed_ai_persona", "platform_terms_violation", "deceptive_communication", "evade_platform_restrictions"]}', 'confidential', null),
  ('f0000000-0000-4000-8000-000000000006', 'monopoly', 'Run Monopoly, the real estate office: deal research and analysis, offer preparation and buyer and seller pipelines.', array['acquisitions-manager', 'deal-analyst', 'lead-researcher', 'dispositions-assist'], array['telegram', 'supabase', 'anthropic', 'wholesale_db', 'resend', 'google'], '{"green": ["research_property", "analyze_deal"], "yellow": ["draft_offer"], "red": ["send_offer", "contact_seller", "spend"], "prohibited": ["sign_contract", "financial_transfer", "earnest_money", "misrepresent_authority"]}', 'client_restricted', null),
  ('f0000000-0000-4000-8000-000000000007', 'ff-marketing', 'Run FF Marketing: ads, campaigns and content for the group and its clients, from briefs to approved launches and reporting.', array['marketing-manager', 'campaign-strategist', 'creative-producer', 'analyst'], array['telegram', 'supabase', 'anthropic', 'resend', 'google', 'meta', 'tiktok', 'linkedin', 'x'], '{"green": ["draft_creative", "report_metrics"], "yellow": ["schedule_organic_post"], "red": ["launch_campaign", "ad_spend", "publish_content", "client_message"], "prohibited": ["unapproved_ad_spend", "misleading_claims", "spend_outside_budget", "deceptive_communication"]}', 'client_restricted', 3),
  ('f0000000-0000-4000-8000-000000000008', 'fruition-factory', 'Run Fruition Factory: innovation and research, testing new venture ideas cheaply and writing up what to build next.', array['research-lead', 'venture-analyst', 'prototype-builder'], array['telegram', 'supabase', 'anthropic', 'llm_free', 'github'], '{"green": ["research", "write_memo", "build_prototype_in_sandbox"], "yellow": ["open_dev_pr"], "red": ["spend", "launch_venture", "external_message"], "prohibited": ["merge_or_deploy", "production_change", "deploy_website", "modify_own_permissions"]}', 'internal', null)
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

-- ---------------------------------------------------------------------------------------------------------------------------- owner: activate (request, then finish)
create or replace function public.office_os_activate(p_office text) returns jsonb
language plpgsql security definer set search_path to 'pg_catalog' as $$
declare p fz_office_os.fz_office_profiles; o public.fz_offices; d fz_office_os.fz_office_decisions; v_other text; v_req uuid; v_nonce text; a text; v_blocked text[] := '{}';
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
    -- ONLY the owner's recorded decision counts (fz_office_os: no API privileges). approval_requests.status is never read: the service key can write it.
    select * into d from fz_office_os.fz_office_decisions where request_id = p.activation_request for update;
    if found and d.slug = p.slug and d.approved and d.consumed_at is null and d.expires_at > now() then
      update fz_office_os.fz_office_decisions set consumed_at = now() where request_id = d.request_id;
      -- the prohibited defaults that are real action_policy actions become office blocks (tighten only; the rest stay advisory)
      foreach a in array array(select jsonb_array_elements_text(p.autonomy -> 'prohibited')) loop
        if exists (select 1 from public.action_policy where action = a) then
          perform public.fz_set_office_policy(p.slug, a, false, null, null, 'office_os');
          v_blocked := v_blocked || a;
        end if;
      end loop;
      perform public.fz_owner_set_office_status(p.slug, 'active');          -- M1, unchanged (audited there)
      update fz_office_os.fz_office_profiles set status = 'active', activated_at = now(), updated_at = now(), updated_by = 'owner' where slug = p.slug;
      insert into public.audit_log (actor, action, target, detail)
        values ('owner', 'office_activated', 'fz_office_profiles/' || p.slug, jsonb_build_object('approval', d.request_id, 'office_blocks', to_jsonb(v_blocked)));
      return jsonb_build_object('office', p.slug, 'status', 'active', 'approval', d.request_id, 'office_blocks', to_jsonb(v_blocked));
    elsif found and d.slug = p.slug and d.approved is null and d.expires_at > now() then
      return jsonb_build_object('office', p.slug, 'status', 'prepared', 'approval', d.request_id, 'nonce', d.nonce,
                                'next', format('office_os_decide(%L, <nonce>, true), then office_os_activate(%L) again', p.slug, p.slug));
    end if;
    update fz_office_os.fz_office_profiles set status = 'dormant', updated_at = now(), updated_by = 'owner' where slug = p.slug;
    insert into public.audit_log (actor, action, target, detail)
      values ('owner', 'office_activation_lapsed', 'fz_office_profiles/' || p.slug,
              jsonb_build_object('approval', p.activation_request, 'decision', case when d.request_id is null then 'missing' when d.approved is false then 'rejected'
                                                                                    when d.consumed_at is not null then 'used' else 'expired' end));
    return jsonb_build_object('office', p.slug, 'status', 'dormant', 'note', 'the activation was rejected or expired; call again to ask again');
  end if;

  -- dormant (or active in the profile but not in M1): one office at a time
  select slug into v_other from fz_office_os.fz_office_profiles where status = 'prepared' and slug <> p.slug limit 1;
  if v_other is not null then raise exception 'refused: one office at a time: % is waiting on its activation decision', v_other; end if;
  insert into public.approval_requests (actor, action, cents, ref, recommendation, expires_at)
    values ('jarvis', 'office_activate', 0, 'office:' || p.slug,
            format('Activate office %s (%s). Manager: %s. Mission: %s Activation only opens the office; every spend still needs an allocation and every red action your approval.',
                   o.title, p.slug, p.manager, p.mission), now() + interval '3 days')
    returning id into v_req;
  v_nonce := replace(gen_random_uuid()::text, '-', '') || replace(gen_random_uuid()::text, '-', '');
  insert into fz_office_os.fz_office_decisions (request_id, slug, nonce, expires_at) values (v_req, p.slug, v_nonce, now() + interval '3 days');
  insert into public.owner_messages (from_agent, kind, channel, body, needs_decision, ref_table, ref_id)
    values ('jarvis', 'proposal', 'telegram',
            format('Office %s is waiting for your activation decision (manager: %s). Decide in the SQL editor with office_os_decide; a tap here does not activate it.', o.title, p.manager),
            false, 'approval_requests', v_req);
  update fz_office_os.fz_office_profiles set status = 'prepared', activation_request = v_req, prepared_at = now(), updated_at = now(), updated_by = 'owner' where slug = p.slug;
  insert into public.audit_log (actor, action, target, detail)
    values ('owner', 'office_activation_requested', 'fz_office_profiles/' || p.slug, jsonb_build_object('approval', v_req));
  return jsonb_build_object('office', p.slug, 'status', 'prepared', 'approval', v_req, 'nonce', v_nonce,
                            'next', format('office_os_decide(%L, <nonce>, true), then office_os_activate(%L) again', p.slug, p.slug));
end $$;
revoke all on function public.office_os_activate(text) from public, anon, authenticated;

-- ---------------------------------------------------------------------------------------------------------------------------- owner: the decision (single-use nonce)
create or replace function public.office_os_decide(p_office text, p_nonce text, p_approved boolean) returns jsonb
language plpgsql security definer set search_path to 'pg_catalog' as $$
declare p fz_office_os.fz_office_profiles; d fz_office_os.fz_office_decisions;
begin
  if not coalesce(public.is_app_owner(), false) then raise exception 'owner approval required: activation decisions are the owner''s only' using errcode = '42501'; end if;
  perform pg_advisory_xact_lock(hashtext('fz_office_os'));
  select * into p from fz_office_os.fz_office_profiles where slug = p_office;
  if not found then raise exception 'unknown office %', p_office; end if;
  select * into d from fz_office_os.fz_office_decisions where request_id = p.activation_request for update;
  if p.status <> 'prepared' or not found or d.slug <> p.slug then raise exception 'refused: % has no activation waiting for a decision', p.slug; end if;
  if d.approved is not null then return jsonb_build_object('office', p.slug, 'ok', false, 'reason', 'already decided'); end if;
  if d.expires_at <= now() then raise exception 'refused: the activation request for % expired; ask again', p.slug; end if;
  if p_nonce is null or p_nonce <> d.nonce then raise exception 'refused: wrong nonce' using errcode = '42501'; end if;
  update fz_office_os.fz_office_decisions set approved = coalesce(p_approved, false), decided_at = now() where request_id = d.request_id;
  update public.approval_requests set status = case when coalesce(p_approved, false) then 'approved' else 'rejected' end, decided_at = now()
   where id = d.request_id and status = 'pending';                         -- mirror for the M3 queue only; never read back
  insert into public.audit_log (actor, action, target, detail)
    values ('owner', 'office_activation_decided', 'fz_office_profiles/' || p.slug, jsonb_build_object('approval', d.request_id, 'approved', coalesce(p_approved, false)));
  return jsonb_build_object('office', p.slug, 'ok', true, 'approved', coalesce(p_approved, false),
                            'next', case when coalesce(p_approved, false) then format('office_os_activate(%L)', p.slug) else 'none: the office returns to dormant on the next office_os_activate' end);
end $$;
revoke all on function public.office_os_decide(text, text, boolean) from public, anon, authenticated;

-- ---------------------------------------------------------------------------------------------------------------------------- drift alert (change-only)
create or replace function public.office_os_drift_check() returns integer
language plpgsql security definer set search_path to 'pg_catalog' as $$
declare v_role text := coalesce(nullif(current_setting('role', true), ''), 'none'); x record; v_state text; old fz_office_os.fz_office_drift; n int := 0;
begin
  if v_role not in ('none', 'postgres', 'service_role') then raise exception 'refused' using errcode = '42501'; end if;
  for x in select p.slug, p.status, p.manager, o.title, o.status as m1 from fz_office_os.fz_office_profiles p join public.fz_offices o on o.id = p.office_id loop
    v_state := case when (x.m1 = 'active') <> (x.status = 'active') then 'm1=' || x.m1 || '/profile=' || x.status end;
    select * into old from fz_office_os.fz_office_drift where slug = x.slug;
    continue when found and old.state is not distinct from v_state;
    continue when not found and v_state is null;
    insert into fz_office_os.fz_office_drift (slug, state, changed_at, alerts) values (x.slug, v_state, now(), case when v_state is null then 0 else 1 end)
      on conflict (slug) do update set state = excluded.state, changed_at = now(), alerts = fz_office_os.fz_office_drift.alerts + excluded.alerts;
    insert into public.audit_log (actor, action, target, detail)
      values ('office_os', case when v_state is null then 'office_drift_cleared' else 'office_drift' end, 'fz_office_profiles/' || x.slug, jsonb_build_object('state', v_state, 'manager_set', x.manager is not null));
    if v_state is not null and exists (select 1 from public.agents where slug = 'jarvis') then
      insert into public.owner_messages (from_agent, kind, channel, body)
        values ('jarvis', 'health', 'telegram', format('DRIFT: office %s is %s in M1 but %s in the office OS%s. Check /office %s; deactivate with office_os_deactivate if this was not you.',
                                                        x.title, x.m1, x.status, case when x.manager is null then ' (no manager appointed)' else '' end, x.slug));
    end if;
    n := n + 1;
  end loop;
  return n;
end $$;
revoke all on function public.office_os_drift_check() from public, anon, authenticated;
do $$ begin
  if exists (select 1 from pg_namespace where nspname = 'cron') then
    perform cron.unschedule(jobid) from cron.job where jobname = 'office-os-drift';
    perform cron.schedule('office-os-drift', '*/10 * * * *', 'select public.office_os_drift_check()');
  end if;
end $$;

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

-- ---------------------------------------------------------------------------------------------------------------------------- client invoicing (Donna bills clients)
-- hq_invoices.py drafts Stripe invoices / payment links (behind FZ_STRIPE_INVOICING=1) and records each one here against its office. Drafting is free; FINALIZING / SENDING
-- an invoice to a client is an external communication: it needs the owner's per-invoice decision (office_os_invoice_decide, signed-in owner only, amount echoed),
-- which the service key cannot write (this schema has no API privileges). Incoming money is revenue only: there is no refund, payout or transfer path anywhere.
create table if not exists fz_office_os.fz_office_invoices (
  id uuid primary key default gen_random_uuid(),
  office_id uuid not null,
  slug text not null,
  kind text not null check (kind in ('invoice', 'payment_link')),
  stripe_id text not null unique check (stripe_id ~ '^(in|plink)_[A-Za-z0-9]{6,64}$'),
  mode text not null check (mode in ('test', 'live')),
  cents integer not null check (cents > 0 and cents <= 10000000),
  currency text not null check (currency ~ '^[a-z]{3}$'),
  description text not null default '' check (length(description) <= 300),
  status text not null default 'draft' check (status in ('draft', 'send_requested', 'approved', 'rejected', 'sending', 'sent', 'send_failed')),
  approval_request uuid,
  decided_at timestamptz,
  sent_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint fz_office_invoices_link_never_sent check (kind = 'invoice' or status = 'draft')
);
revoke all on fz_office_os.fz_office_invoices from public;
alter table fz_office_os.fz_office_invoices add column if not exists customer_id text check (customer_id is null or customer_id ~ '^cus_[A-Za-z0-9]{6,64}$');

drop function if exists public.office_os_invoice_record(text, text, text, text, integer, text, text);
create or replace function public.office_os_invoice_record(p_office text, p_kind text, p_customer text, p_stripe_id text, p_mode text, p_cents integer, p_currency text, p_description text default '') returns jsonb
language plpgsql security definer set search_path to 'pg_catalog' as $$
declare v_role text := coalesce(nullif(current_setting('role', true), ''), 'none'); p fz_office_os.fz_office_profiles; v_id uuid;
begin
  if v_role not in ('none', 'postgres', 'service_role') then raise exception 'refused' using errcode = '42501'; end if;
  select * into p from fz_office_os.fz_office_profiles where slug = p_office;
  if not found then raise exception 'unknown office %', p_office; end if;
  if p.status <> 'active' or not exists (select 1 from public.fz_offices where id = p.office_id and status = 'active') then
    raise exception 'refused: % is not active', p.slug using errcode = '42501'; end if;
  if not ('stripe' = any (p.integrations)) then raise exception 'refused: stripe is not an allowed integration of %', p.slug using errcode = '42501'; end if;
  if p_kind = 'invoice' and coalesce(p_customer, '') !~ '^cus_[A-Za-z0-9]{6,64}$' then raise exception 'refused: an invoice needs its Stripe customer id (cus_...)'; end if;
  insert into fz_office_os.fz_office_invoices (office_id, slug, kind, customer_id, stripe_id, mode, cents, currency, description)
    values (p.office_id, p.slug, p_kind, case when p_kind = 'invoice' then p_customer end, p_stripe_id, p_mode, p_cents, lower(p_currency), left(regexp_replace(coalesce(p_description, ''), '[[:cntrl:]]+', ' ', 'g'), 300))
    returning id into v_id;
  insert into public.audit_log (actor, action, target, detail)
    values ('office_os', 'invoice_drafted', 'fz_office_invoices/' || v_id, jsonb_build_object('office', p.slug, 'kind', p_kind, 'mode', p_mode, 'cents', p_cents, 'currency', lower(p_currency)));
  perform fz_office_os.log_event(p.slug, null, v_id, 'drafted', 'office_os', jsonb_build_object('kind', p_kind, 'mode', p_mode, 'cents', p_cents, 'currency', lower(p_currency)));
  return jsonb_build_object('invoice', v_id, 'status', 'draft');
end $$;
revoke all on function public.office_os_invoice_record(text, text, text, text, text, integer, text, text) from public, anon, authenticated;

create or replace function public.office_os_invoice_request_send(p_invoice uuid) returns jsonb
language plpgsql security definer set search_path to 'pg_catalog' as $$
declare v_role text := coalesce(nullif(current_setting('role', true), ''), 'none'); i fz_office_os.fz_office_invoices; v_req uuid;
begin
  if v_role not in ('none', 'postgres', 'service_role') then raise exception 'refused' using errcode = '42501'; end if;
  select * into i from fz_office_os.fz_office_invoices where id = p_invoice for update;
  if not found then raise exception 'unknown invoice'; end if;
  if i.kind <> 'invoice' then raise exception 'refused: a payment link is never sent by the bot; the owner shares it' using errcode = '42501'; end if;
  if i.status <> 'draft' then return jsonb_build_object('invoice', i.id, 'ok', false, 'reason', 'status is ' || i.status); end if;
  if not exists (select 1 from fz_office_os.fz_office_profiles p join public.fz_offices o on o.id = p.office_id where p.slug = i.slug and p.status = 'active' and o.status = 'active') then
    raise exception 'refused: % is not active', i.slug using errcode = '42501'; end if;
  insert into public.approval_requests (actor, action, cents, ref, recommendation, expires_at)
    values ('jarvis', 'client_invoice_send', i.cents, 'invoice:' || i.id,
            format('Send %s invoice %s to Stripe customer %s for %s %s (%s mode). Decide with office_os_invoice_decide in the SQL editor.', i.slug, i.stripe_id, i.customer_id, to_char(i.cents / 100.0, 'FM999,999,990.00'), upper(i.currency), i.mode),
            now() + interval '7 days') returning id into v_req;
  insert into public.owner_messages (from_agent, kind, channel, body, needs_decision, ref_table, ref_id)
    values ('jarvis', 'proposal', 'telegram', format('Invoice waiting for your send decision: %s %s %s to customer %s (%s). Decide in the SQL editor (office_os_invoice_decide); a tap here does not send it.',
            i.slug, to_char(i.cents / 100.0, 'FM999,999,990.00'), upper(i.currency), i.customer_id, i.mode), false, 'approval_requests', v_req);
  update fz_office_os.fz_office_invoices set status = 'send_requested', approval_request = v_req, updated_at = now() where id = i.id;
  insert into public.audit_log (actor, action, target, detail) values ('office_os', 'invoice_send_requested', 'fz_office_invoices/' || i.id, jsonb_build_object('approval', v_req));
  perform fz_office_os.log_event(i.slug, i.plan_id, i.id, 'requested', 'office_os', jsonb_build_object('approval', v_req));
  return jsonb_build_object('invoice', i.id, 'ok', true, 'status', 'send_requested', 'approval', v_req);
end $$;
revoke all on function public.office_os_invoice_request_send(uuid) from public, anon, authenticated;

-- the owner's per-invoice decision; p_cents must echo the recorded amount (so a changed invoice cannot ride on an old decision)
create or replace function public.office_os_invoice_decide(p_invoice uuid, p_cents integer, p_approved boolean) returns jsonb
language plpgsql security definer set search_path to 'pg_catalog' as $$
declare i fz_office_os.fz_office_invoices;
begin
  if not coalesce(public.is_app_owner(), false) then raise exception 'owner approval required: invoice sends are the owner''s decision' using errcode = '42501'; end if;
  select * into i from fz_office_os.fz_office_invoices where id = p_invoice for update;
  if not found then raise exception 'unknown invoice'; end if;
  if i.status <> 'send_requested' then raise exception 'refused: the invoice is %, not waiting for a send decision', i.status; end if;
  if p_cents is distinct from i.cents then raise exception 'refused: amount does not match the recorded invoice (% cents)', i.cents; end if;
  update fz_office_os.fz_office_invoices set status = case when coalesce(p_approved, false) then 'approved' else 'rejected' end, decided_at = now(), updated_at = now() where id = i.id;
  update public.approval_requests set status = case when coalesce(p_approved, false) then 'approved' else 'rejected' end, decided_at = now() where id = i.approval_request and status = 'pending';
  insert into public.audit_log (actor, action, target, detail) values ('owner', 'invoice_send_decided', 'fz_office_invoices/' || i.id, jsonb_build_object('approved', coalesce(p_approved, false)));
  perform fz_office_os.log_event(i.slug, i.plan_id, i.id, case when coalesce(p_approved, false) then 'approved' else 'cancelled' end, 'owner');
  return jsonb_build_object('invoice', i.id, 'status', case when coalesce(p_approved, false) then 'approved' else 'rejected' end);
end $$;
revoke all on function public.office_os_invoice_decide(uuid, integer, boolean) from public, anon, authenticated;

-- the bot claims ONE approved send (approved -> sending, once), then reports the Stripe result (sending -> sent | send_failed)
create or replace function public.office_os_invoice_claim_send(p_invoice uuid) returns jsonb
language plpgsql security definer set search_path to 'pg_catalog' as $$
declare v_role text := coalesce(nullif(current_setting('role', true), ''), 'none'); i fz_office_os.fz_office_invoices;
begin
  if v_role not in ('none', 'postgres', 'service_role') then raise exception 'refused' using errcode = '42501'; end if;
  select * into i from fz_office_os.fz_office_invoices where id = p_invoice for update;
  if not found then raise exception 'unknown invoice'; end if;
  if i.status <> 'approved' then raise exception 'refused: invoice % has no owner send approval (status %)', i.stripe_id, i.status using errcode = '42501'; end if;
  if i.plan_id is not null and not exists (select 1 from fz_office_os.fz_billing_plans where id = i.plan_id and status = 'approved' and cents = i.cents and currency = i.currency) then
    raise exception 'refused: the billing plan of invoice % is no longer approved', i.stripe_id using errcode = '42501'; end if;
  if not exists (select 1 from fz_office_os.fz_office_profiles p join public.fz_offices o on o.id = p.office_id where p.slug = i.slug and p.status = 'active' and o.status = 'active') then
    raise exception 'refused: % is not active', i.slug using errcode = '42501'; end if;
  update fz_office_os.fz_office_invoices set status = 'sending', updated_at = now() where id = i.id;
  return jsonb_build_object('invoice', i.id, 'stripe_id', i.stripe_id, 'mode', i.mode, 'cents', i.cents, 'currency', i.currency, 'plan', i.plan_id, 'period', i.period, 'customer', i.customer_id);
end $$;
revoke all on function public.office_os_invoice_claim_send(uuid) from public, anon, authenticated;

create or replace function public.office_os_invoice_mark_sent(p_invoice uuid, p_ok boolean) returns jsonb
language plpgsql security definer set search_path to 'pg_catalog' as $$
declare v_role text := coalesce(nullif(current_setting('role', true), ''), 'none'); i fz_office_os.fz_office_invoices;
begin
  if v_role not in ('none', 'postgres', 'service_role') then raise exception 'refused' using errcode = '42501'; end if;
  select * into i from fz_office_os.fz_office_invoices where id = p_invoice for update;
  if not found or i.status <> 'sending' then raise exception 'refused: invoice is not being sent'; end if;
  update fz_office_os.fz_office_invoices set status = case when coalesce(p_ok, false) then 'sent' else 'send_failed' end,
         sent_at = case when coalesce(p_ok, false) then now() end, updated_at = now() where id = i.id;
  insert into public.audit_log (actor, action, target, detail) values ('office_os', case when coalesce(p_ok, false) then 'invoice_sent' else 'invoice_send_failed' end,
                                                                     'fz_office_invoices/' || i.id, jsonb_build_object('stripe_id', i.stripe_id, 'mode', i.mode));
  perform fz_office_os.log_event(i.slug, i.plan_id, i.id, case when coalesce(p_ok, false) then 'sent' else 'failed' end, 'office_os', jsonb_build_object('stripe_id', i.stripe_id, 'mode', i.mode));
  return jsonb_build_object('invoice', i.id, 'status', case when coalesce(p_ok, false) then 'sent' else 'send_failed' end);
end $$;
revoke all on function public.office_os_invoice_mark_sent(uuid, boolean) from public, anon, authenticated;

create or replace function public.office_os_invoices(p_limit integer default 20) returns jsonb
language sql stable security definer set search_path to 'pg_catalog' as $$
  select case when coalesce(nullif(current_setting('role', true), ''), 'none') in ('none', 'postgres', 'service_role') then
    coalesce((select jsonb_agg(jsonb_build_object('id', x.id, 'office', x.slug, 'kind', x.kind, 'customer', x.customer_id, 'stripe_id', x.stripe_id, 'mode', x.mode, 'cents', x.cents, 'currency', x.currency,
                                                  'description', x.description, 'status', x.status, 'created_at', x.created_at) order by x.created_at desc)
              from (select * from fz_office_os.fz_office_invoices order by created_at desc limit least(greatest(coalesce(p_limit, 20), 1), 100)) x), '[]'::jsonb)
  else null end
$$;
revoke all on function public.office_os_invoices(integer) from public, anon, authenticated;

-- billing plans: the owner approves a client's plan ONCE (client label, Stripe customer, amount, currency, interval); each period's invoice of exactly that plan is then
-- recorded as approved and sent without another tap. A different amount or interval, a second invoice in the same period, a one-off, or a revoked plan: refused here
-- (a one-off goes through the per-invoice decision above).
create table if not exists fz_office_os.fz_billing_plans (
  id uuid primary key default gen_random_uuid(),
  office_id uuid not null,
  slug text not null,
  client_label text not null check (client_label ~ '^[A-Za-z0-9][A-Za-z0-9 &.,''-]{1,79}$'),
  customer_id text not null check (customer_id ~ '^cus_[A-Za-z0-9]{6,64}$'),
  cents integer not null check (cents > 0 and cents <= 10000000),
  currency text not null check (currency ~ '^[a-z]{3}$'),
  billing_interval text not null check (billing_interval in ('month', 'year')),
  status text not null default 'proposed' check (status in ('proposed', 'approved', 'rejected', 'revoked')),
  approval_request uuid,
  decided_at timestamptz,
  revoked_at timestamptz,
  created_at timestamptz not null default now()
);
revoke all on fz_office_os.fz_billing_plans from public;
alter table fz_office_os.fz_office_invoices add column if not exists plan_id uuid;
alter table fz_office_os.fz_office_invoices add column if not exists period text;
create unique index if not exists fz_office_invoices_one_per_period on fz_office_os.fz_office_invoices (plan_id, period) where plan_id is not null;

create or replace function public.office_os_plan_propose(p_office text, p_client_label text, p_customer text, p_cents integer, p_currency text, p_interval text) returns jsonb
language plpgsql security definer set search_path to 'pg_catalog' as $$
declare v_role text := coalesce(nullif(current_setting('role', true), ''), 'none'); p fz_office_os.fz_office_profiles; v_id uuid; v_req uuid;
begin
  if v_role not in ('none', 'postgres', 'service_role') then raise exception 'refused' using errcode = '42501'; end if;
  select * into p from fz_office_os.fz_office_profiles where slug = p_office;
  if not found then raise exception 'unknown office %', p_office; end if;
  if p.status <> 'active' or not exists (select 1 from public.fz_offices where id = p.office_id and status = 'active') then raise exception 'refused: % is not active', p.slug using errcode = '42501'; end if;
  if not ('stripe' = any (p.integrations)) then raise exception 'refused: stripe is not an allowed integration of %', p.slug using errcode = '42501'; end if;
  insert into fz_office_os.fz_billing_plans (office_id, slug, client_label, customer_id, cents, currency, billing_interval)
    values (p.office_id, p.slug, p_client_label, p_customer, p_cents, lower(p_currency), p_interval) returning id into v_id;
  insert into public.approval_requests (actor, action, cents, ref, recommendation, expires_at)
    values ('jarvis', 'client_billing_plan', p_cents, 'plan:' || v_id,
            format('Approve billing plan for %s (%s): %s %s every %s. Afterwards each %s invoice of exactly this amount is sent without asking you. Decide with office_os_plan_decide.',
                   p_client_label, p.slug, to_char(p_cents / 100.0, 'FM999,999,990.00'), upper(p_currency), p_interval, p_interval), now() + interval '7 days') returning id into v_req;
  insert into public.owner_messages (from_agent, kind, channel, body, needs_decision, ref_table, ref_id)
    values ('jarvis', 'proposal', 'telegram', format('Billing plan waiting for your decision: %s, %s %s per %s. Decide in the SQL editor (office_os_plan_decide).', p_client_label,
            to_char(p_cents / 100.0, 'FM999,999,990.00'), upper(p_currency), p_interval), false, 'approval_requests', v_req);
  update fz_office_os.fz_billing_plans set approval_request = v_req where id = v_id;
  insert into public.audit_log (actor, action, target, detail) values ('office_os', 'billing_plan_proposed', 'fz_billing_plans/' || v_id, jsonb_build_object('office', p.slug, 'cents', p_cents, 'interval', p_interval));
  perform fz_office_os.log_event(p.slug, v_id, null, 'requested', 'office_os', jsonb_build_object('cents', p_cents, 'interval', p_interval));
  return jsonb_build_object('plan', v_id, 'status', 'proposed', 'approval', v_req);
end $$;
revoke all on function public.office_os_plan_propose(text, text, text, integer, text, text) from public, anon, authenticated;

-- owner only; amount AND interval echoed
create or replace function public.office_os_plan_decide(p_plan uuid, p_cents integer, p_interval text, p_approved boolean) returns jsonb
language plpgsql security definer set search_path to 'pg_catalog' as $$
declare b fz_office_os.fz_billing_plans;
begin
  if not coalesce(public.is_app_owner(), false) then raise exception 'owner approval required: billing plans are the owner''s decision' using errcode = '42501'; end if;
  select * into b from fz_office_os.fz_billing_plans where id = p_plan for update;
  if not found then raise exception 'unknown plan'; end if;
  if b.status <> 'proposed' then raise exception 'refused: the plan is %', b.status; end if;
  if p_cents is distinct from b.cents or p_interval is distinct from b.billing_interval then raise exception 'refused: amount or interval does not match the proposed plan'; end if;
  update fz_office_os.fz_billing_plans set status = case when coalesce(p_approved, false) then 'approved' else 'rejected' end, decided_at = now() where id = b.id;
  update public.approval_requests set status = case when coalesce(p_approved, false) then 'approved' else 'rejected' end, decided_at = now() where id = b.approval_request and status = 'pending';
  insert into public.audit_log (actor, action, target, detail) values ('owner', 'billing_plan_decided', 'fz_billing_plans/' || b.id, jsonb_build_object('approved', coalesce(p_approved, false)));
  perform fz_office_os.log_event(b.slug, b.id, null, case when coalesce(p_approved, false) then 'approved' else 'cancelled' end, 'owner');
  return jsonb_build_object('plan', b.id, 'status', case when coalesce(p_approved, false) then 'approved' else 'rejected' end);
end $$;
revoke all on function public.office_os_plan_decide(uuid, integer, text, boolean) from public, anon, authenticated;

-- revoking only makes things safer: the owner, or the service path (e.g. the client cancelled)
create or replace function public.office_os_plan_revoke(p_plan uuid) returns jsonb
language plpgsql security definer set search_path to 'pg_catalog' as $$
declare v_role text := coalesce(nullif(current_setting('role', true), ''), 'none'); b fz_office_os.fz_billing_plans;
begin
  if v_role not in ('none', 'postgres', 'service_role') and not coalesce(public.is_app_owner(), false) then raise exception 'refused' using errcode = '42501'; end if;
  update fz_office_os.fz_billing_plans set status = 'revoked', revoked_at = now() where id = p_plan and status in ('proposed', 'approved', 'past_due') returning * into b;
  if not found then raise exception 'refused: no open plan %', p_plan; end if;
  insert into public.audit_log (actor, action, target, detail) values (case when coalesce(public.is_app_owner(), false) then 'owner' else 'office_os' end, 'billing_plan_revoked', 'fz_billing_plans/' || b.id, '{}'::jsonb);
  perform fz_office_os.log_event(b.slug, b.id, null, 'cancelled', case when coalesce(public.is_app_owner(), false) then 'owner' else 'office_os' end, '{"refund": false}'::jsonb);
  return jsonb_build_object('plan', b.id, 'status', 'revoked');
end $$;
revoke all on function public.office_os_plan_revoke(uuid) from public, anon, authenticated;

-- this period's invoice of an approved plan: exactly the plan's amount, currency and interval, the CURRENT period only, once per period; recorded as approved
drop function if exists public.office_os_invoice_record_plan(uuid, text, text, integer, text, text);
create or replace function public.office_os_invoice_record_plan(p_plan uuid, p_customer text, p_stripe_id text, p_mode text, p_cents integer, p_currency text, p_interval text) returns jsonb
language plpgsql security definer set search_path to 'pg_catalog' as $$
declare v_role text := coalesce(nullif(current_setting('role', true), ''), 'none'); b fz_office_os.fz_billing_plans; v_period text; v_id uuid;
begin
  if v_role not in ('none', 'postgres', 'service_role') then raise exception 'refused' using errcode = '42501'; end if;
  select * into b from fz_office_os.fz_billing_plans where id = p_plan for update;
  if not found then raise exception 'unknown plan'; end if;
  if b.status <> 'approved' then raise exception 'refused: plan is % (no automatic invoice)', b.status using errcode = '42501'; end if;
  if p_cents is distinct from b.cents or lower(p_currency) is distinct from b.currency then raise exception 'refused: amount differs from the approved plan (% %): needs a per-invoice decision', b.cents, b.currency using errcode = '42501'; end if;
  if p_interval is distinct from b.billing_interval then raise exception 'refused: interval differs from the approved plan (%): needs a per-invoice decision', b.billing_interval using errcode = '42501'; end if;
  if p_customer is distinct from b.customer_id then raise exception 'refused: the Stripe invoice''s customer is not the approved plan''s customer' using errcode = '42501'; end if;
  if not exists (select 1 from fz_office_os.fz_office_profiles p join public.fz_offices o on o.id = p.office_id where p.slug = b.slug and p.status = 'active' and o.status = 'active') then
    raise exception 'refused: % is not active', b.slug using errcode = '42501'; end if;
  v_period := case b.billing_interval when 'month' then to_char(now() at time zone 'America/Toronto', 'YYYY-MM') else to_char(now() at time zone 'America/Toronto', 'YYYY') end;
  if exists (select 1 from fz_office_os.fz_office_invoices where plan_id = b.id and period = v_period) then
    raise exception 'refused: plan already invoiced for %', v_period using errcode = '42501'; end if;
  insert into fz_office_os.fz_office_invoices (office_id, slug, kind, customer_id, stripe_id, mode, cents, currency, description, status, plan_id, period, decided_at)
    values (b.office_id, b.slug, 'invoice', b.customer_id, p_stripe_id, p_mode, b.cents, b.currency, left(b.client_label || ' ' || v_period, 300), 'approved', b.id, v_period, now())
    returning id into v_id;
  insert into public.audit_log (actor, action, target, detail)
    values ('office_os', 'invoice_drafted', 'fz_office_invoices/' || v_id, jsonb_build_object('office', b.slug, 'plan', b.id, 'period', v_period, 'cents', b.cents, 'mode', p_mode, 'auto_approved_by_plan', true));
  perform fz_office_os.log_event(b.slug, b.id, v_id, 'drafted', 'office_os', jsonb_build_object('period', v_period, 'cents', b.cents));
  perform fz_office_os.log_event(b.slug, b.id, v_id, 'approved', 'plan', jsonb_build_object('period', v_period));
  return jsonb_build_object('invoice', v_id, 'status', 'approved', 'period', v_period);
end $$;
revoke all on function public.office_os_invoice_record_plan(uuid, text, text, text, integer, text, text) from public, anon, authenticated;

create or replace function public.office_os_plans() returns jsonb
language sql stable security definer set search_path to 'pg_catalog' as $$
  select case when coalesce(nullif(current_setting('role', true), ''), 'none') in ('none', 'postgres', 'service_role') then
    coalesce((select jsonb_agg(jsonb_build_object('id', b.id, 'office', b.slug, 'client', b.client_label, 'customer', b.customer_id, 'cents', b.cents, 'currency', b.currency,
                                                  'interval', b.billing_interval, 'status', b.status,
                                                  'last_invoice', (select jsonb_build_object('id', i.id, 'stripe_id', i.stripe_id, 'period', i.period, 'status', i.status, 'sent_at', i.sent_at, 'mode', i.mode)
                                                                     from fz_office_os.fz_office_invoices i where i.plan_id = b.id order by i.created_at desc limit 1))
                                    order by b.created_at desc) from fz_office_os.fz_billing_plans b), '[]'::jsonb)
  else null end
$$;
revoke all on function public.office_os_plans() from public, anon, authenticated;

-- billing hardening: an append-only billing log, payment-failure stop (past_due, owner-only resume), owner-only cancellation (never a refund), paid observation
create table if not exists fz_office_os.fz_billing_log (
  id bigserial primary key,
  at timestamptz not null default now(),
  slug text not null,
  plan_id uuid,
  invoice_id uuid,
  event text not null check (event in ('requested', 'drafted', 'approved', 'sent', 'paid', 'failed', 'cancelled', 'past_due', 'resumed')),
  by_whom text not null,
  detail jsonb not null default '{}'::jsonb
);
revoke all on fz_office_os.fz_billing_log from public;
revoke all on sequence fz_office_os.fz_billing_log_id_seq from public;
create or replace function fz_office_os.billing_log_append_only() returns trigger
language plpgsql set search_path to 'pg_catalog' as $$
begin
  raise exception 'fz_billing_log is append-only' using errcode = '42501';
end $$;
revoke all on function fz_office_os.billing_log_append_only() from public, anon, authenticated;
drop trigger if exists fz_billing_log_append_only on fz_office_os.fz_billing_log;
create trigger fz_billing_log_append_only before update or delete on fz_office_os.fz_billing_log for each row execute function fz_office_os.billing_log_append_only();
drop trigger if exists fz_billing_log_no_truncate on fz_office_os.fz_billing_log;
create trigger fz_billing_log_no_truncate before truncate on fz_office_os.fz_billing_log for each statement execute function fz_office_os.billing_log_append_only();
create or replace function fz_office_os.log_event(p_slug text, p_plan uuid, p_invoice uuid, p_event text, p_by text, p_detail jsonb default '{}'::jsonb) returns void
language sql set search_path to 'pg_catalog' as $$
  insert into fz_office_os.fz_billing_log (slug, plan_id, invoice_id, event, by_whom, detail) values (p_slug, p_plan, p_invoice, p_event, p_by, coalesce(p_detail, '{}'::jsonb))
$$;
revoke all on function fz_office_os.log_event(text, uuid, uuid, text, text, jsonb) from public, anon, authenticated;

alter table fz_office_os.fz_billing_plans drop constraint if exists fz_billing_plans_status_check;
alter table fz_office_os.fz_billing_plans add constraint fz_billing_plans_status_check check (status in ('proposed', 'approved', 'rejected', 'revoked', 'past_due', 'cancelled'));
alter table fz_office_os.fz_billing_plans add column if not exists past_due_at timestamptz;
alter table fz_office_os.fz_billing_plans add column if not exists cancelled_at timestamptz;

-- owner only, immediate: no future period is billed, nothing is refunded
create or replace function public.office_os_plan_cancel(p_plan uuid) returns jsonb
language plpgsql security definer set search_path to 'pg_catalog' as $$
declare b fz_office_os.fz_billing_plans;
begin
  if not coalesce(public.is_app_owner(), false) then raise exception 'owner approval required: only the owner cancels a billing plan' using errcode = '42501'; end if;
  update fz_office_os.fz_billing_plans set status = 'cancelled', cancelled_at = now() where id = p_plan and status in ('proposed', 'approved', 'past_due') returning * into b;
  if not found then raise exception 'refused: no open plan %', p_plan; end if;
  perform fz_office_os.log_event(b.slug, b.id, null, 'cancelled', 'owner', jsonb_build_object('refund', false));
  insert into public.audit_log (actor, action, target, detail) values ('owner', 'billing_plan_cancelled', 'fz_billing_plans/' || b.id, '{"refund": false}'::jsonb);
  return jsonb_build_object('plan', b.id, 'status', 'cancelled', 'refund', false);
end $$;
revoke all on function public.office_os_plan_cancel(uuid) from public, anon, authenticated;

-- payment failure: the service path stops the plan (once) and tells the owner; only the owner resumes it
create or replace function public.office_os_plan_past_due(p_plan uuid, p_reason text) returns jsonb
language plpgsql security definer set search_path to 'pg_catalog' as $$
declare v_role text := coalesce(nullif(current_setting('role', true), ''), 'none'); b fz_office_os.fz_billing_plans;
begin
  if v_role not in ('none', 'postgres', 'service_role') then raise exception 'refused' using errcode = '42501'; end if;
  update fz_office_os.fz_billing_plans set status = 'past_due', past_due_at = now() where id = p_plan and status = 'approved' returning * into b;
  if not found then return jsonb_build_object('plan', p_plan, 'changed', false); end if;     -- already stopped: no second alert
  perform fz_office_os.log_event(b.slug, b.id, null, 'past_due', 'office_os', jsonb_build_object('reason', left(coalesce(p_reason, ''), 200)));
  insert into public.audit_log (actor, action, target, detail) values ('office_os', 'billing_plan_past_due', 'fz_billing_plans/' || b.id, jsonb_build_object('reason', left(coalesce(p_reason, ''), 200)));
  if exists (select 1 from public.agents where slug = 'jarvis') then
    insert into public.owner_messages (from_agent, kind, channel, body)
      values ('jarvis', 'money', 'telegram', format('Billing stopped: %s plan for %s is past due (%s). No more automatic invoices until you resume it (office_os_plan_resume) or cancel it.',
                                                    b.slug, b.client_label, left(coalesce(p_reason, ''), 120)));
  end if;
  return jsonb_build_object('plan', b.id, 'changed', true, 'status', 'past_due');
end $$;
revoke all on function public.office_os_plan_past_due(uuid, text) from public, anon, authenticated;

create or replace function public.office_os_plan_resume(p_plan uuid) returns jsonb
language plpgsql security definer set search_path to 'pg_catalog' as $$
declare b fz_office_os.fz_billing_plans;
begin
  if not coalesce(public.is_app_owner(), false) then raise exception 'owner approval required: only the owner resumes a stopped plan' using errcode = '42501'; end if;
  update fz_office_os.fz_billing_plans set status = 'approved', past_due_at = null where id = p_plan and status = 'past_due' returning * into b;
  if not found then raise exception 'refused: plan % is not past due', p_plan; end if;
  perform fz_office_os.log_event(b.slug, b.id, null, 'resumed', 'owner');
  insert into public.audit_log (actor, action, target, detail) values ('owner', 'billing_plan_resumed', 'fz_billing_plans/' || b.id, '{}'::jsonb);
  return jsonb_build_object('plan', b.id, 'status', 'approved');
end $$;
revoke all on function public.office_os_plan_resume(uuid) from public, anon, authenticated;

-- what Stripe says about a sent invoice: 'paid' is logged once (revenue only: nothing is booked or moved here); 'uncollectible' / overdue are logged as failed
create or replace function public.office_os_invoice_observe(p_invoice uuid, p_stripe_status text) returns jsonb
language plpgsql security definer set search_path to 'pg_catalog' as $$
declare v_role text := coalesce(nullif(current_setting('role', true), ''), 'none'); i fz_office_os.fz_office_invoices; v_event text;
begin
  if v_role not in ('none', 'postgres', 'service_role') then raise exception 'refused' using errcode = '42501'; end if;
  select * into i from fz_office_os.fz_office_invoices where id = p_invoice;
  if not found or i.status <> 'sent' then raise exception 'refused: only a sent invoice is observed'; end if;
  v_event := case when p_stripe_status = 'paid' then 'paid' when p_stripe_status in ('uncollectible', 'past_due', 'overdue') then 'failed' else null end;
  if v_event is null or exists (select 1 from fz_office_os.fz_billing_log where invoice_id = i.id and event = v_event) then
    return jsonb_build_object('invoice', i.id, 'logged', false);
  end if;
  perform fz_office_os.log_event(i.slug, i.plan_id, i.id, v_event, 'stripe', jsonb_build_object('stripe_status', p_stripe_status, 'cents', i.cents, 'currency', i.currency));
  return jsonb_build_object('invoice', i.id, 'logged', true, 'event', v_event);
end $$;
revoke all on function public.office_os_invoice_observe(uuid, text) from public, anon, authenticated;

create or replace function public.office_os_billing_log(p_limit integer default 30) returns jsonb
language sql stable security definer set search_path to 'pg_catalog' as $$
  select case when coalesce(nullif(current_setting('role', true), ''), 'none') in ('none', 'postgres', 'service_role') then
    coalesce((select jsonb_agg(jsonb_build_object('at', l.at, 'office', l.slug, 'plan', l.plan_id, 'invoice', l.invoice_id, 'event', l.event, 'by', l.by_whom, 'detail', l.detail) order by l.id desc)
              from (select * from fz_office_os.fz_billing_log order by id desc limit least(greatest(coalesce(p_limit, 30), 1), 200)) l), '[]'::jsonb)
  else null end
$$;
revoke all on function public.office_os_billing_log(integer) from public, anon, authenticated;

-- ---------------------------------------------------------------------------------------------------------------------------- read model (/office <name>)
-- p_office NULL = one line per office. Service path (bot, database session). A scoped role (only if granted by mistake) sees its own office, nothing else.
create or replace function public.office_os_status(p_office text default null) returns jsonb
language plpgsql stable security definer set search_path to 'pg_catalog' as $$
declare v_role text := coalesce(nullif(current_setting('role', true), ''), 'none'); v_own uuid; out jsonb := '[]'::jsonb; x record; v_av bigint; r public.approval_requests; dr fz_office_os.fz_office_drift;
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
    select * into dr from fz_office_os.fz_office_drift where slug = x.slug;
    out := out || jsonb_build_object('office', x.slug, 'title', x.title, 'status', x.status, 'm1_status', x.m1_status,
             'drift', (x.m1_status = 'active') <> (x.status = 'active'), 'drift_alerted_at', case when dr.state is not null then dr.changed_at end,
             'prohibited_enforced', coalesce((select jsonb_agg(e order by e) from jsonb_array_elements_text(x.autonomy -> 'prohibited') e where exists (select 1 from public.action_policy ap where ap.action = e)), '[]'::jsonb),
             'prohibited_advisory', coalesce((select jsonb_agg(e order by e) from jsonb_array_elements_text(x.autonomy -> 'prohibited') e where not exists (select 1 from public.action_policy ap where ap.action = e)), '[]'::jsonb),
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
      execute format('revoke all on function public.office_os_decide(text, text, boolean) from %I', r);
      execute format('revoke all on function public.office_os_drift_check() from %I', r);
      execute format('revoke all on function public.office_os_invoice_record(text, text, text, text, text, integer, text, text) from %I', r);
      execute format('revoke all on function public.office_os_invoice_request_send(uuid) from %I', r);
      execute format('revoke all on function public.office_os_invoice_decide(uuid, integer, boolean) from %I', r);
      execute format('revoke all on function public.office_os_invoice_claim_send(uuid) from %I', r);
      execute format('revoke all on function public.office_os_invoice_mark_sent(uuid, boolean) from %I', r);
      execute format('revoke all on function public.office_os_invoices(integer) from %I', r);
      execute format('revoke all on function public.office_os_plan_propose(text, text, text, integer, text, text) from %I', r);
      execute format('revoke all on function public.office_os_plan_decide(uuid, integer, text, boolean) from %I', r);
      execute format('revoke all on function public.office_os_plan_revoke(uuid) from %I', r);
      execute format('revoke all on function public.office_os_invoice_record_plan(uuid, text, text, text, integer, text, text) from %I', r);
      execute format('revoke all on function public.office_os_plans() from %I', r);
      execute format('revoke all on function public.office_os_plan_cancel(uuid) from %I', r);
      execute format('revoke all on function public.office_os_plan_past_due(uuid, text) from %I', r);
      execute format('revoke all on function public.office_os_plan_resume(uuid) from %I', r);
      execute format('revoke all on function public.office_os_invoice_observe(uuid, text) from %I', r);
      execute format('revoke all on function public.office_os_billing_log(integer) from %I', r);
      execute format('revoke all on function public.office_os_deactivate(text) from %I', r);
      execute format('revoke all on function public.office_os_status(text) from %I', r);
    end if;
  end loop;
end $$;
