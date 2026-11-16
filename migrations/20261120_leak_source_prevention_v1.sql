-- Client-data leak paths, SOURCE-LEVEL prevention (the export-level net is 20261120_backup_redact_leak_paths_v1; this runs after it).
-- The system used to copy client free text into tables that ARE exported. From now on the writers store ids, codes and counts, never the text itself:
--   mark_do_not_contact   audit_log.detail 'reason' was left(p_reason, 300) = the owner's reply note (names, emails, phones). Now: a reason CODE (unsubscribe_reply | lead_flag | owner_text | none)
--                         plus the length. The text is still kept where it belongs: lead_replies.note and contact_suppressions.reason (client_pii tables, never exported).
--   record_lead_reply     no longer passes the reply note on to mark_do_not_contact (it stays in lead_replies.note).
--   set_deal_stage        audit_log.detail 'note' (200 chars of owner text) becomes 'note_chars' (a count). The note itself is still saved on the deal (deals.notes, client_pii).
--   confirm_deal_won      ledger.note was 'deal <id>: owner confirmed win - <free text>'. Now exactly 'deal <id>: owner confirmed win' (the duplicate-revenue check on that prefix is unchanged);
--                         the owner's note is kept on the deal (deals.notes).
--   setter_record_payout  ledger.note named the setter ('Setter payout (close): Sam Setter'). Now 'Setter payout (close): setter <setter uuid>'. The owner-facing reply still shows the name.
--   agent_runs.summary    no repo code writes it (the agent framework does): a BEFORE INSERT/UPDATE trigger now scrubs emails, phones, URLs with personal paths and known client names (LIGHT mode,
--                         it never blanks a summary), so a writer this repo does not control cannot put client contact data in.
-- Each replaced body is the LIVE production definition (read with pg_get_functiondef on Nov 15 2026: md5s equal to the repo's) with only the lines above changed; they are marked LEAK-SOURCE-FIX v1.
-- Money, statuses, state machines, do-not-contact cascade, suppression list and every guard are untouched. Rollback: ops/rollback_leak_redaction.sql.
create or replace function public.mark_do_not_contact(p_lead uuid, p_reason text, p_by text) returns jsonb
language plpgsql security definer set search_path to 'public' as $$
declare l public.leads; addr text; n_leads int := 0; n_drafts int := 0; ids uuid[]; d record; v_code text;
begin
  -- LEAK-SOURCE-FIX v1: the audit row gets a reason code, never the free text
  v_code := case when nullif(btrim(coalesce(p_reason, '')), '') is null then 'none'
                 when p_reason like 'unsubscribe reply%' then 'unsubscribe_reply'
                 when p_reason = 'lead flagged do-not-contact' then 'lead_flag'
                 else 'owner_text' end;
  select * into l from public.leads where id = p_lead;
  if not found then raise exception 'No such lead.'; end if;
  addr := public.normalize_addr(l.email);
  if addr is not null then
    insert into public.contact_suppressions (address, reason, recorded_by, source_lead)
    values (addr, left(coalesce(nullif(btrim(p_reason), ''), 'do not contact'), 300), coalesce(p_by, 'unknown'), l.id)
    on conflict do nothing;
    select coalesce(array_agg(id), '{}') into ids from public.leads where public.normalize_addr(email) = addr or id = l.id;
  else
    addr := null;
    ids := array[l.id];
  end if;
  for d in select id, lead_id, to_ref from public.outbox
            where status in ('draft','qa_passed','approved')
              and (lead_id = any(ids) or (addr is not null and public.normalize_addr(to_ref) = addr)) loop
    begin
      update public.outbox set status = 'rejected', decided_at = now() where id = d.id;
    exception when others then
      update public.outbox set status = 'rejected', decided_at = now(), to_ref = null, lead_id = null,
             qa_notes = left('opt-out: was to ' || coalesce(d.to_ref, '?') || ', lead ' || coalesce(d.lead_id::text, '?'), 300) where id = d.id;
    end;
    n_drafts := n_drafts + 1;
  end loop;
  update public.leads set do_not_contact = true, status = 'do_not_contact', next_followup_at = null where id = any(ids);
  get diagnostics n_leads = row_count;
  insert into public.audit_log (actor, action, target, detail)
  values (coalesce(p_by, 'unknown'), 'do_not_contact', 'leads/' || l.id,
          jsonb_build_object('leads_marked', n_leads, 'drafts_rejected', n_drafts, 'address_suppressed', addr is not null,
                             'reason', v_code, 'reason_code', v_code, 'reason_chars', length(coalesce(p_reason, ''))));
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
    dnc := public.mark_do_not_contact(l.id, 'unsubscribe reply', p_by);   -- LEAK-SOURCE-FIX v1: the reply note stays in lead_replies.note (not exported); it is not copied into the audit row
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
  insert into public.audit_log (actor, action, target, detail)   -- LEAK-SOURCE-FIX v1: a count, not the owner's text (the text is kept in deals.notes)
  values (p_by, 'deal_stage', 'deals/' || d.id, jsonb_build_object('from', d.stage, 'to', p_stage, 'note_chars', length(coalesce(p_note, ''))));
  return jsonb_build_object('deal', d.id, 'from', d.stage, 'to', p_stage);
end $$;

create or replace function public.confirm_deal_won(p_deal uuid, p_amount_cents int, p_ledger_status text, p_by text, p_note text default null) returns jsonb
language plpgsql security definer set search_path to 'public' as $$
declare d public.deals; led uuid;
begin
  if coalesce(p_by, '') not like 'owner%' then raise exception 'Only the owner confirms a win.'; end if;
  if p_amount_cents is null or p_amount_cents <= 0 then raise exception 'Confirming a win needs a positive amount.'; end if;
  if p_amount_cents > 10000000 then raise exception 'Amount is above the 10,000,000 cent (CAD $100,000) limit; confirm a smaller amount or split it.'; end if;
  if p_ledger_status not in ('received','expected') then raise exception 'Say whether the money is received or expected.'; end if;
  select * into d from public.deals where id = p_deal for update;
  if not found then raise exception 'No such deal.'; end if;
  if d.stage not in ('pitched','negotiating') then raise exception 'Deal is already %; revenue is never recorded twice.', d.stage; end if;
  if exists (select 1 from public.ledger where note like 'deal ' || d.id || '%') then raise exception 'Revenue for this deal is already recorded.'; end if;
  insert into public.ledger (venture_id, kind, amount_cents, currency, status, note, occurred_on)   -- LEAK-SOURCE-FIX v1: no owner free text in the books (it is kept in deals.notes)
  values (d.venture_id, 'revenue', p_amount_cents, 'CAD', p_ledger_status, 'deal ' || d.id || ': owner confirmed win',
          (now() at time zone 'America/Toronto')::date) returning id into led;
  update public.deals set stage = 'won', value_cents = p_amount_cents, updated_at = now(), notes = left(coalesce(nullif(btrim(p_note), ''), notes), 500) where id = d.id;
  if d.lead_id is not null then
    update public.leads set status = 'won', next_followup_at = null where id = d.lead_id and not do_not_contact;
  end if;
  insert into public.audit_log (actor, action, target, detail)
  values (p_by, 'deal_won', 'deals/' || d.id, jsonb_build_object('amount_cents', p_amount_cents, 'ledger', led, 'ledger_status', p_ledger_status));
  return jsonb_build_object('deal', d.id, 'amount_cents', p_amount_cents, 'ledger_id', led, 'ledger_status', p_ledger_status);
end $$;

create or replace function public.setter_record_payout(p_name text, p_kind text, p_cents int, p_reference text default null, p_period text default null) returns jsonb
language plpgsql security definer set search_path to 'public' as $$
declare s public.setters%rowtype; v_owed int; v_venture uuid;
begin
  select * into s from public.setters where lower(trim(name)) = lower(trim(p_name));
  if not found then return jsonb_build_object('error', 'No setter with that name.'); end if;
  if p_kind not in ('close','recurring','bonus') or coalesce(p_cents, 0) <= 0 then return jsonb_build_object('error', 'Need a kind (close, recurring, bonus) and an amount above zero.'); end if;
  if p_kind = 'close' then
    select owed_close_cents into v_owed from public.setter_standing where id = s.id;
    if p_cents > v_owed then return jsonb_build_object('error', format('Only $%s is owed for closed deals.', v_owed / 100.0)); end if;
  elsif p_kind = 'recurring' then
    p_period := coalesce(p_period, to_char(now() at time zone 'America/Toronto', 'YYYY-MM'));
    select owed_recurring_cents into v_owed from public.setter_standing where id = s.id;
    if p_cents > v_owed then return jsonb_build_object('error', format('Only $%s is owed as recurring this month.', v_owed / 100.0)); end if;
  end if;
  insert into public.setter_payouts (setter_id, kind, cents, period, reference) values (s.id, p_kind, p_cents, p_period, nullif(trim(p_reference), ''));
  select id into v_venture from public.ventures where slug = 'donna' limit 1;
  insert into public.ledger (venture_id, kind, amount_cents, currency, note, status)   -- LEAK-SOURCE-FIX v1: the setter's id, not the setter's name
    values (v_venture, 'expense', p_cents, 'CAD', format('Setter payout (%s): setter %s', p_kind, s.id), 'received');
  return jsonb_build_object('ok', true, 'name', s.name);
end $$;

-- agent_runs.summary: scrubbed on every write, whoever writes it (LIGHT mode: patterns and known client names; never blanks the summary)
create or replace function public.agent_runs_scrub() returns trigger
language plpgsql security definer set search_path to 'pg_catalog' as $$
begin
  if new.summary is not null then new.summary := public.backup_redact_text(new.summary, null, null, 'light'); end if;   -- LEAK-SOURCE-FIX v1
  return new;
end $$;
drop trigger if exists agent_runs_scrub on public.agent_runs;
create trigger agent_runs_scrub before insert or update of summary on public.agent_runs for each row execute function public.agent_runs_scrub();

-- Round 8 (S1, write path): a venture SLUG is built from the venture NAME, which an LLM tool writes (hq_ventures.slugify), and create_venture() copies the slug into departments, agents and the audit trail.
-- A slug that contains a word the deny-list knows as a client / contact name token of 5+ letters is refused here, before any of those copies exist; hq_ventures.start() then retries once with a neutral slug
-- ('venture-<8 hex>'). The name itself stays where it belongs (ventures.name: exported under strict redaction). Shorter tokens and names learned later are covered at export time (mode 'slug':
-- keyed pseudonym). The message never repeats the name. Only the slug is checked, only when it is set or changed.
create or replace function public.redaction_venture_slug_guard() returns trigger
language plpgsql volatile security definer set search_path to 'pg_catalog' as $$
declare pads text; w text; stop text[];
begin
  if NEW.slug is null or (TG_OP = 'UPDATE' and NEW.slug is not distinct from OLD.slug) then return NEW; end if;
  if to_regprocedure('public.redaction_pads()') is null or to_regclass('public.ffm_redaction_denylist') is null then return NEW; end if;
  pads := public.redaction_pads();
  if pads is null then return NEW; end if;
  stop := public.backup_stopwords();
  foreach w in array regexp_split_to_array(lower(public.backup_fold_text(NEW.slug)), '[^a-z0-9]+') loop
    continue when length(w) < 5 or w = any (stop) or w ~ '^[0-9]+$';
    if exists (select 1 from public.ffm_redaction_denylist d where d.kind = 'n' and d.h = public.redaction_h(pads, 'n', w)) then
      raise exception 'venture slug contains a known client or contact name: use a neutral slug (the name stays in the venture name)' using errcode = '23514', hint = 'neutral_slug';
    end if;
  end loop;
  return NEW;
end $$;
drop trigger if exists redaction_venture_slug_guard on public.ventures;
create trigger redaction_venture_slug_guard before insert or update of slug on public.ventures for each row execute function public.redaction_venture_slug_guard();
revoke all on function public.redaction_venture_slug_guard() from public, anon, authenticated, service_role;

-- what the backup preflight checks: both the export redaction and the source fixes are installed AND are the definitions in force
create or replace function public.backup_redaction_status() returns jsonb
language sql stable security definer set search_path to 'pg_catalog' as $$
  select jsonb_build_object('version', 2,
    'snapshot_redacts', coalesce((select p.prosrc like '%backup_table_expr%' and p.prosrc like '%backup_deny_scan%' and p.prosrc like '%backup_redaction_context%' from pg_proc p where p.oid = to_regprocedure('public.backup_snapshot(text[])')), false),
    'redactor_installed', to_regprocedure('public.backup_redact_text(text,jsonb,integer,text)') is not null and to_regprocedure('public.backup_redaction_spec()') is not null,
    'denylist', coalesce((select (public.redaction_denylist_status() ->> 'key_present')::boolean and (public.redaction_denylist_status() ->> 'triggers')::int >= 2 from (select 1) z where to_regprocedure('public.redaction_denylist_status()') is not null), false),
    'sources_fixed', coalesce((select bool_and(p.prosrc like '%LEAK-SOURCE-FIX v1%') from pg_proc p where p.oid in (
        to_regprocedure('public.mark_do_not_contact(uuid,text,text)'), to_regprocedure('public.record_lead_reply(uuid,text,text,text)'), to_regprocedure('public.setter_record_payout(text,text,integer,text,text)'),
        to_regprocedure('public.set_deal_stage(uuid,text,text,text)'), to_regprocedure('public.confirm_deal_won(uuid,integer,text,text,text)'), to_regprocedure('public.agent_runs_scrub()'))), false),
    'agent_runs_trigger', exists (select 1 from pg_trigger t where t.tgrelid = to_regclass('public.agent_runs') and t.tgname = 'agent_runs_scrub' and not t.tgisinternal))
$$;

revoke all on function public.mark_do_not_contact(uuid, text, text) from public, anon, authenticated;
revoke all on function public.record_lead_reply(uuid, text, text, text) from public, anon, authenticated;
revoke all on function public.set_deal_stage(uuid, text, text, text) from public, anon, authenticated;
revoke all on function public.confirm_deal_won(uuid, integer, text, text, text) from public, anon, authenticated;
revoke all on function public.setter_record_payout(text, text, integer, text, text) from public, anon, authenticated;
revoke all on function public.agent_runs_scrub() from public, anon, authenticated;
revoke all on function public.backup_redaction_status() from public, anon, authenticated;
grant execute on function public.mark_do_not_contact(uuid, text, text) to service_role;
grant execute on function public.record_lead_reply(uuid, text, text, text) to service_role;
grant execute on function public.set_deal_stage(uuid, text, text, text) to service_role;
grant execute on function public.confirm_deal_won(uuid, integer, text, text, text) to service_role;
grant execute on function public.setter_record_payout(text, text, integer, text, text) to service_role;
grant execute on function public.backup_redaction_status() to service_role;
