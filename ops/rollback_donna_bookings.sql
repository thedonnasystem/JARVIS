-- Rollback of migrations/20261214_donna_bookings_v1.sql. Idempotent. Run BEFORE ops/rollback_donna_nudges.sql:
--   psql -v ON_ERROR_STOP=1 -f ops/rollback_donna_bookings.sql        (one transaction; sqltests set fz_in_txn and run it inside theirs)
-- Puts back the Revenue Loop v1 donna_ingest_inbound (no 'booking' source). Booking rows already ingested are KEPT (never deleted): if any exist, the widened
-- source check stays so they remain valid, and the audit row says so; otherwise the original check is restored. The appointment_at column is kept (nullable,
-- nothing reads it after the rollback); donna_stuck_deals goes back to the Nudges v1 body.
\if :{?fz_in_txn}
\else
begin;
\endif
do $$
declare c text; n bigint := (select count(*) from fz_donna_rl.inbound where source = 'booking');
        v_on boolean := to_regprocedure('public.donna_ingest_inbound(text, text, timestamptz, text, text, text, text, boolean, text, boolean, text, text, text, timestamptz)') is not null;
begin
  if not v_on and (n > 0 or not exists (select 1 from pg_constraint where conrelid = 'fz_donna_rl.inbound'::regclass and contype = 'c' and pg_get_constraintdef(oid) like '%booking%')) then
    return;                                                              -- already rolled back (the widened check stays only while booking rows exist)
  end if;
  if n = 0 then
    select conname into c from pg_constraint where conrelid = 'fz_donna_rl.inbound'::regclass and contype = 'c' and pg_get_constraintdef(oid) like '%booking%';
    if c is not null then
      execute format('alter table fz_donna_rl.inbound drop constraint %I', c);
      alter table fz_donna_rl.inbound add constraint inbound_source_check check (source in ('website_form', 'web_call', 'phone_call'));
    end if;
  end if;
  insert into public.audit_log (actor, action, target, detail)
    values ('rollback', 'donna_bookings_rollback', 'public.donna_ingest_inbound', jsonb_build_object('booking_rows_kept', n, 'source_check_restored', n = 0));
end $$;
drop function if exists public.donna_ingest_inbound(text, text, timestamptz, text, text, text, text, boolean, text, boolean, text, text, text, timestamptz);
create or replace function public.donna_ingest_inbound(p_source text, p_ref text, p_received_at timestamptz, p_person text, p_business text, p_email text,
                                                       p_phone text, p_marketing_consent boolean, p_consent_version text, p_booked boolean, p_appointment text,
                                                       p_leak_estimate text, p_summary text) returns jsonb
language plpgsql security definer set search_path to 'pg_catalog' as $$
declare v_v uuid := fz_donna.donna_venture(); v_email text := nullif(lower(btrim(coalesce(p_email, ''))), ''); v_phone text := public.normalize_phone(p_phone);
        v_person text := nullif(left(regexp_replace(btrim(coalesce(p_person, '')), '\s+', ' ', 'g'), 120), '');
        v_biz text := nullif(left(regexp_replace(btrim(coalesce(p_business, '')), '\s+', ' ', 'g'), 160), '');
        l public.leads; v_lead uuid; v_new boolean := false; v_basis text; v_supp boolean := false; v_status text; v_note text; v_in uuid; v_express boolean := coalesce(p_marketing_consent, false);
begin
  perform fz_donna.guard();
  if v_v is null then raise exception 'refused: no donna venture'; end if;
  if p_source is null or p_source not in ('website_form', 'web_call', 'phone_call') then raise exception 'refused: unknown inbound source %', p_source; end if;
  if p_ref is null or p_ref !~ '^[A-Za-z0-9][A-Za-z0-9._:-]{2,99}$' then raise exception 'refused: bad inbound ref'; end if;
  if p_received_at is null or p_received_at > clock_timestamp() + interval '5 minutes' or p_received_at < clock_timestamp() - interval '90 days' then
    raise exception 'refused: received_at must be within the last 90 days'; end if;
  if v_express and p_source <> 'website_form' then raise exception 'refused: express consent comes only from the website form''s own box'; end if;
  if v_express and coalesce(p_consent_version, '') !~ '^[A-Za-z0-9._-]{1,60}$' then raise exception 'refused: express consent needs the wording version the form showed'; end if;
  if v_email is not null and v_email !~ '^[a-z0-9._%+-]+@[a-z0-9.-]+\.[a-z]{2,}$' then v_email := null; end if;
  if exists (select 1 from fz_donna_rl.inbound where source = p_source and ref = p_ref) then
    return jsonb_build_object('duplicate', true, 'lead', (select lead_id from fz_donna_rl.inbound where source = p_source and ref = p_ref));
  end if;
  v_supp := (v_email is not null and public.is_suppressed(v_email)) or (v_phone is not null and public.ffm_is_phone_suppressed(v_phone));
  if v_email is not null or v_phone is not null then
    select * into l from public.leads where venture_id = v_v and ((v_email is not null and lower(email) = v_email) or (v_phone is not null and public.normalize_phone(phone) = v_phone))
     order by created_at limit 1;
    v_basis := case when v_express then 'express_web_form' else 'implied_inquiry' end;
    v_note := left(case p_source when 'website_form' then 'website form' when 'web_call' then 'talked to Donna on the website' else 'called the Donna line' end
                   || ' ' || to_char(p_received_at at time zone 'America/Toronto', 'YYYY-MM-DD') || ' (ref ' || p_ref || ')'
                   || case when v_express then ', ticked the marketing box (wording ' || p_consent_version || ')' else ', inquiry only (implied consent 6 months)' end
                   || case when coalesce(p_booked, false) then ', booked the audit' || coalesce(' ' || left(p_appointment, 80), '') else '' end
                   || case when v_person is not null and v_biz is not null then ', contact ' || v_person else '' end, 400);
    if l.id is null then
      insert into public.leads (venture_id, name, email, phone, source, status, consent_basis, do_not_contact, notes)
        values (v_v, coalesce(v_biz, v_person, 'Website inquiry'), v_email, v_phone, 'donna:' || p_source,
                case when coalesce(p_booked, false) then 'booked' else 'new' end, v_basis, v_supp, v_note)
        returning id into v_lead;
      v_new := true; v_status := case when coalesce(p_booked, false) then 'booked' else 'new' end;
    else
      v_lead := l.id;
      v_status := case when l.do_not_contact or l.status in ('do_not_contact', 'won', 'lost') then l.status
                       when coalesce(p_booked, false) then 'booked'
                       when l.status in ('drafted', 'approved_to_send', 'sent', 'contacted') then 'replied'
                       else l.status end;
      update public.leads set
          status = v_status,
          consent_basis = case when v_express and coalesce(consent_basis, '') not like 'express%' then 'express_web_form'
                               when nullif(btrim(coalesce(consent_basis, '')), '') is null then v_basis else consent_basis end,
          do_not_contact = do_not_contact or v_supp,
          email = coalesce(email, v_email), phone = coalesce(phone, v_phone),
          notes = left(coalesce(notes || E'\n', '') || v_note, 2000)
        where id = l.id;
    end if;
  end if;
  insert into fz_donna_rl.inbound (source, ref, lead_id, person, business, booked, appointment, marketing_consent, consent_version, leak_estimate, summary, received_at)
    values (p_source, p_ref, v_lead, v_person, v_biz, coalesce(p_booked, false), left(nullif(btrim(coalesce(p_appointment, '')), ''), 120), v_express,
            case when v_express then p_consent_version end, left(nullif(btrim(coalesce(p_leak_estimate, '')), ''), 900), left(nullif(btrim(coalesce(p_summary, '')), ''), 1200), p_received_at)
    returning id into v_in;
  insert into public.audit_log (actor, action, target, detail)
    values ('donna:inbound', 'donna_inbound', coalesce('leads/' || v_lead, 'fz_donna_rl.inbound/' || v_in),
            jsonb_build_object('source', p_source, 'new_lead', v_new, 'booked', coalesce(p_booked, false), 'express', v_express, 'suppressed', v_supp));
  return jsonb_build_object('duplicate', false, 'inbound', v_in, 'lead', v_lead, 'new_lead', v_new, 'status', v_status, 'do_not_contact', coalesce(v_supp or l.do_not_contact, v_supp),
                            'contactable', v_lead is not null and not v_supp and not coalesce(l.do_not_contact, false));
end $$;
revoke all on function public.donna_ingest_inbound(text, text, timestamptz, text, text, text, text, boolean, text, boolean, text, text, text) from public, anon, authenticated;
create or replace function public.donna_stuck_deals(p_limit integer default 10) returns jsonb
language plpgsql stable security definer set search_path to 'pg_catalog' as $$
declare v_v uuid := fz_donna.donna_venture(); n integer := least(greatest(coalesce(p_limit, 10), 1), 50);
begin
  perform fz_donna.guard();
  return coalesce((select jsonb_agg(to_jsonb(x) order by x.since) from (
    select * from (
      select 'audit_no_proposal'::text kind, l.short_id, l.name, coalesce((select min(i.received_at) from fz_donna_rl.inbound i where i.lead_id = l.id and i.booked), l.created_at) since,
             null::text client_label
        from public.leads l
       where l.venture_id = v_v and l.status = 'booked' and not l.do_not_contact
         and not exists (select 1 from fz_donna_rl.staged s where s.lead_id = l.id and s.purpose = 'proposal')
         and not exists (select 1 from fz_donna.drafts d where d.lead_id = l.id and d.status = 'draft')      -- a draft already queued for this lead (it stages on retry)
      union all
      select 'won_no_intake', l.short_id, l.name, coalesce((select max(d.updated_at) from public.deals d where d.lead_id = l.id and d.stage = 'won'), l.created_at), null
        from public.leads l
       where l.venture_id = v_v and l.status = 'won'
         and not exists (select 1 from fz_donna.intakes t where t.lead_id = l.id)
      union all
      select 'intake_no_agent', l.short_id, coalesce(l.name, t.client_label), t.created_at, t.client_label
        from (select distinct on (coalesce(t.lead_id::text, t.client_label)) t.* from fz_donna.intakes t
               where t.status in ('draft', 'owner_approved') order by coalesce(t.lead_id::text, t.client_label), t.created_at desc) t
        left join public.leads l on l.id = t.lead_id
       where not exists (select 1 from fz_donna_ca.agents a where a.intake_id = t.id)
         and (l.id is null or l.status = 'won')
    ) s
    where s.kind <> 'audit_no_proposal' or s.since < now() - interval '1 day'
    order by s.since limit n) x), '[]'::jsonb);
end $$;
revoke all on function public.donna_stuck_deals(integer) from public, anon, authenticated;
\if :{?fz_in_txn}
\else
commit;
\endif
