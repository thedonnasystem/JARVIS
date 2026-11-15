-- SQL-level checks for migrations/20261122_insurance_classifier_v1.sql. SCRATCH replica only. One transaction, rolled back.
-- Sections: G grants/owner-only/validation/audit/immutability, E empty-list behaviour (nothing extra permitted), P permitted marketing, X prohibited personal information,
-- O obfuscation (look-alikes, fullwidth, zero-width, combining marks, spaced letters, leetspeak, mixed language, small caps, circled/squared/mathematical letters, encodings), A adversarial wrappers,
-- F2 sensitive application data without any health word, F3 term and vocabulary management limits, F4 legitimate marketing corpus (100+ sentences), R no regression of earlier categories,
-- T guards on real tables, D deterministic differential corpus (old function vs new classifier), L asserted LIMITS (known misses and known over-blocking, so a change is noticed).
-- Review fixes (PR #17): the waiver is no longer a deny-list. Insurance-context text must consist ONLY of approved terms, vocabulary words, numbers and simple punctuation.
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
declare ins uuid; ins2 uuid; ins4 uuid; other uuid; ca uuid; cb uuid; ads uuid; t text; r text; f text; s text; j jsonb; n int; id1 uuid; id2 uuid; id3 uuid; tid uuid;
begin
  insert into auth.users (id, email) values ('99999999-9999-9999-9999-999999999993', 'classifier-owner@example.com');
  insert into public.app_owners (email) values ('classifier-owner@example.com');
  perform pg_temp.as_owner(true);
  insert into public.client_workspaces (slug, name, vertical, status) values ('ic-ins', 'IC Insurance', 'insurance', 'active') returning id into ins;
  insert into public.client_workspaces (slug, name, vertical, status) values ('ic-ins2', 'IC Insurance Two', 'insurance', 'active') returning id into ins2;
  insert into public.client_workspaces (slug, name, vertical, status) values ('ic-other', 'IC Other', 'mortgage', 'active') returning id into other;
  insert into public.ws_campaigns (workspace_id, name) values (ins, 'Spring promo') returning id into ca;
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
                           'public.ws_identifier_hit(text)', 'public.ws_classify_text(text,uuid)', 'public.ws_add_approved_term(uuid,text,text,text,boolean)', 'public.ws_remove_approved_term(uuid)',
                           'public.ws_guard()', 'public.ffm_guard()', 'public.ws_condition_hit(text)', 'public.ws_vocab_denied(text,boolean)', 'public.ws_residual_check(text,text)', 'public.ws_capitalised_name(text,boolean)', 'public.ws_text_insurance_word(text,text,text)',
                           'public.ws_insurance_context(text,uuid)', 'public.ws_classify_core(text,uuid,boolean,boolean)', 'public.ws_add_vocab_word(text,text)', 'public.ws_remove_vocab_word(uuid)', 'public.ws_place_catalog_immutable()'] loop
    foreach r in array array['anon', 'authenticated'] loop
      if has_function_privilege(r, f, 'execute') then raise exception 'G5 % can execute %', r, f; end if;
    end loop;
    if not has_function_privilege('service_role', f, 'execute') then raise exception 'G6 service_role cannot execute %', f; end if;
  end loop;
  -- the guards stay invoker functions (ops/verify_post_release_executor_ffm.sql counts on it); the classifier is a definer that never writes
  if (select prosecdef from pg_proc where oid = 'public.ws_guard()'::regprocedure) or (select prosecdef from pg_proc where oid = 'public.ffm_guard()'::regprocedure) then raise exception 'G7 a guard became SECURITY DEFINER'; end if;
  if (select count(*) from pg_proc where oid in ('public.ws_classify_text(text,uuid)'::regprocedure, 'public.ws_classify_core(text,uuid,boolean,boolean)'::regprocedure, 'public.ws_insurance_context(text,uuid)'::regprocedure,
        'public.ws_add_approved_term(uuid,text,text,text,boolean)'::regprocedure, 'public.ws_remove_approved_term(uuid)'::regprocedure, 'public.ws_add_vocab_word(text,text)'::regprocedure, 'public.ws_remove_vocab_word(uuid)'::regprocedure)
        and prosecdef and proconfig::text like '%search_path=pg_catalog%') <> 7 then raise exception 'G8 definer functions must pin search_path'; end if;
  if (select count(*) from public.ws_approved_terms) <> 0 then raise exception 'G9 the term table must ship EMPTY'; end if;
  -- vocabulary and catalog: seeded, RLS on, no policy, service_role read-only, never writable by anyone but the owner functions / the migration
  foreach r in array array['public.ws_marketing_vocab', 'public.ws_place_catalog'] loop
    if not (select relrowsecurity from pg_class where oid = r::regclass) then raise exception 'G9b RLS off on %', r; end if;
    if exists (select 1 from pg_policy where polrelid = r::regclass) then raise exception 'G9c policy on %', r; end if;
    foreach t in array array['insert', 'update', 'delete', 'truncate', 'trigger', 'references'] loop
      if has_table_privilege('service_role', r, t) or has_table_privilege('anon', r, t) or has_table_privilege('authenticated', r, t) then raise exception 'G9d % can % on %', 'someone', t, r; end if;
    end loop;
    if not has_table_privilege('service_role', r, 'select') or has_table_privilege('anon', r, 'select') or has_table_privilege('authenticated', r, 'select') then raise exception 'G9e select grants on %', r; end if;
  end loop;
  select count(*) into n from public.ws_marketing_vocab where removed_at is null;
  if n < 300 or n > 1500 then raise exception 'G9f seeded vocabulary size %', n; end if;
  if not exists (select 1 from public.ws_marketing_vocab where lang = 'en') or not exists (select 1 from public.ws_marketing_vocab where lang = 'fr') then raise exception 'G9g vocabulary needs both languages'; end if;
  if exists (select 1 from public.ws_marketing_vocab where public.ws_vocab_denied(word, true)) then raise exception 'G9h seeded vocabulary contains a denied word'; end if;
  -- the vocabulary contains NO person reference, relation, title, narrative, claim or health word (spec list, checked independently of the deny function)
  if exists (select 1 from public.ws_marketing_vocab where word = any (array['client', 'clients', 'patient', 'patients', 'he', 'she', 'his', 'her', 'him', 'mother', 'father', 'wife', 'husband', 'son', 'daughter', 'sister', 'brother', 'mr', 'mrs', 'ms', 'mme', 'dr',
       'has', 'had', 'takes', 'took', 'was', 'lost', 'broke', 'diagnosed', 'claim', 'claims', 'approved', 'denied', 'i', 'me', 'my', 'mine', 'mon', 'ma', 'mes', 'je', 'il', 'elle', 'health', 'cancer', 'diabetes', 'income', 'salary', 'off', 'underwriting', 'cannot', 'unable']))
     then raise exception 'G9i a forbidden word is in the seeded vocabulary'; end if;
  if (select count(*) from public.ws_place_catalog) < 60 or exists (select 1 from public.ws_place_catalog where public.ws_vocab_denied(name_norm, false) and name_norm !~ ' ' and name_norm not in ('peterborough', 'charlottetown')) then raise exception 'G9j place catalog'; end if;
  perform pg_temp.expect_fail($q$update public.ws_place_catalog set display_name = 'x'$q$, 'the place catalog is fixed%');
  perform pg_temp.expect_fail($q$delete from public.ws_place_catalog$q$, 'the place catalog is fixed%');
  perform pg_temp.expect_fail($q$truncate public.ws_place_catalog$q$, 'the place catalog is fixed%');
  perform pg_temp.expect_fail($q$delete from public.ws_marketing_vocab$q$, 'approved terms cannot be edited%');
  perform pg_temp.expect_fail($q$update public.ws_marketing_vocab set word = 'zzz' where word = 'family'$q$, 'approved terms cannot be edited%');

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
  foreach s in array array['Life insurance quote', 'Assurance vie pour les familles', 'Spring campaign'] loop
    perform pg_temp.must_pass('E4', s, ins);
  end loop;
  -- a non-insurance workspace (mortgage) keeps the previous behaviour for these
  foreach s in array array['Term 20 coverage', 'Call 613-555-0142 about a renewal', 'Mortgage rates - privacy policy', 'Title insurance included', 'Home insurance requirement for your mortgage',
                           'Mortgage default insurance explained for first-time buyers'] loop
    perform pg_temp.must_pass('E4m', s, other);
  end loop;
  perform pg_temp.must_pass('E5 null', null, ins);
  perform pg_temp.must_pass('E5 empty', '   ', ins);

  -- validation: refusals never echo the term
  foreach s in array array['x1', 'a b', 'health insurance 2026', 'health insurance!', 'health@insurance', 'cancer', 'health', 'my health insurance', 'j''ai une assurance santé', 'bank account insurance',
                           'credit score insurance', 'passport cover', 'health card plan', repeat('health insurance ', 5), 'insurance'] loop
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
  perform public.ws_add_approved_term(ins, null, 'place', 'Ottawa');
  if (select term_norm from public.ws_approved_terms where id = id1) <> 'health insurance' or (select term_norm from public.ws_approved_terms where id = id2) <> 'assurance invalidite' then raise exception 'G11 normalisation'; end if;
  if not exists (select 1 from public.ws_approved_terms where term_norm = 'assurance sante') or not exists (select 1 from public.ws_approved_terms where term_norm = 'assurance d''invalidite') then raise exception 'G11b hyphen/apostrophe normalisation'; end if;
  perform pg_temp.expect_fail(format($q$select public.ws_add_approved_term(%L, null, 'product', 'HEALTH INSURANCE')$q$, ins), 'term already approved%');
  -- audit: actor, ids and counts, never the term text
  select count(*) into n from public.audit_log where action = 'ws_approved_term_added' and target = 'workspace/' || ins;
  if n <> 8 then raise exception 'G12 audit rows: %', n; end if;
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
                           'Compare health insurance and life insurance', 'Health insurance for ages 18-65, trusted by over ten thousand families', 'Health insurance with 24/7 support for over ten thousand families', 'Health insurance. Learn more.',
                           'Disability insurance' || ' ' , 'Assurance d''invalidité pour les travailleurs autonomes', 'Assurance d’invalidité pour les travailleurs autonomes',
                           'Health insurance in Medicine Hat', 'Medicine Hat office open Monday to Friday', 'Monday - Friday: Medicine Hat', 'Critical illness insurance covers you. Health insurance covers your family.',
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
  perform pg_temp.expect_fail($q$select public.ws_add_approved_term(null, 'insurance', 'product', 'Disability insurance')$q$, 'term refused: a vertical-wide approval needs confirm_vertical%');
  perform pg_temp.expect_fail($q$select public.ws_add_approved_term(null, 'insurance', 'product', 'Disability insurance', false)$q$, 'term refused: a vertical-wide approval needs confirm_vertical%');
  tid := public.ws_add_approved_term(null, 'insurance', 'product', 'Disability insurance', true);
  if not exists (select 1 from public.audit_log where action = 'ws_approved_term_added' and detail ->> 'term_id' = tid::text and (detail ->> 'vertical_wide')::boolean) then raise exception 'P5a vertical-wide approval not audit-logged as such'; end if;
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
  tid := public.ws_add_approved_term(null, 'insurance', 'product', 'Disability insurance', true);   -- re-adding after removal is allowed (unique index is on ACTIVE rows)
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
  perform pg_temp.must_block('O3c mixed script is refused even when no health word is visible', 'Health insurance αβγ', ins, 'mixed_script');

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
                           'Choose health insurance that fits your budget: $25, $40 or $60 per month', 'Health insurance - plans from 25$/mois, 100% online', 'Health insurance, 24/7, five stars from reviews'] loop
    if s like '%no medical exam%' then
      perform pg_temp.must_block('A2 (words outside the approved list stay refused)', s, ins);   -- 'medical' is health wording: only an approved feature phrase can carry it
    else perform pg_temp.must_pass('A2', s, ins); end if;   -- 'protect your income' passes: generic second-person income with no amount
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
  ads := public.ffm_add_ad_set(ins, ca, 'Ottawa families', 'families who want health insurance', null);   -- Ottawa is an approved place
  perform public.ffm_add_creative(ins, ca, ads, 'Protect your family with health insurance', 'Critical illness insurance from $25/month. Assurance invalidité pour les travailleurs autonomes.', 'Get a quote');
  perform public.ffm_add_campaign(ins, 'Health insurance spring campaign', 'meta');
  insert into public.ws_ledger (workspace_id, amount_cents, note) values (ins, 100, 'Health insurance ad budget');
  insert into public.ffm_approvals (workspace_id, kind, approved_by, note) values (ins, 'campaign', 'owner', 'Health insurance copy');
  -- refused: not approved here / personal / identifier / split across columns
  perform pg_temp.expect_fail(format($q$select public.ffm_add_creative(%L, %L, %L, 'Health insurance', 'my sister was diagnosed with cancer')$q$, ins, ca, ads), 'Sensitive data refused%health%');
  perform pg_temp.expect_fail(format($q$select public.ffm_add_creative(%L, %L, %L, 'Health insurance', 'Get a quote', '613-555-0100')$q$, ins, ca, ads), 'Sensitive data refused%identifier%');   -- identifier only visible when columns are joined
  perform pg_temp.expect_fail(format($q$select public.ffm_add_creative(%L, %L, %L, 'Critical illness plan', 'Quote today')$q$, ins, ca, ads), 'Sensitive data refused%no_approved_term%') ;
  begin perform public.ffm_add_creative(ins, ca, ads, 'Health insurance', 'I have diabetes'); raise exception 'T1 accepted';
  exception when raise_exception then if sqlerrm like 'T1%' then raise; end if; if sqlerrm ~* 'diabetes|have' then raise exception 'T1b the refusal message echoes the text: %', sqlerrm; end if; end;
  perform pg_temp.expect_fail(format($q$update public.ffm_creatives set body = 'my diabetes and health insurance' where workspace_id = %L$q$, ins), 'Sensitive data refused%');
  perform pg_temp.expect_fail(format($q$update public.ws_campaigns set name = 'Health insurance - my claim' where id = %L$q$, ca), 'Sensitive data refused%');
  perform pg_temp.expect_fail(format($q$insert into public.ws_ledger (workspace_id, amount_cents, note) values (%L, 5, 'Health insurance, claim for her surgery')$q$, ins), 'Sensitive data refused%');
  perform pg_temp.expect_fail(format($q$insert into public.ffm_approvals (workspace_id, kind, approved_by, note) values (%L, 'campaign', 'owner', 'health insurance - he was diagnosed')$q$, ins), 'Sensitive data refused%');
  -- other workspaces are not helped by this workspace's terms
  perform pg_temp.expect_fail(format($q$select public.ffm_add_campaign(%L, 'Health insurance spring campaign')$q$, other), 'Sensitive data refused%no_approved_term%');
  perform pg_temp.expect_fail(format($q$select public.ffm_add_campaign(%L, 'Health insurance spring campaign')$q$, ins2), 'Sensitive data refused%no_approved_term%');
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
  perform pg_temp.expect_fail(format($q$update public.ws_campaigns set channel = 'meta' where id = (select id from public.ws_campaigns where name = 'Health insurance spring campaign')$q$), 'Sensitive data refused%no_approved_term%');


  -- ===== D: deterministic differential corpus: OLD ws_sensitive_hits (unchanged) vs NEW ws_classify_text =====
  perform public.ws_add_approved_term(ins, null, 'product', 'Health insurance');
  declare
    vocab text[] := array['diabetes', 'cancer', 'diagnosed', 'prescribed', 'surgery', 'my doctor', 'heart', 'medication', 'tumour', 'hospital', 'depression', 'pregnant', 'disability', 'illness', 'diabète', 'maladie', 'chirurgie', 'médecin',
                          'j''ai le diabète', 'cœur', 'santé', 'invalidité', 'enceinte', 'health insurance', 'Health Insurance', 'HEALTH INSURANCE', 'assurance invalidité', 'Assurance Invalidité', 'critical illness insurance', 'life insurance',
                          'disability insurance', 'Medicine Hat', 'Protect your family with', 'Get a quote for', 'from $25/month', 'for self-employed workers', 'ages 18-65', 'since 1995', 'over ten thousand families',
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
        for tn in select phrase_norm from public.ws_fixed_phrases where removed_at is null loop      -- the owner-approved fixed phrases are cut the same way (a plain 'mon fri' is not the French 'my')
          resid := regexp_replace(resid, '(^|[^a-z0-9])' || replace(tn, ' ', '[ \-]+') || '([^a-z0-9]|$)', '\1 zzqxp \2', 'g');
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

  -- ===== F1: every CONFIRMED passing example of the review (deny-list bypass) is now refused. Approved terms are present, the wording is third person / unlisted. =====
  foreach s in array array['Health insurance: client has lupus',
                           'Health insurance client takes Lipitor',
                           'Health insurance client takes Ozempic',
                           'Health insurance client takes Xanax',
                           'Health insurance client takes metformin',
                           'Health insurance client has chest pain',
                           'Health insurance client has sciatica',
                           'Health insurance client has hepatitis',
                           'Health insurance client has herpes',
                           'Health insurance client has an STD',
                           'Health insurance client is blind',
                           'Health insurance client is paralyzed',
                           'Health insurance client is dying',
                           'Health insurance client is unwell',
                           'Health insurance client lost a leg',
                           'Health insurance client had a hysterectomy',
                           'Disability insurance: she broke her leg',
                           'Disability insurance for Maria Gonzalez, who cannot walk',
                           'Disability insurance: off work',
                           'Health insurance kanser',
                           'Health insurance Krebs',
                           'Assurance santé TSPT',
                           'Health insurance BPCO',
                           'Health insurance cerebral palsy',
                           'Health insurance burnout',
                           'Health insurance metastatic',
                           'Health insurance carcinoma',
                           'Health insurance A1C',
                           'Health insurance BP 150/95',
                           'Mr. Tremblay has health insurance',
                           'The client''s husband bought disability insurance',
                           'Health insurance, her income is 60000',
                           'Health insurance for dia' || ' health insurance ' || 'betes', 'Health insurance: c health insurance ancer', 'Health insurance - is on ODSP', 'Health insurance is on ODSP', 'Disability insurance - claim approved',
                           'Assurance santé. Le client est séropositif', 'Health insurance: ' || chr(1587) || chr(1585) || chr(1591) || chr(1575) || chr(1606), 'Health insurance: ' || chr(1605) || chr(1589) || chr(1575) || chr(1576) || ' ' || chr(1576) || chr(1575) || chr(1604) || chr(1587) || chr(1585) || chr(1591) || chr(1575) || chr(1606),
                           'Health insurance ' || chr(30284), 'Health insurance ' || chr(2350) || chr(2343) || chr(2369) || chr(2350) || chr(2375) || chr(2361)] loop
    perform pg_temp.must_block('F1', s, ins);
  end loop;
  perform pg_temp.must_block('F1 reason code only, never the text', 'Health insurance: client has lupus', ins, 'unknown_word');
  if pg_temp.codes('Health insurance: client has lupus', ins) ~* 'lupus|client' then raise exception 'F1b reasons echo the text'; end if;
  perform pg_temp.must_block('F1c script', 'Health insurance ' || chr(30284), ins, 'non_latin_script');
  perform pg_temp.must_block('F1d mixed script', 'Health insurance ' || chr(30284) || 'abc', ins, 'mixed_script');

  -- ===== F2: sensitive insurance APPLICATION data with no health word at all, and identifiers without a health word =====
  foreach s in array array['Life insurance application for Jean Tremblay is pending underwriting',
                           'Life insurance: beneficiary is his wife Marie',
                           'Life insurance client was rated table 4 by underwriting',
                           'Life insurance client answered yes to question 7',
                           'Life insurance policy for Jean Tremblay lapsed',
                           'Life insurance quote call 613-555-0100',
                           'Life insurance quote jean@example.com',
                           'Life insurance quote K1A 0B1',
                           'Life insurance quote 123 Main Street',
                           'Life insurance quote 12/03/1985',
                           'Life insurance my income is high',
                           'Life insurance income of $5,000',
                           'Life insurance &#x63;ancer',
                           'Life insurance Y2FuY2Vy',
                           'Life insurance %63ancer',
                           'Life insurance canc=er',
                           'Life insurance ᴄᴀɴᴄᴇʀ',
                           'Life insurance 🄲🄰🄽🄲🄴🄷',
                           'Life insurance ⓒⓐⓝⓒⓔⓡ',
                           'Life insurance 𝐜𝐚𝐧𝐜𝐞𝐫',
                           'Life insurance ｃａｎｃｅｒ',
                           'Life insurance ¢ancer',
                           'Life insurance dia8etes',
                           'Life insurance recnac',
                           'Life insurance diabetis',
                           'Life insurance cancre',
                           'Life insurance hartattack',
                           'Life insurance for people with diabetes',
                           'Life insurance for pregnant women',
                           'Life insurance for john smith',
                           'Life insurance, my husband''s cancer',
                           'Life insurance. Mon père est décédé',
                           'Life insurance. I am a smoker',
                           'Life insurance application for Jean Tremblay is pending underwriting', 'Life insurance: beneficiary is his wife Marie', 'The client''s husband bought disability insurance', 'policy for Jean Tremblay lapsed',
                           'Mr. Tremblay has health insurance', 'Life insurance: client was rated table 4 by underwriting', 'Mme Tremblay a une assurance vie', 'Assurance vie pour Jean Tremblay',
                           'Life insurance quote, phone 613 555 0100', 'Life insurance quote (613) 555-0100', 'Life insurance quote, email jean at example dot com', 'Life insurance quote, postal code K1A0B1',
                           'Life insurance quote, 45 Elm Street', 'Life insurance quote, age 45, born 1980', 'Life insurance quote DOB 12-03-1985', 'Life insurance for a 45 year old male'] loop
    perform pg_temp.must_block('F2', s, ins);
  end loop;
  -- the strict (no workspace) screen is the old behaviour: no insurance vocabulary test on person tables or for callers without a workspace
  perform pg_temp.must_pass('F2b strict/no-workspace behaviour is the old behaviour (no insurance vocabulary test)', 'Life insurance application for Jean Tremblay is pending underwriting', null);
  perform pg_temp.must_block('F2c same text in an insurance workspace', 'Life insurance application for Jean Tremblay is pending underwriting', ins, 'unknown_word');
  perform pg_temp.must_pass('F2c2 in a MORTGAGE workspace an insurance word does not start the vocabulary test (no regression)', 'Life insurance application for Jean Tremblay is pending underwriting', other);
  -- non-insurance text: unchanged (identifiers and unknown words are not refused without insurance context)
  perform pg_temp.must_pass('F2d non-insurance identifiers unchanged', 'Call 613-555-0142 about a renewal in March', other);
  perform pg_temp.must_pass('F2e non-insurance text with unknown words unchanged (other vertical)', 'Spring campaign: Barrhaven snow removal flyers', other);
  perform pg_temp.must_block('F2e2 the same words in an INSURANCE workspace are unknown words', 'Spring campaign: Barrhaven snow removal flyers', ins, 'unknown_word');

  -- ===== F3: term and vocabulary management: what an owner cannot approve =====
  foreach s in array array['cancer insurance', 'diabetes coverage', 'insurance for people with cancer', 'life insurance for people with diabetes', 'hiv coverage', 'insurance for her mother', 'insurance for john smith',
                           'Jean Tremblay insurance', 'dr smith plan', 'insurance for pregnant women', 'cover for seniors with dementia', 'lupus insurance', 'burnout coverage', 'heart attack insurance', 'stroke insurance plan',
                           'insurance for smokers', 'life insurance for men', 'pour les personnes atteintes assurance', 'assurance pour les patients', 'insurance for my family', 'client insurance', 'patient plan', 'insurance for clients',
                           'insurance for amputees', 'insurance for veterans zzz', 'insurance for the claim', 'death insurance claim', 'a1c insurance', 'insurance for ms patients', 'maria gonzalez insurance'] loop
    begin perform public.ws_add_approved_term(ins2, null, 'product', s); raise exception 'F3 accepted product term: %', s;
    exception when raise_exception then if sqlerrm like 'F3%' then raise; end if; if position(s in sqlerrm) > 0 then raise exception 'F3b refusal echoes the term: %', sqlerrm; end if; end;
  end loop;
  foreach s in array array['cancer', 'diabetes', 'hiv', 'mother', 'Jean Tremblay', 'heart attack', 'Atlantis', 'Ottawa Cancer Centre', 'my city', 'Toronto and Ottawa', 'john smith', 'a b', 'Ottawa1'] loop
    begin perform public.ws_add_approved_term(ins2, null, 'place', s); raise exception 'F3 accepted place: %', s;
    exception when raise_exception then if sqlerrm like 'F3%' then raise; end if; if position(s in sqlerrm) > 0 and length(s) > 6 then raise exception 'F3c refusal echoes the place: %', sqlerrm; end if; end;
  end loop;
  foreach s in array array['cancer', 'my cancer', 'client with cancer', 'for people with cancer', 'cover for seniors with dementia', 'john smith heart attack', 'his heart attack', 'diagnosed with cancer', 'pregnant women', 'mother has cancer',
                           'her stroke', 'heart attack and zzzz', 'maria has diabetes', 'patients with heart attack', 'survivors of stroke', 'the claim for stroke'] loop
    begin perform public.ws_add_approved_term(ins2, null, 'feature', s); raise exception 'F3 accepted feature: %', s;
    exception when raise_exception then if sqlerrm like 'F3%' then raise; end if; if position(s in sqlerrm) > 0 and length(s) > 6 then raise exception 'F3d refusal echoes the feature: %', sqlerrm; end if; end;
  end loop;
  -- accepted: generic product names, a catalog place, generic feature phrases
  foreach s in array array['income protection', 'disability income insurance', 'income protection insurance', 'critical illness cover', 'extended health coverage', 'group benefits', 'travel insurance', 'long term care insurance',
                           'term life insurance', 'assurance maladie grave', 'assurance vie temporaire', 'accidental death insurance'] loop
    perform public.ws_add_approved_term(ins2, null, 'product', s);
  end loop;
  perform public.ws_add_approved_term(ins2, null, 'place', 'St Albert');
  perform public.ws_add_approved_term(ins2, null, 'place', 'Quebec City');
  perform public.ws_add_approved_term(ins2, null, 'feature', 'heart attack, stroke and cancer');
  perform public.ws_add_approved_term(ins2, null, 'feature', 'Non-smokers');
  perform public.ws_add_approved_term(ins2, null, 'feature', 'no medical exam');
  -- income: only the whole word 'income' inside a product / feature phrase; never a place; never with another income stem
  perform pg_temp.expect_fail(format($q$select public.ws_add_approved_term(%L, null, 'place', 'income')$q$, ins2), 'term refused%');
  perform pg_temp.expect_fail(format($q$select public.ws_add_approved_term(%L, null, 'product', 'salary protection insurance')$q$, ins2), 'term refused%');
  perform pg_temp.expect_fail(format($q$select public.ws_add_approved_term(%L, null, 'product', 'income verification insurance')$q$, ins2), 'term refused%');
  perform pg_temp.expect_fail(format($q$select public.ws_add_approved_term(%L, null, 'product', 'net worth insurance')$q$, ins2), 'term refused%');
  -- vertical-wide approval needs the confirm flag
  perform pg_temp.expect_fail($q$select public.ws_add_approved_term(null, 'insurance', 'feature', 'heart attack, stroke and cancer')$q$, 'term refused: a vertical-wide approval needs confirm_vertical%');
  -- vocabulary management: owner-only, charset-limited, hard deny list, audit without the word, soft removal only
  perform pg_temp.as_owner(false);
  perform pg_temp.expect_fail($q$select public.ws_add_vocab_word('en', 'zebra')$q$, 'owner approval required%');
  perform pg_temp.expect_fail(format($q$select public.ws_remove_vocab_word(%L)$q$, (select id from public.ws_marketing_vocab where word = 'family')), 'owner approval required%');
  perform pg_temp.as_owner(true);
  foreach s in array array['client', 'clients', 'patient', 'he', 'she', 'his', 'her', 'him', 'mother', 'father', 'wife', 'husband', 'son', 'daughter', 'sister', 'brother', 'mr', 'mrs', 'ms', 'mme', 'dr', 'has', 'had', 'takes', 'took', 'was',
                           'lost', 'broke', 'diagnosed', 'claim', 'approved', 'denied', 'cancer', 'diabetes', 'hiv', 'lupus', 'heart', 'smoker', 'chemo', 'pregnant', 'mon', 'ma', 'ses', 'il', 'elle', 'malade', 'atteint', 'income', 'salary',
                           'hospital', 'pills', 'surgery', 'doctor', 'ODSP', 'underwriting', 'deceased', 'sida', 'vih', 'cancereux', 'zz1', 'two words', 'a', 'x' || chr(8203) || 'y', 'caf' || chr(233) || '!'] loop
    begin perform public.ws_add_vocab_word('en', s); raise exception 'F3 accepted vocabulary word: %', s;
    exception when raise_exception then if sqlerrm like 'F3%' then raise; end if; if position(s in sqlerrm) > 0 and length(s) > 3 then raise exception 'F3e refusal echoes the word: %', sqlerrm; end if; end;
  end loop;
  perform pg_temp.expect_fail($q$select public.ws_add_vocab_word('de', 'zebra')$q$, 'word refused: language%');
  perform pg_temp.expect_fail($q$select public.ws_add_vocab_word('en', 'family')$q$, 'word already in the vocabulary%');
  id1 := public.ws_add_vocab_word('en', 'Zebra');
  id2 := public.ws_add_vocab_word('fr', 'Revenue');
  if not exists (select 1 from public.ws_marketing_vocab where id = id1 and word = 'zebra' and lang = 'en') then raise exception 'F3f vocabulary word not stored normalised'; end if;
  if exists (select 1 from public.audit_log where action in ('ws_vocab_word_added', 'ws_vocab_word_removed') and detail::text ~* 'zebra|revenue') then raise exception 'F3g vocabulary word in the audit log'; end if;
  perform pg_temp.must_pass('F3h a vocabulary word added by the owner works at once', 'Life insurance zebra', ins);
  perform public.ws_remove_vocab_word(id1);
  perform pg_temp.must_block('F3i a removed word stops working at once', 'Life insurance zebra', ins, 'unknown_word');
  perform pg_temp.expect_fail(format($q$select public.ws_remove_vocab_word(%L)$q$, id1), 'vocabulary word not found%');
  perform pg_temp.expect_fail(format($q$update public.ws_marketing_vocab set word = 'zebra2' where id = %L$q$, id2), 'approved terms cannot be edited%');
  if (select count(*) from public.audit_log where action = 'ws_vocab_word_added') <> 2 or (select count(*) from public.audit_log where action = 'ws_vocab_word_removed') <> 1 then raise exception 'F3j vocabulary audit rows'; end if;
  -- the bot (service_role) cannot grow the vocabulary or the terms: it has select only
  foreach s in array array['insert into public.ws_marketing_vocab (lang, word) values (''en'', ''zebra'')', 'delete from public.ws_marketing_vocab', 'insert into public.ws_approved_terms (vertical, kind, term, term_norm, vertical_confirmed) values (''x1'', ''product'', ''health insurance'', ''health insurance'', true)'] loop
    begin set local role service_role; execute s; reset role; raise exception 'F3k service_role wrote: %', s;
    exception when insufficient_privilege then reset role; end;
  end loop;

  -- ===== F4: LEGITIMATE marketing corpus (English and French). Every sentence passes once the matching product terms, feature phrases, places and vocabulary are approved. =====
  insert into public.client_workspaces (slug, name, vertical, status) values ('ic-ins4', 'IC Insurance Four', 'insurance', 'active') returning id into ins4;
  foreach s in array array['health insurance', 'disability insurance', 'critical illness insurance', 'life insurance', 'income protection insurance', 'assurance santé', 'assurances santé', 'assurance d’invalidité', 'assurance invalidité', 'assurance maladie grave',
                           'assurance vie', 'assurance collective', 'assurance voyage', 'critical illness cover', 'extended health coverage', 'group benefits', 'dental insurance', 'travel insurance', 'long term care insurance', 'term life insurance',
                           'whole life insurance', 'universal life insurance', 'health insurance plans', 'mortgage life insurance', 'assurance vie temporaire', 'health coverage', 'disability income insurance', 'income protection'] loop
    perform public.ws_add_approved_term(ins4, null, 'product', s);
  end loop;
  foreach s in array array['heart attack, stroke and cancer', 'non smokers', 'no medical exam', 'non fumeurs', 'examen médical'] loop perform public.ws_add_approved_term(ins4, null, 'feature', s); end loop;
  foreach s in array array['Ottawa', 'Toronto', 'Calgary', 'Medicine Hat', 'Gatineau'] loop perform public.ws_add_approved_term(ins4, null, 'place', s); end loop;
  n := 0;
  for s in select l from regexp_split_to_table($corpus$Canada's #1 health insurance broker
Health insurance in 1 minute
1 in 3 Canadians need disability insurance
Health insurance Option #1
Health Insurance | Life Insurance
Health insurance @ $25/mo
Disability insurance can cover up to 70% of your income
Disability insurance replaces part of your income
Income protection insurance
Critical illness insurance pays a lump sum
Critical illness insurance covers heart attack, stroke and cancer
Life insurance for non-smokers
Protect your family with health insurance
Get a free quote for life insurance today
Compare health insurance plans in minutes
Health insurance from $25/month
Affordable life insurance for families
Life insurance starting at $19.99 per month
Critical illness insurance: protect your family and your future
Disability insurance for self-employed workers
Term life insurance, whole life insurance and universal life insurance
Book a call to learn more about disability insurance
Health insurance for freelancers in Ottawa and Medicine Hat
Travel insurance for your next trip
Group benefits for your business and your employees
Extended health coverage for your family
Choose health insurance that fits your budget: $25, $40 or $60 per month
Health insurance with 24/7 support
Health insurance, trusted by over ten thousand families
Health insurance, five stars from reviews
Get a quote in 2 minutes. No obligation.
No medical exam life insurance
Life insurance from $15 a month for ages 18-65
Health insurance, 100% online
Save up to 30% on life insurance
Talk to a licensed advisor about disability insurance
Your family deserves protection: get life insurance today
Learn how disability insurance works
Disability insurance for business owners and professionals
Long term care insurance for seniors
Dental insurance for you and your family
Health insurance plans for individuals and groups
Critical illness cover: a lump sum, tax free
Life insurance that grows with your family
Disability insurance. Simple. Fast. Affordable.
Health insurance for students and young professionals
Switch to better health insurance and save
Health insurance quotes in Toronto, Calgary and Ottawa
Life insurance riders: add more protection to your plan
Mortgage life insurance for your home
Disability insurance helps pay your bills
Join thousands of Canadians with life insurance
Licensed advisors compare plans from top insurers
Health insurance made simple: just a call
Free quote, no obligation: health insurance for your business
Same day quotes for life insurance
Health insurance coverage that follows you across Canada
Life insurance, disability insurance and critical illness insurance in the same place
Why wait? Get life insurance today
Visit the Ottawa office: Monday to Friday
Health insurance. Because your family comes first.
Assurance santé pour toute la famille
Assurances santé
Assurance maladie grave
Assurance maladie grave : protégez votre famille
Assurance invalidité pour les travailleurs autonomes
Assurance d'invalidité : protégez votre revenu
Assurance vie pour les familles
Assurance vie temporaire à partir de 15 $ par mois
Obtenez une soumission gratuite aujourd'hui
Comparez les assurances santé en quelques minutes
Protégez votre famille avec l'assurance vie
Assurance santé : un appel suffit
Assurance collective pour votre entreprise et vos employés
Assurance voyage pour votre prochain voyage
Assurance santé dès 25 $ par mois
Réservez un appel gratuit avec un conseiller
Assurance santé pour les travailleurs autonomes à Ottawa et à Gatineau
Assurance invalidité : jusqu'à 70 % de votre revenu
Assurance maladie grave : un montant forfaitaire
Assurance vie sans examen médical
Meilleure assurance santé au Canada
Obtenez votre soumission d'assurance vie en 2 minutes
Assurance santé, assurance vie, assurance invalidité : tout au même endroit
Des conseillers agréés à votre service
Assurance santé | Assurance vie
Assurance santé à partir de 25 $/mois
Un appel suffit pour comparer les assurances
Protégez ce qui compte le plus avec l'assurance invalidité
Assurance vie pour les non-fumeurs
Découvrez les assurances santé et vie
Assurance santé : aucune obligation
Assurance collective pour les petites entreprises
Votre famille mérite une protection : assurance vie dès aujourd'hui
Assurance invalidité, assurance maladie grave et assurance vie
Demandez une soumission d'assurance santé
Assurance santé pour tous les budgets
Une assurance vie qui grandit avec votre famille
Assurance vie : protégez votre famille
Life insurance for non-smokers
Critical illness insurance pays a lump sum
Health insurance for your whole family, from $99 a month
Life insurance in Toronto, Ottawa and Calgary
Disability insurance in Calgary
Group benefits for small businesses in Ottawa
Get covered today with health insurance
Talk to an advisor about long term care insurance
Compare term life insurance and whole life insurance
Health insurance plans with no obligation
Assurance voyage pour toute la famille
Assurance santé à Toronto et à Calgary
Assurance vie : obtenez une soumission en 2 minutes
Assurance collective : avantages pour vos employés
Health insurance deals for freelancers
Life insurance quotes in 2 minutes, no obligation
Disability insurance for professionals and business owners in Gatineau$corpus$, E'\n') l where btrim(l) <> '' loop
    n := n + 1;
    perform pg_temp.must_pass('F4 legit sentence', s, ins4);
  end loop;
  if n < 100 then raise exception 'F4 corpus too small: %', n; end if;
  raise notice 'legit corpus: % sentences, all pass with their approved terms/features/vocabulary', n;
  -- the same health-product sentences WITHOUT any approval (a workspace of another vertical) are all refused
  n := 0;
  for s in select l from regexp_split_to_table($corpus$Canada's #1 health insurance broker
Health insurance in 1 minute
1 in 3 Canadians need disability insurance
Health insurance Option #1
Health Insurance | Life Insurance
Health insurance @ $25/mo
Disability insurance can cover up to 70% of your income
Disability insurance replaces part of your income
Income protection insurance
Critical illness insurance pays a lump sum
Critical illness insurance covers heart attack, stroke and cancer
Life insurance for non-smokers
Protect your family with health insurance
Get a free quote for life insurance today
Compare health insurance plans in minutes
Health insurance from $25/month
Affordable life insurance for families
Life insurance starting at $19.99 per month
Critical illness insurance: protect your family and your future
Disability insurance for self-employed workers
Term life insurance, whole life insurance and universal life insurance
Book a call to learn more about disability insurance
Health insurance for freelancers in Ottawa and Medicine Hat
Travel insurance for your next trip
Group benefits for your business and your employees
Extended health coverage for your family
Choose health insurance that fits your budget: $25, $40 or $60 per month
Health insurance with 24/7 support
Health insurance, trusted by over ten thousand families
Health insurance, five stars from reviews
Get a quote in 2 minutes. No obligation.
No medical exam life insurance
Life insurance from $15 a month for ages 18-65
Health insurance, 100% online
Save up to 30% on life insurance
Talk to a licensed advisor about disability insurance
Your family deserves protection: get life insurance today
Learn how disability insurance works
Disability insurance for business owners and professionals
Long term care insurance for seniors
Dental insurance for you and your family
Health insurance plans for individuals and groups
Critical illness cover: a lump sum, tax free
Life insurance that grows with your family
Disability insurance. Simple. Fast. Affordable.
Health insurance for students and young professionals
Switch to better health insurance and save
Health insurance quotes in Toronto, Calgary and Ottawa
Life insurance riders: add more protection to your plan
Mortgage life insurance for your home
Disability insurance helps pay your bills
Join thousands of Canadians with life insurance
Licensed advisors compare plans from top insurers
Health insurance made simple: just a call
Free quote, no obligation: health insurance for your business
Same day quotes for life insurance
Health insurance coverage that follows you across Canada
Life insurance, disability insurance and critical illness insurance in the same place
Why wait? Get life insurance today
Visit the Ottawa office: Monday to Friday
Health insurance. Because your family comes first.
Assurance santé pour toute la famille
Assurances santé
Assurance maladie grave
Assurance maladie grave : protégez votre famille
Assurance invalidité pour les travailleurs autonomes
Assurance d'invalidité : protégez votre revenu
Assurance vie pour les familles
Assurance vie temporaire à partir de 15 $ par mois
Obtenez une soumission gratuite aujourd'hui
Comparez les assurances santé en quelques minutes
Protégez votre famille avec l'assurance vie
Assurance santé : un appel suffit
Assurance collective pour votre entreprise et vos employés
Assurance voyage pour votre prochain voyage
Assurance santé dès 25 $ par mois
Réservez un appel gratuit avec un conseiller
Assurance santé pour les travailleurs autonomes à Ottawa et à Gatineau
Assurance invalidité : jusqu'à 70 % de votre revenu
Assurance maladie grave : un montant forfaitaire
Assurance vie sans examen médical
Meilleure assurance santé au Canada
Obtenez votre soumission d'assurance vie en 2 minutes
Assurance santé, assurance vie, assurance invalidité : tout au même endroit
Des conseillers agréés à votre service
Assurance santé | Assurance vie
Assurance santé à partir de 25 $/mois
Un appel suffit pour comparer les assurances
Protégez ce qui compte le plus avec l'assurance invalidité
Assurance vie pour les non-fumeurs
Découvrez les assurances santé et vie
Assurance santé : aucune obligation
Assurance collective pour les petites entreprises
Votre famille mérite une protection : assurance vie dès aujourd'hui
Assurance invalidité, assurance maladie grave et assurance vie
Demandez une soumission d'assurance santé
Assurance santé pour tous les budgets
Une assurance vie qui grandit avec votre famille
Assurance vie : protégez votre famille
Life insurance for non-smokers
Critical illness insurance pays a lump sum
Health insurance for your whole family, from $99 a month
Life insurance in Toronto, Ottawa and Calgary
Disability insurance in Calgary
Group benefits for small businesses in Ottawa
Get covered today with health insurance
Talk to an advisor about long term care insurance
Compare term life insurance and whole life insurance
Health insurance plans with no obligation
Assurance voyage pour toute la famille
Assurance santé à Toronto et à Calgary
Assurance vie : obtenez une soumission en 2 minutes
Assurance collective : avantages pour vos employés
Health insurance deals for freelancers
Life insurance quotes in 2 minutes, no obligation
Disability insurance for professionals and business owners in Gatineau$corpus$, E'\n') l where btrim(l) ~* 'health|disab|illness|sant|invalid|maladie|medical|heart' loop
    if pg_temp.ok(s, other) then n := n + 1; end if;
  end loop;
  if n > 0 then raise exception 'F4b % health-product sentences pass without any approval', n; end if;

  -- ===== O2: obfuscation and encodings of health words next to approved terms (small caps, squared/circled/mathematical letters, 8-for-b, cent sign, RTL override, reversed, entities, base64, percent-encoding, misspellings) =====
  foreach s in array array['Health insurance ' || chr(7424) || chr(665) || chr(7428) || chr(7429) || chr(7431) || chr(640), 'Health insurance ' || chr(127314) || chr(127312) || chr(127325) || chr(127314) || chr(127316) || chr(127319),
                           'Health insurance ' || chr(9426) || chr(9424) || chr(9437) || chr(9426) || chr(9428) || chr(9441), 'Health insurance ' || chr(120264) || chr(120250) || chr(120263) || chr(120252) || chr(120254) || chr(120267),
                           'Health insurance ' || chr(65347) || chr(65345) || chr(65358) || chr(65347) || chr(65349) || chr(65362), 'Health insurance ' || chr(162) || 'ancer', 'Health insurance dia8etes', 'Health insurance 8reast cancer',
                           'Health insurance ' || chr(8238) || 'recnac', 'Health insurance recnac', 'Health insurance rebateid', 'Health insurance diabetis', 'Health insurance cancre', 'Health insurance hartattak', 'Health insurance dyabetes',
                           'Health insurance &#99;ancer', 'Health insurance &amp; more', 'Health insurance &lt;b&gt;', 'Health insurance Y2FuY2Vy', 'Health insurance Y2FuY2Vy==', 'Health insurance %63ancer', 'Health insurance %20%20',
                           'Health insurance \x63ancer', 'Health insurance cancer', 'Health insurance c&#x61;ncer', 'Health insurance = cancer', 'Health insurance ZGlhYmV0ZXM', 'Health insurance q1w2e3r4t5y6u7i8',
                           'Health insurance Q&A', 'Health insurance #cancer', 'Health insurance @cancer', 'Health insurance cancer@', 'Health insurance a%', 'Health insurance 5%63', 'Health insurance 24/ 7/ 365 150/95 bp'] loop
    perform pg_temp.must_block('O2', s, ins);
  end loop;
  -- digits and symbols standing alone are NOT leetspeak any more (review false positives), but inside a word they still are
  foreach s in array array['Canada''s #1 health insurance broker', 'Health insurance in 1 minute', '1 in 3 Canadians need disability insurance', 'Health insurance Option #1', 'Health Insurance | Life Insurance', 'Assurance santé: 1 in 3 canadiens', 'Health insurance @ $25/mo'] loop
    perform pg_temp.must_pass('O3 stand-alone numeral or separator', s, ins4);
  end loop;
  if public.ws_leet_text('option 1 | a @ b #1 $25', 1) <> 'option 1 | a @ b #1 $25' or public.ws_leet_text('d1abetes', 1) <> 'diabetes' or public.ws_leet_text('di@betes', 2) <> 'diabetes' then raise exception 'O4 leet fold'; end if;

  -- ===== income: waivable only as 'your income' with no amount, or inside an approved product / feature phrase =====
  foreach s in array array['Disability insurance can cover up to 70% of your income', 'Disability insurance replaces part of your income', 'Income protection insurance', 'Protect your income with disability insurance', 'Assurance invalidité : jusqu''à 70 % de votre revenu',
                           'Disability insurance from $25/month protects your income'] loop
    perform pg_temp.must_pass('I1', s, ins4);
  end loop;
  foreach s in array array['Disability insurance: my income is high', 'Disability insurance, income of $5,000', 'Disability insurance protects your income of $5,000', 'Disability insurance - his income is 60k', 'Disability insurance: income 4000',
                           'Disability insurance protects your income, up to $4,500 a month', 'Disability insurance - income', 'Disability insurance and salary', 'Assurance invalidité, mon revenu est élevé', 'Assurance invalidité : votre revenu de 5 000 $',
                           'Disability insurance - proof of income', 'Disability insurance, income verification'] loop
    perform pg_temp.must_block('I2', s, ins4);
  end loop;
  -- 'income' without insurance context is still the mortgage category, with or without a workspace
  perform pg_temp.must_block('I3', 'Spring campaign for your income', other, 'application_or_income');
  perform pg_temp.must_pass('I3c in an insurance workspace the generic phrase is waived', 'Spring campaign for your income', ins4);
  perform pg_temp.must_block('I3b', 'income protection', null, 'application_or_income');

  -- ===== splice / cut-and-splice: the pieces around a cut term are tested one by one, never re-joined =====
  foreach s in array array['Health insurance for dia health insurance betes', 'Health insurance: c health insurance ancer', 'Health insurance: can health insurance cer', 'health insurance d health insurance iabetes',
                           'Health insurance for h health insurance eart', 'life insurance dem life insurance entia', 'Health insurance: lup health insurance us', 'health insurance health insurance cancer',
                           'Health insurance for dia' || chr(8203) || ' health insurance ' || chr(8203) || 'betes'] loop
    perform pg_temp.must_block('S1 splice', s, ins4);
  end loop;

  -- ===== L: asserted LIMITS (honest). If one of these changes, update the policy document. =====
  foreach s in array array['Health insurance (she has MS)', 'Health insurance for people with sugar problems', 'Health insurance - fever for three days', E'Health insurance - Jean is recovering', 'Health insurance - '|| E'օncology',
                           'Health insurance for Marie Tremblay'] loop
    perform pg_temp.must_block('L1 (these were KNOWN MISSES of the deny-list design; the default-deny vocabulary refuses them)', s, ins);
  end loop;
  foreach s in array array['Health insurance - no medical exam', 'Healthy families, health insurance', 'Disability insurance - if you cannot work', 'Disability insurance if you are unable to work', 'File a claim online with health insurance',
                           'Health insurance rated 4.8', 'Health insurance - 50%off', 'Health insurance & dental', 'Health insurance - Q&A',
                           'Assurance santé - mon-ven', 'Life insurance - pre-existing conditions covered', 'Disability insurance helps you recover', 'Health insurance wellness plans',
                           'Affordable Life Insurance For Young Families', 'Life insurance: one call away',
                           'Life insurance - Q4 retargeting', 'Life insurance: ages 54 to 55'] loop
    perform pg_temp.must_block('L2 KNOWN OVER-BLOCK (an unlisted or deliberately excluded word fails closed: the owner approves a feature phrase or a vocabulary word, or rephrases)', s, ins);
  end loop;
  -- R3 (round 3): the fixed-phrase table, number forms and the emoji whitelist remove these false positives
  foreach s in array array['Health insurance: Mon-Fri 9 to 5', 'Health insurance ' || chr(10003) || ' trusted', 'Contact us for a quote', 'Our team of advisors', 'Call us today', 'Life insurance: top 5 reasons to compare',
                           'Life insurance since 1985', 'Assurance vie : nos conseillers'] loop
    perform pg_temp.must_pass('R3 false positive removed (fixed phrase / number form / emoji)', s, ins);
  end loop;
  -- RESIDUAL RISK, asserted so a change is noticed: vocabulary-only text can still carry personal meaning when a vocabulary word is also a name, or numbers are spelled out.
  foreach s in array array['Life insurance: two, three and four', 'Critical illness insurance covers heart attack, stroke and cancer, no medical exam'] loop
    perform pg_temp.must_pass('L3 KNOWN RESIDUAL (single vocabulary word used as a name; spelled-out numbers; feature phrases are generic by owner approval)', s, ins4);
  end loop;

  -- ===== R2: second independent review of PR #17 =====
  -- R2.1 insurance workspace: EVERY free-text column of a non-person row is insurance context, whatever the words are (real guarded inserts)
  foreach s in array array['Client takes Lipitor', 'Client has lupus', 'Maria Gonzalez cannot walk', 'Client is blind', 'Client lost a leg', 'She broke her leg', 'Jean Tremblay lapsed', 'Mr. Tremblay is off work',
                           'Client had a hysterectomy', 'Client has an STD', 'Client has hepatitis', 'Le client est séropositif', 'Maria has chest pain', 'Maria Gonzalez is on ODSP', 'Our client has lupus'] loop
    perform pg_temp.must_block('R2.1 classifier', s, ins2, 'unknown_word');
    perform pg_temp.expect_fail(format($q$insert into public.ws_campaigns (workspace_id, name) values (%L, %L)$q$, ins2, s), 'Sensitive data refused%unknown_word%');
    perform pg_temp.expect_fail(format($q$select public.ffm_add_creative(%L, %L, %L, 'Get covered', %L)$q$, ins, ca, ads, s), 'Sensitive data refused%unknown_word%');
  end loop;
  insert into public.ws_campaigns (workspace_id, name) values (ins2, 'Spring promo');
  perform public.ffm_add_creative(ins, ca, ads, 'Get covered', 'Protect your income');
  -- R2.1b other languages inside an insurance workspace (non-Latin or mixed script, German/Turkish/Spanish/Italian/Portuguese words are simply not vocabulary)
  foreach s in array array['Krankenversicherung: Kunde hat Krebs', 'Sigorta: müşteri kanser', chr(20445) || chr(38505) || ': ' || chr(23458) || chr(25143) || chr(24739) || chr(26377) || chr(30284) || chr(30151), 'Gesundheitsversicherung: Krebs',
                           chr(1578) || chr(1571) || chr(1605) || chr(1610) || chr(1606) || ': ' || chr(1575) || chr(1604) || chr(1593) || chr(1605) || chr(1610) || chr(1604) || ' ' || chr(1605) || chr(1585) || chr(1610) || chr(1590),
                           chr(2348) || chr(2368) || chr(2350) || chr(2366) || ': ' || chr(2325) || chr(2376) || chr(2306) || chr(2360) || chr(2352), 'Assicurazione sanitaria: il cliente ha un tumore', 'Seguro de salud: el cliente tiene cancer',
                           'Seguro de saude: o cliente tem cancro'] loop
    perform pg_temp.must_block('R2.1b', s, ins2);
    perform pg_temp.expect_fail(format($q$insert into public.ws_campaigns (workspace_id, name) values (%L, %L)$q$, ins2, s), 'Sensitive data refused%');
  end loop;
  -- R2.2 first-person plural and generic person words are not vocabulary
  foreach s in array array['Health insurance: heart attack, stroke and cancer in our family', 'Life insurance: we need care', 'Disability insurance: parents can not work', 'Life insurance: someone needs help', 'Life insurance for everyone in the family',
                           'Assurance vie: nous avons besoin', 'Assurance vie: notre famille', 'Assurance vie: nos enfants', 'Life insurance: our kids', 'Life insurance: people', 'Life insurance: ones who can not work'] loop
    perform pg_temp.must_block('R2.2', s, ins4, 'unknown_word');
  end loop;
  foreach s in array array['cancer in our family', 'cancer in the family of our client', 'protection for parents who can not work', 'insurance for people', 'insurance for everyone', 'assurance pour nos enfants', 'insurance for someone'] loop
    perform pg_temp.expect_fail(format($q$select public.ws_add_approved_term(%L, null, 'feature', %L)$q$, ins, s), 'term refused%');
  end loop;
  foreach s in array array['we', 'us', 'our', 'ours', 'ourselves', 'one', 'ones', 'someone', 'anyone', 'everyone', 'parents', 'children', 'kids', 'people', 'nous', 'notre', 'nos', 'enfants', 'gens'] loop
    perform pg_temp.expect_fail(format($q$select public.ws_add_vocab_word('en', %L)$q$, s), 'word refused%');
    if exists (select 1 from public.ws_marketing_vocab where word = s and removed_at is null) then raise exception 'R2.2 % is still in the seeded vocabulary', s; end if;
  end loop;
  perform pg_temp.expect_fail($q$select public.ws_add_vocab_word('fr', 'on')$q$, 'word refused%');
  -- R2.3 capitalised names: a vocabulary word that is also a name fails closed when capitalised, passes in lower case
  foreach s in array array['Health insurance for Will Page', 'Health insurance: Will can not work', 'Life insurance: Brandon', 'Life insurance for Sam', 'Life insurance: Summer', 'Life insurance for Young and Long', 'Life insurance: Don can not work',
                           'LIFE INSURANCE FOR WILL', 'Life insurance: Spring can not work', 'Life insurance: Page'] loop
    perform pg_temp.must_block('R2.3', s, ins4, 'unknown_word');
  end loop;
  foreach s in array array['life insurance: long term care for young families', 'Spring promo', 'Best life insurance for the summer', 'Don''t wait: life insurance quotes'] loop
    perform pg_temp.must_pass('R2.3 lower-case or sentence-initial use passes', s, ins4);
  end loop;
  foreach s in array array['Will insurance', 'insurance for Will', 'Page coverage plan', 'Long term care insurance', 'Sam protection plan', 'insurance for may'] loop
    perform pg_temp.expect_fail(format($q$select public.ws_add_approved_term(%L, null, 'product', %L)$q$, ins, s), 'term refused%');
  end loop;
  foreach s in array array['Victoria', 'Regina', 'Sydney', 'Brandon', 'Barrie', 'Vernon', 'Courtenay'] loop
    perform pg_temp.expect_fail(format($q$select public.ws_add_approved_term(%L, null, 'place', %L)$q$, ins, s), 'term refused%');
    if exists (select 1 from public.ws_place_catalog where name_norm = lower(s)) then raise exception 'R2.3 % is in the place catalog', s; end if;
  end loop;
  -- R2.3b numbers: only price / percent / marketing-duration forms; ages, years, dates and spelled-out digit runs fail; yes/no answers after a feature phrase fail
  foreach s in array array['Life insurance: age 54', 'Life insurance: 54 years', 'Life insurance: 1985', 'Life insurance: one two three four five six seven eight nine', 'Life insurance: two three four five', 'Life insurance: 54', 'Life insurance: born 1985',
                           'Life insurance: 2 3 4 5', 'Life insurance, exam 2025', 'Life insurance: 54 year old', 'Life insurance aged 54', 'Life insurance: ages 54 to 55',
                           'Critical illness insurance covers heart attack, stroke and cancer: no', 'Critical illness insurance covers heart attack, stroke and cancer - yes', 'Critical illness insurance covers heart attack, stroke and cancer, not',
                           'Critical illness insurance covers heart attack, stroke and cancer: oui', 'Assurance vie: 54 ans', 'Life insurance in 2025'] loop
    perform pg_temp.must_block('R2.3b', s, ins4);
  end loop;
  foreach s in array array['Life insurance from $25/month', 'Life insurance: 100% online', 'Life insurance in 10 minutes', 'Life insurance: 1 in 3 Canadians', 'Canada''s #1 life insurance broker', 'Life insurance 24/7', 'Life insurance: ages 18 to 65',
                           'Life insurance, 30 year term', 'Life insurance with 20 years of experience', 'Life insurance: 30 days money back', 'Life insurance: quotes in 5 minutes', 'Assurance vie dès 25 $ par mois'] loop
    perform pg_temp.must_pass('R2.3b allowed number forms', s, ins4);
  end loop;
  -- R2.4 REGRESSION: a non-insurance workspace is not subject to the vocabulary test just because the text says insurance or policy
  foreach s in array array['Mortgage rates - privacy policy', 'Title insurance included', 'Mortgage default insurance explained for first-time buyers', 'Home insurance requirement for your mortgage', 'Our privacy policy', 'Insurance policy review for homeowners'] loop
    perform pg_temp.must_pass('R2.4', s, other);
    insert into public.ws_campaigns (workspace_id, name) values (other, s);
    perform public.ffm_add_creative(other, cb, public.ffm_add_ad_set(other, cb, 'Mortgage ad set', 'First-time buyers in Ottawa', null), s, 'Ask for a quote today');
  end loop;
  -- ...but identifiers are still refused next to an insurance word, in any vertical, and "policy" alone does not trigger anything
  perform pg_temp.must_block('R2.4b', 'Home insurance policy number 12345678', other, 'insurance_identifier');
  perform pg_temp.must_pass('R2.4c bare policy', 'Privacy policy updated 2026', other);
  -- R2.5 the owner hard-deny list cannot be bypassed by inflections, truncation, accents or a missing list entry
  foreach s in array array['lupuses', 'lupusé', 'lupu', 'hivs', 'sidas', 'insomnia', 'meningitis', 'psychosis', 'anxious', 'schizo', 'sclerosis', 'methadone', 'warfarin', 'prednisone', 'cocaine', 'heroin', 'rehab', 'vasectomy',
                           'menopause', 'incontinence', 'catheter', 'colostomy', 'oxygen', 'ventilator', 'amnesia', 'coma', 'stutter', 'cataract', 'glaucoma', 'mommy', 'daddy', 'papa', 'mamie', 'maria', 'gonzalez', 'tremblay', 'jean', 'marie',
                           'john', 'smith', 'Lupuses', 'LUPUS', 'diabètes', 'cancers', 'cancéreux', 'oxygène'] loop
    perform pg_temp.expect_fail(format($q$select public.ws_add_vocab_word('en', %L)$q$, s), 'word refused%');
    if not public.ws_vocab_denied(s, true) then raise exception 'R2.5 % is not denied', s; end if;
  end loop;
  -- ...and the vocabulary additions the review asked for are present
  foreach s in array array['worth', 'reasons', 'guide', 'webinar', 'planning', 'explained', 'freelancers', 'contractors', 'convert', 'loan', 'download', 'paycheque', 'become', 'waiver', 'respecte', 'raisons', 'acheter', 'nouveaux', 'aines',
                           'entiere', 'habitation', 'sejour', 'telechargez', '30s', 'promo'] loop
    if not exists (select 1 from public.ws_marketing_vocab where word = s and removed_at is null) then raise exception 'R2.5 vocabulary lacks %', s; end if;
  end loop;
  -- ===== R3: third review of PR #17 (real guarded inserts / calls for every repro) =====
  -- R3.1 insurance ONBOARDING completes: value_text gets the category / health / personal-context / identifier screens, NOT the marketing vocabulary test
  perform pg_temp.as_owner(true);
  perform public.ffm_instantiate_onboarding(ins);
  foreach s in array array['crm_destination=HubSpot, leads@acme.ca', 'crm_destination=HubSpot', 'booking_link=https://cal.com/acme/intro', 'consent_wording=I agree to be contacted by Acme about insurance quotes',
                           'compliance_contact=Jane Doe, compliance officer', 'compliance_contact=Jane Doe, compliance officer, 613 555 0100', 'brand_assets=https://drive.example.com/acme/brand logo and colours',
                           'ad_account_access=Meta Business Manager access granted to agency', 'ad_review_signoff=compliance@acme.ca approves copy by email', 'lead_fields_agreed=first name, email, phone, postal code, product interest',
                           'licensing_status=Licensed life agent, sponsored by Example Agency', 'recruiting_model=Salaried advisors, referral bonus, no overrides', 'service_geography=Ontario and Quebec',
                           'launch_deadline=Dec 1, 2026', 'monthly_budget=Budget set by the owner in the workspace', 'ad_review_signoff=Sign-off by the brokerage compliance team'] loop
    perform public.ffm_provide_input(ins, split_part(s, '=', 1), substr(s, position('=' in s) + 1), 'client');
  end loop;
  -- every template key of an insurance workspace has a realistic value above (a new template without one must be added to this test)
  if exists (select 1 from public.ffm_onboarding_items i where i.workspace_id = ins and i.status <> 'provided' and i.template_key <> 'no_sensitive_files_confirmed') then
    raise exception 'R3.1 an insurance onboarding key was not completed: %', (select string_agg(template_key, ',') from public.ffm_onboarding_items where workspace_id = ins and status <> 'provided');
  end if;
  -- health text smuggled into any key is refused, whatever the key accepts (e-mail / link / person name keys included)
  for t in select template_key from public.ffm_onboarding_items where workspace_id = ins loop
    foreach s in array array['Client has lupus', 'Maria Gonzalez cannot walk, ODSP', 'HubSpot, client takes insulin for diabetes', 'https://cal.com/acme/intro heart attack', 'my wife has cancer', 'Senior can not work'] loop
      perform pg_temp.expect_fail(format($q$select public.ffm_provide_input(%L, %L, %L, 'client')$q$, ins, t, s), 'Sensitive data refused%');
    end loop;
  end loop;
  -- identifiers, person names and a person's address are refused where not expected
  perform pg_temp.expect_fail(format($q$select public.ffm_provide_input(%L, 'crm_destination', 'Send to jane@acme.ca, SIN 046 454 286', 'client')$q$, ins), 'Sensitive data refused%');
  perform pg_temp.expect_fail(format($q$select public.ffm_provide_input(%L, 'crm_destination', 'maria.gonzalez@gmail.com', 'client')$q$, ins), 'Sensitive data refused%');
  perform pg_temp.expect_fail(format($q$select public.ffm_provide_input(%L, 'booking_link', 'https://cal.com/maria-gonzalez', 'client')$q$, ins), 'Sensitive data refused%');
  perform pg_temp.expect_fail(format($q$select public.ffm_provide_input(%L, 'service_geography', 'Maria Gonzalez, 12 Main Street', 'client')$q$, ins), 'Sensitive data refused%');
  perform pg_temp.expect_fail(format($q$select public.ffm_provide_input(%L, 'licensing_status', 'jane@acme.ca', 'client')$q$, ins), 'Sensitive data refused%');       -- an e-mail only where the key takes one
  perform pg_temp.expect_fail(format($q$select public.ffm_provide_input(%L, 'recruiting_model', 'Jane Doe, compliance officer', 'client')$q$, ins), 'Sensitive data refused%');   -- a person name only for the compliance contact
  -- the vertical variants take the same path
  insert into public.client_workspaces (slug, name, vertical, status) values ('ic-brk', 'IC Broker', 'insurance-broker', 'active') returning id into id1;
  insert into public.ffm_onboarding_items (workspace_id, template_key, title, provider) select id1, key, title, provider from public.ffm_onboarding_templates where vertical = 'generic';
  perform public.ffm_provide_input(id1, 'crm_destination', 'HubSpot, leads@acme.ca', 'client');
  perform pg_temp.expect_fail(format($q$select public.ffm_provide_input(%L, 'crm_destination', 'Client has lupus, leads@acme.ca', 'client')$q$, id1), 'Sensitive data refused%');
  -- R3.2 structural columns hold no personal text (real calls and direct writes)
  foreach s in array array['Maria Gonzalez cannot walk, ODSP', 'Client has lupus', 'client takes insulin', 'Jean Tremblay is angry'] loop
    perform pg_temp.expect_fail(format($q$select public.ffm_block_input(%L, 'launch_deadline', %L)$q$, ins, s), 'Sensitive data refused%');
    perform pg_temp.expect_fail(format($q$update public.ffm_onboarding_items set title = %L where workspace_id = %L and template_key = 'launch_deadline'$q$, s, ins), 'Sensitive data refused%');
    perform pg_temp.expect_fail(format($q$update public.ffm_onboarding_items set provided_by = %L where workspace_id = %L and template_key = 'launch_deadline'$q$, s, ins), 'Sensitive data refused%');
    perform pg_temp.expect_fail(format($q$update public.ffm_onboarding_items set blocked_until = %L where workspace_id = %L and template_key = 'launch_deadline'$q$, s, ins), 'Sensitive data refused%');
    perform pg_temp.expect_fail(format($q$insert into public.ffm_approvals (workspace_id, kind, ref_id, approved_by, note) values (%L, 'creative', gen_random_uuid(), %L, 'ok')$q$, ins, s), 'Sensitive data refused%');
  end loop;
  perform public.ffm_block_input(ins, 'launch_deadline', 'awaiting_client');
  perform public.ffm_block_input(ins, 'monthly_budget', 'Dec 31, 2026');
  update public.ffm_onboarding_items set provided_by = 'moe' where workspace_id = ins and template_key = 'launch_deadline';
  update public.ffm_onboarding_items set title = (select title from public.ffm_onboarding_templates where key = 'launch_deadline') where workspace_id = ins and template_key = 'launch_deadline';
  -- R3.3 yes/no rule: punctuation, position and language do not bypass it (a negation next to a condition-naming feature is a personal statement)
  foreach s in array array['Heart attack, stroke and cancer? No', 'Critical illness insurance: heart attack, stroke and cancer (no)', 'Critical illness insurance: heart attack, stroke and cancer (oui)', 'Critical illness insurance: heart attack, stroke and cancer. No',
                           'Critical illness insurance: heart attack, stroke and cancer ... no', 'Critical illness insurance: heart attack, stroke and cancer / no', 'Critical illness insurance: heart attack, stroke and cancer | no',
                           'Critical illness insurance: heart attack, stroke and cancer ? Non', 'Critical illness insurance: No heart attack, stroke and cancer', 'Critical illness insurance: Not heart attack, stroke and cancer',
                           'Critical illness insurance: heart attack, stroke and cancer - yes', 'Critical illness insurance: heart attack, stroke and cancer: none', 'Critical illness insurance: never heart attack, stroke and cancer',
                           'Critical illness insurance: pas heart attack, stroke and cancer', 'Critical illness insurance: heart attack, stroke and cancer ; nope', 'Critical illness insurance: heart attack, stroke and cancer!! no'] loop
    perform pg_temp.must_block('R3.3', s, ins4, 'unknown_word');
    perform pg_temp.expect_fail(format($q$insert into public.ws_campaigns (workspace_id, name) values (%L, %L)$q$, ins4, s), 'Sensitive data refused%');
  end loop;
  perform pg_temp.must_pass('R3.3 the feature itself is unchanged', 'Critical illness insurance covers heart attack, stroke and cancer', ins4);
  -- R3.4 the 'your income' waiver is refused when a number word is present
  foreach s in array array['Life insurance: your income is fifty thousand a year', 'Life insurance: Votre revenu cent mille', 'Life insurance: your income of forty five thousand', 'Assurance vie: votre revenu soixante mille',
                           'Life insurance: your income one hundred', 'Life insurance: your income 50,000', 'Life insurance: your income $50k'] loop
    perform pg_temp.must_block('R3.4', s, ins4);
  end loop;
  perform pg_temp.must_pass('R3.4 the plain waiver still works', 'Life insurance: protect your income', ins4);
  -- R3.5 vertical variants are insurance context (the exact word 'insurance' was the only match before)
  foreach s in array array['insurance-broker', 'life insurance', 'insurance_brokerage', 'assurances', 'courtage assurance', 'Insurance Advisors', 'assurance-vie'] loop
    insert into public.client_workspaces (slug, name, vertical, status) values ('ic-var-' || translate(lower(s), ' _-', 'xyz'), 'IC variant', s, 'active') returning id into id2;
    perform pg_temp.must_block('R3.5 vertical ' || s, 'Client has lupus', id2, 'unknown_word');
    perform pg_temp.must_block('R3.5 vertical ' || s, 'Maria Gonzalez cannot walk', id2);
    perform pg_temp.expect_fail(format($q$insert into public.ws_campaigns (workspace_id, name) values (%L, 'Client has lupus')$q$, id2), 'Sensitive data refused%');
    perform pg_temp.must_pass('R3.5 vertical ' || s, 'Life insurance: Contact us today', id2);
  end loop;
  perform pg_temp.must_pass('R3.5 a mortgage vertical keeps the old strict behaviour', 'Mortgage renewal rates this spring', other);
  -- R3.6 owner-managed FIXED PHRASES (en/fr): seeded, cut in pass 1, owner-only, soft removal, audit without the phrase, immutable
  foreach s in array array['contact us', 'call us', 'email us', 'text us', 'reach us', 'talk to us', 'our team', 'our advisors', 'our brokers', 'our experts', 'our guide', 'our free guide', 'our checklist', 'one call', 'one plan', 'one place',
                           'notre equipe', 'nos conseillers', 'nos courtiers', 'notre guide', 'contactez nous', 'appelez nous', 'joignez nous', 'mon fri', 'lun ven'] loop
    if not exists (select 1 from public.ws_fixed_phrases where phrase_norm = s and removed_at is null) then raise exception 'R3.6 fixed phrase % is not seeded', s; end if;
  end loop;
  foreach s in array array['Life insurance: contact us today', 'Life insurance: our team', 'Life insurance: Mon-Fri 9am to 5pm', 'Assurance vie: appelez-nous', 'Assurance vie : notre équipe', 'Assurance vie: lun-ven 9h à 17h', 'Life insurance: Monday to Friday, 9 to 5',
                           'Top 5 reasons to compare life insurance', 'Life insurance since 1985', 'Life insurance: 5 stars', 'Life insurance: over 10,000 families', 'Assurance vie depuis 1985', 'Life insurance: 20 year term', 'Life insurance: 10 years of experience',
                           'Assurance vie: 5 raisons de comparer', 'Assurance vie: plus de 10 000 familles', 'Assurance vie: 5 étoiles', 'Life insurance & disability insurance', 'Life insurance ' || chr(10003) || ' ' || chr(9733) || ' ' || chr(10024)] loop
    perform pg_temp.must_pass('R3.6 false positive removed', s, ins4);
  end loop;
  -- ...but 'client', 'I' and first-person pronouns stay denied, a number next to a person word is still refused, and plans/options need no number
  foreach s in array array['Life insurance: our client', 'Life insurance: I need', 'Life insurance: my family', 'Life insurance: Plan 1', 'Life insurance: Option 2', 'Life insurance: age 54', 'Life insurance: 9 to 5 tonight', 'Life insurance: 5 stars for Maria'] loop
    perform pg_temp.must_block('R3.6 still denied', s, ins4);
  end loop;
  perform pg_temp.as_owner(false);
  perform pg_temp.expect_fail($q$select public.ws_add_fixed_phrase('en', 'talk with us')$q$, 'owner approval required%');
  perform pg_temp.as_owner(true);
  perform pg_temp.expect_fail($q$select public.ws_add_fixed_phrase('en', 'our client')$q$, 'phrase refused%');
  perform pg_temp.expect_fail($q$select public.ws_add_fixed_phrase('en', 'client has lupus')$q$, 'phrase refused%');
  perform pg_temp.expect_fail($q$select public.ws_add_fixed_phrase('de', 'besuchen sie uns')$q$, 'phrase refused%');
  perform pg_temp.expect_fail($q$select public.ws_add_fixed_phrase('en', 'x')$q$, 'phrase refused%');
  perform pg_temp.expect_fail($q$select public.ws_add_fixed_phrase('en', 'contact us')$q$, 'phrase already approved%');
  perform pg_temp.must_block('R3.6 a new phrase is not approved yet', 'Life insurance: talk with us', ins4);
  id3 := public.ws_add_fixed_phrase('en', 'Talk with us');
  perform pg_temp.must_pass('R3.6 owner-added phrase', 'Life insurance: talk with us', ins4);
  if exists (select 1 from public.audit_log where action like 'ws_fixed_phrase%' and detail::text ~* 'visit') then raise exception 'R3.6 audit row carries the phrase'; end if;
  if not exists (select 1 from public.audit_log where action like 'ws_fixed_phrase%') then raise exception 'R3.6 no audit row'; end if;
  perform public.ws_remove_fixed_phrase(id3);
  perform pg_temp.must_block('R3.6 a removed phrase is gone', 'Life insurance: talk with us', ins4);
  perform pg_temp.expect_fail(format($q$delete from public.ws_fixed_phrases where id = %L$q$, id3), 'approved terms cannot be edited%');
  perform pg_temp.expect_fail(format($q$update public.ws_fixed_phrases set phrase_norm = 'zzz zzz' where id = %L$q$, id3), 'approved terms cannot be edited%');
  perform pg_temp.expect_fail($q$truncate public.ws_fixed_phrases$q$, 'approved terms cannot be edited%');
  foreach r in array array['anon', 'authenticated'] loop
    if has_table_privilege(r, 'public.ws_fixed_phrases', 'select') then raise exception 'R3.6 % reads the phrase table', r; end if;
  end loop;
  foreach r in array array['insert', 'update', 'delete', 'truncate'] loop
    if has_table_privilege('service_role', 'public.ws_fixed_phrases', r) then raise exception 'R3.6 service_role can % the phrase table', r; end if;
  end loop;
  -- R3.7 spelled digit groups across punctuation, and negated ability ("can't" must not lose its negation)
  foreach s in array array['Life insurance: nine nine nine, nine nine nine, nine nine nine', 'Life insurance: six two three - five five five - zero zero - four two', 'Life insurance: one, two, three, four',
                           'Assurance vie: six un trois / cinq cinq cinq / zero un quatre deux', 'Life insurance: Worker can''t work', 'Life insurance: Senior can not work', 'Life insurance: Worker cant work', 'Life insurance: she cannot pay',
                           'Life insurance: Worker can t walk', 'Life insurance: Family can not pay bills', 'Life insurance: Senior needs care', 'Life insurance: Worker needs surgery', 'Life insurance: Worker could not afford'] loop
    perform pg_temp.must_block('R3.7', s, ins4);
    perform pg_temp.expect_fail(format($q$insert into public.ws_campaigns (workspace_id, name) values (%L, %L)$q$, ins4, s), 'Sensitive data refused%');
  end loop;
  -- R3.8 names that are also vocabulary words: a name by POSITION (after for / to / of / from / beneficiary / named / by / with, or first / last in the text)
  foreach s in array array['Life insurance for will', 'Life insurance: beneficiary will', 'Life insurance named may', 'Life insurance to don', 'Life insurance by sam', 'Life insurance with bill', 'Life insurance of page', 'Life insurance from mark',
                           'Life insurance for rose', 'Life insurance for grace', 'Life insurance for summer', 'Life insurance for spring', 'Life insurance: sun', 'Life insurance: wed', 'will life insurance', 'Life insurance - sam', 'Life insurance to mo',
                           'Life insurance for sat'] loop
    perform pg_temp.must_block('R3.8', s, ins4, 'unknown_word');
  end loop;
  foreach s in array array['Life insurance: will not expire', 'Life insurance: you may qualify', 'Don''t wait: life insurance', 'Life insurance: payment options', 'Life insurance in the summer', 'Life insurance: spring sale'] loop
    perform pg_temp.must_pass('R3.8 ordinary use still passes', s, ins4);
  end loop;
  -- R3.9 generic-subject narrative
  foreach s in array array['Worker can not work', 'Senior needs care', 'Family can not pay bills', 'Senior cannot walk', 'Veteran can''t see', 'Life insurance: parent needs surgery'] loop
    perform pg_temp.must_block('R3.9', s, ins4);
    perform pg_temp.expect_fail(format($q$insert into public.ws_campaigns (workspace_id, name) values (%L, %L)$q$, ins4, s), 'Sensitive data refused%');
  end loop;
  -- R3.10 owner deny list gaps
  foreach s in array array['sis', 'bro', 'hubby', 'wifey', 'widowed', 'bereaved', 'newborn', 'funeral', 'blood', 'pressure', 'sugar', 'glucose', 'faint', 'collapse', 'crutches', 'nursing', 'impaired', 'dentist', 'neurologist', 'pill', 'dose', 'probate',
                           'estate', 'bankrupt', 'bankruptcy', 'debt', 'arrears', 'foreclosure', 'garnish', 'garnishment', 'lawsuit', 'divorce', 'custody', 'immigrant', 'refugee', 'visa', 'jail', 'prison', 'felony', 'arrest', 'gambling', 'lup', 'herpe',
                           'kneecap', 'arthritic', 'sammy', 'jeanne', 'alissa', 'gonzales'] loop
    perform pg_temp.expect_fail(format($q$select public.ws_add_vocab_word('en', %L)$q$, s), 'word refused%');
    if not public.ws_vocab_denied(s, true) then raise exception 'R3.10 % is not denied', s; end if;
    perform pg_temp.must_block('R3.10 in text', 'Life insurance: ' || s, ins4, 'unknown_word');
  end loop;
  -- R3.11 a non-insurance workspace is as before: an e-mail next to an insurance word is no longer refused there (the identifier screen is gone: it was NEW behaviour in this migration)
  perform pg_temp.must_pass('R3.11 mortgage workspace, e-mail next to insurance', 'Write to jane@acme.ca about home insurance', other);
  insert into public.ws_campaigns (workspace_id, name) values (other, 'Write to jane@acme.ca about home insurance');
  -- R3.12 the definer functions of this migration pin search_path to pg_catalog and qualify their references
  for t in select p.proname from pg_proc p where p.pronamespace = 'public'::regnamespace and p.prosecdef
           and p.proname in ('ws_classify_text', 'ws_classify_core', 'ws_insurance_context', 'ws_add_approved_term', 'ws_remove_approved_term', 'ws_add_vocab_word', 'ws_remove_vocab_word', 'ws_add_fixed_phrase', 'ws_remove_fixed_phrase', 'ws_onboarding_value_check', 'ws_structural_value') loop
    if not exists (select 1 from pg_proc p where p.proname = t and p.proconfig @> array['search_path=pg_catalog']) then raise exception 'R3.12 % does not pin search_path to pg_catalog', t; end if;
  end loop;
  -- R3.13 the exact fixture names PR #16 (build/leak-redaction) greps the schema export for are not readable in any function source of this migration
  foreach s in array array['vandenbroek', 'prisca', 'lachapelle', 'theodore', 'zalewski', 'ximena', 'zorro', 'quenneville', 'odalys', 'brightwater', 'tremblay', 'plomberie', 'zzyxwell', 'quillfeather', 'wexcombe', 'bedard', 'marcus', 'eloise', 'marie', 'diabetes'] loop
    if exists (select 1 from pg_proc p where p.pronamespace = 'public'::regnamespace and p.proname ~ '^(ws|ffm)_' and p.proname <> 'ws_sensitive_hits' and lower(p.prosrc) like '%' || s || '%') then raise exception 'R3.13 % is readable in a function source', s; end if;
  end loop;
  -- no literal invisible characters in the new function bodies, only \u escapes
  if exists (select 1 from pg_proc where proname in ('ws_onboarding_value_check', 'ws_structural_value', 'ws_name_word_hit', 'ws_health_word_hit', 'ws_stem_match', 'ws_add_fixed_phrase', 'ws_fold_text', 'ws_classify_text', 'ws_classify_core', 'ws_capitalised_name', 'ws_identifier_hit', 'ws_personal_context_hit', 'ws_health_extra_hit', 'ws_residual_check', 'ws_vocab_denied', 'ws_condition_hit', 'ws_leet_text', 'ws_add_approved_term', 'ws_add_vocab_word')
             and (position(chr(8203) in prosrc) > 0 or position(chr(65279) in prosrc) > 0 or position(chr(173) in prosrc) > 0 or position(chr(8205) in prosrc) > 0)) then raise exception 'L5 literal invisible character in a classifier function'; end if;
  -- the backup schema export carries function source: no full surname / diagnosis word in the functions of this migration (the leak-redaction test greps the export for them)
  if exists (select 1 from pg_proc where proname like 'ws\_%' and (lower(prosrc) like '%tremblay%' or lower(prosrc) like '%diabetes%')) then raise exception 'L6 a classifier function source contains a word the leak test greps for'; end if;
  -- ws_sensitive_hits itself was not touched by this migration: still the 20261119 definition (same long-stem and short-word lists)
  if pg_get_functiondef('public.ws_sensitive_hits(text)'::regprocedure) !~ 'heartfailure' or pg_get_functiondef('public.ws_sensitive_hits(text)'::regprocedure) !~ 'foreach w in array' then raise exception 'L6 ws_sensitive_hits changed'; end if;
  raise notice 'insurance_classifier_check: all passed (% allowed-text assertions, % blocked-text assertions, % refused-statement assertions, plus the differential corpus)',
    (select count(*) from pg_temp.assertion_count where kind = 'pass'), (select count(*) from pg_temp.assertion_count where kind = 'block'), (select count(*) from pg_temp.assertion_count where kind = 'refused');
end $$;
rollback;
