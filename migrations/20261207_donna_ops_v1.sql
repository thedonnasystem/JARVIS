-- FENDEZY GROUP: "Donna Ops v1": what Donna's own agents need to run her office once the owner activates her. ADDITIVE. Needs M1..M7, venture_deals_replies
-- (leads / deals / lead_funnel / venture_kpis), client workspaces, the FFM consent path and Donna Receptionist v1 (20261206). Design: docs/architecture/DONNA_OPS_V1.md.
--   * schema fz_donna (NO API privileges): runs (every mission run of Donna's agents), drafts (outreach / offer / report drafts, owner approval only, NO send path
--     exists: there is no 'sent' status), intakes (client intake -> receptionist config + Web Studio site.json DRAFTS), golive (owner sign-off before a client
--     goes live), reports (one weekly KPI report per ISO week).
--   * DORMANT until the owner activates Donna: every agent-side function refuses unless the Donna office is active (M1 status AND the M7 profile).
--   * The mission -> action map is fixed here (fz_donna.mission_actions); a run is refused unless that action is in Donna's GREEN tier and not prohibited.
--     The 8 enforced prohibited actions (sign_contract, financial_transfer, deceptive_communication, fabricate, evade_platform_restrictions, spend_outside_budget,
--     deploy_website, modify_own_permissions) are refused by name, whatever the profile says. Nothing here can change a permission, a tier or a profile.
--   * CASL on every outreach draft (not legal advice: the owner or counsel confirms): sender identification, a mailing address, an unsubscribe line (email / DM),
--     no "Re:" / "Fwd:" subject, no guarantee / refund promise, no payment request, no request to sign; a draft for a lead needs a recorded consent basis,
--     a lead that is not do_not_contact and an address / number that is not suppressed (is_suppressed / ffm_is_phone_suppressed, called, not changed).
--     A draft with an "[OWNER: ...]" placeholder cannot be approved.
--   * CRM: the existing public.leads / deals of the 'donna' venture (Donna's own prospects) and client_workspaces (her clients). Read through lead_funnel /
--     venture_kpis (called, not changed). Next actions are computed, not stored.
--   * Nothing here moves money, sends anything external or deploys anything. The weekly report is an owner_messages row (the owner's own Telegram).
-- Function names avoid the fz_ prefix (the M1 rollback drill). Ordered BEFORE the lockdown. Rollback: ops/rollback_donna_ops.sql. Safe to re-run.

set lock_timeout = '5s';

create schema if not exists fz_donna;
revoke all on schema fz_donna from public;
do $$ declare r text; begin
  foreach r in array array['anon', 'authenticated', 'service_role', 'fz_jarvis', 'fz_office_agent', 'fz_auditor', 'backup_reader'] loop
    if exists (select 1 from pg_roles where rolname = r) then execute format('revoke all on schema fz_donna from %I', r); end if;
  end loop;
end $$;

-- the fixed mission -> action map (candidates in order; the first one in Donna's green tier is used)
create table if not exists fz_donna.mission_actions (
  mission text primary key check (mission ~ '^[a-z][a-z0-9-]{2,40}$'),
  actions text[] not null check (cardinality(actions) between 1 and 4),
  writes text[] not null default '{}'
);
revoke all on fz_donna.mission_actions from public;
insert into fz_donna.mission_actions (mission, actions, writes) values
  ('market-research', array['market_validation', 'research'], array['niche_report']),
  ('offer-pricing', array['draft_offer', 'draft_proposal'], array['offer_review']),
  ('outreach-prep', array['draft_outreach', 'draft_proposal'], array['cold_email', 'dm', 'call_script', 'follow_up_email']),
  ('delivery-onboarding', array['build_in_sandbox'], array['intake']),
  ('weekly-report', array['research'], array['weekly_report'])
on conflict (mission) do update set actions = excluded.actions, writes = excluded.writes;

create table if not exists fz_donna.runs (
  id uuid primary key default gen_random_uuid(),
  mission text not null references fz_donna.mission_actions (mission),
  action text not null,
  status text not null default 'running' check (status in ('running', 'done', 'failed')),
  summary text check (summary is null or length(summary) <= 2000),
  output jsonb check (output is null or length(output::text) <= 60000),
  sources jsonb not null default '[]'::jsonb check (jsonb_typeof(sources) = 'array' and length(sources::text) <= 30000),
  llm_cents integer not null default 0 check (llm_cents = 0),                     -- spend_outside_budget: Donna's agents run on the free brain only
  started_at timestamptz not null default now(),
  finished_at timestamptz
);
revoke all on fz_donna.runs from public;

create table if not exists fz_donna.drafts (
  id uuid primary key default gen_random_uuid(),
  run_id uuid references fz_donna.runs (id),
  kind text not null check (kind in ('cold_email', 'dm', 'call_script', 'follow_up_email', 'offer_review', 'niche_report', 'weekly_report')),
  channel text check (channel is null or channel in ('email', 'dm', 'call')),
  lead_id uuid references public.leads (id),
  subject text check (subject is null or length(subject) <= 200),
  body text not null check (length(body) between 20 and 12000),
  status text not null default 'draft' check (status in ('draft', 'owner_approved', 'owner_rejected', 'superseded')),   -- no 'sent': drafts are never sent from here
  casl jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  decided_at timestamptz,
  decided_by text,
  note text check (note is null or length(note) <= 500)
);
revoke all on fz_donna.drafts from public;
create index if not exists donna_drafts_status on fz_donna.drafts (status, created_at);

create table if not exists fz_donna.intakes (
  id uuid primary key default gen_random_uuid(),
  run_id uuid references fz_donna.runs (id),
  client_label text not null check (client_label ~ '^[A-Za-z0-9][A-Za-z0-9 &.,''-]{1,79}$'),
  lead_id uuid references public.leads (id),
  workspace_id uuid references public.client_workspaces (id),
  reception_config jsonb not null check (jsonb_typeof(reception_config) = 'object' and reception_config ?& array['business_name', 'timezone', 'hours', 'services', 'faqs',
                                                'escalation_number', 'booking', 'voice'] and length(reception_config::text) <= 20000),
  site_json jsonb not null check (jsonb_typeof(site_json) = 'object' and length(site_json::text) <= 40000),
  open_items jsonb not null default '[]'::jsonb,
  status text not null default 'draft' check (status in ('draft', 'owner_approved', 'owner_rejected', 'applied')),
  created_at timestamptz not null default now(),
  decided_at timestamptz
);
revoke all on fz_donna.intakes from public;

create table if not exists fz_donna.golive (                                      -- the owner's sign-off before a receptionist client goes live
  slug text primary key,
  demo_tested boolean not null,
  client_approved boolean not null,
  number_webhooks_set boolean not null,
  signed_at timestamptz not null default now(),
  signed_by text not null
);
revoke all on fz_donna.golive from public;

create table if not exists fz_donna.reports (
  week text primary key check (week ~ '^[0-9]{4}-W[0-9]{2}$'),
  body text not null,
  kpis jsonb not null,
  message_id uuid,
  created_at timestamptz not null default now()
);
revoke all on fz_donna.reports from public;

-- ---------------------------------------------------------------------------------------------------------------------------- helpers
create or replace function fz_donna.service_path() returns boolean
language sql stable set search_path to 'pg_catalog' as $$
  select coalesce(nullif(current_setting('role', true), ''), 'none') in ('none', 'postgres', 'service_role')
$$;
revoke all on function fz_donna.service_path() from public, anon, authenticated;
create or replace function fz_donna.guard() returns void
language plpgsql stable set search_path to 'pg_catalog' as $$
begin
  if not fz_donna.service_path() then raise exception 'refused' using errcode = '42501'; end if;
end $$;
revoke all on function fz_donna.guard() from public, anon, authenticated;
create or replace function fz_donna.active() returns boolean
language sql stable set search_path to 'pg_catalog' as $$
  select exists (select 1 from public.fz_offices o where o.slug = 'donna' and o.kind = 'office' and o.status = 'active'
                   and (to_regclass('fz_office_os.fz_office_profiles') is null
                        or exists (select 1 from fz_office_os.fz_office_profiles p where p.office_id = o.id and p.status = 'active')))
$$;
revoke all on function fz_donna.active() from public, anon, authenticated;
create or replace function fz_donna.require_active() returns void
language plpgsql stable set search_path to 'pg_catalog' as $$
begin
  if not fz_donna.active() then raise exception 'refused: Donna is dormant; nothing runs until the owner activates her (office_os_activate)' using errcode = '42501'; end if;
end $$;
revoke all on function fz_donna.require_active() from public, anon, authenticated;
create or replace function fz_donna.owner_only(p_what text) returns void
language plpgsql stable set search_path to 'pg_catalog' as $$
begin
  if not coalesce(public.is_app_owner(), false) then raise exception 'owner approval required: % is the owner''s decision', p_what using errcode = '42501'; end if;
end $$;
revoke all on function fz_donna.owner_only(text) from public, anon, authenticated;
-- the enforced prohibited list: these 8 by name (always), plus whatever Donna's profile lists
create or replace function fz_donna.prohibited() returns text[]
language sql stable set search_path to 'pg_catalog' as $$
  select array(select distinct x from unnest(array['sign_contract', 'financial_transfer', 'deceptive_communication', 'fabricate', 'evade_platform_restrictions',
                                                   'spend_outside_budget', 'deploy_website', 'modify_own_permissions']
                                             || coalesce((select array(select jsonb_array_elements_text(p.autonomy -> 'prohibited')) from fz_office_os.fz_office_profiles p
                                                           where p.slug = 'donna' and to_regclass('fz_office_os.fz_office_profiles') is not null), '{}'::text[])) x order by x)
$$;
revoke all on function fz_donna.prohibited() from public, anon, authenticated;
create or replace function fz_donna.green() returns text[]
language sql stable set search_path to 'pg_catalog' as $$
  select coalesce((select array(select jsonb_array_elements_text(p.autonomy -> 'green')) from fz_office_os.fz_office_profiles p where p.slug = 'donna'), '{}'::text[])
$$;
revoke all on function fz_donna.green() from public, anon, authenticated;
create or replace function fz_donna.donna_venture() returns uuid
language sql stable set search_path to 'pg_catalog' as $$
  select id from public.ventures where slug = 'donna' limit 1
$$;
revoke all on function fz_donna.donna_venture() from public, anon, authenticated;

-- CASL / honesty problems of one outreach text (empty = ok). The Python checker (hq_donna.casl_problems) is stricter; this is the floor.
create or replace function fz_donna.text_problems(p_kind text, p_subject text, p_body text) returns text[]
language plpgsql immutable set search_path to 'pg_catalog' as $$
declare b text := lower(coalesce(p_body, '')); s text := lower(btrim(coalesce(p_subject, ''))); out text[] := '{}';
begin
  if p_kind in ('cold_email', 'follow_up_email', 'dm') then
    if b !~ 'donna' then out := out || 'sender identification (Donna and who she sends for) is missing'::text; end if;
    if b !~ '(mailing address|\[owner: mailing address|[0-9]+ [a-z0-9 .''-]+ (street|st\.?|avenue|ave\.?|road|rd\.?|boulevard|blvd\.?|drive|dr\.?|way|crescent|cres\.?)\b)' then
      out := out || 'a mailing address is missing'::text; end if;
    if b !~ '(unsubscribe|opt out|opt-out|reply stop|reply "stop"|reply ''stop'')' then out := out || 'an unsubscribe line is missing'::text; end if;
  end if;
  if p_kind = 'call_script' then
    if b !~ 'donna' then out := out || 'the caller must say who they are and who they call for'::text; end if;
    if b !~ '(do not call|do-not-call|remove (you|your number)|take you off)' then out := out || 'a remove-me (do-not-call) line is missing'::text; end if;
  end if;
  if s ~ '^(re|fw|fwd)\s*:' then out := out || 'a "Re:" / "Fwd:" subject pretends to an earlier conversation (deceptive_communication)'::text; end if;
  if b ~ '(guarantee|refund|risk[- ]free|money[- ]back)' or s ~ '(guarantee|refund|risk[- ]free|money[- ]back)' then
    out := out || 'no guarantee or refund promise (guarantee terms are TBD by the owner)'::text; end if;
  if b ~ '(e-?transfer|wire (the|a) |send (the )?payment|pay (now|today)|credit card number|card number)' then out := out || 'no payment request in outreach (financial_transfer)'::text; end if;
  if b ~ '(e-?sign|sign (the|this|our) (contract|agreement)|docusign)' then out := out || 'no request to sign (sign_contract)'::text; end if;
  if b ~ '(as (we|i) (discussed|promised)|per our (call|conversation)|following up on our (call|chat|conversation))' and p_kind in ('cold_email', 'dm', 'call_script') then
    out := out || 'a first message cannot claim an earlier conversation (deceptive_communication)'::text; end if;
  if b ~ '(i am|i''m) (a real person|not a (bot|robot|ai))' then out := out || 'never claim to be human (deceptive_communication)'::text; end if;
  return out;
end $$;
revoke all on function fz_donna.text_problems(text, text, text) from public, anon, authenticated;

-- ---------------------------------------------------------------------------------------------------------------------------- agent side (service path, Donna active)
create or replace function public.donna_run_begin(p_mission text) returns jsonb
language plpgsql security definer set search_path to 'pg_catalog' as $$
declare m fz_donna.mission_actions; v_action text; v_id uuid; v_green text[]; v_proh text[];
begin
  perform fz_donna.guard();
  perform fz_donna.require_active();
  select * into m from fz_donna.mission_actions where mission = p_mission;
  if m.mission is null then raise exception 'refused: unknown Donna mission %', p_mission using errcode = '42501'; end if;
  v_green := fz_donna.green(); v_proh := fz_donna.prohibited();
  select a into v_action from unnest(m.actions) with ordinality u(a, i) where a = any (v_green) and not (a = any (v_proh)) order by i limit 1;
  if v_action is null then
    raise exception 'refused: % needs one of % in Donna''s green tier (green: %)', p_mission, m.actions, v_green using errcode = '42501'; end if;
  insert into fz_donna.runs (mission, action) values (p_mission, v_action) returning id into v_id;
  insert into public.audit_log (actor, action, target, detail) values ('office:donna', 'donna_run_begin', 'fz_donna.runs/' || v_id, jsonb_build_object('mission', p_mission, 'action', v_action));
  return jsonb_build_object('run', v_id, 'mission', p_mission, 'action', v_action, 'writes', to_jsonb(m.writes), 'prohibited', to_jsonb(v_proh));
end $$;
revoke all on function public.donna_run_begin(text) from public, anon, authenticated;

-- an agent asks before any named action; prohibited and non-green actions are refused and audited
create or replace function public.donna_check_action(p_run uuid, p_action text) returns jsonb
language plpgsql security definer set search_path to 'pg_catalog' as $$
declare r fz_donna.runs;
begin
  perform fz_donna.guard();
  select * into r from fz_donna.runs where id = p_run;
  if r.id is null or r.status <> 'running' then raise exception 'refused: no running Donna run' using errcode = '42501'; end if;
  if p_action = any (fz_donna.prohibited()) then
    insert into public.audit_log (actor, action, target, detail) values ('office:donna', 'donna_prohibited_refused', 'fz_donna.runs/' || p_run, jsonb_build_object('action', p_action));
    return jsonb_build_object('allowed', false, 'reason', 'prohibited for Donna: ' || p_action);
  end if;
  if not (p_action = any (fz_donna.green())) then
    return jsonb_build_object('allowed', false, 'reason', p_action || ' is not in Donna''s green tier: it needs the owner');
  end if;
  return jsonb_build_object('allowed', true);
end $$;
revoke all on function public.donna_check_action(uuid, text) from public, anon, authenticated;

create or replace function public.donna_run_finish(p_run uuid, p_status text, p_summary text, p_output jsonb, p_sources jsonb default '[]'::jsonb) returns jsonb
language plpgsql security definer set search_path to 'pg_catalog' as $$
begin
  perform fz_donna.guard();
  if p_status not in ('done', 'failed') then raise exception 'bad run status %', p_status; end if;
  update fz_donna.runs set status = p_status, summary = left(p_summary, 2000), output = p_output, sources = coalesce(p_sources, '[]'::jsonb), finished_at = now()
   where id = p_run and status = 'running';
  if not found then raise exception 'refused: no running Donna run %', p_run using errcode = '42501'; end if;
  insert into public.audit_log (actor, action, target, detail) values ('office:donna', 'donna_run_' || p_status, 'fz_donna.runs/' || p_run, '{}'::jsonb);
  return jsonb_build_object('run', p_run, 'status', p_status);
end $$;
revoke all on function public.donna_run_finish(uuid, text, text, jsonb, jsonb) from public, anon, authenticated;

-- save one draft of a running mission (the kind must be one that mission writes). Outreach drafts pass the CASL floor; a per-lead draft needs a consent basis.
create or replace function public.donna_save_draft(p_run uuid, p_kind text, p_channel text, p_lead uuid, p_subject text, p_body text, p_casl jsonb default '{}'::jsonb) returns jsonb
language plpgsql security definer set search_path to 'pg_catalog' as $$
declare r fz_donna.runs; m fz_donna.mission_actions; l public.leads; v_probs text[]; v_id uuid;
begin
  perform fz_donna.guard();
  perform fz_donna.require_active();
  select * into r from fz_donna.runs where id = p_run;
  if r.id is null or r.status <> 'running' then raise exception 'refused: no running Donna run' using errcode = '42501'; end if;
  select * into m from fz_donna.mission_actions where mission = r.mission;
  if not (p_kind = any (m.writes)) then raise exception 'refused: % does not write %', r.mission, p_kind using errcode = '42501'; end if;
  v_probs := fz_donna.text_problems(p_kind, p_subject, p_body);
  if cardinality(v_probs) > 0 then raise exception 'refused (CASL / honesty): %', array_to_string(v_probs, '; ') using errcode = '42501'; end if;
  if p_lead is not null then
    select * into l from public.leads where id = p_lead;
    if l.id is null or l.venture_id is distinct from fz_donna.donna_venture() then raise exception 'refused: not a Donna lead' using errcode = '42501'; end if;
    if l.do_not_contact or l.status = 'do_not_contact' then raise exception 'refused: the lead is do-not-contact' using errcode = '42501'; end if;
    if nullif(btrim(coalesce(l.consent_basis, '')), '') is null then raise exception 'refused: no consent basis recorded for this lead (CASL)' using errcode = '42501'; end if;
    if (l.email is not null and public.is_suppressed(l.email)) or (l.phone is not null and public.ffm_is_phone_suppressed(l.phone)) then
      raise exception 'refused: the address or number is on the suppression list' using errcode = '42501'; end if;
    if p_channel = 'email' and l.email is null then raise exception 'refused: the lead has no email' using errcode = '42501'; end if;
  end if;
  update fz_donna.drafts set status = 'superseded' where status = 'draft' and kind = p_kind and lead_id is not distinct from p_lead and coalesce(channel, '') = coalesce(p_channel, '')
     and lead_id is not null;
  insert into fz_donna.drafts (run_id, kind, channel, lead_id, subject, body, casl) values (p_run, p_kind, p_channel, p_lead, p_subject, p_body, coalesce(p_casl, '{}'::jsonb))
    returning id into v_id;
  if p_lead is not null then update public.leads set status = 'drafted' where id = p_lead and status = 'new'; end if;
  insert into public.audit_log (actor, action, target, detail) values ('office:donna', 'donna_draft', 'fz_donna.drafts/' || v_id, jsonb_build_object('kind', p_kind, 'run', p_run));
  return jsonb_build_object('draft', v_id, 'status', 'draft');
end $$;
revoke all on function public.donna_save_draft(uuid, text, text, uuid, text, text, jsonb) from public, anon, authenticated;

-- a prospect found by market research: a PUBLISHED business contact, with the page it was published on (CASL implied consent by conspicuous publication)
create or replace function public.donna_add_prospect(p_run uuid, p_business text, p_email text, p_phone text, p_source_url text, p_no_solicit_notice boolean, p_note text default null) returns jsonb
language plpgsql security definer set search_path to 'pg_catalog' as $$
declare r fz_donna.runs; v_v uuid := fz_donna.donna_venture(); v_id uuid; v_email text := nullif(lower(btrim(coalesce(p_email, ''))), ''); v_phone text := public.normalize_phone(p_phone);
begin
  perform fz_donna.guard();
  perform fz_donna.require_active();
  select * into r from fz_donna.runs where id = p_run;
  if r.id is null or r.status <> 'running' or r.mission <> 'market-research' then raise exception 'refused: prospects come from a running market-research mission' using errcode = '42501'; end if;
  if v_v is null then raise exception 'refused: no donna venture'; end if;
  if coalesce(p_source_url, '') !~ '^https://[A-Za-z0-9.-]+(/[^[:space:]]*)?$' then raise exception 'refused: a prospect needs the https page where its contact is published' using errcode = '42501'; end if;
  if p_no_solicit_notice is distinct from false then raise exception 'refused: the page says no unsolicited messages (or it was not checked)' using errcode = '42501'; end if;
  if length(btrim(coalesce(p_business, ''))) not between 2 and 120 then raise exception 'refused: business name 2-120 characters'; end if;
  if v_email is null and v_phone is null then raise exception 'refused: no published contact'; end if;
  if (v_email is not null and public.is_suppressed(v_email)) or (v_phone is not null and public.ffm_is_phone_suppressed(v_phone)) then
    raise exception 'refused: the address or number is on the suppression list' using errcode = '42501'; end if;
  select id into v_id from public.leads where venture_id = v_v and ((v_email is not null and lower(email) = v_email) or (v_phone is not null and public.normalize_phone(phone) = v_phone)) limit 1;
  if v_id is not null then return jsonb_build_object('lead', v_id, 'duplicate', true); end if;
  insert into public.leads (venture_id, name, email, phone, source, status, consent_basis, notes)
    values (v_v, btrim(p_business), v_email, v_phone, 'donna:research', 'new', 'implied_published',
            left('published at ' || p_source_url || ' (seen ' || to_char(now(), 'YYYY-MM-DD') || ', no "no unsolicited messages" notice)' || coalesce('. ' || p_note, ''), 500))
    returning id into v_id;
  insert into public.audit_log (actor, action, target, detail) values ('office:donna', 'donna_prospect', 'leads/' || v_id, jsonb_build_object('run', p_run));
  return jsonb_build_object('lead', v_id, 'duplicate', false);
end $$;
revoke all on function public.donna_add_prospect(uuid, text, text, text, text, boolean, text) from public, anon, authenticated;

create or replace function public.donna_save_intake(p_run uuid, p_client_label text, p_lead uuid, p_reception_config jsonb, p_site_json jsonb, p_open_items jsonb default '[]'::jsonb) returns jsonb
language plpgsql security definer set search_path to 'pg_catalog' as $$
declare r fz_donna.runs; v_id uuid;
begin
  perform fz_donna.guard();
  perform fz_donna.require_active();
  select * into r from fz_donna.runs where id = p_run;
  if r.id is null or r.status <> 'running' or r.mission <> 'delivery-onboarding' then raise exception 'refused: intakes come from a running delivery-onboarding mission' using errcode = '42501'; end if;
  if p_lead is not null and not exists (select 1 from public.leads where id = p_lead and venture_id = fz_donna.donna_venture()) then raise exception 'refused: not a Donna lead'; end if;
  if (p_site_json ->> 'office') is distinct from 'donna' then raise exception 'refused: a client site draft names office donna'; end if;
  insert into fz_donna.intakes (run_id, client_label, lead_id, reception_config, site_json, open_items) values (p_run, p_client_label, p_lead, p_reception_config, p_site_json, coalesce(p_open_items, '[]'::jsonb))
    returning id into v_id;
  insert into public.audit_log (actor, action, target, detail) values ('office:donna', 'donna_intake', 'fz_donna.intakes/' || v_id, jsonb_build_object('run', p_run));
  return jsonb_build_object('intake', v_id, 'status', 'draft');
end $$;
revoke all on function public.donna_save_intake(uuid, text, uuid, jsonb, jsonb, jsonb) from public, anon, authenticated;

-- the business name of one Donna lead (outreach-prep fills {business} in code; no lead data goes to the model)
create or replace function public.donna_lead_label(p_lead uuid) returns jsonb
language plpgsql stable security definer set search_path to 'pg_catalog' as $$
declare l public.leads;
begin
  perform fz_donna.guard();
  perform fz_donna.require_active();
  select * into l from public.leads where id = p_lead and venture_id = fz_donna.donna_venture();
  if l.id is null then raise exception 'refused: not a Donna lead' using errcode = '42501'; end if;
  return jsonb_build_object('lead', l.id, 'business', left(btrim(l.name), 120), 'do_not_contact', l.do_not_contact, 'has_consent_basis', nullif(btrim(coalesce(l.consent_basis, '')), '') is not null);
end $$;
revoke all on function public.donna_lead_label(uuid) from public, anon, authenticated;

-- ---------------------------------------------------------------------------------------------------------------------------- CRM pipeline (read-only)
create or replace function fz_donna.next_actions(p_limit integer default 25) returns jsonb
language sql stable set search_path to 'pg_catalog' as $$
  select coalesce(jsonb_agg(x order by x ->> 'prio', x ->> 'ref'), '[]'::jsonb) from (
    select jsonb_build_object('prio', a.prio, 'ref', a.ref, 'who', a.who, 'action', a.action) x from (
      select '1' prio, 'lead #' || l.short_id ref, 'owner' who, 'reply waiting: answer it or book the demo (record_lead_reply / create_deal)' action
        from public.leads l where l.venture_id = fz_donna.donna_venture() and not l.do_not_contact and l.status = 'replied'
      union all
      select '2', 'draft ' || left(d.id::text, 8), 'owner', 'review the ' || replace(d.kind, '_', ' ') || ' draft (donna_owner_decide_draft)'
        from fz_donna.drafts d where d.status = 'draft'
      union all
      select '2', 'intake ' || left(i.id::text, 8), 'owner', 'review the onboarding intake for ' || i.client_label || ' (donna_owner_decide_intake)'
        from fz_donna.intakes i where i.status = 'draft'
      union all
      select '3', 'lead #' || l.short_id, 'owner', 'follow-up due ' || l.next_followup_at::text
        from public.leads l where l.venture_id = fz_donna.donna_venture() and not l.do_not_contact and l.status in ('contacted', 'sent') and l.next_followup_at <= current_date
      union all
      select '3', 'deal ' || left(d.id::text, 8), 'owner', 'deal ' || d.stage || ' for ' || (now()::date - d.updated_at::date) || ' days: chase or close it'
        from public.deals d where d.venture_id = fz_donna.donna_venture() and d.stage in ('pitched', 'negotiating') and d.updated_at < now() - interval '7 days'
      union all
      select '3', 'deal ' || left(d.id::text, 8), 'donna:delivery-onboarding', 'won: run the client intake'
        from public.deals d where d.venture_id = fz_donna.donna_venture() and lower(d.stage) in ('won', 'closed_won', 'paid')
         and not exists (select 1 from fz_donna.intakes i where i.lead_id = d.lead_id)
      union all
      select '4', 'client ' || c.slug, 'owner', 'receptionist in demo: test it, then the go-live checklist (/reception golive ' || c.slug || ')'
        from fz_reception.clients c where to_regclass('fz_reception.clients') is not null and c.status = 'demo'
      union all
      select '5', 'lead #' || l.short_id, case when nullif(btrim(coalesce(l.consent_basis, '')), '') is null then 'owner' else 'donna:outreach-prep' end,
             case when nullif(btrim(coalesce(l.consent_basis, '')), '') is null then 'record a consent basis or drop the lead (no outreach without one)' else 'draft the first message' end
        from public.leads l where l.venture_id = fz_donna.donna_venture() and not l.do_not_contact and l.status = 'new'
    ) a limit least(greatest(coalesce(p_limit, 25), 1), 100)) y
$$;
revoke all on function fz_donna.next_actions(integer) from public, anon, authenticated;

create or replace function public.donna_pipeline(p_limit integer default 25) returns jsonb
language plpgsql stable security definer set search_path to 'pg_catalog' as $$
declare v_v uuid := fz_donna.donna_venture();
begin
  perform fz_donna.guard();
  return jsonb_build_object(
    'active', fz_donna.active(),
    'funnel', case when v_v is null then null else public.lead_funnel('donna') end,
    'deals', coalesce((select jsonb_object_agg(stage, jsonb_build_object('n', n, 'value_cents', v)) from (select stage, count(*) n, coalesce(sum(value_cents), 0) v
                         from public.deals where venture_id = v_v group by stage) d), '{}'::jsonb),
    'clients', coalesce((select jsonb_agg(jsonb_build_object('slug', w.slug, 'workspace', w.status,
                           'receptionist', (select c.status from fz_reception.clients c where c.workspace_id = w.id and to_regclass('fz_reception.clients') is not null),
                           'signed_off', exists (select 1 from fz_donna.golive g join fz_reception.clients c on c.slug = g.slug where c.workspace_id = w.id)) order by w.slug)
                         from public.client_workspaces w
                        where exists (select 1 from fz_donna.intakes i where i.workspace_id = w.id)
                           or (to_regclass('fz_reception.clients') is not null and exists (select 1 from fz_reception.clients c where c.workspace_id = w.id))), '[]'::jsonb),
    'drafts', jsonb_build_object('waiting', (select count(*) from fz_donna.drafts where status = 'draft'), 'approved', (select count(*) from fz_donna.drafts where status = 'owner_approved')),
    'intakes_waiting', (select count(*) from fz_donna.intakes where status = 'draft'),
    'runs_7d', (select count(*) from fz_donna.runs where started_at > now() - interval '7 days'),
    'next_actions', fz_donna.next_actions(p_limit));
end $$;
revoke all on function public.donna_pipeline(integer) from public, anon, authenticated;

-- the weekly KPIs: from the HQ data only; a missing number is a GAP, never an estimate
create or replace function fz_donna.kpis() returns jsonb
language plpgsql stable set search_path to 'pg_catalog' as $$
declare v_v uuid := fz_donna.donna_venture(); v_mrr bigint; v_plans int := 0; v_revoked int := 0; v_spent bigint; v_rev bigint; v_won int; gaps text[] := '{}'; f jsonb;
begin
  if to_regclass('fz_office_os.fz_billing_plans') is not null then
    select coalesce(sum(case when billing_interval = 'month' then cents else cents / 12 end), 0), count(*) into v_mrr, v_plans
      from fz_office_os.fz_billing_plans where slug = 'donna' and status = 'approved';
    select count(*) into v_revoked from fz_office_os.fz_billing_plans where slug = 'donna' and status = 'revoked' and revoked_at > now() - interval '30 days';
  else gaps := gaps || 'MRR: no billing plans table'::text; end if;
  if v_plans = 0 then gaps := gaps || 'MRR: no approved billing plan yet'::text; end if;
  if to_regclass('public.fz_office_money') is not null then
    select spent_cents, revenue_cents into v_spent, v_rev from public.fz_office_money where office = 'donna' and kind = 'office';
  end if;
  if v_spent is null then gaps := gaps || 'spend: no office sub-ledger row for donna'::text; end if;
  select count(*) into v_won from public.deals where venture_id = v_v and lower(stage) in ('won', 'closed_won', 'paid');
  if coalesce(v_won, 0) = 0 then gaps := gaps || 'CAC: no won deal yet'::text; end if;
  f := case when v_v is null then null else public.lead_funnel('donna') end;
  if f is null then gaps := gaps || 'pipeline: no donna venture'::text; end if;
  return jsonb_build_object('mrr_cents', v_mrr, 'paying_plans', v_plans, 'churned_30d', v_revoked,
    'churn_pct_30d', case when v_plans + v_revoked > 0 then round(100.0 * v_revoked / (v_plans + v_revoked), 1) end,
    'spent_cents', v_spent, 'revenue_cents', v_rev, 'won_deals', v_won,
    'cac_cents', case when coalesce(v_won, 0) > 0 and v_spent is not null then v_spent / v_won end,
    'leads_new_7d', (select count(*) from public.leads where venture_id = v_v and created_at > now() - interval '7 days'),
    'funnel', f -> 'counts',
    'conversion', case when f is null then null else jsonb_build_object(
        'drafted_of_leads', case when (f ->> 'total')::int > 0 then round(100.0 * ((f -> 'counts' ->> 'drafted')::int + (f -> 'counts' ->> 'approved_to_send')::int + (f -> 'counts' ->> 'sent')::int
                                       + (f -> 'counts' ->> 'replied')::int + (f -> 'counts' ->> 'booked')::int + (f -> 'counts' ->> 'won')::int) / (f ->> 'total')::int, 1) end,
        'replied_of_sent', case when ((f -> 'counts' ->> 'sent')::int + (f -> 'counts' ->> 'replied')::int + (f -> 'counts' ->> 'booked')::int + (f -> 'counts' ->> 'won')::int) > 0
                                then round(100.0 * ((f -> 'counts' ->> 'replied')::int + (f -> 'counts' ->> 'booked')::int + (f -> 'counts' ->> 'won')::int)
                                           / ((f -> 'counts' ->> 'sent')::int + (f -> 'counts' ->> 'replied')::int + (f -> 'counts' ->> 'booked')::int + (f -> 'counts' ->> 'won')::int), 1) end,
        'won_of_booked', case when ((f -> 'counts' ->> 'booked')::int + (f -> 'counts' ->> 'won')::int) > 0
                              then round(100.0 * (f -> 'counts' ->> 'won')::int / ((f -> 'counts' ->> 'booked')::int + (f -> 'counts' ->> 'won')::int), 1) end) end,
    'delivery', coalesce((select jsonb_agg(jsonb_build_object('client', c.slug, 'status', c.status) order by c.slug) from fz_reception.clients c
                           where to_regclass('fz_reception.clients') is not null), '[]'::jsonb),
    'gaps', to_jsonb(gaps));
end $$;
revoke all on function fz_donna.kpis() from public, anon, authenticated;

create or replace function fz_donna.money(c bigint) returns text
language sql immutable set search_path to 'pg_catalog' as $$
  select case when c is null then 'gap' else '$' || to_char(c / 100.0, 'FM999,999,990.00') end
$$;
revoke all on function fz_donna.money(bigint) from public, anon, authenticated;

-- the weekly report (donna-m4-weekly-report): once per ISO week, only while Donna is active, to the owner's own channel (owner_messages). $0: plain SQL, no model.
create or replace function public.donna_weekly_report(p_force boolean default false) returns jsonb
language plpgsql security definer set search_path to 'pg_catalog' as $$
declare k jsonb; p jsonb; v_week text := to_char(now(), 'IYYY-"W"IW'); v_body text; v_msg uuid; v_na text;
begin
  perform fz_donna.guard();
  if not fz_donna.active() then return jsonb_build_object('skipped', 'Donna is dormant'); end if;
  if exists (select 1 from fz_donna.reports where week = v_week) and not coalesce(p_force, false) then return jsonb_build_object('skipped', 'already sent for ' || v_week); end if;
  k := fz_donna.kpis();
  p := public.donna_pipeline(8);
  select string_agg('- ' || (x ->> 'ref') || ' [' || (x ->> 'who') || ']: ' || (x ->> 'action'), E'\n') into v_na from jsonb_array_elements(p -> 'next_actions') x;
  v_body := left(format(E'Donna weekly report %s (from HQ data; gaps are flagged, never estimated)\nMRR %s from %s plan(s); churn 30d %s\nSpent %s, revenue %s, won deals %s, CAC %s\nNew leads 7d: %s. Funnel: %s\nConversion: %s\nDelivery: %s\nDrafts waiting for you: %s; intakes waiting: %s\nNext actions:\n%s\nGaps: %s',
      v_week, fz_donna.money((k ->> 'mrr_cents')::bigint), k ->> 'paying_plans', coalesce((k ->> 'churn_pct_30d') || '%', 'gap'),
      fz_donna.money((k ->> 'spent_cents')::bigint), fz_donna.money((k ->> 'revenue_cents')::bigint), k ->> 'won_deals', fz_donna.money((k ->> 'cac_cents')::bigint),
      k ->> 'leads_new_7d', coalesce((k -> 'funnel')::text, 'gap'), coalesce((k -> 'conversion')::text, 'gap'), (k -> 'delivery')::text,
      p -> 'drafts' ->> 'waiting', p ->> 'intakes_waiting', coalesce(v_na, '- none'),
      coalesce((select string_agg(g, '; ') from jsonb_array_elements_text(k -> 'gaps') g), 'none')), 3900);
  insert into public.owner_messages (from_agent, kind, channel, body) values ('jarvis', 'brief', 'telegram', v_body) returning id into v_msg;
  insert into fz_donna.reports (week, body, kpis, message_id) values (v_week, v_body, k, v_msg)
    on conflict (week) do update set body = excluded.body, kpis = excluded.kpis, message_id = excluded.message_id, created_at = now();
  insert into public.audit_log (actor, action, target, detail) values ('office:donna', 'donna_weekly_report', 'fz_donna.reports/' || v_week, jsonb_build_object('message', v_msg));
  return jsonb_build_object('week', v_week, 'message', v_msg, 'kpis', k);
end $$;
revoke all on function public.donna_weekly_report(boolean) from public, anon, authenticated;

-- the go-live checklist for one receptionist client (read-only); each step says who does it
create or replace function public.donna_golive_checklist(p_slug text) returns jsonb
language plpgsql stable security definer set search_path to 'pg_catalog' as $$
declare c record; g fz_donna.golive; steps jsonb;
begin
  perform fz_donna.guard();
  if to_regclass('fz_reception.clients') is null then raise exception 'Donna Receptionist v1 (20261206) is not applied'; end if;
  select slug, status, twilio_number, text_back_enabled, text_back_standing, config into c from fz_reception.clients where slug = p_slug;
  if c.slug is null then raise exception 'unknown receptionist client %', p_slug; end if;
  select * into g from fz_donna.golive where slug = p_slug;
  steps := jsonb_build_array(
    jsonb_build_object('step', 'Donna office active (office_os_activate)', 'who', 'owner', 'done', fz_donna.active()),
    jsonb_build_object('step', 'client config stored, client in demo', 'who', 'owner', 'done', c.status in ('demo', 'live')),
    jsonb_build_object('step', 'demo line tested end to end (call, booking, text logged dry_run)', 'who', 'owner', 'done', coalesce(g.demo_tested, false)),
    jsonb_build_object('step', 'the client approved the script, hours, prices and FAQs', 'who', 'owner', 'done', coalesce(g.client_approved, false)),
    jsonb_build_object('step', 'client Twilio number set (reception_owner_set_client ... number)', 'who', 'owner', 'done', c.twilio_number is not null),
    jsonb_build_object('step', 'number webhooks set in the Twilio console (voice, status, messaging)', 'who', 'owner', 'done', coalesce(g.number_webhooks_set, false)),
    jsonb_build_object('step', 'owner go-live sign-off recorded (donna_owner_golive_approve)', 'who', 'owner', 'done', g.slug is not null),
    jsonb_build_object('step', 'live (reception_owner_set_flags ''live'')', 'who', 'owner', 'done', c.status = 'live'));
  return jsonb_build_object('client', p_slug, 'status', c.status, 'text_back', c.text_back_enabled, 'standing', c.text_back_standing, 'steps', steps,
    'ready', fz_donna.active() and c.twilio_number is not null and g.slug is not null and g.demo_tested and g.client_approved and g.number_webhooks_set);
end $$;
revoke all on function public.donna_golive_checklist(text) from public, anon, authenticated;

create or replace function public.donna_drafts(p_status text default 'draft', p_limit integer default 20) returns jsonb
language plpgsql stable security definer set search_path to 'pg_catalog' as $$
begin
  perform fz_donna.guard();
  return coalesce((select jsonb_agg(jsonb_build_object('id', d.id, 'kind', d.kind, 'channel', d.channel, 'lead', d.lead_id, 'subject', d.subject, 'body', left(d.body, 1500),
                                                       'created_at', d.created_at) order by d.created_at desc)
                     from (select * from fz_donna.drafts where status = coalesce(p_status, 'draft') order by created_at desc limit least(greatest(coalesce(p_limit, 20), 1), 50)) d), '[]'::jsonb);
end $$;
revoke all on function public.donna_drafts(text, integer) from public, anon, authenticated;

-- ---------------------------------------------------------------------------------------------------------------------------- owner controls
create or replace function public.donna_owner_decide_draft(p_id uuid, p_approved boolean, p_note text default null) returns jsonb
language plpgsql security definer set search_path to 'pg_catalog' as $$
declare d fz_donna.drafts;
begin
  perform fz_donna.owner_only('approving a Donna draft');
  select * into d from fz_donna.drafts where id = p_id for update;
  if d.id is null or d.status <> 'draft' then raise exception 'refused: no open draft %', p_id; end if;
  if p_approved and (coalesce(d.body, '') ~* '\[owner:' or coalesce(d.subject, '') ~* '\[owner:') then
    raise exception 'refused: replace every [OWNER: ...] placeholder (sender identity, mailing address) before approving'; end if;
  update fz_donna.drafts set status = case when p_approved then 'owner_approved' else 'owner_rejected' end, decided_at = now(), decided_by = 'owner', note = left(p_note, 500) where id = p_id;
  insert into public.audit_log (actor, action, target, detail) values ('owner', 'donna_draft_' || case when p_approved then 'approved' else 'rejected' end, 'fz_donna.drafts/' || p_id, '{}'::jsonb);
  return jsonb_build_object('draft', p_id, 'status', case when p_approved then 'owner_approved' else 'owner_rejected' end,
                            'note', 'approved copy only: nothing is sent from here; a send goes through the outreach gate as its own owner step');
end $$;
revoke all on function public.donna_owner_decide_draft(uuid, boolean, text) from public, anon, authenticated;

-- the owner edits a draft (e.g. fills the [OWNER: ...] placeholders); the CASL floor is re-checked
create or replace function public.donna_owner_edit_draft(p_id uuid, p_subject text, p_body text) returns jsonb
language plpgsql security definer set search_path to 'pg_catalog' as $$
declare d fz_donna.drafts; v_probs text[];
begin
  perform fz_donna.owner_only('editing a Donna draft');
  select * into d from fz_donna.drafts where id = p_id for update;
  if d.id is null or d.status <> 'draft' then raise exception 'refused: no open draft %', p_id; end if;
  v_probs := fz_donna.text_problems(d.kind, p_subject, p_body);
  if cardinality(v_probs) > 0 then raise exception 'refused (CASL / honesty): %', array_to_string(v_probs, '; ') using errcode = '42501'; end if;
  update fz_donna.drafts set subject = p_subject, body = p_body where id = p_id;
  insert into public.audit_log (actor, action, target, detail) values ('owner', 'donna_draft_edited', 'fz_donna.drafts/' || p_id, '{}'::jsonb);
  return jsonb_build_object('draft', p_id, 'status', 'draft');
end $$;
revoke all on function public.donna_owner_edit_draft(uuid, text, text) from public, anon, authenticated;

create or replace function public.donna_owner_decide_intake(p_id uuid, p_approved boolean) returns jsonb
language plpgsql security definer set search_path to 'pg_catalog' as $$
begin
  perform fz_donna.owner_only('approving a client intake');
  update fz_donna.intakes set status = case when p_approved then 'owner_approved' else 'owner_rejected' end, decided_at = now() where id = p_id and status = 'draft';
  if not found then raise exception 'refused: no open intake %', p_id; end if;
  insert into public.audit_log (actor, action, target, detail) values ('owner', 'donna_intake_' || case when p_approved then 'approved' else 'rejected' end, 'fz_donna.intakes/' || p_id, '{}'::jsonb);
  return jsonb_build_object('intake', p_id, 'status', case when p_approved then 'owner_approved' else 'owner_rejected' end);
end $$;
revoke all on function public.donna_owner_decide_intake(uuid, boolean) from public, anon, authenticated;

-- an approved intake becomes the client's receptionist config IN DEMO (reception_owner_set_client, owner-only there too). The site.json stays a draft for Web Studio.
create or replace function public.donna_owner_apply_intake(p_id uuid, p_slug text, p_workspace uuid) returns jsonb
language plpgsql security definer set search_path to 'pg_catalog' as $$
declare i fz_donna.intakes; r jsonb;
begin
  perform fz_donna.owner_only('applying a client intake');
  select * into i from fz_donna.intakes where id = p_id for update;
  if i.id is null or i.status <> 'owner_approved' then raise exception 'refused: approve the intake first (donna_owner_decide_intake)'; end if;
  if i.reception_config::text ~* '\[owner:|\[client:' then raise exception 'refused: the receptionist config still has [OWNER: / CLIENT: ...] placeholders'; end if;
  r := public.reception_owner_set_client(p_slug, p_workspace, i.reception_config);
  update fz_donna.intakes set status = 'applied', workspace_id = p_workspace where id = p_id;
  insert into public.audit_log (actor, action, target, detail) values ('owner', 'donna_intake_applied', 'fz_donna.intakes/' || p_id, jsonb_build_object('client', p_slug));
  return jsonb_build_object('intake', p_id, 'client', p_slug, 'status', 'demo', 'site_json', 'still a draft: hand it to Web Studio (its own owner approval before any deploy)');
end $$;
revoke all on function public.donna_owner_apply_intake(uuid, text, uuid) from public, anon, authenticated;

create or replace function public.donna_owner_golive_approve(p_slug text, p_demo_tested boolean, p_client_approved boolean, p_number_webhooks_set boolean) returns jsonb
language plpgsql security definer set search_path to 'pg_catalog' as $$
begin
  perform fz_donna.owner_only('a go-live sign-off');
  if to_regclass('fz_reception.clients') is null or not exists (select 1 from fz_reception.clients where slug = p_slug) then raise exception 'unknown receptionist client %', p_slug; end if;
  if not (coalesce(p_demo_tested, false) and coalesce(p_client_approved, false) and coalesce(p_number_webhooks_set, false)) then
    raise exception 'refused: sign off only after the demo test, the client''s approval and the number webhooks'; end if;
  insert into fz_donna.golive (slug, demo_tested, client_approved, number_webhooks_set, signed_by) values (p_slug, true, true, true, 'owner')
    on conflict (slug) do update set demo_tested = true, client_approved = true, number_webhooks_set = true, signed_at = now(), signed_by = 'owner';
  insert into public.audit_log (actor, action, target, detail) values ('owner', 'donna_golive_signoff', 'fz_reception.clients/' || p_slug, '{}'::jsonb);
  return jsonb_build_object('client', p_slug, 'signed_off', true, 'next', format('reception_owner_set_flags(%L, ''live'', true, false)', p_slug));
end $$;
revoke all on function public.donna_owner_golive_approve(text, boolean, boolean, boolean) from public, anon, authenticated;

do $$ declare r text; f regprocedure; begin
  foreach r in array array['fz_jarvis', 'fz_office_agent', 'fz_auditor', 'backup_reader'] loop
    continue when not exists (select 1 from pg_roles where rolname = r);
    for f in select p.oid::regprocedure from pg_proc p where p.pronamespace = 'public'::regnamespace and p.proname like 'donna\_%' loop
      execute format('revoke all on function %s from %I', f, r);
    end loop;
  end loop;
end $$;

-- weekly report: Mondays 13:05 UTC (09:05 Ottawa), only when pg_cron exists; the function itself does nothing while Donna is dormant
do $$ begin
  if exists (select 1 from pg_namespace where nspname = 'cron') then
    perform cron.unschedule(jobid) from cron.job where jobname = 'donna-weekly-report';
    perform cron.schedule('donna-weekly-report', '5 13 * * 1', 'select public.donna_weekly_report()');
  end if;
end $$;
