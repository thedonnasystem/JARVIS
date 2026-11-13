-- SQL-level checks for migrations/20261114_venture_generic_v1.sql. Run against a SCRATCH replica database only (after scripts/replica/run.sh):
--   psql "$REPLICA_URL" -v ON_ERROR_STOP=1 -f migrations/20261114_venture_generic_v1.sql -f sqltests/venture_generic_check.sql
-- (run.sh's rollback drill drops these functions at the end, hence re-applying the migration first.)
-- Everything runs in one transaction and is rolled back. Any failed assertion raises.
begin;
do $$
declare vid uuid; res jsonb; k jsonb; t uuid; before_ledger int; recent int; cnt int; lid uuid;
begin
  update public.system_state set pause_reason = null where id = 1;

  -- unknown venture
  begin perform public.ensure_venture_agents('no-such-venture', 'test'); raise exception 'T1 unknown venture accepted';
  exception when raise_exception then if sqlerrm like 'T1%' then raise; end if; end;
  if public.queue_prospect_task('no-such-venture') is not null then raise exception 'T2 task for unknown venture'; end if;
  if public.venture_kpis('no-such-venture') is not null then raise exception 'T3 kpis for unknown venture'; end if;

  -- a proposed (inactive) venture
  vid := public.create_venture('gen-test-one', 'Gen Test One', 'revenue', 'revenue', 0, 'generic loop test venture', 'test');
  select count(*) into recent from public.org_changes where kind = 'agent' and status = 'built' and created_at > now() - interval '7 days';
  if recent > 1 then raise exception 'SETUP: % agents already created this week in the scratch DB; need <=1', recent; end if;

  update public.system_state set daily_spend_cap_cents = 100000000 where id = 1;   -- so create_agent itself would leave new agents ACTIVE: only our pause keeps them asleep
  res := public.ensure_venture_agents('gen-test-one', 'test');
  if jsonb_array_length(res->'created') <> 2 then raise exception 'T4 expected 2 agents created: %', res; end if;
  select count(*) into cnt from public.agents where slug in ('gen-test-one-researcher','gen-test-one-division') and status = 'paused'
     and venture_id = vid and daily_spend_cap_cents <= 50 and can_contact_owner = false and department_slug = 'gen-test-one';
  if cnt <> 2 then raise exception 'T5 agents not paused/capped/owned by venture'; end if;
  res := public.ensure_venture_agents('gen-test-one', 'test');
  if jsonb_array_length(res->'created') <> 0 or jsonb_array_length(res->'existing') <> 2 then raise exception 'T6 not idempotent: %', res; end if;
  select count(*) into cnt from public.agents where venture_id = vid and slug like 'gen-test-one-%'; if cnt <> 3 then raise exception 'T6b agent count %', cnt; end if;

  -- creation limit (max 3 agents/week): 2 used by this venture, another venture needing 2 must be refused and create nothing
  perform public.create_venture('gen-test-two', 'Gen Test Two', 'revenue', 'revenue', 0, 'second generic loop test venture', 'test');
  begin perform public.ensure_venture_agents('gen-test-two', 'test'); raise exception 'T7 limit bypassed';
  exception when raise_exception then if sqlerrm like 'T7%' then raise; end if; if sqlerrm not like 'Agent creation limit%' then raise exception 'T7b wrong error %', sqlerrm; end if; end;
  if exists (select 1 from public.agents where slug like 'gen-test-two-%' and slug <> 'gen-test-two-manager') then raise exception 'T8 partial creation after refusal'; end if;

  -- prospecting: inactive venture, then active without a brief -> nothing
  if public.queue_prospect_task('gen-test-one') is not null then raise exception 'T9 task for inactive venture'; end if;
  perform public.activate_venture('gen-test-one', 'owner:test');
  select count(*) into cnt from public.agents where venture_id = vid and status = 'active'; if cnt <> 3 then raise exception 'T10 activation did not wake agents (%)', cnt; end if;
  if public.queue_prospect_task('gen-test-one') is not null then raise exception 'T11 task created without a brief'; end if;
  insert into public.venture_procedures (venture_id, title, steps) values (vid, 'prospecting brief', repeat(' ', 25));
  if public.queue_prospect_task('gen-test-one') is not null then raise exception 'T12 task from a blank brief'; end if;
  update public.venture_procedures set steps = 'Independent bookkeepers in Ottawa with 3+ staff and a public contact page.' where venture_id = vid;

  -- paused agent or global pause -> nothing
  update public.agents set status = 'paused' where slug = 'gen-test-one-researcher';
  if public.queue_prospect_task('gen-test-one') is not null then raise exception 'T13 task for paused researcher'; end if;
  update public.agents set status = 'active' where slug = 'gen-test-one-researcher';
  update public.system_state set pause_reason = 'test' where id = 1;
  if public.queue_prospect_task('gen-test-one') is not null then raise exception 'T14 task while system paused'; end if;
  update public.system_state set pause_reason = null where id = 1;

  t := public.queue_prospect_task('gen-test-one');
  if t is null then raise exception 'T15 no task with brief'; end if;
  select count(*) into cnt from public.tasks where id = t and venture_id = vid and assigned_agent = 'gen-test-one-researcher' and status = 'todo'
     and detail like '%Independent bookkeepers%' and detail like '%contact no one%' and dedupe_key = 'prospect:' || vid;
  if cnt <> 1 then raise exception 'T16 task content wrong'; end if;
  if public.queue_prospect_task('gen-test-one') is not null then raise exception 'T17 duplicate open task'; end if;
  if public.queue_all_prospect_tasks() <> 0 then raise exception 'T18 batch queued a duplicate'; end if;
  update public.tasks set status = 'done' where id = t;
  if public.queue_all_prospect_tasks() <> 1 then raise exception 'T20 batch should queue the venture with a brief'; end if;
  if public.queue_all_prospect_tasks() <> 0 then raise exception 'T21 batch not idempotent'; end if;
  -- Donna's own zero-arg function still resolves, unchanged
  perform public.queue_prospect_task();

  -- KPIs from real rows; no financial writes
  insert into public.leads (venture_id, name, email, status) values (vid, 'A Co', 'a@a.example', 'new') returning id into lid;
  insert into public.leads (venture_id, name, email, status, do_not_contact) values (vid, 'B Co', 'b@b.example', 'new', true);
  insert into public.leads (venture_id, name, status) values (vid, 'C Co', 'new');
  insert into public.outbox (venture_id, agent, channel, to_ref, body, lead_id) values (vid, 'gen-test-one-division', 'email', 'a@a.example', 'hi', lid);
  insert into public.outbox (venture_id, agent, channel, to_ref, body, status) values (vid, 'gen-test-one-division', 'email', 'z@z.example', 'hi', 'draft');
  update public.outbox set status = 'qa_passed', qa_agent = 'owner' where lead_id = lid;
  update public.outbox set status = 'approved' where lead_id = lid;
  insert into public.deals (venture_id, lead_id, stage, value_cents) values (vid, lid, 'won', 5000), (vid, lid, 'pitched', 100);
  insert into public.ledger (venture_id, kind, amount_cents, status) values (vid, 'revenue', 12345, 'received'), (vid, 'revenue', 999, 'expected'), (vid, 'expense', 500, 'received');
  select count(*) into before_ledger from public.ledger;
  k := public.venture_kpis('gen-test-one');
  if (k->>'leads')::int <> 3 or (k->>'emailable_leads')::int <> 1 or (k->>'drafted')::int <> 2 or (k->>'won_deals')::int <> 1
     or (k->>'revenue_cents')::int <> 12345 or (k->>'sent')::int <> 0 or (k->>'approved')::int <> 1 then raise exception 'T22 kpis wrong: %', k; end if;
  if (k->'deals_by_stage'->>'pitched')::int <> 1 then raise exception 'T23 deals_by_stage wrong: %', k; end if;
  select count(*) into cnt from public.ledger; if cnt <> before_ledger then raise exception 'T24 ledger changed'; end if;
  k := public.venture_kpis('gen-test-two');
  if (k->>'leads')::int <> 0 or (k->>'revenue_cents')::int <> 0 then raise exception 'T25 kpis leak across ventures: %', k; end if;
end $$;

-- privileges: only service_role may execute; anon/authenticated/public may not
do $$
declare f text; r text;
begin
  foreach f in array array['public.ensure_venture_agents(text,text)','public.queue_prospect_task(text)','public.queue_all_prospect_tasks()','public.venture_kpis(text)'] loop
    foreach r in array array['anon','authenticated'] loop
      if has_function_privilege(r, f, 'execute') then raise exception 'P1 % can execute %', r, f; end if;
    end loop;
    if not has_function_privilege('service_role', f, 'execute') then raise exception 'P2 service_role cannot execute %', f; end if;
  end loop;
end $$;
set local role anon;
do $$ begin
  begin perform public.venture_kpis('donna'); raise exception 'P3 anon ran venture_kpis';
  exception when insufficient_privilege then null; end;
  begin perform public.ensure_venture_agents('donna', 'owner'); raise exception 'P4 anon ran ensure_venture_agents';
  exception when insufficient_privilege then null; end;
end $$;
reset role;
set local role authenticated;
do $$ begin
  begin perform public.queue_prospect_task('donna'); raise exception 'P5 authenticated ran queue_prospect_task';
  exception when insufficient_privilege then null; end;
end $$;
reset role;
select 'venture_generic_sql_ok';
rollback;
