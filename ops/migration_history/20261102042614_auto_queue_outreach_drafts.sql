create or replace function public.queue_outreach_drafts() returns int
language plpgsql security definer set search_path = public as $$
declare r record; n int := 0;
begin
  for r in
    select v.id venture_id, v.slug, count(*) ready
    from leads l join ventures v on v.id = l.venture_id
    where l.status = 'new' and l.do_not_contact = false and l.email is not null and v.status = 'active'
    group by v.id, v.slug having count(*) >= 3
  loop
    -- one pending draft task per venture at a time, and only if its GM agent is active
    if exists (select 1 from tasks where venture_id = r.venture_id and title like 'Draft outreach%' and status in ('todo','doing')) then continue; end if;
    if not exists (select 1 from agents where slug = r.slug || '-division' and status = 'active') then continue; end if;
    insert into tasks (venture_id, assigned_agent, created_by, title, detail, status, priority)
    values (r.venture_id, r.slug || '-division', 'system', 'Draft outreach for new ' || r.slug || ' leads',
            format('%s emailable leads are waiting. Write one short email per lead using the venture''s offer and call to action from company knowledge. Personalize each email with one specific detail from the lead notes. Research or drafting only: nothing is sent without owner approval.', r.ready),
            'todo', 2);
    n := n + 1;
  end loop;
  return n;
end $$;
revoke all on function public.queue_outreach_drafts() from public, anon, authenticated;
select cron.schedule('hq-queue-drafts', '7,37 * * * *', $$select public.queue_outreach_drafts()$$);