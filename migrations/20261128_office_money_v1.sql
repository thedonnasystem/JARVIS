-- FENDEZY GROUP Phase 1, milestone M2 "Office money": virtual sub-ledgers per office + owner-controlled capital allocation. ADDITIVE. Needs 20261127_org_access_v1 (M1).
-- Design (docs/architecture/PHASE1_M2_OFFICE_MONEY.md has the full write-up):
--   * ONE real bank account (the group's). An office's money is ACCOUNTING ATTRIBUTION only: allocations the owner made to it, and the ledger / AI / reserved spend
--     and the received revenue attributed to it. Nothing here moves money, writes the ledger, or changes a cap, the kill switch, dry run, mode, authorize_action,
--     action_policy, reserve_spend / settle_spend / capital_snapshot or any executor. No trigger is added to any existing table.
--   * fz_office_allocations: append-only allocate / clawback events. Written ONLY by the signed-in owner (is_app_owner(); the bot and every API role are refused,
--     also by a table trigger). Every office starts at $0. An allocation can never exceed the group's unallocated real capital (capital_snapshot).
--   * fz_office_money_proposals: the bot / Jarvis may PROPOSE an allocation, a clawback or a reinvestment rule; only the owner executes or rejects it.
--   * fz_office_money_policy: the per-office reinvestment rule (owner only). No row = 0 % (dormant): an office never keeps profit until the owner says so.
--   * fz_money_attribution: which office each ledger row / model call / spend reservation belongs to, stamped once (by the office spend gate, or by fz_money_stamp()
--     from the row's venture or agent office). Rows from before this migration (the cutover) are the group's. Only the owner re-attributes.
--   * fz_office_money (view): per office allocated, spent, revenue, profit, available. Scoped office identities read their OWN row only; Jarvis and the auditor read all.
--   * fz_reserve_office_spend(): an office layer IN FRONT OF the unchanged reserve_spend(). It can only refuse (dormant office, office balance short); otherwise it
--     returns exactly what reserve_spend() decides. Service path only: no scoped identity can call it (and it refuses one even if a grant were added later),
--     so a scoped caller can never consume an owner approval.
-- Ordered BEFORE the lockdown (R3), like M1: it grants only to the fz roles (select on two views) and service_role; every fz_owner_* function checks is_app_owner().
-- Rollback: ops/rollback_office_money.sql. Safe to re-run.

set lock_timeout = '5s';

-- ---------------------------------------------------------------------------------------------------------------------------- tables
create table if not exists public.fz_money_config (
  id int primary key default 1 check (id = 1),
  cutover_at timestamptz not null default now(),                         -- ledger / AI / reservation rows before this are the group's (attribution starts here)
  created_at timestamptz not null default now()
);
-- re-applying never moves the cutover; after a rollback (which archives this table into fz_archive) the archived cutover is reused (review fix 3)
do $$
begin
  if to_regclass('fz_archive.fz_money_config') is not null then
    execute 'insert into public.fz_money_config (id, cutover_at, created_at) select id, cutover_at, created_at from fz_archive.fz_money_config where id = 1 on conflict (id) do nothing';
  end if;
end $$;
insert into public.fz_money_config (id) values (1) on conflict (id) do nothing;

create table if not exists public.fz_office_allocations (
  id bigint generated always as identity primary key,
  office_id uuid not null,                                               -- no foreign key (fz_offices is not exported; M1 lesson)
  kind text not null check (kind in ('allocate', 'clawback')),
  cents integer not null check (cents > 0),
  reason text not null check (length(btrim(reason)) between 3 and 500),
  proposal_id uuid,
  by text not null default 'owner',
  at timestamptz not null default now()
);
create index if not exists fz_office_allocations_office on public.fz_office_allocations (office_id);

create table if not exists public.fz_office_money_policy (
  office_id uuid primary key,
  reinvest_pct integer not null default 0 check (reinvest_pct between 0 and 100),
  updated_by text not null default 'owner',
  updated_at timestamptz not null default now()
);

create table if not exists public.fz_office_money_proposals (
  id uuid primary key default gen_random_uuid(),
  office_id uuid not null,
  kind text not null check (kind in ('allocate', 'clawback', 'reinvest')),
  cents integer check (cents is null or cents > 0),
  reinvest_pct integer check (reinvest_pct is null or reinvest_pct between 0 and 100),
  rationale text not null check (length(btrim(rationale)) between 10 and 2000),
  proposed_by text not null,
  status text not null default 'pending' check (status in ('pending', 'executed', 'rejected', 'expired')),
  created_at timestamptz not null default now(),
  expires_at timestamptz not null default now() + interval '7 days',
  decided_at timestamptz,
  decided_by text,
  result jsonb,
  check ((kind = 'reinvest' and reinvest_pct is not null and cents is null) or (kind <> 'reinvest' and cents is not null and reinvest_pct is null))
);
create index if not exists fz_office_money_proposals_pending on public.fz_office_money_proposals (office_id) where status = 'pending';

create table if not exists public.fz_money_attribution (
  source text not null check (source in ('ledger', 'llm_call', 'reservation')),
  source_id uuid not null,
  office_id uuid not null,
  how text not null check (how in ('office_gate', 'reservation', 'venture', 'agent', 'group', 'owner')),
  by text not null default 'stamp',
  at timestamptz not null default now(),
  primary key (source, source_id)
);
create index if not exists fz_money_attribution_office on public.fz_money_attribution (office_id);

do $$
declare t text;
begin
  foreach t in array array['fz_money_config', 'fz_office_allocations', 'fz_office_money_policy', 'fz_office_money_proposals', 'fz_money_attribution'] loop
    execute format('alter table public.%I enable row level security', t);
    execute format('revoke all on public.%I from public, anon, authenticated, service_role, fz_jarvis, fz_office_agent, fz_auditor', t);
  end loop;
end $$;
-- the bot reads the raw tables; it never writes them (only the functions below do, as their owner)
grant select on public.fz_money_config, public.fz_office_allocations, public.fz_office_money_policy, public.fz_office_money_proposals, public.fz_money_attribution to service_role;
revoke all on sequence public.fz_office_allocations_id_seq from public, anon, authenticated, service_role;

-- ---------------------------------------------------------------------------------------------------------------------------- guards
-- writes only by the signed-in owner (a direct database session without the owner's auth uid is refused too)
create or replace function public.fz_money_owner_only() returns trigger
language plpgsql security definer set search_path to 'pg_catalog' as $$
begin
  if not coalesce(public.is_app_owner(), false) then
    raise exception 'owner approval required: % is written by the signed-in owner only', tg_relname using errcode = '42501';
  end if;
  if tg_op = 'DELETE' then return old; end if;
  return new;
end $$;
revoke all on function public.fz_money_owner_only() from public, anon, authenticated;

-- proposals: inserted by fz_propose_office_money(); decided only by the owner. The one non-owner change: a pending proposal past its expiry may be marked expired (safer).
create or replace function public.fz_money_proposal_guard() returns trigger
language plpgsql security definer set search_path to 'pg_catalog' as $$
begin
  if tg_op = 'DELETE' then raise exception 'proposals are never deleted' using errcode = '42501'; end if;
  if tg_op = 'INSERT' then
    if new.status <> 'pending' or new.decided_at is not null or new.result is not null then raise exception 'a proposal starts pending' using errcode = '42501'; end if;
    return new;
  end if;
  if coalesce(public.is_app_owner(), false) then
    if old.status <> 'pending' then raise exception 'proposal % is already %', old.id, old.status; end if;
    return new;
  end if;
  if old.status = 'pending' and new.status = 'expired' and old.expires_at <= now()
     and (to_jsonb(new) - 'status' - 'decided_at' - 'decided_by') = (to_jsonb(old) - 'status' - 'decided_at' - 'decided_by') then
    return new;
  end if;
  raise exception 'owner approval required: only the owner decides a money proposal' using errcode = '42501';
end $$;
revoke all on function public.fz_money_proposal_guard() from public, anon, authenticated;

-- attribution: stamped once; only the owner re-attributes; never deleted
create or replace function public.fz_money_attribution_guard() returns trigger
language plpgsql security definer set search_path to 'pg_catalog' as $$
begin
  if tg_op = 'DELETE' then raise exception 'attribution is never deleted' using errcode = '42501'; end if;
  if not coalesce(public.is_app_owner(), false) then raise exception 'owner approval required: only the owner re-attributes money' using errcode = '42501'; end if;
  return new;
end $$;
revoke all on function public.fz_money_attribution_guard() from public, anon, authenticated;

drop trigger if exists fz_office_allocations_owner on public.fz_office_allocations;
create trigger fz_office_allocations_owner before insert on public.fz_office_allocations for each row execute function public.fz_money_owner_only();
drop trigger if exists fz_office_allocations_append_only on public.fz_office_allocations;
create trigger fz_office_allocations_append_only before update or delete on public.fz_office_allocations for each row execute function public.fz_append_only();
drop trigger if exists fz_office_money_policy_owner on public.fz_office_money_policy;
create trigger fz_office_money_policy_owner before insert or update or delete on public.fz_office_money_policy for each row execute function public.fz_money_owner_only();
drop trigger if exists fz_office_money_proposals_guard on public.fz_office_money_proposals;
create trigger fz_office_money_proposals_guard before insert or update or delete on public.fz_office_money_proposals for each row execute function public.fz_money_proposal_guard();
drop trigger if exists fz_money_attribution_guard on public.fz_money_attribution;
create trigger fz_money_attribution_guard before update or delete on public.fz_money_attribution for each row execute function public.fz_money_attribution_guard();
do $$
declare t text;
begin
  foreach t in array array['fz_office_allocations', 'fz_office_money_proposals', 'fz_money_attribution', 'fz_money_config'] loop
    execute format('drop trigger if exists %I on public.%I', t || '_no_truncate', t);
    execute format('create trigger %I before truncate on public.%I for each statement execute function public.fz_append_only()', t || '_no_truncate', t);
  end loop;
end $$;
drop trigger if exists fz_money_config_append_only on public.fz_money_config;
create trigger fz_money_config_append_only before update or delete on public.fz_money_config for each row execute function public.fz_append_only();

-- ---------------------------------------------------------------------------------------------------------------------------- the office sub-ledgers (views)
-- Office of a row (the same rule as fz_money_stamp(), applied live to rows not stamped yet):
--   ledger      stamp -> the office of the spend reservation it settled -> its venture's office -> group
--   llm_calls   stamp -> its agent's office -> group
--   reservation stamp -> its venture's office -> its actor agent's office -> group
-- Only rows from the cutover on (or stamped by the owner) count; earlier rows are the group's history.
-- available = net allocation + kept result - open reservations, where result = revenue - expenses - AI and kept = the result itself when it is a loss (a loss uses up the
-- allocation; revenue first covers the office's own costs) or reinvest_pct % of it when it is a profit (the rest of the profit belongs to the group). At 0 % an office can
-- never spend more than its allocation net of losses.
-- Row filter: the service path (service_role, postgres / the owner's SQL session, the cron job) sees all; a scoped identity its OWN office (group scope: every office);
-- a dormant / unknown token and ANY other role (even one granted select by mistake) see nothing.
create or replace view public.fz_office_money with (security_barrier = true) as
with cfg as (select cutover_at from public.fz_money_config where id = 1),
led as (
  select coalesce(a.office_id, ra.office_id, v.office_id, 'f0000000-0000-4000-8000-000000000000'::uuid) as office_id, l.kind, l.amount_cents::bigint as cents
    from public.ledger l
    cross join cfg
    left join public.fz_money_attribution a on a.source = 'ledger' and a.source_id = l.id
    left join lateral (select x.office_id from public.spend_reservations sr join public.fz_money_attribution x on x.source = 'reservation' and x.source_id = sr.id
                        where sr.ledger_id = l.id limit 1) ra on true
    left join public.ventures v on v.id = l.venture_id
   where l.status = 'received' and not coalesce(l.intercompany, false) and l.kind in ('revenue', 'expense')
     and (l.created_at >= cfg.cutover_at or a.office_id is not null)
),
ai as (
  select coalesce(a.office_id, g.office_id, 'f0000000-0000-4000-8000-000000000000'::uuid) as office_id, coalesce(c.actual_cents, c.reserved_cents)::bigint as cents
    from public.llm_calls c
    cross join cfg
    left join public.fz_money_attribution a on a.source = 'llm_call' and a.source_id = c.id
    left join public.agents g on g.slug = c.agent_slug
   where c.status in ('reserved', 'done') and (c.started_at >= cfg.cutover_at or a.office_id is not null)
),
res as (
  select coalesce(a.office_id, v.office_id, g.office_id, 'f0000000-0000-4000-8000-000000000000'::uuid) as office_id, r.cents::bigint as cents
    from public.spend_reservations r
    cross join cfg
    left join public.fz_money_attribution a on a.source = 'reservation' and a.source_id = r.id
    left join public.ventures v on v.id = r.venture_id
    left join public.agents g on g.slug = r.actor
   where r.status = 'reserved' and (r.created_at >= cfg.cutover_at or a.office_id is not null)
),
alloc as (
  select office_id, coalesce(sum(cents) filter (where kind = 'allocate'), 0)::bigint as allocated, coalesce(sum(cents) filter (where kind = 'clawback'), 0)::bigint as clawed
    from public.fz_office_allocations group by office_id
),
m as (
  select o.id as office_id, o.slug as office, o.title, o.kind, o.status,
         coalesce(al.allocated, 0) as allocated_cents, coalesce(al.clawed, 0) as clawed_back_cents,
         coalesce((select sum(cents) from led where led.office_id = o.id and led.kind = 'revenue'), 0)::bigint as revenue_cents,
         coalesce((select sum(cents) from led where led.office_id = o.id and led.kind = 'expense'), 0)::bigint as expense_cents,
         coalesce((select sum(cents) from ai where ai.office_id = o.id), 0)::bigint as ai_cents,
         coalesce((select sum(cents) from res where res.office_id = o.id), 0)::bigint as reserved_cents,
         coalesce(p.reinvest_pct, 0) as reinvest_pct
    from public.fz_offices o
    left join alloc al on al.office_id = o.id
    left join public.fz_office_money_policy p on p.office_id = o.id
)
select m.office_id, m.office, m.title, m.kind, m.status, m.allocated_cents, m.clawed_back_cents, m.allocated_cents - m.clawed_back_cents as net_allocation_cents,
       m.revenue_cents, m.expense_cents, m.ai_cents, m.expense_cents + m.ai_cents as spent_cents, m.reserved_cents,
       m.revenue_cents - m.expense_cents - m.ai_cents as profit_cents, m.reinvest_pct,
       case when m.kind = 'office' then
         m.allocated_cents - m.clawed_back_cents - m.reserved_cents
         + case when m.revenue_cents - m.expense_cents - m.ai_cents > 0 then ((m.revenue_cents - m.expense_cents - m.ai_cents) * m.reinvest_pct) / 100
                else m.revenue_cents - m.expense_cents - m.ai_cents end
       end as available_cents,
       (select cutover_at from cfg) as since
  from m
 where coalesce(nullif(current_setting('role', true), ''), 'none') in ('none', 'postgres', 'service_role')      -- review fix 7: an allowlist of who sees everything
    or (coalesce(nullif(current_setting('role', true), ''), 'none') in ('fz_jarvis', 'fz_office_agent', 'fz_auditor')
        and ((select public.is_group_scope()) or m.office_id = (select public.current_office_id())));   -- scoped: own office (group scope: all); anyone else: nothing

-- the allocation history (who gave or took back how much, and why), same row filter
create or replace view public.fz_office_allocation_log with (security_barrier = true) as
select a.id, a.office_id, o.slug as office, a.kind, a.cents, a.reason, a.by, a.proposal_id, a.at
  from public.fz_office_allocations a
  join public.fz_offices o on o.id = a.office_id
 where coalesce(nullif(current_setting('role', true), ''), 'none') in ('none', 'postgres', 'service_role')      -- review fix 7: an allowlist of who sees everything
    or (coalesce(nullif(current_setting('role', true), ''), 'none') in ('fz_jarvis', 'fz_office_agent', 'fz_auditor')
        and ((select public.is_group_scope()) or a.office_id = (select public.current_office_id())));   -- scoped: own office (group scope: all); anyone else: nothing

revoke all on public.fz_office_money, public.fz_office_allocation_log from public, anon, authenticated, service_role, fz_jarvis, fz_office_agent, fz_auditor;
grant select on public.fz_office_money, public.fz_office_allocation_log to service_role, fz_jarvis, fz_office_agent, fz_auditor;

-- ---------------------------------------------------------------------------------------------------------------------------- stamping
-- Stamps rows from the cutover on that have no attribution yet (bounded per call). Reservations first, so a ledger row settled from one inherits its office.
create or replace function public.fz_money_stamp() returns integer
language plpgsql security definer set search_path to 'pg_catalog' as $$
declare c timestamptz; n int := 0; k int; g uuid := 'f0000000-0000-4000-8000-000000000000';
begin
  select cutover_at into c from public.fz_money_config where id = 1;
  if c is null then return 0; end if;
  insert into public.fz_money_attribution (source, source_id, office_id, how)
    select 'reservation', r.id, coalesce(v.office_id, a.office_id, g),
           case when v.office_id is not null then 'venture' when a.office_id is not null then 'agent' else 'group' end
      from public.spend_reservations r
      left join public.ventures v on v.id = r.venture_id
      left join public.agents a on a.slug = r.actor
     where r.created_at >= c and not exists (select 1 from public.fz_money_attribution x where x.source = 'reservation' and x.source_id = r.id)
     order by r.created_at limit 5000
  on conflict do nothing;
  get diagnostics k = row_count; n := n + k;
  insert into public.fz_money_attribution (source, source_id, office_id, how)
    select 'ledger', l.id, coalesce(ra.office_id, v.office_id, g),
           case when ra.office_id is not null then 'reservation' when v.office_id is not null then 'venture' else 'group' end
      from public.ledger l
      left join lateral (select x.office_id from public.spend_reservations sr join public.fz_money_attribution x on x.source = 'reservation' and x.source_id = sr.id
                          where sr.ledger_id = l.id limit 1) ra on true
      left join public.ventures v on v.id = l.venture_id
     where l.created_at >= c and not exists (select 1 from public.fz_money_attribution x where x.source = 'ledger' and x.source_id = l.id)
     order by l.created_at limit 5000
  on conflict do nothing;
  get diagnostics k = row_count; n := n + k;
  insert into public.fz_money_attribution (source, source_id, office_id, how)
    select 'llm_call', l.id, coalesce(a.office_id, g), case when a.office_id is not null then 'agent' else 'group' end
      from public.llm_calls l
      left join public.agents a on a.slug = l.agent_slug
     where l.started_at >= c and not exists (select 1 from public.fz_money_attribution x where x.source = 'llm_call' and x.source_id = l.id)
     order by l.started_at limit 5000
  on conflict do nothing;
  get diagnostics k = row_count; n := n + k;
  return n;
end $$;
revoke all on function public.fz_money_stamp() from public, anon, authenticated;

-- ---------------------------------------------------------------------------------------------------------------------------- reads for the owner and the bot
-- one office's available balance (service / owner). Internal helper: the scoped roles read the view instead. Returns a plain number on purpose: a function returning the
-- VIEW's row type cannot be restored from the off-site backup (the restore does not recreate these views; found by the backup drill).
create or replace function public.fz_office_available_cents(p_office uuid) returns bigint
language sql stable security definer set search_path to 'pg_catalog' as $$
  select available_cents from public.fz_office_money where office_id = p_office
$$;
revoke all on function public.fz_office_available_cents(uuid) from public, anon, authenticated;

-- group capital that is not earmarked for an office: the capital controller's available cash minus every office's positive available balance
create or replace function public.fz_unallocated_cents() returns bigint
language sql stable security definer set search_path to 'pg_catalog' as $$
  select coalesce((public.capital_snapshot() ->> 'available_cents')::bigint, 0)
       - coalesce((select sum(greatest(available_cents, 0)) from public.fz_office_money where kind = 'office'), 0)
$$;
revoke all on function public.fz_unallocated_cents() from public, anon, authenticated;

-- the consolidated owner report: per office allocated / spent / revenue / profit / available, group totals, unallocated capital, pending proposals
create or replace function public.fz_money_report() returns jsonb
language plpgsql stable security definer set search_path to 'pg_catalog' as $$
declare s jsonb := public.capital_snapshot();
begin
  return jsonb_build_object(
    'since', (select cutover_at from public.fz_money_config where id = 1),
    'offices', coalesce((select jsonb_agg(jsonb_build_object('office', office, 'title', title, 'status', status, 'allocated_cents', net_allocation_cents,
                          'spent_cents', spent_cents, 'reserved_cents', reserved_cents, 'revenue_cents', revenue_cents, 'profit_cents', profit_cents,
                          'reinvest_pct', reinvest_pct, 'available_cents', available_cents) order by office) from public.fz_office_money where kind = 'office'), '[]'::jsonb),
    'group', (select jsonb_build_object('spent_cents', spent_cents, 'reserved_cents', reserved_cents, 'revenue_cents', revenue_cents, 'profit_cents', profit_cents)
                from public.fz_office_money where kind = 'group'),
    'totals', (select jsonb_build_object('allocated_cents', coalesce(sum(net_allocation_cents) filter (where kind = 'office'), 0),
                                         'spent_cents', coalesce(sum(spent_cents), 0), 'reserved_cents', coalesce(sum(reserved_cents), 0),
                                         'revenue_cents', coalesce(sum(revenue_cents), 0), 'profit_cents', coalesce(sum(profit_cents), 0),
                                         'office_available_cents', coalesce(sum(greatest(available_cents, 0)) filter (where kind = 'office'), 0))
                 from public.fz_office_money),
    'capital_available_cents', (s ->> 'available_cents')::bigint,
    'capital_mode', s ->> 'mode',
    'unallocated_cents', public.fz_unallocated_cents(),
    'pending_proposals', coalesce((select jsonb_agg(jsonb_build_object('id', p.id, 'office', o.slug, 'kind', p.kind, 'cents', p.cents, 'reinvest_pct', p.reinvest_pct,
                                     'by', p.proposed_by, 'rationale', left(p.rationale, 300), 'expires_at', p.expires_at) order by p.created_at)
                                     from public.fz_office_money_proposals p join public.fz_offices o on o.id = p.office_id
                                    where p.status = 'pending' and p.expires_at > now()), '[]'::jsonb),
    'note', 'Virtual sub-ledgers: one real bank account (the group). Office balances are attribution, not cash. Rows before "since" are the group''s.');
end $$;
revoke all on function public.fz_money_report() from public, anon, authenticated;

-- ---------------------------------------------------------------------------------------------------------------------------- owner-only controls
create or replace function public.fz_money_require_owner() returns void
language plpgsql stable security definer set search_path to 'pg_catalog' as $$
begin
  if not coalesce(public.is_app_owner(), false) then raise exception 'owner approval required: this action is refused for the bot' using errcode = '42501'; end if;
end $$;
revoke all on function public.fz_money_require_owner() from public, anon, authenticated;

-- the id of an office (never the group). Returns a plain uuid (no table row type in a signature: restorable from the off-site backup).
create or replace function public.fz_money_office(p_office text) returns uuid
language plpgsql stable security definer set search_path to 'pg_catalog' as $$
declare v uuid;
begin
  select id into v from public.fz_offices where slug = p_office and kind = 'office';
  if v is null then raise exception 'unknown office % (the group itself is not allocated to)', coalesce(p_office, '?'); end if;
  return v;
end $$;
revoke all on function public.fz_money_office(text) from public, anon, authenticated;

-- internal executors (owner checked by every caller and again by the table triggers)
create or replace function public.fz_money_do_allocate(p_office text, p_cents integer, p_reason text, p_proposal uuid) returns jsonb
language plpgsql security definer set search_path to 'pg_catalog' as $$
declare o public.fz_offices; v_free bigint; v_id bigint;
begin
  perform public.fz_money_require_owner();
  select * into o from public.fz_offices where id = public.fz_money_office(p_office);
  if coalesce(p_cents, 0) <= 0 then raise exception 'allocation must be above $0'; end if;
  perform pg_advisory_xact_lock(7333);                                    -- the capital controller's lock: no reservation lands between the check and the allocation
  perform public.fz_money_stamp();
  v_free := public.fz_unallocated_cents();
  if p_cents > v_free then
    raise exception 'Refused: $% is more than the $% of group capital not yet allocated. Allocations never exceed real money (claw back from an office or add funds first).',
      to_char(p_cents / 100.0, 'FM999,999,990.00'), to_char(greatest(v_free, 0) / 100.0, 'FM999,999,990.00');
  end if;
  insert into public.fz_office_allocations (office_id, kind, cents, reason, proposal_id, by) values (o.id, 'allocate', p_cents, btrim(p_reason), p_proposal, 'owner') returning id into v_id;
  insert into public.audit_log (actor, action, target, detail) values ('owner', 'office_allocate', 'fz_offices/' || o.slug, jsonb_build_object('cents', p_cents, 'allocation_id', v_id, 'proposal', p_proposal));
  return jsonb_build_object('office', o.slug, 'allocation_id', v_id, 'kind', 'allocate', 'cents', p_cents, 'available_cents', public.fz_office_available_cents(o.id));
end $$;
revoke all on function public.fz_money_do_allocate(text, integer, text, uuid) from public, anon, authenticated;

create or replace function public.fz_money_do_clawback(p_office text, p_cents integer, p_reason text, p_proposal uuid) returns jsonb
language plpgsql security definer set search_path to 'pg_catalog' as $$
declare o public.fz_offices; v_avail bigint; v_c bigint; v_id bigint;
begin
  perform public.fz_money_require_owner();
  select * into o from public.fz_offices where id = public.fz_money_office(p_office);
  perform pg_advisory_xact_lock(7333);
  perform public.fz_money_stamp();
  v_avail := public.fz_office_available_cents(o.id);
  v_c := coalesce(p_cents, v_avail);                                      -- no amount: everything available
  if v_c is null or v_c <= 0 then raise exception 'Nothing to claw back: % has $% available.', o.title, to_char(greatest(coalesce(v_avail, 0), 0) / 100.0, 'FM999,999,990.00'); end if;
  if v_c > v_avail then
    raise exception 'Refused: % has only $% available (spent or reserved money cannot be clawed back).', o.title, to_char(greatest(v_avail, 0) / 100.0, 'FM999,999,990.00');
  end if;
  insert into public.fz_office_allocations (office_id, kind, cents, reason, proposal_id, by) values (o.id, 'clawback', v_c, btrim(p_reason), p_proposal, 'owner') returning id into v_id;
  insert into public.audit_log (actor, action, target, detail) values ('owner', 'office_clawback', 'fz_offices/' || o.slug, jsonb_build_object('cents', v_c, 'allocation_id', v_id, 'proposal', p_proposal));
  return jsonb_build_object('office', o.slug, 'allocation_id', v_id, 'kind', 'clawback', 'cents', v_c, 'available_cents', public.fz_office_available_cents(o.id));
end $$;
revoke all on function public.fz_money_do_clawback(text, integer, text, uuid) from public, anon, authenticated;

create or replace function public.fz_money_do_reinvest(p_office text, p_pct integer) returns jsonb
language plpgsql security definer set search_path to 'pg_catalog' as $$
declare o public.fz_offices; v_old int;
begin
  perform public.fz_money_require_owner();
  select * into o from public.fz_offices where id = public.fz_money_office(p_office);
  if p_pct is null or p_pct < 0 or p_pct > 100 then raise exception 'reinvestment must be 0 to 100 %%'; end if;
  select reinvest_pct into v_old from public.fz_office_money_policy where office_id = o.id;
  insert into public.fz_office_money_policy (office_id, reinvest_pct, updated_by, updated_at) values (o.id, p_pct, 'owner', now())
  on conflict (office_id) do update set reinvest_pct = excluded.reinvest_pct, updated_by = 'owner', updated_at = now();
  insert into public.audit_log (actor, action, target, detail) values ('owner', 'office_reinvest', 'fz_offices/' || o.slug, jsonb_build_object('pct', p_pct, 'was', coalesce(v_old, 0)));
  return jsonb_build_object('office', o.slug, 'reinvest_pct', p_pct, 'was', coalesce(v_old, 0));
end $$;
revoke all on function public.fz_money_do_reinvest(text, integer) from public, anon, authenticated;

create or replace function public.fz_owner_allocate(p_office text, p_cents integer, p_reason text) returns jsonb
language plpgsql security definer set search_path to 'pg_catalog' as $$
begin
  perform public.fz_money_require_owner();
  return public.fz_money_do_allocate(p_office, p_cents, p_reason, null);
end $$;
revoke all on function public.fz_owner_allocate(text, integer, text) from public, anon, authenticated;

-- p_cents null = claw back everything the office has available
create or replace function public.fz_owner_clawback(p_office text, p_cents integer, p_reason text) returns jsonb
language plpgsql security definer set search_path to 'pg_catalog' as $$
begin
  perform public.fz_money_require_owner();
  return public.fz_money_do_clawback(p_office, p_cents, p_reason, null);
end $$;
revoke all on function public.fz_owner_clawback(text, integer, text) from public, anon, authenticated;

create or replace function public.fz_owner_set_reinvest(p_office text, p_pct integer) returns jsonb
language plpgsql security definer set search_path to 'pg_catalog' as $$
begin
  perform public.fz_money_require_owner();
  return public.fz_money_do_reinvest(p_office, p_pct);
end $$;
revoke all on function public.fz_owner_set_reinvest(text, integer) from public, anon, authenticated;

-- execute (approve) or reject a proposal. Approving re-checks everything against TODAY's numbers; if that fails nothing changes and the proposal stays pending.
create or replace function public.fz_owner_decide_office_proposal(p_id uuid, p_approve boolean, p_note text default null) returns jsonb
language plpgsql security definer set search_path to 'pg_catalog' as $$
declare p public.fz_office_money_proposals; o public.fz_offices; res jsonb;
begin
  perform public.fz_money_require_owner();
  select * into p from public.fz_office_money_proposals where id = p_id for update;
  if not found then raise exception 'unknown proposal %', p_id; end if;
  if p.status <> 'pending' then raise exception 'proposal % is already %', p_id, p.status; end if;
  select * into o from public.fz_offices where id = p.office_id;
  if p.expires_at <= now() then
    update public.fz_office_money_proposals set status = 'expired', decided_at = now(), decided_by = 'owner' where id = p_id;
    return jsonb_build_object('proposal', p_id, 'status', 'expired');
  end if;
  if not coalesce(p_approve, false) then
    update public.fz_office_money_proposals set status = 'rejected', decided_at = now(), decided_by = 'owner', result = jsonb_build_object('note', left(coalesce(p_note, ''), 300)) where id = p_id;
    insert into public.audit_log (actor, action, target, detail) values ('owner', 'office_money_rejected', 'fz_office_money_proposals/' || p_id, jsonb_build_object('office', o.slug, 'kind', p.kind));
    return jsonb_build_object('proposal', p_id, 'status', 'rejected');
  end if;
  res := case p.kind
           when 'allocate' then public.fz_money_do_allocate(o.slug, p.cents, 'proposal by ' || p.proposed_by || ': ' || left(p.rationale, 400), p.id)
           when 'clawback' then public.fz_money_do_clawback(o.slug, p.cents, 'proposal by ' || p.proposed_by || ': ' || left(p.rationale, 400), p.id)
           else public.fz_money_do_reinvest(o.slug, p.reinvest_pct) end;
  update public.fz_office_money_proposals set status = 'executed', decided_at = now(), decided_by = 'owner', result = res where id = p_id;
  return jsonb_build_object('proposal', p_id, 'status', 'executed', 'result', res);
end $$;
revoke all on function public.fz_owner_decide_office_proposal(uuid, boolean, text) from public, anon, authenticated;

-- move a ledger row (e.g. revenue the stamp gave to the group) to an office, or back to the group ('group')
create or replace function public.fz_owner_attribute_ledger(p_ledger uuid, p_office text, p_reason text) returns jsonb
language plpgsql security definer set search_path to 'pg_catalog' as $$
declare v_office uuid; v_was uuid;
begin
  perform public.fz_money_require_owner();
  if not exists (select 1 from public.ledger where id = p_ledger) then raise exception 'unknown ledger row'; end if;
  if coalesce(length(btrim(p_reason)), 0) < 3 then raise exception 'give a reason'; end if;
  select id into v_office from public.fz_offices where slug = p_office;
  if v_office is null then raise exception 'unknown office %', p_office; end if;
  select office_id into v_was from public.fz_money_attribution where source = 'ledger' and source_id = p_ledger;
  insert into public.fz_money_attribution (source, source_id, office_id, how, by) values ('ledger', p_ledger, v_office, 'owner', 'owner')
  on conflict (source, source_id) do update set office_id = excluded.office_id, how = 'owner', by = 'owner', at = now();
  insert into public.audit_log (actor, action, target, detail)
    values ('owner', 'ledger_attribution', 'ledger/' || p_ledger, jsonb_build_object('office', p_office, 'was', v_was, 'reason', left(p_reason, 300)));
  return jsonb_build_object('ledger', p_ledger, 'office', p_office);
end $$;
revoke all on function public.fz_owner_attribute_ledger(uuid, text, text) from public, anon, authenticated;

-- ---------------------------------------------------------------------------------------------------------------------------- the bot / Jarvis: propose only
create or replace function public.fz_propose_office_money(p_office text, p_kind text, p_cents integer, p_reinvest_pct integer, p_rationale text, p_by text default 'jarvis') returns jsonb
language plpgsql security definer set search_path to 'pg_catalog' as $$
declare o public.fz_offices; v_id uuid; v_by text := left(regexp_replace(coalesce(nullif(btrim(p_by), ''), 'jarvis'), '[^A-Za-z0-9:_.-]', '', 'g'), 60); v_what text; v_note text;
begin
  if v_by = '' then v_by := 'jarvis'; end if;
  if coalesce(nullif(current_setting('role', true), ''), 'none') in ('fz_jarvis', 'fz_office_agent', 'fz_auditor') then
    raise exception 'money proposals are made on the service path' using errcode = '42501';
  end if;
  select * into o from public.fz_offices where id = public.fz_money_office(p_office);
  if v_by ilike 'owner%' then v_by := 'bot:' || v_by; end if;                -- a caller cannot record itself as the owner
  perform pg_advisory_xact_lock(hashtext('fzm_prop:' || o.id::text));     -- review fix 8: two concurrent proposals cannot both pass the pending count
  update public.fz_office_money_proposals set status = 'expired', decided_at = now(), decided_by = 'expiry' where status = 'pending' and expires_at <= now();
  if (select count(*) from public.fz_office_money_proposals where office_id = o.id and status = 'pending') >= 3 then
    raise exception '% already has 3 pending money proposals: wait for the owner', o.title;
  end if;
  insert into public.fz_office_money_proposals (office_id, kind, cents, reinvest_pct, rationale, proposed_by)
    values (o.id, p_kind, case when p_kind = 'reinvest' then null else p_cents end, case when p_kind = 'reinvest' then p_reinvest_pct else null end, btrim(p_rationale), v_by)
    returning id into v_id;
  v_what := case p_kind when 'allocate' then format('allocate $%s to %s', to_char(p_cents / 100.0, 'FM999,999,990.00'), o.title)
                        when 'clawback' then format('claw back $%s from %s', to_char(p_cents / 100.0, 'FM999,999,990.00'), o.title)
                        else format('set %s reinvestment to %s%% of profit', o.title, p_reinvest_pct) end;
  -- review fix 6: the real command comes FIRST; the bot's text is fenced below it as an unverified note, with semicolons, quotes and SQL words removed, so it cannot
  -- pass for a command to paste
  v_note := regexp_replace(left(btrim(p_rationale), 600), '[;`''"\\$]', '', 'g');
  v_note := regexp_replace(v_note, '(fz_[A-Za-z0-9_]*|\m(select|insert|update|delete|drop|grant|revoke|alter|create|truncate|begin|commit|rollback|set_config|execute|call|do)\M)', '[removed]', 'gi');
  if exists (select 1 from public.agents where slug = 'jarvis') then
    insert into public.owner_messages (from_agent, kind, channel, body)
      values ('jarvis', 'money', 'telegram', format(E'Money proposal: %s (proposed by %s).\nTo approve, in your owner session (only you can): select public.fz_owner_decide_office_proposal(%L, true);   false instead of true rejects it.\n----- Jarvis''s note (unverified, not a command) -----\n%s\n----- end of note -----',
                                                    v_what, v_by, v_id, v_note));
  end if;
  insert into public.audit_log (actor, action, target, detail) values (v_by, 'office_money_proposed', 'fz_office_money_proposals/' || v_id, jsonb_build_object('office', o.slug, 'kind', p_kind));
  return jsonb_build_object('proposal', v_id, 'office', o.slug, 'kind', p_kind, 'status', 'pending', 'note', 'Only the owner can execute it.');
end $$;
revoke all on function public.fz_propose_office_money(text, text, integer, integer, text, text) from public, anon, authenticated;

-- after an allowed reservation through an office gate: stamp the reservation to the office, and label the allow row that reserve_spend() wrote (its action_log_id) with
-- detail.office, so M1's office daily count (fz_office_refusal) counts it like an fz_authorize_action allow. Internal (gates only).
create or replace function public.fz_money_mark_office_allow(p_reservation uuid, p_office uuid, p_by text) returns void
language plpgsql security definer set search_path to 'pg_catalog' as $$
declare v_slug text := (select slug from public.fz_offices where id = p_office);
begin
  insert into public.fz_money_attribution (source, source_id, office_id, how, by) values ('reservation', p_reservation, p_office, 'office_gate', left(coalesce(p_by, ''), 60))
  on conflict do nothing;
  update public.action_log l set detail = coalesce(l.detail, '{}'::jsonb) || jsonb_build_object('office', v_slug, 'layer', 'office_gate')
   where l.id = (select r.action_log_id from public.spend_reservations r where r.id = p_reservation) and l.decision = 'allow';
end $$;
revoke all on function public.fz_money_mark_office_allow(uuid, uuid, text) from public, anon, authenticated;

-- ---------------------------------------------------------------------------------------------------------------------------- the office spend gate
-- In FRONT of the unchanged reserve_spend(). Office 'group' (or null): reserve_spend() exactly, the reservation stamped to the group. An office:
--   refused (logged) when the office is not active or its available balance is below the cost; otherwise reserve_spend() decides, unchanged, and an allowed
--   reservation is stamped to the office (so its spend and, once settled, its ledger row count against the office). It can only refuse, never allow more.
-- Service path only. A scoped identity is refused before anything is evaluated: it can never consume an owner approval or create a reservation.
create or replace function public.fz_reserve_office_spend(p_office text, p_actor text, p_action text, p_vendor text, p_purpose text, p_expected_benefit text,
                                                          p_alternatives text, p_cents integer, p_recurring boolean default false, p_monthly_cents integer default null,
                                                          p_days_to_benefit integer default null, p_venture uuid default null, p_mission uuid default null) returns jsonb
language plpgsql security definer set search_path to 'pg_catalog' as $$
declare o public.fz_offices; v_avail bigint; v_reason text; res jsonb; v_cents int := coalesce(p_cents, 0); v_found boolean;
begin
  if coalesce(nullif(current_setting('role', true), ''), 'none') in ('fz_jarvis', 'fz_office_agent', 'fz_auditor') then
    raise exception 'the office spend gate is service-path only: a scoped identity evaluates with fz_authorize_action and never reserves' using errcode = '42501';
  end if;
  -- review fix 2: when the spend is for a venture, the VENTURE decides the office (M1 ventures.office_id); a different p_office is refused, and 'group' is accepted
  -- only for a venture of the group. So nobody can skip a dormant office by saying 'group', or charge one office for another office's venture.
  if p_venture is not null then
    select f.* into o from public.ventures v join public.fz_offices f on f.id = v.office_id where v.id = p_venture;
    v_found := found;
    if not v_found then
      v_reason := 'The venture or its office is unknown: refused.';
    elsif p_office is not null and p_office is distinct from o.slug then
      v_reason := format('Office mismatch: this venture belongs to %s, not %s. Refused.', o.slug, p_office);
    end if;
  elsif p_office is null or p_office = 'group' then
    select * into o from public.fz_offices where kind = 'group';
  else
    select * into o from public.fz_offices where slug = p_office and kind = 'office';
    if not found then raise exception 'unknown office %', p_office; end if;
  end if;
  if v_reason is null and o.kind = 'office' then
    perform pg_advisory_xact_lock(7333);                                  -- reserve_spend's lock, then authorize_action's: the same order they take them (no deadlock)
    perform pg_advisory_xact_lock(7332);
    -- review fix 1: M1's office layer, exactly as fz_authorize_action applies it (status, office rule allowed / per-action cap / daily count)
    v_reason := public.fz_office_refusal(o.id, p_action, v_cents);
    if v_reason is null then
      v_avail := public.fz_office_available_cents(o.id);
      if v_cents > 0 and coalesce(v_avail, 0) < v_cents then
        v_reason := format('Office %s has $%s available, the cost is $%s. Ask the owner for an allocation (fz_propose_office_money).', o.title,
                           to_char(greatest(coalesce(v_avail, 0), 0) / 100.0, 'FM999,999,990.00'), to_char(v_cents / 100.0, 'FM999,999,990.00'));
      end if;
    end if;
  end if;
  if v_reason is not null then
    insert into public.action_log (actor, action, tier, decision, reason, cents, venture_id, mission_id, ref, detail)
      values (coalesce(nullif(btrim(p_actor), ''), 'unknown'), p_action, (select tier from public.action_policy where action = p_action), 'deny', v_reason, greatest(v_cents, 0),
              p_venture, p_mission, p_vendor, jsonb_build_object('office', coalesce(o.slug, p_office), 'layer', 'office_money', 'available_cents', v_avail));
    return jsonb_build_object('decision', 'deny', 'reason', v_reason, 'office', coalesce(o.slug, p_office), 'available_cents', v_avail);
  end if;
  res := public.reserve_spend(p_actor, p_action, p_vendor, p_purpose, p_expected_benefit, p_alternatives, p_cents, p_recurring, p_monthly_cents, p_days_to_benefit, p_venture, p_mission);
  if res ->> 'decision' = 'allow' and res ? 'reservation_id' then
    perform public.fz_money_mark_office_allow((res ->> 'reservation_id')::uuid, o.id, p_actor);
  end if;
  return res || jsonb_build_object('office', o.slug);
end $$;
revoke all on function public.fz_reserve_office_spend(text, text, text, text, text, text, text, integer, boolean, integer, integer, uuid, uuid) from public, anon, authenticated;

-- none of the functions above is for a scoped identity (the M1 allowlist stays exact)
do $$
declare f regprocedure;
begin
  for f in select p.oid::regprocedure from pg_proc p where p.pronamespace = 'public'::regnamespace and p.proname in
             ('fz_money_owner_only', 'fz_money_proposal_guard', 'fz_money_attribution_guard', 'fz_money_stamp', 'fz_office_available_cents', 'fz_unallocated_cents', 'fz_money_report',
              'fz_money_require_owner', 'fz_money_office', 'fz_money_do_allocate', 'fz_money_do_clawback', 'fz_money_do_reinvest', 'fz_owner_allocate', 'fz_owner_clawback',
              'fz_owner_set_reinvest', 'fz_owner_decide_office_proposal', 'fz_owner_attribute_ledger', 'fz_propose_office_money', 'fz_reserve_office_spend', 'fz_money_mark_office_allow') loop
    execute format('revoke all on function %s from fz_jarvis, fz_office_agent, fz_auditor', f);
  end loop;
end $$;

-- stamp every 15 minutes (on Supabase: pg_cron). Also run by the gate and by every owner money action.
do $$
begin
  if exists (select 1 from pg_namespace where nspname = 'cron') then
    perform cron.unschedule(jobid) from cron.job where jobname = 'fz-money-stamp';
    perform cron.schedule('fz-money-stamp', '*/15 * * * *', 'select public.fz_money_stamp()');
  end if;
end $$;

-- ---------------------------------------------------------------------------------------------------------------------------- table registry (M1) for the new tables
-- office-owned money (by office_id): NO scoped access to the raw tables; scoped identities read the two filtered views. Group config: no scoped access.
insert into public.fz_table_registry (relname, scope, scope_column, data_class, fz_read, fz_write, fz_insert_columns, fz_update_columns, note) values
  ('fz_money_config',           'group',  null,        'confidential', false, '{}', null, null, 'office money: attribution cutover (rows before it are the group''s)'),
  ('fz_office_allocations',     'office', 'office_id', 'confidential', false, '{}', null, null, 'office money: owner allocations / clawbacks (append-only, owner-only writes); read through fz_office_allocation_log'),
  ('fz_office_money_policy',    'office', 'office_id', 'confidential', false, '{}', null, null, 'office money: reinvestment rule per office (owner-only; no row = 0 %)'),
  ('fz_office_money_proposals', 'office', 'office_id', 'confidential', false, '{}', null, null, 'office money: bot / Jarvis proposals; only the owner executes'),
  ('fz_money_attribution',      'office', 'office_id', 'confidential', false, '{}', null, null, 'office money: which office each ledger row / model call / reservation belongs to (stamped once, owner re-attributes)')
on conflict (relname) do update set scope = excluded.scope, scope_column = excluded.scope_column, data_class = excluded.data_class, fz_read = excluded.fz_read,
  fz_write = excluded.fz_write, fz_insert_columns = excluded.fz_insert_columns, fz_update_columns = excluded.fz_update_columns, note = excluded.note;

-- ---------------------------------------------------------------------------------------------------------------------------- backup classification (PROTECTED: owner approval)
-- Same rows as 20261127_org_access_v1 (unchanged, same order) plus the five office-money tables. Without this the backup fails closed on unclassified tables.
create or replace function public.backup_classification() returns table (table_name text, data_class text, note text)
language sql immutable set search_path to 'pg_catalog' as $$
  select * from (values
    -- public: non-personal reference data
    ('model_prices', 'public', 'published model prices'),
    -- secret: never exported, never in any backup
    ('push_config', 'secret', 'private push keys'),
    ('push_subscriptions', 'secret', 'push endpoints and keys'),
    -- client_pii: third-party personal data (leads, prospects, replies, setters, suppression list). EXCLUDED until retention, access, deletion and key policy are set.
    ('leads', 'client_pii', 'prospect name, phone, email, notes'),
    ('outbox', 'client_pii', 'drafts and recipients (to_ref) for leads'),
    ('lead_replies', 'client_pii', 'free-text notes about replies from leads'),
    ('deals', 'client_pii', 'notes about leads; references leads'),
    ('contact_suppressions', 'client_pii', 'opted-out email addresses. After a restore from an off-site backup this list is EMPTY: restore it from the database provider backup before any outreach is ever enabled'),
    ('setters', 'client_pii', 'sales partner name and contact'),
    ('setter_events', 'client_pii', 'client names per setter event'),
    ('setter_payouts', 'client_pii', 'references setters'),
    ('client_workspaces', 'client_pii', 'client company names'),
    -- internal: operating data of the owner and the ventures
    ('account_requests', 'internal', 'vendor sign-up requests; login name only, never a password'),
    ('accounts_registry', 'internal', 'which service accounts exist; vault reference only'),
    ('action_log', 'internal', 'action audit'), ('action_policy', 'internal', 'autonomy tiers'), ('agent_runs', 'internal', 'run summaries (free text)'),
    ('agents', 'internal', 'agent definitions'), ('alert_state', 'internal', 'alert throttling'), ('app_owners', 'internal', 'owner login emails'),
    ('approval_requests', 'internal', 'approvals'), ('audit_log', 'internal', 'audit trail (free text in detail)'), ('bank_accounts', 'internal', 'owner own bank labels and last4'),
    ('bank_balances', 'internal', 'owner own balances'), ('bank_transactions', 'internal', 'owner own transactions'), ('build_requests', 'internal', 'build queue'),
    ('capital_policy', 'internal', 'spend limits'), ('company_profile', 'internal', 'sender identity of the owner ventures'), ('dayjob_days', 'internal', 'day job counters'),
    ('dayjob_targets', 'internal', 'day job targets'), ('departments', 'internal', 'org'), ('escalations', 'internal', 'escalations (free text)'),
    ('evidence_sources', 'internal', 'fetched public web pages'), ('executor_registry', 'internal', 'executor limits'), ('executor_runs', 'internal', 'executor audit'),
    ('handbook', 'internal', 'handbook'), ('human_handoffs', 'internal', 'tasks for the owner (free text)'), ('ideas', 'internal', 'ideas'),
    ('integration_status', 'internal', 'integration health'), ('ledger', 'internal', 'books'), ('llm_calls', 'internal', 'model call meter'),
    ('memory', 'internal', 'agent memory (free text)'), ('mission_outcomes', 'internal', 'outcomes'), ('missions', 'internal', 'missions (free text)'),
    ('org_changes', 'internal', 'org proposals'), ('owner_messages', 'internal', 'messages to the owner (free text)'), ('payment_instructions', 'internal', 'payment requests; payee may be a person'),
    ('predictions', 'internal', 'predictions'), ('reconciliation_flags', 'internal', 'reconciliation'), ('setter_terms', 'internal', 'setter commission terms'),
    ('spend_reservations', 'internal', 'spend gateway'), ('system_state', 'internal', 'kill switch and modes'), ('systems', 'internal', 'registered systems'),
    ('tasks', 'internal', 'tasks (free text)'), ('tool_registry', 'internal', 'tools'), ('venture_assets', 'internal', 'assets'), ('venture_config', 'internal', 'venture offer config'),
    ('venture_goals', 'internal', 'goals'), ('venture_procedures', 'internal', 'procedures'), ('ventures', 'internal', 'ventures'), ('waterfall_policy', 'internal', 'money waterfall'),
    ('web_messages', 'internal', 'owner chat (free text)'),
    -- Jarvis core v2 (20261123). Class 'secret' = NOT in the off-site export (the database provider's own backups still hold them). Reason: the leak-redaction
    -- export needs a reviewed backup_redaction_spec() entry for every exported text column; until those are written (follow-up, protected) the safe choice is to keep
    -- these operational tables out of the off-site file. They hold no client data by design; jarvis_result_cache may.
    ('jarvis_core_config', 'secret', 'Jarvis core switches; off-site export pending a reviewed redaction spec'), ('jarvis_jobs', 'secret', 'job queue; off-site export pending a reviewed redaction spec'),
    ('jarvis_job_events', 'secret', 'append-only queue audit; off-site export pending a reviewed redaction spec'), ('jarvis_task_stats', 'secret', 'run counts per task class; off-site export pending'),
    ('jarvis_changelog', 'secret', 'append-only changelog; off-site export pending'), ('jarvis_call_log', 'secret', 'append-only emergency-call ledger (no phone numbers); off-site export pending'),
    ('jarvis_large_approvals', 'secret', 'owner approvals for the large model tier; off-site export pending'), ('jarvis_self_fund_credits', 'secret', 'owner-confirmed Jarvis revenue (amounts only); off-site export pending'),
    ('jarvis_agent_wakes', 'secret', 'append-only agent wake / sleep log; off-site export pending'),
    ('jarvis_result_cache', 'secret', 'cached task output; may contain client data, never exported (rebuilt on demand)'),
    ('jarvis_call_criteria', 'secret', 'the owner-approved emergency-call events (copy of ops/CRITICAL_EVENTS.json); off-site export pending'),
    ('jarvis_seed_staging', 'secret', 'owner profile import staged by the bot until the owner applies it; private, never exported'),
    -- Jarvis hands v1 (20261124): metadata only, no secrets (vault references are ids; tokens and passwords live only in the vault)
    ('hand_connectors', 'internal', 'connector registry and owner settings'), ('hand_accounts', 'internal', 'which accounts exist; vault references only, no secrets'),
    ('hand_actions', 'internal', 'action and content queue (payload free text is not exported)'), ('hand_standing', 'internal', 'owner standing approvals'),
    -- Org & Access M1 (20261127): org registry. Class 'secret' = not in the off-site export (as Jarvis core): the offices, identities and table registry are re-seeded by the
    -- migration (statuses come back DORMANT, which is the safe state); exporting them needs reviewed backup_redaction_spec() rows first (follow-up, protected).
    ('fz_offices', 'secret', 'the group and the eight offices; re-seeded by the migration; off-site export pending a reviewed redaction spec'),
    ('fz_identities', 'secret', 'identity registry (status, pinned token ids); re-seeded by the migration'),
    ('fz_table_registry', 'secret', 'table classification; re-seeded by the migration'),
    ('fz_workspace_offices', 'secret', 'which office serves each client workspace; off-site export pending'),
    ('fz_office_action_policy', 'secret', 'per-office tighten-only permission overlay; off-site export pending'),
    ('fz_org_archive', 'secret', 'append-only log of the org re-seed decisions; off-site export pending'),
    -- Office money M2 (20261128): virtual sub-ledgers. 'secret' = not in the off-site export, like the M1 registry. After a restore from the off-site file every office is
    -- back at $0 with no reinvestment (the strictest state); the database provider's own backups keep the history. Exporting needs reviewed redaction-spec rows (protected).
    ('fz_money_config', 'secret', 'office money attribution cutover; re-created by the migration'),
    ('fz_office_allocations', 'secret', 'owner allocations / clawbacks per office (amounts and reasons); off-site export pending'),
    ('fz_office_money_policy', 'secret', 'per-office reinvestment rule; off-site export pending'),
    ('fz_office_money_proposals', 'secret', 'bot money proposals and owner decisions; off-site export pending'),
    ('fz_money_attribution', 'secret', 'office of each ledger row / model call / reservation; off-site export pending')
  ) v (table_name, data_class, note)
$$;
revoke all on function public.backup_classification() from public, anon, authenticated;
reset lock_timeout;
