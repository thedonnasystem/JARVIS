-- FF Marketing EXECUTION v1 (builds on 20261117_client_workspaces_v1, 20261118_ffm_onboarding_v1, 20261121_*consent*, 20261124_jarvis_hands_v1, 20261125_ffm_engine_v1).
-- Additive: 8 tables, 1 connector row (meta-ads, DISABLED), 28 functions, company_profile rows 'ffm-<slug>' (client sender identity), and ONE tightening of an existing grant (owner_messages, below). Changes no existing
-- function, control, cap, mode or kill switch.
--   * ONE owner approval per launch: ffm_run_propose writes the launch (the exact plan, screened, sha256) and its FIRST budget row and asks the owner on Telegram.
--     The approval is recorded ONLY by ffm_run_owner_decide (service_role only): it checks the message id, kind, sender and reference and consumes a single-use
--     nonce stored with the budget row (no API role can read it). A trigger refuses any approved budget that did not come through it. owner_messages.decision
--     alone is never trusted. Proposals need a workspace monthly budget, a client sender profile, a total cap of at least $100 and cover at most 30 days.
--   * owner_messages: anon / authenticated lose every table privilege (the PWA reads and decides only through SECURITY DEFINER app_* functions; the bot uses
--     the service key). This closes the forged-decision path for every module, not only this one.
--   * ffm_run_budgets is the per-launch APPROVED-BUDGET table: amounts immutable (trigger); a change is a new row + a new tap; a new total must stay above spend.
--   * Money is enforced HERE: ad-set budget sums never above the approved daily budget or the remaining cap; spend at the cap -> 'capped'. The Meta campaign
--     also carries a spend cap equal to the approved total. Live spend also goes through the unchanged ws_record_spend.
--   * ffm_run_gate before every step: kill switch, launch status and dates, approved budget; LIVE only for a launch approved in a live mode, with the connector
--     on and an account connected (paid steps: workspace active, hands executor on). Otherwise SIMULATED, receipts say DRY RUN.
--   * Posts and the landing page reuse the hands path, only for the exact approved text / page hash (ffm_run_submit_hand -> unchanged hands_release).
--   * Leads: consent fields required; unchanged ws_add_lead (ws_guard) and ffm_record_consent. Follow-ups are queued in ffm_run_emails with the CLIENT's own
--     sender profile and CASL footer (unsubscribe link) and sent by the FF Marketing sender after ffm_run_claim_email re-checks everything at send time
--     (kill switch, live mode, consent, withdrawal, suppression, outreach gate). The legacy outbox / Donna path is not used. Opt-out -> ffm_withdraw_consent.
--   * RLS on, no policy; anon/authenticated get nothing; service_role may select only; writes only through the functions. ffm_* tables are excluded from backups.
-- Rollback: ops/rollback_ffm_run.sql.

-- ---------------------------------------------------------------------------------------------------------------------------- tables
create table if not exists public.ffm_run_launches (
  id uuid primary key default gen_random_uuid(),
  workspace_id uuid not null references public.client_workspaces(id) on delete restrict,
  campaign_id uuid,
  pack_id uuid,                     -- the pack the plan was built from (no foreign key: the engine tables roll back on their own; the plan is a full snapshot)
  plan jsonb not null check (jsonb_typeof(plan) = 'object' and octet_length(plan::text) <= 60000),
  plan_sha256 text not null check (plan_sha256 ~ '^[0-9a-f]{64}$'),
  paid_platforms text[] not null default '{}' check (paid_platforms <@ array['meta']::text[]),
  organic_platforms text[] not null default '{}' check (organic_platforms <@ array['instagram', 'facebook', 'tiktok', 'linkedin', 'youtube', 'x']::text[]),
  starts_on date not null,
  ends_on date not null,
  status text not null default 'proposed' check (status in ('proposed', 'approved', 'running', 'capped', 'done', 'rejected', 'superseded')),
  dry_run boolean,                  -- set at approval: true when approved in dry-run mode; a dry-run launch never goes live (launch again after going live)
  landing_url text check (landing_url is null or (landing_url ~ '^https://[^\s]{4,}$' and length(landing_url) <= 300)),
  created_by text not null check (length(created_by) between 2 and 60),
  created_at timestamptz not null default now(),
  approved_at timestamptz,
  updated_at timestamptz not null default now(),
  check (ends_on >= starts_on and ends_on <= starts_on + 366),
  foreign key (workspace_id, campaign_id) references public.ws_campaigns (workspace_id, id)
);
create index if not exists ffm_run_launches_ws_idx on public.ffm_run_launches (workspace_id, status);

create table if not exists public.ffm_run_budgets (
  id uuid primary key default gen_random_uuid(),
  launch_id uuid not null references public.ffm_run_launches(id) on delete restrict,
  seq integer not null check (seq >= 1),
  daily_cents integer not null check (daily_cents between 100 and 1000000),
  total_cap_cents integer not null check (total_cap_cents between 100 and 10000000),
  status text not null default 'proposed' check (status in ('proposed', 'approved', 'rejected', 'superseded')),
  owner_message_id uuid,
  approval_nonce text not null default (replace(gen_random_uuid()::text, '-', '') || replace(gen_random_uuid()::text, '-', '')) check (approval_nonce ~ '^[0-9a-f]{64}$'),
  nonce_used_at timestamptz,
  decided_via text check (decided_via is null or decided_via ~ '^telegram:[0-9a-f-]{36}$'),
  requested_by text not null check (length(requested_by) between 2 and 60),
  created_at timestamptz not null default now(),
  decided_at timestamptz,
  decided_by text,
  unique (launch_id, seq),
  check (daily_cents <= total_cap_cents)
);

create table if not exists public.ffm_run_objects (
  id uuid primary key default gen_random_uuid(),
  launch_id uuid not null references public.ffm_run_launches(id) on delete restrict,
  level text not null check (level in ('campaign', 'ad_set', 'ad')),
  plan_ref text not null check (plan_ref ~ '^[A-Za-z0-9_.:-]{1,60}$'),
  parent_id uuid references public.ffm_run_objects(id) on delete restrict,
  external_id text check (external_id is null or external_id ~ '^[A-Za-z0-9:_.-]{1,120}$'),
  status text not null check (status in ('paused', 'active', 'stopped')),
  daily_cents integer check (daily_cents is null or daily_cents >= 0),
  simulated boolean not null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (launch_id, level, plan_ref)
);

create table if not exists public.ffm_run_metrics (
  object_id uuid not null references public.ffm_run_objects(id) on delete restrict,
  launch_id uuid not null references public.ffm_run_launches(id) on delete restrict,
  day date not null,
  spend_cents integer not null default 0 check (spend_cents >= 0),
  impressions integer not null default 0 check (impressions >= 0),
  clicks integer not null default 0 check (clicks >= 0),
  leads integer not null default 0 check (leads >= 0),
  simulated boolean not null,
  updated_at timestamptz not null default now(),
  primary key (object_id, day)
);
create index if not exists ffm_run_metrics_launch_idx on public.ffm_run_metrics (launch_id, day);

create table if not exists public.ffm_run_receipts (
  id bigint generated always as identity primary key,
  launch_id uuid not null references public.ffm_run_launches(id) on delete restrict,
  step text not null check (step ~ '^[a-z_]{2,30}$'),
  item text not null check (item ~ '^[A-Za-z0-9_.:-]{1,80}$'),
  simulated boolean not null,
  ok boolean not null,
  external_ref text check (external_ref is null or external_ref ~ '^[A-Za-z0-9:._/-]{1,200}$'),
  detail text check (detail is null or length(detail) <= 300),
  created_at timestamptz not null default now()
);
create unique index if not exists ffm_run_receipts_once_idx on public.ffm_run_receipts (launch_id, step, item) where ok;
create index if not exists ffm_run_receipts_launch_idx on public.ffm_run_receipts (launch_id, created_at);

create table if not exists public.ffm_run_leads (
  lead_id uuid primary key references public.ws_leads(id) on delete restrict,
  workspace_id uuid not null references public.client_workspaces(id) on delete restrict,
  launch_id uuid not null references public.ffm_run_launches(id) on delete restrict,
  source text not null check (source in ('meta_form', 'landing', 'manual')),
  source_ref text not null check (source_ref ~ '^[A-Za-z0-9][A-Za-z0-9._-]{2,99}$'),
  status text not null default 'active' check (status in ('active', 'replied', 'booked', 'opted_out', 'done', 'needs_consent', 'lost')),
  next_touch integer not null default 1 check (next_touch between 1 and 6),
  next_due_at timestamptz,
  first_response_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (launch_id, source_ref)
);
create index if not exists ffm_run_leads_due_idx on public.ffm_run_leads (status, next_due_at);

create table if not exists public.ffm_run_touches (
  lead_id uuid not null references public.ffm_run_leads(lead_id) on delete restrict,
  touch integer not null check (touch between 1 and 5),
  status text not null check (status in ('queued', 'simulated', 'skipped')),
  email_id uuid,
  reason text check (reason is null or reason ~ '^[a-z_]{2,40}$'),
  created_at timestamptz not null default now(),
  primary key (lead_id, touch)
);

create table if not exists public.ffm_run_emails (
  id uuid primary key default gen_random_uuid(),
  lead_id uuid not null references public.ffm_run_leads(lead_id) on delete restrict,
  launch_id uuid not null references public.ffm_run_launches(id) on delete restrict,
  touch integer not null check (touch between 1 and 5),
  subject text not null check (length(subject) <= 200),
  body text not null check (length(body) <= 4000),
  status text not null default 'queued' check (status in ('queued', 'sending', 'sent', 'withdrawn', 'failed')),
  attempts integer not null default 0,
  provider_ref text check (provider_ref is null or provider_ref ~ '^[A-Za-z0-9:._-]{1,120}$'),
  reason text check (reason is null or length(reason) <= 120),
  created_at timestamptz not null default now(),
  claimed_at timestamptz,
  sent_at timestamptz,
  unique (lead_id, touch)
);
create index if not exists ffm_run_emails_status_idx on public.ffm_run_emails (status, created_at);

do $$ declare t text; begin
  foreach t in array array['ffm_run_launches', 'ffm_run_budgets', 'ffm_run_objects', 'ffm_run_metrics', 'ffm_run_receipts', 'ffm_run_leads', 'ffm_run_touches', 'ffm_run_emails'] loop
    execute format('alter table public.%I enable row level security', t);
    execute format('revoke all on public.%I from public, anon, authenticated', t);
    execute format('grant select on public.%I to service_role', t);
    execute format('revoke insert, update, delete, truncate, trigger, references on public.%I from service_role', t);
  end loop;
end $$;
revoke all on sequence public.ffm_run_receipts_id_seq from public, anon, authenticated, service_role;
-- B1 tightening: nothing outside the service key may write (or read) owner messages; app_* (SECURITY DEFINER) are how the PWA reads and decides
revoke all on public.owner_messages from anon, authenticated;

-- receipts are append-only (own trigger function, so the consent-integrity rollback can still drop ffm_append_only)
create or replace function public.ffm_run_append_only() returns trigger
language plpgsql set search_path to 'public' as $$
begin
  raise exception 'ffm_run_receipts is append-only' using errcode = '42501';
end $$;
revoke all on function public.ffm_run_append_only() from public, anon, authenticated;
drop trigger if exists ffm_run_receipts_append_only on public.ffm_run_receipts;
create trigger ffm_run_receipts_append_only before update or delete on public.ffm_run_receipts for each row execute function public.ffm_run_append_only();
drop trigger if exists ffm_run_receipts_no_truncate on public.ffm_run_receipts;
create trigger ffm_run_receipts_no_truncate before truncate on public.ffm_run_receipts for each statement execute function public.ffm_run_append_only();

-- an approved amount never changes: a different amount is a new row and a new owner tap
create or replace function public.ffm_run_budget_fixed() returns trigger
language plpgsql set search_path to 'public' as $$
begin
  if tg_op = 'DELETE' then raise exception 'ffm_run_budgets rows are never deleted' using errcode = '42501'; end if;
  if new.launch_id <> old.launch_id or new.seq <> old.seq or new.daily_cents <> old.daily_cents or new.total_cap_cents <> old.total_cap_cents
     or new.requested_by <> old.requested_by or new.created_at <> old.created_at or new.approval_nonce <> old.approval_nonce
     or (old.owner_message_id is not null and new.owner_message_id is distinct from old.owner_message_id)
     or (old.nonce_used_at is not null and new.nonce_used_at is distinct from old.nonce_used_at) then
    raise exception 'an approved budget is immutable: request a new one (a new owner approval)' using errcode = '42501';
  end if;
  if not ((old.status = new.status) or (old.status = 'proposed' and new.status in ('approved', 'rejected', 'superseded')) or (old.status = 'approved' and new.status = 'superseded')) then
    raise exception 'budget status % -> % is not allowed', old.status, new.status using errcode = '42501';
  end if;
  if new.status = 'approved' and old.status = 'proposed' and (new.nonce_used_at is null or new.decided_via is null) then
    raise exception 'a budget is approved only through ffm_run_owner_decide (single-use nonce)' using errcode = '42501';
  end if;
  return new;
end $$;
revoke all on function public.ffm_run_budget_fixed() from public, anon, authenticated;
drop trigger if exists ffm_run_budget_fixed on public.ffm_run_budgets;
create trigger ffm_run_budget_fixed before update or delete on public.ffm_run_budgets for each row execute function public.ffm_run_budget_fixed();

-- the Meta Marketing API connection (ad account), connected by the owner through the official OAuth; DISABLED; no hand action can use it
insert into public.hand_connectors (slug, title, auth, actions, signup_mode, max_actions_per_day, cost_cents_per_action, ai_label, signup_url, terms) values
  ('meta-ads', 'Meta ad account (Marketing API)', 'oauth2', '{}', 'assisted', 0, 0, 'none', 'https://business.facebook.com/',
   'The Chairman (or the client) owns the ad account and pays Meta; Jarvis manages only campaigns of an owner-approved launch, inside its approved budget')
on conflict (slug) do nothing;

-- ---------------------------------------------------------------------------------------------------------------------------- internal helpers
create or replace function public.ffm_run_live_mode() returns boolean
language sql stable security definer set search_path to 'public' as $$
  select coalesce((select not kill_switch and mode in ('approve_first', 'auto_in_caps', 'exceptions_only') from public.system_state where id = 1), false)
$$;
revoke all on function public.ffm_run_live_mode() from public, anon, authenticated;
grant execute on function public.ffm_run_live_mode() to service_role;

-- the current approved budget of a launch and the spend recorded against it (null when nothing is approved)
create or replace function public.ffm_run_budget(p_launch uuid) returns jsonb
language sql stable security definer set search_path to 'public' as $$
  select case when b.id is null then null else jsonb_build_object('budget_id', b.id, 'seq', b.seq, 'daily_cents', b.daily_cents, 'total_cap_cents', b.total_cap_cents,
    'spent_cents', s.spent, 'remaining_cents', greatest(b.total_cap_cents - s.spent, 0), 'approved_at', b.decided_at) end
  from (select 1) one
  left join lateral (select * from public.ffm_run_budgets where launch_id = p_launch and status = 'approved' order by seq desc limit 1) b on true
  cross join lateral (select coalesce(sum(spend_cents), 0)::integer as spent from public.ffm_run_metrics where launch_id = p_launch) s
$$;
revoke all on function public.ffm_run_budget(uuid) from public, anon, authenticated;
grant execute on function public.ffm_run_budget(uuid) to service_role;

create or replace function public.ffm_run_money(p_cents integer) returns text
language sql immutable set search_path to 'public' as $$ select '$' || to_char(coalesce(p_cents, 0) / 100.0, 'FM9999999990.00') $$;
revoke all on function public.ffm_run_money(integer) from public, anon, authenticated;
grant execute on function public.ffm_run_money(integer) to service_role;

create or replace function public.ffm_run_ask_owner(p_budget uuid, p_text text) returns uuid
language plpgsql security definer set search_path to 'public' as $$
declare v_id uuid;
begin
  insert into public.owner_messages (from_agent, kind, channel, body, needs_decision, ref_table, ref_id)
  values ('jarvis', 'proposal', 'telegram', left(p_text, 3900), true, 'ffm_run_budgets', p_budget) returning id into v_id;
  update public.ffm_run_budgets set owner_message_id = v_id where id = p_budget;
  return v_id;
end $$;
revoke all on function public.ffm_run_ask_owner(uuid, text) from public, anon, authenticated, service_role;

-- the budget sum rule (raises): ad sets that are not stopped may not together exceed the approved daily budget, and no single day may exceed what is left of the cap
create or replace function public.ffm_run_check_budget(p_launch uuid) returns void
language plpgsql stable security definer set search_path to 'public' as $$
declare b jsonb; v_sum integer;
begin
  b := public.ffm_run_budget(p_launch);
  if b is null then raise exception 'budget refused: this launch has no owner-approved budget' using errcode = '42501'; end if;
  select coalesce(sum(daily_cents), 0) into v_sum from public.ffm_run_objects where launch_id = p_launch and level = 'ad_set' and status <> 'stopped';
  if v_sum > (b ->> 'daily_cents')::int then
    raise exception 'budget refused: ad-set budgets % would exceed the approved daily budget %', v_sum, (b ->> 'daily_cents')::int using errcode = '42501';
  end if;
  if v_sum > (b ->> 'remaining_cents')::int then
    raise exception 'budget refused: ad-set budgets % would exceed what is left of the approved total cap (%)', v_sum, (b ->> 'remaining_cents')::int using errcode = '42501';
  end if;
end $$;
revoke all on function public.ffm_run_check_budget(uuid) from public, anon, authenticated;
grant execute on function public.ffm_run_check_budget(uuid) to service_role;

-- ---------------------------------------------------------------------------------------------------------------------------- the one owner approval
create or replace function public.ffm_run_propose(p_ws uuid, p_pack uuid, p_daily integer, p_total integer, p_starts date, p_ends date, p_paid text[], p_organic text[],
                                                  p_plan jsonb, p_by text) returns jsonb
language plpgsql security definer set search_path to 'public' as $$
declare w public.client_workspaces; pk public.ffm_engine_packs; r record; v_id uuid; v_b uuid; v_msg uuid; v_sha text; n_ads int; n_sets int; n_posts int; n_touch int;
        v_body text; free_keys constant text[] := array['headline', 'body', 'text', 'subject', 'geo'];
begin
  perform public.ffm_open_ws(p_ws);
  select * into w from public.client_workspaces where id = p_ws for update;       -- one proposal at a time per workspace
  if p_by is null or length(btrim(p_by)) < 2 then raise exception 'say who proposed this launch'; end if;
  if w.monthly_budget_cents is null then raise exception 'launch refused: set the workspace monthly budget first (owner-only)'; end if;
  if public.ffm_run_sender(p_ws) is null then raise exception 'launch refused: no sender profile for this client (/ffm sender)'; end if;
  select * into pk from public.ffm_engine_packs where id = p_pack and workspace_id = p_ws and status = 'draft';
  if pk.id is null then raise exception 'launch refused: no current draft pack for this workspace (/ffm pack first)'; end if;
  if p_daily is null or p_total is null or p_daily < 100 or p_total < p_daily then raise exception 'launch refused: daily budget must be at least $1.00 and not above the total cap'; end if;
  if p_total < 10000 then raise exception 'launch refused: the total cap must be at least $100.00 (Meta minimum)'; end if;
  if p_starts is null or p_ends is null or p_ends < p_starts or p_ends > p_starts + 29 or p_starts < (now() at time zone 'America/Toronto')::date then
    raise exception 'launch refused: dates must start today or later and one approval covers at most 30 days';
  end if;
  if p_total > w.monthly_budget_cents then raise exception 'launch refused: the total cap is above the monthly budget you set for this workspace'; end if;
  if exists (select 1 from public.ffm_run_launches where workspace_id = p_ws and status in ('approved', 'running', 'capped')) then
    raise exception 'launch refused: this workspace already has a launch in progress (/ffm stop it first)';
  end if;
  if p_plan is null or jsonb_typeof(p_plan) <> 'object' or exists (select 1 from jsonb_object_keys(p_plan) as t(k) where t.k not in ('ads', 'posts', 'touches', 'landing', 'landing_sha256', 'geo', 'vertical', 'consent_version')) then
    raise exception 'launch refused: unknown plan shape';
  end if;
  for r in select * from public.ffm_engine_leaves(p_plan) loop
    if r.k = any (free_keys) then
      perform public.ffm_engine_screen(p_ws, r.v, 'plan.' || r.k);
    else
      if r.v !~ '^[A-Za-z0-9_.:+\[\]-]{0,80}$' then raise exception 'plan field % must be a short code, not free text', left(coalesce(r.k, '?'), 40); end if;
      if r.k <> 'landing_sha256' then perform public.ffm_engine_screen(null, r.v, 'plan.' || coalesce(r.k, '?')); end if;
    end if;
  end loop;
  n_ads := coalesce(jsonb_array_length(p_plan -> 'ads'), 0);
  n_sets := (select count(distinct x.v ->> 'set') from jsonb_array_elements(coalesce(p_plan -> 'ads', '[]')) as x(v));
  n_posts := coalesce(jsonb_array_length(p_plan -> 'posts'), 0);
  n_touch := coalesce(jsonb_array_length(p_plan -> 'touches'), 0);
  if 'meta' = any (coalesce(p_paid, '{}')) and n_ads = 0 then raise exception 'launch refused: paid ads asked but the plan has no ad'; end if;
  if n_touch > 5 then raise exception 'launch refused: at most 5 follow-up touches'; end if;
  v_sha := encode(sha256(convert_to(p_plan::text, 'UTF8')), 'hex');
  for v_id in select id from public.ffm_run_launches where workspace_id = p_ws and status = 'proposed' for update loop
    update public.ffm_run_budgets set status = 'superseded' where launch_id = v_id and status = 'proposed';
  end loop;
  update public.ffm_run_launches set status = 'superseded', updated_at = now() where workspace_id = p_ws and status = 'proposed';
  insert into public.ffm_run_launches (workspace_id, campaign_id, pack_id, plan, plan_sha256, paid_platforms, organic_platforms, starts_on, ends_on, created_by)
  values (p_ws, pk.campaign_id, pk.id, p_plan, v_sha, coalesce(p_paid, '{}'), coalesce(p_organic, '{}'), p_starts, p_ends, left(p_by, 60)) returning id into v_id;
  insert into public.ffm_run_budgets (launch_id, seq, daily_cents, total_cap_cents, requested_by) values (v_id, 1, p_daily, p_total, left(p_by, 60)) returning id into v_b;
  -- the numbers in the message come from the database, not from the caller
  v_body := 'Sir, launch approval for ' || w.name || ' (' || w.slug || '):' || chr(10)
    || 'Paid ads: ' || case when 'meta' = any (coalesce(p_paid, '{}')) then 'Meta (Facebook + Instagram), ' || n_ads || ' ads in ' || n_sets || ' ad sets, created paused, then switched on' else 'none' end || chr(10)
    || 'Daily budget: ' || public.ffm_run_money(p_daily) || ' on average (Meta may spend up to about 75% more on a single day). Total cap: ' || public.ffm_run_money(p_total)
    || ' = the hard stop (the Meta campaign spend cap is set to the same).' || chr(10)
    || 'Dates: ' || p_starts || ' to ' || p_ends || '.' || chr(10)
    || 'Organic posts: ' || n_posts || case when n_posts > 0 then ' on ' || array_to_string(coalesce(p_organic, '{}'), ', ') else '' end || '.' || chr(10)
    || 'Landing page: ' || case when coalesce((p_plan ->> 'landing')::boolean, false) then 'deployed to your connected Netlify site' else 'not deployed (consent wording missing)' end || '.' || chr(10)
    || 'Leads: up to ' || n_touch || ' emails over 10 days from the client''s own sender profile, sent automatically and only to people with verified consent '
    || '(the first within about 5 minutes when live); stops on reply, booking or opt-out. Every email carries the client''s CASL footer and an unsubscribe link.' || chr(10)
    || 'Everything that will run (every ad, post and email): /ffm plan ' || left(v_id::text, 8) || ' (plan ' || left(v_sha, 12) || ').' || chr(10)
    || 'Approve = I run it alone inside these numbers (daily optimizing, weekly report to you). Anything above the cap comes back to you.'
    || case when public.ffm_run_live_mode() then '' else chr(10) || 'The system is in dry-run mode, so this launch runs as DRY RUN (simulated receipts) to its end. After you connect the accounts and switch the mode, launch again to run it live.' end;
  v_msg := public.ffm_run_ask_owner(v_b, v_body);
  insert into public.audit_log (actor, action, target, detail) values (left(p_by, 60), 'ffm_run_proposed', 'workspace/' || p_ws,
    jsonb_build_object('launch', v_id, 'budget', v_b, 'daily_cents', p_daily, 'total_cap_cents', p_total, 'plan_sha256', v_sha));
  return jsonb_build_object('ok', true, 'launch_id', v_id, 'budget_id', v_b, 'message_id', v_msg, 'plan_sha256', v_sha);
end $$;
revoke all on function public.ffm_run_propose(uuid, uuid, integer, integer, date, date, text[], text[], jsonb, text) from public, anon, authenticated;
grant execute on function public.ffm_run_propose(uuid, uuid, integer, integer, date, date, text[], text[], jsonb, text) to service_role;

-- a bigger budget for a running / capped launch: a NEW budget row and a NEW owner tap; nothing changes until he taps Approve
create or replace function public.ffm_run_request_budget(p_launch uuid, p_daily integer, p_total integer, p_by text) returns jsonb
language plpgsql security definer set search_path to 'public' as $$
declare l public.ffm_run_launches; w public.client_workspaces; b jsonb; v_b uuid; v_seq int;
begin
  select * into l from public.ffm_run_launches where id = p_launch for update;
  if l.id is null or l.status not in ('approved', 'running', 'capped') then raise exception 'budget request refused: the launch is not in progress'; end if;
  if p_by is null or length(btrim(p_by)) < 2 then raise exception 'say who asked'; end if;
  if p_daily is null or p_total is null or p_daily < 100 or p_total < p_daily or p_total < 10000 then
    raise exception 'budget request refused: daily budget at least $1.00, not above the total cap, and a total cap of at least $100.00';
  end if;
  select * into w from public.client_workspaces where id = l.workspace_id;
  if w.monthly_budget_cents is null or p_total > w.monthly_budget_cents then raise exception 'budget request refused: above the monthly budget you set for this workspace'; end if;
  b := public.ffm_run_budget(p_launch);
  if p_total <= (b ->> 'spent_cents')::int then raise exception 'budget request refused: the total cap must be above what is already spent (%)', public.ffm_run_money((b ->> 'spent_cents')::int); end if;
  update public.ffm_run_budgets set status = 'superseded' where launch_id = p_launch and status = 'proposed';
  select coalesce(max(seq), 0) + 1 into v_seq from public.ffm_run_budgets where launch_id = p_launch;
  insert into public.ffm_run_budgets (launch_id, seq, daily_cents, total_cap_cents, requested_by) values (p_launch, v_seq, p_daily, p_total, left(p_by, 60)) returning id into v_b;
  perform public.ffm_run_ask_owner(v_b, 'Sir, budget change for the ' || w.name || ' launch: daily ' || public.ffm_run_money((b ->> 'daily_cents')::int) || ' -> ' || public.ffm_run_money(p_daily)
    || ' (an average; Meta may spend up to about 75% more on a single day), total cap ' || public.ffm_run_money((b ->> 'total_cap_cents')::int) || ' -> ' || public.ffm_run_money(p_total)
    || ' (the hard stop). Spent so far: ' || public.ffm_run_money((b ->> 'spent_cents')::int) || '. Approve? Nothing changes until you do.');
  insert into public.audit_log (actor, action, target, detail) values (left(p_by, 60), 'ffm_run_budget_requested', 'workspace/' || l.workspace_id,
    jsonb_build_object('launch', p_launch, 'budget', v_b, 'daily_cents', p_daily, 'total_cap_cents', p_total));
  return jsonb_build_object('ok', true, 'budget_id', v_b, 'seq', v_seq);
end $$;
revoke all on function public.ffm_run_request_budget(uuid, integer, integer, text) from public, anon, authenticated;
grant execute on function public.ffm_run_request_budget(uuid, integer, integer, text) to service_role;

-- THE approval path. Called only by the bot's owner-only decision handler (hq_commands.apply_decision -> hq_ffm_run.decide; the PWA's Approve goes through the same
-- handler via app_send). It checks the message (id, kind, sender, reference) and a single-use nonce stored with the proposal: service_role only (no API role can
-- call it or read the nonce). owner_messages.decision is never trusted on its own.
create or replace function public.ffm_run_owner_decide(p_message uuid, p_nonce text, p_approved boolean, p_by text) returns jsonb
language plpgsql security definer set search_path to 'public' as $$
declare m public.owner_messages; bd public.ffm_run_budgets; l public.ffm_run_launches; b jsonb; v_launch uuid;
begin
  if p_by is null or p_by !~ '^owner:' then raise exception 'ffm_run_owner_decide: only the owner decides' using errcode = '42501'; end if;
  select * into m from public.owner_messages where id = p_message;
  if m.id is null or m.kind <> 'proposal' or m.from_agent <> 'jarvis' or not m.needs_decision or m.ref_table <> 'ffm_run_budgets' or m.ref_id is null then
    raise exception 'ffm_run_owner_decide: not a launch approval message' using errcode = '42501';
  end if;
  select launch_id into v_launch from public.ffm_run_budgets where id = m.ref_id;
  select * into l from public.ffm_run_launches where id = v_launch for update;          -- the launch first
  select * into bd from public.ffm_run_budgets where id = m.ref_id for update;
  if bd.id is null or bd.owner_message_id is distinct from p_message then raise exception 'ffm_run_owner_decide: message and budget do not match' using errcode = '42501'; end if;
  if bd.nonce_used_at is not null or bd.status <> 'proposed' then return jsonb_build_object('ok', false, 'reason', 'already decided'); end if;
  if p_nonce is null or p_nonce <> bd.approval_nonce then raise exception 'ffm_run_owner_decide: wrong nonce' using errcode = '42501'; end if;
  if coalesce(p_approved, false) and l.status in ('proposed', 'approved', 'running', 'capped') then
    b := public.ffm_run_budget(l.id);
    if b is not null and bd.total_cap_cents <= (b ->> 'spent_cents')::int then
      update public.ffm_run_budgets set status = 'rejected', nonce_used_at = now(), decided_at = now(), decided_by = left(p_by, 60), decided_via = 'telegram:' || p_message where id = bd.id;
      return jsonb_build_object('ok', false, 'reason', 'the new total cap is not above what is already spent');
    end if;
    update public.ffm_run_budgets set status = 'superseded' where launch_id = l.id and status = 'approved';
    update public.ffm_run_budgets set status = 'approved', nonce_used_at = now(), decided_at = now(), decided_by = left(p_by, 60), decided_via = 'telegram:' || p_message where id = bd.id;
    if l.status = 'proposed' then
      update public.ffm_run_launches set status = 'approved', approved_at = now(), updated_at = now(), dry_run = not public.ffm_run_live_mode() where id = l.id;
    elsif l.status = 'capped' and (public.ffm_run_budget(l.id) ->> 'remaining_cents')::int >= 100 then
      update public.ffm_run_launches set status = 'running', updated_at = now() where id = l.id;
    end if;
    insert into public.audit_log (actor, action, target, detail) values (left(p_by, 60), 'ffm_run_budget_approved', 'workspace/' || l.workspace_id, jsonb_build_object('launch', l.id, 'budget', bd.id, 'message', p_message));
    return jsonb_build_object('ok', true, 'status', 'approved', 'seq', bd.seq, 'dry_run', (select dry_run from public.ffm_run_launches where id = l.id));
  end if;
  update public.ffm_run_budgets set status = 'rejected', nonce_used_at = now(), decided_at = now(), decided_by = left(p_by, 60), decided_via = 'telegram:' || p_message where id = bd.id;
  if l.status = 'proposed' then update public.ffm_run_launches set status = 'rejected', updated_at = now() where id = l.id; end if;
  insert into public.audit_log (actor, action, target, detail) values (left(p_by, 60), 'ffm_run_budget_rejected', 'workspace/' || l.workspace_id, jsonb_build_object('launch', l.id, 'budget', bd.id));
  return jsonb_build_object('ok', true, 'status', 'rejected');
end $$;
revoke all on function public.ffm_run_owner_decide(uuid, text, boolean, text) from public, anon, authenticated;
grant execute on function public.ffm_run_owner_decide(uuid, text, boolean, text) to service_role;

-- ---------------------------------------------------------------------------------------------------------------------------- the gate before every step
create or replace function public.ffm_run_gate(p_launch uuid, p_step text, p_connector text default null) returns jsonb
language plpgsql security definer set search_path to 'public' as $$
declare l public.ffm_run_launches; ss public.system_state; b jsonb; why text; c public.hand_connectors; acc public.hand_accounts; today date := (now() at time zone 'America/Toronto')::date;
begin
  if p_step is null or p_step not in ('launch', 'optimize', 'pause', 'post', 'deploy', 'leads', 'followup', 'report') then raise exception 'unknown step'; end if;
  select * into l from public.ffm_run_launches where id = p_launch;
  if l.id is null then return jsonb_build_object('ok', false, 'reason', 'unknown launch'); end if;
  select * into ss from public.system_state where id = 1;
  if coalesce(ss.kill_switch, true) then return jsonb_build_object('ok', false, 'kill', true, 'reason', 'kill switch is on'); end if;
  if l.status not in ('approved', 'running', 'capped', 'done') or (l.status in ('capped', 'done') and p_step not in ('optimize', 'pause', 'leads', 'followup', 'report')) then
    return jsonb_build_object('ok', false, 'reason', 'launch is ' || l.status);
  end if;
  b := public.ffm_run_budget(p_launch);
  if b is null then return jsonb_build_object('ok', false, 'reason', 'no owner-approved budget'); end if;
  if p_step in ('launch', 'post', 'deploy') and today < l.starts_on then return jsonb_build_object('ok', false, 'reason', 'starts on ' || l.starts_on); end if;
  if p_step in ('launch', 'post', 'deploy') and today > l.ends_on then return jsonb_build_object('ok', false, 'reason', 'ended on ' || l.ends_on); end if;
  if coalesce(l.dry_run, true) then why := 'dry-run launch (approved in dry-run mode: launch again after going live)';
  elsif ss.mode is null or ss.mode not in ('approve_first', 'auto_in_caps', 'exceptions_only') then why := 'mode is ' || coalesce(ss.mode, 'unknown');
  elsif p_connector is not null then
    select * into c from public.hand_connectors where slug = p_connector;
    if c.slug is null or not c.enabled then why := 'connector ' || p_connector || ' is off';
    else
      select * into acc from public.hand_accounts where connector = p_connector and division = 'ffm' and status = 'connected' order by updated_at desc limit 1;
      if acc.id is null then why := 'no connected ' || p_connector || ' account for ffm'; end if;
    end if;
  end if;
  if why is null and p_step in ('launch', 'optimize') then
    if (select status from public.client_workspaces where id = l.workspace_id) <> 'active' then why := 'workspace not active (owner activation)';
    elsif not coalesce((select enabled from public.executor_registry where slug = 'hands-actions'), false) then why := 'hands executor is off';
    end if;
  end if;
  if why is null and p_step = 'followup' and public.ffm_run_sender(l.workspace_id) is null then why := 'no sender profile'; end if;
  return jsonb_build_object('ok', true, 'live', why is null, 'why_simulated', why, 'budget', b, 'status', l.status, 'dry_run', coalesce(l.dry_run, true), 'starts_on', l.starts_on, 'ends_on', l.ends_on,
    'account', case when acc.id is null then null else jsonb_build_object('id', acc.id, 'external_id', acc.external_id, 'token_vault_ref', acc.token_vault_ref, 'handle', acc.handle) end);
end $$;
revoke all on function public.ffm_run_gate(uuid, text, text) from public, anon, authenticated;
grant execute on function public.ffm_run_gate(uuid, text, text) to service_role;

-- a tasks row for one live platform write (closed by ffm_run_receipt with the same id)
create or replace function public.ffm_run_task(p_launch uuid, p_step text) returns uuid
language plpgsql security definer set search_path to 'public' as $$
declare v uuid;
begin
  if p_step !~ '^[a-z_]{2,30}$' or not exists (select 1 from public.ffm_run_launches where id = p_launch) then raise exception 'bad task'; end if;
  insert into public.tasks (assigned_agent, created_by, title, status) values ('jarvis-hands', 'jarvis-hands', 'ffm: ' || p_step || ' (' || left(p_launch::text, 8) || ')', 'doing') returning id into v;
  return v;
end $$;
revoke all on function public.ffm_run_task(uuid, text) from public, anon, authenticated;
grant execute on function public.ffm_run_task(uuid, text) to service_role;

create or replace function public.ffm_run_receipt(p_launch uuid, p_step text, p_item text, p_simulated boolean, p_ok boolean, p_ref text default null, p_detail text default null,
                                                  p_task uuid default null) returns boolean
language plpgsql security definer set search_path to 'public' as $$
declare v_detail text := left(p_detail, 300); n int;
begin
  if v_detail is not null and coalesce(array_length(public.ws_sensitive_hits(v_detail), 1), 0) > 0 then v_detail := '[screened]'; end if;
  insert into public.ffm_run_receipts (launch_id, step, item, simulated, ok, external_ref, detail) values (p_launch, p_step, p_item, coalesce(p_simulated, true), coalesce(p_ok, false),
    case when p_ref ~ '^[A-Za-z0-9:._/-]{1,200}$' then p_ref end, v_detail)
  on conflict (launch_id, step, item) where ok do nothing;
  get diagnostics n = row_count;
  if p_task is not null then
    update public.tasks set status = case when p_ok then 'done' else 'cancelled' end, result = left(coalesce(v_detail, p_step), 300), updated_at = now()
     where id = p_task and assigned_agent = 'jarvis-hands' and status = 'doing';
  end if;
  return n > 0;
end $$;
revoke all on function public.ffm_run_receipt(uuid, text, text, boolean, boolean, text, text, uuid) from public, anon, authenticated;
grant execute on function public.ffm_run_receipt(uuid, text, text, boolean, boolean, text, text, uuid) to service_role;

-- ---------------------------------------------------------------------------------------------------------------------------- paid ads (objects, budgets, metrics)
create or replace function public.ffm_run_put_object(p_launch uuid, p_level text, p_ref text, p_parent uuid, p_external text, p_status text, p_daily integer, p_simulated boolean) returns uuid
language plpgsql security definer set search_path to 'public' as $$
declare l public.ffm_run_launches; v_id uuid;
begin
  select * into l from public.ffm_run_launches where id = p_launch for update;
  if l.id is null or l.status not in ('approved', 'running') then raise exception 'refused: the launch is not approved or running'; end if;
  if p_level = 'ad_set' and (p_daily is null or p_daily < 100) then raise exception 'refused: an ad set needs a daily budget of at least $1.00'; end if;
  if p_level <> 'ad_set' and p_daily is not null then raise exception 'refused: only ad sets carry a budget'; end if;
  insert into public.ffm_run_objects (launch_id, level, plan_ref, parent_id, external_id, status, daily_cents, simulated)
  values (p_launch, p_level, p_ref, p_parent, p_external, coalesce(p_status, 'paused'), p_daily, coalesce(p_simulated, true))
  on conflict (launch_id, level, plan_ref) do update set external_id = coalesce(excluded.external_id, ffm_run_objects.external_id), status = excluded.status,
    daily_cents = excluded.daily_cents, simulated = excluded.simulated, updated_at = now()
  returning id into v_id;
  perform public.ffm_run_check_budget(p_launch);
  if coalesce(p_status, 'paused') = 'active' and l.status = 'approved' then update public.ffm_run_launches set status = 'running', updated_at = now() where id = p_launch; end if;
  return v_id;
end $$;
revoke all on function public.ffm_run_put_object(uuid, text, text, uuid, text, text, integer, boolean) from public, anon, authenticated;
grant execute on function public.ffm_run_put_object(uuid, text, text, uuid, text, text, integer, boolean) to service_role;

-- status / budget change of one object. Pausing or stopping is always allowed; switching on or raising a budget passes the budget rule.
create or replace function public.ffm_run_set_object(p_object uuid, p_status text, p_daily integer default null) returns jsonb
language plpgsql security definer set search_path to 'public' as $$
declare o public.ffm_run_objects; l public.ffm_run_launches;
begin
  select * into l from public.ffm_run_launches where id = (select launch_id from public.ffm_run_objects where id = p_object) for update;   -- the launch first
  select * into o from public.ffm_run_objects where id = p_object for update;
  if o.id is null then raise exception 'unknown object'; end if;
  if p_status not in ('paused', 'active', 'stopped') then raise exception 'unknown status'; end if;
  if p_status = 'active' and l.status not in ('approved', 'running') then raise exception 'refused: the launch is %', l.status; end if;
  if p_daily is not null and (o.level <> 'ad_set' or p_daily < 100) then raise exception 'refused: only an ad set takes a daily budget of at least $1.00'; end if;
  update public.ffm_run_objects set status = p_status, daily_cents = coalesce(p_daily, daily_cents), updated_at = now() where id = p_object;
  if p_status = 'active' or coalesce(p_daily, 0) > coalesce(o.daily_cents, 0) then perform public.ffm_run_check_budget(o.launch_id); end if;
  if p_status = 'active' and l.status = 'approved' then update public.ffm_run_launches set status = 'running', updated_at = now() where id = l.id; end if;
  return jsonb_build_object('ok', true, 'status', p_status);
end $$;
revoke all on function public.ffm_run_set_object(uuid, text, integer) from public, anon, authenticated;
grant execute on function public.ffm_run_set_object(uuid, text, integer) to service_role;

-- one day of one ad's numbers (replaces that day). Spend counts against the cap whether live or simulated; live spend also goes to the workspace ledger.
create or replace function public.ffm_run_put_metrics(p_object uuid, p_day date, p_spend integer, p_impressions integer, p_clicks integer, p_leads integer, p_simulated boolean) returns jsonb
language plpgsql security definer set search_path to 'public' as $$
declare o public.ffm_run_objects; l public.ffm_run_launches; v_old integer; b jsonb; v_capped boolean := false; v_ledger text;
begin
  select * into o from public.ffm_run_objects where id = p_object;
  if o.id is null or o.level <> 'ad' then raise exception 'metrics are recorded per ad'; end if;
  select * into l from public.ffm_run_launches where id = o.launch_id for update;
  select spend_cents into v_old from public.ffm_run_metrics where object_id = p_object and day = p_day;
  insert into public.ffm_run_metrics (object_id, launch_id, day, spend_cents, impressions, clicks, leads, simulated)
  values (p_object, o.launch_id, p_day, greatest(coalesce(p_spend, 0), 0), greatest(coalesce(p_impressions, 0), 0), greatest(coalesce(p_clicks, 0), 0), greatest(coalesce(p_leads, 0), 0), coalesce(p_simulated, true))
  on conflict (object_id, day) do update set spend_cents = excluded.spend_cents, impressions = excluded.impressions, clicks = excluded.clicks, leads = excluded.leads,
    simulated = excluded.simulated, updated_at = now();
  if not coalesce(p_simulated, true) and greatest(coalesce(p_spend, 0), 0) > coalesce(v_old, 0) then
    begin
      perform public.ws_record_spend(l.workspace_id, l.campaign_id, greatest(coalesce(p_spend, 0), 0) - coalesce(v_old, 0), 'ffm launch ad spend');
    exception when others then
      v_ledger := left(sqlerrm, 120); v_capped := true;
    end;
  end if;
  b := public.ffm_run_budget(o.launch_id);
  if b is not null and (b ->> 'spent_cents')::int >= (b ->> 'total_cap_cents')::int then v_capped := true; end if;
  if v_capped and l.status in ('approved', 'running') then
    update public.ffm_run_launches set status = 'capped', updated_at = now() where id = l.id;
    insert into public.audit_log (actor, action, target, detail) values ('ffm-run', 'ffm_run_capped', 'workspace/' || l.workspace_id,
      jsonb_build_object('launch', l.id, 'spent_cents', (b ->> 'spent_cents')::int, 'cap_cents', (b ->> 'total_cap_cents')::int, 'ledger', v_ledger));
  end if;
  return coalesce(b, '{}'::jsonb) || jsonb_build_object('capped', v_capped or l.status = 'capped', 'ledger_refused', v_ledger);
end $$;
revoke all on function public.ffm_run_put_metrics(uuid, date, integer, integer, integer, integer, boolean) from public, anon, authenticated;
grant execute on function public.ffm_run_put_metrics(uuid, date, integer, integer, integer, integer, boolean) to service_role;

-- ---------------------------------------------------------------------------------------------------------------------------- organic posts and the landing page (hands path)
create or replace function public.ffm_run_submit_hand(p_launch uuid, p_item text, p_connector text, p_action text, p_payload jsonb) returns jsonb
language plpgsql security definer set search_path to 'public' as $$
declare l public.ffm_run_launches; b jsonb; it jsonb; acc public.hand_accounts; v_id uuid; r jsonb;
        plat constant jsonb := '{"instagram": "meta-instagram", "facebook": "meta-facebook", "tiktok": "tiktok", "linkedin": "linkedin", "youtube": "youtube", "x": "x-twitter"}';
begin
  select * into l from public.ffm_run_launches where id = p_launch for update;
  if l.id is null or l.status not in ('approved', 'running') then return jsonb_build_object('ok', false, 'reason', 'launch not running (or capped)'); end if;
  b := public.ffm_run_budget(p_launch);
  if b is null then return jsonb_build_object('ok', false, 'reason', 'no owner-approved budget'); end if;
  if p_payload is null or jsonb_typeof(p_payload) <> 'object' then return jsonb_build_object('ok', false, 'reason', 'payload must be an object'); end if;
  if p_action = 'post' then
    select x.v into it from jsonb_array_elements(coalesce(l.plan -> 'posts', '[]')) as x(v) where x.v ->> 'ref' = p_item;
    if it is null then return jsonb_build_object('ok', false, 'reason', 'not an item of the approved plan'); end if;
    if (plat ->> (it ->> 'platform')) is distinct from p_connector then return jsonb_build_object('ok', false, 'reason', 'connector does not match the approved platform'); end if;
    if p_payload ->> 'text' is distinct from it ->> 'text' or exists (select 1 from jsonb_object_keys(p_payload) as t(k) where t.k <> 'text') then
      return jsonb_build_object('ok', false, 'reason', 'the text differs from the approved plan');
    end if;
  elsif p_action = 'deploy' then
    if p_connector <> 'netlify' or not coalesce((l.plan ->> 'landing')::boolean, false) then return jsonb_build_object('ok', false, 'reason', 'no landing page in the approved plan'); end if;
    if encode(sha256(convert_to(coalesce(p_payload ->> 'html', ''), 'UTF8')), 'hex') is distinct from l.plan ->> 'landing_sha256'
       or exists (select 1 from jsonb_object_keys(p_payload) as t(k) where t.k <> 'html') then
      return jsonb_build_object('ok', false, 'reason', 'the page differs from the approved plan');
    end if;
  else
    return jsonb_build_object('ok', false, 'reason', 'only post and deploy');
  end if;
  select * into acc from public.hand_accounts where connector = p_connector and division = 'ffm' and status = 'connected' order by updated_at desc limit 1;
  if acc.id is null then return jsonb_build_object('ok', false, 'reason', 'no connected ' || p_connector || ' account for ffm'); end if;
  insert into public.hand_actions (connector, account_id, division, action, payload, ai_generated, created_by, approval_kind, approved_by, approved_at)
  values (p_connector, acc.id, 'ffm', p_action, p_payload, true, 'ffm-run', 'owner', 'owner:launch:' || left((b ->> 'budget_id'), 8), (b ->> 'approved_at')::timestamptz)
  returning id into v_id;
  insert into public.audit_log (actor, action, target, detail) values ('ffm-run', 'hands_action_submitted', p_connector,
    jsonb_build_object('action', v_id, 'kind', p_action, 'launch', p_launch, 'item', p_item, 'approval', 'launch budget ' || (b ->> 'budget_id')));
  r := public.hands_release(v_id);
  return jsonb_build_object('ok', true, 'action_id', v_id) || r;
end $$;
revoke all on function public.ffm_run_submit_hand(uuid, text, text, text, jsonb) from public, anon, authenticated;
grant execute on function public.ffm_run_submit_hand(uuid, text, text, text, jsonb) to service_role;

create or replace function public.ffm_run_set_landing(p_launch uuid, p_url text) returns void
language plpgsql security definer set search_path to 'public' as $$
begin
  if p_url is null or p_url !~ '^https://[^\s]{4,}$' or length(p_url) > 300 then raise exception 'landing url must be https'; end if;
  perform 1 from public.ffm_run_launches where id = p_launch for update;
  update public.ffm_run_launches set landing_url = p_url, updated_at = now() where id = p_launch and status in ('approved', 'running');
  if not found then raise exception 'launch not in progress'; end if;
end $$;
revoke all on function public.ffm_run_set_landing(uuid, text) from public, anon, authenticated;
grant execute on function public.ffm_run_set_landing(uuid, text) to service_role;

-- ---------------------------------------------------------------------------------------------------------------------------- leads
create or replace function public.ffm_run_intake_lead(p_launch uuid, p_source text, p_source_ref text, p_name text, p_email text, p_phone text, p_consent jsonb, p_by text) returns jsonb
language plpgsql security definer set search_path to 'public' as $$
declare l public.ffm_run_launches; v_lead uuid; v_at timestamptz;
begin
  select * into l from public.ffm_run_launches where id = p_launch for update;
  if l.id is null or l.status not in ('approved', 'running', 'capped', 'done') then raise exception 'lead refused: the launch is not taking leads'; end if;
  if p_source not in ('meta_form', 'landing', 'manual') then raise exception 'lead refused: unknown source'; end if;
  if p_source_ref is null or p_source_ref !~ '^[A-Za-z0-9][A-Za-z0-9._-]{2,99}$' then raise exception 'lead refused: source_ref must be the form submission id'; end if;
  select lead_id into v_lead from public.ffm_run_leads where launch_id = p_launch and source_ref = p_source_ref;
  if v_lead is not null then return jsonb_build_object('ok', true, 'duplicate', true, 'lead_id', v_lead); end if;
  -- CASL: no consent fields, no lead
  if p_consent is null or jsonb_typeof(p_consent) <> 'object' or (p_consent ->> 'given') is distinct from 'true'
     or coalesce(btrim(p_consent ->> 'wording_version'), '') = '' or coalesce(p_consent ->> 'captured_at', '') = ''
     or coalesce(p_consent ->> 'evidence_ref', '') !~ '^[A-Za-z0-9][A-Za-z0-9._-]{2,99}$' then
    raise exception 'lead refused: consent is required (given, wording_version, captured_at, evidence_ref)';
  end if;
  v_at := (p_consent ->> 'captured_at')::timestamptz;
  if p_email is null and p_phone is null then raise exception 'lead refused: no email and no phone'; end if;
  -- the unchanged guarded insert: ws_guard refuses applications, banking, credit, ID and sensitive financial data
  v_lead := public.ws_add_lead(l.workspace_id, l.campaign_id, coalesce(nullif(btrim(p_name), ''), 'Lead'), p_email, p_phone, p_source, null);
  if p_email is not null then
    perform public.ffm_record_consent(l.workspace_id, v_lead, 'email', 'express', p_consent ->> 'wording_version', p_source, v_at, p_consent ->> 'evidence_ref', left(coalesce(p_by, 'ffm-run'), 60));
  end if;
  insert into public.ffm_run_leads (lead_id, workspace_id, launch_id, source, source_ref, next_touch, next_due_at)
  values (v_lead, l.workspace_id, p_launch, p_source, p_source_ref, 1, now());
  insert into public.audit_log (actor, action, target, detail) values (left(coalesce(p_by, 'ffm-run'), 60), 'ffm_run_lead_in', 'workspace/' || l.workspace_id,
    jsonb_build_object('launch', p_launch, 'lead', v_lead, 'source', p_source));
  return jsonb_build_object('ok', true, 'lead_id', v_lead, 'contact', public.ffm_contact_status(v_lead, 'email'));
end $$;
revoke all on function public.ffm_run_intake_lead(uuid, text, text, text, text, text, jsonb, text) from public, anon, authenticated;
grant execute on function public.ffm_run_intake_lead(uuid, text, text, text, text, text, jsonb, text) to service_role;

-- one follow-up touch. Allowed only for the lead's next due touch, with the approved text, and only when ffm_contact_status allows email.
-- p_live (python: gate live) AND a live mode -> the email is QUEUED for the FF Marketing sender (ffm_run_claim_email re-checks everything at send time),
-- carrying the client workspace's own CASL footer; otherwise it is recorded as simulated. Nothing here goes through the legacy outbox / Donna path.
create or replace function public.ffm_run_touch(p_lead uuid, p_touch integer, p_subject text, p_body text, p_live boolean) returns jsonb
language plpgsql security definer set search_path to 'public' as $$
declare rl public.ffm_run_leads; l public.ffm_run_launches; wl public.ws_leads; it jsonb; nx jsonb; cs jsonb; v_status text; v_mail uuid; v_reason text;
begin
  select * into l from public.ffm_run_launches where id = (select launch_id from public.ffm_run_leads where lead_id = p_lead) for update;   -- the launch first
  select * into rl from public.ffm_run_leads where lead_id = p_lead for update;
  if rl.lead_id is null then raise exception 'unknown lead'; end if;
  if rl.status <> 'active' then return jsonb_build_object('ok', false, 'reason', 'lead is ' || rl.status); end if;
  if p_touch is distinct from rl.next_touch then return jsonb_build_object('ok', false, 'reason', 'not the next touch'); end if;
  if rl.next_due_at is null or rl.next_due_at > now() then return jsonb_build_object('ok', false, 'reason', 'not due'); end if;
  if coalesce((select kill_switch from public.system_state where id = 1), true) then return jsonb_build_object('ok', false, 'reason', 'kill switch is on'); end if;
  if l.status not in ('approved', 'running', 'capped', 'done') then return jsonb_build_object('ok', false, 'reason', 'launch is ' || l.status); end if;
  it := l.plan -> 'touches' -> (p_touch - 1);
  if it is null then return jsonb_build_object('ok', false, 'reason', 'no such touch in the approved plan'); end if;
  if p_subject is distinct from it ->> 'subject' or p_body is null or position(it ->> 'body' in p_body) <> 1 or length(p_body) > length(it ->> 'body') + 300 then
    return jsonb_build_object('ok', false, 'reason', 'the text differs from the approved plan');
  end if;
  if coalesce(array_length(public.ws_sensitive_hits(coalesce(p_subject, '') || ' ' || p_body), 1), 0) > 0 then raise exception 'Sensitive data refused in the follow-up text' using errcode = 'P0001'; end if;
  cs := public.ffm_contact_status(p_lead, 'email');
  if coalesce((cs ->> 'allowed')::boolean, false) is not true then
    v_reason := left(regexp_replace(coalesce(cs ->> 'reason', 'not_allowed'), '[^a-z_]', '_', 'g'), 40);
    insert into public.ffm_run_touches (lead_id, touch, status, reason) values (p_lead, p_touch, 'skipped', v_reason);
    update public.ffm_run_leads set status = case when v_reason in ('withdrawn', 'suppressed') then 'opted_out' else 'needs_consent' end, next_due_at = null, updated_at = now() where lead_id = p_lead;
    return jsonb_build_object('ok', true, 'status', 'skipped', 'reason', v_reason);
  end if;
  if coalesce(p_live, false) and public.ffm_run_live_mode() and not coalesce(l.dry_run, true) and public.ffm_run_sender(l.workspace_id) is not null then
    insert into public.ffm_run_emails (lead_id, launch_id, touch, subject, body)
    values (p_lead, l.id, p_touch, p_subject, p_body || public.ffm_run_footer(l.workspace_id)) returning id into v_mail;
    v_status := 'queued';
  else
    v_status := 'simulated';
  end if;
  insert into public.ffm_run_touches (lead_id, touch, status, email_id) values (p_lead, p_touch, v_status, v_mail);
  nx := l.plan -> 'touches' -> p_touch;
  update public.ffm_run_leads set next_touch = p_touch + 1, first_response_at = coalesce(first_response_at, now()), updated_at = now(),
    status = case when nx is null then 'done' else 'active' end,
    next_due_at = case when nx is null then null else greatest(rl.created_at + make_interval(days => coalesce((nx ->> 'day')::int, p_touch)), now()) end
   where lead_id = p_lead;
  update public.ws_leads set stage = 'contacted' where id = p_lead and stage = 'new';
  return jsonb_build_object('ok', true, 'status', v_status, 'email_id', v_mail);
end $$;
revoke all on function public.ffm_run_touch(uuid, integer, text, text, boolean) from public, anon, authenticated;
grant execute on function public.ffm_run_touch(uuid, integer, text, text, boolean) to service_role;

-- reply / booking / opt-out / lost: stops the sequence and withdraws this lead's unsent emails. Opt-out also withdraws consent (suppression).
create or replace function public.ffm_run_lead_event(p_lead uuid, p_event text, p_by text) returns jsonb
language plpgsql security definer set search_path to 'public' as $$
declare rl public.ffm_run_leads; n int := 0;
begin
  if p_event is null or p_event not in ('replied', 'booked', 'opted_out', 'lost') then raise exception 'unknown event'; end if;
  perform 1 from public.ffm_run_launches where id = (select launch_id from public.ffm_run_leads where lead_id = p_lead) for update;   -- the launch first
  select * into rl from public.ffm_run_leads where lead_id = p_lead for update;
  if rl.lead_id is null then raise exception 'unknown lead'; end if;
  update public.ffm_run_leads set status = p_event, next_due_at = null, updated_at = now() where lead_id = p_lead;
  update public.ws_leads set stage = case p_event when 'booked' then 'booked' when 'replied' then 'contacted' else 'lost' end where id = p_lead;
  update public.ffm_run_emails set status = 'withdrawn', reason = 'lead ' || p_event where lead_id = p_lead and status = 'queued';
  get diagnostics n = row_count;
  if p_event = 'opted_out' then
    perform public.ffm_withdraw_consent(rl.workspace_id, p_lead, 'all', 'lead opt-out', null, left(coalesce(p_by, 'ffm-run'), 60));
  end if;
  insert into public.audit_log (actor, action, target, detail) values (left(coalesce(p_by, 'ffm-run'), 60), 'ffm_run_lead_' || p_event, 'workspace/' || rl.workspace_id,
    jsonb_build_object('lead', p_lead, 'emails_withdrawn', n));
  return jsonb_build_object('ok', true, 'status', p_event, 'emails_withdrawn', n);
end $$;
revoke all on function public.ffm_run_lead_event(uuid, text, text) from public, anon, authenticated;
grant execute on function public.ffm_run_lead_event(uuid, text, text) to service_role;

-- ---------------------------------------------------------------------------------------------------------------------------- the client's sender and the FF Marketing email sender
-- the client workspace's own CASL identity (owner records it as the client gave it), kept in the EXISTING company_profile table under venture_slug
-- 'ffm-<workspace slug>' (already a backup redaction source; hq_mail.profile reads the same row shape). Required before a launch can be proposed.
create or replace function public.ffm_run_sender(p_ws uuid) returns jsonb
language sql stable security definer set search_path to 'public' as $$
  select jsonb_build_object('from_email', cp.reply_email, 'sender_name', cp.sender_name, 'brand', cp.brand, 'mailing_address', cp.mailing_address)
    from public.client_workspaces w join public.company_profile cp on cp.venture_slug = 'ffm-' || w.slug
   where w.id = p_ws and public.normalize_addr(cp.reply_email) is not null and length(btrim(coalesce(cp.sender_name, ''))) >= 2
     and length(btrim(coalesce(cp.brand, ''))) >= 2 and length(btrim(coalesce(cp.mailing_address, ''))) >= 8
$$;
revoke all on function public.ffm_run_sender(uuid) from public, anon, authenticated;
grant execute on function public.ffm_run_sender(uuid) to service_role;

create or replace function public.ffm_run_set_sender(p_ws uuid, p_from_email text, p_sender_name text, p_brand text, p_mailing_address text, p_by text) returns void
language plpgsql security definer set search_path to 'public' as $$
declare v_slug text;
begin
  if p_by is null or p_by !~ '^owner:' then raise exception 'only the owner records a client sender profile' using errcode = '42501'; end if;
  perform public.ffm_open_ws(p_ws);
  if public.normalize_addr(p_from_email) is null then raise exception 'sender refused: the from address is not one clean email address'; end if;
  if coalesce(length(btrim(p_sender_name)), 0) < 2 or coalesce(length(btrim(p_brand)), 0) < 2 or coalesce(length(btrim(p_mailing_address)), 0) < 8 then
    raise exception 'sender refused: sender name, brand and a real mailing address are required (CASL)';
  end if;
  if coalesce(array_length(public.ws_sensitive_hits(p_sender_name || ' ' || p_brand), 1), 0) > 0 then raise exception 'Sensitive data refused in the sender profile' using errcode = 'P0001'; end if;
  select 'ffm-' || slug into v_slug from public.client_workspaces where id = p_ws;
  insert into public.company_profile (venture_slug, sender_name, brand, mailing_address, reply_email, updated_at)
  values (v_slug, left(btrim(p_sender_name), 80), left(btrim(p_brand), 80), left(btrim(p_mailing_address), 200), public.normalize_addr(p_from_email), now())
  on conflict (venture_slug) do update set sender_name = excluded.sender_name, brand = excluded.brand, mailing_address = excluded.mailing_address,
    reply_email = excluded.reply_email, updated_at = now();
  insert into public.audit_log (actor, action, target, detail) values (left(p_by, 60), 'ffm_run_sender_set', 'workspace/' || p_ws, '{}'::jsonb);
end $$;
revoke all on function public.ffm_run_set_sender(uuid, text, text, text, text, text) from public, anon, authenticated;
grant execute on function public.ffm_run_set_sender(uuid, text, text, text, text, text) to service_role;

create or replace function public.ffm_run_footer(p_ws uuid) returns text
language sql stable security definer set search_path to 'public' as $$
  select chr(10) || chr(10) || '--' || chr(10) || (s ->> 'sender_name') || ', ' || (s ->> 'brand') || chr(10) || (s ->> 'mailing_address') || chr(10)
      || 'Unsubscribe: mailto:' || (s ->> 'from_email') || '?subject=unsubscribe (or reply "unsubscribe"). You will be removed within 10 business days.'
  from (select public.ffm_run_sender(p_ws) as s) x where s is not null
$$;
revoke all on function public.ffm_run_footer(uuid) from public, anon, authenticated;
grant execute on function public.ffm_run_footer(uuid) to service_role;

-- the sender claims one queued email immediately before the provider call; every condition is checked AGAIN here (kill switch, live mode, dry-run launch,
-- the lead's sequence, ffm_contact_status: consent, withdrawal, suppression, outreach gate, and the footer of THIS client).
create or replace function public.ffm_run_claim_email(p_id uuid) returns jsonb
language plpgsql security definer set search_path to 'public' as $$
declare e public.ffm_run_emails; l public.ffm_run_launches; rl public.ffm_run_leads; s jsonb; cs jsonb; why text; v_to text;
begin
  select * into l from public.ffm_run_launches where id = (select launch_id from public.ffm_run_emails where id = p_id) for update;   -- the launch first
  select * into e from public.ffm_run_emails where id = p_id for update;
  if e.id is null or e.status <> 'queued' then return jsonb_build_object('ok', false, 'reason', 'not queued'); end if;
  select * into rl from public.ffm_run_leads where lead_id = e.lead_id;
  s := public.ffm_run_sender(l.workspace_id);
  select email into v_to from public.ws_leads where id = e.lead_id;          -- the recipient is read now, from the lead (never stored twice)
  cs := public.ffm_contact_status(e.lead_id, 'email');
  if not public.ffm_run_live_mode() then why := 'not live (kill switch or dry-run mode)';
  elsif coalesce(l.dry_run, true) then why := 'dry-run launch';
  elsif rl.status not in ('active', 'done') then why := 'lead is ' || rl.status;
  elsif coalesce((cs ->> 'allowed')::boolean, false) is not true then why := 'not contactable: ' || coalesce(cs ->> 'reason', '?');
  elsif s is null or position(s ->> 'mailing_address' in e.body) = 0 or position('unsubscribe' in lower(e.body)) = 0 then why := 'no CASL footer of this client';
  elsif public.normalize_addr(v_to) is null then why := 'no usable address';
  end if;
  if why is not null then
    if why like 'not contactable%' or why like 'lead is%' then update public.ffm_run_emails set status = 'withdrawn', reason = left(why, 120) where id = p_id; end if;
    return jsonb_build_object('ok', false, 'reason', why);
  end if;
  update public.ffm_run_emails set status = 'sending', attempts = attempts + 1, claimed_at = now() where id = p_id;
  return jsonb_build_object('ok', true, 'to', v_to, 'from', s ->> 'from_email', 'from_name', (s ->> 'sender_name') || ' (' || (s ->> 'brand') || ')', 'subject', e.subject, 'body', e.body,
    'unsubscribe', 'mailto:' || (s ->> 'from_email') || '?subject=unsubscribe');
end $$;
revoke all on function public.ffm_run_claim_email(uuid) from public, anon, authenticated;
grant execute on function public.ffm_run_claim_email(uuid) to service_role;

create or replace function public.ffm_run_email_result(p_id uuid, p_ok boolean, p_ref text default null, p_reason text default null) returns void
language plpgsql security definer set search_path to 'public' as $$
declare e public.ffm_run_emails;
begin
  select * into e from public.ffm_run_emails where id = p_id for update;
  if e.id is null or e.status <> 'sending' then raise exception 'email is not being sent'; end if;
  if p_ok then
    update public.ffm_run_emails set status = 'sent', sent_at = now(), provider_ref = case when p_ref ~ '^[A-Za-z0-9:._-]{1,120}$' then p_ref end where id = p_id;
    insert into public.audit_log (actor, action, target, detail) values ('ffm-run', 'ffm_run_email_sent', 'workspace/' || (select workspace_id from public.ffm_run_leads where lead_id = e.lead_id),
      jsonb_build_object('email', p_id, 'touch', e.touch));
  else
    update public.ffm_run_emails set status = case when e.attempts >= 5 then 'failed' else 'queued' end, reason = left(p_reason, 120) where id = p_id;
  end if;
end $$;
revoke all on function public.ffm_run_email_result(uuid, boolean, text, text) from public, anon, authenticated;
grant execute on function public.ffm_run_email_result(uuid, boolean, text, text) to service_role;

-- ---------------------------------------------------------------------------------------------------------------------------- end and report
-- ends a launch: the owner at any time (p_by 'owner:...'), Jarvis only after its end date or once capped
create or replace function public.ffm_run_stop(p_launch uuid, p_by text) returns jsonb
language plpgsql security definer set search_path to 'public' as $$
declare l public.ffm_run_launches;
begin
  select * into l from public.ffm_run_launches where id = p_launch for update;
  if l.id is null then raise exception 'unknown launch'; end if;
  if l.status not in ('proposed', 'approved', 'running', 'capped') then return jsonb_build_object('ok', false, 'reason', 'launch is ' || l.status); end if;
  if coalesce(p_by, '') !~ '^owner:' and not (l.status = 'capped' or (now() at time zone 'America/Toronto')::date > l.ends_on) then
    raise exception 'only the owner ends a launch before its end date' using errcode = '42501';
  end if;
  update public.ffm_run_budgets set status = 'superseded' where launch_id = p_launch and status = 'proposed';
  update public.ffm_run_launches set status = case when l.status = 'proposed' then 'rejected' else 'done' end, updated_at = now() where id = p_launch;
  insert into public.audit_log (actor, action, target, detail) values (left(coalesce(p_by, 'ffm-run'), 60), 'ffm_run_stopped', 'workspace/' || l.workspace_id, jsonb_build_object('launch', p_launch));
  return jsonb_build_object('ok', true);
end $$;
revoke all on function public.ffm_run_stop(uuid, text) from public, anon, authenticated;
grant execute on function public.ffm_run_stop(uuid, text) to service_role;

create or replace function public.ffm_run_report(p_launch uuid, p_from date default null, p_to date default null) returns jsonb
language plpgsql stable security definer set search_path to 'public' as $$
declare l public.ffm_run_launches; w public.client_workspaces; v_to date := coalesce(p_to, (now() at time zone 'America/Toronto')::date); v_from date; b jsonb; spend int; n_leads int; best jsonb;
begin
  v_from := coalesce(p_from, v_to - 6);
  select * into l from public.ffm_run_launches where id = p_launch;
  if l.id is null then raise exception 'unknown launch'; end if;
  select * into w from public.client_workspaces where id = l.workspace_id;
  b := public.ffm_run_budget(p_launch);
  select coalesce(sum(spend_cents), 0)::int into spend from public.ffm_run_metrics where launch_id = p_launch and day between v_from and v_to;
  select count(*) into n_leads from public.ffm_run_leads where launch_id = p_launch and (created_at at time zone 'America/Toronto')::date between v_from and v_to;
  select coalesce(jsonb_agg(x order by (x ->> 'leads')::int > 0 desc, (x ->> 'cpl_cents')::numeric nulls last, (x ->> 'clicks')::int desc), '[]'::jsonb) into best from (
    select jsonb_build_object('ref', o.plan_ref, 'headline', (select x.v ->> 'headline' from jsonb_array_elements(l.plan -> 'ads') as x(v) where x.v ->> 'ref' = o.plan_ref limit 1),
           'status', o.status, 'spend_cents', sum(m.spend_cents), 'leads', sum(m.leads), 'clicks', sum(m.clicks), 'impressions', sum(m.impressions),
           'cpl_cents', case when sum(m.leads) > 0 then round(sum(m.spend_cents)::numeric / sum(m.leads)) end) x
      from public.ffm_run_objects o join public.ffm_run_metrics m on m.object_id = o.id
     where o.launch_id = p_launch and m.day between v_from and v_to group by o.id, o.plan_ref, o.status order by sum(m.leads) desc, sum(m.clicks) desc limit 3) t;
  return jsonb_build_object('workspace', w.slug, 'name', w.name, 'launch', p_launch, 'status', l.status, 'from', v_from, 'to', v_to,
    'spend_cents', spend, 'spent_total_cents', coalesce((b ->> 'spent_cents')::int, 0), 'total_cap_cents', (b ->> 'total_cap_cents')::int, 'daily_cents', (b ->> 'daily_cents')::int,
    'leads', n_leads, 'cpl_cents', case when n_leads > 0 then round(spend::numeric / n_leads) end, 'best_ads', best,
    'leads_by_status', coalesce((select jsonb_object_agg(status, n) from (select status, count(*) n from public.ffm_run_leads where launch_id = p_launch group by status) s), '{}'::jsonb),
    'touches', coalesce((select jsonb_object_agg(t.status, t.n) from (select t.status, count(*) n from public.ffm_run_touches t join public.ffm_run_leads rl on rl.lead_id = t.lead_id
                         where rl.launch_id = p_launch and (t.created_at at time zone 'America/Toronto')::date between v_from and v_to group by t.status) t), '{}'::jsonb),
    'emails_sent', (select count(*) from public.ffm_run_emails where launch_id = p_launch and status = 'sent' and (sent_at at time zone 'America/Toronto')::date between v_from and v_to),
    'simulated', exists (select 1 from public.ffm_run_receipts where launch_id = p_launch and simulated and (created_at at time zone 'America/Toronto')::date between v_from and v_to)
                 or exists (select 1 from public.ffm_run_metrics where launch_id = p_launch and simulated and day between v_from and v_to));
end $$;
revoke all on function public.ffm_run_report(uuid, date, date) from public, anon, authenticated;
grant execute on function public.ffm_run_report(uuid, date, date) to service_role;
