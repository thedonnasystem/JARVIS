-- SQL-level checks for migrations/20261115_venture_deals_replies_v1.sql. Run against a SCRATCH replica database only (scripts/replica/run.sh runs it).
-- One transaction, rolled back. Any failed assertion raises. Proves: grants (anon/authenticated cannot execute), the do-not-contact rule
-- (all ventures sharing an address, drafts rejected, no re-add, no un-flag, no draft/approve/send), owner-only confirmation, revenue only on confirm.
begin;
do $$
declare va uuid; vb uuid; la uuid; lb uuid; lc uuid; ld uuid; le uuid; lnew uuid; lx uuid;
        o1 uuid; o2 uuid; o3 uuid; o4 uuid; o5 uuid; d1 uuid; d2 uuid; d3 uuid; d4 uuid; r jsonb; k jsonb; f jsonb; cnt int; led0 int; ok boolean;
begin
  va := public.create_venture('dr-test-a', 'Dr Test A', 'revenue', 'revenue', 0, 'deal reply test venture A', 'test');
  vb := public.create_venture('dr-test-b', 'Dr Test B', 'revenue', 'revenue', 0, 'deal reply test venture B', 'test');
  insert into public.leads (venture_id, name, email, status) values (va, 'A shared', 'Shared@Example.com ', 'sent') returning id into la;
  insert into public.leads (venture_id, name, email, status) values (vb, 'B shared', 'shared@example.com', 'drafted') returning id into lb;
  insert into public.leads (venture_id, name, email, status) values (va, 'A other', 'other@example.com', 'new') returning id into lc;
  insert into public.leads (venture_id, name, email, status) values (va, 'A phone', null, 'contacted') returning id into ld;
  insert into public.leads (venture_id, name, email, status) values (va, 'A weird', 'w@example.com', 'closed') returning id into le;

  -- ---------- reply recording ----------
  begin perform public.record_lead_reply(lc, 'interested', 'x', 'jarvis'); raise exception 'R1 non-owner recorded a reply';
  exception when raise_exception then if sqlerrm like 'R1%' then raise; end if; end;
  begin perform public.record_lead_reply(lc, 'maybe', 'x', 'owner:test'); raise exception 'R2 bad kind accepted';
  exception when raise_exception then if sqlerrm like 'R2%' then raise; end if; end;
  begin perform public.record_lead_reply(gen_random_uuid(), 'interested', 'x', 'owner:test'); raise exception 'R2b unknown lead accepted';
  exception when raise_exception then if sqlerrm like 'R2b%' then raise; end if; end;
  perform public.record_lead_reply(lc, 'question', 'how much?', 'owner:test');
  if (select status from public.leads where id = lc) <> 'replied' then raise exception 'R3 question did not mark replied'; end if;
  perform public.record_lead_reply(lc, 'booked', 'Tue 10am', 'owner:test');
  if (select status from public.leads where id = lc) <> 'booked' then raise exception 'R3b booked not set'; end if;
  perform public.record_lead_reply(lc, 'interested', 'again', 'owner:test');
  if (select status from public.leads where id = lc) <> 'booked' then raise exception 'R3c a later reply demoted booked'; end if;
  if (select count(*) from public.lead_replies where lead_id = lc) <> 3 then raise exception 'R3d replies not stored'; end if;
  perform public.record_lead_reply(le, 'not_interested', 'no thanks', 'owner:test');
  if (select status from public.leads where id = le) <> 'lost' then raise exception 'R3e not_interested did not mark lost'; end if;

  -- ---------- unsubscribe: every venture sharing the address, open drafts rejected, sent left alone ----------
  insert into public.outbox (venture_id, agent, channel, to_ref, body, lead_id, status) values (va, null, 'email', 'shared@example.com', 'hi a', la, 'draft') returning id into o1;
  insert into public.outbox (venture_id, agent, channel, to_ref, body, lead_id, status) values (vb, null, 'email', 'Shared@example.com', 'hi b', lb, 'draft') returning id into o2;
  update public.outbox set status = 'qa_passed', qa_agent = 'owner' where id = o2;
  insert into public.outbox (venture_id, agent, channel, to_ref, body, status) values (vb, null, 'email', 'shared@example.com', 'hi loose', 'draft') returning id into o3;
  insert into public.outbox (venture_id, agent, channel, to_ref, body, lead_id, status) values (va, null, 'email', 'other@example.com', 'hi other', lc, 'draft') returning id into o4;
  r := public.record_lead_reply(la, 'unsubscribe', 'please remove me', 'owner:test');
  if (select count(*) from public.leads where id in (la, lb) and do_not_contact and status = 'do_not_contact') <> 2 then raise exception 'R4 not every venture''s lead marked: %', r; end if;
  if (select do_not_contact from public.leads where id = lc) then raise exception 'R4b unrelated lead marked'; end if;
  if not public.is_suppressed(' SHARED@example.com') then raise exception 'R4c address not suppressed'; end if;
  if (select count(*) from public.outbox where id in (o1, o2, o3) and status = 'rejected') <> 3 then raise exception 'R4d open drafts to the address not rejected'; end if;
  if (select status from public.outbox where id = o4) <> 'draft' then raise exception 'R4e unrelated draft touched'; end if;
  if not exists (select 1 from public.audit_log where action = 'do_not_contact' and target = 'leads/' || la) then raise exception 'R4f not audited'; end if;
  if (r->>'leads_marked')::int <> 2 then raise exception 'R4g counts %', r; end if;

  -- a reply never lifts do-not-contact
  r := public.record_lead_reply(la, 'interested', 'changed mind?', 'owner:test');
  if not coalesce((r->>'unchanged')::boolean, false) then raise exception 'R5a reply on a do-not-contact lead was processed: %', r; end if;
  if not (select do_not_contact from public.leads where id = la) or (select status from public.leads where id = la) <> 'do_not_contact' then raise exception 'R5 reply lifted do-not-contact'; end if;
  -- cannot un-flag; cannot re-add clean (any case/whitespace) in any venture
  update public.leads set do_not_contact = false, status = 'new' where id = lb;
  if not (select do_not_contact from public.leads where id = lb) then raise exception 'R6 lead un-flagged'; end if;
  insert into public.leads (venture_id, name, email, status) values (vb, 'B again', ' SHARED@example.com', 'new') returning id into lnew;
  if not (select do_not_contact from public.leads where id = lnew) or (select status from public.leads where id = lnew) <> 'do_not_contact' then raise exception 'R7 suppressed address re-added clean'; end if;

  -- ---------- drafting / approval / send paths all refuse ----------
  begin insert into public.outbox (venture_id, agent, channel, to_ref, body, lead_id, status) values (va, null, 'email', 'x@example.com', 'hi', la, 'draft'); raise exception 'R8 draft for do-not-contact lead inserted';
  exception when sqlstate 'P0001' then if sqlerrm like 'R8%' then raise; end if; end;
  begin insert into public.outbox (venture_id, agent, channel, to_ref, body, status) values (va, null, 'email', 'shared@EXAMPLE.com', 'hi', 'draft'); raise exception 'R9 draft to suppressed address inserted';
  exception when sqlstate 'P0001' then if sqlerrm like 'R9%' then raise; end if; end;
  insert into public.outbox (venture_id, agent, channel, to_ref, body, lead_id, status) values (va, null, 'email', 'other@example.com', 'hi2', lc, 'rejected') returning id into o5;  -- a rejected row is always allowed
  -- an older draft slipped past (simulate: trigger disabled while inserting, as if created before the opt-out), then each progress step must fail
  alter table public.outbox disable trigger outbox_dnc_guard;
  insert into public.outbox (venture_id, agent, channel, to_ref, body, lead_id, status) values (va, null, 'email', 'shared@example.com', 'old', null, 'draft') returning id into o5;
  alter table public.outbox enable trigger outbox_dnc_guard;
  begin update public.outbox set status = 'qa_passed', qa_agent = 'owner' where id = o5; raise exception 'R10 qa_passed for suppressed address';
  exception when sqlstate 'P0001' then if sqlerrm like 'R10%' then raise; end if; end;
  begin update public.outbox set status = 'approved' where id = o5; raise exception 'R11 approved for suppressed address';
  exception when sqlstate 'P0001' then if sqlerrm like 'R11%' then raise; end if; end;
  begin update public.outbox set status = 'sent', sent_by = 'owner' where id = o5; raise exception 'R12 sent for suppressed address';
  exception when sqlstate 'P0001' then if sqlerrm like 'R12%' then raise; end if; end;
  update public.outbox set status = 'rejected' where id = o5;   -- rejecting is always allowed

  -- raw flag path (no function): cascades to the other venture's lead sharing the address
  insert into public.leads (venture_id, name, email, status) values (va, 'raw a', 'raw@example.com', 'new') returning id into lx;
  insert into public.leads (venture_id, name, email, status) values (vb, 'raw b', 'raw@example.com', 'new') returning id into lnew;
  update public.leads set do_not_contact = true where id = lx;
  if not (select do_not_contact from public.leads where id = lnew) or not public.is_suppressed('raw@example.com') then raise exception 'R13 raw flag did not cascade'; end if;

  -- ---------- deals: owner-confirmed transitions; revenue only on confirm ----------
  select count(*) into led0 from public.ledger;
  begin perform public.create_deal(la, 100, 'owner:test'); raise exception 'D1 deal opened for do-not-contact lead';
  exception when raise_exception then if sqlerrm like 'D1%' then raise; end if; end;
  begin perform public.create_deal(lc, 100, 'jarvis'); raise exception 'D2 non-owner opened a deal';
  exception when raise_exception then if sqlerrm like 'D2%' then raise; end if; end;
  d1 := public.create_deal(lc, 5000, 'owner:test', 'first');
  if (select stage from public.deals where id = d1) <> 'pitched' then raise exception 'D3 new deal not pitched'; end if;
  begin perform public.set_deal_stage(d1, 'negotiating', 'jarvis'); raise exception 'D4 non-owner moved a deal';
  exception when raise_exception then if sqlerrm like 'D4%' then raise; end if; end;
  begin perform public.set_deal_stage(d1, 'won', 'owner:test'); raise exception 'D5 won without confirmation';
  exception when raise_exception then if sqlerrm like 'D5%' then raise; end if; if sqlerrm not like '%confirming it with an amount%' then raise exception 'D5a wrong refusal: %', sqlerrm; end if; end;
  begin perform public.set_deal_stage(d1, 'closed_won', 'owner:test'); raise exception 'D5b unknown stage accepted';
  exception when raise_exception then if sqlerrm like 'D5b%' then raise; end if; end;
  perform public.set_deal_stage(d1, 'negotiating', 'owner:test', 'talking');
  if (select count(*) from public.ledger) <> led0 then raise exception 'D6 stage move wrote the ledger'; end if;
  begin perform public.confirm_deal_won(d1, 5000, 'received', 'jarvis'); raise exception 'D7 non-owner confirmed a win';
  exception when raise_exception then if sqlerrm like 'D7%' then raise; end if; end;
  begin perform public.confirm_deal_won(d1, 0, 'received', 'owner:test'); raise exception 'D8 zero amount accepted';
  exception when raise_exception then if sqlerrm like 'D8%' then raise; end if; end;
  begin perform public.confirm_deal_won(d1, null, 'received', 'owner:test'); raise exception 'D8b null amount accepted';
  exception when raise_exception then if sqlerrm like 'D8b%' then raise; end if; end;
  begin perform public.confirm_deal_won(d1, 5000, 'maybe', 'owner:test'); raise exception 'D9 bad ledger status accepted';
  exception when raise_exception then if sqlerrm like 'D9%' then raise; end if; end;
  if (select count(*) from public.ledger) <> led0 or (select stage from public.deals where id = d1) <> 'negotiating' then raise exception 'D10 refused confirm changed state'; end if;
  r := public.confirm_deal_won(d1, 4500, 'received', 'owner:test', 'invoice 7');
  if (select count(*) from public.ledger) <> led0 + 1 then raise exception 'D11 expected exactly one ledger row'; end if;
  if not exists (select 1 from public.ledger where venture_id = va and kind = 'revenue' and amount_cents = 4500 and status = 'received' and note like 'deal ' || d1 || '%') then raise exception 'D12 ledger row wrong'; end if;
  if (select stage from public.deals where id = d1) <> 'won' or (select status from public.leads where id = lc) <> 'won' then raise exception 'D13 deal/lead not won'; end if;
  perform public.record_lead_reply(lc, 'not_interested', 'late reply', 'owner:test');
  if (select status from public.leads where id = lc) <> 'won' then raise exception 'D13b a reply demoted a won lead'; end if;
  begin perform public.confirm_deal_won(d1, 4500, 'received', 'owner:test'); raise exception 'D14 revenue recorded twice';
  exception when raise_exception then if sqlerrm like 'D14%' then raise; end if; end;
  begin perform public.set_deal_stage(d1, 'lost', 'owner:test'); raise exception 'D15 won deal moved';
  exception when raise_exception then if sqlerrm like 'D15%' then raise; end if; end;
  if (select count(*) from public.ledger) <> led0 + 1 then raise exception 'D16 ledger changed after refusals'; end if;
  -- legacy won-like stage names are terminal and cannot be won again (no double revenue)
  insert into public.deals (venture_id, lead_id, stage) values (va, lc, 'closed') returning id into d2;
  begin perform public.confirm_deal_won(d2, 100, 'received', 'owner:test'); raise exception 'D17 legacy closed deal confirmed again';
  exception when raise_exception then if sqlerrm like 'D17%' then raise; end if; end;
  -- lost path
  insert into public.leads (venture_id, name, email, status) values (va, 'lost one', 'lost@example.com', 'sent') returning id into lnew;
  d3 := public.create_deal(lnew, null, 'owner:test');
  perform public.set_deal_stage(d3, 'lost', 'owner:test', 'went elsewhere');
  if (select status from public.leads where id = lnew) <> 'lost' then raise exception 'D18 lost deal did not mark lead lost'; end if;
  begin perform public.set_deal_stage(d3, 'pitched', 'owner:test'); raise exception 'D19 lost deal reopened';
  exception when raise_exception then if sqlerrm like 'D19%' then raise; end if; end;

  -- ---------- funnel ----------
  f := public.lead_funnel('dr-test-a');
  -- A leads: la dnc, lc won, ld sent(contacted), le lost, lx dnc, lnew lost, 'raw a' = lx. plus 'B again' belongs to B.
  if (f->'counts'->>'do_not_contact')::int <> 2 or (f->'counts'->>'won')::int <> 1 or (f->'counts'->>'sent')::int <> 1
     or (f->'counts'->>'lost')::int <> 2 or (f->'counts'->>'new')::int <> 0 then raise exception 'F1 funnel wrong: %', f; end if;
  insert into public.leads (venture_id, name, email, status) values (va, 'weird status', 'ws@example.com', 'banana');
  f := public.lead_funnel('dr-test-a');
  if (f->'counts'->>'other')::int <> 1 then raise exception 'F2 unknown status not in other: %', f; end if;
  if (select sum(v::int) from jsonb_each_text(f->'counts') e(k, v)) <> (f->>'total')::int then raise exception 'F3 funnel does not add up to total'; end if;
  f := public.lead_funnel('dr-test-b');
  if (f->'counts'->>'won')::int <> 0 or (f->>'total')::int <> 3 or (f->'counts'->>'do_not_contact')::int <> 3 then raise exception 'F4 funnel leaks across ventures: %', f; end if;
  if public.lead_funnel('no-such-venture') is not null then raise exception 'F5 funnel for unknown venture'; end if;
  k := public.venture_kpis('dr-test-a');
  if k->'funnel' is null or (k->'funnel'->>'won')::int <> 1 or (k->>'won_deals')::int <> 2 or (k->>'revenue_cents')::int <> 4500 then raise exception 'F6 kpis extension wrong: %', k; end if;
  -- reply SLA: an interested reply older than the SLA and still 'replied' is counted; default 24h
  insert into public.leads (venture_id, name, email, status) values (vb, 'sla lead', 'sla@example.com', 'sent') returning id into ld;
  perform public.record_lead_reply(ld, 'interested', 'call me', 'owner:test');
  f := public.lead_funnel('dr-test-b');
  if (f->>'replies_over_sla')::int <> 0 or (f->>'reply_sla_hours')::int <> 24 then raise exception 'F7 fresh reply over SLA: %', f; end if;
  update public.lead_replies set created_at = now() - interval '30 hours' where lead_id = ld;
  f := public.lead_funnel('dr-test-b');
  if (f->>'replies_over_sla')::int <> 1 then raise exception 'F8 stale reply not counted: %', f; end if;
  perform public.set_venture_config('dr-test-b', 'reply_sla_hours', '48', 'owner:test');
  f := public.lead_funnel('dr-test-b');
  if (f->>'replies_over_sla')::int <> 0 or (f->>'reply_sla_hours')::int <> 48 then raise exception 'F9 SLA config ignored: %', f; end if;

  -- ---------- venture config: fail-closed defaults, owner-only ----------
  r := public.venture_config_get('dr-test-a');
  if (r->>'drafts_ready')::boolean or r->>'offer' is not null or (r->>'reply_sla_hours')::int <> 24 or not (r->>'reply_sla_is_default')::boolean then raise exception 'C1 defaults not fail-closed: %', r; end if;
  if not (public.venture_config_get('donna')->>'drafts_ready')::boolean then raise exception 'C2 donna legacy flow not exempt'; end if;
  begin perform public.set_venture_config('dr-test-a', 'offer', 'We fix your invoicing in a week', 'jarvis'); raise exception 'C3 non-owner set config';
  exception when raise_exception then if sqlerrm like 'C3%' then raise; end if; end;
  begin perform public.set_venture_config('dr-test-a', 'price', 'x', 'owner:test'); raise exception 'C4 unknown key accepted';
  exception when raise_exception then if sqlerrm like 'C4%' then raise; end if; end;
  begin perform public.set_venture_config('dr-test-a', 'reply_sla_hours', 'soon', 'owner:test'); raise exception 'C5 bad sla accepted';
  exception when raise_exception then if sqlerrm like 'C5%' then raise; end if; end;
  begin perform public.set_venture_config('dr-test-a', 'offer', 'api_key: sk-abcdefghijklmnop1234', 'owner:test'); raise exception 'C6 credential accepted';
  exception when raise_exception then if sqlerrm like 'C6%' then raise; end if; end;
  begin perform public.set_venture_config('dr-test-a', 'reply_sla_hours', '9999', 'owner:test'); raise exception 'C7 sla out of range accepted';
  exception when others then if sqlerrm like 'C7%' then raise; end if; end;
  perform public.set_venture_config('dr-test-a', 'offer', 'We fix your invoicing in a week', 'owner:test');
  if (public.venture_config_get('dr-test-a')->>'drafts_ready')::boolean then raise exception 'C8 ready with only an offer'; end if;
  r := public.set_venture_config('dr-test-a', 'call_to_action', 'Reply to book a 15 minute call', 'owner:test');
  if not (r->>'drafts_ready')::boolean then raise exception 'C9 not ready with offer and CTA: %', r; end if;
  r := public.set_venture_config('dr-test-a', 'offer', '', 'owner:test');
  if (r->>'drafts_ready')::boolean or r->>'offer' is not null then raise exception 'C10 clearing did not fail closed: %', r; end if;
  if public.venture_config_get('no-such-venture') is not null then raise exception 'C11 config for unknown venture'; end if;
end $$;


-- ---------- address normalisation (the SAME table is parsed by test_hq_venture_ops.py and run through hq_mail.normalize_addr) ----------
do $$
declare bad text;
begin
  select string_agg(coalesce(c.input, 'NULL'), ' | ') into bad from (values
    -- normalize cases begin
    ('bob@x.com', 'bob@x.com'),
    ('  Bob@X.COM ', 'bob@x.com'),
    ('bob+z@x.com', 'bob@x.com'),
    ('BOB+a+b@x.com', 'bob@x.com'),
    ('x+@y.com', 'x@y.com'),
    ('b.o.b@x.com', 'b.o.b@x.com'),
    ('Bob <g@x.com>', 'g@x.com'),
    ('Bob<g@x.com>', 'g@x.com'),
    ('"Bob" <G+news@X.com>', 'g@x.com'),
    ('a@b.com, c@d.com', null),
    ('a@b.com;c@d.com', null),
    ('a@b.com, <c@d.com>', null),
    ('"Doe, Bob" <d@x.com>', null),
    ('plain', null),
    ('@x.com', null),
    ('+tag@x.com', null),
    ('a@b@c.com', null),
    ('a b@x.com', null),
    ('<>', null),
    ('', null)
    -- normalize cases end
  ) as c(input, expected) where public.normalize_addr(c.input) is distinct from c.expected;
  if bad is not null then raise exception 'N1 normalize_addr mismatches: %', bad; end if;
  if public.normalize_addr(null) is not null then raise exception 'N2 null in, non-null out'; end if;
end $$;

do $$
declare va uuid; la uuid; lb uuid; lc uuid; ld uuid; ok boolean; d1 uuid; led0 int; n int;
begin
  va := public.create_venture('dr-test-c', 'Dr Test C', 'revenue', 'revenue', 0, 'deal reply test venture C', 'test');
  insert into public.leads (venture_id, name, email, status) values (va, 'Bob', 'bob@x.com', 'sent') returning id into la;
  insert into public.leads (venture_id, name, email, status) values (va, 'Bob2', 'bob+zz@x.com', 'new') returning id into lb;
  perform public.record_lead_reply(la, 'unsubscribe', 'stop', 'owner:test');
  if (select address from public.contact_suppressions where source_lead = la) <> 'bob@x.com' then raise exception 'A0 suppression address not normalised'; end if;
  if not (select do_not_contact from public.leads where id = lb) then raise exception 'A1 plus-address variant lead not flagged by the opt-out'; end if;
  insert into public.leads (venture_id, name, email, status) values (va, 'Bob3', 'bob+later@X.com', 'new') returning id into lc;
  if not (select do_not_contact from public.leads where id = lc) then raise exception 'A2 plus-address variant added later came back clean'; end if;
  insert into public.leads (venture_id, name, email, status) values (va, 'Bob4', 'Bob <bob@x.com>', 'new') returning id into ld;
  if not (select do_not_contact from public.leads where id = ld) then raise exception 'A2b decorated address came back clean'; end if;
  declare t text; begin
    foreach t in array array['bob+z@x.com', 'Bob<bob@x.com>', 'BOB@X.COM'] loop
      begin insert into public.outbox (venture_id, agent, channel, to_ref, body, status) values (va, null, 'email', t, 'hi', 'draft'); raise exception 'A3 draft to % inserted', t;
      exception when sqlstate 'P0001' then if sqlerrm like 'A3%' then raise; end if; end;
    end loop;
  end;
  -- a plus variant opting out later also covers the plain address (matching goes both ways through normalize_addr)
  insert into public.leads (venture_id, name, email, status) values (va, 'Amy', 'amy@x.com', 'sent') returning id into la;
  insert into public.leads (venture_id, name, email, status) values (va, 'Amy2', 'amy@x.com', 'new') returning id into lb;
  perform public.record_lead_reply(lb, 'unsubscribe', 'x', 'owner:test');
  if not (select do_not_contact from public.leads where id = la) then raise exception 'A4 sibling lead not flagged'; end if;
  -- multi-recipient strings are refused even when no address in them is suppressed
  declare t text; begin
    foreach t in array array['q@y.com;r@y.com', 'q@y.com, r@y.com', 'q@y.com,<r@y.com>'] loop
      begin insert into public.outbox (venture_id, agent, channel, to_ref, body, status) values (va, null, 'email', t, 'hi', 'draft'); raise exception 'B1 multi-recipient % accepted', t;
      exception when sqlstate 'P0001' then if sqlerrm like 'B1%' then raise; end if; end;
    end loop;
  end;
  insert into public.outbox (venture_id, agent, channel, to_ref, body, status) values (va, null, 'email', 'Fine Person <fine@y.com>', 'hi', 'draft');  -- a clean decorated address is allowed

  -- append-only suppression list: nobody can lift an opt-out
  begin delete from public.contact_suppressions; raise exception 'L1 suppression rows deleted';
  exception when sqlstate 'P0001' then if sqlerrm like 'L1%' then raise; end if; end;
  begin update public.contact_suppressions set address = 'other@x.com'; raise exception 'L2 suppression rows updated';
  exception when sqlstate 'P0001' then if sqlerrm like 'L2%' then raise; end if; end;
  begin truncate public.contact_suppressions; raise exception 'L3 suppression list truncated';
  exception when sqlstate 'P0001' then if sqlerrm like 'L3%' then raise; end if; end;
  begin insert into public.contact_suppressions (address, reason, recorded_by) values ('Not Normal@X.com', 'x', 'test'); raise exception 'L4 un-normalised address stored';
  exception when check_violation then null; end;
  declare r text; p text; begin
    foreach r in array array['service_role','anon','authenticated'] loop
      foreach p in array array['UPDATE','DELETE','TRUNCATE'] loop
        if has_table_privilege(r, 'public.contact_suppressions', p) then raise exception 'L5 % has % on the suppression list', r, p; end if;
      end loop;
    end loop;
    if not has_table_privilege('service_role', 'public.contact_suppressions', 'INSERT') then raise exception 'L6 service_role cannot add an opt-out'; end if;
  end;
  if not public.is_suppressed('bob@x.com') then raise exception 'L7 opt-out lost'; end if;

  -- money cap and one open deal per lead
  select count(*) into led0 from public.ledger;
  insert into public.leads (venture_id, name, email, status) values (va, 'Cap1', 'cap1@y.com', 'sent') returning id into la;
  insert into public.leads (venture_id, name, email, status) values (va, 'Cap2', 'cap2@y.com', 'sent') returning id into lb;
  begin perform public.create_deal(la, 10000001, 'owner:test'); raise exception 'M1 deal above the cap opened';
  exception when raise_exception then if sqlerrm like 'M1%' then raise; end if; if sqlerrm not like '%100,000%' then raise exception 'M1b wrong error %', sqlerrm; end if; end;
  d1 := public.create_deal(la, 10000000, 'owner:test');
  begin perform public.confirm_deal_won(d1, 10000001, 'received', 'owner:test'); raise exception 'M2 win above the cap confirmed';
  exception when raise_exception then if sqlerrm like 'M2%' then raise; end if; if sqlerrm not like '%100,000%' then raise exception 'M2b wrong error %', sqlerrm; end if; end;
  if (select count(*) from public.ledger) <> led0 then raise exception 'M3 refused confirm wrote the ledger'; end if;
  perform public.confirm_deal_won(d1, 10000000, 'expected', 'owner:test');
  if (select count(*) from public.ledger where amount_cents = 10000000) <> 1 then raise exception 'M4 amount at the cap not recorded'; end if;
  d1 := public.create_deal(lb, 100, 'owner:test');
  begin perform public.create_deal(lb, 200, 'owner:test'); raise exception 'O1 second open deal for a lead';
  exception when raise_exception then if sqlerrm like 'O1%' then raise; end if; if sqlerrm not like '%already has an open deal%' then raise exception 'O1b wrong error %', sqlerrm; end if; end;
  begin insert into public.deals (venture_id, lead_id, stage) values (va, lb, 'negotiating'); raise exception 'O2 raw duplicate open deal inserted';
  exception when unique_violation then null; end;
  perform public.set_deal_stage(d1, 'lost', 'owner:test');
  perform public.create_deal(lb, 300, 'owner:test');   -- once the first is closed a new deal is fine

  -- replies follow their lead when it is deleted; the suppression list does not
  insert into public.leads (venture_id, name, email, status) values (va, 'Del', 'del@y.com', 'sent') returning id into la;
  perform public.record_lead_reply(la, 'unsubscribe', 'bye', 'owner:test');
  delete from public.leads where id = la;
  select count(*) into n from public.lead_replies where lead_id = la;
  if n <> 0 then raise exception 'R-FK replies survived their lead'; end if;
  if not public.is_suppressed('del@y.com') then raise exception 'R-FK2 deleting the lead lifted the opt-out'; end if;
end $$;

-- privileges: only service_role may execute any new function; anon/authenticated/public may not
do $$
declare f text; r text;
begin
  foreach f in array array['public.is_suppressed(text)','public.mark_do_not_contact(uuid,text,text)','public.record_lead_reply(uuid,text,text,text)',
      'public.create_deal(uuid,integer,text,text)','public.set_deal_stage(uuid,text,text,text)','public.confirm_deal_won(uuid,integer,text,text,text)',
      'public.normalize_addr(text)','public.contact_suppressions_append_only()','public.venture_config_get(text)','public.set_venture_config(text,text,text,text)','public.lead_funnel(text)','public.venture_kpis(text)',
      'public.leads_suppression_guard()','public.leads_dnc_cascade()','public.outbox_dnc_guard()'] loop
    foreach r in array array['anon','authenticated'] loop
      if has_function_privilege(r, f, 'execute') then raise exception 'P1 % can execute %', r, f; end if;
    end loop;
    if not has_function_privilege('service_role', f, 'execute') then raise exception 'P2 service_role cannot execute %', f; end if;
  end loop;
end $$;
set local role anon;
do $$ begin
  begin perform public.mark_do_not_contact(gen_random_uuid(), 'x', 'owner:test'); raise exception 'P3 anon executed mark_do_not_contact';
  exception when insufficient_privilege then null; end;
  begin perform public.confirm_deal_won(gen_random_uuid(), 100, 'received', 'owner:test'); raise exception 'P4 anon executed confirm_deal_won';
  exception when insufficient_privilege then null; end;
end $$;
reset role;
set local role authenticated;
do $$ begin
  begin perform public.record_lead_reply(gen_random_uuid(), 'unsubscribe', 'x', 'owner:test'); raise exception 'P5 authenticated executed record_lead_reply';
  exception when insufficient_privilege then null; end;
  begin perform public.set_venture_config('donna', 'offer', 'long enough offer text', 'owner:test'); raise exception 'P6 authenticated executed set_venture_config';
  exception when insufficient_privilege then null; end;
end $$;
reset role;
select 'venture_deals_replies_sql_ok';
rollback;
