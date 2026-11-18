-- Jarvis hands v1 (migrations/20261124_jarvis_hands_v1.sql). Everything in one transaction, rolled back. Run on a fresh apply (scripts/replica/run.sh does).
begin;
grant usage on schema public to anon, authenticated, service_role;
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
create function pg_temp.nouid(p_sql text) returns text language plpgsql as $$
declare r text; u text := current_setting('app.uid', true);
begin
  perform set_config('app.uid', '', true);
  begin execute p_sql into r; exception when others then perform set_config('app.uid', coalesce(u, ''), true); return 'ERR:' || sqlerrm; end;
  perform set_config('app.uid', coalesce(u, ''), true);
  return 'OK:' || coalesce(r, '');
end $$;
create function pg_temp.as_role(p_role text, p_sql text) returns text language plpgsql as $$
declare r text;
begin
  execute format('set local role %I', p_role);
  begin execute p_sql into r; exception when others then reset role; return 'ERR:' || sqlerrm; end;
  reset role;
  return 'OK:' || coalesce(r, '');
end $$;
insert into auth.users (id, email) values ('99999999-9999-9999-9999-99999999b001', 'hands-owner@example.invalid') on conflict do nothing;
insert into public.app_owners (email) values ('hands-owner@example.invalid') on conflict do nothing;
select set_config('app.uid', '99999999-9999-9999-9999-99999999b001', true);

do $$
declare res jsonb; acc uuid; act uuid; act2 uuid; v text; st text; ks0 boolean; mode0 text;
begin
  select kill_switch, mode into ks0, mode0 from public.system_state where id = 1;

  -- H1 dormant by default; account creation is assisted-only everywhere
  if exists (select 1 from public.hand_connectors where enabled) then raise exception 'H1 a connector is enabled by default'; end if;
  if exists (select 1 from public.executor_registry where slug like 'hands-%') then raise exception 'H1 a hand is registered by default'; end if;
  if (select status from public.agents where slug = 'jarvis-hands') <> 'paused' then raise exception 'H1 jarvis-hands agent is not paused'; end if;
  if exists (select 1 from public.hand_standing) then raise exception 'H1 a standing approval exists by default'; end if;
  if exists (select 1 from public.hand_connectors where signup_mode not in ('assisted', 'none')) then raise exception 'H1 a non-assisted sign-up mode'; end if;
  begin update public.hand_connectors set signup_mode = 'auto' where slug = 'tiktok'; raise exception 'H1 an automated sign-up mode was accepted';
  exception when check_violation then null; end;
  if (select count(*) from public.hand_connectors) <> 8 then raise exception 'H1 connector count %', (select count(*) from public.hand_connectors); end if;

  -- H2 owner-only controls; the bot, a plain SQL session and the API roles are refused
  if pg_temp.svc($q$select public.hands_owner_enable(true)::text$q$) not like 'ERR:owner approval required%' then raise exception 'H2 the bot enabled the hand'; end if;
  if pg_temp.nouid($q$select public.hands_owner_enable(true)::text$q$) not like 'ERR:owner approval required%' then raise exception 'H2 a plain SQL session enabled the hand'; end if;
  if pg_temp.svc($q$select public.hands_owner_set_connector('tiktok', true)::text$q$) not like 'ERR:owner approval required%' then raise exception 'H2 the bot enabled a connector'; end if;
  if pg_temp.svc($q$select public.hands_owner_set_standing('division', 'donna', true)::text$q$) not like 'ERR:owner approval required%' then raise exception 'H2 the bot set a standing approval'; end if;
  if pg_temp.svc($q$update public.hand_connectors set enabled = true returning 'x'$q$) not like 'ERR:permission denied%' then raise exception 'H2 the bot wrote hand_connectors'; end if;
  if pg_temp.svc($q$insert into public.hand_standing (scope_kind, scope_ref, enabled, set_by) values ('division', 'donna', true, 'x') returning 'x'$q$) not like 'ERR:permission denied%' then raise exception 'H2 the bot wrote hand_standing'; end if;
  if pg_temp.svc($q$update public.hand_actions set status = 'approved' returning 'x'$q$) not like 'ERR:permission denied%' then raise exception 'H2 the bot wrote hand_actions'; end if;
  if pg_temp.svc($q$insert into public.executor_registry (slug, enabled) values ('hands-actions', true) returning 'x'$q$) not like 'ERR:permission denied%' then raise exception 'H2 the bot registered an executor'; end if;
  foreach v in array array['anon', 'authenticated'] loop
    if pg_temp.as_role(v, $q$select public.hands_propose_account('tiktok', 'donna', 'abc', null, 'a purpose')::text$q$) not like 'ERR:permission denied%' then raise exception 'H2 % can propose', v; end if;
    if pg_temp.as_role(v, $q$select count(*)::text from public.hand_accounts$q$) not like 'ERR:permission denied%' then raise exception 'H2 % can read accounts', v; end if;
  end loop;
  if pg_temp.svc($q$select public.hands_decide('00000000-0000-0000-0000-000000000000', true, 'jarvis')::text$q$) not like 'ERR:hands_decide: only the owner%' then raise exception 'H2 a non-owner decision was accepted'; end if;
  begin perform public.hands_owner_set_connector('acme', true); raise exception 'H2 an unknown connector was created by SQL';
  exception when others then if sqlerrm not like '%unknown connector%' then raise; end if; end;

  -- H3 proposals: refused while the connector is off; approval is a handoff to the owner, never queued; the owner records completion
  res := public.hands_propose_account('meta-instagram', 'donna', 'donna_hq', 'Donna', 'brand account for the division');
  if (res ->> 'ok')::boolean then raise exception 'H3 proposal accepted for a disabled connector'; end if;
  perform public.hands_owner_set_connector('meta-instagram', true);
  res := public.hands_propose_account('meta-instagram', 'nope-division', 'donna_hq', 'Donna', 'brand account for the division');
  if (res ->> 'ok')::boolean then raise exception 'H3 dormant division accepted'; end if;
  res := public.hands_propose_account('meta-instagram', 'donna', 'donna_hq', 'Donna', 'brand account for the division', 'bio');
  if not (res ->> 'ok')::boolean then raise exception 'H3 proposal refused: %', res; end if;
  acc := (res ->> 'account_id')::uuid; act := (res ->> 'action_id')::uuid;
  if not exists (select 1 from public.owner_messages where ref_table = 'hand_actions' and ref_id = act and needs_decision and body like 'Sir, %') then raise exception 'H3 no decision message for the owner'; end if;
  update public.system_state set mode = 'auto_in_caps', kill_switch = false where id = 1;
  perform public.hands_owner_enable(true);
  res := public.hands_decide(act, true, 'owner:telegram');
  if res ->> 'status' <> 'handoff' or res ->> 'signup_url' not like 'https://%' or (select status from public.hand_accounts where id = acc) <> 'handoff' then raise exception 'H3 approval did not hand off: %', res; end if;
  if exists (select 1 from public.jarvis_jobs where payload ->> 'action_id' = act::text) then raise exception 'H3 an account creation was queued for the worker'; end if;
  if (public.hands_start(act) ->> 'ok')::boolean then raise exception 'H3 the worker could start an account creation'; end if;
  if (public.hands_run_now(act, 'owner:telegram') ->> 'ok')::boolean then raise exception 'H3 /post could run an account creation'; end if;
  if (public.hands_decide(act, true, 'owner:telegram') ->> 'ok')::boolean then raise exception 'H3 decided twice'; end if;
  perform public.hands_account_done(acc, 'donna_hq', 'owner:telegram');
  if (select status from public.hand_accounts where id = acc) <> 'created' or (select status from public.hand_actions where id = act) <> 'done' then raise exception 'H3 owner completion not recorded'; end if;
  perform public.hands_owner_enable(false);

  -- H4 only vault ids are stored: a raw token is refused; only the owner connects
  begin perform public.hands_connect('meta-instagram', 'donna', 'donna_hq', '1789', 'EAAB-raw-access-token', null, '{}', 'owner:telegram'); raise exception 'H4 a raw token was stored';
  exception when check_violation then null; end;
  res := public.hands_connect('meta-instagram', 'donna', 'donna_hq', '1789', '0b8f2a7c-1111-4222-8333-444455556666', null, array['instagram_content_publish'], 'owner:telegram');
  if not (res ->> 'ok')::boolean or (select status from public.hand_accounts where id = acc) <> 'connected' then raise exception 'H4 connect failed: %', res; end if;
  if pg_temp.svc($q$select public.hands_connect('meta-instagram', 'donna', 'donna_hq', '1', '0b8f2a7c-1111-4222-8333-444455556666', null, '{}', 'jarvis')::text$q$) not like 'ERR:hands_connect: only the owner%' then raise exception 'H4 the bot connected an account'; end if;

  -- H5 personal or sensitive data in a public post is refused at submit; unknown actions refused
  res := public.hands_submit_action('meta-instagram', acc, 'post', '{"text": "Client SIN 046 454 286 approved", "media": ["https://cdn.example.invalid/a.jpg"]}');
  if (res ->> 'ok')::boolean or res ->> 'reason' not like 'refused: %' then raise exception 'H5 sensitive post accepted: %', res; end if;
  res := public.hands_submit_action('meta-instagram', acc, 'deploy', '{"text": "x"}');
  if (res ->> 'ok')::boolean then raise exception 'H5 an action the connector does not allow was accepted'; end if;

  -- H6 dry_run: an approved post is only logged as "would post", nothing is queued; a draft cannot be released by the bot
  update public.system_state set mode = 'dry_run' where id = 1;
  res := public.hands_submit_action('meta-instagram', acc, 'post', '{"text": "Fresh spring offer from Donna", "media": ["https://cdn.example.invalid/a.jpg"]}');
  act := (res ->> 'action_id')::uuid;
  if res ->> 'status' <> 'draft' then raise exception 'H6 a post skipped approval: %', res; end if;
  if pg_temp.svc(format($q$select public.hands_release(%L)::text$q$, act)) not like 'ERR:%' then raise exception 'H6 a draft was released without approval'; end if;
  perform public.hands_decide(act, true, 'owner:telegram');
  select status, result into st, v from public.hand_actions where id = act;
  if st <> 'dry_run' or v not like 'dry run: would post%' then raise exception 'H6 dry run not recorded: % %', st, v; end if;
  if exists (select 1 from public.jarvis_jobs where payload ->> 'action_id' = act::text) then raise exception 'H6 dry run queued a job'; end if;
  if not exists (select 1 from public.audit_log where action = 'hands_dry_run' and detail ->> 'action' = act::text) then raise exception 'H6 no audit row'; end if;

  -- H7 live mode: stays approved while the hand is off; queued once the owner enables it
  update public.system_state set mode = 'auto_in_caps' where id = 1;
  res := public.hands_run_now(act, 'owner:telegram');
  if res ->> 'status' <> 'approved' or (res ->> 'queued')::boolean then raise exception 'H7 queued while the hand is off: %', res; end if;
  if pg_temp.svc(format($q$select public.hands_run_now(%L, 'jarvis')::text$q$, act)) not like 'ERR:hands_run_now: owner only%' then raise exception 'H7 the bot re-ran an action'; end if;
  perform public.hands_owner_enable(true, 5, 1);
  if (select status from public.agents where slug = 'jarvis-hands') <> 'active' then raise exception 'H7 agent not active after enable'; end if;
  res := public.hands_run_now(act, 'owner:telegram');
  if not (res ->> 'queued')::boolean then raise exception 'H7 not queued: %', res; end if;
  if not exists (select 1 from public.jarvis_jobs where kind = 'hands.action' and payload ->> 'action_id' = act::text and (payload ->> 'external')::boolean) then raise exception 'H7 no external-flagged job'; end if;

  -- H8 kill switch: nothing starts
  update public.system_state set kill_switch = true where id = 1;
  res := public.hands_start(act);
  if (res ->> 'ok')::boolean or res ->> 'reason' <> 'kill switch is on' then raise exception 'H8 started under the kill switch: %', res; end if;
  update public.system_state set kill_switch = false where id = 1;

  -- H9 start, executor gate, finish; then the per-connector daily limit defers the next one to tomorrow
  update public.hand_connectors set max_actions_per_day = 1 where slug = 'meta-instagram';
  res := public.hands_start(act);
  if not (res ->> 'ok')::boolean or (res ->> 'est_cents')::int < 1 then raise exception 'H9 start failed: %', res; end if;
  if res -> 'account' ->> 'token_vault_ref' is null then raise exception 'H9 start did not hand back the vault reference'; end if;
  res := public.executor_request('hands-actions', 'jarvis-hands', (res ->> 'task_id')::uuid, 1, 'hands post');
  if not (res ->> 'ok')::boolean then raise exception 'H9 executor gate refused: %', res; end if;
  perform public.executor_complete((res ->> 'run_id')::uuid, 0, 'done');
  perform public.hands_finish(act, 'done', '17895695668004550', 'posted');
  if (select status from public.hand_actions where id = act) <> 'done' then raise exception 'H9 not done'; end if;
  res := public.hands_submit_action('meta-instagram', acc, 'post', '{"text": "Second post today", "media": ["https://cdn.example.invalid/b.jpg"]}');
  act2 := (res ->> 'action_id')::uuid;
  perform public.hands_decide(act2, true, 'owner:telegram');
  res := public.hands_start(act2);
  if not coalesce((res ->> 'deferred')::boolean, false) then raise exception 'H9 rate limit not applied: %', res; end if;
  if (select status from public.hand_actions where id = act2) <> 'scheduled' or (select scheduled_at from public.hand_actions where id = act2) < now() + interval '1 minute' then raise exception 'H9 not deferred'; end if;
  if not exists (select 1 from public.jarvis_jobs where payload ->> 'action_id' = act2::text and run_after > now()) then raise exception 'H9 no deferred job'; end if;

  -- H10 standing approval: default off; owner-set per division; post/upload only
  perform public.hands_owner_set_standing('division', 'donna', true);
  res := public.hands_submit_action('meta-instagram', acc, 'post', '{"text": "Standing approved post", "media": ["https://cdn.example.invalid/c.jpg"]}');
  if res ->> 'approval' <> 'standing' then raise exception 'H10 standing approval not used: %', res; end if;
  perform public.hands_owner_set_standing('division', 'donna', false);
  res := public.hands_submit_action('meta-instagram', acc, 'post', '{"text": "Needs the owner again", "media": ["https://cdn.example.invalid/d.jpg"]}');
  if res ->> 'status' <> 'draft' then raise exception 'H10 standing still applied after it was switched off'; end if;

  -- H11 email: drafts only (no separate tap)
  res := public.hands_submit_action('email', null, 'send', '{"lead_id": "00000000-0000-0000-0000-000000000000", "subject": "Hi", "text": "Hello", "division": "donna"}');
  if res ->> 'approval' <> 'no_external_effect' then raise exception 'H11 email draft approval kind: %', res; end if;

  -- H12 backup: every new table classified internal, every text column in the export spec
  if (select count(*) from public.backup_classification() where table_name like 'hand\_%' and data_class = 'internal') <> 4 then raise exception 'H12 hand tables not classified internal'; end if;
  if public.backup_export_policy() -> 'unclassified' <> '[]'::jsonb then raise exception 'H12 unclassified tables: %', public.backup_export_policy() -> 'unclassified'; end if;
  if exists (select 1 from public.backup_effective_spec(public.backup_export_policy() -> 'exported') where table_name like 'hand\_%' and not classified) then raise exception 'H12 a hand column is not in the export spec'; end if;
  if not (public.backup_export_policy() -> 'exported' ? 'hand_actions') then raise exception 'H12 hand_actions not exported: %', public.backup_export_policy() -> 'excluded'; end if;

  -- H13 disabling the hand pauses the agent again
  perform public.hands_owner_enable(false);
  if (select status from public.agents where slug = 'jarvis-hands') <> 'paused' then raise exception 'H13 agent still active'; end if;

  update public.system_state set kill_switch = ks0, mode = mode0 where id = 1;
  raise notice 'jarvis_hands_check: all passed';
end $$;
rollback;
