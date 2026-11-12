-- Payment instructions (spec section 10, items 6-7 and the manual-approval fallback).
-- Jarvis PREPARES a payment: funds are reserved first (capital limits and minimum reserve apply), the owner approves,
-- then the OWNER pays in RBC himself and confirms with the bank reference. Jarvis never moves money, never holds
-- credentials, never sees an authenticated bank session. Needs capital_v1 and bank_v1.
insert into public.action_policy (action, tier, description, max_cents_per_action, max_count_per_day, max_cents_per_week, live_only) values
 ('payment_instruction','yellow','Prepare a payment instruction for the owner to approve and pay himself in RBC', 20000, 5, 50000, false)
on conflict (action) do nothing;

create table if not exists public.payment_instructions (
  id uuid primary key default gen_random_uuid(),
  payee text not null check (length(payee) >= 2),
  amount_cents int not null check (amount_cents > 0),
  purpose text not null check (length(purpose) >= 5),
  venture_id uuid references public.ventures(id),
  due_on date,
  reservation_id uuid references public.spend_reservations(id),
  status text not null default 'awaiting_owner' check (status in ('awaiting_owner','approved','paid','rejected','cancelled')),
  requested_by text not null,
  receipt_ref text,
  paid_cents int,
  created_at timestamptz not null default now(),
  decided_at timestamptz,
  paid_at timestamptz
);
alter table public.payment_instructions enable row level security;
create index if not exists payment_instructions_status_idx on public.payment_instructions(status, due_on);

create or replace function public.prepare_payment(p_actor text, p_payee text, p_cents int, p_purpose text, p_alternatives text,
                                                  p_due date default null, p_venture_slug text default null)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare v_v uuid; r jsonb; v_id uuid;
begin
  if p_venture_slug is not null then select id into v_v from ventures where slug = p_venture_slug; end if;
  r := public.reserve_spend(p_actor, 'payment_instruction', p_payee, p_purpose, 'Required operating cost: ' || p_purpose,
                            coalesce(nullif(p_alternatives, ''), 'none'), p_cents, false, null, null, v_v, null);
  if r->>'decision' <> 'allow' then return r; end if;
  insert into payment_instructions (payee, amount_cents, purpose, venture_id, due_on, reservation_id, requested_by)
    values (p_payee, p_cents, p_purpose, v_v, p_due, (r->>'reservation_id')::uuid, p_actor) returning id into v_id;
  insert into owner_messages (from_agent, kind, channel, body, needs_decision, ref_table, ref_id)
    values ('jarvis', 'payment', 'telegram',
            format(E'Payment to approve: $%s to %s\nFor: %s%s\nFunds are reserved. If you approve, pay it yourself in RBC, then send the bank reference (/pay done %s <amount> <reference>). I never move money.',
                   to_char(p_cents / 100.0, 'FM999,990.00'), p_payee, p_purpose, case when p_due is null then '' else E'\nDue: ' || p_due end, left(v_id::text, 8)),
            true, 'payment_instructions', v_id::text);
  return jsonb_build_object('decision', 'allow', 'instruction_id', v_id, 'reason', 'Reserved; waiting for the owner.');
end $$;

create or replace function public.decide_payment(p_id uuid, p_approved boolean, p_by text) returns text
language plpgsql security definer set search_path to 'public' as $$
declare i public.payment_instructions;
begin
  if p_by is null or p_by not like 'owner%' then raise exception 'Only the owner decides payments.'; end if;
  select * into i from payment_instructions where id = p_id and status = 'awaiting_owner' for update;
  if i.id is null then return 'Not waiting for a decision.'; end if;
  if p_approved then
    update payment_instructions set status = 'approved', decided_at = now() where id = p_id;
    return format('Approved: $%s to %s. Pay it in RBC, then /pay done %s <amount> <reference>.', to_char(i.amount_cents / 100.0, 'FM999,990.00'), i.payee, left(p_id::text, 8));
  end if;
  perform public.release_spend(i.reservation_id);
  update payment_instructions set status = 'rejected', decided_at = now() where id = p_id;
  return 'Rejected. Funds released.';
end $$;

create or replace function public.confirm_payment(p_id uuid, p_paid_cents int, p_receipt text, p_by text) returns text
language plpgsql security definer set search_path to 'public' as $$
declare i public.payment_instructions; r jsonb;
begin
  if p_by is null or p_by not like 'owner%' then raise exception 'Only the owner confirms a payment.'; end if;
  select * into i from payment_instructions where id = p_id and status = 'approved' for update;
  if i.id is null then return 'No approved payment with that id.'; end if;
  if p_paid_cents is null or p_paid_cents <= 0 or p_paid_cents > i.amount_cents then
    return format('Amount must be above $0 and at most the approved $%s. Anything more needs a new instruction.', to_char(i.amount_cents / 100.0, 'FM999,990.00'));
  end if;
  r := public.settle_spend(i.reservation_id, p_paid_cents, p_receipt);
  if (r->>'ok')::boolean is not true then return coalesce(r->>'reason', 'Could not settle.'); end if;
  update payment_instructions set status = 'paid', paid_cents = p_paid_cents, receipt_ref = p_receipt, paid_at = now() where id = p_id;
  return format('Recorded: $%s paid to %s (ref %s). It will match when your bank statement is imported.', to_char(p_paid_cents / 100.0, 'FM999,990.00'), i.payee, p_receipt);
end $$;

-- Unanswered or unpaid instructions do not hold money forever.
create or replace function public.expire_payments() returns int
language plpgsql security definer set search_path to 'public' as $$
declare i record; n int := 0;
begin
  for i in select id, reservation_id from payment_instructions
           where (status = 'awaiting_owner' and created_at < now() - interval '3 days')
              or (status = 'approved' and coalesce(due_on::timestamptz, decided_at) < now() - interval '14 days') loop
    perform public.release_spend(i.reservation_id);
    update payment_instructions set status = 'cancelled' where id = i.id;
    n := n + 1;
  end loop;
  return n;
end $$;

create or replace function public.payments_text() returns text language sql stable security definer set search_path to 'public' as $$
  select coalesce(string_agg(format('%s  $%s to %s  (%s%s)  id %s', status, to_char(amount_cents / 100.0, 'FM999,990.00'), payee, purpose,
                                    case when due_on is null then '' else ', due ' || due_on end, left(id::text, 8)), E'\n' order by due_on nulls last, created_at),
                  'No open payments.')
  from payment_instructions where status in ('awaiting_owner', 'approved')
$$;

create or replace function public.app_payments() returns jsonb
language plpgsql stable security definer set search_path to 'public' as $$
begin
  if not public.is_app_owner() then raise exception 'not authorized' using errcode = '42501'; end if;
  return (select coalesce(jsonb_agg(jsonb_build_object('id', id, 'short', left(id::text, 8), 'payee', payee, 'cents', amount_cents, 'purpose', left(purpose, 160),
                    'due', due_on, 'status', status) order by due_on nulls last, created_at), '[]'::jsonb)
          from payment_instructions where status in ('awaiting_owner', 'approved'));
end $$;
revoke all on function public.app_payments() from public, anon;
grant execute on function public.app_payments() to authenticated;

revoke all on function public.prepare_payment(text, text, int, text, text, date, text), public.decide_payment(uuid, boolean, text),
  public.confirm_payment(uuid, int, text, text), public.expire_payments(), public.payments_text() from public, anon, authenticated;

do $$ begin
  if exists (select 1 from pg_namespace where nspname = 'cron') then
    perform cron.unschedule(jobid) from cron.job where jobname = 'hq-expire-payments';
    perform cron.schedule('hq-expire-payments', '15 9 * * *', 'select public.expire_payments()');
  end if;
end $$;
