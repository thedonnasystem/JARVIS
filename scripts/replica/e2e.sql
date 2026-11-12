\set ON_ERROR_STOP on
insert into auth.users (id, email) values ('11111111-1111-1111-1111-111111111111', 'owner@example.com');
insert into public.app_owners (email) values ('owner@example.com');
select set_config('app.uid', '11111111-1111-1111-1111-111111111111', false), set_config('app.email', 'owner@example.com', false);
select 'is_owner', public.is_app_owner();
select 'snapshot keys', jsonb_object_keys(public.app_snapshot()) k order by 2 limit 40;
select 'create_venture', public.create_venture('acme','Acme Cleaning','lab','paying customers',3000,'owner:test');
select 'activate', public.activate_venture('acme','owner:test');
select 'opp scans', public.queue_opportunity_scans();
select 'office', jsonb_array_length(public.app_office());
select 'venture view', public.app_venture('acme')->>'name', jsonb_array_length(public.app_venture_extras('acme')->'assets');
select 'alloc', public.allocation_text();
select 'budget', public.set_venture_budget('acme', 2500, 'owner:test');
select 'prepare', public.prepare_payment('jarvis','Twilio',1500,'Phone number for Donna','none considered',current_date+3,'acme');
select 'app_payments', public.app_payments();
select 'decide', public.decide_payment((select id from payment_instructions limit 1), true, 'owner:app');
select 'confirm', public.confirm_payment((select id from payment_instructions limit 1), 1500, 'RBC-TEST-1', 'owner:app');
select 'ledger', kind, amount_cents from ledger order by created_at desc limit 1;
select 'account req', public.request_account('jarvis','Twilio','Phone number for Donna','acme','https://twilio.com',0,array['sms_code']);
select 'account decide', public.decide_account((select id from account_requests limit 1), true, 'owner:app');
select 'account done', public.complete_account((select id from account_requests limit 1), 'moe@biz.ca', 'owner:app');
select 'bank alerts', public.bank_alerts();
select 'capital', public.capital_snapshot()->>'available_cents', public.capital_snapshot()->>'mode';
select 'msgs', kind, ref_table, needs_decision from owner_messages order by created_at;
select 'create_agent', public.create_agent('acme-scout','Acme Scout','acme','researcher','cheap',15,'Find local cleaning customers within Ottawa.','leads found','owner-chat');
select 'brief', position('account request' in public.daily_brief_text()) >= 0 as brief_ok;
-- A signed-in user who is NOT the owner must be refused by every app function.
select set_config('app.uid', '22222222-2222-2222-2222-222222222222', false), set_config('app.email', 'intruder@example.com', false);
insert into auth.users (id, email) values ('22222222-2222-2222-2222-222222222222', 'intruder@example.com');
do $$ declare f text; denied int := 0; total int := 0;
begin
  for f in select format('select public.%I(%s)', p.proname, coalesce(string_agg(case when a.oid is null then null else case t.typname when 'text' then '''x''' when 'int4' then '1' when 'bool' then 'true' when 'jsonb' then '''{}''::jsonb' else 'null' end end, ',' order by a.ord), ''))
           from pg_proc p join pg_namespace n on n.oid = p.pronamespace and n.nspname = 'public'
           left join lateral unnest(p.proargtypes) with ordinality as a(oid, ord) on true
           left join pg_type t on t.oid = a.oid
           where p.proname like 'app\_%' and p.proname <> 'app_snapshot_data' group by p.oid, p.proname loop
    total := total + 1;
    begin execute f; raise exception 'LEAK: % returned data to a non-owner', f; exception when insufficient_privilege then denied := denied + 1; end;
  end loop;
  if denied <> total then raise exception 'only % of % app functions refused the intruder', denied, total; end if;
  raise notice 'intruder refused by all % app functions', total;
end $$;
select 'intruder_refused_everywhere';
-- Signed-in users (even the owner) cannot call the privileged functions directly; only the service key (the bot) can.
reset role; set role authenticated;
do $$ declare f text; denied int := 0; total int := 0;
begin
  foreach f in array array[
    $q$select public.prepare_payment('jarvis','X',100,'Phone number','none',null,null)$q$,
    $q$select public.decide_payment(gen_random_uuid(), true, 'owner:app')$q$,
    $q$select public.confirm_payment(gen_random_uuid(), 100, 'ref', 'owner:app')$q$,
    $q$select public.request_account('jarvis','Twilio','Phone number','donna',null,0,null)$q$,
    $q$select public.decide_account(gen_random_uuid(), true, 'owner:app')$q$,
    $q$select public.complete_account(gen_random_uuid(), 'a@b.ca', 'owner:app')$q$,
    $q$select public.set_venture_budget('donna', 100, 'owner:app')$q$,
    $q$select public.queue_opportunity_scans()$q$,
    $q$select public.expire_payments()$q$,
    $q$select public.office_data()$q$] loop
    total := total + 1;
    begin execute f; exception when insufficient_privilege then denied := denied + 1; end;
  end loop;
  if denied <> total then raise exception 'only % of % privileged functions refused a signed-in user', denied, total; end if;
end $$;
reset role;
select 'privileged_functions_not_callable_by_signed_in_users';

-- setters_v1
select public.setter_add('Sam Setter','sam@x.com','salons');
select public.setter_log('sam','booked','Acme Salon');
select public.setter_log('sam','closed','Acme Salon');
select public.setter_log('sam','closed','B Salon');
select public.setter_log('sam','closed','C Salon');
do $$ declare r record; j jsonb; begin
  select * into r from public.setter_standing where name = 'Sam Setter';
  if r.closes <> 3 or r.owed_close_cents <> 36000 or not r.recurring_on or r.owed_recurring_cents <> 15000 then raise exception 'setter math wrong: %', to_jsonb(r); end if;
  j := public.setter_record_payout('Sam Setter','close',99999);
  if j->>'error' is null then raise exception 'overpay allowed'; end if;
  j := public.setter_record_payout('Sam Setter','close',36000,'ref1');
  if j->>'ok' is null then raise exception 'payout failed %', j; end if;
  j := public.setter_record_payout('Sam Setter','recurring',15000,'ref2');
  j := public.setter_record_payout('Sam Setter','recurring',15000,'ref3');
  if j->>'error' is null then raise exception 'recurring paid twice'; end if;
  select * into r from public.setter_standing where name = 'Sam Setter';
  if r.owed_close_cents <> 0 or r.owed_recurring_cents <> 0 then raise exception 'owed not cleared'; end if;
end $$;
select 'setters_ok';

-- finance_rules_v1
do $$ declare w jsonb; i int; begin
  insert into public.ledger (kind, amount_cents, status, note) values ('revenue', 100000, 'received', 'waterfall test');
  insert into public.ledger (kind, amount_cents, status, note) values ('revenue', 50000, 'expected', 'not cash');
  w := public.waterfall(30);
  if (w->>'tax_setaside_cents')::int <> round(((w->>'revenue_cents')::numeric) * 0.33) then raise exception 'tax wrong %', w; end if;
  if (w->>'pool_cents')::int < 0 then raise exception 'negative pool %', w; end if;
  if (w->>'pool_best_cents')::int + (w->>'pool_research_cents')::int + (w->>'pool_deal_cents')::int <> (w->>'pool_cents')::int then raise exception 'pool split %', w; end if;
  if (w->>'revenue_cents')::int < 100000 or (w->>'revenue_cents')::int >= 150000 then raise exception 'expected money counted %', w; end if;
  begin update public.waterfall_policy set tax_pct = 5 where id = 1; raise exception 'agent changed policy'; exception when others then if sqlerrm like 'agent changed%' then raise; end if; end;
  update public.waterfall_policy set tax_pct = 30, updated_by = 'owner:test' where id = 1;
  perform public.owner_seen();
  if (public.coast_state()->>'coast')::boolean then raise exception 'coast too early'; end if;
  update public.system_state set owner_last_seen = now() - interval '5 days' where id = 1;
  if not (public.coast_state()->>'coast')::boolean then raise exception 'coast not detected'; end if;
  update public.system_state set owner_last_seen = now() where id = 1;
  -- slot cap: with max 1, a second revenue venture cannot be activated
  update public.waterfall_policy set max_revenue_ventures = 1, updated_by = 'owner:test' where id = 1;
  perform public.create_venture('slot-a','Slot A','revenue','m',0,'d','jarvis');
  perform public.create_venture('slot-b','Slot B','revenue','m',0,'d','jarvis');
  update public.ventures set status = 'proposed' where status = 'active' and kind = 'revenue';
  perform public.activate_venture('slot-a','owner:test');
  begin perform public.activate_venture('slot-b','owner:test'); raise exception 'slot cap not enforced'; exception when others then if sqlerrm like 'slot cap%' then raise; end if; end;
  update public.waterfall_policy set max_revenue_ventures = 3, updated_by = 'owner:test' where id = 1;
end $$;
select 'finance_rules_ok';

-- autonomy_v1
do $$ declare r jsonb; begin
  insert into public.outbox (channel, to_ref, body, status, decided_at) select 'email', 'x'||g||'@e.com', 'b', case when g <= 3 then 'rejected' else 'approved' end, now() from generate_series(1, 25) g;
  r := public.autonomy_report(0.05, 20);
  if not exists (select 1 from jsonb_array_elements(r) e where e->>'channel' = 'email' and (e->>'reviewed')::int >= 25 and (e->>'rejected')::int = 3 and (e->>'eligible')::boolean = false) then
    raise exception 'autonomy report wrong %', r; end if;
  r := public.autonomy_report(0.15, 20);
  if not exists (select 1 from jsonb_array_elements(r) e where e->>'channel' = 'email' and (e->>'eligible')::boolean) then raise exception 'eligibility wrong %', r; end if;
end $$;
select 'autonomy_ok';

-- lockdown_v1 regression: after every migration, only the owner-checked app_* functions may be callable by anon/authenticated.
do $$ declare bad text; begin
  select string_agg(p.proname, ',') into bad from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.prokind = 'f'
     and ((has_function_privilege('anon', p.oid, 'execute') and p.proname <> 'setter_apply')
          or (has_function_privilege('authenticated', p.oid, 'execute')
              and p.proname not in ('is_app_owner','app_snapshot','app_messages','app_send','app_set_kill','app_set_agent','app_venture','app_venture_extras','app_office','app_payments','app_push_public_key','app_save_push','setter_apply')));
  if bad is not null then raise exception 'callable by anon/authenticated: %', bad; end if;
end $$;
select 'lockdown_ok';

-- setter_apply: public intake safeguards
do $$ declare r jsonb; n0 int; begin
  select count(*) into n0 from public.setters;
  r := public.setter_apply('Pat Public', 'pat@example.com', 'hvac', 'hello', '');
  if (r->>'ok')::boolean is not true or (select count(*) from public.setters) <> n0 + 1 then raise exception 'apply failed %', r; end if;
  if (select status from public.setters where name = 'Pat Public') <> 'applied' then raise exception 'not applied status'; end if;
  perform public.setter_apply('Pat Public', 'other@example.com');            -- same name: no overwrite
  if (select contact from public.setters where name = 'Pat Public') <> 'pat@example.com' then raise exception 'existing setter overwritten'; end if;
  perform public.setter_apply('Bot', 'bot@example.com', null, null, 'http://spam');   -- honeypot
  if exists (select 1 from public.setters where name = 'Bot') then raise exception 'honeypot stored'; end if;
  r := public.setter_apply('X', '1');
  if (r->>'ok')::boolean then raise exception 'bad input accepted'; end if;
  r := public.setter_apply('No Contact Format', 'nothing');
  if (r->>'ok')::boolean then raise exception 'invalid contact accepted'; end if;
  for i in 1..20 loop perform public.setter_apply('Flood '||i, 'flood'||i||'@example.com'); end loop;
  if (select count(*) from public.setters where notes like 'self-signup%' and created_at > now() - interval '1 hour') > 15 then raise exception 'rate limit broken'; end if;
end $$;
select 'setter_apply_ok';

-- Phase 1 repair: idempotency, bulk audit, alerts, integration gate
do $$ declare k text := 'test-key-' || gen_random_uuid(); n0 int; ids uuid[]; a int; r text;
begin
  insert into public.tasks (title, status, dedupe_key) values ('dup test', 'todo', k);
  begin
    insert into public.tasks (title, status, dedupe_key) values ('dup test 2', 'todo', k);
    raise exception 'duplicate open dedupe_key accepted';
  exception when unique_violation then null; end;
  update public.tasks set status = 'done' where dedupe_key = k;            -- closed: the key frees up again
  insert into public.tasks (title, status, dedupe_key) values ('dup test 3', 'todo', k);
  delete from public.tasks where dedupe_key = k;

  -- small change: no audit; bulk change: one identifiable audit row with reason
  insert into public.tasks (title, status) select 'bulk ' || g, 'todo' from generate_series(1, 8) g;
  select count(*) into n0 from public.audit_log where action = 'bulk_task_status_change';
  update public.tasks set status = 'cancelled' where title in ('bulk 1', 'bulk 2');
  if (select count(*) from public.audit_log where action = 'bulk_task_status_change') <> n0 then raise exception 'small change audited'; end if;
  perform set_config('hq.reason', 'phase1 test cleanup', true);
  update public.tasks set status = 'cancelled' where title like 'bulk %' and status = 'todo';
  select count(*) into a from public.audit_log where action = 'bulk_task_status_change';
  if a <> n0 + 0 then null; end if;
  r := (select detail->>'reason' from public.audit_log where action = 'bulk_task_status_change' order by id desc limit 1);
  if r is distinct from 'phase1 test cleanup' then raise exception 'bulk audit reason missing: %', r; end if;
  if (select (detail->>'rows_changed')::int from public.audit_log where action = 'bulk_task_status_change' order by id desc limit 1) <> 6 then raise exception 'bulk audit count wrong'; end if;
  perform set_config('hq.reason', 'phase1 test delete', true);
  delete from public.tasks where title like 'bulk %';
  if not exists (select 1 from public.audit_log where action = 'task_delete' and detail->>'reason' = 'phase1 test delete') then raise exception 'delete not audited'; end if;
end $$;
select 'idempotency_and_audit_ok';

do $$ declare n int; m0 int;
begin
  update public.system_state set pause_reason = 'api_credits', paused_at = now() - interval '2 hours', last_heartbeat = now() where id = 1;
  select count(*) into m0 from public.owner_messages where body like 'ALERT:%';
  n := public.ops_alerts();
  if n < 1 or (select count(*) from public.owner_messages where body like 'ALERT:%') <= m0 then raise exception 'no credit alert'; end if;
  if public.ops_alerts() <> 0 then raise exception 'alert repeated inside cooldown'; end if;
  delete from public.alert_state;
  update public.system_state set pause_reason = null, paused_at = null where id = 1;
  delete from public.alert_state;
  if public.ops_alerts() <> 0 then raise exception 'alert fired on a healthy system'; end if;
  -- value-fixer gate: no integration row means no task
  delete from public.integration_status where key = 'wholesale';
  if public.queue_valuation_task() is not null then raise exception 'valuation task created without integration'; end if;
end $$;
select 'alerts_and_gate_ok';

-- Mission guard: hard per-mission budget and focus mode, enforced by the spend gateway
do $$ declare ag text; mid uuid; other uuid; t1 uuid; t2 uuid; c1 uuid; ok boolean;
begin
  select slug into ag from public.agents where status = 'active' limit 1;
  update public.agents set daily_spend_cap_cents = 100000 where slug = ag;
  update public.system_state set daily_spend_cap_cents = 100000, kill_switch = false where id = 1;
  insert into public.missions (title, objective, status, budget_cents, created_by) values ('guard test', 'guard test objective long enough', 'captured', 10, 'owner') returning id into mid;
  insert into public.missions (title, objective, status, budget_cents, created_by) values ('other', 'other mission objective long enough', 'captured', 100, 'owner') returning id into other;
  insert into public.tasks (title, status, mission_id) values ('s1', 'doing', mid) returning id into t1;
  insert into public.tasks (title, status, mission_id) values ('s2', 'doing', other) returning id into t2;
  c1 := public.reserve_llm_budget(ag, 6, 'm', 'task ' || t1);
  update public.llm_calls set status = 'done', actual_cents = 6 where id = c1;
  begin perform public.reserve_llm_budget(ag, 6, 'm', 'task ' || t1); raise exception 'over-budget reservation accepted';
  exception when raise_exception then if sqlerrm like 'over-budget%' then raise; end if; end;
  perform public.reserve_llm_budget(ag, 4, 'm', 'task ' || t1);                      -- exactly at the budget is fine
  perform public.reserve_llm_budget(ag, 5, 'm', 'untracked purpose');               -- non-mission spend unaffected when no focus
  perform public.set_focus_mission(mid, 'owner:test');
  begin perform public.reserve_llm_budget(ag, 1, 'm', 'task ' || t2); raise exception 'focus mode let another mission spend';
  exception when raise_exception then if sqlerrm like 'focus mode let%' then raise; end if; end;
  begin perform public.reserve_llm_budget(ag, 1, 'm', 'untracked purpose'); raise exception 'focus mode let backlog spend';
  exception when raise_exception then if sqlerrm like 'focus mode let%' then raise; end if; end;
  begin perform public.set_focus_mission(null, 'agent:jarvis'); raise exception 'non-owner cleared focus';
  exception when raise_exception then if sqlerrm like 'non-owner%' then raise; end if; end;
  perform public.set_focus_mission(null, 'owner:test');
  perform public.reserve_llm_budget(ag, 1, 'm', 'task ' || t2);
  if not exists (select 1 from public.audit_log where action = 'focus_set') then raise exception 'focus not audited'; end if;
end $$;
select 'mission_guard_ok';

-- Step limit: a 4-step mission cannot gain a 5th step task or a 5-step plan, whatever the model or Python does
do $$ declare mid uuid; i int; tid uuid;
begin
  insert into public.missions (title, objective, status, budget_cents, created_by, max_steps)
    values ('step limit test', 'step limit test objective long enough', 'captured', 200, 'owner', 4) returning id into mid;
  for i in 1..4 loop insert into public.tasks (title, status, mission_id, mission_role) values ('Mission: step ' || i, 'todo', mid, 'step'); end loop;
  begin insert into public.tasks (title, status, mission_id, mission_role) values ('Mission: step 5', 'todo', mid, 'step'); raise exception 'fifth step accepted';
  exception when raise_exception then if sqlerrm like 'fifth%' then raise; end if; end;
  begin insert into public.tasks (title, status, mission_id) values ('Mission: untagged', 'todo', mid); raise exception 'untagged task bypassed limit';
  exception when raise_exception then if sqlerrm like 'untagged%' then raise; end if; end;
  -- a model-chosen title cannot dodge the limit
  begin insert into public.tasks (title, status, mission_id, mission_role) values ('Mission: Verify sneaky', 'todo', mid, 'step'); raise exception 'title spoof bypassed limit';
  exception when raise_exception then if sqlerrm like 'title spoof%' then raise; end if; end;
  -- evaluation and verification tasks are not steps
  insert into public.tasks (title, status, mission_id, mission_role) values ('Mission: Evaluate x', 'todo', mid, 'eval'), ('Mission: Verify x', 'todo', mid, 'verify');
  -- cancelled steps free their slot (pause then resume)
  update public.tasks set status = 'cancelled' where mission_id = mid and title = 'Mission: step 4';
  insert into public.tasks (title, status, mission_id, mission_role) values ('Mission: step 4 again', 'todo', mid, 'step');
  -- plan length
  begin update public.missions set plan = '[{"a":1},{"a":2},{"a":3},{"a":4},{"a":5}]'::jsonb where id = mid; raise exception 'five-step plan accepted';
  exception when raise_exception then if sqlerrm like 'five-step%' then raise; end if; end;
  update public.missions set plan = '[{"a":1},{"a":2},{"a":3},{"a":4}]'::jsonb where id = mid;
  begin update public.missions set max_steps = 9 where id = mid; raise exception 'max_steps above ceiling accepted';
  exception when check_violation then null; end;
end $$;
select 'step_limit_ok';

-- Step allowance: non-strict gets max_steps per attempt; strict is a hard lifetime ceiling
do $$ declare m1 uuid; m2 uuid; i int;
begin
  insert into public.missions (title, objective, status, created_by, max_steps, strict_steps) values ('loose', 'loose mission objective long enough', 'captured', 'owner', 2, false) returning id into m1;
  insert into public.missions (title, objective, status, created_by, max_steps, strict_steps) values ('strict', 'strict mission objective long enough', 'captured', 'owner', 2, true) returning id into m2;
  insert into public.tasks (title, mission_id, mission_role) values ('s1', m1, 'step'), ('s2', m1, 'step'), ('t1', m2, 'step'), ('t2', m2, 'step');
  begin insert into public.tasks (title, mission_id, mission_role) values ('s3', m1, 'step'); raise exception 'loose attempt 0 over allowance';
  exception when raise_exception then if sqlerrm like 'loose%' then raise; end if; end;
  update public.missions set attempts = 1 where id in (m1, m2);                  -- a failed verification happened
  insert into public.tasks (title, mission_id, mission_role) values ('s3', m1, 'step'), ('s4', m1, 'step');   -- re-plan gets 2 more
  begin insert into public.tasks (title, mission_id, mission_role) values ('t3', m2, 'step'); raise exception 'strict ceiling bypassed';
  exception when raise_exception then if sqlerrm like 'strict%' then raise; end if; end;
end $$;
select 'step_allowance_ok';
-- Lifetime ceiling: in a strict mission a cancelled step that SPENT keeps its slot; a cancelled step that never spent frees it
do $$ declare mid uuid; i int; ag text; tid uuid; c uuid;
begin
  select slug into ag from public.agents where status = 'active' and slug <> 'jarvis-chat' limit 1;
  update public.agents set daily_spend_cap_cents = 100000 where slug = ag;
  update public.system_state set daily_spend_cap_cents = 100000, kill_switch = false, pause_reason = null, focus_mission = null where id = 1;
  insert into public.missions (title, objective, status, budget_cents, created_by, max_steps, strict_steps)
    values ('lifetime', 'lifetime ceiling objective long enough', 'captured', 200, 'owner', 4, true) returning id into mid;
  for i in 1..4 loop insert into public.tasks (title, status, mission_id, mission_role) values ('Mission: step ' || i, 'todo', mid, 'step'); end loop;
  select id into tid from public.tasks where mission_id = mid and title = 'Mission: step 1';
  c := public.reserve_llm_budget(ag, 10, 'm', 'task ' || tid);
  update public.llm_calls set status = 'done', actual_cents = 10 where id = c;
  update public.tasks set status = 'cancelled' where id = tid;                        -- paid step cancelled
  begin insert into public.tasks (title, status, mission_id, mission_role) values ('Mission: step 1 again', 'todo', mid, 'step'); raise exception 'paid cancelled step freed its slot';
  exception when raise_exception then if sqlerrm like 'paid cancelled%' then raise; end if; end;
  update public.tasks set status = 'cancelled' where mission_id = mid and title = 'Mission: step 4';   -- unpaid step cancelled
  insert into public.tasks (title, status, mission_id, mission_role) values ('Mission: step 4 again', 'todo', mid, 'step');
  begin insert into public.tasks (title, status, mission_id, mission_role) values ('Mission: step 6', 'todo', mid, 'step'); raise exception 'ceiling exceeded after replacement';
  exception when raise_exception then if sqlerrm like 'ceiling%' then raise; end if; end;
end $$;
select 'lifetime_ceiling_ok';


-- Focus-mode isolation (database level): backlog, cron-made tasks, chat, budget inside focus, cleanup, stale-focus alert
do $$ declare ag text; mid uuid; t_in uuid; t_bk uuid; c uuid; n int;
begin
  select slug into ag from public.agents where status = 'active' and slug <> 'jarvis-chat' limit 1;
  if not exists (select 1 from public.agents where slug = 'jarvis-chat') then
    insert into public.agents (slug, title, charter, metric, status) values ('jarvis-chat', 'Jarvis chat', 'owner chat', 'm', 'active');
  end if;
  update public.agents set daily_spend_cap_cents = 100000 where slug in (ag, 'jarvis-chat');
  update public.system_state set daily_spend_cap_cents = 100000, kill_switch = false, pause_reason = null where id = 1;
  insert into public.missions (title, objective, status, budget_cents, created_by, max_steps, strict_steps)
    values ('focus iso', 'focus isolation objective long enough', 'captured', 20, 'owner', 4, true) returning id into mid;
  insert into public.tasks (title, status, mission_id, mission_role) values ('Mission: in focus', 'doing', mid, 'step') returning id into t_in;
  insert into public.tasks (title, status, created_by) values ('Daily planning backlog', 'doing', 'system') returning id into t_bk;
  perform public.set_focus_mission(mid, 'owner:test');

  -- backlog (cron/system task), triage and any non-mission agent are refused by the gateway itself
  begin perform public.reserve_llm_budget(ag, 1, 'm', 'task ' || t_bk); raise exception 'backlog task spent in focus';
  exception when raise_exception then if sqlerrm like 'backlog%' then raise; end if; end;
  begin perform public.reserve_llm_budget(ag, 1, 'm', 'triage ' || gen_random_uuid()); raise exception 'triage spent in focus';
  exception when raise_exception then if sqlerrm like 'triage%' then raise; end if; end;
  -- a purpose that merely looks like a task id but is not one is refused too
  begin perform public.reserve_llm_budget(ag, 1, 'm', 'task not-a-uuid'); raise exception 'malformed purpose spent in focus';
  exception when raise_exception then if sqlerrm like 'malformed%' then raise; end if; end;
  -- owner chat stays available (metered by the normal caps); it is not backlog
  c := public.reserve_llm_budget('jarvis-chat', 1, 'm', 'chat');
  if c is null then raise exception 'chat blocked by focus'; end if;
  -- the mission itself runs, and its own budget (20c) is still a hard stop inside focus
  c := public.reserve_llm_budget(ag, 15, 'm', 'task ' || t_in);
  update public.llm_calls set status = 'done', actual_cents = 15 where id = c;
  begin perform public.reserve_llm_budget(ag, 10, 'm', 'task ' || t_in); raise exception 'mission overspent inside focus';
  exception when raise_exception then if sqlerrm like 'mission overspent%' then raise; end if; end;
  -- a cron queue function runs fine in focus (it only makes tasks), but those tasks cannot spend
  perform public.queue_outreach_drafts();

  -- stale focus is flagged: finish the mission, the alert must fire once
  update public.missions set status = 'rejected' where id = mid;
  delete from public.alert_state;
  select count(*) into n from public.owner_messages where body like 'ALERT: Focus mode is still ON%';
  perform public.ops_alerts();
  if (select count(*) from public.owner_messages where body like 'ALERT: Focus mode is still ON%') <> n + 1 then raise exception 'stale focus not flagged'; end if;

  -- cleanup: owner clears it, backlog may spend again, and the action is audited
  perform public.set_focus_mission(null, 'owner:test');
  c := public.reserve_llm_budget(ag, 1, 'm', 'task ' || t_bk);
  if not exists (select 1 from public.audit_log where action = 'focus_cleared') then raise exception 'cleanup not audited'; end if;
  if (select focus_mission from public.system_state where id = 1) is not null then raise exception 'focus still set'; end if;
end $$;
select 'focus_isolation_ok';

-- Draft queue: one open task per venture, a daily circuit breaker, and the pause guard (the Nov 2026 storm)
do $$ declare vid uuid; n int; ag text := 'qzv-division'; i int; made int;
begin
  insert into public.ventures (slug, name, kind, status) values ('qzv', 'QZV test venture', 'revenue', 'active') returning id into vid;
  insert into public.agents (slug, title, charter, metric, status, venture_id) values (ag, 'QZV division', 'c', 'm', 'active', vid);
  for i in 1..4 loop
    insert into public.leads (venture_id, name, email, status, do_not_contact) values (vid, 'Lead ' || i, 'lead' || i || '@qzv.example', 'new', false);
  end loop;
  update public.system_state set pause_reason = 'api_credits', paused_at = now() where id = 1;
  if public.queue_outreach_drafts() <> 0 then raise exception 'drafts queued while paused'; end if;
  update public.system_state set pause_reason = null, paused_at = null where id = 1;
  if public.queue_outreach_drafts() <> 1 then raise exception 'first run should queue one task'; end if;
  if public.queue_outreach_drafts() <> 0 or public.queue_outreach_drafts() <> 0 then raise exception 'repeat cron runs queued duplicates'; end if;
  select count(*) into n from public.tasks where venture_id = vid and title like 'Draft outreach%'; if n <> 1 then raise exception 'expected 1 task, got %', n; end if;
  -- a failure: the task blocks; no respawn inside the 12 h cool-down
  update public.tasks set status = 'blocked', updated_at = now() where venture_id = vid and title like 'Draft outreach%';
  if public.queue_outreach_drafts() <> 0 then raise exception 'respawned inside cool-down'; end if;
  -- after the cool-down a new one may start, but never more than 3 a day, whatever happens to them
  for i in 1..5 loop
    update public.tasks set status = 'cancelled', updated_at = now() - interval '13 hours' where venture_id = vid and title like 'Draft outreach%' and status in ('todo','doing','blocked');
    perform public.queue_outreach_drafts();
  end loop;
  select count(*) into n from public.tasks where venture_id = vid and title like 'Draft outreach%';
  if n > 3 then raise exception 'circuit breaker failed: % tasks in a day', n; end if;
  -- concurrent-style duplicate insert is refused by the database even if the function is bypassed
  begin
    insert into public.tasks (venture_id, title, status, dedupe_key) select vid, 'Draft outreach x', 'todo', 'draft-outreach:' || vid
      from generate_series(1, 2);
    raise exception 'duplicate open key accepted';
  exception when unique_violation then null; end;
end $$;
select 'draft_queue_ok';

-- chat exemption must not be usable by a backlog TASK that is merely assigned to the chat agent
do $$ declare mid uuid; tb uuid;
begin
  insert into public.missions (title, objective, status, created_by) values ('focus chat', 'focus chat objective long enough', 'captured', 'owner') returning id into mid;
  insert into public.tasks (title, status, assigned_agent, created_by) values ('chat-agent backlog', 'doing', 'jarvis-chat', 'system') returning id into tb;
  perform public.set_focus_mission(mid, 'owner:test');
  begin perform public.reserve_llm_budget('jarvis-chat', 1, 'm', 'task ' || tb); raise exception 'chat-agent task bypassed focus';
  exception when raise_exception then if sqlerrm like 'chat-agent%' then raise; end if; end;
  perform public.reserve_llm_budget('jarvis-chat', 1, 'm', 'chat message');
  perform public.set_focus_mission(null, 'owner:test');
end $$;
select 'chat_exemption_scoped_ok';
-- INDEPENDENT CONTROLS: each of the six guards is shown to stop spend/sending ON ITS OWN while every other guard is wide open.
do $$ declare ag text; ag2 text; mid uuid; t1 uuid; c uuid; l uuid; o uuid; lim text;
begin
  select slug into ag from public.agents where status = 'active' and slug <> 'jarvis-chat' order by slug limit 1;
  select slug into ag2 from public.agents where status = 'active' and slug <> 'jarvis-chat' and slug <> ag order by slug limit 1;
  delete from public.llm_calls;
  update public.agents set daily_spend_cap_cents = 100000;
  update public.system_state set daily_spend_cap_cents = 100000, kill_switch = false, pause_reason = null, focus_mission = null, mode = 'dry_run' where id = 1;
  -- (1) 200c mission budget alone: global/agent caps 100000c, no focus, kill off
  insert into public.missions (title, objective, status, budget_cents, created_by, max_steps, strict_steps)
    values ('ctl', 'independent control objective long enough', 'captured', 200, 'owner', 4, true) returning id into mid;
  insert into public.tasks (title, status, mission_id, mission_role) values ('Mission: s', 'doing', mid, 'step') returning id into t1;
  c := public.reserve_llm_budget(ag, 200, 'm', 'task ' || t1); update public.llm_calls set status = 'done', actual_cents = 200 where id = c;
  begin perform public.reserve_llm_budget(ag, 1, 'm', 'task ' || t1); raise exception 'CTL1 201st cent accepted';
  exception when raise_exception then if sqlerrm like 'CTL1%' then raise; end if; end;
  -- (2) 4-step lifetime ceiling alone is covered by step_limit_ok / lifetime_ceiling_ok (no spend involved)
  -- (3) focus alone: a different mission is refused although its own budget and every cap have room
  insert into public.tasks (title, status, created_by) values ('backlog', 'doing', 'system') returning id into t1;
  perform public.set_focus_mission(mid, 'owner:test');
  begin perform public.reserve_llm_budget(ag, 1, 'm', 'task ' || t1); raise exception 'CTL3 focus let backlog spend';
  exception when raise_exception then if sqlerrm like 'CTL3%' then raise; end if; end;
  perform public.set_focus_mission(null, 'owner:test');
  -- (4) global daily cap alone (330c): no mission budget, no focus, agent caps huge
  delete from public.llm_calls;
  update public.system_state set daily_spend_cap_cents = 330 where id = 1;
  c := public.reserve_llm_budget(ag, 200, 'm', 'untracked'); update public.llm_calls set status = 'done', actual_cents = 200 where id = c;
  c := public.reserve_llm_budget(ag2, 130, 'm', 'untracked'); update public.llm_calls set status = 'done', actual_cents = 130 where id = c;   -- exactly 330 across two agents
  begin perform public.reserve_llm_budget(ag2, 1, 'm', 'untracked'); raise exception 'CTL4 331st cent accepted';
  exception when raise_exception then if sqlerrm like 'CTL4%' then raise; end if; end;
  -- (5) dry_run alone: an approved, QA-passed draft cannot be marked sent while kill switch is OFF
  update public.system_state set daily_spend_cap_cents = 100000 where id = 1;
  insert into public.leads (venture_id, name, email, source, status) values ((select id from public.ventures limit 1), 'ctl lead', 'ctl@example.com', 'test', 'new') returning id into l;
  insert into public.outbox (venture_id, agent, channel, to_ref, body, status, lead_id) values ((select id from public.ventures limit 1), ag, 'email', 'ctl@example.com', 'Subject: x' || E'\nhi', 'draft', l) returning id into o;
  update public.outbox set status = 'qa_passed', qa_agent = ag2 where id = o;
  update public.outbox set status = 'approved' where id = o;
  begin update public.outbox set status = 'sent' where id = o; raise exception 'CTL5 sent in dry_run';
  exception when raise_exception then if sqlerrm like 'CTL5%' then raise; end if; if sqlerrm !~* 'dry.run' then raise exception 'CTL5 wrong reason: %', sqlerrm; end if; end;
  -- (6) kill switch alone: spend refused with everything else open; and sending refused even in live mode
  update public.system_state set kill_switch = true where id = 1;
  begin perform public.reserve_llm_budget(ag, 1, 'm', 'untracked'); raise exception 'CTL6 spend under kill switch';
  exception when raise_exception then if sqlerrm like 'CTL6%' then raise; end if; if sqlerrm !~* 'kill switch' then raise exception 'CTL6 wrong reason: %', sqlerrm; end if; end;
  update public.system_state set mode = 'approve_first' where id = 1;
  begin update public.outbox set status = 'sent' where id = o; raise exception 'CTL6b sent under kill switch';
  exception when raise_exception then if sqlerrm like 'CTL6b%' then raise; end if; if sqlerrm !~* 'kill switch' then raise exception 'CTL6b wrong reason: %', sqlerrm; end if; end;
  update public.system_state set kill_switch = false, mode = 'dry_run' where id = 1;
  if exists (select 1 from public.outbox where status = 'sent') then raise exception 'something was sent'; end if;
end $$;
select 'independent_controls_ok';

