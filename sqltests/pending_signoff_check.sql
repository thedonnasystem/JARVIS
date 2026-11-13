-- Proves ops/pending_signoff/audit_spend_send_hardening.sql on a SCRATCH database, in one rolled-back transaction. The pending file is NOT a
-- migration and is never applied for real; this test is how the owner can see, before signing off, what each change does and that the
-- existing guarantees (caps, kill switch, dry-run, approvals, suppression, daily limits) still hold afterwards.
-- The "BEFORE" lines record today's behaviour as NOTICEs (they ARE the findings, so they never fail); every "AFTER" line is an assertion.
begin;

create or replace function pg_temp.refused(p_sql text) returns text language plpgsql as $f$
begin execute p_sql; return null; exception when others then return sqlerrm; end $f$;
create or replace function pg_temp.expect(p_id text, p_sql text, p_like text default null) returns void language plpgsql as $f$
declare m text;
begin
  m := pg_temp.refused(p_sql);
  if m is null then raise exception 'PENDING FAIL %: succeeded but must be refused: %', p_id, left(p_sql, 200); end if;
  if p_like is not null and m not ilike p_like then raise exception 'PENDING FAIL %: refused for the wrong reason [%]', p_id, m; end if;
end $f$;
create or replace function pg_temp.ok(p_id text, p_sql text) returns void language plpgsql as $f$
declare m text;
begin
  m := pg_temp.refused(p_sql);
  if m is not null then raise exception 'PENDING FAIL %: must succeed but was refused [%]: %', p_id, m, left(p_sql, 160); end if;
end $f$;

-- Supabase gives service_role the sequences too; the replica (tables copied without default privileges for sequences) does not
grant usage on all sequences in schema public to service_role;
alter role service_role bypassrls;   -- as on Supabase (the replica role is plain NOLOGIN); rolled back with the transaction
grant usage on schema public to anon, authenticated, service_role;   -- live grants this; a fresh replica schema does not

do $$
declare base int; cid uuid; m text; res uuid; r jsonb; va uuid; o uuid := '00000000-0000-0000-0000-00000000d001';
begin
  if not exists (select 1 from pg_trigger where tgname = 'outbox_rules' and tgrelid = 'public.outbox'::regclass) then
    create trigger outbox_rules before insert or update on public.outbox for each row execute function public.enforce_outbox_rules();
  end if;
  insert into public.agents (slug, title, daily_spend_cap_cents) values ('pend-agent', 'Pending test', 500);
  insert into public.ventures (slug, name, kind) values ('pend-v', 'Pend V', 'revenue') returning id into va;
  update public.system_state set kill_switch = false, mode = 'auto_in_caps', focus_mission = null where id = 1;
  update public.capital_policy set operating_fund_cents = 100000000, updated_by = 'owner:audit';
  select coalesce(sum(coalesce(actual_cents, reserved_cents)), 0) into base from public.llm_calls where status in ('reserved', 'done')
     and started_at >= date_trunc('day', now() at time zone 'America/Toronto') at time zone 'America/Toronto';
  update public.system_state set daily_spend_cap_cents = base + 100 where id = 1;

  m := pg_temp.refused($q$select public.reserve_llm_budget('pend-agent', -500, 'm', 'x')$q$);
  raise notice 'BEFORE F7a: a negative estimate is %', case when m is null then 'ACCEPTED (and then 500 more cents fit under the cap)' else 'refused' end;
  cid := public.reserve_llm_budget('pend-agent', 10, 'm', 'x');
  perform public.settle_llm_call(cid, 10, 'done');
  m := pg_temp.refused(format('select public.settle_llm_call(%L, 0, ''failed'')', cid));
  raise notice 'BEFORE F7b: re-settling a finished call to 0/failed is %', case when m is null then 'ACCEPTED (its spend disappears from every cap)' else 'refused' end;
  m := pg_temp.refused(format('select public.settle_llm_call(%L, -1000, ''done'')', cid));
  raise notice 'BEFORE F7c: a negative actual cost is %', case when m is null then 'ACCEPTED' else 'refused' end;
  begin   -- (undone with an exception so the money limits of the AFTER part start clean)
    r := public.reserve_spend('audit', 'research', 'Vendor', 'a real purpose', 'a real benefit', 'none', 100);
    raise notice 'BEFORE F9: a paid reservation labelled with the GREEN action "research" is %', r->>'decision';
    r := public.reserve_spend('audit', 'routine_expense', 'Vendor', 'a real purpose', 'a real benefit', 'none', 100);
    m := public.settle_spend((r->>'reservation_id')::uuid, 99999999, 'R')::text;
    raise notice 'BEFORE F8: settling a $1 reservation for $999,999.99 gives %', left(m, 20);
    raise exception 'UNDO';
  exception when others then if sqlerrm <> 'UNDO' then raise; end if; end;
  insert into public.outbox (id, agent, channel, to_ref, body, venture_id) values (o, 'donna-ops', 'email', 'pend1@example.com', 'x unsubscribe', va);
  update public.outbox set status = 'qa_passed', qa_agent = 'ceo' where id = o; update public.outbox set status = 'approved' where id = o;
  update public.system_state set kill_switch = true where id = 1;
  m := pg_temp.refused(format('update public.outbox set status = ''sent'', sent_by = ''owner'' where id = %L', o));
  raise notice 'BEFORE F10: any API writer sending with sent_by=owner while the KILL SWITCH is on: %', case when m is null then 'ALLOWED' else 'refused' end;
  update public.system_state set kill_switch = false where id = 1;
  m := pg_temp.refused(format('update public.outbox set status = ''draft'' where id = %L', o));
  raise notice 'BEFORE F11: a sent message going back to draft is %', case when m is null then 'ALLOWED (it can be re-sent)' else 'refused' end;
  set local role service_role;
  m := pg_temp.refused($q$insert into public.action_policy (action, tier, description) values ('evil_green', 'green', 'x')$q$);
  reset role;
  raise notice 'BEFORE F12: the API role adding a new GREEN policy action is %', case when m is null then 'ALLOWED' else 'refused' end;
end $$;

\ir ../ops/pending_signoff/audit_spend_send_hardening.sql

do $$
declare base int; cid uuid; cid2 uuid; res uuid; r jsonb; va uuid; lid uuid; o uuid; o2 uuid; n int; led int;
begin
  select id into va from public.ventures where slug = 'pend-v';
  update public.system_state set kill_switch = false, mode = 'auto_in_caps', focus_mission = null where id = 1;
  select coalesce(sum(coalesce(actual_cents, reserved_cents)), 0) into base from public.llm_calls where status in ('reserved', 'done')
     and started_at >= date_trunc('day', now() at time zone 'America/Toronto') at time zone 'America/Toronto';
  update public.system_state set daily_spend_cap_cents = base + 100 where id = 1;

  -- 1. gateway
  perform pg_temp.expect('P1 negative estimate', $q$select public.reserve_llm_budget('pend-agent', -1, 'm', 'x')$q$, '%zero or more%');
  perform pg_temp.expect('P1b null estimate', $q$select public.reserve_llm_budget('pend-agent', null, 'm', 'x')$q$, '%zero or more%');
  cid := public.reserve_llm_budget('pend-agent', 60, 'm', 'x');
  perform pg_temp.expect('P1c company cap still applies', $q$select public.reserve_llm_budget('pend-agent', 50, 'm', 'x')$q$, '%company daily spend cap%');
  update public.system_state set kill_switch = true where id = 1;
  perform pg_temp.expect('P1d kill switch still applies', $q$select public.reserve_llm_budget('pend-agent', 1, 'm', 'x')$q$, '%kill switch%');
  update public.system_state set kill_switch = false where id = 1;
  perform pg_temp.expect('P2 negative actual', format('select public.settle_llm_call(%L, -1, ''done'')', cid), '%zero or more%');
  perform public.settle_llm_call(cid, 25, 'done');
  perform public.settle_llm_call(cid, 0, 'failed');   -- a no-op now
  if (select status || actual_cents::text from public.llm_calls where id = cid) <> 'done25' then raise exception 'PENDING FAIL P2b: a settled call was changed'; end if;
  cid2 := public.reserve_llm_budget('pend-agent', 5, 'm', 'x');
  update public.llm_calls set status = 'released' where id = cid2;   -- what the restart recovery does
  perform public.settle_llm_call(cid2, 7, 'done');
  if (select status || actual_cents::text from public.llm_calls where id = cid2) <> 'done7' then raise exception 'PENDING FAIL P2c: a late finish of a released call was lost'; end if;

  -- 3. capital
  begin
    r := public.reserve_spend('audit', 'research', 'Vendor', 'a real purpose', 'a real benefit', 'none', 100);
    if r->>'decision' = 'allow' then raise exception 'PENDING FAIL P3: a green label on a paid reservation was allowed: %', r; end if;
    raise exception 'PENDING FAIL P3: expected the guard to raise, got %', r;
  exception when others then
    if sqlerrm like 'PENDING FAIL%' then raise; end if;
    if sqlerrm not ilike '%yellow or red%' then raise exception 'PENDING FAIL P3: wrong refusal %', sqlerrm; end if;
  end;
  r := public.reserve_spend('audit', 'routine_expense', 'Vendor', 'a real purpose', 'a real benefit', 'none', 1000);
  if r->>'decision' <> 'allow' then raise exception 'PENDING FAIL P3b: a normal expense was refused: %', r; end if;
  res := (r->>'reservation_id')::uuid;
  select count(*) into led from public.ledger where kind = 'expense';
  if (public.settle_spend(res, 1001, 'R1')->>'ok')::boolean then raise exception 'PENDING FAIL P4: settled above the reservation'; end if;
  if (public.settle_spend(res, -5, 'R1')->>'ok')::boolean then raise exception 'PENDING FAIL P4b: settled a negative amount'; end if;
  if (public.settle_spend(res, 0, 'R1')->>'ok')::boolean then raise exception 'PENDING FAIL P4c: settled zero'; end if;
  if (select count(*) from public.ledger where kind = 'expense') <> led then raise exception 'PENDING FAIL P4d: a refused settlement wrote the ledger'; end if;
  if not (public.settle_spend(res, 900, 'R1')->>'ok')::boolean then raise exception 'PENDING FAIL P4e: a smaller real amount was refused'; end if;
  if (public.settle_spend(res, 900, 'R1')->>'ok')::boolean then raise exception 'PENDING FAIL P4f: settled twice'; end if;
  r := public.prepare_payment('audit', 'Payee Co', 1800, 'domain renewal', 'none');
  if r->>'decision' <> 'allow' then raise exception 'PENDING FAIL P5: payment instructions broke: %', r; end if;

  -- 4./5. outbox
  o := '00000000-0000-0000-0000-00000000d002'; o2 := '00000000-0000-0000-0000-00000000d003';
  insert into public.outbox (id, agent, channel, to_ref, body, venture_id) values (o, 'donna-ops', 'email', 'pend2@example.com', 'x unsubscribe', va);
  update public.outbox set status = 'qa_passed', qa_agent = 'ceo' where id = o; update public.outbox set status = 'approved' where id = o;
  update public.system_state set kill_switch = true where id = 1;
  perform pg_temp.expect('P6 sent_by=owner by raw update, kill switch', format('update public.outbox set status = ''sent'', sent_by = ''owner'' where id = %L', o), '%kill switch%');
  update public.system_state set kill_switch = false, mode = 'dry_run' where id = 1;
  perform pg_temp.expect('P6b sent_by=owner by raw update, dry-run', format('update public.outbox set status = ''sent'', sent_by = ''owner'' where id = %L', o), '%dry run%');
  perform pg_temp.expect('P7 non-owner uses owner_mark_sent', format('select public.owner_mark_sent(%L, ''jarvis'')', o), '%only the owner%');
  update public.system_state set kill_switch = true where id = 1;
  r := public.owner_mark_sent(o, 'owner:telegram');       -- the owner records his own manual send even in dry-run + kill switch, as before
  if not (r->>'ok')::boolean or (select status from public.outbox where id = o) <> 'sent' or (select sent_by from public.outbox where id = o) <> 'owner' then raise exception 'PENDING FAIL P8: the owner cannot record a manual send: %', r; end if;
  if current_setting('app.owner_send', true) = 'on' then raise exception 'PENDING FAIL P8b: the owner flag leaked out of owner_mark_sent'; end if;
  if (public.owner_mark_sent(o, 'owner:telegram')->>'ok')::boolean then raise exception 'PENDING FAIL P8c: a sent row was marked sent again'; end if;
  perform pg_temp.expect('P9 sent is final', format('update public.outbox set status = ''draft'' where id = %L', o), '%already been delivered%');
  perform pg_temp.expect('P9b sent is final (rejected)', format('update public.outbox set status = ''rejected'' where id = %L', o), '%already been delivered%');
  perform pg_temp.ok('P9c other columns of a sent row can still be updated', format('update public.outbox set qa_notes = ''n'' where id = %L', o));
  -- the agent path is unchanged: allowed in auto_in_caps, refused in kill / dry-run / approve_first, per-lead daily limit kept
  update public.system_state set kill_switch = false, mode = 'auto_in_caps' where id = 1;
  insert into public.outbox (id, agent, channel, to_ref, body, venture_id) values (o2, 'donna-ops', 'email', 'pend3@example.com', 'x unsubscribe', va);
  update public.outbox set status = 'qa_passed', qa_agent = 'ceo' where id = o2; update public.outbox set status = 'approved' where id = o2;
  update public.system_state set mode = 'dry_run' where id = 1;
  perform pg_temp.expect('P10 agent send in dry-run', format('update public.outbox set status = ''sent'', sent_by = ''system'' where id = %L', o2), '%dry run%');
  update public.system_state set mode = 'auto_in_caps' where id = 1;
  perform pg_temp.ok('P10b agent send in auto_in_caps', format('update public.outbox set status = ''sent'', sent_by = ''system'' where id = %L', o2));
  -- the owner marker does not switch off the opt-out list
  insert into public.leads (venture_id, name, email) values (va, 'Pend lead', 'pend4@example.com') returning id into lid;
  insert into public.outbox (id, agent, channel, to_ref, body, venture_id, lead_id) values ('00000000-0000-0000-0000-00000000d004', 'donna-ops', 'email', 'pend4@example.com', 'x', va, lid);
  update public.outbox set status = 'qa_passed', qa_agent = 'ceo' where id = '00000000-0000-0000-0000-00000000d004';
  update public.outbox set status = 'approved' where id = '00000000-0000-0000-0000-00000000d004';
  perform public.mark_do_not_contact(lid, 'unsubscribe', 'owner:t');
  r := public.owner_mark_sent('00000000-0000-0000-0000-00000000d004', 'owner:telegram');
  if (r->>'ok')::boolean then raise exception 'PENDING FAIL P11: the owner marker recorded a send to an opted-out address'; end if;

  -- 6. policy rows
  set local role service_role;
  perform pg_temp.expect('P12 API role adds a green action', $q$insert into public.action_policy (action, tier, description) values ('evil_green', 'green', 'x')$q$, '%only the owner%');
  perform pg_temp.ok('P12b the API role adds an action WITH the owner marker', $q$insert into public.action_policy (action, tier, description, updated_by) values ('owner_added', 'red', 'x', 'owner:telegram')$q$);
  reset role;
  perform pg_temp.ok('P12c migrations / SQL editor (database owner) can still seed', $q$insert into public.action_policy (action, tier, description) values ('seed_added', 'red', 'x')$q$);
end $$;

rollback;
