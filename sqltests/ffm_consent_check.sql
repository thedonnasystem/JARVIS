-- SQL-level checks for migrations/20261119_ffm_consent_v1.sql. SCRATCH replica only. One transaction, rolled back.
-- Section C: consent log (grants, default-deny, withdrawal wins, implied window, immutability, erasure, routing gate, no sending).
-- Section H: the 'health' detector category: what is flagged, the ACCEPTED FALSE POSITIVES, and the KNOWN MISSES (asserted, so a change is noticed).
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
  if p then perform set_config('app.uid', '99999999-9999-9999-9999-999999999992', true);
  else perform set_config('app.uid', '', true); end if;
end $$;
do $$
declare a uuid; b uuid; ca uuid; la uuid; lb uuid; lc uuid; ld uuid; le uuid; t text; r text; f text; s text; j jsonb; n int; cid uuid; before_n int;
begin
  insert into auth.users (id, email) values ('99999999-9999-9999-9999-999999999992', 'consent-owner@example.com');
  insert into public.app_owners (email) values ('consent-owner@example.com');
  perform pg_temp.as_owner(false);

  -- C1-C6 grants
  foreach t in array array['ffm_consent_log', 'ffm_consent_settings'] loop
    if not (select relrowsecurity from pg_class where oid = ('public.' || t)::regclass) then raise exception 'C1 RLS off on %', t; end if;
    if exists (select 1 from pg_policy where polrelid = ('public.' || t)::regclass) then raise exception 'C2 policy on %', t; end if;
    foreach r in array array['anon', 'authenticated'] loop
      if has_table_privilege(r, 'public.' || t, 'select') or has_table_privilege(r, 'public.' || t, 'insert') then raise exception 'C3 % has access to %', r, t; end if;
    end loop;
    foreach r in array array['insert', 'update', 'delete', 'truncate', 'trigger', 'references'] loop
      if has_table_privilege('service_role', 'public.' || t, r) then raise exception 'C4 service_role can % %', r, t; end if;
    end loop;
    if not has_table_privilege('service_role', 'public.' || t, 'select') then raise exception 'C4b service_role cannot read %', t; end if;
  end loop;
  foreach f in array array['public.ffm_consent_immutable()', 'public.ffm_set_implied_window(uuid,integer)', 'public.ffm_record_consent(uuid,uuid,text,text,text,text,timestamptz,text,text)',
                           'public.ffm_withdraw_consent(uuid,uuid,text,text,text,text)', 'public.ffm_contact_status(uuid,text)', 'public.ffm_can_contact(uuid,text)',
                           'public.ffm_erase_lead(uuid,uuid,text)', 'public.ffm_route_preview(uuid,uuid)'] loop
    foreach r in array array['anon', 'authenticated'] loop
      if has_function_privilege(r, f, 'execute') then raise exception 'C5 % can execute %', r, f; end if;
    end loop;
    if not has_function_privilege('service_role', f, 'execute') then raise exception 'C6 service_role cannot execute %', f; end if;
  end loop;

  -- two clients, leads
  insert into public.client_workspaces (slug, name, vertical) values ('c-mortgage', 'Consent Test Mortgage', 'mortgage') returning id into a;
  insert into public.client_workspaces (slug, name, vertical) values ('c-insurance', 'Consent Test Insurance', 'insurance') returning id into b;
  insert into public.ws_campaigns (workspace_id, name) values (a, 'camp a') returning id into ca;
  la := public.ws_add_lead(a, ca, 'Lead Alpha', 'alpha@example.com', '613-555-0101', 'web form');
  lb := public.ws_add_lead(a, ca, 'Lead Bravo', 'bravo@example.com', '613-555-0102', 'web form');
  lc := public.ws_add_lead(a, ca, 'Lead Charlie', 'charlie@example.com', '613-555-0103', 'web form');
  ld := public.ws_add_lead(a, ca, 'Lead Delta', 'delta@example.com', '613-555-0104', 'web form');
  le := public.ws_add_lead(b, null, 'Lead Echo', 'echo@example.com', null, 'web form');

  -- C7 DEFAULT DENY: no consent, unknown lead, bad channel, nulls
  foreach t in array array['email', 'sms', 'phone', 'mail'] loop
    if public.ffm_can_contact(la, t) then raise exception 'C7 default is not deny for %', t; end if;
  end loop;
  if public.ffm_can_contact(gen_random_uuid(), 'email') then raise exception 'C8 unknown lead allowed'; end if;
  if public.ffm_can_contact(la, 'fax') or public.ffm_can_contact(la, null) or public.ffm_can_contact(null, 'email') or public.ffm_can_contact(la, 'all') then raise exception 'C9 bad input allowed'; end if;
  if public.ffm_contact_status(la, 'email') ->> 'reason' <> 'no_consent' then raise exception 'C10 reason'; end if;

  -- C11 express consent (bot may record it, with evidence), per channel only
  cid := public.ffm_record_consent(a, la, 'email', 'express', 'form-v3', 'web form', now() - interval '1 hour', 'form-submission-1001', 'bot');
  if not public.ffm_can_contact(la, 'email') then raise exception 'C11 express consent not honoured'; end if;
  if public.ffm_can_contact(la, 'sms') or public.ffm_can_contact(la, 'phone') then raise exception 'C12 consent leaked across channels'; end if;
  if public.ffm_can_contact(lb, 'email') then raise exception 'C13 consent leaked across leads'; end if;
  if (select count(*) from public.audit_log where action = 'ffm_consent_recorded' and (detail ->> 'consent')::uuid = cid) <> 1 then raise exception 'C14 not audited'; end if;
  if (select detail::text from public.audit_log where action = 'ffm_consent_recorded' and (detail ->> 'consent')::uuid = cid) like '%form-submission%' then raise exception 'C14b evidence text copied into audit_log'; end if;

  -- C15 refusals while recording
  perform pg_temp.expect_fail(format($q$select public.ffm_record_consent(%L,%L,'email','express','v1','web',now(),'',  'bot')$q$, a, lb), 'consent refused: an evidence reference%');
  perform pg_temp.expect_fail(format($q$select public.ffm_record_consent(%L,%L,'email','express',' ','web',now(),'form-1','bot')$q$, a, lb), 'consent refused: the wording version%');
  perform pg_temp.expect_fail(format($q$select public.ffm_record_consent(%L,%L,'email','express','v1','web',now() + interval '1 day','form-1','bot')$q$, a, lb), 'consent refused: captured_at%');
  perform pg_temp.expect_fail(format($q$select public.ffm_record_consent(%L,%L,'email','express','v1','web',null,'form-1','bot')$q$, a, lb), 'consent refused: captured_at%');
  perform pg_temp.expect_fail(format($q$select public.ffm_record_consent(%L,%L,'fax','express','v1','web',now(),'form-1','bot')$q$, a, lb), 'consent refused: channel%');
  perform pg_temp.expect_fail(format($q$select public.ffm_record_consent(%L,%L,'all','express','v1','web',now(),'form-1','bot')$q$, a, lb), 'consent refused: channel%');
  perform pg_temp.expect_fail(format($q$select public.ffm_record_consent(%L,%L,'email','withdrawn','v1','web',now(),'form-1','bot')$q$, a, lb), 'consent refused: basis%');
  perform pg_temp.expect_fail(format($q$select public.ffm_record_consent(%L,%L,'email','express','v1','web',now(),'form-1','bot')$q$, b, lb), 'lead not found in this workspace%');   -- another workspace's id
  perform pg_temp.expect_fail(format($q$select public.ffm_record_consent(%L,%L,'email','express','v1','web',now(),'form-1','bot')$q$, a, gen_random_uuid()), 'lead not found in this workspace%');
  -- C16 evidence / source go through the sensitive-data guard (including the new health category)
  perform pg_temp.expect_fail(format($q$select public.ffm_record_consent(%L,%L,'email','express','v1','web',now(),'bank statement attached','bot')$q$, a, lb), 'Sensitive data refused%');
  perform pg_temp.expect_fail(format($q$select public.ffm_record_consent(%L,%L,'email','express','v1','health questionnaire',now(),'form-2','bot')$q$, a, lb), 'Sensitive data refused%');
  perform pg_temp.expect_fail(format($q$select public.ffm_record_consent(%L,%L,'email','express','v1','web',now(),'diabetes form 2','bot')$q$, a, lb), 'Sensitive data refused%');
  if (select count(*) from public.ffm_consent_log where lead_id = lb) <> 0 then raise exception 'C17 a refused record left a row'; end if;

  -- C18 IMPLIED consent: owner-only, and useless until the OWNER sets a window
  perform pg_temp.expect_fail(format($q$select public.ffm_record_consent(%L,%L,'email','implied','v1','inquiry',now(),'inquiry-77','bot')$q$, a, lb), 'owner approval required%');
  perform pg_temp.expect_fail(format($q$select public.ffm_set_implied_window(%L, 30)$q$, a), 'owner approval required%');
  perform pg_temp.as_owner(true);
  perform public.ffm_record_consent(a, lb, 'email', 'implied', 'v1', 'inquiry', now() - interval '10 days', 'inquiry-77', 'owner');
  perform pg_temp.as_owner(false);
  if public.ffm_can_contact(lb, 'email') then raise exception 'C19 implied consent accepted with no owner-set window'; end if;
  if public.ffm_contact_status(lb, 'email') ->> 'reason' <> 'implied_not_accepted' then raise exception 'C20 reason'; end if;
  if (select count(*) from public.ffm_consent_settings where workspace_id = a) <> 0 then raise exception 'C21 a window exists without the owner setting it'; end if;
  perform pg_temp.as_owner(true);
  perform public.ffm_set_implied_window(a, 30);
  perform public.ffm_record_consent(a, lc, 'email', 'implied', 'v1', 'inquiry', now() - interval '40 days', 'inquiry-78', 'owner');
  perform pg_temp.as_owner(false);
  if not public.ffm_can_contact(lb, 'email') then raise exception 'C22 implied consent inside the window refused'; end if;
  if public.ffm_can_contact(lc, 'email') then raise exception 'C23 expired implied consent accepted'; end if;
  if public.ffm_contact_status(lc, 'email') ->> 'reason' <> 'implied_expired' then raise exception 'C24 reason'; end if;
  if public.ffm_can_contact(le, 'email') then raise exception 'C25 window of workspace A applied to workspace B'; end if;
  perform pg_temp.as_owner(true);
  perform public.ffm_set_implied_window(a, null);
  perform pg_temp.as_owner(false);
  if public.ffm_can_contact(lb, 'email') then raise exception 'C26 clearing the window did not remove implied consent'; end if;
  perform pg_temp.as_owner(true);
  perform pg_temp.expect_fail(format($q$select public.ffm_set_implied_window(%L, 0)$q$, a), '%check%');   -- sanity bound
  perform pg_temp.as_owner(false);

  -- C27 WITHDRAWAL ALWAYS WINS, is a new row, and is final
  n := (select count(*) from public.ffm_consent_log where lead_id = la);
  perform public.ffm_withdraw_consent(a, la, 'email', 'reply STOP', 'msg-5', 'bot');
  if public.ffm_can_contact(la, 'email') then raise exception 'C28 withdrawn but allowed'; end if;
  if (select count(*) from public.ffm_consent_log where lead_id = la) <> n + 1 then raise exception 'C29 withdrawal was not a new row'; end if;
  if (select basis from public.ffm_consent_log where id = cid) <> 'express' then raise exception 'C30 the original row changed'; end if;
  perform pg_temp.expect_fail(format($q$select public.ffm_record_consent(%L,%L,'email','express','v2','web',now(),'form-9','bot')$q$, a, la), 'consent refused: this lead withdrew%');
  perform pg_temp.as_owner(true);
  perform pg_temp.expect_fail(format($q$select public.ffm_record_consent(%L,%L,'email','express','v2','web',now(),'form-9','owner')$q$, a, la), 'consent refused: this lead withdrew%');
  perform pg_temp.as_owner(false);
  -- a withdrawal for ALL channels beats an express consent on a different channel
  perform public.ffm_record_consent(a, ld, 'sms', 'express', 'v1', 'web form', now() - interval '1 day', 'form-3000', 'bot');
  perform public.ffm_record_consent(a, ld, 'email', 'express', 'v1', 'web form', now() - interval '1 day', 'form-3001', 'bot');
  if not public.ffm_can_contact(ld, 'sms') or not public.ffm_can_contact(ld, 'email') then raise exception 'C31 setup'; end if;
  perform public.ffm_withdraw_consent(a, ld, 'all', 'phone call', null, 'bot');
  if public.ffm_can_contact(ld, 'sms') or public.ffm_can_contact(ld, 'email') or public.ffm_can_contact(ld, 'phone') then raise exception 'C32 withdrawal of all channels not honoured'; end if;
  -- withdrawing one channel leaves the others alone
  perform public.ffm_record_consent(a, lc, 'sms', 'express', 'v1', 'web form', now() - interval '1 day', 'form-3002', 'bot');
  perform public.ffm_withdraw_consent(a, lc, 'email', 'reply STOP', null, 'bot');
  if not public.ffm_can_contact(lc, 'sms') then raise exception 'C33 withdrawing email removed sms'; end if;
  perform pg_temp.expect_fail(format($q$select public.ffm_withdraw_consent(%L,%L,'email','x',null,'bot')$q$, b, la), 'lead not found in this workspace%');
  perform pg_temp.expect_fail(format($q$select public.ffm_withdraw_consent(%L,%L,'fax','x',null,'bot')$q$, a, la), 'withdrawal refused: channel%');

  -- C34 IMMUTABLE (update, delete, truncate refused even for the table owner)
  perform pg_temp.expect_fail(format($q$update public.ffm_consent_log set basis = 'express' where lead_id = %L and basis = 'withdrawn'$q$, la), 'The consent log is append-only%');
  perform pg_temp.expect_fail(format($q$update public.ffm_consent_log set evidence_ref = null where id = %L$q$, cid), 'The consent log is append-only%');   -- blanking evidence needs the owner-only erasure path
  perform pg_temp.expect_fail(format($q$delete from public.ffm_consent_log where id = %L$q$, cid), 'The consent log is append-only%');
  perform pg_temp.expect_fail('truncate public.ffm_consent_log', 'The consent log is append-only%');
  perform pg_temp.expect_fail(format($q$update public.ffm_consent_log set wording_version = 'v9' where id = %L$q$, cid), 'The consent log is append-only%');
  perform pg_temp.expect_fail(format($q$delete from public.ws_leads where id = %L$q$, la), '%foreign key%');   -- a lead with consent history cannot be hard-deleted: erase it instead
  perform pg_temp.expect_fail(format($q$insert into public.ffm_consent_log (workspace_id, lead_id, channel, basis, wording_version, source, captured_at, recorded_by) values (%L, %L, 'all', 'express', 'v1', 'x1', now(), 'bot')$q$, a, lb), '%check%');   -- 'all' only for withdrawals
  perform pg_temp.expect_fail(format($q$insert into public.ffm_consent_log (workspace_id, lead_id, channel, basis, source, captured_at, recorded_by) values (%L, %L, 'email', 'express', 'x1', now(), 'bot')$q$, a, lb), '%check%');   -- express needs a wording version

  -- C35 suppression list and closed workspaces
  insert into public.contact_suppressions (address, reason, recorded_by) values ('echo@example.com', 'unsubscribe', 'test');
  perform public.ffm_record_consent(b, le, 'email', 'express', 'v1', 'web form', now() - interval '1 day', 'form-4000', 'bot');
  if public.ffm_can_contact(le, 'email') then raise exception 'C36 suppressed address allowed'; end if;
  if public.ffm_contact_status(le, 'email') ->> 'reason' <> 'suppressed' then raise exception 'C37 reason'; end if;
  update public.client_workspaces set status = 'closed' where id = a;
  if public.ffm_can_contact(lc, 'sms') then raise exception 'C38 closed workspace allowed'; end if;
  perform public.ffm_withdraw_consent(a, lc, 'sms', 'late STOP', null, 'bot');   -- a withdrawal is accepted even in a closed workspace
  update public.client_workspaces set status = 'draft' where id = a;

  -- C39 routing preview refuses leads with no current consent (still a dry run)
  perform public.ffm_add_routing_rule(a, 'to client crm', 'crm', null, array['name', 'email']);
  update public.ffm_routing_rules set status = 'approved' where workspace_id = a;
  perform pg_temp.expect_fail(format($q$select public.ffm_route_preview(%L, %L)$q$, a, la), 'routing refused: no current consent%');   -- withdrawn
  perform pg_temp.expect_fail(format($q$select public.ffm_route_preview(%L, %L)$q$, a, ld), 'routing refused: no current consent%');   -- withdrawn all
  perform pg_temp.expect_fail(format($q$select public.ffm_route_preview(%L, %L)$q$, a, lc), 'routing refused: no current consent%');
  perform pg_temp.expect_fail(format($q$select public.ffm_route_preview(%L, %L)$q$, a, lb), 'routing refused: no current consent%');   -- implied, window cleared
  perform pg_temp.expect_fail(format($q$select public.ffm_route_preview(%L, %L)$q$, a, le), 'lead not found in this workspace%');
  before_n := (select count(*) from public.ffm_route_log);
  if before_n <> 0 then raise exception 'C40 a refused preview was logged'; end if;
  lb := public.ws_add_lead(a, ca, 'Lead Foxtrot', 'foxtrot@example.com', null, 'web form');
  perform public.ffm_record_consent(a, lb, 'email', 'express', 'v1', 'web form', now() - interval '1 day', 'form-5000', 'bot');
  j := public.ffm_route_preview(a, lb);
  if jsonb_array_length(j) <> 1 or (j -> 0 ->> 'dry_run')::boolean is not true then raise exception 'C41 consented lead not previewed as a dry run: %', j; end if;
  perform public.ffm_withdraw_consent(a, lb, 'all', 'STOP', null, 'bot');
  perform pg_temp.expect_fail(format($q$select public.ffm_route_preview(%L, %L)$q$, a, lb), 'routing refused: no current consent%');

  -- C42 nothing here can send: dry_run stays true everywhere, and no function or table was added that carries a sent/delivered state
  foreach t in array array['ffm_ad_sets', 'ffm_creatives', 'ffm_routing_rules', 'ffm_route_log'] loop
    if not exists (select 1 from pg_constraint where conrelid = ('public.' || t)::regclass and contype = 'c' and pg_get_constraintdef(oid) ~ '^CHECK \(?dry_run\)?$') then raise exception 'C42 no dry_run CHECK on %', t; end if;
  end loop;
  if exists (select 1 from information_schema.columns where table_schema = 'public' and table_name in ('ffm_consent_log', 'ffm_consent_settings') and column_name ~ '(sent|deliver|send)') then raise exception 'C43 sending state in the consent tables'; end if;

  -- C44 ERASURE: owner-only; redacts contact fields, blanks evidence pointers, keeps metadata, ends contact on every channel
  perform pg_temp.expect_fail(format($q$select public.ffm_erase_lead(%L, %L, 'erasure_request')$q$, a, la), 'owner approval required%');
  perform pg_temp.as_owner(true);
  perform pg_temp.expect_fail(format($q$select public.ffm_erase_lead(%L, %L, 'because')$q$, a, la), 'erasure refused: reason%');
  perform pg_temp.expect_fail(format($q$select public.ffm_erase_lead(%L, %L, 'erasure_request')$q$, b, la), 'lead not found in this workspace%');
  n := (select count(*) from public.ffm_consent_log where lead_id = la);
  j := public.ffm_erase_lead(a, la, 'erasure_request');
  perform pg_temp.as_owner(false);
  if (select name || coalesce(email, '') || coalesce(phone, '') || coalesce(note, '') from public.ws_leads where id = la) <> '[erased]' then raise exception 'C45 lead not redacted'; end if;
  if exists (select 1 from public.ffm_consent_log where lead_id = la and evidence_ref is not null) then raise exception 'C46 evidence pointers remain'; end if;
  if (select count(*) from public.ffm_consent_log where lead_id = la and evidence_erased_at is not null) <> (j ->> 'evidence_refs_blanked')::int then raise exception 'C47 erasure count'; end if;
  if (select count(*) from public.ffm_consent_log where lead_id = la) <> n + 1 then raise exception 'C48 metadata rows lost or no final withdrawal added'; end if;
  if (select basis from public.ffm_consent_log where id = cid) <> 'express' then raise exception 'C49 basis changed by erasure'; end if;
  if public.ffm_can_contact(la, 'email') or public.ffm_can_contact(la, 'sms') then raise exception 'C50 erased lead contactable'; end if;
  perform pg_temp.expect_fail(format($q$update public.ffm_consent_log set evidence_ref = null where id = %L$q$, cid), 'The consent log is append-only%');   -- the erasure flag does not leak out of the function
  if (select count(*) from public.audit_log where action = 'ffm_lead_erased' and (detail ->> 'lead')::uuid = la) <> 1 then raise exception 'C51 erasure not audited'; end if;
  if (select detail::text from public.audit_log where action = 'ffm_lead_erased' and (detail ->> 'lead')::uuid = la) ~* 'alpha|613' then raise exception 'C52 personal data in the audit row'; end if;
  perform pg_temp.expect_fail('select set_config(''app.ffm_erasure'', ''on'', true); update public.ffm_consent_log set basis = ''express''', 'The consent log is append-only%');   -- the flag alone does not unlock other columns

  -- ===== H: the health category =====
  -- H1 flagged (each must contain 'health')
  foreach s in array array['diabetes', 'Type 2 diabetic', 'd.i.a.b.e.t.e.s', 'D I A B E T E S', 'cancer', 'cancer survivor', 'c a n c e r', 'she is a smoker', 'non-smoker', 'smokers', 'tobacco use', 'nicotine',
                           'high blood pressure', 'blood-pressure med', 'heart condition', 'heart', 'my heart', 'h.e.a.r.t', 'heart attack', 'my doctor said', 'Dr. visit, doctor''s note', 'nurse', 'prescription', 'prescribed',
                           'meds', 'rx', 'pregnant', 'pregnancy', 'disability', 'disabilities benefit', 'mental health', 'mental', 'therapy', 'therapist', 'surgery last year', 'surgeon', 'hospital', 'hospitalized',
                           'HIV', 'H.I.V', 'AIDS', 'medical history', 'medication', 'medicine', 'medicare', 'health', 'health insurance', 'chronic pain', 'suicidal', 'ADHD', 'a s t h m a', 'asthma',
                           'diagnosed with', 'diagnosis', 'cardiac', 'stroke', 'has a stroke', 'epilepsy', 'depression', 'anxiety', 'bipolar', 'PTSD', 'chemo', 'chemotherapy', 'oncology', 'tumor', 'tumour',
                           'dialysis', 'insulin', 'inhaler', 'vaccine', 'allergy', 'allergic', 'wheelchair', 'injury', 'covid', 'ambulance', 'clinic', 'symptoms', 'illness', 'disease', 'sick', 'sick leave',
                           'drug use', 'vaping', 'cannabis', 'rehabilitation hospital', 'terminally ill, hospice', 'physician', 'obese', 'obesity', 'eating disorder', 'miscarriage', 'abortion', 'maternity',
                           'zero-width' || chr(8203) || ' d' || chr(8203) || 'iabetes', 'ＤＩＡＢＥＴＥＳ'] loop
    if not ('health' = any(public.ws_sensitive_hits(s))) then raise exception 'H1 not flagged: %', s; end if;
  end loop;
  -- H2 NOT flagged: ordinary text must keep working
  foreach s in array array['Call 613-555-0142 about a renewal in March', 'Mortgage renewal for a condo in Barrhaven', 'Interested in a quote', 'hospitality industry', 'the chronicle', 'fundamental and incremental',
                           'departmental sentimental', 'heartfelt thanks', 'Hearthstone Realty', 'doctorate in physics', 'the art of selling', 'deliver the brochure', 'Kingston Road branch', 'Life insurance quote',
                           'Term 20 coverage', 'wants a callback next week', 'Facebook lead form', 'Landing page A', 'mental' || 'ity', 'Medina Street', 'comedic timing', 'immediate follow up', 'intermediate level',
                           'Spring campaign creative', 'Book a call', 'aid' , 'said hi very much', 'rxample', 'hiving'] loop
    if public.ws_sensitive_hits(s) <> '{}' then raise exception 'H2 false positive on ordinary text: % -> %', s, public.ws_sensitive_hits(s); end if;
  end loop;
  -- H3 ACCEPTED FALSE POSITIVES (fail-closed by design; the owner accepted refusing these rather than missing health data). If one stops being flagged, update the policy document.
  foreach s in array array['healthy lead', 'health insurance quote', 'scan certificate attached', 'diagnostic tool', 'hearing aids', 'teaching aids', 'seizure of property', 'brush stroke', 'sick day', 'an addictive game',
                           'disordered shelves', 'kidney beans', 'soil fertility', 'drug store', 'clinical trial software', 'depressed market', 'anxiety about rates', 'heart of the city', 'the doctor', 'he art attack'] loop
    if not ('health' = any(public.ws_sensitive_hits(s))) then raise exception 'H3 accepted false positive no longer flagged (update the policy list): %', s; end if;
  end loop;
  -- H4 KNOWN MISSES (documented limits of regex detection; asserted so that any change is deliberate)
  foreach s in array array['diabtes', 'diabète', 'cáncer', 'my sugar is high', 'd1abetes', 'sugar problems', 'takes pills every morning', 'in remission', 'had a bypass'] loop
    if 'health' = any(public.ws_sensitive_hits(s)) then raise exception 'H4 expected miss now flagged (update the limits list): %', s; end if;
  end loop;
  -- H5 the earlier categories are unchanged
  if public.ws_sensitive_hits('SIN 123-456-789') <> array['identity_document'] and not ('sin_like_number' = any(public.ws_sensitive_hits('SIN 123-456-789'))) then raise exception 'H5 sin'; end if;
  if not ('credit' = any(public.ws_sensitive_hits('equifax report'))) or not ('banking' = any(public.ws_sensitive_hits('void cheque'))) or not ('application_or_income' = any(public.ws_sensitive_hits('annual income 120k'))) then raise exception 'H5 earlier categories changed'; end if;
  if public.ws_sensitive_hits(null) <> '{}' or public.ws_sensitive_hits('') <> '{}' then raise exception 'H6 null/empty'; end if;
  -- H7 no invisible or literal non-ASCII-escape regressions in the function body: the zero-width class must still be written as \u escapes
  if position(chr(8203) in pg_get_functiondef('public.ws_sensitive_hits(text)'::regprocedure)) > 0 or position(chr(65279) in pg_get_functiondef('public.ws_sensitive_hits(text)'::regprocedure)) > 0 then raise exception 'H7 literal invisible character in ws_sensitive_hits'; end if;
  if pg_get_functiondef('public.ws_sensitive_hits(text)'::regprocedure) !~ '\\u200b' then raise exception 'H7b escape missing'; end if;
  -- H8 the guard applies the new category to every ws_* / ffm_* table
  begin perform public.ws_add_lead(a, ca, 'Case', null, null, 'x', 'has diabetes'); raise exception 'H8 ws_leads accepted a health note';
  exception when raise_exception then if sqlerrm like 'H8%' then raise; end if; end;
  begin insert into public.ffm_creatives (workspace_id, headline, body) values (a, 'Quit smoking today', 'x1'); raise exception 'H9 creative accepted';
  exception when raise_exception then if sqlerrm like 'H9%' then raise; end if; end;
  raise notice 'ffm_consent_check: all passed';
end $$;
rollback;
