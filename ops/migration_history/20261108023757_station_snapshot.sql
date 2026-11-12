create or replace function public.station_snapshot() returns jsonb
language sql stable security definer set search_path = public as $$
  with day as (select (date_trunc('day', now() at time zone 'America/Toronto') at time zone 'America/Toronto') as start),
  doing as (select assigned_agent, title, updated_at from tasks where status = 'doing'),
  todo as (select assigned_agent, count(*) n from tasks where status = 'todo' group by 1),
  last_done as (select distinct on (assigned_agent) assigned_agent, title, updated_at from tasks where status = 'done' order by assigned_agent, updated_at desc),
  spend as (select coalesce(sum(coalesce(actual_cents, reserved_cents)), 0) c from llm_calls, day where started_at >= day.start and status in ('reserved','done')),
  agent_spend as (select agent_slug, coalesce(sum(coalesce(actual_cents, reserved_cents)), 0) c from llm_calls, day where started_at >= day.start and status in ('reserved','done') group by 1)
  select jsonb_build_object(
    'generated_at', now(),
    'heartbeat', (select last_heartbeat from system_state where id = 1),
    'mode', (select mode from system_state where id = 1),
    'kill_switch', (select kill_switch from system_state where id = 1),
    'cap_cents', (select daily_spend_cap_cents from system_state where id = 1),
    'spent_cents', (select c from spend),
    'rooms', (select jsonb_agg(jsonb_build_object('slug', coalesce(v.slug, 'company'), 'name', coalesce(v.name, 'Company'), 'status', coalesce(v.status, 'active')) order by v.slug nulls first)
              from (select distinct venture_id from agents) a left join ventures v on v.id = a.venture_id),
    'agents', (select jsonb_agg(jsonb_build_object(
                 'slug', a.slug, 'room', coalesce(v.slug, 'company'), 'tier', a.model_tier, 'status', a.status,
                 'working', d.title, 'working_since', d.updated_at, 'queued', coalesce(t.n, 0),
                 'last_done', ld.title, 'last_done_at', ld.updated_at,
                 'spent_cents', coalesce(s.c, 0), 'cap_cents', a.daily_spend_cap_cents) order by a.slug)
               from agents a left join ventures v on v.id = a.venture_id
               left join doing d on d.assigned_agent = a.slug left join todo t on t.assigned_agent = a.slug
               left join last_done ld on ld.assigned_agent = a.slug left join agent_spend s on s.agent_slug = a.slug),
    'feed', (select coalesce(jsonb_agg(x order by x->>'at' desc), '[]'::jsonb) from (
               select jsonb_build_object('at', updated_at, 'agent', assigned_agent, 'title', title, 'status', status) x
               from tasks where status in ('done','blocked','doing') order by updated_at desc limit 12) f),
    'approvals', (select count(*) from owner_messages where needs_decision and decision is null),
    'drafts', (select count(*) from outbox where status = 'draft'),
    'leads', (select jsonb_object_agg(coalesce(v.slug, 'none'), c) from (select venture_id, count(*) c from leads where status <> 'duplicate' group by 1) l left join ventures v on v.id = l.venture_id),
    'emailable', (select count(*) from leads where email is not null and do_not_contact = false and status = 'new'),
    'facts', (select count(*) from memory where kind = 'fact' and (expires_at is null or expires_at > now())),
    'decisions', (select count(*) from memory where kind = 'decision' and (expires_at is null or expires_at > now())),
    'ideas', (select count(*) from ideas where status in ('new','testing')),
    'systems', (select coalesce(jsonb_agg(jsonb_build_object('name', name, 'room', venture_slug, 'status', last_status, 'ms', last_ms, 'checked', last_checked_at) order by slug), '[]'::jsonb) from systems where active),
    'revenue_cents', (select coalesce(sum(amount_cents), 0) from ledger where kind = 'revenue')
  );
$$;
revoke all on function public.station_snapshot() from public, anon, authenticated;
select left(public.station_snapshot()::text, 600);