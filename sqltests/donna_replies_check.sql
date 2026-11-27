-- Donna Replies v1 (migrations/20261212_donna_replies_v1.sql). ONE transaction, rolled back. Fresh apply, repo root.
-- Proves: works while dormant; a reply moves contacted -> replied and stops follow-ups; booked/won never move back; an unsubscribe reply makes the lead
-- do-not-contact and suppresses the address; one row per message id; unmatched senders are recorded without a lead; no API role reaches it; rollback.
begin;
create function pg_temp.r(p_id text, p_from text, p_unsub boolean) returns jsonb language sql as $$
  select public.donna_record_email_reply(p_id, p_from, now(), p_unsub) $$;
do $$
declare v uuid := (select id from public.ventures where slug = 'donna'); a uuid; b uuid; c uuid; x jsonb; f regprocedure; rl text;
begin
  insert into public.leads (venture_id, name, email, status, consent_basis) values (v, 'Birch Dental', 'hi@birch.example', 'contacted', 'implied_published') returning id into a;
  insert into public.leads (venture_id, name, email, status, consent_basis) values (v, 'Maple Salon', 'hi@maple.example', 'booked', 'implied_published') returning id into b;
  insert into public.leads (venture_id, name, email, status, consent_basis) values (v, 'Elm Auto', 'Hi@Elm.example', 'contacted', 'implied_published') returning id into c;
  x := pg_temp.r('msg_aaaaaa1', 'HI@birch.example', false);
  if not (x ->> 'matched')::boolean or x ->> 'status' <> 'replied' or (select status from public.leads where id = a) <> 'replied' then raise exception 'P1 reply %', x; end if;
  if not (pg_temp.r('msg_aaaaaa1', 'hi@birch.example', false) ->> 'duplicate')::boolean then raise exception 'P1 duplicate'; end if;
  x := pg_temp.r('msg_bbbbbb2', 'hi@maple.example', false);
  if (select status from public.leads where id = b) <> 'booked' then raise exception 'P2 booked moved back'; end if;
  x := pg_temp.r('msg_cccccc3', 'hi@elm.example', true);
  if x ->> 'kind' <> 'unsubscribe' or not (select do_not_contact from public.leads where id = c) or not public.is_suppressed('hi@elm.example') then raise exception 'P3 unsubscribe %', x; end if;
  if public.donna_unseen_messages(array['msg_aaaaaa1', 'msg_zzzzzz9', 'bad id']) <> '["msg_zzzzzz9"]'::jsonb then raise exception 'P4 unseen'; end if;
  x := pg_temp.r('msg_dddddd4', 'stranger@nowhere.example', false);
  if (x ->> 'matched')::boolean or not exists (select 1 from fz_donna_rp.seen where message_id = 'msg_dddddd4' and lead_id is null) then raise exception 'P4 unmatched %', x; end if;
  begin perform pg_temp.r('bad id!', 'a@b.example', false); raise exception 'P5 bad id accepted'; exception when others then if sqlerrm not like 'refused: bad message id%' then raise; end if; end;
  foreach rl in array array['anon', 'authenticated', 'service_role', 'fz_jarvis', 'fz_office_agent'] loop
    continue when not exists (select 1 from pg_roles where rolname = rl);
    if has_schema_privilege(rl, 'fz_donna_rp', 'usage') then raise exception 'P6 % has usage', rl; end if;
    if rl <> 'service_role' and has_function_privilege(rl, 'public.donna_record_email_reply(text, text, timestamptz, boolean)', 'execute') then raise exception 'P6 % can execute', rl; end if;
  end loop;
end $$;
\set fz_in_txn 1
\ir ../ops/rollback_donna_replies.sql
\ir ../ops/rollback_donna_replies.sql
do $$ begin
  if to_regnamespace('fz_donna_rp') is not null or to_regprocedure('public.donna_record_email_reply(text, text, timestamptz, boolean)') is not null
     or to_regprocedure('public.donna_unseen_messages(text[])') is not null then raise exception 'P7 left behind'; end if;
  if (select count(*) from fz_archive.donna_rp_seen) <> 4 then raise exception 'P7 not archived'; end if;
end $$;
\ir ../migrations/20261212_donna_replies_v1.sql
\ir ../migrations/20261212_donna_replies_v1.sql
select 'donna_replies_check ok';
rollback;
