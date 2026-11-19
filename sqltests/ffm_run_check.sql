-- FF Marketing execution v1 (migrations/20261126_ffm_run_v1.sql). Everything in one transaction, rolled back. Run on a fresh apply (scripts/replica/run.sh does).
-- Proves at the SQL level: one owner approval (nothing runs before the tap, the message numbers come from the database); the approved budget is immutable and enforced
-- (daily sum, remaining cap, capped at the cap); the gate honours the kill switch and simulates in dry run; leads need consent fields and pass the guard;
-- only approved plan items can use the launch approval; opt-out stops everything; anon/authenticated get nothing; the bot cannot write the tables. Python end-to-end
-- coverage of the same objects: test_hq_ffm_run.DbTests (also run by scripts/replica/run.sh).
begin;
grant usage on schema public to anon, authenticated, service_role;
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
declare w uuid; c uuid; pk uuid; res text; j jsonb; l uuid; b uuid; s1 uuid; s2 uuid; a1 uuid; lead uuid; t date := (now() at time zone 'America/Toronto')::date; n int; msg record; nonce text;
  plan jsonb := '{"ads": [{"ref": "V1", "set": "A", "headline": "Renewal review", "body": "Book a free renewal review call.", "cta": "BOOK_NOW"},
                          {"ref": "V2", "set": "B", "headline": "Renewal help", "body": "Talk to a local team.", "cta": "LEARN_MORE"}],
                  "posts": [{"ref": "P1", "day": 1, "platform": "facebook", "text": "Renewal tip number one."}],
                  "touches": [{"touch": 1, "day": 0, "subject": "Your renewal review", "body": "Hi there, thanks for asking."},
                              {"touch": 2, "day": 1, "subject": "Your renewal review", "body": "Hi there, following up."}],
                  "landing": false, "vertical": "mortgage", "geo": "Ottawa"}';
begin
  update public.system_state set kill_switch = false, mode = 'dry_run' where id = 1;
  w := public.ffm_engine_create_workspace('run-check', 'Run Check Mortgages', 'mortgage', 'owner:telegram');
  c := public.ffm_add_campaign(w, 'Run check campaign', 'meta');
  pk := (public.ffm_engine_save_pack(w, 'mortgage', '{"schema": "ffm.pack.v1", "status": "draft", "dry_run": true}', c, 0, null, 'ffm-engine') ->> 'id')::uuid;

  -- R1 proposal: needs a monthly budget and a sender profile; $100 minimum cap; at most 30 days; screened; one owner message with the database's numbers
  if pg_temp.svc(format($q$select public.ffm_run_propose(%L, %L, 1000, 20000, %L, %L, '{meta}', '{facebook}', %L, 'owner:telegram')$q$, w, pk, t, t + 9, plan)) not like 'ERR:%monthly budget first%' then raise exception 'R1 no monthly budget accepted'; end if;
  update public.client_workspaces set monthly_budget_cents = 100000 where id = w;      -- (owner-only ffm_set_budget in production)
  if pg_temp.svc(format($q$select public.ffm_run_propose(%L, %L, 1000, 20000, %L, %L, '{meta}', '{facebook}', %L, 'owner:telegram')$q$, w, pk, t, t + 9, plan)) not like 'ERR:%no sender profile%' then raise exception 'R1 no sender accepted'; end if;
  if pg_temp.svc(format($q$select public.ffm_run_set_sender(%L, 'hello@runcheck.example', 'Sam Lee', 'Run Check Mortgages', '100 Main Street, Ottawa ON', 'jarvis')$q$, w)) not like 'ERR:%only the owner%' then raise exception 'R1 bot set a sender'; end if;
  if pg_temp.svc(format($q$select public.ffm_run_set_sender(%L, 'not-an-address', 'Sam Lee', 'Run Check Mortgages', '100 Main Street, Ottawa ON', 'owner:telegram')$q$, w)) not like 'ERR:%clean email%' then raise exception 'R1 bad sender address'; end if;
  perform public.ffm_run_set_sender(w, 'hello@runcheck.example', 'Sam Lee', 'Run Check Mortgages', '100 Main Street, Ottawa ON', 'owner:telegram');
  if pg_temp.svc(format($q$select public.ffm_run_propose(%L, %L, 5000, 1000, %L, %L, '{meta}', '{facebook}', %L, 'owner:telegram')$q$, w, pk, t, t + 9, plan)) not like 'ERR:%not above the total cap%' then raise exception 'R1 daily above cap accepted'; end if;
  if pg_temp.svc(format($q$select public.ffm_run_propose(%L, %L, 1000, 5000, %L, %L, '{meta}', '{facebook}', %L, 'owner:telegram')$q$, w, pk, t, t + 9, plan)) not like 'ERR:%at least $100.00%' then raise exception 'R1 cap below $100 accepted'; end if;
  if pg_temp.svc(format($q$select public.ffm_run_propose(%L, %L, 1000, 20000, %L, %L, '{meta}', '{facebook}', %L, 'owner:telegram')$q$, w, pk, t, t + 30, plan)) not like 'ERR:%at most 30 days%' then raise exception 'R1 31 days accepted'; end if;
  if pg_temp.svc(format($q$select public.ffm_run_propose(%L, %L, 1000, 200000, %L, %L, '{meta}', '{facebook}', %L, 'owner:telegram')$q$, w, pk, t, t + 9, plan)) not like 'ERR:%above the monthly budget%' then raise exception 'R1 above monthly budget accepted'; end if;
  if pg_temp.svc(format($q$select public.ffm_run_propose(%L, %L, 1000, 20000, %L, %L, '{meta}', '{facebook}', %L, 'owner:telegram')$q$, w, pk, t - 3, t + 9, plan)) not like 'ERR:%dates must start today%' then raise exception 'R1 past start accepted'; end if;
  if pg_temp.svc(format($q$select public.ffm_run_propose(%L, %L, 1000, 20000, %L, %L, '{meta}', '{facebook}', %L, 'owner:telegram')$q$, w, pk, t, t + 9,
       jsonb_set(plan, '{posts,0,text}', '"Send us your bank statement and credit report"'))) not like 'ERR:%Sensitive data refused%' then raise exception 'R1 sensitive plan accepted'; end if;
  if pg_temp.svc(format($q$select public.ffm_run_propose(%L, %L, 1000, 20000, %L, %L, '{meta}', '{facebook}', %L, 'owner:telegram')$q$, w, pk, t, t + 9, plan || '{"extra": "x"}')) not like 'ERR:%unknown plan shape%' then raise exception 'R1 free-form plan accepted'; end if;
  res := pg_temp.svc(format($q$select public.ffm_run_propose(%L, %L, 1000, 20000, %L, %L, '{meta}', '{facebook}', %L, 'owner:telegram')::text$q$, w, pk, t, t + 9, plan));
  if res not like 'OK:%' then raise exception 'R1 propose refused: %', res; end if;
  j := substr(res, 4)::jsonb; l := (j ->> 'launch_id')::uuid; b := (j ->> 'budget_id')::uuid;
  select * into msg from public.owner_messages where id = (j ->> 'message_id')::uuid;
  if not msg.needs_decision or msg.ref_table <> 'ffm_run_budgets' or msg.ref_id <> b or msg.kind <> 'proposal' then raise exception 'R1 owner message wrong'; end if;
  if msg.body not like 'Sir, launch approval for Run Check Mortgages%' or msg.body not like '%Daily budget: $10.00 on average (Meta may spend up to about 75%% more%'
     or msg.body not like '%Total cap: $200.00 = the hard stop%' or msg.body not like '%2 ads in 2 ad sets%' or msg.body not like '%/ffm plan ' || left(l::text, 8) || '%'
     or msg.body not like '%runs as DRY RUN%launch again%' then raise exception 'R1 message body: %', msg.body; end if;
  if public.ffm_run_budget(l) is not null then raise exception 'R1 budget approved before the tap'; end if;
  if (pg_temp.svc(format($q$select public.ffm_run_gate(%L, 'launch', null)::text$q$, l))) not like '%launch is proposed%' then raise exception 'R1 gate open before approval'; end if;

  -- R2 B1: the decision column is not an approval; anon / authenticated cannot touch owner_messages; only ffm_run_owner_decide with the single-use nonce approves
  update public.owner_messages set decision = 'approved', decided_at = now() where id = msg.id;                       -- a forged decision (even by the service key)
  if public.ffm_run_budget(l) is not null or (select status from public.ffm_run_launches where id = l) <> 'proposed' then raise exception 'R2 bare decision column approved a launch'; end if;
  foreach res in array array['anon', 'authenticated'] loop
    if pg_temp.as_role(res, format($q$update public.owner_messages set decision = 'approved' where id = %L$q$, msg.id)) not like 'ERR:%permission denied%' then raise exception 'R2 % writes owner_messages', res; end if;
    if pg_temp.as_role(res, $q$select count(*)::text from public.owner_messages$q$) not like 'ERR:%permission denied%' then raise exception 'R2 % reads owner_messages', res; end if;
    if pg_temp.as_role(res, format($q$select public.ffm_run_owner_decide(%L, 'x', true, 'owner:telegram')$q$, msg.id)) not like 'ERR:%permission denied%' then raise exception 'R2 % calls owner_decide', res; end if;
    if pg_temp.as_role(res, $q$select count(*)::text from public.ffm_run_budgets$q$) not like 'ERR:%permission denied%' then raise exception 'R2 % reads nonces', res; end if;
  end loop;
  begin
    update public.ffm_run_budgets set status = 'approved' where id = b;
    raise exception 'R2 direct approval accepted';
  exception when insufficient_privilege then null;
  end;
  select approval_nonce into nonce from public.ffm_run_budgets where id = b;
  if pg_temp.svc(format($q$select public.ffm_run_owner_decide(%L, %L, true, 'jarvis')$q$, msg.id, nonce)) not like 'ERR:%only the owner%' then raise exception 'R2 non-owner decided'; end if;
  if pg_temp.svc(format($q$select public.ffm_run_owner_decide(%L, %L, true, 'owner:telegram')$q$, msg.id, repeat('0', 64))) not like 'ERR:%wrong nonce%' then raise exception 'R2 wrong nonce accepted'; end if;
  if pg_temp.svc(format($q$select public.ffm_run_owner_decide(%L, %L, true, 'owner:telegram')$q$, (select id from public.owner_messages where ref_table is distinct from 'ffm_run_budgets' limit 1), nonce)) not like 'ERR:%not a launch approval%' then raise exception 'R2 other message accepted'; end if;
  j := substr(pg_temp.svc(format($q$select public.ffm_run_owner_decide(%L, %L, true, 'owner:telegram')::text$q$, msg.id, nonce)), 4)::jsonb;
  if j ->> 'status' <> 'approved' or (select status from public.ffm_run_launches where id = l) <> 'approved' or not (select dry_run from public.ffm_run_launches where id = l) then raise exception 'R2 approval: %', j; end if;
  if (substr(pg_temp.svc(format($q$select public.ffm_run_owner_decide(%L, %L, true, 'owner:telegram')::text$q$, msg.id, nonce)), 4)::jsonb ->> 'reason') <> 'already decided' then raise exception 'R2 nonce reused'; end if;
  if (public.ffm_run_budget(l) ->> 'daily_cents')::int <> 1000 then raise exception 'R2 budget'; end if;
  begin
    update public.ffm_run_budgets set daily_cents = 99999 where id = b;
    raise exception 'R2 approved amount changed';
  exception when insufficient_privilege then null;
  end;
  if pg_temp.svc(format($q$select public.ffm_run_propose(%L, %L, 1000, 20000, %L, %L, '{meta}', '{facebook}', %L, 'owner:telegram')$q$, w, pk, t, t + 9, plan)) not like 'ERR:%already has a launch%' then raise exception 'R2 second launch accepted'; end if;

  -- R3 gate: a dry-run launch never goes live (even after the mode switch); kill switch stops everything
  j := substr(pg_temp.svc(format($q$select public.ffm_run_gate(%L, 'launch', 'meta-ads')::text$q$, l)), 4)::jsonb;
  if not (j ->> 'ok')::boolean or (j ->> 'live')::boolean or j ->> 'why_simulated' not like 'dry-run launch%' then raise exception 'R3 dry-run gate: %', j; end if;
  update public.system_state set mode = 'auto_in_caps' where id = 1;
  j := substr(pg_temp.svc(format($q$select public.ffm_run_gate(%L, 'launch', 'meta-ads')::text$q$, l)), 4)::jsonb;
  if (j ->> 'live')::boolean or j ->> 'why_simulated' not like 'dry-run launch%' then raise exception 'R3 dry-run launch went live: %', j; end if;
  update public.ffm_run_launches set dry_run = false where id = l;                                                       -- (as if approved in a live mode)
  j := substr(pg_temp.svc(format($q$select public.ffm_run_gate(%L, 'launch', 'meta-ads')::text$q$, l)), 4)::jsonb;
  if (j ->> 'live')::boolean or j ->> 'why_simulated' <> 'connector meta-ads is off' then raise exception 'R3 disabled connector not simulated: %', j; end if;
  update public.system_state set kill_switch = true where id = 1;
  j := substr(pg_temp.svc(format($q$select public.ffm_run_gate(%L, 'report', null)::text$q$, l)), 4)::jsonb;
  if (j ->> 'ok')::boolean or not (j ->> 'kill')::boolean then raise exception 'R3 kill switch ignored: %', j; end if;
  update public.system_state set kill_switch = false, mode = 'dry_run' where id = 1;
  update public.ffm_run_launches set dry_run = true where id = l;

  -- R4 budget rule: ad-set budgets never above the approved daily budget or the remaining cap; capped at the cap; a new total must be above spend
  res := pg_temp.svc(format($q$select public.ffm_run_put_object(%L, 'campaign', 'campaign', null, 'sim:c', 'paused', null, true)::text$q$, l));
  if res not like 'OK:%' then raise exception 'R4 campaign: %', res; end if;
  c := substr(res, 4)::uuid;
  s1 := substr(pg_temp.svc(format($q$select public.ffm_run_put_object(%L, 'ad_set', 'A', %L, 'sim:a', 'paused', 500, true)::text$q$, l, c)), 4)::uuid;
  if pg_temp.svc(format($q$select public.ffm_run_put_object(%L, 'ad_set', 'B', %L, 'sim:b', 'paused', 600, true)$q$, l, c)) not like 'ERR:%exceed the approved daily budget%' then raise exception 'R4 daily sum exceeded'; end if;
  s2 := substr(pg_temp.svc(format($q$select public.ffm_run_put_object(%L, 'ad_set', 'B', %L, 'sim:b', 'paused', 500, true)::text$q$, l, c)), 4)::uuid;
  if pg_temp.svc(format($q$select public.ffm_run_set_object(%L, 'active', 501)$q$, s1)) not like 'ERR:%exceed the approved daily budget%' then raise exception 'R4 raise above daily accepted'; end if;
  if pg_temp.svc(format($q$select public.ffm_run_set_object(%L, 'paused', 50)$q$, s1)) not like 'ERR:%at least $1.00%' then raise exception 'R4 tiny budget accepted'; end if;
  a1 := substr(pg_temp.svc(format($q$select public.ffm_run_put_object(%L, 'ad', 'V1', %L, 'sim:v1', 'active', null, true)::text$q$, l, s1)), 4)::uuid;
  if (select status from public.ffm_run_launches where id = l) <> 'running' then raise exception 'R4 not running after switch-on'; end if;
  j := substr(pg_temp.svc(format($q$select public.ffm_run_put_metrics(%L, %L, 19600, 10, 2, 0, true)::text$q$, a1, t)), 4)::jsonb;
  if (j ->> 'capped')::boolean then raise exception 'R4 capped too early'; end if;
  if pg_temp.svc(format($q$select public.ffm_run_set_object(%L, 'active', null)$q$, s1)) not like 'ERR:%left of the approved total cap%' then raise exception 'R4 remaining cap not enforced'; end if;
  j := substr(pg_temp.svc(format($q$select public.ffm_run_put_metrics(%L, %L, 20000, 10, 2, 0, true)::text$q$, a1, t)), 4)::jsonb;
  if not (j ->> 'capped')::boolean or (select status from public.ffm_run_launches where id = l) <> 'capped' then raise exception 'R4 not capped at the cap: %', j; end if;
  if pg_temp.svc(format($q$select public.ffm_run_set_object(%L, 'active', null)$q$, s2)) not like 'ERR:%launch is capped%' then raise exception 'R4 switched on while capped'; end if;
  if pg_temp.svc(format($q$select public.ffm_run_set_object(%L, 'paused', null)$q$, a1)) not like 'OK:%' then raise exception 'R4 pausing refused'; end if;
  if pg_temp.svc(format($q$select public.ffm_run_request_budget(%L, 1000, 20000, 'jarvis')$q$, l)) not like 'ERR:%above what is already spent%' then raise exception 'R4 cap at spend accepted'; end if;
  if (pg_temp.svc(format($q$select public.ffm_run_submit_hand(%L, 'P1', 'meta-facebook', 'post', '{"text": "Renewal tip number one."}')::text$q$, l))) not like '%launch not running (or capped)%' then raise exception 'R4 posting while capped'; end if;
  -- more money = a new row and a new tap through the nonce path
  res := pg_temp.svc(format($q$select public.ffm_run_request_budget(%L, 1000, 40000, 'jarvis')::text$q$, l));
  if (public.ffm_run_budget(l) ->> 'total_cap_cents')::int <> 20000 then raise exception 'R4 raise applied without a tap'; end if;
  b := (substr(res, 4)::jsonb ->> 'budget_id')::uuid;
  select owner_message_id, approval_nonce into msg.id, nonce from public.ffm_run_budgets where id = b;
  perform public.ffm_run_owner_decide(msg.id, nonce, true, 'owner:telegram');
  if (public.ffm_run_budget(l) ->> 'total_cap_cents')::int <> 40000 or (select status from public.ffm_run_launches where id = l) <> 'running' then raise exception 'R4 approved raise not applied'; end if;
  if (select count(*) from public.ffm_run_budgets where launch_id = l and status = 'approved') <> 1 then raise exception 'R4 two approved budgets'; end if;

  -- R5 only approved plan items can use the launch approval
  if (pg_temp.svc(format($q$select public.ffm_run_submit_hand(%L, 'P1', 'meta-facebook', 'post', '{"text": "Buy now!"}')::text$q$, l))) not like '%differs from the approved plan%' then raise exception 'R5 other text accepted'; end if;
  if (pg_temp.svc(format($q$select public.ffm_run_submit_hand(%L, 'P9', 'meta-facebook', 'post', '{"text": "x"}')::text$q$, l))) not like '%not an item of the approved plan%' then raise exception 'R5 unknown item accepted'; end if;
  if (pg_temp.svc(format($q$select public.ffm_run_submit_hand(%L, 'P1', 'x-twitter', 'post', '{"text": "Renewal tip number one."}')::text$q$, l))) not like '%does not match the approved platform%' then raise exception 'R5 other platform accepted'; end if;
  if (pg_temp.svc(format($q$select public.ffm_run_submit_hand(%L, 'landing', 'netlify', 'deploy', '{"html": "<p>x</p>"}')::text$q$, l))) not like '%no landing page%' then raise exception 'R5 unapproved page accepted'; end if;

  -- R6 leads: consent fields required, the guard refuses sensitive data, no contact without verified consent, nothing in the legacy outbox, opt-out stops and suppresses
  if pg_temp.svc(format($q$select public.ffm_run_intake_lead(%L, 'landing', 'nf-r6a', 'Alex', 'alex@example.com', null, '{"given": false}', 'ffm-run')$q$, l)) not like 'ERR:%consent is required%' then raise exception 'R6 no-consent lead accepted'; end if;
  if pg_temp.svc(format($q$select public.ffm_run_intake_lead(%L, 'landing', 'nf-r6b', 'my SIN is 046 454 286', 'alex@example.com', null, %L, 'ffm-run')$q$, l,
       jsonb_build_object('given', true, 'wording_version', 'v1', 'captured_at', now(), 'evidence_ref', 'nf-r6b'))) not like 'ERR:%Sensitive data refused%' then raise exception 'R6 sensitive lead accepted'; end if;
  res := pg_temp.svc(format($q$select public.ffm_run_intake_lead(%L, 'landing', 'nf-r6c', 'Alex', 'alex.r6@example.com', null, %L, 'ffm-run')::text$q$, l,
       jsonb_build_object('given', true, 'wording_version', 'v1', 'captured_at', now(), 'evidence_ref', 'nf-r6c')));
  if res not like 'OK:%' then raise exception 'R6 lead refused: %', res; end if;
  lead := (substr(res, 4)::jsonb ->> 'lead_id')::uuid;
  if (select basis from public.ffm_consent_log where lead_id = lead) <> 'unverified' then raise exception 'R6 unsealed consent counted as express'; end if;
  if pg_temp.svc(format($q$select public.ffm_run_touch(%L, 1, 'Your renewal review', 'Something else', false)::text$q$, lead)) not like '%differs from the approved plan%' then raise exception 'R6 other text accepted'; end if;
  j := substr(pg_temp.svc(format($q$select public.ffm_run_touch(%L, 1, 'Your renewal review', 'Hi there, thanks for asking.', true)::text$q$, lead)), 4)::jsonb;
  if j ->> 'status' <> 'skipped' or (select status from public.ffm_run_leads where lead_id = lead) <> 'needs_consent' then raise exception 'R6 contacted without verified consent: %', j; end if;
  if exists (select 1 from public.outbox where idempotency_key like 'ffm:%') or exists (select 1 from public.ffm_run_emails where lead_id = lead) then raise exception 'R6 an email was queued'; end if;
  if pg_temp.svc(format($q$select public.ffm_run_lead_event(%L, 'opted_out', 'owner:telegram')::text$q$, lead)) not like 'OK:%' then raise exception 'R6 opt-out refused'; end if;
  if not exists (select 1 from public.ffm_consent_log where lead_id = lead and basis = 'withdrawn') or not public.is_suppressed('alex.r6@example.com') then raise exception 'R6 opt-out did not withdraw / suppress'; end if;
  if (select stage from public.ws_leads where id = lead) <> 'lost' then raise exception 'R6 stage'; end if;

  -- R6b B5: a queued email carries THIS client's footer; the claim re-checks everything at send time and refuses in dry run / for an opted-out lead
  insert into public.ffm_run_emails (lead_id, launch_id, touch, subject, body) values (lead, l, 2, 'x', 'Hi' || public.ffm_run_footer(w));
  if (select body from public.ffm_run_emails where lead_id = lead) not like '%100 Main Street, Ottawa ON%Unsubscribe: mailto:hello@runcheck.example?subject=unsubscribe%' then raise exception 'R6b footer'; end if;
  if (select body from public.ffm_run_emails where lead_id = lead) like '%Donna%' then raise exception 'R6b Donna identity on a client email'; end if;
  j := substr(pg_temp.svc(format($q$select public.ffm_run_claim_email(%L)::text$q$, (select id from public.ffm_run_emails where lead_id = lead))), 4)::jsonb;
  if (j ->> 'ok')::boolean or j ->> 'reason' not like 'not live%' then raise exception 'R6b claimed in dry run: %', j; end if;
  update public.system_state set mode = 'auto_in_caps' where id = 1; update public.ffm_run_launches set dry_run = false where id = l;
  j := substr(pg_temp.svc(format($q$select public.ffm_run_claim_email(%L)::text$q$, (select id from public.ffm_run_emails where lead_id = lead))), 4)::jsonb;
  if (j ->> 'ok')::boolean or j ->> 'reason' <> 'lead is opted_out' or (select status from public.ffm_run_emails where lead_id = lead) <> 'withdrawn' then raise exception 'R6b opted-out lead claimed: %', j; end if;
  update public.system_state set mode = 'dry_run' where id = 1; update public.ffm_run_launches set dry_run = true where id = l;
  if pg_temp.as_role('anon', $q$select count(*)::text from public.ffm_run_emails$q$) not like 'ERR:%permission denied%' then raise exception 'R6b anon reads emails'; end if;

  -- R7 ending, report, receipts append-only
  if pg_temp.svc(format($q$select public.ffm_run_stop(%L, 'jarvis')$q$, l)) not like 'ERR:%only the owner%' then raise exception 'R7 Jarvis ended a launch early'; end if;
  perform public.ffm_run_receipt(l, 'launch', 'ads', true, true, 'sim:c', 'DRY RUN: created');
  if public.ffm_run_receipt(l, 'launch', 'ads', true, true, 'sim:c', 'again') then raise exception 'R7 once-only receipt repeated'; end if;
  begin
    update public.ffm_run_receipts set ok = false where launch_id = l;
    raise exception 'R7 receipts editable';
  exception when others then if sqlerrm like 'R7%' then raise; end if;
  end;
  if public.ffm_run_receipt(l, 'post', 'P1', true, true, null, 'customer card 4111 1111 1111 1111') is not true
     or (select detail from public.ffm_run_receipts where launch_id = l and step = 'post') <> '[screened]' then raise exception 'R7 receipt detail not screened'; end if;
  j := public.ffm_run_report(l, t - 6, t);
  if (j ->> 'spend_cents')::int <> 20000 or (j ->> 'leads')::int <> 1 or not (j ->> 'simulated')::boolean or j -> 'best_ads' -> 0 ->> 'headline' <> 'Renewal review' then raise exception 'R7 report: %', j; end if;
  res := pg_temp.svc(format($q$select public.ffm_run_stop(%L, 'owner:telegram')::text$q$, l));
  if res not like 'OK:%' or (select status from public.ffm_run_launches where id = l) <> 'done' then raise exception 'R7 owner stop: %', res; end if;

  -- R8 the bot cannot write the tables; anon / authenticated get nothing; the new connector is off and actionless
  if pg_temp.svc(format($q$insert into public.ffm_run_budgets (launch_id, seq, daily_cents, total_cap_cents, status, requested_by) values (%L, 9, 100, 100, 'approved', 'x')$q$, l)) not like 'ERR:%permission denied%' then raise exception 'R8 direct budget insert'; end if;
  if pg_temp.svc(format($q$update public.ffm_run_launches set status = 'running' where id = %L$q$, l)) not like 'ERR:%permission denied%' then raise exception 'R8 direct launch update'; end if;
  foreach res in array array['anon', 'authenticated'] loop
    if pg_temp.as_role(res, $q$select count(*)::text from public.ffm_run_launches$q$) not like 'ERR:%permission denied%' then raise exception 'R8 % reads launches', res; end if;
    if pg_temp.as_role(res, format($q$select public.ffm_run_gate(%L, 'launch', null)$q$, l)) not like 'ERR:%permission denied%' then raise exception 'R8 % calls the gate', res; end if;
    if pg_temp.as_role(res, format($q$select public.ffm_run_claim_email(%L)$q$, l)) not like 'ERR:%permission denied%' then raise exception 'R8 % claims emails', res; end if;
  end loop;
  if exists (select 1 from public.hand_connectors where slug = 'meta-ads' and (enabled or actions <> '{}')) then raise exception 'R8 meta-ads connector enabled or has actions'; end if;
  if public.backup_export_policy() -> 'unclassified' <> '[]'::jsonb then raise exception 'R8 unclassified: %', public.backup_export_policy() -> 'unclassified'; end if;
  if public.backup_export_policy() -> 'exported' ?| array['ffm_run_launches', 'ffm_run_leads', 'ffm_run_receipts', 'ffm_run_emails'] then raise exception 'R8 run tables exported'; end if;
  raise notice 'ffm_run_check: all passed';
end $$;
rollback;
