create or replace function public.queue_followup_digest() returns int
language plpgsql security definer set search_path = public as $$
declare v_today date := (now() at time zone 'America/Toronto')::date; v_list text; v_n int;
begin
  select count(*), string_agg(format('#%s %s %s', short_id, name, coalesce(phone,'')), E'\n' order by next_followup_at, short_id)
    into v_n, v_list
    from (select short_id, name, phone, next_followup_at from leads
          where next_followup_at <= v_today and do_not_contact = false and status is distinct from 'closed'
          order by next_followup_at, short_id limit 25) d;
  if v_n = 0 then return 0; end if;
  insert into owner_messages(from_agent, kind, channel, body)
  values ('jarvis','money','telegram', format(E'Follow-ups due today (%s):\n%s\n\nAfter each call: /done <#> <days> <note>', v_n, v_list));
  return v_n;
end $$;
revoke all on function public.queue_followup_digest() from public, anon, authenticated;
select cron.schedule('hq-followups-0815', '15 13 * * 1-6', $$select public.queue_followup_digest()$$);