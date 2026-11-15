-- SQL-level checks for migrations/20261117_client_workspaces_v1.sql. SCRATCH replica only. One transaction, rolled back.
-- Proves: default-deny grants, cross-client isolation (composite FKs, summaries), sensitive-data refusal on every table and column,
-- ordinary lead data accepted, spend refused until the owner sets a budget and again past it.
begin;
do $$
declare a uuid; b uuid; ca uuid; cb uuid; l uuid; t text; r text; f text; s text; ok boolean; j jsonb;
begin
  foreach t in array array['client_workspaces', 'ws_campaigns', 'ws_leads', 'ws_ledger'] loop
    if not (select relrowsecurity from pg_class where oid = ('public.' || t)::regclass) then raise exception 'W1 RLS off on %', t; end if;
    if exists (select 1 from pg_policy where polrelid = ('public.' || t)::regclass) then raise exception 'W2 policy on %', t; end if;
    foreach r in array array['anon', 'authenticated'] loop
      if has_table_privilege(r, 'public.' || t, 'select') or has_table_privilege(r, 'public.' || t, 'insert') then raise exception 'W3 % has access to %', r, t; end if;
    end loop;
    foreach r in array array['insert', 'update', 'delete', 'truncate'] loop
      if has_table_privilege('service_role', 'public.' || t, r) then raise exception 'W4 service_role can % %', r, t; end if;
    end loop;
  end loop;
  foreach f in array array['public.ws_sensitive_hits(text)', 'public.ws_guard()', 'public.ws_add_lead(uuid,uuid,text,text,text,text,text)', 'public.ws_record_spend(uuid,uuid,integer,text)', 'public.ws_summary(uuid)'] loop
    foreach r in array array['anon', 'authenticated'] loop
      if has_function_privilege(r, f, 'execute') then raise exception 'W5 % can execute %', r, f; end if;
    end loop;
    if not has_function_privilege('service_role', f, 'execute') then raise exception 'W6 service_role cannot execute %', f; end if;
  end loop;

  insert into public.client_workspaces (slug, name, vertical, status) values ('t-mortgage', 'Test Mortgage Broker', 'mortgage', 'active') returning id into a;
  insert into public.client_workspaces (slug, name, vertical, status) values ('t-insurance', 'Test Life Insurance', 'insurance', 'active') returning id into b;
  insert into public.ws_campaigns (workspace_id, name) values (a, 'A campaign') returning id into ca;
  insert into public.ws_campaigns (workspace_id, name) values (b, 'B campaign') returning id into cb;

  -- isolation: a lead cannot reference the other client's campaign, on any path
  l := public.ws_add_lead(a, ca, 'Pat Example', 'pat@example.com', '613-555-0142', 'web form', 'wants a callback about renewal');
  begin perform public.ws_add_lead(a, cb, 'Cross', null, null, 'x'); raise exception 'W7 cross-workspace campaign accepted';
  exception when foreign_key_violation then null; end;
  begin insert into public.ws_ledger (workspace_id, campaign_id, amount_cents) values (a, cb, 5); raise exception 'W8 cross-workspace ledger accepted';
  exception when foreign_key_violation then null; end;
  perform public.ws_add_lead(b, cb, 'Sam Other', 'sam@example.com', null, 'referral');
  j := public.ws_summary(a);
  if (j->'leads_by_stage'->>'new')::int <> 1 or j->>'workspace' <> 't-mortgage' then raise exception 'W9 summary leaks or is wrong: %', j; end if;
  if (select count(*) from public.ws_leads where workspace_id = b) <> 1 then raise exception 'W10 other workspace row count wrong'; end if;
  begin delete from public.client_workspaces where id = a; raise exception 'W11 workspace with data deleted';
  exception when foreign_key_violation then null; end;

  -- sensitive data is refused in every table and text column
  foreach s in array array['SIN 123-456-789', 'my sin is 123456789', 'card 4111 1111 1111 1111', 'passport scan attached', 'driver''s licence photo',
                           'bank statement attached', 'account number 55512', 'credit score 710', 'equifax report', 'mortgage application form',
                           'pay stub for May', 'T4 slip', 'annual income 120k', 'void cheque'] loop
    begin perform public.ws_add_lead(a, ca, 'Case', null, null, 'x', s); raise exception 'W12 accepted note: %', s;
    exception when raise_exception then if sqlerrm like 'W12%' then raise; end if; end;
    begin perform public.ws_add_lead(a, ca, s, null, null, 'x'); raise exception 'W13 accepted name: %', s;
    exception when raise_exception then if sqlerrm like 'W13%' then raise; end if; end;
  end loop;
  begin insert into public.ws_campaigns (workspace_id, name, channel) values (a, 'ok', 'upload bank statement'); raise exception 'W14 campaign channel accepted';
  exception when raise_exception then if sqlerrm like 'W14%' then raise; end if; end;
  begin insert into public.ws_ledger (workspace_id, amount_cents, note) values (a, 5, 'credit report fee'); raise exception 'W15 ledger note accepted';
  exception when raise_exception then if sqlerrm like 'W15%' then raise; end if; end;
  begin update public.ws_leads set note = 'SIN 987654321' where id = l; raise exception 'W16 update accepted';
  exception when raise_exception then if sqlerrm like 'W16%' then raise; end if; end;
  begin update public.client_workspaces set vertical = 'banking details' where id = a; raise exception 'W17 workspace update accepted';
  exception when raise_exception then if sqlerrm like 'W17%' then raise; end if; end;
  -- normal phone numbers and ordinary notes are NOT refused
  if public.ws_sensitive_hits('Call 613-555-0142 about a renewal in March') <> '{}' then raise exception 'W18 false positive on phone'; end if;

  -- review-found bypasses
  foreach s in array array['123 456 789 call 613 555 1234', '123.456.789', '123/456/789', '123_456_789', '1234 56789', '12 34 56 78 9', '１２３４５６７８９',
                           '١٢٣٤٥٦٧٨٩', 'S.I.N 5', 's i n', 'social-insurance', 'SSN', 'bank account 1234567', 'chequing account', 'Experian', 'credit history',
                           'FICO', 'pre approval letter', 'loan application', 'T4A', 'tax return', 'OHIP', 'date of birth', 'salary', E's\u200bin'] loop
    if public.ws_sensitive_hits(s) = '{}' then raise exception 'W23 not flagged: %', s; end if;
  end loop;
  begin perform public.ws_add_lead(a, ca, '123', '456', '789', 'x'); raise exception 'W24 digits split across columns accepted';
  exception when raise_exception then if sqlerrm like 'W24%' then raise; end if; end;
  begin insert into public.client_workspaces (slug, name) values ('123456789', 'Digits'); raise exception 'W25 digit slug accepted';
  exception when raise_exception then if sqlerrm like 'W25%' then raise; end if; end;
  if public.ws_sensitive_hits('Call 613-555-0142 or (613) 555 0142 about a renewal in March') <> '{}' then raise exception 'W26 false positive on phones'; end if;
  foreach f in array array['client_workspaces', 'ws_campaigns', 'ws_leads', 'ws_ledger'] loop
    if has_table_privilege('service_role', 'public.' || f, 'trigger') or has_table_privilege('service_role', 'public.' || f, 'references') then raise exception 'W27 service_role keeps trigger/references on %', f; end if;
  end loop;

  -- money is default-deny, then capped
  begin perform public.ws_record_spend(a, ca, 5, 'ad test'); raise exception 'W19 spend accepted with no budget';
  exception when raise_exception then if sqlerrm like 'W19%' then raise; end if; end;
  update public.client_workspaces set monthly_budget_cents = 100 where id = a;
  perform public.ws_record_spend(a, ca, 60, 'ad test');
  begin perform public.ws_record_spend(a, ca, 60, 'ad test 2'); raise exception 'W20 spend over budget accepted';
  exception when raise_exception then if sqlerrm like 'W20%' then raise; end if; end;
  begin perform public.ws_record_spend(b, cb, 1); raise exception 'W21 spend for workspace with no budget accepted';
  exception when raise_exception then if sqlerrm like 'W21%' then raise; end if; end;
  if (public.ws_summary(a)->>'spent_cents')::int <> 60 or (public.ws_summary(b)->>'spent_cents')::int <> 0 then raise exception 'W22 spend not isolated'; end if;
end $$;
rollback;
