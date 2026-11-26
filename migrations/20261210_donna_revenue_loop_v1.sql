-- FENDEZY GROUP: "Donna Revenue Loop v1": the money loop around Donna Ops v1 (20261207). ADDITIVE. Design: docs/architecture/DONNA_REVENUE_LOOP_V1.md.
--   * schema fz_donna_rl (NO API privileges), so Donna Ops v1 and its rollback are untouched:
--       inbound  every website form and Donna call that reached the CRM (one row per source + ref; idempotent), with the lead it landed on;
--       staged   which owner-review Donna draft was handed to the EXISTING outreach gate (public.outbox, status 'draft'), once;
--       briefs   the audit-prep brief written for a booked Revenue Leak Audit.
--   * donna_ingest_inbound (service path): a website form or a Donna call becomes a lead of the 'donna' venture. Consent basis from what the person did:
--     the unticked marketing box ticked = 'express_web_form' (wording version recorded); otherwise 'implied_inquiry' (CASL s.10(10)(b): an inquiry, dated in the notes).
--     Never a downgrade, never over do-not-contact; a suppressed address or number makes the lead do-not-contact. Works while Donna is DORMANT (the owner's switch
--     is DONNA_INBOUND=1 on the bot): recording an inquiry the owner already received is bookkeeping, not an agent action. Nothing is sent.
--   * donna_stage_outbox (service path, Donna ACTIVE): an owner-review email draft for a lead goes to public.outbox as 'draft' (needs_owner) and the Donna draft is
--     marked superseded (its decision lives on the outbox row now). That is the
--     existing gate: the owner approves or rejects it in Telegram (CASL gate, suppression, kill switch, policy caps, outreach gate) and only then can hq_mail send it.
--     Refused while an [OWNER: ...] placeholder is left (e.g. the mailing address), for a do-not-contact / suppressed / no-consent lead, or twice for one draft.
--   * donna_followups_due / donna_lead_context / donna_save_brief / donna_revenue_queue / donna_inbound_recent: reads and an internal brief. No send path.
-- Nothing here moves money, sends anything, deploys anything or changes a permission, a tier or a profile. Function names keep the donna_ prefix
-- (rollback_donna_ops.sql drops them with its own; run ops/rollback_donna_revenue_loop.sql FIRST for a clean archive). Ordered BEFORE the lockdown. Safe to re-run.

set lock_timeout = '5s';

create schema if not exists fz_donna_rl;
revoke all on schema fz_donna_rl from public;
do $$ declare r text; begin
  foreach r in array array['anon', 'authenticated', 'service_role', 'fz_jarvis', 'fz_office_agent', 'fz_auditor', 'backup_reader'] loop
    if exists (select 1 from pg_roles where rolname = r) then execute format('revoke all on schema fz_donna_rl from %I', r); end if;
  end loop;
end $$;

-- FIX: hq_mail.deliver_approved selects outbox.subject, but the live outbox never had that column (scripts/replica/01_tables.sql), so the select failed and no
-- approved email could be sent. Additive and nullable (hq_mail falls back to a default subject); kept on rollback, like every other column of a live table.
alter table public.outbox add column if not exists subject text;
do $$ begin
  if not exists (select 1 from pg_constraint where conname = 'outbox_subject_len' and conrelid = 'public.outbox'::regclass) then
    alter table public.outbox add constraint outbox_subject_len check (subject is null or length(subject) <= 200);
  end if;
end $$;

create table if not exists fz_donna_rl.inbound (
  id uuid primary key default gen_random_uuid(),
  source text not null check (source in ('website_form', 'web_call', 'phone_call')),
  ref text not null check (ref ~ '^[A-Za-z0-9][A-Za-z0-9._:-]{2,99}$'),
  lead_id uuid references public.leads (id),
  person text check (person is null or length(person) <= 120),
  business text check (business is null or length(business) <= 160),
  booked boolean not null default false,
  appointment text check (appointment is null or length(appointment) <= 120),
  marketing_consent boolean not null default false,
  consent_version text check (consent_version is null or consent_version ~ '^[A-Za-z0-9._-]{1,60}$'),
  leak_estimate text check (leak_estimate is null or length(leak_estimate) <= 900),
  summary text check (summary is null or length(summary) <= 1200),
  received_at timestamptz not null,
  created_at timestamptz not null default now(),
  unique (source, ref)
);
revoke all on fz_donna_rl.inbound from public;
create index if not exists donna_rl_inbound_lead on fz_donna_rl.inbound (lead_id, received_at desc);

create table if not exists fz_donna_rl.staged (
  draft_id uuid primary key references fz_donna.drafts (id),
  outbox_id uuid not null unique references public.outbox (id),
  lead_id uuid not null references public.leads (id),
  purpose text check (purpose is null or purpose ~ '^[a-z_]{3,30}$'),
  staged_at timestamptz not null default now()
);
revoke all on fz_donna_rl.staged from public;

create table if not exists fz_donna_rl.briefs (
  id uuid primary key default gen_random_uuid(),
  run_id uuid references fz_donna.runs (id),
  lead_id uuid not null references public.leads (id),
  body text not null check (length(body) between 20 and 8000),
  created_at timestamptz not null default now()
);
revoke all on fz_donna_rl.briefs from public;
create index if not exists donna_rl_briefs_lead on fz_donna_rl.briefs (lead_id, created_at desc);

-- ---------------------------------------------------------------------------------------------------------------------------- inbound -> CRM (service path)
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

create or replace function public.donna_inbound_recent(p_limit integer default 10) returns jsonb
language plpgsql stable security definer set search_path to 'pg_catalog' as $$
begin
  perform fz_donna.guard();
  return coalesce((select jsonb_agg(x order by x ->> 'received_at' desc) from (
    select jsonb_build_object('source', i.source, 'received_at', i.received_at, 'lead', i.lead_id, 'short_id', l.short_id, 'name', coalesce(i.business, i.person, l.name),
                              'booked', i.booked, 'appointment', i.appointment, 'leak_estimate', left(i.leak_estimate, 160), 'status', l.status, 'do_not_contact', l.do_not_contact) x
      from fz_donna_rl.inbound i left join public.leads l on l.id = i.lead_id
     order by i.received_at desc limit least(greatest(coalesce(p_limit, 10), 1), 50)) y), '[]'::jsonb);
end $$;
revoke all on function public.donna_inbound_recent(integer) from public, anon, authenticated;

-- ---------------------------------------------------------------------------------------------------------------------------- agent side (service path, Donna ACTIVE)
-- what a template needs about one lead: names, status, the latest inquiry. The address and number stay in the database (staging reads them there).
create or replace function public.donna_lead_context(p_lead uuid) returns jsonb
language plpgsql stable security definer set search_path to 'pg_catalog' as $$
declare l public.leads; i fz_donna_rl.inbound; n_sent integer;
begin
  perform fz_donna.guard();
  perform fz_donna.require_active();
  select * into l from public.leads where id = p_lead and venture_id = fz_donna.donna_venture();
  if l.id is null then raise exception 'refused: not a Donna lead' using errcode = '42501'; end if;
  select * into i from fz_donna_rl.inbound where lead_id = l.id order by received_at desc, created_at desc limit 1;
  select count(*) into n_sent from public.outbox where lead_id = l.id and status = 'sent';
  return jsonb_build_object('lead', l.id, 'short_id', l.short_id, 'business', left(btrim(coalesce(i.business, l.name, '')), 120), 'person', i.person,
    'status', l.status, 'source', l.source, 'has_email', l.email is not null, 'do_not_contact', l.do_not_contact,
    'consent_basis', l.consent_basis, 'sent', n_sent, 'last_contact_at', l.last_contact_at,
    'inbound', case when i.id is null then null else jsonb_build_object('source', i.source, 'received_at', i.received_at,
                 'booked', l.status = 'booked' or exists (select 1 from fz_donna_rl.inbound b where b.lead_id = l.id and b.booked),
                 'appointment', (select b.appointment from fz_donna_rl.inbound b where b.lead_id = l.id and b.booked and b.appointment is not null order by b.received_at desc, b.created_at desc limit 1),
                 'leak_estimate', (select b.leak_estimate from fz_donna_rl.inbound b where b.lead_id = l.id and b.leak_estimate is not null order by b.received_at desc, b.created_at desc limit 1),
                 'summary', i.summary) end,
    'has_brief', exists (select 1 from fz_donna_rl.briefs b where b.lead_id = l.id));
end $$;
revoke all on function public.donna_lead_context(uuid) from public, anon, authenticated;

-- hand one owner-review email draft to the EXISTING outreach gate (public.outbox 'draft'); the owner's Telegram decision is what can send it
create or replace function public.donna_stage_outbox(p_draft uuid, p_purpose text default null) returns jsonb
language plpgsql security definer set search_path to 'pg_catalog' as $$
declare d fz_donna.drafts; l public.leads; v_probs text[]; v_ob uuid;
begin
  perform fz_donna.guard();
  perform fz_donna.require_active();
  select * into d from fz_donna.drafts where id = p_draft;
  if d.id is null then raise exception 'refused: unknown draft' using errcode = '42501'; end if;
  if exists (select 1 from fz_donna_rl.staged where draft_id = d.id) then
    return jsonb_build_object('duplicate', true, 'outbox', (select outbox_id from fz_donna_rl.staged where draft_id = d.id)); end if;
  if d.status <> 'draft' then raise exception 'refused: only a draft waiting for review can be staged (status %)', d.status using errcode = '42501'; end if;
  if d.kind not in ('cold_email', 'follow_up_email') or d.channel is distinct from 'email' or d.lead_id is null then
    raise exception 'refused: only an email draft for one lead goes to the outbox' using errcode = '42501'; end if;
  if p_purpose is not null and p_purpose !~ '^[a-z_]{3,30}$' then raise exception 'refused: bad purpose'; end if;
  if strpos(lower(d.body) || lower(coalesce(d.subject, '')), '[owner:') > 0 then
    raise exception 'refused: the draft still has an [OWNER: ...] placeholder (set the mailing address / sender first)' using errcode = '42501'; end if;
  v_probs := fz_donna.text_problems(d.kind, d.subject, d.body);
  if cardinality(v_probs) > 0 then raise exception 'refused (CASL / honesty): %', array_to_string(v_probs, '; ') using errcode = '42501'; end if;
  select * into l from public.leads where id = d.lead_id;
  if l.id is null or l.venture_id is distinct from fz_donna.donna_venture() then raise exception 'refused: not a Donna lead' using errcode = '42501'; end if;
  if l.do_not_contact or l.status = 'do_not_contact' then raise exception 'refused: the lead is do-not-contact' using errcode = '42501'; end if;
  if nullif(btrim(coalesce(l.consent_basis, '')), '') is null then raise exception 'refused: no consent basis recorded for this lead (CASL)' using errcode = '42501'; end if;
  if l.email is null then raise exception 'refused: the lead has no email' using errcode = '42501'; end if;
  if public.is_suppressed(l.email) then raise exception 'refused: the address is on the suppression list' using errcode = '42501'; end if;
  if exists (select 1 from public.outbox o where o.lead_id = l.id and o.status in ('draft', 'qa_passed')) then   -- one draft per lead (outbox_one_draft_per_lead)
    raise exception 'refused: an email to this lead is already waiting for the owner''s decision; approve or reject it first (this draft is retried after)' using errcode = '42501'; end if;
  insert into public.outbox (venture_id, channel, to_ref, subject, body, status, needs_owner, lead_id, idempotency_key)
    values (l.venture_id, 'email', l.email, d.subject, d.body, 'draft', true, l.id, 'donna-draft:' || d.id)
    returning id into v_ob;
  insert into fz_donna_rl.staged (draft_id, outbox_id, lead_id, purpose) values (d.id, v_ob, l.id, p_purpose);
  -- the decision now lives on the outbox row (the owner's Approve / Reject): the Donna draft stops counting as waiting for review
  update fz_donna.drafts set status = 'superseded', note = left('handed to the outbox for the owner''s decision (outbox/' || v_ob || ')', 500) where id = d.id;
  insert into public.audit_log (actor, action, target, detail) values ('office:donna', 'donna_stage_outbox', 'outbox/' || v_ob,
                                                                       jsonb_build_object('draft', d.id, 'lead', l.id, 'purpose', p_purpose));
  return jsonb_build_object('duplicate', false, 'outbox', v_ob, 'draft', d.id, 'status', 'draft', 'needs_owner', true);
end $$;
revoke all on function public.donna_stage_outbox(uuid, text) from public, anon, authenticated;

-- leads whose next follow-up is due: contacted (hq_mail sets next_followup_at), at most 3 emails in total, nothing already waiting for the owner
create or replace function public.donna_followups_due(p_limit integer default 10) returns jsonb
language plpgsql stable security definer set search_path to 'pg_catalog' as $$
begin
  perform fz_donna.guard();
  perform fz_donna.require_active();
  return coalesce((select jsonb_agg(jsonb_build_object('lead', x.id, 'step', x.n_sent + 1) order by x.next_followup_at, x.id) from (
    select l.id, l.next_followup_at, (select count(*) from public.outbox o where o.lead_id = l.id and o.status = 'sent') n_sent
      from public.leads l
     where l.venture_id = fz_donna.donna_venture() and not l.do_not_contact and l.status = 'contacted' and l.email is not null
       and nullif(btrim(coalesce(l.consent_basis, '')), '') is not null and l.next_followup_at <= (now() at time zone 'America/Toronto')::date
       and not exists (select 1 from public.outbox o where o.lead_id = l.id and o.status in ('draft', 'qa_passed', 'approved'))
       and not exists (select 1 from fz_donna.drafts d where d.lead_id = l.id and d.status = 'draft' and d.created_at > coalesce(l.last_contact_at, l.created_at))
     order by l.next_followup_at, l.id limit least(greatest(coalesce(p_limit, 10), 1), 50)) x where x.n_sent between 1 and 2), '[]'::jsonb);
end $$;
revoke all on function public.donna_followups_due(integer) from public, anon, authenticated;

-- the audit-prep brief of one booked lead (internal: it goes to the owner, never to the lead); written by a running offer-pricing mission
create or replace function public.donna_save_brief(p_run uuid, p_lead uuid, p_body text) returns jsonb
language plpgsql security definer set search_path to 'pg_catalog' as $$
declare r fz_donna.runs; v_id uuid;
begin
  perform fz_donna.guard();
  perform fz_donna.require_active();
  select * into r from fz_donna.runs where id = p_run;
  if r.id is null or r.status <> 'running' or r.mission <> 'offer-pricing' then raise exception 'refused: a brief comes from a running offer-pricing mission' using errcode = '42501'; end if;
  if not exists (select 1 from public.leads where id = p_lead and venture_id = fz_donna.donna_venture()) then raise exception 'refused: not a Donna lead' using errcode = '42501'; end if;
  insert into fz_donna_rl.briefs (run_id, lead_id, body) values (p_run, p_lead, p_body) returning id into v_id;
  insert into public.audit_log (actor, action, target, detail) values ('office:donna', 'donna_brief', 'fz_donna_rl.briefs/' || v_id, jsonb_build_object('run', p_run, 'lead', p_lead));
  return jsonb_build_object('brief', v_id);
end $$;
revoke all on function public.donna_save_brief(uuid, uuid, text) from public, anon, authenticated;

-- what the revenue loop has waiting, for /donna and the tick (read-only; counts and lead refs, no contact data)
create or replace function public.donna_revenue_queue(p_limit integer default 20) returns jsonb
language plpgsql stable security definer set search_path to 'pg_catalog' as $$
declare v_v uuid := fz_donna.donna_venture(); n integer := least(greatest(coalesce(p_limit, 20), 1), 100);
begin
  perform fz_donna.guard();
  return jsonb_build_object(
    'active', fz_donna.active(),
    'reply_needed', coalesce((select jsonb_agg(l.id order by l.created_at) from (select l.id, l.created_at from public.leads l
        where l.venture_id = v_v and not l.do_not_contact and l.email is not null and l.status in ('new', 'booked', 'replied')
          and nullif(btrim(coalesce(l.consent_basis, '')), '') is not null
          and exists (select 1 from fz_donna_rl.inbound i where i.lead_id = l.id)
          and not exists (select 1 from fz_donna_rl.staged s where s.lead_id = l.id and s.staged_at >= (select max(i.created_at) from fz_donna_rl.inbound i where i.lead_id = l.id))
          and not exists (select 1 from fz_donna.drafts d where d.lead_id = l.id and d.status = 'draft' and d.created_at >= (select max(i.created_at) from fz_donna_rl.inbound i where i.lead_id = l.id))
        order by l.created_at limit n) l), '[]'::jsonb),
    'brief_needed', coalesce((select jsonb_agg(l.id order by l.created_at) from (select l.id, l.created_at from public.leads l
        where l.venture_id = v_v and l.status = 'booked' and not exists (select 1 from fz_donna_rl.briefs b where b.lead_id = l.id)
        order by l.created_at limit n) l), '[]'::jsonb),
    'outbox_waiting', (select count(*) from fz_donna_rl.staged s join public.outbox o on o.id = s.outbox_id where o.status in ('draft', 'qa_passed')),
    'staged_today', (select count(*) from fz_donna_rl.staged where staged_at >= ((now() at time zone 'America/Toronto')::date::timestamp at time zone 'America/Toronto')),
    'cold_staged_today', (select count(*) from fz_donna_rl.staged where purpose = 'cold'
                            and staged_at >= ((now() at time zone 'America/Toronto')::date::timestamp at time zone 'America/Toronto')),
    'approved_not_sent', (select count(*) from fz_donna_rl.staged s join public.outbox o on o.id = s.outbox_id where o.status = 'approved' and o.sent_at is null),
    'sent_7d', (select count(*) from fz_donna_rl.staged s join public.outbox o on o.id = s.outbox_id where o.status = 'sent' and o.sent_at > now() - interval '7 days'),
    'inbound_7d', (select count(*) from fz_donna_rl.inbound where received_at > now() - interval '7 days'),
    'booked_7d', (select count(*) from fz_donna_rl.inbound where booked and received_at > now() - interval '7 days'));
end $$;
revoke all on function public.donna_revenue_queue(integer) from public, anon, authenticated;
