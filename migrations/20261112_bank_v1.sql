-- Section 10: real bank as the source of truth (manual-first; official RBC API only if RBC approves it later).
-- Depends on 20261112_capital_v1.sql. All money CAD cents. NEVER store full account numbers, card numbers,
-- passwords or PINs: only the last 4 digits of an account, for labelling.
-- Owner enters/imports balances and statements. Agents cannot raise their own cash.

create table if not exists public.bank_accounts (
  id uuid primary key default gen_random_uuid(),
  label text not null,
  institution text not null default 'RBC',
  last4 text check (last4 ~ '^[0-9]{4}$'),
  currency text not null default 'CAD',
  active boolean not null default true,
  created_at timestamptz not null default now()
);
create table if not exists public.bank_balances (
  id uuid primary key default gen_random_uuid(),
  account_id uuid references public.bank_accounts(id),
  as_of date not null,
  balance_cents int not null,
  source text not null default 'manual' check (source in ('manual','statement','api')),
  entered_by text not null,
  created_at timestamptz not null default now()
);
create table if not exists public.bank_transactions (
  id uuid primary key default gen_random_uuid(),
  account_id uuid references public.bank_accounts(id),
  posted_on date not null,
  description text not null,
  amount_cents int not null,                 -- signed: deposit +, withdrawal -
  dedupe_key text not null unique,
  status text not null default 'unmatched' check (status in ('unmatched','matched','ignored')),
  ledger_id uuid references public.ledger(id),
  reservation_id uuid references public.spend_reservations(id),
  note text,
  imported_at timestamptz not null default now()
);
create index if not exists bank_tx_status_idx on public.bank_transactions(status, posted_on);
alter table public.bank_accounts enable row level security;
alter table public.bank_balances enable row level security;
alter table public.bank_transactions enable row level security;

create or replace function public.guard_bank_balance() returns trigger language plpgsql set search_path to 'public' as $$
begin
  if coalesce(new.entered_by, '') not like 'owner%' then
    raise exception 'Only the owner can record a bank balance.';
  end if;
  insert into public.audit_log (actor, action, target, detail) values (new.entered_by, 'bank_balance', 'bank_balances', to_jsonb(new));
  return new;
end $$;
drop trigger if exists bank_balance_guard on public.bank_balances;
create trigger bank_balance_guard before insert on public.bank_balances for each row execute function public.guard_bank_balance();

-- Import statement rows: p_rows = [{"date":"2026-11-03","description":"...","cents":-1250}, ...]
-- Re-importing the same file is safe (same rows get the same key). Identical same-day rows stay distinct by position.
create or replace function public.bank_import(p_account uuid, p_rows jsonb) returns jsonb
language plpgsql set search_path to 'public' as $$
declare v_new int;
begin
  with src as (
    select (r->>'date')::date d, left(coalesce(r->>'description',''), 200) descr, (r->>'cents')::int c
    from jsonb_array_elements(p_rows) r),
  numbered as (select *, row_number() over (partition by d, descr, c) n from src),
  ins as (
    insert into public.bank_transactions (account_id, posted_on, description, amount_cents, dedupe_key)
    select p_account, d, descr, c, md5(coalesce(p_account::text,'') || '|' || d || '|' || descr || '|' || c || '|' || n) from numbered
    on conflict (dedupe_key) do nothing returning 1)
  select count(*) into v_new from ins;
  return jsonb_build_object('rows', jsonb_array_length(p_rows), 'new', v_new, 'duplicates', jsonb_array_length(p_rows) - v_new);
end $$;

-- One-to-one matching of bank rows to what we recorded: received ledger rows (same amount, +/-3 days)
-- and settled spend reservations (same amount, +/-3 days).
create or replace function public.bank_reconcile() returns jsonb language plpgsql set search_path to 'public' as $$
declare t record; m_id uuid; n_ledger int := 0; n_res int := 0; n_left int;
begin
  for t in select * from public.bank_transactions where status = 'unmatched' order by posted_on loop
    m_id := null;
    select l.id into m_id from public.ledger l
      where l.status = 'received' and not coalesce(l.intercompany, false)
        and l.amount_cents = abs(t.amount_cents)
        and ((t.amount_cents > 0 and l.kind = 'revenue') or (t.amount_cents < 0 and l.kind = 'expense'))
        and abs(l.occurred_on - t.posted_on) <= 3
        and not exists (select 1 from public.bank_transactions b where b.ledger_id = l.id)
      order by abs(l.occurred_on - t.posted_on) limit 1;
    if m_id is not null then
      update public.bank_transactions set status = 'matched', ledger_id = m_id where id = t.id; n_ledger := n_ledger + 1; continue;
    end if;
    if t.amount_cents < 0 then
      select s.id into m_id from public.spend_reservations s
        where s.status = 'settled' and s.actual_cents = -t.amount_cents
          and abs((s.settled_at at time zone 'America/Toronto')::date - t.posted_on) <= 3
          and not exists (select 1 from public.bank_transactions b where b.reservation_id = s.id)
        order by abs((s.settled_at at time zone 'America/Toronto')::date - t.posted_on) limit 1;
      if m_id is not null then
        update public.bank_transactions set status = 'matched', reservation_id = m_id where id = t.id; n_res := n_res + 1;
      end if;
    end if;
  end loop;
  select count(*) into n_left from public.bank_transactions where status = 'unmatched';
  return jsonb_build_object('matched_ledger', n_ledger, 'matched_spend', n_res, 'unmatched', n_left);
end $$;

-- Things the owner should hear about. Empty array = all clear.
create or replace function public.bank_alerts() returns jsonb language plpgsql stable set search_path to 'public' as $$
declare s jsonb; p public.capital_policy; out jsonb := '[]'::jsonb; n int; big int;
begin
  s := public.capital_snapshot();
  select * into p from public.capital_policy where id = 1;
  if s->>'bank_balance_cents' is null then
    out := out || to_jsonb('No bank balance on record: spending is limited by the internal ledger only. Send /bank balance <amount>.'::text);
  else
    if (s->>'bank_age_days')::int > 7 then out := out || to_jsonb(('Bank balance is ' || (s->>'bank_age_days') || ' days old. Send /bank balance <amount>.')::text); end if;
    if (s->>'bank_balance_cents')::int < p.min_reserve_cents then out := out || to_jsonb('Bank balance is below the reserve floor.'::text); end if;
    if (s->>'ledger_available_cents')::int > (s->>'bank_available_cents')::int then
      out := out || to_jsonb(('Ledger shows $' || round((s->>'ledger_available_cents')::numeric/100,2) || ' but the bank supports only $' || round((s->>'bank_available_cents')::numeric/100,2) || '. Spending is capped at the bank figure.')::text);
    end if;
  end if;
  select count(*), coalesce(max(abs(amount_cents)), 0) into n, big from public.bank_transactions where status = 'unmatched' and posted_on < current_date - 3;
  if n > 0 then out := out || to_jsonb((n || ' bank transaction(s) older than 3 days have no matching record (largest $' || round(big::numeric/100,2) || '). Use /bank unmatched.')::text); end if;
  return out;
end $$;

-- Safe to re-run: bank-aware snapshot (replaces the capital_v1 version; same fields plus bank_*).
create or replace function public.capital_snapshot()
returns jsonb language plpgsql stable set search_path to 'public' as $$
declare p public.capital_policy; v_start timestamptz; v_rev int; v_exp int; v_ai int; v_res int; v_week int;
        v_recurring int; v_avail int; v_mode text;
        v_bal int; v_asof date; v_pending int; v_bank_avail int; v_ledger_avail int;
begin
  select * into p from public.capital_policy where id = 1;
  v_start := p.fund_started_on::timestamp at time zone 'America/Toronto';
  select coalesce(sum(amount_cents) filter (where kind = 'revenue'), 0),
         coalesce(sum(amount_cents) filter (where kind = 'expense'), 0)
    into v_rev, v_exp
    from public.ledger where status = 'received' and not coalesce(intercompany, false) and occurred_on >= p.fund_started_on;
  select coalesce(sum(coalesce(actual_cents, reserved_cents)), 0) into v_ai
    from public.llm_calls where status in ('reserved','done') and started_at >= v_start;
  select coalesce(sum(cents), 0) into v_res from public.spend_reservations where status = 'reserved';
  select coalesce(sum(coalesce(actual_cents, cents)), 0) into v_week
    from public.spend_reservations where status in ('reserved','settled') and created_at >= now() - interval '7 days';
  select coalesce(sum(monthly_cost_cents), 0) into v_recurring from public.tool_registry where status = 'active';
  v_avail := p.operating_fund_cents + v_rev - v_exp - v_ai - v_res;
  v_ledger_avail := v_avail;
  -- The bank is the source of truth: the ledger may never show more money than the bank holds.
  select balance_cents, as_of into v_bal, v_asof from public.bank_balances order by as_of desc, created_at desc limit 1;
  if v_bal is not null then
    select coalesce(sum(sr.actual_cents), 0) into v_pending from public.spend_reservations sr
      where sr.status = 'settled' and sr.settled_at::date > v_asof
        and not exists (select 1 from public.bank_transactions bt where bt.reservation_id = sr.id);
    v_pending := v_pending + coalesce((select sum(coalesce(actual_cents, reserved_cents)) from public.llm_calls
      where status in ('reserved','done') and (started_at at time zone 'America/Toronto')::date > v_asof), 0);
    v_bank_avail := v_bal - v_res - v_pending;
    v_avail := least(v_avail, v_bank_avail);
  end if;
  v_mode := case when v_avail <= p.hard_stop_cents then 'hard_stop'
                 when v_avail <= p.low_cost_threshold_cents then 'low_cost'
                 else 'normal' end;
  return jsonb_build_object('available_cents', v_avail, 'mode', v_mode, 'fund_cents', p.operating_fund_cents,
    'revenue_cents', v_rev, 'expense_cents', v_exp, 'ai_spend_cents', v_ai, 'reserved_cents', v_res,
    'week_spend_cents', v_week, 'recurring_monthly_cents', v_recurring, 'min_reserve_cents', p.min_reserve_cents,
    'weekly_limit_cents', p.weekly_limit_cents, 'per_transaction_limit_cents', p.per_transaction_limit_cents,
    'reinvest_pct', p.reinvest_pct, 'since', p.fund_started_on,
    'ledger_available_cents', v_ledger_avail, 'bank_balance_cents', v_bal, 'bank_as_of', v_asof,
    'bank_age_days', case when v_asof is null then null else (now() at time zone 'America/Toronto')::date - v_asof end,
    'bank_available_cents', v_bank_avail);
end $$;

