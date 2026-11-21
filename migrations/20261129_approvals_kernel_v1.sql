-- FENDEZY GROUP Phase 1, milestone M3 "Approvals kernel + office wiring". ADDITIVE. Needs 20261127_org_access_v1 (M1) and 20261128_office_money_v1 (M2).
-- Design (docs/architecture/PHASE1_M3_APPROVALS.md):
--   * fz_approval_queue (view): ONE read model of everything waiting on the owner: the existing approval_requests (red / approve-first actions) and the M2 office money
--     proposals. Type, office, requester, action, amount, risk, created, expires, effective status, and HOW it is decided. Metadata only (no recommendation text).
--     Scoped office identities read their own office's rows; Jarvis and the auditor read all; anon / authenticated nothing (M1 helpers only: the scoped allowlist is unchanged).
--   * Decisions keep their EXISTING owner-verified paths, unchanged: approval_requests by the owner's Telegram tap (owner_messages -> hq_commands.apply_decision ->
--     hq_policy.decide_approval, consumed once by authorize_action); money proposals by fz_owner_decide_office_proposal (signed-in owner only). No new approval route.
--   * fz_queue_expire(): one expiry rule for both (pending past expires_at -> expired) and a cap of p_cap (5) pending action approvals per office per action (the oldest
--     extras are superseded -> expired); money proposals are already capped at insert (M2: 3 pending per office). Every state change it makes, and every status change of a money proposal (trigger on the M2 table), writes an audit_log row. Nothing is deleted.
--     Expired is the safe state: authorize_action never consumes an expired or pending request, and decide_approval only changes pending ones.
--   * fz_prepare_office_payment(): the office layer in front of the UNCHANGED prepare_payment() (the one paid path that carries a venture). It can only refuse (the
--     venture's office is not active, or its available balance is short); otherwise it returns exactly what prepare_payment() decides. Service path only. The bot uses it
--     only when FZ_OFFICE_SPEND_GATE=1 (hq_payments.py); default OFF = today's behaviour.
--   No change to authorize_action, action_policy, approval_requests' structure or triggers, caps, kill switch, mode, executors, hq_llm or any owner-identity check. No new table.
-- Ordered BEFORE the lockdown (R3). Rollback: ops/rollback_approvals_kernel.sql (before ops/rollback_office_money.sql). Safe to re-run.

set lock_timeout = '5s';

-- ---------------------------------------------------------------------------------------------------------------------------- the queue (read model)
create or replace view public.fz_approval_queue with (security_barrier = true) as
with q as (
  select 'action_approval'::text as request_type, r.id as source_id,
         coalesce(g.office_id, 'f0000000-0000-4000-8000-000000000000'::uuid) as office_id,
         r.actor as requester, r.action, r.cents::bigint as amount_cents, coalesce(p.tier, 'unknown') as risk,
         case when r.status = 'pending' and r.expires_at <= now() then 'expired' else r.status end as status,
         r.created_at, r.expires_at, r.decided_at,
         'owner Telegram tap (approval message)'::text as decided_by_path
    from public.approval_requests r
    left join public.agents g on g.slug = r.actor
    left join public.action_policy p on p.action = r.action
  union all
  -- every column named in both branches: the off-site restore re-creates the view from pg_get_viewdef(), which is only a fixed point with named columns
  select 'office_money_' || m.kind as request_type, m.id as source_id, m.office_id as office_id, m.proposed_by as requester, m.kind as action,
         m.cents::bigint as amount_cents, 'money'::text as risk,
         case when m.status = 'pending' and m.expires_at <= now() then 'expired' else m.status end as status,
         m.created_at as created_at, m.expires_at as expires_at, m.decided_at as decided_at,
         'owner session: fz_owner_decide_office_proposal'::text as decided_by_path
    from public.fz_office_money_proposals m
)
select q.request_type, q.source_id, q.office_id, o.slug as office, q.requester, q.action, q.amount_cents, q.risk, q.status, q.created_at, q.expires_at, q.decided_at,
       q.decided_by_path
  from q
  left join public.fz_offices o on o.id = q.office_id
 where coalesce(nullif(current_setting('role', true), ''), 'none') in ('none', 'postgres', 'service_role')      -- review fix 7: an allowlist of who sees everything
    or (coalesce(nullif(current_setting('role', true), ''), 'none') in ('fz_jarvis', 'fz_office_agent', 'fz_auditor')
        and ((select public.is_group_scope()) or q.office_id = (select public.current_office_id())));   -- scoped: own office (group scope: all); anyone else: nothing

revoke all on public.fz_approval_queue from public, anon, authenticated, service_role, fz_jarvis, fz_office_agent, fz_auditor;
grant select on public.fz_approval_queue to service_role, fz_jarvis, fz_office_agent, fz_auditor;

-- ---------------------------------------------------------------------------------------------------------------------------- expiry + cap (one rule for every type)
-- p_cap: pending requests allowed per office per type (action_approval: per action too), honoured only for the owner / the database session (default 5).
-- Returns how many it expired. Service path and cron only.
create or replace function public.fz_queue_expire(p_cap integer default 5) returns integer
language plpgsql security definer set search_path to 'pg_catalog' as $$
declare n int := 0; r record; v_role text := coalesce(nullif(current_setting('role', true), ''), 'none'); v_cap int := 5;
begin
  if v_role in ('fz_jarvis', 'fz_office_agent', 'fz_auditor') then
    raise exception 'the approval queue is maintained on the service path only' using errcode = '42501';
  end if;
  -- review fix 4: the cap is 5. Only the signed-in owner or the database's own session (the cron job / the owner's SQL session: no API role) may choose another one;
  -- the bot's key (service_role) cannot mass-expire requests with a small cap.
  if p_cap is not null and (coalesce(public.is_app_owner(), false) or v_role in ('none', 'postgres')) then v_cap := greatest(p_cap, 1); end if;
  -- 1. past expiry
  for r in update public.approval_requests set status = 'expired' where status = 'pending' and expires_at <= now() returning id, actor, action, cents loop
    insert into public.audit_log (actor, action, target, detail) values ('queue', 'approval_expired', 'approval_requests/' || r.id,
      jsonb_build_object('from', 'pending', 'to', 'expired', 'reason', 'past expiry', 'action', r.action, 'requester', r.actor, 'cents', r.cents));
    n := n + 1;
  end loop;
  for r in update public.fz_office_money_proposals set status = 'expired', decided_at = now(), decided_by = 'expiry' where status = 'pending' and expires_at <= now() returning id loop
    n := n + 1;                                                           -- audited by the proposal status trigger
  end loop;
  -- 2. cap: at most v_cap pending per office per type (the newest are kept; the older extras are superseded)
  for r in update public.approval_requests a set status = 'expired' from (
             select x.id from (select r2.id, row_number() over (partition by coalesce(g.office_id, 'f0000000-0000-4000-8000-000000000000'::uuid), r2.action order by r2.created_at desc, r2.id) k
                                 from public.approval_requests r2 left join public.agents g on g.slug = r2.actor where r2.status = 'pending') x where x.k > v_cap) s
           where a.id = s.id and a.status = 'pending' returning a.id, a.actor, a.action, a.cents loop
    insert into public.audit_log (actor, action, target, detail) values ('queue', 'approval_expired', 'approval_requests/' || r.id,
      jsonb_build_object('from', 'pending', 'to', 'expired', 'reason', format('superseded: more than %s pending for this office and action', v_cap), 'action', r.action, 'requester', r.actor, 'cents', r.cents));
    n := n + 1;
  end loop;
  -- money proposals are capped at insert (M2: 3 pending per office), so nothing to supersede there
  return n;
end $$;
revoke all on function public.fz_queue_expire(integer) from public, anon, authenticated;

-- every status change of a money proposal is audited (M2 audits proposals and executions; this covers rejected / expired / executed uniformly)
create or replace function public.fz_queue_audit_proposal() returns trigger
language plpgsql security definer set search_path to 'pg_catalog' as $$
begin
  -- review fix 5: exactly one audit row per change. A rejection is already audited by fz_owner_decide_office_proposal (M2, 'office_money_rejected'), so it is skipped here.
  if new.status is distinct from old.status and new.status <> 'rejected' then
    insert into public.audit_log (actor, action, target, detail) values (coalesce(new.decided_by, 'unknown'), 'office_money_' || new.status, 'fz_office_money_proposals/' || new.id,
      jsonb_build_object('from', old.status, 'to', new.status, 'kind', new.kind, 'office_id', new.office_id, 'cents', new.cents, 'reinvest_pct', new.reinvest_pct));
  end if;
  return null;
end $$;
revoke all on function public.fz_queue_audit_proposal() from public, anon, authenticated;
drop trigger if exists fz_office_money_proposals_audit on public.fz_office_money_proposals;
create trigger fz_office_money_proposals_audit after update on public.fz_office_money_proposals for each row execute function public.fz_queue_audit_proposal();

-- ---------------------------------------------------------------------------------------------------------------------------- office wiring: payments
-- In FRONT of the unchanged prepare_payment(). The office is the venture's office (M1 ventures.office_id). Group (or no venture): prepare_payment() exactly.
create or replace function public.fz_prepare_office_payment(p_actor text, p_payee text, p_cents integer, p_purpose text, p_alternatives text,
                                                            p_due date default null, p_venture_slug text default null) returns jsonb
language plpgsql security definer set search_path to 'pg_catalog' as $$
declare o public.fz_offices; v_avail bigint; v_reason text; v_cents int := coalesce(p_cents, 0); res jsonb;
begin
  if coalesce(nullif(current_setting('role', true), ''), 'none') in ('fz_jarvis', 'fz_office_agent', 'fz_auditor') then
    raise exception 'the office payment gate is service-path only' using errcode = '42501';
  end if;
  if p_venture_slug is not null then
    select f.* into o from public.ventures v join public.fz_offices f on f.id = v.office_id where v.slug = p_venture_slug and f.kind = 'office';
  end if;
  if o.id is not null then
    perform pg_advisory_xact_lock(7333);                                  -- reserve_spend's lock, then authorize_action's: their order (no deadlock)
    perform pg_advisory_xact_lock(7332);
    -- review fix 1: M1's office layer exactly as fz_authorize_action applies it (status, office rule allowed / per-action cap / daily count)
    v_reason := public.fz_office_refusal(o.id, 'payment_instruction', v_cents);
    if v_reason is null then
      v_avail := public.fz_office_available_cents(o.id);
      if v_cents > 0 and coalesce(v_avail, 0) < v_cents then
        v_reason := format('Office %s has $%s available, the payment is $%s. Ask the owner for an allocation.', o.title,
                           to_char(greatest(coalesce(v_avail, 0), 0) / 100.0, 'FM999,999,990.00'), to_char(v_cents / 100.0, 'FM999,999,990.00'));
      end if;
    end if;
    if v_reason is not null then
      insert into public.action_log (actor, action, tier, decision, reason, cents, ref, detail)
        values (coalesce(nullif(btrim(p_actor), ''), 'unknown'), 'payment_instruction', (select tier from public.action_policy where action = 'payment_instruction'), 'deny', v_reason,
                greatest(v_cents, 0), p_payee, jsonb_build_object('office', o.slug, 'layer', 'office_money', 'venture', p_venture_slug, 'available_cents', v_avail));
      return jsonb_build_object('decision', 'deny', 'reason', v_reason, 'office', o.slug, 'available_cents', v_avail);
    end if;
  end if;
  res := public.prepare_payment(p_actor, p_payee, p_cents, p_purpose, p_alternatives, p_due, p_venture_slug);
  if o.id is not null and res ->> 'decision' = 'allow' then                -- stamp the reservation to the office and label its allow row (the office daily count counts it)
    perform public.fz_money_mark_office_allow((select reservation_id from public.payment_instructions where id = (res ->> 'instruction_id')::uuid), o.id, p_actor);
  end if;
  return res || jsonb_build_object('office', coalesce(o.slug, 'group'));
end $$;
revoke all on function public.fz_prepare_office_payment(text, text, integer, text, text, date, text) from public, anon, authenticated;

do $$
declare f regprocedure;
begin
  for f in select p.oid::regprocedure from pg_proc p where p.pronamespace = 'public'::regnamespace and p.proname in ('fz_queue_expire', 'fz_queue_audit_proposal', 'fz_prepare_office_payment') loop
    execute format('revoke all on function %s from fz_jarvis, fz_office_agent, fz_auditor', f);
  end loop;
  if exists (select 1 from pg_namespace where nspname = 'cron') then
    perform cron.unschedule(jobid) from cron.job where jobname = 'fz-queue-expire';
    perform cron.schedule('fz-queue-expire', '*/15 * * * *', 'select public.fz_queue_expire()');
  end if;
end $$;
reset lock_timeout;
