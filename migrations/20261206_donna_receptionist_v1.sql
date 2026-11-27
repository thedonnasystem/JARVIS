-- FENDEZY GROUP: "Donna Receptionist v1" (Donna's first offer: AI receptionist for a client business). ADDITIVE. Needs M1..M7 + client workspaces / FFM consent.
-- Design: docs/architecture/DONNA_RECEPTIONIST_V1.md. Integration, not a new stack: Pipecat (voice agent) + Twilio (telephony / SMS) + Cal.com (booking) in
-- hq_receptionist.py; this file is the governance around them.
--   * a receptionist CLIENT is an existing client workspace (client_workspaces); callers become its ws_leads (the existing CRM), so the existing consent log,
--     suppression list and withdrawal path (ffm_can_contact / ffm_is_phone_suppressed / ffm_withdraw_consent) apply unchanged.
--   * schema fz_reception (NO API privileges): clients (config: hours, services, prices, FAQs, escalation number, booking, voice), calls, messages.
--   * NO live calls and NO texts without the owner: a client starts in 'demo' (answered on the owner's demo line only, texts are logged as dry_run and can never
--     be sent); 'live' and every send flag are owner-only. Each text is pending until the owner approves it, unless the owner set a STANDING approval for that
--     client's missed-call text-back. Follow-up texts need current consent (ffm_can_contact sms). Every text names the business and carries "Reply STOP".
--     At send time the number is re-checked against the suppression list. STOP withdraws consent through ffm_withdraw_consent and cancels queued texts.
--   * no outbound calls exist in v1. Daily text ceiling per client. Nothing here moves money (the demo number is an owner spend approval, outside this file).
-- Function names avoid the fz_ prefix (the M1 rollback drill). Ordered BEFORE the lockdown. Rollback: ops/rollback_donna_receptionist.sql. Safe to re-run.

set lock_timeout = '5s';

create schema if not exists fz_reception;
revoke all on schema fz_reception from public;
do $$ declare r text; begin
  foreach r in array array['anon', 'authenticated', 'service_role', 'fz_jarvis', 'fz_office_agent', 'fz_auditor', 'backup_reader'] loop
    if exists (select 1 from pg_roles where rolname = r) then execute format('revoke all on schema fz_reception from %I', r); end if;
  end loop;
end $$;

create table if not exists fz_reception.clients (
  id uuid primary key default gen_random_uuid(),
  slug text not null unique check (slug ~ '^[a-z0-9][a-z0-9-]{1,40}$'),
  workspace_id uuid not null unique references public.client_workspaces (id),
  config jsonb not null check (jsonb_typeof(config) = 'object' and config ?& array['business_name', 'timezone', 'hours', 'services', 'faqs', 'escalation_number', 'booking', 'voice']
                               and length(config::text) <= 20000),
  twilio_number text check (twilio_number is null or twilio_number ~ '^\+[1-9][0-9]{7,14}$'),
  status text not null default 'demo' check (status in ('demo', 'live', 'paused')),
  text_back_enabled boolean not null default false,                             -- owner: missed-call text-back may be queued
  text_back_standing boolean not null default false,                            -- owner: queued text-backs need no per-text approval
  max_texts_day integer not null default 50 check (max_texts_day between 0 and 500),
  updated_at timestamptz not null default now()
);
revoke all on fz_reception.clients from public;

create table if not exists fz_reception.calls (
  id uuid primary key default gen_random_uuid(),
  client_id uuid not null references fz_reception.clients (id),
  call_sid text not null unique check (call_sid ~ '^[A-Za-z0-9]{10,64}$'),
  from_phone text,
  lead_id uuid,
  status text not null default 'ringing' check (status in ('ringing', 'in_progress', 'answered', 'missed', 'voicemail', 'escalated', 'completed', 'failed')),
  mode text not null check (mode in ('demo', 'live')),
  duration_s integer not null default 0 check (duration_s >= 0),
  booking_ref text check (booking_ref is null or booking_ref ~ '^[A-Za-z0-9:._-]{1,120}$'),
  summary text check (summary is null or length(summary) <= 1000),
  cost_est_cents integer not null default 0 check (cost_est_cents >= 0),
  started_at timestamptz not null default now(),
  ended_at timestamptz
);
revoke all on fz_reception.calls from public;
create index if not exists reception_calls_client on fz_reception.calls (client_id, started_at);

create table if not exists fz_reception.messages (
  id uuid primary key default gen_random_uuid(),
  client_id uuid not null references fz_reception.clients (id),
  call_id uuid references fz_reception.calls (id),
  lead_id uuid,
  to_phone text not null,
  kind text not null check (kind in ('text_back', 'follow_up', 'booking_confirm')),
  body text not null check (length(body) between 10 and 320),
  status text not null check (status in ('dry_run', 'pending_approval', 'approved', 'sending', 'sent', 'failed', 'rejected', 'cancelled', 'refused')),
  basis text not null,
  provider_sid text check (provider_sid is null or provider_sid ~ '^[A-Za-z0-9]{10,64}$'),
  decided_by text,
  created_at timestamptz not null default now(),
  sent_at timestamptz
);
revoke all on fz_reception.messages from public;
create unique index if not exists reception_one_text_back on fz_reception.messages (call_id) where kind = 'text_back';

-- ---------------------------------------------------------------------------------------------------------------------------- helpers
create or replace function fz_reception.service_path() returns boolean
language sql stable set search_path to 'pg_catalog' as $$
  select coalesce(nullif(current_setting('role', true), ''), 'none') in ('none', 'postgres', 'service_role')
$$;
revoke all on function fz_reception.service_path() from public, anon, authenticated;
create or replace function fz_reception.guard() returns void
language plpgsql stable set search_path to 'pg_catalog' as $$
begin
  if not fz_reception.service_path() then raise exception 'refused' using errcode = '42501'; end if;
end $$;
revoke all on function fz_reception.guard() from public, anon, authenticated;
-- live work (a live call, a real text) also needs the Donna office ACTIVE; demo works while Donna is still being prepared
create or replace function fz_reception.donna_active() returns boolean
language sql stable set search_path to 'pg_catalog' as $$
  select exists (select 1 from public.fz_offices o where o.slug = 'donna' and o.kind = 'office' and o.status = 'active'
                   and (to_regclass('fz_office_os.fz_office_profiles') is null
                        or exists (select 1 from fz_office_os.fz_office_profiles p where p.office_id = o.id and p.status = 'active')))
$$;
revoke all on function fz_reception.donna_active() from public, anon, authenticated;
create or replace function fz_reception.owner_only(p_what text) returns void
language plpgsql stable set search_path to 'pg_catalog' as $$
begin
  if not coalesce(public.is_app_owner(), false) then raise exception 'owner approval required: % is the owner''s decision', p_what using errcode = '42501'; end if;
end $$;
revoke all on function fz_reception.owner_only(text) from public, anon, authenticated;
create or replace function fz_reception.client(p_slug text) returns fz_reception.clients
language plpgsql stable set search_path to 'pg_catalog' as $$
declare c fz_reception.clients;
begin
  select * into c from fz_reception.clients where slug = p_slug;
  if c.id is null then raise exception 'unknown receptionist client %', p_slug; end if;
  if c.status = 'paused' then raise exception 'refused: client % is paused', p_slug using errcode = '42501'; end if;
  return c;
end $$;
revoke all on function fz_reception.client(text) from public, anon, authenticated;
create or replace function fz_reception.stop_word(p text) returns boolean
language sql immutable set search_path to 'pg_catalog' as $$
  select regexp_replace(translate(upper(coalesce(p, '')), 'ÀÂÄÉÈÊËÎÏÔÖÛÙÜÇ', 'AAAEEEEIIOOUUUC'), '[^A-Z]', '', 'g') in ('STOP', 'STOPALL', 'UNSUBSCRIBE', 'CANCEL', 'END', 'QUIT', 'ARRET', 'ARRETER')
$$;
revoke all on function fz_reception.stop_word(text) from public, anon, authenticated;

-- ---------------------------------------------------------------------------------------------------------------------------- service path (the webhook server)
-- the call's config for the voice agent; mode says how the call may be answered ('demo' = only on the owner's demo line)
create or replace function public.reception_client_config(p_slug text) returns jsonb
language plpgsql stable security definer set search_path to 'pg_catalog' as $$
declare c fz_reception.clients;
begin
  perform fz_reception.guard();
  c := fz_reception.client(p_slug);
  return jsonb_build_object('client', c.slug, 'status', c.status, 'live', c.status = 'live' and fz_reception.donna_active(), 'config', c.config,
                            'twilio_number', c.twilio_number, 'text_back_enabled', c.text_back_enabled);
end $$;
revoke all on function public.reception_client_config(text) from public, anon, authenticated;

-- Twilio call status callbacks. A caller becomes (or matches) a lead in the client's workspace: the existing CRM.
create or replace function public.reception_call_event(p_slug text, p_call_sid text, p_from text, p_status text, p_duration integer default 0, p_summary text default null,
                                                      p_cost_est_cents integer default 0) returns jsonb
language plpgsql security definer set search_path to 'pg_catalog' as $$
declare c fz_reception.clients; k fz_reception.calls; v_lead uuid; v_phone text := public.normalize_phone(p_from);
begin
  perform fz_reception.guard();
  c := fz_reception.client(p_slug);
  if p_status not in ('ringing', 'in_progress', 'answered', 'missed', 'voicemail', 'escalated', 'completed', 'failed') then raise exception 'bad call status %', p_status; end if;
  select * into k from fz_reception.calls where call_sid = p_call_sid for update;
  if k.id is not null and k.client_id <> c.id then raise exception 'refused: call belongs to another client' using errcode = '42501'; end if;
  if k.id is null then
    if v_phone is not null then
      select id into v_lead from public.ws_leads where workspace_id = c.workspace_id and public.normalize_phone(phone) = v_phone order by created_at limit 1;
      if v_lead is null then v_lead := public.ws_add_lead(c.workspace_id, null, 'Caller', null, v_phone, 'receptionist_call', null); end if;
    end if;
    insert into fz_reception.calls (client_id, call_sid, from_phone, lead_id, status, mode, duration_s, summary, cost_est_cents)
      values (c.id, p_call_sid, v_phone, v_lead, p_status, case when c.status = 'live' and fz_reception.donna_active() then 'live' else 'demo' end, greatest(coalesce(p_duration, 0), 0),
              left(p_summary, 1000), greatest(coalesce(p_cost_est_cents, 0), 0)) returning * into k;
  else
    update fz_reception.calls set status = case when k.status in ('missed', 'voicemail', 'escalated') and p_status = 'completed' then k.status else p_status end,
           duration_s = greatest(k.duration_s, coalesce(p_duration, 0)), summary = coalesce(left(p_summary, 1000), k.summary),
           cost_est_cents = greatest(k.cost_est_cents, coalesce(p_cost_est_cents, 0)),
           ended_at = case when p_status in ('missed', 'voicemail', 'completed', 'failed') then now() else k.ended_at end
     where id = k.id returning * into k;
  end if;
  return jsonb_build_object('call', k.id, 'status', k.status, 'mode', k.mode, 'lead', k.lead_id);
end $$;
revoke all on function public.reception_call_event(text, text, text, text, integer, text, integer) from public, anon, authenticated;

create or replace function public.reception_booking_record(p_call_sid text, p_booking_ref text) returns jsonb
language plpgsql security definer set search_path to 'pg_catalog' as $$
begin
  perform fz_reception.guard();
  update fz_reception.calls set booking_ref = p_booking_ref where call_sid = p_call_sid;
  if not found then raise exception 'unknown call'; end if;
  return jsonb_build_object('call_sid', p_call_sid, 'booking_ref', p_booking_ref);
end $$;
revoke all on function public.reception_booking_record(text, text) from public, anon, authenticated;

-- queue a text. The rules are here, not in the webhook code.
create or replace function public.reception_queue_sms(p_call_sid text, p_kind text, p_body text) returns jsonb
language plpgsql security definer set search_path to 'pg_catalog' as $$
declare k fz_reception.calls; c fz_reception.clients; v_status text; v_basis text; v_id uuid; v_body text := btrim(regexp_replace(coalesce(p_body, ''), '[[:cntrl:]]+', ' ', 'g'));
begin
  perform fz_reception.guard();
  select * into k from fz_reception.calls where call_sid = p_call_sid;
  if k.id is null then raise exception 'unknown call'; end if;
  select * into c from fz_reception.clients where id = k.client_id;
  if c.status = 'paused' then raise exception 'refused: client % is paused', c.slug using errcode = '42501'; end if;
  if k.from_phone is null or k.lead_id is null then raise exception 'refused: no usable caller number' using errcode = '42501'; end if;
  if position(lower(c.config ->> 'business_name') in lower(v_body)) = 0 or v_body !~* 'reply stop' then
    raise exception 'refused: a text must name the business and carry "Reply STOP to opt out"' using errcode = '42501'; end if;
  if public.ffm_is_phone_suppressed(k.from_phone) or exists (select 1 from public.ffm_consent_log where lead_id = k.lead_id and basis = 'withdrawn' and channel in ('sms', 'all')) then
    raise exception 'refused: the number is suppressed or opted out' using errcode = '42501'; end if;
  if (select count(*) from fz_reception.messages where client_id = c.id and created_at > now() - interval '1 day' and status not in ('refused', 'cancelled', 'rejected')) >= c.max_texts_day then
    raise exception 'refused: daily text ceiling reached for %', c.slug using errcode = '42501'; end if;
  if p_kind = 'text_back' then
    if k.status not in ('missed', 'voicemail') or k.started_at < now() - interval '24 hours' then raise exception 'refused: a text-back answers a missed call from the last 24 hours' using errcode = '42501'; end if;
    if not c.text_back_enabled then raise exception 'refused: missed-call text-back is off for % (owner switch)', c.slug using errcode = '42501'; end if;
    v_basis := 'reply to the caller''s inquiry (missed call ' || k.call_sid || ')';
  elsif p_kind = 'follow_up' then
    if not public.ffm_can_contact(k.lead_id, 'sms') then raise exception 'refused: no current SMS consent for this lead (ffm_can_contact)' using errcode = '42501'; end if;
    v_basis := 'consent log (ffm_contact_status sms)';
  elsif p_kind = 'booking_confirm' then
    if k.booking_ref is null then raise exception 'refused: no booking on this call' using errcode = '42501'; end if;
    v_basis := 'transactional: confirms booking ' || k.booking_ref;
  else
    raise exception 'bad kind %', p_kind;
  end if;
  v_status := case when c.status <> 'live' or k.mode <> 'live' or not fz_reception.donna_active() then 'dry_run'
                   when p_kind = 'text_back' and c.text_back_standing then 'approved'
                   else 'pending_approval' end;
  insert into fz_reception.messages (client_id, call_id, lead_id, to_phone, kind, body, status, basis, decided_by)
    values (c.id, k.id, k.lead_id, k.from_phone, p_kind, v_body, v_status, v_basis, case when v_status = 'approved' then 'owner:standing' end) returning id into v_id;
  insert into public.audit_log (actor, action, target, detail) values ('receptionist', 'reception_sms_' || v_status, 'fz_reception.messages/' || v_id,
    jsonb_build_object('client', c.slug, 'kind', p_kind));
  return jsonb_build_object('message', v_id, 'status', v_status);
end $$;
revoke all on function public.reception_queue_sms(text, text, text) from public, anon, authenticated;

-- the sender claims an APPROVED live text; the suppression list and consent are re-checked at send time
create or replace function public.reception_claim_sms(p_id uuid) returns jsonb
language plpgsql security definer set search_path to 'pg_catalog' as $$
declare m fz_reception.messages; c fz_reception.clients;
begin
  perform fz_reception.guard();
  select * into m from fz_reception.messages where id = p_id for update;
  if m.id is null then raise exception 'unknown message'; end if;
  if m.status <> 'approved' then raise exception 'refused: message is %', m.status using errcode = '42501'; end if;
  select * into c from fz_reception.clients where id = m.client_id;
  if c.status <> 'live' or c.twilio_number is null or not fz_reception.donna_active() then raise exception 'refused: client is not live (or the Donna office is not active)' using errcode = '42501'; end if;
  if public.ffm_is_phone_suppressed(m.to_phone) or exists (select 1 from public.ffm_consent_log where lead_id = m.lead_id and basis = 'withdrawn' and channel in ('sms', 'all'))
     or (m.kind = 'follow_up' and not public.ffm_can_contact(m.lead_id, 'sms')) then
    update fz_reception.messages set status = 'cancelled' where id = m.id;           -- kept (no exception): the cancellation must persist
    return jsonb_build_object('message', m.id, 'status', 'cancelled', 'refused', 'the number opted out or is suppressed');
  end if;
  update fz_reception.messages set status = 'sending' where id = m.id;
  return jsonb_build_object('message', m.id, 'to', m.to_phone, 'from', c.twilio_number, 'body', m.body);
end $$;
revoke all on function public.reception_claim_sms(uuid) from public, anon, authenticated;

create or replace function public.reception_mark_sms(p_id uuid, p_ok boolean, p_provider_sid text default null) returns jsonb
language plpgsql security definer set search_path to 'pg_catalog' as $$
begin
  if not fz_reception.service_path() then raise exception 'refused' using errcode = '42501'; end if;
  update fz_reception.messages set status = case when p_ok then 'sent' else 'failed' end, provider_sid = p_provider_sid, sent_at = case when p_ok then now() end
   where id = p_id and status = 'sending';
  if not found then raise exception 'refused: message is not sending'; end if;
  return jsonb_build_object('message', p_id, 'status', case when p_ok then 'sent' else 'failed' end);
end $$;
revoke all on function public.reception_mark_sms(uuid, boolean, text) from public, anon, authenticated;

-- the sender loop's work list: approved texts of live clients (oldest first)
create or replace function public.reception_pending_sends(p_limit integer default 20) returns jsonb
language plpgsql stable security definer set search_path to 'pg_catalog' as $$
begin
  perform fz_reception.guard();
  return coalesce((select jsonb_agg(id order by created_at) from (select m.id, m.created_at from fz_reception.messages m join fz_reception.clients c on c.id = m.client_id
     where m.status = 'approved' and c.status = 'live' order by m.created_at limit least(greatest(coalesce(p_limit, 20), 1), 100)) x), '[]'::jsonb);
end $$;
revoke all on function public.reception_pending_sends(integer) from public, anon, authenticated;

-- inbound text: STOP (and the French equivalents) withdraws SMS consent through the existing CASL path and cancels queued texts
create or replace function public.reception_inbound_sms(p_slug text, p_from text, p_body text, p_sid text) returns jsonb
language plpgsql security definer set search_path to 'pg_catalog' as $$
declare c fz_reception.clients; v_phone text := public.normalize_phone(p_from); v_lead uuid; n int;
begin
  if not fz_reception.service_path() then raise exception 'refused' using errcode = '42501'; end if;
  select * into c from fz_reception.clients where slug = p_slug;                 -- a STOP is honoured even when the client or Donna is paused
  if c.id is null then raise exception 'unknown receptionist client %', p_slug; end if;
  if not fz_reception.stop_word(p_body) then return jsonb_build_object('opted_out', false); end if;
  if v_phone is null then raise exception 'refused: no usable number'; end if;
  for v_lead in select id from public.ws_leads where workspace_id = c.workspace_id and public.normalize_phone(phone) = v_phone loop
    perform public.ffm_withdraw_consent(c.workspace_id, v_lead, 'sms', 'sms STOP to ' || c.slug, p_sid, 'receptionist');
  end loop;
  update fz_reception.messages set status = 'cancelled' where client_id = c.id and to_phone = v_phone and status in ('pending_approval', 'approved', 'dry_run');
  get diagnostics n = row_count;
  insert into public.audit_log (actor, action, target, detail) values ('receptionist', 'reception_sms_stop', 'fz_reception.clients/' || c.slug, jsonb_build_object('cancelled', n));
  return jsonb_build_object('opted_out', true, 'cancelled', n);
end $$;
revoke all on function public.reception_inbound_sms(text, text, text, text) from public, anon, authenticated;

-- ---------------------------------------------------------------------------------------------------------------------------- owner controls
create or replace function public.reception_owner_set_client(p_slug text, p_workspace uuid, p_config jsonb, p_twilio_number text default null) returns jsonb
language plpgsql security definer set search_path to 'pg_catalog' as $$
declare v uuid;
begin
  perform fz_reception.owner_only('a receptionist client');
  if not exists (select 1 from public.client_workspaces where id = p_workspace) then raise exception 'unknown workspace'; end if;
  insert into fz_reception.clients (slug, workspace_id, config, twilio_number) values (p_slug, p_workspace, p_config, p_twilio_number)
    on conflict (slug) do update set config = excluded.config, twilio_number = excluded.twilio_number, updated_at = now() returning id into v;
  insert into public.audit_log (actor, action, target, detail) values ('owner', 'reception_client', 'fz_reception.clients/' || p_slug, jsonb_build_object('workspace', p_workspace));
  return jsonb_build_object('client', v, 'slug', p_slug);
end $$;
revoke all on function public.reception_owner_set_client(text, uuid, jsonb, text) from public, anon, authenticated;

-- going live and the text switches are the owner's alone
create or replace function public.reception_owner_set_flags(p_slug text, p_status text, p_text_back boolean, p_text_back_standing boolean, p_max_texts_day integer default 50) returns jsonb
language plpgsql security definer set search_path to 'pg_catalog' as $$
begin
  perform fz_reception.owner_only('going live and the text switches');
  if p_status not in ('demo', 'live', 'paused') then raise exception 'bad status %', p_status; end if;
  if p_status = 'live' and (select twilio_number from fz_reception.clients where slug = p_slug) is null then raise exception 'refused: set the client''s Twilio number first'; end if;
  update fz_reception.clients set status = p_status, text_back_enabled = coalesce(p_text_back, false), text_back_standing = coalesce(p_text_back, false) and coalesce(p_text_back_standing, false),
         max_texts_day = coalesce(p_max_texts_day, 50), updated_at = now() where slug = p_slug;
  if not found then raise exception 'unknown receptionist client %', p_slug; end if;
  insert into public.audit_log (actor, action, target, detail) values ('owner', 'reception_flags', 'fz_reception.clients/' || p_slug,
    jsonb_build_object('status', p_status, 'text_back', coalesce(p_text_back, false), 'standing', coalesce(p_text_back_standing, false)));
  return jsonb_build_object('client', p_slug, 'status', p_status);
end $$;
revoke all on function public.reception_owner_set_flags(text, text, boolean, boolean, integer) from public, anon, authenticated;

create or replace function public.reception_owner_decide_sms(p_id uuid, p_approved boolean) returns jsonb
language plpgsql security definer set search_path to 'pg_catalog' as $$
begin
  perform fz_reception.owner_only('sending a text');
  update fz_reception.messages set status = case when p_approved then 'approved' else 'rejected' end, decided_by = 'owner' where id = p_id and status = 'pending_approval';
  if not found then raise exception 'refused: no pending text %', p_id; end if;
  insert into public.audit_log (actor, action, target, detail) values ('owner', 'reception_sms_' || case when p_approved then 'approved' else 'rejected' end, 'fz_reception.messages/' || p_id, '{}'::jsonb);
  return jsonb_build_object('message', p_id, 'status', case when p_approved then 'approved' else 'rejected' end);
end $$;
revoke all on function public.reception_owner_decide_sms(uuid, boolean) from public, anon, authenticated;

create or replace function public.reception_report() returns jsonb
language plpgsql stable security definer set search_path to 'pg_catalog' as $$
begin
  if not fz_reception.service_path() then raise exception 'refused' using errcode = '42501'; end if;
  return coalesce((select jsonb_agg(jsonb_build_object('client', c.slug, 'status', c.status, 'text_back', c.text_back_enabled, 'standing', c.text_back_standing,
           'calls_7d', (select count(*) from fz_reception.calls k where k.client_id = c.id and k.started_at > now() - interval '7 days'),
           'missed_7d', (select count(*) from fz_reception.calls k where k.client_id = c.id and k.started_at > now() - interval '7 days' and k.status in ('missed', 'voicemail')),
           'booked_7d', (select count(*) from fz_reception.calls k where k.client_id = c.id and k.started_at > now() - interval '7 days' and k.booking_ref is not null),
           'minutes_7d', (select round(coalesce(sum(k.duration_s), 0) / 60.0, 1) from fz_reception.calls k where k.client_id = c.id and k.started_at > now() - interval '7 days'),
           'cost_est_cents_7d', (select coalesce(sum(k.cost_est_cents), 0) from fz_reception.calls k where k.client_id = c.id and k.started_at > now() - interval '7 days'),
           'texts_pending', (select count(*) from fz_reception.messages m where m.client_id = c.id and m.status = 'pending_approval'),
           'texts_sent_7d', (select count(*) from fz_reception.messages m where m.client_id = c.id and m.status = 'sent' and m.created_at > now() - interval '7 days')) order by c.slug)
    from fz_reception.clients c), '[]'::jsonb);
end $$;
revoke all on function public.reception_report() from public, anon, authenticated;

do $$ declare r text; f regprocedure; begin
  foreach r in array array['fz_jarvis', 'fz_office_agent', 'fz_auditor', 'backup_reader'] loop
    continue when not exists (select 1 from pg_roles where rolname = r);
    for f in select p.oid::regprocedure from pg_proc p where p.pronamespace = 'public'::regnamespace and p.proname like 'reception\_%' loop
      execute format('revoke all on function %s from %I', f, r);
    end loop;
  end loop;
end $$;
