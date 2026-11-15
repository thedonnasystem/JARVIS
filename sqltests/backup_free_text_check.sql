-- Owner directive E: free text written by agents, scrapers, clients or counterparties is NOT exported (mode BLANK) instead of relying on pattern redaction. PRODUCTION spec (no override).
-- SCRATCH replica only; one transaction, rolled back.
begin;
do $$
declare
  want_blank text[] := array['action_log.detail','action_log.evidence','action_log.reason','action_log.result','agent_runs.summary','approval_requests.recommendation','bank_transactions.description','bank_transactions.note',
    'escalations.evidence','escalations.resolution','escalations.summary','evidence_sources.final_url','evidence_sources.text','evidence_sources.title','evidence_sources.url','executor_runs.purpose','executor_runs.refusal_reason',
    'human_handoffs.task','human_handoffs.url','human_handoffs.why_human','ideas.demand_source','ideas.description','ideas.kill_metric','ideas.result','ideas.revisit_trigger','memory.content','memory.source','missions.checkpoint',
    'missions.evidence','missions.next_action','missions.owner_decision','missions.plan','missions.result','missions.risks','missions.success_definition','missions.verdict_reason','owner_messages.answer','owner_messages.body',
    'owner_messages.options','payment_instructions.payee','predictions.action_ref','predictions.expected','predictions.outcome','reconciliation_flags.detail','tasks.detail','tasks.result','tasks.title','web_messages.body','web_messages.payload'];
  want_strict text[] := array['audit_log.detail', 'ledger.note', 'missions.objective', 'missions.title'];
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
  alter table public.ideas add column zz_new_note text;
  if not exists (select 1 from public.backup_effective_spec(public.backup_export_policy() -> 'exported') where table_name = 'ideas' and column_name = 'zz_new_note' and mode = 'strict' and not classified) then raise exception 'E9 an unclassified column is not strict'; end if;
  alter table public.ideas drop column zz_new_note;
  raise notice 'FREE TEXT CHECKS PASSED';
end $$;
rollback;
select 'backup_free_text_check_ok';
