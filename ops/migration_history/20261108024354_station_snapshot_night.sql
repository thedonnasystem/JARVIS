do $mig$
declare src text;
begin
  src := pg_get_functiondef('public.station_snapshot()'::regprocedure);
  src := replace(src, $a$'paused_at', (select paused_at from system_state where id = 1),$a$,
    $b$'paused_at', (select paused_at from system_state where id = 1),
    'night_until', (select night_until from system_state where id = 1),
    'questions', (select count(*) from owner_messages where options is not null and answer is null),$b$);
  if src not like '%night_until%' then raise exception 'not applied'; end if;
  execute src;
end $mig$;