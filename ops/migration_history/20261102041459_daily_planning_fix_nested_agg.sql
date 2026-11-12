do $mig$
declare src text;
begin
  src := pg_get_functiondef('public.queue_daily_planning'::regproc);
  src := replace(src,
    $a$select coalesce(string_agg(format('%s: %s new, %s drafted', v.slug, count(*) filter (where l.status='new'), count(*) filter (where l.status='drafted')), '; '), 'none')
    into v_leads from leads l join ventures v on v.id = l.venture_id where l.source <> 'owner' group by true;$a$,
    $b$select coalesce(string_agg(format('%s: %s new, %s drafted', slug, n_new, n_drafted), '; '), 'none') into v_leads
    from (select v.slug, count(*) filter (where l.status='new') n_new, count(*) filter (where l.status='drafted') n_drafted
          from leads l join ventures v on v.id = l.venture_id where l.source is distinct from 'owner' group by v.slug) x;$b$);
  execute src;
end $mig$;