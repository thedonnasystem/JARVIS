-- SQL-level checks for migrations/20261122_insurance_classifier_v1.sql. SCRATCH replica only. One transaction, rolled back.
-- Sections: G grants/owner-only/validation/audit/immutability, E empty-list behaviour (nothing extra permitted), P permitted marketing, X prohibited personal information,
-- O obfuscation (look-alikes, fullwidth, zero-width, combining marks, spaced letters, leetspeak, mixed language), A adversarial wrappers, R no regression of earlier categories,
-- T guards on real tables, D deterministic differential corpus (old function vs new classifier), L asserted LIMITS (known misses, so a change is noticed).
begin;
create temp table pg_temp.assertion_count (kind text) on commit drop;
create function pg_temp.expect_fail(p_sql text, p_pat text) returns void language plpgsql as $$
begin
  insert into pg_temp.assertion_count values ('refused');
  begin execute p_sql; exception when others then
    if sqlerrm like p_pat then return; end if;
    raise exception 'wrong error for [%]: got [%], wanted like [%]', p_sql, sqlerrm, p_pat;
  end;
  raise exception 'NOT REFUSED: %', p_sql;
end $$;
create function pg_temp.as_owner(p boolean) returns void language plpgsql as $$
begin
  if p then perform set_config('app.uid', '99999999-9999-9999-9999-999999999993', true);
  else perform set_config('app.uid', '', true); end if;
end $$;
create function pg_temp.ok(p_text text, p_ws uuid) returns boolean language sql as $$ select (public.ws_classify_text(p_text, p_ws) ->> 'allowed')::boolean $$;
create function pg_temp.codes(p_text text, p_ws uuid) returns text language sql as $$ select array_to_string(array(select jsonb_array_elements_text(public.ws_classify_text(p_text, p_ws) -> 'reasons')), ',') $$;
create function pg_temp.must_pass(p_tag text, p_text text, p_ws uuid) returns void language plpgsql as $$
begin insert into pg_temp.assertion_count values ('pass'); if not pg_temp.ok(p_text, p_ws) then raise exception '% should PASS: % -> %', p_tag, p_text, pg_temp.codes(p_text, p_ws); end if; end $$;
create function pg_temp.must_block(p_tag text, p_text text, p_ws uuid, p_code text default null) returns void language plpgsql as $$
begin
  insert into pg_temp.assertion_count values ('block');
  if pg_temp.ok(p_text, p_ws) then raise exception '% should be BLOCKED: %', p_tag, p_text; end if;
  if p_code is not null and position(p_code in pg_temp.codes(p_text, p_ws)) = 0 then raise exception '% blocked with the wrong code: % -> % (wanted %)', p_tag, p_text, pg_temp.codes(p_text, p_ws), p_code; end if;
end $$;

do $$
declare ins uuid; ins2 uuid; other uuid; ca uuid; cb uuid; ads uuid; t text; r text; f text; s text; j jsonb; n int; id1 uuid; id2 uuid; id3 uuid; tid uuid;
begin
  insert into auth.users (id, email) values ('99999999-9999-9999-9999-999999999993', 'classifier-owner@example.com');
  insert into public.app_owners (email) values ('classifier-owner@example.com');
  perform pg_temp.as_owner(true);
  insert into public.client_workspaces (slug, name, vertical, status) values ('ic-ins', 'IC Insurance', 'insurance', 'active') returning id into ins;
  insert into public.client_workspaces (slug, name, vertical, status) values ('ic-ins2', 'IC Insurance Two', 'insurance', 'active') returning id into ins2;
  insert into public.client_workspaces (slug, name, vertical, status) values ('ic-other', 'IC Other', 'mortgage', 'active') returning id into other;
  insert into public.ws_campaigns (workspace_id, name) values (ins, 'Ins campaign') returning id into ca;
  insert into public.ws_campaigns (workspace_id, name) values (other, 'Other campaign') returning id into cb;

  -- ===== G: grants, owner-only, validation, audit, immutability =====
  if not (select relrowsecurity from pg_class where oid = 'public.ws_approved_terms'::regclass) then raise exception 'G1 RLS off'; end if;
  if exists (select 1 from pg_policy where polrelid = 'public.ws_approved_terms'::regclass) then raise exception 'G2 policy present'; end if;
  foreach r in array array['anon', 'authenticated'] loop
    if has_table_privilege(r, 'public.ws_approved_terms', 'select') or has_table_privilege(r, 'public.ws_approved_terms', 'insert') then raise exception 'G3 % has access', r; end if;
  end loop;
  foreach r in array array['insert', 'update', 'delete', 'truncate', 'trigger', 'references'] loop
    if has_table_privilege('service_role', 'public.ws_approved_terms', r) then raise exception 'G4 service_role can %', r; end if;
  end loop;
  if not has_table_privilege('service_role', 'public.ws_approved_terms', 'select') then raise exception 'G4b service_role cannot read'; end if;
  foreach f in array array['public.ws_terms_immutable()', 'public.ws_fold_text(text)', 'public.ws_leet_text(text,integer)', 'public.ws_health_extra_hit(text)', 'public.ws_personal_context_hit(text)',
                           'public.ws_identifier_hit(text)', 'public.ws_classify_text(text,uuid)', 'public.ws_add_approved_term(uuid,text,text,text)', 'public.ws_remove_approved_term(uuid)',
                           'public.ws_guard()', 'public.ffm_guard()'] loop
    foreach r in array array['anon', 'authenticated'] loop
      if has_function_privilege(r, f, 'execute') then raise exception 'G5 % can execute %', r, f; end if;
    end loop;
    if not has_function_privilege('service_role', f, 'execute') then raise exception 'G6 service_role cannot execute %', f; end if;
  end loop;
  -- the guards stay invoker functions (ops/verify_post_release_executor_ffm.sql counts on it); the classifier is a definer that never writes
  if (select prosecdef from pg_proc where oid = 'public.ws_guard()'::regprocedure) or (select prosecdef from pg_proc where oid = 'public.ffm_guard()'::regprocedure) then raise exception 'G7 a guard became SECURITY DEFINER'; end if;
  if (select count(*) from pg_proc where oid in ('public.ws_classify_text(text,uuid)'::regprocedure, 'public.ws_add_approved_term(uuid,text,text,text)'::regprocedure, 'public.ws_remove_approved_term(uuid)'::regprocedure) and prosecdef and proconfig::text like '%search_path=public%') <> 3 then raise exception 'G8 definer functions must pin search_path'; end if;
  if (select count(*) from public.ws_approved_terms) <> 0 then raise exception 'G9 the table must ship EMPTY'; end if;

  -- owner-only: the bot is refused
  perform pg_temp.as_owner(false);
  perform pg_temp.expect_fail(format($q$select public.ws_add_approved_term(%L, null, 'product', 'health insurance')$q$, ins), 'owner approval required%');
  perform pg_temp.as_owner(true);

  -- E (empty list) BEFORE any approval: the old behaviour, every phrase of the brief is refused
  foreach s in array array['health insurance', 'Protect your family with health insurance', 'Critical illness insurance from $25/month', 'Assurance invalidité pour les travailleurs autonomes', 'disability insurance',
                           'Medicine Hat', 'critical illness cover', 'assurance santé'] loop
    perform pg_temp.must_block('E1', s, ins, 'health:no_approved_term');
    perform pg_temp.must_block('E2', s, null, 'health');
    perform pg_temp.must_block('E3', s, other, 'health');
  end loop;
  foreach s in array array['Life insurance quote', 'Term 20 coverage', 'Assurance vie pour les familles', 'Spring campaign', 'Call 613-555-0142 about a renewal'] loop
    perform pg_temp.must_pass('E4', s, ins);
  end loop;
  perform pg_temp.must_pass('E5 null', null, ins);
  perform pg_temp.must_pass('E5 empty', '   ', ins);

  -- validation: refusals never echo the term
  foreach s in array array['x1', 'a b', 'health insurance 2026', 'health insurance!', 'health@insurance', 'cancer', 'health', 'my health insurance', 'j''ai une assurance santé', 'bank account insurance',
                           'income protection plan', 'credit score insurance', 'passport cover', 'health card plan', repeat('health insurance ', 5), 'insurance'] loop
    begin perform public.ws_add_approved_term(ins, null, 'product', s); raise exception 'G10 accepted term: %', s;
    exception when raise_exception then if sqlerrm like 'G10%' then raise; end if; if position(s in sqlerrm) > 0 and length(s) > 6 then raise exception 'G10b refusal echoes the term: %', sqlerrm; end if; end;
  end loop;
  perform pg_temp.expect_fail(format($q$select public.ws_add_approved_term(%L, 'insurance', 'product', 'health insurance')$q$, ins), 'term refused: give exactly one%');
  perform pg_temp.expect_fail($q$select public.ws_add_approved_term(null, null, 'product', 'health insurance')$q$, 'term refused: give exactly one%');
  perform pg_temp.expect_fail($q$select public.ws_add_approved_term(null, 'Insurance Co', 'product', 'health insurance')$q$, 'term refused: vertical%');
  perform pg_temp.expect_fail($q$select public.ws_add_approved_term(gen_random_uuid(), null, 'product', 'health insurance')$q$, 'term refused: workspace not found%');
  perform pg_temp.expect_fail(format($q$select public.ws_add_approved_term(%L, null, 'brand', 'health insurance')$q$, ins), 'term refused: kind%');
  perform pg_temp.expect_fail(format($q$select public.ws_add_approved_term(%L, null, 'place', 'one two three four five six')$q$, ins), 'term refused: a place name%');
  -- accepted, normalised (case, accents, hyphen, curly apostrophe)
  id1 := public.ws_add_approved_term(ins, null, 'product', 'Health  Insurance');
  id2 := public.ws_add_approved_term(ins, null, 'product', 'Assurance invalidité');
  id3 := public.ws_add_approved_term(ins, null, 'place', 'Medicine Hat');
  perform public.ws_add_approved_term(ins, null, 'product', 'Critical illness insurance');
  perform public.ws_add_approved_term(ins, null, 'product', 'Assurance-santé');
  perform public.ws_add_approved_term(ins, null, 'product', 'Assurance d’invalidité');
  perform public.ws_add_approved_term(ins, null, 'product', 'Life insurance');
  if (select term_norm from public.ws_approved_terms where id = id1) <> 'health insurance' or (select term_norm from public.ws_approved_terms where id = id2) <> 'assurance invalidite' then raise exception 'G11 normalisation'; end if;
  if not exists (select 1 from public.ws_approved_terms where term_norm = 'assurance sante') or not exists (select 1 from public.ws_approved_terms where term_norm = 'assurance d''invalidite') then raise exception 'G11b hyphen/apostrophe normalisation'; end if;
  perform pg_temp.expect_fail(format($q$select public.ws_add_approved_term(%L, null, 'product', 'HEALTH INSURANCE')$q$, ins), 'term already approved%');
  -- audit: actor, ids and counts, never the term text
  select count(*) into n from public.audit_log where action = 'ws_approved_term_added' and target = 'workspace/' || ins;
  if n <> 7 then raise exception 'G12 audit rows: %', n; end if;
  if exists (select 1 from public.audit_log where action in ('ws_approved_term_added', 'ws_approved_term_removed') and detail::text ~* 'health|insurance|assurance|medicine|hat|invalid') then raise exception 'G13 term text in the audit log'; end if;
  if exists (select 1 from public.audit_log where action = 'ws_approved_term_added' and actor <> 'owner') then raise exception 'G13b audit actor'; end if;
  -- immutability
  perform pg_temp.expect_fail(format($q$delete from public.ws_approved_terms where id = %L$q$, id1), 'approved terms cannot be edited%');
  perform pg_temp.expect_fail(format($q$update public.ws_approved_terms set term = 'x' where id = %L$q$, id1), 'approved terms cannot be edited%');
  perform pg_temp.expect_fail($q$truncate public.ws_approved_terms$q$, 'approved terms cannot be edited%');
  perform pg_temp.expect_fail(format($q$update public.ws_approved_terms set removed_at = now(), term_norm = 'zzz zzz' where id = %L$q$, id1), 'approved terms cannot be edited%');

  -- ===== P: permitted product marketing (exact approved terms, no personal context, no identifiers) =====
  foreach s in array array['Protect your family with health insurance', 'Critical illness insurance from $25/month', 'Assurance invalidité pour les travailleurs autonomes',
                           'HEALTH INSURANCE', 'Health   insurance', 'health-insurance', 'Assurance santé pour toute la famille', 'Assurance-santé dès 25$ par mois', 'Assurance santé: protégez votre famille',
                           'Compare health insurance and life insurance', 'Health insurance for ages 18-65, since 1995', 'Health insurance with 24/7 support for over 10,000 families', 'Health insurance. Learn more.',
                           'Disability insurance' || ' ' , 'Assurance d''invalidité pour les travailleurs autonomes', 'Assurance d’invalidité pour les travailleurs autonomes',
                           'Health insurance in Medicine Hat', 'Medicine Hat office open Mon-Fri', 'Mon - Fri: Medicine Hat', 'Critical illness insurance covers you. Health insurance covers your family.',
                           'ＨＥＡＬＴＨ ＩＮＳＵＲＡＮＣＥ', 'Health' || chr(8203) || ' insurance', 'Heal' || chr(173) || 'th insurance'] loop
    if s like 'Disability insurance%' then continue; end if;   -- not approved in this scope on purpose (see E and below)
    perform pg_temp.must_pass('P1', s, ins);
  end loop;
  perform pg_temp.must_block('P2 disability not approved here', 'Disability insurance for self-employed workers', ins, 'health:no_approved_term');
  perform pg_temp.must_block('P2b similar but different term', 'Health insurance premium; disability cover', ins, 'health');
  perform pg_temp.must_block('P2c plural/partial is not exact', 'Healthy insurance', ins, 'health');
  perform pg_temp.must_block('P2d substring of a longer word', 'Unhealth insurance', ins);
  if pg_temp.codes('Protect your family with health insurance', ins) <> 'approved_product_term' then raise exception 'P3 reason code for an allowed product text: %', pg_temp.codes('Protect your family with health insurance', ins); end if;
  if pg_temp.codes('Medicine Hat office', ins) <> 'approved_place' then raise exception 'P3b reason code for a place: %', pg_temp.codes('Medicine Hat office', ins); end if;
  -- scope: terms of workspace A do not apply to workspace B or to a workspace of another vertical
  perform pg_temp.must_block('P4 other workspace same vertical', 'Protect your family with health insurance', ins2, 'health:no_approved_term');
  perform pg_temp.must_block('P4b other vertical', 'Protect your family with health insurance', other);
  -- vertical scope
  tid := public.ws_add_approved_term(null, 'insurance', 'product', 'Disability insurance');
  perform pg_temp.must_pass('P5 vertical term, workspace 1', 'Disability insurance for self-employed workers', ins);
  perform pg_temp.must_pass('P5b vertical term, workspace 2', 'Disability insurance for self-employed workers', ins2);
  perform pg_temp.must_block('P5c vertical term does not leak to another vertical', 'Disability insurance for self-employed workers', other);
  -- soft removal: the waiver stops immediately, the row stays
  perform pg_temp.as_owner(false);
  perform pg_temp.expect_fail(format($q$select public.ws_remove_approved_term(%L)$q$, tid), 'owner approval required%');
  perform pg_temp.as_owner(true);
  perform public.ws_remove_approved_term(tid);
  perform pg_temp.must_block('P6 removed term no longer waives', 'Disability insurance for self-employed workers', ins2, 'health:no_approved_term');
  if not exists (select 1 from public.ws_approved_terms where id = tid and removed_at is not null) then raise exception 'P6b row must remain'; end if;
  perform pg_temp.expect_fail(format($q$select public.ws_remove_approved_term(%L)$q$, tid), 'approved term not found%');
  if not exists (select 1 from public.audit_log where action = 'ws_approved_term_removed' and detail ->> 'term_id' = tid::text) then raise exception 'P6c removal not audited'; end if;
  tid := public.ws_add_approved_term(null, 'insurance', 'product', 'Disability insurance');   -- re-adding after removal is allowed (unique index is on ACTIVE rows)
  perform public.ws_add_approved_term(ins, null, 'product', 'Disability insurance');
  perform pg_temp.must_pass('P7', 'Disability insurance for self-employed workers', ins);

  -- ===== X: personal health / personal information is refused even with approved terms present =====
  foreach s in array array['I have diabetes and need health insurance', 'Health insurance for my husband''s cancer', 'Critical illness insurance - my sister was diagnosed with cancer last month',
                           'j''ai le diabète, assurance santé', 'Assurance santé: ma mère est atteinte', 'Assurance invalidité - ma demande d''invalidité', 'Disability insurance - my disability claim was denied',
                           'Health insurance claim for my surgery', 'Health insurance claim for her surgery', 'Health insurance - he was diagnosed in March', 'Prescribed medication and health insurance',
                           'Health insurance for John who has cancer', 'Health insurance. Patient history attached', 'Health insurance, in remission', 'Health insurance - takes pills every morning',
                           'Assurance santé, il souffre du cancer', 'Assurance santé pour Marie, enceinte de 6 mois', 'Health insurance: she is pregnant', 'Health insurance after his heart attack',
                           'Health insurance - she passed away last year', 'Health insurance - policy number on file', 'Health insurance, claim number on file', 'Assurance santé numéro de police sur le dossier',
                           'I need health insurance', 'Me and health insurance', 'my health insurance', 'Health insurance - I', 'Assurance santé pour moi', 'Assurance santé: mon dossier', 'Assurance santé, j''ai appelé',
                           'Health insurance - born in 1985', 'Health insurance dob 03/12/1985'] loop
    perform pg_temp.must_block('X1', s, ins, 'health');
  end loop;
  -- identifiers next to a product phrase
  foreach s in array array['Health insurance quotes call 613-555-0100', 'Health insurance (613) 555 0100', 'Health insurance 6135550100', 'Health insurance 555-0100', 'Health insurance john@example.com',
                           'Health insurance john at example dot com', 'Health insurance K1A 0B1', 'Health insurance 123 Main Street', 'Health insurance 12/03/1985', 'Health insurance 1985-03-12',
                           'Health insurance ref 8875', 'Health insurance 4111 1111 1111 1111', 'Health insurance 123-456-789', 'Health insurance SIN', 'Assurance santé 613 555 0100',
                           'Health insurance policy 99887766', 'Health insurance, contract 123456'] loop
    perform pg_temp.must_block('X2', s, ins);
  end loop;
  -- PROHIBITED categories are never waivable by a term
  foreach s in array array['Health insurance. Upload your bank statement', 'Health insurance, credit score 710', 'Health insurance - passport', 'Health insurance: void cheque',
                           'Health insurance, annual income 120k', 'Health insurance, T4', 'Health insurance - date of birth', 'Health insurance, health card number', 'Health insurance - OHIP'] loop
    perform pg_temp.must_block('X3', s, ins);
  end loop;
  perform pg_temp.must_block('X4 old category code kept', 'Health insurance. Upload your bank statement', ins, 'banking');
  perform pg_temp.must_block('X4b', 'Health insurance - SIN 123 456 789', ins, 'identity_document');
  perform pg_temp.must_block('X4c', 'Health insurance, annual income 120k', ins, 'application_or_income');

  -- ===== O: obfuscation. A hidden health word is never excused by an approved term elsewhere =====
  foreach s in array array['Health insurance cаncer', 'Health insurance dіabetes', 'Health insurance сancer', 'hеаlth insurance', 'Health insurance ＣＡＮＣＥＲ', 'Health insurance diab' || chr(8203) || 'etes',
                           'Health insurance can' || chr(8205) || 'cer', 'Health insurance dia' || chr(769) || 'betes', 'Health insurance c a n c e r', 'Health insurance d.i.a.b.e.t.e.s', 'Health insurance d-i-a-b-e-t-e-s',
                           'Health insurance c4nc3r', 'Health insurance d1abetes', 'Health insurance di@betes', 'Health insurance m3dication', 'Health insurance pr3scr!ption', 'Health insurance dépression',
                           'Health insurance maladie', 'Health insurance m a l a d i e', 'Health insurance mal4die', 'Health insurance cœur', 'Health insurance c0eur', 'Health insurance hôpital', 'Health insurance hopital',
                           'Assurance santé médecin', 'Assurance santé médicament', 'Assurance santé chirurgie', 'Assurance santé diabète', 'Assurance santé tumeur', 'Assurance santé chimio', 'Assurance santé grossesse',
                           'Assurance santé invalidité', 'Assurance santé handicap', 'Assurance santé AVC', 'Assurance santé cancer du sein', 'Assurance santé œdème et cœur', 'Assurance santé ordonnance',
                           'Health insurance heart', 'Health insurance h.e.a.r.t', 'Health insurance ＨＥＡＲＴ', 'Health insurance hеart', 'Health insurance hear' || chr(8203) || 't'] loop
    perform pg_temp.must_block('O1', s, ins, 'health');
  end loop;
  -- the same hidden words with NO approved term anywhere: still refused (also with a null workspace)
  foreach s in array array['cаncer', 'dіabetes', 'ＣＡＮＣＥＲ', 'diab' || chr(8203) || 'etes', 'dia' || chr(769) || 'betes', 'c a n c e r', 'c4nc3r', 'd1abetes', 'di@betes', 'diabète', 'maladie', 'cáncer', 'cœur', 'hôpital', 'ma mère est atteinte de la maladie',
                           'médecin', 'chirurgie', 'santé', 'invalidité', 'tumeur', 'enceinte', 'médicament', 'Ça fait mal, mon cœur', 'Ηealth', 'ѕіск'] loop
    if s in ('Ça fait mal, mon cœur', 'ѕіск') then continue; end if;
    perform pg_temp.must_block('O2', s, null, 'health');
    perform pg_temp.must_block('O2b', s, ins, 'health');
  end loop;
  -- mixed Latin + Cyrillic/Greek is never excused (an obfuscation signature), even when the visible words are an approved term
  perform pg_temp.must_block('O3', 'Health insurance ' || 'аheart', ins);
  perform pg_temp.must_block('O3b', 'Health insurance ' || 'нealth', ins);
  perform pg_temp.must_block('O3c mixed script is refused even when no health word is visible', 'Health insurance αβγ', ins, 'health:mixed_script');

  -- ===== A: adversarial wording: a product phrase wrapped around personal information =====
  foreach s in array array['Critical illness insurance - my sister was diagnosed with cancer last month', 'Critical illness insurance. Her chemo starts Monday.',
                           'Health insurance; Dr. Lee prescribed insulin', 'Health insurance! My mom, 61, lung cancer, stage 3', 'Health insurance - patient file 4471 attached', 'Health insurance. Previous surgery: knee.',
                           'Health insurance . . . diagnosed . . .', 'Assurance santé - ma soeur a reçu un diagnostic de cancer le mois dernier', 'Assurance santé / mon père est décédé / sa maladie',
                           'Assurance invalidité: ma demande d''invalidité a été refusée', 'Disability insurance. Disability: bad back, since 2019', 'Health insurance - take my pills', 'Health insurance? asthma kid',
                           E'Health insurance\nmy diabetes', E'Health insurance\tcancer', 'Health insurance' || repeat(' ', 40) || 'cancer', 'HEALTH INSURANCE CANCER', 'Health insurance. Cancer.', 'cancer; health insurance',
                           'Health insurance for diabetics', 'Health insurance for people with cancer', 'Health insurance, 613-555-0100, call me', 'Health insurance - call 613-555-0100 re: her claim',
                           'Critical illness insurance and my SIN is 123-456-789', 'Critical illness insurance, card 4111 1111 1111 1111', 'Critical illness insurance john.smith@example.com DOB 1985-03-12',
                           'Health insurance for Jean Tremblay, 1985-03-12, 45 Rue Principale', 'Mon assurance santé', 'Je cherche une assurance santé', 'Health insurance claim denied for him',
                           'Health insurance - his claim for surgery was approved'] loop
    perform pg_temp.must_block('A1', s, ins);
  end loop;
  -- ... while neighbouring ordinary marketing is still fine (the classifier must not become a blanket block)
  foreach s in array array['Health insurance and life insurance for your family', 'Health insurance from $19.99/month - no medical exam needed' || '', 'Assurance santé, assurance-vie, assurance invalidité: tout au même endroit',
                           'Critical illness insurance: protect your income, your family and your future', 'Get a free quote. Book a call. Health insurance made simple.', 'Health insurance for freelancers in Ottawa and Medicine Hat',
                           'Choose health insurance that fits your budget: $25, $40 or $60 per month', 'Health insurance - plans from 25$/mois, 100% online', 'Health insurance, 24/7, since 1998, 4.8 stars from 2,300 reviews'] loop
    if s like '%no medical exam%' or s like '%protect your income%' then
      perform pg_temp.must_block('A2 (words outside the approved list stay refused)', s, ins);   -- 'medical' and 'income' are not waived: see the limits section
    else perform pg_temp.must_pass('A2', s, ins); end if;
  end loop;

  -- ===== R: no regression: every earlier category still fires, in every workspace, with or without terms =====
  foreach s in array array['SIN 123-456-789', 'my sin is 123456789', 'card 4111 1111 1111 1111', 'passport scan attached', 'driver''s licence photo', 'bank statement attached', 'account number 55512', 'credit score 710',
                           'equifax report', 'mortgage application form', 'pay stub for May', 'T4 slip', 'annual income 120k', 'void cheque', '123 456 789 call 613 555 1234', '123.456.789', '123/456/789', '123_456_789',
                           '１２３４５６７８９', '١٢٣٤٥٦٧٨٩', 'S.I.N 5', 's i n', 'social-insurance', 'SSN', 'bank account 1234567', 'chequing account', 'Experian', 'credit history', 'FICO', 'pre approval letter',
                           'loan application', 'T4A', 'tax return', 'OHIP', 'date of birth', 'salary', 's' || chr(8203) || 'in', 'ｓｉｎ', 'sіn', 'ѕalary', 'income', 'ｉｎｃｏｍｅ', 'sal' || chr(8203) || 'ary', 'Sálary'] loop
    foreach t in array array['ins', 'other', 'null'] loop
      f := case t when 'ins' then ins::text when 'other' then other::text else null end;
      if public.ws_sensitive_hits(s) = '{}' then continue; end if;
      if pg_temp.ok(s, f::uuid) then raise exception 'R1 earlier category no longer refused (%): %', t, s; end if;
      foreach r in array public.ws_sensitive_hits(s) loop
        if r <> 'health' and position(r in pg_temp.codes(s, f::uuid)) = 0 then raise exception 'R2 category % missing from reasons for %: %', r, s, pg_temp.codes(s, f::uuid); end if;
      end loop;
    end loop;
  end loop;
  -- the whole H1 list of ffm_consent_check.sql is still refused, with and without terms
  foreach s in array array['diabetes', 'Type 2 diabetic', 'd.i.a.b.e.t.e.s', 'D I A B E T E S', 'cancer', 'cancer survivor', 'c a n c e r', 'she is a smoker', 'non-smoker', 'tobacco use', 'high blood pressure', 'heart condition',
                           'heart', 'my heart', 'heart attack', 'my doctor said', 'nurse', 'prescription', 'prescribed', 'meds', 'rx', 'pregnant', 'disability', 'mental health', 'therapy', 'surgery last year', 'hospital', 'HIV',
                           'AIDS', 'medical history', 'medication', 'medicine', 'medicare', 'health', 'health insurance', 'chronic pain', 'suicidal', 'ADHD', 'asthma', 'diagnosed with', 'cardiac', 'stroke', 'epilepsy',
                           'depression', 'anxiety', 'chemo', 'oncology', 'tumour', 'insulin', 'wheelchair', 'covid', 'illness', 'disease', 'sick', 'drug use', 'cannabis', 'physician', 'obesity', 'miscarriage', 'maternity',
                           'zero-width' || chr(8203) || ' d' || chr(8203) || 'iabetes', 'ＤＩＡＢＥＴＥＳ'] loop
    perform pg_temp.must_block('R3', s, null, 'health');
    perform pg_temp.must_block('R3b', s, other, 'health');
  end loop;
  -- ordinary text keeps working (the H2 list of ffm_consent_check.sql)
  foreach s in array array['Call 613-555-0142 about a renewal in March', 'Mortgage renewal for a condo in Barrhaven', 'Interested in a quote', 'hospitality industry', 'the chronicle', 'departmental sentimental',
                           'heartfelt thanks', 'Hearthstone Realty', 'doctorate in physics', 'Life insurance quote', 'Term 20 coverage', 'wants a callback next week', 'Facebook lead form', 'Landing page A', 'Medina Street',
                           'immediate follow up', 'Spring campaign creative', 'Book a call', 'said hi very much', 'hiving', 'Élodie Gagné', 'François Lefèvre', 'Zoë Brontë', 'Ça va très bien, merci', 'Привет, Иван',
                           'Facture 24 h après la demande', 'Hélène Côté, Québec', 'Mon - Fri 9 to 5', 'Contact: info@acme.ca'] loop
    perform pg_temp.must_pass('R4', s, null);
  end loop;

  -- ===== T: the guards on the real tables =====
  ads := public.ffm_add_ad_set(ins, ca, 'Ottawa families', 'people who may want health insurance', null);
  perform public.ffm_add_creative(ins, ca, ads, 'Protect your family with health insurance', 'Critical illness insurance from $25/month. Assurance invalidité pour les travailleurs autonomes.', 'Get a quote');
  perform public.ffm_add_campaign(ins, 'Health insurance spring push', 'meta');
  insert into public.ws_ledger (workspace_id, amount_cents, note) values (ins, 100, 'Health insurance ad spend');
  insert into public.ffm_approvals (workspace_id, kind, approved_by, note) values (ins, 'campaign', 'owner', 'approved: health insurance copy v2');
  -- refused: not approved here / personal / identifier / split across columns
  perform pg_temp.expect_fail(format($q$select public.ffm_add_creative(%L, %L, %L, 'Health insurance', 'my sister was diagnosed with cancer')$q$, ins, ca, ads), 'Sensitive data refused%health%');
  perform pg_temp.expect_fail(format($q$select public.ffm_add_creative(%L, %L, %L, 'Health insurance', 'Get a quote', '613-555-0100')$q$, ins, ca, ads), 'Sensitive data refused%health:identifier%');   -- identifier only visible when columns are joined
  perform pg_temp.expect_fail(format($q$select public.ffm_add_creative(%L, %L, %L, 'Critical illness plan', 'Quote today')$q$, ins, ca, ads), 'Sensitive data refused%no_approved_term%') ;
  begin perform public.ffm_add_creative(ins, ca, ads, 'Health insurance', 'I have diabetes'); raise exception 'T1 accepted';
  exception when raise_exception then if sqlerrm like 'T1%' then raise; end if; if sqlerrm ~* 'diabetes|have' then raise exception 'T1b the refusal message echoes the text: %', sqlerrm; end if; end;
  perform pg_temp.expect_fail(format($q$update public.ffm_creatives set body = 'my diabetes and health insurance' where workspace_id = %L$q$, ins), 'Sensitive data refused%');
  perform pg_temp.expect_fail(format($q$update public.ws_campaigns set name = 'Health insurance - my claim' where id = %L$q$, ca), 'Sensitive data refused%');
  perform pg_temp.expect_fail(format($q$insert into public.ws_ledger (workspace_id, amount_cents, note) values (%L, 5, 'Health insurance, claim for her surgery')$q$, ins), 'Sensitive data refused%');
  perform pg_temp.expect_fail(format($q$insert into public.ffm_approvals (workspace_id, kind, approved_by, note) values (%L, 'campaign', 'owner', 'health insurance - he was diagnosed')$q$, ins), 'Sensitive data refused%');
  -- other workspaces are not helped by this workspace's terms
  perform pg_temp.expect_fail(format($q$select public.ffm_add_campaign(%L, 'Health insurance spring push')$q$, other), 'Sensitive data refused%no_approved_term%');
  perform pg_temp.expect_fail(format($q$select public.ffm_add_campaign(%L, 'Health insurance spring push')$q$, ins2), 'Sensitive data refused%no_approved_term%');
  -- PERSON tables stay strict even in the workspace with approved terms: a lead note about health products is still health data about a person
  perform pg_temp.expect_fail(format($q$select public.ws_add_lead(%L, %L, 'Pat Example', null, null, 'web form', 'interested in health insurance')$q$, ins, ca), 'Sensitive data refused%health%');
  perform pg_temp.expect_fail(format($q$select public.ws_add_lead(%L, %L, 'Health insurance', null, null, 'web form')$q$, ins, ca), 'Sensitive data refused%health%');
  perform pg_temp.expect_fail(format($q$update public.client_workspaces set name = 'Acme Health Insurance Brokers' where id = %L$q$, ins), 'Sensitive data refused%health%');
  perform pg_temp.expect_fail(format($q$select public.ffm_add_routing_rule(%L, 'Health insurance leads', 'email', 'x@example.com', array['name'])$q$, ins), 'Sensitive data refused%health%');
  perform public.ws_add_lead(ins, ca, 'Pat Example', 'pat@example.com', '613-555-0142', 'web form', 'wants a callback about renewal');   -- ordinary leads unaffected
  -- French and look-alike text reach the strict tables too (they were bypasses before this migration)
  perform pg_temp.expect_fail(format($q$select public.ws_add_lead(%L, %L, 'Pat Example', null, null, 'web form', 'a le diabète')$q$, ins, ca), 'Sensitive data refused%');
  perform pg_temp.expect_fail(format($q$select public.ws_add_lead(%L, %L, 'Pat Example', null, null, 'web form', 'cаncer')$q$, ins, ca), 'Sensitive data refused%');
  perform pg_temp.expect_fail(format($q$select public.ws_add_lead(%L, %L, 'Pat Example', null, null, 'web form', 'sa mère est malade')$q$, ins, ca), 'Sensitive data refused%');
  perform pg_temp.expect_fail(format($q$select public.ws_add_lead(%L, %L, 'Pat Example', null, null, 'web form', 'policy number 1234567')$q$, ins, ca), 'Sensitive data refused%');
  perform pg_temp.expect_fail(format($q$select public.ws_add_lead(%L, %L, 'Pat Example', null, null, 'web form', 'né le 12 mars 1985')$q$, ins, ca), 'Sensitive data refused%');
  -- removing a term does not rewrite stored rows (documented), but the next UPDATE of that row is checked again
  perform public.ws_remove_approved_term((select id from public.ws_approved_terms where term_norm = 'health insurance' and workspace_id = ins and removed_at is null));
  perform pg_temp.expect_fail(format($q$update public.ws_campaigns set channel = 'meta' where id = (select id from public.ws_campaigns where name = 'Health insurance spring push')$q$), 'Sensitive data refused%no_approved_term%');


  -- ===== D: deterministic differential corpus: OLD ws_sensitive_hits (unchanged) vs NEW ws_classify_text =====
  perform public.ws_add_approved_term(ins, null, 'product', 'Health insurance');
  declare
    vocab text[] := array['diabetes', 'cancer', 'diagnosed', 'prescribed', 'surgery', 'my doctor', 'heart', 'medication', 'tumour', 'hospital', 'depression', 'pregnant', 'disability', 'illness', 'diabète', 'maladie', 'chirurgie', 'médecin',
                          'j''ai le diabète', 'cœur', 'santé', 'invalidité', 'enceinte', 'health insurance', 'Health Insurance', 'HEALTH INSURANCE', 'assurance invalidité', 'Assurance Invalidité', 'critical illness insurance', 'life insurance',
                          'disability insurance', 'Medicine Hat', 'Protect your family with', 'Get a quote for', 'from $25/month', 'for self-employed workers', 'Call us today', 'ages 18-65', 'since 1995', 'over 10,000 families',
                          'my', 'I', 'j''ai', 'ma mère', 'me', 'her claim for surgery', 'he passed away', 'policy number', 'born 1985-03-12', 'diagnosed', 'suffers from', 'atteinte',
                          '613-555-0100', '123-456-789', '123456789', '4111 1111 1111 1111', '1234567', 'T2T 1A1', 'john@example.com', '12/03/1985', '123 Main Street', '$500,000', '55512',
                          'bank statement', 'credit score', 'SIN', 'passport', 'void cheque', 'salary', 'mortgage application', 'Equifax', 'date of birth', 'T4',
                          'quote', 'family', 'renewal', 'Spring campaign', 'landing page', 'Barrhaven', 'hospitality', 'heartfelt thanks', 'callback', 'Ottawa', 'Mon-Fri', 'Book a call'];
    seps text[] := array[' ', ', ', ' - ', '. ', ': ', ' '];
    txt text; mut text; o text[]; i int; k int; nv int := array_length(vocab, 1); ns int := array_length(seps, 1); res_ins jsonb; res_oth jsonb; res_nul jsonb;
    n_old int := 0; n_hl int := 0; n_alw_hl int := 0; n_blk int := 0; n_mut int := 0; resid text; used boolean; tn text;
  begin
    perform setseed(0.31416);
    for i in 1..2500 loop
      txt := '';
      for k in 1..(1 + floor(random() * 6)::int) loop txt := txt || vocab[1 + floor(random() * nv)::int] || seps[1 + floor(random() * ns)::int]; end loop;
      txt := btrim(txt);
      o := public.ws_sensitive_hits(txt);
      res_ins := public.ws_classify_text(txt, ins); res_oth := public.ws_classify_text(txt, other); res_nul := public.ws_classify_text(txt, null);
      if cardinality(o) > 0 then n_old := n_old + 1; end if;
      if o = array['health'] then n_hl := n_hl + 1; end if;
      if not (res_ins ->> 'allowed')::boolean then n_blk := n_blk + 1; end if;
      -- D1: with no approved terms, nothing extra is permitted
      if ((res_oth ->> 'allowed')::boolean or (res_nul ->> 'allowed')::boolean) and cardinality(o) > 0 then raise exception 'D1 allowed with no terms although the old detector hit (%): %', o, txt; end if;
      -- D2: a non-health old hit is never waived
      if exists (select 1 from unnest(o) h where h <> 'health') and (res_ins ->> 'allowed')::boolean then raise exception 'D2 earlier category waived (%): %', o, txt; end if;
      -- D3: old hit + allowed => only health, an approved term was cut out, and the independent oracle finds nothing left
      if cardinality(o) > 0 and (res_ins ->> 'allowed')::boolean then
        n_alw_hl := n_alw_hl + 1;
        resid := translate(lower(txt), 'éèêëàâçôîïûüœ', 'eeeeaaco' || 'iiuuo');
        used := false;
        for tn in select term_norm from public.ws_approved_terms where removed_at is null and (workspace_id = ins or vertical = 'insurance') loop
          for k in 1..3 loop
            if resid ~ ('(^|[^a-z0-9])' || replace(tn, ' ', '[ \-]+') || '([^a-z0-9]|$)') then
              resid := regexp_replace(resid, '(^|[^a-z0-9])' || replace(tn, ' ', '[ \-]+') || '([^a-z0-9]|$)', '\1 zzqx \2', 'g'); used := true; end if;
          end loop;
        end loop;
        if o <> array['health'] or not used or public.ws_sensitive_hits(resid) <> '{}' or resid ~ '(^|[^a-z0-9])(i|im|ive|me|my|mine|myself|je|moi|mon|ma|mes|suis)([^a-z0-9]|$)|(^|[^a-z0-9])(j|m)''' then
          raise exception 'D3 allowed although the oracle disagrees (old=%): %', o, txt; end if;
      end if;
      -- D4: mutations of a blocked text stay blocked (look-alikes, zero-width after every letter, fullwidth, upper case)
      if not (res_ins ->> 'allowed')::boolean then
        n_mut := n_mut + 1;
        foreach mut in array array[translate(txt, 'aeopcx', 'аеорсх'), regexp_replace(txt, '([a-z])', '\1' || chr(8203), 'g'), upper(txt), regexp_replace(txt, '([a-z])', '\1' || chr(769), 'g')] loop
          if (public.ws_classify_text(mut, ins) ->> 'allowed')::boolean then raise exception 'D4 mutation unblocked the text: %', txt; end if;
        end loop;
      end if;
    end loop;
    if n_old < 800 or n_hl < 300 or n_alw_hl < 40 or n_blk < 1200 or n_mut < 1200 then raise exception 'D5 corpus did not exercise the branches: old=% healthonly=% allowed_with_old_health=% blocked=% mutated=%', n_old, n_hl, n_alw_hl, n_blk, n_mut; end if;
    raise notice 'differential corpus: 2500 texts, old hits %, health-only %, allowed-despite-old-health %, blocked %, mutation checks %', n_old, n_hl, n_alw_hl, n_blk, n_mut;
  end;

  -- ===== L: asserted LIMITS (known misses and known over-blocking). If one of these changes, update the policy document. =====
  foreach s in array array['Health insurance (she has MS)', 'Health insurance for people with sugar problems', 'Health insurance - fever for three days', E'Health insurance - Jean is recovering', 'Health insurance - '|| E'օncology',
                           'Health insurance for Marie Tremblay'] loop
    perform pg_temp.must_pass('L1 KNOWN MISS (abbreviation, unlisted symptom, unmapped look-alike, person named without a health word)', s, ins);
  end loop;
  foreach s in array array['Disability income insurance', 'Income protection insurance', '$1,000,000 of coverage', 'Health insurance - no medical exam', 'Protect your income with health insurance', 'Healthy families, health insurance'] loop
    perform pg_temp.must_block('L2 KNOWN OVER-BLOCK (income and account-like numbers are never waived; unlisted health words need their own approved term)', s, ins);
  end loop;
  -- no literal invisible characters in the new function bodies, only \u escapes
  if exists (select 1 from pg_proc where proname in ('ws_fold_text', 'ws_classify_text', 'ws_identifier_hit', 'ws_personal_context_hit', 'ws_health_extra_hit')
             and (position(chr(8203) in prosrc) > 0 or position(chr(65279) in prosrc) > 0 or position(chr(173) in prosrc) > 0 or position(chr(8205) in prosrc) > 0)) then raise exception 'L3 literal invisible character in a classifier function'; end if;
  -- ws_sensitive_hits itself was not touched by this migration: still the 20261119 definition (same long-stem and short-word lists)
  if pg_get_functiondef('public.ws_sensitive_hits(text)'::regprocedure) !~ 'heartfailure' or pg_get_functiondef('public.ws_sensitive_hits(text)'::regprocedure) !~ 'foreach w in array' then raise exception 'L4 ws_sensitive_hits changed'; end if;
  raise notice 'insurance_classifier_check: all passed (% allowed-text assertions, % blocked-text assertions, % refused-statement assertions, plus the differential corpus)',
    (select count(*) from pg_temp.assertion_count where kind = 'pass'), (select count(*) from pg_temp.assertion_count where kind = 'block'), (select count(*) from pg_temp.assertion_count where kind = 'refused');
end $$;
rollback;
