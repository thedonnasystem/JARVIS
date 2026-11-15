-- SQL-level checks for migrations/20261118_ffm_onboarding_v1.sql. SCRATCH replica only. One transaction, rolled back.
-- Proves: default-deny grants, workspace isolation (FKs, reports, routing), refusal of sensitive data on every new table,
-- activation gating (inputs + budget + owner approval + staleness), owner-only actions refused for the bot, dry-run-only campaigns/routing.
begin;
create function pg_temp.expect_fail(p_sql text, p_pat text) returns void language plpgsql as $$
begin
  begin execute p_sql; exception when others then
    if sqlerrm like p_pat then return; end if;
    raise exception 'wrong error for [%]: got [%], wanted like [%]', p_sql, sqlerrm, p_pat;
  end;
  raise exception 'NOT REFUSED: %', p_sql;
end $$;
create function pg_temp.as_owner(p boolean) returns void language plpgsql as $$
begin
  if p then perform set_config('app.uid', '99999999-9999-9999-9999-999999999991', true);
  else perform set_config('app.uid', '', true); end if;
end $$;
-- fixture: open the outreach gate (closed by default) and give the tests an owner-attested capture helper. Evidence verification itself is tested in consent_integrity_check.sql.
set local session_replication_role = replica;
insert into public.ffm_secrets (name, value, set_by) values ('suppression_hmac_key', repeat('fixture-key-', 4), 'fixture') on conflict do nothing;
update public.ffm_outreach_gate set state = 'verified', verified_raw_count = 0, reason = 'test fixture' where id = 1;
set local session_replication_role = origin;
create function pg_temp.express(p_ws uuid, p_lead uuid, p_ch text, p_ref text, p_by text default 'bot') returns uuid language plpgsql as $$
declare prev text := current_setting('app.uid', true); r uuid;
begin
  perform set_config('app.uid', '99999999-9999-9999-9999-999999999991', true);
  if not exists (select 1 from public.ffm_consent_wordings where workspace_id = p_ws and version = 'v1') then perform public.ffm_register_wording(p_ws, 'v1', repeat('b', 64), 'test'); end if;
  perform public.ffm_register_capture_owner(p_ws, p_ref, p_ch, 'v1', repeat('a', 64), now() - interval '2 hours', p_lead, null, 'test');
  perform set_config('app.uid', coalesce(prev, ''), true);
  return public.ffm_record_consent(p_ws, p_lead, p_ch, 'express', 'v1', 'web form', now(), p_ref, p_by);
end $$;
do $$
declare a uuid; b uuid; ca uuid; cb uuid; sa uuid; cra uuid; rr uuid; lead_a uuid; lead_b uuid; ap uuid; t text; r text; f text; j jsonb; k text; n int; s text;
begin
  insert into auth.users (id, email) values ('99999999-9999-9999-9999-999999999991', 'ffm-owner@example.com');
  insert into public.app_owners (email) values ('ffm-owner@example.com');
  perform pg_temp.as_owner(false);

  -- F1-F6 grants: RLS on, no policy, nothing for anon/authenticated, service_role read-only on tables and views
  foreach t in array array['ffm_onboarding_templates', 'ffm_onboarding_items', 'ffm_ad_sets', 'ffm_creatives', 'ffm_routing_rules', 'ffm_approvals', 'ffm_route_log'] loop
    if not (select relrowsecurity from pg_class where oid = ('public.' || t)::regclass) then raise exception 'F1 RLS off on %', t; end if;
    if exists (select 1 from pg_policy where polrelid = ('public.' || t)::regclass) then raise exception 'F2 policy on %', t; end if;
    foreach r in array array['anon', 'authenticated'] loop
      if has_table_privilege(r, 'public.' || t, 'select') or has_table_privilege(r, 'public.' || t, 'insert') then raise exception 'F3 % has access to %', r, t; end if;
    end loop;
    foreach r in array array['insert', 'update', 'delete', 'truncate', 'trigger', 'references'] loop
      if has_table_privilege('service_role', 'public.' || t, r) then raise exception 'F4 service_role can % %', r, t; end if;
    end loop;
  end loop;
  foreach t in array array['ffm_funnel_v', 'ffm_spend_v'] loop
    foreach r in array array['anon', 'authenticated'] loop
      if has_table_privilege(r, 'public.' || t, 'select') then raise exception 'F3b % can read view %', r, t; end if;
    end loop;
    if has_table_privilege('service_role', 'public.' || t, 'insert') then raise exception 'F4b service_role writes view %', t; end if;
  end loop;
  for f in select p.oid::regprocedure::text from pg_proc p where p.pronamespace = 'public'::regnamespace and p.proname like 'ffm\_%' loop
    foreach r in array array['anon', 'authenticated'] loop
      if has_function_privilege(r, f, 'execute') then raise exception 'F5 % can execute %', r, f; end if;
    end loop;
    if not has_function_privilege('service_role', f, 'execute') then raise exception 'F6 service_role cannot execute %', f; end if;
  end loop;
  select count(*) into n from pg_proc where pronamespace = 'public'::regnamespace and proname like 'ffm\_%';
  if n <> 51 then raise exception 'F6b expected 51 ffm functions (21 onboarding + 7 consent + 12 evidence (+ffm_lp, ffm_key_problem) + 11 suppression integrity (-ffm_suppression_mac, +ffm_sup_message)), found %', n; end if;

  -- two clients
  insert into public.client_workspaces (slug, name, vertical) values ('f-mortgage', 'Test Mortgage Broker', 'mortgage') returning id into a;
  insert into public.client_workspaces (slug, name, vertical) values ('f-insurance', 'Test Life Insurance', 'insurance') returning id into b;
  if (select status from public.client_workspaces where id = a) <> 'draft' then raise exception 'F7 workspace not draft by default'; end if;
  if (select monthly_budget_cents from public.client_workspaces where id = a) is not null then raise exception 'F8 budget not null by default'; end if;

  -- onboarding instantiation per vertical, idempotent, isolated
  if public.ffm_instantiate_onboarding(a) < 10 then raise exception 'F9 too few items'; end if;
  perform public.ffm_instantiate_onboarding(b);
  if public.ffm_instantiate_onboarding(a) <> 0 then raise exception 'F10 not idempotent'; end if;
  if not exists (select 1 from public.ffm_onboarding_items where workspace_id = a and template_key = 'no_sensitive_files_confirmed') then raise exception 'F11 mortgage item missing'; end if;
  if exists (select 1 from public.ffm_onboarding_items where workspace_id = b and template_key = 'no_sensitive_files_confirmed') then raise exception 'F12 mortgage item leaked to insurance'; end if;
  if not exists (select 1 from public.ffm_onboarding_items where workspace_id = b and template_key = 'recruiting_model' and required and status = 'pending' and value_text is null) then raise exception 'F13 insurance recruiting_model must be required and unset'; end if;
  if exists (select 1 from public.ffm_onboarding_items where workspace_id = a and template_key = 'recruiting_model') then raise exception 'F14 insurance item leaked to mortgage'; end if;

  -- placeholders and unknown keys are refused; values are guarded
  perform pg_temp.expect_fail(format($q$select public.ffm_provide_input(%L, 'service_geography', 'unset', 'moe')$q$, a), 'a real value%');
  perform pg_temp.expect_fail(format($q$select public.ffm_provide_input(%L, 'service_geography', 'TBD', 'moe')$q$, a), 'a real value%');
  perform pg_temp.expect_fail(format($q$select public.ffm_provide_input(%L, 'nope', 'x', 'moe')$q$, a), 'unknown onboarding item%');
  perform pg_temp.expect_fail(format($q$select public.ffm_provide_input(%L, 'service_geography', 'Ottawa', '')$q$, a), 'say who%');
  perform pg_temp.expect_fail(format($q$select public.ffm_provide_input(%L, 'crm_destination', 'send the bank statement to crm', 'moe')$q$, a), 'Sensitive data refused%');
  perform pg_temp.expect_fail(format($q$select public.ffm_provide_input(%L, 'crm_destination', 'SIN 123-456-789', 'moe')$q$, a), 'Sensitive data refused%');

  -- activation is refused, with every reason, while anything is missing
  perform pg_temp.expect_fail(format($q$select public.ffm_activate(%L)$q$, a), 'activation refused:%missing required inputs%no monthly budget%no owner approval%');
  -- the bot cannot set the budget or approve
  perform pg_temp.expect_fail(format($q$select public.ffm_set_budget(%L, 50000)$q$, a), 'owner approval required%');
  perform pg_temp.expect_fail(format($q$select public.ffm_owner_approve(%L, 'activation')$q$, a), 'owner approval required%');
  perform pg_temp.expect_fail(format($q$select public.ffm_revoke_approval(gen_random_uuid())$q$), 'owner approval required%');
  -- a non-owner signed-in user is also refused
  insert into auth.users (id, email) values ('99999999-9999-9999-9999-999999999992', 'stranger@example.com');
  perform set_config('app.uid', '99999999-9999-9999-9999-999999999992', true);
  perform pg_temp.expect_fail(format($q$select public.ffm_owner_approve(%L, 'activation')$q$, a), 'owner approval required%');
  perform pg_temp.as_owner(false);

  -- supply every required input except one, owner sets budget + approves: still refused
  for k in select template_key from public.ffm_onboarding_items where workspace_id = a and required and template_key <> 'launch_deadline' loop
    if k <> 'booking_link' then perform public.ffm_provide_input(a, k, 'value for ' || k, 'client contact'); end if;
  end loop;
  perform pg_temp.as_owner(true);
  perform public.ffm_set_budget(a, 100000);
  ap := public.ffm_owner_approve(a, 'activation', null, 'ready');
  perform pg_temp.as_owner(false);
  j := public.ffm_readiness(a);
  if (j->>'ready')::boolean or j->'missing_required' <> '["booking_link"]'::jsonb then raise exception 'F15 readiness wrong: %', j; end if;
  perform pg_temp.expect_fail(format($q$select public.ffm_activate(%L)$q$, a), 'activation refused: missing required inputs: booking_link%');
  -- supplying the last input AFTER approval makes the approval stale
  perform public.ffm_provide_input(a, 'booking_link', 'https://example.com/book', 'client contact');
  j := public.ffm_readiness(a);
  if not (j->>'approval_stale')::boolean or (j->>'ready')::boolean then raise exception 'F16 approval should be stale: %', j; end if;
  perform pg_temp.expect_fail(format($q$select public.ffm_activate(%L)$q$, a), 'activation refused:%stale%');
  -- other workspace is unaffected and still refused
  perform pg_temp.expect_fail(format($q$select public.ffm_activate(%L)$q$, b), 'activation refused:%');
  -- re-approve; budget change after approval also stales it
  perform pg_temp.as_owner(true);
  perform public.ffm_owner_approve(a, 'activation');
  perform public.ffm_set_budget(a, 90000);
  perform pg_temp.as_owner(false);
  perform pg_temp.expect_fail(format($q$select public.ffm_activate(%L)$q$, a), 'activation refused:%stale%');
  perform pg_temp.as_owner(true);
  ap := public.ffm_owner_approve(a, 'activation');
  perform pg_temp.as_owner(false);
  -- budget must be a real number; the approved-at-budget is recorded
  if (select budget_cents_at_approval from public.ffm_approvals where id = ap) <> 90000 then raise exception 'F17 budget not recorded in approval'; end if;
  -- a revoked approval blocks activation
  perform pg_temp.as_owner(true); perform public.ffm_revoke_approval(ap); perform pg_temp.as_owner(false);
  perform pg_temp.expect_fail(format($q$select public.ffm_activate(%L)$q$, a), 'activation refused:%');
  perform pg_temp.as_owner(true); ap := public.ffm_owner_approve(a, 'activation'); perform pg_temp.as_owner(false);
  j := public.ffm_activate(a);
  if (select status from public.client_workspaces where id = a) <> 'active' then raise exception 'F18 not active'; end if;
  if (select status from public.client_workspaces where id = b) <> 'draft' then raise exception 'F19 other workspace changed'; end if;
  perform pg_temp.expect_fail(format($q$select public.ffm_activate(%L)$q$, a), 'activation refused: workspace is not in draft%');

  -- blocked items and their reasons
  perform public.ffm_block_input(b, 'licensing_status', 'client has not replied');
  if (select status from public.ffm_onboarding_items where workspace_id = b and template_key = 'licensing_status') <> 'blocked' then raise exception 'F20 not blocked'; end if;

  -- campaign architecture: drafts are plain text, guarded, isolated, dry-run only
  ca := public.ffm_add_campaign(a, 'Renewal reminders', 'meta');
  cb := public.ffm_add_campaign(b, 'Agent recruiting test', 'meta');
  sa := public.ffm_add_ad_set(a, ca, 'Ottawa homeowners', 'renewal in the next year', null);
  cra := public.ffm_add_creative(a, ca, sa, 'Mortgage renewal coming up?', 'Talk to a licensed broker about your options.', 'Book a call');
  perform pg_temp.expect_fail(format($q$select public.ffm_add_ad_set(%L, %L, 'x ad set')$q$, a, cb), '%foreign key%');
  perform pg_temp.expect_fail(format($q$select public.ffm_add_creative(%L, %L, %L, 'hello there', 'body text')$q$, b, cb, sa), '%foreign key%');
  perform pg_temp.expect_fail(format($q$select public.ffm_add_creative(%L, %L, %L, 'Upload your credit report', 'body text')$q$, a, ca, sa), 'Sensitive data refused%');
  perform pg_temp.expect_fail(format($q$select public.ffm_add_creative(%L, %L, %L, 'Fine headline', 'send your bank statement here')$q$, a, ca, sa), 'Sensitive data refused%');
  perform pg_temp.expect_fail(format($q$select public.ffm_add_ad_set(%L, %L, 'Fine name', 'income over 100k')$q$, a, ca), 'Sensitive data refused%');
  perform pg_temp.expect_fail(format($q$select public.ffm_add_campaign(%L, 'Pre-approval push')$q$, a), 'Sensitive data refused%');
  perform pg_temp.expect_fail($q$insert into public.ffm_creatives (workspace_id, campaign_id, ad_set_id, headline, body, dry_run) select workspace_id, campaign_id, id, 'hello', 'body text', false from public.ffm_ad_sets limit 1$q$, '%violates check%');
  perform pg_temp.expect_fail($q$update public.ffm_ad_sets set dry_run = false$q$, '%violates check%');
  -- the bot can send a creative to review but cannot approve it; the owner can
  perform public.ffm_set_creative_status(a, cra, 'in_review');
  perform pg_temp.expect_fail(format($q$select public.ffm_set_creative_status(%L, %L, 'approved')$q$, a, cra), 'owner approval required%');
  perform pg_temp.expect_fail(format($q$select public.ffm_set_creative_status(%L, %L, 'in_review')$q$, b, cra), 'creative not found in this workspace%');
  -- campaign approval needs an active workspace and an approved creative; it only reaches 'approved', never 'running'
  perform pg_temp.as_owner(true);
  perform pg_temp.expect_fail(format($q$select public.ffm_owner_approve(%L, 'campaign', %L)$q$, a, ca), 'campaign has no approved creative%');
  perform pg_temp.expect_fail(format($q$select public.ffm_owner_approve(%L, 'campaign', %L)$q$, a, cb), 'campaign not found in this workspace%');
  perform public.ffm_set_creative_status(a, cra, 'approved');
  perform public.ffm_owner_approve(a, 'campaign', ca, 'ok for dry run');
  perform pg_temp.as_owner(false);
  if (select status from public.ws_campaigns where id = ca) <> 'approved' then raise exception 'F21 campaign not approved'; end if;
  if exists (select 1 from public.ws_campaigns where status = 'running') then raise exception 'F22 something is running'; end if;
  perform pg_temp.as_owner(true);
  perform pg_temp.expect_fail(format($q$select public.ffm_owner_approve(%L, 'campaign', %L)$q$, b, cb), 'workspace is not active%');
  perform pg_temp.as_owner(false);

  -- routing: default deny, allow-list only, never free text, approved-only, same workspace, dry run
  lead_a := public.ws_add_lead(a, ca, 'Pat Example', 'pat@example.com', '613-555-0142', 'web form', 'wants a callback about renewal');
  lead_b := public.ws_add_lead(b, cb, 'Sam Other', 'sam@example.com', null, 'referral');
  -- (20261119) routing preview now needs current consent: record an express consent for both test leads so this section keeps testing routing, not consent
  perform pg_temp.express(a, lead_a, 'email', 'form-001', 'test');
  perform pg_temp.express(b, lead_b, 'email', 'form-002', 'test');
  perform pg_temp.expect_fail(format($q$select public.ffm_add_routing_rule(%L, 'bad', 'email', 'x@example.com', array['name','note'])$q$, a), '%violates check%');
  perform pg_temp.expect_fail(format($q$select public.ffm_add_routing_rule(%L, 'bad', 'email', 'x@example.com', array['name','sin'])$q$, a), '%violates check%');
  perform pg_temp.expect_fail(format($q$select public.ffm_add_routing_rule(%L, 'bad', 'email', 'bank statement inbox', array['name'])$q$, a), 'Sensitive data refused%');
  rr := public.ffm_add_routing_rule(a, 'To broker CRM', 'crm', 'broker-crm-intake', array['name', 'email', 'phone', 'source']);
  if public.ffm_route_preview(a, lead_a) <> '[]'::jsonb then raise exception 'F23 unapproved rule produced a payload'; end if;
  perform pg_temp.as_owner(true); perform public.ffm_owner_approve(a, 'routing', rr); perform pg_temp.as_owner(false);
  j := public.ffm_route_preview(a, lead_a);
  if jsonb_array_length(j) <> 1 or j->0->'payload' <> '{"name":"Pat Example","email":"pat@example.com","phone":"613-555-0142","source":"web form"}'::jsonb then raise exception 'F24 payload wrong: %', j; end if;
  if j->0->'payload' ? 'note' or (j->0->>'dry_run')::boolean is not true then raise exception 'F25 note leaked or not dry run'; end if;
  perform pg_temp.expect_fail(format($q$select public.ffm_route_preview(%L, %L)$q$, a, lead_b), 'lead not found in this workspace%');
  perform pg_temp.expect_fail(format($q$select public.ffm_route_preview(%L, %L)$q$, b, lead_a), 'lead not found in this workspace%');
  if public.ffm_route_preview(b, lead_b) <> '[]'::jsonb then raise exception 'F26 rule leaked across workspaces'; end if;
  if (select count(*) from public.ffm_route_log where workspace_id = a) <> 1 or exists (select 1 from public.ffm_route_log where dry_run is not true) then raise exception 'F27 route log wrong'; end if;
  -- an empty field list passes nothing
  rr := public.ffm_add_routing_rule(a, 'Empty', 'email', 'nobody@example.com', null);
  perform pg_temp.as_owner(true); perform public.ffm_owner_approve(a, 'routing', rr); perform pg_temp.as_owner(false);
  if jsonb_array_length(public.ffm_route_preview(a, lead_a)) <> 1 then raise exception 'F28 empty rule produced output'; end if;
  -- a sensitive value that slipped into an allow-listed lead field is caught at routing time (ws_leads guard normally stops it earlier)
  perform pg_temp.expect_fail($q$update public.ffm_routing_rules set allowed_fields = array['name','note']$q$, '%violates check%');

  -- reporting: strictly per workspace
  perform public.ws_add_lead(a, ca, 'Booked One', 'b1@example.com', null, 'web form');
  update public.ws_leads set stage = 'booked' where workspace_id = a and name = 'Booked One';
  j := public.ffm_funnel(a);
  if (j->>'leads')::int <> 2 or (j->'by_stage'->>'booked')::int <> 1 or j->>'workspace' <> 'f-mortgage' then raise exception 'F29 funnel A wrong: %', j; end if;
  j := public.ffm_funnel(b);
  if (j->>'leads')::int <> 1 or j->'by_stage' ? 'booked' then raise exception 'F30 funnel B leaks: %', j; end if;
  j := public.ffm_lead_booked_rate(a);
  if (j->>'rate')::numeric <> 0.5 then raise exception 'F31 rate wrong: %', j; end if;
  if (public.ffm_lead_booked_rate(b)->>'rate')::numeric <> 0 then raise exception 'F32 rate B wrong'; end if;

  -- spend vs budget: unset budget reads 'unset' and refuses spend; set budget reports remaining; isolated
  j := public.ffm_spend_report(b);
  if j->>'budget' <> 'unset' or j->'remaining_cents' <> 'null'::jsonb or j->'pct_used' <> 'null'::jsonb then raise exception 'F33 unset budget report wrong: %', j; end if;
  perform public.ws_record_spend(a, ca, 22500, 'dry-run bookkeeping only');
  j := public.ffm_spend_report(a);
  if (j->>'spent_cents')::int <> 22500 or (j->>'remaining_cents')::int <> 67500 or (j->>'pct_used')::numeric <> 0.25 then raise exception 'F34 spend report wrong: %', j; end if;
  if (public.ffm_spend_report(b)->>'spent_cents')::int <> 0 then raise exception 'F35 spend leaks'; end if;
  if (select spent_all_time_cents from public.ffm_spend_v where workspace_id = a) <> 22500 or (select spent_all_time_cents from public.ffm_spend_v where workspace_id = b) <> 0 then raise exception 'F36 spend view wrong'; end if;
  if (select leads from public.ffm_funnel_v where workspace_id = a) <> 2 or (select leads from public.ffm_funnel_v where workspace_id = b) <> 1 then raise exception 'F37 funnel view wrong'; end if;
  perform pg_temp.expect_fail(format($q$select public.ws_record_spend(%L, %L, 1, 'x')$q$, b, cb), '%');

  -- weekly report: shape, window, isolation
  j := public.ffm_weekly_report(a, now() - interval '1 day', now() + interval '1 day');
  if j->>'workspace' <> 'f-mortgage' or (j->'funnel'->>'leads')::int <> 2 or (j->'lead_to_booked'->>'booked')::int <> 1
     or (j->'spend'->>'spent_in_period_cents')::int <> 22500 or (j->'campaigns_by_status'->>'approved')::int <> 1
     or (j->'readiness'->>'status') <> 'active' or (j->>'creatives_awaiting_review')::int <> 0 then raise exception 'F38 weekly report wrong: %', j; end if;
  j := public.ffm_weekly_report(a, now() - interval '30 day', now() - interval '20 day');
  if (j->'funnel'->>'leads')::int <> 0 or (j->'spend'->>'spent_in_period_cents')::int <> 0 or (j->'lead_to_booked'->'rate') <> 'null'::jsonb then raise exception 'F39 empty window wrong: %', j; end if;
  j := public.ffm_weekly_report(b, now() - interval '1 day', now() + interval '1 day');
  if (j->'funnel'->>'leads')::int <> 1 or (j->'spend'->>'spent_in_period_cents')::int <> 0 or (j->'campaigns_by_status'->>'draft')::int <> 1 or (j->'readiness'->>'ready')::boolean then raise exception 'F40 weekly report B wrong: %', j; end if;
  perform pg_temp.expect_fail($q$select public.ffm_weekly_report(gen_random_uuid())$q$, 'workspace not found%');
  if public.ffm_readiness(gen_random_uuid())->>'ready' <> 'false' then raise exception 'F41 unknown workspace ready'; end if;
  -- no sensitive wording survives anywhere in the stored onboarding rows
  if exists (select 1 from public.ffm_onboarding_items where array_length(public.ws_sensitive_hits(title || ' ' || coalesce(value_text, '')), 1) > 0) then raise exception 'F42 stored item looks sensitive'; end if;
  -- guard bypass regression (reviewer repros): a date-shaped prefix must NOT excuse digits behind it, in ANY free-text column
  perform pg_temp.expect_fail(format($q$select public.ffm_provide_input(%L, 'service_geography', '2026-01-01 123456789', 'moe')$q$, a), 'Sensitive data refused%');
  perform pg_temp.expect_fail(format($q$select public.ffm_provide_input(%L, 'service_geography', '2026-01-01T 4111 1111 1111 1111', 'moe')$q$, a), 'Sensitive data refused%');
  perform pg_temp.expect_fail(format($q$select public.ffm_provide_input(%L, 'service_geography', '2026-01-01 4111-1111-1111-1111', 'moe')$q$, a), 'Sensitive data refused%');
  perform pg_temp.expect_fail(format($q$select public.ffm_provide_input(%L, 'service_geography', 'Ottawa', '2026-01-01 123456789')$q$, a), 'Sensitive data refused%');   -- provided_by
  perform pg_temp.expect_fail(format($q$select public.ffm_block_input(%L, 'launch_deadline', '2026-01-01 123 456 789')$q$, a), 'Sensitive data refused%');          -- blocked_until
  perform pg_temp.expect_fail(format($q$select public.ffm_add_ad_set(%L, %L, 'Fine name', '2026-01-01 123456789')$q$, a, ca), 'Sensitive data refused%');            -- audience_note
  perform pg_temp.expect_fail(format($q$select public.ffm_add_creative(%L, %L, %L, 'Fine headline', '2026-01-01T 4111 1111 1111 1111', 'Book')$q$, a, ca, sa), 'Sensitive data refused%');
  perform pg_temp.expect_fail(format($q$select public.ffm_add_routing_rule(%L, 'ok rule', 'email', '2026-01-01 123456789', array['name'])$q$, a), 'Sensitive data refused%');
  perform pg_temp.as_owner(true);
  perform pg_temp.expect_fail(format($q$select public.ffm_owner_approve(%L, 'activation', null, '2026-01-01 123456789')$q$, a), 'Sensitive data refused%');   -- approvals.note
  perform pg_temp.as_owner(false);
  -- obfuscated variants go through the same detector (checked directly and through the guard)
  foreach s in array array['１２３４５６７８９', '123 456 789', '123-456-789', '123.456.789', '1 2 3 4 5 6 7 8 9', E'1​2​3456789', '٤١١١١١١١١١١١١١١١١', '4111 1111 1111 1111', '2026-01-01 １２３４５６７８９'] loop
    if array_length(public.ws_sensitive_hits(s), 1) is null then raise exception 'G1 detector missed %', s; end if;
    perform pg_temp.expect_fail(format($q$select public.ffm_provide_input(%L, 'service_geography', %L, 'moe')$q$, a, s), 'Sensitive data refused%');
  end loop;
  -- typed uuid/timestamptz columns are still not scanned (no false refusals), and every other string column is
  insert into public.ffm_approvals (workspace_id, kind, approved_by, created_at) values (a, 'routing', 'ok', '2026-01-01 12:34:56.789012+00');
  delete from public.ffm_approvals where approved_by = 'ok';

  -- app_ffm_* owner wrappers: owner works; anon / stranger / bot refused; nothing launches
  foreach f in array array['app_ffm_workspaces()', 'app_ffm_inputs(uuid)', 'app_ffm_set_budget(uuid,integer)', 'app_ffm_approve_activation(uuid,text)',
                           'app_ffm_revoke_approval(uuid)', 'app_ffm_approve_creative(uuid,uuid)', 'app_ffm_weekly_report(uuid,timestamptz,timestamptz)'] loop
    foreach r in array array['anon', 'authenticated'] loop
      if has_function_privilege(r, 'public.' || f, 'execute') then raise exception 'W1 % can execute %', r, f; end if;
    end loop;
    if not has_function_privilege('service_role', 'public.' || f, 'execute') then raise exception 'W2 service_role cannot execute %', f; end if;
  end loop;
  if exists (select 1 from pg_proc where pronamespace = 'public'::regnamespace and proname ~ '^app_ffm_(activate|launch|run|publish|spend|send)') then raise exception 'W3 a launch wrapper exists'; end if;
  perform pg_temp.as_owner(false);   -- bot / service path: no auth.uid()
  perform pg_temp.expect_fail($q$select public.app_ffm_workspaces()$q$, 'not authorized%');
  perform pg_temp.expect_fail(format($q$select public.app_ffm_inputs(%L)$q$, b), 'not authorized%');
  perform pg_temp.expect_fail(format($q$select public.app_ffm_set_budget(%L, 1)$q$, b), 'not authorized%');
  perform pg_temp.expect_fail(format($q$select public.app_ffm_approve_activation(%L)$q$, b), 'not authorized%');
  perform pg_temp.expect_fail(format($q$select public.app_ffm_revoke_approval(%L)$q$, gen_random_uuid()), 'not authorized%');
  perform pg_temp.expect_fail(format($q$select public.app_ffm_approve_creative(%L, %L)$q$, a, cra), 'not authorized%');
  perform pg_temp.expect_fail(format($q$select public.app_ffm_weekly_report(%L)$q$, a), 'not authorized%');
  perform set_config('app.uid', '99999999-9999-9999-9999-999999999992', true);   -- signed-in stranger
  perform pg_temp.expect_fail($q$select public.app_ffm_workspaces()$q$, 'not authorized%');
  perform pg_temp.expect_fail(format($q$select public.app_ffm_set_budget(%L, 1)$q$, b), 'not authorized%');
  perform pg_temp.expect_fail(format($q$select public.app_ffm_approve_activation(%L)$q$, b), 'not authorized%');
  perform pg_temp.expect_fail(format($q$select public.app_ffm_approve_creative(%L, %L)$q$, a, cra), 'not authorized%');
  perform pg_temp.as_owner(true);
  j := public.app_ffm_workspaces();
  if jsonb_array_length(j) <> 2 or not exists (select 1 from jsonb_array_elements(j) e where e->>'slug' = 'f-mortgage' and e->'readiness'->>'status' = 'active')
     or not exists (select 1 from jsonb_array_elements(j) e where e->>'slug' = 'f-insurance' and e->>'status' = 'draft') then raise exception 'W4 workspaces wrong: %', j; end if;
  j := public.app_ffm_inputs(a);
  if jsonb_array_length(j) < 10 or not exists (select 1 from jsonb_array_elements(j) e where e->>'key' = 'booking_link' and e->>'status' = 'provided') then raise exception 'W5 inputs wrong'; end if;
  if jsonb_array_length(public.app_ffm_inputs(b)) < 10 or public.app_ffm_inputs(gen_random_uuid()) <> '[]'::jsonb then raise exception 'W5b inputs isolation wrong'; end if;
  perform public.app_ffm_set_budget(a, 80000);
  if (select monthly_budget_cents from public.client_workspaces where id = a) <> 80000 then raise exception 'W6 budget not set'; end if;
  perform pg_temp.expect_fail(format($q$select public.app_ffm_set_budget(%L, -1)$q$, a), 'budget must be%');
  ap := public.app_ffm_approve_activation(a, 'via wrapper');
  if (select kind from public.ffm_approvals where id = ap) <> 'activation' or (select budget_cents_at_approval from public.ffm_approvals where id = ap) <> 80000 then raise exception 'W7 approval wrong'; end if;
  perform public.app_ffm_revoke_approval(ap);
  if (select revoked_at from public.ffm_approvals where id = ap) is null then raise exception 'W8 not revoked'; end if;
  perform pg_temp.expect_fail(format($q$select public.app_ffm_revoke_approval(%L)$q$, ap), 'approval not found or already revoked%');
  perform pg_temp.as_owner(false);
  perform public.ffm_set_creative_status(a, cra, 'in_review');
  perform pg_temp.as_owner(true);
  perform public.app_ffm_approve_creative(a, cra);
  if (select status from public.ffm_creatives where id = cra) <> 'approved' then raise exception 'W9 creative not approved'; end if;
  perform pg_temp.expect_fail(format($q$select public.app_ffm_approve_creative(%L, %L)$q$, b, cra), 'creative not found in this workspace%');
  j := public.app_ffm_weekly_report(a, now() - interval '1 day', now() + interval '1 day');
  if j->>'workspace' <> 'f-mortgage' or (j->'funnel'->>'leads')::int <> 2 then raise exception 'W10 report wrong: %', j; end if;
  perform pg_temp.as_owner(false);
  if exists (select 1 from public.ws_campaigns where status = 'running') then raise exception 'W11 something is running'; end if;
  -- the bot path stays refused for the underlying approvals too
  perform pg_temp.expect_fail(format($q$select public.ffm_owner_approve(%L, 'activation')$q$, a), 'owner approval required%');

  -- closed workspaces accept nothing
  update public.client_workspaces set status = 'closed' where id = b;
  perform pg_temp.expect_fail(format($q$select public.ffm_add_campaign(%L, 'late one')$q$, b), 'workspace not found or not open%');
  perform pg_temp.expect_fail(format($q$select public.ffm_provide_input(%L, 'launch_deadline', '2027-01-15', 'moe')$q$, b), 'workspace not found or not open%');
end $$;
rollback;
