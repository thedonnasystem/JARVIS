-- PROPOSED, NOT APPLIED, NOT IN APPLY_ORDER.txt. Needs the owner's explicit approval: it changes a permission-control trigger.
-- Problem (reproduced by scripts/repro/double_authorize.sql): one email send authorizes twice (Python hq_mail.deliver_approved,
-- then this trigger when the row is marked sent). Effects: send_email/day counts 2 per send (20/day policy = 10 sends); in
-- approve_first mode the single owner approval is consumed by Python and the trigger then refuses; with an odd daily limit the
-- trigger can refuse AFTER the email was posted.
-- Fix: the trigger first claims ONE unused 'allow' row that the sender just wrote for this very outbox row (same action, same ref,
-- last 30 minutes, result still null) and marks it used. No claimable row (a direct SQL/agent update) => it authorizes exactly as
-- before, so nothing becomes easier to bypass. The kill switch is still checked here either way.
create or replace function public.outbox_send_policy()
returns trigger language plpgsql set search_path to 'public' as $$
declare r jsonb; v_claim bigint; v_kill boolean; v_mode text;
begin
  if tg_op = 'UPDATE' and new.status = 'sent' and old.status is distinct from 'sent'
     and coalesce(new.sent_by, '') <> 'owner' then
    select kill_switch, mode into v_kill, v_mode from public.system_state where id = 1;
    if coalesce(v_kill, true) then
      raise exception 'Send refused by policy: Kill switch is on.';
    end if;
    if v_mode = 'dry_run' then   -- dry-run is re-checked at mark time even when a claim exists
      raise exception 'Send refused by policy: Dry-run mode: external actions are switched off.';
    end if;
    select id into v_claim from public.action_log
      where action = 'send_email' and decision = 'allow' and ref = new.id::text and result is null
        and at > now() - interval '30 minutes'
      order by id desc limit 1 for update;
    if v_claim is not null then
      update public.action_log set result = 'sent', evidence = 'claimed by outbox_send_policy', verified = false where id = v_claim;
      return new;
    end if;
    r := public.authorize_action(coalesce(new.agent, 'unknown'), 'send_email', 0, new.id::text, null, null,
                                 jsonb_build_object('to', new.to_ref));
    if r->>'decision' <> 'allow' then
      raise exception 'Send refused by policy: %', r->>'reason';
    end if;
  end if;
  return new;
end $$;
