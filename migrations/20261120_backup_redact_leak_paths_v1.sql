-- Off-site backup, SECOND PROTECTIVE LAYER: redaction of client-text leak paths INSIDE backup_snapshot() (v2: independent-review fixes).
-- Why: the system copies client text into EXPORTED tables (audit_log.detail.reason, ledger.note, tasks.result, agent_runs.summary, and any free-text column; see
-- DATA_CLASSIFICATION_AND_BACKUP_POLICY.md section 2). Source-level prevention is in 20261120_leak_source_prevention_v1; THIS migration is the export-level net.
-- What it adds (read-only, no table is changed, service role only):
--   backup_fold_text / backup_unescape_text / backup_normalise   NFKC, zero-width and combining marks out, Cyrillic/Greek look-alikes and non-Latin digits to ASCII, then percent / HTML-entity / \u / \x decoding
--   backup_redaction_context()    the CLIENT NAMES known at export time, compiled once per snapshot. Contains client data: never returned by the snapshot.
--   backup_deny_scan() / backup_deny_terms()   names, emails and phones that are NO LONGER in the database (erased / deleted leads) but whose KEYED HASHES are kept in ffm_redaction_denylist
--                                 (migration 20261120_redaction_denylist_v1): the candidate tokens that actually occur in the exported text are hashed and compared; matches join the context
--   backup_redact_patterns / _probe_encoded   emails, phones, SIN-like and long digit runs, spelled-out digits, URLs with personal paths, known names, base64/hex blobs that decode to any of those
--   backup_redact_text(text, ctx, max, mode)   STRICT: fails closed. LIGHT: patterns and names only, never blanks a field. The short-code shortcut now runs only AFTER the digit / split-name checks (it used to return first).
--                                 In strict mode the result is re-checked with the same contact tests the Python lock uses, so the Python lock is a backstop that should never trip.
--   backup_redact_json(jsonb, ...) JSON strings, KEYS and NUMBERS: integers of 7+ digits are redacted unless the key is on the amounts allow-list; phone/SSN/account-like keys are redacted whole
--   backup_redaction_spec() / backup_effective_spec()   EVERY text-like column of every exported table is classified (strict | light | keep | blank) with a reason; a column nobody classified is treated as STRICT
--   backup_snapshot(skip)         replaced (same name, signature, grants, policy output): one statement, one snapshot; the context is computed ONCE; the response says what was redacted ('redaction').
-- Financial records are untouched: only text/json columns change; numeric columns, ids, timestamps and 'keep' columns are never altered.
-- LIMITS (stated plainly): pattern + known-name + hashed-name based, not a classifier. It cannot recognise a NAME nobody ever stored in leads/setters/ws_leads/workspaces (a person who only appears in free text),
-- misspellings, leetspeak, mixed digit/word phones, short base64, base32; common words that are also client names ('pat', 'sam', 'bob', 'will') are redacted EVERYWHERE they occur as words (usefulness cost).

-- (a database that ran an earlier draft of this migration: remove the superseded signatures first; a fresh database has none of them)
drop function if exists public.backup_deny_scan(jsonb, jsonb);
drop function if exists public.backup_redaction_spec() cascade;
create or replace function public.backup_fold_text(p text) returns text
language plpgsql immutable set search_path to 'pg_catalog' as $$
declare t text;
begin
  if p is null then return null; end if;
  t := p;
  begin t := normalize(t, NFKC); exception when others then null; end;
  begin t := normalize(t, NFD); exception when others then null; end;
  t := regexp_replace(t, '[­͏؜ᅟᅠ឴឵᠋-᠎​-‏‪-‮⁠-⁯ㅤ︀-️﻿ﾠ-]', '', 'g');
  t := regexp_replace(t, '[̀-ͯ᪰-᫿᷀-᷿⃐-⃿︠-︯]', '', 'g');
  t := translate(t, 'аеорсхуіјѕһԁԛԝкмтнвѵɡӏոսАВЕКМНОРСТХУІЈЅҮѠԌԚԜᎪᏟαονρτικυχεγημωςβΑΒΕΖΗΙΚΜΝΟΡΤΥΧϹͿàÀáÁâÂãÃäÄåÅāĀăĂąĄǎǍǟǞǡǠǻǺȁȀȃȂȧȦçÇćĆĉĈċĊčČďĎđĐèÈéÉêÊëËēĒĕĔėĖęĘěĚȅȄȇȆȩȨĝĜğĞġĠģĢǧǦĥĤħĦìÌíÍîÎïÏĩĨīĪĭĬįĮıǐǏȉȈȋȊĵĴķĶĺĹļĻľĽŀĿłŁñÑńŃņŅňŇŉòÒóÓôÔõÕöÖøØōŌŏŎőŐǒǑǫǪȍȌȏȎȯȮŕŔŗŖřŘȑȐȓȒśŚŝŜşŞšŠșȘţŢťŤŧŦțȚùÙúÚûÛüÜũŨūŪŭŬůŮűŰųŲǔǓȕȔȗȖŵŴýÝÿŸŷŶźŹżŻžŽßœŒæÆðÐþÞĳ٠١٢٣٤٥٦٧٨٩۰۱۲۳۴۵۶۷۸۹०१२३४५६७८९০১২৩৪৫৬৭৮৯੦੧੨੩੪੫੬੭੮੯૦૧૨૩૪૫૬૭૮૯୦୧୨୩୪୫୬୭୮୯௦௧௨௩௪௫௬௭௮௯౦౧౨౩౪౫౬౭౮౯೦೧೨೩೪೫೬೭೮೯൦൧൨൩൪൫൬൭൮൯๐๑๒๓๔๕๖๗๘๙໐໑໒໓໔໕໖໗໘໙༠༡༢༣༤༥༦༧༨༩၀၁၂၃၄၅၆၇၈၉០១២៣៤៥៦៧៨៩᠐᠑᠒᠓᠔᠕᠖᠗᠘᠙', 'aeopcxyijshdqwkmthbvglnuABEKMHOPCTXYIJSYWGQWACaovptikuxeynuwsbABEZHIKMNOPTYXCJaAaAaAaAaAaAaAaAaAaAaAaAaAaAaAaAcCcCcCcCcCdDdDeEeEeEeEeEeEeEeEeEeEeEeEgGgGgGgGgGhHhHiIiIiIiIiIiIiIiIiiIiIiIjJkKlLlLlLlLlLnNnNnNnNnoOoOoOoOoOoOoOoOoOoOoOoOoOoOrRrRrRrRrRsSsSsSsSsStTtTtTtTuUuUuUuUuUuUuUuUuUuUuUuUuUwWyYyYyYzZzZzZsoOaAdDpPi01234567890123456789012345678901234567890123456789012345678901234567890123456789012345678901234567890123456789012345678901234567890123456789012345678901234567890123456789');
  t := translate(t, 'ᴀʙᴄᴅᴇꜰɢʜɪᴊᴋʟᴍɴᴏᴘʀꜱᴛᴜᴠᴡʏᴢɑɩ', 'abcdefghijklmnoprstuvwyzai');       -- small capitals and Latin alpha / iota look-alikes
  return t;
end $$;

create or replace function public.backup_unescape_text(p text) returns text
language plpgsql immutable set search_path to 'pg_catalog' as $$
declare t text := p; m text; n int; seq text; named text[] := array['amp','&','lt','<','gt','>','quot','"','apos','''','nbsp',' ','commat','@','period','.','colon',':','sol','/','lpar','(','rpar',')',
      'lsqb','[','rsqb',']','lbrack','[','rbrack',']','lcub','{','rcub','}','plus','+','comma',',','hyphen','-','dash','-','lowbar','_','num','#','semi',';','excl','!','percnt','%','equals','=','quest','?'];
  i int;
begin
  if t is null then return null; end if;
  -- percent-encoding: runs of %XX are decoded as UTF-8; a run that is not valid UTF-8 is left alone
  for m in select x from (select distinct (regexp_matches(t, '((?:%[0-9a-fA-F]{2})+)', 'g'))[1] x) q order by length(x) desc loop
    begin t := replace(t, m, convert_from(decode(replace(m, '%', ''), 'hex'), 'UTF8')); exception when others then null; end;
  end loop;
  -- HTML numeric entities (decimal and hex), with or without the final semicolon
  for m in select x from (select distinct (regexp_matches(t, '(&#[0-9]{1,7};?)', 'g'))[1] x) q order by length(x) desc loop
    begin n := regexp_replace(m, '[^0-9]', '', 'g')::int; if n between 1 and 1114111 and n not between 55296 and 57343 then t := replace(t, m, chr(n)); end if; exception when others then null; end;
  end loop;
  for m in select x from (select distinct (regexp_matches(t, '(&#[xX][0-9a-fA-F]{1,6};?)', 'g'))[1] x) q order by length(x) desc loop
    begin n := ('x' || lpad(regexp_replace(m, '[^0-9a-fA-F]|^&#[xX]', '', 'g'), 8, '0'))::bit(32)::int; if n between 1 and 1114111 and n not between 55296 and 57343 then t := replace(t, m, chr(n)); end if; exception when others then null; end;
  end loop;
  -- HTML named entities that matter for contact data
  i := 1;
  while i < cardinality(named) loop
    if position('&' || named[i] || ';' in t) > 0 then t := replace(t, '&' || named[i] || ';', named[i + 1]); end if;
    i := i + 2;
  end loop;
  -- \uXXXX and \xHH escapes written out as text
  for m in select x from (select distinct (regexp_matches(t, '(\\u[0-9a-fA-F]{4}|\\x[0-9a-fA-F]{2})', 'g'))[1] x) q loop
    begin n := ('x' || lpad(substr(m, 3), 8, '0'))::bit(32)::int; if n between 1 and 1114111 and n not between 55296 and 57343 then t := replace(t, m, chr(n)); end if; exception when others then null; end;
  end loop;
  return t;
end $$;


create or replace function public.backup_normalise(p text) returns text
language plpgsql immutable parallel safe set search_path to 'pg_catalog' as $$
declare t text; nxt text; i int;
begin
  if p is null then return null; end if;
  if octet_length(p) = length(p) and strpos(p, '%') = 0 and strpos(p, '&') = 0 and strpos(p, '\') = 0 then return p; end if;       -- plain ASCII without escape characters: folding and unescaping are the identity
  t := public.backup_fold_text(p);
  for i in 1..4 loop
    nxt := public.backup_fold_text(public.backup_unescape_text(t));
    exit when nxt = t;
    t := nxt;
  end loop;
  return t;
end $$;

create or replace function public.backup_stopwords() returns text[]
language sql immutable parallel safe set search_path to 'pg_catalog' as $$
  select array['the','and','for','inc','ltd','llc','corp','company','group','services','service','solutions','ottawa','canada','ontario','toronto','barrhaven','kanata','home','homes','real','estate','realty',
               'mortgage','mortgages','insurance','plumbing','heating','cooling','electric','electrical','roofing','construction','contracting','contractors','cleaning','renovation','renovations','design',
               'studio','law','legal','dental','care','auto','detailing','energy','les','des','pour','avec','management','consulting','marketing','agency','store','shop','ltee','cie','enr','com','www','http','https',
               'setter','setters','lead','leads','payout','payouts','deal','deals','close','closed','owner','client','clients','public','task','tasks','note','notes','salon','salons','flood','test','demo','sample',
               'erased','redacted','unknown','anonymous','none','null']   -- operating vocabulary: a lead called "Setter" must not blank the word everywhere (the full name is still redacted as a phrase)
$$;

create or replace function public.backup_re_escape(p text) returns text
language sql immutable parallel safe set search_path to 'pg_catalog' as $$ select regexp_replace(p, '([\\^$.|?*+()\[\]{}])', '\\\1', 'g') $$;

-- fragment windows of a chain such as 'z.o.r.b.a.t.r.o.v' or 'zorba.trov': every contiguous run of 2+ fragments, squashed, 5+ letters. Rare input only.
create or replace function public.backup_windows(p text) returns setof text
language plpgsql immutable parallel safe set search_path to 'pg_catalog' as $$
declare f text[]; n int; i int; j int; s text;
begin
  f := array(select x from unnest(regexp_split_to_array(p, '[^a-z0-9]+')) x where x <> '');
  n := least(cardinality(f), 60);
  for i in 1..n loop
    s := '';
    for j in i..least(n, i + 19) loop
      s := s || f[j];
      if j > i and length(s) >= 5 then return next s; end if;
    end loop;
  end loop;
end $$;

-- assembles the context object from the term arrays (live names, plus names the deny-list adds)
create or replace function public.backup_ctx_build(p_phrases text[], p_parts text[], p_squashed text[], p_phones text[], p_base jsonb default '{}'::jsonb) returns jsonb
language plpgsql immutable set search_path to 'pg_catalog' as $$
declare alts text[]; nre text; sq text[]; ph text[];
begin
  alts := array(select distinct x from unnest(coalesce(p_phrases, '{}') || coalesce(p_parts, '{}')) x where x <> '');
  if cardinality(alts) > 0 then
    nre := '(?<![a-z0-9])(?:' || array_to_string(array(select x from unnest(alts) x order by length(x) desc, x), '|') || ')(?![a-z0-9])';
  else nre := ''; end if;
  sq := array(select distinct x from unnest(coalesce(p_squashed, '{}')) x where length(x) >= 5 and x ~ '^[a-z0-9]+$');
  ph := array(select distinct x from unnest(coalesce(p_phones, '{}')) x where length(x) >= 7 and x ~ '^[0-9]+$');
  return coalesce(p_base, '{}'::jsonb) || jsonb_build_object('v', 2, 'phrases', to_jsonb(coalesce(p_phrases, '{}')), 'parts', to_jsonb(coalesce(p_parts, '{}')), 'name_re', nre,
           'squashed', to_jsonb(sq), 'sq_re', case when cardinality(sq) > 0 then '(?:' || array_to_string(sq, '|') || ')' else '' end, 'phones', to_jsonb(ph), 'n_terms', cardinality(alts));
end $$;

-- adds what the deny-list scan found (plaintext terms that occur in the data) to a context
create or replace function public.backup_ctx_add(p_ctx jsonb, p_found jsonb) returns jsonb
language plpgsql immutable set search_path to 'pg_catalog' as $$
declare ph text[]; pa text[]; sq text[]; pn text[]; x text; tok text[];
begin
  if p_found is null then return p_ctx; end if;
  ph := array(select jsonb_array_elements_text(p_ctx -> 'phrases'));
  pa := array(select jsonb_array_elements_text(p_ctx -> 'parts'));
  sq := array(select jsonb_array_elements_text(p_ctx -> 'squashed'));
  pn := array(select jsonb_array_elements_text(p_ctx -> 'phones'));
  for x in select jsonb_array_elements_text(coalesce(p_found -> 'names', '[]'::jsonb)) loop pa := pa || public.backup_re_escape(x); end loop;
  for x in select jsonb_array_elements_text(coalesce(p_found -> 'chains', '[]'::jsonb)) loop sq := sq || x; end loop;
  for x in select jsonb_array_elements_text(coalesce(p_found -> 'phones', '[]'::jsonb)) loop pn := pn || x; end loop;
  for x in select jsonb_array_elements_text(coalesce(p_found -> 'emails', '[]'::jsonb)) loop
    tok := array(select y from unnest(regexp_split_to_array(split_part(x, '@', 1), '[^a-z0-9]+')) y where y <> '');
    if cardinality(tok) > 0 and length(array_to_string(tok, '')) >= 5 then
      ph := ph || array_to_string(array(select public.backup_re_escape(y) from unnest(tok) y), '[^a-z0-9]{0,3}');
      sq := sq || array_to_string(tok, '');
    end if;
  end loop;
  return public.backup_ctx_build(ph, pa, sq, pn, p_ctx - 'phrases' - 'parts' - 'name_re' - 'squashed' - 'sq_re' - 'phones' - 'n_terms');
end $$;

-- fast, exact twin of ws_sensitive_hits() for the NON-digit categories (the redactor ignores the three digit-shaped ones). Same normalisation, same stems; the per-word health loop is ONE alternation.
-- Valid only while ws_sensitive_hits() is the definition whose md5 is in backup_detector_pins(); the snapshot checks that and otherwise calls ws_sensitive_hits() itself (slower, never wrong).
create or replace function public.backup_topic_core(k text, kc text) returns text[]
language plpgsql immutable parallel safe set search_path to 'pg_catalog' as $$
declare hits text[] := '{}';
begin
  if k ~ '(^|[^a-z])s[ ._\-]*i[ ._\-]*n([^a-z]|$)' or k ~ '(^|[^a-z])(ssn|nas)([^a-z]|$)'
     or kc ~ '(socialinsurance|passport|driverslicen|driverlicen|governmentid|healthcard|ohip|dateofbirth)' then hits := hits || array['identity_document']; end if;
  if kc ~ '(bankstatement|accountnumber|accountno|bankaccount|chequingaccount|routingnumber|transitnumber|institutionnumber|voidcheque|voidcheck|directdeposit|bankingdetails|iban)' then hits := hits || array['banking']; end if;
  if kc ~ '(creditscore|creditreport|creditcheck|credithistory|creditrating|equifax|transunion|experian|beaconscore)' or k ~ '(^|[^a-z])fico([^a-z]|$)' then hits := hits || array['credit']; end if;
  if kc ~ '(mortgageapplication|loanapplication|preapproval|noticeofassessment|paystub|employmentletter|incomeverification|proofofincome|networth|income|salary|taxreturn)'
     or k ~ '(^|[^a-z0-9])(t4a?|noa)([^a-z0-9]|$)' then hits := hits || array['application_or_income']; end if;
  if kc ~ '(diabet|cancer|tumou?r|chemo|radiotherap|oncolog|leuk[a]?emi|lymphoma|melanoma|hypertens|hypotens|cholesterol|asthma|epilep|seizure|dementia|alzheimer|parkinson|arthritis|osteoporo|fibromyalg|multiplesclerosis|cysticfibrosis|crohn|colitis|dialysis|transplant|pacemaker|insulin|inhaler|antibiotic|antidepress|opioid|painkill|steroid|heartattack|heartdisease|heartcondition|heartfailure|heartmurmur|bloodpressure|bloodsugar|bloodtest|bloodwork|bloodthinner|cardiac|cardiolog|cardiovascular|thyroid|kidney|ulcerative|migraine|chronic(?!le)|medical|medication|medicine|medicinal|medicare|medicaid|prescri|pharmac|diagnos|disabilit|pregnan|miscarriage|fertility|abortion|contracepti|maternity|mentalhealth|mentalillness|psychiatr|psychotherap|bipolar|schizophren|depress|anxiety|ptsd|autis|dyslexi|therap|surger|surgical|surgeon|hospital(?!ity)|hospice|palliative|ambulance|clinic|physician|symptom|disease|illness|sickness|syndrome|disorder|infection|infectious|covid|vaccin|allerg|injur|wheelchair|impairment|addict|alcoholi|substanceabuse|overdose|suicid|selfharm|eatingdisorder|anorexi|bulimi|obesity|paralys|hearingloss|hearingaid|apnea|apnoea|biops|mammogra|xray|ctscan|smoker|smoking|tobacco|nicotine|cigarette|cannabis|marijuana|patientrecord|patientfile|patientchart|patienthistory|patientinfo|patientnumber|patientid|patients|health)' or k ~ '(^|[^a-z])(?:h[ ._\-]?e[ ._\-]?a[ ._\-]?r[ ._\-]?t|h[ ._\-]?e[ ._\-]?a[ ._\-]?r[ ._\-]?t[ ._\-]?s|h[._\-]?i[._\-]?v|a[._\-]?i[._\-]?d[._\-]?s|m[ ._\-]?e[ ._\-]?n[ ._\-]?t[ ._\-]?a[ ._\-]?l|m[ ._\-]?e[ ._\-]?n[ ._\-]?t[ ._\-]?a[ ._\-]?l[ ._\-]?l[ ._\-]?y|s[._\-]?i[._\-]?c[._\-]?k|d[ ._\-]?o[ ._\-]?c[ ._\-]?t[ ._\-]?o[ ._\-]?r|d[ ._\-]?o[ ._\-]?c[ ._\-]?t[ ._\-]?o[ ._\-]?r[ ._\-]?s|n[ ._\-]?u[ ._\-]?r[ ._\-]?s[ ._\-]?e|n[ ._\-]?u[ ._\-]?r[ ._\-]?s[ ._\-]?e[ ._\-]?s|r[._\-]?x|m[._\-]?e[._\-]?d[._\-]?s|a[._\-]?d[._\-]?h[._\-]?d|o[._\-]?c[._\-]?d|c[._\-]?o[._\-]?p[._\-]?d|d[._\-]?r[._\-]?u[._\-]?g|d[ ._\-]?r[ ._\-]?u[ ._\-]?g[ ._\-]?s|v[._\-]?a[._\-]?p[._\-]?e|v[ ._\-]?a[ ._\-]?p[ ._\-]?e[ ._\-]?s|v[ ._\-]?a[ ._\-]?p[ ._\-]?i[ ._\-]?n[ ._\-]?g|s[ ._\-]?t[ ._\-]?r[ ._\-]?o[ ._\-]?k[ ._\-]?e|s[ ._\-]?t[ ._\-]?r[ ._\-]?o[ ._\-]?k[ ._\-]?e[ ._\-]?s|l[._\-]?u[._\-]?n[._\-]?g|l[ ._\-]?u[ ._\-]?n[ ._\-]?g[ ._\-]?s|u[ ._\-]?l[ ._\-]?c[ ._\-]?e[ ._\-]?r|u[ ._\-]?l[ ._\-]?c[ ._\-]?e[ ._\-]?r[ ._\-]?s|m[._\-]?r[._\-]?i|i[._\-]?v[._\-]?f|s[ ._\-]?t[ ._\-]?e[ ._\-]?n[ ._\-]?t|o[ ._\-]?b[ ._\-]?e[ ._\-]?s[ ._\-]?e|d[._\-]?e[._\-]?a[._\-]?f|d[ ._\-]?e[ ._\-]?a[ ._\-]?f[ ._\-]?n[ ._\-]?e[ ._\-]?s[ ._\-]?s)([^a-z]|$)' then hits := hits || array['health']; end if;
  return hits;
end $$;


-- cheap pre-filter for the twin: two regexes (one over the compacted text, one over the lower-cased text) that match whenever ANY category of backup_topic_core could match. Generated from the core's own patterns.
create or replace function public.backup_topic_fast(k text, kc text) returns text[]
language plpgsql immutable parallel safe set search_path to 'pg_catalog' as $$
begin
  if kc !~ '(?:(socialinsurance|passport|driverslicen|driverlicen|governmentid|healthcard|ohip|dateofbirth))|(?:(bankstatement|accountnumber|accountno|bankaccount|chequingaccount|routingnumber|transitnumber|institutionnumber|voidcheque|voidcheck|directdeposit|bankingdetails|iban))|(?:(creditscore|creditreport|creditcheck|credithistory|creditrating|equifax|transunion|experian|beaconscore))|(?:(mortgageapplication|loanapplication|preapproval|noticeofassessment|paystub|employmentletter|incomeverification|proofofincome|networth|income|salary|taxreturn))|(?:(diabet|cancer|tumou?r|chemo|radiotherap|oncolog|leuk[a]?emi|lymphoma|melanoma|hypertens|hypotens|cholesterol|asthma|epilep|seizure|dementia|alzheimer|parkinson|arthritis|osteoporo|fibromyalg|multiplesclerosis|cysticfibrosis|crohn|colitis|dialysis|transplant|pacemaker|insulin|inhaler|antibiotic|antidepress|opioid|painkill|steroid|heartattack|heartdisease|heartcondition|heartfailure|heartmurmur|bloodpressure|bloodsugar|bloodtest|bloodwork|bloodthinner|cardiac|cardiolog|cardiovascular|thyroid|kidney|ulcerative|migraine|chronic(?!le)|medical|medication|medicine|medicinal|medicare|medicaid|prescri|pharmac|diagnos|disabilit|pregnan|miscarriage|fertility|abortion|contracepti|maternity|mentalhealth|mentalillness|psychiatr|psychotherap|bipolar|schizophren|depress|anxiety|ptsd|autis|dyslexi|therap|surger|surgical|surgeon|hospital(?!ity)|hospice|palliative|ambulance|clinic|physician|symptom|disease|illness|sickness|syndrome|disorder|infection|infectious|covid|vaccin|allerg|injur|wheelchair|impairment|addict|alcoholi|substanceabuse|overdose|suicid|selfharm|eatingdisorder|anorexi|bulimi|obesity|paralys|hearingloss|hearingaid|apnea|apnoea|biops|mammogra|xray|ctscan|smoker|smoking|tobacco|nicotine|cigarette|cannabis|marijuana|patientrecord|patientfile|patientchart|patienthistory|patientinfo|patientnumber|patientid|patients|health))' and k !~ '(?:(^|[^a-z])s[ ._\-]*i[ ._\-]*n([^a-z]|$))|(?:(^|[^a-z])(ssn|nas)([^a-z]|$))|(?:(^|[^a-z])fico([^a-z]|$))|(?:(^|[^a-z0-9])(t4a?|noa)([^a-z0-9]|$))|(?:(^|[^a-z])(?:h[ ._\-]?e[ ._\-]?a[ ._\-]?r[ ._\-]?t|h[ ._\-]?e[ ._\-]?a[ ._\-]?r[ ._\-]?t[ ._\-]?s|h[._\-]?i[._\-]?v|a[._\-]?i[._\-]?d[._\-]?s|m[ ._\-]?e[ ._\-]?n[ ._\-]?t[ ._\-]?a[ ._\-]?l|m[ ._\-]?e[ ._\-]?n[ ._\-]?t[ ._\-]?a[ ._\-]?l[ ._\-]?l[ ._\-]?y|s[._\-]?i[._\-]?c[._\-]?k|d[ ._\-]?o[ ._\-]?c[ ._\-]?t[ ._\-]?o[ ._\-]?r|d[ ._\-]?o[ ._\-]?c[ ._\-]?t[ ._\-]?o[ ._\-]?r[ ._\-]?s|n[ ._\-]?u[ ._\-]?r[ ._\-]?s[ ._\-]?e|n[ ._\-]?u[ ._\-]?r[ ._\-]?s[ ._\-]?e[ ._\-]?s|r[._\-]?x|m[._\-]?e[._\-]?d[._\-]?s|a[._\-]?d[._\-]?h[._\-]?d|o[._\-]?c[._\-]?d|c[._\-]?o[._\-]?p[._\-]?d|d[._\-]?r[._\-]?u[._\-]?g|d[ ._\-]?r[ ._\-]?u[ ._\-]?g[ ._\-]?s|v[._\-]?a[._\-]?p[._\-]?e|v[ ._\-]?a[ ._\-]?p[ ._\-]?e[ ._\-]?s|v[ ._\-]?a[ ._\-]?p[ ._\-]?i[ ._\-]?n[ ._\-]?g|s[ ._\-]?t[ ._\-]?r[ ._\-]?o[ ._\-]?k[ ._\-]?e|s[ ._\-]?t[ ._\-]?r[ ._\-]?o[ ._\-]?k[ ._\-]?e[ ._\-]?s|l[._\-]?u[._\-]?n[._\-]?g|l[ ._\-]?u[ ._\-]?n[ ._\-]?g[ ._\-]?s|u[ ._\-]?l[ ._\-]?c[ ._\-]?e[ ._\-]?r|u[ ._\-]?l[ ._\-]?c[ ._\-]?e[ ._\-]?r[ ._\-]?s|m[._\-]?r[._\-]?i|i[._\-]?v[._\-]?f|s[ ._\-]?t[ ._\-]?e[ ._\-]?n[ ._\-]?t|o[ ._\-]?b[ ._\-]?e[ ._\-]?s[ ._\-]?e|d[._\-]?e[._\-]?a[._\-]?f|d[ ._\-]?e[ ._\-]?a[ ._\-]?f[ ._\-]?n[ ._\-]?e[ ._\-]?s[ ._\-]?s)([^a-z]|$))' then return '{}'::text[]; end if;
  return public.backup_topic_core(k, kc);
end $$;

create or replace function public.backup_topic_hits(p_text text) returns text[]
language plpgsql immutable parallel safe set search_path to 'pg_catalog' as $$
declare t text; k text;
begin
  t := translate(normalize(regexp_replace(coalesce(p_text, ''), '[\u200b-\u200d\u2060\ufeff]', '', 'g'), NFKC), '٠١٢٣٤٥٦٧٨٩۰۱۲۳۴۵۶۷۸۹', '01234567890123456789');
  k := lower(t);
  return public.backup_topic_fast(k, regexp_replace(k, '[^a-z0-9]', '', 'g'));
end $$;

create or replace function public.backup_detector_pins() returns text[]
language sql immutable parallel safe set search_path to 'pg_catalog' as $$
  select array['e13e47c15c1d034043a21938e14e0431']::text[]     -- md5(pg_get_functiondef(ws_sensitive_hits)) that backup_topic_hits() was proven equal to (sqltests/leak_redaction_check.sql, section G)
$$;

-- the client names that exist in the database RIGHT NOW. Contains client data: service role only, and it is never part of a snapshot.
-- Returns the FULL context (every live name compiled, so a direct call is exact). backup_snapshot() narrows it (backup_ctx_hot) to the names that actually occur in the exported text.
create or replace function public.backup_redaction_context() returns jsonb
language plpgsql stable security definer set search_path to 'pg_catalog' as $$
declare
  src text; tbl text; col text; kind text; v text; f text; tok text[]; w text; d text; pads text; deny boolean := false; fast boolean := false;
  stop text[] := public.backup_stopwords();
  phrases text[] := '{}'; parts text[] := '{}'; squashed text[] := '{}'; phones text[] := '{}';
  live jsonb := '[]'::jsonb; a int; b int; ent_s2 text; ent_t text[]; ent_p text[]; ent_s text; ent_ss text[];
begin
  foreach src in array array['leads.name:n', 'leads.phone:c', 'leads.email:e', 'setters.name:n', 'setters.contact:c', 'ws_leads.name:n', 'ws_leads.phone:c', 'ws_leads.email:e',
                              'client_workspaces.name:n', 'setter_events.client:n', 'contact_suppressions.address:e', 'outbox.to_ref:c'] loop
    tbl := split_part(split_part(src, ':', 1), '.', 1); col := split_part(split_part(src, ':', 1), '.', 2); kind := split_part(src, ':', 2);
    continue when to_regclass('public.' || tbl) is null;
    continue when not exists (select 1 from pg_attribute a where a.attrelid = to_regclass('public.' || tbl) and a.attname = col and a.attnum > 0 and not a.attisdropped);
    for v in execute format('select distinct %I::text from public.%I where %I is not null', col, tbl, col) loop
      f := lower(public.backup_fold_text(btrim(v)));
      continue when length(f) < 2;
      d := regexp_replace(f, '[^0-9]', '', 'g');
      if length(d) >= 7 then phones := phones || right(d, least(length(d), 10)); continue when kind <> 'n'; end if;
      if kind = 'e' or (kind = 'c' and position('@' in f) > 0) then f := split_part(f, '@', 1); end if;     -- an email contributes its local part as a phrase, never as loose words
      tok := array(select x from unnest(regexp_split_to_array(f, '[\s.,;:/\\|()<>\[\]{}"''`~!?@#$%^&*+=_-]+')) x where x <> '');
      continue when cardinality(tok) = 0;
      continue when cardinality(tok) = 1 and length(tok[1]) < case when tok[1] ~ '[^\x01-\x7f]' then 2 else 3 end;   -- the 3-character floor is for ASCII; a 2-character CJK / Korean / Arabic name is a whole name
      ent_t := '{}'; ent_p := '{}'; ent_s := null; ent_ss := '{}';
      phrases := phrases || case when cardinality(tok) = 2 and kind <> 'e'          -- a two-part name is matched in either order ('Li, Wu' for 'Wu Li'), glued or separated
                                 then '(?:' || public.backup_re_escape(tok[1]) || '[^a-z0-9]{0,3}' || public.backup_re_escape(tok[2]) || '|' || public.backup_re_escape(tok[2]) || '[^a-z0-9]{0,3}' || public.backup_re_escape(tok[1]) || ')'
                                 else array_to_string(array(select public.backup_re_escape(x) from unnest(tok) x), '[^a-z0-9]{0,3}') end;
      if length(array_to_string(tok, '')) >= 5 then ent_s := regexp_replace(array_to_string(tok, ''), '[^a-z0-9]', '', 'g'); squashed := squashed || ent_s; ent_ss := ent_ss || ent_s; end if;
      if kind <> 'e' then
        for a in 1..least(cardinality(tok), 8) loop           -- adjacent tokens squashed ('ashgrovepellew', 'darcy'), like the deny-list capture
          for b in a + 1..least(cardinality(tok), 8) loop
            ent_s2 := regexp_replace(array_to_string(tok[a:b], ''), '[^a-z0-9]', '', 'g');
            if length(ent_s2) >= 5 and ent_s2 <> coalesce(ent_s, '') then squashed := squashed || ent_s2; ent_ss := ent_ss || ent_s2; end if;
          end loop;
        end loop;
        foreach w in array tok loop
          if length(w) >= (case when w ~ '[^\x01-\x7f]' then 2 else 3 end) and not (w = any (stop)) and w !~ '^[0-9]+$' then
            parts := parts || public.backup_re_escape(w); ent_t := ent_t || w; ent_p := ent_p || public.backup_re_escape(w);
            if length(w) >= 5 then squashed := squashed || regexp_replace(w, '[^a-z0-9]', '', 'g'); ent_ss := ent_ss || regexp_replace(w, '[^a-z0-9]', '', 'g'); end if;
          end if;
        end loop;
      end if;
      live := live || jsonb_build_object('re', phrases[cardinality(phrases)], 't', to_jsonb(ent_t), 's', ent_s, 'ss', to_jsonb(ent_ss));
    end loop;
  end loop;
  if to_regprocedure('public.redaction_pads()') is not null and to_regclass('public.ffm_redaction_denylist') is not null then
    execute 'select public.redaction_pads()' into pads;
    if pads is not null then execute 'select exists (select 1 from public.ffm_redaction_denylist)' into deny; end if;
  end if;
  begin fast := md5(pg_get_functiondef(to_regprocedure('public.ws_sensitive_hits(text)'))) = any (public.backup_detector_pins()); exception when others then fast := false; end;
  return public.backup_ctx_build(phrases, parts, squashed, phones, jsonb_build_object('deny', deny, 'scanned', false, 'fast_detector', fast, 'live', live));
end $$;

-- the context a snapshot hands to every row: only the live names that OCCUR in the exported text (found by the keyed-hash scan, which also covers live names because the triggers keep the
-- deny-list current) plus the names the deny-list adds. Names that are not in the text cannot be matched in it, and a smaller pattern is what keeps the redactor fast as the client list grows.
-- The full name pattern stays in the context ('alts_full') for the one case that needs it: a decoded base64/hex blob.
create or replace function public.backup_ctx_hot(p_ctx jsonb, p_found jsonb) returns jsonb
language plpgsql immutable set search_path to 'pg_catalog' as $$
declare e jsonb; ph text[] := '{}'; sq text[] := '{}'; names text[]; chains text[]; keep boolean; base jsonb;
begin
  base := p_ctx - 'live' - 'phrases' - 'parts' - 'name_re' - 'squashed' - 'sq_re' - 'phones' - 'n_terms';
  if coalesce(p_ctx ->> 'deny', 'false') <> 'true' or p_found is null then return p_ctx || jsonb_build_object('alts_full', coalesce(substring(p_ctx ->> 'name_re' from '^\(\?<!\[a-z0-9\]\)\(\?:(.*)\)\(\?!\[a-z0-9\]\)$'), '')); end if;
  names := array(select jsonb_array_elements_text(p_found -> 'names')); chains := array(select jsonb_array_elements_text(p_found -> 'chains'));
  for e in select * from jsonb_array_elements(p_ctx -> 'live') loop
    sq := sq || array(select jsonb_array_elements_text(coalesce(e -> 'ss', '[]'::jsonb)));       -- the squashed (spaced / glued / suffixed) forms of EVERY live name stay in the context: a token that does not occur whole can still occur letter-spaced or glued ('p i c a r d e a u', 'jpicardeau', 'picardeau1')
    keep := jsonb_array_length(e -> 't') = 0;                                     -- a name made only of operating words (a business called "Barrhaven Plumbing") is always kept
    if not keep then keep := exists (select 1 from jsonb_array_elements_text(e -> 't') z where z = any (names)); end if;
    if not keep and (e ->> 's') is not null then keep := (e ->> 's') = any (chains) or (e ->> 's') = any (names); end if;
    if keep then
      ph := ph || (e ->> 're');
      if (e ->> 's') is not null then sq := sq || (e ->> 's'); end if;
    end if;
  end loop;
  return public.backup_ctx_add(public.backup_ctx_build(ph, '{}', sq, '{}', base || jsonb_build_object('alts_full', coalesce(substring(p_ctx ->> 'name_re' from '^\(\?<!\[a-z0-9\]\)\(\?:(.*)\)\(\?!\[a-z0-9\]\)$'), ''))),
                               p_found);
end $$;

-- context for a DECODED blob (base64/hex): every live name (not only the ones that occur in the raw text) plus what the deny-list finds in the decoded text
create or replace function public.backup_ctx_blob(p_ctx jsonb, p_found jsonb) returns jsonb
language plpgsql immutable set search_path to 'pg_catalog' as $$
declare alts text; extra text[] := '{}'; x text; c jsonb := p_ctx;
begin
  if p_found is not null then c := public.backup_ctx_add(p_ctx, p_found); end if;
  if not (p_ctx ? 'alts_full') then return c; end if;
  alts := coalesce(p_ctx ->> 'alts_full', '');
  if p_found is not null then
    for x in select jsonb_array_elements_text(coalesce(p_found -> 'names', '[]'::jsonb)) loop extra := extra || public.backup_re_escape(x); end loop;
  end if;
  if alts = '' and cardinality(extra) = 0 then return c; end if;
  return c || jsonb_build_object('name_re', '(?<![a-z0-9])(?:' || array_to_string(array_remove(array[alts] || extra, ''), '|') || ')(?![a-z0-9])');
end $$;

-- SQL text that finds, in a subquery of lower-case normalised strings (column s), the candidates whose keyed hash is in the deny-list. $1 = pads.
create or replace function public.backup_deny_query(p_src text) returns text
language sql immutable set search_path to 'pg_catalog' as $$
  select format($q$
    with src as materialized (%1$s),
    toks as materialized (select distinct w from src, unnest(string_to_array(regexp_replace(src.s, '[^a-z0-9\u0080-\uffff]+', ' ', 'g'), ' ')) w where length(w) >= case when w ~ '[^\x01-\x7f]' then 2 else 3 end and w !~ '^[0-9]+$')
    select cand.k, cand.c from (
      select 'n'::text k, w c from toks
      union all select 'f', w from toks where length(w) >= 5
      union all select 'f', x.v from (select distinct substr(w, 1 + a, length(w) - a - b) v from toks, generate_series(0, 2) a, generate_series(0, 2) b where length(w) between 6 and 40 and length(w) - a - b >= 5 and (a > 0 or b > 0)) x   -- 1-2 character prefix / suffix: 'jchandrasekaran', 'chandrasekaran1', plural
      union all select 'f', x.v from (select distinct regexp_replace(w, '^[0-9]+|[0-9]+$', '', 'g') v from toks where w ~ '^[0-9]+[a-z\u0080-\uffff]|[a-z\u0080-\uffff][0-9]+$') x where length(x.v) >= 5   -- 'brackenridge2024', '2brackenridge': digits at either end
      union all select 'f', b.w from (select distinct w from src, regexp_matches(src.s, '[a-z0-9]+(?:[^a-z0-9\s]{1,2}[a-z0-9]+)+', 'g') m, lateral public.backup_windows(m[1]) w) b
      union all select 'f', c2.w from (select distinct w from src, regexp_matches(src.s, '(?<![a-z0-9])(?:[a-z0-9][ 	._-]+){2,}[a-z0-9](?![a-z0-9])', 'g') m, lateral public.backup_windows(m[1]) w) c2
      union all select 'e', e.em from (select distinct m[1] em from src, regexp_matches(src.s, '([a-z0-9._%%+''-]+@[a-z0-9-]+(?:\.[a-z0-9-]+)+)', 'g') m) e
      union all select v.kk, v.dd from (select distinct regexp_replace(m[1], '[^0-9]', '', 'g') d from src, regexp_matches(src.s, '[0-9](?:[0-9 .()/+-]{4,}[0-9])|[0-9]{7,}', 'g') m) x,
                lateral (values ('p7'::text, right(x.d, 7)), ('p10'::text, right(x.d, 10))) v (kk, dd) where length(x.d) >= 7 and (v.kk = 'p7' or length(x.d) >= 10)
    ) cand
    where exists (select 1 from public.ffm_redaction_denylist dl where dl.h = public.redaction_h($1, cand.k, cand.c) and dl.kind = cand.k)
  $q$, p_src)
$$;

-- SECURITY INVOKER on purpose: it executes SQL text. As invoker it runs with the CALLER's rights, so service_role (the lockdown migration grants it execute on everything) cannot read the key or the
-- deny-list through it, and cannot write; only the definer functions that build the text from catalog names (backup_deny_scan / backup_deny_terms) run it as the owner.
create or replace function public.backup_deny_run(p_src text, p_pads text) returns jsonb
language plpgsql stable set search_path to 'pg_catalog' as $$
declare r record; n text[] := '{}'; f text[] := '{}'; e text[] := '{}'; p text[] := '{}';
begin
  for r in execute public.backup_deny_query(p_src) using p_pads loop
    if r.k = 'n' then n := n || r.c; elsif r.k = 'f' then f := f || r.c; elsif r.k = 'e' then e := e || r.c; else p := p || r.c; end if;
  end loop;
  return jsonb_build_object('names', to_jsonb(n), 'chains', to_jsonb(f), 'emails', to_jsonb(e), 'phones', to_jsonb(p));
end $$;

-- ONE string (decoded blob, a direct call, the agent_runs trigger): the deny-list terms in it as a context addition, or null when there is nothing to check
create or replace function public.backup_deny_terms(p_text text, p_ctx jsonb) returns jsonb
language plpgsql stable set search_path to 'pg_catalog' as $$
declare pads text;
begin
  if p_text is null or coalesce(p_ctx ->> 'deny', 'false') <> 'true' then return null; end if;
  begin pads := public.redaction_pads(); exception when insufficient_privilege then return null; end;     -- SECURITY INVOKER: only a caller that may read the key (the owner, i.e. backup_snapshot / the page function / the triggers) gets deny-list answers; service_role gets none                         -- derived HERE, inside the definer function: no context, argument or result ever carries the pads
  if pads is null then return null; end if;
  return public.backup_deny_run('select ' || quote_literal(lower(public.backup_normalise(p_text))) || '::text as s', pads);
end $$;

-- every TEXT-LIKE column of the exported tables, with its class from backup_redaction_spec(); a column that is not in the spec is STRICT (fail closed) and marked unclassified

-- RE-REVIEW FIX: a column whose type the redactor does not read (bytea, name, xml, tsvector, composite, "char", jsonb[], inet, domain over json, array of enum / domain...) would be exported
-- unredacted and unflagged. backup_type_ok() lists the types that are either handled by backup_effective_spec() (text-like, json, enums, text arrays, domains over text) or cannot carry
-- a name (numbers, booleans, uuid, date/time, money, arrays of those). Any other type makes its TABLE "unclassified": not exported, listed in backup_export_policy()->unclassified.
create or replace function public.backup_type_ok(p_oid oid) returns boolean
language plpgsql stable set search_path to 'pg_catalog' as $$
declare t record; b record;
  safe constant text[] := array['bool', 'int2', 'int4', 'int8', 'numeric', 'float4', 'float8', 'uuid', 'date', 'time', 'timetz', 'timestamp', 'timestamptz', 'interval', 'money'];
  txt constant text[] := array['text', 'varchar', 'bpchar'];
begin
  select typname, typtype, typbasetype, typelem, typcategory into t from pg_type where oid = p_oid;
  if not found then return false; end if;
  if t.typtype = 'e' then return true; end if;
  if t.typname = any (safe || txt || array['citext', 'json', 'jsonb']) then return true; end if;
  if t.typtype = 'd' then
    select typname, typtype into b from pg_type where oid = t.typbasetype;
    return b.typtype = 'b' and b.typname = any (safe || txt || array['citext']);
  end if;
  if t.typcategory = 'A' and t.typelem <> 0 then
    select typname, typtype into b from pg_type where oid = t.typelem;
    return b.typtype = 'b' and b.typname = any (safe || txt);
  end if;
  return false;
end $$;

create or replace function public.backup_export_policy() returns jsonb
language plpgsql stable security definer set search_path to 'pg_catalog' as $$
declare res jsonb;
begin
  with recursive tabs as (
    select c.relname::text n from pg_class c where c.relnamespace = 'public'::regnamespace and c.relkind in ('r', 'p')
  ), base as (
    select t.n,
           case when t.n ~ '^(ws_|ffm_)' or t.n = 'client_workspaces' then 'client_pii'
                when exists (select 1 from pg_attribute a join pg_class c on c.oid = a.attrelid where c.relnamespace = 'public'::regnamespace and c.relname = t.n and a.attnum > 0 and not a.attisdropped and not public.backup_type_ok(a.atttypid)) then 'unclassified'
                else coalesce(k.data_class, 'unclassified') end as cls,
           case
             when t.n ~ '^(ws_|ffm_)' or t.n = 'client_workspaces' then 'denied by rule: client workspace tables are never exported'
             when exists (select 1 from pg_attribute a join pg_class c on c.oid = a.attrelid where c.relnamespace = 'public'::regnamespace and c.relname = t.n and a.attnum > 0 and not a.attisdropped and not public.backup_type_ok(a.atttypid))
               then 'unclassified: a column has a type the export redactor does not cover (bytea, name, xml, tsvector, composite, "char", jsonb[], inet, domains over json, arrays of enums or domains...): extend backup_type_ok() and the spec, or leave the table out'
             when k.data_class is null then 'unclassified: add it to backup_classification() in a migration'
             when k.data_class not in ('public', 'internal') then 'class ' || k.data_class
             when exists (select 1 from pg_attribute a join pg_class c on c.oid = a.attrelid
                          where c.relnamespace = 'public'::regnamespace and c.relname = t.n and a.attnum > 0 and not a.attisdropped
                            and a.attname ~* '(^|_)(email|e_mail|phone|mobile|first_?name|last_?name|full_?name|to_ref|address|payee|dob|birth[a-z]*)($|_)'
                            and not exists (select 1 from public.backup_pii_column_exceptions() x where x.table_name = t.n and x.column_name = a.attname))
               then 'column that looks like personal contact data is not on the reviewed exception list'
           end as why
      from tabs t left join public.backup_classification() k on k.table_name = t.n
  ), ex as (
    select n from base where why is not null
    union
    select c.relname::text
      from pg_constraint f join pg_class c on c.oid = f.conrelid join pg_class r on r.oid = f.confrelid join ex on ex.n = r.relname::text
     where f.contype = 'f' and c.relnamespace = 'public'::regnamespace and r.relnamespace = 'public'::regnamespace
  ), ex1 as (
    select b.n, b.cls, coalesce(b.why, 'references a table that is not exported (foreign key); a restore would load rows that point at missing data') as why
      from base b where b.n in (select n from ex)
  )
  select jsonb_build_object(
    'exported', coalesce((select jsonb_agg(n order by n) from tabs where n not in (select n from ex1)), '[]'::jsonb),
    'excluded', coalesce((select jsonb_agg(jsonb_build_object('table', n, 'class', cls, 'reason', why) order by n) from ex1), '[]'::jsonb),
    'unclassified', coalesce((select jsonb_agg(n order by n) from base where cls = 'unclassified'), '[]'::jsonb))
  into res;
  return res;
end $$;
create or replace function public.backup_effective_spec(p_exported jsonb) returns table (table_name text, column_name text, kind text, mode text, max_len integer, reason text, classified boolean)
language plpgsql stable set search_path to 'pg_catalog' as $$
begin
  return query select c.relname::text, a.attname::text,
         case when ty.typname in ('json', 'jsonb') then 'json' when ty.typcategory = 'A' then 'array' else 'text' end,
         coalesce(s.mode, 'strict'), coalesce(s.max_len, case when s.mode is null then 2000 end), coalesce(s.reason, 'NOT CLASSIFIED: treated as strict'), s.mode is not null
    from pg_class c join pg_attribute a on a.attrelid = c.oid and a.attnum > 0 and not a.attisdropped
    join pg_type ty on ty.oid = a.atttypid
    left join public.backup_redaction_spec() s on s.table_name = c.relname and s.column_name = a.attname
   where c.relnamespace = 'public'::regnamespace and c.relkind in ('r', 'p') and c.relname in (select jsonb_array_elements_text(p_exported))
     and (ty.typname in ('text', 'varchar', 'bpchar', 'citext', 'json', 'jsonb', '_text', '_varchar', '_bpchar') or ty.typtype = 'e'
          or (ty.typtype = 'd' and exists (select 1 from pg_type bt where bt.oid = ty.typbasetype and bt.typname in ('text', 'varchar', 'bpchar', 'citext'))));
end $$;

create or replace function public.backup_deny_scan(p_exported jsonb, p_ctx jsonb, p_only text default null, p_off integer default null, p_lim integer default null) returns jsonb
language plpgsql stable set search_path to 'pg_catalog' as $$
declare r record; raw text; res jsonb; n text[] := '{}'; f text[] := '{}'; e text[] := '{}'; p text[] := '{}'; pads text;
begin
  if coalesce(p_ctx ->> 'deny', 'false') <> 'true' then return null; end if;
  begin pads := public.redaction_pads(); exception when insufficient_privilege then return null; end; if pads is null then return null; end if;      -- SECURITY INVOKER (see backup_deny_terms): a caller without the key gets nothing
  for r in select * from public.backup_effective_spec(p_exported) where mode in ('strict', 'light') and (p_only is null or table_name = p_only) loop
    raw := case r.kind when 'json' then format('regexp_replace(t.%I::text, ''\\.'', '' '', ''g'')', r.column_name)
                       when 'array' then format('array_to_string(t.%I::text[], '' '')', r.column_name)
                       else format('t.%I::text', r.column_name) end;
    res := public.backup_deny_run(format('select lower(case when (octet_length(z.e) <> length(z.e) or strpos(z.e, ''%%'') > 0 or strpos(z.e, ''&'') > 0 or strpos(z.e, ''\'') > 0) then public.backup_normalise(z.e) else z.e end) as s from (select %s as e from %s t where t.%I is not null) z',
                                         raw, case when p_only is null then format('public.%I', r.table_name) else format('(select * from public.%I t order by %s offset %s limit %s)', r.table_name, public.backup_pk_order(r.table_name), p_off, p_lim) end, r.column_name), pads);
    n := n || array(select jsonb_array_elements_text(res -> 'names')); f := f || array(select jsonb_array_elements_text(res -> 'chains'));
    e := e || array(select jsonb_array_elements_text(res -> 'emails')); p := p || array(select jsonb_array_elements_text(res -> 'phones'));
  end loop;
  return jsonb_build_object('names', to_jsonb(array(select distinct x from unnest(n) x)), 'chains', to_jsonb(array(select distinct x from unnest(f) x)),
                            'emails', to_jsonb(array(select distinct x from unnest(e) x)), 'phones', to_jsonb(array(select distinct x from unnest(p) x)));
end $$;

create or replace function public.backup_redact_patterns(p_t text, p_ctx jsonb) returns text
language plpgsql stable set search_path to 'pg_catalog' as $$
declare t text := p_t; m text; d text; nre text := coalesce(p_ctx ->> 'name_re', '');
begin
  if t is null then return null; end if;
  -- URLs with a personal path / query / known name; ordinary business URLs are kept (mission evidence checks need them)
  if t ~* 'https?://|www\.' then
  for m in select x from (select distinct (regexp_matches(t, '((?:https?://|www\.)[^\s<>"'')\]]+)', 'gi'))[1] x) q order by length(x) desc loop
    if m ~* '(linkedin\.com/(?:in|pub|profile|sales/people)/|facebook\.com/(?!pages/|groups/|events/|business/|marketplace/)[^/?#]+|fb\.com/|instagram\.com/|twitter\.com/|x\.com/|tiktok\.com/@|snapchat\.com/add|youtube\.com/(?:@|user/|c/|channel/)|github\.com/[^/?#]+|/(?:~|@)[^/?#]+|/(?:profile|profiles|people|person|user|users|u|member|members|staff|team|employee|contact|about-us/team)/[^/?#]+|[?&](?:email|e-mail|mail|phone|tel|mobile|name|first|last|fname|lname|user|username|uid|contact)=|[0-9]{7,})'
       or (nre <> '' and m ~* nre) then
      t := replace(t, m, '[redacted:url]');
    end if;
  end loop;
  end if;
  -- obfuscated and plain emails (the gate: an '@', a bracketed at, or a spaced at / arobase)
  if t ~* '@|[\[({<][ \t]*(?:at|arobase)[ \t]*[\])}>]|[ \t](?:at|arobase)[ \t]' then
  t := regexp_replace(t, '[a-z0-9._%+''-]+[ \t]*[\[({<][ \t]*(?:at|arobase|@)[ \t]*[\])}>][ \t]*[a-z0-9-]+(?:[ \t]*(?:[\[({<][ \t]*(?:dot|point|\.)[ \t]*[\])}>]|\.)[ \t]*[a-z0-9-]+)+', '[redacted:email]', 'gi');
  t := regexp_replace(t, '[a-z0-9._%+''-]+[ \t]*@[ \t]*[a-z0-9-]+(?:[ \t]*(?:[\[({<][ \t]*(?:dot|point)[ \t]*[\])}>]|[ \t]+(?:dot|point)[ \t]+)[ \t]*[a-z0-9-]+)+', '[redacted:email]', 'gi');
  t := regexp_replace(t, '[a-z0-9._%+''-]{2,}[ \t]+(?:at|arobase)[ \t]+[a-z0-9-]+(?:[ \t]+(?:dot|point)[ \t]+[a-z0-9-]+)+', '[redacted:email]', 'gi');
  t := regexp_replace(t, '[a-z0-9._%+''-]{2,}[ \t]+(?:at|arobase)[ \t]+[a-z][a-z0-9-]*(?:\.[a-z0-9-]+)*\.[a-z]{2,}', '[redacted:email]', 'gi');
  t := regexp_replace(t, '[a-z0-9._%+''-]+ ?@ ?[a-z0-9-]+(?:\.[a-z0-9-]+)+', '[redacted:email]', 'gi');
  t := regexp_replace(t, '(?<![a-z0-9._@])@[a-z0-9_.]{3,}', '[redacted:handle]', 'gi');
  end if;
  -- phone numbers: NANP-shaped with one repeated separator of any kind, then generic digit groups
  t := regexp_replace(t, '(?<![0-9])\(?[0-9]{3}\)?([^a-z0-9\s])[0-9]{3}\1[0-9]{4}(?![0-9])', '[redacted:phone]', 'g');
  if t ~ '[0-9]' then
  for m in select x from (select distinct (regexp_matches(t, '([+(]?[0-9][0-9 \t.()/–—\-]{5,}[0-9])', 'g'))[1] x) q order by length(x) desc loop
    d := regexp_replace(m, '[^0-9]', '', 'g');
    if length(d) >= 9 or (left(m, 1) = '+' and length(d) >= 7) or (length(d) = 7 and m ~ '^[0-9]{3}[ .\-][0-9]{4}$') then t := replace(t, m, '[redacted:phone]'); end if;
  end loop;
  end if;
  t := regexp_replace(t, '(?<![0-9])[0-9]{7,}(?![0-9])', '[redacted:id]', 'g');      -- any other run of seven or more digits (account-like numbers, local phone numbers without punctuation)
  -- spelled-out digits (English and French) and single digits in a run of seven or more
  t := regexp_replace(t, '(?<![a-z0-9])(?:(?:zero|oh|one|two|three|four|five|six|seven|eight|nine|un|deux|trois|quatre|cinq|sept|huit|neuf|[0-9])(?:[ \t,.\-]+|$)){7,}', '[redacted:phone] ', 'gi');
  -- client names known to the database
  if nre <> '' then t := regexp_replace(t, nre, '[redacted:name]', 'gi'); end if;
  return t;
end $$;

create or replace function public.backup_probe_encoded(p_t text, p_ctx jsonb, p_depth integer default 0) returns text
language plpgsql stable set search_path to 'pg_catalog' as $$
declare t text := p_t; m text; b text; dec text; f text; padded text; c2 jsonb;
begin
  if t is null or p_depth > 2 then return t; end if;
  if t !~ '[A-Za-z0-9+/_-]{16}' then return t; end if;        -- nothing long enough to be an encoded blob
  -- hex-encoded text
  for m in select x from (select distinct (regexp_matches(t, '((?:0x)?(?:[0-9a-fA-F]{2}){8,})', 'g'))[1] x) q order by length(x) desc loop
    b := regexp_replace(m, '^0x', '');
    begin dec := convert_from(decode(b, 'hex'), 'UTF8'); exception when others then continue; end;
    continue when dec !~ '^[\x20-\x7e\t\r\n -￿]{4,}$';
    f := public.backup_fold_text(dec);
    c2 := public.backup_ctx_blob(p_ctx, public.backup_deny_terms(f, p_ctx));          -- a decoded blob may hold a name that only the deny-list knows
    if public.backup_redact_patterns(f, c2) <> f or public.backup_probe_encoded(f, c2, p_depth + 1) <> f or cardinality(public.ws_sensitive_hits(f)) > 0 then t := replace(t, m, '[redacted:encoded]'); end if;
  end loop;
  -- base64 / base64url-encoded text
  for m in select x from (select distinct (regexp_matches(t, '([A-Za-z0-9+/_-]{16,}={0,2})', 'g'))[1] x) q order by length(x) desc loop
    b := translate(rtrim(m, '='), '-_', '+/');
    continue when length(b) % 4 = 1;
    padded := b || repeat('=', (4 - length(b) % 4) % 4);
    begin dec := convert_from(decode(padded, 'base64'), 'UTF8'); exception when others then continue; end;
    continue when dec !~ '^[\x20-\x7e\t\r\n -￿]{4,}$';
    f := public.backup_fold_text(dec);
    c2 := public.backup_ctx_blob(p_ctx, public.backup_deny_terms(f, p_ctx));          -- a decoded blob may hold a name that only the deny-list knows
    if public.backup_redact_patterns(f, c2) <> f or public.backup_probe_encoded(f, c2, p_depth + 1) <> f or cardinality(public.ws_sensitive_hits(f)) > 0 then t := replace(t, m, '[redacted:encoded]'); end if;
  end loop;
  return t;
end $$;


create or replace function public.backup_redact_text_full(p text, p_ctx jsonb, p_max integer, p_mode text) returns text
language plpgsql stable set search_path to 'pg_catalog' as $$
declare
  u constant text := '[redacted:uncertain]';
  ctx jsonb; t text; t1 text; r text; nxt text; m text; i int; prot text[] := '{}'; sq text; sq2 text; s text; dg text; rt text; rc text; nre text; sqre text; hits text[]; found jsonb; plain boolean; k text; kc text; wsp text;
  is_strict boolean := (p_mode = 'strict');
  email_re constant text := '[a-z0-9._%+''-]{2,}@[a-z0-9-]{2,}(?:\.[a-z0-9-]{2,})+';
  obf_re constant text := '[a-z0-9._%+''-]{2,}[\[({<](?:at|arobase|@)[\])}>][a-z0-9-]+(?:(?:[\[({<](?:dot|point|\.)[\])}>]|\.)[a-z0-9-]+)+';
  uuid_iso constant text := '[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}|[0-9]{4}-[0-9]{2}-[0-9]{2}(?:[T ][0-9:.]+(?:Z|[+-][0-9:]+)?)?|[0-9a-fA-F]{32,}';
  phone_re constant text := '(?<![0-9])\(?[0-9]{3}\)?[ .\-][0-9]{3}[ .\-][0-9]{4}(?![0-9])|(?<![0-9])[0-9]{10,}(?![0-9])';
begin
  if p is null then return null; end if;
  if p_mode not in ('strict', 'light') then return u; end if;
  if p_max is not null and length(p) > p_max then return u; end if;
  begin
    ctx := coalesce(p_ctx, public.backup_redaction_context());
    nre := coalesce(ctx ->> 'name_re', ''); sqre := coalesce(ctx ->> 'sq_re', '');
    plain := (octet_length(p) = length(p) and strpos(p, '%') = 0 and strpos(p, '&') = 0 and strpos(p, '\') = 0);
    if not plain then                                                   -- not plain ASCII: fold look-alikes, then decode escapes until nothing changes
      t := public.backup_normalise(p);
      if is_strict and public.backup_unescape_text(t) <> t then return u; end if;     -- still decodable after four rounds: do not vouch
    else t := p; end if;
    t1 := t;
    -- A short code (action codes, statuses, ids such as 'do_not_contact') needs no further work, but ONLY when it holds no 3-digit group, no single-letter fragment ('z_o_r_b_a'),
    -- no known name and no known squashed name. (It used to return before these checks: 'tel:613-555-0199', 'zorba.trov' and 'b-o-b-n-g' went out unchanged.)
    if length(t) <= 80 and (coalesce(ctx ->> 'scanned', 'false') = 'true' or coalesce(ctx ->> 'deny', 'false') <> 'true') then
      if t ~ '^[0-9]{1,6}$' then return p; end if;
      if t ~ '^[a-z][a-z0-9]*(?:[_:./-][a-z0-9]+)*$' and t !~ '[0-9]{3}' and t !~ '(^|[_:./-])[a-z0-9]([_:./-]|$)'
         and (nre = '' or t !~* nre) and (sqre = '' or regexp_replace(t, '[^a-z0-9]', '', 'g') !~ sqre) then return p; end if;
    end if;
    -- a direct call (no snapshot scan) with a deny-list: look this one string up
    if coalesce(ctx ->> 'scanned', 'false') <> 'true' and coalesce(ctx ->> 'deny', 'false') = 'true' then
      found := public.backup_deny_terms(t, ctx);
      if found is not null then ctx := public.backup_ctx_add(ctx, found) || jsonb_build_object('scanned', true); nre := coalesce(ctx ->> 'name_re', ''); sqre := coalesce(ctx ->> 'sq_re', ''); end if;
    end if;
    -- the detector flags the whole field. Its three digit-shaped categories (sin/card/account-like) join every number in the text into one string and so flag ordinary prose with amounts and dates;
    -- those shapes are handled by this redactor's own digit rules instead. EVERY OTHER detector category blanks the field.
    if is_strict then
      if coalesce(ctx ->> 'fast_detector', 'false') = 'true' then
        if plain then
          k := lower(t); wsp := regexp_replace(k, '[^a-z0-9]+', ' ', 'g'); kc := replace(wsp, ' ', '');      -- one compaction pass, reused below
          hits := public.backup_topic_fast(k, kc);
        else hits := public.backup_topic_hits(t) || public.backup_topic_hits(p); end if;
      else hits := public.ws_sensitive_hits(p) || case when t <> p then public.ws_sensitive_hits(t) else '{}'::text[] end; end if;
      if exists (select 1 from unnest(hits) h where h not in ('sin_like_number', 'card_like_number', 'account_like_number')) then return u; end if;
    end if;
    -- ids and timestamps are protected from the digit rules
    for m in select x from (select distinct (regexp_matches(t, '([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}|(?<![0-9-])[0-9]{4}-[0-9]{2}-[0-9]{2}(?![0-9])(?:[t ][0-9]{2}:[0-9]{2}(?::[0-9]{2}(?:[.,][0-9]+)?)?(?:z|[+-][0-9]{2}(?::?[0-9]{2})?)?)?)', 'gi'))[1] x) q order by length(x) desc loop
      prot := prot || m;
      if cardinality(prot) >= 6000 then return u; end if;
      t := replace(t, m, chr(57343 + cardinality(prot)));
    end loop;
    t := public.backup_probe_encoded(t, ctx, 0);
    if (kc is null or kc ~ '[0-9a-f]{32}') and t ~* '[0-9a-f]{32}' then
      for m in select x from (select distinct (regexp_matches(t, '([0-9a-f]{32,})', 'gi'))[1] x) q order by length(x) desc loop      -- hashes (hex that is not readable text)
        continue when m !~* '[a-f]';
        prot := prot || m;
        if cardinality(prot) >= 6000 then return u; end if;
        t := replace(t, m, chr(57343 + cardinality(prot)));
      end loop;
    end if;
    r := public.backup_redact_patterns(t, ctx);
    for i in reverse cardinality(prot)..1 loop
      r := replace(r, chr(57343 + i), prot[i]);
    end loop;
    if is_strict then
      if kc is not null and r = t1 then sq := kc; else sq := lower(regexp_replace(r, '[^a-zA-Z0-9]', '', 'g')); end if;
      if sqre <> '' and sq ~ sqre then return u; end if;                                 -- a known name survives only in letter-spaced / split form
      if length(sq) >= 7 and jsonb_array_length(coalesce(ctx -> 'phones', '[]'::jsonb)) > 0 then
        dg := regexp_replace(r, '[^0-9]', '', 'g');
        for s in select jsonb_array_elements_text(ctx -> 'phones') loop
          if length(s) >= 7 and position(s in dg) > 0 then return u; end if;            -- a known phone number survives in some spaced form
        end loop;
      end if;
      if position('@' in r) > 0 or r ~* '[\[({<][ \t]*(?:at|arobase)' then
        sq2 := regexp_replace(r, '[ \t\r\n]', '', 'g');
        -- spaced-out, bracket-obfuscated or reversed email. Looked for in a window around each '@' / bracketed "at" only: running the pattern over the whole space-stripped text is quadratic.
        for m in select (regexp_matches(sq2, '(.{0,80}@.{0,160})', 'g'))[1] loop if m ~* email_re then return u; end if; end loop;
        for m in select (regexp_matches(sq2, '(.{0,80}[\[({<](?:at|arobase|@)[\])}>].{0,160})', 'gi'))[1] loop if m ~* obf_re then return u; end if; end loop;
        if position('@' in r) > 0 and reverse(r) ~* email_re then return u; end if;
        rt := translate(r, 'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ', 'nopqrstuvwxyzabcdefghijklmNOPQRSTUVWXYZABCDEFGHIJKLM');
        if rt ~* email_re then return u; end if;                                          -- ROT13 email
      end if;
      if sqre <> '' then
        rt := translate(r, 'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ', 'nopqrstuvwxyzabcdefghijklmNOPQRSTUVWXYZABCDEFGHIJKLM');
        sq2 := lower(regexp_replace(rt, '[^a-zA-Z0-9]', '', 'g'));
        if sq2 ~ sqre then
          for s in select jsonb_array_elements_text(coalesce(ctx -> 'squashed', '[]'::jsonb)) loop
            if position(s in sq2) > 0 and position(s in sq) = 0 then return u; end if;   -- ROT13 of a known name
          end loop;
        end if;
      end if;
      -- last gate = the SAME contact tests the Python lock (hq_backup.assert_redacted) applies: whatever it would refuse is blanked here, so one odd row never stops the whole backup
      if position('@' in r) > 0 and r ~* email_re then return u; end if;
      if (kc is null or kc ~ '[0-9]{10}') and r ~ phone_re then
        rc := regexp_replace(r, uuid_iso, ' ', 'g');
        if rc ~ phone_re then return u; end if;
      end if;
    end if;
    if r = t1 then return p; end if;                                                      -- nothing found: the original text, unchanged
    return r;
  exception when others then
    return u;                                                                              -- any failure: fail closed
  end;
end $$;

-- The entry point. Cheap exits first (no sub-transaction, no pattern passes) for the great majority of fields, then the full redactor. A field takes an exit ONLY when it has none of the features the
-- full redactor acts on: digits (under 7 in all), '@', URLs, long blobs, spelled-out digit runs, a known name, a known squashed name, and (strict) the topic detector is clear.
-- sqltests/leak_redaction_check.sql section G proves, on a corpus, that the exits and the full redactor give the same answer.
create or replace function public.backup_redact_text(p text, p_ctx jsonb default null, p_max integer default 20000, p_mode text default 'strict') returns text
language plpgsql stable set search_path to 'pg_catalog' as $$
declare nre text; sqre text; hits text[]; is_strict boolean := (p_mode = 'strict');
  rot26 constant text := 'nopqrstuvwxyzabcdefghijklmNOPQRSTUVWXYZABCDEFGHIJKLM';
begin
  if p is null then return null; end if;
  if p_mode not in ('strict', 'light') then return '[redacted:uncertain]'; end if;
  if p_max is not null and length(p) > p_max then return '[redacted:uncertain]'; end if;
  if p_ctx is not null and length(p) <= 300 and (p_ctx ->> 'scanned') = 'true' and octet_length(p) = length(p) and strpos(p, '%') = 0 and strpos(p, '&') = 0 and strpos(p, '\') = 0 then
    if p ~ '^[0-9]{1,6}$' then return p; end if;
    nre := coalesce(p_ctx ->> 'name_re', ''); sqre := coalesce(p_ctx ->> 'sq_re', '');
    if p !~ '(?:[0-9][^0-9A-Za-z]*){7}' and p !~ '@|[A-Za-z0-9+/_-]{16}|https?:|www\.|[\[({<][ \t]*(?:at|arobase)|[ \t](?:at|arobase)[ \t]+[a-z0-9-]+(?:[ \t]+(?:dot|point)[ \t]|\.[a-z]{2})' 
       and p !~* '(?:(?:zero|oh|one|two|three|four|five|six|seven|eight|nine|un|deux|trois|quatre|cinq|sept|huit|neuf|[0-9])[ \t,.\-]+){5}'
       and (nre = '' or p !~* nre) then
      if sqre <> '' and (lower(regexp_replace(p, '[^a-zA-Z0-9]', '', 'g')) ~ sqre or lower(regexp_replace(translate(p, 'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ', rot26), '[^a-zA-Z0-9]', '', 'g')) ~ sqre) then
        return public.backup_redact_text_full(p, p_ctx, p_max, p_mode);
      end if;
      if is_strict and (length(p) > 80 or p !~ '^[a-z][a-z0-9]*(?:[_:./-][a-z0-9]+)*$') then      -- (the old code-shortcut skipped the detector for short lower-case codes; so does this one)
        if coalesce(p_ctx ->> 'fast_detector', 'false') = 'true' then hits := public.backup_topic_hits(p); else hits := public.ws_sensitive_hits(p); end if;
        if exists (select 1 from unnest(hits) h where h not in ('sin_like_number', 'card_like_number', 'account_like_number')) then return '[redacted:uncertain]'; end if;
      end if;
      return p;
    end if;
  end if;
  return public.backup_redact_text_full(p, p_ctx, p_max, p_mode);
end $$;

create or replace function public.backup_redact_json_k(j jsonb, p_key text, p_ctx jsonb, p_max integer, p_mode text) returns jsonb
language plpgsql stable set search_path to 'pg_catalog' as $$
declare k text := lower(coalesce(p_key, '')); digits int;
begin
  if j is null then return null; end if;
  case jsonb_typeof(j)
    when 'string' then return to_jsonb(public.backup_redact_text(j #>> '{}', p_ctx, p_max, p_mode));
    when 'number' then
      if p_mode <> 'strict' then return j; end if;
      -- a number has no text to inspect, so the KEY decides: phone / SSN / account-like keys are redacted whatever the size; any other integer of 7+ digits (a phone, SIN or long id written as a number)
      -- is redacted unless the key is on the amounts allow-list. Amounts in NUMERIC COLUMNS (ledger.amount_cents ...) are never touched: this only sees numbers inside json.
      if k ~ '(^|[^a-z])(ph|phone|phones|tel|telephone|mobile|cell|cellphone|fax|ssn|sin|nas|dob|birthdate|birthday|birth|passport|licen[sc]e|card|iban|routing|transit|acct|account|accounts)([^a-z]|$)' then return to_jsonb('[redacted:key]'::text); end if;
      digits := length(regexp_replace(split_part(replace(j #>> '{}', '-', ''), '.', 1), '[^0-9]', '', 'g'));
      -- a number that IS a known phone (the live phone list, 7-10+ digits compared on the right-hand end) is redacted under ANY key, including the amount allow-list ('amount': 6135550199)
      if digits >= 7 and exists (select 1 from jsonb_array_elements_text(coalesce(p_ctx -> 'phones', '[]'::jsonb)) ph
                                 where right(ph, least(digits, 10)) = right(regexp_replace(split_part(replace(j #>> '{}', '-', ''), '.', 1), '[^0-9]', '', 'g'), least(digits, 10)) and length(ph) >= least(digits, 10))
        then return to_jsonb('[redacted:id]'::text); end if;
      if digits >= 7 and k !~ '(^|_)(txid|xid|pid|seq|epoch|attempts|retries|amount|amt|cents|total|count|qty|quantity|sum|price|cost|fee|fees|balance|bytes|rows|chars|length|ms|secs|seconds|minutes|hours|days|limit|max|min|in|out|tokens|searches|spent|budget|cap|usd|cad|per_[a-z]+|to_cents|from_cents)($|_)'
        then return to_jsonb('[redacted:id]'::text); end if;
      return j;
    when 'object' then return coalesce((select jsonb_object_agg(
        case when p_mode = 'strict' and coalesce(kc.c ->> 'sq_re', '') <> '' and regexp_replace(lower(public.backup_fold_text(e.k)), '[^a-z0-9]', '', 'g') ~ (kc.c ->> 'sq_re') then '[redacted:key]'     -- a key that holds a known name in spaced / glued form
             else public.backup_redact_text(e.k, p_ctx, null, 'light') end,
        public.backup_redact_json_k(e.v, e.k, p_ctx, p_max, p_mode))
      from jsonb_each(j) e (k, v),
           lateral (select case when p_mode = 'strict' and coalesce(p_ctx ->> 'scanned', 'false') <> 'true' and coalesce(p_ctx ->> 'deny', 'false') = 'true' and length(e.k) >= 5
                                then public.backup_ctx_blob(p_ctx, public.backup_deny_terms(e.k, p_ctx)) else p_ctx end c) kc), '{}'::jsonb);     -- an UNSCANNED context (a direct call) asks the deny-list about the key too; the export scan already did
    when 'array' then return coalesce((select jsonb_agg(public.backup_redact_json_k(a.v, p_key, p_ctx, p_max, p_mode) order by a.ord) from jsonb_array_elements(j) with ordinality a (v, ord)), '[]'::jsonb);
    else return j;
  end case;
end $$;

create or replace function public.backup_redact_json(j jsonb, p_ctx jsonb, p_max integer default 500, p_mode text default 'strict') returns jsonb
language sql stable set search_path to 'pg_catalog' as $$ select public.backup_redact_json_k(j, null, p_ctx, p_max, p_mode) $$;

create or replace function public.backup_redact_array(a text[], p_ctx jsonb, p_max integer, p_mode text) returns jsonb
language sql stable set search_path to 'pg_catalog' as $$
  select case when a is null then null else coalesce((select jsonb_agg(public.backup_redact_text(x, p_ctx, p_max, p_mode) order by o) from unnest(a) with ordinality z (x, o)), '[]'::jsonb) end
$$;

-- THE reviewed classification of EVERY text-like column (text, varchar, json, jsonb, text[]) of every exported table. One line of reason each.
--   strict  fail closed: the field becomes '[redacted:uncertain]' when it cannot be vouched for (the leak paths: names, payers, owner text, agent output)
--   light   patterns and known names only; a field is never blanked for its topic
--   keep    identifier / status / code / hash / the owner's own setting: not free text, never altered (an altered slug or status would break foreign keys and restores)
--   blank   not exported at all: the value is replaced by an empty string (NOT NULL columns stay valid)
-- A column that is NOT in this list is treated as STRICT by backup_snapshot() and reported under redaction.unclassified_columns; sqltests/leak_redaction_check.sql (section F) FAILS when one exists,
-- so adding a text column to an exported table cannot silently leak and cannot go unreviewed.
create or replace function public.backup_redaction_spec() returns table (table_name text, column_name text, kind text, mode text, max_len integer, reason text)
language sql immutable set search_path to 'pg_catalog' as $$
  select * from (values
    ('account_requests', 'account_login', 'text', 'keep', null, 'identifier, status, code, hash or the owner/business own setting; not free text'),
    ('account_requests', 'needs', 'array', 'keep', null, 'identifier, status, code, hash or the owner/business own setting; not free text'),
    ('account_requests', 'purpose', 'text', 'light', null, 'free text or title: patterns and known names only (never blanked)'),
    ('account_requests', 'requested_by', 'text', 'keep', null, 'identifier, status, code, hash or the owner/business own setting; not free text'),
    ('account_requests', 'signup_url', 'text', 'light', null, 'free text or title: patterns and known names only (never blanked)'),
    ('account_requests', 'status', 'text', 'keep', null, 'identifier, status, code, hash or the owner/business own setting; not free text'),
    ('account_requests', 'vendor', 'text', 'light', null, 'free text or title: patterns and known names only (never blanked)'),
    ('accounts_registry', 'created_by', 'text', 'keep', null, 'identifier, status, code, hash or the owner/business own setting; not free text'),
    ('accounts_registry', 'login_email', 'text', 'keep', null, 'identifier, status, code, hash or the owner/business own setting; not free text'),
    ('accounts_registry', 'notes', 'text', 'light', null, 'free text or title: patterns and known names only (never blanked)'),
    ('accounts_registry', 'purpose', 'text', 'light', null, 'free text or title: patterns and known names only (never blanked)'),
    ('accounts_registry', 'service', 'text', 'keep', null, 'identifier, status, code, hash or the owner/business own setting; not free text'),
    ('accounts_registry', 'status', 'text', 'keep', null, 'identifier, status, code, hash or the owner/business own setting; not free text'),
    ('accounts_registry', 'vault_ref', 'text', 'keep', null, 'identifier, status, code, hash or the owner/business own setting; not free text'),
    ('action_log', 'action', 'text', 'keep', null, 'identifier, status, code, hash or the owner/business own setting; not free text'),
    ('action_log', 'actor', 'text', 'keep', null, 'identifier, status, code, hash or the owner/business own setting; not free text'),
    ('action_log', 'decision', 'text', 'keep', null, 'identifier, status, code, hash or the owner/business own setting; not free text'),
    ('action_log', 'detail', 'json', 'strict', 1000, 'json detail'),
    ('action_log', 'evidence', 'text', 'strict', 2000, 'free text evidence'),
    ('action_log', 'reason', 'text', 'strict', 1000, 'free text reason'),
    ('action_log', 'ref', 'text', 'keep', null, 'unique key or system reference (table/id, dedupe key, url key): altering it could collide on restore or break lookups; written by code, not typed text'),
    ('action_log', 'result', 'text', 'strict', 1000, 'free text result'),
    ('action_log', 'tier', 'text', 'keep', null, 'identifier, status, code, hash or the owner/business own setting; not free text'),
    ('action_policy', 'action', 'text', 'keep', null, 'identifier, status, code, hash or the owner/business own setting; not free text'),
    ('action_policy', 'description', 'text', 'light', null, 'free text or title: patterns and known names only (never blanked)'),
    ('action_policy', 'tier', 'text', 'keep', null, 'identifier, status, code, hash or the owner/business own setting; not free text'),
    ('action_policy', 'updated_by', 'text', 'keep', null, 'identifier, status, code, hash or the owner/business own setting; not free text'),
    ('agent_runs', 'status', 'text', 'keep', null, 'identifier, status, code, hash or the owner/business own setting; not free text'),
    ('agent_runs', 'summary', 'text', 'strict', 4000, 'agent output'),
    ('agents', 'charter', 'text', 'light', null, 'free text or title: patterns and known names only (never blanked)'),
    ('agents', 'department_slug', 'text', 'keep', null, 'identifier, status, code, hash or the owner/business own setting; not free text'),
    ('agents', 'metric', 'text', 'light', null, 'free text or title: patterns and known names only (never blanked)'),
    ('agents', 'model_tier', 'text', 'keep', null, 'identifier, status, code, hash or the owner/business own setting; not free text'),
    ('agents', 'office_function', 'text', 'light', null, 'free text or title: patterns and known names only (never blanked)'),
    ('agents', 'role', 'text', 'keep', null, 'identifier, status, code, hash or the owner/business own setting; not free text'),
    ('agents', 'slug', 'text', 'keep', null, 'identifier, status, code, hash or the owner/business own setting; not free text'),
    ('agents', 'status', 'text', 'keep', null, 'identifier, status, code, hash or the owner/business own setting; not free text'),
    ('agents', 'title', 'text', 'light', null, 'free text or title: patterns and known names only (never blanked)'),
    ('alert_state', 'key', 'text', 'keep', null, 'identifier, status, code, hash or the owner/business own setting; not free text'),
    ('app_owners', 'email', 'text', 'keep', null, 'identifier, status, code, hash or the owner/business own setting; not free text'),
    ('approval_requests', 'action', 'text', 'keep', null, 'identifier, status, code, hash or the owner/business own setting; not free text'),
    ('approval_requests', 'actor', 'text', 'keep', null, 'identifier, status, code, hash or the owner/business own setting; not free text'),
    ('approval_requests', 'recommendation', 'text', 'strict', 2000, 'agent free text recommendation'),
    ('approval_requests', 'ref', 'text', 'keep', null, 'unique key or system reference (table/id, dedupe key, url key): altering it could collide on restore or break lookups; written by code, not typed text'),
    ('approval_requests', 'status', 'text', 'keep', null, 'identifier, status, code, hash or the owner/business own setting; not free text'),
    ('audit_log', 'action', 'text', 'keep', null, 'identifier, status, code, hash or the owner/business own setting; not free text'),
    ('audit_log', 'actor', 'text', 'keep', null, 'identifier, status, code, hash or the owner/business own setting; not free text'),
    ('audit_log', 'detail', 'json', 'strict', 500, 'free text copied from owner/agent actions (reason, notes)'),
    ('audit_log', 'target', 'text', 'keep', null, 'unique key or system reference (table/id, dedupe key, url key): altering it could collide on restore or break lookups; written by code, not typed text'),
    ('bank_accounts', 'currency', 'text', 'keep', null, 'identifier, status, code, hash or the owner/business own setting; not free text'),
    ('bank_accounts', 'institution', 'text', 'keep', null, 'identifier, status, code, hash or the owner/business own setting; not free text'),
    ('bank_accounts', 'label', 'text', 'light', null, 'free text or title: patterns and known names only (never blanked)'),
    ('bank_accounts', 'last4', 'text', 'keep', null, 'identifier, status, code, hash or the owner/business own setting; not free text'),
    ('bank_balances', 'entered_by', 'text', 'keep', null, 'identifier, status, code, hash or the owner/business own setting; not free text'),
    ('bank_balances', 'source', 'text', 'light', null, 'free text or title: patterns and known names only (never blanked)'),
    ('bank_transactions', 'dedupe_key', 'text', 'keep', null, 'unique key or system reference (table/id, dedupe key, url key): altering it could collide on restore or break lookups; written by code, not typed text'),
    ('bank_transactions', 'description', 'text', 'strict', 500, 'bank statement text: payer / payee names'),
    ('bank_transactions', 'note', 'text', 'strict', 500, 'free text note on a transaction'),
    ('bank_transactions', 'status', 'text', 'keep', null, 'identifier, status, code, hash or the owner/business own setting; not free text'),
    ('build_requests', 'approved_by', 'text', 'keep', null, 'identifier, status, code, hash or the owner/business own setting; not free text'),
    ('build_requests', 'qa_agent', 'text', 'keep', null, 'identifier, status, code, hash or the owner/business own setting; not free text'),
    ('build_requests', 'requested_by', 'text', 'keep', null, 'identifier, status, code, hash or the owner/business own setting; not free text'),
    ('build_requests', 'risk', 'text', 'light', null, 'free text or title: patterns and known names only (never blanked)'),
    ('build_requests', 'rollback_plan', 'text', 'light', null, 'free text or title: patterns and known names only (never blanked)'),
    ('build_requests', 'spec', 'text', 'light', null, 'free text or title: patterns and known names only (never blanked)'),
    ('build_requests', 'status', 'text', 'keep', null, 'identifier, status, code, hash or the owner/business own setting; not free text'),
    ('build_requests', 'test_result', 'text', 'light', null, 'free text or title: patterns and known names only (never blanked)'),
    ('build_requests', 'title', 'text', 'light', null, 'free text or title: patterns and known names only (never blanked)'),
    ('capital_policy', 'last_mode', 'text', 'light', null, 'free text or title: patterns and known names only (never blanked)'),
    ('capital_policy', 'updated_by', 'text', 'keep', null, 'identifier, status, code, hash or the owner/business own setting; not free text'),
    ('company_profile', 'brand', 'text', 'light', null, 'free text or title: patterns and known names only (never blanked)'),
    ('company_profile', 'mailing_address', 'text', 'light', null, 'free text or title: patterns and known names only (never blanked)'),
    ('company_profile', 'reply_email', 'text', 'keep', null, 'identifier, status, code, hash or the owner/business own setting; not free text'),
    ('company_profile', 'sender_name', 'text', 'light', null, 'free text or title: patterns and known names only (never blanked)'),
    ('company_profile', 'venture_slug', 'text', 'keep', null, 'identifier, status, code, hash or the owner/business own setting; not free text'),
    ('departments', 'kind', 'text', 'keep', null, 'identifier, status, code, hash or the owner/business own setting; not free text'),
    ('departments', 'name', 'text', 'light', null, 'free text or title: patterns and known names only (never blanked)'),
    ('departments', 'slug', 'text', 'keep', null, 'identifier, status, code, hash or the owner/business own setting; not free text'),
    ('departments', 'status', 'text', 'keep', null, 'identifier, status, code, hash or the owner/business own setting; not free text'),
    ('escalations', 'department_slug', 'text', 'keep', null, 'identifier, status, code, hash or the owner/business own setting; not free text'),
    ('escalations', 'evidence', 'json', 'light', null, 'free text or title: patterns and known names only (never blanked)'),
    ('escalations', 'from_agent', 'text', 'keep', null, 'identifier, status, code, hash or the owner/business own setting; not free text'),
    ('escalations', 'kind', 'text', 'keep', null, 'identifier, status, code, hash or the owner/business own setting; not free text'),
    ('escalations', 'resolution', 'text', 'light', null, 'free text or title: patterns and known names only (never blanked)'),
    ('escalations', 'status', 'text', 'keep', null, 'identifier, status, code, hash or the owner/business own setting; not free text'),
    ('escalations', 'summary', 'text', 'strict', 4000, 'agent output'),
    ('evidence_sources', 'content_sha256', 'text', 'keep', null, 'identifier, status, code, hash or the owner/business own setting; not free text'),
    ('evidence_sources', 'content_type', 'text', 'keep', null, 'identifier, status, code, hash or the owner/business own setting; not free text'),
    ('evidence_sources', 'final_url', 'text', 'light', null, 'the URL that was fetched (a prospect page can carry a name or an email): the light twin of url; same pattern and known-name redaction, never blanked. Uniqueness on restore also rests on content_sha256'),
    ('evidence_sources', 'flags', 'json', 'keep', null, 'identifier, status, code, hash or the owner/business own setting; not free text'),
    ('evidence_sources', 'host_norm', 'text', 'keep', null, 'identifier, status, code, hash or the owner/business own setting; not free text'),
    ('evidence_sources', 'kind', 'text', 'keep', null, 'identifier, status, code, hash or the owner/business own setting; not free text'),
    ('evidence_sources', 'text', 'text', 'blank', null, 'public web page bodies (up to 40k chars each): bulk third-party text, rebuildable by re-fetching; not copied off-site (exported as an empty string; sha256 and url stay)'),
    ('evidence_sources', 'title', 'text', 'light', null, 'free text or title: patterns and known names only (never blanked)'),
    ('evidence_sources', 'url', 'text', 'light', null, 'free text or title: patterns and known names only (never blanked)'),
    ('executor_registry', 'allowed_agents', 'array', 'keep', null, 'identifier, status, code, hash or the owner/business own setting; not free text'),
    ('executor_registry', 'kind', 'text', 'keep', null, 'identifier, status, code, hash or the owner/business own setting; not free text'),
    ('executor_registry', 'note', 'text', 'light', null, 'free text or title: patterns and known names only (never blanked)'),
    ('executor_registry', 'slug', 'text', 'keep', null, 'identifier, status, code, hash or the owner/business own setting; not free text'),
    ('executor_runs', 'agent_slug', 'text', 'keep', null, 'identifier, status, code, hash or the owner/business own setting; not free text'),
    ('executor_runs', 'executor', 'text', 'light', null, 'free text or title: patterns and known names only (never blanked)'),
    ('executor_runs', 'purpose', 'text', 'light', null, 'free text or title: patterns and known names only (never blanked)'),
    ('executor_runs', 'refusal_reason', 'text', 'strict', 1000, 'free text reason'),
    ('executor_runs', 'result_sha256', 'text', 'keep', null, 'identifier, status, code, hash or the owner/business own setting; not free text'),
    ('executor_runs', 'status', 'text', 'keep', null, 'identifier, status, code, hash or the owner/business own setting; not free text'),
    ('handbook', 'content', 'text', 'light', null, 'free text or title: patterns and known names only (never blanked)'),
    ('human_handoffs', 'requested_by', 'text', 'keep', null, 'identifier, status, code, hash or the owner/business own setting; not free text'),
    ('human_handoffs', 'status', 'text', 'keep', null, 'identifier, status, code, hash or the owner/business own setting; not free text'),
    ('human_handoffs', 'task', 'text', 'light', null, 'free text or title: patterns and known names only (never blanked)'),
    ('human_handoffs', 'url', 'text', 'light', null, 'free text or title: patterns and known names only (never blanked)'),
    ('human_handoffs', 'why_human', 'text', 'light', null, 'free text or title: patterns and known names only (never blanked)'),
    ('ideas', 'demand_source', 'text', 'light', null, 'free text or title: patterns and known names only (never blanked)'),
    ('ideas', 'description', 'text', 'strict', 2000, 'free text'),
    ('ideas', 'kill_metric', 'text', 'light', null, 'free text or title: patterns and known names only (never blanked)'),
    ('ideas', 'name', 'text', 'light', null, 'free text or title: patterns and known names only (never blanked)'),
    ('ideas', 'result', 'text', 'strict', 4000, 'agent output'),
    ('ideas', 'revisit_trigger', 'text', 'light', null, 'free text or title: patterns and known names only (never blanked)'),
    ('ideas', 'status', 'text', 'keep', null, 'identifier, status, code, hash or the owner/business own setting; not free text'),
    ('ideas', 'verdict', 'text', 'keep', null, 'identifier, status, code, hash or the owner/business own setting; not free text'),
    ('integration_status', 'detail', 'text', 'light', null, 'free text or title: patterns and known names only (never blanked)'),
    ('integration_status', 'key', 'text', 'keep', null, 'identifier, status, code, hash or the owner/business own setting; not free text'),
    ('ledger', 'currency', 'text', 'keep', null, 'identifier, status, code, hash or the owner/business own setting; not free text'),
    ('ledger', 'kind', 'text', 'keep', null, 'identifier, status, code, hash or the owner/business own setting; not free text'),
    ('ledger', 'note', 'text', 'strict', 500, 'free text; names of payers/payees and setters'),
    ('ledger', 'original_currency', 'text', 'keep', null, 'identifier, status, code, hash or the owner/business own setting; not free text'),
    ('ledger', 'status', 'text', 'keep', null, 'identifier, status, code, hash or the owner/business own setting; not free text'),
    ('llm_calls', 'agent_slug', 'text', 'keep', null, 'identifier, status, code, hash or the owner/business own setting; not free text'),
    ('llm_calls', 'model', 'text', 'keep', null, 'identifier, status, code, hash or the owner/business own setting; not free text'),
    ('llm_calls', 'purpose', 'text', 'light', null, 'free text or title: patterns and known names only (never blanked)'),
    ('llm_calls', 'status', 'text', 'keep', null, 'identifier, status, code, hash or the owner/business own setting; not free text'),
    ('memory', 'agent', 'text', 'keep', null, 'identifier, status, code, hash or the owner/business own setting; not free text'),
    ('memory', 'confidence', 'text', 'keep', null, 'identifier, status, code, hash or the owner/business own setting; not free text'),
    ('memory', 'content', 'text', 'light', null, 'free text or title: patterns and known names only (never blanked)'),
    ('memory', 'kind', 'text', 'keep', null, 'identifier, status, code, hash or the owner/business own setting; not free text'),
    ('memory', 'source', 'text', 'light', null, 'free text or title: patterns and known names only (never blanked)'),
    ('mission_outcomes', 'verdict', 'text', 'keep', null, 'identifier, status, code, hash or the owner/business own setting; not free text'),
    ('missions', 'checkpoint', 'json', 'strict', 4000, 'checkpoint json'),
    ('missions', 'created_by', 'text', 'keep', null, 'identifier, status, code, hash or the owner/business own setting; not free text'),
    ('missions', 'evidence', 'json', 'strict', 8000, 'mission evidence json: cited sources and quotes'),
    ('missions', 'next_action', 'text', 'light', null, 'free text or title: patterns and known names only (never blanked)'),
    ('missions', 'objective', 'text', 'strict', 4000, 'owner-typed mission text'),
    ('missions', 'owner_decision', 'text', 'light', null, 'free text or title: patterns and known names only (never blanked)'),
    ('missions', 'plan', 'json', 'strict', 8000, 'plan json with step text'),
    ('missions', 'result', 'text', 'light', null, 'free text or title: patterns and known names only (never blanked)'),
    ('missions', 'risks', 'text', 'light', null, 'free text or title: patterns and known names only (never blanked)'),
    ('missions', 'status', 'text', 'keep', null, 'identifier, status, code, hash or the owner/business own setting; not free text'),
    ('missions', 'success_definition', 'text', 'light', null, 'free text or title: patterns and known names only (never blanked)'),
    ('missions', 'title', 'text', 'strict', 500, 'owner-typed mission text'),
    ('missions', 'verdict', 'text', 'keep', null, 'identifier, status, code, hash or the owner/business own setting; not free text'),
    ('missions', 'verdict_reason', 'text', 'light', null, 'free text or title: patterns and known names only (never blanked)'),
    ('model_prices', 'model', 'text', 'keep', null, 'identifier, status, code, hash or the owner/business own setting; not free text'),
    ('model_prices', 'source', 'text', 'light', null, 'free text or title: patterns and known names only (never blanked)'),
    ('model_prices', 'tier', 'text', 'keep', null, 'identifier, status, code, hash or the owner/business own setting; not free text'),
    ('org_changes', 'alternatives', 'text', 'light', null, 'free text or title: patterns and known names only (never blanked)'),
    ('org_changes', 'change', 'text', 'light', null, 'free text or title: patterns and known names only (never blanked)'),
    ('org_changes', 'cost', 'text', 'light', null, 'free text or title: patterns and known names only (never blanked)'),
    ('org_changes', 'disagrees_with_owner', 'text', 'light', null, 'free text or title: patterns and known names only (never blanked)'),
    ('org_changes', 'gain', 'text', 'light', null, 'free text or title: patterns and known names only (never blanked)'),
    ('org_changes', 'kind', 'text', 'keep', null, 'identifier, status, code, hash or the owner/business own setting; not free text'),
    ('org_changes', 'proposed_by', 'text', 'keep', null, 'identifier, status, code, hash or the owner/business own setting; not free text'),
    ('org_changes', 'risk', 'text', 'light', null, 'free text or title: patterns and known names only (never blanked)'),
    ('org_changes', 'status', 'text', 'keep', null, 'identifier, status, code, hash or the owner/business own setting; not free text'),
    ('org_changes', 'target', 'text', 'light', null, 'free text or title: patterns and known names only (never blanked)'),
    ('org_changes', 'time_to_results', 'text', 'light', null, 'free text or title: patterns and known names only (never blanked)'),
    ('owner_messages', 'answer', 'text', 'strict', 2000, 'owner free-text answer'),
    ('owner_messages', 'body', 'text', 'light', null, 'free text or title: patterns and known names only (never blanked)'),
    ('owner_messages', 'channel', 'text', 'keep', null, 'identifier, status, code, hash or the owner/business own setting; not free text'),
    ('owner_messages', 'decision', 'text', 'keep', null, 'identifier, status, code, hash or the owner/business own setting; not free text'),
    ('owner_messages', 'from_agent', 'text', 'keep', null, 'identifier, status, code, hash or the owner/business own setting; not free text'),
    ('owner_messages', 'kind', 'text', 'keep', null, 'identifier, status, code, hash or the owner/business own setting; not free text'),
    ('owner_messages', 'options', 'json', 'strict', 2000, 'option text json'),
    ('owner_messages', 'ref_table', 'text', 'keep', null, 'identifier, status, code, hash or the owner/business own setting; not free text'),
    ('payment_instructions', 'payee', 'text', 'strict', 300, 'payee: a person or company'),
    ('payment_instructions', 'purpose', 'text', 'light', null, 'free text or title: patterns and known names only (never blanked)'),
    ('payment_instructions', 'receipt_ref', 'text', 'light', null, 'free text or title: patterns and known names only (never blanked)'),
    ('payment_instructions', 'requested_by', 'text', 'keep', null, 'identifier, status, code, hash or the owner/business own setting; not free text'),
    ('payment_instructions', 'status', 'text', 'keep', null, 'identifier, status, code, hash or the owner/business own setting; not free text'),
    ('predictions', 'action_ref', 'text', 'light', null, 'free text or title: patterns and known names only (never blanked)'),
    ('predictions', 'agent_slug', 'text', 'keep', null, 'identifier, status, code, hash or the owner/business own setting; not free text'),
    ('predictions', 'expected', 'text', 'light', null, 'free text or title: patterns and known names only (never blanked)'),
    ('predictions', 'outcome', 'text', 'light', null, 'free text or title: patterns and known names only (never blanked)'),
    ('reconciliation_flags', 'check_name', 'text', 'keep', null, 'identifier, status, code, hash or the owner/business own setting; not free text'),
    ('reconciliation_flags', 'detail', 'text', 'strict', 1000, 'free text with bank transaction text'),
    ('reconciliation_flags', 'status', 'text', 'keep', null, 'identifier, status, code, hash or the owner/business own setting; not free text'),
    ('spend_reservations', 'action', 'text', 'keep', null, 'identifier, status, code, hash or the owner/business own setting; not free text'),
    ('spend_reservations', 'actor', 'text', 'keep', null, 'identifier, status, code, hash or the owner/business own setting; not free text'),
    ('spend_reservations', 'alternatives', 'text', 'light', null, 'free text or title: patterns and known names only (never blanked)'),
    ('spend_reservations', 'expected_benefit', 'text', 'light', null, 'free text or title: patterns and known names only (never blanked)'),
    ('spend_reservations', 'purpose', 'text', 'light', null, 'free text or title: patterns and known names only (never blanked)'),
    ('spend_reservations', 'receipt_ref', 'text', 'light', null, 'free text or title: patterns and known names only (never blanked)'),
    ('spend_reservations', 'status', 'text', 'keep', null, 'identifier, status, code, hash or the owner/business own setting; not free text'),
    ('spend_reservations', 'vendor', 'text', 'light', null, 'free text or title: patterns and known names only (never blanked)'),
    ('system_state', 'mode', 'text', 'keep', null, 'identifier, status, code, hash or the owner/business own setting; not free text'),
    ('system_state', 'pause_reason', 'text', 'light', null, 'free text or title: patterns and known names only (never blanked)'),
    ('systems', 'data_store', 'text', 'light', null, 'free text or title: patterns and known names only (never blanked)'),
    ('systems', 'health_url', 'text', 'light', null, 'free text or title: patterns and known names only (never blanked)'),
    ('systems', 'host', 'text', 'light', null, 'free text or title: patterns and known names only (never blanked)'),
    ('systems', 'name', 'text', 'light', null, 'free text or title: patterns and known names only (never blanked)'),
    ('systems', 'notes', 'text', 'light', null, 'free text or title: patterns and known names only (never blanked)'),
    ('systems', 'repo', 'text', 'light', null, 'free text or title: patterns and known names only (never blanked)'),
    ('systems', 'slug', 'text', 'keep', null, 'identifier, status, code, hash or the owner/business own setting; not free text'),
    ('systems', 'url', 'text', 'light', null, 'free text or title: patterns and known names only (never blanked)'),
    ('systems', 'venture_slug', 'text', 'keep', null, 'identifier, status, code, hash or the owner/business own setting; not free text'),
    ('systems', 'warmup_local_times', 'array', 'keep', null, 'identifier, status, code, hash or the owner/business own setting; not free text'),
    ('tasks', 'assigned_agent', 'text', 'keep', null, 'identifier, status, code, hash or the owner/business own setting; not free text'),
    ('tasks', 'created_by', 'text', 'keep', null, 'identifier, status, code, hash or the owner/business own setting; not free text'),
    ('tasks', 'dedupe_key', 'text', 'keep', null, 'unique key or system reference (table/id, dedupe key, url key): altering it could collide on restore or break lookups; written by code, not typed text'),
    ('tasks', 'detail', 'text', 'light', null, 'free text or title: patterns and known names only (never blanked)'),
    ('tasks', 'mission_role', 'text', 'keep', null, 'identifier, status, code, hash or the owner/business own setting; not free text'),
    ('tasks', 'result', 'text', 'strict', 20000, 'agent output: researched prospects, names, emails, phones'),
    ('tasks', 'status', 'text', 'keep', null, 'identifier, status, code, hash or the owner/business own setting; not free text'),
    ('tasks', 'title', 'text', 'light', null, 'free text or title: patterns and known names only (never blanked)'),
    ('tool_registry', 'currency', 'text', 'keep', null, 'identifier, status, code, hash or the owner/business own setting; not free text'),
    ('tool_registry', 'kind', 'text', 'keep', null, 'identifier, status, code, hash or the owner/business own setting; not free text'),
    ('tool_registry', 'notes', 'text', 'light', null, 'free text or title: patterns and known names only (never blanked)'),
    ('tool_registry', 'owner_agent', 'text', 'keep', null, 'identifier, status, code, hash or the owner/business own setting; not free text'),
    ('tool_registry', 'purpose', 'text', 'light', null, 'free text or title: patterns and known names only (never blanked)'),
    ('tool_registry', 'slug', 'text', 'keep', null, 'identifier, status, code, hash or the owner/business own setting; not free text'),
    ('tool_registry', 'status', 'text', 'keep', null, 'identifier, status, code, hash or the owner/business own setting; not free text'),
    ('venture_assets', 'created_by', 'text', 'keep', null, 'identifier, status, code, hash or the owner/business own setting; not free text'),
    ('venture_assets', 'kind', 'text', 'keep', null, 'identifier, status, code, hash or the owner/business own setting; not free text'),
    ('venture_assets', 'name', 'text', 'light', null, 'free text or title: patterns and known names only (never blanked)'),
    ('venture_assets', 'notes', 'text', 'light', null, 'free text or title: patterns and known names only (never blanked)'),
    ('venture_assets', 'status', 'text', 'keep', null, 'identifier, status, code, hash or the owner/business own setting; not free text'),
    ('venture_assets', 'url', 'text', 'light', null, 'free text or title: patterns and known names only (never blanked)'),
    ('venture_config', 'call_to_action', 'text', 'light', null, 'free text or title: patterns and known names only (never blanked)'),
    ('venture_config', 'offer', 'text', 'light', null, 'free text or title: patterns and known names only (never blanked)'),
    ('venture_config', 'updated_by', 'text', 'keep', null, 'identifier, status, code, hash or the owner/business own setting; not free text'),
    ('venture_goals', 'created_by', 'text', 'keep', null, 'identifier, status, code, hash or the owner/business own setting; not free text'),
    ('venture_goals', 'metric', 'text', 'light', null, 'free text or title: patterns and known names only (never blanked)'),
    ('venture_goals', 'status', 'text', 'keep', null, 'identifier, status, code, hash or the owner/business own setting; not free text'),
    ('venture_goals', 'unit', 'text', 'light', null, 'free text or title: patterns and known names only (never blanked)'),
    ('venture_procedures', 'created_by', 'text', 'keep', null, 'identifier, status, code, hash or the owner/business own setting; not free text'),
    ('venture_procedures', 'owner_agent', 'text', 'keep', null, 'identifier, status, code, hash or the owner/business own setting; not free text'),
    ('venture_procedures', 'status', 'text', 'keep', null, 'identifier, status, code, hash or the owner/business own setting; not free text'),
    ('venture_procedures', 'steps', 'text', 'light', null, 'free text or title: patterns and known names only (never blanked)'),
    ('venture_procedures', 'title', 'text', 'keep', null, 'unique key or system reference (table/id, dedupe key, url key): altering it could collide on restore or break lookups; written by code, not typed text'),
    ('ventures', 'description', 'text', 'light', null, 'free text or title: patterns and known names only (never blanked)'),
    ('ventures', 'gate_criteria', 'text', 'light', null, 'free text or title: patterns and known names only (never blanked)'),
    ('ventures', 'kind', 'text', 'keep', null, 'identifier, status, code, hash or the owner/business own setting; not free text'),
    ('ventures', 'manager_agent', 'text', 'keep', null, 'identifier, status, code, hash or the owner/business own setting; not free text'),
    ('ventures', 'name', 'text', 'light', null, 'free text or title: patterns and known names only (never blanked)'),
    ('ventures', 'primary_metric', 'text', 'light', null, 'free text or title: patterns and known names only (never blanked)'),
    ('ventures', 'proposed_by', 'text', 'keep', null, 'identifier, status, code, hash or the owner/business own setting; not free text'),
    ('ventures', 'slug', 'text', 'keep', null, 'identifier, status, code, hash or the owner/business own setting; not free text'),
    ('ventures', 'stage', 'text', 'keep', null, 'identifier, status, code, hash or the owner/business own setting; not free text'),
    ('ventures', 'status', 'text', 'keep', null, 'identifier, status, code, hash or the owner/business own setting; not free text'),
    ('waterfall_policy', 'updated_by', 'text', 'keep', null, 'identifier, status, code, hash or the owner/business own setting; not free text'),
    ('web_messages', 'body', 'text', 'strict', 4000, 'owner chat: people and numbers typed by the owner'),
    ('web_messages', 'kind', 'text', 'keep', null, 'identifier, status, code, hash or the owner/business own setting; not free text'),
    ('web_messages', 'payload', 'json', 'strict', 2000, 'owner chat payload json'),
    ('web_messages', 'role', 'text', 'keep', null, 'identifier, status, code, hash or the owner/business own setting; not free text'),
    ('web_messages', 'status', 'text', 'keep', null, 'identifier, status, code, hash or the owner/business own setting; not free text')
  ) v (table_name, column_name, kind, mode, max_len, reason)
$$;

create or replace function public.backup_redact_row(p_table text, p_row jsonb, p_ctx jsonb) returns jsonb
language plpgsql stable set search_path to 'pg_catalog' as $$
declare s record; v jsonb := p_row;
begin
  for s in select * from public.backup_redaction_spec() x where x.table_name = p_table and x.mode <> 'keep' loop
    continue when not (v ? s.column_name) or jsonb_typeof(v -> s.column_name) = 'null';
    if s.mode = 'blank' then v := jsonb_set(v, array[s.column_name], to_jsonb(''::text));
    elsif s.kind = 'json' then v := jsonb_set(v, array[s.column_name], public.backup_redact_json(v -> s.column_name, p_ctx, coalesce(s.max_len, 500), s.mode));
    elsif s.kind = 'array' then v := jsonb_set(v, array[s.column_name], public.backup_redact_array(array(select jsonb_array_elements_text(v -> s.column_name)), p_ctx, s.max_len, s.mode));
    else v := jsonb_set(v, array[s.column_name], to_jsonb(public.backup_redact_text(v ->> s.column_name, p_ctx, s.max_len, s.mode)));
    end if;
  end loop;
  return v;
end $$;

-- the SQL expression (over alias t, context in $1) that turns one row of an exported table into its redacted jsonb
create or replace function public.backup_table_expr(p_table text, p_exported jsonb) returns text
language plpgsql stable set search_path to 'pg_catalog' as $$
declare r text;
begin
  select case when count(es.column_name) filter (where es.mode <> 'keep') = 0 then 'to_jsonb(t)'
              else 'to_jsonb(t) || jsonb_build_object(' || string_agg(format('%L, %s', es.column_name,
                     case when es.mode = 'blank' then format('case when t.%I is null then null::text else ''''::text end', es.column_name)
                          when es.kind = 'json' then format('public.backup_redact_json(t.%I::jsonb, $1, %s, %L)', es.column_name, coalesce(es.max_len, 500), es.mode)
                          when es.kind = 'array' then format('public.backup_redact_array(t.%I::text[], $1, %s, %L)', es.column_name, coalesce(es.max_len, 2000), es.mode)
                          else format('public.backup_redact_text(t.%I::text, $1, %s, %L)', es.column_name, coalesce(es.max_len::text, 'null'), es.mode) end), ', ') filter (where es.mode <> 'keep') || ')' end
    into r from public.backup_effective_spec(p_exported) es where es.table_name = p_table;
  return coalesce(r, 'to_jsonb(t)');
end $$;

-- primary-key ORDER BY list of a table (a stable order for paging); falls back to the row text itself
create or replace function public.backup_pk_order(p_table text) returns text
language sql stable set search_path to 'pg_catalog' as $$
  select coalesce((select string_agg(quote_ident(a.attname), ', ' order by k.ord) from pg_index i join pg_class c on c.oid = i.indrelid
                     cross join lateral unnest(i.indkey) with ordinality k (attnum, ord) join pg_attribute a on a.attrelid = c.oid and a.attnum = k.attnum
                    where c.relnamespace = 'public'::regnamespace and c.relname = p_table and i.indisprimary), 'to_jsonb(t)::text')
$$;

-- same name, signature, volatility and grants as before: one-statement consistent snapshot of the EXPORTED tables + schema + policy.
-- Every text-like column of an exported table is redacted per backup_effective_spec(); the redaction context (client names, deny-list terms found in the data) is computed ONCE and handed to every row.
-- The scan, the context and the data all run in this one statement's snapshot (STABLE function): the single-statement consistency claim holds. For data volumes that do not fit one statement
-- (backup_snapshot_cost() says so) hq_backup.py pages the same redaction per table (backup_snapshot_page + backup_table_digest) and proves consistency by comparing raw digests before and after.
create or replace function public.backup_snapshot(skip text[] default array['push_config', 'push_subscriptions']) returns jsonb
language plpgsql stable security definer set search_path to 'pg_catalog' as $$
declare q text; res jsonb; pol jsonb := public.backup_export_policy(); ctx jsonb; found jsonb; t0 timestamptz := clock_timestamp(); t1 timestamptz; deny_hits int := 0;
begin
  ctx := public.backup_redaction_context();
  found := public.backup_deny_scan(pol -> 'exported', ctx);
  ctx := public.backup_ctx_hot(ctx, found);
  if found is not null then
    deny_hits := jsonb_array_length(found -> 'names') + jsonb_array_length(found -> 'chains') + jsonb_array_length(found -> 'emails') + jsonb_array_length(found -> 'phones');
  end if;
  ctx := ctx || jsonb_build_object('scanned', true);
  t1 := clock_timestamp();
  select 'select jsonb_build_object(''data'', (select coalesce(jsonb_object_agg(k, v), ''{}''::jsonb) from (' ||
         string_agg(format('select %L::text as k, (select coalesce(jsonb_agg(%s), ''[]''::jsonb) from public.%I t) as v', c.relname, public.backup_table_expr(c.relname::text, pol -> 'exported'), c.relname), ' union all ' order by c.relname) ||
         ') s), ''schema'', public.backup_schema(), ''policy'', ' || quote_literal(pol::text) || '::jsonb, ''method'', ''single statement snapshot'')'
    into q
    from pg_class c
   where c.relnamespace = 'public'::regnamespace and c.relkind in ('r', 'p') and c.relname <> all (skip) and c.relname in (select jsonb_array_elements_text(pol -> 'exported'));
  if q is null then raise exception 'backup refused: the export policy lists no exportable table'; end if;
  execute q into res using ctx;
  return res || jsonb_build_object('redaction', public.backup_redaction_meta(pol) || jsonb_build_object('known_client_terms', ctx -> 'n_terms', 'deny_list_terms_found', deny_hits,
                                   'detector', case when ctx ->> 'fast_detector' = 'true' then 'fast twin (pinned)' else 'ws_sensitive_hits' end,
                                   'ms_scan', round(extract(epoch from (t1 - t0)) * 1000), 'ms_total', round(extract(epoch from (clock_timestamp() - t0)) * 1000)));
end $$;

-- what was redacted and how (never client data)
create or replace function public.backup_redaction_meta(p_pol jsonb default null) returns jsonb
language plpgsql stable security definer set search_path to 'pg_catalog' as $$
declare pol jsonb := coalesce(p_pol, public.backup_export_policy()); spec jsonb; uncls jsonb;
begin
  select coalesce(jsonb_agg(jsonb_build_object('table_name', e.table_name, 'column_name', e.column_name, 'kind', e.kind, 'mode', e.mode, 'max_len', e.max_len)), '[]'::jsonb),
         coalesce(jsonb_agg(e.table_name || '.' || e.column_name) filter (where not e.classified), '[]'::jsonb)
    into spec, uncls from public.backup_effective_spec(pol -> 'exported') e;
  return jsonb_build_object('version', 2, 'unclassified_columns', uncls, 'spec', spec);
end $$;

-- The whole-export deny-list scan, done once for a paged run (see backup_snapshot_page). The result is the set of candidate strings of the exported text that are on the deny-list (strings that are
-- already in the exported rows, nothing from the list itself); it is kept in an owner-only table for 30 minutes or until backup_deny_release(). Returns counts only.
create table if not exists public.ffm_redaction_found (id integer primary key check (id = 1), found jsonb not null, at timestamptz not null default now());
alter table public.ffm_redaction_found add column if not exists run uuid;
alter table public.ffm_redaction_found enable row level security;
revoke all on public.ffm_redaction_found from public, anon, authenticated, service_role;
create or replace function public.backup_deny_prepare() returns jsonb
language plpgsql volatile security definer set search_path to 'pg_catalog' as $$
declare pol jsonb := public.backup_export_policy(); ctx jsonb := public.backup_redaction_context(); found jsonb; rid uuid := gen_random_uuid();
begin
  found := public.backup_deny_scan(pol -> 'exported', ctx);
  delete from public.ffm_redaction_found;
  if found is not null then insert into public.ffm_redaction_found (id, found, run) values (1, found, rid); end if;
  return jsonb_build_object('run', rid, 'prepared', found is not null, 'terms', case when found is null then 0 else jsonb_array_length(found -> 'names') + jsonb_array_length(found -> 'chains') + jsonb_array_length(found -> 'emails') + jsonb_array_length(found -> 'phones') end);
end $$;
create or replace function public.backup_deny_release() returns jsonb
language plpgsql volatile security definer set search_path to 'pg_catalog' as $$
begin
  delete from public.ffm_redaction_found;
  return jsonb_build_object('released', true);
end $$;
revoke all on function public.backup_deny_prepare() from public, anon, authenticated;
revoke all on function public.backup_deny_release() from public, anon, authenticated;
grant execute on function public.backup_deny_prepare() to service_role;
grant execute on function public.backup_deny_release() to service_role;

-- ONE PAGE of one exported table, redacted exactly like the snapshot (context and scan computed for this page). For volumes that do not fit one statement.
drop function if exists public.backup_snapshot_page(text, integer, integer);
create or replace function public.backup_snapshot_page(p_table text, p_offset integer, p_limit integer, p_run uuid default null) returns jsonb
language plpgsql stable security definer set search_path to 'pg_catalog' as $$
declare pol jsonb := public.backup_export_policy(); ctx jsonb; found jsonb; res jsonb; ord text; t0 timestamptz := clock_timestamp();
begin
  if p_table is null or not ((pol -> 'exported') ? p_table) or p_table in ('push_config', 'push_subscriptions') then raise exception 'backup_snapshot_page: % is not an exportable table', p_table; end if;
  if p_offset is null or p_offset < 0 or p_limit is null or p_limit < 1 or p_limit > 5000 then raise exception 'backup_snapshot_page: bad offset/limit'; end if;
  ord := public.backup_pk_order(p_table);
  ctx := public.backup_redaction_context();
  -- The found-name set must NOT depend on which rows share a page (a neighbouring row that spells a name whole makes the squashed check catch a glued form in another row): it is the set of the WHOLE export,
  -- exactly what the single statement uses. backup_deny_prepare() computes it once per run and returns a run id; a page call that passes that id reuses the stored set (owner-only table, 30 minutes), any other call simply runs the whole scan here (slow, same result, never stale).
  select f.found into found from public.ffm_redaction_found f where p_run is not null and f.id = 1 and f.run = p_run and f.at > now() - interval '30 minutes';     -- only a caller that holds the run id of ITS prepare (hq_backup.py) reuses it
  if found is null then found := public.backup_deny_scan(pol -> 'exported', ctx); end if;
  ctx := public.backup_ctx_hot(ctx, found) || jsonb_build_object('scanned', true);
  execute format('select coalesce(jsonb_agg(%s), ''[]''::jsonb) from (select * from public.%I t order by %s offset %s limit %s) t', public.backup_table_expr(p_table, pol -> 'exported'), p_table, ord, p_offset, p_limit)
    into res using ctx;
  return jsonb_build_object('rows', res, 'n', jsonb_array_length(res), 'ms', round(extract(epoch from (clock_timestamp() - t0)) * 1000));
end $$;

-- raw (unredacted) digest of a table: equal digests before and after a paged export prove nothing changed while it was read. Reveals nothing but a hash.
create or replace function public.backup_table_digest(p_table text) returns jsonb
language plpgsql stable security definer set search_path to 'pg_catalog' as $$
declare pol jsonb := public.backup_export_policy(); r jsonb;
begin
  if p_table is null or not ((pol -> 'exported') ? p_table) then raise exception 'backup_table_digest: % is not an exportable table', p_table; end if;
  execute format('select jsonb_build_object(''rows'', count(*), ''md5'', coalesce(md5(string_agg(md5(to_jsonb(t)::text), '','' order by %s)), '''')) from public.%I t', public.backup_pk_order(p_table), p_table) into r;
  return r;
end $$;

-- how much work one backup_snapshot() statement is, in seconds (per-character costs measured on the scratch machine: see DATA_CLASSIFICATION_AND_BACKUP_POLICY.md section 2). hq_backup.py pages above its limit.
create or replace function public.backup_snapshot_cost() returns jsonb
language plpgsql stable security definer set search_path to 'pg_catalog' as $$
declare pol jsonb := public.backup_export_policy(); e record; chars bigint; strict_chars bigint := 0; light_chars bigint := 0; rows bigint := 0; n bigint; expr text;
begin
  for e in select * from public.backup_effective_spec(pol -> 'exported') where mode in ('strict', 'light') loop
    expr := case e.kind when 'array' then format('array_to_string(t.%I::text[], '' '')', e.column_name) else format('t.%I::text', e.column_name) end;
    execute format('select coalesce(sum(length(%s)), 0), count(*) from public.%I t', expr, e.table_name) into chars, n;
    if e.mode = 'strict' then strict_chars := strict_chars + chars; else light_chars := light_chars + chars; end if;
    rows := rows + n;
  end loop;
  return jsonb_build_object('strict_chars', strict_chars, 'light_chars', light_chars, 'field_count', rows,
                            'est_seconds', round((strict_chars * 0.0000013 + light_chars * 0.00000035 + rows * 0.00004)::numeric, 1));
end $$;

revoke all on function public.backup_type_ok(oid) from public, anon, authenticated;
revoke all on function public.backup_export_policy() from public, anon, authenticated;
revoke all on function public.backup_fold_text(text) from public, anon, authenticated;
revoke all on function public.backup_unescape_text(text) from public, anon, authenticated;
revoke all on function public.backup_normalise(text) from public, anon, authenticated;
revoke all on function public.backup_stopwords() from public, anon, authenticated;
revoke all on function public.backup_re_escape(text) from public, anon, authenticated;
revoke all on function public.backup_windows(text) from public, anon, authenticated;
revoke all on function public.backup_ctx_build(text[], text[], text[], text[], jsonb) from public, anon, authenticated;
revoke all on function public.backup_ctx_add(jsonb, jsonb) from public, anon, authenticated;
revoke all on function public.backup_topic_hits(text) from public, anon, authenticated;
revoke all on function public.backup_topic_core(text, text) from public, anon, authenticated;
revoke all on function public.backup_topic_fast(text, text) from public, anon, authenticated;
revoke all on function public.backup_detector_pins() from public, anon, authenticated;
revoke all on function public.backup_redaction_context() from public, anon, authenticated;
revoke all on function public.backup_deny_query(text) from public, anon, authenticated;
revoke all on function public.backup_deny_run(text, text) from public, anon, authenticated;
revoke all on function public.backup_deny_terms(text, jsonb) from public, anon, authenticated;
revoke all on function public.backup_effective_spec(jsonb) from public, anon, authenticated;
revoke all on function public.backup_deny_scan(jsonb, jsonb, text, integer, integer) from public, anon, authenticated;
revoke all on function public.backup_redact_patterns(text, jsonb) from public, anon, authenticated;
revoke all on function public.backup_probe_encoded(text, jsonb, integer) from public, anon, authenticated;
revoke all on function public.backup_redact_text_full(text, jsonb, integer, text) from public, anon, authenticated;
revoke all on function public.backup_redact_text(text, jsonb, integer, text) from public, anon, authenticated;
revoke all on function public.backup_ctx_hot(jsonb, jsonb) from public, anon, authenticated;
revoke all on function public.backup_ctx_blob(jsonb, jsonb) from public, anon, authenticated;
revoke all on function public.backup_redact_json_k(jsonb, text, jsonb, integer, text) from public, anon, authenticated;
revoke all on function public.backup_redact_json(jsonb, jsonb, integer, text) from public, anon, authenticated;
revoke all on function public.backup_redact_array(text[], jsonb, integer, text) from public, anon, authenticated;
revoke all on function public.backup_redaction_spec() from public, anon, authenticated;
revoke all on function public.backup_redact_row(text, jsonb, jsonb) from public, anon, authenticated;
revoke all on function public.backup_snapshot(text[]) from public, anon, authenticated;
revoke all on function public.backup_table_expr(text, jsonb) from public, anon, authenticated;
revoke all on function public.backup_pk_order(text) from public, anon, authenticated;
revoke all on function public.backup_redaction_meta(jsonb) from public, anon, authenticated;
revoke all on function public.backup_snapshot_page(text, integer, integer, uuid) from public, anon, authenticated;
revoke all on function public.backup_table_digest(text) from public, anon, authenticated;
revoke all on function public.backup_snapshot_cost() from public, anon, authenticated;
grant execute on function public.backup_export_policy() to service_role;
grant execute on function public.backup_fold_text(text) to service_role;
grant execute on function public.backup_unescape_text(text) to service_role;
grant execute on function public.backup_normalise(text) to service_role;
grant execute on function public.backup_redaction_context() to service_role;
grant execute on function public.backup_redact_patterns(text, jsonb) to service_role;
grant execute on function public.backup_probe_encoded(text, jsonb, integer) to service_role;
grant execute on function public.backup_redact_text(text, jsonb, integer, text) to service_role;
grant execute on function public.backup_redact_json(jsonb, jsonb, integer, text) to service_role;
grant execute on function public.backup_redaction_spec() to service_role;
grant execute on function public.backup_redact_row(text, jsonb, jsonb) to service_role;
grant execute on function public.backup_effective_spec(jsonb) to service_role;
grant execute on function public.backup_snapshot(text[]) to service_role;
grant execute on function public.backup_redaction_meta(jsonb) to service_role;
grant execute on function public.backup_snapshot_page(text, integer, integer, uuid) to service_role;
grant execute on function public.backup_table_digest(text) to service_role;
grant execute on function public.backup_snapshot_cost() to service_role;

-- search_path hijack: with Supabase's default ACL the API roles may CREATE objects in schema public, so a function created there with the name of a builtin could run with the owner's rights inside a definer
-- function that has public on its search_path. Every function of the leak migrations now sets search_path = pg_catalog ONLY (all other references are schema-qualified), and the API roles lose CREATE on public
-- (nothing in this repository creates objects as an API role: migrations run as the owner; PostgREST needs USAGE only).
revoke create on schema public from public;
do $$ begin
  if exists (select 1 from pg_roles where rolname = 'anon') then execute 'revoke create on schema public from anon'; end if;
  if exists (select 1 from pg_roles where rolname = 'authenticated') then execute 'revoke create on schema public from authenticated'; end if;
  if exists (select 1 from pg_roles where rolname = 'service_role') then execute 'revoke create on schema public from service_role'; end if;
end $$;
