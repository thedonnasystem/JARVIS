create or replace function public.queue_valuation_task() returns uuid
language plpgsql security definer set search_path = public as $$
declare v_id uuid;
begin
  if not exists (select 1 from agents where slug = 'real-estate-researcher' and status = 'active') then return null; end if;
  if exists (select 1 from tasks where title like 'Value fixer leads%' and status in ('todo','doing')) then return null; end if;
  insert into tasks (venture_id, assigned_agent, created_by, title, detail, status, priority)
  values ('d50c02c1-0256-49eb-816b-c720d12944cb', 'real-estate-researcher', 'system',
          'Value fixer leads ' || to_char(now() at time zone 'America/Toronto', 'YYYY-MM-DD'),
          'Value the deal-funnel leads attached below so the funnel can tell which ones have room for a $15k assignment fee. Research only.',
          'todo', 2)
  returning id into v_id;
  return v_id;
end $$;
revoke all on function public.queue_valuation_task() from public, anon, authenticated;
select cron.schedule('hq-value-fixers', '45 14 * * *', $$select public.queue_valuation_task()$$);