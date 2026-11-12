alter table public.system_state add column if not exists pause_reason text, add column if not exists paused_at timestamptz;
do $mig$
declare src text;
begin
  src := pg_get_functiondef('public.queue_outreach_drafts()'::regprocedure);
  src := replace(src, $a$    if exists (select 1 from tasks where venture_id = r.venture_id and title like 'Draft outreach%' and status in ('todo','doing')) then continue; end if;$a$,
    $b$    if exists (select 1 from tasks where venture_id = r.venture_id and title like 'Draft outreach%' and status in ('todo','doing')) then continue; end if;
    -- don't respawn a task that just failed (Nov 2026: one failing task was re-created every 30 min for 2 days)
    if exists (select 1 from tasks where venture_id = r.venture_id and title like 'Draft outreach%' and status = 'blocked' and updated_at > now() - interval '12 hours') then continue; end if;
    if (select pause_reason from system_state where id = 1) is not null then continue; end if;$b$);
  if src not like '%just failed%' then raise exception 'drafts guard not applied'; end if;
  execute src;
end $mig$;