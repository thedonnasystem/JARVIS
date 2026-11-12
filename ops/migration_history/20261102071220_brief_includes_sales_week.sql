do $mig$
declare src text;
begin
  src := pg_get_functiondef('public.daily_brief_text'::regproc);
  src := replace(src, $a$    || E'\n' || v_money$a$, $b$    || E'\n' || v_money
    || E'\n' || coalesce(public.dayjob_week_text(), '')$b$);
  if src not like '%dayjob_week_text%' then raise exception 'brief hook not found'; end if;
  execute src;
end $mig$;