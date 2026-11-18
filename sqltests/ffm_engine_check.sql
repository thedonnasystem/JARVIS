-- FF Marketing engine v1 (migrations/20261125_ffm_engine_v1.sql). Everything in one transaction, rolled back. Run on a fresh apply (scripts/replica/run.sh does).
-- Proves: the bot (service_role) can draft a workspace, a brief and a pack only through the functions; budget/approval/activation stay owner-only;
-- every stored string is screened; packs are drafts with dry_run true; anon/authenticated get nothing.
begin;
grant usage on schema public to anon, authenticated, service_role;
create function pg_temp.svc(p_sql text) returns text language plpgsql as $$
declare r text;
begin
  set local role service_role;
  begin execute p_sql into r; exception when others then reset role; return 'ERR:' || sqlerrm; end;
  reset role;
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
do $$
declare res text; w uuid; c uuid; j jsonb; ok_pack jsonb := '{"schema": "ffm.pack.v1", "positioning": {"statement": "Warm homes before the first cold snap"},
  "ad_variants": [{"id": "V1", "headline": "Furnace check", "primary_text": "Book a tune-up"}], "follow_up": [{"day": 0, "body": "Reply STOP to opt out"}], "status": "draft", "dry_run": true}';
begin
  -- E1 the bot drafts a workspace: draft status, NO budget, onboarding checklist instantiated
  res := pg_temp.svc($q$select public.ffm_engine_create_workspace('eng-check', 'Engine Check Mortgages', 'mortgage', 'owner:telegram')$q$);
  if res not like 'OK:%' then raise exception 'E1 create refused: %', res; end if;
  w := substr(res, 4)::uuid;
  if (select status from public.client_workspaces where id = w) <> 'draft' or (select monthly_budget_cents from public.client_workspaces where id = w) is not null then raise exception 'E1 not a draft without budget'; end if;
  if (select count(*) from public.ffm_onboarding_items where workspace_id = w) < 9 then raise exception 'E1 onboarding not instantiated'; end if;
  if pg_temp.svc($q$select public.ffm_engine_create_workspace('eng-check', 'Again', 'generic', 'owner:telegram')$q$) not like 'ERR:%slug already exists%' then raise exception 'E1 duplicate slug accepted'; end if;
  if pg_temp.svc($q$select public.ffm_engine_create_workspace('eng-check2', 'Bad', 'crypto', 'owner:telegram')$q$) not like 'ERR:%unknown vertical%' then raise exception 'E1 bad vertical accepted'; end if;

  -- E2 budget, approval and activation stay owner-only for the bot
  if pg_temp.svc(format($q$select public.ffm_set_budget(%L, 100000)$q$, w)) not like 'ERR:%owner approval required%' then raise exception 'E2 bot set a budget'; end if;
  if pg_temp.svc(format($q$select public.ffm_activate(%L)$q$, w)) not like 'ERR:%activation refused%' then raise exception 'E2 bot activated'; end if;

  -- E3 brief: allow-listed keys only, screened
  res := pg_temp.svc(format($q$select public.ffm_engine_save_brief(%L, '{"offer": "Free renewal review call", "service_area": "Ottawa", "goal": "booked calls"}', 'owner:telegram')$q$, w));
  if res not like 'OK:%' then raise exception 'E3 brief refused: %', res; end if;
  if pg_temp.svc(format($q$select public.ffm_engine_save_brief(%L, '{"business_name": "anything"}', 'owner:telegram')$q$, w)) not like 'ERR:%unknown brief field%' then raise exception 'E3 free-form key accepted'; end if;
  if pg_temp.svc(format($q$select public.ffm_engine_save_brief(%L, '{"offer": "send us your credit report and bank statement"}', 'owner:telegram')$q$, w)) not like 'ERR:%Sensitive data refused%' then raise exception 'E3 sensitive brief accepted'; end if;

  -- E4 screen pre-check: reports indexes and reason codes, never the text
  j := (substr(pg_temp.svc(format($q$select public.ffm_engine_screen_texts(%L, array['Book a tune-up', 'my SIN is 046 454 286', 'Furnace check'])::text$q$, w)), 4))::jsonb;
  if jsonb_array_length(j) <> 1 or (j -> 0 ->> 'i')::int <> 1 or j::text like '%046%' then raise exception 'E4 screen pre-check wrong: %', j; end if;

  -- E5 pack: stored as a draft (dry_run), versioned, every string leaf screened; a sensitive leaf anywhere refuses the whole pack
  c := public.ffm_add_campaign(w, 'Engine check campaign', 'meta');
  res := pg_temp.svc(format($q$select public.ffm_engine_save_pack(%L, 'mortgage', %L, %L, 3, 'claude-haiku-5-5', 'ffm-engine')::text$q$, w, ok_pack, c));
  if res not like 'OK:%' or (substr(res, 4)::jsonb ->> 'version')::int <> 1 then raise exception 'E5 pack refused: %', res; end if;
  res := pg_temp.svc(format($q$select public.ffm_engine_save_pack(%L, 'mortgage', %L, null, 3, 'claude-haiku-5-5', 'ffm-engine')::text$q$, w, ok_pack));
  if (substr(res, 4)::jsonb ->> 'version')::int <> 2 then raise exception 'E5 no new version: %', res; end if;
  if (select count(*) from public.ffm_engine_packs where workspace_id = w and status = 'draft') <> 1 or (select count(*) from public.ffm_engine_packs where workspace_id = w and status = 'superseded') <> 1 then raise exception 'E5 supersede wrong'; end if;
  if exists (select 1 from public.ffm_engine_packs where not dry_run) then raise exception 'E5 a pack is not dry run'; end if;
  if pg_temp.svc(format($q$select public.ffm_engine_save_pack(%L, 'mortgage', %L, null, 0, null, 'ffm-engine')$q$, w, jsonb_set(ok_pack, '{follow_up,0,body}', '"upload your void cheque and paystub"'))) not like 'ERR:%Sensitive data refused%' then raise exception 'E5 sensitive leaf accepted'; end if;
  -- free text cannot hide in a structural (non free-text) field, and structural codes still get the strict screen
  if pg_temp.svc(format($q$select public.ffm_engine_save_pack(%L, 'mortgage', %L, null, 0, null, 'ffm-engine')$q$, w, ok_pack || '{"schema": "send your bank statement please"}')) not like 'ERR:%must be a short code%' then raise exception 'E5 free text in a code field accepted'; end if;
  if pg_temp.svc(format($q$select public.ffm_engine_save_pack(%L, 'mortgage', %L, null, 0, null, 'ffm-engine')$q$, w, ok_pack || '{"ref": "046454286"}')) not like 'ERR:%Sensitive data refused%' then raise exception 'E5 SIN-like code accepted'; end if;
  -- an insurance-context workspace (every vertical but mortgage) keeps the classifier's vocabulary allow-list
  res := pg_temp.svc($q$select public.ffm_engine_create_workspace('eng-check-hs', 'Engine Check Heating', 'home_services', 'owner:telegram')$q$);
  if res not like 'OK:%' then raise exception 'E5 home services create refused: %', res; end if;
  if pg_temp.svc(format($q$select public.ffm_engine_save_brief(%L, '{"offer": "Free furnace inspection"}', 'owner:telegram')$q$, substr(res, 4)::uuid)) not like 'ERR:%unknown_word%' then raise exception 'E5 vocabulary not enforced'; end if;
  begin
    update public.ffm_engine_packs set dry_run = false where workspace_id = w;
    raise exception 'E5 dry_run can be switched off';
  exception when check_violation then null;
  end;

  -- E6 the bot cannot write the tables directly; anon / authenticated cannot read or call anything
  if pg_temp.svc(format($q$insert into public.ffm_engine_packs (workspace_id, version, vertical, pack, created_by) values (%L, 9, 'generic', '{}', 'x')$q$, w)) not like 'ERR:%permission denied%' then raise exception 'E6 direct insert allowed'; end if;
  if pg_temp.svc($q$select count(*)::text from public.ffm_engine_packs$q$) not like 'OK:%' then raise exception 'E6 bot cannot read packs'; end if;
  foreach res in array array['anon', 'authenticated'] loop
    if pg_temp.as_role(res, $q$select count(*)::text from public.ffm_engine_packs$q$) not like 'ERR:%permission denied%' then raise exception 'E6 % reads packs', res; end if;
    if pg_temp.as_role(res, $q$select public.ffm_engine_create_workspace('x-anon', 'X Anon', 'generic', 'x')$q$) not like 'ERR:%permission denied%' then raise exception 'E6 % creates workspaces', res; end if;
  end loop;

  -- E7 backups: the engine tables are client workspace tables, never exported
  if public.backup_export_policy() -> 'exported' ? 'ffm_engine_packs' or public.backup_export_policy() -> 'exported' ? 'ffm_engine_briefs' then raise exception 'E7 engine tables exported'; end if;
  if public.backup_export_policy() -> 'unclassified' <> '[]'::jsonb then raise exception 'E7 unclassified: %', public.backup_export_policy() -> 'unclassified'; end if;
  raise notice 'ffm_engine_check: all passed';
end $$;
rollback;
