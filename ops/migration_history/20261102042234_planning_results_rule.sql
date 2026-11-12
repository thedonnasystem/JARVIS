do $mig$
declare src text;
begin
  src := pg_get_functiondef('public.queue_daily_planning'::regproc);
  src := replace(src,
    $a$Propose at most 3 new tasks that move a venture forward toward its first dollar and build on what was learned. Reply with ONLY a JSON array like [{"agent":"slug","title":"short title","detail":"what to do, which sources to use, what the output must contain"}]. If nothing useful remains, reply [].$a$,
    $b$RESULTS RULE: this company exists to make money. Propose at most 3 new tasks, each one the shortest path to real dollars, not research for its own sake. Rank by expected CAD divided by days to cash. Skip any venture on hold or paused. Every task must state what it is worth: expected_cad (a realistic CAD amount this task helps bring in) and days_to_cash (how many days until that money could arrive). Tasks without both are discarded. Reply with ONLY a JSON array like [{"agent":"slug","title":"short title","detail":"what to do, which sources to use, what the output must contain","expected_cad":500,"days_to_cash":14,"why":"one sentence"}]. If nothing would move money, reply [].$b$);
  if src not like '%RESULTS RULE%' then raise exception 'planning prompt not found'; end if;
  execute src;
end $mig$;