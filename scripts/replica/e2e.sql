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
