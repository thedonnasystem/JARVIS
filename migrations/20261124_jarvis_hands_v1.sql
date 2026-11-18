-- Jarvis hands v1 (Nov 18 2026). UNRELEASED dev migration (build/jarvis-hands-v1). ADDITIVE and DORMANT: nothing here runs, spends or posts until the owner
-- enables it, and dry_run still holds every external effect.
--   * hand_connectors: the connector registry (one row per service adapter in hq_hands_adapters.py; a python test keeps the two identical). Every connector
--     starts DISABLED. Account creation is ASSISTED ONLY for every connector: Jarvis prepares the details and hands the Chairman the official sign-up page; the
--     Chairman signs up himself. The column cannot hold any automated sign-up mode.
--   * hand_accounts: which accounts exist (connector, handle, division, status, token vault reference). NO credentials: the Chairman's password stays with him and
--     the platform; the only reference kept is the vault id of the official OAuth / API token (uuid shape enforced, so a raw token cannot be stored here).
--   * hand_actions: the generic action queue (create_account, post, upload, send, update, deploy):
--     draft -> approved -> scheduled -> running -> done / failed; create_account goes draft -> handoff -> done (the owner completed it); dry_run = logged only.
--   * hand_standing: standing approvals per division or account (post / upload only). Owner-only, default OFF (no rows).
--   * Execution goes through the existing executor gate: executor 'hands-actions' is registered ONLY by hands_owner_enable (owner-only); executor_request applies
--     kill switch, mode, caps and the spend gateway (agent 'jarvis-hands', seeded PAUSED). Jobs go through the core queue (jarvis_enqueue, kind 'hands.action'),
--     which hands out nothing while the core / worker is off or the kill switch is on.
--   * Rate limit IN THE DATABASE: max_actions_per_day per connector (a due action over the limit is deferred to tomorrow).
--   * Public actions (post, upload, update, deploy) are screened with ws_sensitive_hits() at submit (plus the python personal-data scan before every call).
--   * backup_classification() / backup_redaction_spec() are re-created with the same rows plus the new tables (class internal, every text column classified).
--     PROTECTED objects: owner approval needed.
-- Rollback: ops/rollback_jarvis_hands.sql.

-- ---------------------------------------------------------------------------------------------------------------------------- tables
create table if not exists public.hand_connectors (
  slug text primary key check (slug ~ '^[a-z][a-z0-9-]{1,39}$'),
  title text not null check (length(title) between 2 and 80),
  auth text not null check (auth in ('oauth2', 'api_key', 'none')),
  actions text[] not null default '{}' check (actions <@ array['create_account', 'post', 'upload', 'send', 'update', 'deploy']),
  signup_mode text not null default 'assisted' check (signup_mode in ('assisted', 'none')),   -- no automated sign-up exists, for any connector
  enabled boolean not null default false,
  max_actions_per_day integer not null default 0 check (max_actions_per_day between 0 and 200),
  cost_cents_per_action integer not null default 0 check (cost_cents_per_action between 0 and 100000),
  ai_label text not null default 'none' check (ai_label in ('api_field', 'caption', 'none')),
  terms text not null default '' check (length(terms) <= 400),
  signup_url text check (signup_url is null or (signup_url ~ '^https://[^\s]{4,}$' and length(signup_url) <= 300)),
  updated_at timestamptz not null default now(),
  updated_by text not null default 'migration'
);

insert into public.hand_connectors (slug, title, auth, actions, signup_mode, max_actions_per_day, cost_cents_per_action, ai_label, signup_url, terms) values
  ('meta-facebook', 'Facebook Page (Meta Graph API)', 'oauth2', array['create_account', 'post'], 'assisted', 5, 0, 'caption', 'https://www.facebook.com/pages/create',
   'The Chairman creates the Page himself; publishing only through the Graph API with a Page token'),
  ('meta-instagram', 'Instagram professional account (Instagram Graph API)', 'oauth2', array['create_account', 'post'], 'assisted', 5, 0, 'caption', 'https://www.instagram.com/accounts/emailsignup/',
   'The Chairman signs up himself; content publishing API only, Meta caps API posts per 24 h'),
  ('tiktok', 'TikTok (Content Posting API)', 'oauth2', array['create_account', 'post', 'upload'], 'assisted', 3, 0, 'api_field', 'https://www.tiktok.com/signup',
   'The Chairman signs up himself; unaudited API clients may only post privately'),
  ('youtube', 'YouTube (Data API v3 uploads)', 'oauth2', array['create_account', 'upload'], 'assisted', 3, 0, 'api_field', 'https://accounts.google.com/signup',
   'The Chairman creates the Google account / channel himself; uploads from unverified API projects stay private until Google audit'),
  ('x-twitter', 'X (API v2 posts)', 'oauth2', array['create_account', 'post'], 'assisted', 5, 0, 'caption', 'https://x.com/i/flow/signup',
   'The Chairman signs up himself; posting through the API only, within the app tier limits'),
  ('linkedin', 'LinkedIn (Posts API)', 'oauth2', array['create_account', 'post'], 'assisted', 3, 0, 'caption', 'https://www.linkedin.com/signup',
   'The Chairman signs up himself; member posting via the Share on LinkedIn product only'),
  ('email', 'Email (existing outbox, CASL consent and suppression enforced)', 'api_key', array['send'], 'none', 20, 0, 'none', null,
   'Only drafts into the existing outbox: consent, suppression and the outreach gate decide every send; never a cold list'),
  ('netlify', 'Netlify static site deploy', 'api_key', array['create_account', 'deploy'], 'assisted', 3, 0, 'none', 'https://app.netlify.com/signup',
   'The Chairman signs up himself; deploys a zip he approved to a site he connected; free tier')
on conflict (slug) do update set title = excluded.title, auth = excluded.auth, actions = excluded.actions, signup_mode = excluded.signup_mode,
  ai_label = excluded.ai_label, terms = excluded.terms, cost_cents_per_action = excluded.cost_cents_per_action, signup_url = excluded.signup_url;

create table if not exists public.hand_accounts (
  id uuid primary key default gen_random_uuid(),
  connector text not null references public.hand_connectors(slug),
  division text not null check (division ~ '^[a-z][a-z0-9-]{1,39}$'),
  handle text not null check (handle ~ '^[A-Za-z0-9._-]{2,60}$'),
  display_name text check (display_name is null or length(display_name) <= 80),
  purpose text not null check (length(purpose) between 5 and 300),
  bio text check (bio is null or length(bio) <= 500),
  asset_ref text check (asset_ref is null or (asset_ref ~ '^(https://[^\s]{4,}|asset:[A-Za-z0-9._/-]{1,120})$' and length(asset_ref) <= 400)),
  monthly_cents integer not null default 0 check (monthly_cents between 0 and 100000),
  status text not null default 'proposed' check (status in ('proposed', 'rejected', 'handoff', 'created', 'connected', 'disabled')),
  token_vault_ref text check (token_vault_ref is null or token_vault_ref ~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'),
  external_id text check (external_id is null or external_id ~ '^[A-Za-z0-9:._-]{1,120}$'),
  token_expires_at timestamptz,
  scopes text[] not null default '{}',
  proposed_by text not null default 'jarvis',
  decided_by text,
  decided_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create unique index if not exists hand_accounts_handle_idx on public.hand_accounts (connector, lower(handle));

create table if not exists public.hand_actions (
  id uuid primary key default gen_random_uuid(),
  connector text not null references public.hand_connectors(slug),
  account_id uuid references public.hand_accounts(id),
  division text not null check (division ~ '^[a-z][a-z0-9-]{1,39}$'),
  action text not null check (action in ('create_account', 'post', 'upload', 'send', 'update', 'deploy')),
  payload jsonb not null default '{}'::jsonb check (jsonb_typeof(payload) = 'object' and octet_length(payload::text) <= 20000),
  ai_generated boolean not null default true,
  status text not null default 'draft' check (status in ('draft', 'approved', 'scheduled', 'running', 'handoff', 'done', 'failed', 'rejected', 'cancelled', 'dry_run')),
  approval_kind text check (approval_kind is null or approval_kind in ('owner', 'standing', 'no_external_effect')),
  scheduled_at timestamptz,
  approved_by text,
  approved_at timestamptz,
  external_ref text check (external_ref is null or external_ref ~ '^[A-Za-z0-9:._/-]{1,200}$'),
  result text check (result is null or length(result) <= 300),
  attempts integer not null default 0,
  created_by text not null default 'jarvis',
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  finished_at timestamptz
);
create index if not exists hand_actions_status_idx on public.hand_actions (status, connector);

create table if not exists public.hand_standing (
  scope_kind text not null check (scope_kind in ('division', 'account')),
  scope_ref text not null check (length(scope_ref) between 2 and 60),
  enabled boolean not null default false,
  set_by text not null,
  set_at timestamptz not null default now(),
  primary key (scope_kind, scope_ref)
);

do $$
declare t text;
begin
  foreach t in array array['hand_connectors', 'hand_accounts', 'hand_actions', 'hand_standing'] loop
    execute format('alter table public.%I enable row level security', t);
    execute format('revoke all on public.%I from public, anon, authenticated, service_role', t);
  end loop;
end $$;
-- the bot reads; it writes only through the functions below
grant select on public.hand_connectors, public.hand_accounts, public.hand_actions, public.hand_standing to service_role;

-- the hands' spending identity: PAUSED, so the spend gateway (and therefore the executor gate) refuses it until the owner enables the hand
insert into public.agents (slug, title, charter, metric, daily_spend_cap_cents, status, role, model_tier, can_contact_owner)
values ('jarvis-hands', 'Jarvis hands', 'Runs owner-approved publishing actions through the executor gate (dormant until the owner enables it).', 'actions done', 100, 'paused', 'ops', 'cheap', false)
on conflict (slug) do nothing;

-- ---------------------------------------------------------------------------------------------------------------------------- owner-only controls
-- Registering 'hands-actions' is the ONLY way any action can run (executor_request refuses an unregistered or disabled executor).
create or replace function public.hands_owner_enable(p_enabled boolean, p_max_runs_per_day integer default 10, p_max_cents_per_run integer default 1) returns jsonb
language plpgsql security definer set search_path to 'public' as $$
begin
  perform public.jarvis_require_owner();
  if p_enabled is null or p_max_runs_per_day not between 0 and 200 or p_max_cents_per_run not between 1 and 100000 then raise exception 'hands_owner_enable: bad limits'; end if;
  insert into public.executor_registry (slug, kind, enabled, max_cents_per_run, max_runs_per_day, allowed_agents, note)
  values ('hands-actions', 'hands', p_enabled, p_max_cents_per_run, p_max_runs_per_day, array['jarvis-hands'], 'Jarvis hands (owner-enabled)')
  on conflict (slug) do update set enabled = excluded.enabled, max_cents_per_run = excluded.max_cents_per_run, max_runs_per_day = excluded.max_runs_per_day,
                                   allowed_agents = excluded.allowed_agents, kind = excluded.kind, note = excluded.note;
  update public.agents set status = case when p_enabled then 'active' else 'paused' end where slug = 'jarvis-hands';
  insert into public.audit_log (actor, action, target, detail) values ('owner', 'hands_enable', 'hands-actions',
    jsonb_build_object('enabled', p_enabled, 'max_runs_per_day', p_max_runs_per_day, 'max_cents_per_run', p_max_cents_per_run));
  return jsonb_build_object('ok', true, 'enabled', p_enabled);
end $$;
revoke all on function public.hands_owner_enable(boolean, integer, integer) from public, anon, authenticated;

create or replace function public.hands_owner_set_connector(p_slug text, p_enabled boolean, p_max_actions_per_day integer default null) returns jsonb
language plpgsql security definer set search_path to 'public' as $$
declare c public.hand_connectors;
begin
  perform public.jarvis_require_owner();
  update public.hand_connectors set enabled = coalesce(p_enabled, enabled), max_actions_per_day = coalesce(p_max_actions_per_day, max_actions_per_day),
         updated_at = now(), updated_by = 'owner'
   where slug = p_slug returning * into c;
  if c.slug is null then raise exception 'hands_owner_set_connector: unknown connector % (new services are adapters in code)', p_slug; end if;
  insert into public.audit_log (actor, action, target, detail) values ('owner', 'hands_connector_set', p_slug, jsonb_build_object('enabled', p_enabled, 'max_actions_per_day', p_max_actions_per_day));
  return to_jsonb(c);
end $$;
revoke all on function public.hands_owner_set_connector(text, boolean, integer) from public, anon, authenticated;

create or replace function public.hands_owner_set_standing(p_kind text, p_ref text, p_enabled boolean) returns jsonb
language plpgsql security definer set search_path to 'public' as $$
begin
  perform public.jarvis_require_owner();
  insert into public.hand_standing (scope_kind, scope_ref, enabled, set_by) values (p_kind, p_ref, coalesce(p_enabled, false), 'owner')
  on conflict (scope_kind, scope_ref) do update set enabled = excluded.enabled, set_by = 'owner', set_at = now();
  insert into public.audit_log (actor, action, target, detail) values ('owner', 'hands_standing_set', p_kind || ':' || p_ref, jsonb_build_object('enabled', p_enabled));
  return jsonb_build_object('ok', true, 'scope', p_kind || ':' || p_ref, 'enabled', coalesce(p_enabled, false));
end $$;
revoke all on function public.hands_owner_set_standing(text, text, boolean) from public, anon, authenticated;

-- ---------------------------------------------------------------------------------------------------------------------------- internal helpers
create or replace function public.hands_day_start() returns timestamptz
language sql stable set search_path to 'public' as $$ select (date_trunc('day', now() at time zone 'America/Toronto') at time zone 'America/Toronto') $$;
revoke all on function public.hands_day_start() from public, anon, authenticated;

-- release an approved action: create_account -> handoff to the owner (always); dry_run -> logged "would ...", nothing queued; hand off -> stays approved;
-- else queued for the worker
create or replace function public.hands_release(p_id uuid) returns jsonb
language plpgsql security definer set search_path to 'public' as $$
declare a public.hand_actions; c public.hand_connectors; v_mode text; v_on boolean; v_job uuid;
begin
  select * into a from public.hand_actions where id = p_id for update;
  -- never releases a draft: only an owner decision, an owner standing approval or the email draft path set approval_kind (callers are owner-checked)
  if a.id is null or a.approval_kind is null then raise exception 'hands_release: action is not approved' using errcode = '42501'; end if;
  select * into c from public.hand_connectors where slug = a.connector;
  if a.action = 'create_account' then
    update public.hand_actions set status = 'handoff', result = 'the owner signs up on the official page', updated_at = now() where id = p_id;
    update public.hand_accounts set status = 'handoff', updated_at = now() where id = a.account_id;
    insert into public.audit_log (actor, action, target, detail) values ('jarvis-hands', 'hands_handoff', a.connector, jsonb_build_object('action', p_id));
    return jsonb_build_object('ok', true, 'status', 'handoff', 'signup_url', c.signup_url);
  end if;
  select mode into v_mode from public.system_state where id = 1;
  if v_mode is null or v_mode = 'dry_run' then
    update public.hand_actions set status = 'dry_run', result = 'dry run: would ' || a.action || ' on ' || a.connector || '; nothing was sent', updated_at = now() where id = p_id;
    insert into public.audit_log (actor, action, target, detail) values ('jarvis-hands', 'hands_dry_run', a.connector, jsonb_build_object('action', p_id, 'kind', a.action));
    return jsonb_build_object('ok', true, 'status', 'dry_run');
  end if;
  select enabled into v_on from public.executor_registry where slug = 'hands-actions';
  if not coalesce(v_on, false) or not c.enabled then
    update public.hand_actions set status = 'approved', result = 'approved; waiting: the hand or the connector is switched off', updated_at = now() where id = p_id;
    return jsonb_build_object('ok', true, 'status', 'approved', 'queued', false, 'reason', 'hand or connector off');
  end if;
  v_job := public.jarvis_enqueue(a.division, 'hands.action', jsonb_build_object('action_id', p_id, 'external', true), 'normal',
                                 'hands:' || p_id::text || ':' || a.attempts, greatest(coalesce(a.scheduled_at, now()), now()), null, false, 3);
  update public.hand_actions set status = case when a.scheduled_at > now() then 'scheduled' else 'approved' end, result = null, updated_at = now() where id = p_id;
  return jsonb_build_object('ok', true, 'status', case when a.scheduled_at > now() then 'scheduled' else 'approved' end, 'queued', true, 'job', v_job);
end $$;
revoke all on function public.hands_release(uuid) from public, anon, authenticated, service_role;   -- internal (the lockdown file re-grants service_role on a fresh build: the guard above is the control)

create or replace function public.hands_ask_owner(p_id uuid, p_text text) returns void
language plpgsql security definer set search_path to 'public' as $$
begin
  insert into public.owner_messages (from_agent, kind, channel, body, needs_decision, ref_table, ref_id)
  values ('jarvis', 'proposal', 'telegram', left(p_text, 3900), true, 'hand_actions', p_id);
end $$;
revoke all on function public.hands_ask_owner(uuid, text) from public, anon, authenticated, service_role;

-- ---------------------------------------------------------------------------------------------------------------------------- bot-callable
-- Jarvis prepares an account for the owner to create himself (assisted only)
create or replace function public.hands_propose_account(p_connector text, p_division text, p_handle text, p_display_name text, p_purpose text, p_bio text default null,
                                                        p_asset_ref text default null, p_monthly_cents integer default 0, p_by text default 'jarvis') returns jsonb
language plpgsql security definer set search_path to 'public' as $$
declare c public.hand_connectors; v_acc uuid; v_act uuid; v_active text[];
begin
  select * into c from public.hand_connectors where slug = p_connector;
  if c.slug is null then return jsonb_build_object('ok', false, 'reason', 'unknown connector'); end if;
  if not c.enabled then return jsonb_build_object('ok', false, 'reason', 'connector ' || p_connector || ' is not on the owner allowlist (disabled)'); end if;
  if not ('create_account' = any (c.actions)) then return jsonb_build_object('ok', false, 'reason', 'connector ' || p_connector || ' has no account to create'); end if;
  select active_divisions into v_active from public.jarvis_core_config where id = 1;
  if not (p_division = any (coalesce(v_active, '{}'))) then return jsonb_build_object('ok', false, 'reason', 'division ' || p_division || ' is not active'); end if;
  if (select count(*) from public.hand_accounts where status = 'proposed') >= 5 then return jsonb_build_object('ok', false, 'reason', 'five proposals already wait for the owner'); end if;
  insert into public.hand_accounts (connector, division, handle, display_name, purpose, bio, asset_ref, monthly_cents, proposed_by)
  values (p_connector, p_division, p_handle, p_display_name, p_purpose, p_bio, p_asset_ref, coalesce(p_monthly_cents, 0), left(coalesce(p_by, 'jarvis'), 60)) returning id into v_acc;
  insert into public.hand_actions (connector, account_id, division, action, ai_generated, created_by)
  values (p_connector, v_acc, p_division, 'create_account', false, left(coalesce(p_by, 'jarvis'), 60)) returning id into v_act;
  perform public.hands_ask_owner(v_act, 'Sir, I propose a ' || c.title || ' account for ' || p_division || ': @' || p_handle
    || coalesce(' (' || p_display_name || ')', '') || '. Purpose: ' || p_purpose
    || '. If you approve, I send you the official sign-up page with everything prepared; you sign up yourself.'
    || case when coalesce(p_monthly_cents, 0) > 0 then ' Paid plan: ' || p_monthly_cents || ' cents/month (you pay; it goes through the spend gateway as a tool cost).' else ' Free.' end);
  insert into public.audit_log (actor, action, target, detail) values (left(coalesce(p_by, 'jarvis'), 60), 'hands_account_proposed', p_connector, jsonb_build_object('account', v_acc, 'action', v_act));
  return jsonb_build_object('ok', true, 'account_id', v_acc, 'action_id', v_act);
exception when unique_violation then
  return jsonb_build_object('ok', false, 'reason', 'that handle is already recorded for ' || p_connector);
end $$;
revoke all on function public.hands_propose_account(text, text, text, text, text, text, text, integer, text) from public, anon, authenticated;

create or replace function public.hands_submit_action(p_connector text, p_account uuid, p_action text, p_payload jsonb, p_scheduled_at timestamptz default null,
                                                      p_ai_generated boolean default true, p_by text default 'jarvis') returns jsonb
language plpgsql security definer set search_path to 'public' as $$
declare c public.hand_connectors; acc public.hand_accounts; v_id uuid; v_hits text[]; v_text text; v_kind text; v_div text; r jsonb;
begin
  select * into c from public.hand_connectors where slug = p_connector;
  if c.slug is null then return jsonb_build_object('ok', false, 'reason', 'unknown connector'); end if;
  if p_action = 'create_account' then return jsonb_build_object('ok', false, 'reason', 'use hands_propose_account'); end if;
  if not (p_action = any (c.actions)) then return jsonb_build_object('ok', false, 'reason', p_connector || ' does not allow ' || coalesce(p_action, '?')); end if;
  if p_payload is null or jsonb_typeof(p_payload) <> 'object' then return jsonb_build_object('ok', false, 'reason', 'payload must be an object'); end if;
  if p_account is not null then
    select * into acc from public.hand_accounts where id = p_account;
    if acc.id is null or acc.connector <> p_connector then return jsonb_build_object('ok', false, 'reason', 'account not found for this connector'); end if;
    if acc.status <> 'connected' then return jsonb_build_object('ok', false, 'reason', 'account is not connected (status ' || acc.status || ')'); end if;
    v_div := acc.division;
  elsif c.signup_mode = 'none' then
    v_div := coalesce(p_payload ->> 'division', 'donna');
  else
    return jsonb_build_object('ok', false, 'reason', 'an account is required');
  end if;
  if p_action in ('post', 'upload', 'update', 'deploy') then
    select string_agg(value, ' ') into v_text from jsonb_each_text(p_payload) where key in ('text', 'title', 'description', 'caption');
    v_hits := public.ws_sensitive_hits(coalesce(v_text, ''));
    if coalesce(array_length(v_hits, 1), 0) > 0 then
      insert into public.audit_log (actor, action, target, detail) values (left(coalesce(p_by, 'jarvis'), 60), 'hands_refused_pii', p_connector, jsonb_build_object('hits', v_hits));
      return jsonb_build_object('ok', false, 'reason', 'refused: the text looks like personal or sensitive data (' || array_to_string(v_hits, ', ') || ')');
    end if;
  end if;
  insert into public.hand_actions (connector, account_id, division, action, payload, ai_generated, scheduled_at, created_by)
  values (p_connector, p_account, v_div, p_action, p_payload - 'division', coalesce(p_ai_generated, true), p_scheduled_at, left(coalesce(p_by, 'jarvis'), 60)) returning id into v_id;
  insert into public.audit_log (actor, action, target, detail) values (left(coalesce(p_by, 'jarvis'), 60), 'hands_action_submitted', p_connector, jsonb_build_object('action', v_id, 'kind', p_action));
  -- the email connector only DRAFTS into the existing outbox (the outbox approval, consent and suppression gate the send): no separate tap
  if p_connector = 'email' and p_action = 'send' then v_kind := 'no_external_effect';
  elsif p_action in ('post', 'upload') and p_account is not null and exists (select 1 from public.hand_standing s where s.enabled
          and ((s.scope_kind = 'account' and s.scope_ref = p_account::text) or (s.scope_kind = 'division' and s.scope_ref = v_div))) then v_kind := 'standing';
  end if;
  if v_kind is not null then
    update public.hand_actions set approval_kind = v_kind, approved_by = v_kind, approved_at = now() where id = v_id;
    r := public.hands_release(v_id);
    return jsonb_build_object('ok', true, 'action_id', v_id, 'approval', v_kind) || r;
  end if;
  perform public.hands_ask_owner(v_id, 'Sir, ' || c.title || ' ' || p_action || ' for ' || v_div || coalesce(' @' || acc.handle, '')
    || coalesce(' at ' || to_char(p_scheduled_at at time zone 'America/Toronto', 'YYYY-MM-DD HH24:MI'), ', as soon as approved') || ':' || chr(10)
    || left(coalesce(p_payload ->> 'text', p_payload ->> 'title', p_payload ->> 'subject', '(no text)'), 1500)
    || case when coalesce(p_ai_generated, true) and c.ai_label <> 'none' then chr(10) || '(AI disclosure will be applied)' else '' end);
  return jsonb_build_object('ok', true, 'action_id', v_id, 'status', 'draft');
end $$;
revoke all on function public.hands_submit_action(text, uuid, text, jsonb, timestamptz, boolean, text) from public, anon, authenticated;

-- the owner's decision (Telegram one-tap or /approve, recorded by the bot's owner-only handlers)
create or replace function public.hands_decide(p_id uuid, p_approved boolean, p_by text) returns jsonb
language plpgsql security definer set search_path to 'public' as $$
declare a public.hand_actions;
begin
  if p_by is null or p_by !~ '^owner:' then raise exception 'hands_decide: only the owner decides' using errcode = '42501'; end if;
  select * into a from public.hand_actions where id = p_id for update;
  if a.id is null then return jsonb_build_object('ok', false, 'reason', 'not found'); end if;
  if a.status <> 'draft' then return jsonb_build_object('ok', false, 'reason', 'already ' || a.status); end if;
  insert into public.audit_log (actor, action, target, detail) values (p_by, case when p_approved then 'hands_approved' else 'hands_rejected' end, a.connector, jsonb_build_object('action', p_id, 'kind', a.action));
  if not coalesce(p_approved, false) then
    update public.hand_actions set status = 'rejected', approved_by = left(p_by, 60), approved_at = now(), updated_at = now() where id = p_id;
    if a.action = 'create_account' then update public.hand_accounts set status = 'rejected', decided_by = left(p_by, 60), decided_at = now(), updated_at = now() where id = a.account_id; end if;
    return jsonb_build_object('ok', true, 'status', 'rejected');
  end if;
  update public.hand_actions set approval_kind = 'owner', approved_by = left(p_by, 60), approved_at = now(), updated_at = now() where id = p_id;
  if a.action = 'create_account' then update public.hand_accounts set decided_by = left(p_by, 60), decided_at = now(), updated_at = now() where id = a.account_id; end if;
  return public.hands_release(p_id);
end $$;
revoke all on function public.hands_decide(uuid, boolean, text) from public, anon, authenticated;

-- /post <id>: run an approved (or dry-run, or failed) action again now
create or replace function public.hands_run_now(p_id uuid, p_by text) returns jsonb
language plpgsql security definer set search_path to 'public' as $$
declare a public.hand_actions;
begin
  if p_by is null or p_by !~ '^owner:' then raise exception 'hands_run_now: owner only' using errcode = '42501'; end if;
  select * into a from public.hand_actions where id = p_id for update;
  if a.id is null then return jsonb_build_object('ok', false, 'reason', 'not found'); end if;
  if a.action = 'create_account' then return jsonb_build_object('ok', false, 'reason', 'account creation is done by the owner'); end if;
  if a.status not in ('approved', 'scheduled', 'dry_run', 'failed') or a.approval_kind is null then return jsonb_build_object('ok', false, 'reason', 'status ' || a.status || ': approve it first'); end if;
  update public.hand_actions set scheduled_at = now(), attempts = attempts + 1, updated_at = now() where id = p_id;
  insert into public.audit_log (actor, action, target, detail) values (p_by, 'hands_run_now', a.connector, jsonb_build_object('action', p_id));
  return public.hands_release(p_id);
end $$;
revoke all on function public.hands_run_now(uuid, text) from public, anon, authenticated;

-- called by the worker before any external call: re-checks everything in one transaction and hands back what the adapter needs (vault REFERENCE only)
create or replace function public.hands_start(p_id uuid) returns jsonb
language plpgsql security definer set search_path to 'public' as $$
declare a public.hand_actions; c public.hand_connectors; acc public.hand_accounts; ss public.system_state; v_n integer; v_task uuid; v_when timestamptz; v_job uuid;
begin
  select * into a from public.hand_actions where id = p_id for update;
  if a.id is null then return jsonb_build_object('ok', false, 'reason', 'not found'); end if;
  if a.action = 'create_account' then return jsonb_build_object('ok', false, 'reason', 'account creation is done by the owner'); end if;
  if a.status not in ('approved', 'scheduled') or a.approval_kind is null then return jsonb_build_object('ok', false, 'reason', 'status ' || a.status); end if;
  select * into ss from public.system_state where id = 1;
  if coalesce(ss.kill_switch, true) then return jsonb_build_object('ok', false, 'reason', 'kill switch is on'); end if;
  if ss.mode is null or ss.mode = 'dry_run' then
    update public.hand_actions set status = 'dry_run', result = 'dry run: would ' || a.action || ' on ' || a.connector || '; nothing was sent', updated_at = now() where id = p_id;
    insert into public.audit_log (actor, action, target, detail) values ('jarvis-hands', 'hands_dry_run', a.connector, jsonb_build_object('action', p_id, 'kind', a.action));
    return jsonb_build_object('ok', false, 'dry_run', true, 'reason', 'dry run');
  end if;
  select * into c from public.hand_connectors where slug = a.connector;
  if not c.enabled then return jsonb_build_object('ok', false, 'reason', 'connector is disabled'); end if;
  if a.account_id is not null then
    select * into acc from public.hand_accounts where id = a.account_id;
    if acc.status <> 'connected' then return jsonb_build_object('ok', false, 'reason', 'account is not connected'); end if;
  end if;
  select count(*) into v_n from public.hand_actions where connector = a.connector and status in ('running', 'done') and updated_at >= public.hands_day_start() and action <> 'create_account';
  if v_n >= c.max_actions_per_day then   -- rate limit: deferred to tomorrow, nothing is sent today
    v_when := public.hands_day_start() + interval '1 day 5 minutes';
    v_job := public.jarvis_enqueue(a.division, 'hands.action', jsonb_build_object('action_id', p_id, 'external', true), 'normal', 'hands:' || p_id::text || ':' || to_char(v_when, 'YYYYMMDD'), v_when, null, false, 3);
    update public.hand_actions set status = 'scheduled', scheduled_at = v_when, result = 'rate limit reached; deferred to ' || to_char(v_when at time zone 'America/Toronto', 'YYYY-MM-DD HH24:MI'), updated_at = now() where id = p_id;
    insert into public.audit_log (actor, action, target, detail) values ('jarvis-hands', 'hands_rate_limited', a.connector, jsonb_build_object('action', p_id, 'until', v_when));
    return jsonb_build_object('ok', false, 'deferred', true, 'until', v_when);
  end if;
  insert into public.tasks (assigned_agent, created_by, title, status) values ('jarvis-hands', 'jarvis-hands', 'hands: ' || a.action || ' on ' || a.connector || ' (' || left(p_id::text, 8) || ')', 'doing') returning id into v_task;
  update public.hand_actions set status = 'running', attempts = attempts + 1, updated_at = now() where id = p_id;
  return jsonb_build_object('ok', true, 'task_id', v_task, 'action', to_jsonb(a) - 'status', 'connector', to_jsonb(c),
    'account', case when acc.id is null then null else to_jsonb(acc) end, 'est_cents', greatest(1, c.cost_cents_per_action));
end $$;
revoke all on function public.hands_start(uuid) from public, anon, authenticated;

create or replace function public.hands_finish(p_id uuid, p_status text, p_external_ref text default null, p_result text default null) returns jsonb
language plpgsql security definer set search_path to 'public' as $$
declare a public.hand_actions;
begin
  if p_status not in ('done', 'failed', 'dry_run') then raise exception 'hands_finish: bad status %', p_status; end if;
  select * into a from public.hand_actions where id = p_id for update;
  if a.id is null then raise exception 'hands_finish: unknown action'; end if;
  if a.status <> 'running' then raise exception 'hands_finish: action is %', a.status; end if;
  update public.hand_actions set status = p_status, external_ref = p_external_ref, result = left(p_result, 300), updated_at = now(), finished_at = now() where id = p_id;
  update public.tasks set status = case when p_status = 'failed' then 'cancelled' else 'done' end, result = left(coalesce(p_result, p_status), 300), updated_at = now()
   where assigned_agent = 'jarvis-hands' and status = 'doing' and title like '%(' || left(p_id::text, 8) || ')';
  insert into public.audit_log (actor, action, target, detail) values ('jarvis-hands', 'hands_' || p_status, a.connector,
    jsonb_build_object('action', p_id, 'kind', a.action, 'external_ref', p_external_ref));
  return jsonb_build_object('ok', true, 'status', p_status);
end $$;
revoke all on function public.hands_finish(uuid, text, text, text) from public, anon, authenticated;

-- the owner finished an assisted sign-up himself (/accounts done <id> [handle])
create or replace function public.hands_account_done(p_account uuid, p_handle text, p_by text) returns jsonb
language plpgsql security definer set search_path to 'public' as $$
declare acc public.hand_accounts;
begin
  if p_by is null or p_by !~ '^owner:' then raise exception 'hands_account_done: owner only' using errcode = '42501'; end if;
  select * into acc from public.hand_accounts where id = p_account for update;
  if acc.id is null then return jsonb_build_object('ok', false, 'reason', 'not found'); end if;
  if acc.status <> 'handoff' then return jsonb_build_object('ok', false, 'reason', 'status ' || acc.status); end if;
  update public.hand_accounts set status = 'created', handle = coalesce(nullif(p_handle, ''), handle), decided_by = left(p_by, 60), updated_at = now() where id = p_account;
  update public.hand_actions set status = 'done', result = 'created by the owner', finished_at = now(), updated_at = now()
   where account_id = p_account and action = 'create_account' and status = 'handoff';
  insert into public.audit_log (actor, action, target, detail) values (p_by, 'hands_account_done', acc.connector, jsonb_build_object('account', p_account));
  return jsonb_build_object('ok', true, 'status', 'created');
end $$;
revoke all on function public.hands_account_done(uuid, text, text) from public, anon, authenticated;

-- an official OAuth / API-key connection the owner completed: the token lives in the vault, only its reference is recorded
create or replace function public.hands_connect(p_connector text, p_division text, p_handle text, p_external_id text, p_token_vault_ref text,
                                                p_expires_at timestamptz default null, p_scopes text[] default '{}', p_by text default null) returns jsonb
language plpgsql security definer set search_path to 'public' as $$
declare v_id uuid; v_active text[];
begin
  if p_by is null or p_by !~ '^owner:' then raise exception 'hands_connect: only the owner connects an account' using errcode = '42501'; end if;
  if not exists (select 1 from public.hand_connectors where slug = p_connector and auth in ('oauth2', 'api_key')) then return jsonb_build_object('ok', false, 'reason', 'connector has no API connection'); end if;
  select active_divisions into v_active from public.jarvis_core_config where id = 1;
  if not (p_division = any (coalesce(v_active, '{}'))) then return jsonb_build_object('ok', false, 'reason', 'division ' || p_division || ' is not active'); end if;
  select id into v_id from public.hand_accounts where connector = p_connector and lower(handle) = lower(p_handle);
  if v_id is null then
    insert into public.hand_accounts (connector, division, handle, purpose, status, token_vault_ref, external_id, token_expires_at, scopes, proposed_by, decided_by, decided_at)
    values (p_connector, p_division, p_handle, 'connected by the owner', 'connected', p_token_vault_ref, p_external_id, p_expires_at, coalesce(p_scopes, '{}'), left(p_by, 60), left(p_by, 60), now())
    returning id into v_id;
  else
    update public.hand_accounts set status = 'connected', token_vault_ref = p_token_vault_ref, external_id = p_external_id, token_expires_at = p_expires_at,
           scopes = coalesce(p_scopes, '{}'), updated_at = now() where id = v_id;
  end if;
  insert into public.audit_log (actor, action, target, detail) values (p_by, 'hands_connected', p_connector, jsonb_build_object('account', v_id));
  return jsonb_build_object('ok', true, 'account_id', v_id);
end $$;
revoke all on function public.hands_connect(text, text, text, text, text, timestamptz, text[], text) from public, anon, authenticated;

-- token refresh: the worker replaces the vault reference (new vault entry) after refreshing a token through the platform's official token endpoint
create or replace function public.hands_token_refreshed(p_account uuid, p_token_vault_ref text, p_expires_at timestamptz) returns void
language plpgsql security definer set search_path to 'public' as $$
begin
  update public.hand_accounts set token_vault_ref = p_token_vault_ref, token_expires_at = p_expires_at, updated_at = now() where id = p_account and status = 'connected';
  if not found then raise exception 'hands_token_refreshed: account is not connected'; end if;
end $$;
revoke all on function public.hands_token_refreshed(uuid, text, timestamptz) from public, anon, authenticated;

-- ---------------------------------------------------------------------------------------------------------------------------- backup classification + export spec (PROTECTED: owner approval)
-- Same rows as 20261123_jarvis_core_v1 (unchanged, same order) plus the four hand_* tables, class internal (search_path as the post-lockdown file sets it).
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
    ('hand_actions', 'internal', 'action and content queue (payload free text is not exported)'), ('hand_standing', 'internal', 'owner standing approvals')
  ) v (table_name, data_class, note)
$$;
revoke all on function public.backup_classification() from public, anon, authenticated;
-- Same rows as 20261120_backup_redact_leak_paths_v1 (unchanged, same order) plus every text-like column of the hand_* tables. Free text (purpose, bio, payload,
-- results) is BLANK in the off-site export; identifiers, statuses and vault ids are kept; slugs are pseudonymised as everywhere else.
create or replace function public.backup_redaction_spec() returns table (table_name text, column_name text, kind text, mode text, max_len integer, reason text)
language sql immutable set search_path to 'pg_catalog' as $$
  select * from (values
    ('account_requests', 'account_login', 'text', 'keep', null, 'identifier, status, code, hash or the owner/business own setting; not free text'),
    ('account_requests', 'needs', 'array', 'keep', null, 'identifier, status, code, hash or the owner/business own setting; not free text'),
    ('account_requests', 'purpose', 'text', 'blank', null, 'agent / scraper / counterparty / unknown writer: free text is not exported (round 6)'),
    ('account_requests', 'requested_by', 'text', 'slug', null, 'identifier that can carry a venture / agent slug: a known client name inside it is exported as a keyed pseudonym (round 8, S1)'),
    ('account_requests', 'signup_url', 'text', 'blank', null, 'agent / scraper / counterparty / unknown writer: free text is not exported (round 6)'),
    ('account_requests', 'status', 'text', 'keep', null, 'identifier, status, code, hash or the owner/business own setting; not free text'),
    ('account_requests', 'vendor', 'text', 'blank', null, 'agent / scraper / counterparty / unknown writer: free text is not exported (round 6)'),
    ('accounts_registry', 'created_by', 'text', 'slug', null, 'identifier that can carry a venture / agent slug: a known client name inside it is exported as a keyed pseudonym (round 8, S1)'),
    ('accounts_registry', 'login_email', 'text', 'keep', null, 'identifier, status, code, hash or the owner/business own setting; not free text'),
    ('accounts_registry', 'notes', 'text', 'blank', null, 'agent / scraper / counterparty / unknown writer: free text is not exported (round 6)'),
    ('accounts_registry', 'purpose', 'text', 'blank', null, 'agent / scraper / counterparty / unknown writer: free text is not exported (round 6)'),
    ('accounts_registry', 'service', 'text', 'keep', null, 'identifier, status, code, hash or the owner/business own setting; not free text'),
    ('accounts_registry', 'status', 'text', 'keep', null, 'identifier, status, code, hash or the owner/business own setting; not free text'),
    ('accounts_registry', 'vault_ref', 'text', 'keep', null, 'identifier, status, code, hash or the owner/business own setting; not free text'),
    ('action_log', 'action', 'text', 'keep', null, 'identifier, status, code, hash or the owner/business own setting; not free text'),
    ('action_log', 'actor', 'text', 'slug', null, 'identifier that can carry a venture / agent slug: a known client name inside it is exported as a keyed pseudonym (round 8, S1)'),
    ('action_log', 'decision', 'text', 'keep', null, 'identifier, status, code, hash or the owner/business own setting; not free text'),
    ('action_log', 'detail', 'json', 'blank', null, 'BLANK: free text written by an agent, a scraper, a client or a counterparty cannot be made safe by pattern and known-name redaction (an unknown person''s name passes), so it is not exported; it restores as blank / NULL (see the policy, section 2, E)'),
    ('action_log', 'evidence', 'text', 'blank', null, 'BLANK: free text written by an agent, a scraper, a client or a counterparty cannot be made safe by pattern and known-name redaction (an unknown person''s name passes), so it is not exported; it restores as blank / NULL (see the policy, section 2, E)'),
    ('action_log', 'reason', 'text', 'blank', null, 'BLANK: free text written by an agent, a scraper, a client or a counterparty cannot be made safe by pattern and known-name redaction (an unknown person''s name passes), so it is not exported; it restores as blank / NULL (see the policy, section 2, E)'),
    ('action_log', 'ref', 'text', 'slug', null, 'identifier that can carry a venture / agent slug: a known client name inside it is exported as a keyed pseudonym (round 8, S1)'),
    ('action_log', 'result', 'text', 'blank', null, 'BLANK: free text written by an agent, a scraper, a client or a counterparty cannot be made safe by pattern and known-name redaction (an unknown person''s name passes), so it is not exported; it restores as blank / NULL (see the policy, section 2, E)'),
    ('action_log', 'tier', 'text', 'keep', null, 'identifier, status, code, hash or the owner/business own setting; not free text'),
    ('action_policy', 'action', 'text', 'keep', null, 'identifier, status, code, hash or the owner/business own setting; not free text'),
    ('action_policy', 'description', 'text', 'light', null, 'free text or title: patterns and known names only (never blanked)'),
    ('action_policy', 'tier', 'text', 'keep', null, 'identifier, status, code, hash or the owner/business own setting; not free text'),
    ('action_policy', 'updated_by', 'text', 'slug', null, 'identifier that can carry a venture / agent slug: a known client name inside it is exported as a keyed pseudonym (round 8, S1)'),
    ('agent_runs', 'status', 'text', 'keep', null, 'identifier, status, code, hash or the owner/business own setting; not free text'),
    ('agent_runs', 'summary', 'text', 'blank', null, 'BLANK: free text written by an agent, a scraper, a client or a counterparty cannot be made safe by pattern and known-name redaction (an unknown person''s name passes), so it is not exported; it restores as blank / NULL (see the policy, section 2, E)'),
    ('agents', 'charter', 'text', 'blank', null, 'written by an LLM tool (hq_start_venture / add_goal): free text is not exported (round 7, E2b)'),
    ('agents', 'department_slug', 'text', 'slug', null, 'identifier that can carry a venture / agent slug: a known client name inside it is exported as a keyed pseudonym (round 8, S1)'),
    ('agents', 'metric', 'text', 'blank', null, 'written by an LLM tool (hq_start_venture / add_goal): free text is not exported (round 7, E2b)'),
    ('agents', 'model_tier', 'text', 'keep', null, 'identifier, status, code, hash or the owner/business own setting; not free text'),
    ('agents', 'office_function', 'text', 'light', null, 'free text or title: patterns and known names only (never blanked)'),
    ('agents', 'role', 'text', 'keep', null, 'identifier, status, code, hash or the owner/business own setting; not free text'),
    ('agents', 'slug', 'text', 'slug', null, 'identifier that can carry a venture / agent slug: a known client name inside it is exported as a keyed pseudonym (round 8, S1)'),
    ('agents', 'status', 'text', 'keep', null, 'identifier, status, code, hash or the owner/business own setting; not free text'),
    ('agents', 'title', 'text', 'strict', 500, 'short label written by an LLM tool or owner command: strict redaction, owner decision whether to blank (round 7, E2b)'),
    ('alert_state', 'key', 'text', 'slug', null, 'identifier that can carry a venture / agent slug: a known client name inside it is exported as a keyed pseudonym (round 8, S1)'),
    ('app_owners', 'email', 'text', 'keep', null, 'identifier, status, code, hash or the owner/business own setting; not free text'),
    ('approval_requests', 'action', 'text', 'keep', null, 'identifier, status, code, hash or the owner/business own setting; not free text'),
    ('approval_requests', 'actor', 'text', 'slug', null, 'identifier that can carry a venture / agent slug: a known client name inside it is exported as a keyed pseudonym (round 8, S1)'),
    ('approval_requests', 'recommendation', 'text', 'blank', null, 'BLANK: free text written by an agent, a scraper, a client or a counterparty cannot be made safe by pattern and known-name redaction (an unknown person''s name passes), so it is not exported; it restores as blank / NULL (see the policy, section 2, E)'),
    ('approval_requests', 'ref', 'text', 'slug', null, 'identifier that can carry a venture / agent slug: a known client name inside it is exported as a keyed pseudonym (round 8, S1)'),
    ('approval_requests', 'status', 'text', 'keep', null, 'identifier, status, code, hash or the owner/business own setting; not free text'),
    ('audit_log', 'action', 'text', 'keep', null, 'identifier, status, code, hash or the owner/business own setting; not free text'),
    ('audit_log', 'actor', 'text', 'slug', null, 'identifier that can carry a venture / agent slug: a known client name inside it is exported as a keyed pseudonym (round 8, S1)'),
    ('audit_log', 'detail', 'json', 'strict', 500, 'free text copied from owner/agent actions (reason, notes)'),
    ('audit_log', 'target', 'text', 'slug', null, 'identifier that can carry a venture / agent slug: a known client name inside it is exported as a keyed pseudonym (round 8, S1)'),
    ('bank_accounts', 'currency', 'text', 'keep', null, 'identifier, status, code, hash or the owner/business own setting; not free text'),
    ('bank_accounts', 'institution', 'text', 'keep', null, 'identifier, status, code, hash or the owner/business own setting; not free text'),
    ('bank_accounts', 'label', 'text', 'light', null, 'free text or title: patterns and known names only (never blanked)'),
    ('bank_accounts', 'last4', 'text', 'keep', null, 'identifier, status, code, hash or the owner/business own setting; not free text'),
    ('bank_balances', 'entered_by', 'text', 'slug', null, 'identifier that can carry a venture / agent slug: a known client name inside it is exported as a keyed pseudonym (round 8, S1)'),
    ('bank_balances', 'source', 'text', 'light', null, 'free text or title: patterns and known names only (never blanked)'),
    ('bank_transactions', 'dedupe_key', 'text', 'slug', null, 'identifier that can carry a venture / agent slug: a known client name inside it is exported as a keyed pseudonym (round 8, S1)'),
    ('bank_transactions', 'description', 'text', 'blank', null, 'BLANK: free text written by an agent, a scraper, a client or a counterparty cannot be made safe by pattern and known-name redaction (an unknown person''s name passes), so it is not exported; it restores as blank / NULL (see the policy, section 2, E)'),
    ('bank_transactions', 'note', 'text', 'blank', null, 'BLANK: free text written by an agent, a scraper, a client or a counterparty cannot be made safe by pattern and known-name redaction (an unknown person''s name passes), so it is not exported; it restores as blank / NULL (see the policy, section 2, E)'),
    ('bank_transactions', 'status', 'text', 'keep', null, 'identifier, status, code, hash or the owner/business own setting; not free text'),
    ('build_requests', 'approved_by', 'text', 'slug', null, 'identifier that can carry a venture / agent slug: a known client name inside it is exported as a keyed pseudonym (round 8, S1)'),
    ('build_requests', 'qa_agent', 'text', 'slug', null, 'identifier that can carry a venture / agent slug: a known client name inside it is exported as a keyed pseudonym (round 8, S1)'),
    ('build_requests', 'requested_by', 'text', 'slug', null, 'identifier that can carry a venture / agent slug: a known client name inside it is exported as a keyed pseudonym (round 8, S1)'),
    ('build_requests', 'risk', 'text', 'blank', null, 'agent / scraper / counterparty / unknown writer: free text is not exported (round 6)'),
    ('build_requests', 'rollback_plan', 'text', 'blank', null, 'agent / scraper / counterparty / unknown writer: free text is not exported (round 6)'),
    ('build_requests', 'spec', 'text', 'blank', null, 'agent / scraper / counterparty / unknown writer: free text is not exported (round 6)'),
    ('build_requests', 'status', 'text', 'keep', null, 'identifier, status, code, hash or the owner/business own setting; not free text'),
    ('build_requests', 'test_result', 'text', 'blank', null, 'agent / scraper / counterparty / unknown writer: free text is not exported (round 6)'),
    ('build_requests', 'title', 'text', 'blank', null, 'agent / scraper / counterparty / unknown writer: free text is not exported (round 6)'),
    ('capital_policy', 'last_mode', 'text', 'light', null, 'free text or title: patterns and known names only (never blanked)'),
    ('capital_policy', 'updated_by', 'text', 'slug', null, 'identifier that can carry a venture / agent slug: a known client name inside it is exported as a keyed pseudonym (round 8, S1)'),
    ('company_profile', 'brand', 'text', 'light', null, 'free text or title: patterns and known names only (never blanked)'),
    ('company_profile', 'mailing_address', 'text', 'light', null, 'free text or title: patterns and known names only (never blanked)'),
    ('company_profile', 'reply_email', 'text', 'keep', null, 'identifier, status, code, hash or the owner/business own setting; not free text'),
    ('company_profile', 'sender_name', 'text', 'light', null, 'free text or title: patterns and known names only (never blanked)'),
    ('company_profile', 'venture_slug', 'text', 'slug', null, 'identifier that can carry a venture / agent slug: a known client name inside it is exported as a keyed pseudonym (round 8, S1)'),
    ('departments', 'kind', 'text', 'keep', null, 'identifier, status, code, hash or the owner/business own setting; not free text'),
    ('departments', 'name', 'text', 'strict', 500, 'short label written by an LLM tool or owner command: strict redaction, owner decision whether to blank (round 7, E2b)'),
    ('departments', 'slug', 'text', 'slug', null, 'identifier that can carry a venture / agent slug: a known client name inside it is exported as a keyed pseudonym (round 8, S1)'),
    ('departments', 'status', 'text', 'keep', null, 'identifier, status, code, hash or the owner/business own setting; not free text'),
    ('escalations', 'department_slug', 'text', 'slug', null, 'identifier that can carry a venture / agent slug: a known client name inside it is exported as a keyed pseudonym (round 8, S1)'),
    ('escalations', 'evidence', 'json', 'blank', null, 'BLANK: free text written by an agent, a scraper, a client or a counterparty cannot be made safe by pattern and known-name redaction (an unknown person''s name passes), so it is not exported; it restores as blank / NULL (see the policy, section 2, E)'),
    ('escalations', 'from_agent', 'text', 'slug', null, 'identifier that can carry a venture / agent slug: a known client name inside it is exported as a keyed pseudonym (round 8, S1)'),
    ('escalations', 'kind', 'text', 'keep', null, 'identifier, status, code, hash or the owner/business own setting; not free text'),
    ('escalations', 'resolution', 'text', 'blank', null, 'BLANK: free text written by an agent, a scraper, a client or a counterparty cannot be made safe by pattern and known-name redaction (an unknown person''s name passes), so it is not exported; it restores as blank / NULL (see the policy, section 2, E)'),
    ('escalations', 'status', 'text', 'keep', null, 'identifier, status, code, hash or the owner/business own setting; not free text'),
    ('escalations', 'summary', 'text', 'blank', null, 'BLANK: free text written by an agent, a scraper, a client or a counterparty cannot be made safe by pattern and known-name redaction (an unknown person''s name passes), so it is not exported; it restores as blank / NULL (see the policy, section 2, E)'),
    ('evidence_sources', 'content_sha256', 'text', 'keep', null, 'identifier, status, code, hash or the owner/business own setting; not free text'),
    ('evidence_sources', 'content_type', 'text', 'keep', null, 'identifier, status, code, hash or the owner/business own setting; not free text'),
    ('evidence_sources', 'final_url', 'text', 'blank', null, 'BLANK: free text written by an agent, a scraper, a client or a counterparty cannot be made safe by pattern and known-name redaction (an unknown person''s name passes), so it is not exported; it restores as blank / NULL (see the policy, section 2, E)'),
    ('evidence_sources', 'flags', 'json', 'keep', null, 'identifier, status, code, hash or the owner/business own setting; not free text'),
    ('evidence_sources', 'host_norm', 'text', 'slug', null, 'host name of a fetched page (can be a client''s own domain): a known client name inside it is exported as a keyed pseudonym (round 8, S1)'),
    ('evidence_sources', 'kind', 'text', 'keep', null, 'identifier, status, code, hash or the owner/business own setting; not free text'),
    ('evidence_sources', 'text', 'text', 'blank', null, 'public web page bodies (up to 40k chars each): bulk third-party text, rebuildable by re-fetching; not copied off-site (exported as an empty string; sha256 and url stay)'),
    ('evidence_sources', 'title', 'text', 'blank', null, 'BLANK: free text written by an agent, a scraper, a client or a counterparty cannot be made safe by pattern and known-name redaction (an unknown person''s name passes), so it is not exported; it restores as blank / NULL (see the policy, section 2, E)'),
    ('evidence_sources', 'url', 'text', 'blank', null, 'BLANK: free text written by an agent, a scraper, a client or a counterparty cannot be made safe by pattern and known-name redaction (an unknown person''s name passes), so it is not exported; it restores as blank / NULL (see the policy, section 2, E)'),
    ('executor_registry', 'allowed_agents', 'array', 'slug', null, 'identifier that can carry a venture / agent slug: a known client name inside it is exported as a keyed pseudonym (round 8, S1)'),
    ('executor_registry', 'kind', 'text', 'keep', null, 'identifier, status, code, hash or the owner/business own setting; not free text'),
    ('executor_registry', 'note', 'text', 'light', null, 'free text or title: patterns and known names only (never blanked)'),
    ('executor_registry', 'slug', 'text', 'slug', null, 'identifier that can carry a venture / agent slug: a known client name inside it is exported as a keyed pseudonym (round 8, S1)'),
    ('executor_runs', 'agent_slug', 'text', 'slug', null, 'identifier that can carry a venture / agent slug: a known client name inside it is exported as a keyed pseudonym (round 8, S1)'),
    ('executor_runs', 'executor', 'text', 'light', null, 'free text or title: patterns and known names only (never blanked)'),
    ('executor_runs', 'purpose', 'text', 'blank', null, 'BLANK: free text written by an agent, a scraper, a client or a counterparty cannot be made safe by pattern and known-name redaction (an unknown person''s name passes), so it is not exported; it restores as blank / NULL (see the policy, section 2, E)'),
    ('executor_runs', 'refusal_reason', 'text', 'blank', null, 'BLANK: free text written by an agent, a scraper, a client or a counterparty cannot be made safe by pattern and known-name redaction (an unknown person''s name passes), so it is not exported; it restores as blank / NULL (see the policy, section 2, E)'),
    ('executor_runs', 'result_sha256', 'text', 'keep', null, 'identifier, status, code, hash or the owner/business own setting; not free text'),
    ('executor_runs', 'status', 'text', 'keep', null, 'identifier, status, code, hash or the owner/business own setting; not free text'),
    ('handbook', 'content', 'text', 'light', null, 'free text or title: patterns and known names only (never blanked)'),
    ('human_handoffs', 'requested_by', 'text', 'slug', null, 'identifier that can carry a venture / agent slug: a known client name inside it is exported as a keyed pseudonym (round 8, S1)'),
    ('human_handoffs', 'status', 'text', 'keep', null, 'identifier, status, code, hash or the owner/business own setting; not free text'),
    ('human_handoffs', 'task', 'text', 'blank', null, 'BLANK: free text written by an agent, a scraper, a client or a counterparty cannot be made safe by pattern and known-name redaction (an unknown person''s name passes), so it is not exported; it restores as blank / NULL (see the policy, section 2, E)'),
    ('human_handoffs', 'url', 'text', 'blank', null, 'BLANK: free text written by an agent, a scraper, a client or a counterparty cannot be made safe by pattern and known-name redaction (an unknown person''s name passes), so it is not exported; it restores as blank / NULL (see the policy, section 2, E)'),
    ('human_handoffs', 'why_human', 'text', 'blank', null, 'BLANK: free text written by an agent, a scraper, a client or a counterparty cannot be made safe by pattern and known-name redaction (an unknown person''s name passes), so it is not exported; it restores as blank / NULL (see the policy, section 2, E)'),
    ('ideas', 'demand_source', 'text', 'blank', null, 'BLANK: free text written by an agent, a scraper, a client or a counterparty cannot be made safe by pattern and known-name redaction (an unknown person''s name passes), so it is not exported; it restores as blank / NULL (see the policy, section 2, E)'),
    ('ideas', 'description', 'text', 'blank', null, 'BLANK: free text written by an agent, a scraper, a client or a counterparty cannot be made safe by pattern and known-name redaction (an unknown person''s name passes), so it is not exported; it restores as blank / NULL (see the policy, section 2, E)'),
    ('ideas', 'kill_metric', 'text', 'blank', null, 'BLANK: free text written by an agent, a scraper, a client or a counterparty cannot be made safe by pattern and known-name redaction (an unknown person''s name passes), so it is not exported; it restores as blank / NULL (see the policy, section 2, E)'),
    ('ideas', 'name', 'text', 'blank', null, 'agent / scraper / counterparty / unknown writer: free text is not exported (round 6)'),
    ('ideas', 'result', 'text', 'blank', null, 'BLANK: free text written by an agent, a scraper, a client or a counterparty cannot be made safe by pattern and known-name redaction (an unknown person''s name passes), so it is not exported; it restores as blank / NULL (see the policy, section 2, E)'),
    ('ideas', 'revisit_trigger', 'text', 'blank', null, 'BLANK: free text written by an agent, a scraper, a client or a counterparty cannot be made safe by pattern and known-name redaction (an unknown person''s name passes), so it is not exported; it restores as blank / NULL (see the policy, section 2, E)'),
    ('ideas', 'status', 'text', 'keep', null, 'identifier, status, code, hash or the owner/business own setting; not free text'),
    ('ideas', 'verdict', 'text', 'keep', null, 'identifier, status, code, hash or the owner/business own setting; not free text'),
    ('integration_status', 'detail', 'text', 'blank', null, 'agent / scraper / counterparty / unknown writer: free text is not exported (round 6)'),
    ('integration_status', 'key', 'text', 'slug', null, 'identifier that can carry a venture / agent slug: a known client name inside it is exported as a keyed pseudonym (round 8, S1)'),
    ('ledger', 'currency', 'text', 'keep', null, 'identifier, status, code, hash or the owner/business own setting; not free text'),
    ('ledger', 'kind', 'text', 'keep', null, 'identifier, status, code, hash or the owner/business own setting; not free text'),
    ('ledger', 'note', 'text', 'strict', 500, 'free text; names of payers/payees and setters'),
    ('ledger', 'original_currency', 'text', 'keep', null, 'identifier, status, code, hash or the owner/business own setting; not free text'),
    ('ledger', 'status', 'text', 'keep', null, 'identifier, status, code, hash or the owner/business own setting; not free text'),
    ('llm_calls', 'agent_slug', 'text', 'slug', null, 'identifier that can carry a venture / agent slug: a known client name inside it is exported as a keyed pseudonym (round 8, S1)'),
    ('llm_calls', 'model', 'text', 'keep', null, 'identifier, status, code, hash or the owner/business own setting; not free text'),
    ('llm_calls', 'purpose', 'text', 'blank', null, 'agent / scraper / counterparty / unknown writer: free text is not exported (round 6)'),
    ('llm_calls', 'status', 'text', 'keep', null, 'identifier, status, code, hash or the owner/business own setting; not free text'),
    ('memory', 'agent', 'text', 'slug', null, 'identifier that can carry a venture / agent slug: a known client name inside it is exported as a keyed pseudonym (round 8, S1)'),
    ('memory', 'confidence', 'text', 'keep', null, 'identifier, status, code, hash or the owner/business own setting; not free text'),
    ('memory', 'content', 'text', 'blank', null, 'BLANK: free text written by an agent, a scraper, a client or a counterparty cannot be made safe by pattern and known-name redaction (an unknown person''s name passes), so it is not exported; it restores as blank / NULL (see the policy, section 2, E)'),
    ('memory', 'kind', 'text', 'keep', null, 'identifier, status, code, hash or the owner/business own setting; not free text'),
    ('memory', 'source', 'text', 'blank', null, 'BLANK: free text written by an agent, a scraper, a client or a counterparty cannot be made safe by pattern and known-name redaction (an unknown person''s name passes), so it is not exported; it restores as blank / NULL (see the policy, section 2, E)'),
    ('mission_outcomes', 'verdict', 'text', 'keep', null, 'identifier, status, code, hash or the owner/business own setting; not free text'),
    ('missions', 'checkpoint', 'json', 'blank', null, 'BLANK: free text written by an agent, a scraper, a client or a counterparty cannot be made safe by pattern and known-name redaction (an unknown person''s name passes), so it is not exported; it restores as blank / NULL (see the policy, section 2, E)'),
    ('missions', 'created_by', 'text', 'slug', null, 'identifier that can carry a venture / agent slug: a known client name inside it is exported as a keyed pseudonym (round 8, S1)'),
    ('missions', 'evidence', 'json', 'blank', null, 'BLANK: free text written by an agent, a scraper, a client or a counterparty cannot be made safe by pattern and known-name redaction (an unknown person''s name passes), so it is not exported; it restores as blank / NULL (see the policy, section 2, E)'),
    ('missions', 'next_action', 'text', 'blank', null, 'BLANK: free text written by an agent, a scraper, a client or a counterparty cannot be made safe by pattern and known-name redaction (an unknown person''s name passes), so it is not exported; it restores as blank / NULL (see the policy, section 2, E)'),
    ('missions', 'objective', 'text', 'blank', null, 'written by an LLM tool too (hq_start_venture copies the venture description, which is blank in ventures, into the objective): free text is not exported (round 8, N4)'),
    ('missions', 'owner_decision', 'text', 'blank', null, 'BLANK: free text written by an agent, a scraper, a client or a counterparty cannot be made safe by pattern and known-name redaction (an unknown person''s name passes), so it is not exported; it restores as blank / NULL (see the policy, section 2, E)'),
    ('missions', 'plan', 'json', 'blank', null, 'BLANK: free text written by an agent, a scraper, a client or a counterparty cannot be made safe by pattern and known-name redaction (an unknown person''s name passes), so it is not exported; it restores as blank / NULL (see the policy, section 2, E)'),
    ('missions', 'result', 'text', 'blank', null, 'BLANK: free text written by an agent, a scraper, a client or a counterparty cannot be made safe by pattern and known-name redaction (an unknown person''s name passes), so it is not exported; it restores as blank / NULL (see the policy, section 2, E)'),
    ('missions', 'risks', 'text', 'blank', null, 'BLANK: free text written by an agent, a scraper, a client or a counterparty cannot be made safe by pattern and known-name redaction (an unknown person''s name passes), so it is not exported; it restores as blank / NULL (see the policy, section 2, E)'),
    ('missions', 'status', 'text', 'keep', null, 'identifier, status, code, hash or the owner/business own setting; not free text'),
    ('missions', 'success_definition', 'text', 'blank', null, 'BLANK: free text written by an agent, a scraper, a client or a counterparty cannot be made safe by pattern and known-name redaction (an unknown person''s name passes), so it is not exported; it restores as blank / NULL (see the policy, section 2, E)'),
    ('missions', 'title', 'text', 'strict', 500, 'owner-typed mission text'),
    ('missions', 'verdict', 'text', 'keep', null, 'identifier, status, code, hash or the owner/business own setting; not free text'),
    ('missions', 'verdict_reason', 'text', 'blank', null, 'BLANK: free text written by an agent, a scraper, a client or a counterparty cannot be made safe by pattern and known-name redaction (an unknown person''s name passes), so it is not exported; it restores as blank / NULL (see the policy, section 2, E)'),
    ('model_prices', 'model', 'text', 'keep', null, 'identifier, status, code, hash or the owner/business own setting; not free text'),
    ('model_prices', 'source', 'text', 'light', null, 'free text or title: patterns and known names only (never blanked)'),
    ('model_prices', 'tier', 'text', 'keep', null, 'identifier, status, code, hash or the owner/business own setting; not free text'),
    ('org_changes', 'alternatives', 'text', 'blank', null, 'agent / scraper / counterparty / unknown writer: free text is not exported (round 6)'),
    ('org_changes', 'change', 'text', 'blank', null, 'agent / scraper / counterparty / unknown writer: free text is not exported (round 6)'),
    ('org_changes', 'cost', 'text', 'blank', null, 'agent / scraper / counterparty / unknown writer: free text is not exported (round 6)'),
    ('org_changes', 'disagrees_with_owner', 'text', 'blank', null, 'agent / scraper / counterparty / unknown writer: free text is not exported (round 6)'),
    ('org_changes', 'gain', 'text', 'blank', null, 'agent / scraper / counterparty / unknown writer: free text is not exported (round 6)'),
    ('org_changes', 'kind', 'text', 'keep', null, 'identifier, status, code, hash or the owner/business own setting; not free text'),
    ('org_changes', 'proposed_by', 'text', 'slug', null, 'identifier that can carry a venture / agent slug: a known client name inside it is exported as a keyed pseudonym (round 8, S1)'),
    ('org_changes', 'risk', 'text', 'blank', null, 'agent / scraper / counterparty / unknown writer: free text is not exported (round 6)'),
    ('org_changes', 'status', 'text', 'keep', null, 'identifier, status, code, hash or the owner/business own setting; not free text'),
    ('org_changes', 'target', 'text', 'blank', null, 'agent / scraper / counterparty / unknown writer: free text is not exported (round 6)'),
    ('org_changes', 'time_to_results', 'text', 'blank', null, 'agent / scraper / counterparty / unknown writer: free text is not exported (round 6)'),
    ('owner_messages', 'answer', 'text', 'blank', null, 'BLANK: free text written by an agent, a scraper, a client or a counterparty cannot be made safe by pattern and known-name redaction (an unknown person''s name passes), so it is not exported; it restores as blank / NULL (see the policy, section 2, E)'),
    ('owner_messages', 'body', 'text', 'blank', null, 'BLANK: free text written by an agent, a scraper, a client or a counterparty cannot be made safe by pattern and known-name redaction (an unknown person''s name passes), so it is not exported; it restores as blank / NULL (see the policy, section 2, E)'),
    ('owner_messages', 'channel', 'text', 'keep', null, 'identifier, status, code, hash or the owner/business own setting; not free text'),
    ('owner_messages', 'decision', 'text', 'keep', null, 'identifier, status, code, hash or the owner/business own setting; not free text'),
    ('owner_messages', 'from_agent', 'text', 'slug', null, 'identifier that can carry a venture / agent slug: a known client name inside it is exported as a keyed pseudonym (round 8, S1)'),
    ('owner_messages', 'kind', 'text', 'keep', null, 'identifier, status, code, hash or the owner/business own setting; not free text'),
    ('owner_messages', 'options', 'json', 'blank', null, 'BLANK: free text written by an agent, a scraper, a client or a counterparty cannot be made safe by pattern and known-name redaction (an unknown person''s name passes), so it is not exported; it restores as blank / NULL (see the policy, section 2, E)'),
    ('owner_messages', 'ref_table', 'text', 'slug', null, 'identifier that can carry a venture / agent slug: a known client name inside it is exported as a keyed pseudonym (round 8, S1)'),
    ('payment_instructions', 'payee', 'text', 'blank', null, 'BLANK: free text written by an agent, a scraper, a client or a counterparty cannot be made safe by pattern and known-name redaction (an unknown person''s name passes), so it is not exported; it restores as blank / NULL (see the policy, section 2, E)'),
    ('payment_instructions', 'purpose', 'text', 'blank', null, 'agent / scraper / counterparty / unknown writer: free text is not exported (round 6)'),
    ('payment_instructions', 'receipt_ref', 'text', 'blank', null, 'agent / scraper / counterparty / unknown writer: free text is not exported (round 6)'),
    ('payment_instructions', 'requested_by', 'text', 'slug', null, 'identifier that can carry a venture / agent slug: a known client name inside it is exported as a keyed pseudonym (round 8, S1)'),
    ('payment_instructions', 'status', 'text', 'keep', null, 'identifier, status, code, hash or the owner/business own setting; not free text'),
    ('predictions', 'action_ref', 'text', 'blank', null, 'BLANK: free text written by an agent, a scraper, a client or a counterparty cannot be made safe by pattern and known-name redaction (an unknown person''s name passes), so it is not exported; it restores as blank / NULL (see the policy, section 2, E)'),
    ('predictions', 'agent_slug', 'text', 'slug', null, 'identifier that can carry a venture / agent slug: a known client name inside it is exported as a keyed pseudonym (round 8, S1)'),
    ('predictions', 'expected', 'text', 'blank', null, 'BLANK: free text written by an agent, a scraper, a client or a counterparty cannot be made safe by pattern and known-name redaction (an unknown person''s name passes), so it is not exported; it restores as blank / NULL (see the policy, section 2, E)'),
    ('predictions', 'outcome', 'text', 'blank', null, 'BLANK: free text written by an agent, a scraper, a client or a counterparty cannot be made safe by pattern and known-name redaction (an unknown person''s name passes), so it is not exported; it restores as blank / NULL (see the policy, section 2, E)'),
    ('reconciliation_flags', 'check_name', 'text', 'keep', null, 'identifier, status, code, hash or the owner/business own setting; not free text'),
    ('reconciliation_flags', 'detail', 'text', 'blank', null, 'BLANK: free text written by an agent, a scraper, a client or a counterparty cannot be made safe by pattern and known-name redaction (an unknown person''s name passes), so it is not exported; it restores as blank / NULL (see the policy, section 2, E)'),
    ('reconciliation_flags', 'status', 'text', 'keep', null, 'identifier, status, code, hash or the owner/business own setting; not free text'),
    ('spend_reservations', 'action', 'text', 'keep', null, 'identifier, status, code, hash or the owner/business own setting; not free text'),
    ('spend_reservations', 'actor', 'text', 'slug', null, 'identifier that can carry a venture / agent slug: a known client name inside it is exported as a keyed pseudonym (round 8, S1)'),
    ('spend_reservations', 'alternatives', 'text', 'blank', null, 'agent / scraper / counterparty / unknown writer: free text is not exported (round 6)'),
    ('spend_reservations', 'expected_benefit', 'text', 'blank', null, 'agent / scraper / counterparty / unknown writer: free text is not exported (round 6)'),
    ('spend_reservations', 'purpose', 'text', 'blank', null, 'agent / scraper / counterparty / unknown writer: free text is not exported (round 6)'),
    ('spend_reservations', 'receipt_ref', 'text', 'blank', null, 'agent / scraper / counterparty / unknown writer: free text is not exported (round 6)'),
    ('spend_reservations', 'status', 'text', 'keep', null, 'identifier, status, code, hash or the owner/business own setting; not free text'),
    ('spend_reservations', 'vendor', 'text', 'blank', null, 'agent / scraper / counterparty / unknown writer: free text is not exported (round 6)'),
    ('system_state', 'mode', 'text', 'keep', null, 'identifier, status, code, hash or the owner/business own setting; not free text'),
    ('system_state', 'pause_reason', 'text', 'blank', null, 'agent / scraper / counterparty / unknown writer: free text is not exported (round 6)'),
    ('systems', 'data_store', 'text', 'light', null, 'free text or title: patterns and known names only (never blanked)'),
    ('systems', 'health_url', 'text', 'light', null, 'free text or title: patterns and known names only (never blanked)'),
    ('systems', 'host', 'text', 'light', null, 'free text or title: patterns and known names only (never blanked)'),
    ('systems', 'name', 'text', 'light', null, 'free text or title: patterns and known names only (never blanked)'),
    ('systems', 'notes', 'text', 'blank', null, 'agent / scraper / counterparty / unknown writer: free text is not exported (round 6)'),
    ('systems', 'repo', 'text', 'light', null, 'free text or title: patterns and known names only (never blanked)'),
    ('systems', 'slug', 'text', 'slug', null, 'identifier that can carry a venture / agent slug: a known client name inside it is exported as a keyed pseudonym (round 8, S1)'),
    ('systems', 'url', 'text', 'light', null, 'free text or title: patterns and known names only (never blanked)'),
    ('systems', 'venture_slug', 'text', 'slug', null, 'identifier that can carry a venture / agent slug: a known client name inside it is exported as a keyed pseudonym (round 8, S1)'),
    ('systems', 'warmup_local_times', 'array', 'keep', null, 'identifier, status, code, hash or the owner/business own setting; not free text'),
    ('tasks', 'assigned_agent', 'text', 'slug', null, 'identifier that can carry a venture / agent slug: a known client name inside it is exported as a keyed pseudonym (round 8, S1)'),
    ('tasks', 'created_by', 'text', 'slug', null, 'identifier that can carry a venture / agent slug: a known client name inside it is exported as a keyed pseudonym (round 8, S1)'),
    ('tasks', 'dedupe_key', 'text', 'slug', null, 'identifier that can carry a venture / agent slug: a known client name inside it is exported as a keyed pseudonym (round 8, S1)'),
    ('tasks', 'detail', 'text', 'blank', null, 'BLANK: free text written by an agent, a scraper, a client or a counterparty cannot be made safe by pattern and known-name redaction (an unknown person''s name passes), so it is not exported; it restores as blank / NULL (see the policy, section 2, E)'),
    ('tasks', 'mission_role', 'text', 'keep', null, 'identifier, status, code, hash or the owner/business own setting; not free text'),
    ('tasks', 'result', 'text', 'blank', null, 'BLANK: free text written by an agent, a scraper, a client or a counterparty cannot be made safe by pattern and known-name redaction (an unknown person''s name passes), so it is not exported; it restores as blank / NULL (see the policy, section 2, E)'),
    ('tasks', 'status', 'text', 'keep', null, 'identifier, status, code, hash or the owner/business own setting; not free text'),
    ('tasks', 'title', 'text', 'blank', null, 'BLANK: free text written by an agent, a scraper, a client or a counterparty cannot be made safe by pattern and known-name redaction (an unknown person''s name passes), so it is not exported; it restores as blank / NULL (see the policy, section 2, E)'),
    ('tool_registry', 'currency', 'text', 'keep', null, 'identifier, status, code, hash or the owner/business own setting; not free text'),
    ('tool_registry', 'kind', 'text', 'keep', null, 'identifier, status, code, hash or the owner/business own setting; not free text'),
    ('tool_registry', 'notes', 'text', 'blank', null, 'agent / scraper / counterparty / unknown writer: free text is not exported (round 6)'),
    ('tool_registry', 'owner_agent', 'text', 'slug', null, 'identifier that can carry a venture / agent slug: a known client name inside it is exported as a keyed pseudonym (round 8, S1)'),
    ('tool_registry', 'purpose', 'text', 'blank', null, 'agent / scraper / counterparty / unknown writer: free text is not exported (round 6)'),
    ('tool_registry', 'slug', 'text', 'slug', null, 'identifier that can carry a venture / agent slug: a known client name inside it is exported as a keyed pseudonym (round 8, S1)'),
    ('tool_registry', 'status', 'text', 'keep', null, 'identifier, status, code, hash or the owner/business own setting; not free text'),
    ('venture_assets', 'created_by', 'text', 'slug', null, 'identifier that can carry a venture / agent slug: a known client name inside it is exported as a keyed pseudonym (round 8, S1)'),
    ('venture_assets', 'kind', 'text', 'keep', null, 'identifier, status, code, hash or the owner/business own setting; not free text'),
    ('venture_assets', 'name', 'text', 'blank', null, 'agent / scraper / counterparty / unknown writer: free text is not exported (round 6)'),
    ('venture_assets', 'notes', 'text', 'blank', null, 'agent / scraper / counterparty / unknown writer: free text is not exported (round 6)'),
    ('venture_assets', 'status', 'text', 'keep', null, 'identifier, status, code, hash or the owner/business own setting; not free text'),
    ('venture_assets', 'url', 'text', 'blank', null, 'agent / scraper / counterparty / unknown writer: free text is not exported (round 6)'),
    ('venture_config', 'call_to_action', 'text', 'strict', 500, 'short label written by an LLM tool or owner command: strict redaction, owner decision whether to blank (round 7, E2b)'),
    ('venture_config', 'offer', 'text', 'strict', 500, 'short label written by an LLM tool or owner command: strict redaction, owner decision whether to blank (round 7, E2b)'),
    ('venture_config', 'updated_by', 'text', 'slug', null, 'identifier that can carry a venture / agent slug: a known client name inside it is exported as a keyed pseudonym (round 8, S1)'),
    ('venture_goals', 'created_by', 'text', 'slug', null, 'identifier that can carry a venture / agent slug: a known client name inside it is exported as a keyed pseudonym (round 8, S1)'),
    ('venture_goals', 'metric', 'text', 'blank', null, 'written by an LLM tool (hq_start_venture / add_goal): free text is not exported (round 7, E2b)'),
    ('venture_goals', 'status', 'text', 'keep', null, 'identifier, status, code, hash or the owner/business own setting; not free text'),
    ('venture_goals', 'unit', 'text', 'strict', 500, 'short label written by an LLM tool or owner command: strict redaction, owner decision whether to blank (round 7, E2b)'),
    ('venture_procedures', 'created_by', 'text', 'slug', null, 'identifier that can carry a venture / agent slug: a known client name inside it is exported as a keyed pseudonym (round 8, S1)'),
    ('venture_procedures', 'owner_agent', 'text', 'slug', null, 'identifier that can carry a venture / agent slug: a known client name inside it is exported as a keyed pseudonym (round 8, S1)'),
    ('venture_procedures', 'status', 'text', 'keep', null, 'identifier, status, code, hash or the owner/business own setting; not free text'),
    ('venture_procedures', 'steps', 'text', 'blank', null, 'agent / scraper / counterparty / unknown writer: free text is not exported (round 6)'),
    ('venture_procedures', 'title', 'text', 'slug', null, 'identifier that can carry a venture / agent slug: a known client name inside it is exported as a keyed pseudonym (round 8, S1)'),
    ('ventures', 'description', 'text', 'blank', null, 'written by an LLM tool (hq_start_venture / add_goal): free text is not exported (round 7, E2b)'),
    ('ventures', 'gate_criteria', 'text', 'light', null, 'free text or title: patterns and known names only (never blanked)'),
    ('ventures', 'kind', 'text', 'keep', null, 'identifier, status, code, hash or the owner/business own setting; not free text'),
    ('ventures', 'manager_agent', 'text', 'slug', null, 'identifier that can carry a venture / agent slug: a known client name inside it is exported as a keyed pseudonym (round 8, S1)'),
    ('ventures', 'name', 'text', 'strict', 500, 'short label written by an LLM tool or owner command: strict redaction, owner decision whether to blank (round 7, E2b)'),
    ('ventures', 'primary_metric', 'text', 'blank', null, 'written by an LLM tool (hq_start_venture / add_goal): free text is not exported (round 7, E2b)'),
    ('ventures', 'proposed_by', 'text', 'slug', null, 'identifier that can carry a venture / agent slug: a known client name inside it is exported as a keyed pseudonym (round 8, S1)'),
    ('ventures', 'slug', 'text', 'slug', null, 'identifier that can carry a venture / agent slug: a known client name inside it is exported as a keyed pseudonym (round 8, S1)'),
    ('ventures', 'stage', 'text', 'keep', null, 'identifier, status, code, hash or the owner/business own setting; not free text'),
    ('ventures', 'status', 'text', 'keep', null, 'identifier, status, code, hash or the owner/business own setting; not free text'),
    ('waterfall_policy', 'updated_by', 'text', 'slug', null, 'identifier that can carry a venture / agent slug: a known client name inside it is exported as a keyed pseudonym (round 8, S1)'),
    ('web_messages', 'body', 'text', 'blank', null, 'BLANK: free text written by an agent, a scraper, a client or a counterparty cannot be made safe by pattern and known-name redaction (an unknown person''s name passes), so it is not exported; it restores as blank / NULL (see the policy, section 2, E)'),
    ('web_messages', 'kind', 'text', 'keep', null, 'identifier, status, code, hash or the owner/business own setting; not free text'),
    ('web_messages', 'payload', 'json', 'blank', null, 'BLANK: free text written by an agent, a scraper, a client or a counterparty cannot be made safe by pattern and known-name redaction (an unknown person''s name passes), so it is not exported; it restores as blank / NULL (see the policy, section 2, E)'),
    ('web_messages', 'role', 'text', 'keep', null, 'identifier, status, code, hash or the owner/business own setting; not free text'),
    ('web_messages', 'status', 'text', 'keep', null, 'identifier, status, code, hash or the owner/business own setting; not free text'),
    -- Jarvis hands v1 (20261124)
    ('hand_connectors', 'slug', 'text', 'keep', null, 'identifier, status, code, hash or the owner/business own setting; not free text'),
    ('hand_connectors', 'title', 'text', 'keep', null, 'identifier, status, code, hash or the owner/business own setting; not free text'),
    ('hand_connectors', 'auth', 'text', 'keep', null, 'identifier, status, code, hash or the owner/business own setting; not free text'),
    ('hand_connectors', 'actions', 'array', 'keep', null, 'identifier, status, code, hash or the owner/business own setting; not free text'),
    ('hand_connectors', 'signup_mode', 'text', 'keep', null, 'identifier, status, code, hash or the owner/business own setting; not free text'),
    ('hand_connectors', 'ai_label', 'text', 'keep', null, 'identifier, status, code, hash or the owner/business own setting; not free text'),
    ('hand_connectors', 'terms', 'text', 'keep', null, 'identifier, status, code, hash or the owner/business own setting; not free text'),
    ('hand_connectors', 'signup_url', 'text', 'keep', null, 'identifier, status, code, hash or the owner/business own setting; not free text'),
    ('hand_connectors', 'updated_by', 'text', 'slug', null, 'identifier that can carry a venture / agent slug: a known client name inside it is exported as a keyed pseudonym (round 8, S1)'),
    ('hand_accounts', 'connector', 'text', 'keep', null, 'identifier, status, code, hash or the owner/business own setting; not free text'),
    ('hand_accounts', 'division', 'text', 'slug', null, 'identifier that can carry a venture / agent slug: a known client name inside it is exported as a keyed pseudonym (round 8, S1)'),
    ('hand_accounts', 'handle', 'text', 'keep', null, 'identifier, status, code, hash or the owner/business own setting; not free text'),
    ('hand_accounts', 'display_name', 'text', 'light', null, 'owner-set business display name: patterns and known names only'),
    ('hand_accounts', 'purpose', 'text', 'blank', null, 'agent / scraper / counterparty / unknown writer: free text is not exported (round 6)'),
    ('hand_accounts', 'bio', 'text', 'blank', null, 'agent / scraper / counterparty / unknown writer: free text is not exported (round 6)'),
    ('hand_accounts', 'asset_ref', 'text', 'blank', null, 'agent / scraper / counterparty / unknown writer: free text is not exported (round 6)'),
    ('hand_accounts', 'status', 'text', 'keep', null, 'identifier, status, code, hash or the owner/business own setting; not free text'),
    ('hand_accounts', 'token_vault_ref', 'text', 'keep', null, 'identifier, status, code, hash or the owner/business own setting; not free text'),
    ('hand_accounts', 'external_id', 'text', 'keep', null, 'identifier, status, code, hash or the owner/business own setting; not free text'),
    ('hand_accounts', 'scopes', 'array', 'keep', null, 'identifier, status, code, hash or the owner/business own setting; not free text'),
    ('hand_accounts', 'proposed_by', 'text', 'slug', null, 'identifier that can carry a venture / agent slug: a known client name inside it is exported as a keyed pseudonym (round 8, S1)'),
    ('hand_accounts', 'decided_by', 'text', 'slug', null, 'identifier that can carry a venture / agent slug: a known client name inside it is exported as a keyed pseudonym (round 8, S1)'),
    ('hand_actions', 'connector', 'text', 'keep', null, 'identifier, status, code, hash or the owner/business own setting; not free text'),
    ('hand_actions', 'division', 'text', 'slug', null, 'identifier that can carry a venture / agent slug: a known client name inside it is exported as a keyed pseudonym (round 8, S1)'),
    ('hand_actions', 'action', 'text', 'keep', null, 'identifier, status, code, hash or the owner/business own setting; not free text'),
    ('hand_actions', 'payload', 'json', 'blank', null, 'agent / scraper / counterparty / unknown writer: free text is not exported (round 6)'),
    ('hand_actions', 'status', 'text', 'keep', null, 'identifier, status, code, hash or the owner/business own setting; not free text'),
    ('hand_actions', 'approval_kind', 'text', 'keep', null, 'identifier, status, code, hash or the owner/business own setting; not free text'),
    ('hand_actions', 'approved_by', 'text', 'slug', null, 'identifier that can carry a venture / agent slug: a known client name inside it is exported as a keyed pseudonym (round 8, S1)'),
    ('hand_actions', 'external_ref', 'text', 'keep', null, 'identifier, status, code, hash or the owner/business own setting; not free text'),
    ('hand_actions', 'result', 'text', 'blank', null, 'agent / scraper / counterparty / unknown writer: free text is not exported (round 6)'),
    ('hand_actions', 'created_by', 'text', 'slug', null, 'identifier that can carry a venture / agent slug: a known client name inside it is exported as a keyed pseudonym (round 8, S1)'),
    ('hand_standing', 'scope_kind', 'text', 'keep', null, 'identifier, status, code, hash or the owner/business own setting; not free text'),
    ('hand_standing', 'scope_ref', 'text', 'slug', null, 'identifier that can carry a venture / agent slug: a known client name inside it is exported as a keyed pseudonym (round 8, S1)'),
    ('hand_standing', 'set_by', 'text', 'slug', null, 'identifier that can carry a venture / agent slug: a known client name inside it is exported as a keyed pseudonym (round 8, S1)')
  ) v (table_name, column_name, kind, mode, max_len, reason)
$$;
revoke all on function public.backup_redaction_spec() from public, anon, authenticated;
