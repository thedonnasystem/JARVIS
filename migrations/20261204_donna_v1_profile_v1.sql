-- FENDEZY GROUP: Donna v1 profile (owner direction v1, offices/donna.json). Needs M7 (20261203_office_os_v1.sql). Data-only change of ONE M7-owned row.
-- Sets Donna's fz_office_os.fz_office_profiles row to the v1 brief: mission, the 4 v1 agent roles, integrations, green / yellow / red tiers, and a prohibited list
-- that carries every real action_policy action mapped for Donna (sign_contract, financial_transfer, deceptive_communication, fabricate, evade_platform_restrictions,
-- spend_outside_budget, deploy_website, modify_own_permissions: all seeded by 20261112_permissions_v1.sql; enforced as office blocks at activation by M7)
-- plus the owner's advisory entries (labelled advisory by office_os_status and /office).
-- Refused unless Donna is DORMANT (profile and M1). Idempotent: a re-run with the v1 values already in place changes nothing.
-- The previous values are kept once in fz_archive.donna_profile_before_v1 (no API privileges); ops/rollback_donna_v1_profile.sql restores them.
-- Touches no other office, no money control, no protected object; writes audit_log by INSERT only (production audit_log / ledger are append-only).
-- Ordered after 20261203_office_os_v1.sql, BEFORE the lockdown (R3).

set lock_timeout = '5s';

do $$
declare
  p fz_office_os.fz_office_profiles;
  v_mission text := 'Run Donna, an Ottawa AI infrastructure and digital-presence agency. First milestone: 3 paying clients. Service line A: AI receptionist, call and text handling, booking, lead follow-up, CRM and workflow automation (recurring). Service line B: websites, maintenance, booking and lead-capture integration (setup fee plus support). No niche is locked until validated and the owner commits one. Founding offer: $497 first month, setup waived. Guarantee terms TBD by owner.';
  v_roles text[] := array['market-research', 'offer-pricing', 'outreach-prep', 'delivery-onboarding'];
  v_integrations text[] := array['telegram', 'supabase', 'anthropic', 'vault', 'resend', 'google', 'automation', 'meta', 'stripe'];
  v_autonomy jsonb := '{"green": ["research", "market_validation", "draft_offer", "draft_outreach", "build_in_sandbox"], "yellow": ["book_meeting", "schedule_follow_up"], "red": ["send_email", "external_message", "client_deliverable", "spend", "contract", "publish_content"], "prohibited": ["sign_contract", "financial_transfer", "deceptive_communication", "fabricate", "evade_platform_restrictions", "spend_outside_budget", "deploy_website", "modify_own_permissions", "email_without_consent", "client_data_outside_office", "sell_undelivered_or_untested_service", "client_portal_or_saas", "large_agent_workforce", "refund_or_guarantee_promise"]}';
  a text;
begin
  if to_regclass('fz_office_os.fz_office_profiles') is null then raise exception 'the M7 office OS (20261203_office_os_v1) is not applied'; end if;
  select * into p from fz_office_os.fz_office_profiles where slug = 'donna' for update;
  if not found then raise exception 'the donna profile is missing'; end if;
  if p.mission = v_mission and p.agent_roles = v_roles and p.integrations = v_integrations and p.autonomy = v_autonomy then
    return;                                                               -- already v1: nothing to do
  end if;
  if p.status <> 'dormant' or exists (select 1 from public.fz_offices where id = p.office_id and status <> 'dormant') then
    raise exception 'refused: Donna is % (M1: %); the v1 profile is applied only while she is dormant (office_os_deactivate first)', p.status,
      (select status from public.fz_offices where id = p.office_id) using errcode = '42501';
  end if;
  -- every enforced entry must be a real action_policy action
  foreach a in array array['sign_contract', 'financial_transfer', 'deceptive_communication', 'fabricate', 'evade_platform_restrictions', 'spend_outside_budget', 'deploy_website', 'modify_own_permissions'] loop
    if not exists (select 1 from public.action_policy where action = a) then raise exception 'action_policy has no action %', a; end if;
  end loop;
  create schema if not exists fz_archive;
  revoke all on schema fz_archive from public;
  if exists (select 1 from pg_roles where rolname = 'anon') then execute 'revoke all on schema fz_archive from anon, authenticated, service_role'; end if;
  create table if not exists fz_archive.donna_profile_before_v1 (archived_at timestamptz not null default now(), mission text not null, agent_roles text[] not null,
    integrations text[] not null, autonomy jsonb not null, confidentiality text not null, activation_rank integer);
  revoke all on fz_archive.donna_profile_before_v1 from public;
  if not exists (select 1 from fz_archive.donna_profile_before_v1) then        -- the values before v1, kept once (a re-apply never overwrites them)
    insert into fz_archive.donna_profile_before_v1 (mission, agent_roles, integrations, autonomy, confidentiality, activation_rank)
      values (p.mission, p.agent_roles, p.integrations, p.autonomy, p.confidentiality, p.activation_rank);
  end if;
  update fz_office_os.fz_office_profiles set mission = v_mission, agent_roles = v_roles, integrations = v_integrations, autonomy = v_autonomy,
         updated_at = now(), updated_by = 'migration:donna_v1_profile' where slug = 'donna';
  insert into public.audit_log (actor, action, target, detail)
    values ('migration', 'office_profile_v1', 'fz_office_profiles/donna', jsonb_build_object('roles', to_jsonb(v_roles), 'prohibited', v_autonomy -> 'prohibited'));
end $$;
