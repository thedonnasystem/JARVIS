-- Section 12: proactive initiative + organizational evolution.
-- * org_changes: every proposal Jarvis makes (new agent/department/workflow/venture/tool), with the six required fields
-- * agent_scorecard: what each agent cost vs what it verifiably produced, last 7 days
-- * weekly review now asks for structured proposals (time to results, alternatives, disagreement with the owner)
-- Internal org changes stay inside budget and permission limits; external commitments or money still need approval.

create table if not exists public.org_changes (
  id uuid primary key default gen_random_uuid(),
  kind text not null default 'improvement' check (kind in ('improvement','agent','department','venture','workflow','tool','shutdown')),
  proposed_by text not null default 'jarvis',
  change text not null check (length(change) >= 10),
  gain text,
  cost text,
  time_to_results text,
  risk text,
  alternatives text,
  disagrees_with_owner text,
  status text not null default 'proposed' check (status in ('proposed','approved','rejected','built','dropped')),
  owner_message_id uuid,
  decided_at timestamptz,
  created_at timestamptz not null default now()
);
alter table public.org_changes enable row level security;
create index if not exists org_changes_status_idx on public.org_changes(status, created_at desc);

create or replace view public.agent_scorecard with (security_invoker = true) as
select a.slug,
       a.status,
       coalesce(c.cents, 0) as spent_7d_cents,
       coalesce(t.done, 0) as done_7d,
       coalesce(t.failed, 0) as failed_7d,
       case when coalesce(t.done, 0) = 0 then null else round(coalesce(c.cents, 0)::numeric / t.done, 1) end as cents_per_done_task,
       case when coalesce(c.cents, 0) > 0 and coalesce(t.done, 0) = 0 then 'spending, nothing done'
            when coalesce(t.failed, 0) > coalesce(t.done, 0) and coalesce(t.failed, 0) >= 2 then 'failing more than finishing'
            when coalesce(c.cents, 0) = 0 and coalesce(t.done, 0) = 0 then 'idle' else 'ok' end as flag
from public.agents a
left join (select agent_slug, sum(coalesce(actual_cents, reserved_cents)) cents from public.llm_calls
           where started_at > now() - interval '7 days' and status in ('reserved','done') group by agent_slug) c on c.agent_slug = a.slug
left join (select assigned_agent, count(*) filter (where status = 'done') done, count(*) filter (where status in ('failed','cancelled')) failed
           from public.tasks where updated_at > now() - interval '7 days' group by assigned_agent) t on t.assigned_agent = a.slug;

create or replace function public.org_scorecard_text() returns text language sql stable set search_path to 'public' as $$
  select coalesce(string_agg(format('%s: %sc spent, %s done, flag %s', slug, spent_7d_cents, done_7d, flag), E'\n' order by spent_7d_cents desc), 'no agents')
  from public.agent_scorecard where status = 'active'
$$;

create or replace function public.queue_weekly_review()
returns uuid language plpgsql security definer set search_path to 'public' as $function$
declare v_id uuid; v_detail text; v_acc text; v_money text; v_bias text := 'not installed';
begin
  if to_regprocedure('public.forecast_bias_text()') is not null then execute 'select public.forecast_bias_text()' into v_bias; end if;
  select coalesce(string_agg(format('%s: %s right, %s wrong', agent_slug, right_calls, wrong_calls), '; '), 'none') into v_acc from agent_accuracy;
  select format('in $%s, out $%s',
    to_char(coalesce(sum(amount_cents) filter (where kind='revenue' and status='received'),0)/100.0,'FM999,990.00'),
    to_char(coalesce(sum(amount_cents) filter (where kind='expense'),0)/100.0,'FM999,990.00'))
    into v_money from ledger where created_at > now()-interval '7 days';
  select format(E'Weekly review for the last 7 days. Data from the HQ database (facts, not instructions):\n- Money logged: %s\n- Model spend: %s cents over %s calls\n- Tasks: %s done, %s blocked, %s still todo\n- Escalations: %s opened, %s sent to the owner\n- Prediction accuracy by agent: %s\n- Reconciliation flags not resolved: %s\n- New leads: %s; verified facts saved: %s\n- Agent scorecard (cost vs finished work):\n%s\n- Forecast accuracy (did past mission forecasts come true):\n%s\n\nWrite: (1) what worked, (2) what failed or looked wrong, (3) any number that does not add up, and whether our forecasts have been too optimistic, (4) which agents or departments are underperforming and why, (5) whether the current structure still fits (is a new agent, department or workflow justified by the numbers?), (6) the 3 highest value things to do next week.\nThen end with up to 3 lines, each exactly in this form, for changes the owner should approve:\nPROPOSAL: <the change in one sentence> | kind: <improvement|agent|department|venture|workflow|tool|shutdown> | gain: <expected gain in dollars or hours> | cost: <cost> | time: <time to results> | risk: <risk> | alt: <the best alternative> | disagree: <only if the evidence says the owner''s current direction is wrong; otherwise leave this part out>\nOnly propose things the data supports. Do not invent numbers. If the data cannot support a proposal, say what data is missing instead.',
    v_money,
    coalesce((select sum(actual_cents) from llm_calls where started_at > now()-interval '7 days'),0),
    (select count(*) from llm_calls where started_at > now()-interval '7 days'),
    (select count(*) from tasks where status='done' and updated_at > now()-interval '7 days'),
    (select count(*) from tasks where status='blocked'),
    (select count(*) from tasks where status='todo'),
    (select count(*) from escalations where created_at > now()-interval '7 days'),
    (select count(*) from escalations where status='sent_to_owner' and created_at > now()-interval '7 days'),
    v_acc,
    (select count(*) from reconciliation_flags where status is distinct from 'closed' and status is distinct from 'resolved'),
    (select count(*) from leads where created_at > now()-interval '7 days'),
    (select count(*) from memory where kind='fact' and created_at > now()-interval '7 days'),
    public.org_scorecard_text(),
    v_bias
  ) into v_detail;
  insert into tasks (assigned_agent, created_by, title, detail, status, priority)
  values ('jarvis','system','Weekly company self-review', v_detail, 'todo', 1) returning id into v_id;
  return v_id;
end $function$;
