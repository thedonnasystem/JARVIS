-- FENDEZY GROUP Phase 1, milestone M4 "Audit and security hardening". ADDITIVE. Needs M1 (20261127), M2 (20261128), M3 (20261129).
-- Design (docs/architecture/PHASE1_M4_SECURITY.md):
--   * fz_audit_chain: a tamper-EVIDENT hash chain over audit_log, built by fz_audit_chain_extend() (cron, every 15 min) from audit_log rows older than 5 minutes (so a
--     transaction that commits late is not mistaken for an insertion). row_hash = sha256(id|at|actor|action|target|detail), chain_hash = sha256(previous chain_hash || row_hash).
--     Append-only. audit_log itself and its triggers are NOT modified. fz_audit_verify() recomputes everything and names the first break: a row changed, a row deleted, a row
--     inserted below the chain head, or the chain table itself edited.
--   * fz_security_report(): read-only owner report: privileged grants (writes / definer functions open to anon, authenticated, the scoped roles or backup_reader; API roles
--     with superuser / bypassrls / createrole; API roles holding service_role or postgres), SECURITY DEFINER functions without a pinned search_path, public tables with RLS off,
--     identities (active / dormant / revoked, pinned token ids, voided-before), registered tokens near or past expiry, the chain status, recent alerts. Telegram /security.
--   * fz_token_registry: the owner records each minted scoped token (identity, jti, expiry) so expiry can be reported (the JWT itself is never stored).
--   * fz_security_watch() (cron, every 15 min): extends and verifies the chain, compares the privileged items with the baseline (taken on its first run), and on a break or a
--     NEW privileged item writes ONE alert per finding to the owner's own Telegram chat (owner_messages kind 'health': never a call, never anything external) + fz_security_alerts.
--   No change to audit_log, authorize_action, action_policy, caps, kill switch, mode, executors, hq_llm or any owner-identity check. Money controls unchanged (fingerprint).
-- Ordered BEFORE the lockdown (R3). Rollback: ops/rollback_security_hardening.sql (archives the tables, never drops them). Safe to re-run.

set lock_timeout = '5s';

-- ---------------------------------------------------------------------------------------------------------------------------- tables
create table if not exists public.fz_audit_chain (
  seq bigint generated always as identity primary key,
  audit_id bigint not null unique,                                       -- audit_log.id (no foreign key: audit_log is never touched)
  row_hash text not null,
  chain_hash text not null,
  chained_at timestamptz not null default now()
);

create table if not exists public.fz_security_baseline (
  item text primary key,                                                 -- e.g. table:tasks:fz_jarvis:insert / function:x(text):anon / role:anon:bypassrls
  status text not null default 'baseline' check (status in ('baseline', 'alerted', 'acknowledged')),
  first_seen timestamptz not null default now(),
  acknowledged_by text,
  acknowledged_at timestamptz
);

create table if not exists public.fz_security_alerts (
  id bigint generated always as identity primary key,
  kind text not null check (kind in ('chain_break', 'new_privilege')),
  item text not null,
  detail jsonb not null default '{}'::jsonb,
  at timestamptz not null default now()
);
create unique index if not exists fz_security_alerts_once on public.fz_security_alerts (kind, item);

create table if not exists public.fz_token_registry (
  jti text primary key check (length(jti) between 4 and 200),
  identity text not null,
  issued_at timestamptz not null default now(),
  expires_at timestamptz not null,
  note text not null default '',
  registered_by text not null default 'owner',
  registered_at timestamptz not null default now()
);

do $$
declare t text;
begin
  foreach t in array array['fz_audit_chain', 'fz_security_baseline', 'fz_security_alerts', 'fz_token_registry'] loop
    execute format('alter table public.%I enable row level security', t);
    execute format('revoke all on public.%I from public, anon, authenticated, service_role, fz_jarvis, fz_office_agent, fz_auditor', t);
  end loop;
end $$;
grant select on public.fz_audit_chain, public.fz_security_baseline, public.fz_security_alerts, public.fz_token_registry to service_role;
revoke all on sequence public.fz_audit_chain_seq_seq, public.fz_security_alerts_id_seq from public, anon, authenticated, service_role;

-- append-only history (M1's guard); the token registry is written by the owner only
drop trigger if exists fz_audit_chain_append_only on public.fz_audit_chain;
create trigger fz_audit_chain_append_only before update or delete on public.fz_audit_chain for each row execute function public.fz_append_only();
drop trigger if exists fz_security_alerts_append_only on public.fz_security_alerts;
create trigger fz_security_alerts_append_only before update or delete on public.fz_security_alerts for each row execute function public.fz_append_only();
do $$
declare t text;
begin
  foreach t in array array['fz_audit_chain', 'fz_security_alerts', 'fz_security_baseline', 'fz_token_registry'] loop
    execute format('drop trigger if exists %I on public.%I', t || '_no_truncate', t);
    execute format('create trigger %I before truncate on public.%I for each statement execute function public.fz_append_only()', t || '_no_truncate', t);
  end loop;
end $$;
drop trigger if exists fz_token_registry_owner on public.fz_token_registry;
create trigger fz_token_registry_owner before insert or update or delete on public.fz_token_registry for each row execute function public.fz_money_owner_only();

-- ---------------------------------------------------------------------------------------------------------------------------- the audit hash chain
create or replace function public.fz_audit_row_hash(p_id bigint, p_at timestamptz, p_actor text, p_action text, p_target text, p_detail jsonb) returns text
language sql immutable set search_path to 'pg_catalog' as $$
  select encode(sha256(convert_to(concat_ws('|', p_id::text, to_char(p_at at time zone 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.US'), coalesce(p_actor, ''), coalesce(p_action, ''),
                                            coalesce(p_target, ''), coalesce(p_detail::text, '')), 'UTF8')), 'hex')
$$;
revoke all on function public.fz_audit_row_hash(bigint, timestamptz, text, text, text, jsonb) from public, anon, authenticated;

create or replace function public.fz_audit_link(p_prev text, p_row text) returns text
language sql immutable set search_path to 'pg_catalog' as $$ select encode(sha256(convert_to(coalesce(p_prev, 'genesis') || ':' || p_row, 'UTF8')), 'hex') $$;
revoke all on function public.fz_audit_link(text, text) from public, anon, authenticated;

-- adds audit_log rows above the chain head to the chain, in id order, stopping at the first row younger than 5 minutes (so a transaction still committing is not
-- skipped and later mistaken for an insertion). Returns how many. Service path / cron.
create or replace function public.fz_audit_chain_extend(p_limit integer default 5000) returns integer
language plpgsql security definer set search_path to 'pg_catalog' as $$
declare h public.fz_audit_chain; r record; n int := 0; v_prev text; v_row text;
begin
  if coalesce(nullif(current_setting('role', true), ''), 'none') in ('fz_jarvis', 'fz_office_agent', 'fz_auditor') then
    raise exception 'the audit chain is built on the service path only' using errcode = '42501';
  end if;
  perform pg_advisory_xact_lock(7334);
  select * into h from public.fz_audit_chain order by seq desc limit 1;
  v_prev := h.chain_hash;
  for r in select a.id, a.at, a.actor, a.action, a.target, a.detail from public.audit_log a
            where a.id > coalesce(h.audit_id, 0) order by a.id limit greatest(coalesce(p_limit, 5000), 1) loop
    exit when r.at >= now() - interval '5 minutes';                      -- a contiguous prefix only: stop at the first row younger than 5 minutes
    v_row := public.fz_audit_row_hash(r.id, r.at, r.actor, r.action, r.target, r.detail);
    v_prev := public.fz_audit_link(v_prev, v_row);
    insert into public.fz_audit_chain (audit_id, row_hash, chain_hash) values (r.id, v_row, v_prev);
    n := n + 1;
  end loop;
  return n;
end $$;
revoke all on function public.fz_audit_chain_extend(integer) from public, anon, authenticated;

-- recomputes every link. ok = no break. breaks: first 20 findings (changed / deleted / chain_edited / unchained = a row below the head that is not in the chain).
create or replace function public.fz_audit_verify() returns jsonb
language plpgsql stable security definer set search_path to 'pg_catalog' as $$
declare c record; a record; v_prev text; v_row text; n bigint := 0; breaks jsonb := '[]'::jsonb; nb int := 0; v_head bigint; v_unch bigint;
begin
  for c in select * from public.fz_audit_chain order by seq loop
    n := n + 1;
    select x.id, x.at, x.actor, x.action, x.target, x.detail into a from public.audit_log x where x.id = c.audit_id;
    if a.id is null then
      nb := nb + 1; if nb <= 20 then breaks := breaks || jsonb_build_object('audit_id', c.audit_id, 'problem', 'deleted'); end if;
      v_row := c.row_hash;
    else
      v_row := public.fz_audit_row_hash(a.id, a.at, a.actor, a.action, a.target, a.detail);
      if v_row <> c.row_hash then nb := nb + 1; if nb <= 20 then breaks := breaks || jsonb_build_object('audit_id', c.audit_id, 'problem', 'changed'); end if; end if;
    end if;
    if public.fz_audit_link(v_prev, c.row_hash) <> c.chain_hash then
      nb := nb + 1; if nb <= 20 then breaks := breaks || jsonb_build_object('audit_id', c.audit_id, 'problem', 'chain_edited'); end if;
    end if;
    v_prev := c.chain_hash;
  end loop;
  select max(audit_id) into v_head from public.fz_audit_chain;
  select count(*) into v_unch from public.audit_log x where x.id <= coalesce(v_head, 0) and not exists (select 1 from public.fz_audit_chain c2 where c2.audit_id = x.id)
     and x.id > coalesce((select min(audit_id) from public.fz_audit_chain), 0);
  if v_unch > 0 then
    nb := nb + 1;
    breaks := breaks || jsonb_build_object('problem', 'unchained', 'rows', v_unch, 'note', 'rows below the chain head that are not in the chain (inserted with an old id)');
  end if;
  return jsonb_build_object('ok', nb = 0, 'checked', n, 'breaks', breaks, 'break_count', nb, 'head_audit_id', v_head,
                            'head_hash', (select chain_hash from public.fz_audit_chain order by seq desc limit 1));
end $$;
revoke all on function public.fz_audit_verify() from public, anon, authenticated;

-- ---------------------------------------------------------------------------------------------------------------------------- privileged items
-- what must never quietly appear: writes or SECURITY DEFINER execution for the API / scoped / backup roles, escalated role attributes, and API roles holding the powerful roles
create or replace function public.fz_privileged_items() returns setof text
language sql stable security definer set search_path to 'pg_catalog' as $$
  with watched as (select rolname, oid from pg_roles where rolname in ('anon', 'authenticated', 'fz_jarvis', 'fz_office_agent', 'fz_auditor', 'backup_reader'))
  select 'table:' || c.relname || ':' || w.rolname || ':' || p.priv
    from pg_class c cross join watched w cross join unnest(array['INSERT', 'UPDATE', 'DELETE', 'TRUNCATE', 'REFERENCES', 'TRIGGER']) p (priv)
   where c.relnamespace = 'public'::regnamespace and c.relkind in ('r', 'p', 'v', 'm') and has_table_privilege(w.oid, c.oid, p.priv)
  union
  select 'column-write:' || c.relname || ':' || w.rolname
    from pg_class c cross join watched w
   where c.relnamespace = 'public'::regnamespace and c.relkind in ('r', 'p') and (has_any_column_privilege(w.oid, c.oid, 'INSERT') or has_any_column_privilege(w.oid, c.oid, 'UPDATE'))
  union
  select 'table-read:' || c.relname || ':' || w.rolname
    from pg_class c cross join watched w
   where c.relnamespace = 'public'::regnamespace and c.relkind in ('r', 'p', 'v', 'm') and w.rolname in ('anon', 'authenticated') and has_table_privilege(w.oid, c.oid, 'SELECT')
  union
  select 'definer:' || p.oid::regprocedure::text || ':' || w.rolname
    from pg_proc p cross join watched w
   where p.pronamespace = 'public'::regnamespace and p.prosecdef and has_function_privilege(w.oid, p.oid, 'EXECUTE')
  union
  select 'role:' || r.rolname || ':' || a.attr
    from pg_roles r cross join lateral (values ('superuser', r.rolsuper), ('bypassrls', r.rolbypassrls), ('createrole', r.rolcreaterole), ('createdb', r.rolcreatedb)) a (attr, on_)
   where a.on_ and r.rolname in ('anon', 'authenticated', 'authenticator', 'fz_jarvis', 'fz_office_agent', 'fz_auditor', 'backup_reader')
  union
  select 'member:' || m.member::regrole::text || ':' || m.roleid::regrole::text
    from pg_auth_members m join pg_roles g on g.oid = m.roleid
   where g.rolname in ('service_role', 'postgres', 'supabase_admin') and m.member::regrole::text in ('anon', 'authenticated', 'fz_jarvis', 'fz_office_agent', 'fz_auditor', 'backup_reader')
$$;
revoke all on function public.fz_privileged_items() from public, anon, authenticated;

-- ---------------------------------------------------------------------------------------------------------------------------- the watch (cron) and its owner alerts
create or replace function public.fz_security_alert(p_kind text, p_item text, p_detail jsonb, p_body text) returns boolean
language plpgsql security definer set search_path to 'pg_catalog' as $$
declare v_id bigint;
begin
  insert into public.fz_security_alerts (kind, item, detail) values (p_kind, left(p_item, 500), coalesce(p_detail, '{}'::jsonb)) on conflict (kind, item) do nothing returning id into v_id;
  if v_id is null then return false; end if;                            -- already alerted once for this finding
  if exists (select 1 from public.agents where slug = 'jarvis') then
    insert into public.owner_messages (from_agent, kind, channel, body) values ('jarvis', 'health', 'telegram', left(p_body, 3000));   -- the owner's own chat only
  end if;
  insert into public.audit_log (actor, action, target, detail) values ('security', 'security_alert_' || p_kind, left(p_item, 300), coalesce(p_detail, '{}'::jsonb));
  return true;
end $$;
revoke all on function public.fz_security_alert(text, text, jsonb, text) from public, anon, authenticated;

create or replace function public.fz_security_watch() returns jsonb
language plpgsql security definer set search_path to 'pg_catalog' as $$
declare v jsonb; b jsonb; n_new int := 0; n_alert int := 0; it text; v_first boolean;
begin
  if coalesce(nullif(current_setting('role', true), ''), 'none') in ('fz_jarvis', 'fz_office_agent', 'fz_auditor') then
    raise exception 'the security watch runs on the service path only' using errcode = '42501';
  end if;
  perform public.fz_audit_chain_extend();
  v := public.fz_audit_verify();
  if not (v ->> 'ok')::boolean then
    b := v -> 'breaks' -> 0;
    if public.fz_security_alert('chain_break', coalesce(b ->> 'problem', '?') || ':' || coalesce(b ->> 'audit_id', b ->> 'rows', '?'), v,
         format(E'SECURITY: the audit log hash chain is broken (%s finding(s); first: %s at audit row %s). An audit record was changed, deleted or inserted afterwards. Nothing was changed by Jarvis. Check with: select public.fz_audit_verify();',
                v ->> 'break_count', b ->> 'problem', coalesce(b ->> 'audit_id', '-'))) then n_alert := n_alert + 1; end if;
  end if;
  v_first := not exists (select 1 from public.fz_security_baseline);
  for it in select x from public.fz_privileged_items() x where not exists (select 1 from public.fz_security_baseline s where s.item = x) order by 1 loop
    insert into public.fz_security_baseline (item, status) values (it, case when v_first then 'baseline' else 'alerted' end) on conflict (item) do nothing;
    n_new := n_new + 1;
    if not v_first and public.fz_security_alert('new_privilege', it, jsonb_build_object('item', it),
         format(E'SECURITY: a new privileged grant appeared: %s. If you did not make it, revoke it now. If it is expected, acknowledge it in your owner session: select public.fz_owner_ack_security(%L);', it, it)) then
      n_alert := n_alert + 1;
    end if;
  end loop;
  return jsonb_build_object('chain_ok', (v ->> 'ok')::boolean, 'chain_checked', (v ->> 'checked')::bigint, 'baseline_taken', v_first, 'new_items', n_new, 'alerts_sent', n_alert);
end $$;
revoke all on function public.fz_security_watch() from public, anon, authenticated;

-- ---------------------------------------------------------------------------------------------------------------------------- owner-only
create or replace function public.fz_owner_ack_security(p_item text) returns jsonb
language plpgsql security definer set search_path to 'pg_catalog' as $$
begin
  perform public.fz_money_require_owner();
  update public.fz_security_baseline set status = 'acknowledged', acknowledged_by = 'owner', acknowledged_at = now() where item = p_item;
  if not found then raise exception 'unknown item %', p_item; end if;
  insert into public.audit_log (actor, action, target, detail) values ('owner', 'security_acknowledged', left(p_item, 300), '{}'::jsonb);
  return jsonb_build_object('item', p_item, 'status', 'acknowledged');
end $$;
revoke all on function public.fz_owner_ack_security(text) from public, anon, authenticated;

create or replace function public.fz_owner_register_token(p_identity text, p_jti text, p_expires_at timestamptz, p_note text default '') returns jsonb
language plpgsql security definer set search_path to 'pg_catalog' as $$
begin
  perform public.fz_money_require_owner();
  if not exists (select 1 from public.fz_identities where slug = p_identity) then raise exception 'unknown identity %', p_identity; end if;
  if p_expires_at is null or p_expires_at <= now() then raise exception 'expiry must be in the future'; end if;
  insert into public.fz_token_registry (jti, identity, expires_at, note) values (btrim(p_jti), p_identity, p_expires_at, left(coalesce(p_note, ''), 200));
  insert into public.audit_log (actor, action, target, detail) values ('owner', 'token_registered', 'fz_identities/' || p_identity, jsonb_build_object('expires_at', p_expires_at));
  return jsonb_build_object('identity', p_identity, 'expires_at', p_expires_at);
end $$;
revoke all on function public.fz_owner_register_token(text, text, timestamptz, text) from public, anon, authenticated;

-- ---------------------------------------------------------------------------------------------------------------------------- the report (read-only)
create or replace function public.fz_security_report(p_days integer default 14) returns jsonb
language plpgsql stable security definer set search_path to 'pg_catalog' as $$
declare v jsonb := public.fz_audit_verify(); d int := greatest(coalesce(p_days, 14), 1);
begin
  if coalesce(nullif(current_setting('role', true), ''), 'none') in ('fz_jarvis', 'fz_office_agent', 'fz_auditor') then
    raise exception 'the security report is for the owner' using errcode = '42501';
  end if;
  return jsonb_build_object(
    'privileged', coalesce((select jsonb_agg(jsonb_build_object('item', x, 'status', coalesce(s.status, 'NEW (not in baseline)')) order by x)
                              from public.fz_privileged_items() x left join public.fz_security_baseline s on s.item = x), '[]'::jsonb),
    'definer_without_search_path', coalesce((select jsonb_agg(p.oid::regprocedure::text order by 1) from pg_proc p
                                               where p.pronamespace = 'public'::regnamespace and p.prosecdef
                                                 and not exists (select 1 from unnest(coalesce(p.proconfig, '{}')) cfg where cfg like 'search_path=%')), '[]'::jsonb),
    'rls_off', coalesce((select jsonb_agg(c.relname::text order by 1) from pg_class c where c.relnamespace = 'public'::regnamespace and c.relkind in ('r', 'p') and not c.relrowsecurity), '[]'::jsonb),
    'identities', coalesce((select jsonb_agg(jsonb_build_object('identity', slug, 'kind', kind, 'status', status, 'role', db_role, 'jti_pinned', token_jti is not null,
                                                               'tokens_valid_after', tokens_valid_after) order by status, slug) from public.fz_identities), '[]'::jsonb),
    'tokens_expiring', coalesce((select jsonb_agg(jsonb_build_object('identity', identity, 'expires_at', expires_at, 'expired', expires_at <= now()) order by expires_at)
                                   from public.fz_token_registry where expires_at <= now() + make_interval(days => d)), '[]'::jsonb),
    'chain', jsonb_build_object('ok', v -> 'ok', 'checked', v -> 'checked', 'break_count', v -> 'break_count', 'head_hash', v -> 'head_hash'),
    'alerts', coalesce((select jsonb_agg(jsonb_build_object('kind', kind, 'item', item, 'at', at) order by at desc) from (select * from public.fz_security_alerts order by at desc limit 10) a), '[]'::jsonb),
    'note', 'Read-only. Nothing here changes a grant or a token.');
end $$;
revoke all on function public.fz_security_report(integer) from public, anon, authenticated;

do $$
declare f regprocedure;
begin
  for f in select p.oid::regprocedure from pg_proc p where p.pronamespace = 'public'::regnamespace and p.proname in
             ('fz_audit_row_hash', 'fz_audit_link', 'fz_audit_chain_extend', 'fz_audit_verify', 'fz_privileged_items', 'fz_security_alert', 'fz_security_watch',
              'fz_owner_ack_security', 'fz_owner_register_token', 'fz_security_report') loop
    execute format('revoke all on function %s from fz_jarvis, fz_office_agent, fz_auditor', f);
  end loop;
  if exists (select 1 from pg_namespace where nspname = 'cron') then
    perform cron.unschedule(jobid) from cron.job where jobname = 'fz-security-watch';
    perform cron.schedule('fz-security-watch', '*/15 * * * *', 'select public.fz_security_watch()');
  end if;
end $$;

-- ---------------------------------------------------------------------------------------------------------------------------- registry (M1) + backup classification
insert into public.fz_table_registry (relname, scope, scope_column, data_class, fz_read, fz_write, fz_insert_columns, fz_update_columns, note) values
  ('fz_audit_chain',       'group', null, 'confidential', false, '{}', null, null, 'security: append-only hash chain over audit_log'),
  ('fz_security_baseline', 'group', null, 'confidential', false, '{}', null, null, 'security: accepted privileged items'),
  ('fz_security_alerts',   'group', null, 'confidential', false, '{}', null, null, 'security: append-only alerts sent to the owner'),
  ('fz_token_registry',    'group', null, 'confidential', false, '{}', null, null, 'security: minted scoped tokens (id and expiry only, never the token)')
on conflict (relname) do update set scope = excluded.scope, scope_column = excluded.scope_column, data_class = excluded.data_class, fz_read = excluded.fz_read,
  fz_write = excluded.fz_write, fz_insert_columns = excluded.fz_insert_columns, fz_update_columns = excluded.fz_update_columns, note = excluded.note;

-- backup classification (PROTECTED: owner approval): same rows as 20261128_office_money_v1 plus the four security tables ('secret': not in the off-site export)
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
    ('fz_money_attribution', 'secret', 'office of each ledger row / model call / reservation; off-site export pending'),
    -- Security hardening M4 (20261130): 'secret' = not in the off-site export (as the M1 / M2 registries); the chain is rebuilt from audit_log after a restore.
    ('fz_audit_chain', 'secret', 'append-only hash chain over audit_log; rebuilt from audit_log after a restore'),
    ('fz_security_baseline', 'secret', 'accepted privileged items; re-taken on the first watch run'),
    ('fz_security_alerts', 'secret', 'append-only security alerts sent to the owner'),
    ('fz_token_registry', 'secret', 'minted scoped token ids and expiry (never a token)')
  ) v (table_name, data_class, note)
$$;
revoke all on function public.backup_classification() from public, anon, authenticated;
reset lock_timeout;
