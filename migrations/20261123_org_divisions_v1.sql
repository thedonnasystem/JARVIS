-- Organization layer v1 (docs/org/ORG_ARCHITECTURE.md). UNRELEASED PROPOSAL: do not apply to production without a release authorization.
-- Additive: 2 tables, 6 functions, 1 trigger. Re-declares backup_classification() (same signature) only to classify the 2 new tables.
-- Touches no existing table, the spend gateway, the kill switch, spend caps, action policy, executor registry or any privacy control.
--   * PREPARES, DOES NOT ACTIVATE. A division is 'dormant' or 'staged'. The status 'active' is refused by a CHECK constraint, so nobody
--     (bot, owner, or this migration) can activate a division with this schema. Activation needs a later, separately approved migration
--     that also puts the envelope check inside the spend gateway (see the doc, section "Activation gate").
--   * ZERO MONEY. envelope_daily_cents is CHECK-constrained to 0. proposed_daily_cents is a non-binding owner note for the activation
--     review: only a staged division may hold one, and all proposals together may not exceed system_state.daily_spend_cap_cents.
--   * DEFAULT DENY. org_division_may() is true only for an ACTIVE division with a GRANTED row and the kill switch off. Neither state can
--     exist here ('granted' is refused by CHECK), so it answers false for everything. It is a necessary check, never a sufficient one.
--   * NO SELF-ESCALATION. Capabilities that would let a division change its own limits (grant., delegation., division., budget.,
--     permission., spend_cap., kill_switch., executor., payment., ...) are refused by CHECK whatever anyone inserts.
--   * OWNER ONLY. Every mutation is a function that requires is_app_owner(); the bot (service_role) has no auth.uid() and is refused, and
--     has no table write privilege. RLS on, no policy; anon/authenticated have nothing. No app_* wrapper is opened in this migration.
--   * NO FREE TEXT. Charters, objectives, KPIs and mission templates stay in ops/org/divisions.json (git, reviewed). The tables hold
--     constrained identifiers, states and integers only, so there is nothing for an agent to write personal data into.
create table if not exists public.org_divisions (
  id uuid primary key default gen_random_uuid(),
  slug text not null unique check (slug ~ '^[a-z][a-z0-9-]{1,39}$'),
  name text not null check (length(name) between 2 and 80),
  status text not null default 'dormant' check (status in ('dormant', 'staged')),
  proposed_daily_cents integer not null default 0 check (proposed_daily_cents >= 0),
  envelope_daily_cents integer not null default 0 check (envelope_daily_cents = 0),
  contract_version text not null check (contract_version ~ '^[0-9]+\.[0-9]+\.[0-9]+$'),
  staged_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint org_divisions_dormant_has_nothing check (status = 'staged' or (proposed_daily_cents = 0 and staged_at is null))
);
create table if not exists public.org_division_grants (
  id uuid primary key default gen_random_uuid(),
  division_slug text not null references public.org_divisions(slug) on delete restrict,
  capability text not null check (capability ~ '^[a-z_]+\.[a-z_]+$'
    and capability !~ '^(kill_switch|spend_cap|budget|grant|delegation|division|permission|executor|payment|bank|backup|deploy|migration|owner|privacy|consent|secret)\.'
    and capability not in ('outbox.send', 'agent.create', 'agent.activate')),
  scope text not null check (scope in ('own_division', 'own_workspaces')),
  status text not null default 'dormant' check (status in ('dormant', 'revoked')),
  created_at timestamptz not null default now(),
  unique (division_slug, capability)
);
do $$ declare t text; begin
  foreach t in array array['org_divisions', 'org_division_grants'] loop
    execute format('alter table public.%I enable row level security', t);
    execute format('revoke all on public.%I from public, anon, authenticated', t);
    execute format('grant select on public.%I to service_role', t);
    execute format('revoke insert, update, delete, truncate, trigger, references on public.%I from service_role', t);
  end loop;
end $$;

-- Runs for every writer, the table owner included. The slug is permanent; all proposals together stay inside the company AI cap.
-- If the cap cannot be read, a non-zero proposal is refused (fail closed).
create or replace function public.org_divisions_guard() returns trigger
language plpgsql set search_path to 'pg_catalog', 'public' as $$
declare v_cap integer; v_others bigint;
begin
  if tg_op = 'UPDATE' and new.slug is distinct from old.slug then raise exception 'org: a division slug cannot change'; end if;
  if new.proposed_daily_cents > 0 then
    perform pg_advisory_xact_lock(7341);
    select s.daily_spend_cap_cents into v_cap from public.system_state s where s.id = 1;
    if v_cap is null then raise exception 'org: company spend cap unreadable, proposal refused'; end if;
    select coalesce(sum(d.proposed_daily_cents), 0) into v_others from public.org_divisions d where d.slug <> new.slug;
    if v_others + new.proposed_daily_cents > v_cap then
      raise exception 'org: proposed envelopes (% cents) would exceed the company daily AI cap (% cents)', v_others + new.proposed_daily_cents, v_cap;
    end if;
  end if;
  new.updated_at := clock_timestamp();
  return new;
end $$;
drop trigger if exists org_divisions_guard on public.org_divisions;
create trigger org_divisions_guard before insert or update on public.org_divisions for each row execute function public.org_divisions_guard();

-- Default deny. True only when: kill switch readable and off, the division is active, and the capability is granted to it.
create or replace function public.org_division_may(p_division text, p_capability text) returns boolean
language sql stable security definer set search_path to 'pg_catalog', 'public' as $$
  select coalesce((select s.kill_switch is false from public.system_state s where s.id = 1), false)
     and exists (select 1 from public.org_divisions d join public.org_division_grants g on g.division_slug = d.slug
                  where d.slug = p_division and g.capability = p_capability and d.status = 'active' and g.status = 'granted')
$$;

-- Pre-check for spend, necessary and never sufficient: real spend is decided by the existing gateway (reserve_llm_budget / reserve_spend).
create or replace function public.org_division_spend_allowed(p_division text, p_cents integer) returns boolean
language sql stable security definer set search_path to 'pg_catalog', 'public' as $$
  select coalesce(p_cents > 0, false) and public.org_division_may(p_division, 'llm.spend')
     and exists (select 1 from public.org_divisions d where d.slug = p_division and d.status = 'active' and p_cents <= d.envelope_daily_cents)
$$;

-- Owner only. dormant -> staged: "I have read the charter and the allow-list; this division may be put forward for activation".
-- Grants nothing and enables nothing. Refused while the kill switch is on or unreadable.
create or replace function public.org_stage_division(p_slug text) returns void
language plpgsql security definer set search_path to 'pg_catalog', 'public' as $$
begin
  if not coalesce(public.is_app_owner(), false) then raise exception 'owner approval required: this action is refused for the bot'; end if;
  if (select s.kill_switch from public.system_state s where s.id = 1) is distinct from false then raise exception 'org: kill switch is on or unreadable'; end if;
  update public.org_divisions set status = 'staged', staged_at = clock_timestamp() where slug = p_slug and status = 'dormant';
  if not found then raise exception 'org: unknown division or not dormant'; end if;
  insert into public.audit_log (actor, action, target, detail) values ('owner', 'org_division_staged', 'org_divisions/' || p_slug, '{}'::jsonb);
end $$;

-- Owner only. Back to dormant; clears the proposal. Allowed while the kill switch is on (it only removes).
create or replace function public.org_unstage_division(p_slug text) returns void
language plpgsql security definer set search_path to 'pg_catalog', 'public' as $$
begin
  if not coalesce(public.is_app_owner(), false) then raise exception 'owner approval required: this action is refused for the bot'; end if;
  update public.org_divisions set status = 'dormant', proposed_daily_cents = 0, staged_at = null where slug = p_slug and status = 'staged';
  if not found then raise exception 'org: unknown division or not staged'; end if;
  insert into public.audit_log (actor, action, target, detail) values ('owner', 'org_division_unstaged', 'org_divisions/' || p_slug, '{}'::jsonb);
end $$;

-- Owner only. A non-binding number for the activation review. Spends nothing: envelope_daily_cents stays 0.
create or replace function public.org_propose_envelope(p_slug text, p_cents integer) returns void
language plpgsql security definer set search_path to 'pg_catalog', 'public' as $$
begin
  if not coalesce(public.is_app_owner(), false) then raise exception 'owner approval required: this action is refused for the bot'; end if;
  if (select s.kill_switch from public.system_state s where s.id = 1) is distinct from false then raise exception 'org: kill switch is on or unreadable'; end if;
  if p_cents is null or p_cents < 0 then raise exception 'org: proposal must be zero or more cents'; end if;
  update public.org_divisions set proposed_daily_cents = p_cents where slug = p_slug and status = 'staged';
  if not found then raise exception 'org: unknown division or not staged'; end if;
  insert into public.audit_log (actor, action, target, detail) values ('owner', 'org_envelope_proposed', 'org_divisions/' || p_slug, jsonb_build_object('cents', p_cents));
end $$;

-- Seed: every division dormant, zero money, allow-list rows dormant. Generated from ops/org/divisions.json.
-- BEGIN GENERATED SEED (scripts/org_contract.py --emit-seed; do not edit by hand)
insert into public.org_divisions (slug, name, contract_version) values
  ('day-job-sales', 'Day-job Sales', '1.0.0'),
  ('donna', 'Donna System', '1.0.0'),
  ('ffm', 'FF Marketing', '1.0.0'),
  ('idea-lab', 'Idea Lab / New Ventures', '1.0.0'),
  ('music', 'Music', '1.0.0'),
  ('real-estate', 'Real Estate', '1.0.0'),
  ('research', 'Research & Intelligence', '1.0.0'),
  ('soccer', 'Soccer', '1.0.0')
on conflict (slug) do nothing;
insert into public.org_division_grants (division_slug, capability, scope) values
  ('day-job-sales', 'kpi.report', 'own_division'),
  ('day-job-sales', 'llm.spend', 'own_division'),
  ('day-job-sales', 'memory.read', 'own_division'),
  ('day-job-sales', 'memory.write', 'own_division'),
  ('day-job-sales', 'mission.propose', 'own_division'),
  ('day-job-sales', 'org.propose', 'own_division'),
  ('day-job-sales', 'task.create', 'own_division'),
  ('donna', 'kpi.report', 'own_division'),
  ('donna', 'llm.spend', 'own_division'),
  ('donna', 'memory.read', 'own_division'),
  ('donna', 'memory.write', 'own_division'),
  ('donna', 'mission.propose', 'own_division'),
  ('donna', 'org.propose', 'own_division'),
  ('donna', 'outbox.draft', 'own_division'),
  ('donna', 'research.fetch', 'own_division'),
  ('donna', 'task.create', 'own_division'),
  ('ffm', 'kpi.report', 'own_workspaces'),
  ('ffm', 'llm.spend', 'own_workspaces'),
  ('ffm', 'memory.read', 'own_workspaces'),
  ('ffm', 'memory.write', 'own_workspaces'),
  ('ffm', 'mission.propose', 'own_workspaces'),
  ('ffm', 'org.propose', 'own_workspaces'),
  ('ffm', 'task.create', 'own_workspaces'),
  ('ffm', 'workspace.read', 'own_workspaces'),
  ('idea-lab', 'kpi.report', 'own_division'),
  ('idea-lab', 'llm.spend', 'own_division'),
  ('idea-lab', 'memory.read', 'own_division'),
  ('idea-lab', 'memory.write', 'own_division'),
  ('idea-lab', 'mission.propose', 'own_division'),
  ('idea-lab', 'org.propose', 'own_division'),
  ('idea-lab', 'research.fetch', 'own_division'),
  ('idea-lab', 'task.create', 'own_division'),
  ('music', 'org.propose', 'own_division'),
  ('real-estate', 'kpi.report', 'own_division'),
  ('real-estate', 'llm.spend', 'own_division'),
  ('real-estate', 'memory.read', 'own_division'),
  ('real-estate', 'memory.write', 'own_division'),
  ('real-estate', 'mission.propose', 'own_division'),
  ('real-estate', 'org.propose', 'own_division'),
  ('real-estate', 'research.fetch', 'own_division'),
  ('real-estate', 'task.create', 'own_division'),
  ('research', 'kpi.report', 'own_division'),
  ('research', 'llm.spend', 'own_division'),
  ('research', 'memory.read', 'own_division'),
  ('research', 'memory.write', 'own_division'),
  ('research', 'mission.propose', 'own_division'),
  ('research', 'org.propose', 'own_division'),
  ('research', 'research.fetch', 'own_division'),
  ('research', 'task.create', 'own_division'),
  ('soccer', 'org.propose', 'own_division')
on conflict (division_slug, capability) do nothing;
-- END GENERATED SEED

-- Data classification (DATA_CLASSIFICATION_AND_BACKUP_POLICY.md): same function, same signature, the reviewed list plus the 2 new tables.
create or replace function public.backup_classification() returns table (table_name text, data_class text, note text)
language sql immutable set search_path to 'pg_catalog', 'public' as $$
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
    -- 20261123_org_divisions_v1: organization layer. Operator-seeded identifiers, states and numbers only; no free text written by agents, no personal data
    ('org_divisions', 'internal', 'division register: slug, operator-authored name, lifecycle state, proposed envelope'),
    ('org_division_grants', 'internal', 'dormant delegated-permission rows: constrained identifiers only')
  ) v (table_name, data_class, note)
$$;

revoke all on function public.org_divisions_guard() from public, anon, authenticated;
revoke all on function public.org_division_may(text, text) from public, anon, authenticated;
revoke all on function public.org_division_spend_allowed(text, integer) from public, anon, authenticated;
revoke all on function public.org_stage_division(text) from public, anon, authenticated;
revoke all on function public.org_unstage_division(text) from public, anon, authenticated;
revoke all on function public.org_propose_envelope(text, integer) from public, anon, authenticated;
revoke all on function public.backup_classification() from public, anon, authenticated;
grant execute on function public.org_divisions_guard() to service_role;
grant execute on function public.org_division_may(text, text) to service_role;
grant execute on function public.org_division_spend_allowed(text, integer) to service_role;
grant execute on function public.org_stage_division(text) to service_role;
grant execute on function public.org_unstage_division(text) to service_role;
grant execute on function public.org_propose_envelope(text, integer) to service_role;
grant execute on function public.backup_classification() to service_role;
