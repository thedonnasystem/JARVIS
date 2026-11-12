-- Corporate office (spec section 11): the nine functions, each computed from REAL agents, tasks, spend and data.
-- No decorative rows: a function with no agents shows as "unstaffed" and Jarvis can propose to fill it.
alter table public.agents add column if not exists office_function text
  check (office_function is null or office_function in ('executive','bizdev','research','engineering','marketing','sales','finance','operations','agentmgmt'));

create or replace function public.office_function_of(p_slug text, p_override text) returns text
language sql immutable set search_path to 'public' as $$
  select coalesce(p_override, case
    when p_slug in ('jarvis','ceo') then 'executive'
    when p_slug in ('growth','idea-lab-division') or p_slug like 'new-ventures-%' and p_slug not like '%-finance' and p_slug not like '%-auditor' and p_slug not like '%-researcher' then 'bizdev'
    when p_slug = 'research' or p_slug like '%-researcher' then 'research'
    when p_slug = 'builder' then 'engineering'
    when p_slug = 'marketing' then 'marketing'
    when p_slug = 'sales' or p_slug = 'day-job-sales-division' then 'sales'
    when p_slug = 'cfo' or p_slug like '%-finance' then 'finance'
    when p_slug in ('hr','compliance-qa') or p_slug like '%-auditor' then 'agentmgmt'
    else 'operations' end)
$$;

create or replace function public.office_data() returns jsonb
language plpgsql stable security definer set search_path to 'public' as $$
declare v_start timestamptz := date_trunc('day', now() at time zone 'America/Toronto') at time zone 'America/Toronto'; r jsonb;
begin
  with a as (
    select ag.slug, ag.title, ag.status, ag.daily_spend_cap_cents cap, public.office_function_of(ag.slug, ag.office_function) fn,
           (select coalesce(sum(coalesce(c.actual_cents, c.reserved_cents)), 0) from llm_calls c
             where c.agent_slug = ag.slug and c.status in ('reserved','done') and c.started_at >= v_start) spent_today,
           (select coalesce(sum(coalesce(c.actual_cents, c.reserved_cents)), 0) from llm_calls c
             where c.agent_slug = ag.slug and c.status in ('reserved','done') and c.started_at > now() - interval '7 days') spent_7d,
           (select count(*) from tasks t where t.assigned_agent = ag.slug and t.status in ('todo','doing')) open_tasks,
           (select count(*) from tasks t where t.assigned_agent = ag.slug and t.status = 'blocked') blocked,
           (select count(*) from tasks t where t.assigned_agent = ag.slug and t.status = 'done' and t.updated_at > now() - interval '7 days') done_7d
    from agents ag),
  f(fn, name, ord) as (values
    ('executive','Executive Office',1),('bizdev','Business Development',2),('research','Research & Intelligence',3),
    ('engineering','Engineering & Technology',4),('marketing','Marketing & Media',5),('sales','Sales & Customer Acquisition',6),
    ('finance','Finance & Treasury',7),('operations','Operations',8),('agentmgmt','Agent Management',9))
  select jsonb_agg(jsonb_build_object(
    'fn', f.fn, 'name', f.name,
    'staffed', exists (select 1 from a where a.fn = f.fn and a.status = 'active'),
    'agents', (select coalesce(jsonb_agg(jsonb_build_object('slug', a.slug, 'title', a.title, 'status', a.status, 'spent_today', a.spent_today, 'cap', a.cap) order by a.slug), '[]'::jsonb) from a where a.fn = f.fn),
    'open', (select coalesce(sum(open_tasks), 0) from a where a.fn = f.fn),
    'blocked', (select coalesce(sum(blocked), 0) from a where a.fn = f.fn),
    'done_7d', (select coalesce(sum(done_7d), 0) from a where a.fn = f.fn),
    'spent_7d', (select coalesce(sum(spent_7d), 0) from a where a.fn = f.fn),
    'headline', case f.fn
      when 'executive' then format('%s live missions, %s open escalations',
        (select count(*) from missions where status not in ('completed','rejected','abandoned','failed')), (select count(*) from escalations where status not in ('resolved','closed')))
      when 'bizdev' then format('%s ideas in the lab, %s ventures awaiting approval',
        (select count(*) from ideas where status not in ('parked','rejected','killed')), (select count(*) from ventures where status = 'proposed'))
      when 'research' then format('%s facts learned this week', (select count(*) from memory where kind = 'fact' and created_at > now() - interval '7 days'))
      when 'engineering' then format('%s tasks shipped this week', (select coalesce(sum(done_7d), 0) from a where a.fn = 'engineering'))
      when 'marketing' then format('%s tasks done this week', (select coalesce(sum(done_7d), 0) from a where a.fn = 'marketing'))
      when 'sales' then format('%s leads, %s due for follow-up', (select count(*) from leads),
        (select count(*) from leads where next_followup_at <= (now() at time zone 'America/Toronto')::date and not do_not_contact and status <> 'closed'))
      when 'finance' then format('Cash in $%s, out $%s (30 days, received only)',
        to_char((select coalesce(sum(amount_cents) filter (where kind = 'revenue' and status = 'received'), 0) from ledger where created_at > now() - interval '30 days') / 100.0, 'FM999,990.00'),
        to_char((select coalesce(sum(amount_cents) filter (where kind = 'expense'), 0) from ledger where created_at > now() - interval '30 days') / 100.0, 'FM999,990.00'))
      when 'operations' then format('%s blocked tasks, %s tasks waiting', (select count(*) from tasks where status = 'blocked'), (select count(*) from tasks where status = 'todo'))
      when 'agentmgmt' then format('%s agents, %s paused', (select count(*) from a), (select count(*) from a where status <> 'active'))
    end) order by f.ord) into r from f;
  return r;
end $$;
revoke all on function public.office_data() from public, anon, authenticated;

create or replace function public.app_office() returns jsonb
language plpgsql stable security definer set search_path to 'public' as $$
begin
  if not public.is_app_owner() then raise exception 'not authorized' using errcode = '42501'; end if;
  return public.office_data();
end $$;
revoke all on function public.app_office() from public, anon;
grant execute on function public.app_office() to authenticated;
