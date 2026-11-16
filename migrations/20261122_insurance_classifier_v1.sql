-- Insurance content classification v1 (FENDEZY priority 3, Nov 2026). UNRELEASED: edited in place after independent review (PR #17). Additive: 4 tables (ws_approved_terms, ws_marketing_vocab, ws_place_catalog, ws_fixed_phrases), new functions (classifier, deny lists, owner management, ws_onboarding_value_check, ws_structural_value; all pin search_path = pg_catalog), 2 replaced functions (ws_guard, ffm_guard). Seed rows are vocabulary, fixed phrases and the municipality catalog only; no existing row is changed.
--   PROBLEM: the 'health' detector (20261119) refuses ordinary insurance PRODUCT wording ("health insurance", "disability insurance", "critical illness cover",
--   "Medicine Hat"), so Client 2 (insurance) could not write marketing. It also missed French, accents, look-alike letters and leetspeak.
--   MODEL (default-deny on the residual): insurance PRODUCT MARKETING is allowed only as exact OWNER-APPROVED terms plus an OWNER-MANAGED generic vocabulary.
--   Everything else in insurance-context text is refused. A deny-list of "personal" words was the first design and it failed review (any health word not on the list passed in
--   third person); the allow-list below fails closed instead: an unknown word blocks, whatever it means.
--   * ws_approved_terms: owner-managed, scoped to ONE workspace or (with an explicit confirm flag) a VERTICAL. Ships EMPTY. Kinds:
--       product  a product NAME ("health insurance", "income protection"): every word must be generic vocabulary or a product-name word; no condition, person or targeting word
--       feature  a generic coverage description that may name conditions ("heart attack, stroke and cancer"), never a person or a targeting phrase; matters only next to a product term or an insurance word
--       place    a Canadian municipality chosen from the fixed catalog ws_place_catalog (no free text)
--     Terms are added/removed only by ws_add_approved_term / ws_remove_approved_term (owner-only, audit logged WITHOUT the term text). Rows are never deleted.
--   * ws_marketing_vocab: owner-managed generic marketing words (en/fr), seeded here with non-sensitive function words and marketing words ONLY. Owner-only add/remove
--     (ws_add_vocab_word / ws_remove_vocab_word, soft removal, audit logged without the word); the bot cannot. A hard deny list inside ws_vocab_denied (person references,
--     narrative words, anything the health/condition detectors flag) means such a word can never be added.
--   * ws_classify_text(text, workspace) -> {"allowed": bool, "reasons": [codes]}. It NEVER echoes the text. Order of decision (workspace given):
--       1. every previous category (SIN, card, account, identity, banking, credit) still blocks on the original text AND on a normalised view AND on two leetspeak views.
--       2. 'health' and 'income' are the ONLY categories a term can waive: the approved terms are cut out of the folded token stream (whole words, never re-joined),
--          'your income' is waived only when no currency amount appears, and the detectors run again on what is left.
--       3. INSURANCE CONTEXT = the WORKSPACE is not of a known non-insurance vertical, or holds an approved product term (ws_insurance_context; the words of the text decide nothing).
--          In that context the residual may contain ONLY vocabulary words, numbers and simple punctuation. Any other token => 'unknown_word'. Non-Latin scripts,
--          mixed scripts, '&', '=' and percent-encoding => blocked. Phone, email, postal code, street address and 4+ digit numbers => 'identifier' (whatever the health words).
--       4. non-insurance text behaves exactly as before (strict screen; a place term only waives its own health-looking name).
--   * ws_guard / ffm_guard (replaced) call the classifier. Approved-term waivers apply ONLY on non-person tables (ws_campaigns, ws_ledger, ffm_ad_sets, ffm_creatives, ffm_approvals,
--     ffm_onboarding_items). Person tables (ws_leads, client_workspaces, ffm_routing_rules, ffm_consent_*) keep the old screen as the first test and, in an insurance workspace,
--     get the insurance screen on top of it (round 4, ws_person_column_check).
--   * ROUND 4 (independent review RV17-C): money / pay / debt fail closed (ws_financial_hit); a feature phrase can never state a fact about a person (ws_feature_context_ok);
--     the insurance screen applies to every workspace whose vertical is not exactly 'mortgage' (ws_vertical_insurance: NULL / unknown / misspelled fail closed); person tables as above;
--     spelled digit groups across columns, vocabulary-word names, form labels and answers, onboarding values and owner validation tightened. See the policy document, section 5a.
--   * ws_fixed_phrases (round 3): owner-managed en/fr fixed phrases ("contact us", "our team", "notre equipe", "Mon-Fri" ...), cut in pass 1 like an approved term; owner-only, soft removal, PII-free audit, immutable.
--   * ws_onboarding_value_check / ws_structural_value (round 3): onboarding VALUES are list-screened (no vocabulary test, no waiver); structural columns skip the vocabulary test only when they really are a template title, a plain date or a short token.
--   * ws_sensitive_hits is NOT changed (other callers, the Python wrapper and ffm_route_preview keep the strict result). Regular expressions and word lists have stated limits: see the policy document.

-- 1. approved terms (owner-managed; ships empty)
create table if not exists public.ws_approved_terms (
  id uuid primary key default gen_random_uuid(),
  workspace_id uuid references public.client_workspaces(id) on delete restrict,
  vertical text check (vertical is null or vertical ~ '^[a-z0-9][a-z0-9-]{1,40}$'),
  kind text not null check (kind in ('product', 'place', 'feature')),
  term text not null check (length(term) between 3 and 120),
  term_norm text not null check (length(term_norm) between 3 and 120) check (term_norm ~ '^[a-z]+([ ''][a-z]+)*$'),   -- two separate checks: one AND-chain with BETWEEN is re-rendered differently after a schema dump/restore (backup drill, schema identity)
  vertical_confirmed boolean not null default false,
  created_by text not null default 'owner',
  created_at timestamptz not null default clock_timestamp(),
  removed_at timestamptz,
  removed_by text,
  check ((workspace_id is null) <> (vertical is null)),
  check (workspace_id is not null or vertical_confirmed)
);
create unique index if not exists ws_approved_terms_active_uidx
  on public.ws_approved_terms ((coalesce(workspace_id::text, 'v:' || vertical)), kind, term_norm) where removed_at is null;
alter table public.ws_approved_terms enable row level security;
revoke all on public.ws_approved_terms from public, anon, authenticated;
grant select on public.ws_approved_terms to service_role;
revoke insert, update, delete, truncate, trigger, references on public.ws_approved_terms from service_role;

-- 1b. owner-managed generic marketing vocabulary (per language). Soft removal only.
create table if not exists public.ws_marketing_vocab (
  id uuid primary key default gen_random_uuid(),
  lang text not null check (lang in ('en', 'fr')),
  word text not null check (word ~ '^[a-z0-9]{1,30}$'),
  created_by text not null default 'owner',
  created_at timestamptz not null default clock_timestamp(),
  removed_at timestamptz,
  removed_by text
);
create unique index if not exists ws_marketing_vocab_active_uidx on public.ws_marketing_vocab (lang, word) where removed_at is null;
create index if not exists ws_marketing_vocab_word_idx on public.ws_marketing_vocab (word) where removed_at is null;
alter table public.ws_marketing_vocab enable row level security;
revoke all on public.ws_marketing_vocab from public, anon, authenticated;
grant select on public.ws_marketing_vocab to service_role;
revoke insert, update, delete, truncate, trigger, references on public.ws_marketing_vocab from service_role;

-- 1c. fixed catalog of Canadian municipalities an owner may approve as 'place' terms (no free text). Never edited by anyone: rows only arrive with this migration.
create table if not exists public.ws_place_catalog (
  name_norm text primary key check (name_norm ~ '^[a-z]+([ ''][a-z]+)*$'),
  display_name text not null,
  province text not null check (province ~ '^[A-Z]{2}$')
);
alter table public.ws_place_catalog enable row level security;
revoke all on public.ws_place_catalog from public, anon, authenticated;
grant select on public.ws_place_catalog to service_role;
revoke insert, update, delete, truncate, trigger, references on public.ws_place_catalog from service_role;

-- 1d. owner-managed FIXED PHRASES (en/fr): short whole phrases that contain a word the vocabulary hard-denies on its own ("contact us", "our team", "notre equipe", "mon fri").
--     Cut out of the token stream in pass 1 like an approved term, only in insurance context. Owner-only management, soft removal, PII-free audit, never edited.
create table if not exists public.ws_fixed_phrases (
  id uuid primary key default gen_random_uuid(),
  lang text not null check (lang in ('en', 'fr')),
  phrase text not null check (length(phrase) between 5 and 60),
  phrase_norm text not null check (phrase_norm ~ '^[a-z]+( [a-z]+){1,4}$'),
  created_by text not null default 'owner',
  created_at timestamptz not null default clock_timestamp(),
  removed_at timestamptz,
  removed_by text
);
create unique index if not exists ws_fixed_phrases_active_uidx on public.ws_fixed_phrases (phrase_norm) where removed_at is null;
alter table public.ws_fixed_phrases enable row level security;
revoke all on public.ws_fixed_phrases from public, anon, authenticated;
grant select on public.ws_fixed_phrases to service_role;
revoke insert, update, delete, truncate, trigger, references on public.ws_fixed_phrases from service_role;

-- rows are never deleted; the only allowed update is the one-way soft removal done by the owner functions (terms and vocabulary share this trigger)
create or replace function public.ws_terms_immutable() returns trigger
language plpgsql set search_path to 'pg_catalog' as $$
begin
  if tg_op = 'UPDATE' and old.removed_at is null and new.removed_at is not null
     and (to_jsonb(new) - 'removed_at' - 'removed_by') = (to_jsonb(old) - 'removed_at' - 'removed_by') then
    return new;
  end if;
  raise exception 'approved terms cannot be edited or deleted: remove the term (soft) and add a new one' using errcode = 'P0001';
end $$;
drop trigger if exists ws_terms_immutable on public.ws_approved_terms;
create trigger ws_terms_immutable before update or delete on public.ws_approved_terms for each row execute function public.ws_terms_immutable();
drop trigger if exists ws_terms_no_truncate on public.ws_approved_terms;
create trigger ws_terms_no_truncate before truncate on public.ws_approved_terms for each statement execute function public.ws_terms_immutable();
drop trigger if exists ws_vocab_immutable on public.ws_marketing_vocab;
create trigger ws_vocab_immutable before update or delete on public.ws_marketing_vocab for each row execute function public.ws_terms_immutable();
drop trigger if exists ws_vocab_no_truncate on public.ws_marketing_vocab;
create trigger ws_vocab_no_truncate before truncate on public.ws_marketing_vocab for each statement execute function public.ws_terms_immutable();
drop trigger if exists ws_phrases_immutable on public.ws_fixed_phrases;
create trigger ws_phrases_immutable before update or delete on public.ws_fixed_phrases for each row execute function public.ws_terms_immutable();
drop trigger if exists ws_phrases_no_truncate on public.ws_fixed_phrases;
create trigger ws_phrases_no_truncate before truncate on public.ws_fixed_phrases for each statement execute function public.ws_terms_immutable();

create or replace function public.ws_place_catalog_immutable() returns trigger
language plpgsql set search_path to 'pg_catalog' as $$
begin
  raise exception 'the place catalog is fixed: it is changed only by a migration' using errcode = 'P0001';
end $$;
drop trigger if exists ws_place_catalog_immutable on public.ws_place_catalog;
create trigger ws_place_catalog_immutable before update or delete on public.ws_place_catalog for each row execute function public.ws_place_catalog_immutable();
drop trigger if exists ws_place_catalog_no_truncate on public.ws_place_catalog;
create trigger ws_place_catalog_no_truncate before truncate on public.ws_place_catalog for each statement execute function public.ws_place_catalog_immutable();

-- 2. normalisation. zero-width / bidi / variation selectors out, NFKC (fullwidth, circled, squared, mathematical letters), NFD + combining marks out (accents), lower case, ligatures,
--    Cyrillic / Greek / Latin-extended look-alikes to Latin, Arabic-Indic digits to ASCII, typographic apostrophes and dashes to ASCII, whitespace squeezed.
create or replace function public.ws_fold_text(p_text text) returns text
language plpgsql immutable set search_path to 'pg_catalog' as $$
declare t text := coalesce(p_text, '');
begin
  t := regexp_replace(t, '[\u00ad\u034f\u061c\u115f\u1160\u17b4\u17b5\u180b-\u180e\u200b-\u200f\u202a-\u202e\u2060-\u206f\u3164\ufe00-\ufe0f\ufeff\uffa0]', '', 'g');
  t := regexp_replace(t, '[\U000e0001\U000e0020-\U000e007f\U000e0100-\U000e01ef]', '', 'g');
  t := normalize(t, NFKC);
  t := normalize(t, NFD);
  t := regexp_replace(t, '[\u0300-\u036f\u1ab0-\u1aff\u1dc0-\u1dff\u20d0-\u20ff\ufe20-\ufe2f]', '', 'g');
  -- capital look-alikes BEFORE lower-casing: Greek capital Eta/Nu/Mu/Upsilon would otherwise lower-case to letters that look like n, v, u (not H, N, M, Y)
  t := translate(t, 'ΗΝΜΥΖΒΕΚΟΡΤΧΑΙАВЕКМНОРСТХУІЈЅ', 'HNMYZBEKOPTXAIABEKMHOPCTXYIJS');
  t := lower(t);
  t := replace(replace(replace(replace(replace(replace(t, 'œ', 'oe'), 'æ', 'ae'), 'ß', 'ss'), 'ø', 'o'), 'ł', 'l'), 'đ', 'd');
  t := translate(t, 'ıавекмнорстухіїјѕԁԛԝһӏүѡɑɡαβγεικνορτυχωϲϳςμη', 'iabekmhopctyxiijsdqwhlywagabyeikvoptuxwcjcun');
  t := translate(t, '٠١٢٣٤٥٦٧٨٩۰۱۲۳۴۵۶۷۸۹’‘`´ʼ′‐‑‒–—−', '01234567890123456789''''''''''''------');
  t := regexp_replace(t, '[[:space:]]+', ' ', 'g');
  return btrim(t);
end $$;

-- leetspeak views (for DETECTION of obfuscated words only, never used for the number detectors, never used to match approved terms or vocabulary).
-- Review fix: digits and symbols are folded ONLY inside a token that contains a letter. A lone "1", "#1", "|", "@", "$25" or "!" stands for itself.
create or replace function public.ws_leet_text(p_fold text, p_variant integer) returns text
language sql immutable set search_path to 'pg_catalog' as $$
  select coalesce(string_agg(case when m[1] ~ '[a-z]'
                                  then case when p_variant = 2 then translate(m[1], '013457$@!|', 'oleastsail') else translate(m[1], '013457$@!|', 'oieastsaii') end
                                  else m[1] end, '' order by ord), '')
  from regexp_matches(coalesce(p_fold, ''), '[a-z0-9$@!|]+|[^a-z0-9$@!|]+', 'g') with ordinality as t(m, ord);
$$;

-- 3. extra health wording the old detector did not know (French, and a few English gaps). Input is an already folded (ASCII, lower case) view.
create or replace function public.ws_health_extra_hit(p_fold text) returns boolean
language plpgsql immutable set search_path to 'pg_catalog' as $$
declare k text := coalesce(p_fold, ''); kc text; w text;
begin
  kc := regexp_replace(k, '[^a-z0-9]', '', 'g');
  if kc ~ '(maladie|malade|tumeur|chimio|hopita|medecin|medicament|ordonnance|invalidit|incapacit|handicap|cardiaque|infarctus|greffe|dialyse|enceinte|grossesse|faussecouche|avortement|chirurg|blessure|anxie|asthm|leucemi|sclerose|demence|alcooli|surdite|symptome|infirmi|psycholog|ambulanc|preexist|amputat|bedridden|disabled|disabling|terminallyill|fracture|remission|pills|santemental|cancereu|diabetique|epilepsie)'
  then return true; end if;
  foreach w in array array['sante', 'avc', 'sida', 'vih', 'coeur', 'flu', 'cough', 'invalide', 'invalides', 'rhume', 'fievre', 'douleur', 'douleurs', 'toux', 'cancer', 'diabete'] loop
    if k ~ ('(^|[^a-z])' || array_to_string(regexp_split_to_array(w, ''), case when length(w) <= 4 then '[._\-]?' else '[ ._\-]?' end) || '([^a-z]|$)') then return true; end if;
  end loop;
  return false;
end $$;

-- 3b. condition / medication / body-part words that neither detector knows. Used ONLY to validate owner input (vocabulary, feature phrases): a word on this list is never
--     generic vocabulary. NOT used on stored text: unknown words there are refused by the vocabulary test, which is the real defence.
create or replace function public.ws_condition_hit(p_fold text) returns boolean
language plpgsql immutable set search_path to 'pg_catalog' as $$
declare k text := coalesce(p_fold, '');
begin
  return k ~ ('(^|[^a-z])(lupus|odsp|wsib|aish|herpes|hepatit[a-z]*|std|stds|sti|stis|chlamydia|syphilis|gonorrh[a-z]*|sciatica|burnout|palsy|cerebral|metasta[a-z]*|carcinoma|sarcoma|leprosy|tubercul[a-z]*|malaria|measles|polio|scolios[a-z]*|an[a]?emi[a-z]*|hernia|eczema|psoriasis|acne|rash|fever|lipitor|ozempic|xanax|metformin|viagra|prozac|zoloft|codeine|morphine|oxycodone|ibuprofen|tylenol|aspirin|'
              || 'leg|legs|arm|arms|knee|knees|hip|hips|shoulder|shoulders|chest|head|neck|eye|eyes|ear|ears|liver|brain|breast|breasts|bone|bones|skin|teeth|tooth|stomach|colon|prostate|pain|pains|ache|aches|sore|dizzy|nausea|vomit[a-z]*|bleed[a-z]*|blind[a-z]*|paraly[a-z]*|dying|a1c|bp|tspt|bpco|kanser|krebs|ms|als|copd|chf|dvt|cirrhosis|gout|shingles|ibs|uti|seropositi[a-z]*|fumeurs?|fumeuse|fumeuses|tabac|tabagisme|hysterectomy|mastectomy|stents?|bypass|limp|lame|crippled|handicap[a-z]*|wound[a-z]*|ulcers?|tumou?rs?|lesions?|polyps?|cysts?|nodules?|infected|infection|virus|viral|bacteria[a-z]*|sepsis|pneumonia|bronchitis|emphysema|stroke|strokes|aneurysm|embol[a-z]*|thromb[a-z]*|angina|arrhythm[a-z]*|murmur|palpitations?)([^a-z]|$)');
end $$;

-- 4. first-person / narrative context ("I have diabetes", "my husband's cancer", "j'ai", "ma mere", "diagnosed", "claim for", "passed away", "policy number").
--    Used when the old-style waiver of a PLACE name needs it, and to validate owner input (a term is never personal wording). Input: folded view.
create or replace function public.ws_personal_context_hit(p_fold text) returns boolean
language plpgsql immutable set search_path to 'pg_catalog' as $$
declare k text := coalesce(p_fold, '');
begin
  if k ~ '(^|[^a-z0-9])(i|im|ive|me|my|mine|myself|je|moi|moimeme|mien|miens|mienne|miennes|mes|ma|suis)([^a-z0-9]|$)' then return true; end if;
  if k ~ '(^|[^a-z0-9])(j|m)''' then return true; end if;
  if k ~ '(^|[^a-z0-9])mon[ ]+(?!(to|through|thru|and|et|au|a|fri|ven)([^a-z]|$))[a-z]' then return true; end if;
  if k ~ ('(^|[^a-z0-9])(passed away|passed on|has died|have died|died|deceased|late (husband|wife|father|mother|spouse|partner)|funeral|widow|widower|veuve|veuf|decede|decedee|est mort|est morte|'
          || 'suffer|suffers|suffered|suffering|souffre|souffrant|souffert|atteint|atteinte|atteints|atteintes|undergo|underwent|undergoing|admitted|hospitali[sz]ed|recover(ed|ing)? from|treated for|treatment for|'
          || 'claim for|claimed for|claim on behalf|filed (a|an|his|her|their|my) claim|filed for|applied for|(was|were|got|been|being|get) (denied|declined|rejected|turned down|refused)|denied coverage|declined coverage|(claim|claims|coverage|application|request|policy|demande|reclamation) (was |were |has been |is |got )?(denied|declined|rejected|refused|refusee|refuse|rejetee|turned down)|'
          || 'test results|lab results|(policy|claim|member|certificate|case|file|group) ?(number|no|num|nr|id|#)|numero de (police|reclamation|certificat|membre|dossier|contrat)|no de police|'
          || 'born|dob|years old|yrs old|ne le|nee le|date de naissance|demande de (reclamation|prestation|indemnite)|reclamation pour|votre dossier medical)([^a-z0-9]|$)') then return true; end if;
  return false;
end $$;

-- 5. identifiers that must not appear in insurance-context text. Prices ($25/month, 100%), years (1995..2099) and age ranges (18-65) are allowed. Input: folded view.
--    Review fix: a lone " @ " is a separator ("Health insurance @ $25/mo"); an @ touching a letter or digit is an email or handle.
create or replace function public.ws_identifier_hit(p_fold text) returns boolean
language plpgsql immutable set search_path to 'pg_catalog' as $$
declare x text := coalesce(p_fold, '');
begin
  if x ~ '[a-z0-9._-]@|@[a-z0-9._-]' or x ~ '[a-z0-9._-]+ ?(\[at\]|\(at\)|\sat\s|arobase) ?[a-z0-9-]+( ?(\[dot\]|\(dot\)|\sdot\s|\spoint\s|\.) ?)[a-z]{2,}' then return true; end if;
  if x ~ '(^|[^a-z0-9])[a-z][0-9][a-z][ -]?[0-9][a-z][0-9]([^a-z0-9]|$)' then return true; end if;
  if x ~ '(^|[^0-9])[0-9]{1,6} +[a-z]+( [a-z]+)? +(street|st|avenue|ave|road|rd|boulevard|blvd|drive|dr|lane|ln|rue|chemin|court|crescent|way|place|terrace)([^a-z]|$)' then return true; end if;
  x := regexp_replace(x, '\$ ?[0-9]([0-9,. ]*[0-9])?', ' ', 'g');
  x := regexp_replace(x, '[0-9]([0-9,.]*[0-9])? ?(\$|%|dollars?|cad|usd|euros?)', ' ', 'g');
  x := regexp_replace(x, '(^|[^0-9])(19|20)[0-9]{2}([^0-9]|$)', '\1 \3', 'g');
  x := regexp_replace(x, '(^|[^0-9])(19|20)[0-9]{2}([^0-9]|$)', '\1 \3', 'g');
  x := regexp_replace(x, '(^|[^0-9])[0-9]{1,2} ?(-|to|a) ?[0-9]{1,3}([^0-9]|$)', '\1 \3', 'g');
  if x ~ '[0-9]{4,}' then return true; end if;
  if x ~ '[0-9]{2,}[ .\-/][0-9]{2,}[ .\-/][0-9]{2,}' then return true; end if;
  if x ~ '[0-9]{1,4}[/.\-][0-9]{1,2}[/.\-][0-9]{1,4}' then return true; end if;
  if x ~ '[0-9]{3}[ .\-)/]+[0-9]{3}' then return true; end if;
  return false;
end $$;

-- 6. stem matching (a generic helper: no sensitive word in it). A stem matches the word, or any of its trimmed forms (plural, -ed, -ing, final -e, -ies), exactly; a stem of
--    5+ letters also as a PREFIX of the word, a stem of 7+ letters anywhere inside it. Input: one folded word and the stems.
create or replace function public.ws_stem_match(p_word text, p_stems text[]) returns boolean
language sql immutable set search_path to 'pg_catalog' as $$
  select exists (select 1 from unnest(p_stems) s
                 cross join lateral unnest(array[p_word, regexp_replace(p_word, '(ies)$', 'y'), regexp_replace(p_word, '(es|s|ed|d|ing|e)$', ''), regexp_replace(p_word, '(ies|es|s|ed|ing)$', ''), regexp_replace(p_word, 'e$', '')]) c
                 where s <> '' and (c = s or (length(s) >= 5 and left(c, length(s)) = s) or (length(s) >= 7 and position(s in c) > 0)));
$$;

-- 6a. relations, nicknames, common given names and surnames (en, fr) and person-sensitive stems (probate, debt, custody, visa, prison ...). Always denied. The list is stored
--     ROT13-encoded: the backup schema export carries function source, and a readable list of names would put those names into the off-site file.
create or replace function public.ws_name_word_hit(p_word text) returns boolean
language sql immutable set search_path to 'pg_catalog' as $$
  select public.ws_stem_match(public.ws_fold_text(p_word), string_to_array(translate(
       'nneba novtnvy nqnz nqnzf nuzrq nyna nyoregb nyrknaqre nyv nyvffn nyyra nznaqn nzryvn nzl naqrefba naqer naqern naqerj natryn naan nagubal nagbvar ' ||
       'neernef neerfg neguhe nfuyrl nhfgva onxre onaxehcg oneevr ornh-crer ornhyvrh orynatre oryyr-zrer orawnzva orernirq oretreba orggl ovyyl obhpuneq ' ||
       'obhpure oblsevraq oenaqba oeraqn oevna oeb oebja oehpr oelna pnzcoryy pney pneby pnebyla pneba pnegre pngurevar punagny puneyrf puneybggr pura purely ' ||
       'puybr puevfgvna puevfgvan puevfgvar puevfgbcure pynex pybhgvre pbgr pbhegranl pbhfva pbhfvar phfgbql plaguvn qnqql qnavry qnivq qnivf qrobenu qroen ' ||
       'qrog qraavf qvnar qvibepr qbaan qbhtynf qlyna rqjneq rzvyl rzzn revp rfgngr rguna rgvraar riryla sngvzn srybal svnapr svnaprr syberf sberpybfher ' ||
       'sbegva sbheavre senaprf senapbvf shareny tnoevry tntar tntaba tnzoyvat tnepvn tneavfu tnel tnhguvre trbetr trenyq tveneq tveysevraq tybevn tbamnyrf ' ||
       'tbamnyrm tenaqzrer tenaqcrer tenaavr tenaal tertbel thvyynhzr unaanu unebyq unecre urngure uryra urael ureanaqrm uhool vzzvtenag vfnoryyn vfnoryyr ' ||
       'wnpx wnpxfba wnpbo wnpdhrf wnvy wnzrf wnarg wnavpr wnfba wrna wrnaar wrsserl wraavsre wrerzl wreel wrffr wrffvpn wbna wbua wbuafba wbanguna wbarf ' ||
       'wbeqna wnar qbr wbfr wbfrcu wbfuhn wblpr whna whqvgu whyvr whfgva xnera xngurevar xnguyrra xnguela xrvgu xryyl xraargu xriva xuna xvz xhzne xlyr yncbvagr yneel ' ||
       'ynhen ynhera ynibvr ynjerapr ynjfhvg yroynap yrpyrep yrsroier yrirfdhr yrjvf yvaqn yvfn ybtna ybcrm ybhvf znqvfba znzn znzvr znzzn znzl znevn znevr ' ||
       'zneenvar znegun znegva znegvarm znel znguvrh znggurj znkvzr zrtna zryvffn zvpunry zvpury zvpuryyr zvyyre zvgpuryy zbunzrq zbunzzrq zbzzvrf zbzzl zbber ' ||
       'zbeva zhzzl anan anapl angunyvr anguna aryfba arcurj arirh arjobea athlra avpubynf avpbyr avrpr abnu abaan byvivn bapyr bhryyrg cnzryn cncn cncv cncl ' ||
       'cndhrggr cneenva cngry cngevpvn cngevpx cnhy cryyrgvre crerm crgre cuvyvccr cvreer cbvevre cevfba cevln cebongr enpury enzverm erorppn ershtrr ertvan ' ||
       'evpuneq eviren eboreg eboregf ebovafba ebqevthrm ebtre ebanyq elna fnznagun fnzzl fnzhry fnapurm fnaqen fnen fnenu fpbgg frna funeba fvzneq fvatu fvf ' ||
       'fzvgu fbsvn fbcuvn fbcuvr fgrcqnhtugre fgrcsngure fgrcunavr fgrcura fgrczbgure fgrcfba fgrira fhfna flqarl flyivr gnagr gnlybe grerfn greel gubznf ' ||
       'gubzcfba gvzbgul gbeerf gerzoynl glyre ireaba ivpgbevn ivfn jnyxre jnygre jnat jnlar jrv jvqbjrq jvsrl jvyyvnz jvyyvnzf jvyyvr jvyfba jevtug mnpunel ' ||
       'munat ',
       'nopqrstuvwxyzabcdefghijklm', 'abcdefghijklmnopqrstuvwxyz'), ' '));
$$;

-- 6b0. conditions, drugs, body parts and other health stems, plus every detector of this system. Used on owner input (vocabulary, terms) and on onboarding values; never needed on
--      stored marketing text, where unknown words are refused anyway.
create or replace function public.ws_health_word_hit(p_word text) returns boolean
language plpgsql immutable set search_path to 'pg_catalog' as $$
declare w text := public.ws_fold_text(p_word);
begin
  if w is null or w = '' then return false; end if;
  if w ~ '^(pregnan|medicat|prescri|surg|cancer|diabet|dement|alzheim|tumou?r|chemo|radiat|dialys|transplant)' then return true; end if;
  if public.ws_stem_match(w, array[
         'arm', 'avc', 'ear', 'eye', 'hip', 'hiv', 'leg', 'lup', 'std', 'sti', 'adhd', 'aids', 'bras', 'coma', 'copd', 'dose', 'feet', 'foie', 'foot', 'gout', 'hand', 'knee', 'lung',
         'lupu', 'main', 'oeil', 'pied', 'pill', 'rein', 'sida', 'skin', 'yeux', 'blood', 'bowel', 'brain', 'chemo', 'chest', 'coeur', 'colon', 'covid', 'crohn', 'faint', 'genou', 'heart',
         'herpe', 'jambe', 'liver', 'lupus', 'obese', 'ovary', 'rehab', 'renal', 'spine', 'stent', 'sugar', 'teeth', 'tooth', 'tumor', 'ulcer', 'xanax', 'addict', 'anemia', 'asthma',
         'autism', 'biopsy', 'breast', 'cancer', 'cardio', 'celiac', 'diabet', 'eczema', 'epaule', 'hernia', 'heroin', 'herpes', 'kidney', 'opioid', 'oxygen', 'poumon', 'prozac', 'schizo',
         'smoker', 'sprain', 'statin', 'stroke', 'throat', 'tumour', 'uterus', 'zoloft', 'amnesia', 'amputee', 'anaemia', 'anxiety', 'anxious', 'aspirin', 'bipolar', 'bladder', 'cardiac',
         'cerveau', 'cocaine', 'codeine', 'colitis', 'dentist', 'diabete', 'glucose', 'insulin', 'kneecap', 'lipitor', 'malaria', 'nursing', 'obesity', 'ozempic', 'seizure', 'stomach',
         'stutter', 'suicide', 'thyroid', 'tobacco', 'tylenol', 'vaccine', 'vertigo', 'abortion', 'aneurysm', 'autistic', 'cannabis', 'cataract', 'catheter', 'collapse', 'crutches',
         'dementia', 'dialysis', 'dyslexia', 'embolism', 'epilepsy', 'fentanyl', 'fracture', 'glaucoma', 'impaired', 'insomnia', 'leukemia', 'lymphoma', 'melanoma', 'migraine', 'morphine',
         'nicotine', 'overdose', 'poitrine', 'pregnant', 'pressure', 'prostate', 'sciatica', 'shingles', 'shoulder', 'suicidal', 'syphilis', 'testicle', 'thyroide', 'tinnitus', 'warfarin',
         'whiplash', 'addiction', 'alcoholic', 'alzheimer', 'arthritic', 'arthritis', 'cancereux', 'chlamydia', 'colostomy', 'depressed', 'depressif', 'gonorrhea', 'hepatitis',
         'ibuprofen', 'infarctus', 'influenza', 'leukaemia', 'mammogram', 'marijuana', 'menopause', 'metformin', 'methadone', 'oxycodone', 'pacemaker', 'paralysis', 'paralyzed',
         'parkinson', 'pneumonia', 'pregnancy', 'psoriasis', 'psychosis', 'psychotic', 'radiation', 'sclerosis', 'scoliosis', 'vasectomy', 'alcoholism', 'amputation', 'antibiotic',
         'arrhythmia', 'bronchitis', 'concussion', 'depression', 'mastectomy', 'meningitis', 'prednisone', 'prosthesis', 'thrombosis', 'transplant', 'ventilator', 'wheelchair',
         'cholesterol', 'colonoscopy', 'infertility', 'miscarriage', 'neurologist', 'seropositif', 'fibromyalgia', 'hypertension', 'hysterectomy', 'incontinence', 'osteoporosis',
         'seropositive', 'tuberculosis', 'contraceptive']) then return true; end if;
  return cardinality(public.ws_sensitive_hits(w)) > 0 or public.ws_health_extra_hit(w) or public.ws_condition_hit(w)
         or cardinality(public.ws_sensitive_hits(public.ws_leet_text(w, 1))) > 0 or cardinality(public.ws_sensitive_hits(public.ws_leet_text(w, 2))) > 0;
end $$;

-- 6b. hard deny list for the vocabulary and for terms: person references, relations, titles, narrative words (events that happened to someone), claim/underwriting wording,
--    French equivalents, names, and (p_health) anything the health / condition detectors or any earlier category flag. NEVER echoes. Input: one word, any case/accents.
create or replace function public.ws_vocab_denied(p_word text, p_health boolean default true) returns boolean
language plpgsql immutable set search_path to 'pg_catalog' as $$
declare w text := public.ws_fold_text(p_word);
begin
  if w is null or w = '' then return true; end if;
  if w = any (array[
    'client', 'clients', 'cliente', 'clientes', 'patient', 'patients', 'patiente', 'patientes', 'customer', 'customers', 'he', 'she', 'him', 'her', 'hers', 'his', 'himself', 'herself',
    'they', 'them', 'their', 'theirs', 'themselves', 'i', 'me', 'my', 'mine', 'myself', 'am', 'mother', 'mothers', 'mom', 'moms', 'mum', 'father', 'fathers', 'dad', 'dads', 'wife', 'wives',
    'husband', 'husbands', 'spouse', 'spouses', 'son', 'sons', 'daughter', 'daughters', 'sister', 'sisters', 'brother', 'brothers', 'sibling', 'siblings', 'aunt', 'uncle', 'cousin',
    'nephew', 'niece', 'grandmother', 'grandfather', 'grandma', 'grandpa', 'grandson', 'granddaughter', 'grandchild', 'baby', 'babies', 'infant', 'toddler', 'teen', 'teenager', 'child',
    'boy', 'boys', 'girl', 'girls', 'man', 'men', 'woman', 'women', 'lady', 'ladies', 'guy', 'guys', 'person', 'persons', 'mr', 'mrs', 'ms', 'miss', 'mme', 'mlle', 'monsieur', 'madame',
    'mademoiselle', 'dr', 'doctor', 'doctors', 'nurse', 'nurses', 'name', 'named', 'widow', 'widower', 'orphan',
    'il', 'elle', 'ils', 'elles', 'lui', 'leur', 'leurs', 'son', 'sa', 'ses', 'mon', 'ma', 'mes', 'ton', 'ta', 'tes', 'je', 'j', 'm', 't', 'tu', 'moi', 'toi', 'mere', 'meres', 'pere', 'peres',
    'femme', 'femmes', 'mari', 'maris', 'epoux', 'epouse', 'fils', 'fille', 'filles', 'soeur', 'soeurs', 'frere', 'freres', 'enfant', 'bebe', 'bebes', 'garcon', 'garcons', 'homme', 'hommes',
    'dame', 'dames', 'veuve', 'veuf', 'personne', 'personnes',
    'has', 'had', 'having', 'was', 'were', 'been', 'being', 'did', 'takes', 'took', 'taken', 'taking', 'lost', 'lose', 'loses', 'broke', 'broken', 'break', 'diagnosed', 'diagnosis', 'diagnose',
    'suffer', 'suffers', 'suffered', 'suffering', 'passed', 'died', 'dies', 'die', 'dying', 'dead', 'death', 'deceased', 'born', 'birth', 'married', 'divorced', 'admitted', 'treated', 'treatment',
    'treatments', 'claim', 'claims', 'claimed', 'claimant', 'claimants', 'approved', 'approval', 'denied', 'declined', 'rejected', 'refused', 'pending', 'lapsed', 'lapse', 'rated', 'underwriting',
    'underwritten', 'underwriter', 'table', 'off', 'absent', 'leave', 'laid', 'fired', 'injured', 'injury', 'hurt', 'fell', 'cannot', 'cant', 'unable', 'unwell', 'sick', 'ill', 'weak', 'blind',
    'deaf', 'paralyzed', 'paralysed', 'walk', 'walks', 'walked', 'walking', 'drink', 'drinks', 'drank', 'drinker', 'tested', 'test', 'tests',
    'result', 'results', 'positive', 'negative', 'stage', 'chronic', 'terminal', 'terminally', 'recovering', 'recovered', 'recovery', 'condition', 'conditions', 'answered', 'answer', 'answers',
    'ai', 'ont', 'avait', 'avais', 'etait', 'etais', 'fut', 'ete', 'mort', 'morte', 'decede', 'decedee', 'malade', 'souffre', 'souffrant', 'souffrants', 'atteint', 'atteinte', 'atteints',
    'atteintes', 'enceinte', 'prend', 'pris', 'perdu', 'casse', 'diagnostique', 'refuse', 'refusee', 'accepte', 'approuve', 'approuvee', 'rejete', 'rejetee', 'reclamation', 'reclamations',
    'sinistre', 'sinistres', 'accidente', 'blesse', 'blessee', 'hospitalise', 'income', 'incomes', 'revenu', 'revenus', 'salary', 'wage', 'wages',
    'we', 'us', 'our', 'ours', 'ourselves', 'nous', 'notre', 'nos', 'one', 'ones', 'someone', 'anyone', 'everyone', 'somebody', 'anybody', 'everybody', 'nobody', 'none', 'parents', 'parent', 'children', 'kids',
    'people', 'couples', 'gens', 'enfants', 'proches', 'family members', 'relatives', 'relative', 'friend', 'friends', 'neighbour', 'neighbours', 'neighbor', 'neighbors', 'colleague', 'colleagues',
    -- round 4 (S8): age, body measure, habit, pay / debt and applicant words an owner could still add
    'aged', 'old', 'older', 'elderly', 'yes', 'weight', 'weights', 'weighs', 'height', 'tall', 'lbs', 'lb', 'kg', 'pounds', 'overweight', 'underweight', 'bmi', 'sober', 'sobriety', 'expecting', 'expectant', 'shrink',
    'therapist', 'therapy', 'owes', 'owe', 'owed', 'owing', 'dui', 'dwi', 'earns', 'earn', 'earned', 'earning', 'earnings', 'figures', 'figure', 'applicant', 'applicants', 'smoke', 'smokes', 'smoked', 'smoking',
    'vape', 'vapes', 'vaping', 'fume', 'fumer', 'fumes', 'gagne', 'gagnes', 'salaried', 'unemployed', 'jobless', 'bankrupt', 'arrears', 'overdue', 'gender', 'sex', 'sexe', 'race', 'religion', 'ethnicity', 'citizenship', 'ssn', 'nas']) then return true; end if;
  if w ~ '^(diagnos|suffer|claim|underwrit)' then return true; end if;
  if public.ws_name_word_hit(w) then return true; end if;
  if p_health and public.ws_health_word_hit(w) then return true; end if;
  return false;
end $$;

-- 6b. capitalised names. A vocabulary word that is also a given name or surname ("Will", "Page", "Sam", "Summer") is vocabulary when written in lower case, but a CAPITALISED
--     occurrence is treated as a name and fails closed. p_strict (term management): hard names in any case, soft names whenever capitalised. Text: hard names whenever
--     capitalised; soft names when capitalised in mid-sentence (not at the start of the text or of a sentence) or when the whole text has no lower-case letter.
--     Round 4 (S5), text only: any vocabulary word can be a surname ("the Price family", "quote for Tailor", "call Day"), so three POSITIONS fail closed whatever the word is:
--       * "<word> family" unless the word is a determiner / plain adjective (your, the, every, whole, new ...), and "famille <Capitalised word>";
--       * "for <word>" / "pour <word>" closing a clause, unless the word is a plural or one of a short list (you, free, less, life, business, home ...);
--       * a Capitalised word right after for / to / of / from / by / with / call / contact / ask / meet / email / text / tell / see (pour / de / avec / appelez / contactez), unless it is a
--         place of the catalog, a province, a month, a weekday, a platform or a product-name word (Life, Insurance, Term ...), or the whole text is written In Title Case
--         (then the two rules above are the only defence: a stated limit).
create or replace function public.ws_capitalised_name(p_text text, p_strict boolean default false) returns boolean
language plpgsql stable set search_path to 'pg_catalog' as $$
declare lt text; caps_mid integer := 0; lower_long integer := 0; bad boolean := false; starts boolean; prevw text := '';
        hard text[] := array['will', 'may', 'page', 'sam', 'don'];
        soft text[] := array['star', 'stars', 'summer', 'spring', 'winter', 'sun', 'sat', 'wed', 'long', 'young', 'best', 'bill', 'bills', 'mo', 'fall'];
        m text[]; w text; t text; lower_present boolean; toks text[] := '{}'; ntok integer; i integer;
begin
  -- the same normalisation as ws_fold_text, but case-preserving (zero-width and combining characters out, fullwidth / mathematical letters and look-alikes to Latin)
  t := coalesce(p_text, '');
  t := regexp_replace(t, '[\u00ad\u034f\u061c\u115f\u1160\u17b4\u17b5\u180b-\u180e\u200b-\u200f\u202a-\u202e\u2060-\u206f\u3164\ufe00-\ufe0f\ufeff\uffa0]', '', 'g');
  t := regexp_replace(t, '[\U000e0001\U000e0020-\U000e007f\U000e0100-\U000e01ef]', '', 'g');
  t := normalize(t, nfkc);
  t := normalize(t, nfd);
  t := regexp_replace(t, '[\u0300-\u036f\u1ab0-\u1aff\u1dc0-\u1dff\u20d0-\u20ff\ufe20-\ufe2f]', '', 'g');
  t := translate(t, 'ΗΝΜΥΖΒΕΚΟΡΤΧΑΙАВЕКМНОРСТХУІЈЅ', 'HNMYZBEKOPTXAIABEKMHOPCTXYIJS');
  t := translate(t, 'ıавекмнорстухіїјѕԁԛԝһӏүѡɑɡαβγεικνορτυχωϲϳςμη', 'iabekmhopctyxiijsdqwhlywagabyeikvoptuxwcjcun');
  lower_present := t ~ '[a-z]';
  for m in select g from regexp_matches(t, '(^|[.!?][ \t\n]+|[^A-Za-z])([A-Za-z]+)(?![A-Za-z])(?![''’]t(?![A-Za-z]))', 'g') as r(g) loop
    w := lower(m[2]);
    if p_strict and w = any (hard) then return true; end if;
    if m[2] !~ '^[A-Z]' then continue; end if;
    if w = any (hard) then return true; end if;
    if w = any (soft) and (p_strict or not lower_present or not (m[1] = '' or m[1] ~ '^[.!?]')) then return true; end if;
  end loop;
  -- positions that are never modal or ordinary use, in ANY case: first or last word of the text, or right after for / to / of / from / beneficiary / named / by / with
  for m in select g from regexp_matches(lower(t), '(^|[^a-z])([a-z]+)(?![a-z])(?![''’]t(?![a-z]))', 'g') as r(g) loop toks := toks || m[2]; end loop;
  ntok := coalesce(cardinality(toks), 0);
  for i in 1..ntok loop
    if toks[i] = any (array['will', 'may', 'don', 'sam', 'bill', 'sun', 'sat', 'wed']) and (i = 1 or i = ntok) then return true; end if;     -- (seasons at an edge stay allowed: "Spring promo", "Summer sale")
    if toks[i] = any (array['will', 'may', 'don', 'sam', 'bill', 'page', 'mo', 'sun', 'sat', 'wed', 'summer', 'spring', 'mark', 'rose', 'grace']) and i > 1 and toks[i - 1] = any (array['for', 'to', 'of', 'from', 'beneficiary', 'named', 'by', 'with']) then return true; end if;
  end loop;
  if p_strict then return false; end if;
  lt := lower(t);
  for m in select g from regexp_matches(lt, '(^|[^a-z])([a-z]+) +(family|famille)(?![a-z])', 'g') as r(g) loop
    if m[2] <> all (array['your', 'the', 'a', 'an', 'every', 'each', 'whole', 'entire', 'new', 'for', 'of', 'to', 'and', 'or', 'with', 'by', 'from', 'as', 'protect', 'protects', 'protecting', 'canadian', 'local', 'growing',
                          'big', 'small', 'large', 'busy', 'modern', 'working', 'single', 'this', 'that', 'any', 'all', 'no', 'more', 'votre', 'la', 'une', 'chaque', 'toute', 'pour', 'de', 'et', 'protegez', 'en']) then return true; end if;
  end loop;
  if t ~ '(^|[^A-Za-z])[Ff][Aa][Mm][Ii][Ll][Ll][Ee] +[A-Z][a-z]' then return true; end if;
  for m in select g from regexp_matches(lt, '(^|[^a-z])(for|pour) +([a-z]+) *($|[.,;:!?])', 'g') as r(g) loop
    if m[3] !~ 's$' and m[3] <> all (array['you', 'free', 'less', 'life', 'business', 'home', 'travel', 'work', 'sale', 'today', 'now', 'more', 'all', 'it', 'this', 'that', 'canada', 'ontario', 'quebec', 'alberta', 'manitoba',
                                          'saskatchewan', 'retirement', 'everything', 'coverage', 'protection', 'insurance', 'security', 'auto', 'car', 'real', 'sure', 'good', 'vous', 'tous', 'toutes', 'moins', 'tout', 'toujours', 'vrai']) then return true; end if;
  end loop;
  if lower_present then
    for m in select g from regexp_matches(t, '(^|[.!?:;][ \t\n]+|["(\n•*-] ?|[^A-Za-z])([A-Za-z]+)', 'g') as r(g) loop
      starts := m[1] = '' or m[1] ~ '^[.!?:;"(\n•*-]';
      w := lower(m[2]);
      if m[2] ~ '^[A-Z]' and not starts then
        if m[2] ~ '^[A-Z]{2,}$' then prevw := w; continue; end if;
        caps_mid := caps_mid + 1;
        if prevw = any (array['for', 'to', 'of', 'from', 'by', 'with', 'call', 'contact', 'ask', 'meet', 'email', 'text', 'tell', 'see', 'pour', 'de', 'avec', 'appelez', 'contactez'])
           and w <> all (array['canada', 'canadian', 'canadians', 'canadien', 'canadiens', 'canadienne', 'canadiennes', 'ontario', 'quebec', 'alberta', 'british', 'columbia', 'manitoba', 'saskatchewan', 'newfoundland', 'labrador',
                           'nova', 'scotia', 'brunswick', 'territories', 'january', 'february', 'march', 'april', 'june', 'july', 'august', 'september', 'october', 'november', 'december', 'janvier', 'fevrier', 'mars', 'avril',
                           'mai', 'juin', 'juillet', 'aout', 'septembre', 'octobre', 'novembre', 'decembre', 'monday', 'tuesday', 'wednesday', 'thursday', 'friday', 'saturday', 'sunday', 'mon', 'tue', 'thu', 'fri',
                           'lundi', 'mardi', 'mercredi', 'jeudi', 'vendredi', 'samedi', 'dimanche', 'meta', 'google', 'facebook', 'instagram', 'tiktok', 'linkedin', 'youtube', 'i', 'faq',
                           'insurance', 'insurances', 'assurance', 'assurances', 'life', 'term', 'whole', 'universal', 'health', 'dental', 'disability', 'critical', 'illness', 'travel', 'home', 'auto', 'car', 'mortgage',
                           'group', 'benefits', 'coverage', 'protection', 'plan', 'plans', 'policy', 'vie', 'invalidite', 'sante', 'maladie', 'maladies', 'grave', 'graves', 'dentaire', 'voyage', 'collective', 'temporaire', 'permanente',
                           'habitation', 'hypothecaire', 'accident', 'income', 'medical', 'exam', 'care', 'long', 'final', 'expense', 'key', 'person', 'business', 'pet', 'tenant', 'condo', 'commercial', 'liability', 'cyber'])
           and not exists (select 1 from public.ws_place_catalog c where w = any (string_to_array(c.name_norm, ' '))) then bad := true; end if;
      elsif m[2] ~ '^[a-z]' and length(m[2]) >= 4 then lower_long := lower_long + 1;
      end if;
      prevw := case when starts and m[1] <> '' then '' else w end;
    end loop;
    if bad and not (caps_mid >= 2 and lower_long = 0) then return true; end if;
  end if;
  return false;
end $$;

-- 6c. spelled-out number words (en, fr), as one regular-expression alternation. One place, so every rule counts the same words.
create or replace function public.ws_number_words() returns text
language sql immutable set search_path to 'pg_catalog' as $$
  select 'zero|one|two|three|four|five|six|seven|eight|nine|ten|eleven|twelve|thirteen|fourteen|fifteen|sixteen|seventeen|eighteen|nineteen|twenty|thirty|forty|fifty|sixty|seventy|eighty|ninety|hundred|thousand|million|billion|deux|trois|quatre|cinq|sept|huit|neuf|dix|onze|douze|treize|quatorze|quinze|seize|vingt|trente|quarante|cinquante|soixante|cent|cents|mille|milles|millions'::text;
$$;

-- 6d. FINANCIAL AND APPLICATION DETAIL (review round 4, B1 / S6). Fails closed: in insurance-context text an amount of money is refused unless it is one of two marketing forms:
--       a PRICE PER PERIOD   "from $18 a month", "only $25/week", "des 25 $ par mois", "$25/month"   (lead word, at most 3 digits, per day / week / month; never per hour or per year)
--       a COVERAGE CEILING   "up to $500,000", "jusqu'a 1 000 000 $"                              (the words "up to" / "jusqu'a" and a round number of thousands)
--     Refused whatever the other words are: any other currency amount ("$85,000", "45000 $", "85k", "$30/hour"), a spelled-out magnitude (hundred, thousand, million, mille, cent),
--     a number word next to a period ("fifty a year", "six monthly"), a spelled-out age ("age forty five"), payment-trouble wording (late on, behind on, arrears, unemployed, bankrupt),
--     and (p_strict, a single value) a pay / debt word (pay, paid, makes, earns, salary, paycheque, mortgage, loan, debt, tax, cash, rent, job ...) in the same value as ANY amount or number.
--     Input: a folded view (approved terms already cut out). Never echoes. The joined all-columns scan passes p_strict = false (a product price in one column next to "mortgage" in another is normal ad copy).
create or replace function public.ws_financial_hit(p_fold text, p_strict boolean default true) returns boolean
language plpgsql immutable set search_path to 'pg_catalog' as $$
declare n text; m text; nw text := '(?:' || public.ws_number_words() || ')';
        amt text := '(?:\$ ?[0-9]{1,3}(?:[.,][0-9]{2})?|[0-9]{1,3}(?:[.,][0-9]{2})? ?\$)';
begin
  n := ' ' || translate(coalesce(p_fold, ''), '€£¥', repeat(chr(36), 3)) || ' ';
  n := regexp_replace(replace(n, '''', ' '), '[[:space:]]+', ' ', 'g');
  n := replace(n, ' pour cent', ' %');
  -- the two allowed forms become placeholders
  n := regexp_replace(n, '([^a-z0-9$])(from|only|just|at|for|as low as|starting at|starts at|under|less than|about|des|a partir de|pour|seulement|moins de) ' || amt
                         || ' ?(?:(?:/|per|a|an|par|each|every) ?)?(?:mo|month|mois|week|semaine|day|jour|monthly|weekly|daily)(?![a-z0-9])', '\1 zzprice ', 'g');
  n := regexp_replace(n, '([^a-z0-9$,.])\$ ?[0-9]{1,3}(?:[.,][0-9]{2})? ?/ ?(?:mo|month|mois)(?![a-z0-9])', '\1 zzprice ', 'g');
  n := regexp_replace(n, '([^a-z0-9$])(up to|jusqu a|jusqu au) (?:\$ ?[1-9][0-9]{0,2}(?:,000){1,2}|[1-9][0-9]{0,2}(?: 000){1,2} ?\$)(?![0-9k]|[,.][0-9])', '\1 zzcov ', 'g');
  if n ~ '\$|[0-9] ?(?:dollars?|cad|usd|euros?|bucks|piastres?|grand|k)(?![a-z0-9])' then return true; end if;
  -- a spelled-out COUNT of things ("over ten thousand families", "plus de mille clients"): the words over / more than, number words, then a plural noun that is not money or time
  n := regexp_replace(n, '([^a-z])(over|more than|plus de) ' || nw || '(?: ' || nw || ')* (?!dollars|bucks|years|months|weeks|hours|days|piastres|euros|ans|mois|cents)(?=[a-z]+s[^a-z])', '\1\2 zzcount ', 'g');
  if n ~ '[^a-z](?:hundred|thousand|million|billion|mille|milles|millions|millier|milliers|cent|cents)(?![a-z])' then return true; end if;
  if n ~ ('[^a-z]' || nw || '(?:[ -]+' || nw || ')*[ -]+(?:(?:a|an|per|par|each|every|de l|l) )?(?:year|yr|month|week|hour|an|annee|mois|semaine|heure)(?![a-z])(?! (?:term|terme|plan|guarantee|garantie|renewable|renouvelable))')
     or n ~ ('[^a-z]' || nw || ' (?:yearly|monthly|weekly|annually|hourly|biweekly)(?![a-z])') then return true; end if;
  if n ~ ('[^a-z](?:age|aged|ages|agee|agees)[^a-z0-9]{0,3}(?:de )?' || nw || '(?![a-z])')
     or n ~ ('[^a-z]' || nw || '(?:[ -]+' || nw || ')?[ -]+(?:years?|yrs?|ans)[ -]+(?:old|olds)(?![a-z])') then return true; end if;
  if n ~ ('[^a-z](?:(?:months?|weeks?|days?|payments?|mois|semaines?|paiements?) (?:late|behind|overdue|en retard)|late on|behind on|overdue|en retard|past due|arrears|arrerages|'
          || 'missed (?:[a-z]+ ){0,2}payments?|laid off|out of work|unemployed|sans emploi|chomage|bankrupt[a-z]*|faillite|foreclos[a-z]*|garnish[a-z]*|collections agency)(?![a-z])') then return true; end if;
  if p_strict and n ~ ('[^a-z](?:pay|pays|paid|paying|payez|paye|payes|payer|make|makes|made|making|earn[a-z]*|gagne[a-z]*|salar[a-z]*|wages?|paycheques?|paychecks?|paystubs?|mortgages?|hypothe[a-z]*|'
          || 'loans?|prets?|debts?|dettes?|owe[sd]?|owing|doit|tax|taxes|impots?|cash|rent|loyer|job|jobs|emploi|worth|net|gross|brut|hourly|income|incomes|revenus?)(?![a-z])') then
    m := regexp_replace(n, '([^0-9])24 ?/ ?7([^0-9])', '\1 \2', 'g');
    m := regexp_replace(m, '([^0-9])(?:19|20)[0-9]{2}([^0-9])', '\1 \2', 'g');
    m := regexp_replace(m, '[0-9]+ ?-? ?(?:minutes?|mins?|hours?|heures?|days?|jours?|seconds?|secondes?|steps?|etapes?|reasons?|raisons?|stars?|etoiles?|tips?|conseils?)(?![a-z])', ' ', 'g');
    if m ~ ('zzprice|zzcov|zzcount|%|[0-9]|[^a-z]' || replace(nw, '|one|', '|') || '(?![a-z])') then return true; end if;      -- ("one" alone is a pronoun far more often than a number)
  end if;
  return false;
end $$;

-- 6e. APPROVED FEATURE PHRASES can never state a fact about a person (review round 4, B2). Input: the folded residual, where a feature phrase that names a condition is the token
--     <marker>c and any other feature phrase ("no medical exam") is <marker>f. Returns false (= refuse) when
--       * any feature phrase touches (over punctuation only) a second-person, possessive, family, having, negation, affirmation or answer word, or a check mark / star / arrow / thumb
--         ("sans" / "without" may touch a plain feature such as "examen medical", never a condition-naming one);
--       * a CONDITION-NAMING phrase stands in a value that is not a plain coverage template: besides product terms and the phrase itself only the words
--         covers / coverage / protection / against / in case of / and / or / plus / including (fr: couvre / couverture / contre / en cas de / et / ou / y compris) and , . : ; - may appear;
--       * (p_joined: the all-columns scan of a row) a condition-naming phrase shares the ROW with such a word, a symbol, a digit or a number word in any other column.
create or replace function public.ws_feature_context_ok(p_r text, p_marker text, p_joined boolean) returns boolean
language plpgsql immutable set search_path to 'pg_catalog' as $$
declare v text := replace(coalesce(p_r, ''), '''', ' '); fc text := p_marker || 'c'; fm text := p_marker || 'f'; mk text; n integer;
        deny text := '(?:you|your|yours|yourself|u|ur|vous|votre|vos|tu|ton|ta|tes|toi|have|has|had|having|got|avez|avoir|ai|as|family|families|famille|familles|familial|familiaux|no|not|non|none|never|pas|aucun|aucune|'
                     || 'jamais|yes|oui|yep|yeah|true|false|vrai|faux|zero|nil|free|any|all|some|both|neither|either|first|age|aged|ages|n|y|ok|today|now|current|currently|since|depuis|last|ago|history|historique|antecedents|who|qui|is|are|was|were|est|sont|x)';
        -- the words that make a statement about someone wherever they stand in the ROW (the generic ones above, such as free / any / today, only count when they touch the phrase)
        deny_row text := '(?:you|your|yours|yourself|u|ur|vous|votre|vos|tu|ton|ta|tes|toi|have|has|had|having|got|avez|avoir|ai|family|families|famille|familles|familial|familiaux|without|sans|no|not|non|none|never|pas|aucun|aucune|'
                     || 'jamais|yes|oui|yep|yeah|true|false|vrai|faux|zero|nil|neither|age|aged|ages|n|y|ok|since|depuis|ago|history|historique|antecedents)';
        decor text := '[✅⭐✔✓★→✨☑✗✘❌❎' || chr(128077) || chr(128078) || ']';
        tmpl text[] := array['covers', 'cover', 'covered', 'coverage', 'protection', 'protects', 'against', 'and', 'or', 'plus', 'including', 'includes', 'include', 'in', 'case', 'of', 'the', 'a', 'an',
                             'couvre', 'couvrent', 'couverture', 'contre', 'et', 'ou', 'y', 'compris', 'inclus', 'inclut', 'en', 'cas', 'de', 'd', 'le', 'la', 'les', 'l', 'un', 'une'];
begin
  mk := '(?:' || fc || '|' || fm || ')(?![a-z0-9])';
  if v !~ ('(^|[^a-z0-9])' || mk) then return true; end if;
  if v ~ ('(^|[^a-z0-9])' || fc || '(?![a-z0-9])[^a-z0-9]*(?:without|sans)(?![a-z0-9])') or v ~ ('(^|[^a-z0-9])(?:without|sans)[^a-z0-9]*' || fc || '(?![a-z0-9])') then return false; end if;
  if v ~ ('(^|[^a-z0-9])' || mk || '[^a-z0-9✅⭐✔✓★→✨☑✗✘❌❎' || chr(128077) || chr(128078) || ']*(?:' || decor || '|' || deny || '(?![a-z0-9]))')
     or v ~ ('(?:' || decor || '|(?:^|[^a-z0-9])' || deny || ')[^a-z0-9✅⭐✔✓★→✨☑✗✘❌❎' || chr(128077) || chr(128078) || ']*' || mk) then return false; end if;
  if v !~ ('(^|[^a-z0-9])' || fc || '(?![a-z0-9])') then return true; end if;
  if p_joined then
    return not (v ~ decor or v ~ '[0-9]' or v ~ ('(^|[^a-z0-9])' || deny_row || '(?![a-z0-9])') or v ~ ('(^|[^a-z])(?:' || public.ws_number_words() || ')(?![a-z])'));
  end if;
  select count(*) into n from regexp_matches(v, '[a-z0-9]+|[^a-z0-9 ]', 'g') as m(g)
   where not (m.g[1] = p_marker or m.g[1] = fc or m.g[1] = fm or m.g[1] = any (tmpl) or m.g[1] ~ '^[.,;:-]$');
  return n = 0;
end $$;

-- 7. the default-deny vocabulary test. Input: the folded residual (approved terms already cut out and replaced by p_marker, never re-joined). Returns the reason codes
--    (empty array = every token is vocabulary, an allowed number FORM, or simple punctuation). Never echoes the text.
--    Numbers: a bare number is NOT vocabulary. Only these forms are allowed: an amount of money in one of the two forms of ws_financial_hit, a percentage, #N, "in N minutes", N in M, 24/7, N days/hours (a fixed
--    list of marketing numbers), "30 year term", "20 years of experience", an age RANGE ("ages 18 to 65", at least 15 years wide).
--    Spelled-out numbers: 4+ number words anywhere, or 3 in a row ("zero four six"), fail. A yes/no/none answer straight after an approved term ("cancer: no") fails.
--    Round 4: an application-form shape fails whatever its words are: a one-word label and a colon ("beneficiary: ...", "age: ...", "family: ..."), and a bare answer after a colon,
--    question mark or dash ("exam: no", "have life insurance: no"). A month and a day is a number form only as a deadline ("before December 31"), never as "policy date march 3".
create or replace function public.ws_residual_check(p_r text, p_marker text) returns text[]
language plpgsql stable set search_path to 'pg_catalog' as $$
declare v text := coalesce(p_r, ''); codes text[] := '{}'; n integer; tmp text; m text[]; hrs boolean; fm text := p_marker || 'f'; pm text := p_marker || 'p'; cm text := p_marker || 'c';
        nw text := public.ws_number_words();
        neg text := 'no|not|non|oui|yes|pas|none|never|nope';
        mon text := 'january|february|march|april|june|july|august|september|october|november|december|janvier|fevrier|mars|avril|juin|juillet|aout|septembre|octobre|novembre|decembre|jan|feb|mar|apr|jun|jul|aug|sep|sept|oct|nov|dec';
begin
  v := translate(translate(v, '«»“”„•·‣', '"""""   '), '€£', chr(36) || chr(36));
  -- application-form shapes: a one-word field label and a colon / equals sign at the start of the text or of a clause; a bare answer after a colon, question mark or dash
  if v ~ ('(^|[.;,!?] *)(beneficiary|beneficiaries|beneficiaire|beneficiaires|insurer|insured|assureur|assure|exam|examen|age|ages|family|famille|plan|premium|prime|coverage|couverture|term|terme|policy|police|amount|montant|'
          || 'pay|mortgage|loan|budget|job|date|renewal|application|payment|paiement|rate|taux|home|car|auto|status|cash|tax|owner|employer|employeur|smoker|height|weight|gender|sex|sexe|dob|income|revenu) *[:=]')
     or v ~ '[:=?] *(no|non|none|not|never|pas|aucun|aucune|yes|oui|n|y|true|false|zero|nil|nope|ok|n/a|na) *([.,;!)]|$)'
     or v ~ ' - *(no|non|none|yes|oui|n|y|true|false|zero|nil|nope|ok) *([.,;!)]|$)' then
    codes := codes || array['unknown_word'];
  end if;
  -- a short whitelist of purely decorative symbols (check mark, star, sparkles, thumbs up, arrow); every other symbol or emoji is refused
  v := regexp_replace(translate(v, '✅⭐✔✓★→✨', '       '), chr(128077), ' ', 'g');
  -- negated ability and need ("can't work", "can not pay bills", "needs care"): narrative about a person, never marketing. Checked before apostrophes are split off.
  if v ~ '(^|[^a-z])(can ?not|cannot|can['' ]?t|could ?not|couldn[''’ ]?t|unable to|not able to|won[''’ ]?t|will not)( +[a-z]+)? +(work|walk|pay|afford|move|see|hear|speak|breathe|stand|drive|eat|sleep|care|cope|bills)([^a-z]|$)'
     or v ~ '(^|[^a-z])needs? +(care|surgery|treatment|dialysis|medication|assistance|a doctor)([^a-z]|$)' then
    codes := codes || array['unknown_word'];
  end if;
  v := regexp_replace(v, '(^|[^a-z0-9])(l|d|c|n|s|qu|jusqu|lorsqu|puisqu)''(?=[a-z0-9])', '\1\2 ', 'g');   -- French elision: l'assurance -> l assurance
  v := regexp_replace(v, '([a-z])''(s|t|ll|re|ve|d)(?![a-z0-9])', '\1 ', 'g');                              -- Canada's, don't
  v := replace(v, '''', ' ');                                                                                -- any other apostrophe (j'ai) just splits the word
  if v ~ '[^ -~]' then
    codes := codes || array['unknown_word', 'non_latin_script'];
    if v ~ '[a-z]' then codes := codes || array['mixed_script']; end if;
  end if;
  if v like '%zznum%' then codes := codes || array['unknown_word']; end if;
  tmp := regexp_replace(v, '(^|[^0-9])24 ?/ ?7([^0-9]|$)', '\1 \2', 'g');
  if v ~ '[a-z0-9]@|@[a-z0-9]' or v ~ '[a-z0-9&]&|&[a-z0-9#]' or v ~ '(^|[^0-9 ])%' or v ~ '(^|[^0-9]) +%' or v ~ '%[0-9a-f]{2}' or v ~ '(^|[^0-9])\+'
     or tmp ~ '(^|[^0-9a-z.,])[0-9]+ ?/ ?[0-9]+([^0-9a-z]|$)' then
    codes := codes || array['unknown_word', 'encoded_text'];
  end if;
  -- allowed number forms become the placeholder token zznum; anything numeric that is left is an unknown word
  if v ~ '[0-9]' then
    hrs := v ~ '(^|[^a-z])(hours?|heures?|open|opening|ouverts?|ouverture|monday|friday|lundi|vendredi|weekdays|saturday|samedi)([^a-z]|$)' or position(pm in v) > 0;
    v := regexp_replace(v, '(^|[^0-9])24 ?/ ?7([^0-9]|$)', '\1 zznum \2', 'g');
    -- (an amount of money that reaches this point is one of the two allowed forms: ws_financial_hit refused every other amount before this function was called)
    v := regexp_replace(v, '(^|[^0-9,.])[0-9]{1,3}( 000){1,2} ?\$', '\1 zznum ', 'g');
    v := regexp_replace(v, '\$ ?[0-9][0-9,.]*k?', ' zznum ', 'g');
    v := regexp_replace(v, '[0-9][0-9,.]*k? ?\$', ' zznum ', 'g');
    v := regexp_replace(v, '(^|[^0-9a-z])[0-9]{1,3}\+? +(insurers|assureurs|providers|companies|carriers|compagnies|plans|options|quotes|soumissions)([^a-z]|$)', '\1 zznum \2\3', 'g');
    v := regexp_replace(v, '[0-9][0-9,.]* ?%', ' zznum ', 'g');
    v := regexp_replace(v, '#[0-9]+', ' zznum ', 'g');
    v := regexp_replace(v, '(^|[^a-z0-9])(in|within|under|than|en|dans|sous|de) +[0-9]+ ?(minutes?|mins?|hours?|hrs?|heures?|days?|jours?|seconds?|secondes?)([^a-z]|$)', '\1\2 zznum \4', 'g');
    v := regexp_replace(v, '(^|[^a-z0-9])(24|48|72|7|14|15|21|30|60|90|365) ?-? ?(days?|jours?|hours?|heures?|hrs?)([^a-z]|$)', '\1 zznum \4', 'g');
    v := regexp_replace(v, '(^|[^0-9a-z])[0-9]+ in [0-9]+([^0-9a-z]|$)', '\1 zznum \2', 'g');
    v := regexp_replace(v, '(^|[^a-z])(before|until|till|by|ends|ending|avant) +(' || mon || ') +([1-9]|[12][0-9]|3[01])([^0-9a-z]|$)', '\1\2 \3 zznum \5', 'g');
    v := regexp_replace(v, '(^|[^a-z])(avant le|jusqu au|d ici le) +([1-9]|[12][0-9]|3[01]) +(' || mon || ')([^a-z]|$)', '\1\2 zznum \4\5', 'g');
    v := regexp_replace(v, '(^|[^0-9a-z])[0-9]{1,3} ?-? ?(minutes?|mins?|seconds?|secs?|secondes?) ', '\1 zznum ', 'g');
    v := regexp_replace(v, '(^|[^0-9a-z])[0-9]+ ?-? ?(years?|yrs?|ans?|annees?) ?(term|terme|plan|coverage|couverture|renewable|renouvelable|guarantee|garantie|level)([^a-z]|$)', '\1 zznum \3\4', 'g');
    v := regexp_replace(v, '(^|[^0-9a-z])(5|10|15|20|25|30|35|40) ?-? ?(years?|yrs?|ans?) +(' || p_marker || ')([^a-z]|$)', '\1 zznum \4\5', 'g');
    v := regexp_replace(v, '(^|[^0-9a-z])[0-9]+ ?\+? ?(years?|ans) (of experience|d experience|in business|of service|de service|serving)', '\1 zznum \3', 'g');
    v := regexp_replace(v, '(^|[^a-z])(top|meilleurs?) +[0-9]{1,2}([^0-9a-z]|$)', '\1 zznum \3', 'g');
    v := regexp_replace(v, '(^|[^0-9a-z])[0-9]{1,2} +(reasons?|raisons?|stars?|etoiles?|steps?|etapes?|tips?|conseils?|astuces?|ways|mistakes|myths|questions?)([^a-z]|$)', '\1 zznum \2\3', 'g');
    v := regexp_replace(v, '(^|[^a-z])(over|more than|plus de|plus d|plus que) +([0-9]{1,3}([, ][0-9]{3})+|[0-9]{3,})\+?', '\1\2 zznum ', 'g');
    v := regexp_replace(v, '(^|[^a-z])(since|depuis) +(19|20)[0-9]{2}([^0-9]|$)', '\1\2 zznum \4', 'g');
    for m in select g from regexp_matches(v, '((?:ages?|aged) +([0-9]{1,2}) ?(?:-|to|and|a|et) ?([0-9]{1,2}))', 'g') as r(g) loop
      if abs(m[3]::integer - m[2]::integer) >= 15 and m[2]::integer >= 18 then v := replace(v, m[1], ' zznum '); end if;
    end loop;
    if hrs then   -- opening hours: "9 to 5", "9am - 5pm", "9h a 17h", only next to an hours word or a fixed phrase such as Mon-Fri
      v := regexp_replace(v, '(^|[^0-9a-z])([0-9]|1[0-9]|2[0-4])(:[0-5][0-9])? ?(am|pm|h)? ?(-|to|a|et|and) ?([0-9]|1[0-9]|2[0-4])(:[0-5][0-9])? ?(am|pm|h)?([^0-9a-z]|$)', '\1 zznum \9', 'g');
      v := regexp_replace(v, '(^|[^0-9a-z])([0-9]|1[0-9]|2[0-4])(:[0-5][0-9])? ?(am|pm|h)([^a-z]|$)', '\1 zznum \5', 'g');
    end if;
  end if;
  -- spelled-out numbers: four or more number words anywhere in the text (also across punctuation: "nine nine nine, nine nine nine")
  select count(*) into n from regexp_matches(v, '(^|[^a-z])(' || nw || ')(?![a-z])', 'g');
  if n >= 4 or v ~ ('(^|[^a-z])(' || nw || ')([ ,.;:/-]+(' || nw || ')){2}(?![a-z])') then codes := codes || array['unknown_word']; end if;
  -- yes / no / none next to an approved feature phrase, on either side, over any punctuation ("cancer? no", "(no)", "no heart attack")
  if v ~ ('(' || fm || '|' || cm || ')[^a-z0-9]*(' || neg || ')([^a-z]|$)') or v ~ ('(^|[^a-z])(' || neg || ')[^a-z0-9]*(' || fm || '|' || cm || ')') then codes := codes || array['unknown_word']; end if;
  select count(*) into n from regexp_matches(v, '[a-z0-9]+(?:[.,][0-9]+)*|[^a-z0-9 ]', 'g') as m(g)
   where not (m.g[1] = p_marker or m.g[1] = fm or m.g[1] = pm or m.g[1] = cm
              or m.g[1] = 'zznum'
              or m.g[1] ~ '^[.,;:!?"()/%$|#+&@-]$'
              or exists (select 1 from public.ws_marketing_vocab w where w.word = m.g[1] and w.removed_at is null));
  if n > 0 then codes := codes || array['unknown_word']; end if;
  select coalesce(array_agg(distinct c order by c), '{}') into codes from unnest(codes) c;
  return codes;
end $$;

-- 8. insurance-context helpers. A word that marks the text as insurance-related (any obfuscation view), and the row-level test the guards use.
create or replace function public.ws_text_insurance_word(p_fold text, p_l1 text, p_l2 text) returns boolean
language plpgsql immutable set search_path to 'pg_catalog' as $$
declare x text; kc text;
begin
  foreach x in array array[coalesce(p_fold, ''), coalesce(p_l1, ''), coalesce(p_l2, '')] loop
    kc := regexp_replace(x, '[^a-z0-9]', '', 'g');
    if kc ~ '(insur|assuranc|underwrit|beneficiar|annuit|indemnit|versicher|seguro|assicura|sigorta)' then return true; end if;
  end loop;
  return false;
end $$;

-- S3 (review round 4): the insurance screen no longer depends on what a free-text, nullable label happens to say. A workspace gets the insurance screen UNLESS its vertical is exactly
-- one of the verticals this system knows to be something else (today: 'mortgage', the only other vertical with an onboarding template). NULL, blank, misspelled, unknown, new: insurance
-- screen (fail closed). A new non-insurance vertical is added here, by a migration, never by naming a workspace.
create or replace function public.ws_vertical_insurance(p_vertical text) returns boolean
language sql immutable set search_path to 'pg_catalog' as $$
  select lower(btrim(coalesce(p_vertical, ''))) <> all (array['mortgage']);
$$;

create or replace function public.ws_insurance_context(p_text text, p_ws uuid) returns boolean
language plpgsql stable security definer set search_path to 'pg_catalog' as $$
declare vert text; hit boolean;
begin
  -- WORKSPACE level (p_text is not consulted): every free-text column of a row in a workspace whose vertical is not a known non-insurance vertical, or in a workspace that holds
  -- an approved product term, is insurance context, whatever the words are. A workspace id that does not exist is insurance context too (fail closed).
  -- No workspace at all (the strict screen of ws_classify_text(text)) is not: that caller asked for the old screen.
  if p_ws is null then return false; end if;
  select true, vertical into hit, vert from public.client_workspaces where id = p_ws;
  if hit is not true then return true; end if;
  if public.ws_vertical_insurance(vert) then return true; end if;
  return exists (select 1 from public.ws_approved_terms where removed_at is null and kind = 'product' and (workspace_id = p_ws or (vert is not null and vertical = vert)));
end $$;

-- 9. THE classifier core. Never echoes the text. Reasons are fixed codes: the old category names, plus
--    health:no_approved_term / health:residual / health:personal_context / identifier / insurance_identifier / unknown_word / non_latin_script / mixed_script / encoded_text /
--    financial_detail / approved_product_term / approved_feature / approved_place / insurance_vocabulary.
--    p_row_ctx: the guards pass true for every free-text column of a row when ANY column of that row is insurance-context. p_joined: the all-columns-joined scan (split values):
--    categories, health, identifiers, amounts, feature-phrase context and spelled-out digit groups, no vocabulary test (the columns were each tested on their own).
--    p_person: the row belongs to a PERSON table (leads, routing, consent) of an insurance workspace: same default-deny screen, but no feature-phrase waiver and no 'your income' waiver.
drop function if exists public.ws_classify_core(text, uuid, boolean, boolean);   -- the 4-argument version of earlier review rounds, if a scratch database has it
create or replace function public.ws_classify_core(p_text text, p_ws uuid, p_row_ctx boolean, p_joined boolean, p_person boolean default false) returns jsonb
language plpgsql stable security definer set search_path to 'pg_catalog' as $$
declare
  f text; l1 text; l2 text; r text; r1 text; r2 text; prev text; rx text; tr record; vert text; marker text; before_r text; fx text; ct text; cf text; mk text;
  cats_s text[] := '{}'; allc text[]; hh text[]; health boolean := false; health0 boolean; inc boolean := false; x text; res text[];
  n_prod integer := 0; n_place integer := 0; n_feat integer := 0; n_phr integer := 0; ctx boolean := false; cut boolean := false; pass integer; word_ctx boolean; views text[]; ex text[]; nm boolean; is_cond boolean;
  prodwords text[] := array['health', 'medical', 'dental', 'disability', 'disabilities', 'critical', 'illness', 'illnesses', 'accident', 'accidental', 'dismemberment', 'death', 'sante', 'invalidite', 'maladie', 'maladies', 'grave', 'graves', 'dentaire', 'medicale', 'income', 'revenu', 'revenus'];
begin
  if p_text is null or btrim(p_text) = '' then return jsonb_build_object('allowed', true, 'reasons', '[]'::jsonb); end if;
  f := public.ws_fold_text(p_text);
  -- context (waivers and the vocabulary test) is a property of the WORKSPACE (see ws_insurance_context); the guards pass p_row_ctx for a row they already know the answer for
  word_ctx := p_ws is not null and (coalesce(p_row_ctx, false) or public.ws_insurance_context(p_text, p_ws));
  -- a COVERAGE CEILING of a round million or more ("up to $1,000,000", "jusqu'a 1 000 000 $") is seven digits, which the old account-number rule refuses. In insurance context
  -- only, that one form (the words, then 1-3 digits and nothing but groups of 000) is masked for the category scan. It cannot carry an account number: every other digit is a zero.
  ct := p_text;
  if word_ctx then
    ct := regexp_replace(p_text, '(up to|jusqu[''’ ]?[aà]) +(\$ ?[1-9][0-9]{0,2}(,000){2}|[1-9][0-9]{0,2}([ \u00a0\u202f]000){2} ?\$)(?![0-9]|[,.][0-9])', '\1 zzcov ', 'gi');
  end if;
  cf := case when ct = p_text then f else public.ws_fold_text(ct) end;
  l1 := public.ws_leet_text(cf, 1);
  l2 := public.ws_leet_text(cf, 2);
  -- every previous category, on the original text and on the folded and leetspeak views. Union: a hit in ANY view is a hit.
  -- (identical views are scanned once: the union is the same, the work is not repeated)
  views := array[ct];
  if cf <> ct then views := views || cf; end if;
  if l1 <> cf then views := views || l1; end if;
  if l2 <> l1 then views := views || l2; end if;
  foreach x in array views loop
    hh := public.ws_sensitive_hits(x);
    if 'health' = any(hh) then health := true; end if;
    if 'application_or_income' = any(hh) then inc := true; end if;
    cats_s := cats_s || array_remove(array_remove(hh, 'health'), 'application_or_income');
  end loop;
  ex := array[cf];
  if l1 <> cf then ex := ex || l1; end if;
  if l2 <> l1 then ex := ex || l2; end if;
  foreach x in array ex loop
    if public.ws_health_extra_hit(x) then health := true; end if;
  end loop;
  -- insurance identifiers tied to a person: "policy number 1234567", "claim no. 998877", "numero de police 123456"
  if cf ~ '(polic[ey]|claim|reclamation|member|membre|certificate|certificat|contrat|contract)[ _.\-]*(no|nr|num|number|numero|nbr|id|#)?[ _.:#\-]*[a-z]{0,4}[ \-]?[0-9]([ \-]?[0-9]){4,}' then
    cats_s := cats_s || array['insurance_identifier'];
  end if;
  -- date of birth next to a number
  if cf ~ '(^|[^a-z])(born|dob|birthday|birth|naissance|ne le|nee le)[^0-9a-z]{0,15}[0-9]' then cats_s := cats_s || array['identity_document']; end if;
  health0 := health;

  -- strict screen (no workspace): exactly the previous behaviour
  if p_ws is null then
    allc := cats_s || case when inc then array['application_or_income'] else '{}'::text[] end;
    select coalesce(array_agg(distinct c order by c), '{}') into allc from unnest(allc) c;
    if cardinality(allc) > 0 then return jsonb_build_object('allowed', false, 'reasons', to_jsonb(allc || case when health then array['health'] else '{}'::text[] end)); end if;
    if not health then return jsonb_build_object('allowed', true, 'reasons', '[]'::jsonb); end if;
    return jsonb_build_object('allowed', false, 'reasons', jsonb_build_array('health', 'health:no_approved_term'));
  end if;

  -- workspace given. An insurance WORD in the text changes nothing here (a mortgage workspace keeps the previous behaviour; only policy / claim numbers and dates of birth
  -- are refused everywhere, see above).
  ctx := word_ctx;
  marker := 'zzqx';
  while position(marker in f) > 0 loop marker := marker || 'x'; end loop;
  select vertical into vert from public.client_workspaces where id = p_ws;
  r := f;
  -- cut approved terms out of the TOKEN STREAM: whole words only, replaced by a marker that keeps the neighbours apart (no re-joining, so a splice
  -- such as "dia health insurance betes" leaves the two halves as separate unknown words). Pass 1: products and places, pass 2: feature phrases (only next to insurance context).
  if ctx then
    -- owner-managed FIXED PHRASES ("contact us", "our team", "notre equipe"): whole phrase only, cut like an approved term, so its pronoun is never vocabulary on its own
    for tr in select phrase_norm as term_norm from public.ws_fixed_phrases where removed_at is null and position(split_part(phrase_norm, ' ', 1) in r) > 0      -- cheap pre-filter: skip phrases whose first word is absent
                 order by length(phrase_norm) desc, phrase_norm loop
      rx := '(^|[^a-z0-9])' || replace(tr.term_norm, ' ', '[ ,\-]+') || '([^a-z0-9]|$)';
      prev := null;
      while r ~ rx and prev is distinct from r loop
        prev := r;
        r := regexp_replace(r, rx, '\1 ' || marker || 'p \2', 'g');
        n_phr := n_phr + 1;
      end loop;
    end loop;
  end if;
  for pass in 1..2 loop
    if pass = 2 then
      ctx := ctx or n_prod > 0;
      -- PERSON tables (lead notes, routing, consent): a feature phrase is never waived there. "non smokers" in a lead note is a statement about that lead.
      if not ctx or p_person then exit; end if;
    end if;
    for tr in select term_norm, kind from public.ws_approved_terms
              where removed_at is null and (workspace_id = p_ws or (vert is not null and vertical = vert))
                and ((pass = 1 and kind in ('product', 'place')) or (pass = 2 and kind = 'feature'))
              order by length(term_norm) desc, term_norm loop
      rx := '(^|[^a-z0-9])' || replace(tr.term_norm, ' ', '[ ,\-]+') || '([^a-z0-9]|$)';
      if r !~ rx then continue; end if;
      -- a feature phrase NAMES A CONDITION when one of its words is neither generic vocabulary nor a product-name word ("heart attack, stroke and cancer": yes; "no medical exam": no)
      is_cond := tr.kind = 'feature' and exists (select 1 from unnest(string_to_array(replace(tr.term_norm, '''', ' '), ' ')) w
                                                  where w <> '' and w <> all (prodwords) and not exists (select 1 from public.ws_marketing_vocab v where v.word = w and v.removed_at is null));
      mk := case when tr.kind <> 'feature' then marker when is_cond then marker || 'c' else marker || 'f' end;
      prev := null;
      while r ~ rx and prev is distinct from r loop
        prev := r;
        r := regexp_replace(r, rx, '\1 ' || mk || ' \2', 'g');
        if tr.kind = 'product' then n_prod := n_prod + 1; elsif tr.kind = 'place' then n_place := n_place + 1; else n_feat := n_feat + 1; end if;
      end loop;
    end loop;
  end loop;
  ctx := ctx or n_prod > 0;
  -- 'your income' is generic marketing; any other 'income' stays the mortgage-income category. Never when a currency amount (other than a product price per period) is present,
  -- and never on a person table.
  if ctx and not p_person then
    -- a PRICE OF THE PRODUCT ("from $25/month", "dès 25 $ par mois") is not an amount of income; "up to $4,500 a month" next to 'income' is
    fx := regexp_replace(f, '(^|[^a-z])(from|at|only|just|for|des|de|low as|starting|starts) +\$ ?[0-9][0-9,.]*[0-9]? *(/| per | a | par )? *(mo|month|mois|year|an|yr|week|day|jour|semaine|annee)([^a-z]|$)', '\1 \5', 'g');
    fx := regexp_replace(fx, '(^|[^a-z])(from|at|only|just|for|des|de|low as|starting|starts) +[0-9][0-9,.]*[0-9]? ?\$ ?(/| per | a | par )? *(mo|month|mois|year|an|yr|week|day|jour|semaine|annee)([^a-z]|$)', '\1 \5', 'g');
    fx := regexp_replace(fx, '(^|[^0-9])(19|20)[0-9]{2}([^0-9]|$)', '\1 \3', 'g');
    if fx !~ '[$]|[0-9] ?(dollars?|cad|usd|euros?|k)([^a-z]|$)|[0-9]{4,}'
       and f !~ ('(^|[^a-z])(' || public.ws_number_words() || ')([^a-z]|$)') then
      before_r := r;
      r := regexp_replace(r, '(^|[^a-z0-9])((your|votre) +)income(?![a-z0-9])', '\1\2 ' || marker || ' ', 'g');
      r := regexp_replace(r, '(^|[^a-z0-9])((votre|vos) +)revenus?(?![a-z0-9])', '\1\2 ' || marker || ' ', 'g');
      if r is distinct from before_r then cut := true; end if;
    end if;
  end if;
  cut := cut or (n_prod + n_place + n_feat + n_phr) > 0;
  if cut then
    -- health and income are decided on what is LEFT; every other category was decided on the whole text above
    health := false; inc := false;
    r1 := public.ws_leet_text(r, 1);
    r2 := public.ws_leet_text(r, 2);
    views := array[r];
    if r1 <> r then views := views || r1; end if;
    if r2 <> r1 then views := views || r2; end if;
    foreach x in array views loop
      hh := public.ws_sensitive_hits(x);
      if 'health' = any(hh) then health := true; end if;
      if 'application_or_income' = any(hh) then inc := true; end if;
      if public.ws_health_extra_hit(x) then health := true; end if;
    end loop;
  end if;
  allc := cats_s || case when inc then array['application_or_income'] else '{}'::text[] end;
  select coalesce(array_agg(distinct c order by c), '{}') into allc from unnest(allc) c;
  if cardinality(allc) > 0 then return jsonb_build_object('allowed', false, 'reasons', to_jsonb(allc || case when health0 then array['health'] else '{}'::text[] end)); end if;
  if health then
    if (n_prod + n_place + n_feat) = 0 then return jsonb_build_object('allowed', false, 'reasons', jsonb_build_array('health', 'health:no_approved_term')); end if;
    return jsonb_build_object('allowed', false, 'reasons', jsonb_build_array('health', 'health:residual'));
  end if;
  -- mixed Latin + Cyrillic/Greek letters: an obfuscation signature, never waived (only where a waiver or the vocabulary test applies)
  if (ctx or (health0 and n_place > 0)) and p_text ~ '[Ͱ-ϿЀ-ԯ]' and p_text ~ '[A-Za-z]' then
    return jsonb_build_object('allowed', false, 'reasons', to_jsonb(case when health0 then array['health'] else '{}'::text[] end || array['mixed_script', 'unknown_word']));
  end if;
  if ctx then
    -- B1: money, pay, debt, spelled-out amounts and ages (fail closed; only a price per period and a coverage ceiling are amounts a marketing text may carry)
    if public.ws_financial_hit(r, not p_joined) then
      return jsonb_build_object('allowed', false, 'reasons', to_jsonb(case when health0 then array['health'] else '{}'::text[] end || array['financial_detail']));
    end if;
    if public.ws_identifier_hit(r) then
      return jsonb_build_object('allowed', false, 'reasons', to_jsonb(case when health0 then array['health'] else '{}'::text[] end || array['identifier']));
    end if;
    -- B2: an approved feature phrase may only stand where it cannot state a fact about a person (also checked on the joined row: "you have" in one column, the phrase in another)
    if n_feat > 0 and not public.ws_feature_context_ok(r, marker, p_joined) then
      return jsonb_build_object('allowed', false, 'reasons', jsonb_build_array('health', 'health:residual'));
    end if;
    if not p_joined then
      res := public.ws_residual_check(r, marker);
      if cardinality(res) = 0 and public.ws_capitalised_name(p_text, false) then res := array['unknown_word']; end if;
      if cardinality(res) > 0 then
        return jsonb_build_object('allowed', false, 'reasons', to_jsonb(case when health0 then array['health'] else '{}'::text[] end || res));
      end if;
    elsif (select count(*) from regexp_matches(r, '(^|[^a-z])(' || public.ws_number_words() || ')(?![a-z])', 'g')) >= 4
          or r ~ ('(^|[^a-z])(' || public.ws_number_words() || ')([ ,.;:/-]+(' || public.ws_number_words() || ')){2}(?![a-z])') then
      -- S4: spelled-out digit groups split across the columns of one row
      return jsonb_build_object('allowed', false, 'reasons', to_jsonb(case when health0 then array['health'] else '{}'::text[] end || array['unknown_word']));
    end if;
    return jsonb_build_object('allowed', true, 'reasons', jsonb_build_array(case when n_prod > 0 then 'approved_product_term' when n_feat > 0 then 'approved_feature' when n_place > 0 then 'approved_place' else 'insurance_vocabulary' end));
  end if;
  if health0 then
    -- no insurance context: only an approved PLACE name could have waived the health-looking word. Same rules as before: nothing personal or identifying may remain.
    if public.ws_personal_context_hit(r) or public.ws_personal_context_hit(r1) or public.ws_personal_context_hit(r2) then
      return jsonb_build_object('allowed', false, 'reasons', jsonb_build_array('health', 'health:personal_context'));
    end if;
    if public.ws_identifier_hit(r) then return jsonb_build_object('allowed', false, 'reasons', jsonb_build_array('health', 'identifier')); end if;
    return jsonb_build_object('allowed', true, 'reasons', jsonb_build_array('approved_place'));
  end if;
  return jsonb_build_object('allowed', true, 'reasons', '[]'::jsonb);
end $$;

-- the public classifier: same two-argument signature as before (hq_workspace.classify_text calls it)
create or replace function public.ws_classify_text(p_text text, p_ws uuid default null) returns jsonb
language sql stable security definer set search_path to 'pg_catalog' as $$
  select public.ws_classify_core(p_text, p_ws, false, false, false);
$$;

-- 10. owner-only term management. The audit row carries ids, kinds and counts only: never the term text.
drop function if exists public.ws_add_approved_term(uuid, text, text, text);
create or replace function public.ws_add_approved_term(p_ws uuid, p_vertical text, p_kind text, p_term text, p_confirm_vertical boolean default false) returns uuid
language plpgsql security definer set search_path to 'pg_catalog' as $$
declare v_term text; v_norm text; v_id uuid; v_words integer; v_scope text; n_active integer; w text; prodwords text[] := array[
          'health', 'medical', 'dental', 'disability', 'disabilities', 'critical', 'illness', 'illnesses', 'accident', 'accidental', 'dismemberment', 'death', 'sante', 'invalidite', 'maladie', 'maladies', 'grave', 'graves', 'dentaire', 'medicale', 'income', 'revenu', 'revenus'];
        ptdeny text[] := array['with', 'who', 'whom', 'people', 'persons', 'personnes', 'individuals', 'those', 'patients', 'sufferers', 'survivors', 'victims', 'suffering', 'living', 'having', 'atteint', 'atteinte', 'atteints',
          'atteintes', 'souffrant', 'souffrants', 'ceux', 'celles', 'gens', 'anyone', 'everyone', 'someone', 'women', 'men', 'femmes', 'hommes', 'pregnant', 'enceinte'];
        featdeny text[] := array['you', 'your', 'yours', 'yourself', 'vous', 'votre', 'vos', 'tu', 'ton', 'ta', 'tes', 'toi', 'have', 'had', 'got', 'avez', 'avoir', 'family', 'families', 'famille', 'familles', 'without', 'sans', 'free',
          'age', 'ages', 'aged', 'old', 'yes', 'oui', 'true', 'false', 'any', 'all', 'some', 'never', 'jamais', 'history', 'today', 'now', 'current', 'currently', 'since', 'depuis', 'is', 'are', 'est', 'sont'];
        negw text[] := array['no', 'not', 'non', 'nor', 'neither', 'none', 'pas', 'ni', 'aucun', 'aucune'];
        hits text[]; ws_words text[]; names_cond boolean;
begin
  perform public.ffm_require_owner();
  if (p_ws is null) = (p_vertical is null) then raise exception 'term refused: give exactly one of a workspace or a vertical'; end if;
  if p_kind is null or p_kind not in ('product', 'place', 'feature') then raise exception 'term refused: kind must be product, place or feature'; end if;
  if p_ws is not null and not exists (select 1 from public.client_workspaces where id = p_ws) then raise exception 'term refused: workspace not found'; end if;
  if p_vertical is not null and p_vertical !~ '^[a-z0-9][a-z0-9-]{1,40}$' then raise exception 'term refused: vertical must be lower-case letters, digits and hyphens'; end if;
  if p_vertical is not null and coalesce(p_confirm_vertical, false) is not true then raise exception 'term refused: a vertical-wide approval needs confirm_vertical = true (it applies to every workspace of that vertical)'; end if;
  v_term := btrim(regexp_replace(coalesce(p_term, ''), '[[:space:]]+', ' ', 'g'));
  if length(v_term) < 3 or length(v_term) > 120 then raise exception 'term refused: length must be 3 to 120 characters'; end if;
  if v_term !~ '^[A-Za-z\u00c0-\u00d6\u00d8-\u00f6\u00f8-\u00ff\u0152\u0153\u2019'' ,-]+$' or (p_kind <> 'feature' and position(',' in v_term) > 0) then raise exception 'term refused: letters, spaces, hyphens and apostrophes only (commas in a feature phrase); no digits or symbols'; end if;
  v_norm := btrim(replace(replace(public.ws_fold_text(v_term), '-', ' '), ',', ' '));
  v_norm := regexp_replace(v_norm, ' +', ' ', 'g');
  if v_norm !~ '^[a-z]+([ ''][a-z]+)*$' then raise exception 'term refused: could not be normalised to plain letters'; end if;
  v_words := cardinality(regexp_split_to_array(v_norm, ' '));
  -- words (apostrophe splits: assurance d'invalidite -> assurance, d, invalidite)
  ws_words := regexp_split_to_array(regexp_replace(v_norm, '''', ' ', 'g'), ' ');
  if p_kind = 'product' and (v_words < 2 or v_words > 6) then raise exception 'term refused: a product term is 2 to 6 words'; end if;
  if p_kind = 'feature' and (v_words < 2 or v_words > 12) then raise exception 'term refused: a feature phrase is 2 to 12 words'; end if;
  if p_kind = 'place' and v_words > 5 then raise exception 'term refused: a place name is at most 5 words'; end if;
  if public.ws_personal_context_hit(v_norm) then raise exception 'term refused: personal wording (first person or narrative) is not a product name'; end if;
  if public.ws_capitalised_name(v_term, true) then raise exception 'term refused: it contains a word that is also a given name or surname (write ordinary words in lower case)'; end if;
  hits := public.ws_sensitive_hits(v_norm) || public.ws_sensitive_hits(v_term);
  -- the only non-health category an owner may approve is the word 'income' inside a product or feature phrase (income protection, disability income)
  if exists (select 1 from unnest(hits) h where h not in ('health', 'application_or_income')) then raise exception 'term refused: it contains wording this system never allows (identity, banking, credit)'; end if;
  if 'application_or_income' = any(hits) then
    if p_kind = 'place' or 'application_or_income' = any(public.ws_sensitive_hits(regexp_replace(v_norm, '(^| )income( |$)', ' ', 'g'))) then
      raise exception 'term refused: income wording is accepted only as the whole word "income" inside a product or feature phrase';
    end if;
  end if;
  if p_kind = 'place' then
    if not exists (select 1 from public.ws_place_catalog where name_norm = v_norm) then raise exception 'term refused: a place must be chosen from the fixed municipality catalog (ws_place_catalog)'; end if;
  else
    -- no person, relation, title, narrative, claim or underwriting word, no targeting phrase ("for people with", "pour les personnes atteintes"), in ANY kind
    foreach w in array ws_words loop
      if (public.ws_vocab_denied(w, false) and not (w = any (prodwords))) or w = any (ptdeny) then raise exception 'term refused: it contains a person, narrative or targeting word'; end if;
    end loop;
    if p_kind = 'product' then
      if v_norm !~ '(^| )(insurance|assurance|assurances|coverage|cover|protection|benefit|benefits|plan|plans|policy|policies|couverture|garantie|garanties|annuity|rente)( |$)' then
        raise exception 'term refused: a product term must name a product (insurance, assurance, coverage, cover, protection, plan, benefit, policy ...)';
      end if;
      -- default deny: every word is generic vocabulary or a product-name word. No condition, medication, body part or name can pass.
      foreach w in array ws_words loop
        if not (w = any (prodwords)) and not exists (select 1 from public.ws_marketing_vocab v where v.word = w and v.removed_at is null) then
          raise exception 'term refused: every word of a product term must be generic marketing vocabulary or a product-name word (ask the owner to add the word to the vocabulary first)';
        end if;
      end loop;
    else
      -- feature phrase: vocabulary words, product-name words, and words the health detectors recognise ONE BY ONE as a coverage subject ("heart", "stroke", "cancer") plus a few companions ("attack").
      -- Word by word, never as a run: a name before a condition must fail on the name.
      foreach w in array ws_words loop
        if not (w = any (prodwords) or w = any (array['attack', 'attacks', 'failure', 'arrest', 'loss', 'bypass', 'replacement', 'crise', 'cardiaque', 'avc']) or exists (select 1 from public.ws_marketing_vocab v where v.word = w and v.removed_at is null)
                or public.ws_health_extra_hit(w) or public.ws_condition_hit(w) or 'health' = any(public.ws_sensitive_hits(w))) then
          raise exception 'term refused: a feature phrase may name only recognised coverage subjects and vocabulary words';
        end if;
        -- round 4 (S8): a feature phrase never addresses, owns, counts or dates anything ("you have ...", "family history of ...", "... free")
        if w = any (featdeny) then raise exception 'term refused: a feature phrase describes coverage; it cannot contain a second-person, possessive, family, having, affirmation or time word'; end if;
      end loop;
      -- a NEGATION next to a named condition is a statement about someone ("no <condition>", "non smokers"); a negated plain feature ("no medical exam") is fine
      names_cond := exists (select 1 from unnest(ws_words) x where x <> '' and x <> all (prodwords) and not exists (select 1 from public.ws_marketing_vocab v where v.word = x and v.removed_at is null));
      if names_cond and ws_words && negw then raise exception 'term refused: a feature phrase that names a condition cannot be negated (it would state a fact about a person)'; end if;
    end if;
  end if;
  v_scope := case when p_ws is not null then 'workspace/' || p_ws else 'vertical/' || p_vertical end;
  select count(*) into n_active from public.ws_approved_terms where removed_at is null and coalesce(workspace_id::text, 'v:' || vertical) = coalesce(p_ws::text, 'v:' || p_vertical);
  if n_active >= 100 then raise exception 'term refused: at most 100 active terms per scope'; end if;
  if exists (select 1 from public.ws_approved_terms where removed_at is null and coalesce(workspace_id::text, 'v:' || vertical) = coalesce(p_ws::text, 'v:' || p_vertical) and kind = p_kind and term_norm = v_norm) then
    raise exception 'term already approved in this scope';
  end if;
  insert into public.ws_approved_terms (workspace_id, vertical, kind, term, term_norm, vertical_confirmed) values (p_ws, p_vertical, p_kind, v_term, v_norm, p_vertical is not null) returning id into v_id;
  insert into public.audit_log (actor, action, target, detail)
    values ('owner', 'ws_approved_term_added', v_scope, jsonb_build_object('term_id', v_id, 'kind', p_kind, 'words', v_words, 'vertical_wide', p_vertical is not null));
  return v_id;
end $$;

create or replace function public.ws_remove_approved_term(p_term_id uuid) returns void
language plpgsql security definer set search_path to 'pg_catalog' as $$
declare t public.ws_approved_terms;
begin
  perform public.ffm_require_owner();
  select * into t from public.ws_approved_terms where id = p_term_id and removed_at is null for update;
  if t.id is null then raise exception 'approved term not found or already removed'; end if;
  update public.ws_approved_terms set removed_at = clock_timestamp(), removed_by = 'owner' where id = p_term_id;
  insert into public.audit_log (actor, action, target, detail)
    values ('owner', 'ws_approved_term_removed', case when t.workspace_id is not null then 'workspace/' || t.workspace_id else 'vertical/' || t.vertical end, jsonb_build_object('term_id', p_term_id, 'kind', t.kind, 'vertical_wide', t.vertical is not null));
end $$;

-- 11. owner-only vocabulary management. The audit row carries ids and the language only: never the word. A word on the hard deny list can never be added.
create or replace function public.ws_add_vocab_word(p_lang text, p_word text) returns uuid
language plpgsql security definer set search_path to 'pg_catalog' as $$
declare v_norm text; v_id uuid;
begin
  perform public.ffm_require_owner();
  if p_lang is null or p_lang not in ('en', 'fr') then raise exception 'word refused: language must be en or fr'; end if;
  if p_word is null or btrim(p_word) !~ '^[A-Za-z\u00c0-\u00d6\u00d8-\u00f6\u00f8-\u00ff\u0152\u0153]{2,30}$' then raise exception 'word refused: one word of 2 to 30 letters (no digits, spaces, hyphens or symbols)'; end if;
  v_norm := public.ws_fold_text(btrim(p_word));
  if v_norm !~ '^[a-z]{2,30}$' then raise exception 'word refused: could not be normalised to plain letters'; end if;
  if public.ws_vocab_denied(v_norm, true) then raise exception 'word refused: it is on the hard deny list (people, events, wording about a case, or anything medical) and can never be vocabulary'; end if;
  if p_lang = 'fr' and v_norm = 'on' then raise exception 'word refused: it is on the hard deny list (people, events, wording about a case, or anything medical) and can never be vocabulary'; end if;
  if public.ws_capitalised_name(initcap(v_norm), true) then raise exception 'word refused: it is also a common given name or surname; it stays out of the vocabulary unless the owner decides otherwise in a migration'; end if;
  if exists (select 1 from public.ws_marketing_vocab where lang = p_lang and word = v_norm and removed_at is null) then raise exception 'word already in the vocabulary'; end if;
  insert into public.ws_marketing_vocab (lang, word) values (p_lang, v_norm) returning id into v_id;
  insert into public.audit_log (actor, action, target, detail) values ('owner', 'ws_vocab_word_added', 'vocab/' || p_lang, jsonb_build_object('word_id', v_id, 'lang', p_lang));
  return v_id;
end $$;

create or replace function public.ws_remove_vocab_word(p_word_id uuid) returns void
language plpgsql security definer set search_path to 'pg_catalog' as $$
declare t public.ws_marketing_vocab;
begin
  perform public.ffm_require_owner();
  select * into t from public.ws_marketing_vocab where id = p_word_id and removed_at is null for update;
  if t.id is null then raise exception 'vocabulary word not found or already removed'; end if;
  update public.ws_marketing_vocab set removed_at = clock_timestamp(), removed_by = 'owner' where id = p_word_id;
  insert into public.audit_log (actor, action, target, detail) values ('owner', 'ws_vocab_word_removed', 'vocab/' || t.lang, jsonb_build_object('word_id', p_word_id, 'lang', t.lang));
end $$;

-- 11b. owner-only fixed-phrase management. A phrase is 2-4 words; every word is vocabulary or one of a short list of pronouns / possessives that only make sense inside a fixed phrase
--      (we, us, our, ours, nous, notre, nos, one, ones); a health, name or relation word, a first-person word and a narrative word are refused. Audit rows carry ids and the language only.
create or replace function public.ws_add_fixed_phrase(p_lang text, p_phrase text) returns uuid
language plpgsql security definer set search_path to 'pg_catalog' as $$
declare v_term text; v_norm text; v_id uuid; w text; ws_words text[];
begin
  perform public.ffm_require_owner();
  if p_lang is null or p_lang not in ('en', 'fr') then raise exception 'phrase refused: language must be en or fr'; end if;
  v_term := btrim(regexp_replace(coalesce(p_phrase, ''), '[[:space:]]+', ' ', 'g'));
  if v_term !~ '^[A-Za-zÀ-ÖØ-öø-ÿŒœ’'' -]{5,60}$' then raise exception 'phrase refused: letters, spaces, hyphens and apostrophes only (5 to 60 characters)'; end if;
  if public.ws_capitalised_name(v_term, true) then raise exception 'phrase refused: it contains a word that is also a given name or surname (write ordinary words in lower case)'; end if;
  v_norm := btrim(regexp_replace(replace(public.ws_fold_text(v_term), '-', ' '), ' +', ' ', 'g'));
  if v_norm !~ '^[a-z]+( [a-z]+){1,4}$' then raise exception 'phrase refused: 2 to 5 plain words'; end if;
  ws_words := regexp_split_to_array(v_norm, ' ');
  foreach w in array ws_words loop
    if public.ws_name_word_hit(w) or public.ws_health_word_hit(w) then raise exception 'phrase refused: it contains a person, name, relation or health word'; end if;
    if w = any (array['we', 'us', 'our', 'ours', 'nous', 'notre', 'nos', 'one', 'ones']) then continue; end if;
    if public.ws_vocab_denied(w, false) then raise exception 'phrase refused: it contains a person, narrative or first-person word'; end if;
    if not exists (select 1 from public.ws_marketing_vocab v where v.word = w and v.removed_at is null) then raise exception 'phrase refused: every other word must be marketing vocabulary'; end if;
  end loop;
  if exists (select 1 from public.ws_fixed_phrases where removed_at is null and phrase_norm = v_norm) then raise exception 'phrase already approved'; end if;
  insert into public.ws_fixed_phrases (lang, phrase, phrase_norm) values (p_lang, v_term, v_norm) returning id into v_id;
  insert into public.audit_log (actor, action, target, detail) values ('owner', 'ws_fixed_phrase_added', 'phrase/' || p_lang, jsonb_build_object('phrase_id', v_id, 'lang', p_lang, 'words', cardinality(ws_words)));
  return v_id;
end $$;

create or replace function public.ws_remove_fixed_phrase(p_phrase_id uuid) returns void
language plpgsql security definer set search_path to 'pg_catalog' as $$
declare t public.ws_fixed_phrases;
begin
  perform public.ffm_require_owner();
  select * into t from public.ws_fixed_phrases where id = p_phrase_id and removed_at is null for update;
  if t.id is null then raise exception 'fixed phrase not found or already removed'; end if;
  update public.ws_fixed_phrases set removed_at = clock_timestamp(), removed_by = 'owner' where id = p_phrase_id;
  insert into public.audit_log (actor, action, target, detail) values ('owner', 'ws_fixed_phrase_removed', 'phrase/' || t.lang, jsonb_build_object('phrase_id', p_phrase_id, 'lang', t.lang));
end $$;

-- 12. seed data. VOCABULARY: generic function and marketing words only (no person, relation, narrative, claim, underwriting or health word; the DO block below proves it
--     with the same deny function the owner functions use, and fails the migration otherwise). Terms ship EMPTY. A word the owner removed stays removed on re-apply.
insert into public.ws_marketing_vocab (lang, word, created_by)
select 'en', w, 'seed' from (select distinct unnest(regexp_split_to_array($v$
a an the and or but nor so yet if then than as at by for from in into of on onto out over per plus to under up upon via with within without about above across against along among around
behind below beside between beyond during except inside near since through throughout toward towards until while whether because both either neither each every all any some no not only just
also even more most much many less least other another such same own very too now today tomorrow here there where when what which who how why can could will would should may might must shall
do does don doesn isn aren be is are
you your yours yourself it its this that these those
protect protects protected cover covers covered pay pays paying paid save saves saving savings get gets learn compare comparing apply quote start choose find ask talk speak contact book schedule
visit see read discover build grow plan prepare secure safeguard insure insures enjoy feel stay keep give help helps support guide review check explore join click tap send request receive access
manage customize customise tailor simplify switch renew upgrade enroll sign buy shop reduce lower increase replace replaces replacing include includes including offer offers provide provides
let allows allow need needs want look looking take make makes worry trust rely begin
family families business businesses price prices pricing month months monthly year years yearly annual annually week weeks weekly day days daily hour hours minute minutes second seconds
coverage coverages protection protections plans quotes free benefit benefits policy policies insurance insurances insurer broker brokers agent agents advisor advisors adviser advisers advice
expert experts team service services online phone call text chat email rate rates premium premiums deductible lump sum payout payouts payment payments cost costs budget value option options
choice choices solution solutions program programs product products package packages deal deals discount discounts peace mind security future life lives home homes house car auto travel trip
trips vacation work worker workers employee employees employer employers owner owners self employed freelancer freelancers professional professionals entrepreneur entrepreneurs student
students senior seniors retirement retirees canada canadian canadians ontario quebec alberta british columbia manitoba saskatchewan newfoundland labrador
scotia brunswick territories north south east west province provinces nationwide national local coast mortgage mortgages
affordable simple easy fast quick flexible personal personalized best top trusted licensed independent leading reliable safe strong smart clear transparent complete comprehensive extra
additional new real true better good great perfect right ready available guaranteed limited full whole term permanent universal group individual extended long short high low fair
competitive tax
two three four five six seven eight nine ten twenty thirty forty fifty hundred thousand million zero first
tue wed thu fri sat sun monday tuesday wednesday thursday friday saturday sunday spring summer fall winter holiday holidays open office offices location locations appointment consultation
meeting obligation commitment fee fees hidden instantly instant anytime cancel cancellation renewal renewable renews application applications beneficiary beneficiaries exam care level levels tier
tiers amount amounts lifetime forever rider riders non lowest highest reviews stars star
small large big medium mo yr yrs part parts starting starts next fits fit ages age deserves deserve works grows grow groups individuals add bills young thousands insurers made follows follow place wait comes come lifestyle
meta google facebook instagram tiktok linkedin youtube sms seo ads ad campaign campaigns creative creatives landing page pages form forms lead leads audience audiences headline copy draft
worth reasons reason guide guides webinar webinars planning explained freelancers contractors contractor convert loan loans download downloads paycheque paycheck become becomes waiver promo promotion promotions
spend retargeting remarketing tips checklist education experience serving money back
step steps way ways mistakes mistake myths myth questions question faq faqs blog article articles video videos newsletter subscribe ebook calculator estimate estimates digital mobile app apps website site sites link links
homepage banner banners button buttons image images photo photos logo logos brand brands color colour colors colours font template templates report reports summary overview comparison worksheet handbook toolkit resources resource
library course courses training workshop workshops event events seminar seminars partner partners partnership licence license licences certified certification accredited award awards winning recognized experienced dedicated
friendly knowledgeable caring honest unbiased objective neutral evening evenings morning mornings noon weekend weekends closed january february march july september october november december cheap cheaper cheapest bundle bundles
bundled multi countrywide wide stars star reasons reason top plans quotes hours hour opening open
20s 30s 40s 50s 60s 70s 80s 90s
acceptance accepting act annuities annuity asked before brokerage builds buying callback changes commercial community company condo current cyber date decision equipment expense expenses file final frequently fully getting going growing happens have insured keeps key know landlord landlords language legacy liability lock love market matters member owned paperless paperwork pet plain proud really say select side soon special started something tenant thank thanks time tools understanding unexpected use watch sale sales prepared prepare overpaying overpay teams team holiday holidays protecting homeowners portable professional consultants consultant works expire expires expiry qualify qualifies qualified payment payments rate rates book books booked schedule schedules meeting meetings consultation consultations
$v$, '[[:space:]]+')) w) s where w <> '' and not exists (select 1 from public.ws_marketing_vocab v where v.lang = 'en' and v.word = s.w);
insert into public.ws_marketing_vocab (lang, word, created_by)
select 'fr', w, 'seed' from (select distinct unnest(regexp_split_to_array($v$
le la les l un une des du de d au aux et ou mais donc or ni car que qu quel quelle quels quelles qui quoi dont ce cet cette ces ca celui
dans en sur sous avec sans pour par chez vers entre contre depuis pendant jusque jusqu plus moins tres trop assez aussi encore deja toujours jamais ne n pas non oui si tout tous toute toutes
chaque autre autres meme tel
vous votre vos se s c y
protegez protegeons proteger obtenez obtenir appelez appeler comparez comparer economisez economiser profitez profiter decouvrez decouvrir demandez soumettez contactez choisissez trouvez
apprenez planifiez assurez assurer couvrir couvre couvrent payer paye payez beneficier beneficiez commencez reservez visitez simplifiez preparez securisez rassurez peut peuvent pouvez
pouvons est sont soit etre avez avons avoir faire faites aller veut voulez cherchez
famille familles entreprise entreprises prix mois an ans annee annees semaine semaines jour jours heure heures minute minutes couverture couvertures protection protections plan plans soumission
soumissions devis gratuit gratuite gratuits avantage avantages courtier courtiers agent agents conseiller conseillers conseillere equipe service services soutien aide ligne telephone taux prime
primes somme montant montants paiement paiements cout couts budget valeur option options choix solution solutions programme programmes produit produits forfait forfaits offre offres rabais
economie economies paix esprit securite avenir vie vies maison maisons auto voiture voyage voyages vacances travail travailleurs travailleur autonome autonomes employes employeur employeurs
proprietaire proprietaires etudiants etudiant retraite retraites canada canadien canadiens canadiennes ontario quebec alberta manitoba saskatchewan
assurance assurances assure assures assureur
abordable simple facile rapide flexible personnalise meilleur meilleure meilleurs fiable securitaire complet complete complets exclusif nouveau nouvelle grand grande vrai bon bonne parfait
pret prete disponible garanti terme temporaire permanente collective collectif individuelle individuel appel suffit suffisent ici maintenant aujourd hui demain
un deux trois quatre cinq six sept huit neuf dix vingt trente cent mille million
lundi mardi mercredi jeudi vendredi samedi dimanche lun mar mer jeu ven sam dim printemps automne hiver ouvert ouverts bureau bureaux rendez consultation sans obligation gratuitement
quelques partir prochain endroit compte aucune aucun petite petites petit petits merite budgets grandit grandir forfaitaire examen examens tarif tarifs mieux
beneficiaire beneficiaires niveau niveaux montant duree toujours vie
respecte raisons acheter nouveaux aines entiere habitation sejour telechargez agrees
etoiles etoile etapes etape conseils conseil astuces questions question guide guides blogue article articles video videos infolettre abonnez calculateur estimation estimations
numerique mobile application site web lien liens image images photo photos logo logos marque marques couleur couleurs modele modeles rapport rapports sommaire apercu comparaison
ressources ressource formation atelier ateliers evenement evenements seminaire partenaire partenaires partenariat licence licences certifie accredite prix gagnant experimente
dedie sympathique honnete objectif neutre soir soirs matin matins midi weekend ferme janvier fevrier mars juillet septembre octobre novembre decembre
acceptons accumule achat actuelle aider assureurs autorise avant cabinet certains ceux cher choisir combien comparent comptent courtage coute decision engagement equipes familial immobilier imprevisible inscrivez instantanee lisez limitee marche parce parlez participez partie poser pourquoi premier prenez rachat rappel regimes regroupez remplace requis responsabilite revisez revision savoir seul simplement successorale tardez tranquillite utilisez venir verse webinaire police planification expliquee note notez choix soumission soumissions salaire locataire locataires hypothecaire pret proprietaires professionnelle quebecoises consultants protegees protegee proteges heritage
$v$, '[[:space:]]+')) w) s where w <> '' and not exists (select 1 from public.ws_marketing_vocab v where v.lang = 'fr' and v.word = s.w);
insert into public.ws_fixed_phrases (lang, phrase, phrase_norm, created_by)
select l, p, regexp_replace(replace(public.ws_fold_text(p), '-', ' '), ' +', ' ', 'g'), 'seed'
from (values
 ('en', 'contact us'), ('en', 'call us'), ('en', 'email us'), ('en', 'text us'), ('en', 'reach us'), ('en', 'talk to us'), ('en', 'our team'), ('en', 'our advisors'), ('en', 'our brokers'),
 ('en', 'our experts'), ('en', 'our guide'), ('en', 'our free guide'), ('en', 'our checklist'), ('en', 'one call'), ('en', 'one plan'), ('en', 'one place'), ('en', 'mon fri'), ('en', 'mon to fri'),
 ('fr', 'notre equipe'), ('fr', 'nos conseillers'), ('fr', 'nos courtiers'), ('fr', 'notre guide'), ('fr', 'contactez nous'), ('fr', 'appelez nous'), ('fr', 'joignez nous'), ('fr', 'lun ven'),
 ('en', 'we can help'), ('en', 'we are here to help'), ('en', 'our free checklist'), ('en', 'our video'), ('en', 'our short video'), ('en', 'our free webinar'), ('en', 'our free seminar'), ('en', 'here to help'), ('en', 'about us'), ('en', 'who we are'), ('en', 'meet our team'), ('en', 'our services'), ('en', 'our process'), ('en', 'our story'), ('en', 'our mission'), ('en', 'our partners'),
 ('en', 'our insurers'), ('en', 'our plans'), ('en', 'our products'), ('en', 'our offices'), ('en', 'our newsletter'), ('en', 'our blog'), ('en', 'our website'), ('en', 'our free calculator'), ('en', 'join us'), ('en', 'visit us'),
 ('fr', 'nos services'), ('fr', 'notre mission'), ('fr', 'nos partenaires'), ('fr', 'nos assureurs'), ('fr', 'notre infolettre'), ('fr', 'notre blogue'), ('fr', 'qui sommes nous'), ('fr', 'a propos de nous'),
 ('fr', 'nous sommes la'), ('fr', 'visitez nous'), ('fr', 'notre calculateur gratuit'), ('fr', 'notre webinaire gratuit'), ('fr', 'notre webinaire')) as v(l, p)
where not exists (select 1 from public.ws_fixed_phrases f where f.phrase_norm = regexp_replace(replace(public.ws_fold_text(v.p), '-', ' '), ' +', ' ', 'g'));
do $$ declare bad text; begin
  select string_agg(f.phrase, ', ') into bad from public.ws_fixed_phrases f
   where f.created_by = 'seed' and f.removed_at is null
     and exists (select 1 from unnest(string_to_array(f.phrase_norm, ' ')) w
                 where public.ws_name_word_hit(w) or public.ws_health_word_hit(w)
                    or (public.ws_vocab_denied(w, false) and w <> all (array['we', 'us', 'our', 'ours', 'nous', 'notre', 'nos', 'one', 'ones', 'mon'])));
  if bad is not null then raise exception 'seed fixed phrases contain denied words: %', bad; end if;
end $$;
do $$ declare bad text; begin
  select string_agg(word, ', ') into bad from public.ws_marketing_vocab where created_by = 'seed' and removed_at is null and public.ws_vocab_denied(word, true);
  if bad is not null then raise exception 'seed vocabulary contains denied words: %', bad; end if;
end $$;

-- PLACE CATALOG: municipalities an owner may approve (fixed; no free text). Only unambiguous names (no common nouns, no first names: Victoria, Regina, Sydney, Brandon, Barrie, Vernon and Courtenay are deliberately NOT here). Never edited after this migration.
insert into public.ws_place_catalog (name_norm, display_name, province)
select public.ws_fold_text(split_part(e, '|', 1)), split_part(e, '|', 1), split_part(e, '|', 2)
from unnest(array[
 'Toronto|ON', 'Ottawa|ON', 'Mississauga|ON', 'Brampton|ON', 'Hamilton|ON', 'London|ON', 'Markham|ON', 'Vaughan|ON', 'Kitchener|ON', 'Windsor|ON', 'Richmond Hill|ON', 'Oakville|ON', 'Burlington|ON',
 'Oshawa|ON', 'St Catharines|ON', 'Guelph|ON', 'Cambridge|ON', 'Whitby|ON', 'Kingston|ON', 'Ajax|ON', 'Waterloo|ON', 'Pickering|ON', 'Niagara Falls|ON', 'Peterborough|ON',
 'Sudbury|ON', 'Thunder Bay|ON', 'Cornwall|ON', 'Belleville|ON', 'Sarnia|ON', 'North Bay|ON', 'Brantford|ON', 'Kanata|ON', 'Barrhaven|ON', 'Nepean|ON', 'Orleans|ON', 'Stittsville|ON',
 'Montreal|QC', 'Quebec City|QC', 'Laval|QC', 'Gatineau|QC', 'Longueuil|QC', 'Sherbrooke|QC', 'Saguenay|QC', 'Levis|QC', 'Trois Rivieres|QC', 'Terrebonne|QC', 'Drummondville|QC', 'Granby|QC', 'Brossard|QC',
 'Vancouver|BC', 'Burnaby|BC', 'Kelowna|BC', 'Abbotsford|BC', 'Kamloops|BC', 'Nanaimo|BC', 'Chilliwack|BC', 'Prince George|BC', 'Penticton|BC',
 'Calgary|AB', 'Edmonton|AB', 'Red Deer|AB', 'Lethbridge|AB', 'Medicine Hat|AB', 'Airdrie|AB', 'Grande Prairie|AB', 'St Albert|AB', 'Fort McMurray|AB', 'Cochrane|AB', 'Lloydminster|AB',
 'Winnipeg|MB', 'Saskatoon|SK', 'Moose Jaw|SK', 'Prince Albert|SK', 'Swift Current|SK',
 'Halifax|NS', 'Truro|NS', 'Moncton|NB', 'Fredericton|NB', 'Saint John|NB', 'Charlottetown|PE', 'St Johns|NL', 'Corner Brook|NL', 'Gander|NL', 'Mount Pearl|NL',
 'Whitehorse|YT', 'Yellowknife|NT', 'Iqaluit|NU']) e
on conflict (name_norm) do nothing;

-- 9b. structural columns. A value in an enum-like column skips only the vocabulary test, and only when it really looks like one: a short token (letters, digits, _ : . -), no health word, no
--     name; onboarding `title` only when it IS a template title; onboarding `blocked_until` only when it is a date; `provided_by` only when it is an actor tag. Anything else in these
--     columns is free text and gets the full screen. Never echoes the value.
create or replace function public.ws_structural_value(p_table text, p_col text, p_value text) returns boolean
language plpgsql stable security definer set search_path to 'pg_catalog' as $$
declare v text := btrim(coalesce(p_value, '')); w text;
begin
  if v = '' then return true; end if;
  if p_col = 'title' then return p_table = 'ffm_onboarding_items' and exists (select 1 from public.ffm_onboarding_templates t where t.title = p_value); end if;
  if p_col = 'blocked_until' then
    if p_table <> 'ffm_onboarding_items' then return false; end if;
    if lower(v) ~ '^(jan|feb|mar|apr|may|jun|jul|aug|sep|sept|oct|nov|dec)[a-z]* [0-9]{1,2}(, [0-9]{4})?$' then return true; end if;       -- a plain date (ISO dates are refused by the old account-number rule, as before)
  elsif p_col <> all (array['status', 'stage', 'kind', 'provider', 'template_key', 'approved_by', 'provided_by', 'destination_kind', 'channel', 'basis', 'wording_version', 'recorded_by', 'set_by']) then
    return false;
  end if;
  if p_col = any (array['approved_by', 'recorded_by', 'set_by', 'provided_by']) and v ~* '^[a-z0-9._%+-]{1,60}@[a-z0-9.-]{3,60}\.[a-z]{2,10}$' then v := split_part(v, '@', 1);          -- an actor e-mail: its local part gets the same word checks
  elsif v !~ '^[A-Za-z0-9_:.-]{1,60}$' then return false; end if;
  -- round 4 (N5): a token is split at separators AND between letters and digits ("age45" -> age, 45); a pay / age / number word makes it free text ("makes_85k", "fifty_thousand")
  foreach w in array regexp_split_to_array(regexp_replace(lower(v), '([a-z])([0-9])|([0-9])([a-z])', '\1\3_\2\4', 'g'), '[_:.-]+') loop
    if length(w) >= 2 and w ~ '[a-z]' and (public.ws_name_word_hit(w) or public.ws_health_word_hit(w)) then return false; end if;
    if w ~ ('^(' || public.ws_number_words() || '|age|aged|ages|dob|born|old|makes|make|earns|earn|pay|paid|pays|salary|income|owes|owe|debt|mortgage|loan|rent|k|yrs|yr|yo)$') then return false; end if;
  end loop;
  return true;
end $$;

-- 9c. onboarding VALUES in an insurance workspace (ffm_onboarding_items.value_text). Not marketing copy: it holds business contacts, links, wording and agreements, so the vocabulary test
--     does not apply; instead: every earlier category and the health screen (no waiver), every word of the value checked against the health / condition / drug / body lists (URL and
--     e-mail parts included), no narrative or first-person personal context (consent wording may say "I agree"), no person name (except for the compliance contact), and no identifier
--     (phone, postal code, street address, date, long number), except: e-mail addresses and links are accepted for the business-contact / CRM / booking / brand / sign-off keys, a phone
--     for the compliance contact, and dates for the deadline and licence keys. Round 4: third-person and euphemistic wording about one person, an insurer's decision, body measures and
--     habits are refused; so is every amount of money, pay / debt wording and spelled-out number (ws_financial_hit), except that the monthly budget may be an amount and nothing else.
--     Still a LIST screen: wording that uses none of the listed words passes (stated limit). Never echoes the value.
create or replace function public.ws_onboarding_value_check(p_key text, p_value text) returns jsonb
language plpgsql stable security definer set search_path to 'pg_catalog' as $$
declare k text := coalesce(p_key, ''); f text; v text; ident text; w text; res jsonb;
        contact_keys text[] := array['crm_destination', 'booking_link', 'brand_assets', 'compliance_contact', 'ad_review_signoff', 'lead_fields_agreed', 'ad_account_access', 'consent_wording'];
        name_keys text[] := array['compliance_contact', 'workspace_name'];      -- a person or business NAME is the point of these values (workspace_name: client_workspaces.name, see ws_person_column_check)
        plain_keys text[] := array['launch_deadline', 'monthly_budget', 'licensing_status', 'licence_details'];
begin
  if p_value is null or btrim(p_value) = '' then return jsonb_build_object('allowed', true, 'reasons', '[]'::jsonb); end if;
  res := public.ws_classify_core(p_value, null, false, false, false);             -- earlier categories + health, strict (no workspace, no waiver)
  if not (res ->> 'allowed')::boolean then return res; end if;
  f := public.ws_fold_text(p_value);
  for w in select m[1] from regexp_matches(f, '[a-z0-9]{3,}', 'g') as m loop        -- (letters and digits: a lab value such as "a1c" is one token)
    if w ~ '[a-z]' and public.ws_health_word_hit(w) then return jsonb_build_object('allowed', false, 'reasons', jsonb_build_array('health', 'health:residual')); end if;
  end loop;
  -- round 4 (S7): wording about one person that carries no word of the health lists: third-person pronouns, euphemisms, body measures, habits, an insurer's decision
  if f ~ '(^|[^a-z])(she|he|her|hers|his|him|elle|lui)([^a-z]|$)'
     or f ~ ('(^|[^a-z])(expecting|expectant|shrink|therap[a-z]*|sober|sobriety|rehab|detox|opere|operee|operes|operation|hanche|doctor|docteur|weight|weighs|height|lbs|kg|pounds|bmi|dui|dwi|smok[a-z]*|vape|vapes|vaping|'
             || 'drinks|drinking|drunk|(declined|denied|refused|rejected|postponed|rated|turned down|refuse|refusee|rejete|rejetee) (by|par)|(beneficiary|beneficiaries|beneficiaire|beneficiaires) *(is|are|est|sont|:|=|-))([^a-z]|$)') then
    return jsonb_build_object('allowed', false, 'reasons', jsonb_build_array('health', 'health:personal_context'));
  end if;
  -- round 4 (S7 / B1): money, pay, debt, spelled-out amounts and ages. The monthly budget may be an amount, and nothing else.
  if k = 'monthly_budget' and f ~ '[0-9$]' then
    if regexp_replace(regexp_replace(f, '\$ ?[0-9][0-9,.]*k?|[0-9][0-9,. ]*k? ?(\$|dollars?|cad)', ' ', 'g'), '(^|[^a-z])(per|a|month|monthly|mo|cad|budget|ad|ads|spend|max|maximum|up|to|about|approx|total|par|mois|mensuel|environ)(?![a-z])', ' ', 'g') ~ '[a-z0-9]' then
      return jsonb_build_object('allowed', false, 'reasons', jsonb_build_array('financial_detail'));
    end if;
  elsif public.ws_financial_hit(f, true) then
    return jsonb_build_object('allowed', false, 'reasons', jsonb_build_array('financial_detail'));
  end if;
  v := f; ident := f;
  if k = any (contact_keys) then
    -- an e-mail address or link is allowed for these keys (not for an identifier check), but its WORDS (local part, host, path) still get the name and health checks above and below
    ident := regexp_replace(ident, '[a-z0-9._%+-]+@[a-z0-9.-]+\.[a-z]{2,}', ' ', 'g');
    ident := regexp_replace(ident, '(https?://|www\.)[^ ]+', ' ', 'g');
    ident := regexp_replace(ident, '[a-z0-9-]+(\.[a-z0-9-]+)*\.[a-z]{2,}(/[^ ,;]*)?', ' ', 'g');
  end if;
  if k = 'compliance_contact' then ident := regexp_replace(ident, '[0-9]{3}[ .)/-]*[0-9]{3}[ .-]?[0-9]{4}', ' ', 'g'); end if;
  if (k <> 'consent_wording' and public.ws_personal_context_hit(v))                  -- consent wording may say "I agree"; nothing else may be first-person or about a person
     or v ~ '(^|[^a-z])(can ?not|cannot|can['' ]?t|could ?not|unable to|not able to|won[''’ ]?t|will not)( +[a-z]+)? +(work|walk|pay|afford|move|see|hear|speak|breathe|stand|drive|eat|sleep|care|cope|bills)([^a-z]|$)'
     or v ~ '(^|[^a-z])needs? +(care|surgery|treatment|dialysis|medication|assistance|a doctor)([^a-z]|$)' then
    return jsonb_build_object('allowed', false, 'reasons', jsonb_build_array('health', 'health:personal_context'));
  end if;
  if not (k = any (contact_keys)) and f ~ '(@|https?:|www\.|[a-z0-9-]+\.(com|ca|org|net|io|co|app|info|biz|me)([^a-z]|$))' then      -- an e-mail address or link only where the key takes one
    return jsonb_build_object('allowed', false, 'reasons', jsonb_build_array('identifier'));
  end if;
  if not (k = any (name_keys)) then
    for w in select m[1] from regexp_matches(v, '[a-z]{3,}', 'g') as m loop
      if public.ws_name_word_hit(w) then return jsonb_build_object('allowed', false, 'reasons', jsonb_build_array('unknown_word')); end if;
    end loop;
  end if;
  if not (k = any (plain_keys)) and public.ws_identifier_hit(ident) then return jsonb_build_object('allowed', false, 'reasons', jsonb_build_array('identifier')); end if;
  return jsonb_build_object('allowed', true, 'reasons', '[]'::jsonb);
end $$;

-- 9d. PERSON TABLES in an insurance workspace (review round 4, S2): ws_leads, client_workspaces, ffm_routing_rules, ffm_consent_log, ffm_consent_settings. Until round 4 these had the old
--     deny-list only, so "takes <drug> daily", an age, a date of birth in words, a beneficiary or an insurer's decision was stored in a lead note. Now, column by column:
--       lead name               a NAME: letters only, at most 5 words, no health / relation / narrative / number / sentence word (ws_person_name_check). Not a vocabulary test: names are not vocabulary.
--       lead e-mail, phone      an address / a number of that shape: the old screen, plus the health lists on the words of the address. Any other content: the insurance screen.
--       workspace name          a business name: list screen (ws_onboarding_value_check: health lists, personal wording, amounts, identifiers), no vocabulary test.
--       destination / evidence  a reference without spaces (e-mail, link, id): list screen. With spaces: the insurance screen.
--       source                  a tag of one or two plain words that are on no deny list ("web form", "referral"); anything else: the insurance screen.
--       enum / actor columns    a short token (ws_structural_value): every category, identifiers and amounts; no vocabulary test.
--       everything else (note, source, rule name ...): the INSURANCE screen (default-deny vocabulary, no feature-phrase waiver).
--     Returns {"allowed", "reasons", "free"}; free = the value is free text and belongs in the joined insurance scan of the row. Never echoes the value.
create or replace function public.ws_person_name_check(p_value text) returns jsonb
language plpgsql stable security definer set search_path to 'pg_catalog' as $$
declare f text; w text; n integer := 0; res jsonb;
begin
  if p_value is null or btrim(p_value) = '' then return jsonb_build_object('allowed', true, 'reasons', '[]'::jsonb); end if;
  res := public.ws_classify_core(p_value, null, false, false, false);
  if not (res ->> 'allowed')::boolean then return res; end if;
  f := public.ws_fold_text(p_value);
  if f !~ '^[a-z][a-z'' .,-]{0,79}$' then return jsonb_build_object('allowed', false, 'reasons', jsonb_build_array('unknown_word')); end if;
  for w in select m[1] from regexp_matches(f, '[a-z]+', 'g') as m loop
    n := n + 1;
    if length(w) >= 2 and public.ws_health_word_hit(w) then return jsonb_build_object('allowed', false, 'reasons', jsonb_build_array('health', 'health:residual')); end if;
    if (public.ws_vocab_denied(w, false) and not public.ws_name_word_hit(w))
       or w ~ ('^(' || public.ws_number_words() || ')$')
       or w = any (array['is', 'are', 'the', 'a', 'an', 'for', 'of', 'on', 'in', 'by', 'with', 'to', 'from', 'and', 'or', 'not', 'no', 'at', 'as', 'this', 'that', 'it', 'you', 'your', 'have', 'who', 'whose', 'but', 'if',
                         'beneficiary', 'beneficiaries', 'beneficiaire', 'insured', 'insurer', 'policy', 'insurance', 'assurance', 'coverage', 'quote', 'plan', 'premium', 'smoker', 'age', 'years', 'year', 'since', 'last',
                         'daily', 'weekly', 'monthly', 'yearly', 'takes', 'makes', 'needs', 'wants', 'called', 'call', 'interested', 'est', 'sont', 'les', 'un', 'une', 'pour', 'avec', 'sans', 'sur', 'dans', 'par', 'et', 'ou',
                         'depuis', 'ans', 'annuel', 'vous', 'votre', 'en', 'arret', 'travail', 'opere', 'operee', 'hanche', 'tension', 'elevee', 'recently', 'currently', 'formerly', 'widowed', 'separated', 'single',
                         'retired', 'unemployed', 'family', 'famille', 'probate', 'debt', 'debts', 'custody', 'visa', 'prison', 'jail', 'divorce', 'funeral', 'lawsuit', 'gambling', 'arrears', 'bankrupt', 'immigrant', 'refugee',
                         'felony', 'estate', 'foreclosure', 'bereaved', 'arrest', 'arrested', 'newborn', 'fiance', 'fiancee', 'boyfriend', 'girlfriend', 'hubby', 'wifey', 'daddy', 'mommy', 'mummy', 'mama', 'papa', 'granny',
                         'grannie', 'nana', 'nonna', 'oncle', 'tante', 'mamie', 'papi', 'cousine', 'neveu', 'bro', 'sis']) then
      return jsonb_build_object('allowed', false, 'reasons', jsonb_build_array('unknown_word'));
    end if;
  end loop;
  if n > 5 then return jsonb_build_object('allowed', false, 'reasons', jsonb_build_array('unknown_word')); end if;
  return jsonb_build_object('allowed', true, 'reasons', '[]'::jsonb);
end $$;

create or replace function public.ws_person_column_check(p_table text, p_col text, p_value text, p_ws uuid) returns jsonb
language plpgsql stable security definer set search_path to 'pg_catalog' as $$
declare v text := btrim(coalesce(p_value, '')); res jsonb; w text; nofree jsonb := jsonb_build_object('free', false);
begin
  if v = '' then return jsonb_build_object('allowed', true, 'reasons', '[]'::jsonb, 'free', false); end if;
  res := public.ws_classify_core(p_value, null, false, false, false);            -- the old screen first, always: nothing it refused is ever accepted here
  if not (res ->> 'allowed')::boolean then return res || nofree; end if;
  if p_table = 'ws_leads' and p_col = 'name' then return public.ws_person_name_check(p_value) || nofree; end if;
  if p_table = 'ws_leads' and p_col = 'email' and v ~* '^[a-z0-9._%+-]{1,64}@[a-z0-9.-]{3,80}\.[a-z]{2,10}$' then
    for w in select m[1] from regexp_matches(public.ws_fold_text(v), '[a-z]{3,}', 'g') as m loop
      if public.ws_health_word_hit(w) then return jsonb_build_object('allowed', false, 'reasons', jsonb_build_array('health', 'health:residual'), 'free', false); end if;
    end loop;
    return res || nofree;
  end if;
  if p_table = 'ws_leads' and p_col = 'phone' and v ~ '^[+]?[0-9() .x-]{7,25}$' then return res || nofree; end if;
  if p_table = 'client_workspaces' then
    if p_col = 'name' then return public.ws_onboarding_value_check('workspace_name', p_value) || nofree; end if;
    if p_col = any (array['slug', 'vertical']) and v ~ '^[A-Za-z0-9 _-]{1,60}$' then
      for w in select m[1] from regexp_matches(public.ws_fold_text(v), '[a-z]{3,}', 'g') as m loop
        if public.ws_health_word_hit(w) then return jsonb_build_object('allowed', false, 'reasons', jsonb_build_array('health', 'health:residual'), 'free', false); end if;
      end loop;
      return res || nofree;
    end if;
  end if;
  if ((p_table = 'ffm_routing_rules' and p_col = 'destination_ref') or (p_table = 'ffm_consent_log' and p_col = 'evidence_ref')) and v !~ '[[:space:]]' then
    -- a reference id ("form-submission-1001", "crm-main"): letters and separators, then at most ONE group of up to 6 digits; its words get the name / health / pay / number checks
    -- an e-mail address or a link: list screen (its words get the name and health checks). Anything else without spaces must be such a reference id, or it is refused.
    if v ~ '[@/]' then return public.ws_onboarding_value_check('crm_destination', p_value) || nofree; end if;
    if v ~ '^[A-Za-z][A-Za-z_:.-]{0,50}[0-9]{0,6}[A-Za-z]{0,3}$' and public.ws_structural_value(p_table, 'kind', v) then return res || nofree; end if;
    return jsonb_build_object('allowed', false, 'reasons', jsonb_build_array('unknown_word'), 'free', false);
  end if;
  -- a lead / consent SOURCE tag ("web form", "referral", "meta_ad"): one or two plain words, each of them clear of every deny list (people, narrative, health, names, numbers, pay / debt).
  -- Not a vocabulary test (a tag is not marketing copy); anything longer is free text and gets the insurance screen below.
  if p_col = 'source' and public.ws_fold_text(v) ~ '^[a-z]{3,20}([ _-][a-z]{2,20})?$' then
    for w in select m[1] from regexp_matches(public.ws_fold_text(v), '[a-z]+', 'g') as m loop
      if public.ws_vocab_denied(w, true) or w ~ ('^(' || public.ws_number_words() || '|age|ages|dob|makes|make|pay|paid|pays|salary|owes|debt|mortgage|loan|rent|smoker|non|no|not|yes|ex|former|single|retired|pregnant|expecting|late|behind)$') then
        return jsonb_build_object('allowed', false, 'reasons', jsonb_build_array('unknown_word'), 'free', false);
      end if;
    end loop;
    return res || nofree;
  end if;
  if public.ws_structural_value(p_table, p_col, v) then
    if v ~* '^[a-z0-9._%+-]{1,60}@[a-z0-9.-]{3,60}\.[a-z]{2,10}$' then return res || nofree; end if;       -- an actor e-mail (its words were checked by ws_structural_value)
    return public.ws_classify_core(p_value, p_ws, true, true, true) || nofree;
  end if;
  -- free text: the insurance screen. A source tag such as "meta_ad" is read as its words.
  return public.ws_classify_core(case when p_col = 'source' then translate(p_value, '_', ' ') else p_value end, p_ws, true, false, true) || jsonb_build_object('free', true);
end $$;

-- 13. guards, replaced. Same exclusions and messages as before; the classifier decides. Approved-term waivers only on non-person tables; in an insurance workspace the person
--     tables get the insurance screen too (round 4, S2: ws_person_column_check). A workspace of a known non-insurance vertical (mortgage) behaves exactly as before on every table.
--     "Structural" columns (enums, template keys, actor tags) are exempt from the vocabulary test only: every category and the health screen still apply to them.
create or replace function public.ws_guard() returns trigger
language plpgsql set search_path to 'pg_catalog' as $$
declare k text; v text; t text; e record; res jsonb; allv text := ''; freev text := ''; j jsonb := to_jsonb(new); v_ws uuid; c_ws uuid; ctx boolean := false; person boolean; n_vals integer := 0; n_free integer := 0;
begin
  person := tg_table_name <> all (array['ws_campaigns', 'ws_ledger']);
  -- insurance screen: decided by the workspace (for a workspace row: by its own vertical). Fails closed, see ws_insurance_context.
  if tg_table_name = 'client_workspaces' then
    v_ws := nullif(j ->> 'id', '')::uuid;
    ctx := public.ws_vertical_insurance(j ->> 'vertical');
  else
    v_ws := nullif(j ->> 'workspace_id', '')::uuid;
    ctx := v_ws is not null and public.ws_insurance_context(null, v_ws);
  end if;
  c_ws := case when person then null else v_ws end;        -- person tables: the old strict screen (no waiver) stays the first test for every value
  -- a value split across columns (name / phone / note) is caught by also scanning every scanned column joined together (only when there is more than one value to join)
  for e in select key, value from jsonb_each(j - array['id', 'workspace_id', 'campaign_id', 'created_at', 'status', 'stage', 'amount_cents', 'monthly_budget_cents']) loop
    v := e.value #>> '{}';
    if v is not null and btrim(v) <> '' and jsonb_typeof(e.value) <> 'boolean' then allv := allv || ' ' || v; n_vals := n_vals + 1; end if;
  end loop;
  if n_vals > 1 then
    res := public.ws_classify_core(allv, c_ws, ctx and not person, true, false);
    if not (res ->> 'allowed')::boolean then
      raise exception 'Sensitive data refused in % (%). Applications, banking, credit, ID and sensitive financial data must never be stored here.', tg_table_name, array_to_string(array(select jsonb_array_elements_text(res -> 'reasons')), ', ') using errcode = 'P0001';
    end if;
  end if;
  for e in select key, value from jsonb_each(j - array['id', 'workspace_id', 'campaign_id', 'created_at', 'status', 'stage', 'amount_cents', 'monthly_budget_cents']) loop
    v := e.value #>> '{}'; t := jsonb_typeof(e.value);
    continue when v is null or btrim(v) = '' or t = 'boolean';
    if person and ctx and t = 'string' then
      -- S2: a person table of an insurance workspace gets the insurance screen, column by column (ws_person_column_check)
      res := public.ws_person_column_check(tg_table_name, e.key, v, v_ws);
      if (res ->> 'free')::boolean then freev := freev || ' ' || v; n_free := n_free + 1; end if;
    else
      -- numbers and other non-text values: every category still applies, the vocabulary test does not (a number column is not wording)
      res := public.ws_classify_core(v, c_ws, ctx and not person, t <> 'string', false);
    end if;
    if not (res ->> 'allowed')::boolean then
      raise exception 'Sensitive data refused in %.% (%). Applications, banking, credit, ID and sensitive financial data must never be stored here.', tg_table_name, e.key, array_to_string(array(select jsonb_array_elements_text(res -> 'reasons')), ', ')
        using errcode = 'P0001';
    end if;
  end loop;
  if n_free > 1 then
    res := public.ws_classify_core(freev, v_ws, true, true, true);      -- the free-text columns of a person row, joined (insurance screen)
    if not (res ->> 'allowed')::boolean then
      raise exception 'Sensitive data refused in % (%). Applications, banking, credit, ID and sensitive financial data must never be stored here.', tg_table_name, array_to_string(array(select jsonb_array_elements_text(res -> 'reasons')), ', ') using errcode = 'P0001';
    end if;
  end if;
  return new;
end $$;

create or replace function public.ffm_guard() returns trigger
language plpgsql set search_path to 'pg_catalog' as $$
declare k text; v text; res jsonb; allv text := ''; freev text := ''; j jsonb := to_jsonb(new); v_ws uuid; c_ws uuid; ctx boolean := false; person boolean; structural boolean; n_vals integer := 0; n_free integer := 0;
begin
  person := tg_table_name <> all (array['ffm_ad_sets', 'ffm_creatives', 'ffm_approvals', 'ffm_onboarding_items']);
  v_ws := nullif(j ->> 'workspace_id', '')::uuid;
  ctx := v_ws is not null and public.ws_insurance_context(null, v_ws);
  c_ws := case when person then null else v_ws end;        -- person tables: the old strict screen (no waiver) stays the first test for every value
  for k, v in select e.key, e.value #>> '{}' from jsonb_each(j) e
              where jsonb_typeof(e.value) = 'string'
                and not exists (select 1 from pg_attribute a where a.attrelid = tg_relid and a.attname = e.key and a.attnum > 0 and not a.attisdropped
                                  and a.atttypid in ('uuid'::regtype, 'timestamptz'::regtype)) loop
    continue when btrim(v) = '';
    if ctx and tg_table_name = 'ffm_onboarding_items' and k = 'value_text' then
      res := public.ws_onboarding_value_check(j ->> 'template_key', v);       -- onboarding values are business contacts and wording, not marketing copy (see ws_onboarding_value_check)
      if not (res ->> 'allowed')::boolean then
        raise exception 'Sensitive data refused in %.% (%). Applications, banking, credit, ID and sensitive financial data must never be stored here.', tg_table_name, k, array_to_string(array(select jsonb_array_elements_text(res -> 'reasons')), ', ') using errcode = 'P0001';
      end if;
      continue;                                                                -- already screened as a whole: not joined with the other columns (an e-mail / link here is legitimate)
    elsif person and ctx then
      -- S2: a person table (routing, consent) of an insurance workspace gets the insurance screen, column by column (ws_person_column_check)
      res := public.ws_person_column_check(tg_table_name, k, v, v_ws);
      if (res ->> 'free')::boolean then freev := freev || ' ' || v; n_free := n_free + 1; end if;
    else
      -- a structural column (enum, template key, actor tag, template title, date) skips only the vocabulary test, and only when the value really looks like one
      structural := public.ws_structural_value(tg_table_name, k, v);
      res := public.ws_classify_core(v, c_ws, ctx and not person, structural, false);
    end if;
    if not (res ->> 'allowed')::boolean then
      raise exception 'Sensitive data refused in %.% (%). Applications, banking, credit, ID and sensitive financial data must never be stored here.', tg_table_name, k, array_to_string(array(select jsonb_array_elements_text(res -> 'reasons')), ', ') using errcode = 'P0001';
    end if;
    allv := allv || ' ' || v; n_vals := n_vals + 1;
  end loop;
  if n_vals > 1 then
    res := public.ws_classify_core(allv, c_ws, ctx and not person, true, false);   -- a value split across columns
    if not (res ->> 'allowed')::boolean then
      raise exception 'Sensitive data refused in % (%). Applications, banking, credit, ID and sensitive financial data must never be stored here.', tg_table_name, array_to_string(array(select jsonb_array_elements_text(res -> 'reasons')), ', ') using errcode = 'P0001';
    end if;
  end if;
  if n_free > 1 then
    res := public.ws_classify_core(freev, v_ws, true, true, true);      -- the free-text columns of a person row, joined (insurance screen)
    if not (res ->> 'allowed')::boolean then
      raise exception 'Sensitive data refused in % (%). Applications, banking, credit, ID and sensitive financial data must never be stored here.', tg_table_name, array_to_string(array(select jsonb_array_elements_text(res -> 'reasons')), ', ') using errcode = 'P0001';
    end if;
  end if;
  return new;
end $$;

-- 14. grants: service_role only. The term and vocabulary management functions additionally require the owner (ffm_require_owner refuses the bot).
revoke all on function public.ws_terms_immutable() from public, anon, authenticated;
revoke all on function public.ws_place_catalog_immutable() from public, anon, authenticated;
revoke all on function public.ws_fold_text(text) from public, anon, authenticated;
revoke all on function public.ws_leet_text(text, integer) from public, anon, authenticated;
revoke all on function public.ws_health_extra_hit(text) from public, anon, authenticated;
revoke all on function public.ws_condition_hit(text) from public, anon, authenticated;
revoke all on function public.ws_personal_context_hit(text) from public, anon, authenticated;
revoke all on function public.ws_identifier_hit(text) from public, anon, authenticated;
revoke all on function public.ws_vocab_denied(text, boolean) from public, anon, authenticated;
revoke all on function public.ws_residual_check(text, text) from public, anon, authenticated;
revoke all on function public.ws_capitalised_name(text, boolean) from public, anon, authenticated;
revoke all on function public.ws_text_insurance_word(text, text, text) from public, anon, authenticated;
revoke all on function public.ws_insurance_context(text, uuid) from public, anon, authenticated;
revoke all on function public.ws_classify_core(text, uuid, boolean, boolean, boolean) from public, anon, authenticated;
revoke all on function public.ws_classify_text(text, uuid) from public, anon, authenticated;
revoke all on function public.ws_add_approved_term(uuid, text, text, text, boolean) from public, anon, authenticated;
revoke all on function public.ws_remove_approved_term(uuid) from public, anon, authenticated;
revoke all on function public.ws_add_vocab_word(text, text) from public, anon, authenticated;
revoke all on function public.ws_remove_vocab_word(uuid) from public, anon, authenticated;
revoke all on function public.ws_guard() from public, anon, authenticated;
revoke all on function public.ffm_guard() from public, anon, authenticated;
revoke all on function public.ws_stem_match(text, text[]) from public, anon, authenticated;
revoke all on function public.ws_name_word_hit(text) from public, anon, authenticated;
revoke all on function public.ws_health_word_hit(text) from public, anon, authenticated;
revoke all on function public.ws_add_fixed_phrase(text, text) from public, anon, authenticated;
revoke all on function public.ws_remove_fixed_phrase(uuid) from public, anon, authenticated;
revoke all on function public.ws_structural_value(text, text, text) from public, anon, authenticated;
revoke all on function public.ws_onboarding_value_check(text, text) from public, anon, authenticated;
revoke all on function public.ws_number_words() from public, anon, authenticated;
revoke all on function public.ws_financial_hit(text, boolean) from public, anon, authenticated;
revoke all on function public.ws_feature_context_ok(text, text, boolean) from public, anon, authenticated;
revoke all on function public.ws_vertical_insurance(text) from public, anon, authenticated;
revoke all on function public.ws_person_name_check(text) from public, anon, authenticated;
revoke all on function public.ws_person_column_check(text, text, text, uuid) from public, anon, authenticated;
grant execute on function public.ws_terms_immutable() to service_role;
grant execute on function public.ws_place_catalog_immutable() to service_role;
grant execute on function public.ws_fold_text(text) to service_role;
grant execute on function public.ws_leet_text(text, integer) to service_role;
grant execute on function public.ws_health_extra_hit(text) to service_role;
grant execute on function public.ws_condition_hit(text) to service_role;
grant execute on function public.ws_personal_context_hit(text) to service_role;
grant execute on function public.ws_identifier_hit(text) to service_role;
grant execute on function public.ws_vocab_denied(text, boolean) to service_role;
grant execute on function public.ws_residual_check(text, text) to service_role;
grant execute on function public.ws_capitalised_name(text, boolean) to service_role;
grant execute on function public.ws_text_insurance_word(text, text, text) to service_role;
grant execute on function public.ws_insurance_context(text, uuid) to service_role;
grant execute on function public.ws_classify_core(text, uuid, boolean, boolean, boolean) to service_role;
grant execute on function public.ws_classify_text(text, uuid) to service_role;
grant execute on function public.ws_add_approved_term(uuid, text, text, text, boolean) to service_role;
grant execute on function public.ws_remove_approved_term(uuid) to service_role;
grant execute on function public.ws_add_vocab_word(text, text) to service_role;
grant execute on function public.ws_remove_vocab_word(uuid) to service_role;
grant execute on function public.ws_guard() to service_role;
grant execute on function public.ffm_guard() to service_role;
grant execute on function public.ws_stem_match(text, text[]) to service_role;
grant execute on function public.ws_name_word_hit(text) to service_role;
grant execute on function public.ws_health_word_hit(text) to service_role;
grant execute on function public.ws_add_fixed_phrase(text, text) to service_role;
grant execute on function public.ws_remove_fixed_phrase(uuid) to service_role;
grant execute on function public.ws_structural_value(text, text, text) to service_role;
grant execute on function public.ws_onboarding_value_check(text, text) to service_role;
grant execute on function public.ws_number_words() to service_role;
grant execute on function public.ws_financial_hit(text, boolean) to service_role;
grant execute on function public.ws_feature_context_ok(text, text, boolean) to service_role;
grant execute on function public.ws_vertical_insurance(text) to service_role;
grant execute on function public.ws_person_name_check(text) to service_role;
grant execute on function public.ws_person_column_check(text, text, text, uuid) to service_role;
