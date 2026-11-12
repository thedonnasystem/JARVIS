do $mig$
declare src text;
begin
  src := pg_get_functiondef('public.post_daily_brief()'::regprocedure);
  src := replace(src, $a$where kind = 'brief'$a$, $b$where kind = 'brief' and body like 'Health:%'$b$);
  if src not like '%Health:%%' then raise exception 'not applied'; end if;
  execute src;
end $mig$;