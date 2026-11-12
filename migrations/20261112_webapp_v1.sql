-- FENDEZY HQ web app (private PWA) backend. Additive. No new infrastructure: Supabase Auth + owner-only functions.
-- Tables stay locked (RLS on, no policies). The app can ONLY call the app_* functions below, and every one of
-- them first checks that the caller is a signed-in, email-verified user whose email is in app_owners.
-- Add the owner after applying:  insert into public.app_owners(email) values ('<owner email>');

create table if not exists public.app_owners (email text primary key, added_at timestamptz not null default now());
alter table public.app_owners enable row level security;

create table if not exists public.web_messages (
  id uuid primary key default gen_random_uuid(),
  role text not null check (role in ('owner','jarvis')),
  kind text not null default 'chat' check (kind in ('chat','decision','answer','mission','bank','venture','system')),
  body text not null default '' check (length(body) <= 12000),
  payload jsonb not null default '{}'::jsonb,
  status text not null default 'new' check (status in ('new','processing','done','failed')),
  reply_to uuid,
  created_at timestamptz not null default now()
);
alter table public.web_messages enable row level security;
create index if not exists web_messages_new on public.web_messages(created_at) where status = 'new';
create index if not exists web_messages_created on public.web_messages(created_at desc);

create or replace function public.is_app_owner()
returns boolean language sql stable security definer set search_path to 'public' as $$
  select exists (
    select 1 from auth.users u join public.app_owners o on lower(o.email) = lower(u.email)
    where u.id = auth.uid() and u.email_confirmed_at is not null);
$$;

-- Everything the app shows, in one call. Internal: not callable by the app directly.
create or replace function public.app_snapshot_data()
returns jsonb language plpgsql stable security definer set search_path to 'public' as $$
declare v_start timestamptz := date_trunc('day', now() at time zone 'America/Toronto') at time zone 'America/Toronto';
        v_capital jsonb; v_policy jsonb; v_alerts jsonb := '[]'::jsonb; v_pnl jsonb; v_score jsonb; v_org jsonb; v_stage jsonb := '{}'::jsonb; out_ jsonb;
begin
  if to_regprocedure('public.capital_snapshot()') is not null then
    execute 'select public.capital_snapshot()' into v_capital;
  end if;
  if to_regclass('public.action_policy') is not null then
    execute $q$select jsonb_agg(jsonb_build_object('action',action,'tier',tier,'each',max_cents_per_action,'day',max_count_per_day,'week',max_cents_per_week) order by tier, action) from public.action_policy$q$ into v_policy;
  end if;
  if to_regprocedure('public.bank_alerts()') is not null then
    execute 'select public.bank_alerts()' into v_alerts;
  end if;
  if to_regclass('public.agent_scorecard') is not null then
    execute $q$select coalesce(jsonb_object_agg(slug, jsonb_build_object('flag', flag, 'cents_per_done', cents_per_done, 'done_7d', done_7d)), '{}'::jsonb) from public.agent_scorecard$q$ into v_score;
  end if;
  if to_regclass('public.org_changes') is not null then
    execute $q$select coalesce(jsonb_agg(jsonb_build_object('kind', kind, 'change', left(change, 200), 'status', status, 'gain', gain, 'cost', cost, 'at', created_at) order by created_at desc), '[]'::jsonb)
                from (select * from public.org_changes order by created_at desc limit 12) o$q$ into v_org;
  end if;
  if to_regprocedure('public.holding_pnl(integer)') is not null then
    execute 'select public.holding_pnl(30)' into v_pnl;
  end if;
  if exists (select 1 from information_schema.columns where table_schema='public' and table_name='ventures' and column_name='stage') then
    execute $q$select coalesce(jsonb_object_agg(slug, stage), '{}'::jsonb) from public.ventures$q$ into v_stage;
  end if;
  select jsonb_build_object(
    'now', now(),
    'bank_alerts', coalesce(v_alerts, '[]'::jsonb),
    'pnl', v_pnl,
    'scorecard', coalesce(v_score, '{}'::jsonb),
    'org_changes', coalesce(v_org, '[]'::jsonb),
    'venture_stage', v_stage,
    'state', (select jsonb_build_object('mode', mode, 'kill_switch', kill_switch, 'pause_reason', pause_reason,
                'paused_at', paused_at, 'cap_cents', daily_spend_cap_cents, 'last_heartbeat', last_heartbeat,
                'night_until', night_until) from system_state where id = 1),
    'spend_today_cents', (select coalesce(sum(coalesce(actual_cents, reserved_cents)),0) from llm_calls
                          where started_at >= v_start and status in ('reserved','done')),
    'spend_7d', (select coalesce(jsonb_agg(jsonb_build_object('d', d, 'c', c) order by d), '[]'::jsonb) from (
                   select (started_at at time zone 'America/Toronto')::date d, sum(coalesce(actual_cents, reserved_cents)) c
                   from llm_calls where status in ('reserved','done') and started_at > now() - interval '7 days' group by 1) x),
    'capital', v_capital,
    'policy', v_policy,
    'ventures', (select coalesce(jsonb_agg(jsonb_build_object('slug', v.slug, 'name', v.name, 'status', v.status,
                   'in_cents', coalesce(l.rev,0), 'out_cents', coalesce(l.exp,0), 'expected_cents', coalesce(l.pend,0),
                   'agents', (select count(*) from agents a where a.venture_id = v.id and a.status = 'active'),
                   'leads', (select count(*) from leads ld where ld.venture_id = v.id),
                   'ai_cents_7d', (select coalesce(sum(coalesce(c.actual_cents, c.reserved_cents)),0) from llm_calls c
                                   join agents a on a.slug = c.agent_slug
                                   where a.venture_id = v.id and c.status in ('reserved','done') and c.started_at > now() - interval '7 days'))
                   order by v.name), '[]'::jsonb)
                 from ventures v left join lateral (
                   select sum(amount_cents) filter (where kind='revenue' and status='received') rev,
                          sum(amount_cents) filter (where kind='expense' and status='received') exp,
                          sum(amount_cents) filter (where kind='revenue' and status<>'received') pend
                   from ledger where venture_id = v.id) l on true
                 where v.status in ('active','proposed')),
    'missions', (select coalesce(jsonb_agg(jsonb_build_object('id', m.id, 'title', m.title, 'status', m.status,
                   'verdict', m.verdict, 'verdict_reason', m.verdict_reason, 'objective', left(m.objective, 600),
                   'success', m.success_definition, 'risks', m.risks, 'next_action', m.next_action,
                   'budget_cents', m.budget_cents, 'spent_cents', public.mission_spent_cents(m.id),
                   'expected_cad', m.expected_cad, 'days_to_cash', m.days_to_cash, 'attempts', m.attempts,
                   'plan', m.plan, 'evidence', m.evidence, 'result', m.result, 'updated_at', m.updated_at)
                   order by (m.status in ('completed','rejected','abandoned','failed')), m.priority, m.created_at desc), '[]'::jsonb)
                 from (select * from missions order by created_at desc limit 30) m),
    'agents', (select coalesce(jsonb_agg(jsonb_build_object('slug', a.slug, 'title', a.title, 'role', a.role,
                 'status', a.status, 'tier', a.model_tier, 'cap_cents', a.daily_spend_cap_cents, 'metric', a.metric,
                 'venture', (select slug from ventures v where v.id = a.venture_id),
                 'spent_today', (select coalesce(sum(coalesce(c.actual_cents, c.reserved_cents)),0) from llm_calls c
                                 where c.agent_slug = a.slug and c.status in ('reserved','done') and c.started_at >= v_start),
                 'done_7d', (select count(*) from tasks t where t.assigned_agent = a.slug and t.status = 'done' and t.updated_at > now() - interval '7 days'),
                 'open', (select count(*) from tasks t where t.assigned_agent = a.slug and t.status in ('todo','doing')),
                 'last_task', (select left(t.title, 90) from tasks t where t.assigned_agent = a.slug order by t.updated_at desc limit 1))
                 order by a.slug), '[]'::jsonb) from agents a),
    'needs_you', (select coalesce(jsonb_agg(jsonb_build_object('id', o.id, 'kind', o.kind, 'body', o.body,
                    'options', o.options, 'needs_decision', o.needs_decision, 'created_at', o.created_at) order by o.created_at desc), '[]'::jsonb)
                  from owner_messages o
                  where (o.needs_decision and o.decision is null) or (o.options is not null and o.answer is null)),
    'feed', (select coalesce(jsonb_agg(f order by f->>'at' desc), '[]'::jsonb) from (
               (select jsonb_build_object('at', t.updated_at, 'type', 'task', 'who', t.assigned_agent,
                        'text', t.title, 'status', t.status) f
                from tasks t where t.status in ('done','blocked') order by t.updated_at desc limit 20)
               union all
               (select jsonb_build_object('at', o.created_at, 'type', 'message', 'who', o.from_agent,
                        'text', left(o.body, 240), 'status', o.kind)
                from owner_messages o order by o.created_at desc limit 15)
               union all
               (select jsonb_build_object('at', a.at, 'type', 'audit', 'who', a.actor, 'text', a.action || coalesce(' ' || a.target, ''), 'status', 'log')
                from audit_log a where a.action not in ('llm_call','llm_call_failed') order by a.at desc limit 15)) q),
    'tasks', (select jsonb_build_object('todo', count(*) filter (where status='todo'), 'doing', count(*) filter (where status='doing'),
                'blocked', count(*) filter (where status='blocked'), 'done_24h', count(*) filter (where status='done' and updated_at > now() - interval '24 hours')) from tasks),
    'leads', (select jsonb_build_object('total', count(*), 'new_24h', count(*) filter (where created_at > now() - interval '24 hours'),
                'due', count(*) filter (where next_followup_at <= now() and not do_not_contact)) from leads),
    'drafts', (select coalesce(jsonb_agg(jsonb_build_object('id', o.id, 'to', o.to_ref, 'body', left(o.body, 900), 'agent', o.agent, 'created_at', o.created_at)
                 order by o.created_at desc), '[]'::jsonb) from (select * from outbox where status in ('draft','qa_passed') order by created_at desc limit 20) o),
    'ideas', (select coalesce(jsonb_agg(jsonb_build_object('name', name, 'status', status, 'score', score, 'verdict', verdict) order by score desc nulls last), '[]'::jsonb)
              from (select * from ideas where status in ('new','testing','scaled') order by score desc nulls last limit 10) i),
    'systems', (select coalesce(jsonb_agg(jsonb_build_object('name', name, 'status', last_status, 'checked', last_checked_at, 'url', url) order by name), '[]'::jsonb)
                from systems where active)
  ) into out_;
  return out_;
end $$;

-- ---- what the app may call (each checks the owner first) ----
create or replace function public.app_snapshot() returns jsonb
language plpgsql stable security definer set search_path to 'public' as $$
begin
  if not public.is_app_owner() then raise exception 'not authorized' using errcode = '42501'; end if;
  return public.app_snapshot_data();
end $$;

create or replace function public.app_messages(p_limit int default 60) returns jsonb
language plpgsql stable security definer set search_path to 'public' as $$
begin
  if not public.is_app_owner() then raise exception 'not authorized' using errcode = '42501'; end if;
  return (select coalesce(jsonb_agg(jsonb_build_object('id', id, 'role', role, 'kind', kind, 'body', body, 'status', status,
                    'reply_to', reply_to, 'at', created_at) order by created_at), '[]'::jsonb)
          from (select * from web_messages order by created_at desc limit least(greatest(p_limit, 1), 200)) m);
end $$;

create or replace function public.app_send(p_body text, p_kind text default 'chat', p_payload jsonb default '{}'::jsonb) returns uuid
language plpgsql security definer set search_path to 'public' as $$
declare v_id uuid;
begin
  if not public.is_app_owner() then raise exception 'not authorized' using errcode = '42501'; end if;
  if p_kind not in ('chat','decision','answer','mission','bank','venture') then raise exception 'bad kind'; end if;
  if pg_column_size(coalesce(p_payload, '{}'::jsonb)) > 400000 then raise exception 'payload too large'; end if;
  if p_kind = 'chat' and length(trim(coalesce(p_body, ''))) = 0 then raise exception 'empty message'; end if;
  if (select count(*) from web_messages where role = 'owner' and created_at > now() - interval '1 minute') >= 30 then
    raise exception 'Slow down: 30 messages a minute max.';
  end if;
  insert into web_messages (role, kind, body, payload) values ('owner', p_kind, left(coalesce(p_body, ''), 6000), coalesce(p_payload, '{}'::jsonb))
    returning id into v_id;
  return v_id;
end $$;

create or replace function public.app_set_kill(p_on boolean) returns boolean
language plpgsql security definer set search_path to 'public' as $$
begin
  if not public.is_app_owner() then raise exception 'not authorized' using errcode = '42501'; end if;
  update system_state set kill_switch = p_on where id = 1;
  insert into audit_log (actor, action, target, detail) values ('owner', case when p_on then 'kill_on' else 'kill_off' end, 'system_state', '{"via":"app"}');
  return p_on;
end $$;

create or replace function public.app_set_agent(p_slug text, p_status text) returns text
language plpgsql security definer set search_path to 'public' as $$
begin
  if not public.is_app_owner() then raise exception 'not authorized' using errcode = '42501'; end if;
  if p_status not in ('active','paused') then raise exception 'bad status'; end if;
  update agents set status = p_status where slug = p_slug;
  insert into audit_log (actor, action, target, detail) values ('owner', 'agent_' || p_status, p_slug, '{"via":"app"}');
  return p_status;
end $$;

-- Lock the door: nothing is callable by the public or by signed-in strangers except through the checks above.
revoke all on function public.app_snapshot_data() from public, anon, authenticated;
revoke all on function public.is_app_owner() from public, anon;
revoke all on function public.app_snapshot(), public.app_messages(int), public.app_send(text, text, jsonb),
              public.app_set_kill(boolean), public.app_set_agent(text, text) from public, anon;
grant execute on function public.is_app_owner(), public.app_snapshot(), public.app_messages(int), public.app_send(text, text, jsonb),
              public.app_set_kill(boolean), public.app_set_agent(text, text) to authenticated;
