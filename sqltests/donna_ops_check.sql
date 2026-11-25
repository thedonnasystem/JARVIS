-- Donna Ops v1 (migrations/20261207_donna_ops_v1.sql). ONE transaction, rolled back. Fresh apply, repo root.
-- Proves: money controls unchanged (with / without / re-applied) under the append-only audit_log + ledger lock; the rollback archives every table and leaves
-- nothing behind; no API role reaches fz_donna or the donna_* functions; DORMANT: every agent-side function refuses until Donna is active; the mission -> action map
-- needs a GREEN action and refuses the 8 prohibited actions by name (even if the profile lists them as green); CASL floor on outreach drafts (identification,
-- address, unsubscribe, no Re:/Fwd:, no guarantee / payment / signature / fake prior conversation / claiming to be human); a lead draft needs a consent basis,
-- no do-not-contact and no suppression; a prospect needs its https source page and no "no unsolicited" notice; there is no send status; placeholders block
-- approval; owner-only decisions; intake -> receptionist client in DEMO; go-live checklist + sign-off; the weekly report (once per week, dormant = nothing).
begin;
grant usage on schema public to anon, authenticated, service_role;
create function pg_temp.as_id(p_role text, p_sql text) returns text language plpgsql as $$
declare r text; u text := current_setting('app.uid', true);
begin
  perform set_config('app.uid', '', true);
  execute format('set local role %I', p_role);
  begin execute p_sql into r; exception when others then reset role; perform set_config('app.uid', coalesce(u, ''), true); return 'ERR:' || sqlerrm; end;
  reset role;
  perform set_config('app.uid', coalesce(u, ''), true);
  return 'OK:' || coalesce(r, '');
end $$;
create function pg_temp.bot(p_sql text) returns text language plpgsql as $$
declare r text; u text := current_setting('app.uid', true);
begin
  perform set_config('app.uid', '', true);
  begin execute p_sql into r; exception when others then perform set_config('app.uid', coalesce(u, ''), true); return 'ERR:' || sqlerrm; end;
  perform set_config('app.uid', coalesce(u, ''), true);
  return 'OK:' || coalesce(r, '');
end $$;
create function pg_temp.owner(p_sql text) returns text language plpgsql as $$
declare r text;
begin
  begin execute p_sql into r; exception when others then return 'ERR:' || sqlerrm; end;
  return 'OK:' || coalesce(r, '');
end $$;
create function pg_temp.j(p text) returns jsonb language sql as $$ select case when p like 'OK:%' then substr(p, 4)::jsonb end $$;
create function pg_temp.expect(p_tag text, p_got text, p_like text) returns void language plpgsql as $$
begin
  if p_got is null or p_got not like p_like then raise exception '% expected [%] got [%]', p_tag, p_like, p_got; end if;
end $$;
create function pg_temp.draft(p_run uuid, p_kind text, p_channel text, p_lead uuid, p_subject text, p_body text) returns text language sql as $$
  select pg_temp.bot(format($q$select public.donna_save_draft(%L, %L, %L, %L, %L, %L)::text$q$, p_run, p_kind, p_channel, p_lead, p_subject, p_body))
$$;
create function pg_temp.activate() returns void language plpgsql as $$
begin
  perform public.fz_owner_set_office_status('donna', 'active');
  update fz_office_os.fz_office_profiles set manager = coalesce(manager, 'fzd manager'), status = 'active', activated_at = now() where slug = 'donna';
end $$;
create function pg_temp.deactivate() returns void language plpgsql as $$
begin
  perform public.fz_owner_set_office_status('donna', 'dormant');
  update fz_office_os.fz_office_profiles set status = 'dormant' where slug = 'donna';
end $$;

-- the production lock: audit_log and ledger are append-only; this migration and its rollback only INSERT
create or replace function public.fz_append_only_record() returns trigger language plpgsql set search_path to 'pg_catalog' as $$
begin raise exception '% is append-only', tg_relname using errcode = '42501'; end $$;
drop trigger if exists audit_log_append_only on public.audit_log;
create trigger audit_log_append_only before update or delete on public.audit_log for each row execute function public.fz_append_only_record();
drop trigger if exists ledger_append_only on public.ledger;
create trigger ledger_append_only before update or delete on public.ledger for each row execute function public.fz_append_only_record();

\ir include/money_fingerprint.sql
insert into auth.users (id, email) values ('99999999-9999-9999-9999-99999999d0e2', 'fzd-owner@example.invalid') on conflict do nothing;
insert into public.app_owners (email) values ('fzd-owner@example.invalid') on conflict do nothing;
select set_config('app.uid', '99999999-9999-9999-9999-99999999d0e2', true);
insert into public.client_workspaces (slug, name, status) values ('fzd-hvac', 'Spruce Heating Demo', 'active');
create temp table fzd as select (select id from public.client_workspaces where slug = 'fzd-hvac') ws, (select id from public.ventures where slug = 'donna') v;
insert into public.leads (venture_id, name, email, status, consent_basis) values
  ((select v from fzd), 'Spruce Heating Demo', 'office@spruce-heating.example', 'new', 'implied_published'),
  ((select v from fzd), 'Cedar Plumbing Demo', 'info@cedar-plumbing.example', 'new', null),
  ((select v from fzd), 'Oak Dental Demo', 'hello@oak-dental.example', 'new', 'express');
create temp table fzd_l as select (select id from public.leads where email = 'office@spruce-heating.example') ok_lead,
                                  (select id from public.leads where email = 'info@cedar-plumbing.example') no_basis,
                                  (select id from public.leads where email = 'hello@oak-dental.example') supp;
insert into public.contact_suppressions (address, reason, recorded_by) values ('hello@oak-dental.example', 'unsubscribe', 'test') on conflict do nothing;
create temp table fzd_txt as select
  E'Hi {business}, missed calls cost local trades jobs. Donna is an AI receptionist that answers, texts back missed callers and books visits. Want a 10 minute demo?\n--\nDonna, the AI receptionist service of Fendezy Demo Inc.\nMailing address: 100 Example Street, Ottawa ON\nTo stop these emails, reply "unsubscribe".'::text good;

-- D1 money controls unchanged: with == after the rollback (twice) == re-applied; every table archived with its rows; nothing left behind
\set fz_in_txn 1
select pg_temp.activate();
create temp table fzd_run0 as select (public.donna_run_begin('weekly-report') ->> 'run')::uuid id;
select pg_temp.deactivate();
create temp table fzd_fp_with as select * from pg_temp.fz_money_fp();
create temp table fzd_ex0 as select count(*) n from public.audit_log where action = 'donna_ops_export';
\ir ../ops/rollback_donna_ops.sql
\ir ../ops/rollback_donna_ops.sql
do $$
begin
  if to_regnamespace('fz_donna') is not null or exists (select 1 from pg_proc where proname like 'donna\_%' and pronamespace = 'public'::regnamespace) then raise exception 'D1 the rollback left objects behind'; end if;
  if (select count(*) from fz_archive.donna_ops_runs) < 1 or (select count(*) from fz_archive.donna_ops_mission_actions) <> 5 then raise exception 'D1 tables not archived'; end if;
  if (select count(*) from public.audit_log where action = 'donna_ops_export') - (select n from fzd_ex0) <> 1 then raise exception 'D1 export rows'; end if;
  if exists (select * from fzd_fp_with except select * from pg_temp.fz_money_fp()) or exists (select * from pg_temp.fz_money_fp() except select * from fzd_fp_with) then
    raise exception 'D1 money fingerprint changed by the rollback'; end if;
  if (select count(*) from fzd_fp_with) < 300 then raise exception 'D1 fingerprint too small'; end if;
end $$;
\ir ../migrations/20261207_donna_ops_v1.sql
\ir ../migrations/20261207_donna_ops_v1.sql
do $$
begin
  if exists (select * from fzd_fp_with except select * from pg_temp.fz_money_fp()) or exists (select * from pg_temp.fz_money_fp() except select * from fzd_fp_with) then
    raise exception 'D1 money fingerprint changed by the re-apply'; end if;
  if (select count(*) from fz_donna.mission_actions) <> 5 then raise exception 'D1 mission map'; end if;
end $$;

-- D2 no API role reaches fz_donna or the donna_* functions
do $$
declare r text; f regprocedure;
begin
  foreach r in array array['anon', 'authenticated', 'service_role', 'fz_jarvis', 'fz_office_agent', 'fz_auditor'] loop
    continue when not exists (select 1 from pg_roles where rolname = r);
    if has_schema_privilege(r, 'fz_donna', 'usage') then raise exception 'D2 % has usage on fz_donna', r; end if;
  end loop;
  for f in select p.oid::regprocedure from pg_proc p where p.pronamespace = 'public'::regnamespace and p.proname like 'donna\_%' loop
    foreach r in array array['anon', 'authenticated', 'fz_jarvis', 'fz_office_agent', 'fz_auditor', 'backup_reader'] loop
      continue when not exists (select 1 from pg_roles where rolname = r);
      if has_function_privilege(r, f, 'execute') then raise exception 'D2 % can execute %', r, f; end if;
    end loop;
  end loop;
  perform pg_temp.expect('D2 anon', pg_temp.as_id('anon', $q$select public.donna_pipeline()::text$q$), 'ERR:permission denied%');
  perform pg_temp.expect('D2 authenticated', pg_temp.as_id('authenticated', $q$select public.donna_run_begin('market-research')::text$q$), 'ERR:permission denied%');
end $$;

-- D3 DORMANT: nothing runs, nothing is written, no report goes out
do $$
begin
  perform pg_temp.expect('D3 run', pg_temp.bot($q$select public.donna_run_begin('market-research')::text$q$), 'ERR:refused: Donna is dormant%');
  perform pg_temp.expect('D3 draft', pg_temp.draft((select id from fzd_run0), 'weekly_report', null, null, null, 'a weekly report body that is long enough'), 'ERR:refused: Donna is dormant%');
  perform pg_temp.expect('D3 prospect', pg_temp.bot(format($q$select public.donna_add_prospect(%L, 'X Demo', 'a@b.example', null, 'https://x.example/contact', false)::text$q$, (select id from fzd_run0))), 'ERR:refused: Donna is dormant%');
  perform pg_temp.expect('D3 lead label', pg_temp.bot(format($q$select public.donna_lead_label(%L)::text$q$, (select ok_lead from fzd_l))), 'ERR:refused: Donna is dormant%');
  perform pg_temp.expect('D3 report', pg_temp.bot($q$select public.donna_weekly_report()::text$q$), 'OK:{"skipped": "Donna is dormant"}');
  if exists (select 1 from public.owner_messages where from_agent = 'jarvis' and kind = 'brief' and body like 'Donna weekly report%') then raise exception 'D3 a dormant Donna messaged the owner'; end if;
  -- the pipeline is readable (owner view) while dormant
  perform pg_temp.expect('D3 pipeline', pg_temp.bot($q$select public.donna_pipeline()::text$q$), 'OK:%"active": false%');
end $$;

-- D4 green / prohibited: the map needs a green action; prohibited actions are refused by name even when the profile calls them green
do $$
declare r jsonb; v_run uuid; v_prof jsonb := (select autonomy from fz_office_os.fz_office_profiles where slug = 'donna'); a text;
begin
  perform pg_temp.activate();
  r := pg_temp.j(pg_temp.bot($q$select public.donna_run_begin('market-research')::text$q$));
  if r ->> 'action' not in ('market_validation', 'research') then raise exception 'D4 action %', r; end if;
  v_run := (r ->> 'run')::uuid;
  perform pg_temp.expect('D4 unknown mission', pg_temp.bot($q$select public.donna_run_begin('send-campaign')::text$q$), 'ERR:refused: unknown Donna mission%');
  foreach a in array array['sign_contract', 'financial_transfer', 'deceptive_communication', 'fabricate', 'evade_platform_restrictions', 'spend_outside_budget', 'deploy_website', 'modify_own_permissions'] loop
    perform pg_temp.expect('D4 prohibited ' || a, pg_temp.bot(format($q$select public.donna_check_action(%L, %L)::text$q$, v_run, a)), 'OK:{"reason": "prohibited for Donna: ' || a || '", "allowed": false}');
  end loop;
  if (select count(*) from public.audit_log where action = 'donna_prohibited_refused') < 8 then raise exception 'D4 refusals not audited'; end if;
  perform pg_temp.expect('D4 red', pg_temp.bot(format($q$select public.donna_check_action(%L, 'send_email')::text$q$, v_run)), 'OK:%green tier%"allowed": false%');
  perform pg_temp.expect('D4 green', pg_temp.bot(format($q$select public.donna_check_action(%L, 'research')::text$q$, v_run)), 'OK:{"allowed": true}');
  -- even a profile that put every prohibited action in green cannot start a run with one: build_in_sandbox removed + deploy_website added as green
  update fz_office_os.fz_office_profiles set autonomy = jsonb_set(autonomy, '{green}', '["deploy_website", "sign_contract", "financial_transfer"]') where slug = 'donna';
  perform pg_temp.expect('D4 no green action', pg_temp.bot($q$select public.donna_run_begin('delivery-onboarding')::text$q$), 'ERR:refused: delivery-onboarding needs one of%');
  perform pg_temp.expect('D4 prohibited stays prohibited', pg_temp.bot(format($q$select public.donna_check_action(%L, 'deploy_website')::text$q$, v_run)), 'OK:%prohibited for Donna%');
  update fz_office_os.fz_office_profiles set autonomy = v_prof where slug = 'donna';
  -- a write the mission does not own is refused; no 'sent' status exists at all
  perform pg_temp.expect('D4 wrong kind', pg_temp.draft(v_run, 'cold_email', 'email', null, 'Hello', (select good from fzd_txt)), 'ERR:refused: market-research does not write cold_email%');
  if exists (select 1 from pg_constraint where conrelid = 'fz_donna.drafts'::regclass and pg_get_constraintdef(oid) like '%sent%') then raise exception 'D4 drafts can be sent'; end if;
  perform pg_temp.bot(format($q$select public.donna_run_finish(%L, 'done', 'ok', '{}'::jsonb)::text$q$, v_run));
  perform pg_temp.expect('D4 finished run', pg_temp.bot(format($q$select public.donna_check_action(%L, 'research')::text$q$, v_run)), 'ERR:refused: no running Donna run%');
  perform pg_temp.expect('D4 llm cents', pg_temp.bot(format($q$update fz_donna.runs set llm_cents = 5 where id = %L returning id::text$q$, v_run)), 'ERR:%runs_llm_cents_check%');
end $$;

-- D5 CASL floor on outreach drafts + consent / suppression / do-not-contact for a lead
do $$
declare v_run uuid := (pg_temp.j(pg_temp.bot($q$select public.donna_run_begin('outreach-prep')::text$q$)) ->> 'run')::uuid; g text := (select good from fzd_txt); r jsonb;
begin
  perform pg_temp.expect('D5 template ok', pg_temp.draft(v_run, 'cold_email', 'email', null, 'Missed calls at {business}', g), 'OK:%"status": "draft"%');
  perform pg_temp.expect('D5 no id', pg_temp.draft(v_run, 'cold_email', 'email', null, 'Hi', replace(g, 'Donna', 'We')), 'ERR:refused (CASL / honesty): %sender identification%');
  perform pg_temp.expect('D5 no address', pg_temp.draft(v_run, 'cold_email', 'email', null, 'Hi', replace(g, 'Mailing address: 100 Example Street, Ottawa ON', 'Ottawa')), 'ERR:refused (CASL / honesty): %mailing address is missing%');
  perform pg_temp.expect('D5 no unsubscribe', pg_temp.draft(v_run, 'cold_email', 'email', null, 'Hi', replace(g, 'To stop these emails, reply "unsubscribe".', '')), 'ERR:refused (CASL / honesty): %unsubscribe line is missing%');
  perform pg_temp.expect('D5 Re:', pg_temp.draft(v_run, 'cold_email', 'email', null, 'Re: your calls', g), 'ERR:refused (CASL / honesty): %deceptive_communication%');
  perform pg_temp.expect('D5 guarantee', pg_temp.draft(v_run, 'cold_email', 'email', null, 'Hi', g || ' Results guaranteed.'), 'ERR:refused (CASL / honesty): %guarantee or refund%');
  perform pg_temp.expect('D5 payment', pg_temp.draft(v_run, 'cold_email', 'email', null, 'Hi', g || ' Send an e-transfer to start.'), 'ERR:refused (CASL / honesty): %financial_transfer%');
  perform pg_temp.expect('D5 sign', pg_temp.draft(v_run, 'cold_email', 'email', null, 'Hi', g || ' Please sign the agreement attached.'), 'ERR:refused (CASL / honesty): %sign_contract%');
  perform pg_temp.expect('D5 prior talk', pg_temp.draft(v_run, 'cold_email', 'email', null, 'Hi', 'As we discussed, ' || g), 'ERR:refused (CASL / honesty): %earlier conversation%');
  perform pg_temp.expect('D5 human', pg_temp.draft(v_run, 'dm', 'dm', null, null, 'I''m a real person. ' || g), 'ERR:refused (CASL / honesty): %claim to be human%');
  perform pg_temp.expect('D5 call script', pg_temp.draft(v_run, 'call_script', 'call', null, null, 'Hi, this is Donna calling about missed calls. Any interest in a demo?'), 'ERR:refused (CASL / honesty): %do-not-call%');
  perform pg_temp.expect('D5 call ok', pg_temp.draft(v_run, 'call_script', 'call', null, null, 'Hi, this is Sam calling for Donna, an AI receptionist service. If you''d rather not hear from us I''ll add your number to our do-not-call list.'), 'OK:%draft%');
  -- per lead
  perform pg_temp.expect('D5 no basis', pg_temp.draft(v_run, 'cold_email', 'email', (select no_basis from fzd_l), 'Hi', g), 'ERR:refused: no consent basis%');
  perform pg_temp.expect('D5 suppressed', pg_temp.draft(v_run, 'cold_email', 'email', (select supp from fzd_l), 'Hi', g), 'ERR:refused: the address or number is on the suppression list%');
  update public.leads set do_not_contact = true where id = (select no_basis from fzd_l);
  perform pg_temp.expect('D5 dnc', pg_temp.draft(v_run, 'cold_email', 'email', (select no_basis from fzd_l), 'Hi', g), 'ERR:refused: the lead is do-not-contact%');
  r := pg_temp.j(pg_temp.draft(v_run, 'cold_email', 'email', (select ok_lead from fzd_l), 'Missed calls at Spruce', replace(g, '{business}', 'Spruce Heating Demo')));
  if r is null or (select status from public.leads where id = (select ok_lead from fzd_l)) <> 'drafted' then raise exception 'D5 lead draft %', r; end if;
  perform pg_temp.draft(v_run, 'cold_email', 'email', (select ok_lead from fzd_l), 'Missed calls at Spruce', replace(g, '{business}', 'Spruce Heating'));
  if (select status from fz_donna.drafts where id = (r ->> 'draft')::uuid) <> 'superseded' then raise exception 'D5 an older lead draft was not superseded'; end if;
  perform pg_temp.expect('D5 lead label', pg_temp.bot(format($q$select public.donna_lead_label(%L)::text$q$, (select ok_lead from fzd_l))), 'OK:%"business": "Spruce Heating Demo"%');
  perform pg_temp.expect('D5 not a donna lead', pg_temp.bot(format($q$select public.donna_lead_label(%L)::text$q$, gen_random_uuid())), 'ERR:refused: not a Donna lead%');
  perform pg_temp.bot(format($q$select public.donna_run_finish(%L, 'done', 'ok', '{}'::jsonb)::text$q$, v_run));
end $$;

-- D6 prospects: published https source, no "no unsolicited" notice, not suppressed, deduplicated; only market-research
do $$
declare v_run uuid := (pg_temp.j(pg_temp.bot($q$select public.donna_run_begin('market-research')::text$q$)) ->> 'run')::uuid; r jsonb;
begin
  perform pg_temp.expect('D6 no url', pg_temp.bot(format($q$select public.donna_add_prospect(%L, 'Birch Roofing Demo', 'jobs@birch.example', null, 'http://birch.example', false)::text$q$, v_run)), 'ERR:refused: a prospect needs the https page%');
  perform pg_temp.expect('D6 notice', pg_temp.bot(format($q$select public.donna_add_prospect(%L, 'Birch Roofing Demo', 'jobs@birch.example', null, 'https://birch.example/contact', true)::text$q$, v_run)), 'ERR:refused: the page says no unsolicited%');
  perform pg_temp.expect('D6 unchecked', pg_temp.bot(format($q$select public.donna_add_prospect(%L, 'Birch Roofing Demo', 'jobs@birch.example', null, 'https://birch.example/contact', null)::text$q$, v_run)), 'ERR:refused: the page says no unsolicited%');
  perform pg_temp.expect('D6 suppressed', pg_temp.bot(format($q$select public.donna_add_prospect(%L, 'Oak Dental Demo', 'hello@oak-dental.example', null, 'https://oak.example/contact', false)::text$q$, v_run)), 'ERR:refused: the address or number is on the suppression list%');
  r := pg_temp.j(pg_temp.bot(format($q$select public.donna_add_prospect(%L, 'Birch Roofing Demo', 'Jobs@Birch.example', null, 'https://birch.example/contact', false)::text$q$, v_run)));
  if r is null or (r ->> 'duplicate')::boolean then raise exception 'D6 add %', r; end if;
  if (select consent_basis || '|' || source || '|' || status from public.leads where id = (r ->> 'lead')::uuid) <> 'implied_published|donna:research|new' then raise exception 'D6 lead row'; end if;
  if (select notes from public.leads where id = (r ->> 'lead')::uuid) not like 'published at https://birch.example/contact (seen %' then raise exception 'D6 evidence note'; end if;
  perform pg_temp.expect('D6 duplicate', pg_temp.bot(format($q$select public.donna_add_prospect(%L, 'Birch Roofing', 'jobs@birch.example', null, 'https://birch.example/contact', false)::text$q$, v_run)), 'OK:%"duplicate": true%');
  perform pg_temp.bot(format($q$select public.donna_run_finish(%L, 'done', 'ok', '{}'::jsonb)::text$q$, v_run));
  v_run := (pg_temp.j(pg_temp.bot($q$select public.donna_run_begin('outreach-prep')::text$q$)) ->> 'run')::uuid;
  perform pg_temp.expect('D6 other mission', pg_temp.bot(format($q$select public.donna_add_prospect(%L, 'Elm Demo', 'a@elm.example', null, 'https://elm.example', false)::text$q$, v_run)), 'ERR:refused: prospects come from a running market-research%');
  perform pg_temp.bot(format($q$select public.donna_run_finish(%L, 'failed', 'x', null)::text$q$, v_run));
end $$;

-- D7 owner decisions: placeholders block approval; owner only; approval is copy, never a send
do $$
declare d uuid; d2 uuid; v_run uuid := (pg_temp.j(pg_temp.bot($q$select public.donna_run_begin('outreach-prep')::text$q$)) ->> 'run')::uuid;
begin
  d := (pg_temp.j(pg_temp.draft(v_run, 'cold_email', 'email', null, 'Missed calls', replace((select good from fzd_txt), 'Fendezy Demo Inc.', '[OWNER: legal entity name]'))) ->> 'draft')::uuid;
  d2 := (pg_temp.j(pg_temp.draft(v_run, 'dm', 'dm', null, null, (select good from fzd_txt))) ->> 'draft')::uuid;
  perform pg_temp.expect('D7 bot', pg_temp.bot(format($q$select public.donna_owner_decide_draft(%L, true)::text$q$, d2)), 'ERR:owner approval required%');
  perform pg_temp.expect('D7 edit bot', pg_temp.bot(format($q$select public.donna_owner_edit_draft(%L, 'x', 'y')::text$q$, d)), 'ERR:owner approval required%');
  perform pg_temp.expect('D7 edit drops unsubscribe', pg_temp.owner(format($q$select public.donna_owner_edit_draft(%L, 'Missed calls', %L)::text$q$, d,
    replace((select body from fz_donna.drafts where id = d), 'To stop these emails, reply "unsubscribe".', ''))), 'ERR:refused (CASL / honesty): an unsubscribe line is missing%');
  perform pg_temp.expect('D7 placeholder', pg_temp.owner(format($q$select public.donna_owner_decide_draft(%L, true)::text$q$, d)), 'ERR:refused: replace every [OWNER%');
  perform pg_temp.expect('D7 approve', pg_temp.owner(format($q$select public.donna_owner_decide_draft(%L, true)::text$q$, d2)), 'OK:%nothing is sent%owner_approved%');
  perform pg_temp.expect('D7 twice', pg_temp.owner(format($q$select public.donna_owner_decide_draft(%L, false)::text$q$, d2)), 'ERR:refused: no open draft%');
  perform pg_temp.expect('D7 reject', pg_temp.owner(format($q$select public.donna_owner_decide_draft(%L, false, 'no')::text$q$, d)), 'OK:%owner_rejected%');
  if exists (select 1 from public.outbox where body like '%AI receptionist that answers%') then raise exception 'D7 a draft reached the outbox'; end if;
  perform pg_temp.bot(format($q$select public.donna_run_finish(%L, 'done', 'ok', '{}'::jsonb)::text$q$, v_run));
end $$;

-- D8 intake -> receptionist client in DEMO (owner), site.json stays a draft; go-live checklist and sign-off
do $$
declare v_run uuid := (pg_temp.j(pg_temp.bot($q$select public.donna_run_begin('delivery-onboarding')::text$q$)) ->> 'run')::uuid; i uuid; c jsonb;
        cfg jsonb := jsonb_build_object('business_name', 'Spruce Heating Demo', 'timezone', 'America/Toronto', 'hours', '{"mon": [["09:00", "17:00"]]}'::jsonb, 'services', '[]'::jsonb,
                                        'faqs', '[]'::jsonb, 'escalation_number', '+15555550100', 'booking', '{"provider": "none"}'::jsonb, 'voice', '{"tts": "kokoro"}'::jsonb);
begin
  perform pg_temp.expect('D8 office', pg_temp.bot(format($q$select public.donna_save_intake(%L, 'Spruce Heating Demo', null, %L, '{"office": "other"}')::text$q$, v_run, cfg)), 'ERR:refused: a client site draft names office donna%');
  i := (pg_temp.j(pg_temp.bot(format($q$select public.donna_save_intake(%L, 'Spruce Heating Demo', %L, %L, '{"office": "donna", "slug": "spruce-heating-demo"}')::text$q$, v_run, (select ok_lead from fzd_l), cfg))) ->> 'intake')::uuid;
  if i is null then raise exception 'D8 intake not saved'; end if;
  perform pg_temp.expect('D8 apply before approval', pg_temp.owner(format($q$select public.donna_owner_apply_intake(%L, 'spruce', %L)::text$q$, i, (select ws from fzd))), 'ERR:refused: approve the intake first%');
  perform pg_temp.expect('D8 bot decide', pg_temp.bot(format($q$select public.donna_owner_decide_intake(%L, true)::text$q$, i)), 'ERR:owner approval required%');
  perform public.donna_owner_decide_intake(i, true);
  perform pg_temp.expect('D8 apply', pg_temp.owner(format($q$select public.donna_owner_apply_intake(%L, 'spruce', %L)::text$q$, i, (select ws from fzd))), 'OK:%"status": "demo"%');
  if (select status from fz_reception.clients where slug = 'spruce') <> 'demo' then raise exception 'D8 not demo'; end if;
  c := pg_temp.j(pg_temp.bot($q$select public.donna_golive_checklist('spruce')::text$q$));
  if (c ->> 'ready')::boolean then raise exception 'D8 ready without sign-off %', c; end if;
  perform pg_temp.expect('D8 signoff bot', pg_temp.bot($q$select public.donna_owner_golive_approve('spruce', true, true, true)::text$q$), 'ERR:owner approval required%');
  perform pg_temp.expect('D8 signoff partial', pg_temp.owner($q$select public.donna_owner_golive_approve('spruce', true, false, true)::text$q$), 'ERR:refused: sign off only after%');
  perform public.donna_owner_golive_approve('spruce', true, true, true);
  perform public.reception_owner_set_client('spruce', (select ws from fzd), cfg, '+15555550188');
  c := pg_temp.j(pg_temp.bot($q$select public.donna_golive_checklist('spruce')::text$q$));
  if not (c ->> 'ready')::boolean or c ->> 'status' <> 'demo' then raise exception 'D8 ready %', c; end if;
  if not (pg_temp.j(pg_temp.bot($q$select public.donna_pipeline()::text$q$)) -> 'next_actions')::text like '%client spruce%' then raise exception 'D8 next action for the demo client'; end if;
  perform pg_temp.bot(format($q$select public.donna_run_finish(%L, 'done', 'ok', '{}'::jsonb)::text$q$, v_run));
end $$;

-- D9 weekly report: once per ISO week, to the owner's own channel, gaps flagged; the pipeline lists the next actions
do $$
declare r jsonb; p jsonb;
begin
  r := pg_temp.j(pg_temp.bot($q$select public.donna_weekly_report()::text$q$));
  if r ->> 'message' is null then raise exception 'D9 report %', r; end if;
  if (select body from public.owner_messages where id = (r ->> 'message')::uuid) not like 'Donna weekly report %Gaps: %MRR: no approved billing plan yet%' then
    raise exception 'D9 body %', (select body from public.owner_messages where id = (r ->> 'message')::uuid); end if;
  perform pg_temp.expect('D9 once a week', pg_temp.bot($q$select public.donna_weekly_report()::text$q$), 'OK:%already sent for%');
  if (select count(*) from public.owner_messages where from_agent = 'jarvis' and kind = 'brief' and body like 'Donna weekly report%') <> 1 then raise exception 'D9 more than one report'; end if;
  p := pg_temp.j(pg_temp.bot($q$select public.donna_pipeline()::text$q$));
  if (p -> 'funnel' -> 'counts' ->> 'drafted')::int < 1 or jsonb_array_length(p -> 'next_actions') < 1 then raise exception 'D9 pipeline %', p; end if;
  perform pg_temp.expect('D9 scoped', pg_temp.as_id('authenticated', $q$select public.donna_weekly_report()::text$q$), 'ERR:permission denied%');
end $$;
select 'donna_ops_check ok';
rollback;
