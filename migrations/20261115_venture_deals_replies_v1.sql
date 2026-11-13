-- Deals, reply tracking, do-not-contact and per-venture operating config (VENTURE_FACTORY.md, "Deals, replies and do-not-contact").
-- Safe to re-run. Touches NO spend control, cap, kill switch, dry-run, permission or capital function. Nothing here sends anything.
--   contact_suppressions     one row per suppressed address (CASL): survives lead deletion, shared by every venture.
--   lead_replies             the owner's record of a reply on a lead (interested / not_interested / question / unsubscribe / booked).
--   venture_config           offer, call to action, reply SLA per venture (the prospecting brief stays a venture_procedures row).
--   is_suppressed(addr)      true when the address is on the suppression list.
--   mark_do_not_contact()    flags EVERY lead sharing the address (all ventures), suppresses it, rejects open drafts to it.
--   record_lead_reply()      owner-only; 'unsubscribe' calls mark_do_not_contact.
--   create_deal / set_deal_stage / confirm_deal_won   owner-confirmed deal pipeline. Revenue is written ONLY by confirm_deal_won.
--   lead_funnel(), venture_kpis() (replaced, adds funnel/replies/SLA), venture_config_get(), set_venture_config()
--   triggers: leads_suppression_guard (a suppressed address can never be un-flagged or re-added clean),
--             leads_dnc_cascade (any path that flags a lead do-not-contact cascades), outbox_dnc_guard (a do-not-contact lead
--             or suppressed address can never be drafted, qa-passed, approved or sent).
-- Deal stages. The ONLY stage names found in the repo are the table default 'pitched' (core schema) and the won-like names that
-- venture_kpis already counts ('won','closed','closed_won','paid'). The pipeline therefore uses: pitched -> negotiating -> won | lost,
-- and treats the legacy won-like names as already won (terminal). No CHECK constraint is added, so existing rows are never invalidated.

create table if not exists public.contact_suppressions (
  address text primary key check (address = lower(btrim(address)) and position('@' in address) > 1),
  reason text not null,
  recorded_by text not null,
  source_lead uuid,
  recorded_at timestamptz not null default now()
);
alter table public.contact_suppressions enable row level security;

create table if not exists public.lead_replies (
  id uuid primary key default gen_random_uuid(),
  lead_id uuid not null references public.leads(id),
  venture_id uuid not null references public.ventures(id),
  kind text not null check (kind in ('interested','not_interested','question','unsubscribe','booked')),
  note text,
  recorded_by text not null,
  created_at timestamptz not null default now()
);
alter table public.lead_replies enable row level security;
create index if not exists lead_replies_lead_idx on public.lead_replies(lead_id, created_at desc);
create index if not exists lead_replies_venture_idx on public.lead_replies(venture_id, created_at desc);

create table if not exists public.venture_config (
  venture_id uuid primary key references public.ventures(id) on delete cascade,
  offer text check (offer is null or length(offer) between 10 and 600),
  call_to_action text check (call_to_action is null or length(call_to_action) between 5 and 300),
  reply_sla_hours int check (reply_sla_hours is null or reply_sla_hours between 1 and 720),
  updated_by text not null default 'owner',
  updated_at timestamptz not null default now()
);
alter table public.venture_config enable row level security;

-- Addresses already flagged do-not-contact before this migration are carried onto the suppression list (additive, conservative).
insert into public.contact_suppressions (address, reason, recorded_by)
select distinct lower(btrim(email)), 'lead already flagged do-not-contact before suppression list', 'migration'
from public.leads where do_not_contact and email is not null and position('@' in btrim(email)) > 1
on conflict do nothing;

create or replace function public.is_suppressed(p_address text) returns boolean
language sql stable set search_path to 'public' as $$
  select p_address is not null and exists (select 1 from public.contact_suppressions where address = lower(btrim(p_address)))
$$;

create or replace function public.mark_do_not_contact(p_lead uuid, p_reason text, p_by text) returns jsonb
language plpgsql security definer set search_path to 'public' as $$
declare l public.leads; addr text; n_leads int := 0; n_drafts int := 0; ids uuid[];
begin
  select * into l from public.leads where id = p_lead;
  if not found then raise exception 'No such lead.'; end if;
  addr := nullif(lower(btrim(coalesce(l.email, ''))), '');
  if addr is not null and position('@' in addr) > 1 then
    insert into public.contact_suppressions (address, reason, recorded_by, source_lead)
    values (addr, left(coalesce(nullif(btrim(p_reason), ''), 'do not contact'), 300), coalesce(p_by, 'unknown'), l.id)
    on conflict do nothing;
    select coalesce(array_agg(id), '{}') into ids from public.leads where lower(btrim(coalesce(email, ''))) = addr or id = l.id;
  else
    addr := null;
    ids := array[l.id];
  end if;
  update public.leads set do_not_contact = true, status = 'do_not_contact', next_followup_at = null where id = any(ids);
  get diagnostics n_leads = row_count;
  update public.outbox set status = 'rejected', decided_at = now()
   where status in ('draft','qa_passed','approved')
     and (lead_id = any(ids) or (addr is not null and lower(btrim(coalesce(to_ref, ''))) = addr));
  get diagnostics n_drafts = row_count;
  insert into public.audit_log (actor, action, target, detail)
  values (coalesce(p_by, 'unknown'), 'do_not_contact', 'leads/' || l.id,
          jsonb_build_object('leads_marked', n_leads, 'drafts_rejected', n_drafts, 'address_suppressed', addr is not null,
                             'reason', left(coalesce(p_reason, ''), 300)));
  return jsonb_build_object('leads_marked', n_leads, 'drafts_rejected', n_drafts, 'address_suppressed', addr is not null);
end $$;

create or replace function public.record_lead_reply(p_lead uuid, p_kind text, p_note text, p_by text) returns jsonb
language plpgsql security definer set search_path to 'public' as $$
declare l public.leads; order_ text[] := array['new','drafted','approved_to_send','contacted','sent','replied','booked','won'];
        cur int; target text; dnc jsonb;
begin
  if coalesce(p_by, '') not like 'owner%' then raise exception 'Only the owner records a reply.'; end if;
  if p_kind not in ('interested','not_interested','question','unsubscribe','booked') then
    raise exception 'Reply kind must be interested, not_interested, question, unsubscribe or booked.'; end if;
  select * into l from public.leads where id = p_lead;
  if not found then raise exception 'No such lead.'; end if;
  insert into public.lead_replies (lead_id, venture_id, kind, note, recorded_by)
  values (l.id, l.venture_id, p_kind, left(nullif(btrim(coalesce(p_note, '')), ''), 500), p_by);
  if p_kind = 'unsubscribe' then
    dnc := public.mark_do_not_contact(l.id, 'unsubscribe reply: ' || coalesce(p_note, ''), p_by);
    return jsonb_build_object('kind', p_kind, 'status', 'do_not_contact') || dnc;
  end if;
  if l.do_not_contact or l.status in ('won','do_not_contact') then   -- a reply never lifts do-not-contact and never demotes a win
    return jsonb_build_object('kind', p_kind, 'status', l.status, 'unchanged', true);
  end if;
  cur := coalesce(array_position(order_, l.status), 0);
  target := case p_kind when 'not_interested' then 'lost'
                        when 'booked' then 'booked'
                        else 'replied' end;
  if target = 'lost' or cur < array_position(order_, target) then
    update public.leads set status = target, next_followup_at = case when target in ('lost','booked') then null else next_followup_at end
     where id = l.id;
  else
    target := l.status;
  end if;
  return jsonb_build_object('kind', p_kind, 'status', target);
end $$;

-- ---------- deals ----------
create or replace function public.create_deal(p_lead uuid, p_value_cents int, p_by text, p_note text default null) returns uuid
language plpgsql security definer set search_path to 'public' as $$
declare l public.leads; d uuid;
begin
  if coalesce(p_by, '') not like 'owner%' then raise exception 'Only the owner opens a deal.'; end if;
  select * into l from public.leads where id = p_lead;
  if not found then raise exception 'No such lead.'; end if;
  if l.do_not_contact or public.is_suppressed(l.email) then raise exception 'That lead is do-not-contact; no deal can be opened.'; end if;
  if p_value_cents is not null and p_value_cents < 0 then raise exception 'Deal value cannot be negative.'; end if;
  insert into public.deals (venture_id, lead_id, stage, value_cents, notes)
  values (l.venture_id, l.id, 'pitched', p_value_cents, left(p_note, 500)) returning id into d;
  insert into public.audit_log (actor, action, target, detail)
  values (p_by, 'deal_created', 'deals/' || d, jsonb_build_object('lead', l.id, 'value_cents', p_value_cents));
  return d;
end $$;

create or replace function public.set_deal_stage(p_deal uuid, p_stage text, p_by text, p_note text default null) returns jsonb
language plpgsql security definer set search_path to 'public' as $$
declare d public.deals; ok boolean;
begin
  if coalesce(p_by, '') not like 'owner%' then raise exception 'Only the owner moves a deal.'; end if;
  select * into d from public.deals where id = p_deal for update;
  if not found then raise exception 'No such deal.'; end if;
  if p_stage = 'won' then raise exception 'A deal is won only by confirming it with an amount (confirm_deal_won): that is what records revenue.'; end if;
  if p_stage not in ('pitched','negotiating','lost') then raise exception 'Stage must be pitched, negotiating or lost.'; end if;
  ok := (d.stage = 'pitched' and p_stage in ('negotiating','lost'))
     or (d.stage = 'negotiating' and p_stage in ('pitched','lost'));
  if not ok then raise exception 'Deal stage % -> % is not allowed.', d.stage, p_stage; end if;
  update public.deals set stage = p_stage, updated_at = now(), notes = left(coalesce(nullif(btrim(p_note), ''), notes), 500) where id = d.id;
  if p_stage = 'lost' and d.lead_id is not null then
    update public.leads set status = 'lost' where id = d.lead_id and not do_not_contact and status not in ('won','do_not_contact');
  end if;
  insert into public.audit_log (actor, action, target, detail)
  values (p_by, 'deal_stage', 'deals/' || d.id, jsonb_build_object('from', d.stage, 'to', p_stage, 'note', left(coalesce(p_note, ''), 200)));
  return jsonb_build_object('deal', d.id, 'from', d.stage, 'to', p_stage);
end $$;

-- The ONE place a deal becomes won and the ONE place this feature writes the ledger. It never infers an amount.
create or replace function public.confirm_deal_won(p_deal uuid, p_amount_cents int, p_ledger_status text, p_by text, p_note text default null) returns jsonb
language plpgsql security definer set search_path to 'public' as $$
declare d public.deals; led uuid;
begin
  if coalesce(p_by, '') not like 'owner%' then raise exception 'Only the owner confirms a win.'; end if;
  if p_amount_cents is null or p_amount_cents <= 0 then raise exception 'Confirming a win needs a positive amount.'; end if;
  if p_ledger_status not in ('received','expected') then raise exception 'Say whether the money is received or expected.'; end if;
  select * into d from public.deals where id = p_deal for update;
  if not found then raise exception 'No such deal.'; end if;
  if d.stage not in ('pitched','negotiating') then raise exception 'Deal is already %; revenue is never recorded twice.', d.stage; end if;
  if exists (select 1 from public.ledger where note like 'deal ' || d.id || '%') then raise exception 'Revenue for this deal is already recorded.'; end if;
  insert into public.ledger (venture_id, kind, amount_cents, currency, status, note, occurred_on)
  values (d.venture_id, 'revenue', p_amount_cents, 'CAD', p_ledger_status, left('deal ' || d.id || ': owner confirmed win' || coalesce(' - ' || nullif(btrim(p_note), ''), ''), 300),
          (now() at time zone 'America/Toronto')::date) returning id into led;
  update public.deals set stage = 'won', value_cents = p_amount_cents, updated_at = now() where id = d.id;
  if d.lead_id is not null then
    update public.leads set status = 'won', next_followup_at = null where id = d.lead_id and not do_not_contact;
  end if;
  insert into public.audit_log (actor, action, target, detail)
  values (p_by, 'deal_won', 'deals/' || d.id, jsonb_build_object('amount_cents', p_amount_cents, 'ledger', led, 'ledger_status', p_ledger_status));
  return jsonb_build_object('deal', d.id, 'amount_cents', p_amount_cents, 'ledger_id', led, 'ledger_status', p_ledger_status);
end $$;

-- ---------- config ----------
create or replace function public.venture_config_get(p_venture text) returns jsonb
language plpgsql stable set search_path to 'public' as $$
declare v public.ventures; c public.venture_config;
begin
  select * into v from public.ventures where slug = p_venture;
  if not found then return null; end if;
  select * into c from public.venture_config where venture_id = v.id;
  return jsonb_build_object('venture', v.slug, 'offer', c.offer, 'call_to_action', c.call_to_action,
    'reply_sla_hours', coalesce(c.reply_sla_hours, 24), 'reply_sla_is_default', c.reply_sla_hours is null,
    'prospecting_brief_set', exists (select 1 from public.venture_procedures p where p.venture_id = v.id and p.title = 'prospecting brief'
                                      and p.status = 'active' and length(btrim(p.steps)) >= 20),
    -- fail closed: a venture other than donna needs BOTH an offer and a call to action before a draft for it can be approved
    'drafts_ready', v.slug = 'donna' or (c.offer is not null and c.call_to_action is not null));
end $$;

create or replace function public.set_venture_config(p_venture text, p_key text, p_value text, p_by text) returns jsonb
language plpgsql security definer set search_path to 'public' as $$
declare v public.ventures; val text := nullif(btrim(coalesce(p_value, '')), '');
begin
  if coalesce(p_by, '') not like 'owner%' then raise exception 'Only the owner changes venture config.'; end if;
  select * into v from public.ventures where slug = p_venture;
  if not found then raise exception 'No such venture.'; end if;
  if p_key not in ('offer','call_to_action','reply_sla_hours') then raise exception 'Config key must be offer, call_to_action or reply_sla_hours.'; end if;
  if val ~* '(password|passwd|secret|api[_-]?key|token)\s*[:=]|sk-[A-Za-z0-9]{10,}' then raise exception 'Config must not contain credentials.'; end if;
  insert into public.venture_config (venture_id, updated_by) values (v.id, p_by) on conflict do nothing;
  if p_key = 'offer' then update public.venture_config set offer = val where venture_id = v.id;
  elsif p_key = 'call_to_action' then update public.venture_config set call_to_action = val where venture_id = v.id;
  else
    if val is not null and val !~ '^[0-9]{1,3}$' then raise exception 'reply_sla_hours must be a whole number of hours (1-720).'; end if;
    update public.venture_config set reply_sla_hours = val::int where venture_id = v.id;
  end if;
  update public.venture_config set updated_by = p_by, updated_at = now() where venture_id = v.id;
  insert into public.audit_log (actor, action, target, detail)
  values (p_by, 'venture_config', 'ventures/' || v.slug, jsonb_build_object('key', p_key, 'cleared', val is null));
  return public.venture_config_get(p_venture);
end $$;

-- ---------- funnel + KPIs (read-only) ----------
create or replace function public.lead_funnel(p_venture text) returns jsonb
language plpgsql stable set search_path to 'public' as $$
declare v public.ventures; sla int; counts jsonb; stale int;
begin
  select * into v from public.ventures where slug = p_venture;
  if not found then return null; end if;
  sla := coalesce((select reply_sla_hours from public.venture_config where venture_id = v.id), 24);
  select jsonb_build_object(
      'new', count(*) filter (where b = 'new'), 'drafted', count(*) filter (where b = 'drafted'),
      'approved_to_send', count(*) filter (where b = 'approved_to_send'), 'sent', count(*) filter (where b = 'sent'),
      'replied', count(*) filter (where b = 'replied'), 'booked', count(*) filter (where b = 'booked'),
      'won', count(*) filter (where b = 'won'), 'lost', count(*) filter (where b = 'lost'),
      'do_not_contact', count(*) filter (where b = 'do_not_contact'), 'other', count(*) filter (where b = 'other'))
    into counts
    from (select case when do_not_contact then 'do_not_contact'
                      when status in ('new','drafted','approved_to_send','replied','booked','won','lost','do_not_contact') then status
                      when status in ('contacted','sent') then 'sent'   -- 'contacted' is what mark_sent / hq_mail actually write
                      else 'other' end b
            from public.leads where venture_id = v.id) s;
  -- replies waiting on the owner longer than the SLA: still 'replied', last recorded reply is interested/question and older than sla hours
  select count(*) into stale from public.leads l
   where l.venture_id = v.id and not l.do_not_contact and l.status = 'replied'
     and (select max(r.created_at) from public.lead_replies r where r.lead_id = l.id and r.kind in ('interested','question')) < now() - make_interval(hours => sla);
  return jsonb_build_object('venture', v.slug, 'counts', counts, 'total', (select count(*) from public.leads where venture_id = v.id),
    'reply_sla_hours', sla, 'replies_over_sla', stale,
    'replies_by_kind', coalesce((select jsonb_object_agg(kind, n) from (select kind, count(*) n from public.lead_replies where venture_id = v.id group by kind) r), '{}'::jsonb));
end $$;

create or replace function public.venture_kpis(p_venture text) returns jsonb
language plpgsql stable set search_path to 'public' as $$
declare v public.ventures; f jsonb;
begin
  select * into v from public.ventures where slug = p_venture;
  if not found then return null; end if;
  f := public.lead_funnel(p_venture);
  return jsonb_build_object(
    'venture', v.slug,
    'leads', (select count(*) from public.leads where venture_id = v.id),
    'emailable_leads', (select count(*) from public.leads where venture_id = v.id and email is not null and do_not_contact = false),
    'drafted', (select count(*) from public.outbox o left join public.leads l on l.id = o.lead_id where coalesce(o.venture_id, l.venture_id) = v.id),
    'approved', (select count(*) from public.outbox o left join public.leads l on l.id = o.lead_id where coalesce(o.venture_id, l.venture_id) = v.id and o.status in ('approved','sent')),
    'sent', (select count(*) from public.outbox o left join public.leads l on l.id = o.lead_id where coalesce(o.venture_id, l.venture_id) = v.id and o.status = 'sent'),
    'won_deals', (select count(*) from public.deals where venture_id = v.id and lower(stage) in ('won','closed','closed_won','paid')),
    'deals_by_stage', coalesce((select jsonb_object_agg(stage, n) from (select stage, count(*) n from public.deals where venture_id = v.id group by stage) d), '{}'::jsonb),
    'revenue_cents', coalesce((select sum(amount_cents) from public.ledger where venture_id = v.id and kind = 'revenue' and status = 'received' and intercompany = false), 0),
    'funnel', f->'counts', 'replies_by_kind', f->'replies_by_kind', 'replies_over_sla', f->'replies_over_sla', 'reply_sla_hours', f->'reply_sla_hours');
end $$;

-- ---------- guards ----------
-- A suppressed address can never be (re)added clean or un-flagged, whichever path writes the lead.
create or replace function public.leads_suppression_guard() returns trigger
language plpgsql set search_path to 'public' as $$
begin
  if public.is_suppressed(new.email) then
    new.do_not_contact := true;
    if tg_op = 'INSERT' or new.status is distinct from 'do_not_contact' then new.status := 'do_not_contact'; end if;
    new.next_followup_at := null;
  end if;
  return new;
end $$;
drop trigger if exists leads_suppression_guard on public.leads;
create trigger leads_suppression_guard before insert or update on public.leads
  for each row execute function public.leads_suppression_guard();

-- Any path (raw update included) that flags a lead do-not-contact cascades to every lead and draft sharing the address.
create or replace function public.leads_dnc_cascade() returns trigger
language plpgsql security definer set search_path to 'public' as $$
begin
  if new.do_not_contact and new.email is not null and not public.is_suppressed(new.email) then
    perform public.mark_do_not_contact(new.id, 'lead flagged do-not-contact', 'system:trigger');
  end if;
  return null;
end $$;
drop trigger if exists leads_dnc_cascade on public.leads;
create trigger leads_dnc_cascade after insert or update of do_not_contact on public.leads
  for each row when (new.do_not_contact) execute function public.leads_dnc_cascade();

-- Last line of defence for every drafting / approval / send path. Rejecting a draft is always allowed.
create or replace function public.outbox_dnc_guard() returns trigger
language plpgsql set search_path to 'public' as $$
declare dnc boolean := false;
begin
  if new.status not in ('draft','qa_passed','approved','sent') then return new; end if;
  if tg_op = 'UPDATE' and new.status is not distinct from old.status then return new; end if;   -- only progress is guarded
  if new.lead_id is not null then
    select do_not_contact into dnc from public.leads where id = new.lead_id;
  end if;
  if coalesce(dnc, false) or (new.channel = 'email' and public.is_suppressed(new.to_ref)) then
    raise exception 'Do-not-contact: this lead or address has opted out (CASL). No draft, approval or send is allowed.' using errcode = 'P0001';
  end if;
  return new;
end $$;
drop trigger if exists outbox_dnc_guard on public.outbox;
create trigger outbox_dnc_guard before insert or update on public.outbox
  for each row execute function public.outbox_dnc_guard();

revoke all on function public.is_suppressed(text) from public, anon, authenticated;
grant execute on function public.is_suppressed(text) to service_role;
revoke all on function public.mark_do_not_contact(uuid, text, text) from public, anon, authenticated;
grant execute on function public.mark_do_not_contact(uuid, text, text) to service_role;
revoke all on function public.record_lead_reply(uuid, text, text, text) from public, anon, authenticated;
grant execute on function public.record_lead_reply(uuid, text, text, text) to service_role;
revoke all on function public.create_deal(uuid, int, text, text) from public, anon, authenticated;
grant execute on function public.create_deal(uuid, int, text, text) to service_role;
revoke all on function public.set_deal_stage(uuid, text, text, text) from public, anon, authenticated;
grant execute on function public.set_deal_stage(uuid, text, text, text) to service_role;
revoke all on function public.confirm_deal_won(uuid, int, text, text, text) from public, anon, authenticated;
grant execute on function public.confirm_deal_won(uuid, int, text, text, text) to service_role;
revoke all on function public.venture_config_get(text) from public, anon, authenticated;
grant execute on function public.venture_config_get(text) to service_role;
revoke all on function public.set_venture_config(text, text, text, text) from public, anon, authenticated;
grant execute on function public.set_venture_config(text, text, text, text) to service_role;
revoke all on function public.lead_funnel(text) from public, anon, authenticated;
grant execute on function public.lead_funnel(text) to service_role;
revoke all on function public.venture_kpis(text) from public, anon, authenticated;
grant execute on function public.venture_kpis(text) to service_role;
revoke all on function public.leads_suppression_guard() from public, anon, authenticated;
grant execute on function public.leads_suppression_guard() to service_role;
revoke all on function public.leads_dnc_cascade() from public, anon, authenticated;
grant execute on function public.leads_dnc_cascade() to service_role;
revoke all on function public.outbox_dnc_guard() from public, anon, authenticated;
grant execute on function public.outbox_dnc_guard() to service_role;
