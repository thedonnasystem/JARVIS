-- Run AFTER ops/pending_signoff/send_policy_single_authorization.sql on a scratch replica. Rolled back. Every case must print ok.
begin;
create temp table neg (step text, detail text) on commit drop;
do $$
declare ag text; ag2 text; vid uuid; o uuid; o2 uuid; o3 uuid; r jsonb; n int; claimed int;
begin
  select slug into ag from public.agents order by slug limit 1;
  select slug into ag2 from public.agents where slug <> ag order by slug limit 1;
  select id into vid from public.ventures limit 1;
  update public.system_state set kill_switch = false, mode = 'auto_in_caps' where id = 1;
  delete from public.action_log where action = 'send_email';
  for o in select 1 limit 0 loop end loop;
  insert into public.outbox (venture_id, agent, channel, to_ref, body, status) values (vid, ag, 'email', 'n1@example.com', 'Subject: x'||E'\nhi', 'draft') returning id into o;
  update public.outbox set status = 'qa_passed', qa_agent = ag2 where id = o; update public.outbox set status = 'approved' where id = o;
  insert into public.outbox (venture_id, agent, channel, to_ref, body, status) values (vid, ag, 'email', 'n2@example.com', 'Subject: x'||E'\nhi', 'draft') returning id into o2;
  update public.outbox set status = 'qa_passed', qa_agent = ag2 where id = o2; update public.outbox set status = 'approved' where id = o2;
  insert into public.outbox (venture_id, agent, channel, to_ref, body, status) values (vid, ag, 'email', 'n3@example.com', 'Subject: x'||E'\nhi', 'draft') returning id into o3;
  update public.outbox set status = 'qa_passed', qa_agent = ag2 where id = o3; update public.outbox set status = 'approved' where id = o3;

  -- N1 an allow row written for outbox row o is NOT consumed by sending o2: o2 must do its own authorization
  r := public.authorize_action(ag, 'send_email', 0, o::text);
  update public.outbox set status = 'sent', sent_at = now() where id = o2;
  select count(*) into claimed from public.action_log where ref = o::text and result = 'sent';
  select count(*) into n from public.action_log where ref = o2::text and decision = 'allow';
  insert into neg values ('N1 foreign allow row not consumed', case when claimed = 0 and n = 1 then 'ok' else format('FAIL claimed=%s own_rows=%s', claimed, n) end);

  -- N2 stale allow row (older than 30 min) is not claimable: the trigger authorizes afresh (a second allow row appears)
  r := public.authorize_action(ag, 'send_email', 0, o3::text);
  update public.action_log set at = now() - interval '31 minutes' where ref = o3::text;
  update public.outbox set status = 'sent', sent_at = now() where id = o3;
  select count(*) into claimed from public.action_log where ref = o3::text and result = 'sent';
  select count(*) into n from public.action_log where ref = o3::text and decision = 'allow';
  insert into neg values ('N2 stale allow row not claimable', case when claimed = 0 and n = 2 then 'ok' else format('FAIL claimed=%s rows=%s', claimed, n) end);

  -- N3 kill switch beats a claimable allow row
  update public.outbox set status = 'approved', sent_at = null where id = o;   -- (reset so the next update is a fresh approved->sent)
  update public.system_state set kill_switch = true where id = 1;
  begin update public.outbox set status = 'sent', sent_at = now() where id = o; insert into neg values ('N3 kill switch with allow row', 'FAIL: sent');
  exception when others then insert into neg values ('N3 kill switch with allow row', case when sqlerrm ~* 'kill switch' then 'ok' else 'FAIL ' || sqlerrm end); end;
  update public.system_state set kill_switch = false where id = 1;

  -- N4 dry-run flipped after the allow row was written: refused at mark time
  update public.system_state set mode = 'dry_run' where id = 1;
  begin update public.outbox set status = 'sent', sent_at = now() where id = o; insert into neg values ('N4 dry-run flipped after allow', 'FAIL: sent');
  exception when others then insert into neg values ('N4 dry-run flipped after allow', case when sqlerrm ~* 'dry.run' then 'ok' else 'FAIL ' || sqlerrm end); end;
  update public.system_state set mode = 'auto_in_caps' where id = 1;

  -- N5 the legitimate claim works once and is marked used
  update public.outbox set status = 'sent', sent_at = now() where id = o;
  select count(*) into claimed from public.action_log where ref = o::text and result = 'sent';
  insert into neg values ('N5 own allow row claimed once', case when claimed = 1 then 'ok' else 'FAIL claimed=' || claimed end);

  -- N6 the claim is single-use: sending the same row again needs a fresh authorization (a new allow row appears)
  update public.outbox set status = 'approved', sent_at = null where id = o;
  update public.outbox set status = 'sent', sent_at = now() where id = o;
  select count(*) into n from public.action_log where ref = o::text and decision = 'allow';
  select count(*) into claimed from public.action_log where ref = o::text and result = 'sent';
  insert into neg values ('N6 claim is single-use', case when n = 2 and claimed = 1 then 'ok' else format('FAIL rows=%s claimed=%s', n, claimed) end);
end $$;
select step || ' => ' || detail from neg order by ctid;
rollback;
