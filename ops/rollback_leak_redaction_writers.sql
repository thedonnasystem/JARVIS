-- Used by ops/rollback_leak_redaction.sql (\i). GENERATED: the definitions that were in force before the leak-redaction migrations, exactly as pg_get_functiondef() prints them after the previous rollback
-- script (which re-ran whole older migration files). Round 8 (integration rehearsal S2): ONLY the functions the leak-redaction migrations replaced are restored here. Re-running
-- 20261112_setters_v1 / 20261115_venture_deals_replies_v1 / 20261116_audit_hardening_v1 / 20261119_backup_exclude_client_pii_v1 wholesale also re-created functions that OTHER migrations have since
-- replaced (is_suppressed, outbox_dnc_guard: consent integrity), silently reverting their protection. md5 of each definition: ops/live_function_md5_20261115.txt (checked by the replica run).
CREATE OR REPLACE FUNCTION public.mark_do_not_contact(p_lead uuid, p_reason text, p_by text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare l public.leads; addr text; n_leads int := 0; n_drafts int := 0; ids uuid[]; d record;
begin
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
                             'reason', left(coalesce(p_reason, ''), 300)));
  return jsonb_build_object('leads_marked', n_leads, 'drafts_rejected', n_drafts, 'address_suppressed', addr is not null);
end $function$

;
CREATE OR REPLACE FUNCTION public.record_lead_reply(p_lead uuid, p_kind text, p_note text, p_by text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
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
end $function$

;
CREATE OR REPLACE FUNCTION public.set_deal_stage(p_deal uuid, p_stage text, p_by text, p_note text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
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
end $function$

;
CREATE OR REPLACE FUNCTION public.confirm_deal_won(p_deal uuid, p_amount_cents integer, p_ledger_status text, p_by text, p_note text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
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
end $function$

;
CREATE OR REPLACE FUNCTION public.setter_record_payout(p_name text, p_kind text, p_cents integer, p_reference text DEFAULT NULL::text, p_period text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
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
  insert into public.ledger (venture_id, kind, amount_cents, currency, note, status)
    values (v_venture, 'expense', p_cents, 'CAD', format('Setter payout (%s): %s', p_kind, s.name), 'received');
  return jsonb_build_object('ok', true, 'name', s.name);
end $function$

;
CREATE OR REPLACE FUNCTION public.backup_export_policy()
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public'
AS $function$
declare res jsonb;
begin
  with recursive tabs as (
    select c.relname::text n from pg_class c where c.relnamespace = 'public'::regnamespace and c.relkind in ('r', 'p')
  ), base as (
    select t.n,
           case when t.n ~ '^(ws_|ffm_)' or t.n = 'client_workspaces' then 'client_pii' else coalesce(k.data_class, 'unclassified') end as cls,
           case
             when t.n ~ '^(ws_|ffm_)' or t.n = 'client_workspaces' then 'denied by rule: client workspace tables are never exported'
             when k.data_class is null then 'unclassified: add it to backup_classification() in a migration'
             when k.data_class not in ('public', 'internal') then 'class ' || k.data_class
             when exists (select 1 from pg_attribute a join pg_class c on c.oid = a.attrelid
                          where c.relnamespace = 'public'::regnamespace and c.relname = t.n and a.attnum > 0 and not a.attisdropped
                            and a.attname ~* '(^|_)(email|e_mail|phone|mobile|first_?name|last_?name|full_?name|to_ref|address|payee|dob|birth[a-z]*)($|_)'
                            and not exists (select 1 from public.backup_pii_column_exceptions() x where x.table_name = t.n and x.column_name = a.attname))
               then 'column that looks like personal contact data is not on the reviewed exception list'
           end as why
      from tabs t left join public.backup_classification() k on k.table_name = t.n
  ), ex as (
    select n from base where why is not null
    union
    select c.relname::text
      from pg_constraint f join pg_class c on c.oid = f.conrelid join pg_class r on r.oid = f.confrelid join ex on ex.n = r.relname::text
     where f.contype = 'f' and c.relnamespace = 'public'::regnamespace and r.relnamespace = 'public'::regnamespace
  ), ex1 as (
    select b.n, b.cls, coalesce(b.why, 'references a table that is not exported (foreign key); a restore would load rows that point at missing data') as why
      from base b where b.n in (select n from ex)
  )
  select jsonb_build_object(
    'exported', coalesce((select jsonb_agg(n order by n) from tabs where n not in (select n from ex1)), '[]'::jsonb),
    'excluded', coalesce((select jsonb_agg(jsonb_build_object('table', n, 'class', cls, 'reason', why) order by n) from ex1), '[]'::jsonb),
    'unclassified', coalesce((select jsonb_agg(n order by n) from base where cls = 'unclassified'), '[]'::jsonb))
  into res;
  return res;
end $function$

;
CREATE OR REPLACE FUNCTION public.backup_snapshot(skip text[] DEFAULT ARRAY['push_config'::text, 'push_subscriptions'::text])
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public'
AS $function$
declare q text; res jsonb; pol jsonb := public.backup_export_policy();
begin
  select 'select jsonb_build_object(''data'', (select coalesce(jsonb_object_agg(k, v), ''{}''::jsonb) from (' ||
         string_agg(format('select %L::text as k, (select coalesce(jsonb_agg(to_jsonb(t)), ''[]''::jsonb) from public.%I t) as v', c.relname, c.relname), ' union all ' order by c.relname) ||
         ') s), ''schema'', public.backup_schema(), ''policy'', ' || quote_literal(pol::text) || '::jsonb, ''method'', ''single statement snapshot'')'
    into q
    from pg_class c
   where c.relnamespace = 'public'::regnamespace and c.relkind in ('r', 'p') and c.relname <> all (skip)
     and c.relname in (select jsonb_array_elements_text(pol -> 'exported'));
  if q is null then raise exception 'backup refused: the export policy lists no exportable table'; end if;
  execute q into res;
  return res;
end $function$

;
