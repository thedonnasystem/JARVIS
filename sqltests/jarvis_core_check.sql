-- Jarvis core v2 (migrations/20261123_jarvis_core_v1.sql). Everything in one transaction, rolled back. Run on a fresh apply (scripts/replica/run.sh does).
begin;
grant usage on schema public to anon, authenticated, service_role;   -- as on Supabase (inside the rolled-back transaction)
create function pg_temp.svc(p_sql text) returns text language plpgsql as $$
declare r text;
begin
  set local role service_role;
  begin execute p_sql into r; exception when others then reset role; return 'ERR:' || sqlerrm; end;
  reset role;
  return 'OK:' || coalesce(r, '');
end $$;
create function pg_temp.as_role(p_role text, p_sql text) returns text language plpgsql as $$
declare r text;
begin
  execute format('set local role %I', p_role);
  begin execute p_sql into r; exception when others then reset role; return 'ERR:' || sqlerrm; end;
  reset role;
  return 'OK:' || coalesce(r, '');
end $$;

do $$
declare c public.jarvis_core_config; j1 uuid; j2 uuid; j3 uuid; r record; n int; st text; t timestamptz; a uuid; res jsonb; cap0 int; ks0 boolean; mode0 text;
begin
  select daily_spend_cap_cents, kill_switch, mode into cap0, ks0, mode0 from public.system_state where id = 1;

  -- J1 dormant by default
  select * into c from public.jarvis_core_config where id = 1;
  if c.core_enabled or c.worker_enabled or c.self_edit_enabled or c.self_automation_enabled or c.whatsapp_enabled or c.emergency_call_enabled then raise exception 'J1 a switch is on by default'; end if;
  if c.active_divisions <> array['donna', 'wolf-squad', 'ffm'] then raise exception 'J1 active divisions %', c.active_divisions; end if;
  if (select status from public.agents where slug = 'jarvis-core') <> 'paused' then raise exception 'J1 jarvis-core agent is not paused'; end if;
  begin perform public.reserve_llm_budget('jarvis-core', 1, 'claude-haiku-5-5', 'jarvis:donna:-:test'); raise exception 'J1 the gateway did not refuse the paused core agent';
  exception when others then if sqlerrm not like 'Agent jarvis-core is paused%' then raise; end if; end;
  if (select count(*) from public.jarvis_jobs) <> 0 then raise exception 'J1 queue not empty'; end if;

  -- J2 only the owner flips switches; the bot is refused
  if pg_temp.svc($q$select public.jarvis_set_config('core_enabled', 'true')::text$q$) not like 'ERR:owner approval required%' then raise exception 'J2 the bot could change the config'; end if;
  if pg_temp.svc($q$update public.jarvis_core_config set core_enabled = true returning 'x'$q$) not like 'ERR:permission denied%' then raise exception 'J2 the bot could update the config table'; end if;
  if pg_temp.svc($q$select public.jarvis_set_config('self_edit_enabled', 'true')::text$q$) not like 'ERR:%' then raise exception 'J2 bot self_edit'; end if;
  begin perform public.jarvis_set_config('kill_switch', 'true'); raise exception 'J2 unknown key accepted'; exception when others then if sqlerrm not like 'jarvis_set_config: unknown setting%' then raise; end if; end;
  begin perform public.jarvis_set_config('core_enabled', '"yes"'); raise exception 'J2 non-boolean accepted'; exception when others then if sqlerrm not like '%needs true or false%' then raise; end if; end;

  -- J3 queue: dormant divisions refused, dedupe
  if pg_temp.svc($q$select public.jarvis_enqueue('real-estate', 'scan')::text$q$) not like 'ERR:division real-estate is dormant%' then raise exception 'J3 dormant division accepted'; end if;
  st := pg_temp.svc($q$select public.jarvis_enqueue('donna', 'lead.followup', '{"n": 1}', 'normal', 'dk-1')::text$q$);
  if st not like 'OK:%' then raise exception 'J3 enqueue failed: %', st; end if;
  j1 := substr(st, 4)::uuid;
  if pg_temp.svc($q$select public.jarvis_enqueue('donna', 'lead.followup', '{"n": 2}', 'normal', 'dk-1')::text$q$) <> 'OK:' || j1 then raise exception 'J3 dedupe made a second job'; end if;
  if (select count(*) from public.jarvis_job_events where job_id = j1 and event = 'deduped') <> 1 then raise exception 'J3 dedupe not audited'; end if;
  if pg_temp.svc($q$insert into public.jarvis_jobs (division, kind) values ('donna', 'x') returning 'x'$q$) not like 'ERR:permission denied%' then raise exception 'J3 the bot can insert jobs directly'; end if;

  -- J4 lease: nothing while off
  if pg_temp.svc($q$select count(*)::text from public.jarvis_lease('w1', 5)$q$) <> 'OK:0' then raise exception 'J4 lease while dormant'; end if;
  perform public.jarvis_set_config('core_enabled', 'true');
  if pg_temp.svc($q$select count(*)::text from public.jarvis_lease('w1', 5)$q$) <> 'OK:0' then raise exception 'J4 lease while worker off'; end if;
  perform public.jarvis_set_config('worker_enabled', 'true');
  if (select count(*) from public.jarvis_changelog where kind = 'config') < 2 or (select count(*) from public.audit_log where action = 'jarvis_config_set') < 2 then raise exception 'J4 config change not logged'; end if;
  update public.system_state set kill_switch = true where id = 1;
  if pg_temp.svc($q$select count(*)::text from public.jarvis_lease('w1', 5)$q$) <> 'OK:0' then raise exception 'J4 lease while kill switch on'; end if;
  update public.system_state set kill_switch = ks0 where id = 1;
  j2 := public.jarvis_enqueue('ffm', 'report.weekly', '{}', 'low');
  j3 := public.jarvis_enqueue('wolf-squad', 'alert.check', '{}', 'critical');
  -- urgency order: critical first
  select * into r from public.jarvis_lease('w1', 1);
  if r.id <> j3 or r.status <> 'leased' or r.attempts <> 1 or r.lease_owner <> 'w1' then raise exception 'J4 critical job not leased first (% %)', r.id, r.urgency; end if;
  -- only the holder can finish
  if pg_temp.svc(format($q$select public.jarvis_finish(%L, 'w2', true)$q$, j3)) not like 'ERR:%w2 does not hold the lease%' then raise exception 'J4 a non-holder finished a job'; end if;
  if public.jarvis_finish(j3, 'w1', true, null, 3, true) <> 'done' then raise exception 'J4 finish'; end if;
  if (select status from public.jarvis_jobs where id = j3) <> 'done' then raise exception 'J4 not done'; end if;
  -- retry with backoff, then dead
  select * into r from public.jarvis_lease('w1', 1, 60, array['donna']);
  if r.id <> j1 then raise exception 'J4 division filter'; end if;
  if public.jarvis_finish(j1, 'w1', false, 'provider timeout') <> 'retry' then raise exception 'J4 retry'; end if;
  select run_after into t from public.jarvis_jobs where id = j1;
  if t < now() + interval '25 seconds' or t > now() + interval '35 seconds' then raise exception 'J4 first backoff is not 30 s: %', t - now(); end if;
  update public.jarvis_jobs set run_after = now() - interval '1 second', max_attempts = 2 where id = j1;
  select * into r from public.jarvis_lease('w1', 1, 60, array['donna']);
  if r.attempts <> 2 then raise exception 'J4 attempts %', r.attempts; end if;
  if public.jarvis_finish(j1, 'w1', false, 'again') <> 'dead' then raise exception 'J4 not dead after max attempts'; end if;
  -- an expired lease is reclaimed by another worker
  select * into r from public.jarvis_lease('w1', 1, 30, array['ffm']);
  update public.jarvis_jobs set lease_until = now() - interval '1 second' where id = j2;
  select * into r from public.jarvis_lease('w9', 1, 30, array['ffm']);
  if r.id <> j2 or r.lease_owner <> 'w9' then raise exception 'J4 expired lease not reclaimed'; end if;
  if not exists (select 1 from public.jarvis_job_events where job_id = j2 and event = 'reclaimed' and actor = 'w9') then raise exception 'J4 reclaim not audited'; end if;
  begin perform public.jarvis_finish(j2, 'w1', true); raise exception 'J4 the old lease holder finished a reclaimed job';
  exception when others then if sqlerrm not like '%w1 does not hold the lease%' then raise; end if; end;
  if public.jarvis_finish(j2, 'w9', true) <> 'done' then raise exception 'J4 reclaimed job finish'; end if;
  if (select runs from public.jarvis_task_stats where task_class = 'alert.check') <> 1 then raise exception 'J4 stats'; end if;
end $$;

-- J5 append-only audit, even for the database owner
do $$
begin
  perform public.jarvis_enqueue('donna', 'x.y');
  begin update public.jarvis_job_events set actor = 'x'; raise exception 'J5 update accepted'; exception when others then if sqlerrm not like '%append-only%' then raise; end if; end;
  begin delete from public.jarvis_job_events; raise exception 'J5 delete accepted'; exception when others then if sqlerrm not like '%append-only%' then raise; end if; end;
  begin truncate public.jarvis_job_events; raise exception 'J5 truncate accepted'; exception when others then if sqlerrm not like '%append-only%' then raise; end if; end;
  insert into public.jarvis_changelog (kind, summary) values ('deploy', 'test row');
  begin delete from public.jarvis_changelog; raise exception 'J5 changelog delete accepted'; exception when others then if sqlerrm not like '%append-only%' then raise; end if; end;
  begin truncate public.jarvis_call_log; raise exception 'J5 call log truncate accepted'; exception when others then if sqlerrm not like '%append-only%' then raise; end if; end;
end $$;

-- J6 ACL: API roles hold nothing; the bot reads and calls functions, never writes tables
do $$
declare t text; ro text; f record;
begin
  foreach t in array array['jarvis_core_config', 'jarvis_jobs', 'jarvis_job_events', 'jarvis_task_stats', 'jarvis_result_cache', 'jarvis_changelog', 'jarvis_call_log', 'jarvis_large_approvals'] loop
    if not (select relrowsecurity from pg_class where oid = ('public.' || t)::regclass) then raise exception 'J6 RLS off on %', t; end if;
    foreach ro in array array['anon', 'authenticated'] loop
      if has_table_privilege(ro, 'public.' || t, 'select,insert,update,delete,truncate') then raise exception 'J6 % holds a privilege on %', ro, t; end if;
    end loop;
    if has_table_privilege('service_role', 'public.' || t, 'insert,update,delete,truncate') then raise exception 'J6 service_role can write %', t; end if;
  end loop;
  if has_table_privilege('service_role', 'public.jarvis_result_cache', 'select') or has_table_privilege('service_role', 'public.jarvis_large_approvals', 'select') then raise exception 'J6 service_role reads cache / approvals directly'; end if;
  for f in select p.oid::regprocedure::text sig, p.oid from pg_proc p where p.pronamespace = 'public'::regnamespace and p.proname like 'jarvis\_%' loop
    if has_function_privilege('anon', f.oid, 'execute') or has_function_privilege('authenticated', f.oid, 'execute') then raise exception 'J6 % executable by an app role', f.sig; end if;
  end loop;
end $$;

-- J7 emergency-call ledger: disabled, criteria, limit, dedupe (enforced in the database)
do $$
declare r jsonb;
begin
  r := public.jarvis_call_allowed('kill_switch', 'ks-1', true);
  if r ->> 'outcome' <> 'refused_disabled' then raise exception 'J7 disabled: %', r; end if;
  update public.jarvis_core_config set emergency_call_enabled = true where id = 1;
  if (public.jarvis_call_allowed('lunch', 'l-1', false)) ->> 'outcome' <> 'refused_criteria' then raise exception 'J7 criteria'; end if;
  if (public.jarvis_call_allowed('kill_switch', 'ks-1', true)) ->> 'outcome' <> 'allowed' then raise exception 'J7 first call'; end if;
  if (public.jarvis_call_allowed('kill_switch', 'ks-1', true)) ->> 'outcome' <> 'refused_duplicate' then raise exception 'J7 dedupe'; end if;
  if (public.jarvis_call_allowed('production_down', 'pd-1', true)) ->> 'outcome' <> 'allowed' then raise exception 'J7 second call'; end if;
  if (public.jarvis_call_allowed('security_incident', 'si-1', true)) ->> 'outcome' <> 'refused_limit' then raise exception 'J7 third call allowed (limit 2/day)'; end if;
  perform public.jarvis_call_result('ks-1', 'placed', '{"to": "+15550000000", "sid": "x"}');
  if exists (select 1 from public.jarvis_call_log where detail ? 'to') then raise exception 'J7 a phone number was logged'; end if;
  if (select count(*) from public.jarvis_call_log) < 7 then raise exception 'J7 not every decision logged'; end if;
  begin perform public.jarvis_set_config('max_calls_per_day', '9'); raise exception 'J7 limit above 5 accepted'; exception when others then if sqlerrm not like '%max_calls_per_day_check%' and sqlerrm not like '%violates check%' then raise; end if; end;
end $$;

-- J8 large model tier: owner-issued, single use, expiring
do $$
declare a uuid;
begin
  if pg_temp.svc($q$select public.jarvis_owner_approve_large(null, 1)::text$q$) not like 'ERR:owner approval required%' then raise exception 'J8 the bot issued a large-tier approval'; end if;
  a := public.jarvis_owner_approve_large(null, 1);
  if pg_temp.svc(format($q$select public.jarvis_use_large_approval(%L)::text$q$, a)) <> 'OK:true' then raise exception 'J8 first use'; end if;
  if pg_temp.svc(format($q$select public.jarvis_use_large_approval(%L)::text$q$, a)) <> 'OK:false' then raise exception 'J8 second use allowed'; end if;
  a := public.jarvis_owner_approve_large(null, 1);
  update public.jarvis_large_approvals set expires_at = now() - interval '1 minute' where id = a;
  if public.jarvis_use_large_approval(a) then raise exception 'J8 expired approval used'; end if;
  if pg_temp.svc($q$select public.jarvis_use_large_approval(gen_random_uuid())::text$q$) <> 'OK:false' then raise exception 'J8 unknown approval'; end if;
end $$;

-- J9 memory seed (synthetic data only): added, deduped, audited without content
do $$
declare r jsonb; h text := repeat('ab', 32);
begin
  r := public.jarvis_seed_memory('[{"section":"Role","content":"Synthetic chairman runs three test ventures"},{"section":"Style","content":"Prefers short bullet answers"},{"content":"x"}]', h, 'owner');
  if (r ->> 'added')::int <> 2 or (r ->> 'rejected')::int <> 1 then raise exception 'J9 first import %', r; end if;
  r := public.jarvis_seed_memory('[{"section":"role","content":"Synthetic  chairman runs three test ventures"}]', h, 'owner');
  if (r ->> 'duplicates')::int <> 1 or (r ->> 'added')::int <> 0 then raise exception 'J9 dedupe %', r; end if;
  if (select count(*) from public.audit_log where action = 'jarvis_memory_seeded') <> 2 then raise exception 'J9 audit rows'; end if;
  if exists (select 1 from public.audit_log where action = 'jarvis_memory_seeded' and detail::text ilike '%chairman%') then raise exception 'J9 audit row carries content'; end if;
  begin perform public.jarvis_seed_memory('[]', 'nothex', 'owner'); raise exception 'J9 bad hash accepted'; exception when others then if sqlerrm not like '%file hash required%' then raise; end if; end;
  -- J10 retrieval, not a dump
  if (select count(*) from public.jarvis_memory_search('bullet answers', 8, array['owner_profile'])) <> 1 then raise exception 'J10 search'; end if;
  if (select count(*) from public.jarvis_memory_search('ventures', 1, null)) > 1 then raise exception 'J10 limit'; end if;
end $$;

-- J11 cost meter + daily report + $10/day design (cap changed only inside this rolled-back transaction)
do $$
declare r jsonb; id1 uuid; ag text := 'jarvis-core';
begin
  insert into public.llm_calls (agent_slug, model, purpose, reserved_cents, actual_cents, status) values ('jarvis', 'claude-haiku-5-5', 'jarvis:donna:-:lead.followup', 5, 4, 'done'),
    ('jarvis', 'local-small', 'jarvis:ffm:' || gen_random_uuid() || ':report', 3, 3, 'done'), ('jarvis', 'claude-haiku-5-5', 'triage', 2, 2, 'done');
  r := public.jarvis_cost_meter(1);
  if (r -> 'per_division' ->> 'donna')::int <> 4 or (r -> 'per_division' ->> 'ffm')::int <> 3 or (r -> 'per_division' ->> 'other')::int < 2 then raise exception 'J11 meter %', r; end if;
  if jsonb_typeof(r -> 'per_mission') <> 'object' or (select count(*) from jsonb_object_keys(r -> 'per_mission')) <> 1 then raise exception 'J11 per mission %', r -> 'per_mission'; end if;
  r := public.jarvis_daily_report_data((now() at time zone 'America/Toronto')::date);
  if (r ->> 'spend_cents')::int < 9 or not (r ? 'changelog') or not (r ? 'approvals_waiting') or not (r ? 'missions') then raise exception 'J11 report %', r; end if;
  -- the design cap: with the owner's $10/day (1000 cents) a $6 reservation fits and a further $5 is refused by the existing gateway
  update public.agents set status = 'active' where slug = ag;
  update public.system_state set daily_spend_cap_cents = 1000 where id = 1;
  update public.llm_calls set started_at = started_at - interval '3 days';     -- today's earlier test traffic (e2e, integration) moved out of today, inside this rolled-back transaction
  if public.capital_mode() <> 'normal' then raise notice 'J11 design-cap check skipped: capital mode is %', public.capital_mode(); return; end if;
  id1 := public.reserve_llm_budget(ag, 600, 'claude-haiku-5-5', 'jarvis:donna:-:t');
  begin perform public.reserve_llm_budget(ag, 500, 'claude-haiku-5-5', 'jarvis:donna:-:t'); raise exception 'J11 over the design cap accepted';
  exception when others then if sqlerrm not like '%daily cap%' and sqlerrm not like '%spend cap would be exceeded%' then raise; end if; end;
end $$;

-- J12 self-automation candidates never include protected classes
do $$
begin
  delete from public.jarvis_task_stats;
  insert into public.jarvis_task_stats (task_class, runs, ai_runs, cost_cents) values ('lead.followup', 50, 50, 10), ('spend.review', 99, 99, 999), ('backup.check', 99, 99, 999), ('report.weekly', 3, 3, 500), ('never.ai', 99, 0, 0);
  if (select array_agg(task_class order by task_class) from public.jarvis_automation_candidates(array['report.weekly'])) <> array['lead.followup'] then
    raise exception 'J12 candidates %', (select array_agg(task_class) from public.jarvis_automation_candidates(array['report.weekly'])); end if;
  if (select count(*) from public.jarvis_automation_candidates('{}')) <> 2 then raise exception 'J12 thresholds'; end if;
end $$;

-- J13 backup: every new table classified; the cache is never exported
do $$
declare p jsonb := public.backup_export_policy();
begin
  if p -> 'unclassified' <> '[]'::jsonb then raise exception 'J13 unclassified %', p -> 'unclassified'; end if;
  if exists (select 1 from jsonb_array_elements_text(p -> 'exported') e where e like 'jarvis\_%') then raise exception 'J13 a jarvis table is in the off-site export before its redaction spec exists'; end if;
end $$;
-- J15 self-funding: only owner-confirmed, bank-matched revenue counts; paid use stays off until the owner enables it
do $$
declare l1 uuid; l2 uuid; r jsonb;
begin
  r := public.jarvis_self_fund_status();
  if (r ->> 'paid_allowed')::boolean or (r ->> 'pct')::int <> 0 or (r ->> 'paid_enabled')::boolean then raise exception 'J15 default %', r; end if;
  insert into public.ledger (kind, amount_cents, status, note) values ('revenue', 10000, 'received', 'synthetic') returning id into l1;
  insert into public.ledger (kind, amount_cents, status, note) values ('revenue', 5000, 'expected', 'synthetic') returning id into l2;
  if pg_temp.svc(format($q$select public.jarvis_owner_confirm_revenue(%L)::text$q$, l1)) not like 'ERR:owner approval required%' then raise exception 'J15 the bot confirmed revenue'; end if;
  begin perform public.jarvis_owner_confirm_revenue(l1); raise exception 'J15 unmatched revenue accepted'; exception when others then if sqlerrm not like '%not matched to a bank deposit%' then raise; end if; end;
  begin perform public.jarvis_owner_confirm_revenue(l2); raise exception 'J15 expected revenue accepted'; exception when others then if sqlerrm not like '%only a received revenue%' then raise; end if; end;
  insert into public.bank_transactions (posted_on, description, amount_cents, dedupe_key, status, ledger_id) values (current_date, 'deposit', 10000, 'jc-test-1', 'matched', l1);
  perform public.jarvis_set_config('self_fund_pct', '20');
  r := public.jarvis_owner_confirm_revenue(l1);
  if (r ->> 'budget_cents')::int <> 2000 or (r ->> 'paid_allowed')::boolean then raise exception 'J15 budget without paid switch %', r; end if;
  perform public.jarvis_set_config('paid_providers_enabled', 'true');
  r := public.jarvis_self_fund_status();
  if not (r ->> 'paid_allowed')::boolean or (r ->> 'available_cents')::int <> 2000 - (r ->> 'paid_spent_cents')::int then raise exception 'J15 status %', r; end if;
  begin perform public.jarvis_set_config('self_fund_pct', '80'); raise exception 'J15 pct above 50 accepted'; exception when others then if sqlerrm not like '%check%' then raise; end if; end;
  if pg_temp.svc($q$select public.jarvis_set_config('self_fund_pct', '50')::text$q$) not like 'ERR:owner approval required%' then raise exception 'J15 the bot set the percentage'; end if;
end $$;
-- J16 only Jarvis is always on: an agent wakes only for a real queued job with a reason; every wake / sleep is logged append-only
do $$
declare j uuid; r jsonb;
begin
  j := public.jarvis_enqueue('donna', 'lead.research', '{"reason": "owner asked for 5 HVAC leads"}');
  begin perform public.jarvis_wake_agent('donna-researcher', gen_random_uuid(), 'no such job'); raise exception 'J16 woke without a job'; exception when others then if sqlerrm not like '%no queued job, no wake%' then raise; end if; end;
  begin perform public.jarvis_wake_agent('donna-researcher', j, ''); raise exception 'J16 woke without a reason'; exception when others then if sqlerrm not like '%needs a reason%' then raise; end if; end;
  begin perform public.jarvis_wake_agent('jarvis', j, 'should not'); raise exception 'J16 jarvis woken'; exception when others then if sqlerrm not like '%always on%' then raise; end if; end;
  begin perform public.jarvis_sleep_agent('donna-researcher', 'idle'); raise exception 'J16 slept while asleep'; exception when others then if sqlerrm not like '%is not awake%' then raise; end if; end;
  perform public.jarvis_wake_agent('donna-researcher', j, 'lead.research: owner asked for 5 HVAC leads');
  perform public.jarvis_sleep_agent('donna-researcher', 'queue empty', 1, 0);
  begin delete from public.jarvis_agent_wakes; raise exception 'J16 wake log deletable'; exception when others then if sqlerrm not like '%append-only%' then raise; end if; end;
  r := public.jarvis_daily_report_data((now() at time zone 'America/Toronto')::date);
  if (r -> 'wakes' -> 'donna-researcher' ->> 'wakes')::int <> 1 or (r -> 'wakes' -> 'donna-researcher' ->> 'sleeps')::int <> 1 then raise exception 'J16 report %', r -> 'wakes'; end if;
end $$;
rollback;

-- J14 nothing above changed the controls in data (outside the rolled-back transaction)
do $$
begin
  if (select core_enabled or worker_enabled or emergency_call_enabled from public.jarvis_core_config where id = 1) then raise exception 'J14 config leaked out of the test'; end if;
  if (select status from public.agents where slug = 'jarvis-core') <> 'paused' then raise exception 'J14 agent'; end if;
end $$;
