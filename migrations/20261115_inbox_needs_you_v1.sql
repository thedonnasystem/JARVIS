-- Unified "Needs you" inbox: ONE ranked, read-only list of everything waiting on the owner.
--   needs_you(p_limit)      internal (service role only, like app_snapshot_data): the Telegram /needs command and the brief call it.
--   app_needs_you()         owner-checked wrapper for the PWA (same pattern as app_snapshot -> app_snapshot_data). It is created CLOSED
--                           (service role only): opening a function to the signed-in owner means adding its name to the lockdown keep-open
--                           list, which edits an applied migration and needs the owner's sign-off. The ready-to-apply change is
--                           ops/pending_signoff/inbox_open_app_needs_you.patch (see WEBAPP.md). Until then the PWA Inbox falls back to the
--                           data app_snapshot already returns. NEVER callable by anon.
-- It only READS. Approving/rejecting/answering still goes through the existing decision path (app_send kind decision/answer/mission
-- -> hq_commands.apply_decision / apply_answer / hq_missions.set_status). Nothing here changes spend controls, caps, policy or kill switch.
--
-- Sources (each is de-duplicated against the pending owner_messages that already carry its Approve/Reject buttons):
--   approval        owner_messages needs_decision, undecided        (stale ones - request no longer pending - are dropped)
--   question        owner_messages with options, unanswered         (Task Brief)
--   alert           owner_messages kind emergency/health, last 24h  (what ops_alerts() queues)
--   mission         missions status 'blocked'                        (resume / abandon)
--   escalation      escalations 'sent_to_owner' with no pending message
--   proposal        org_changes 'proposed' and ventures 'proposed' with no pending message
--   payment         payment_instructions approved (you pay) or awaiting_owner with no pending message
--   account         account_requests awaiting_owner / approved (you create it)
--   draft           outbox draft/qa_passed (review) or approved (send it) with no pending message
--   task            blocked tasks that are not part of a mission, last 3 days, not just waiting on API credit
--   expiring        approval_requests about to expire with no message; ideas whose 7-day test has ended
-- Ranking: score = base per kind + up to 10 for age (1 point per 12h) + expiry bump; ties oldest first. Returns a jsonb array.

create or replace function public.needs_you(p_limit int default 50) returns jsonb
language plpgsql stable security definer set search_path to 'public' as $$
declare r jsonb; v_lim int := greatest(1, least(coalesce(p_limit, 50), 200));
begin
  with pend as (
    select ref_table, ref_id from owner_messages where needs_decision and decision is null and ref_table is not null),
  raw(kind, ref_table, ref_id, title, created_at, expires_at, why, base, action, actions, command) as (
    -- approvals ---------------------------------------------------------------------------------------------------------
    select 'approval', 'owner_messages', o.id::text,
           left(coalesce(nullif(split_part(o.body, E'\n', 1), ''), o.kind), 140), o.created_at,
           (select ar.expires_at from approval_requests ar where o.ref_table = 'approval_requests' and ar.id = o.ref_id),
           case when o.ref_table = 'approval_requests' then 'An agent asked to take a restricted action; it happens once, only if you approve'
                when o.ref_table = 'payment_instructions' then 'A payment you would make yourself; approving reserves the funds'
                when o.ref_table = 'account_requests' then 'An account an agent wants you to create'
                when o.ref_table = 'org_changes' then 'A change to the company (agent, tool, workflow or shutdown)'
                when o.ref_table = 'outbox' then 'An outreach draft; approving does not send it, you send it yourself'
                when o.ref_table = 'escalations' then 'An agent escalated this and Jarvis could not close it'
                when o.ref_table like 'activate_venture:%' then 'A venture waiting for you to switch it on'
                when o.ref_table like 'set_cap:%' then 'A proposal to change the daily AI budget'
                else 'Waiting for your Approve or Reject (' || o.kind || ')' end,
           80 + case when o.ref_table in ('approval_requests', 'payment_instructions', 'account_requests') then 10 else 0 end,
           'approve_or_reject',
           jsonb_build_array(
             jsonb_build_object('verb', 'approve', 'label', 'Approve', 'kind', 'decision', 'payload', jsonb_build_object('msg_id', o.id, 'approved', true)),
             jsonb_build_object('verb', 'reject', 'label', 'Reject', 'kind', 'decision', 'payload', jsonb_build_object('msg_id', o.id, 'approved', false))),
           null::text
      from owner_messages o
     where o.needs_decision and o.decision is null and o.options is null
       and case o.ref_table
             when 'approval_requests' then exists (select 1 from approval_requests a where a.id = o.ref_id and a.status = 'pending' and a.expires_at > now())
             when 'payment_instructions' then exists (select 1 from payment_instructions p where p.id = o.ref_id and p.status = 'awaiting_owner')
             when 'org_changes' then exists (select 1 from org_changes c where c.id = o.ref_id and c.status = 'proposed')
             when 'escalations' then exists (select 1 from escalations e where e.id = o.ref_id and e.status not in ('closed', 'resolved'))
             else true end
    union all
    -- questions (Task Brief options) ------------------------------------------------------------------------------------------
    select 'question', 'owner_messages', o.id::text, left(coalesce(nullif(split_part(o.body, E'\n', 1), ''), o.kind), 140), o.created_at, null,
           'A task is paused until you pick an option', 65, 'answer',
           (select jsonb_agg(jsonb_build_object('verb', 'answer', 'label', left(case when jsonb_typeof(x.v) = 'string' then x.v #>> '{}' else coalesce(x.v->>'label', x.v->>'title', 'Option ' || x.i) end, 60),
                                                'kind', 'answer', 'payload', jsonb_build_object('msg_id', o.id, 'idx', x.i - 1)) order by x.i)
              from jsonb_array_elements(o.options) with ordinality as x(v, i)),
           null
      from owner_messages o
     where o.options is not null and jsonb_typeof(o.options) = 'array' and jsonb_array_length(o.options) > 0 and o.answer is null
    union all
    -- important alerts (ops_alerts() queues these as owner_messages kind health; emergencies come from the engine) ----------------
    select 'alert', 'owner_messages', a.id::text, left(regexp_replace(a.body, '^ALERT: ', ''), 140), a.created_at, null,
           case when a.kind = 'emergency' then 'Emergency from HQ' else 'HQ health alert (repeats are suppressed for a few hours)' end,
           case when a.kind = 'emergency' then 100 else 70 end, 'review', '[]'::jsonb, null
      from (select distinct on (body) * from owner_messages
             where kind in ('emergency', 'health') and not needs_decision and options is null and created_at > now() - interval '24 hours'
             order by body, created_at desc) a
    union all
    -- blocked missions ----------------------------------------------------------------------------------------------------------
    select 'mission', 'missions', m.id::text, left(regexp_replace(m.title, '^Mission: ', ''), 140), coalesce(m.last_progress_at, m.updated_at), null,
           coalesce(nullif(left(m.next_action, 200), ''), 'Blocked; a failed step needs you'), 60, 'resume_or_abandon',
           jsonb_build_array(
             jsonb_build_object('verb', 'resume', 'label', 'Resume', 'kind', 'mission', 'payload', jsonb_build_object('verb', 'resume', 'id', m.id)),
             jsonb_build_object('verb', 'abandon', 'label', 'Abandon', 'kind', 'mission', 'confirm', true, 'payload', jsonb_build_object('verb', 'abandon', 'id', m.id))),
           '/mission retry ' || left(m.id::text, 8)
      from missions m where m.status = 'blocked'
    union all
    -- escalations that reached the owner and have no Approve/Reject message pending ------------------------------------------------------
    select 'escalation', 'escalations', e.id::text, left(e.summary, 140), e.created_at, null,
           'From ' || e.from_agent || ': ' || e.kind || '. ' || coalesce(left(e.resolution, 160), 'Jarvis passed it to you'), 55, 'review', '[]'::jsonb, null
      from escalations e
     where e.status = 'sent_to_owner'
       and not exists (select 1 from pend p where p.ref_table = 'escalations' and p.ref_id = e.id)
    union all
    -- proposals -----------------------------------------------------------------------------------------------------------------------
    select 'proposal', 'org_changes', c.id::text, left(c.change, 140), c.created_at, null,
           'Proposed ' || c.kind || ' by ' || c.proposed_by || coalesce('. Gain: ' || left(c.gain, 100), '') || coalesce('. Cost: ' || left(c.cost, 60), ''), 50, 'review', '[]'::jsonb, null
      from org_changes c
     where c.status = 'proposed' and not exists (select 1 from pend p where p.ref_table = 'org_changes' and p.ref_id = c.id)
       and (c.owner_message_id is null or not exists (select 1 from owner_messages m2 where m2.id = c.owner_message_id and m2.needs_decision and m2.decision is null))
    union all
    select 'proposal', 'ventures', v.id::text, left(v.name, 140), v.created_at, null,
           'Venture set up but switched off until you approve it', 50, 'review', '[]'::jsonb, '/venture activate ' || v.slug
      from ventures v
     where v.status = 'proposed' and not exists (select 1 from pend p where p.ref_table = 'activate_venture:' || v.slug)
    union all
    -- payments ------------------------------------------------------------------------------------------------------------------------
    select 'payment', 'payment_instructions', p.id::text, '$' || to_char(p.amount_cents / 100.0, 'FM999,990.00') || ' to ' || p.payee, p.created_at,
           case when p.due_on is not null then (p.due_on::timestamp at time zone 'America/Toronto') end,
           case when p.status = 'approved' then 'Approved: pay it in RBC yourself, then confirm with the reference' else 'Waiting for your OK' end
             || ' (' || left(p.purpose, 100) || ')' || coalesce('. Due ' || p.due_on, ''),
           case when p.status = 'approved' then 75 else 70 end, case when p.status = 'approved' then 'pay' else 'review' end, '[]'::jsonb,
           case when p.status = 'approved' then '/pay done ' || left(p.id::text, 8) || ' <amount> <reference>' else '/pay' end
      from payment_instructions p
     where p.status = 'approved'
        or (p.status = 'awaiting_owner' and not exists (select 1 from pend x where x.ref_table = 'payment_instructions' and x.ref_id = p.id))
    union all
    -- accounts ------------------------------------------------------------------------------------------------------------------------
    select 'account', 'account_requests', a.id::text, a.vendor || ': ' || left(a.purpose, 100), a.created_at, null,
           case when a.status = 'approved' then 'Approved: sign up yourself' || coalesce(' (needs ' || array_to_string(a.needs, ', ') || ')', '') || ', then confirm'
                else 'Waiting for your OK' end,
           case when a.status = 'approved' then 55 else 45 end, case when a.status = 'approved' then 'create' else 'review' end, '[]'::jsonb,
           case when a.status = 'approved' then '/account done ' || left(a.id::text, 8) || ' <login>' else '/account' end
      from account_requests a
     where a.status = 'approved'
        or (a.status = 'awaiting_owner' and not exists (select 1 from pend x where x.ref_table = 'account_requests' and x.ref_id = a.id))
    union all
    -- outreach drafts -------------------------------------------------------------------------------------------------------------------
    select 'draft', 'outbox', b.id::text, left('To ' || coalesce(b.to_ref, 'unknown') || ': ' || regexp_replace(b.body, '\s+', ' ', 'g'), 140), b.created_at, null,
           case when b.status = 'approved' then 'Approved: send it from your business email, then mark it sent' else 'Outreach draft waiting for your review' end,
           case when b.status = 'approved' then 60 else 40 end, case when b.status = 'approved' then 'send' else 'review' end, '[]'::jsonb,
           case when b.status = 'approved' then '/sent ' || left(b.id::text, 8) else '/drafts' end
      from outbox b
     where b.status = 'approved'
        or (b.status in ('draft', 'qa_passed') and not exists (select 1 from pend x where x.ref_table = 'outbox' and x.ref_id = b.id))
    union all
    -- blocked tasks outside missions (missions are listed above) -----------------------------------------------------------------------------
    select 'task', 'tasks', t.id::text, left(t.title, 140), t.updated_at, null,
           coalesce('Blocked: ' || nullif(left(regexp_replace(coalesce(t.result, ''), '\s+', ' ', 'g'), 160), ''), 'Blocked'), 30, 'review', '[]'::jsonb, null
      from tasks t
     where t.status = 'blocked' and t.mission_id is null and t.updated_at > now() - interval '3 days'
       and coalesce(t.result, '') not ilike '%credit balance is too low%'
    union all
    -- expiring: a request that lapses with no message carrying its buttons, and finished idea tests -------------------------------------------
    select 'expiring', 'approval_requests', ar.id::text, left(ar.action || ' by ' || ar.actor, 140), ar.created_at, ar.expires_at,
           'Expires ' || to_char(ar.expires_at at time zone 'America/Toronto', 'Mon DD HH24:MI') || '; ' || left(ar.recommendation, 120), 85, 'review', '[]'::jsonb, null
      from approval_requests ar
     where ar.status = 'pending' and ar.expires_at > now() and ar.expires_at < now() + interval '48 hours'
       and not exists (select 1 from pend p where p.ref_table = 'approval_requests' and p.ref_id = ar.id)
    union all
    select 'expiring', 'ideas', i.id::text, left(i.name, 140), i.test_ends_on::timestamp at time zone 'America/Toronto', i.test_ends_on::timestamp at time zone 'America/Toronto',
           '7-day test ended ' || i.test_ends_on || '; decide: scale or park' || coalesce(' (kill if: ' || left(i.kill_metric, 80) || ')', ''), 62, 'review', '[]'::jsonb, '/ideas'
      from ideas i where i.status = 'testing' and i.test_ends_on is not null and i.test_ends_on <= (now() at time zone 'America/Toronto')::date),
  scored as (
    select raw.*, greatest(0, extract(epoch from now() - raw.created_at) / 60)::bigint age_minutes,
           raw.base + least(10, (greatest(0, extract(epoch from now() - raw.created_at)) / 43200)::int)
                    + case when raw.expires_at is not null and raw.expires_at <= now() + interval '24 hours' then 15
                           when raw.expires_at is not null and raw.expires_at <= now() + interval '48 hours' then 8 else 0 end score
      from raw),
  capped as (select s.*, row_number() over (partition by s.kind order by s.score desc, s.created_at) k_n from scored s),
  ranked as (select c.*, row_number() over (order by c.score desc, c.created_at asc, c.ref_id) rn from capped c where c.k_n <= case c.kind when 'task' then 8 when 'alert' then 5 else 25 end)
  select coalesce(jsonb_agg(jsonb_build_object(
           'rank', rn, 'kind', kind, 'ref_table', ref_table, 'ref_id', ref_id, 'title', title, 'created_at', created_at,
           'age_minutes', age_minutes, 'why', why, 'score', score, 'expires_at', expires_at, 'action', action,
           'actions', coalesce(actions, '[]'::jsonb), 'command', command) order by rn), '[]'::jsonb)
    into r from ranked where rn <= v_lim;
  return r;
end $$;
revoke all on function public.needs_you(int) from public, anon, authenticated;
grant execute on function public.needs_you(int) to service_role;

create or replace function public.app_needs_you() returns jsonb
language plpgsql stable security definer set search_path to 'public' as $$
begin
  if not public.is_app_owner() then raise exception 'not authorized' using errcode = '42501'; end if;
  return public.needs_you(50);
end $$;
revoke all on function public.app_needs_you() from public, anon, authenticated;
grant execute on function public.app_needs_you() to service_role;
