-- Autonomy ladder evidence (Master Plan: "each message type is promoted only after a measured error rate under a limit Moe sets").
-- This only REPORTS. Nothing is promoted automatically; only the owner changes the mode.
create or replace function public.autonomy_report(p_limit numeric default 0.05, p_min int default 20) returns jsonb
language sql stable set search_path to 'public' as $$
  with d as (
    select channel, count(*) filter (where status in ('approved','sent','rejected') and decided_at is not null) reviewed,
           count(*) filter (where status = 'rejected') rejected,
           count(*) filter (where status in ('approved','sent') and decided_at is not null) accepted
    from public.outbox group by channel)
  select coalesce(jsonb_agg(jsonb_build_object('channel', channel, 'reviewed', reviewed, 'accepted', accepted, 'rejected', rejected,
      'error_rate', case when reviewed > 0 then round(rejected::numeric / reviewed, 3) else null end,
      'eligible', reviewed >= p_min and rejected::numeric / nullif(reviewed, 0) <= p_limit) order by channel), '[]'::jsonb) from d;
$$;
revoke all on function public.autonomy_report(numeric, int) from public, anon, authenticated;
