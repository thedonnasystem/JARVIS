do $mig$
declare src text;
begin
  src := pg_get_functiondef('public.queue_prospect_task()'::regprocedure);
  src := replace(src, $a$For each, OPEN its own website contact page and record the business email it publishes (info@, office@, service@). Skip any business whose site has no published email, and note if the site says no unsolicited messages.$a$,
                      $b$For each, OPEN its own website contact page (or, if the site lists none, the business''s own Facebook page or Google Business profile) and record the generic business email the business itself publishes (info@, office@, service@). Never use an email from a third-party directory or a person''s own address. Skip any business with no self-published email, and note if it says no unsolicited messages.$b$);
  if src not like '%Google Business profile%' then raise exception 'prospect prompt not found'; end if;
  execute src;
end $mig$;