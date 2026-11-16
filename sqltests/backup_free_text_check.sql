-- Owner directive E: free text written by agents, scrapers, clients or counterparties is NOT exported (mode BLANK) instead of relying on pattern redaction. PRODUCTION spec (no override).
-- SCRATCH replica only; one transaction, rolled back.
begin;
do $$
declare
  want_blank text[] := array['account_requests.purpose','account_requests.signup_url','account_requests.vendor','accounts_registry.notes','accounts_registry.purpose','build_requests.risk','build_requests.rollback_plan','build_requests.spec','build_requests.test_result','build_requests.title','ideas.name','integration_status.detail','llm_calls.purpose','org_changes.alternatives','org_changes.change','org_changes.cost','org_changes.disagrees_with_owner','org_changes.gain','org_changes.risk','org_changes.target','org_changes.time_to_results','payment_instructions.purpose','payment_instructions.receipt_ref','spend_reservations.alternatives','spend_reservations.expected_benefit','spend_reservations.purpose','spend_reservations.receipt_ref','spend_reservations.vendor','system_state.pause_reason','systems.notes','tool_registry.notes','tool_registry.purpose','venture_assets.name','venture_assets.notes','venture_assets.url','venture_procedures.steps',
    'action_log.detail','action_log.evidence','action_log.reason','action_log.result','agent_runs.summary','approval_requests.recommendation','bank_transactions.description','bank_transactions.note',
    'escalations.evidence','escalations.resolution','escalations.summary','evidence_sources.final_url','evidence_sources.text','evidence_sources.title','evidence_sources.url','executor_runs.purpose','executor_runs.refusal_reason',
    'human_handoffs.task','human_handoffs.url','human_handoffs.why_human','ideas.demand_source','ideas.description','ideas.kill_metric','ideas.result','ideas.revisit_trigger','memory.content','memory.source','missions.checkpoint',
    'missions.evidence','missions.next_action','missions.owner_decision','missions.plan','missions.result','missions.risks','missions.success_definition','missions.verdict_reason','owner_messages.answer','owner_messages.body',
    'owner_messages.options','payment_instructions.payee','predictions.action_ref','predictions.expected','predictions.outcome','reconciliation_flags.detail','tasks.detail','tasks.result','tasks.title','web_messages.body','web_messages.payload',
    'agents.charter','agents.metric','ventures.description','ventures.primary_metric','venture_goals.metric','missions.objective'];
  want_strict text[] := array['agents.title', 'audit_log.detail', 'departments.name', 'ledger.note', 'missions.title', 'venture_config.call_to_action', 'venture_config.offer', 'venture_goals.unit', 'ventures.name'];
  got text[]; v uuid; ag text; agid uuid; snap jsonb; pg jsonb; rec record; cn text; n int; txt text; mid uuid; i int;
begin
  select id into v from public.ventures order by slug limit 1; select slug, id into ag, agid from public.agents order by slug limit 1;
  -- E1 the production classification: exactly these columns are blank, exactly these are strict (a new one must be added here on purpose)
  got := array(select table_name || '.' || column_name from public.backup_effective_spec(public.backup_export_policy() -> 'exported') where mode = 'blank' order by 1);
  if got <> (select array_agg(w order by w) from unnest(want_blank) w) then raise exception 'E1 blank columns differ: only in db %, only in test %', array(select u from unnest(got) u except select w from unnest(want_blank) w), array(select w from unnest(want_blank) w except select u from unnest(got) u); end if;
  got := array(select table_name || '.' || column_name from public.backup_effective_spec(public.backup_export_policy() -> 'exported') where mode = 'strict' order by 1);
  if got <> want_strict then raise exception 'E2 strict columns differ: %', got; end if;
  if exists (select 1 from public.backup_effective_spec(public.backup_export_policy() -> 'exported') where not classified) then raise exception 'E3 an exported text-like column is unclassified'; end if;
  -- the named agent-written columns are all blank
  foreach cn in array array['agent_runs.summary', 'tasks.result', 'tasks.title', 'tasks.detail', 'memory.content', 'owner_messages.body', 'missions.result', 'escalations.evidence'] loop
    if not cn = any (want_blank) then raise exception 'E4 % is not blank', cn; end if;
  end loop;

  -- E5 seeded client text in the named columns never reaches the single statement or the paged export, whatever its shape
  set local session_replication_role = replica;
  insert into public.tasks (assigned_agent, title, detail, status, result, created_by) values (ag, 'Call Zzmarker Quillfeather about 613-555-0144', 'detail for zzmarker quillfeather', 'done', 'Zzmarker Quillfeather, z.quillfeather@example.test, 613-555-0144', 'owner');
  insert into public.agent_runs (agent_id, status, summary) values (agid, 'ok', 'researched Zzmarker Quillfeather');
  insert into public.memory (kind, content, source) values ('lesson', 'Zzmarker Quillfeather prefers texts', 'zzmarker source');
  insert into public.owner_messages (from_agent, kind, channel, body) values ('jarvis', 'health', 'telegram', 'Zzmarker Quillfeather replied');
  insert into public.escalations (from_agent, kind, summary, evidence, resolution) values (ag, 'failure', 'zzmarker summary', '{"who": "Zzmarker Quillfeather"}'::jsonb, 'zzmarker resolution');
  insert into public.missions (title, objective, status, result, plan, evidence, checkpoint) values ('zz free text mission', 'a long enough objective for the length check to pass here', 'captured', 'Zzmarker Quillfeather result', '[{"s":"Zzmarker step"}]'::jsonb, '[{"q":"Zzmarker quote"}]'::jsonb, '{"n":"Zzmarker"}'::jsonb);
  set local session_replication_role = origin;
  snap := public.backup_snapshot();
  if position('zzmarker' in lower((snap -> 'data')::text)) > 0 then raise exception 'E5 client text reached the single-statement export'; end if;
  foreach cn in array array['tasks', 'agent_runs', 'memory', 'owner_messages', 'escalations', 'missions'] loop
    for i in 0..((public.backup_table_digest(cn) ->> 'rows')::int / 50) loop
      pg := public.backup_snapshot_page(cn, i * 50, 50);
      if position('zzmarker' in lower((pg -> 'rows')::text)) > 0 then raise exception 'E6 client text reached the paged export of %', cn; end if;
    end loop;
  end loop;
  -- E7 every blank column of every exported row is empty (text '') or JSON null, all tables
  for rec in select e.key tname, s.column_name, s.kind from jsonb_each(snap -> 'data') e, public.backup_effective_spec(public.backup_export_policy() -> 'exported') s where s.table_name = e.key and s.mode = 'blank' loop
    if exists (select 1 from jsonb_array_elements(snap -> 'data' -> rec.tname) r where r -> rec.column_name is not null and jsonb_typeof(r -> rec.column_name) not in ('null') and r ->> rec.column_name <> '') then
      raise exception 'E7 %.% is not blank in the export', rec.tname, rec.column_name; end if;
  end loop;
  -- E8 what must NOT change: ids, counts, statuses, amounts survive in the blanked tables
  if (select count(*) from jsonb_array_elements(snap -> 'data' -> 'tasks')) <> (select count(*) from public.tasks) then raise exception 'E8 task rows lost'; end if;
  if exists (select 1 from jsonb_array_elements(snap -> 'data' -> 'tasks') r where r ->> 'status' is null or r ->> 'id' is null) then raise exception 'E8b task id/status lost'; end if;
  -- E9 a column nobody classified is strict (fails closed) and is reported
  -- E10 (round 6) LIGHT is not a guarantee-free zone: a known / erased / deleted name glued to other characters, pluralised or letter-spaced blanks the whole LIGHT field (bounded over-blanking), a clean config text is untouched
  insert into public.leads (venture_id, name, email, status) values (v, 'Zzbrackenfeather Quillmoor', 'zzbrackenfeather@example.test', 'new');
  declare ctx jsonb := public.backup_redaction_context(); w text;
  begin
    foreach w in array array['jzzbrackenfeather', 'zzbrackenfeather2024', 'the Zzbrackenfeathers', 'Zzbrackenfeather', 'z z b r a c k e n f e a t h e r', 'quillmoorco'] loop
      if public.backup_redact_text(w, ctx, 500, 'light') like '%feather%' or public.backup_redact_text(w, ctx, 500, 'light') like '%quillmoor%' then raise exception 'E10 LIGHT let % through: %', w, public.backup_redact_text(w, ctx, 500, 'light'); end if;
    end loop;
    if public.backup_redact_text('Heating and cooling service plan', ctx, 500, 'light') <> 'Heating and cooling service plan' then raise exception 'E10b clean configuration text was changed in LIGHT'; end if;
  end;
  update public.agents set title = 'Chief of jzzbrackenfeather' where slug = ag;
  if position('zzbrackenfeather' in lower(((public.backup_snapshot() -> 'data' -> 'agents'))::text)) > 0 then raise exception 'E11 a glued known name reached the single-statement export of a LIGHT column (agents.title)'; end if;
  pg := public.backup_snapshot_page('agents', 0, 50);
  if position('zzbrackenfeather' in lower((pg -> 'rows')::text)) > 0 then raise exception 'E11b a glued known name reached the paged export of a LIGHT column'; end if;
  -- E12 (round 7, E1b) 3-4 character known name tokens glued / pluralised / digit-suffixed are blanked in LIGHT and STRICT, and the bare word is still redacted IN PLACE (the field survives)
  insert into public.leads (venture_id, name, email, status) values (v, 'Imran Khan', 'e12a@example.test', 'new'), (v, 'Priya Shah', 'e12b@example.test', 'new'), (v, 'Wei Lee', 'e12c@example.test', 'new'),
                                                                   (v, 'Tom Fox', 'e12d@example.test', 'new'), (v, 'Sam Wong', 'e12e@example.test', 'new');
  declare ctx2 jsonb := public.backup_redaction_context(); w2 text; m2 text;
  begin
    foreach m2 in array array['light', 'strict'] loop
      foreach w2 in array array['the Khans', 'khan2024', 'jkhan', 'Shah123', 'fox2024', 'Lees', 'LeeFamily', 'Wongs', 'jfox', 'mrfox', 'call the Khans tomorrow about the quote', 'Mr Wong2024 asked'] loop
        if public.backup_redact_text(w2, ctx2, 500, m2) ~* '(khan|shah|lee|fox|wong)' then raise exception 'E12 % let % through: %', m2, w2, public.backup_redact_text(w2, ctx2, 500, m2); end if;
      end loop;
      if public.backup_redact_text('Call Imran Khan today', ctx2, 500, m2) !~ 'today' or public.backup_redact_text('Call Imran Khan today', ctx2, 500, m2) ~* 'khan' then raise exception 'E12b % the bare name must be redacted in place: %', m2, public.backup_redact_text('Call Imran Khan today', ctx2, 500, m2); end if;
      if public.backup_redact_text('Heating and cooling service plan, review quarterly', ctx2, 500, m2) <> 'Heating and cooling service plan, review quarterly' then raise exception 'E12c % clean text was changed', m2; end if;
    end loop;
  end;
  insert into public.handbook (version, content, active) values ((select coalesce(max(version), 0) + 1 from public.handbook), 'owner note: the Khans and khan2024', false);
  update public.ledger set note = 'payout jfox and Shah123' where id = (select id from public.ledger order by id limit 1);
  if lower((public.backup_snapshot() -> 'data' -> 'handbook')::text || (public.backup_snapshot() -> 'data' -> 'ledger')::text) ~ '(khan|shah123|jfox)' then raise exception 'E12d a short glued known name reached the single-statement export (LIGHT or STRICT column)'; end if;
  pg := public.backup_snapshot_page('handbook', 0, 100); if lower((pg -> 'rows')::text) ~ 'khan' then raise exception 'E12e a short glued known name reached the paged export (LIGHT)'; end if;
  pg := public.backup_snapshot_page('ledger', 0, 100); if lower((pg -> 'rows')::text) ~ '(shah123|jfox)' then raise exception 'E12f a short glued known name reached the paged export (STRICT)'; end if;
  -- ===== Round 8 =====
  -- S2 (over-blanking): with 19 ordinary short names on file, ordinary prose is exported UNCHANGED in LIGHT and STRICT (it used to be blanked whole: 'cus'+'tom', 'to'+'day', 'p'+'rice'+'s', 'wor'+'king').
  --    The real forms of the same names are still removed, IN PLACE: the rest of the field survives. S3: the forms the round-7 rule missed.
  insert into public.leads (venture_id, name, email, status)
  select v, z.nm, 's2' || z.o || '@example.test', 'new' from unnest(array['Ann Day', 'Art Ross', 'Tim Rice', 'Ken Long', 'Sam King', 'Ray Ward', 'Dan Hart', 'Sue Low', 'Mary Chen', 'Ted Hank', 'Ron Bell', 'Kay Hall', 'Joy Park',
                                                                    'Eric Lane', 'Pete Ford', 'Ruth Wood', 'Pam Hill', 'Andy Cook', 'Mark Bill']) with ordinality z (nm, o);
  declare ctx3 jsonb := public.backup_redaction_context(); w3 text; m3 text; o3 text; nmark int := 0;
    prose text[] := array['Custom offers: start with part one, making sure the token is working. Forward the award list.',
                          'Today and Monday the prices changed several times across all plans; thanks for the summary of the kitchen chart.',
                          'Start a paid subscription', 'Allow follow up emails below the primary issue; okay to enjoy the generic sales array.',
                          'The handy system tokens are stolen unless rules, files and bills are tracked; remarks welcome.'];
    forms text[] := array['k h a n', 'K.H.A.N', 'k-h-a-n called', 'khanfamily2024', 'KhanRoofing', 'khanroofing', 'missfox', 'profkhan', 'khanjr', 'khanz', 'khanss', 'shahco', 'wonginc', 'DrKing asked', 'jking', 'JKing', 'kingfamily',
                          'King2024', 'the Kings2 file', 'mrday', 'd a y', 'MsHart', 'chenco', 'lowinc', 'the Khans', 'khan2024', 'jkhan', 'Shah123', 'fox2024', 'Lees', 'LeeFamily', 'Wongs', 'jfox', 'mrfox'];
  begin
    foreach m3 in array array['light', 'strict'] loop
      foreach w3 in array prose loop
        o3 := public.backup_redact_text(w3, ctx3, 500, m3);
        nmark := nmark + (select count(*) from regexp_matches(o3, '\[redacted', 'g'));
        if o3 <> w3 then raise exception 'S2 % ordinary prose was changed. expected: %  actual: %', m3, w3, o3; end if;
      end loop;
      foreach w3 in array forms loop
        o3 := public.backup_redact_text(w3, ctx3, 500, m3);
        if o3 ~* '(khan|shah|lee|fox|wong|king|day|hart|chen|low)' or o3 ~* 'k.h.a.n|d.a.y' then raise exception 'S3 % let % through: %', m3, w3, o3; end if;
        if o3 = '[redacted:uncertain]' then raise exception 'S2 % a short-name form blanked the whole field instead of the word: %', m3, w3; end if;
      end loop;
      -- in place: the words around the name survive
      o3 := public.backup_redact_text('Quote for the Khans is ready, jking will call on Monday', ctx3, 500, m3);
      if o3 <> 'Quote for the [redacted:name] is ready, [redacted:name] will call on Monday' then raise exception 'S2 % expected in-place redaction, got: %', m3, o3; end if;
    end loop;
    if nmark <> 0 then raise exception 'S2 % redaction markers in ordinary prose (expected 0)', nmark; end if;
    -- documented accepted residuals (policy rule 15): a 4+ letter arbitrary prefix, an arbitrary non-business suffix, and the PLURAL of a name that is an ordinary word when it is lower-case, sentence-initial or ALL CAPS
    -- an ordinary word that is a client's name + s, Capitalised in the middle of a sentence, is a name: redacted in place. Weekdays stay.
    foreach m3 in array array['light', 'strict'] loop
      o3 := public.backup_redact_text('Please call the Kings tomorrow, then the Days, on Monday', ctx3, 500, m3);
      if o3 <> 'Please call the [redacted:name] tomorrow, then the [redacted:name], on Monday' then raise exception 'S3 % a Capitalised mid-sentence plural of a known name. expected in-place redaction, actual: %', m3, o3; end if;
    end loop;
    foreach w3 in array array['xxxxkhan', 'khanabc', 'kings', 'days', 'Kings of the road', 'KINGS'] loop
      if public.backup_redact_text(w3, ctx3, 500, 'strict') <> w3 then raise exception 'S3 the documented residual list is out of date: % is now redacted (update the policy)', w3; end if;
    end loop;
  end;
  -- S2 through the real export: a handbook and a ledger note of ordinary prose survive whole; a policy description is not lost
  insert into public.handbook (version, content, active) values ((select coalesce(max(version), 0) + 1 from public.handbook), 'Custom offers: start with part one, making sure the token is working. Forward the award list.', false);
  snap := public.backup_snapshot();
  if not exists (select 1 from jsonb_array_elements(snap -> 'data' -> 'handbook') h where h ->> 'content' = 'Custom offers: start with part one, making sure the token is working. Forward the award list.') then
    raise exception 'S2 the handbook prose did not survive the export: %', (select jsonb_agg(h ->> 'content') from jsonb_array_elements(snap -> 'data' -> 'handbook') h where h ->> 'content' ~ 'offers|redacted');
  end if;
  if exists (select 1 from public.action_policy p join jsonb_array_elements(snap -> 'data' -> 'action_policy') e on e ->> 'action' = p.action where e ->> 'description' is distinct from p.description) then
    raise exception 'S2 an action_policy description was changed by the export: %', (select jsonb_agg(e ->> 'description') from public.action_policy p join jsonb_array_elements(snap -> 'data' -> 'action_policy') e on e ->> 'action' = p.action where e ->> 'description' is distinct from p.description);
  end if;

  -- S1 a KNOWN client name must not leave through an identifier. Venture created the way hq_start_venture does it (create_venture copies the slug to departments, agents, the manager and the audit trail).
  reset session_replication_role;
  insert into public.leads (venture_id, name, email, status) values (v, 'Imran Khanzada', 's1@example.test', 'new');
  begin
    perform public.create_venture('khanzada-roofing', 'Khanzada Roofing', 'revenue', 'revenue', 0, 'Roofing for the Khanzada family', 'jarvis');
    raise exception 'S1w the write path accepted a slug that carries a known client name';
  exception when check_violation then
    if sqlerrm ~* 'khanzada' then raise exception 'S1w the refusal repeats the name: %', sqlerrm; end if;
  end;
  -- names learned AFTER the venture exists, short names and glued names are the export's job: create the ventures with the guard off, as if the leads had come later
  alter table public.ventures disable trigger redaction_venture_slug_guard;
  perform public.create_venture('khanzada-roofing', 'Khanzada Roofing', 'revenue', 'revenue', 0, 'Roofing for the Khanzada family', 'jarvis');
  perform public.create_venture('foxroofing', 'Fox Roofing', 'revenue', 'revenue', 0, 'Roofing for the Fox family', 'jarvis');
  perform public.create_venture('khanzadaplumbing', 'Khanzadaplumbing', 'revenue', 'revenue', 0, 'Plumbing for the same family', 'jarvis');
  alter table public.ventures enable trigger redaction_venture_slug_guard;
  insert into public.owner_messages (from_agent, kind, channel, needs_decision, ref_table, body) values ('jarvis', 'proposal', 'telegram', true, 'activate_venture:khanzada-roofing', 'x');
  insert into public.tasks (assigned_agent, title, status, created_by, dedupe_key) values ('khanzada-roofing-manager', 't', 'todo', 'khanzada-roofing-manager', 'plan:khanzada-roofing:1');
  insert into public.leads (venture_id, name, email, status) values (v, 'Donna Jarvis', 's1b@example.test', 'new');        -- a client who shares a word with the system's own slugs
  snap := public.backup_snapshot();
  select string_agg(k, ', ') into txt from jsonb_each(snap -> 'data') e (k, val) where val::text ~* 'khanzada|fox';
  if txt is not null then raise exception 'S1 a known client name reached the export. expected: none. actual: in table(s) %', txt; end if;
  for rec in select t.k from (values ('ventures'), ('departments'), ('agents'), ('audit_log'), ('owner_messages'), ('tasks')) t (k) loop
    pg := public.backup_snapshot_page(rec.k, 0, 5000);
    if (pg -> 'rows')::text ~* 'khanzada|fox' then raise exception 'S1 a known client name reached the PAGED export of %', rec.k; end if;
  end loop;
  -- the pseudonym is the same everywhere, so the references still join, and distinct slugs stay distinct (unique indexes survive a restore)
  select e ->> 'slug' into txt from jsonb_array_elements(snap -> 'data' -> 'ventures') e where e ->> 'manager_agent' ~ '^n[0-9a-f]{10}-roofing-manager$';
  if txt is null or txt !~ '^n[0-9a-f]{10}-roofing$' then raise exception 'S1 expected a pseudonymous slug of the form n<10 hex>-roofing, got %', txt; end if;
  if not exists (select 1 from jsonb_array_elements(snap -> 'data' -> 'departments') e where e ->> 'slug' = txt)
     or not exists (select 1 from jsonb_array_elements(snap -> 'data' -> 'agents') e where e ->> 'slug' = txt || '-manager' and e ->> 'department_slug' = txt)
     or not exists (select 1 from jsonb_array_elements(snap -> 'data' -> 'audit_log') e where e ->> 'target' = 'ventures/' || txt)
     or not exists (select 1 from jsonb_array_elements(snap -> 'data' -> 'owner_messages') e where e ->> 'ref_table' = 'activate_venture:' || txt)
     or not exists (select 1 from jsonb_array_elements(snap -> 'data' -> 'tasks') e where e ->> 'assigned_agent' = txt || '-manager' and e ->> 'dedupe_key' = 'plan:' || txt || ':1') then
    raise exception 'S1 the pseudonym is not consistent across ventures / departments / agents / audit_log / owner_messages / tasks (slug %)', txt;
  end if;
  if (select count(distinct e ->> 'slug') from jsonb_array_elements(snap -> 'data' -> 'ventures') e) <> (select count(*) from public.ventures) then raise exception 'S1 two venture slugs collapsed into one (a restore would hit the unique index)'; end if;
  if (select count(distinct e ->> 'slug') from jsonb_array_elements(snap -> 'data' -> 'agents') e) <> (select count(*) from public.agents) then raise exception 'S1 two agent slugs collapsed into one'; end if;
  if not exists (select 1 from jsonb_array_elements(snap -> 'data' -> 'ventures') e where e ->> 'slug' ~ '^r[0-9a-f]{16}$') then raise exception 'S1 the glued slug (khanzadaplumbing) was not replaced whole'; end if;
  -- the system's own slugs are untouched although a client is called Donna Jarvis
  if not exists (select 1 from jsonb_array_elements(snap -> 'data' -> 'agents') e where e ->> 'slug' = 'jarvis') or (select count(*) from jsonb_array_elements(snap -> 'data' -> 'ventures') e where e ->> 'slug' = 'donna') <> (select count(*) from public.ventures where slug = 'donna') then
    raise exception 'S1 a system slug (jarvis / donna) was pseudonymised: a restore could not find it';
  end if;
  -- same input, same pseudonym, on a second export (keyed, deterministic)
  if (select e ->> 'slug' from jsonb_array_elements(public.backup_snapshot() -> 'data' -> 'ventures') e where e ->> 'manager_agent' ~ '^n[0-9a-f]{10}-roofing-manager$') is distinct from txt then raise exception 'S1 the pseudonym changed between two exports'; end if;
  -- N4: the venture description is blank in ventures AND in the mission objective that hq_ventures.start copies it into
  insert into public.missions (title, objective, status, created_by) values ('Validate venture: Zzobj', 'Venture ''Zzobj'' (zzobj): cleaning for Mrs Quillfeatherstone of Ottawa', 'captured', 'jarvis');
  if (public.backup_snapshot() -> 'data' -> 'missions')::text ~* 'quillfeatherstone' then raise exception 'N4 the venture description left through missions.objective'; end if;

  alter table public.ideas add column zz_new_note text;
  if not exists (select 1 from public.backup_effective_spec(public.backup_export_policy() -> 'exported') where table_name = 'ideas' and column_name = 'zz_new_note' and mode = 'strict' and not classified) then raise exception 'E9 an unclassified column is not strict'; end if;
  alter table public.ideas drop column zz_new_note;
  raise notice 'FREE TEXT CHECKS PASSED';
end $$;
rollback;
select 'backup_free_text_check_ok';
