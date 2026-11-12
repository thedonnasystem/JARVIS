-- Master Plan rules: reinvestment waterfall, HST watch, revenue-venture slots, and coast mode when the owner is away.
-- Numbers here are PROPOSALS (the plan says Moe sets them; an accountant confirms tax). Defaults apply until he changes them.
-- Only RECEIVED cash feeds the waterfall. Service-key only; owner-only edits to the policy.
create table if not exists public.waterfall_policy (
  id int primary key check (id = 1),
  tax_pct numeric not null default 33 check (tax_pct between 0 and 60),                 -- plan: 30-35% until an accountant sets it
  buffer_months numeric not null default 1.5 check (buffer_months between 0 and 6),    -- plan: one to two months of costs
  owner_draw_cents int not null default 0 check (owner_draw_cents >= 0),                -- a fixed monthly amount only Moe names
  pool_best_pct numeric not null default 60, pool_research_pct numeric not null default 25, pool_deal_pct numeric not null default 15,
  max_revenue_ventures int not null default 3 check (max_revenue_ventures between 1 and 10),
  hst_threshold_cents bigint not null default 3000000,
  coast_after_days int not null default 3 check (coast_after_days between 1 and 30),
  updated_by text not null default 'seed', updated_at timestamptz not null default now(),
  check (pool_best_pct + pool_research_pct + pool_deal_pct = 100));
insert into public.waterfall_policy (id) values (1) on conflict do nothing;
alter table public.waterfall_policy enable row level security;
create or replace function public.waterfall_policy_guard() returns trigger language plpgsql as $$
begin
  if new.updated_by is null or new.updated_by not like 'owner%' then raise exception 'Only the owner can change the waterfall policy.'; end if;
  new.updated_at := now(); return new;
end $$;
drop trigger if exists waterfall_policy_guard on public.waterfall_policy;
create trigger waterfall_policy_guard before update on public.waterfall_policy for each row execute function public.waterfall_policy_guard();

alter table public.system_state add column if not exists owner_last_seen timestamptz;
create or replace function public.owner_seen() returns void language sql set search_path to 'public' as
$$ update public.system_state set owner_last_seen = now() where id = 1 $$;
create or replace function public.coast_state() returns jsonb language plpgsql stable set search_path to 'public' as $$
declare p public.waterfall_policy; seen timestamptz;
begin
  select * into p from public.waterfall_policy where id = 1;
  select owner_last_seen into seen from public.system_state where id = 1;
  return jsonb_build_object('coast', seen is not null and seen < now() - make_interval(days => p.coast_after_days),
    'last_seen', seen, 'after_days', p.coast_after_days);
end $$;

-- Where each received dollar goes, for the last p_days (default 30). Linear: tax, then running costs, then living buffer, then the draw, then the pool.
create or replace function public.waterfall(p_days int default 30) returns jsonb
language plpgsql stable set search_path to 'public' as $$
declare p public.waterfall_policy; d int := greatest(1, least(coalesce(p_days, 30), 365)); since_ timestamptz;
  rev bigint; ledger_exp bigint; ai bigint; costs bigint; burn bigint; tax bigint; after_tax bigint; after_costs bigint;
  buf_target bigint; buf_have bigint; buf_fill bigint; after_buf bigint; draw bigint; pool bigint; t12 bigint; hst text;
begin
  select * into p from public.waterfall_policy where id = 1;
  since_ := now() - make_interval(days => d);
  select coalesce(sum(amount_cents) filter (where kind = 'revenue'), 0), coalesce(sum(amount_cents) filter (where kind = 'expense'), 0)
    into rev, ledger_exp from public.ledger where status = 'received' and not coalesce(intercompany, false) and created_at >= since_;
  select coalesce(sum(coalesce(actual_cents, reserved_cents)), 0) into ai from public.llm_calls where status in ('reserved','done') and started_at >= since_;
  costs := ledger_exp + ai;
  tax := round(rev * p.tax_pct / 100);
  after_tax := rev - tax;
  after_costs := after_tax - costs;
  -- monthly burn: last 30 days of costs plus recurring tool commitments, whichever is larger
  select greatest(
    coalesce((select sum(amount_cents) from public.ledger where kind = 'expense' and status = 'received' and not coalesce(intercompany,false) and created_at >= now() - interval '30 days'), 0)
      + coalesce((select sum(coalesce(actual_cents, reserved_cents)) from public.llm_calls where status in ('reserved','done') and started_at >= now() - interval '30 days'), 0),
    coalesce((select sum(monthly_cost_cents) from public.tool_registry where status = 'active'), 0)) into burn;
  buf_target := round(burn * p.buffer_months);
  buf_have := greatest((public.capital_snapshot()->>'available_cents')::bigint, 0);
  buf_fill := greatest(least(greatest(after_costs, 0), buf_target - buf_have), 0);
  after_buf := greatest(after_costs, 0) - buf_fill;
  draw := least(after_buf, p.owner_draw_cents::bigint * d / 30);
  pool := after_buf - draw;
  select coalesce(sum(amount_cents), 0) into t12 from public.ledger
    where kind = 'revenue' and status = 'received' and not coalesce(intercompany, false) and created_at >= now() - interval '12 months';
  hst := case when t12 >= p.hst_threshold_cents then 'REGISTER: trailing 12-month revenue is at or past the HST small-supplier threshold. Confirm with your accountant now.'
              when t12 >= p.hst_threshold_cents * 0.8 then 'WATCH: trailing 12-month revenue is within 20% of the HST threshold. Ask your accountant about registering.'
              else 'ok' end;
  return jsonb_build_object('days', d, 'revenue_cents', rev, 'tax_setaside_cents', tax, 'running_costs_cents', costs,
    'buffer_target_cents', buf_target, 'buffer_have_cents', buf_have, 'buffer_fill_cents', buf_fill, 'owner_draw_cents', draw,
    'pool_cents', pool, 'pool_best_cents', round(pool * p.pool_best_pct / 100), 'pool_research_cents', round(pool * p.pool_research_pct / 100),
    'pool_deal_cents', pool - round(pool * p.pool_best_pct / 100) - round(pool * p.pool_research_pct / 100),
    'shortfall_cents', greatest(-after_costs, 0), 'tax_pct', p.tax_pct, 'trailing_12m_revenue_cents', t12, 'hst', hst,
    'note', 'A structure to test, not financial advice. Only received cash counts. An accountant should confirm the tax rate and HST.');
end $$;

create or replace function public.activate_venture(p_slug text, p_by text) returns void language plpgsql set search_path to 'public' as $$
begin
  if coalesce(p_by, '') not like 'owner%' then raise exception 'Only the owner can activate a venture.'; end if;
  if (select count(*) from public.ventures where status = 'active' and kind = 'revenue' and slug <> p_slug)
       >= (select max_revenue_ventures from public.waterfall_policy where id = 1)
     and (select kind from public.ventures where slug = p_slug) = 'revenue' then
    raise exception 'Revenue venture slots are full (max % at once). Park or cut one first.', (select max_revenue_ventures from public.waterfall_policy where id = 1);
  end if;
  update public.ventures set status = 'active', stage = case when stage = 'idea' then 'validate' else stage end where slug = p_slug and status in ('proposed','paused');
  if not found then raise exception 'Venture % is not waiting for activation.', p_slug; end if;
  update public.departments set status = 'active' where slug = p_slug;
  update public.agents set status = 'active' where venture_id = (select id from public.ventures where slug = p_slug);
  insert into public.audit_log (actor, action, target, detail) values (p_by, 'venture_activated', 'ventures/' || p_slug, '{}'::jsonb);
  -- The manager's first job: turn the validation mission's findings into a 30-day operating plan (planning only).
  insert into public.tasks (assigned_agent, created_by, title, detail, status, priority, venture_id)
  select manager_agent, 'system', 'Operating plan: ' || name,
         'Read what HQ already knows about this venture (memory, mission results) and write a 30-day operating plan: 3 measurable goals with numbers, the first 5 actions in order, the cheapest first-dollar path, and what would make you recommend shutting it down. Planning only: no spending, no contacting anyone. Budget ceiling: ' || monthly_budget_cents || ' cents/month.' ||
         E'\nFinish with up to 3 lines: NEXT: <action>',
         'todo', 1, id
  from public.ventures where slug = p_slug and manager_agent is not null;
end $$;

revoke all on public.waterfall_policy from public, anon, authenticated;
revoke all on function public.waterfall(int), public.coast_state(), public.owner_seen() from public, anon, authenticated;
