-- Synthetic data for the redaction performance test (SCRATCH ONLY). psql -v audit=50000 -v tasks=10000 -v leads=40 -f scripts/perf_redaction_seed.sql
-- Shapes follow production: audit_log.detail small json (codes, counts, ids), tasks.result ~11.5k characters of research prose with URLs, prices and dates.
\set ON_ERROR_STOP on
select set_config('perf.audit', :'audit', false), set_config('perf.tasks', :'tasks', false), set_config('perf.leads', :'leads', false) \gset
do $$
declare v uuid; n_leads int := current_setting('perf.leads')::int; n_aud int := current_setting('perf.audit')::int; n_tasks int := current_setting('perf.tasks')::int;
  words text[] := array['market','pricing','supplier','quote','estimate','service','heating','furnace','install','warranty','review','rating','competitor','region','coverage','budget','margin','invoice','contract','schedule','crew','permit','inspection','customer','lead','follow','proposal','channel','campaign','audience','budget','keyword','landing','conversion','offer','region','season','winter','demand','capacity','cost','revenue','profit','trend','report','summary','finding','source','verified','checked','listing','directory','association','member','chapter','event','training','certified','licensed','insured','bonded','local','regional','national','average','median','range','typical','common','recent','current','annual','monthly'];
  doms text[] := array['https://example.ca/industry/report','https://example.org/pricing/2026','https://data.example.net/api/v2/series?id=hvac','https://example.ca/staff/directory','https://news.example.com/2026/11/heating-demand'];
begin
  select id into v from public.ventures where slug = 'donna' limit 1;
  for i in 1..n_leads loop
    insert into public.leads (venture_id, name, email, phone, status) values (v, 'Perfname' || i || ' Perfsurname' || i, 'perf' || i || '@perf-co' || i || '.example', '613-555-' || lpad((1000 + i)::text, 4, '0'), 'new') on conflict do nothing;
  end loop;
  insert into public.audit_log (actor, action, target, detail)
  select 'perf', (array['do_not_contact','deal_stage','task_done','lead_added','mission_step'])[1 + (g % 5)], 'leads/' || gen_random_uuid(),
         jsonb_build_object('reason_code', (array['unsubscribe_reply','lead_flag','owner_text','none'])[1 + (g % 4)], 'reason_chars', g % 300, 'leads_marked', 1, 'to', 'negotiating', 'note_chars', g % 200, 'run', g,
                            'summary', 'step ' || g || ' completed for the weekly pipeline; cost ' || (g % 97) || ' cents; 3 sources checked')
    from generate_series(1, n_aud) g;
  insert into public.tasks (title, detail, status, result, created_by)
  select 'Research task ' || g, 'Find pricing and supplier information for region ' || (g % 40), 'done',
         (select string_agg(w || ' ' || case when k % 23 = 0 then doms[1 + (k % 5)] when k % 31 = 0 then '$' || (k * 37 % 5000) || '.00' when k % 41 = 0 then '2026-11-' || lpad((1 + k % 28)::text, 2, '0') else '' end, ' ')
            from (select words[1 + ((g * 7 + k * 13) % array_length(words, 1))] w, k from generate_series(1, 1100) k) q),
         'perf'
    from generate_series(1, n_tasks) g;
end $$;
analyze public.tasks; analyze public.audit_log;
select (select count(*) from public.audit_log) audit, (select count(*) from public.tasks) tasks, (select avg(length(result)) from public.tasks)::int avg_result_len, (select count(*) from public.leads) leads;
