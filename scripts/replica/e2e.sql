\set ON_ERROR_STOP on
insert into auth.users (id, email) values ('11111111-1111-1111-1111-111111111111', 'owner@example.com');
insert into public.app_owners (email) values ('owner@example.com');
select set_config('app.uid', '11111111-1111-1111-1111-111111111111', false), set_config('app.email', 'owner@example.com', false);
select 'is_owner', public.is_app_owner();
select 'snapshot keys', jsonb_object_keys(public.app_snapshot()) k order by 2 limit 40;
select 'create_venture', public.create_venture('acme','Acme Cleaning','revenue','paying customers',3000,'owner:test');
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
