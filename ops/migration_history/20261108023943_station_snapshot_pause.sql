do $mig$
declare src text;
begin
  src := pg_get_functiondef('public.station_snapshot()'::regprocedure);
  src := replace(src, $a$'kill_switch', (select kill_switch from system_state where id = 1),$a$,
    $b$'kill_switch', (select kill_switch from system_state where id = 1),
    'pause_reason', (select pause_reason from system_state where id = 1),
    'paused_at', (select paused_at from system_state where id = 1),
    'drafts_ready', (select coalesce(jsonb_agg(jsonb_build_object('to', to_ref, 'subject', split_part(split_part(body, E'\n', 1), 'Subject: ', 2)) order by created_at), '[]'::jsonb) from (select to_ref, body, created_at from outbox where status = 'draft' order by created_at limit 20) d),$b$);
  if src not like '%pause_reason%' then raise exception 'not applied'; end if;
  execute src;
end $mig$;