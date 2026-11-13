-- PENDING OWNER SIGN-OFF. NOT in migrations/, NOT in APPLY_ORDER.txt, NOT applied anywhere.
-- These change PROTECTED controls (the spend gateway, the capital controller, outbox send rules, the policy table), so per the working rules
-- they are only proposed here. sqltests/pending_signoff_check.sql applies this file inside a rolled-back transaction on the scratch database
-- and proves every change does what it says (and that the existing guarantees still hold). It changes NO limit, cap, tier, mode or policy row.
-- Findings: AUDIT_PATHS.md F7 (gateway accepts negative / un-bounded numbers), F9 (green label on a paid reservation), F10 (owner marker),
-- F11 (sent is not final), F12 (policy rows can be INSERTed by the API role without the owner marker).
--
-- Apply order if approved: copy into a new migration file (before 20261112_lockdown_v1.sql in APPLY_ORDER.txt) and run scripts/gate.sh --strict.
-- Part 4 (owner_mark_sent) also needs hq_commands.mark_sent to call rpc/owner_mark_sent (see AUDIT_PATHS.md); parts 1-3 and 5-6 need no code change.

-- ---------------------------------------------------------------------------------------------------------------------------------------
-- 1. AI spend gateway: an estimate must be a number >= 0. A negative estimate was ACCEPTED and stored as a negative reservation, which lowers
--    every later "spent so far" sum and lets later calls exceed the daily, agent and mission caps by that amount. (Body = 20261113_mission_guard_v1
--    reserve_llm_budget plus the one check marked NEW. No cap, order of checks or message is changed.)
create or replace function public.reserve_llm_budget(p_agent text, p_est_cents integer, p_model text, p_purpose text)
 returns uuid
 language plpgsql
 set search_path to 'public'
as $function$
declare
  v_ks boolean; v_cap_total int; v_status text; v_cap_agent int;
  v_start timestamptz; v_total int; v_agent int; v_id uuid; v_mode text;
begin
  perform pg_advisory_xact_lock(7331);
  select kill_switch, daily_spend_cap_cents into v_ks, v_cap_total from public.system_state where id = 1;
  if v_ks then raise exception 'Kill switch is on.'; end if;
  if p_est_cents is null or p_est_cents < 0 then raise exception 'The cost estimate must be zero or more.'; end if;   -- NEW
  v_mode := public.capital_mode();
  if v_mode = 'hard_stop' then raise exception 'Capital hard stop: the operating fund is nearly empty. AI calls are paused.'; end if;
  if v_mode = 'low_cost' then
    v_cap_total := least(v_cap_total, (select low_cost_ai_cap_cents from public.capital_policy where id = 1));
  end if;
  select status, daily_spend_cap_cents into v_status, v_cap_agent from public.agents where slug = p_agent;
  if v_status is null then raise exception 'Unknown agent %.', p_agent; end if;
  if v_status <> 'active' then raise exception 'Agent % is paused.', p_agent; end if;
  v_start := (date_trunc('day', now() at time zone 'America/Toronto') at time zone 'America/Toronto');
  select coalesce(sum(coalesce(actual_cents, reserved_cents)), 0) into v_total
    from public.llm_calls where started_at >= v_start and status in ('reserved','done');
  select coalesce(sum(coalesce(actual_cents, reserved_cents)), 0) into v_agent
    from public.llm_calls where agent_slug = p_agent and started_at >= v_start and status in ('reserved','done');
  if v_agent + p_est_cents > v_cap_agent then raise exception 'Agent % would exceed its daily cap.', p_agent; end if;
  if v_total + p_est_cents > v_cap_total then raise exception 'The company daily spend cap would be exceeded.'; end if;
  perform public.mission_guard(p_agent, p_purpose, p_est_cents);
  insert into public.llm_calls (agent_slug, model, purpose, reserved_cents)
    values (p_agent, p_model, p_purpose, p_est_cents) returning id into v_id;
  return v_id;
end $function$;

-- 2. settle_llm_call: the actual cost is >= 0, and only a call that is still open ('reserved', or 'released' by the restart recovery, whose
--    provider call may genuinely finish late) can be settled. A settled call is final: it could be re-settled to 0 / 'failed' / negative,
--    which erased real spend from every cap. Same signature and return type, so every caller keeps working.
create or replace function public.settle_llm_call(p_id uuid, p_actual_cents integer, p_status text default 'done'::text) returns void
language plpgsql set search_path to 'public' as $function$
begin
  if p_actual_cents is null or p_actual_cents < 0 then raise exception 'The actual cost must be zero or more.'; end if;
  update public.llm_calls set actual_cents = p_actual_cents, status = p_status, finished_at = now()
   where id = p_id and status in ('reserved', 'released');
end $function$;

-- ---------------------------------------------------------------------------------------------------------------------------------------
-- 3. Capital controller. (a) settle_spend takes ANY actual amount: negative (a ledger "expense" of -$x RAISES the fund) or far above what the
--    gate reserved and the per-transaction / weekly limits checked. The actual must be >0 and no more than the reservation; anything bigger is a
--    new reservation. (b) reserve_spend accepts any policy action as the label, including a GREEN one such as 'research' (no limits, allowed in
--    dry-run), so a paid reservation could skip the Yellow rules; a paid reservation needs a Yellow or Red action.
create or replace function public.settle_spend(p_id uuid, p_actual_cents int, p_receipt text)
returns jsonb language plpgsql set search_path to 'public' as $$
declare r public.spend_reservations; v_ledger uuid;
begin
  select * into r from public.spend_reservations where id = p_id and status = 'reserved' for update;
  if r.id is null then return jsonb_build_object('ok', false, 'reason', 'No open reservation.'); end if;
  if coalesce(p_receipt, '') = '' then return jsonb_build_object('ok', false, 'reason', 'A receipt or provider reference is required.'); end if;
  if p_actual_cents is null or p_actual_cents <= 0 or p_actual_cents > r.cents then                                  -- NEW
    return jsonb_build_object('ok', false, 'reason', format('The paid amount must be above $0 and at most the reserved $%s; more needs a new reservation.', r.cents / 100.0));
  end if;
  insert into public.ledger (venture_id, kind, amount_cents, currency, note, occurred_on, status)
    values (r.venture_id, 'expense', p_actual_cents, 'CAD', format('%s: %s (receipt %s)', r.vendor, r.purpose, p_receipt),
            (now() at time zone 'America/Toronto')::date, 'received')
    returning id into v_ledger;
  update public.spend_reservations set status = 'settled', actual_cents = p_actual_cents, receipt_ref = p_receipt,
         ledger_id = v_ledger, settled_at = now() where id = p_id;
  if r.recurring then
    insert into public.tool_registry (slug, kind, purpose, owner_agent, venture_id, monthly_cost_cents, currency, status, next_renewal_on, notes)
      values (lower(regexp_replace(r.vendor, '[^a-zA-Z0-9]+', '-', 'g')), 'saas', r.purpose,
              (select slug from public.agents where slug = r.actor), r.venture_id,
              coalesce(r.monthly_cents, p_actual_cents), 'CAD', 'active',
              ((now() at time zone 'America/Toronto')::date + 30), 'Added by settle_spend ' || p_id::text)
      on conflict (slug) do update set monthly_cost_cents = excluded.monthly_cost_cents, status = 'active',
                                       next_renewal_on = excluded.next_renewal_on;
  end if;
  if r.action_log_id is not null then
    update public.action_log set result = 'paid', evidence = p_receipt, verified = true where id = r.action_log_id and result is null;
  end if;
  return jsonb_build_object('ok', true, 'ledger_id', v_ledger);
end $$;

-- reserve_spend keeps its body; the wrapper-free way to add the check is a BEFORE INSERT trigger on spend_reservations (no second copy of the
-- function to keep in sync, and it also catches an INSERT that does not go through reserve_spend).
create or replace function public.spend_reservation_action_guard() returns trigger language plpgsql set search_path to 'public' as $$
begin
  if not exists (select 1 from public.action_policy where action = new.action and tier in ('yellow', 'red')) then
    raise exception 'A paid reservation needs a Yellow or Red spending action; "%" is not one.', new.action using errcode = 'P0001';
  end if;
  return new;
end $$;
drop trigger if exists spend_reservation_action_guard on public.spend_reservations;
create trigger spend_reservation_action_guard before insert on public.spend_reservations for each row execute function public.spend_reservation_action_guard();

-- ---------------------------------------------------------------------------------------------------------------------------------------
-- 4. Outbox: the owner marker. enforce_outbox_rules and outbox_send_policy skip the kill switch, dry-run AND the send policy whenever
--    sent_by = 'owner', and sent_by is just a column any API-key holder can write. Make the marker mean something: it only counts inside
--    owner_mark_sent(), which sets a transaction-local flag. (Everything else in both functions is unchanged.)
--    ALSO NEEDS: hq_commands.mark_sent -> POST /rest/v1/rpc/owner_mark_sent {"p_id": <outbox id>, "p_by": "owner"} instead of the PATCH.
create or replace function public.owner_mark_sent(p_id uuid, p_by text) returns jsonb
language plpgsql security definer set search_path to 'public' as $$
declare o public.outbox;
begin
  if coalesce(p_by, '') not like 'owner%' then raise exception 'Only the owner records a manual send.'; end if;
  perform set_config('app.owner_send', 'on', true);
  update public.outbox set status = 'sent', sent_by = 'owner', sent_at = now() where id = p_id and status = 'approved' returning * into o;
  perform set_config('app.owner_send', 'off', true);
  if o.id is null then return jsonb_build_object('ok', false, 'reason', 'No approved draft with that id.'); end if;
  insert into public.audit_log (actor, action, target, detail) values (p_by, 'owner_marked_sent', 'outbox/' || o.id, jsonb_build_object('lead', o.lead_id));
  return jsonb_build_object('ok', true, 'id', o.id, 'lead_id', o.lead_id);
end $$;

CREATE OR REPLACE FUNCTION public.enforce_outbox_rules()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO 'public'
AS $function$
declare v_mode text; v_ks boolean; v_owner boolean;
begin
  select mode, kill_switch into v_mode, v_ks from public.system_state where id = 1;
  v_owner := coalesce(new.sent_by, '') = 'owner' and coalesce(current_setting('app.owner_send', true), '') = 'on';   -- CHANGED: marker + flag

  if tg_op = 'INSERT' and new.status <> 'draft' then
    raise exception 'New outbox rows must start as draft.';
  end if;

  if exists (select 1 from public.leads l
             where l.do_not_contact
               and (l.id = new.lead_id or (new.to_ref is not null and (l.phone = new.to_ref or l.email = new.to_ref)))) then
    raise exception 'Recipient is on the do-not-contact list.';
  end if;

  if tg_op = 'UPDATE' and new.status is distinct from old.status then
    if new.status = 'qa_passed' then
      if old.status <> 'draft' then raise exception 'Only a draft can pass QA.'; end if;
      if new.qa_agent is null or new.qa_agent = new.agent then
        raise exception 'QA must be done by a different agent than the one who wrote the message.';
      end if;
    elsif new.status = 'approved' then
      if old.status <> 'qa_passed' then raise exception 'A message must pass QA before approval.'; end if;
    elsif new.status = 'sent' then
      if old.status <> 'approved' then raise exception 'A message must be approved before sending.'; end if;
      if v_ks and not v_owner then raise exception 'Kill switch is on: nothing may be sent.'; end if;
      if v_mode = 'dry_run' and not v_owner then raise exception 'Dry run mode: nothing may be sent.'; end if;
      if new.lead_id is not null and exists (
           select 1 from public.outbox o
           where o.lead_id = new.lead_id and o.status = 'sent' and o.id <> new.id
             and o.sent_at >= (date_trunc('day', now() at time zone 'America/Toronto') at time zone 'America/Toronto')) then
        raise exception 'Daily contact limit reached for this lead.';
      end if;
      new.sent_at := now();
    end if;
  end if;
  return new;
end $function$;

create or replace function public.outbox_send_policy()
returns trigger language plpgsql set search_path to 'public' as $$
declare r jsonb;
begin
  if tg_op = 'UPDATE' and new.status = 'sent' and old.status is distinct from 'sent'
     and not (coalesce(new.sent_by, '') = 'owner' and coalesce(current_setting('app.owner_send', true), '') = 'on') then   -- CHANGED: marker + flag
    r := public.authorize_action(coalesce(new.agent, 'unknown'), 'send_email', 0, new.id::text, null, null,
                                 jsonb_build_object('to', new.to_ref));
    if r->>'decision' <> 'allow' then
      raise exception 'Send refused by policy: %', r->>'reason';
    end if;
  end if;
  return new;
end $$;

-- 5. 'sent' is final. Nothing in the rules stops sent -> draft, so a sent row can be re-run through QA, approval and sending (the one-contact-
--    per-lead-per-day rule only helps on the same day). Additive: a new trigger, no existing function touched.
create or replace function public.outbox_sent_is_final() returns trigger language plpgsql set search_path to 'public' as $$
begin
  if old.status = 'sent' and new.status is distinct from 'sent' then
    raise exception 'A sent message cannot go back to %: it has already been delivered.', new.status using errcode = 'P0001';
  end if;
  return new;
end $$;
drop trigger if exists outbox_sent_is_final on public.outbox;
create trigger outbox_sent_is_final before update on public.outbox for each row execute function public.outbox_sent_is_final();

-- 6. New policy rows: the API role cannot add an action (a new GREEN row = a new thing agents may do) without the owner marker. Migrations and the
--    SQL editor run as the database owner and are not affected, so the seed inserts keep working.
create or replace function public.action_policy_api_insert_guard() returns trigger language plpgsql set search_path to 'public' as $$
begin
  if current_user in ('service_role', 'anon', 'authenticated') and coalesce(new.updated_by, '') not like 'owner%' then
    raise exception 'Only the owner can add an action to the policy.' using errcode = 'P0001';
  end if;
  return new;
end $$;
drop trigger if exists action_policy_api_insert_guard on public.action_policy;
create trigger action_policy_api_insert_guard before insert on public.action_policy for each row execute function public.action_policy_api_insert_guard();

revoke all on function public.owner_mark_sent(uuid, text), public.outbox_sent_is_final(), public.action_policy_api_insert_guard(),
  public.spend_reservation_action_guard() from public, anon, authenticated;
grant execute on function public.owner_mark_sent(uuid, text) to service_role;
