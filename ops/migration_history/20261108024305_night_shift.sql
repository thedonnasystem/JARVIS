alter table public.system_state
  add column if not exists night_until timestamptz,
  add column if not exists night_started_at timestamptz,
  add column if not exists day_cap_cents int;
grant execute on function public.queue_prospect_task() to service_role;
grant execute on function public.queue_valuation_task() to service_role;
grant execute on function public.queue_outreach_drafts() to service_role;
create or replace function public.night_shift_report(p_since timestamptz) returns text
language sql stable security definer set search_path = public as $$
  with t as (
    select title, assigned_agent, status, updated_at,
           (select coalesce(sum(coalesce(actual_cents, reserved_cents)), 0) from llm_calls l
             where l.purpose = 'task ' || tasks.id::text and l.started_at >= p_since) cents
    from tasks where updated_at >= p_since and status in ('done','blocked','cancelled')
  )
  select format(E'Night Shift report (since %s):\n%s\nTotal AI spend overnight: $%s.',
    to_char(p_since at time zone 'America/Toronto', 'HH24:MI'),
    coalesce((select string_agg(format('- %s %s: %s ($%s)', upper(status), assigned_agent, left(title, 70), to_char(cents/100.0, 'FM990.00')), E'\n' order by updated_at) from t), '- nothing ran'),
    to_char((select coalesce(sum(coalesce(actual_cents, reserved_cents)), 0) from llm_calls where started_at >= p_since and status in ('done','reserved'))/100.0, 'FM990.00'));
$$;
revoke all on function public.night_shift_report(timestamptz) from public, anon, authenticated;
grant execute on function public.night_shift_report(timestamptz) to service_role;