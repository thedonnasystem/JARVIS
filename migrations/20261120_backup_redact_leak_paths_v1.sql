-- Off-site backup, SECOND PROTECTIVE LAYER: redaction of the four known client-text leak paths (and their derived copies) INSIDE backup_snapshot().
-- Why: the system copies client text into EXPORTED tables (audit_log.detail.reason from record_lead_reply / mark_do_not_contact, ledger.note from setter payouts,
-- tasks.result and agent_runs.summary from agent output; see DATA_CLASSIFICATION_AND_BACKUP_POLICY.md section 2). Source-level prevention is in
-- 20261120_leak_source_prevention_v1; THIS migration is the export-level net for everything that is already stored or arrives by another route.
-- What it adds (all read-only, no table is changed, service role only):
--   backup_fold_text / backup_unescape_text   normalisation: NFKC, zero-width and combining marks out, Cyrillic/Greek look-alikes and non-Latin digits to ASCII, then percent / HTML-entity / \u / \x decoding
--   backup_redaction_context()                the CLIENT NAMES known at export time (leads, setters, ws_leads, client workspaces, setter event clients) compiled into a matcher. Contains client data: never returned by the snapshot.
--   backup_redact_patterns / _probe_encoded   emails (plain, spaced, "[at]/[dot]", French arobase/point), phone numbers (all separator styles, +1, French), SIN-like and long digit runs, spelled-out digits,
--                                             URLs with personal paths, known client names (case/accent-insensitive), and base64/hex blobs that decode to any of those
--   backup_redact_text(text, ctx, max, mode)   STRICT mode (the four leak paths): FAILS CLOSED. The whole field becomes '[redacted:uncertain]' when the sensitive-data detector (ws_sensitive_hits) flags it,
--                                             when it is longer than max, when decoding does not settle, when a known name survives only in letter-spaced / ROT13 form, or on any internal error.
--                                             LIGHT mode (derived copies): patterns and known names only, never blanks a whole field. A field in which nothing is found is returned UNCHANGED (accents, case and all).
--   backup_redaction_spec()                   which columns are redacted and how (reviewed list); backup_redact_row() applies it to one exported row
--   backup_snapshot(skip)                     replaced (same name, signature, grants, policy output): exported rows pass through backup_redact_row(); the response says what was redacted ('redaction').
-- Financial records are untouched: only the listed text/json columns change; amounts, ids, statuses, counts, action codes and timestamps are never altered.
-- LIMITS (stated plainly): pattern + known-name based, not a classifier. It cannot recognise a NAME it has not been told about (a person who is not in leads/setters/ws_leads), misspellings, leetspeak, reversed
-- or ROT13 names (only flagged when they match a known name), languages whose digits are not mapped, base32/other encodings. The sensitive-data detector blanks the whole field on a topic word (health, income, ...).
create or replace function public.backup_fold_text(p text) returns text
language plpgsql immutable set search_path to 'pg_catalog', 'public' as $$
declare t text;
begin
  if p is null then return null; end if;
  t := p;
  begin t := normalize(t, NFKC); exception when others then null; end;
  begin t := normalize(t, NFD); exception when others then null; end;
  t := regexp_replace(t, '[­͏؜ᅟᅠ឴឵᠋-᠎​-‏‪-‮⁠-⁯ㅤ︀-️﻿ﾠ-]', '', 'g');
  t := regexp_replace(t, '[̀-ͯ᪰-᫿᷀-᷿⃐-⃿︠-︯]', '', 'g');
  t := translate(t, 'аеорсхуіјѕһԁԛԝкмтнвѵɡӏոսАВЕКМНОРСТХУІЈЅҮѠԌԚԜᎪᏟαονρτικυχεγημωςβΑΒΕΖΗΙΚΜΝΟΡΤΥΧϹͿàÀáÁâÂãÃäÄåÅāĀăĂąĄǎǍǟǞǡǠǻǺȁȀȃȂȧȦçÇćĆĉĈċĊčČďĎđĐèÈéÉêÊëËēĒĕĔėĖęĘěĚȅȄȇȆȩȨĝĜğĞġĠģĢǧǦĥĤħĦìÌíÍîÎïÏĩĨīĪĭĬįĮıǐǏȉȈȋȊĵĴķĶĺĹļĻľĽŀĿłŁñÑńŃņŅňŇŉòÒóÓôÔõÕöÖøØōŌŏŎőŐǒǑǫǪȍȌȏȎȯȮŕŔŗŖřŘȑȐȓȒśŚŝŜşŞšŠșȘţŢťŤŧŦțȚùÙúÚûÛüÜũŨūŪŭŬůŮűŰųŲǔǓȕȔȗȖŵŴýÝÿŸŷŶźŹżŻžŽßœŒæÆðÐþÞĳ٠١٢٣٤٥٦٧٨٩۰۱۲۳۴۵۶۷۸۹०१२३४५६७८९০১২৩৪৫৬৭৮৯੦੧੨੩੪੫੬੭੮੯૦૧૨૩૪૫૬૭૮૯୦୧୨୩୪୫୬୭୮୯௦௧௨௩௪௫௬௭௮௯౦౧౨౩౪౫౬౭౮౯೦೧೨೩೪೫೬೭೮೯൦൧൨൩൪൫൬൭൮൯๐๑๒๓๔๕๖๗๘๙໐໑໒໓໔໕໖໗໘໙༠༡༢༣༤༥༦༧༨༩၀၁၂၃၄၅၆၇၈၉០១២៣៤៥៦៧៨៩᠐᠑᠒᠓᠔᠕᠖᠗᠘᠙', 'aeopcxyijshdqwkmthbvglnuABEKMHOPCTXYIJSYWGQWACaovptikuxeynuwsbABEZHIKMNOPTYXCJaAaAaAaAaAaAaAaAaAaAaAaAaAaAaAaAcCcCcCcCcCdDdDeEeEeEeEeEeEeEeEeEeEeEeEgGgGgGgGgGhHhHiIiIiIiIiIiIiIiIiiIiIiIjJkKlLlLlLlLlLnNnNnNnNnoOoOoOoOoOoOoOoOoOoOoOoOoOoOrRrRrRrRrRsSsSsSsSsStTtTtTtTuUuUuUuUuUuUuUuUuUuUuUuUuUwWyYyYyYzZzZzZsoOaAdDpPi01234567890123456789012345678901234567890123456789012345678901234567890123456789012345678901234567890123456789012345678901234567890123456789012345678901234567890123456789');
  return t;
end $$;

create or replace function public.backup_unescape_text(p text) returns text
language plpgsql immutable set search_path to 'pg_catalog', 'public' as $$
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

-- the client names that exist in the database RIGHT NOW. Contains client data: service role only, and it is never part of a snapshot.
create or replace function public.backup_redaction_context() returns jsonb
language plpgsql stable security definer set search_path to 'pg_catalog', 'public' as $$
declare
  src text; tbl text; col text; kind text; v text; f text; tok text[]; w text; d text;
  stop text[] := array['the','and','for','inc','ltd','llc','corp','company','group','services','service','solutions','ottawa','canada','ontario','toronto','barrhaven','kanata','home','homes','real','estate','realty',
                       'mortgage','mortgages','insurance','plumbing','heating','cooling','electric','electrical','roofing','construction','contracting','contractors','cleaning','renovation','renovations','design',
                       'studio','law','legal','dental','care','auto','detailing','energy','les','des','pour','avec','management','consulting','marketing','agency','store','shop','ltee','cie','enr','com','www','http','https',
                       'setter','setters','lead','leads','payout','payouts','deal','deals','close','closed','owner','client','clients','public','task','tasks','note','notes','salon','salons','flood','test','demo','sample'];   -- operating vocabulary: a lead called "Setter" must not blank the word everywhere (the full name is still redacted as a phrase)
  phrases text[] := '{}'; parts text[] := '{}'; squashed text[] := '{}'; phones text[] := '{}'; alts text[]; nre text;
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
      continue when cardinality(tok) = 1 and length(tok[1]) < 3;
      phrases := phrases || array_to_string(array(select regexp_replace(x, '([\\^$.|?*+()\[\]{}])', '\\\1', 'g') from unnest(tok) x), '[^a-z0-9]{0,3}');
      if length(array_to_string(tok, '')) >= 6 then squashed := squashed || regexp_replace(array_to_string(tok, ''), '[^a-z0-9]', '', 'g'); end if;
      if kind <> 'e' then
        foreach w in array tok loop
          if length(w) >= 3 and not (w = any (stop)) and w !~ '^[0-9]+$' then
            parts := parts || regexp_replace(w, '([\\^$.|?*+()\[\]{}])', '\\\1', 'g');
            if length(w) >= 5 then squashed := squashed || regexp_replace(w, '[^a-z0-9]', '', 'g'); end if;
          end if;
        end loop;
      end if;
    end loop;
  end loop;
  alts := array(select distinct x from unnest(phrases || parts) x where x <> '');
  if cardinality(alts) > 0 then
    nre := '(?<![a-z0-9])(?:' || array_to_string(array(select x from unnest(alts) x order by length(x) desc, x), '|') || ')(?![a-z0-9])';
  else nre := ''; end if;
  return jsonb_build_object('v', 1, 'name_re', nre, 'squashed', to_jsonb(array(select distinct x from unnest(squashed) x where length(x) >= 5)),
                            'phones', to_jsonb(array(select distinct x from unnest(phones) x)), 'n_terms', cardinality(alts));
end $$;

create or replace function public.backup_redact_patterns(p_t text, p_ctx jsonb) returns text
language plpgsql stable set search_path to 'pg_catalog', 'public' as $$
declare t text := p_t; m text; d text; nre text := coalesce(p_ctx ->> 'name_re', '');
begin
  if t is null then return null; end if;
  -- URLs with a personal path / query / known name; ordinary business URLs are kept (mission evidence checks need them)
  for m in select x from (select distinct (regexp_matches(t, '((?:https?://|www\.)[^\s<>"'')\]]+)', 'gi'))[1] x) q order by length(x) desc loop
    if m ~* '(linkedin\.com/(?:in|pub|profile|sales/people)/|facebook\.com/(?!pages/|groups/|events/|business/|marketplace/)[^/?#]+|fb\.com/|instagram\.com/|twitter\.com/|x\.com/|tiktok\.com/@|snapchat\.com/add|youtube\.com/(?:@|user/|c/|channel/)|github\.com/[^/?#]+|/(?:~|@)[^/?#]+|/(?:profile|profiles|people|person|user|users|u|member|members|staff|team|employee|contact|about-us/team)/[^/?#]+|[?&](?:email|e-mail|mail|phone|tel|mobile|name|first|last|fname|lname|user|username|uid|contact)=|[0-9]{7,})'
       or (nre <> '' and m ~* nre) then
      t := replace(t, m, '[redacted:url]');
    end if;
  end loop;
  -- obfuscated and plain emails
  t := regexp_replace(t, '[a-z0-9._%+''-]+[ \t]*[\[({<][ \t]*(?:at|arobase|@)[ \t]*[\])}>][ \t]*[a-z0-9-]+(?:[ \t]*(?:[\[({<][ \t]*(?:dot|point|\.)[ \t]*[\])}>]|\.)[ \t]*[a-z0-9-]+)+', '[redacted:email]', 'gi');
  t := regexp_replace(t, '[a-z0-9._%+''-]+[ \t]*@[ \t]*[a-z0-9-]+(?:[ \t]*(?:[\[({<][ \t]*(?:dot|point)[ \t]*[\])}>]|[ \t]+(?:dot|point)[ \t]+)[ \t]*[a-z0-9-]+)+', '[redacted:email]', 'gi');
  t := regexp_replace(t, '[a-z0-9._%+''-]{2,}[ \t]+(?:at|arobase)[ \t]+[a-z0-9-]+(?:[ \t]+(?:dot|point)[ \t]+[a-z0-9-]+)+', '[redacted:email]', 'gi');
  t := regexp_replace(t, '[a-z0-9._%+''-]{2,}[ \t]+(?:at|arobase)[ \t]+[a-z][a-z0-9-]*(?:\.[a-z0-9-]+)*\.[a-z]{2,}', '[redacted:email]', 'gi');
  t := regexp_replace(t, '[a-z0-9._%+''-]+ ?@ ?[a-z0-9-]+(?:\.[a-z0-9-]+)+', '[redacted:email]', 'gi');
  t := regexp_replace(t, '(?<![a-z0-9._@])@[a-z0-9_.]{3,}', '[redacted:handle]', 'gi');
  -- phone numbers: NANP-shaped with one repeated separator of any kind, then generic digit groups
  t := regexp_replace(t, '(?<![0-9])\(?[0-9]{3}\)?([^a-z0-9\s])[0-9]{3}\1[0-9]{4}(?![0-9])', '[redacted:phone]', 'g');
  for m in select x from (select distinct (regexp_matches(t, '([+(]?[0-9][0-9 \t.()/–—\-]{5,}[0-9])', 'g'))[1] x) q order by length(x) desc loop
    d := regexp_replace(m, '[^0-9]', '', 'g');
    if length(d) >= 9 or (left(m, 1) = '+' and length(d) >= 7) or (length(d) = 7 and m ~ '^[0-9]{3}[ .\-][0-9]{4}$') then t := replace(t, m, '[redacted:phone]'); end if;
  end loop;
  t := regexp_replace(t, '(?<![0-9])[0-9]{7,}(?![0-9])', '[redacted:id]', 'g');      -- any other run of seven or more digits (account-like numbers, local phone numbers without punctuation)
  -- spelled-out digits (English and French) and single digits in a run of seven or more
  t := regexp_replace(t, '(?<![a-z0-9])(?:(?:zero|oh|one|two|three|four|five|six|seven|eight|nine|un|deux|trois|quatre|cinq|sept|huit|neuf|[0-9])(?:[ \t,.\-]+|$)){7,}', '[redacted:phone] ', 'gi');
  -- client names known to the database
  if nre <> '' then t := regexp_replace(t, nre, '[redacted:name]', 'gi'); end if;
  return t;
end $$;

create or replace function public.backup_probe_encoded(p_t text, p_ctx jsonb, p_depth integer default 0) returns text
language plpgsql stable set search_path to 'pg_catalog', 'public' as $$
declare t text := p_t; m text; b text; dec text; f text; padded text;
begin
  if t is null or p_depth > 2 then return t; end if;
  -- hex-encoded text
  for m in select x from (select distinct (regexp_matches(t, '((?:0x)?(?:[0-9a-fA-F]{2}){8,})', 'g'))[1] x) q order by length(x) desc loop
    b := regexp_replace(m, '^0x', '');
    begin dec := convert_from(decode(b, 'hex'), 'UTF8'); exception when others then continue; end;
    continue when dec !~ '^[\x20-\x7e\t\r\n -￿]{4,}$';
    f := public.backup_fold_text(dec);
    if public.backup_redact_patterns(f, p_ctx) <> f or public.backup_probe_encoded(f, p_ctx, p_depth + 1) <> f or cardinality(public.ws_sensitive_hits(f)) > 0 then t := replace(t, m, '[redacted:encoded]'); end if;
  end loop;
  -- base64 / base64url-encoded text
  for m in select x from (select distinct (regexp_matches(t, '([A-Za-z0-9+/_-]{16,}={0,2})', 'g'))[1] x) q order by length(x) desc loop
    b := translate(rtrim(m, '='), '-_', '+/');
    continue when length(b) % 4 = 1;
    padded := b || repeat('=', (4 - length(b) % 4) % 4);
    begin dec := convert_from(decode(padded, 'base64'), 'UTF8'); exception when others then continue; end;
    continue when dec !~ '^[\x20-\x7e\t\r\n -￿]{4,}$';
    f := public.backup_fold_text(dec);
    if public.backup_redact_patterns(f, p_ctx) <> f or public.backup_probe_encoded(f, p_ctx, p_depth + 1) <> f or cardinality(public.ws_sensitive_hits(f)) > 0 then t := replace(t, m, '[redacted:encoded]'); end if;
  end loop;
  return t;
end $$;

create or replace function public.backup_redact_text(p text, p_ctx jsonb default null, p_max integer default 20000, p_mode text default 'strict') returns text
language plpgsql stable set search_path to 'pg_catalog', 'public' as $$
declare
  u constant text := '[redacted:uncertain]';
  ctx jsonb; t text; t1 text; r text; nxt text; m text; i int; prot text[] := '{}'; sq text; sq2 text; s text; dg text; rt text; nre text;
  is_strict boolean := (p_mode = 'strict');
  email_re constant text := '[a-z0-9._%+''-]{2,}@[a-z0-9-]{2,}(?:\.[a-z0-9-]{2,})+';
  obf_re constant text := '[a-z0-9._%+''-]{2,}[\[({<](?:at|arobase|@)[\])}>][a-z0-9-]+(?:(?:[\[({<](?:dot|point|\.)[\])}>]|\.)[a-z0-9-]+)+';
begin
  if p is null then return null; end if;
  if p_mode not in ('strict', 'light') then return u; end if;
  if p_max is not null and length(p) > p_max then return u; end if;
  begin
    ctx := coalesce(p_ctx, public.backup_redaction_context());
    nre := coalesce(ctx ->> 'name_re', '');
    t := public.backup_fold_text(p);
    for i in 1..4 loop
      nxt := public.backup_fold_text(public.backup_unescape_text(t));
      exit when nxt = t;
      t := nxt;
    end loop;
    if is_strict and public.backup_unescape_text(t) <> t then return u; end if;        -- still decodable after four rounds: do not vouch
    t1 := t;
    -- a short lower-case code (action codes, statuses, ids such as 'do_not_contact') is kept as is, unless it is or contains a known name
    if is_strict and length(t) <= 80 and t ~ '^[a-z][a-z0-9]*(?:[_:./-][a-z0-9]+)+$' and t !~ '[0-9]{7}' and (nre = '' or t !~* nre) then return p; end if;
    -- the detector flags the whole field. Its three digit-shaped categories (sin/card/account-like) join every number in the text into one string and so flag ordinary prose with amounts and dates;
    -- those shapes are handled by this redactor's own digit rules instead (runs of 7+ digits, grouped numbers of 9+ digits, SIN/phone shapes). EVERY OTHER detector category blanks the field.
    if is_strict and exists (select 1 from unnest(public.ws_sensitive_hits(p) || public.ws_sensitive_hits(t)) h where h not in ('sin_like_number', 'card_like_number', 'account_like_number')) then return u; end if;
    -- ids and timestamps are protected from the digit rules
    for m in select x from (select distinct (regexp_matches(t, '([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}|(?<![0-9-])[0-9]{4}-[0-9]{2}-[0-9]{2}(?![0-9])(?:[t ][0-9]{2}:[0-9]{2}(?::[0-9]{2}(?:[.,][0-9]+)?)?(?:z|[+-][0-9]{2}(?::?[0-9]{2})?)?)?)', 'gi'))[1] x) q order by length(x) desc loop
      prot := prot || m;
      if cardinality(prot) >= 6000 then return u; end if;
      t := replace(t, m, chr(57343 + cardinality(prot)));
    end loop;
    t := public.backup_probe_encoded(t, ctx, 0);
    for m in select x from (select distinct (regexp_matches(t, '([0-9a-f]{32,})', 'gi'))[1] x) q order by length(x) desc loop      -- hashes (hex that is not readable text)
      continue when m !~* '[a-f]';
      prot := prot || m;
      if cardinality(prot) >= 6000 then return u; end if;
      t := replace(t, m, chr(57343 + cardinality(prot)));
    end loop;
    r := public.backup_redact_patterns(t, ctx);
    for i in reverse cardinality(prot)..1 loop
      r := replace(r, chr(57343 + i), prot[i]);
    end loop;
    if is_strict then
      sq := lower(regexp_replace(r, '[^a-zA-Z0-9]', '', 'g'));
      for s in select jsonb_array_elements_text(coalesce(ctx -> 'squashed', '[]'::jsonb)) loop
        if position(s in sq) > 0 then return u; end if;                                  -- a known name survives only in letter-spaced / split form
      end loop;
      dg := regexp_replace(r, '[^0-9]', '', 'g');
      for s in select jsonb_array_elements_text(coalesce(ctx -> 'phones', '[]'::jsonb)) loop
        if length(s) >= 7 and position(s in dg) > 0 then return u; end if;              -- a known phone number survives in some spaced form
      end loop;
      sq2 := regexp_replace(r, '[ \t\r\n]', '', 'g');
      -- spaced-out, bracket-obfuscated or reversed email. Looked for in a window around each '@' / bracketed "at" only: running the pattern over the whole space-stripped text is quadratic.
      for m in select (regexp_matches(sq2, '(.{0,80}@.{0,160})', 'g'))[1] loop if m ~* email_re then return u; end if; end loop;
      for m in select (regexp_matches(sq2, '(.{0,80}[\[({<](?:at|arobase|@)[\])}>].{0,160})', 'gi'))[1] loop if m ~* obf_re then return u; end if; end loop;
      if position('@' in r) > 0 and reverse(r) ~* email_re then return u; end if;
      rt := translate(r, 'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ', 'nopqrstuvwxyzabcdefghijklmNOPQRSTUVWXYZABCDEFGHIJKLM');
      if rt ~* email_re then return u; end if;                       -- ROT13 email
      sq2 := lower(regexp_replace(rt, '[^a-zA-Z0-9]', '', 'g'));
      for s in select jsonb_array_elements_text(coalesce(ctx -> 'squashed', '[]'::jsonb)) loop
        if position(s in sq2) > 0 and position(s in sq) = 0 then return u; end if;   -- ROT13 of a known name
      end loop;
    end if;
    if r = t1 then return p; end if;                                                      -- nothing found: the original text, unchanged
    return r;
  exception when others then
    return u;                                                                              -- any failure: fail closed
  end;
end $$;

create or replace function public.backup_redact_json(j jsonb, p_ctx jsonb, p_max integer default 500, p_mode text default 'strict') returns jsonb
language plpgsql stable set search_path to 'pg_catalog', 'public' as $$
begin
  if j is null then return null; end if;
  case jsonb_typeof(j)
    when 'string' then return to_jsonb(public.backup_redact_text(j #>> '{}', p_ctx, p_max, p_mode));
    when 'object' then return coalesce((select jsonb_object_agg(public.backup_redact_text(e.k, p_ctx, null, 'light'), public.backup_redact_json(e.v, p_ctx, p_max, p_mode)) from jsonb_each(j) e (k, v)), '{}'::jsonb);
    when 'array' then return coalesce((select jsonb_agg(public.backup_redact_json(a.v, p_ctx, p_max, p_mode) order by a.ord) from jsonb_array_elements(j) with ordinality a (v, ord)), '[]'::jsonb);
    else return j;
  end case;
end $$;

-- the reviewed list of redacted columns. strict = fail closed (the four named leak paths and the escalation copy of task output); light = derived copies, patterns and known names only.
create or replace function public.backup_redaction_spec() returns table (table_name text, column_name text, kind text, mode text, max_len integer)
language sql immutable set search_path to 'pg_catalog', 'public' as $$
  select * from (values
    ('audit_log', 'detail', 'json', 'strict', 500), ('ledger', 'note', 'text', 'strict', 500), ('tasks', 'result', 'text', 'strict', 20000), ('agent_runs', 'summary', 'text', 'strict', 4000),
    ('escalations', 'summary', 'text', 'strict', 4000),
    ('tasks', 'title', 'text', 'light', null), ('tasks', 'detail', 'text', 'light', null), ('escalations', 'evidence', 'json', 'light', null), ('memory', 'content', 'text', 'light', null),
    ('owner_messages', 'body', 'text', 'light', null), ('human_handoffs', 'task', 'text', 'light', null), ('human_handoffs', 'why_human', 'text', 'light', null),
    ('missions', 'result', 'text', 'light', null)
  ) v (table_name, column_name, kind, mode, max_len)
$$;

create or replace function public.backup_redact_row(p_table text, p_row jsonb, p_ctx jsonb) returns jsonb
language plpgsql stable set search_path to 'pg_catalog', 'public' as $$
declare s record; v jsonb := p_row;
begin
  for s in select * from public.backup_redaction_spec() x where x.table_name = p_table loop
    if v ? s.column_name and jsonb_typeof(v -> s.column_name) <> 'null' then
      if s.kind = 'json' then v := jsonb_set(v, array[s.column_name], public.backup_redact_json(v -> s.column_name, p_ctx, s.max_len, s.mode));
      else v := jsonb_set(v, array[s.column_name], to_jsonb(public.backup_redact_text(v ->> s.column_name, p_ctx, s.max_len, s.mode)));
      end if;
    end if;
  end loop;
  return v;
end $$;

-- same name, signature, volatility and grants as 20261119_backup_exclude_client_pii_v1: one-statement consistent snapshot of the EXPORTED tables + schema + policy.
-- NEW: every row of a table in backup_redaction_spec() passes through backup_redact_row(); the response lists the spec under 'redaction' (never the client names).
create or replace function public.backup_snapshot(skip text[] default array['push_config', 'push_subscriptions']) returns jsonb
language plpgsql stable security definer set search_path to 'pg_catalog', 'public' as $$
declare q text; res jsonb; pol jsonb := public.backup_export_policy(); ctx jsonb := public.backup_redaction_context();
begin
  select 'select jsonb_build_object(''data'', (select coalesce(jsonb_object_agg(k, v), ''{}''::jsonb) from (' ||
         string_agg(format('select %L::text as k, (select coalesce(jsonb_agg(%s), ''[]''::jsonb) from public.%I t) as v', c.relname,
                           case when c.relname in (select s.table_name from public.backup_redaction_spec() s) then format('public.backup_redact_row(%L, to_jsonb(t), $1)', c.relname) else 'to_jsonb(t)' end,
                           c.relname), ' union all ' order by c.relname) ||
         ') s), ''schema'', public.backup_schema(), ''policy'', ' || quote_literal(pol::text) || '::jsonb, ''method'', ''single statement snapshot'')'
    into q
    from pg_class c
   where c.relnamespace = 'public'::regnamespace and c.relkind in ('r', 'p') and c.relname <> all (skip)
     and c.relname in (select jsonb_array_elements_text(pol -> 'exported'));
  if q is null then raise exception 'backup refused: the export policy lists no exportable table'; end if;
  execute q into res using ctx;
  return res || jsonb_build_object('redaction', jsonb_build_object('version', 1, 'known_client_terms', ctx -> 'n_terms',
                                   'spec', (select jsonb_agg(to_jsonb(s)) from public.backup_redaction_spec() s)));
end $$;

revoke all on function public.backup_fold_text(text) from public, anon, authenticated;
revoke all on function public.backup_unescape_text(text) from public, anon, authenticated;
revoke all on function public.backup_redaction_context() from public, anon, authenticated;
revoke all on function public.backup_redact_patterns(text, jsonb) from public, anon, authenticated;
revoke all on function public.backup_probe_encoded(text, jsonb, integer) from public, anon, authenticated;
revoke all on function public.backup_redact_text(text, jsonb, integer, text) from public, anon, authenticated;
revoke all on function public.backup_redact_json(jsonb, jsonb, integer, text) from public, anon, authenticated;
revoke all on function public.backup_redaction_spec() from public, anon, authenticated;
revoke all on function public.backup_redact_row(text, jsonb, jsonb) from public, anon, authenticated;
revoke all on function public.backup_snapshot(text[]) from public, anon, authenticated;
grant execute on function public.backup_fold_text(text) to service_role;
grant execute on function public.backup_unescape_text(text) to service_role;
grant execute on function public.backup_redaction_context() to service_role;
grant execute on function public.backup_redact_patterns(text, jsonb) to service_role;
grant execute on function public.backup_probe_encoded(text, jsonb, integer) to service_role;
grant execute on function public.backup_redact_text(text, jsonb, integer, text) to service_role;
grant execute on function public.backup_redact_json(jsonb, jsonb, integer, text) to service_role;
grant execute on function public.backup_redaction_spec() to service_role;
grant execute on function public.backup_redact_row(text, jsonb, jsonb) to service_role;
grant execute on function public.backup_snapshot(text[]) to service_role;
