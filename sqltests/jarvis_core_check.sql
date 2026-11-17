-- Jarvis core v2 (migrations/20261123_jarvis_core_v1.sql). Everything in one transaction, rolled back. Run on a fresh apply (scripts/replica/run.sh does).
begin;
grant usage on schema public to anon, authenticated, service_role;   -- as on Supabase (inside the rolled-back transaction)
-- the bot: service_role with NO signed-in user (app.uid cleared for the call, restored after)
create function pg_temp.svc(p_sql text) returns text language plpgsql as $$
declare r text; u text := current_setting('app.uid', true);
begin
  perform set_config('app.uid', '', true);
  set local role service_role;
  begin execute p_sql into r; exception when others then reset role; perform set_config('app.uid', coalesce(u, ''), true); return 'ERR:' || sqlerrm; end;
  reset role;
  perform set_config('app.uid', coalesce(u, ''), true);
  return 'OK:' || coalesce(r, '');
end $$;
-- a plain database session without the owner's auth uid (an agent with direct SQL access)
create function pg_temp.nouid(p_sql text) returns text language plpgsql as $$
declare r text; u text := current_setting('app.uid', true);
begin
  perform set_config('app.uid', '', true);
  begin execute p_sql into r; exception when others then perform set_config('app.uid', coalesce(u, ''), true); return 'ERR:' || sqlerrm; end;
  perform set_config('app.uid', coalesce(u, ''), true);
  return 'OK:' || coalesce(r, '');
end $$;
-- the owner, signed in (synthetic auth user; the same pattern as ops/OWNER_JARVIS_CORE.sql)
insert into auth.users (id, email) values ('99999999-9999-9999-9999-99999999a001', 'jc-owner@example.invalid') on conflict do nothing;
insert into public.app_owners (email) values ('jc-owner@example.invalid') on conflict do nothing;
select set_config('app.uid', '99999999-9999-9999-9999-99999999a001', true);
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
  -- S4: a direct database session is NOT the owner by itself (as strict as ffm_require_owner)
  if pg_temp.nouid($q$select public.jarvis_set_config('core_enabled', 'true')::text$q$) not like 'ERR:owner approval required%' then raise exception 'J2 a plain SQL session acted as the owner'; end if;
  if pg_temp.nouid($q$select public.jarvis_owner_approve_large(null, 1)::text$q$) not like 'ERR:owner approval required%' then raise exception 'J2 a plain SQL session approved the large tier'; end if;
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
  -- B6: a job that crashes the worker every time (the lease just expires) is dead-lettered at max_attempts, never leased forever
  j1 := public.jarvis_enqueue('donna', 'crash.loop', '{}', 'normal', null, null, null, false, 2);
  for n in 1..40 loop
    perform 1 from public.jarvis_lease('w-crash', 5, 30, array['donna']);
    update public.jarvis_jobs set lease_until = now() - interval '1 second' where id = j1 and status = 'leased';
  end loop;
  select * into r from public.jarvis_jobs where id = j1;
  if r.status <> 'dead' or r.attempts <> 2 then raise exception 'B6 crash loop: status % attempts %', r.status, r.attempts; end if;
  if (select count(*) from public.jarvis_job_events where job_id = j1 and event in ('leased', 'reclaimed')) <> 2 then raise exception 'B6 leased more than max_attempts times'; end if;
  if not exists (select 1 from public.jarvis_job_events where job_id = j1 and event = 'dead' and detail ->> 'reason' = 'lease expired') then raise exception 'B6 dead-letter not audited'; end if;
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
  r := public.jarvis_call_allowed('kill_switch_tripped', 'ks-1', true);
  if r ->> 'outcome' <> 'refused_disabled' then raise exception 'J7 disabled: %', r; end if;
  update public.jarvis_core_config set emergency_call_enabled = true where id = 1;
  -- B7: the criteria are the DATABASE's list; the caller's boolean is ignored; unlisted events never use up the limit
  if (public.jarvis_call_allowed('lunch_is_ready', 'l-1', true)) ->> 'outcome' <> 'refused_criteria' then raise exception 'J7 unlisted event with criteria_ok=true allowed'; end if;
  if (public.jarvis_call_allowed('anything_at_all', 'a-1', true)) ->> 'outcome' <> 'refused_criteria' then raise exception 'J7 unlisted event allowed'; end if;
  if pg_temp.svc($q$select (public.jarvis_call_allowed('lunch_is_ready', 'l-2', true)) ->> 'outcome'$q$) <> 'OK:refused_criteria' then raise exception 'J7 bot: unlisted allowed'; end if;
  if pg_temp.svc($q$insert into public.jarvis_call_criteria values ('lunch_is_ready', 'critical', 'lunch') returning 'x'$q$) not like 'ERR:permission denied%' then raise exception 'J7 the bot can add criteria'; end if;
  if (public.jarvis_call_allowed('kill_switch_tripped', 'ks-1', false)) ->> 'outcome' <> 'allowed' then raise exception 'J7 first call (listed event, caller flag ignored)'; end if;
  if (public.jarvis_call_allowed('kill_switch_tripped', 'ks-1', true)) ->> 'outcome' <> 'refused_duplicate' then raise exception 'J7 dedupe'; end if;
  if (public.jarvis_call_allowed('production_down', 'pd-1', true)) ->> 'outcome' <> 'allowed' then raise exception 'J7 second call'; end if;
  if (public.jarvis_call_allowed('security_incident', 'si-1', true)) ->> 'outcome' <> 'refused_limit' then raise exception 'J7 third call allowed (limit 2/day)'; end if;
  perform public.jarvis_call_result('ks-1', 'placed', '{"to": "+15550000000", "To": "+15550000000", "phone": "+15550000000", "call": "x"}');
  if exists (select 1 from public.jarvis_call_log where detail ?| array['to', 'To', 'phone']) then raise exception 'J7 a phone number was logged'; end if;
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
declare r jsonb; h text := repeat('ab', 32); st text;
begin
  r := public.jarvis_seed_memory('[{"section":"Role","content":"Synthetic chairman runs three test ventures"},{"section":"Style","content":"Prefers short bullet answers"},{"content":"x"}]', h, 'owner');
  if (r ->> 'added')::int <> 2 or (r ->> 'rejected')::int <> 1 then raise exception 'J9 first import %', r; end if;
  r := public.jarvis_seed_memory('[{"section":"role","content":"Synthetic  chairman runs three test ventures"}]', h, 'owner');
  if (r ->> 'duplicates')::int <> 1 or (r ->> 'added')::int <> 0 then raise exception 'J9 dedupe %', r; end if;
  if (select count(*) from public.audit_log where action = 'jarvis_memory_seeded') <> 2 then raise exception 'J9 audit rows'; end if;
  if exists (select 1 from public.audit_log where action = 'jarvis_memory_seeded' and detail::text ilike '%chairman%') then raise exception 'J9 audit row carries content'; end if;
  begin perform public.jarvis_seed_memory('[]', 'nothex', 'owner'); raise exception 'J9 bad hash accepted'; exception when others then if sqlerrm not like '%file hash required%' then raise; end if; end;
  -- S9: owner-only IN SQL: the bot cannot seed directly (even claiming p_actor 'owner'); it stages, the owner applies
  if pg_temp.svc(format($q$select public.jarvis_seed_memory('[{"content":"bot written profile line"}]', %L, 'owner')::text$q$, h)) not like 'ERR:owner approval required%' then raise exception 'S9 the bot seeded memory'; end if;
  st := pg_temp.svc(format($q$select public.jarvis_seed_stage('[{"section":"Goal","content":"Synthetic staged item one"}]', %L)::text$q$, h));
  if st not like 'OK:%' then raise exception 'S9 stage %', st; end if;
  if pg_temp.svc(format($q$select public.jarvis_seed_apply(%L)::text$q$, substr(st, 4))) not like 'ERR:owner approval required%' then raise exception 'S9 the bot applied a stage'; end if;
  r := public.jarvis_seed_apply(substr(st, 4)::uuid);
  if (r ->> 'added')::int <> 1 then raise exception 'S9 apply %', r; end if;
  begin perform public.jarvis_seed_apply(substr(st, 4)::uuid); raise exception 'S9 applied twice'; exception when others then if sqlerrm not like '%no unapplied%' then raise; end if; end;
  if exists (select 1 from public.audit_log where action like 'jarvis_memory_seed%' and actor not in ('owner', 'bot')) then raise exception 'S9 audit actor'; end if;
  -- J10 retrieval, not a dump; B5: the private profile only for a self-hosted destination; any word matches
  if (select count(*) from public.jarvis_memory_search('bullet answers', 8, array['owner_profile'], 'selfhost')) <> 1 then raise exception 'J10 search'; end if;
  if (select count(*) from public.jarvis_memory_search('bullet answers', 8, null)) <> 0 then raise exception 'B5 owner_profile returned for an external destination'; end if;
  if (select count(*) from public.jarvis_memory_search('bullet answers', 8, array['owner_profile'], 'groq')) <> 0 then raise exception 'B5 owner_profile returned for groq'; end if;
  if (select count(*) from public.jarvis_memory_search('what bullet style zzqq', 8, array['owner_profile'], 'selfhost')) < 1 then raise exception 'J10 multi-word query found nothing (AND semantics)'; end if;
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
  insert into public.jarvis_task_stats (task_class, runs, ai_runs, cost_cents) values ('summary.daily', 50, 50, 10), ('spend.review', 99, 99, 999), ('backup.check', 99, 99, 999),
    ('report.weekly', 3, 3, 500), ('never.ai', 99, 0, 0), ('lead.payment.reminder', 99, 99, 99), ('ffm.consent.followup', 99, 99, 99), ('legal.check', 99, 99, 99),
    ('contract.review', 99, 99, 99), ('outreach.send', 99, 99, 99), ('billing.refund', 99, 99, 99), ('wire.transfer', 99, 99, 99), ('ops.backup.verify', 99, 99, 99);
  if (select array_agg(task_class order by task_class) from public.jarvis_automation_candidates(array['report.weekly'])) <> array['summary.daily'] then
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
  -- S5: a 1-cent matched deposit does not confirm a 100-dollar row
  insert into public.bank_transactions (posted_on, description, amount_cents, dedupe_key, status, ledger_id) values (current_date, 'deposit', 1, 'jc-test-0', 'matched', l1);
  begin perform public.jarvis_owner_confirm_revenue(l1); raise exception 'S5 amount mismatch accepted'; exception when others then if sqlerrm not like '%do not equal the revenue amount exactly%' then raise; end if; end;
  update public.bank_transactions set amount_cents = 10000 where dedupe_key = 'jc-test-0';
  perform public.jarvis_set_config('self_fund_pct', '20');
  r := public.jarvis_owner_confirm_revenue(l1);
  if (r ->> 'budget_cents')::int <> 2000 or (r ->> 'paid_allowed')::boolean then raise exception 'J15 budget without paid switch %', r; end if;
  perform public.jarvis_set_config('paid_providers_enabled', 'true');
  r := public.jarvis_self_fund_status();
  if not (r ->> 'paid_allowed')::boolean or (r ->> 'available_cents')::int <> 2000 - (r ->> 'paid_spent_cents')::int then raise exception 'J15 status %', r; end if;
  -- S5: the credit stops counting when the deposit is unmatched or the ledger row is changed
  update public.bank_transactions set status = 'unmatched' where dedupe_key = 'jc-test-0';
  if ((public.jarvis_self_fund_status()) ->> 'confirmed_revenue_cents')::int <> 0 then raise exception 'S5 credit kept after the deposit was unmatched'; end if;
  update public.bank_transactions set status = 'matched' where dedupe_key = 'jc-test-0';
  update public.ledger set amount_cents = 1 where id = l1;
  if ((public.jarvis_self_fund_status()) ->> 'confirmed_revenue_cents')::int <> 0 then raise exception 'S5 credit kept after the ledger row changed'; end if;
  update public.ledger set amount_cents = 10000 where id = l1;
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
-- J17 B8: mission budgets apply to the core's 'jarvis:<division>:<mission>:...' purposes (focus mode too)
do $$
declare m uuid; id1 uuid;
begin
  update public.agents set status = 'active' where slug = 'jarvis-core';
  if public.capital_mode() <> 'normal' then raise notice 'J17 skipped: capital mode is %', public.capital_mode(); return; end if;
  insert into public.missions (title, objective, budget_cents) values ('jc synthetic mission', 'synthetic objective for the budget test', 5) returning id into m;
  begin perform public.reserve_llm_budget('jarvis-core', 50, 'claude-haiku-5-5', 'jarvis:donna:' || m || ':x:anthropic'); raise exception 'J17 50 cents reserved against a 5-cent mission';
  exception when others then if sqlerrm not like '%Mission budget would be exceeded%' then raise; end if; end;
  id1 := public.reserve_llm_budget('jarvis-core', 0, 'claude-haiku-5-5', 'jarvis:donna:' || m || ':x:groq');      -- a free call still fits
  begin perform public.reserve_llm_budget('jarvis-core', 0, 'claude-haiku-5-5', 'jarvis:donna:' || gen_random_uuid() || ':x:groq'); raise exception 'J17 unknown mission accepted';
  exception when others then if sqlerrm not like '%Unknown mission%' then raise; end if; end;
end $$;
-- J18 RVJC2 S4: mission matching is case-insensitive and accepts any division text, exactly like the spend counting (the 4 x 3-cent bypass)
do $$
declare m uuid; n int := 0; i int;
begin
  if public.capital_mode() <> 'normal' then raise notice 'J18 skipped: capital mode is %', public.capital_mode(); return; end if;
  insert into public.missions (title, objective, budget_cents) values ('jc synthetic mission 2', 'synthetic objective for the case test', 5) returning id into m;
  for i in 1..4 loop
    begin perform public.reserve_llm_budget('jarvis-core', 3, 'claude-haiku-5-5', 'jarvis:donna:' || upper(m::text) || ':x:anthropic'); n := n + 1;
    exception when others then if sqlerrm not like '%Mission budget would be exceeded%' then raise; end if; end;
  end loop;
  if n <> 1 then raise exception 'J18 % upper-case 3-cent reservations passed a 5-cent budget', n; end if;
  if public.mission_spent_cents(m) <> 3 then raise exception 'J18 spend counting %', public.mission_spent_cents(m); end if;
  foreach i in array array[1, 2, 3] loop
    begin perform public.reserve_llm_budget('jarvis-core', 50, 'claude-haiku-5-5',
                                            (array['jarvis:wolf_squad:', 'jarvis:Donna:', 'JARVIS:donna:'])[i] || m || ':x:anthropic');
      raise exception 'J18 division / prefix variant % passed the budget', i;
    exception when others then if sqlerrm not like '%Mission budget would be exceeded%' then raise; end if; end;
  end loop;
  begin perform public.reserve_llm_budget('jarvis-core', 1, 'claude-haiku-5-5', 'jarvis:donna:not-a-uuid:x:anthropic'); raise exception 'J18 bad mission text accepted';
  exception when others then if sqlerrm not like '%must name a mission uuid%' then raise; end if; end;
end $$;
rollback;

-- J14 nothing above changed the controls in data (outside the rolled-back transaction)
do $$
begin
  if (select core_enabled or worker_enabled or emergency_call_enabled from public.jarvis_core_config where id = 1) then raise exception 'J14 config leaked out of the test'; end if;
  if (select status from public.agents where slug = 'jarvis-core') <> 'paused' then raise exception 'J14 agent'; end if;
end $$;
