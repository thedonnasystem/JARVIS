-- Insurance content classification v1 (FENDEZY priority 3, Nov 2026). Additive: 1 table, 9 new functions, 2 replaced functions (ws_guard, ffm_guard). No rows are changed.
--   PROBLEM: the 'health' detector (20261119) refuses ordinary insurance PRODUCT wording ("health insurance", "disability insurance", "critical illness cover",
--   "Medicine Hat"), so Client 2 (insurance) could not write marketing. It also missed French, accents, look-alike letters and leetspeak.
--   MODEL: separate insurance-PRODUCT MARKETING (allowed only as an exact OWNER-APPROVED term) from PERSONAL HEALTH INFORMATION (always refused, fail closed).
--   * ws_approved_terms: owner-managed allow-list scoped to ONE workspace or to a VERTICAL. It ships EMPTY; empty = nothing extra is permitted (old behaviour).
--     Terms are added/removed only by ws_add_approved_term / ws_remove_approved_term (owner-only, audit logged WITHOUT the term text, charset and length limited). Rows are never deleted.
--   * ws_classify_text(text, workspace) -> {"allowed": bool, "reasons": [codes]}. It NEVER echoes the text. Order of decision:
--       1. every previous category (SIN, card, account, identity, banking, credit, income) still blocks, on the original text AND on a normalised view
--          (accents, look-alike letters, zero-width, fullwidth, combining marks) AND on two leetspeak views. Nothing about these is waivable.
--       2. the 'health' category (old detector + new French/extra stems, same four views) is the ONLY category an approved term can waive. With no approved term
--          matched, health text is refused exactly as before.
--       3. an approved term must match EXACTLY (whole words, case/accent-insensitive). It is cut out of the text; if ANY health wording remains in what is left
--          (a diagnosis, "diabetes", "claim for my surgery"), the text is refused.
--       4. a term (product or place) is waived only if the rest has NO first-person / narrative context (my, I, j'ai, ma, diagnosed ... passed away, policy number ...) and NO
--          identifier (phone, email, postal code, street address, date, 4+ digit run; prices and years are allowed), and no mixed Latin/Cyrillic/Greek script.
--       Anything ambiguous is refused. A place name (kind 'place', e.g. Medicine Hat) is waived on the same exact-match rule and the same context/identifier checks.
--   * ws_guard / ffm_guard (replaced) call the classifier. The waiver is applied ONLY on non-person tables (ws_campaigns, ws_ledger, ffm_ad_sets, ffm_creatives,
--     ffm_approvals, ffm_onboarding_items). Person tables (ws_leads, client_workspaces, ffm_routing_rules, ffm_consent_*) keep the strict behaviour, plus the wider normalisation.
--   * ws_sensitive_hits is NOT changed (other callers, the Python wrapper and ffm_route_preview keep the strict result). Regular expressions have stated limits: see the policy document.

-- 1. approved terms (owner-managed; ships empty)
create table if not exists public.ws_approved_terms (
  id uuid primary key default gen_random_uuid(),
  workspace_id uuid references public.client_workspaces(id) on delete restrict,
  vertical text check (vertical is null or vertical ~ '^[a-z0-9][a-z0-9-]{1,40}$'),
  kind text not null check (kind in ('product', 'place')),
  term text not null check (length(term) between 3 and 60),
  term_norm text not null check (length(term_norm) between 3 and 60) check (term_norm ~ '^[a-z]+([ ''][a-z]+)*$'),   -- two separate checks: one AND-chain with BETWEEN is re-rendered differently after a schema dump/restore (backup drill, schema identity)
  created_by text not null default 'owner',
  created_at timestamptz not null default clock_timestamp(),
  removed_at timestamptz,
  removed_by text,
  check ((workspace_id is null) <> (vertical is null))
);
create unique index if not exists ws_approved_terms_active_uidx
  on public.ws_approved_terms ((coalesce(workspace_id::text, 'v:' || vertical)), kind, term_norm) where removed_at is null;
alter table public.ws_approved_terms enable row level security;
revoke all on public.ws_approved_terms from public, anon, authenticated;
grant select on public.ws_approved_terms to service_role;
revoke insert, update, delete, truncate, trigger, references on public.ws_approved_terms from service_role;

-- rows are never deleted; the only allowed update is the one-way soft removal done by ws_remove_approved_term
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

-- 2. normalisation. zero-width / bidi / variation selectors out, NFKC (fullwidth), NFD + combining marks out (accents), lower case, ligatures,
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

-- leetspeak views (for DETECTION of obfuscated words only, never used for the number detectors, never used to match approved terms).
create or replace function public.ws_leet_text(p_fold text, p_variant integer) returns text
language sql immutable set search_path to 'public' as $$
  select case when p_variant = 2 then translate(coalesce(p_fold, ''), '013457$@!|', 'oleastsail')
              else translate(coalesce(p_fold, ''), '013457$@!|', 'oieastsaii') end;
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

-- 4. first-person / narrative context ("I have diabetes", "my husband's cancer", "j'ai", "ma mere", "diagnosed", "claim for", "passed away", "policy number").
--    Second-person marketing ("your family") and company voice ("we", "our") are NOT context. Input: folded view.
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

-- 5. identifiers that must not sit next to a health product phrase. Prices ($25/month, 100%), years (1995..2099) and age ranges (18-65) are allowed. Input: folded view.
create or replace function public.ws_identifier_hit(p_fold text) returns boolean
language plpgsql immutable set search_path to 'public' as $$
declare x text := coalesce(p_fold, '');
begin
  if x ~ '@' or x ~ '[a-z0-9._-]+ ?(\[at\]|\(at\)|\sat\s|arobase) ?[a-z0-9-]+( ?(\[dot\]|\(dot\)|\sdot\s|\spoint\s|\.) ?)[a-z]{2,}' then return true; end if;
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

-- 6. THE classifier. Never echoes the text. Reasons are fixed codes: the old category names, plus
--    health:no_approved_term / health:residual / health:personal_context / health:identifier / health:mixed_script / insurance_identifier / approved_product_term / approved_place.
create or replace function public.ws_classify_text(p_text text, p_ws uuid default null) returns jsonb
language plpgsql stable security definer set search_path to 'public' as $$
declare
  f text; l1 text; l2 text; r text; r1 text; r2 text; prev text; rx text; tr record; vert text;
  cats text[] := '{}'; hh text[]; health boolean := false; n_prod integer := 0; n_place integer := 0; x text;
begin
  if p_text is null or btrim(p_text) = '' then return jsonb_build_object('allowed', true, 'reasons', '[]'::jsonb); end if;
  f := public.ws_fold_text(p_text);
  l1 := public.ws_leet_text(f, 1);
  l2 := public.ws_leet_text(f, 2);
  -- every previous category, on the original text and on the folded and leetspeak views. Union: a hit in ANY view is a hit.
  foreach x in array array[p_text, f, l1, l2] loop
    hh := public.ws_sensitive_hits(x);
    if 'health' = any(hh) then health := true; end if;
    cats := cats || array_remove(hh, 'health');
  end loop;
  if public.ws_health_extra_hit(f) or public.ws_health_extra_hit(l1) or public.ws_health_extra_hit(l2) then health := true; end if;
  -- insurance identifiers tied to a person: "policy number 1234567", "claim no. 998877", "numero de police 123456"
  if f ~ '(polic[ey]|claim|reclamation|member|membre|certificate|certificat|contrat|contract)[ _.\-]*(no|nr|num|number|numero|nbr|id|#)?[ _.:#\-]*[a-z]{0,4}[ \-]?[0-9]([ \-]?[0-9]){4,}' then
    cats := cats || array['insurance_identifier'];
  end if;
  -- date of birth next to a number
  if f ~ '(^|[^a-z])(born|dob|birthday|birth|naissance|ne le|nee le)[^0-9a-z]{0,15}[0-9]' then cats := cats || array['identity_document']; end if;
  select coalesce(array_agg(distinct c order by c), '{}') into cats from unnest(cats) c;
  if cardinality(cats) > 0 then
    return jsonb_build_object('allowed', false, 'reasons', to_jsonb(cats || case when health then array['health'] else '{}'::text[] end));
  end if;
  if not health then return jsonb_build_object('allowed', true, 'reasons', '[]'::jsonb); end if;

  -- health wording present. Only an exact, owner-approved term inside this workspace/vertical can waive it.
  if p_ws is null then return jsonb_build_object('allowed', false, 'reasons', jsonb_build_array('health', 'health:no_approved_term')); end if;
  select vertical into vert from public.client_workspaces where id = p_ws;
  r := f;
  for tr in select term_norm, kind from public.ws_approved_terms
            where removed_at is null and (workspace_id = p_ws or (vert is not null and vertical = vert)) order by length(term_norm) desc, term_norm loop
    rx := '(^|[^a-z0-9])' || replace(tr.term_norm, ' ', '[ \-]+') || '([^a-z0-9]|$)';
    prev := null;
    while r ~ rx and prev is distinct from r loop
      prev := r;
      r := regexp_replace(r, rx, '\1 zzqx \2', 'g');
      if tr.kind = 'product' then n_prod := n_prod + 1; else n_place := n_place + 1; end if;
    end loop;
  end loop;
  if n_prod + n_place = 0 then return jsonb_build_object('allowed', false, 'reasons', jsonb_build_array('health', 'health:no_approved_term')); end if;
  -- mixed Latin + Cyrillic/Greek letters: an obfuscation signature, never waived
  if p_text ~ '[\u0370-\u03ff\u0400-\u052f]' and p_text ~ '[A-Za-z]' then return jsonb_build_object('allowed', false, 'reasons', jsonb_build_array('health', 'health:mixed_script')); end if;
  -- whatever is left after cutting out the approved terms must be free of health wording, in every view
  r1 := public.ws_leet_text(r, 1);
  r2 := public.ws_leet_text(r, 2);
  if 'health' = any(public.ws_sensitive_hits(r)) or 'health' = any(public.ws_sensitive_hits(r1)) or 'health' = any(public.ws_sensitive_hits(r2))
     or public.ws_health_extra_hit(r) or public.ws_health_extra_hit(r1) or public.ws_health_extra_hit(r2) then
    return jsonb_build_object('allowed', false, 'reasons', jsonb_build_array('health', 'health:residual'));
  end if;
  -- both kinds of waiver (product or place) need a context-free, identifier-free text: simpler to explain, and fail closed
  if public.ws_personal_context_hit(r) or public.ws_personal_context_hit(r1) or public.ws_personal_context_hit(r2) then
    return jsonb_build_object('allowed', false, 'reasons', jsonb_build_array('health', 'health:personal_context'));
  end if;
  if public.ws_identifier_hit(r) then
    return jsonb_build_object('allowed', false, 'reasons', jsonb_build_array('health', 'health:identifier'));
  end if;
  return jsonb_build_object('allowed', true, 'reasons', jsonb_build_array(case when n_prod > 0 then 'approved_product_term' else 'approved_place' end));
end $$;

-- 7. owner-only term management. The audit row carries ids and counts only: never the term text.
create or replace function public.ws_add_approved_term(p_ws uuid, p_vertical text, p_kind text, p_term text) returns uuid
language plpgsql security definer set search_path to 'public' as $$
declare v_term text; v_norm text; v_id uuid; v_words integer; v_scope text; n_active integer;
begin
  perform public.ffm_require_owner();
  if (p_ws is null) = (p_vertical is null) then raise exception 'term refused: give exactly one of a workspace or a vertical'; end if;
  if p_kind is null or p_kind not in ('product', 'place') then raise exception 'term refused: kind must be product or place'; end if;
  if p_ws is not null and not exists (select 1 from public.client_workspaces where id = p_ws) then raise exception 'term refused: workspace not found'; end if;
  if p_vertical is not null and p_vertical !~ '^[a-z0-9][a-z0-9-]{1,40}$' then raise exception 'term refused: vertical must be lower-case letters, digits and hyphens'; end if;
  v_term := btrim(regexp_replace(coalesce(p_term, ''), '[[:space:]]+', ' ', 'g'));
  if length(v_term) < 3 or length(v_term) > 60 then raise exception 'term refused: length must be 3 to 60 characters'; end if;
  if v_term !~ '^[A-Za-z\u00c0-\u00d6\u00d8-\u00f6\u00f8-\u00ff\u0152\u0153\u2019'' -]+$' then raise exception 'term refused: letters, spaces, hyphens and apostrophes only (no digits or symbols)'; end if;
  v_norm := btrim(replace(public.ws_fold_text(v_term), '-', ' '));
  v_norm := regexp_replace(v_norm, ' +', ' ', 'g');
  if v_norm !~ '^[a-z]+([ ''][a-z]+)*$' then raise exception 'term refused: could not be normalised to plain letters'; end if;
  v_words := cardinality(regexp_split_to_array(v_norm, ' '));
  if p_kind = 'product' and (v_words < 2 or v_words > 6) then raise exception 'term refused: a product term is 2 to 6 words'; end if;
  if p_kind = 'place' and v_words > 5 then raise exception 'term refused: a place name is at most 5 words'; end if;
  if p_kind = 'product' and v_norm !~ '(^| )(insurance|assurance|assurances|coverage|cover|protection|benefit|benefits|plan|plans|policy|policies|couverture|garantie|garanties|annuity|rente)( |$)' then
    raise exception 'term refused: a product term must name a product (insurance, assurance, coverage, cover, protection, plan, benefit, policy ...)';
  end if;
  if public.ws_personal_context_hit(v_norm) then raise exception 'term refused: personal wording (first person or narrative) is not a product name'; end if;
  if exists (select 1 from unnest(public.ws_sensitive_hits(v_norm) || public.ws_sensitive_hits(v_term)) h where h <> 'health') then
    raise exception 'term refused: it contains wording this system never allows (identity, banking, credit, income)';
  end if;
  v_scope := case when p_ws is not null then 'workspace/' || p_ws else 'vertical/' || p_vertical end;
  select count(*) into n_active from public.ws_approved_terms where removed_at is null and coalesce(workspace_id::text, 'v:' || vertical) = coalesce(p_ws::text, 'v:' || p_vertical);
  if n_active >= 100 then raise exception 'term refused: at most 100 active terms per scope'; end if;
  if exists (select 1 from public.ws_approved_terms where removed_at is null and coalesce(workspace_id::text, 'v:' || vertical) = coalesce(p_ws::text, 'v:' || p_vertical) and kind = p_kind and term_norm = v_norm) then
    raise exception 'term already approved in this scope';
  end if;
  insert into public.ws_approved_terms (workspace_id, vertical, kind, term, term_norm) values (p_ws, p_vertical, p_kind, v_term, v_norm) returning id into v_id;
  insert into public.audit_log (actor, action, target, detail) values ('owner', 'ws_approved_term_added', v_scope, jsonb_build_object('term_id', v_id, 'kind', p_kind, 'words', v_words));
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
    values ('owner', 'ws_approved_term_removed', case when t.workspace_id is not null then 'workspace/' || t.workspace_id else 'vertical/' || t.vertical end, jsonb_build_object('term_id', p_term_id, 'kind', t.kind));
end $$;

-- 8. guards, replaced. Same exclusions and messages as before; the classifier decides. Waiver only on non-person tables.
create or replace function public.ws_guard() returns trigger
language plpgsql set search_path to 'public' as $$
declare k text; v text; res jsonb; allv text := ''; j jsonb := to_jsonb(new); v_ws uuid;
begin
  v_ws := case when tg_table_name = any (array['ws_campaigns', 'ws_ledger']) then nullif(j ->> 'workspace_id', '')::uuid else null end;
  -- a value split across columns (name / phone / note) is caught by also scanning every scanned column joined together
  for k, v in select key, value from jsonb_each_text(j - array['id', 'workspace_id', 'campaign_id', 'created_at', 'status', 'stage', 'amount_cents', 'monthly_budget_cents']) loop
    allv := allv || ' ' || coalesce(v, '');
  end loop;
  res := public.ws_classify_text(allv, v_ws);
  if not (res ->> 'allowed')::boolean then
    raise exception 'Sensitive data refused in % (%). Applications, banking, credit, ID and sensitive financial data must never be stored here.', tg_table_name, array_to_string(array(select jsonb_array_elements_text(res -> 'reasons')), ', ') using errcode = 'P0001';
  end if;
  for k, v in select key, value from jsonb_each_text(j - array['id', 'workspace_id', 'campaign_id', 'created_at', 'status', 'stage', 'amount_cents', 'monthly_budget_cents']) loop
    res := public.ws_classify_text(v, v_ws);
    if not (res ->> 'allowed')::boolean then
      raise exception 'Sensitive data refused in %.% (%). Applications, banking, credit, ID and sensitive financial data must never be stored here.', tg_table_name, k, array_to_string(array(select jsonb_array_elements_text(res -> 'reasons')), ', ')
        using errcode = 'P0001';
    end if;
  end loop;
  return new;
end $$;

create or replace function public.ffm_guard() returns trigger
language plpgsql set search_path to 'public' as $$
declare k text; v text; res jsonb; allv text := ''; j jsonb := to_jsonb(new); v_ws uuid;
begin
  v_ws := case when tg_table_name = any (array['ffm_ad_sets', 'ffm_creatives', 'ffm_approvals', 'ffm_onboarding_items']) then nullif(j ->> 'workspace_id', '')::uuid else null end;
  for k, v in select e.key, e.value #>> '{}' from jsonb_each(j) e
              where jsonb_typeof(e.value) = 'string'
                and not exists (select 1 from pg_attribute a where a.attrelid = tg_relid and a.attname = e.key and a.attnum > 0 and not a.attisdropped
                                  and a.atttypid in ('uuid'::regtype, 'timestamptz'::regtype)) loop
    res := public.ws_classify_text(v, v_ws);
    if not (res ->> 'allowed')::boolean then
      raise exception 'Sensitive data refused in %.% (%). Applications, banking, credit, ID and sensitive financial data must never be stored here.', tg_table_name, k, array_to_string(array(select jsonb_array_elements_text(res -> 'reasons')), ', ') using errcode = 'P0001';
    end if;
    allv := allv || ' ' || v;
  end loop;
  res := public.ws_classify_text(allv, v_ws);   -- a value split across columns
  if not (res ->> 'allowed')::boolean then
    raise exception 'Sensitive data refused in % (%). Applications, banking, credit, ID and sensitive financial data must never be stored here.', tg_table_name, array_to_string(array(select jsonb_array_elements_text(res -> 'reasons')), ', ') using errcode = 'P0001';
  end if;
  return new;
end $$;

-- 9. grants: service_role only. The two term-management functions additionally require the owner (ffm_require_owner refuses the bot).
revoke all on function public.ws_terms_immutable() from public, anon, authenticated;
revoke all on function public.ws_fold_text(text) from public, anon, authenticated;
revoke all on function public.ws_leet_text(text, integer) from public, anon, authenticated;
revoke all on function public.ws_health_extra_hit(text) from public, anon, authenticated;
revoke all on function public.ws_personal_context_hit(text) from public, anon, authenticated;
revoke all on function public.ws_identifier_hit(text) from public, anon, authenticated;
revoke all on function public.ws_classify_text(text, uuid) from public, anon, authenticated;
revoke all on function public.ws_add_approved_term(uuid, text, text, text) from public, anon, authenticated;
revoke all on function public.ws_remove_approved_term(uuid) from public, anon, authenticated;
revoke all on function public.ws_guard() from public, anon, authenticated;
revoke all on function public.ffm_guard() from public, anon, authenticated;
grant execute on function public.ws_terms_immutable() to service_role;
grant execute on function public.ws_fold_text(text) to service_role;
grant execute on function public.ws_leet_text(text, integer) to service_role;
grant execute on function public.ws_health_extra_hit(text) to service_role;
grant execute on function public.ws_personal_context_hit(text) to service_role;
grant execute on function public.ws_identifier_hit(text) to service_role;
grant execute on function public.ws_classify_text(text, uuid) to service_role;
grant execute on function public.ws_add_approved_term(uuid, text, text, text) to service_role;
grant execute on function public.ws_remove_approved_term(uuid) to service_role;
grant execute on function public.ws_guard() to service_role;
grant execute on function public.ffm_guard() to service_role;
