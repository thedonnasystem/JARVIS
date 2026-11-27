-- FENDEZY GROUP: "Donna Replies v1": an email reply from a Donna lead stops her follow-ups, and an unsubscribe reply makes the lead do-not-contact, automatically.
-- ADDITIVE, after Donna Ops v1 (20261207). Design: docs/architecture/DONNA_REPLIES_V1.md.
--   * schema fz_donna_rp (NO API privileges): seen, one row per inbox message id (idempotent), with the lead it matched.
--   * donna_record_email_reply (service path; works while Donna is DORMANT, because stopping follow-ups and honouring an unsubscribe is a safety step, not an
--     agent action): the sender is matched to a Donna lead by address; a reply moves drafted / approved_to_send / contacted / sent to 'replied' (so
--     donna_followups_due stops); an unsubscribe reply runs the existing mark_do_not_contact (suppression list, drafts rejected). No message text is stored.
--   * donna_unseen_messages: which received-message ids are new.
-- Nothing here sends, pays or deploys. Ordered BEFORE the lockdown. Safe to re-run.

set lock_timeout = '5s';

create schema if not exists fz_donna_rp;
revoke all on schema fz_donna_rp from public;
do $$ declare r text; begin
  foreach r in array array['anon', 'authenticated', 'service_role', 'fz_jarvis', 'fz_office_agent', 'fz_auditor', 'backup_reader'] loop
    if exists (select 1 from pg_roles where rolname = r) then execute format('revoke all on schema fz_donna_rp from %I', r); end if;
  end loop;
end $$;

create table if not exists fz_donna_rp.seen (
  message_id text primary key check (message_id ~ '^[A-Za-z0-9_-]{6,120}$'),
  lead_id uuid references public.leads (id),
  kind text not null check (kind in ('reply', 'unsubscribe', 'unmatched')),
  received_at timestamptz not null,
  created_at timestamptz not null default now()
);
revoke all on fz_donna_rp.seen from public;

create or replace function public.donna_record_email_reply(p_message_id text, p_from text, p_received_at timestamptz, p_unsubscribe boolean) returns jsonb
language plpgsql security definer set search_path to 'pg_catalog' as $$
declare v_addr text := nullif(lower(btrim(coalesce(p_from, ''))), ''); l public.leads; v_kind text; v_status text;
begin
  perform fz_donna.guard();
  if p_message_id is null or p_message_id !~ '^[A-Za-z0-9_-]{6,120}$' then raise exception 'refused: bad message id'; end if;
  if p_received_at is null or p_received_at > clock_timestamp() + interval '5 minutes' then raise exception 'refused: bad received_at'; end if;
  if exists (select 1 from fz_donna_rp.seen where message_id = p_message_id) then
    return jsonb_build_object('duplicate', true);
  end if;
  if v_addr is not null and v_addr ~ '^[a-z0-9._%+-]+@[a-z0-9.-]+\.[a-z]{2,}$' then
    select * into l from public.leads where venture_id = fz_donna.donna_venture() and lower(email) = v_addr order by created_at limit 1;
  end if;
  if l.id is null then
    insert into fz_donna_rp.seen (message_id, kind, received_at) values (p_message_id, 'unmatched', p_received_at);
    return jsonb_build_object('duplicate', false, 'matched', false);
  end if;
  if coalesce(p_unsubscribe, false) then
    v_kind := 'unsubscribe';
    perform public.mark_do_not_contact(l.id, 'unsubscribe reply by email', 'donna:replies');
    v_status := 'do_not_contact';
  else
    v_kind := 'reply';
    v_status := case when l.status in ('drafted', 'approved_to_send', 'contacted', 'sent') and not l.do_not_contact then 'replied' else l.status end;
    if v_status is distinct from l.status then update public.leads set status = v_status where id = l.id; end if;
  end if;
  insert into fz_donna_rp.seen (message_id, lead_id, kind, received_at) values (p_message_id, l.id, v_kind, p_received_at);
  insert into public.audit_log (actor, action, target, detail) values ('donna:replies', 'donna_email_reply', 'leads/' || l.id,
                                                                       jsonb_build_object('kind', v_kind, 'status', v_status));
  return jsonb_build_object('duplicate', false, 'matched', true, 'lead', l.id, 'short_id', l.short_id, 'name', l.name, 'kind', v_kind, 'status', v_status);
end $$;
revoke all on function public.donna_record_email_reply(text, text, timestamptz, boolean) from public, anon, authenticated;

-- which of these received-message ids are new (so the bot fetches each body once)
create or replace function public.donna_unseen_messages(p_ids text[]) returns jsonb
language plpgsql stable security definer set search_path to 'pg_catalog' as $$
begin
  perform fz_donna.guard();
  return coalesce((select jsonb_agg(i) from unnest((coalesce(p_ids, '{}'::text[]))[1:100]) i
                    where i ~ '^[A-Za-z0-9_-]{6,120}$' and not exists (select 1 from fz_donna_rp.seen s where s.message_id = i)), '[]'::jsonb);
end $$;
revoke all on function public.donna_unseen_messages(text[]) from public, anon, authenticated;
