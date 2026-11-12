create or replace function public.queue_prospect_task() returns uuid
language plpgsql security definer set search_path = public as $$
declare v_id uuid; v_areas text[] := array['Ottawa east (Orleans, Gloucester)','Ottawa west (Kanata, Stittsville, Nepean)','Ottawa south (Barrhaven, Manotick)',
  'Kingston','Belleville and Quinte','Peterborough','Barrie','Oshawa and Whitby','Hamilton','Kitchener-Waterloo','London ON','Windsor','Sudbury','North Bay'];
  v_area text; v_trade text;
begin
  if not exists (select 1 from agents where slug = 'donna-researcher' and status = 'active') then return null; end if;
  if exists (select 1 from tasks where title like 'Find Donna prospects%' and status in ('todo','doing')) then return null; end if;
  if (select count(*) from leads l join ventures v on v.id = l.venture_id where v.slug = 'donna' and l.status = 'new' and l.email is not null) >= 15 then
    return null;  -- enough unworked emailable leads; don't pay to find more yet
  end if;
  v_area := v_areas[1 + (extract(doy from now())::int % array_length(v_areas, 1))];
  v_trade := (array['HVAC','plumbing','electrical'])[1 + (extract(doy from now())::int % 3)];
  insert into tasks (venture_id, assigned_agent, created_by, title, detail, status, priority)
  values ((select id from ventures where slug = 'donna'), 'donna-researcher', 'system',
          format('Find Donna prospects: %s contractors, %s', v_trade, v_area),
          format('Find up to 12 established %s contractors in %s (several trucks or staff, 50+ reviews, phone-driven intake) that would lose jobs to missed calls. For each, OPEN its own website contact page and record the business email it publishes (info@, office@, service@). Skip any business whose site has no published email, and note if the site says no unsolicited messages. Skip franchises of national chains. Output the LEADS section first.', v_trade, v_area),
          'todo', 3)
  returning id into v_id;
  return v_id;
end $$;
revoke all on function public.queue_prospect_task() from public, anon, authenticated;
select cron.schedule('hq-donna-prospects', '15 15 * * *', $$select public.queue_prospect_task()$$);