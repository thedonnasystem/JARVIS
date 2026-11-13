-- REPRODUCTION (read-only against a throwaway replica; everything runs in a transaction that is rolled back).
-- Question: what does ONE email send do to the daily send_email allowance, and what happens at the boundaries?
-- It mimics hq_mail.deliver_approved exactly: (1) Python calls authorize_action('send_email', ref=outbox id),
-- (2) the email is posted, (3) Python PATCHes outbox status 'sent', which fires trigger outbox_send_policy,
-- which calls authorize_action again with the same ref.
begin;
set local client_min_messages = warning;
create temp table repro_out (step text, detail text) on commit drop;
do $$
declare
  ag text; ag2 text; vid uuid; l uuid; o uuid; r jsonb; n int; sent int := 0; posted_not_marked int := 0; i int; lim int;
begin
  select slug into ag from public.agents order by slug limit 1;
  select slug into ag2 from public.agents where slug <> ag order by slug limit 1;
  select id into vid from public.ventures limit 1;
  update public.system_state set kill_switch = false, mode = 'auto_in_caps' where id = 1;
  select max_count_per_day into lim from public.action_policy where action = 'send_email';
  insert into repro_out values ('policy', format('send_email tier=yellow max_count_per_day=%s mode=auto_in_caps', lim));

  -- A) one send, count what the log holds
  insert into public.leads (venture_id, name, email, source, status) values (vid, 'repro', 'repro-a@example.com', 'test', 'new') returning id into l;
  insert into public.outbox (venture_id, agent, channel, to_ref, body, status, lead_id) values (vid, ag, 'email', 'repro-a@example.com', 'Subject: x'||E'\nhi', 'draft', l) returning id into o;
  update public.outbox set status = 'qa_passed', qa_agent = ag2 where id = o;
  update public.outbox set status = 'approved' where id = o;
  r := public.authorize_action(ag, 'send_email', 0, o::text);                  -- (1) Python side
  insert into repro_out values ('A1 python authorize', r->>'decision');
  update public.outbox set status = 'sent', sent_at = now(), sent_by = 'system' where id = o;  -- (3) mark sent -> trigger
  select count(*) into n from public.action_log where action = 'send_email' and decision = 'allow' and ref = o::text;
  insert into repro_out values ('A2 allow rows logged for ONE send', n::text);

  -- B) drive sends until the daily limit stops them, exactly as the sender would
  delete from public.action_log where action = 'send_email';
  for i in 1..40 loop
    insert into public.outbox (venture_id, agent, channel, to_ref, body, status, lead_id)
      values (vid, ag, 'email', 'repro-b'||i||'@example.com', 'Subject: x'||E'\nhi', 'draft', null) returning id into o;
    update public.outbox set status = 'qa_passed', qa_agent = ag2 where id = o;
    update public.outbox set status = 'approved' where id = o;
    r := public.authorize_action(ag, 'send_email', 0, o::text);
    exit when r->>'decision' <> 'allow';
    begin
      update public.outbox set status = 'sent', sent_at = now(), sent_by = 'system' where id = o;
      sent := sent + 1;
    exception when others then
      posted_not_marked := posted_not_marked + 1;   -- email already posted at step (2), but the row could not be marked sent
      insert into repro_out values ('B! trigger refused AFTER python allowed', sqlerrm);
    end;
  end loop;
  insert into repro_out values ('B1 sends completed', sent::text);
  insert into repro_out values ('B2 emails posted but row NOT marked sent (would be re-sent next tick)', posted_not_marked::text);
  select count(*) into n from public.action_log where action = 'send_email' and decision = 'allow';
  insert into repro_out values ('B3 allow rows consumed in the daily counter', n::text);

  -- C) approve_first mode with one owner approval: python consumes it, the trigger then asks again
  delete from public.action_log where action = 'send_email';
  update public.system_state set mode = 'approve_first' where id = 1;
  insert into public.outbox (venture_id, agent, channel, to_ref, body, status) values (vid, ag, 'email', 'repro-c@example.com', 'Subject: x'||E'\nhi', 'draft') returning id into o;
  update public.outbox set status = 'qa_passed', qa_agent = ag2 where id = o;
  update public.outbox set status = 'approved' where id = o;
  insert into public.approval_requests (actor, action, cents, ref, recommendation, status, decided_at)
    values (ag, 'send_email', 0, o::text, 'repro', 'approved', now());
  r := public.authorize_action(ag, 'send_email', 0, o::text);
  insert into repro_out values ('C1 python authorize with ONE owner approval', r->>'decision');
  begin
    update public.outbox set status = 'sent', sent_at = now(), sent_by = 'system' where id = o;
    insert into repro_out values ('C2 mark sent', 'ok');
  exception when others then
    insert into repro_out values ('C2 mark sent', 'REFUSED: ' || sqlerrm);
  end;

  -- D) odd daily limit (5): python allows at count 4 (logs the 5th), then the trigger sees 5 >= 5 and refuses
  delete from public.action_log where action = 'send_email';
  update public.system_state set mode = 'auto_in_caps' where id = 1;
  update public.action_policy set max_count_per_day = 5, updated_by = 'owner:repro' where action = 'send_email';
  sent := 0; posted_not_marked := 0;
  for i in 1..12 loop
    insert into public.outbox (venture_id, agent, channel, to_ref, body, status) values (vid, ag, 'email', 'repro-d'||i||'@example.com', 'Subject: x'||E'\nhi', 'draft') returning id into o;
    update public.outbox set status = 'qa_passed', qa_agent = ag2 where id = o;
    update public.outbox set status = 'approved' where id = o;
    r := public.authorize_action(ag, 'send_email', 0, o::text);
    exit when r->>'decision' <> 'allow';
    begin
      update public.outbox set status = 'sent', sent_at = now(), sent_by = 'system' where id = o;
      sent := sent + 1;
    exception when others then
      posted_not_marked := posted_not_marked + 1;
      insert into repro_out values ('D! trigger refused AFTER python allowed', sqlerrm);
    end;
  end loop;
  insert into repro_out values ('D1 limit 5: sends completed', sent::text);
  insert into repro_out values ('D2 limit 5: emails posted but row NOT marked sent', posted_not_marked::text);
end $$;
select step || ' => ' || detail as result from repro_out order by ctid;
rollback;
