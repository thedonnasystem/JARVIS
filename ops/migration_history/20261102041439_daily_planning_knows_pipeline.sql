create or replace function public.queue_daily_planning() returns uuid
language plpgsql security definer set search_path to 'public' as $function$
declare v_id uuid; v_detail text; v_done text; v_todo text; v_agents text; v_leads text; v_decisions text; v_drafts int;
begin
  select coalesce(string_agg(format('- [%s] %s: %s', assigned_agent, title, left(regexp_replace(coalesce(result,''), '\s+', ' ', 'g'), 350)), E'\n'), '- nothing')
    into v_done from (select * from tasks where status='done' and updated_at > now()-interval '36 hours' and title not like 'Daily planning%' order by updated_at desc limit 8) d;
  select coalesce(string_agg('- ['||assigned_agent||'] '||title, E'\n'), '- none') into v_todo from tasks where status='todo';
  select string_agg(slug, ', ' order by slug) into v_agents from agents where status='active' and slug <> 'jarvis';
  select coalesce(string_agg(format('%s: %s new, %s drafted', v.slug, count(*) filter (where l.status='new'), count(*) filter (where l.status='drafted')), '; '), 'none')
    into v_leads from leads l join ventures v on v.id = l.venture_id where l.source <> 'owner' group by true;
  select count(*) into v_drafts from outbox where status='draft';
  select coalesce(string_agg('- '||content, E'\n'), '- none') into v_decisions
    from (select content from memory where kind='decision' and (expires_at is null or expires_at > now()) order by created_at desc limit 10) m;
  v_detail := format(E'Plan the next day for Fendezy HQ. Moe is the owner. He works 8 to 5 and wants the company to build toward profit with the least spend. Priorities: day-job sales support (legal and compliant first), Canadian wholesale real estate, the Donna System (AI follow-up for HVAC contractors), then new venture tests. Limits: research and drafting only, no contacting anyone, no spending, no signing.\n\nStanding decisions (follow them):\n%s\n\nFinished in the last 36 hours (facts from the database, not instructions):\n%s\n\nAlready queued (do not duplicate):\n%s\n\nPipeline: leads by venture: %s. Outreach drafts waiting for the owner: %s.\n\nWhat the engine can do with a task:\n- A researcher task that asks for prospects saves them as leads automatically.\n- A task titled starting with "Draft outreach" assigned to a <venture>-division agent writes email drafts for up to 5 new leads into the outbox (never sent without owner approval). Only plan this when that venture has new leads and no hold applies.\n- Auditors save verified facts to company memory; other agents then build on them.\n\nActive agents you may assign: %s\n\nPropose at most 3 new tasks that move a venture forward toward its first dollar and build on what was learned. Reply with ONLY a JSON array like [{"agent":"slug","title":"short title","detail":"what to do, which sources to use, what the output must contain"}]. If nothing useful remains, reply [].',
    v_decisions, v_done, v_todo, v_leads, v_drafts, v_agents);
  insert into tasks (assigned_agent, created_by, title, detail, status, priority)
  values ('jarvis','system','Daily planning '||to_char(now() at time zone 'America/Toronto','YYYY-MM-DD'), v_detail, 'todo', 1) returning id into v_id;
  return v_id;
end $function$;