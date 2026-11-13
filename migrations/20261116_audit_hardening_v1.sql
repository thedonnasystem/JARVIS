-- Audit hardening (AUDIT_PATHS.md findings F1 and F2). Safe to re-run. Replaces two CASL/do-not-contact helpers from
-- 20261115_venture_deals_replies_v1.sql with stricter versions. Touches NO protected control: authorize_action, outbox_send_policy,
-- enforce_outbox_rules, spend gateway, capital, kill switch, dry-run and permissions are not read or changed here. Nothing here sends anything.
--
--   normalize_addr(text)   F1: the old version returned a non-null, NON-MATCHING key for forms a mail server delivers to the same mailbox
--                          (trailing dot "a@b.com.", quoted local part "\"a\"@b.com", comments "a(x)@b.com") and kept lookalike or invisible
--                          characters (NBSP, zero-width, fullwidth) in the key, so an opted-out address could be re-drafted and approved.
--                          Now: ONE strict, ASCII-only, single-address form, else NULL (= "not one clean address", which every caller
--                          already treats as "do not send"). Trailing dots on the domain are dropped. Python mirror: hq_mail.normalize_addr.
--   outbox_dnc_guard()     F1b: with a NULL key the old guard silently let the row through. Now an email row whose address is not one clean
--                          address cannot be drafted, QA-passed, approved or sent and a retarget
--                          (to_ref / channel / lead_id changed) of a live row is re-checked, not only a status change.
--   mark_do_not_contact    F13: an unsubscribe could not be recorded while the lead had an open draft (see the comment on the function).
--   contact_suppressions   F6: restores the address CHECK that a sprint rollback (DROP FUNCTION ... CASCADE) removes.
-- Dots in the local part are still NOT folded (gmail-only rule; folding would silently change the meaning of stored opt-outs).

create or replace function public.normalize_addr(p text) returns text
language sql immutable set search_path to 'public' as $$
  select case
    when s.bad or s.a is null or s.a !~ '^[^@]+@[^@]+$' or s.loc is null then null
    when s.loc !~ '^[a-z0-9.!#$%&''*+/=?^_`{|}~-]+$' then null
    when s.dom !~ '^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)*$' then null
    else s.loc || '@' || s.dom end
  from (
    select b.a, b.bad,
           nullif(regexp_replace(split_part(b.a, '@', 1), '\+.*$', ''), '') as loc,
           regexp_replace(split_part(b.a, '@', 2), '\.+$', '') as dom
    from (select
            lower(btrim(coalesce(substring(btrim(p) from '<([^<>]*)>'), btrim(p)))) as a,
            (p is null
             or p ~ '[;,]'
             or p ~ '[^\x20-\x7e]'                                        -- tabs, newlines, NBSP, zero-width, fullwidth and every other non-ASCII char
             or length(p) - length(replace(p, '<', '')) > 1                -- two address-bracket pairs: ambiguous
             or length(p) - length(replace(p, '>', '')) > 1
             or (btrim(p) ~ '<[^<>]*>' and btrim(regexp_replace(btrim(p), '^[^<]*<[^<>]*>', '')) <> '')   -- anything after the closing bracket
            ) as bad) b
  ) s
$$;

create or replace function public.outbox_dnc_guard() returns trigger
language plpgsql set search_path to 'public' as $$
declare dnc boolean := false;
begin
  if new.status not in ('draft','qa_passed','approved','sent') then return new; end if;
  if tg_op = 'UPDATE' and new.status is not distinct from old.status
     and new.to_ref is not distinct from old.to_ref and new.channel is not distinct from old.channel
     and new.lead_id is not distinct from old.lead_id then
    return new;   -- nothing that decides WHO is contacted or WHETHER it advances changed
  end if;
  if new.lead_id is not null then
    select do_not_contact into dnc from public.leads where id = new.lead_id;
  end if;
  if new.channel = 'email' and new.to_ref ~ '[;,]' then
    raise exception 'One recipient per email: a list of addresses is not allowed.' using errcode = 'P0001';
  end if;
  if new.channel = 'email' and new.to_ref is not null and public.normalize_addr(new.to_ref) is null then
    raise exception 'The recipient is not one clean email address (CASL check cannot be done). Fix the address first.' using errcode = 'P0001';
  end if;
  if coalesce(dnc, false) or (new.channel = 'email' and public.is_suppressed(new.to_ref)) then
    raise exception 'Do-not-contact: this lead or address has opted out (CASL). No draft, approval or send is allowed.' using errcode = 'P0001';
  end if;
  return new;
end $$;

-- F13 (High): with the live trigger outbox_rules (enforce_outbox_rules) in place, UPDATE-ing a draft whose lead is already do-not-contact is
-- refused ("Recipient is on the do-not-contact list"), and mark_do_not_contact flagged the leads BEFORE it rejected the drafts. So an unsubscribe
-- on a lead that had an open draft raised, rolled back the suppression too, and the opt-out could not be recorded at all (the replica has no such
-- trigger, so this never showed in tests). Now: suppress, reject the drafts FIRST (leads not yet flagged), flag the leads last; a draft that is still
-- refused (the raw-flag cascade path flags the lead before calling this) is rejected with its lead and address detached (kept in qa_notes).
create or replace function public.mark_do_not_contact(p_lead uuid, p_reason text, p_by text) returns jsonb
language plpgsql security definer set search_path to 'public' as $$
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
end $$;

-- F6: DROP FUNCTION normalize_addr ... CASCADE (ops/rollback_sprint12.sql) silently drops the suppression table's CHECK that depends on it,
-- and re-applying 20261115 does not put it back because the table already exists. Restore it (NOT VALID: new rows are checked, rows stored
-- by an earlier version are not re-validated).
do $$ begin
  if to_regclass('public.contact_suppressions') is not null
     and not exists (select 1 from pg_constraint where conrelid = 'public.contact_suppressions'::regclass and contype = 'c') then
    alter table public.contact_suppressions add constraint contact_suppressions_address_check
      check (coalesce(address = public.normalize_addr(address), false)) not valid;
  end if;
end $$;

revoke all on function public.normalize_addr(text) from public, anon, authenticated;
grant execute on function public.normalize_addr(text) to service_role;
revoke all on function public.outbox_dnc_guard() from public, anon, authenticated;
grant execute on function public.outbox_dnc_guard() to service_role;
revoke all on function public.mark_do_not_contact(uuid, text, text) from public, anon, authenticated;
grant execute on function public.mark_do_not_contact(uuid, text, text) to service_role;
