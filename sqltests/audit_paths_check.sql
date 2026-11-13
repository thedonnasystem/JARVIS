-- AUDIT_PATHS adversarial checks. Run against a SCRATCH replica database only (scripts/replica/run.sh runs it after the migrations).
-- ONE transaction, rolled back, any failed assertion raises 'AUDIT FAIL <id>: ...'. Proves, for the paths in AUDIT_PATHS.md:
--   B  opt-out (CASL) suppression cannot be dodged by address form (case, +tag, <>, trailing dots, quotes, comments, NBSP, zero-width,
--      fullwidth, lists), by another venture, by a direct outbox INSERT, a direct status UPDATE, a retarget or a channel flip
--   C  outbox approval flow, kill switch, dry-run, send policy and daily caps on a direct UPDATE of outbox.status
--   D  authorize_action: default-deny, prohibited, kill switch, dry-run, red/approve-first, one-use approvals, limits, owner-only policy edits
--   E  anon / authenticated database roles: no function, no RLS table, no app_* function is usable by a stranger
--   F  spend gateway (reserve_llm_budget): kill switch, paused/unknown agent, agent and company caps, mission budget, focus, hard stop
--   G  money: reserve_spend / payments cannot exceed limits, owner-only decisions, one payment settles once
--   H  deal pipeline (one open deal per lead, money cap, confirm_deal_won idempotent, revenue only from confirmation) and mission lifecycle
-- The replica lacks the live trigger outbox_rules (enforce_outbox_rules is created by the permissions migration, the trigger by
-- ops/migration_history/20261102020851); the first block creates it inside the transaction so the LIVE state is what is tested.
begin;
-- live Supabase grants USAGE on schema public to the API roles; a freshly created replica schema does not
grant usage on schema public to anon, authenticated, service_role;

create or replace function pg_temp.refused(p_sql text) returns text language plpgsql as $f$
begin execute p_sql; return null; exception when others then return sqlerrm; end $f$;

-- expect(id, sql, like): the statement must fail, and (when given) the message must match the ILIKE pattern
create or replace function pg_temp.expect(p_id text, p_sql text, p_like text default null) returns void language plpgsql as $f$
declare m text;
begin
  m := pg_temp.refused(p_sql);
  if m is null then raise exception 'AUDIT FAIL %: succeeded but must be refused: %', p_id, left(p_sql, 220); end if;
  if p_like is not null and m not ilike p_like then raise exception 'AUDIT FAIL %: refused for the wrong reason [%]: %', p_id, m, left(p_sql, 160); end if;
end $f$;

create or replace function pg_temp.ok(p_id text, p_sql text) returns void language plpgsql as $f$
declare m text;
begin
  m := pg_temp.refused(p_sql);
  if m is not null then raise exception 'AUDIT FAIL %: must succeed but was refused [%]: %', p_id, m, left(p_sql, 160); end if;
end $f$;

do $$ begin
  if not exists (select 1 from pg_trigger where tgname = 'outbox_rules' and tgrelid = 'public.outbox'::regclass) then
    create trigger outbox_rules before insert or update on public.outbox for each row execute function public.enforce_outbox_rules();
  end if;
  -- a neutral, predictable world for the whole file
  update public.system_state set kill_switch = false, mode = 'auto_in_caps', pause_reason = null, focus_mission = null where id = 1;
  update public.capital_policy set operating_fund_cents = 100000000, updated_by = 'owner:audit';
end $$;

-- =============================================================== B. suppression
do $$
declare va uuid; vb uuid; la uuid; lb uuid; f text; r jsonb; o uuid; msg text;
        same_mailbox text[] := array['VICTIM@EXAMPLE.COM', '  victim@example.com  ', 'victim+promo@example.com', 'Victim <victim@example.com>',
                                     '<victim@example.com>', 'victim@example.com.', 'victim@example.com...', '"Victim" <Victim+X@Example.Com.>'];
        unclean text[] := array['"victim"@example.com', 'victim(c)@example.com', E'victim@example.com\t', E'victim@example.com\n', E'\tvictim@example.com',
                                E'victim@example.com ', E'victim@example.com​', U&'\FF56ictim@example.com', U&'victim@example.com\2024',
                                'victim@example.com, other@x.com', 'victim@example.com;other@x.com', '<victim@example.com> <other@x.com>',
                                'victim@exa mple.com', 'mailto:victim@example.com', 'victim@[192.0.2.1]', 'victim@example.com>', '<victim@example.com',
                                'victim@@example.com', 'a@b.com <victim@example.com> trailing', 'not-an-email', ''];
begin
  insert into public.ventures (slug, name, kind) values ('audit-a', 'Audit A', 'revenue') returning id into va;
  insert into public.ventures (slug, name, kind) values ('audit-b', 'Audit B', 'revenue') returning id into vb;
  insert into public.leads (venture_id, name, email) values (va, 'A victim', 'Victim@Example.com') returning id into la;
  insert into public.leads (venture_id, name, email) values (vb, 'B victim', 'victim+b@example.com.') returning id into lb;   -- other venture, other spelling

  -- open drafts at every stage, in both ventures, under different spellings, BEFORE the opt-out
  insert into public.outbox (id, agent, channel, to_ref, body, venture_id) values
    ('00000000-0000-0000-0000-00000000b001', 'donna-ops', 'email', 'VICTIM+one@example.com', 'x unsubscribe', va),
    ('00000000-0000-0000-0000-00000000b002', 'donna-ops', 'email', 'Victim <victim@example.com.>', 'x unsubscribe', vb),
    ('00000000-0000-0000-0000-00000000b003', 'donna-ops', 'email', 'victim@example.com', 'x unsubscribe', vb),
    ('00000000-0000-0000-0000-00000000b004', 'donna-ops', 'email', 'bystander@example.com', 'x unsubscribe', va),
    ('00000000-0000-0000-0000-00000000b005', 'donna-ops', 'email', 'bystander2@example.com', 'x unsubscribe', va);
  update public.outbox set status = 'qa_passed', qa_agent = 'ceo' where id::text like '00000000-0000-0000-0000-00000000b00%' and id <> '00000000-0000-0000-0000-00000000b001';
  update public.outbox set status = 'approved' where id in ('00000000-0000-0000-0000-00000000b003', '00000000-0000-0000-0000-00000000b004', '00000000-0000-0000-0000-00000000b005');

  r := public.mark_do_not_contact(la, 'unsubscribe reply', 'owner:test');

  if (select count(*) from public.outbox where id in ('00000000-0000-0000-0000-00000000b001', '00000000-0000-0000-0000-00000000b002', '00000000-0000-0000-0000-00000000b003') and status = 'rejected') <> 3 then
    raise exception 'AUDIT FAIL B1: open drafts to spelling variants / other ventures were not rejected by the opt-out';
  end if;
  if (select count(*) from public.outbox where id in ('00000000-0000-0000-0000-00000000b004', '00000000-0000-0000-0000-00000000b005') and status = 'approved') <> 2 then
    raise exception 'AUDIT FAIL B2: the opt-out touched an unrelated address';
  end if;
  if not (select do_not_contact from public.leads where id = lb) then raise exception 'AUDIT FAIL B3: the other venture''s lead (same mailbox, other spelling) was not flagged'; end if;

  -- every spelling of the same mailbox is refused as a direct outbox INSERT and as a new lead (the DB is the last line of defence)
  foreach f in array same_mailbox loop
    perform pg_temp.expect('B4 insert ' || quote_literal(f),
      format('insert into public.outbox (agent, channel, to_ref, body, venture_id) values (''donna-ops'', ''email'', %L, ''x unsubscribe'', %L)', f, va), '%do-not-contact%');
    perform pg_temp.expect('B4b qa-passed row ' || quote_literal(f), format($q$select public.is_suppressed(%L)::int / 0 where public.is_suppressed(%L)$q$, f, f));  -- is_suppressed is true for it
    insert into public.leads (venture_id, name, email) values (vb, 'late ' || f, f) returning id into o;
    if not (select do_not_contact from public.leads where id = o) then raise exception 'AUDIT FAIL B5: lead re-added clean under the spelling %', quote_literal(f); end if;
  end loop;

  -- anything that is not ONE clean address cannot become a live email at all (it cannot be checked, so it cannot be sent)
  foreach f in array unclean loop
    perform pg_temp.expect('B6 unclean ' || quote_literal(f),
      format('insert into public.outbox (agent, channel, to_ref, body, venture_id) values (''donna-ops'', ''email'', %L, ''x unsubscribe'', %L)', f, va), '%');
  end loop;
  -- ... and the same text is not an address for the suppression list either (NULL key, never a surprise match)
  if public.normalize_addr(E'victim@example.com ') is not null or public.normalize_addr('"victim"@example.com') is not null then
    raise exception 'AUDIT FAIL B7: normalize_addr kept a lookalike or quoted form';
  end if;

  -- direct status flips on the rejected rows cannot resurrect them
  foreach o in array array['00000000-0000-0000-0000-00000000b001', '00000000-0000-0000-0000-00000000b002', '00000000-0000-0000-0000-00000000b003']::uuid[] loop
    perform pg_temp.expect('B8 rejected -> approved', format('update public.outbox set status = ''approved'' where id = %L', o));
    perform pg_temp.expect('B8 rejected -> qa_passed', format('update public.outbox set status = ''qa_passed'', qa_agent = ''ceo'' where id = %L', o));
    perform pg_temp.expect('B8 rejected -> sent', format('update public.outbox set status = ''sent'' where id = %L', o));
    perform pg_temp.expect('B8 rejected -> draft', format('update public.outbox set status = ''draft'' where id = %L', o), '%do-not-contact%');
  end loop;

  -- retarget a LIVE approved row to the opted-out mailbox (status unchanged): refused
  perform pg_temp.expect('B9 retarget approved row', 'update public.outbox set to_ref = ''Victim+z@example.com.'' where id = ''00000000-0000-0000-0000-00000000b004''', '%do-not-contact%');
  perform pg_temp.expect('B9b retarget to a list', 'update public.outbox set to_ref = ''bystander@example.com,victim@example.com'' where id = ''00000000-0000-0000-0000-00000000b004''');
  perform pg_temp.expect('B9c retarget to junk', 'update public.outbox set to_ref = ''x'' where id = ''00000000-0000-0000-0000-00000000b004''', '%not one clean%');
  -- the channel flip trick: leave email, retarget, come back
  perform pg_temp.ok('B10a channel -> text', 'update public.outbox set channel = ''text'' where id = ''00000000-0000-0000-0000-00000000b005''');
  perform pg_temp.ok('B10b retarget on text', 'update public.outbox set to_ref = ''victim@example.com'' where id = ''00000000-0000-0000-0000-00000000b005''');
  perform pg_temp.expect('B10c channel back to email', 'update public.outbox set channel = ''email'' where id = ''00000000-0000-0000-0000-00000000b005''', '%do-not-contact%');
  -- a lead flagged do-not-contact blocks every draft that points at it, whatever the address says
  perform pg_temp.expect('B11 draft for a do-not-contact lead', format('insert into public.outbox (agent, channel, to_ref, body, lead_id) values (''donna-ops'', ''email'', ''fresh@example.com'', ''x unsubscribe'', %L)', la), '%do-not-contact%');
  -- the raw flag cascades and cannot be cleared
  update public.leads set do_not_contact = false, status = 'new' where id in (la, lb);   -- accepted, but silently re-flagged by leads_suppression_guard
  if exists (select 1 from public.leads where id in (la, lb) and (not do_not_contact or status <> 'do_not_contact')) then
    raise exception 'AUDIT FAIL B12: a suppressed address was un-flagged by a raw update';
  end if;
  -- B14: the opt-out must work when the lead has OPEN drafts on the very same address string. With the live outbox_rules trigger in place the
  -- draft-rejecting UPDATE used to be refused ("Recipient is on the do-not-contact list") because the lead was flagged first, which rolled the whole
  -- opt-out back: an unsubscribe could not be recorded while a draft existed.
  declare lx uuid; ox uuid := '00000000-0000-0000-0000-00000000b0a1'; oy uuid := '00000000-0000-0000-0000-00000000b0a2';
  begin
    insert into public.leads (venture_id, name, email) values (va, 'Has drafts', 'has.drafts@example.com') returning id into lx;
    insert into public.outbox (id, agent, channel, to_ref, body, venture_id, lead_id) values (ox, 'donna-ops', 'email', 'has.drafts@example.com', 'x unsubscribe', va, lx);
    update public.outbox set status = 'qa_passed', qa_agent = 'ceo' where id = ox; update public.outbox set status = 'approved' where id = ox;
    insert into public.outbox (id, agent, channel, to_ref, body, venture_id, lead_id) values (oy, 'donna-ops', 'email', 'has.drafts@example.com', 'y unsubscribe', va, lx);
    r := public.record_lead_reply(lx, 'unsubscribe', 'stop', 'owner:audit');
    if (select count(*) from public.outbox where id in (ox, oy) and status = 'rejected') <> 2 then raise exception 'AUDIT FAIL B14: open drafts were not rejected by the unsubscribe: %', r; end if;
    if not (select do_not_contact from public.leads where id = lx) or not public.is_suppressed('has.drafts@example.com') then raise exception 'AUDIT FAIL B14b: the unsubscribe did not stick'; end if;
  end;
  -- B15: the same through the raw flag (the lead is already flagged when the cascade runs): the draft must still end up rejected, never stay live
  declare ly uuid; oz uuid := '00000000-0000-0000-0000-00000000b0b1';
  begin
    insert into public.leads (venture_id, name, email) values (va, 'Raw flag', 'raw.flag@example.com') returning id into ly;
    insert into public.outbox (id, agent, channel, to_ref, body, venture_id, lead_id) values (oz, 'donna-ops', 'email', 'raw.flag@example.com', 'x unsubscribe', va, ly);
    update public.leads set do_not_contact = true where id = ly;
    if (select status from public.outbox where id = oz) <> 'rejected' then raise exception 'AUDIT FAIL B15: a raw do-not-contact flag left the draft live'; end if;
    if not public.is_suppressed('raw.flag@example.com') then raise exception 'AUDIT FAIL B15b: a raw flag did not suppress the address'; end if;
  end;
  -- the list is append-only for every role we have
  perform pg_temp.expect('B13 delete suppression', 'delete from public.contact_suppressions', '%append-only%');
  perform pg_temp.expect('B13 update suppression', 'update public.contact_suppressions set reason = ''x''', '%append-only%');
  perform pg_temp.expect('B13 truncate suppression', 'truncate public.contact_suppressions', '%append-only%');
  perform pg_temp.expect('B13 un-normalised suppression', 'insert into public.contact_suppressions (address, reason, recorded_by) values (''Quoted@X.com.'', ''x'', ''t'')');
end $$;

-- =============================================================== C. outbox approval flow, kill switch, dry-run, send policy
do $$
declare va uuid; n int; o uuid := '00000000-0000-0000-0000-00000000c001'; o2 uuid := '00000000-0000-0000-0000-00000000c002'; today int; i int;
begin
  select id into va from public.ventures where slug = 'audit-a';
  perform pg_temp.expect('C1 insert as approved', 'insert into public.outbox (agent, channel, to_ref, body, status) values (''donna-ops'', ''email'', ''ok@example.com'', ''x'', ''approved'')', '%start as draft%');
  perform pg_temp.expect('C1b insert as sent', 'insert into public.outbox (agent, channel, to_ref, body, status) values (''donna-ops'', ''email'', ''ok@example.com'', ''x'', ''sent'')', '%start as draft%');
  insert into public.outbox (id, agent, channel, to_ref, body, venture_id) values (o, 'donna-ops', 'email', 'ok1@example.com', 'x unsubscribe', va);
  perform pg_temp.expect('C2 draft -> approved skips QA', format('update public.outbox set status = ''approved'' where id = %L', o), '%pass QA%');
  perform pg_temp.expect('C3 draft -> sent skips everything', format('update public.outbox set status = ''sent'' where id = %L', o), '%approved before%');
  perform pg_temp.expect('C4 QA by the writing agent', format('update public.outbox set status = ''qa_passed'', qa_agent = ''donna-ops'' where id = %L', o), '%different agent%');
  perform pg_temp.expect('C4b QA with no reviewer', format('update public.outbox set status = ''qa_passed'' where id = %L', o), '%different agent%');
  update public.outbox set status = 'qa_passed', qa_agent = 'ceo' where id = o;
  perform pg_temp.expect('C5 qa_passed -> sent skips approval', format('update public.outbox set status = ''sent'' where id = %L', o), '%approved before%');
  update public.outbox set status = 'approved' where id = o;

  -- kill switch: nothing leaves, whatever the sender claims to be (except the owner marker, see KNOWN below)
  update public.system_state set kill_switch = true where id = 1;
  perform pg_temp.expect('C6 kill switch, no marker', format('update public.outbox set status = ''sent'' where id = %L', o), '%kill switch%');
  perform pg_temp.expect('C6b kill switch, sent_by system', format('update public.outbox set status = ''sent'', sent_by = ''system'' where id = %L', o), '%kill switch%');
  perform pg_temp.expect('C6c kill switch, sent_by agent', format('update public.outbox set status = ''sent'', sent_by = ''donna-ops'' where id = %L', o), '%kill switch%');
  update public.system_state set kill_switch = false, mode = 'dry_run' where id = 1;
  perform pg_temp.expect('C7 dry run', format('update public.outbox set status = ''sent'', sent_by = ''system'' where id = %L', o), '%dry run%');
  update public.system_state set mode = 'approve_first' where id = 1;
  perform pg_temp.expect('C8 approve_first: every send asks the owner', format('update public.outbox set status = ''sent'', sent_by = ''system'' where id = %L', o), '%refused by policy%');
  -- (a refusal raised inside the trigger rolls back its own action_log row: AUDIT_PATHS.md F8, observability only)
  update public.system_state set mode = 'auto_in_caps' where id = 1;

  -- daily cap of the send_email policy applies to a direct UPDATE too
  select count(*) into today from public.action_log where action = 'send_email' and decision = 'allow'
     and at >= date_trunc('day', now() at time zone 'America/Toronto') at time zone 'America/Toronto';
  for i in 1 .. greatest(0, 19 - today) loop insert into public.action_log (actor, action, tier, decision, reason) values ('audit', 'send_email', 'yellow', 'allow', 'pad'); end loop;
  perform pg_temp.ok('C9 send inside the daily cap', format('update public.outbox set status = ''sent'', sent_by = ''system'' where id = %L', o));
  if (select status from public.outbox where id = o) <> 'sent' or (select sent_at from public.outbox where id = o) is null then raise exception 'AUDIT FAIL C9b: not recorded as sent'; end if;
  insert into public.outbox (id, agent, channel, to_ref, body, venture_id) values (o2, 'donna-ops', 'email', 'ok2@example.com', 'x unsubscribe', va);
  update public.outbox set status = 'qa_passed', qa_agent = 'ceo' where id = o2;
  update public.outbox set status = 'approved' where id = o2;
  perform pg_temp.expect('C10 daily cap reached', format('update public.outbox set status = ''sent'', sent_by = ''system'' where id = %L', o2), '%refused by policy%');
  if (select status from public.outbox where id = o2) <> 'approved' then raise exception 'AUDIT FAIL C10b: a refused send changed the row'; end if;

  -- one contact per lead per day (enforce_outbox_rules), also on a direct UPDATE
  declare lid uuid; oa uuid := '00000000-0000-0000-0000-00000000c003'; ob uuid := '00000000-0000-0000-0000-00000000c004';
  begin
    delete from public.action_log where actor = 'audit' and reason = 'pad';   -- room under the daily send cap again
    insert into public.leads (venture_id, name, email) values (va, 'Twice', 'twice@example.com') returning id into lid;
    insert into public.outbox (id, agent, channel, to_ref, body, venture_id, lead_id) values (oa, 'donna-ops', 'email', 'twice@example.com', 'x unsubscribe', va, lid);
    update public.outbox set status = 'qa_passed', qa_agent = 'ceo' where id = oa; update public.outbox set status = 'approved' where id = oa;
    update public.outbox set status = 'sent', sent_by = 'system' where id = oa;
    insert into public.outbox (id, agent, channel, to_ref, body, venture_id, lead_id) values (ob, 'donna-ops', 'email', 'twice@example.com', 'y unsubscribe', va, lid);
    update public.outbox set status = 'qa_passed', qa_agent = 'ceo' where id = ob; update public.outbox set status = 'approved' where id = ob;
    perform pg_temp.expect('C11 second email to the same lead today', format('update public.outbox set status = ''sent'', sent_by = ''system'' where id = %L', ob), '%daily contact limit%');
  end;
  -- one open draft per lead at the database level
  perform pg_temp.ok('C12 first open draft', format('insert into public.outbox (agent, channel, to_ref, body, venture_id, lead_id) select ''donna-ops'', ''email'', ''twice2@example.com'', ''z'', %L, lead_id from public.outbox where id = %L', va, '00000000-0000-0000-0000-00000000c003'));
  perform pg_temp.expect('C12b second open draft for the same lead', format('insert into public.outbox (agent, channel, to_ref, body, venture_id, lead_id) select ''donna-ops'', ''email'', ''twice3@example.com'', ''z'', %L, lead_id from public.outbox where id = %L', va, '00000000-0000-0000-0000-00000000c003'), '%duplicate%');
end $$;

-- =============================================================== D. authorize_action (default-deny, kill switch, dry-run, approvals, limits)
do $$
declare r jsonb; ap uuid; n int;
begin
  update public.system_state set kill_switch = false, mode = 'auto_in_caps' where id = 1;
  r := public.authorize_action('audit', 'no_such_action_exists');
  if r->>'decision' <> 'deny' then raise exception 'AUDIT FAIL D1: an unknown action was not denied: %', r; end if;
  r := public.authorize_action('research', 'access_personal_bank');
  if r->>'decision' <> 'deny' or r->>'tier' <> 'prohibited' then raise exception 'AUDIT FAIL D2: a prohibited action was not denied: %', r; end if;
  if not exists (select 1 from public.escalations where summary like '%access_personal_bank%') then raise exception 'AUDIT FAIL D2b: a prohibited attempt did not escalate'; end if;
  r := public.authorize_action('audit', 'research');
  if r->>'decision' <> 'allow' then raise exception 'AUDIT FAIL D3: a green action was refused in normal mode: %', r; end if;
  update public.system_state set kill_switch = true where id = 1;
  r := public.authorize_action('audit', 'research');
  if r->>'decision' <> 'deny' or r->>'reason' not like 'Kill switch%' then raise exception 'AUDIT FAIL D4: the kill switch did not stop a GREEN action: %', r; end if;
  r := public.authorize_action('audit', 'take_loan');
  if r->>'decision' <> 'deny' then raise exception 'AUDIT FAIL D4b: the kill switch did not stop a RED action: %', r; end if;
  update public.system_state set kill_switch = false, mode = 'dry_run' where id = 1;
  if public.authorize_action('audit', 'research')->>'decision' <> 'allow' then raise exception 'AUDIT FAIL D5: dry-run must still allow internal green work'; end if;
  if public.authorize_action('audit', 'send_email')->>'decision' = 'allow' then raise exception 'AUDIT FAIL D5b: dry-run allowed send_email'; end if;
  if public.authorize_action('audit', 'routine_expense', 100)->>'decision' = 'allow' then raise exception 'AUDIT FAIL D5c: dry-run allowed an expense'; end if;
  if public.authorize_action('audit', 'take_loan')->>'decision' = 'allow' then raise exception 'AUDIT FAIL D5d: dry-run allowed a red action'; end if;
  update public.system_state set mode = 'auto_in_caps' where id = 1;

  -- red: asks; one approval = one use; bound to action, ref, amount and expiry; pending / rejected / expired never count
  r := public.authorize_action('audit', 'take_loan', 0, 'loan-1');
  if r->>'decision' <> 'ask_owner' then raise exception 'AUDIT FAIL D6: a red action did not ask the owner: %', r; end if;
  insert into public.approval_requests (actor, action, cents, ref, recommendation, status, decided_at) values ('audit', 'take_loan', 0, 'loan-1', 'x', 'pending', null);
  if public.authorize_action('audit', 'take_loan', 0, 'loan-1')->>'decision' <> 'ask_owner' then raise exception 'AUDIT FAIL D7: a PENDING request allowed the action'; end if;
  update public.approval_requests set status = 'rejected', decided_at = now() where ref = 'loan-1';
  if public.authorize_action('audit', 'take_loan', 0, 'loan-1')->>'decision' <> 'ask_owner' then raise exception 'AUDIT FAIL D7b: a REJECTED request allowed the action'; end if;
  insert into public.approval_requests (actor, action, cents, ref, recommendation, status, decided_at, expires_at) values ('audit', 'take_loan', 0, 'loan-2', 'x', 'approved', now(), now() - interval '1 minute');
  if public.authorize_action('audit', 'take_loan', 0, 'loan-2')->>'decision' <> 'ask_owner' then raise exception 'AUDIT FAIL D7c: an EXPIRED approval allowed the action'; end if;
  insert into public.approval_requests (actor, action, cents, ref, recommendation, status, decided_at) values ('audit', 'take_loan', 100, 'loan-3', 'x', 'approved', now()) returning id into ap;
  if public.authorize_action('audit', 'take_loan', 500, 'loan-3')->>'decision' <> 'ask_owner' then raise exception 'AUDIT FAIL D8: an approval for $1 covered a $5 action'; end if;
  if public.authorize_action('audit', 'take_loan', 100, 'other-ref')->>'decision' <> 'ask_owner' then raise exception 'AUDIT FAIL D8b: an approval was used for a different ref'; end if;
  if public.authorize_action('audit', 'sell_business', 100, 'loan-3')->>'decision' <> 'ask_owner' then raise exception 'AUDIT FAIL D8c: an approval was used for a different action'; end if;
  if public.authorize_action('audit', 'take_loan', 100, 'loan-3')->>'decision' <> 'allow' then raise exception 'AUDIT FAIL D9: the matching approval was not honoured'; end if;
  if (select status from public.approval_requests where id = ap) <> 'used' then raise exception 'AUDIT FAIL D9b: approval not consumed'; end if;
  if public.authorize_action('audit', 'take_loan', 100, 'loan-3')->>'decision' <> 'ask_owner' then raise exception 'AUDIT FAIL D10: one approval was used twice'; end if;

  -- approve-first mode: yellow needs the owner too
  update public.system_state set mode = 'approve_first' where id = 1;
  if public.authorize_action('audit', 'routine_expense', 100)->>'decision' <> 'ask_owner' then raise exception 'AUDIT FAIL D11: approve_first let a yellow action through'; end if;
  update public.system_state set mode = 'auto_in_caps' where id = 1;
  -- limits: per action, per day, per week; negative amounts count as zero, never as credit
  if public.authorize_action('audit', 'payment_instruction', 20001)->>'decision' <> 'ask_owner' then raise exception 'AUDIT FAIL D12: per-action limit'; end if;
  if public.authorize_action('audit', 'payment_instruction', -999999, 'neg')->>'decision' <> 'allow' then raise exception 'AUDIT FAIL D12b: a negative amount must be treated as zero'; end if;
  if (select cents from public.action_log where ref = 'neg' order by id desc limit 1) <> 0 then raise exception 'AUDIT FAIL D12c: a negative amount was logged as credit'; end if;
  insert into public.action_log (actor, action, tier, decision, reason, cents) select 'audit', 'routine_expense', 'yellow', 'allow', 'pad', 1 from generate_series(1, 3);
  if public.authorize_action('audit', 'routine_expense', 1)->>'decision' <> 'deny' then raise exception 'AUDIT FAIL D13: daily count limit'; end if;
  delete from public.action_log where reason = 'pad' and actor = 'audit';
  insert into public.action_log (actor, action, tier, decision, reason, cents) values ('audit', 'routine_expense', 'yellow', 'allow', 'pad', 4900);
  if public.authorize_action('audit', 'routine_expense', 200)->>'decision' <> 'ask_owner' then raise exception 'AUDIT FAIL D14: weekly money limit'; end if;
  delete from public.action_log where reason = 'pad' and actor = 'audit';

  -- the policy table: only the owner marker may change it; nothing may delete from it
  perform pg_temp.expect('D15 non-owner edit', 'update public.action_policy set tier = ''green'' where action = ''take_loan''', '%only the owner%');
  perform pg_temp.expect('D15b non-owner raise of a limit', 'update public.action_policy set max_count_per_day = 9999, updated_by = ''jarvis'' where action = ''send_email''', '%only the owner%');
  perform pg_temp.expect('D15c delete', 'delete from public.action_policy where action = ''take_loan''', '%cannot be deleted%');
  perform pg_temp.expect('D15d capital limits by a non-owner', 'update public.capital_policy set per_transaction_limit_cents = 99999999, updated_by = ''jarvis''', '%only the owner%');
  perform pg_temp.expect('D15e focus mode by a non-owner', 'select public.set_focus_mission(null, ''jarvis'')', '%only the owner%');
end $$;

-- =============================================================== E. anon / authenticated database roles
do $$
declare bad text; n int; t record; cnt_su bigint; cnt_r bigint; nonempty int := 0; uid_stranger uuid := gen_random_uuid(); uid_owner uuid := gen_random_uuid(); uid_unconfirmed uuid := gen_random_uuid();
        fn text; mid uuid;
        app_fns text[] := array['select public.app_snapshot()', 'select public.app_messages(5)', 'select public.app_send(''hello'')', 'select public.app_set_kill(false)',
                                'select public.app_set_agent(''research'', ''paused'')', 'select public.app_venture(''donna'')', 'select public.app_venture_extras(''donna'')',
                                'select public.app_office()', 'select public.app_payments()', 'select public.app_push_public_key()',
                                'select public.app_save_push(''{}''::jsonb, ''x'')'];
begin
  -- E1: the ONLY functions a stranger may execute are the owner-checked app_* functions, the owner probe and the public setter sign-up
  select string_agg(p.oid::regprocedure::text, ', ') into bad from pg_proc p
   where p.pronamespace = 'public'::regnamespace and p.prokind = 'f'
     and (has_function_privilege('anon', p.oid, 'execute') or has_function_privilege('authenticated', p.oid, 'execute') or has_function_privilege('public', p.oid, 'execute'))
     and p.proname not in ('is_app_owner', 'app_snapshot', 'app_messages', 'app_send', 'app_set_kill', 'app_set_agent', 'app_venture', 'app_venture_extras', 'app_office',
                           'app_payments', 'app_push_public_key', 'app_save_push', 'app_needs_you', 'setter_apply');
  if bad is not null then raise exception 'AUDIT FAIL E1: functions executable by anon/authenticated/public that should not be: %', bad; end if;
  select string_agg(p.oid::regprocedure::text, ', ') into bad from pg_proc p
   where p.pronamespace = 'public'::regnamespace and p.prokind = 'f' and has_function_privilege('anon', p.oid, 'execute') and p.proname <> 'setter_apply';
  if bad is not null then raise exception 'AUDIT FAIL E1b: anon (not signed in) can execute: %', bad; end if;
  -- every security-definer function pins its search_path (no schema hijack)
  select string_agg(p.oid::regprocedure::text, ', ') into bad from pg_proc p
   where p.pronamespace = 'public'::regnamespace and p.prosecdef and not exists (select 1 from unnest(coalesce(p.proconfig, '{}')) c where c like 'search_path=%');
  if bad is not null then raise exception 'AUDIT FAIL E2: security definer without a pinned search_path: %', bad; end if;
  -- no RLS policy hands a table to a stranger
  if exists (select 1 from pg_policies where schemaname = 'public' and roles && array['anon', 'authenticated', 'public']::name[]) then
    raise exception 'AUDIT FAIL E3: an RLS policy grants rows to anon/authenticated/public';
  end if;
  -- views must run with the caller's rights (otherwise they bypass RLS) or be closed to strangers
  select string_agg(c.relname, ', ') into bad from pg_class c
   where c.relnamespace = 'public'::regnamespace and c.relkind in ('v', 'm')
     and (has_table_privilege('anon', c.oid, 'select') or has_table_privilege('authenticated', c.oid, 'select'))
     and not coalesce(c.reloptions::text like '%security_invoker=true%', false) and c.relname not like 'drill%';
  if bad is not null then raise exception 'AUDIT FAIL E4: view readable by a stranger without security_invoker: %', bad; end if;
  -- every table a MIGRATION made has RLS on. The replica's core tables (01_tables.sql, copied from live) have RLS off here; live proves it with ops/verify_live.sql (rls_off must be 'none').
  select string_agg(c.relname, ', ') into bad from pg_class c
   where c.relnamespace = 'public'::regnamespace and c.relkind = 'r' and not c.relrowsecurity and c.relname not like 'drill%'
     and c.relname not in ('accounts_registry','agent_runs','agents','audit_log','build_requests','company_profile','dayjob_days','dayjob_targets','deals','departments','escalations',
                           'handbook','human_handoffs','ideas','leads','ledger','llm_calls','memory','missions','model_prices','outbox','owner_messages','predictions',
                           'reconciliation_flags','system_state','systems','tasks','tool_registry','ventures');
  if bad is not null then raise exception 'AUDIT FAIL E5: a new table has no row level security (add "alter table ... enable row level security"): %', bad; end if;

  -- E6: with RLS on and no policy a stranger sees and changes nothing, in every RLS table that holds rows
  insert into public.app_owners (email) values ('owner@example.com') on conflict do nothing;
  insert into public.web_messages (role, kind, body) values ('jarvis', 'chat', 'seed');
  insert into public.approval_requests (actor, action, recommendation) values ('audit', 'take_loan', 'seed');
  for t in select c.relname from pg_class c where c.relnamespace = 'public'::regnamespace and c.relkind = 'r' and c.relrowsecurity order by 1 loop
    execute format('select count(*) from public.%I', t.relname) into cnt_su;
    if cnt_su > 0 then nonempty := nonempty + 1; end if;
    foreach fn in array array['anon', 'authenticated'] loop
      execute format('set local role %I', fn);
      begin execute format('select count(*) from public.%I', t.relname) into cnt_r; exception when insufficient_privilege then cnt_r := 0; end;
      if cnt_r <> 0 then reset role; raise exception 'AUDIT FAIL E6: % can read % rows of %', fn, cnt_r, t.relname; end if;
      begin
        execute format('delete from public.%I', t.relname); get diagnostics n = row_count;
        if n <> 0 then reset role; raise exception 'AUDIT FAIL E6b: % deleted % rows of %', fn, n, t.relname; end if;
      exception when insufficient_privilege then null; end;
      reset role;
    end loop;
    execute format('select count(*) from public.%I', t.relname) into cnt_r;
    if cnt_r <> cnt_su then raise exception 'AUDIT FAIL E6c: row count of % changed (% -> %) after stranger writes', t.relname, cnt_su, cnt_r; end if;
  end loop;
  if nonempty < 5 then raise exception 'AUDIT FAIL E6d: only % RLS tables held rows, the check proves too little', nonempty; end if;

  -- E7: a signed-in stranger (not in app_owners) is refused by every app_* function and cannot forge an owner command by writing web_messages
  insert into auth.users (id, email, email_confirmed_at) values (uid_stranger, 'stranger@example.com', now()), (uid_owner, 'Owner@Example.com', now()), (uid_unconfirmed, 'owner@example.com', null);
  perform set_config('app.uid', uid_stranger::text, true);
  set local role authenticated;
  if public.is_app_owner() then reset role; raise exception 'AUDIT FAIL E7: a stranger is an owner'; end if;
  foreach fn in array app_fns loop
    begin execute fn; reset role; raise exception 'AUDIT FAIL E7b: a stranger could run: %', fn;
    exception when insufficient_privilege then null; when others then if sqlerrm like 'AUDIT FAIL%' then raise; end if; end;
  end loop;
  begin insert into public.web_messages (role, kind, body, status) values ('owner', 'decision', 'forged', 'new'); reset role; raise exception 'AUDIT FAIL E7c: a stranger forged an owner command';
  exception when insufficient_privilege then null; end;
  reset role;
  -- the owner proper (verified e-mail on the list, case-insensitive) works, and still cannot write the table directly
  perform set_config('app.uid', uid_owner::text, true);
  set local role authenticated;
  if not public.is_app_owner() then reset role; raise exception 'AUDIT FAIL E8: the owner is refused'; end if;
  mid := public.app_send('hello', 'chat', '{}'::jsonb);
  begin insert into public.web_messages (role, kind, body, status) values ('owner', 'decision', 'direct', 'new'); reset role; raise exception 'AUDIT FAIL E8b: the owner wrote web_messages directly';
  exception when insufficient_privilege then null; end;
  reset role;
  if (select role from public.web_messages where id = mid) <> 'owner' then raise exception 'AUDIT FAIL E8c: app_send did not record an owner message'; end if;
  -- an unconfirmed e-mail with the owner's address is not the owner
  perform set_config('app.uid', uid_unconfirmed::text, true);
  set local role authenticated;
  if public.is_app_owner() then reset role; raise exception 'AUDIT FAIL E9: an unconfirmed e-mail counts as the owner'; end if;
  reset role;
end $$;

-- =============================================================== F. spend gateway (AI)
do $$
declare base int; a1 text := 'audit-agent-1'; a2 text := 'audit-agent-2'; c1 uuid; c2 uuid; m uuid; t1 uuid;
begin
  insert into public.agents (slug, title, daily_spend_cap_cents) values (a1, 'Audit 1', 50), (a2, 'Audit 2', 500);
  select coalesce(sum(coalesce(actual_cents, reserved_cents)), 0) into base from public.llm_calls where status in ('reserved', 'done')
     and started_at >= date_trunc('day', now() at time zone 'America/Toronto') at time zone 'America/Toronto';
  update public.system_state set daily_spend_cap_cents = base + 100, kill_switch = false, mode = 'auto_in_caps', focus_mission = null where id = 1;
  update public.capital_policy set operating_fund_cents = 100000000, updated_by = 'owner:audit';

  perform pg_temp.expect('F1 unknown agent', $q$select public.reserve_llm_budget('nobody', 1, 'm', 'x')$q$, '%unknown agent%');
  c1 := public.reserve_llm_budget(a1, 40, 'm', 'x');
  perform pg_temp.expect('F2 agent cap', format('select public.reserve_llm_budget(%L, 20, ''m'', ''x'')', a1), '%daily cap%');
  perform pg_temp.expect('F3 company cap', format('select public.reserve_llm_budget(%L, 70, ''m'', ''x'')', a2), '%company daily spend cap%');
  c2 := public.reserve_llm_budget(a2, 60, 'm', 'x');
  perform pg_temp.expect('F4 company cap exactly used', format('select public.reserve_llm_budget(%L, 1, ''m'', ''x'')', a2), '%company daily spend cap%');
  perform public.settle_llm_call(c2, 0, 'failed');   -- a failed call frees its reservation
  perform pg_temp.ok('F5 freed budget can be used again', format('select public.reserve_llm_budget(%L, 60, ''m'', ''x'')', a2));

  update public.agents set status = 'paused' where slug = a2;
  perform pg_temp.expect('F6 paused agent', format('select public.reserve_llm_budget(%L, 1, ''m'', ''x'')', a2), '%paused%');
  update public.agents set status = 'active' where slug = a2;
  update public.system_state set kill_switch = true where id = 1;
  perform pg_temp.expect('F7 kill switch', format('select public.reserve_llm_budget(%L, 1, ''m'', ''x'')', a1), '%kill switch%');
  perform pg_temp.expect('F7b kill switch, even the credit probe', $q$select public.reserve_llm_budget('jarvis', 1, 'm', 'credit probe')$q$, '%kill switch%');
  update public.system_state set kill_switch = false, daily_spend_cap_cents = base + 100000 where id = 1;

  -- capital: hard stop refuses every AI call, low-cost mode caps the company at low_cost_ai_cap_cents
  update public.capital_policy set operating_fund_cents = operating_fund_cents - (public.capital_snapshot()->>'available_cents')::int + 1500, updated_by = 'owner:audit';
  perform pg_temp.expect('F8 capital hard stop', format('select public.reserve_llm_budget(%L, 1, ''m'', ''x'')', a2), '%hard stop%');
  update public.capital_policy set operating_fund_cents = operating_fund_cents - (public.capital_snapshot()->>'available_cents')::int + 6000, updated_by = 'owner:audit';
  if public.capital_mode() <> 'low_cost' then raise exception 'AUDIT FAIL F9 setup: mode is %', public.capital_mode(); end if;
  perform pg_temp.expect('F9 low-cost company cap', format('select public.reserve_llm_budget(%L, 1, ''m'', ''x'')', a2), '%company daily spend cap%');
  update public.capital_policy set operating_fund_cents = 100000000, updated_by = 'owner:audit';

  -- mission budget is enforced BEFORE the call is reserved, per task purpose; focus mode refuses everything else
  insert into public.missions (title, objective, budget_cents) values ('Audit mission', 'objective long enough to pass', 100) returning id into m;
  insert into public.tasks (title, assigned_agent, mission_id, mission_role) values ('step a', a2, m, 'step') returning id into t1;
  c1 := public.reserve_llm_budget(a2, 60, 'm', 'task ' || t1);
  perform pg_temp.expect('F10 mission budget', format('select public.reserve_llm_budget(%L, 50, ''m'', %L)', a2, 'task ' || t1), '%mission budget%');
  perform public.settle_llm_call(c1, 10, 'done');
  perform pg_temp.ok('F11 budget freed by a cheaper settlement', format('select public.reserve_llm_budget(%L, 50, ''m'', %L)', a2, 'task ' || t1));
  perform public.set_focus_mission(m, 'owner:audit');
  perform pg_temp.expect('F12 focus mode refuses other work', format('select public.reserve_llm_budget(%L, 1, ''m'', ''triage something'')', a2), '%focus mode%');
  perform pg_temp.ok('F12b focus mode keeps its own mission', format('select public.reserve_llm_budget(%L, 1, ''m'', %L)', a2, 'task ' || t1));
  perform public.set_focus_mission(null, 'owner:audit');
end $$;

-- =============================================================== G. money (non-AI spend, payments)
do $$
declare r jsonb; res uuid; pid uuid; txt text; led int;
begin
  update public.system_state set kill_switch = false, mode = 'auto_in_caps' where id = 1;
  update public.capital_policy set operating_fund_cents = 100000000, updated_by = 'owner:audit';
  r := public.reserve_spend('audit', 'routine_expense', 'Vendor', 'a real purpose', 'a real benefit', 'none', 0);
  if r->>'decision' <> 'deny' then raise exception 'AUDIT FAIL G1: a zero-cost reservation was allowed: %', r; end if;
  r := public.reserve_spend('audit', 'routine_expense', 'Vendor', 'a real purpose', 'a real benefit', 'none', -500);
  if r->>'decision' <> 'deny' then raise exception 'AUDIT FAIL G1b: a negative reservation was allowed: %', r; end if;
  r := public.reserve_spend('audit', 'not_a_policy_action', 'Vendor', 'a real purpose', 'a real benefit', 'none', 100);
  if r->>'decision' <> 'deny' then raise exception 'AUDIT FAIL G2: an unknown spend action was allowed: %', r; end if;
  r := public.reserve_spend('audit', 'routine_expense', 'Vendor', 'a real purpose', 'a real benefit', 'none', 2600);
  if r->>'decision' = 'allow' then raise exception 'AUDIT FAIL G3: over the per-transaction limit was allowed: %', r; end if;
  r := public.reserve_spend('audit', 'routine_expense', 'Vendor', 'a real purpose', 'a real benefit', 'none', 1500);
  if r->>'decision' <> 'allow' then raise exception 'AUDIT FAIL G4: a small expense was refused: %', r; end if;
  res := (r->>'reservation_id')::uuid;
  update public.system_state set mode = 'dry_run' where id = 1;
  r := public.reserve_spend('audit', 'routine_expense', 'Vendor', 'a real purpose', 'a real benefit', 'none', 100);
  if r->>'decision' = 'allow' then raise exception 'AUDIT FAIL G5: dry-run allowed a paid reservation: %', r; end if;
  update public.system_state set kill_switch = true, mode = 'auto_in_caps' where id = 1;
  r := public.reserve_spend('audit', 'routine_expense', 'Vendor', 'a real purpose', 'a real benefit', 'none', 100);
  if r->>'decision' = 'allow' then raise exception 'AUDIT FAIL G6: the kill switch did not stop a paid reservation: %', r; end if;
  update public.system_state set kill_switch = false where id = 1;
  r := public.settle_spend(res, 1500, '');
  if (r->>'ok')::boolean then raise exception 'AUDIT FAIL G7: settled without a receipt'; end if;
  r := public.settle_spend(res, 1500, 'RCPT-1');
  if not (r->>'ok')::boolean then raise exception 'AUDIT FAIL G8: could not settle: %', r; end if;
  r := public.settle_spend(res, 1500, 'RCPT-1');
  if (r->>'ok')::boolean then raise exception 'AUDIT FAIL G9: one reservation settled twice'; end if;

  -- payments: the owner decides and confirms; amounts are bounded by what was approved; one payment, one settlement
  r := public.prepare_payment('audit', 'Payee Co', 25000, 'rent for the office', 'none');
  if r->>'decision' = 'allow' then raise exception 'AUDIT FAIL G10: a $250 payment was prepared without the owner (per-transaction limit): %', r; end if;
  r := public.prepare_payment('audit', 'Payee Co', 1800, 'domain renewal', 'none');
  if r->>'decision' <> 'allow' then raise exception 'AUDIT FAIL G11: a small payment instruction was refused: %', r; end if;
  pid := (r->>'instruction_id')::uuid;
  perform pg_temp.expect('G12 non-owner decides', format('select public.decide_payment(%L, true, ''jarvis'')', pid), '%only the owner%');
  txt := public.confirm_payment(pid, 100, 'r', 'owner:audit');
  if txt not like 'No approved payment%' then raise exception 'AUDIT FAIL G12b: confirmed before approval: %', txt; end if;
  perform public.decide_payment(pid, true, 'owner:audit');
  perform pg_temp.expect('G13 non-owner confirms', format('select public.confirm_payment(%L, 100, ''r'', ''jarvis'')', pid), '%only the owner%');
  txt := public.confirm_payment(pid, 1801, 'BANK-1', 'owner:audit');
  if txt not like 'Amount must be%' then raise exception 'AUDIT FAIL G14: paid more than approved: %', txt; end if;
  txt := public.confirm_payment(pid, 0, 'BANK-1', 'owner:audit');
  if txt not like 'Amount must be%' then raise exception 'AUDIT FAIL G14b: paid zero: %', txt; end if;
  select count(*) into led from public.ledger where note like '%BANK-1%';
  txt := public.confirm_payment(pid, 1800, 'BANK-1', 'owner:audit');
  if txt not like 'Recorded:%' then raise exception 'AUDIT FAIL G15: could not confirm: %', txt; end if;
  txt := public.confirm_payment(pid, 1800, 'BANK-1', 'owner:audit');
  if txt not like 'No approved payment%' then raise exception 'AUDIT FAIL G16: a payment confirmed twice: %', txt; end if;
  if (select count(*) from public.ledger where note like '%BANK-1%') <> led + 1 then raise exception 'AUDIT FAIL G16b: the ledger did not get exactly one expense'; end if;
  -- rejecting releases the money
  r := public.prepare_payment('audit', 'Payee Two', 1200, 'hosting for a month', 'none');
  pid := (r->>'instruction_id')::uuid;
  perform public.decide_payment(pid, false, 'owner:audit');
  if (select status from public.spend_reservations where id = (select reservation_id from public.payment_instructions where id = pid)) <> 'released' then raise exception 'AUDIT FAIL G17: a rejected payment kept its money reserved'; end if;
end $$;

-- =============================================================== H. deal pipeline and mission lifecycle
do $$
declare va uuid; lid uuid; ldnc uuid; d uuid; d2 uuid; led int; r jsonb; m uuid; n int;
begin
  select id into va from public.ventures where slug = 'audit-a';
  insert into public.leads (venture_id, name, email, status) values (va, 'Deal lead', 'deal.lead@example.com', 'replied') returning id into lid;
  select id into ldnc from public.leads where name = 'A victim';
  perform pg_temp.expect('H1 deal for an opted-out lead', format('select public.create_deal(%L, 100, ''owner:audit'')', ldnc), '%do-not-contact%');
  perform pg_temp.expect('H2 non-owner opens a deal', format('select public.create_deal(%L, 100, ''donna-ops'')', lid), '%only the owner%');
  perform pg_temp.expect('H3 value above the cap', format('select public.create_deal(%L, 10000001, ''owner:audit'')', lid), '%10,000,000%');
  perform pg_temp.expect('H3b negative value', format('select public.create_deal(%L, -1, ''owner:audit'')', lid), '%between 0%');
  d := public.create_deal(lid, 10000000, 'owner:audit', 'at the cap');
  perform pg_temp.expect('H4 second open deal for the lead', format('select public.create_deal(%L, 100, ''owner:audit'')', lid), '%already has an open deal%');
  perform pg_temp.expect('H4b raw second open deal', format('insert into public.deals (venture_id, lead_id, stage) values (%L, %L, ''negotiating'')', va, lid), '%duplicate%');
  perform pg_temp.expect('H5 won through set_deal_stage', format('select public.set_deal_stage(%L, ''won'', ''owner:audit'')', d), '%confirm_deal_won%');
  perform pg_temp.expect('H5b non-owner moves a deal', format('select public.set_deal_stage(%L, ''negotiating'', ''donna-ops'')', d), '%only the owner%');
  select count(*) into led from public.ledger where kind = 'revenue';
  perform pg_temp.expect('H6 non-owner confirms', format('select public.confirm_deal_won(%L, 100, ''received'', ''donna-ops'')', d), '%only the owner%');
  perform pg_temp.expect('H6b zero amount', format('select public.confirm_deal_won(%L, 0, ''received'', ''owner:audit'')', d), '%positive amount%');
  perform pg_temp.expect('H6c negative amount', format('select public.confirm_deal_won(%L, -5, ''received'', ''owner:audit'')', d), '%positive amount%');
  perform pg_temp.expect('H6d amount above the cap', format('select public.confirm_deal_won(%L, 10000001, ''received'', ''owner:audit'')', d), '%limit%');
  perform pg_temp.expect('H6e bad ledger status', format('select public.confirm_deal_won(%L, 100, ''signed'', ''owner:audit'')', d), '%received or expected%');
  perform pg_temp.expect('H6f unknown deal', format('select public.confirm_deal_won(%L, 100, ''received'', ''owner:audit'')', gen_random_uuid()), '%no such deal%');
  if (select count(*) from public.ledger where kind = 'revenue') <> led then raise exception 'AUDIT FAIL H7: a refused confirmation wrote the ledger'; end if;
  r := public.confirm_deal_won(d, 10000000, 'expected', 'owner:audit', 'at the cap');
  if (select count(*) from public.ledger where kind = 'revenue' and note like 'deal ' || d || '%' and amount_cents = 10000000 and status = 'expected') <> 1 then raise exception 'AUDIT FAIL H8: revenue not recorded exactly once'; end if;
  perform pg_temp.expect('H9 confirm twice (idempotent)', format('select public.confirm_deal_won(%L, 10000000, ''expected'', ''owner:audit'')', d), '%already won%');
  if (select count(*) from public.ledger where kind = 'revenue' and note like 'deal ' || d || '%') <> 1 then raise exception 'AUDIT FAIL H9b: revenue recorded twice'; end if;
  perform pg_temp.expect('H10 stage change after a win', format('select public.set_deal_stage(%L, ''lost'', ''owner:audit'')', d), null);
  if (select status from public.leads where id = lid) <> 'won' then raise exception 'AUDIT FAIL H11: lead not marked won'; end if;
  -- a lost deal can never be confirmed; a raw stage write records no revenue (only the KPI count can be touched, never the ledger)
  insert into public.leads (venture_id, name, email) values (va, 'Lost lead', 'lost.lead@example.com') returning id into lid;
  d2 := public.create_deal(lid, 500, 'owner:audit');
  perform public.set_deal_stage(d2, 'lost', 'owner:audit');
  perform pg_temp.expect('H12 confirm a lost deal', format('select public.confirm_deal_won(%L, 500, ''received'', ''owner:audit'')', d2), '%already lost%');
  select count(*) into led from public.ledger where kind = 'revenue';
  update public.deals set stage = 'won' where id = d2;
  if (select count(*) from public.ledger where kind = 'revenue') <> led then raise exception 'AUDIT FAIL H13: a raw stage update wrote revenue'; end if;

  -- missions: lifecycle, evidence, budget ceiling, step and plan limits
  perform pg_temp.expect('H20 start in a non-initial state', $q$insert into public.missions (title, objective, status) values ('Bad start', 'objective long enough', 'executing')$q$, '%start as captured%');
  perform pg_temp.expect('H21 budget above the hard ceiling', $q$insert into public.missions (title, objective, budget_cents) values ('Big budget', 'objective long enough', 2001)$q$, null);
  perform pg_temp.expect('H21b negative budget', $q$insert into public.missions (title, objective, budget_cents) values ('Neg budget', 'objective long enough', -1)$q$, null);
  insert into public.missions (title, objective, budget_cents, max_steps) values ('Lifecycle', 'objective long enough', 100, 2) returning id into m;
  perform pg_temp.expect('H22 captured -> executing', format('update public.missions set status = ''executing'' where id = %L', m), '%cannot go from%');
  update public.missions set status = 'evaluated' where id = m; update public.missions set status = 'planned' where id = m; update public.missions set status = 'executing' where id = m;
  update public.missions set status = 'blocked' where id = m;
  update public.missions set status = 'executing' where id = m; update public.missions set status = 'verifying' where id = m;
  perform pg_temp.expect('H23 complete without evidence', format('update public.missions set status = ''completed'' where id = %L', m), '%evidence%');
  perform pg_temp.expect('H23b complete with empty evidence', format('update public.missions set status = ''completed'', evidence = ''[]'' where id = %L', m), '%evidence%');
  perform pg_temp.expect('H23c plan above max_steps', format('update public.missions set plan = ''[1,2,3]''::jsonb where id = %L', m), '%steps%');
  update public.missions set status = 'completed', evidence = '[{"claim":"c","source":"s"}]' where id = m;
  perform pg_temp.expect('H24 a completed mission cannot be reopened', format('update public.missions set status = ''executing'' where id = %L', m), '%cannot go from%');
  insert into public.missions (title, objective, budget_cents, max_steps, strict_steps) values ('Strict', 'objective long enough', 100, 2, true) returning id into m;
  insert into public.tasks (title, assigned_agent, mission_id, mission_role) values ('s1', 'research', m, 'step'), ('s2', 'research', m, 'step');
  perform pg_temp.expect('H25 third step in a 2-step mission', format('insert into public.tasks (title, assigned_agent, mission_id, mission_role) values (''s3'', ''research'', %L, ''step'')', m), '%step limit%');
  for n in 1 .. 12 loop insert into public.tasks (title, assigned_agent, mission_id, mission_role) values ('v' || n, 'research', m, 'verify'); end loop;
  perform pg_temp.expect('H26 thirteenth verification task', format('insert into public.tasks (title, assigned_agent, mission_id, mission_role) values (''v13'', ''research'', %L, ''verify'')', m), '%too many%');
end $$;

rollback;
