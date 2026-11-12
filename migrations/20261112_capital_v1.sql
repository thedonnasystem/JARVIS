-- Phase 5: capital controller (master spec section 7). Extends what exists; no second budget system:
--   * AI spend stays in llm_calls via reserve_llm_budget (now also capital-aware)
--   * non-AI spend gets spend_reservations, settled into the existing ledger
--   * recurring commitments live in the existing tool_registry (monthly_cost_cents + next_renewal_on)
-- Depends on 20261112_permissions_v1.sql (authorize_action). All money here is CAD cents.

create table if not exists public.capital_policy (
  id int primary key default 1 check (id = 1),
  fund_started_on date not null default (now() at time zone 'America/Toronto')::date,
  operating_fund_cents int not null default 30000,      -- starting fund (example $300)
  min_reserve_cents int not null default 5000,          -- never spend below this
  low_cost_threshold_cents int not null default 10000,  -- below this: low-cost mode
  hard_stop_cents int not null default 2000,            -- below this: paid operations stop
  weekly_limit_cents int not null default 7500,         -- all non-AI spend, rolling 7 days
  per_transaction_limit_cents int not null default 2500,
  low_cost_ai_cap_cents int not null default 100,       -- company AI cap per day while in low-cost mode
  reinvest_pct int not null default 50 check (reinvest_pct between 0 and 100),
  last_mode text not null default 'normal',
  updated_by text not null default 'seed',
  updated_at timestamptz not null default now()
);
alter table public.capital_policy enable row level security;
insert into public.capital_policy (id) values (1) on conflict (id) do nothing;

create or replace function public.guard_capital_policy()
returns trigger language plpgsql set search_path to 'public' as $$
begin
  -- last_mode is engine bookkeeping; every other field is the owner's to change
  if (to_jsonb(new) - 'last_mode' - 'updated_at' - 'updated_by') is distinct from (to_jsonb(old) - 'last_mode' - 'updated_at' - 'updated_by')
     and coalesce(new.updated_by, '') not like 'owner%' then
    raise exception 'Only the owner can change capital limits.';
  end if;
  new.updated_at := now();
  if (to_jsonb(new) - 'last_mode' - 'updated_at') is distinct from (to_jsonb(old) - 'last_mode' - 'updated_at') then
    insert into public.audit_log (actor, action, target, detail) values (new.updated_by, 'capital_policy_update', 'capital_policy', to_jsonb(new));
  end if;
  return new;
end $$;
drop trigger if exists capital_policy_guard on public.capital_policy;
create trigger capital_policy_guard before update on public.capital_policy for each row execute function public.guard_capital_policy();

-- Recurring commitments: the existing tool registry, plus a renewal date.
alter table public.tool_registry add column if not exists next_renewal_on date;

-- Keep money kinds apart: actual cash vs signed vs qualified vs estimates/forecasts (never mixed in totals).
alter table public.ledger drop constraint if exists ledger_status_check;
alter table public.ledger add constraint ledger_status_check
  check (status = any (array['received','expected','signed','qualified','estimate','forecast']));

create table if not exists public.spend_reservations (
  id uuid primary key default gen_random_uuid(),
  actor text not null,
  action text not null,                 -- an action_policy action (subscription_purchase, routine_expense, ...)
  vendor text not null check (length(vendor) >= 2),
  purpose text not null check (length(purpose) >= 5),
  expected_benefit text not null check (length(expected_benefit) >= 5),
  days_to_benefit int,
  alternatives text not null check (length(alternatives) >= 3),  -- cheaper options considered
  cents int not null check (cents > 0),
  recurring boolean not null default false,
  monthly_cents int,                     -- if recurring
  venture_id uuid references public.ventures(id),
  mission_id uuid references public.missions(id),
  status text not null default 'reserved' check (status in ('reserved','settled','released')),
  actual_cents int,
  receipt_ref text,
  ledger_id uuid,
  action_log_id bigint,
  created_at timestamptz not null default now(),
  settled_at timestamptz
);
alter table public.spend_reservations enable row level security;

-- Where the fund stands right now. AI spend since the fund started counts against it too.
create or replace function public.capital_snapshot()
returns jsonb language plpgsql stable set search_path to 'public' as $$
declare p public.capital_policy; v_start timestamptz; v_rev int; v_exp int; v_ai int; v_res int; v_week int;
        v_recurring int; v_avail int; v_mode text;
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
  v_mode := case when v_avail <= p.hard_stop_cents then 'hard_stop'
                 when v_avail <= p.low_cost_threshold_cents then 'low_cost'
                 else 'normal' end;
  return jsonb_build_object('available_cents', v_avail, 'mode', v_mode, 'fund_cents', p.operating_fund_cents,
    'revenue_cents', v_rev, 'expense_cents', v_exp, 'ai_spend_cents', v_ai, 'reserved_cents', v_res,
    'week_spend_cents', v_week, 'recurring_monthly_cents', v_recurring, 'min_reserve_cents', p.min_reserve_cents,
    'weekly_limit_cents', p.weekly_limit_cents, 'per_transaction_limit_cents', p.per_transaction_limit_cents,
    'reinvest_pct', p.reinvest_pct, 'since', p.fund_started_on);
end $$;

create or replace function public.capital_mode() returns text language sql stable set search_path to 'public' as
$$ select public.capital_snapshot()->>'mode' $$;

-- Every paid non-AI action: policy gate first, then the money rules, then the reservation.
create or replace function public.reserve_spend(
  p_actor text, p_action text, p_vendor text, p_purpose text, p_expected_benefit text, p_alternatives text,
  p_cents int, p_recurring boolean default false, p_monthly_cents int default null, p_days_to_benefit int default null,
  p_venture uuid default null, p_mission uuid default null)
returns jsonb language plpgsql set search_path to 'public' as $$
declare snap jsonb; p public.capital_policy; auth jsonb; v_id uuid; v_log bigint; v_avail int;
begin
  perform pg_advisory_xact_lock(7333);
  select * into p from public.capital_policy where id = 1;
  snap := public.capital_snapshot();
  v_avail := (snap->>'available_cents')::int;
  if coalesce(p_cents, 0) <= 0 then
    return jsonb_build_object('decision','deny','reason','Cost must be known and above zero before spending.');
  end if;
  if snap->>'mode' = 'hard_stop' then
    return jsonb_build_object('decision','deny','reason','Capital hard stop: paid operations are paused.');
  end if;
  if snap->>'mode' = 'low_cost' and (p_recurring or p_cents > 1000) then
    return jsonb_build_object('decision','deny','reason','Low-cost mode: no new subscriptions and nothing over $10 until revenue comes in.');
  end if;
  if v_avail - p_cents < p.min_reserve_cents then
    return jsonb_build_object('decision','deny','reason',
      format('Would break the minimum reserve ($%s available, $%s reserve).', v_avail/100.0, p.min_reserve_cents/100.0));
  end if;
  if p_cents > p.per_transaction_limit_cents then
    return jsonb_build_object('decision','ask_owner','reason',format('Over the per-transaction limit ($%s).', p.per_transaction_limit_cents/100.0));
  end if;
  if (snap->>'week_spend_cents')::int + p_cents > p.weekly_limit_cents then
    return jsonb_build_object('decision','ask_owner','reason',format('Over the weekly limit ($%s).', p.weekly_limit_cents/100.0));
  end if;
  auth := public.authorize_action(p_actor, p_action, p_cents, p_vendor, p_venture, p_mission,
            jsonb_build_object('purpose', p_purpose, 'recurring', p_recurring));
  if auth->>'decision' <> 'allow' then
    return auth;
  end if;
  select id into v_log from public.action_log where actor = p_actor and action = p_action order by id desc limit 1;
  insert into public.spend_reservations (actor, action, vendor, purpose, expected_benefit, alternatives, cents, recurring,
                                         monthly_cents, days_to_benefit, venture_id, mission_id, action_log_id)
    values (p_actor, p_action, p_vendor, p_purpose, p_expected_benefit, p_alternatives, p_cents, p_recurring,
            p_monthly_cents, p_days_to_benefit, p_venture, p_mission, v_log)
    returning id into v_id;
  return jsonb_build_object('decision','allow','reason','Reserved.','reservation_id', v_id,
                            'available_after_cents', v_avail - p_cents);
end $$;

-- After paying: real cost + receipt -> ledger expense (actual cash) and, if recurring, the tool registry.
create or replace function public.settle_spend(p_id uuid, p_actual_cents int, p_receipt text)
returns jsonb language plpgsql set search_path to 'public' as $$
declare r public.spend_reservations; v_ledger uuid;
begin
  select * into r from public.spend_reservations where id = p_id and status = 'reserved' for update;
  if r.id is null then return jsonb_build_object('ok', false, 'reason', 'No open reservation.'); end if;
  if coalesce(p_receipt, '') = '' then return jsonb_build_object('ok', false, 'reason', 'A receipt or provider reference is required.'); end if;
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

create or replace function public.release_spend(p_id uuid) returns void language sql set search_path to 'public' as
$$ update public.spend_reservations set status = 'released', settled_at = now() where id = p_id and status = 'reserved' $$;

-- AI spend gateway becomes capital-aware: hard stop refuses, low-cost mode lowers the company cap.
CREATE OR REPLACE FUNCTION public.reserve_llm_budget(p_agent text, p_est_cents integer, p_model text, p_purpose text)
 RETURNS uuid
 LANGUAGE plpgsql
 SET search_path TO 'public'
AS $function$
declare
  v_ks boolean; v_cap_total int; v_status text; v_cap_agent int;
  v_start timestamptz; v_total int; v_agent int; v_id uuid; v_mode text;
begin
  perform pg_advisory_xact_lock(7331);
  select kill_switch, daily_spend_cap_cents into v_ks, v_cap_total from public.system_state where id = 1;
  if v_ks then raise exception 'Kill switch is on.'; end if;
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
  insert into public.llm_calls (agent_slug, model, purpose, reserved_cents)
    values (p_agent, p_model, p_purpose, p_est_cents) returning id into v_id;
  return v_id;
end $function$;

-- Tell the owner once when the fund changes mode (normal -> low_cost -> hard_stop, or back).
create or replace function public.capital_check() returns void language plpgsql set search_path to 'public' as $$
declare snap jsonb; v_last text; v_mode text;
begin
  snap := public.capital_snapshot();
  v_mode := snap->>'mode';
  select last_mode into v_last from public.capital_policy where id = 1;
  if v_mode is distinct from v_last then
    update public.capital_policy set last_mode = v_mode where id = 1;
    insert into public.owner_messages (from_agent, kind, channel, body)
      values ('jarvis', case when v_mode = 'hard_stop' then 'emergency' else 'money' end, 'telegram',
        case v_mode
          when 'hard_stop' then format('Capital HARD STOP: $%s left in the operating fund. Paid operations and AI calls are paused; data is safe. Add funds or raise the limits with /capital.', (snap->>'available_cents')::int/100.0)
          when 'low_cost' then format('Capital LOW-COST mode: $%s left. No new subscriptions, nothing over $10, AI capped lower, revenue work first.', (snap->>'available_cents')::int/100.0)
          else format('Capital back to normal: $%s available.', (snap->>'available_cents')::int/100.0) end);
  end if;
end $$;

-- Renewals coming up in the next 7 days go in front of the owner (no hidden recurring costs).
create or replace function public.capital_brief_text() returns text language plpgsql stable set search_path to 'public' as $$
declare s jsonb; v_ren text;
begin
  s := public.capital_snapshot();
  select string_agg(format('%s $%s on %s', slug, to_char(monthly_cost_cents/100.0,'FM9990.00'), next_renewal_on), ', ')
    into v_ren from public.tool_registry where status = 'active' and next_renewal_on <= (now() at time zone 'America/Toronto')::date + 7;
  return format('Operating fund: $%s available of $%s start (%s). Spent: AI $%s, other $%s. Recurring: $%s/mo.%s',
    to_char((s->>'available_cents')::int/100.0,'FM99990.00'), to_char((s->>'fund_cents')::int/100.0,'FM99990.00'),
    upper(s->>'mode'), to_char((s->>'ai_spend_cents')::int/100.0,'FM99990.00'),
    to_char((s->>'expense_cents')::int/100.0,'FM99990.00'), to_char((s->>'recurring_monthly_cents')::int/100.0,'FM9990.00'),
    coalesce(' Renewing this week: ' || v_ren || '.', ''));
end $$;

select cron.schedule('hq-capital-check', '*/30 * * * *', 'select public.capital_check()');

-- The 7pm brief gains the operating-fund line (same body as 20261112_brief_missions.sql plus one line).
CREATE OR REPLACE FUNCTION public.daily_brief_text()
 RETURNS text
 LANGUAGE plpgsql
 STABLE
 SET search_path TO 'public'
AS $function$
declare v_done text; v_todo int; v_blocked int; v_leads int; v_facts int; v_flags text; v_money text;
        v_core text; v_reason text; v_since timestamptz; v_days int;
begin
  select coalesce(string_agg('- '||title||' ('||assigned_agent||')', E'\n' order by updated_at desc), '') into v_done
  from (select title, assigned_agent, updated_at from tasks where status='done' and updated_at > now()-interval '24 hours' order by updated_at desc limit 6) d;
  select count(*) filter (where status='todo'), count(*) filter (where status='blocked') into v_todo, v_blocked from tasks;
  select count(*) into v_leads from leads where created_at > now()-interval '24 hours';
  select count(*) into v_facts from memory where kind='fact' and created_at > now()-interval '24 hours';
  select string_agg('- '||check_name||': '||left(detail,120), E'\n') into v_flags
    from (select check_name, detail from reconciliation_flags where status is distinct from 'closed' and created_at > now()-interval '24 hours' order by created_at desc limit 4) f;
  select format('Money logged in 24h: +$%s in, -$%s out',
           to_char(coalesce(sum(amount_cents) filter (where kind='revenue'),0)/100.0,'FM999,990.00'),
           to_char(coalesce(sum(amount_cents) filter (where kind='expense'),0)/100.0,'FM999,990.00'))
    into v_money from ledger where created_at > now()-interval '24 hours';
  v_core := public.daily_brief_core();
  select pause_reason, paused_at into v_reason, v_since from system_state limit 1;
  if v_reason is not null then
    v_days := greatest(1, ceil(extract(epoch from now()-coalesce(v_since, now()))/86400)::int);
    v_core := regexp_replace(v_core, '^Health:[^\n]*',
      'Health: RED. HQ PAUSED for ' || v_days || ' day(s) — ' ||
      case when v_reason = 'api_credits'
           then 'the Anthropic API account is out of credit, so no agent can run. Top up at console.anthropic.com > Settings > Billing; HQ resumes on its own within the hour.'
           else 'reason: ' || v_reason end);
  end if;
  return v_core
    || coalesce(E'\n\n' || public.capital_brief_text(), '')
    || coalesce(E'\n\n' || public.missions_brief_text(), '')
    || E'\n\nDone in the last 24h:\n' || coalesce(nullif(v_done,''),'- nothing')
    || format(E'\nQueue: %s to do, %s blocked', v_todo, v_blocked)
    || format(E'\nNew: %s leads, %s verified facts saved', v_leads, v_facts)
    || E'\n' || v_money
    || E'\n' || coalesce(public.dayjob_week_text(), '')
    || coalesce(E'\nFlags:\n' || v_flags, '');
end $function$;
