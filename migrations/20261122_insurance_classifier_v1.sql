-- Insurance content classification v1 (FENDEZY priority 3, Nov 2026). UNRELEASED: edited in place after independent review (PR #17). Additive: 4 tables, new functions, 2 replaced functions (ws_guard, ffm_guard). No rows are changed.
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
--       3. INSURANCE CONTEXT = the text (or, in the guards, the row) contains an insurance word (insurance, assurance, policy, underwriting, beneficiary, annuity ...) or an approved
--          product term. In that context the residual may contain ONLY vocabulary words, numbers and simple punctuation. Any other token => 'unknown_word'. Non-Latin scripts,
--          mixed scripts, '&', '=' and percent-encoding => blocked. Phone, email, postal code, street address and 4+ digit numbers => 'identifier' (whatever the health words).
--       4. non-insurance text behaves exactly as before (strict screen; a place term only waives its own health-looking name).
--   * ws_guard / ffm_guard (replaced) call the classifier. The waiver applies ONLY on non-person tables (ws_campaigns, ws_ledger, ffm_ad_sets, ffm_creatives, ffm_approvals,
--     ffm_onboarding_items); insurance context is decided per ROW there. Person tables (ws_leads, client_workspaces, ffm_routing_rules, ffm_consent_*) keep the strict behaviour.
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
  word text not null check (word ~ '^[a-z]{1,30}$'),
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

-- rows are never deleted; the only allowed update is the one-way soft removal done by the owner functions (terms and vocabulary share this trigger)
create or replace function public.ws_terms_immutable() returns trigger
language plpgsql set search_path to 'public' as $$
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

create or replace function public.ws_place_catalog_immutable() returns trigger
language plpgsql set search_path to 'public' as $$
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
language plpgsql immutable set search_path to 'public' as $$
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
language sql immutable set search_path to 'public' as $$
  select coalesce(string_agg(case when m[1] ~ '[a-z]'
                                  then case when p_variant = 2 then translate(m[1], '013457$@!|', 'oleastsail') else translate(m[1], '013457$@!|', 'oieastsaii') end
                                  else m[1] end, '' order by ord), '')
  from regexp_matches(coalesce(p_fold, ''), '[a-z0-9$@!|]+|[^a-z0-9$@!|]+', 'g') with ordinality as t(m, ord);
$$;

-- 3. extra health wording the old detector did not know (French, and a few English gaps). Input is an already folded (ASCII, lower case) view.
create or replace function public.ws_health_extra_hit(p_fold text) returns boolean
language plpgsql immutable set search_path to 'public' as $$
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
language plpgsql immutable set search_path to 'public' as $$
declare k text := coalesce(p_fold, '');
begin
  return k ~ ('(^|[^a-z])(lupus|odsp|wsib|aish|herpes|hepatit[a-z]*|std|stds|sti|stis|chlamydia|syphilis|gonorrh[a-z]*|sciatica|burnout|palsy|cerebral|metasta[a-z]*|carcinoma|sarcoma|leprosy|tubercul[a-z]*|malaria|measles|polio|scolios[a-z]*|an[a]?emi[a-z]*|hernia|eczema|psoriasis|acne|rash|fever|lipitor|ozempic|xanax|metformin|viagra|prozac|zoloft|codeine|morphine|oxycodone|ibuprofen|tylenol|aspirin|'
              || 'leg|legs|arm|arms|knee|knees|hip|hips|shoulder|shoulders|chest|head|neck|eye|eyes|ear|ears|liver|brain|breast|breasts|bone|bones|skin|teeth|tooth|stomach|colon|prostate|pain|pains|ache|aches|sore|dizzy|nausea|vomit[a-z]*|bleed[a-z]*|blind[a-z]*|paraly[a-z]*|dying|a1c|bp|tspt|bpco|kanser|krebs|ms|als|copd|chf|dvt|cirrhosis|gout|shingles|ibs|uti|seropositi[a-z]*|fumeurs?|fumeuse|fumeuses|tabac|tabagisme|hysterectomy|mastectomy|stents?|bypass|limp|lame|crippled|handicap[a-z]*|wound[a-z]*|ulcers?|tumou?rs?|lesions?|polyps?|cysts?|nodules?|infected|infection|virus|viral|bacteria[a-z]*|sepsis|pneumonia|bronchitis|emphysema|stroke|strokes|aneurysm|embol[a-z]*|thromb[a-z]*|angina|arrhythm[a-z]*|murmur|palpitations?)([^a-z]|$)');
end $$;

-- 4. first-person / narrative context ("I have diabetes", "my husband's cancer", "j'ai", "ma mere", "diagnosed", "claim for", "passed away", "policy number").
--    Used when the old-style waiver of a PLACE name needs it, and to validate owner input (a term is never personal wording). Input: folded view.
create or replace function public.ws_personal_context_hit(p_fold text) returns boolean
language plpgsql immutable set search_path to 'public' as $$
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
language plpgsql immutable set search_path to 'public' as $$
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

-- 6. hard deny list for the vocabulary and for terms: person references, relations, titles, narrative words (events that happened to someone), claim/underwriting wording,
--    French equivalents, and (p_health) anything the health / condition detectors or any earlier category flag. NEVER echoes. Input: one word, any case/accents.
create or replace function public.ws_vocab_denied(p_word text, p_health boolean default true) returns boolean
language plpgsql immutable set search_path to 'public' as $$
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
    'sinistre', 'sinistres', 'accidente', 'blesse', 'blessee', 'hospitalise', 'income', 'incomes', 'revenu', 'revenus', 'salary', 'wage', 'wages']) then return true; end if;
  if w ~ '^(diagnos|suffer|claim|underwrit)' then return true; end if;
  if p_health then
    if w ~ '^(pregnan|medicat|prescri|surg|cancer|diabet|dement|alzheim|tumou?r|chemo|radiat|dialys|transplant)' then return true; end if;
    if cardinality(public.ws_sensitive_hits(w)) > 0 or public.ws_health_extra_hit(w) or public.ws_condition_hit(w)
       or cardinality(public.ws_sensitive_hits(public.ws_leet_text(w, 1))) > 0 or cardinality(public.ws_sensitive_hits(public.ws_leet_text(w, 2))) > 0 then return true; end if;
  end if;
  return false;
end $$;

-- 7. the default-deny vocabulary test. Input: the folded residual (approved terms already cut out and replaced by p_marker, never re-joined). Returns the reason codes
--    (empty array = every token is vocabulary, a number, or simple punctuation). Never echoes the text.
create or replace function public.ws_residual_check(p_r text, p_marker text) returns text[]
language plpgsql stable set search_path to 'public' as $$
declare v text := coalesce(p_r, ''); codes text[] := '{}'; n integer; tmp text;
begin
  v := translate(translate(v, '«»“”„•·‣', '"""""   '), '€£', chr(36) || chr(36));
  v := regexp_replace(v, '(^|[^a-z0-9])(l|d|c|n|s|qu|jusqu|lorsqu|puisqu)''(?=[a-z0-9])', '\1\2 ', 'g');   -- French elision: l'assurance -> l assurance
  v := regexp_replace(v, '([a-z])''(s|t|ll|re|ve|d)(?![a-z0-9])', '\1 ', 'g');                              -- Canada's, don't
  v := replace(v, '''', ' ');                                                                                -- any other apostrophe (j'ai) just splits the word
  if v ~ '[^ -~]' then
    codes := codes || array['unknown_word', 'non_latin_script'];
    if v ~ '[a-z]' then codes := codes || array['mixed_script']; end if;
  end if;
  tmp := regexp_replace(v, '(^|[^0-9])24 ?/ ?7([^0-9]|$)', '\1 \2', 'g');
  if v ~ '[a-z0-9]@|@[a-z0-9]' or v ~ '[a-z0-9&]&|&[a-z0-9#]' or v ~ '(^|[^0-9 ])%' or v ~ '(^|[^0-9]) +%' or v ~ '%[0-9a-f]{2}' or v ~ '(^|[^0-9])\+'
     or tmp ~ '(^|[^0-9a-z.,])[0-9]+ ?/ ?[0-9]+([^0-9a-z]|$)' then
    codes := codes || array['unknown_word', 'encoded_text'];
  end if;
  select count(*) into n from regexp_matches(v, '[a-z0-9]+(?:[.,][0-9]+)*|[^a-z0-9 ]', 'g') as m(g)
   where not (m.g[1] = p_marker
              or m.g[1] ~ '^[0-9]+([.,][0-9]+)*$'
              or m.g[1] ~ '^[.,;:!?"()/%$|#+&@-]$'
              or exists (select 1 from public.ws_marketing_vocab w where w.word = m.g[1] and w.removed_at is null));
  if n > 0 then codes := codes || array['unknown_word']; end if;
  select coalesce(array_agg(distinct c order by c), '{}') into codes from unnest(codes) c;
  return codes;
end $$;

-- 8. insurance-context helpers. A word that marks the text as insurance-related (any obfuscation view), and the row-level test the guards use.
create or replace function public.ws_text_insurance_word(p_fold text, p_l1 text, p_l2 text) returns boolean
language plpgsql immutable set search_path to 'public' as $$
declare x text; kc text;
begin
  foreach x in array array[coalesce(p_fold, ''), coalesce(p_l1, ''), coalesce(p_l2, '')] loop
    kc := regexp_replace(x, '[^a-z0-9]', '', 'g');
    if kc ~ '(insur|assuranc|underwrit|policy|policies|beneficiar|annuit|indemnit)' then return true; end if;
  end loop;
  return false;
end $$;

create or replace function public.ws_insurance_context(p_text text, p_ws uuid) returns boolean
language plpgsql stable security definer set search_path to 'public' as $$
declare f text; vert text; tr record;
begin
  if p_ws is null or p_text is null or btrim(p_text) = '' then return false; end if;
  f := public.ws_fold_text(p_text);
  if public.ws_text_insurance_word(f, public.ws_leet_text(f, 1), public.ws_leet_text(f, 2)) then return true; end if;
  select vertical into vert from public.client_workspaces where id = p_ws;
  for tr in select term_norm from public.ws_approved_terms where removed_at is null and kind = 'product' and (workspace_id = p_ws or (vert is not null and vertical = vert)) loop
    if f ~ ('(^|[^a-z0-9])' || replace(tr.term_norm, ' ', '[ ,\-]+') || '([^a-z0-9]|$)') then return true; end if;
  end loop;
  return false;
end $$;

-- 9. THE classifier core. Never echoes the text. Reasons are fixed codes: the old category names, plus
--    health:no_approved_term / health:residual / health:personal_context / identifier / insurance_identifier / unknown_word / non_latin_script / mixed_script / encoded_text /
--    approved_product_term / approved_feature / approved_place / insurance_vocabulary.
--    p_row_ctx: the guards pass true for every free-text column of a row when ANY column of that row is insurance-context. p_joined: the all-columns-joined scan (split values):
--    categories, health and identifiers only, no vocabulary test (the columns were each tested on their own).
create or replace function public.ws_classify_core(p_text text, p_ws uuid, p_row_ctx boolean, p_joined boolean) returns jsonb
language plpgsql stable security definer set search_path to 'public' as $$
declare
  f text; l1 text; l2 text; r text; r1 text; r2 text; prev text; rx text; tr record; vert text; marker text; before_r text; fx text;
  cats_s text[] := '{}'; allc text[]; hh text[]; health boolean := false; health0 boolean; inc boolean := false; x text; res text[];
  n_prod integer := 0; n_place integer := 0; n_feat integer := 0; ctx boolean := false; cut boolean := false; pass integer; word_ctx boolean; views text[]; ex text[];
begin
  if p_text is null or btrim(p_text) = '' then return jsonb_build_object('allowed', true, 'reasons', '[]'::jsonb); end if;
  f := public.ws_fold_text(p_text);
  l1 := public.ws_leet_text(f, 1);
  l2 := public.ws_leet_text(f, 2);
  -- every previous category, on the original text and on the folded and leetspeak views. Union: a hit in ANY view is a hit.
  -- (identical views are scanned once: the union is the same, the work is not repeated)
  views := array[p_text];
  if f <> p_text then views := views || f; end if;
  if l1 <> f then views := views || l1; end if;
  if l2 <> l1 then views := views || l2; end if;
  foreach x in array views loop
    hh := public.ws_sensitive_hits(x);
    if 'health' = any(hh) then health := true; end if;
    if 'application_or_income' = any(hh) then inc := true; end if;
    cats_s := cats_s || array_remove(array_remove(hh, 'health'), 'application_or_income');
  end loop;
  ex := array[f];
  if l1 <> f then ex := ex || l1; end if;
  if l2 <> l1 then ex := ex || l2; end if;
  foreach x in array ex loop
    if public.ws_health_extra_hit(x) then health := true; end if;
  end loop;
  -- insurance identifiers tied to a person: "policy number 1234567", "claim no. 998877", "numero de police 123456"
  if f ~ '(polic[ey]|claim|reclamation|member|membre|certificate|certificat|contrat|contract)[ _.\-]*(no|nr|num|number|numero|nbr|id|#)?[ _.:#\-]*[a-z]{0,4}[ \-]?[0-9]([ \-]?[0-9]){4,}' then
    cats_s := cats_s || array['insurance_identifier'];
  end if;
  -- date of birth next to a number
  if f ~ '(^|[^a-z])(born|dob|birthday|birth|naissance|ne le|nee le)[^0-9a-z]{0,15}[0-9]' then cats_s := cats_s || array['identity_document']; end if;
  health0 := health;

  -- strict screen (no workspace): exactly the previous behaviour
  if p_ws is null then
    allc := cats_s || case when inc then array['application_or_income'] else '{}'::text[] end;
    select coalesce(array_agg(distinct c order by c), '{}') into allc from unnest(allc) c;
    if cardinality(allc) > 0 then return jsonb_build_object('allowed', false, 'reasons', to_jsonb(allc || case when health then array['health'] else '{}'::text[] end)); end if;
    if not health then return jsonb_build_object('allowed', true, 'reasons', '[]'::jsonb); end if;
    return jsonb_build_object('allowed', false, 'reasons', jsonb_build_array('health', 'health:no_approved_term'));
  end if;

  -- workspace given (non-person tables). Context: an insurance word anywhere (or the row says so), or an approved product term below.
  word_ctx := p_row_ctx or public.ws_text_insurance_word(f, l1, l2);
  ctx := word_ctx;
  marker := 'zzqx';
  while position(marker in f) > 0 loop marker := marker || 'x'; end loop;
  select vertical into vert from public.client_workspaces where id = p_ws;
  r := f;
  -- cut approved terms out of the TOKEN STREAM: whole words only, replaced by a marker that keeps the neighbours apart (no re-joining, so a splice
  -- such as "dia health insurance betes" leaves the two halves as separate unknown words). Pass 1: products and places, pass 2: feature phrases (only next to insurance context).
  for pass in 1..2 loop
    if pass = 2 then
      ctx := ctx or n_prod > 0;
      if not ctx then exit; end if;
    end if;
    for tr in select term_norm, kind from public.ws_approved_terms
              where removed_at is null and (workspace_id = p_ws or (vert is not null and vertical = vert))
                and ((pass = 1 and kind in ('product', 'place')) or (pass = 2 and kind = 'feature'))
              order by length(term_norm) desc, term_norm loop
      rx := '(^|[^a-z0-9])' || replace(tr.term_norm, ' ', '[ ,\-]+') || '([^a-z0-9]|$)';
      prev := null;
      while r ~ rx and prev is distinct from r loop
        prev := r;
        r := regexp_replace(r, rx, '\1 ' || marker || ' \2', 'g');
        if tr.kind = 'product' then n_prod := n_prod + 1; elsif tr.kind = 'place' then n_place := n_place + 1; else n_feat := n_feat + 1; end if;
      end loop;
    end loop;
  end loop;
  ctx := ctx or n_prod > 0;
  -- 'your income' is generic marketing; any other 'income' stays the mortgage-income category. Never when a currency amount (other than a product price per period) is present.
  if ctx then
    -- a PRICE OF THE PRODUCT ("from $25/month", "dès 25 $ par mois") is not an amount of income; "up to $4,500 a month" next to 'income' is
    fx := regexp_replace(f, '(^|[^a-z])(from|at|only|just|for|des|de|low as|starting|starts) +\$ ?[0-9][0-9,.]*[0-9]? *(/| per | a | par )? *(mo|month|mois|year|an|yr|week|day|jour|semaine|annee)([^a-z]|$)', '\1 \5', 'g');
    fx := regexp_replace(fx, '(^|[^a-z])(from|at|only|just|for|des|de|low as|starting|starts) +[0-9][0-9,.]*[0-9]? ?\$ ?(/| per | a | par )? *(mo|month|mois|year|an|yr|week|day|jour|semaine|annee)([^a-z]|$)', '\1 \5', 'g');
    fx := regexp_replace(fx, '(^|[^0-9])(19|20)[0-9]{2}([^0-9]|$)', '\1 \3', 'g');
    if fx !~ '[$]|[0-9] ?(dollars?|cad|usd|euros?|k)([^a-z]|$)|[0-9]{4,}' then
      before_r := r;
      r := regexp_replace(r, '(^|[^a-z0-9])((your|votre) +)income(?![a-z0-9])', '\1\2 ' || marker || ' ', 'g');
      r := regexp_replace(r, '(^|[^a-z0-9])((votre|vos) +)revenus?(?![a-z0-9])', '\1\2 ' || marker || ' ', 'g');
      if r is distinct from before_r then cut := true; end if;
    end if;
  end if;
  cut := cut or (n_prod + n_place + n_feat) > 0;
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
  if (ctx or (health0 and n_place > 0)) and p_text ~ '[\u0370-\u03ff\u0400-\u052f]' and p_text ~ '[A-Za-z]' then
    return jsonb_build_object('allowed', false, 'reasons', to_jsonb(case when health0 then array['health'] else '{}'::text[] end || array['mixed_script', 'unknown_word']));
  end if;
  if ctx then
    if public.ws_identifier_hit(r) then
      return jsonb_build_object('allowed', false, 'reasons', to_jsonb(case when health0 then array['health'] else '{}'::text[] end || array['identifier']));
    end if;
    if not p_joined then
      res := public.ws_residual_check(r, marker);
      if cardinality(res) > 0 then
        return jsonb_build_object('allowed', false, 'reasons', to_jsonb(case when health0 then array['health'] else '{}'::text[] end || res));
      end if;
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
language sql stable security definer set search_path to 'public' as $$
  select public.ws_classify_core(p_text, p_ws, false, false);
$$;

-- 10. owner-only term management. The audit row carries ids, kinds and counts only: never the term text.
drop function if exists public.ws_add_approved_term(uuid, text, text, text);
create or replace function public.ws_add_approved_term(p_ws uuid, p_vertical text, p_kind text, p_term text, p_confirm_vertical boolean default false) returns uuid
language plpgsql security definer set search_path to 'public' as $$
declare v_term text; v_norm text; v_id uuid; v_words integer; v_scope text; n_active integer; w text; prodwords text[] := array[
          'health', 'medical', 'dental', 'disability', 'disabilities', 'critical', 'illness', 'illnesses', 'accident', 'accidental', 'dismemberment', 'death', 'sante', 'invalidite', 'maladie', 'maladies', 'grave', 'graves', 'dentaire', 'medicale', 'income', 'revenu', 'revenus'];
        ptdeny text[] := array['with', 'who', 'whom', 'people', 'persons', 'personnes', 'individuals', 'those', 'patients', 'sufferers', 'survivors', 'victims', 'suffering', 'living', 'having', 'atteint', 'atteinte', 'atteints',
          'atteintes', 'souffrant', 'souffrants', 'ceux', 'celles', 'gens', 'anyone', 'everyone', 'someone', 'women', 'men', 'femmes', 'hommes', 'pregnant', 'enceinte'];
        hits text[]; ws_words text[];
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
      -- Word by word, never as a run: "john smith heart attack" must fail on "john".
      foreach w in array ws_words loop
        if not (w = any (prodwords) or w = any (array['attack', 'attacks', 'failure', 'arrest', 'loss', 'bypass', 'replacement']) or exists (select 1 from public.ws_marketing_vocab v where v.word = w and v.removed_at is null)
                or public.ws_health_extra_hit(w) or public.ws_condition_hit(w) or 'health' = any(public.ws_sensitive_hits(w))) then
          raise exception 'term refused: a feature phrase may name only recognised coverage subjects and vocabulary words';
        end if;
      end loop;
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
language plpgsql security definer set search_path to 'public' as $$
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
language plpgsql security definer set search_path to 'public' as $$
declare v_norm text; v_id uuid;
begin
  perform public.ffm_require_owner();
  if p_lang is null or p_lang not in ('en', 'fr') then raise exception 'word refused: language must be en or fr'; end if;
  if p_word is null or btrim(p_word) !~ '^[A-Za-z\u00c0-\u00d6\u00d8-\u00f6\u00f8-\u00ff\u0152\u0153]{2,30}$' then raise exception 'word refused: one word of 2 to 30 letters (no digits, spaces, hyphens or symbols)'; end if;
  v_norm := public.ws_fold_text(btrim(p_word));
  if v_norm !~ '^[a-z]{2,30}$' then raise exception 'word refused: could not be normalised to plain letters'; end if;
  if public.ws_vocab_denied(v_norm, true) then raise exception 'word refused: it is on the hard deny list (people, events, wording about a case, or anything medical) and can never be vocabulary'; end if;
  if exists (select 1 from public.ws_marketing_vocab where lang = p_lang and word = v_norm and removed_at is null) then raise exception 'word already in the vocabulary'; end if;
  insert into public.ws_marketing_vocab (lang, word) values (p_lang, v_norm) returning id into v_id;
  insert into public.audit_log (actor, action, target, detail) values ('owner', 'ws_vocab_word_added', 'vocab/' || p_lang, jsonb_build_object('word_id', v_id, 'lang', p_lang));
  return v_id;
end $$;

create or replace function public.ws_remove_vocab_word(p_word_id uuid) returns void
language plpgsql security definer set search_path to 'public' as $$
declare t public.ws_marketing_vocab;
begin
  perform public.ffm_require_owner();
  select * into t from public.ws_marketing_vocab where id = p_word_id and removed_at is null for update;
  if t.id is null then raise exception 'vocabulary word not found or already removed'; end if;
  update public.ws_marketing_vocab set removed_at = clock_timestamp(), removed_by = 'owner' where id = p_word_id;
  insert into public.audit_log (actor, action, target, detail) values ('owner', 'ws_vocab_word_removed', 'vocab/' || t.lang, jsonb_build_object('word_id', p_word_id, 'lang', t.lang));
end $$;

-- 12. seed data. VOCABULARY: generic function and marketing words only (no person, relation, narrative, claim, underwriting or health word; the DO block below proves it
--     with the same deny function the owner functions use, and fails the migration otherwise). Terms ship EMPTY. A word the owner removed stays removed on re-apply.
insert into public.ws_marketing_vocab (lang, word, created_by)
select 'en', w, 'seed' from (select distinct unnest(regexp_split_to_array($v$
a an the and or but nor so yet if then than as at by for from in into of on onto out over per plus to under up upon via with within without about above across against along among around
behind below beside between beyond during except inside near since through throughout toward towards until while whether because both either neither each every all any some no not only just
also even more most much many less least other another such same own very too now today tomorrow here there where when what which who how why can could will would should may might must shall
do does don doesn isn aren be is are
you your yours yourself we us our ours ourselves it its this that these those one ones everyone anyone someone
protect protects protected cover covers covered pay pays paying paid save saves saving savings get gets learn compare comparing apply quote start choose find ask talk speak contact book schedule
visit see read discover build grow plan prepare secure safeguard insure insures enjoy feel stay keep give help helps support guide review check explore join click tap send request receive access
manage customize customise tailor simplify switch renew upgrade enroll sign buy shop reduce lower increase replace replaces replacing include includes including offer offers provide provides
let allows allow need needs want look looking take make makes worry trust rely begin
family families business businesses price prices pricing month months monthly year years yearly annual annually week weeks weekly day days daily hour hours minute minutes second seconds
coverage coverages protection protections plans quotes free benefit benefits policy policies insurance insurances insurer broker brokers agent agents advisor advisors adviser advisers advice
expert experts team service services online phone call text chat email rate rates premium premiums deductible lump sum payout payouts payment payments cost costs budget value option options
choice choices solution solutions program programs product products package packages deal deals discount discounts peace mind security future life lives home homes house car auto travel trip
trips vacation work worker workers employee employees employer employers owner owners self employed freelancer freelancers professional professionals entrepreneur entrepreneurs student
students senior seniors retirement retirees children kids couples people parents canada canadian canadians ontario quebec alberta british columbia manitoba saskatchewan newfoundland labrador
scotia brunswick territories north south east west province provinces nationwide national local coast mortgage mortgages
affordable simple easy fast quick flexible personal personalized best top trusted licensed independent leading reliable safe strong smart clear transparent complete comprehensive extra
additional new real true better good great perfect right ready available guaranteed limited full whole term permanent universal group individual extended long short high low fair
competitive tax
one two three four five six seven eight nine ten twenty thirty forty fifty hundred thousand million zero first
tue wed thu fri sat sun monday tuesday wednesday thursday friday saturday sunday spring summer fall winter holiday holidays open office offices location locations appointment consultation
meeting obligation commitment fee fees hidden instantly instant anytime cancel cancellation renewal renewable renews application applications beneficiary beneficiaries exam care level levels tier
tiers amount amounts lifetime forever rider riders non lowest highest reviews stars star
small large big medium mo yr yrs part parts starting starts next fits fit ages age deserves deserve works grows grow groups individuals add bills young thousands insurers made follows follow place wait comes come lifestyle
meta google facebook instagram tiktok linkedin youtube sms seo ads ad campaign campaigns creative creatives landing page pages form forms lead leads audience audiences headline copy draft
$v$, '[[:space:]]+')) w) s where w <> '' and not exists (select 1 from public.ws_marketing_vocab v where v.lang = 'en' and v.word = s.w);
insert into public.ws_marketing_vocab (lang, word, created_by)
select 'fr', w, 'seed' from (select distinct unnest(regexp_split_to_array($v$
le la les l un une des du de d au aux et ou mais donc or ni car que qu quel quelle quels quelles qui quoi dont ce cet cette ces ca celui
dans en sur sous avec sans pour par chez vers entre contre depuis pendant jusque jusqu plus moins tres trop assez aussi encore deja toujours jamais ne n pas non oui si tout tous toute toutes
chaque autre autres meme tel
vous votre vos nous notre nos on se s c y
protegez protegeons proteger obtenez obtenir appelez appeler comparez comparer economisez economiser profitez profiter decouvrez decouvrir demandez soumettez contactez choisissez trouvez
apprenez planifiez assurez assurer couvrir couvre couvrent payer paye payez beneficier beneficiez commencez reservez visitez simplifiez preparez securisez rassurez peut peuvent pouvez
pouvons est sont soit etre avez avons avoir faire faites aller veut voulez cherchez
famille familles entreprise entreprises prix mois an ans annee annees semaine semaines jour jours heure heures minute minutes couverture couvertures protection protections plan plans soumission
soumissions devis gratuit gratuite gratuits avantage avantages courtier courtiers agent agents conseiller conseillers conseillere equipe service services soutien aide ligne telephone taux prime
primes somme montant montants paiement paiements cout couts budget valeur option options choix solution solutions programme programmes produit produits forfait forfaits offre offres rabais
economie economies paix esprit securite avenir vie vies maison maisons auto voiture voyage voyages vacances travail travailleurs travailleur autonome autonomes employes employeur employeurs
proprietaire proprietaires etudiants etudiant retraite retraites parents enfants couples gens canada canadien canadiens canadiennes ontario quebec alberta manitoba saskatchewan
assurance assurances assure assures assureur
abordable simple facile rapide flexible personnalise meilleur meilleure meilleurs fiable securitaire complet complete complets exclusif nouveau nouvelle grand grande vrai bon bonne parfait
pret prete disponible garanti terme temporaire permanente collective collectif individuelle individuel appel suffit suffisent ici maintenant aujourd hui demain
un deux trois quatre cinq six sept huit neuf dix vingt trente cent mille million
lundi mardi mercredi jeudi vendredi samedi dimanche lun mar mer jeu ven sam dim printemps automne hiver ouvert ouverts bureau bureaux rendez consultation sans obligation gratuitement
quelques partir prochain endroit compte aucune aucun petite petites petit petits merite budgets grandit grandir proches forfaitaire examen examens tarif tarifs mieux
beneficiaire beneficiaires niveau niveaux montant duree toujours vie
$v$, '[[:space:]]+')) w) s where w <> '' and not exists (select 1 from public.ws_marketing_vocab v where v.lang = 'fr' and v.word = s.w);
do $$ declare bad text; begin
  select string_agg(word, ', ') into bad from public.ws_marketing_vocab where created_by = 'seed' and removed_at is null and public.ws_vocab_denied(word, true);
  if bad is not null then raise exception 'seed vocabulary contains denied words: %', bad; end if;
end $$;

-- PLACE CATALOG: municipalities an owner may approve (fixed; no free text). Only unambiguous names (no common nouns, no first names). Never edited after this migration.
insert into public.ws_place_catalog (name_norm, display_name, province)
select public.ws_fold_text(split_part(e, '|', 1)), split_part(e, '|', 1), split_part(e, '|', 2)
from unnest(array[
 'Toronto|ON', 'Ottawa|ON', 'Mississauga|ON', 'Brampton|ON', 'Hamilton|ON', 'London|ON', 'Markham|ON', 'Vaughan|ON', 'Kitchener|ON', 'Windsor|ON', 'Richmond Hill|ON', 'Oakville|ON', 'Burlington|ON',
 'Oshawa|ON', 'Barrie|ON', 'St Catharines|ON', 'Guelph|ON', 'Cambridge|ON', 'Whitby|ON', 'Kingston|ON', 'Ajax|ON', 'Waterloo|ON', 'Pickering|ON', 'Niagara Falls|ON', 'Peterborough|ON',
 'Sudbury|ON', 'Thunder Bay|ON', 'Cornwall|ON', 'Belleville|ON', 'Sarnia|ON', 'North Bay|ON', 'Brantford|ON', 'Kanata|ON', 'Barrhaven|ON', 'Nepean|ON', 'Orleans|ON', 'Stittsville|ON',
 'Montreal|QC', 'Quebec City|QC', 'Laval|QC', 'Gatineau|QC', 'Longueuil|QC', 'Sherbrooke|QC', 'Saguenay|QC', 'Levis|QC', 'Trois Rivieres|QC', 'Terrebonne|QC', 'Drummondville|QC', 'Granby|QC', 'Brossard|QC',
 'Vancouver|BC', 'Victoria|BC', 'Burnaby|BC', 'Kelowna|BC', 'Abbotsford|BC', 'Kamloops|BC', 'Nanaimo|BC', 'Chilliwack|BC', 'Prince George|BC', 'Vernon|BC', 'Penticton|BC', 'Courtenay|BC',
 'Calgary|AB', 'Edmonton|AB', 'Red Deer|AB', 'Lethbridge|AB', 'Medicine Hat|AB', 'Airdrie|AB', 'Grande Prairie|AB', 'St Albert|AB', 'Fort McMurray|AB', 'Cochrane|AB', 'Lloydminster|AB',
 'Winnipeg|MB', 'Brandon|MB', 'Saskatoon|SK', 'Regina|SK', 'Moose Jaw|SK', 'Prince Albert|SK', 'Swift Current|SK',
 'Halifax|NS', 'Truro|NS', 'Sydney|NS', 'Moncton|NB', 'Fredericton|NB', 'Saint John|NB', 'Charlottetown|PE', 'St Johns|NL', 'Corner Brook|NL', 'Gander|NL', 'Mount Pearl|NL',
 'Whitehorse|YT', 'Yellowknife|NT', 'Iqaluit|NU']) e
on conflict (name_norm) do nothing;

-- 13. guards, replaced. Same exclusions and messages as before; the classifier decides. Waiver and vocabulary test only on non-person tables.
--     "Structural" columns (enums, template keys, actor tags) are exempt from the vocabulary test only: every category and the health screen still apply to them.
create or replace function public.ws_guard() returns trigger
language plpgsql set search_path to 'public' as $$
declare k text; v text; res jsonb; allv text := ''; j jsonb := to_jsonb(new); v_ws uuid; row_ctx boolean := false;
begin
  v_ws := case when tg_table_name = any (array['ws_campaigns', 'ws_ledger']) then nullif(j ->> 'workspace_id', '')::uuid else null end;
  -- a value split across columns (name / phone / note) is caught by also scanning every scanned column joined together
  for k, v in select key, value from jsonb_each_text(j - array['id', 'workspace_id', 'campaign_id', 'created_at', 'status', 'stage', 'amount_cents', 'monthly_budget_cents']) loop
    allv := allv || ' ' || coalesce(v, '');
  end loop;
  if v_ws is not null then row_ctx := public.ws_insurance_context(allv, v_ws); end if;
  res := public.ws_classify_core(allv, v_ws, row_ctx, true);
  if not (res ->> 'allowed')::boolean then
    raise exception 'Sensitive data refused in % (%). Applications, banking, credit, ID and sensitive financial data must never be stored here.', tg_table_name, array_to_string(array(select jsonb_array_elements_text(res -> 'reasons')), ', ') using errcode = 'P0001';
  end if;
  for k, v in select key, value from jsonb_each_text(j - array['id', 'workspace_id', 'campaign_id', 'created_at', 'status', 'stage', 'amount_cents', 'monthly_budget_cents']) loop
    res := public.ws_classify_core(v, v_ws, row_ctx, false);
    if not (res ->> 'allowed')::boolean then
      raise exception 'Sensitive data refused in %.% (%). Applications, banking, credit, ID and sensitive financial data must never be stored here.', tg_table_name, k, array_to_string(array(select jsonb_array_elements_text(res -> 'reasons')), ', ')
        using errcode = 'P0001';
    end if;
  end loop;
  return new;
end $$;

create or replace function public.ffm_guard() returns trigger
language plpgsql set search_path to 'public' as $$
declare k text; v text; res jsonb; allv text := ''; j jsonb := to_jsonb(new); v_ws uuid; row_ctx boolean := false; structural boolean; allfree text := '';
begin
  v_ws := case when tg_table_name = any (array['ffm_ad_sets', 'ffm_creatives', 'ffm_approvals', 'ffm_onboarding_items']) then nullif(j ->> 'workspace_id', '')::uuid else null end;
  for k, v in select e.key, e.value #>> '{}' from jsonb_each(j) e
              where jsonb_typeof(e.value) = 'string'
                and not exists (select 1 from pg_attribute a where a.attrelid = tg_relid and a.attname = e.key and a.attnum > 0 and not a.attisdropped
                                  and a.atttypid in ('uuid'::regtype, 'timestamptz'::regtype)) loop
    structural := k = any (array['status', 'stage', 'kind', 'provider', 'template_key', 'approved_by', 'destination_kind']) or (k = 'provided_by' and lower(btrim(v)) in ('owner', 'client', 'ai', 'bot', 'system'));
    if not structural then allfree := allfree || ' ' || v; end if;
  end loop;
  if v_ws is not null then row_ctx := public.ws_insurance_context(allfree, v_ws); end if;
  for k, v in select e.key, e.value #>> '{}' from jsonb_each(j) e
              where jsonb_typeof(e.value) = 'string'
                and not exists (select 1 from pg_attribute a where a.attrelid = tg_relid and a.attname = e.key and a.attnum > 0 and not a.attisdropped
                                  and a.atttypid in ('uuid'::regtype, 'timestamptz'::regtype)) loop
    structural := k = any (array['status', 'stage', 'kind', 'provider', 'template_key', 'approved_by', 'destination_kind']) or (k = 'provided_by' and lower(btrim(v)) in ('owner', 'client', 'ai', 'bot', 'system'));
    res := public.ws_classify_core(v, v_ws, row_ctx and not structural, false);
    if not (res ->> 'allowed')::boolean then
      raise exception 'Sensitive data refused in %.% (%). Applications, banking, credit, ID and sensitive financial data must never be stored here.', tg_table_name, k, array_to_string(array(select jsonb_array_elements_text(res -> 'reasons')), ', ') using errcode = 'P0001';
    end if;
    allv := allv || ' ' || v;
  end loop;
  res := public.ws_classify_core(allv, v_ws, row_ctx, true);   -- a value split across columns
  if not (res ->> 'allowed')::boolean then
    raise exception 'Sensitive data refused in % (%). Applications, banking, credit, ID and sensitive financial data must never be stored here.', tg_table_name, array_to_string(array(select jsonb_array_elements_text(res -> 'reasons')), ', ') using errcode = 'P0001';
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
revoke all on function public.ws_text_insurance_word(text, text, text) from public, anon, authenticated;
revoke all on function public.ws_insurance_context(text, uuid) from public, anon, authenticated;
revoke all on function public.ws_classify_core(text, uuid, boolean, boolean) from public, anon, authenticated;
revoke all on function public.ws_classify_text(text, uuid) from public, anon, authenticated;
revoke all on function public.ws_add_approved_term(uuid, text, text, text, boolean) from public, anon, authenticated;
revoke all on function public.ws_remove_approved_term(uuid) from public, anon, authenticated;
revoke all on function public.ws_add_vocab_word(text, text) from public, anon, authenticated;
revoke all on function public.ws_remove_vocab_word(uuid) from public, anon, authenticated;
revoke all on function public.ws_guard() from public, anon, authenticated;
revoke all on function public.ffm_guard() from public, anon, authenticated;
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
grant execute on function public.ws_text_insurance_word(text, text, text) to service_role;
grant execute on function public.ws_insurance_context(text, uuid) to service_role;
grant execute on function public.ws_classify_core(text, uuid, boolean, boolean) to service_role;
grant execute on function public.ws_classify_text(text, uuid) to service_role;
grant execute on function public.ws_add_approved_term(uuid, text, text, text, boolean) to service_role;
grant execute on function public.ws_remove_approved_term(uuid) to service_role;
grant execute on function public.ws_add_vocab_word(text, text) to service_role;
grant execute on function public.ws_remove_vocab_word(uuid) to service_role;
grant execute on function public.ws_guard() to service_role;
grant execute on function public.ffm_guard() to service_role;
