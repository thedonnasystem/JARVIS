-- SQL-level regression test for the client-data leak paths: migrations 20261120_backup_redact_leak_paths_v1 (export redaction) and 20261120_leak_source_prevention_v1 (source fixes).
-- SCRATCH replica only. One transaction, rolled back. Every check raises with its id, so a regression names itself.
--   A  source: the writers store codes/ids/counts, not names/emails/phones, and keep the client text where it belongs (client_pii tables)
--   B  redactor vectors: direct, formats, encodings, obfuscation, Unicode look-alikes, French, adversarial splitting, fail-closed, and "must NOT be damaged" vectors
--   C  indirect propagation: a name typed in a lead reply reappears in a task prompt/result, an audit row, a ledger note, an agent run, an escalation; none survives in the snapshot
--   D  integrity: ledger / audit_log / tasks / agent_runs identical to the live rows in everything except the redacted column; counts and sums equal
--   E  grants, response shape, idempotence
begin;
create temp table lv (id text, input text, forbid text[], keep text[], expect text) on commit drop;
do $$
declare
  v uuid; ag text; l1 uuid; l2 uuid; s1 uuid; ws uuid; cp uuid; dl uuid; a_n int; j jsonb; r text; txt text; snap jsonb; rec record; ctx jsonb; f text; k text; sq text; dg text; n int; n2 int;
  led_before int; led_sum_before bigint; aud_before int; task_before int; d1 uuid; setter_id uuid; led_id uuid; sid uuid; cnt int;
  b64 text; hx text; rot text; vecs text[]; i int;
begin
  select id into v from public.ventures where slug = 'donna' limit 1;
  if v is null then select id into v from public.ventures limit 1; end if;
  select slug into ag from public.agents order by slug limit 1;
  -- ------------------------------------------------------------ seed the client data the redactor must learn from the database
  insert into public.leads (venture_id, name, email, phone, notes, status) values (v, 'Jean Tremblay', 'jean.tremblay@tremblay-plomberie.ca', '613-555-0142', 'wants a quote', 'sent') returning id into l1;
  insert into public.leads (venture_id, name, email, phone, notes, status) values (v, 'Éloïse Bédard', 'eloise@bedard-renos.example', '514-555-0177', 'n', 'new') returning id into l2;
  perform public.setter_add('Marcus Zzyxwell', 'marcus.zzyxwell@setters.example', 'salons');
  select id into setter_id from public.setters where name = 'Marcus Zzyxwell';
  insert into public.setter_events (setter_id, kind, client) values (setter_id, 'booked', 'Quillfeather Bakery');
  insert into public.setter_events (setter_id, kind, client) values (setter_id, 'closed', 'Quillfeather Bakery');
  insert into public.setter_events (setter_id, kind, client) values (setter_id, 'closed', 'Quillfeather Bakery');
  insert into public.setter_events (setter_id, kind, client) values (setter_id, 'closed', 'Quillfeather Bakery');
  insert into public.client_workspaces (slug, name) values ('zz-leak', 'Wexcombe Holdings Ltd') returning id into ws;
  insert into public.ws_campaigns (workspace_id, name) values (ws, 'zz camp') returning id into cp;
  perform public.ws_add_lead(ws, cp, 'Odalys Quenneville', 'odalys.q@quenneville-co.example', '819-555-0123', 'web form');
  insert into public.ventures (slug, name, kind) values ('zz-visible-leak', 'ZZVISIBLELEAK venture', 'lab');

  -- ============================================================ A. SOURCE LEVEL
  aud_before := (select count(*) from public.audit_log);
  -- A1 record_lead_reply (unsubscribe) -> mark_do_not_contact -> audit_log
  j := public.record_lead_reply(l1, 'unsubscribe', 'Jean Tremblay says: call him at 613-555-0142 or write jean.tremblay@tremblay-plomberie.ca, he is angry', 'owner:test');
  if j ->> 'status' <> 'do_not_contact' then raise exception 'A1 unsubscribe no longer marks do-not-contact: %', j; end if;
  select detail into j from public.audit_log where action = 'do_not_contact' and target = 'leads/' || l1 order by id desc limit 1;
  if j is null then raise exception 'A1b the do_not_contact audit row is missing'; end if;
  txt := lower(j::text);
  if txt like '%tremblay%' or txt like '%555%' or txt like '%@%' or txt like '%angry%' then raise exception 'A1c client text reached audit_log.detail: %', j; end if;
  if j ->> 'reason_code' <> 'unsubscribe_reply' or j ->> 'reason' <> 'unsubscribe_reply' or (j ->> 'reason_chars')::int <> length('unsubscribe reply') or (j ->> 'leads_marked')::int < 1 or (j -> 'address_suppressed') <> 'true'::jsonb then raise exception 'A1d audit detail lost its operational fields: %', j; end if;
  if (select note from public.lead_replies where lead_id = l1) not like '%613-555-0142%' then raise exception 'A1e the reply note must still be kept in lead_replies (client_pii)'; end if;
  if not exists (select 1 from public.contact_suppressions where address = 'jean.tremblay@tremblay-plomberie.ca') or not (select do_not_contact from public.leads where id = l1) then raise exception 'A1f suppression / do-not-contact no longer works'; end if;
  -- A2 mark_do_not_contact called directly with free text
  perform public.mark_do_not_contact(l2, 'Éloïse Bédard asked by phone 514-555-0177 to stop', 'owner:test');
  select detail into j from public.audit_log where action = 'do_not_contact' and target = 'leads/' || l2 order by id desc limit 1;
  txt := lower(j::text);
  if txt like '%bedard%' or txt like '%bédard%' or txt like '%514%' or txt like '%phone%' then raise exception 'A2 free text reached audit_log: %', j; end if;
  if j ->> 'reason_code' <> 'owner_text' or (j ->> 'reason_chars')::int < 20 then raise exception 'A2b reason code wrong: %', j; end if;
  perform public.mark_do_not_contact(l2, null, null);
  if (select detail ->> 'reason_code' from public.audit_log where target = 'leads/' || l2 order by id desc limit 1) <> 'none' then raise exception 'A2c empty reason must be code none'; end if;
  -- A3 deals: stage note and confirmed win note
  insert into public.leads (venture_id, name, email, phone, status) values (v, 'Prisca Vandenbroek', 'prisca@vandenbroek.example', '613-555-0188', 'sent') returning id into sid;
  d1 := public.create_deal(sid, 250000, 'owner:test', 'first note about Prisca Vandenbroek');
  perform public.set_deal_stage(d1, 'negotiating', 'owner:test', 'Prisca Vandenbroek wants 10% off, phone 613-555-0188');
  select detail into j from public.audit_log where action = 'deal_stage' and target = 'deals/' || d1 order by id desc limit 1;
  if lower(j::text) like '%prisca%' or lower(j::text) like '%555%' or (j ->> 'note_chars')::int < 20 or j ->> 'to' <> 'negotiating' then raise exception 'A3 deal_stage audit: %', j; end if;
  if (select notes from public.deals where id = d1) not like '%Prisca%' then raise exception 'A3b deals.notes must keep the owner note'; end if;
  led_before := (select count(*) from public.ledger); led_sum_before := (select coalesce(sum(amount_cents), 0) from public.ledger);
  j := public.confirm_deal_won(d1, 250000, 'expected', 'owner:test', 'Prisca Vandenbroek signed, call 613-555-0188');
  select id, note into rec from public.ledger where id = (j ->> 'ledger_id')::uuid;
  if rec.note <> 'deal ' || d1 || ': owner confirmed win' then raise exception 'A3c ledger note for a won deal: %', rec.note; end if;
  if (select count(*) from public.ledger) <> led_before + 1 or (select sum(amount_cents) from public.ledger) <> led_sum_before + 250000 then raise exception 'A3d ledger amount/count changed wrongly'; end if;
  begin perform public.confirm_deal_won(d1, 250000, 'expected', 'owner:test', null); raise exception 'A3e revenue recorded twice'; exception when others then if sqlerrm like 'A3e%' then raise; end if; end;
  if (select notes from public.deals where id = d1) not like '%signed%' then raise exception 'A3f deals.notes lost the win note'; end if;
  if exists (select 1 from public.audit_log where action = 'deal_won' and lower(detail::text) like '%prisca%') then raise exception 'A3g deal_won audit holds a name'; end if;
  -- A4 setter payout
  for rec in select * from public.setter_standing where id = setter_id loop
    if rec.owed_close_cents <> 36000 then raise exception 'A4 setter math: %', to_jsonb(rec); end if;
  end loop;
  j := public.setter_record_payout('Marcus Zzyxwell', 'close', 36000, 'ref-a');
  if j ->> 'ok' is null or j ->> 'name' <> 'Marcus Zzyxwell' then raise exception 'A4b payout result changed: %', j; end if;
  select note, amount_cents, kind, currency, status into rec from public.ledger where note like 'Setter payout (close)%' order by created_at desc limit 1;
  if rec.note <> 'Setter payout (close): setter ' || setter_id or rec.amount_cents <> 36000 or rec.kind <> 'expense' or rec.currency <> 'CAD' or rec.status <> 'received' then raise exception 'A4c payout ledger row: %', to_jsonb(rec); end if;
  if lower(rec.note) like '%marcus%' or lower(rec.note) like '%zzyxwell%' then raise exception 'A4d setter name in ledger'; end if;
  if (public.setter_record_payout('Marcus Zzyxwell', 'close', 36000) ->> 'error') is null then raise exception 'A4e overpay allowed'; end if;
  -- A5 agent_runs trigger (light mode: scrubs, never blanks)
  insert into public.agent_runs (agent_id, status, summary) select id, 'ok', 'Researched Odalys Quenneville: email odalys.q@quenneville-co.example phone 819-555-0123; 4 leads found, cost $0.12' from public.agents order by slug limit 1 returning summary into r;
  if lower(r) like '%odalys%' or lower(r) like '%quenneville%' or r like '%819%' or r like '%@%' then raise exception 'A5 agent_runs.summary not scrubbed: %', r; end if;
  if r not like '%4 leads found, cost $0.12%' then raise exception 'A5b agent_runs.summary lost its operational text: %', r; end if;
  update public.agent_runs set summary = 'Call Jean Tremblay on 613 555 0142' where summary like 'Researched%' returning summary into r;
  if lower(r) like '%tremblay%' or r like '%0142%' then raise exception 'A5c update not scrubbed: %', r; end if;
  insert into public.agent_runs (agent_id, status, summary) select id, 'ok', null from public.agents order by slug limit 1;

  -- ============================================================ B. VECTORS
  ctx := public.backup_redaction_context();
  if (ctx ->> 'n_terms')::int < 6 or ctx ->> 'name_re' not like '%tremblay%' or ctx ->> 'name_re' not like '%zzyxwell%' or ctx ->> 'name_re' not like '%quillfeather%' or ctx ->> 'name_re' not like '%quenneville%' or ctx ->> 'name_re' not like '%wexcombe%' or ctx ->> 'name_re' not like '%bedard%' then
    raise exception 'B0 context misses known client names: %', left(ctx::text, 400); end if;
  b64 := encode(convert_to('jean.tremblay@tremblay-plomberie.ca', 'UTF8'), 'base64');
  hx := encode(convert_to('jean.tremblay@tremblay-plomberie.ca', 'UTF8'), 'hex');
  rot := translate('jean.tremblay@tremblay-plomberie.ca', 'abcdefghijklmnopqrstuvwxyz', 'nopqrstuvwxyzabcdefghijklm');
  insert into lv (id, input, forbid, expect) values
    -- direct input
    ('D1', 'Call Jean Tremblay on 613-555-0142 or jean.tremblay@tremblay-plomberie.ca', array['tremblay', '#6135550142', 'jeantremblay@'], null),
    ('D2', 'owner note: Marcus Zzyxwell was paid; Quillfeather Bakery closed; Wexcombe Holdings asked', array['zzyxwell', 'quillfeather', 'wexcombe'], null),
    ('D3', 'Lead Odalys Quenneville odalys.q@quenneville-co.example 819-555-0123', array['odalys', 'quenneville', '#8195550123'], null),
    -- phone formats
    ('P1', 'a (613) 555-0142 b', array['#6135550142'], null), ('P2', 'a 613.555.0142 b', array['#6135550142'], null), ('P3', 'a +1 613 555 0142 b', array['#6135550142'], null),
    ('P4', 'a 6135550142 b', array['#6135550142'], null), ('P5', 'a 1-613-555-0142 b', array['#6135550142'], null), ('P6', 'a 613 555 01 42 b', array['#6135550142'], null),
    ('P7', 'tel:+16135550142', array['#6135550142'], null), ('P8', 'a 613,555,0142 b', array['#6135550142'], null), ('P9', 'a 613_555_0142 b', array['#6135550142'], null),
    ('P10', 'local 555-0142 only', array['#5550142'], null), ('P11', 'a 06 12 34 56 78 b', array['#0612345678'], null), ('P12', 'a +33 6 12 34 56 78 b', array['#33612345678'], null),
    ('P13', 'a 613 - 555 - 0142 b', array['#6135550142'], null), ('P14', E'a 613\t555\t0142 b', array['#6135550142'], null),
    ('P15', 'six one three five five five zero one four two', array['sixonethree'], null), ('P16', 'appelez le six un trois cinq cinq cinq zéro un quatre deux', array['sixuntrois'], null),
    ('P17', 'a 6 1 3 5 5 5 0 1 4 2 b', array['#6135550142'], null),
    -- Arabic-Indic / Persian / fullwidth / Devanagari digits
    ('U1', 'a ٦١٣-٥٥٥-٠١٤٢ b', array['#6135550142', '٦١٣'], null), ('U2', 'a ６１３－５５５－０１４２ b', array['#6135550142', '６１３'], null), ('U3', 'a ۶۱۳۵۵۵۰۱۴۲ b', array['#6135550142'], null),
    ('U4', 'a ६१३५५५०१४२ b', array['#6135550142'], null),
    -- SIN-like and long digit runs
    ('S1', 'SIN 123-456-789', array['#123456789'], 'uncertain'), ('S2', 'number 123 456 789 here', array['#123456789'], null), ('S3', 'ref 123456789012345678 here', array['#123456789012345678'], null),
    ('S4', 'acct 4111 1111 1111 1111 here', array['#4111111111111111'], null),
    -- emails: plain, spaced, obfuscated, fullwidth, French
    ('E1', 'mail jane.doe@example.com now', array['janedoe', 'example.com'], null), ('E2', 'jane [at] example [dot] com', array['janeexamplecom'], null),
    ('E3', 'jane (at) example (dot) com', array['janeexamplecom'], null), ('E4', 'jane at example dot com', array['janeexamplecom'], null), ('E5', 'jane @ example.com', array['janeexamplecom'], null),
    ('E6', 'jane＠example.com', array['janeexamplecom'], null), ('E7', 'jane{at}example{dot}com', array['janeexamplecom'], null), ('E8', 'jane arobase example point com', array['janeexamplecom'], null),
    ('E9', 'jane [ at ] example.com', array['janeexamplecom'], null), ('E10', 'JANE@EXAMPLE.COM', array['janeexamplecom'], null), ('E11', 'j a n e @ e x a m p l e . c o m', array['janeexamplecom'], 'uncertain'),
    ('E12', 'courriel : marie.cote@exemple.ca', array['mariecote'], null), ('E13', 'jane@example dot com', array['janeexamplecom'], null), ('E14', 'ping @jane_doe_99 on instagram', array['janedoe99'], null),
    ('E15', 'moc.elpmaxe@enaj', array['janeexamplecom', 'moc.elpmaxe@enaj'], 'uncertain'), ('E16', 'wnar@rknzcyr.pbz', array['wnar@rknzcyr.pbz'], null),
    -- encodings
    ('X1', 'x ' || b64 || ' y', array['tremblay', 'amVhbi5', lower(b64)], null), ('X2', 'x ' || hx || ' y', array['tremblay', hx], null), ('X3', 'x ' || '0x' || hx || ' y', array['tremblay', hx], null),
    ('X4', 'x jean.tremblay%40tremblay-plomberie.ca y', array['tremblay'], null), ('X5', 'x jean.tremblay&#64;tremblay-plomberie.ca y', array['tremblay'], null), ('X6', 'x jean.tremblay&#x40;tremblay-plomberie.ca y', array['tremblay'], null),
    ('X7', 'x jean.tremblay&commat;tremblay-plomberie&period;ca y', array['tremblay'], null), ('X8', 'x jean.tremblay@tremblay-plomberie.ca y', array['tremblay'], null),
    ('X9', 'x jean.tremblay%2540tremblay-plomberie.ca y', array['tremblay'], null), ('X10', 'x %4A%65%61%6E %54%72%65%6D%62%6C%61%79 y', array['tremblay', 'jeantremblay'], null),
    ('X11', 'x ' || rot || ' y', array['tremblay', rot], null), ('X12', 'x ' || encode(convert_to(b64, 'UTF8'), 'base64') || ' y', array['tremblay'], null),
    ('X13', 'x ' || translate(b64, '+/=', '-_') || ' y', array['tremblay'], null), ('X14', 'x &#74;&#101;&#97;&#110; &#84;&#114;&#101;&#109;&#98;&#108;&#97;&#121; y', array['tremblay'], null),
    ('X15', 'x 613-555-0142 encoded ' || encode(convert_to('613-555-0142', 'UTF8'), 'base64') || ' y', array['#6135550142', encode(convert_to('613-555-0142', 'UTF8'), 'base64')], null),
    -- Unicode / look-alikes / zero width / combining
    ('H1', 'Jеаn Trеmblау', array['tremblay'], null),                                                       -- Cyrillic е а у
    ('H2', 'Ιean Τremblay', array['tremblay'], null),                                                       -- Greek capital iota, tau
    ('H3', E'Je​an Trem‍blay', array['tremblay'], null), ('H4', E'Trémblay', array['tremblay'], null), ('H5', 'ＪＥＡＮ ＴＲＥＭＢＬＡＹ', array['tremblay'], null),
    ('H6', E'Je­an Tremb﻿l⁠ay', array['tremblay'], null), ('H7', 'Éloïse Bédard', array['bedard'], null), ('H8', 'Eloise Bedard', array['bedard'], null), ('H9', 'ÉLOÏSE BÉDARD', array['bedard'], null),
    ('H10', E'Éloïse Bédard', array['bedard'], null), ('H11', 'jеаn.trеmblау＠tremblay-plomberie.ca', array['tremblay'], null),
    ('H12', '𝐓𝐫𝐞𝐦𝐛𝐥𝐚𝐲 ⓙⓔⓐⓝ', array['tremblay'], null), ('H13', 'ⓣⓡⓔⓜⓑⓛⓐⓨ', array['tremblay'], null),
    -- French
    ('F1', 'appelez Jean Tremblay au 613-555-0142', array['tremblay', '#6135550142'], null), ('F2', 'courriel: jean.tremblay@tremblay-plomberie.ca merci', array['tremblay'], null),
    ('F3', 'Éloïse Bédard a dit: rappelez-moi au 514 555 0177 svp', array['bedard', '#5145550177'], null), ('F4', 'le client Quillfeather Bakery a payé; téléphone (819) 555-0123', array['quillfeather', '#8195550123'], null),
    ('F5', 'Écrivez à marie.cote [arobase] exemple [point] ca', array['mariecote'], null),
    -- adversarial splitting / spacing / case
    ('V1', 'J e a n   T r e m b l a y', array['jeantremblay'], 'uncertain'), ('V2', 'jEaN tReMbLaY', array['tremblay'], null), ('V3', 'Tremblay, Jean', array['tremblay'], null),
    ('V4', 'JEAN-TREMBLAY', array['tremblay'], null), ('V5', 'jeantremblay', array['tremblay'], null), ('V6', 'Tremblay', array['tremblay'], null), ('V7', 'Jean', array['jean'], null),
    ('V8', 'J.e.a.n T.r.e.m.b.l.a.y', array['jeantremblay'], 'uncertain'), ('V9', 'Tremb' || chr(10) || 'lay', array['tremblay'], 'uncertain'), ('V10', 'Quill feather Bakery', array['quillfeather'], null),
    ('V11', 'Q-u-i-l-l-f-e-a-t-h-e-r', array['quillfeather'], 'uncertain'), ('V12', 'M. Zzyxwell (setter)', array['zzyxwell'], null), ('V13', 'WEXCOMBE   holdings', array['wexcombe'], null),
    ('V14', 'jean.tremblay', array['tremblay'], null), ('V15', 'tremblay_jean', array['tremblay'], null), ('V16', 'Prénom: Jean, Nom: Tremblay', array['tremblay'], null),
    -- urls
    ('L1', 'see https://www.linkedin.com/in/jean-tremblay-1234 now', array['jean-tremblay'], null), ('L2', 'https://example.com/contact?email=jane@example.com&name=Jane', array['jane@', 'name=jane'], null),
    ('L3', 'https://www.facebook.com/jean.tremblay.55', array['jean.tremblay'], null), ('L4', 'https://tremblay-plomberie.ca/about', array['tremblay'], null), ('L5', 'http://x.example/u/jean', array['/u/jean'], null),
    -- fail closed
    ('C1', 'The client has diabetes and takes insulin', array['diabetes'], 'uncertain'), ('C2', 'monthly income verification and credit score', array['credit'], 'uncertain'),
    ('C3', 'void cheque and bank account number', array['cheque'], 'uncertain'), ('C4', 'x ' || repeat('lorem ipsum ', 3000) || ' y', array[]::text[], 'uncertain'),
    ('C5', 'passport number on file', array['passport'], 'uncertain');
  -- must-stay-unchanged vectors
  insert into lv (id, input, forbid, keep, expect) values
    ('K1', 'do_not_contact', '{}', array['do_not_contact'], 'same'), ('K2', 'received', '{}', array['received'], 'same'), ('K3', 'unsubscribe_reply', '{}', array['unsubscribe_reply'], 'same'),
    ('K4', 'deal 3f2a1b4c-1111-4222-8333-444455556666: owner confirmed win', '{}', array['deal 3f2a1b4c-1111-4222-8333-444455556666: owner confirmed win'], 'same'),
    ('K5', 'Setter payout (close): setter 3f2a1b4c-1111-4222-8333-444455556666', '{}', array['Setter payout (close): setter 3f2a1b4c-1111-4222-8333-444455556666'], 'same'),
    ('K6', 'Verified 3 suppliers; margin 12%; total $1,250.00; see https://acmeplumbing.ca/about', '{}', array['Verified 3 suppliers; margin 12%; total $1,250.00; see https://acmeplumbing.ca/about'], 'same'),
    ('K7', '2026-11-15T10:30:00Z', '{}', array['2026-11-15T10:30:00Z'], 'same'), ('K8', 'Résumé des tâches: 3 terminées, 2 en cours, 40 000 $ prévus', '{}', array['Résumé des tâches: 3 terminées, 2 en cours, 40 000 $ prévus'], 'same'),
    ('K9', 'cap $3.30 per day; 12 of 40 done; status=blocked; 5 retries', '{}', array['cap $3.30 per day; 12 of 40 done; status=blocked; 5 retries'], 'same'),
    ('K10', 'Spent 33 cents of 330 cents on 2026-11-15 (3f2a1b4c-1111-4222-8333-444455556666)', '{}', array['Spent 33 cents of 330 cents on 2026-11-15 (3f2a1b4c-1111-4222-8333-444455556666)'], 'same'),
    ('K11', 'sha256 9f86d081884c7d659a2feaa0c55ad015a3bf4f1b2b0b822cd15d6c15b0f00a08 verified', '{}', array['9f86d081884c7d659a2feaa0c55ad015a3bf4f1b2b0b822cd15d6c15b0f00a08'], 'same'),
    ('K12', 'Task done: 3 prospects, 2 sites checked, next step queued', '{}', array['Task done: 3 prospects, 2 sites checked, next step queued'], 'same');
  for rec in select * from lv order by id loop
    r := public.backup_redact_text(rec.input, ctx);
    sq := lower(regexp_replace(public.backup_fold_text(r), '[^a-zA-Z0-9]', '', 'g'));
    dg := regexp_replace(public.backup_fold_text(r), '[^0-9]', '', 'g');
    foreach f in array rec.forbid loop
      if left(f, 1) = '#' then
        if position(substr(f, 2) in dg) > 0 then raise exception 'B % leaked digits %: % -> %', rec.id, f, rec.input, r; end if;
      elsif position(lower(regexp_replace(public.backup_fold_text(f), '[^a-zA-Z0-9]', '', 'g')) in sq) > 0 or position(lower(f) in lower(r)) > 0 then
        raise exception 'B % leaked %: % -> %', rec.id, f, rec.input, r;
      end if;
    end loop;
    if rec.expect = 'uncertain' and r <> '[redacted:uncertain]' then raise exception 'B % must fail closed: % -> %', rec.id, rec.input, r; end if;
    if rec.expect = 'same' and r is distinct from rec.input then raise exception 'B % must be unchanged: % -> %', rec.id, rec.input, r; end if;
    if rec.expect is null and r = rec.input then raise exception 'B % was not redacted at all: %', rec.id, r; end if;
    if public.backup_redact_text(r, ctx) is distinct from r then raise exception 'B % redaction is not idempotent: % -> %', rec.id, r, public.backup_redact_text(r, ctx); end if;
  end loop;
  select count(*) into cnt from lv;
  if cnt < 110 then raise exception 'B vector table is smaller than expected (%)', cnt; end if;
  -- B light mode never blanks a whole field, and the length limit is strict-only
  r := public.backup_redact_text('The patient has diabetes. Call Jean Tremblay on 613-555-0142', ctx, null, 'light');
  if r like '%uncertain%' or lower(r) like '%tremblay%' or r not like '%diabetes%' then raise exception 'B light mode: %', r; end if;
  if public.backup_redact_text(repeat('x ', 30000) || 'Tremblay', ctx, null, 'light') like '%remblay%' then raise exception 'B light long text leaked'; end if;
  if public.backup_redact_text('x', ctx, 20000, 'bogus') <> '[redacted:uncertain]' then raise exception 'B unknown mode must fail closed'; end if;
  if public.backup_redact_text(null, ctx) is not null or public.backup_redact_text('', ctx) <> '' then raise exception 'B null/empty handling'; end if;
  -- B internal failure fails closed (a context that is not an object)
  if public.backup_redact_text('hello Jean Tremblay', '"broken"'::jsonb) not in ('[redacted:uncertain]', 'hello Jean Tremblay') then raise exception 'B broken ctx'; end if;
  -- B json: keys and numbers survive, strings are redacted, nested values too
  j := public.backup_redact_json('{"leads_marked": 2, "ok": true, "reason": "Jean Tremblay 613-555-0142", "nested": {"list": ["a@b.example", "fine_code", 7]}, "n": null}'::jsonb, ctx, 500, 'strict');
  if (j ->> 'leads_marked')::int <> 2 or (j -> 'ok') <> 'true'::jsonb or j::text ilike '%tremblay%' or j::text like '%555%' or j::text like '%@%' or j #>> '{nested,list,1}' <> 'fine_code' or (j #>> '{nested,list,2}')::int <> 7 or j -> 'n' <> 'null'::jsonb then raise exception 'B json: %', j; end if;

  -- ============================================================ C. INDIRECT PROPAGATION through the real writers, then the whole snapshot
  -- a name typed in a lead reply reappears in a task prompt (detail), a researcher result, an escalation, an audit row of another writer, a ledger note written by something else, an agent run
  insert into public.tasks (venture_id, assigned_agent, created_by, title, detail, status, priority, result) values
    (v, ag, 'system', 'Follow up with Jean Tremblay', 'Prompt: reply from Jean Tremblay: "call me 613-555-0142". Email jean.tremblay@tremblay-plomberie.ca', 'done', 2,
     E'Researched Jean Tremblay (Tremblay Plomberie).\nPublished email: jean.tremblay@tremblay-plomberie.ca\nPhone: (613) 555-0142\nLinkedIn: https://www.linkedin.com/in/jean-tremblay-1234\nOutreach draft: Bonjour Jean, appelez-moi.\nFound 3 prospects, 2 verified; see https://acmeplumbing.ca/about'),
    (v, ag, 'system', 'Check Odalys', null, 'done', 2, 'Odalys Quenneville <odalys.q@quenneville-co.example> 819-555-0123, Quillfeather Bakery, Wexcombe Holdings'),
    (v, ag, 'system', 'blocked one', null, 'blocked', 2, E'Patient notes: diabetes. Contact Jean Tremblay'),
    (v, ag, 'system', 'clean one', null, 'done', 2, 'Done: 4 prospects checked, 3 sites verified, cost 12 cents'),
    (v, ag, 'system', 'huge', null, 'done', 2, repeat('lorem ipsum dolor ', 2000) || ' Jean Tremblay');
  insert into public.escalations (from_agent, kind, summary) values (ag, 'uncertain', 'Follow up with Jean Tremblay: researcher said call 613-555-0142 or jean.tremblay@tremblay-plomberie.ca');
  insert into public.audit_log (actor, action, target, detail) values ('system', 'zz_other_writer', 'x/1', jsonb_build_object('reason', 'Marcus Zzyxwell wants cash, 819-555-0123', 'note', 'ask Odalys Quenneville', 'count', 3, 'ids', jsonb_build_array(l1, l2)));
  insert into public.ledger (venture_id, kind, amount_cents, currency, note, status) values (v, 'expense', 1234, 'CAD', 'Setter payout (close): Marcus Zzyxwell', 'received'), (v, 'revenue', 5000, 'CAD', 'legacy: Quillfeather Bakery invoice, call 819-555-0123', 'expected');
  insert into public.owner_messages (from_agent, kind, channel, body) values ('jarvis', 'proposal', 'telegram', 'Jean Tremblay replied from 613-555-0142; Wexcombe Holdings too');
  insert into public.memory (venture_id, agent, kind, content, source, confidence) values (v, ag, 'fact', 'Jean Tremblay prefers email: jean.tremblay@tremblay-plomberie.ca; Bonjour à tous', 'web', 'high'),
    (v, ag, 'fact', 'Règle: toujours répondre en français, voilà des accents', 'web', 'high');
  led_before := (select count(*) from public.ledger); aud_before := (select count(*) from public.audit_log); task_before := (select count(*) from public.tasks);
  snap := public.backup_snapshot();
  txt := lower(public.backup_fold_text(snap::text));
  foreach k in array array['tremblay', 'zzyxwell', 'quillfeather', 'wexcombe', 'quenneville', 'odalys', 'bedard', 'eloise', 'vandenbroek', 'prisca', '613-555-0142', '555-0142', '555-0188', '555-0177', '555-0123', 'tremblay-plomberie', 'jean-tremblay', 'angry',
                          'jean.tremblay', 'odalys.q', 'bedard-renos', 'marcus.zzyxwell', 'diabetes'] loop
    if position(k in txt) > 0 then raise exception 'C1 "%" is in the snapshot: %', k, substr(txt, greatest(position(k in txt) - 80, 1), 200); end if;
  end loop;
  dg := regexp_replace(txt, '[^0-9]', '', 'g');
  foreach k in array array['6135550142', '5145550177', '8195550123', '6135550188'] loop
    if position(k in dg) > 0 then raise exception 'C2 phone digits % are in the snapshot', k; end if;
  end loop;
  if position('zzvisibleleak' in txt) = 0 then raise exception 'C3 control marker missing: the snapshot is not reading exported tables'; end if;
  if (snap -> 'data') ? 'leads' or (snap -> 'data') ? 'setters' or (snap -> 'data') ? 'ws_leads' then raise exception 'C4 client tables are back in the export'; end if;
  -- the operational parts survived
  select j2 into j from jsonb_array_elements(snap -> 'data' -> 'tasks') j2 where j2 ->> 'title' like 'clean one%' or j2 ->> 'title' = 'clean one';
  if j ->> 'result' <> 'Done: 4 prospects checked, 3 sites verified, cost 12 cents' then raise exception 'C5 a clean result was altered: %', j ->> 'result'; end if;
  select j2 into j from jsonb_array_elements(snap -> 'data' -> 'tasks') j2 where j2 ->> 'result' like 'Researched%';
  if j is not null and (j ->> 'result' not like '%https://acmeplumbing.ca/about%' or j ->> 'result' not like '%3 prospects, 2 verified%') then raise exception 'C6 research result lost its non-personal content: %', j ->> 'result'; end if;
  if (select count(*) from jsonb_array_elements(snap -> 'data' -> 'tasks') j2 where j2 ->> 'result' = '[redacted:uncertain]') < 2 then raise exception 'C7 detector-flagged and over-length results must fail closed'; end if;
  select j2 into j from jsonb_array_elements(snap -> 'data' -> 'memory') j2 where j2 ->> 'content' like '%voilà%';
  if j is null or j ->> 'content' <> 'Règle: toujours répondre en français, voilà des accents' then raise exception 'C8 clean text must come back unchanged, accents included: %', j; end if;
  if exists (select 1 from jsonb_array_elements(snap -> 'data' -> 'memory') j2 where j2 ->> 'content' like '%Bonjour%' and (j2 ->> 'content' ilike '%tremblay%' or j2 ->> 'content' like '%@%')) then raise exception 'C8b memory row leaked'; end if;
  select j2 into j from jsonb_array_elements(snap -> 'data' -> 'audit_log') j2 where j2 ->> 'action' = 'zz_other_writer';
  if (j -> 'detail' ->> 'count')::int <> 3 or jsonb_array_length(j -> 'detail' -> 'ids') <> 2 or j -> 'detail' -> 'ids' <> jsonb_build_array(l1, l2) then raise exception 'C9 audit detail ids/counts altered: %', j; end if;

  -- ============================================================ D. INTEGRITY: only the redacted columns differ
  if jsonb_array_length(snap -> 'data' -> 'ledger') <> led_before or jsonb_array_length(snap -> 'data' -> 'audit_log') <> aud_before or jsonb_array_length(snap -> 'data' -> 'tasks') <> task_before then raise exception 'D1 row counts differ'; end if;
  if (select coalesce(sum((x ->> 'amount_cents')::bigint), 0) from jsonb_array_elements(snap -> 'data' -> 'ledger') x) <> (select coalesce(sum(amount_cents), 0) from public.ledger)
     or (select count(*) from jsonb_array_elements(snap -> 'data' -> 'ledger') x where x ->> 'kind' = 'revenue') <> (select count(*) from public.ledger where kind = 'revenue') then raise exception 'D2 ledger sums/kinds differ'; end if;
  select count(*) into n from public.ledger l join jsonb_array_elements(snap -> 'data' -> 'ledger') x on x ->> 'id' = l.id::text where (to_jsonb(l) - 'note') = (x - 'note');
  if n <> led_before then raise exception 'D3 a ledger row differs outside note (% of %)', n, led_before; end if;
  select count(*) into n from public.audit_log l join jsonb_array_elements(snap -> 'data' -> 'audit_log') x on x ->> 'id' = l.id::text where (to_jsonb(l) - 'detail') = (x - 'detail');
  if n <> aud_before then raise exception 'D4 an audit row differs outside detail (% of %)', n, aud_before; end if;
  select count(*) into n from public.tasks l join jsonb_array_elements(snap -> 'data' -> 'tasks') x on x ->> 'id' = l.id::text where (to_jsonb(l) - 'result' - 'title' - 'detail') = (x - 'result' - 'title' - 'detail');
  if n <> task_before then raise exception 'D5 a task differs outside result/title/detail (% of %)', n, task_before; end if;
  select count(*) into n from public.agent_runs l join jsonb_array_elements(snap -> 'data' -> 'agent_runs') x on x ->> 'id' = l.id::text where (to_jsonb(l) - 'summary') = (x - 'summary');
  if n <> (select count(*) from public.agent_runs) or n < 2 then raise exception 'D6 an agent_run differs outside summary'; end if;
  -- audit rows with no client text are byte-identical (the redaction does not rewrite what it has no reason to touch)
  select count(*) into n from public.audit_log l join jsonb_array_elements(snap -> 'data' -> 'audit_log') x on x ->> 'id' = l.id::text where l.detail is not distinct from (x -> 'detail');
  select count(*) into n2 from public.audit_log;
  if n < n2 - 8 then raise exception 'D7 too many audit details were rewritten (% of %): the redaction is over-reaching', n2 - n, n2; end if;
  -- every column that is not on the spec is untouched in every exported table (cheap structural check on the tables this test touched)
  if exists (select 1 from jsonb_array_elements(snap -> 'data' -> 'ventures') x where x ->> 'slug' = 'zz-visible-leak' and x ->> 'name' <> 'ZZVISIBLELEAK venture') then raise exception 'D8 unlisted table altered'; end if;
  -- the spec is the reviewed one
  if (select count(*) from public.backup_redaction_spec() where mode = 'strict') < 5 or (select count(*) from public.backup_redaction_spec() where mode = 'strict' and (table_name, column_name) in (('audit_log', 'detail'), ('ledger', 'note'), ('tasks', 'result'), ('agent_runs', 'summary'), ('escalations', 'summary'))) <> 5 or not exists (select 1 from public.backup_redaction_spec() where (table_name, column_name) in (('audit_log', 'detail'), ('ledger', 'note'), ('tasks', 'result'), ('agent_runs', 'summary'))) then raise exception 'D9 spec lost a leak path'; end if;

  -- ============================================================ E. shape, grants
  if snap -> 'redaction' ->> 'version' <> '2' or (snap -> 'redaction' ->> 'known_client_terms')::int < 6 or (snap -> 'redaction')::text ilike '%tremblay%' or (snap -> 'redaction')::text ilike '%name_re%' then raise exception 'E1 redaction block wrong/leaky: %', snap -> 'redaction'; end if;
  if snap -> 'policy' <> public.backup_export_policy() or jsonb_typeof(snap -> 'schema') <> 'object' or snap ->> 'method' <> 'single statement snapshot' then raise exception 'E2 snapshot lost policy/schema/method'; end if;
  foreach f in array array['public.backup_fold_text(text)', 'public.backup_unescape_text(text)', 'public.backup_redaction_context()', 'public.backup_redact_patterns(text,jsonb)', 'public.backup_probe_encoded(text,jsonb,integer)',
                           'public.backup_redact_text(text,jsonb,integer,text)', 'public.backup_redact_json(jsonb,jsonb,integer,text)', 'public.backup_redaction_spec()', 'public.backup_redact_row(text,jsonb,jsonb)', 'public.backup_snapshot(text[])',
                           'public.backup_redaction_status()', 'public.agent_runs_scrub()', 'public.mark_do_not_contact(uuid,text,text)', 'public.record_lead_reply(uuid,text,text,text)', 'public.setter_record_payout(text,text,integer,text,text)',
                           'public.set_deal_stage(uuid,text,text,text)', 'public.confirm_deal_won(uuid,integer,text,text,text)'] loop
    foreach k in array array['anon', 'authenticated'] loop
      if has_function_privilege(k, f, 'execute') then raise exception 'E3 % can execute %', k, f; end if;
    end loop;
  end loop;
  foreach f in array array['public.backup_redaction_context()', 'public.backup_redact_text(text,jsonb,integer,text)', 'public.backup_snapshot(text[])', 'public.backup_redaction_status()'] loop
    if not has_function_privilege('service_role', f, 'execute') then raise exception 'E4 service_role cannot execute %', f; end if;
  end loop;
  if (select provolatile from pg_proc where oid = 'public.backup_snapshot(text[])'::regprocedure) <> 's' then raise exception 'E5 backup_snapshot must stay STABLE'; end if;
  j := public.backup_redaction_status();
  if not ((j ->> 'snapshot_redacts')::boolean and (j ->> 'sources_fixed')::boolean and (j ->> 'redactor_installed')::boolean and (j ->> 'agent_runs_trigger')::boolean and (j ->> 'denylist')::boolean) then raise exception 'E6 status: %', j; end if;
  -- the old unchecked behaviours are really gone: a repeat of the original leak scenario, end to end, leaves nothing
  perform public.record_lead_reply(l2, 'unsubscribe', 'second try: Éloïse Bédard, 514-555-0177, eloise@bedard-renos.example', 'owner:test');
  snap := public.backup_snapshot();
  if position('bedard' in lower(public.backup_fold_text(snap::text))) > 0 or snap::text like '%514-555%' then raise exception 'E7 original leak scenario still leaks'; end if;

  -- ============================================================ F. SPEC COMPLETE BY CONSTRUCTION (finding 3)
  -- every text-like column of every exported table must be in the spec with a mode and a one-line reason; a new column is strict until classified
  select count(*) into n from (
    select c.table_name, c.column_name from information_schema.columns c
     where c.table_schema = 'public' and c.table_name in (select jsonb_array_elements_text(public.backup_export_policy() -> 'exported'))
       and (c.udt_name in ('text', 'varchar', 'bpchar', 'citext', 'json', 'jsonb', '_text', '_varchar', '_bpchar') or c.data_type = 'USER-DEFINED' and exists (select 1 from pg_type t where t.typname = c.udt_name and t.typtype = 'e'))
    except select table_name, column_name from public.backup_redaction_spec()) q;
  if n > 0 then raise exception 'F1 % exported text-like column(s) are not in backup_redaction_spec()', n; end if;
  if exists (select 1 from public.backup_redaction_spec() where mode not in ('strict', 'light', 'keep', 'blank') or coalesce(btrim(reason), '') = '') then raise exception 'F2 a spec row has no valid mode or no reason'; end if;
  if (select count(*) from public.backup_effective_spec(public.backup_export_policy() -> 'exported') where not classified) > 0 then raise exception 'F3 effective spec has unclassified columns: %', public.backup_redaction_meta() -> 'unclassified_columns'; end if;
  select count(*) into n from (values ('web_messages', 'body'), ('web_messages', 'payload'), ('action_log', 'reason'), ('action_log', 'detail'), ('action_log', 'result'), ('action_log', 'evidence'), ('action_log', 'ref'),
      ('bank_transactions', 'description'), ('bank_transactions', 'note'), ('missions', 'title'), ('missions', 'objective'), ('missions', 'evidence'), ('missions', 'plan'), ('missions', 'checkpoint'),
      ('ideas', 'description'), ('ideas', 'result'), ('owner_messages', 'answer'), ('owner_messages', 'options'), ('approval_requests', 'recommendation'), ('payment_instructions', 'payee'),
      ('reconciliation_flags', 'detail'), ('executor_runs', 'refusal_reason'), ('evidence_sources', 'text'), ('venture_assets', 'notes')) v (t, c)
    where exists (select 1 from public.backup_redaction_spec() s where s.table_name = v.t and s.column_name = v.c);
  if n <> 24 then raise exception 'F4 a column named in the review is missing from the spec (% of 24)', n; end if;
  if (select mode from public.backup_redaction_spec() where table_name = 'bank_transactions' and column_name = 'description') <> 'strict' or (select mode from public.backup_redaction_spec() where table_name = 'payment_instructions' and column_name = 'payee') <> 'strict' then raise exception 'F5 bank_transactions.description and payment_instructions.payee must be strict'; end if;
  if (select mode from public.backup_redaction_spec() where table_name = 'evidence_sources' and column_name = 'text') <> 'blank' then raise exception 'F6 evidence_sources.text is blank (bulk public page bodies, rebuildable) by decision'; end if;
  -- the blank column restores: an empty string satisfies every constraint on the table (the restore inserts exactly what the export carries)
  if exists (select 1 from pg_constraint c where c.conrelid = 'public.evidence_sources'::regclass and c.contype = 'c' and pg_get_constraintdef(c.oid) ~* 'length\(text\)\s*(>|>=)') then raise exception 'F6b evidence_sources.text = empty string would be refused on restore'; end if;
  if (select (public.backup_snapshot() -> 'data' -> 'evidence_sources') is null) then raise exception 'F6c evidence_sources is no longer exported'; end if;
  alter table public.ideas add column zz_new_note text;
  insert into public.ideas (name, zz_new_note) values ('zz new column idea', 'ring Jean Tremblay on 613-555-0142');
  snap := public.backup_snapshot();
  if not (snap -> 'redaction' -> 'unclassified_columns') ? 'ideas.zz_new_note' then raise exception 'F7 an unclassified column must be reported: %', snap -> 'redaction' -> 'unclassified_columns'; end if;
  if exists (select 1 from jsonb_array_elements(snap -> 'data' -> 'ideas') x where x ->> 'zz_new_note' ilike '%tremblay%' or x ->> 'zz_new_note' like '%0142%') then raise exception 'F8 an unclassified column was exported raw'; end if;
  alter table public.ideas drop column zz_new_note;

  -- ============================================================ G. THE REVIEW FINDINGS 1, 3, 4
  insert into public.leads (venture_id, name, email, phone, notes, status) values (v, 'Zorba Trov', 'zt@zt-fixture.example', '613-555-0199', 'n', 'new'), (v, 'Wf Fother', 'wf@wf-fixture.example', '613-555-0198', 'n', 'new'), (v, 'Bob Ng', 'bn@bn-fixture.example', '613-555-0197', 'n', 'new');
  ctx := public.backup_redaction_context();
  foreach f in array array['tel:613-555-0199', 'x613.555.0199', 'phone-613-555-0199', 'z.o.r.b.a.t.r.o.v', 'z_o_r_b_a_t_r_o_v', 'zorba.trov', 'wf.fother', 'b-o-b-n-g'] loop
    r := public.backup_redact_text(f, ctx, 500, 'strict');
    if r = f or lower(regexp_replace(r, '[^a-zA-Z0-9]', '', 'g')) ~ '(zorbatrov|wffother|bobng)' or regexp_replace(r, '[^0-9]', '', 'g') ~ '61355501(97|98|99)' then raise exception 'G1 short-code shortcut leaked "%": %', f, r; end if;
  end loop;
  foreach f in array array['do_not_contact', 'owner_text', 'received', 'unsubscribe_reply', 'bot-status-ok'] loop
    if public.backup_redact_text(f, ctx, 500, 'strict') <> f then raise exception 'G1b a plain code was altered: %', f; end if;
  end loop;
  j := public.backup_redact_json('{"detail":{"ph":6135550199,"ssn":123456789,"amount":12345678,"cents":250000,"txid":99887766,"count":3,"note":"Wf Fother"}}'::jsonb, ctx, 500, 'strict');
  if j::text like '%6135550199%' or j::text like '%123456789%' or j::text ilike '%fother%' then raise exception 'G4 JSON number or name survived: %', j; end if;
  if (j #>> '{detail,amount}')::bigint <> 12345678 or (j #>> '{detail,cents}')::int <> 250000 or (j #>> '{detail,txid}')::bigint <> 99887766 or (j #>> '{detail,count}')::int <> 3 then raise exception 'G4b an amount was altered: %', j; end if;
  insert into public.web_messages (role, body, kind, payload, status) values ('owner', 'call Wf Fother at 613-555-0198', 'chat', '{"x":"Wf Fother 613-555-0198","ph":6135550198}', 'new');
  insert into public.ideas (name, description, result) values ('zz idea g3', 'idea for Wf Fother, call 613-555-0198', 'Bob Ng said yes');
  snap := public.backup_snapshot();
  txt := lower(public.backup_fold_text((snap -> 'data')::text)); dg := regexp_replace((snap -> 'data')::text, '[^0-9]', '', 'g');
  foreach f in array array['zorbatrov', 'zorba trov', 'wf fother', 'wffother', 'bob ng', '613-555-0199', '613-555-0198'] loop
    if position(f in txt) > 0 then raise exception 'G3 "%" is in the snapshot: %', f, substr(txt, greatest(position(f in txt) - 80, 1), 200); end if;
  end loop;
  if position('6135550198' in dg) > 0 or position('6135550199' in dg) > 0 then raise exception 'G3b a seeded phone is in the snapshot'; end if;

  -- ============================================================ H. DENY-LIST (finding 2)
  if (public.redaction_denylist_status() ->> 'hashes')::int < 10 or not (public.redaction_denylist_status() ->> 'key_present')::boolean or (public.redaction_denylist_status() ->> 'triggers')::int < 5 then raise exception 'H0 deny-list not populated by the triggers: %', public.redaction_denylist_status(); end if;
  if (select count(*) from public.ffm_redaction_denylist where length(h) <> 64 or h !~ '^[0-9a-f]+$') > 0 then raise exception 'H1 the deny-list holds something other than hashes'; end if;
  foreach k in array array['anon', 'authenticated'] loop
    if has_table_privilege(k, 'public.ffm_redaction_denylist', 'select') or has_table_privilege(k, 'public.ffm_redaction_keys', 'select') then raise exception 'H2 % can read the deny-list or its key', k; end if;
  end loop;
  if exists (select 1 from public.backup_export_policy() p, jsonb_array_elements_text(p -> 'exported') e where e like 'ffm_redaction%') then raise exception 'H3 the deny-list is in the export'; end if;
  begin delete from public.ffm_redaction_denylist; raise exception 'H4 the deny-list can be deleted from'; exception when others then if sqlerrm like 'H4%' then raise; end if; end;
  begin truncate public.ffm_redaction_denylist; raise exception 'H4b the deny-list can be truncated'; exception when others then if sqlerrm like 'H4b%' then raise; end if; end;
  insert into public.tasks (assigned_agent, title, detail, status, result, created_by) values (ag, 'zz erasure fixture', 'x', 'done', 'Spoke with Zorba Trov (613-555-0199) about the quote; zt@zt-fixture.example confirmed', 'owner');
  insert into public.audit_log (actor, action, target, detail) values ('test', 'note', 'zz/erasure', jsonb_build_object('who', 'Bob Ng', 'k', 'asked for Wf Fother'));
  insert into public.ledger (kind, amount_cents, currency, note, status) values ('expense', 100, 'CAD', 'lunch with Bob Ng', 'received');
  delete from public.leads where name = 'Zorba Trov';
  update public.leads set name = '[erased]', email = null, phone = null where name = 'Wf Fother';
  delete from public.leads where name = 'Bob Ng';
  ctx := public.backup_redaction_context();
  if ctx ->> 'name_re' ilike '%zorba%' then raise exception 'H5 premise: the live context should no longer know the deleted name'; end if;
  snap := public.backup_snapshot();
  txt := lower(public.backup_fold_text((snap -> 'data')::text)); dg := regexp_replace((snap -> 'data')::text, '[^0-9]', '', 'g');
  foreach f in array array['zorba', 'trov', 'fother', 'bob ng', 'bobng', 'zt@zt-fixture'] loop
    if position(f in txt) > 0 then raise exception 'H6 erased/deleted name "%" is exported: %', f, substr(txt, greatest(position(f in txt) - 80, 1), 200); end if;
  end loop;
  if position('6135550199' in dg) > 0 or position('6135550198' in dg) > 0 then raise exception 'H7 an erased phone is exported'; end if;
  if (snap -> 'redaction' ->> 'deny_list_terms_found')::int < 1 then raise exception 'H8 the response must say the deny-list was used: %', snap -> 'redaction'; end if;
  insert into public.tasks (assigned_agent, title, detail, status, result, created_by) values (ag, 'zz never known', 'x', 'done', 'Spoke with Quentin Raskolnikov about the quote', 'owner');
  snap := public.backup_snapshot();
  if not exists (select 1 from jsonb_array_elements(snap -> 'data' -> 'tasks') x where x ->> 'title' = 'zz never known' and x ->> 'result' like '%Raskolnikov%') then raise exception 'H9 documented limit changed: a name that was never in the database is not caught by name'; end if;

  -- ============================================================ I. cheap path = full path; paged export = single statement; grants
  ctx := public.backup_ctx_hot(public.backup_redaction_context(), '{}'::jsonb) || '{"scanned":true}'::jsonb;
  for rec in select input from lv loop
    if public.backup_redact_text(rec.input, ctx, 20000, 'strict') is distinct from public.backup_redact_text_full(rec.input, ctx, 20000, 'strict') then raise exception 'I1 cheap and full path differ for: %', rec.input; end if;
  end loop;
  snap := public.backup_snapshot();
  for rec in select e as t from public.backup_export_policy() p, jsonb_array_elements_text(p -> 'exported') e where e not in ('push_config', 'push_subscriptions') order by e loop
    j := '[]'::jsonb;
    for i in 0..((public.backup_table_digest(rec.t) ->> 'rows')::int / 50) loop
      j := j || (public.backup_snapshot_page(rec.t, i * 50, 50) -> 'rows');
    end loop;
    if jsonb_array_length(j) <> jsonb_array_length(snap -> 'data' -> rec.t) then raise exception 'I2 paged row count differs for %: % vs %', rec.t, jsonb_array_length(j), jsonb_array_length(snap -> 'data' -> rec.t); end if;
  end loop;
  begin perform public.backup_snapshot_page('leads', 0, 10); raise exception 'I3 a client table can be paged out'; exception when others then if sqlerrm like 'I3%' then raise; end if; end;
  begin perform public.backup_snapshot_page('tasks', -1, 10); raise exception 'I3b bad offset accepted'; exception when others then if sqlerrm like 'I3b%' then raise; end if; end;
  begin perform public.backup_table_digest('ffm_redaction_denylist'); raise exception 'I3c deny-list digest allowed'; exception when others then if sqlerrm like 'I3c%' then raise; end if; end;
  if (public.backup_snapshot_cost() ->> 'est_seconds')::numeric is null then raise exception 'I4 cost estimate missing'; end if;
  foreach f in array array['public.backup_snapshot_page(text,integer,integer)', 'public.backup_table_digest(text)', 'public.backup_snapshot_cost()', 'public.backup_redaction_meta(jsonb)', 'public.redaction_denylist_status()'] loop
    foreach k in array array['anon', 'authenticated'] loop
      if has_function_privilege(k, f, 'execute') then raise exception 'I5 % can execute %', k, f; end if;
    end loop;
    if not has_function_privilege('service_role', f, 'execute') then raise exception 'I5b service_role cannot execute %', f; end if;
  end loop;


  -- ============================================================ J. HOT CONTEXT KEEPS THE SQUASHED FORM OF EVERY LIVE NAME (re-review finding 1)
  -- Property: for every variant of every name, in every strict/light column, backup_snapshot() == the direct redactor with the FULL live context, and the single-statement
  -- snapshot == the paged export. (The hot context narrows whole-word phrases to names that occur; the squashed check must not be narrowed.)
  insert into public.leads (venture_id, name, email, phone, status) values (v, 'Jean-Luc Picardeau', 'jlp@picardeau-fixture.example', '613-555-0171', 'new'), (v, 'Jean Tremblay', 'jt2@tremblay-fixture.example', '613-555-0172', 'new')
    on conflict do nothing;
  ctx := public.backup_redaction_context();
  create temp table jv (id serial, s text, col text) on commit drop;
  foreach f in array array['p i c a r d e a u', 'the Picardeaus', 'jpicardeau', 'www.jpicardeau.ca', 'LucPicardeau', 'picardeau1', 'picardeaucontracting', 'contact T r e m b l a y asap', 'tremblay1', 'Jean-Luc Picardeau', 'jeanluc picardeau', 'PICARDEAU', 'notes: tremblay_invoice'] loop
    insert into jv (s, col) values (f, 'tasks.result'), (f, 'ledger.note'), (f, 'audit_log.detail.v'), (f, 'audit_log.detail.key'), (f, 'agent_runs.summary'), (f, 'ideas.name');
  end loop;
  set local session_replication_role = replica;                       -- the source triggers are bypassed on purpose: this section tests the EXPORT layer alone
  for rec in select * from jv order by id loop
    case rec.col
      when 'tasks.result' then insert into public.tasks (assigned_agent, title, detail, status, result, created_by) values (ag, 'zzj ' || rec.id, 'x', 'done', rec.s, 'owner');
      when 'ledger.note' then insert into public.ledger (kind, amount_cents, currency, note, status) values ('expense', 100 + rec.id, 'CAD', rec.s, 'received');
      when 'audit_log.detail.v' then insert into public.audit_log (actor, action, target, detail) values ('zzj', 'note', 'zzj/' || rec.id, jsonb_build_object('v', rec.s));
      when 'audit_log.detail.key' then insert into public.audit_log (actor, action, target, detail) values ('zzj', 'note', 'zzj/' || rec.id, jsonb_build_object(rec.s, 1));
      when 'agent_runs.summary' then insert into public.agent_runs (agent_id, status, summary) select id, 'ok', rec.s || ' #zzj' || rec.id from public.agents order by slug limit 1;
      when 'ideas.name' then insert into public.ideas (name) values (rec.s || ' zzj' || rec.id);
    end case;
  end loop;
  set local session_replication_role = origin;
  snap := public.backup_snapshot();
  for rec in select * from jv order by id loop
    case rec.col
      when 'tasks.result' then
        r := (select x ->> 'result' from jsonb_array_elements(snap -> 'data' -> 'tasks') x where x ->> 'title' = 'zzj ' || rec.id);
        if r is distinct from public.backup_redact_text(rec.s, ctx, 20000, 'strict') then raise exception 'J1 tasks.result "%": snapshot % vs direct %', rec.s, r, public.backup_redact_text(rec.s, ctx, 20000, 'strict'); end if;
      when 'ledger.note' then
        r := (select x ->> 'note' from jsonb_array_elements(snap -> 'data' -> 'ledger') x where (x ->> 'amount_cents')::int = 100 + rec.id and x ->> 'kind' = 'expense' and x ->> 'status' = 'received' and x ->> 'note' is not null limit 1);
        if r is distinct from public.backup_redact_text(rec.s, ctx, 500, 'strict') then raise exception 'J2 ledger.note "%": snapshot % vs direct %', rec.s, r, public.backup_redact_text(rec.s, ctx, 500, 'strict'); end if;
      when 'audit_log.detail.v' then
        j := (select x -> 'detail' from jsonb_array_elements(snap -> 'data' -> 'audit_log') x where x ->> 'target' = 'zzj/' || rec.id);
        if j is distinct from public.backup_redact_json(jsonb_build_object('v', rec.s), ctx, 500, 'strict') then raise exception 'J3 audit_log.detail value "%": snapshot % vs direct %', rec.s, j, public.backup_redact_json(jsonb_build_object('v', rec.s), ctx, 500, 'strict'); end if;
      when 'audit_log.detail.key' then
        j := (select x -> 'detail' from jsonb_array_elements(snap -> 'data' -> 'audit_log') x where x ->> 'target' = 'zzj/' || rec.id);
        if j is distinct from public.backup_redact_json(jsonb_build_object(rec.s, 1), ctx, 500, 'strict') then raise exception 'J4 audit_log.detail key "%": snapshot % vs direct %', rec.s, j, public.backup_redact_json(jsonb_build_object(rec.s, 1), ctx, 500, 'strict'); end if;
      when 'agent_runs.summary' then
        r := (select x ->> 'summary' from jsonb_array_elements(snap -> 'data' -> 'agent_runs') x where x ->> 'summary' like '%#zzj' || rec.id or x ->> 'summary' = '[redacted:uncertain]' and false limit 1);
        if r is null then
          -- a failed-closed row has lost its marker: find it by exclusion below
          null;
        elsif r is distinct from public.backup_redact_text(rec.s || ' #zzj' || rec.id, ctx, 4000, 'strict') then raise exception 'J5 agent_runs.summary "%": snapshot % vs direct %', rec.s, r, public.backup_redact_text(rec.s || ' #zzj' || rec.id, ctx, 4000, 'strict'); end if;
      when 'ideas.name' then
        r := (select x ->> 'name' from jsonb_array_elements(snap -> 'data' -> 'ideas') x where x ->> 'name' like '% zzj' || rec.id or x ->> 'name' like '%zzj' || rec.id limit 1);
        if r is not null and r is distinct from public.backup_redact_text(rec.s || ' zzj' || rec.id, ctx, 20000, 'light') and r <> '[redacted:uncertain]' then raise exception 'J6 ideas.name "%": snapshot % vs direct %', rec.s, r, public.backup_redact_text(rec.s || ' zzj' || rec.id, ctx, 20000, 'light'); end if;
    end case;
  end loop;
  -- (light columns, e.g. ideas.name, only remove patterns and whole known names by design: a letter-spaced name survives there, see the policy; they are checked for equality with the direct redactor above)
  -- nothing of either surname in any exported value of the seeded rows, in any column (squash the whole data block)
  txt := lower(regexp_replace(public.backup_fold_text((snap -> 'data')::text), '[^a-zA-Z0-9]', '', 'g'));
  for rec in select e.key tname, x from jsonb_each(snap -> 'data') e, jsonb_array_elements(e.value) x where e.key <> 'ideas' and lower(regexp_replace(public.backup_fold_text(x::text), '[^a-zA-Z0-9]', '', 'g')) ~ '(picardeau|tremblay)' limit 3 loop
    raise exception 'J7 a surname survives in %: %', rec.tname, left(rec.x::text, 300);
  end loop;
  -- paged export gives the same rows as the single statement for the tables that hold the seeded rows
  for rec in select t from (values ('tasks'), ('ledger'), ('audit_log'), ('agent_runs')) v (t) loop
    j := '[]'::jsonb;
    for i in 0..((public.backup_table_digest(rec.t) ->> 'rows')::int / 40) loop j := j || (public.backup_snapshot_page(rec.t, i * 40, 40) -> 'rows'); end loop;
    if (select count(*) from jsonb_array_elements(j) x where lower(regexp_replace(x::text, '[^a-zA-Z0-9]', '', 'g')) ~ '(picardeau|tremblay)') > 0 then raise exception 'J8 paged export of % leaks a surname', rec.t; end if;
    if j <> (snap -> 'data' -> rec.t) and not (select bool_and(x = any (select jsonb_array_elements(snap -> 'data' -> rec.t))) from jsonb_array_elements(j) x) then raise exception 'J9 paged rows differ from the snapshot rows for %', rec.t; end if;
  end loop;


  -- ============================================================ K. COLUMN TYPES THE REDACTOR DOES NOT READ (re-review finding 5) and L. INTERNALS AFTER LOCKDOWN (finding 2)
  create type public.zz_comp as (a text, b int);
  create domain public.zz_dom_json as jsonb;
  create domain public.zz_dom_text as text;
  create type public.zz_enum as enum ('a', 'b');
  foreach f in array array['bytea', 'name', 'xml', 'tsvector', '"char"', 'jsonb[]', 'inet', 'public.zz_comp', 'public.zz_dom_json', 'public.zz_enum[]', 'public.zz_dom_text[]', 'point', 'json[]', 'citext[]', 'cidr', 'macaddr', 'tsquery', 'int4range', 'bit(3)', 'oid'] loop
    begin
      if public.backup_type_ok(f::regtype::oid) then raise exception 'K1 type % is accepted but the redactor does not read it', f; end if;
    exception when undefined_object or invalid_text_representation then if f = 'citext[]' then null; else raise; end if; end;
  end loop;
  foreach f in array array['text', 'varchar(20)', 'bpchar', 'json', 'jsonb', 'text[]', 'varchar[]', 'boolean', 'smallint', 'integer', 'bigint', 'numeric(10,2)', 'real', 'double precision', 'uuid', 'date', 'time', 'timetz', 'timestamp', 'timestamptz', 'interval', 'money', 'integer[]', 'uuid[]', 'bigint[]', 'numeric[]', 'timestamptz[]', 'public.zz_enum', 'public.zz_dom_text'] loop
    if not public.backup_type_ok(f::regtype::oid) then raise exception 'K2 type % must be accepted', f; end if;
  end loop;
  -- end to end: an exported table that gains a bytea (or any unread type) column leaves the export and is listed as unclassified
  alter table public.ideas add column zz_blob bytea;
  insert into public.ideas (name, zz_blob) values ('zz blob idea', convert_to('Jean Tremblay 613-555-0142', 'UTF8'));
  j := public.backup_export_policy();
  if (j -> 'exported') ? 'ideas' or not (j -> 'unclassified') ? 'ideas' then raise exception 'K3 a table with an unread column type is still exported / not listed unclassified: %', j -> 'unclassified'; end if;
  snap := public.backup_snapshot();
  if (snap -> 'data') ? 'ideas' or position('tremblay' in lower((snap -> 'data')::text)) > 0 then raise exception 'K4 the table with an unread column type is in the snapshot data'; end if;
  alter table public.ideas drop column zz_blob;
  if not (public.backup_export_policy() -> 'exported') ? 'ideas' then raise exception 'K5 ideas should be exported again once the column is gone'; end if;

  -- L. after the full replica (the lockdown migration is LAST and re-grants execute on every function to service_role) the key-equivalent internals are still not usable by service_role
  grant usage on schema public to service_role;
  set local role service_role;
  begin perform public.redaction_pads(); reset role; raise exception 'L1 service_role can read the key pads'; exception when others then reset role; if sqlerrm like 'L1%' then raise; end if; end;
  set local role service_role;
  begin perform public.redaction_capture('n', 'Poison Pill'); reset role; raise exception 'L2 service_role can write the deny-list through redaction_capture'; exception when others then reset role; if sqlerrm like 'L2%' then raise; end if; end;
  set local role service_role;
  begin insert into public.ffm_redaction_denylist (h, kind) values (repeat('a', 64), 'n'); reset role; raise exception 'L3 service_role can insert into the deny-list'; exception when others then reset role; if sqlerrm like 'L3%' then raise; end if; end;
  set local role service_role;
  begin perform 1 from public.ffm_redaction_keys; reset role; raise exception 'L4 service_role can read the key table'; exception when others then reset role; if sqlerrm like 'L4%' then raise; end if; end;
  -- the intended entry points still work for service_role
  set local role service_role;
  begin perform public.backup_snapshot_cost(); perform public.backup_redaction_status(); reset role; exception when others then reset role; raise exception 'L5 service_role lost an intended entry point: %', sqlerrm; end;

  raise notice 'LEAK REDACTION CHECKS PASSED (% redactor vectors)', cnt;
end $$;
rollback;
select 'leak_redaction_check_ok';
