-- FENDEZY GROUP Phase 1, milestone M4 "Audit and security hardening". ADDITIVE. Needs M1 (20261127), M2 (20261128), M3 (20261129).
-- Design (docs/architecture/PHASE1_M4_SECURITY.md). Second review (Nov 21) rebuilt the chain and the watch:
--   * fz_audit_chain: a tamper-EVIDENT hash chain over audit_log, strictly in id order, IGNORING audit_log.at (which the service key could forge). Each visible row is first
--     OBSERVED (its hash stored in fz_audit_pending with OUR timestamp); it is chained 5 minutes after it was first seen, with the hash seen then. So a row edited, re-dated or
--     deleted after it was first seen is detected even before it is chained. A hole in the ids becomes a 'gap' link once a later id has been visible 5 minutes (a deleted row, or
--     a rolled-back insert: both are reported, as 'gap', distinct from a 'deleted' chained row). A row that later appears in a gap ('gap_filled') or below the first chained id
--     ('below_genesis') is reported. audit_log itself and its triggers are NOT modified (the real fix, append-only audit_log and ledger, is the owner proposal
--     ops/proposals/audit_ledger_append_only.sql).
--   * fz_audit_verify(): incremental from a stored checkpoint; a full rescan at most nightly, and only for the cron job / the owner (never on demand by the service key).
--   * privileged items in EVERY non-system schema, compared with a committed, reviewed allowlist (fz_expected_grants(), generated into ops/expected_grants.tsv). Standing
--     findings (any anon / authenticated write; service_role UPDATE / DELETE / TRUNCATE on audit_log or ledger) are always reported and can never be acknowledged.
--   * the watch: an item that disappears is marked revoked (its acknowledgement ends), so its return alerts again; SECURITY DEFINER functions the API roles can execute are
--     fingerprinted (body + settings): a change alerts. Alerts have a stable dedupe key; writing them is inline in the watch (no callable alert helper).
--   * rollback + re-apply: the chain, its state, the baseline and the fingerprints are seeded back from fz_archive and the owner is told ("re-initialised").
--   No change to audit_log, ledger, authorize_action, action_policy, caps, kill switch, mode, executors, hq_llm or any owner-identity check. Money controls unchanged (fingerprint).
-- Ordered BEFORE the lockdown (R3). Rollback: ops/rollback_security_hardening.sql (archives the tables, never drops them). Safe to re-run.

set lock_timeout = '5s';

-- ---------------------------------------------------------------------------------------------------------------------------- tables
create table if not exists public.fz_audit_chain (
  seq bigint generated always as identity primary key,
  audit_id bigint not null unique,                                       -- audit_log.id (no foreign key: audit_log is never touched)
  kind text not null default 'row' check (kind in ('row', 'gap')),
  row_hash text not null,                                                -- for a gap: 'gap'
  chain_hash text not null,
  chained_at timestamptz not null default now()
);
create table if not exists public.fz_audit_pending (                    -- rows seen but not chained yet: hash as first seen, and when (our clock, not audit_log.at)
  audit_id bigint primary key,
  row_hash text not null,
  first_seen timestamptz not null default now()
);
create table if not exists public.fz_audit_state (
  id int primary key default 1 check (id = 1),
  genesis_id bigint,
  checkpoint_seq bigint,
  checkpoint_hash text,
  last_full_at timestamptz,
  last_full_ok boolean,
  reinitialised_at timestamptz
);
insert into public.fz_audit_state (id) values (1) on conflict (id) do nothing;
create table if not exists public.fz_security_baseline (
  item text primary key,
  category text not null default 'grant' check (category in ('grant', 'standing')),
  status text not null default 'alerted' check (status in ('expected', 'alerted', 'acknowledged', 'revoked')),
  generation int not null default 1,                                     -- +1 each time a revoked item comes back (it alerts again)
  first_seen timestamptz not null default now(),
  last_seen timestamptz not null default now(),
  acknowledged_by text,
  acknowledged_at timestamptz
);
create table if not exists public.fz_security_fingerprints (            -- SECURITY DEFINER functions an API role can execute: body + settings
  sig text primary key,
  fp text not null,
  first_seen timestamptz not null default now(),
  changed_at timestamptz
);
create table if not exists public.fz_security_alerts (
  id bigint generated always as identity primary key,
  kind text not null check (kind in ('chain_break', 'new_privilege', 'standing', 'definer_changed', 'reinitialised')),
  item text not null,
  dedupe_key text not null unique,                                       -- type + first id: one problem alerts once
  detail jsonb not null default '{}'::jsonb,
  at timestamptz not null default now()
);
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
  foreach t in array array['fz_audit_chain', 'fz_audit_pending', 'fz_audit_state', 'fz_security_baseline', 'fz_security_fingerprints', 'fz_security_alerts', 'fz_token_registry'] loop
    execute format('alter table public.%I enable row level security', t);
    execute format('revoke all on public.%I from public, anon, authenticated, service_role, fz_jarvis, fz_office_agent, fz_auditor', t);
  end loop;
end $$;
grant select on public.fz_audit_chain, public.fz_audit_state, public.fz_security_baseline, public.fz_security_fingerprints, public.fz_security_alerts, public.fz_token_registry to service_role;
revoke all on sequence public.fz_audit_chain_seq_seq, public.fz_security_alerts_id_seq from public, anon, authenticated, service_role;

drop trigger if exists fz_audit_chain_append_only on public.fz_audit_chain;
create trigger fz_audit_chain_append_only before update or delete on public.fz_audit_chain for each row execute function public.fz_append_only();
drop trigger if exists fz_security_alerts_append_only on public.fz_security_alerts;
create trigger fz_security_alerts_append_only before update or delete on public.fz_security_alerts for each row execute function public.fz_append_only();
do $$
declare t text;
begin
  foreach t in array array['fz_audit_chain', 'fz_audit_state', 'fz_security_alerts', 'fz_security_baseline', 'fz_security_fingerprints', 'fz_token_registry'] loop
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

-- 1. OBSERVE every visible row above the head (hash + our time); 2. CHAIN, strictly by id, each row first seen at least 5 minutes ago (with the hash seen then); a hole
-- becomes a 'gap' link once a later id has been visible for 5 minutes. audit_log.at plays no part. Returns how many links were added. Service path / cron.
create or replace function public.fz_audit_chain_extend(p_limit integer default 5000) returns integer
language plpgsql security definer set search_path to 'pg_catalog' as $$
declare h public.fz_audit_chain; st public.fz_audit_state; k bigint; v_prev text; p public.fz_audit_pending; n int := 0; v_lim int := greatest(coalesce(p_limit, 5000), 1);
        v_max_ready bigint;
begin
  if coalesce(nullif(current_setting('role', true), ''), 'none') in ('fz_jarvis', 'fz_office_agent', 'fz_auditor') then
    raise exception 'the audit chain is built on the service path only' using errcode = '42501';
  end if;
  perform pg_advisory_xact_lock(7334);
  select * into h from public.fz_audit_chain order by seq desc limit 1;
  insert into public.fz_audit_pending (audit_id, row_hash)
    select a.id, public.fz_audit_row_hash(a.id, a.at, a.actor, a.action, a.target, a.detail) from public.audit_log a
     where a.id > coalesce(h.audit_id, 0) order by a.id limit 50000
  on conflict (audit_id) do nothing;
  select * into st from public.fz_audit_state where id = 1 for update;
  if h.seq is null then
    k := (select min(audit_id) from public.fz_audit_pending where first_seen <= now() - interval '5 minutes');
    if k is null then return 0; end if;
    update public.fz_audit_state set genesis_id = k where id = 1;
  else
    k := h.audit_id + 1;
  end if;
  v_prev := h.chain_hash;
  select max(audit_id) into v_max_ready from public.fz_audit_pending where first_seen <= now() - interval '5 minutes';
  while n < v_lim and k <= coalesce(v_max_ready, 0) loop
    select * into p from public.fz_audit_pending where audit_id = k;
    if p.audit_id is not null then
      exit when p.first_seen > now() - interval '5 minutes';
      v_prev := public.fz_audit_link(v_prev, p.row_hash);
      insert into public.fz_audit_chain (audit_id, kind, row_hash, chain_hash) values (k, 'row', p.row_hash, v_prev);
      delete from public.fz_audit_pending where audit_id = k;            -- working buffer only (the chain now holds the hash)
    else
      v_prev := public.fz_audit_link(v_prev, 'gap');                     -- a later id has been visible for 5 minutes and this one never appeared
      insert into public.fz_audit_chain (audit_id, kind, row_hash, chain_hash) values (k, 'gap', 'gap', v_prev);
    end if;
    n := n + 1; k := k + 1;
  end loop;
  return n;
end $$;
revoke all on function public.fz_audit_chain_extend(integer) from public, anon, authenticated;

-- verifies from the checkpoint (incremental) or from the start (p_full; honoured only for the cron job / the owner's session / the signed-in owner). Always checks the
-- pending rows (changed since first seen), rows below genesis, and rows that appeared in gaps. Read-only: the watch stores the checkpoint.
create or replace function public.fz_audit_verify(p_full boolean default false) returns jsonb
language plpgsql stable security definer set search_path to 'pg_catalog' as $$
declare c record; a record; v_prev text; n bigint := 0; breaks jsonb := '[]'::jsonb; nb int := 0; st public.fz_audit_state; v_full boolean; v_from bigint; v_last_seq bigint; v_last_hash text;
        v_role text := coalesce(nullif(current_setting('role', true), ''), 'none'); v_x bigint;
begin
  select * into st from public.fz_audit_state where id = 1;
  v_full := coalesce(p_full, false) and (v_role in ('none', 'postgres') or coalesce(public.is_app_owner(), false));
  if not v_full and st.checkpoint_seq is not null then
    v_from := st.checkpoint_seq; v_prev := st.checkpoint_hash;
    if (select chain_hash from public.fz_audit_chain where seq = st.checkpoint_seq) is distinct from st.checkpoint_hash then
      nb := nb + 1; breaks := breaks || jsonb_build_object('problem', 'chain_edited', 'seq', st.checkpoint_seq, 'note', 'the checkpointed link changed');
    end if;
  else
    v_from := 0; v_prev := null;
  end if;
  for c in select * from public.fz_audit_chain where seq > v_from order by seq loop
    n := n + 1;
    select x.id, x.at, x.actor, x.action, x.target, x.detail into a from public.audit_log x where x.id = c.audit_id;
    if c.kind = 'row' then
      if a.id is null then nb := nb + 1; if nb <= 20 then breaks := breaks || jsonb_build_object('audit_id', c.audit_id, 'problem', 'deleted'); end if;
      elsif public.fz_audit_row_hash(a.id, a.at, a.actor, a.action, a.target, a.detail) <> c.row_hash then
        nb := nb + 1; if nb <= 20 then breaks := breaks || jsonb_build_object('audit_id', c.audit_id, 'problem', 'changed'); end if;
      end if;
    elsif a.id is not null then
      nb := nb + 1; if nb <= 20 then breaks := breaks || jsonb_build_object('audit_id', c.audit_id, 'problem', 'gap_filled', 'note', 'a row appeared later in a hole of the chain'); end if;
    end if;
    if public.fz_audit_link(v_prev, c.row_hash) <> c.chain_hash then
      nb := nb + 1; if nb <= 20 then breaks := breaks || jsonb_build_object('audit_id', c.audit_id, 'problem', 'chain_edited'); end if;
    end if;
    v_prev := c.chain_hash; v_last_seq := c.seq; v_last_hash := c.chain_hash;
  end loop;
  -- rows seen but not chained yet: changed or gone since first seen
  for c in select p.audit_id, p.row_hash, x.id, x.at, x.actor, x.action, x.target, x.detail from public.fz_audit_pending p left join public.audit_log x on x.id = p.audit_id order by p.audit_id loop
    if c.id is null then nb := nb + 1; if nb <= 20 then breaks := breaks || jsonb_build_object('audit_id', c.audit_id, 'problem', 'deleted', 'note', 'deleted before it was chained'); end if;
    elsif public.fz_audit_row_hash(c.id, c.at, c.actor, c.action, c.target, c.detail) <> c.row_hash then
      nb := nb + 1; if nb <= 20 then breaks := breaks || jsonb_build_object('audit_id', c.audit_id, 'problem', 'changed', 'note', 'changed before it was chained'); end if;
    end if;
  end loop;
  select count(*) into v_x from public.audit_log where id < st.genesis_id;
  if v_x > 0 then nb := nb + 1; breaks := breaks || jsonb_build_object('problem', 'below_genesis', 'rows', v_x, 'note', 'rows with an id below the first chained row'); end if;
  return jsonb_build_object('ok', nb = 0, 'full', v_full or st.checkpoint_seq is null, 'checked', n, 'breaks', breaks, 'break_count', nb,
                            'last_seq', coalesce(v_last_seq, st.checkpoint_seq), 'last_hash', coalesce(v_last_hash, st.checkpoint_hash),
                            'gaps', (select count(*) from public.fz_audit_chain where kind = 'gap'), 'genesis_id', st.genesis_id,
                            'head_hash', (select chain_hash from public.fz_audit_chain order by seq desc limit 1));
end $$;
revoke all on function public.fz_audit_verify(boolean) from public, anon, authenticated;

-- ---------------------------------------------------------------------------------------------------------------------------- privileged items (every non-system schema)
-- category 'standing': always reported, never acknowledged (any anon / authenticated write, REFERENCES or TRIGGER; service_role UPDATE / DELETE / TRUNCATE on audit_log or ledger, until the owner
-- applies ops/proposals/audit_ledger_append_only.sql). 'grant': compared with the reviewed allowlist fz_expected_grants().
create or replace function public.fz_privileged_items() returns table (item text, category text)
language sql stable security definer set search_path to 'pg_catalog' as $$
  with watched as (select rolname, oid from pg_roles where rolname in ('anon', 'authenticated', 'fz_jarvis', 'fz_office_agent', 'fz_auditor', 'backup_reader')),
  rels as (select c.oid, c.relkind, c.relrowsecurity, n.nspname || '.' || c.relname as qn from pg_class c join pg_namespace n on n.oid = c.relnamespace
            where n.nspname !~ '^pg_' and n.nspname <> 'information_schema' and c.relkind in ('r', 'p', 'v', 'm', 'f'))
  select 'table:' || r.qn || ':' || w.rolname || ':' || p.priv, case when w.rolname in ('anon', 'authenticated') then 'standing' else 'grant' end   -- incl. REFERENCES / TRIGGER
    from rels r cross join watched w cross join unnest(array['INSERT', 'UPDATE', 'DELETE', 'TRUNCATE', 'REFERENCES', 'TRIGGER']) p (priv)
   where has_table_privilege(w.oid, r.oid, p.priv)
  union
  select 'column-write:' || r.qn || ':' || w.rolname, case when w.rolname in ('anon', 'authenticated') then 'standing' else 'grant' end
    from rels r cross join watched w
   where r.relkind in ('r', 'p') and not has_table_privilege(w.oid, r.oid, 'INSERT') and not has_table_privilege(w.oid, r.oid, 'UPDATE')
     and (has_any_column_privilege(w.oid, r.oid, 'INSERT') or has_any_column_privilege(w.oid, r.oid, 'UPDATE'))
  union
  select 'table-read:' || r.qn || ':' || w.rolname || case when r.relkind in ('r', 'p') and not r.relrowsecurity then ':rls-off' else '' end, 'grant'
    from rels r cross join watched w
   where w.rolname in ('anon', 'authenticated') and has_table_privilege(w.oid, r.oid, 'SELECT')
  union
  select 'table:public.' || t.t || ':service_role:' || p.priv, 'standing'
    from unnest(array['audit_log', 'ledger']) t (t) cross join unnest(array['UPDATE', 'DELETE', 'TRUNCATE']) p (priv)
   where to_regclass('public.' || t.t) is not null and exists (select 1 from pg_roles where rolname = 'service_role') and has_table_privilege('service_role', ('public.' || t.t)::regclass, p.priv)
  union
  select 'definer:' || n.nspname || '.' || p.oid::regprocedure::text || ':' || w.rolname, 'grant'
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace cross join watched w
   where n.nspname !~ '^pg_' and n.nspname <> 'information_schema' and p.prosecdef and has_function_privilege(w.oid, p.oid, 'EXECUTE')
  union
  select 'schema-create:' || n.nspname || ':' || w.rolname, case when w.rolname in ('anon', 'authenticated') then 'standing' else 'grant' end
    from pg_namespace n cross join watched w
   where n.nspname !~ '^pg_' and n.nspname <> 'information_schema' and has_schema_privilege(w.oid, n.oid, 'CREATE')
  union
  select 'role:' || r.rolname || ':' || a.attr, 'grant'
    from pg_roles r cross join lateral (values ('superuser', r.rolsuper), ('bypassrls', r.rolbypassrls), ('createrole', r.rolcreaterole), ('createdb', r.rolcreatedb)) a (attr, on_)
   where a.on_ and r.rolname in ('anon', 'authenticated', 'authenticator', 'fz_jarvis', 'fz_office_agent', 'fz_auditor', 'backup_reader')
  union
  select 'member:' || m.member::regrole::text || ':' || m.roleid::regrole::text, 'grant'
    from pg_auth_members m join pg_roles g on g.oid = m.roleid
   where g.rolname in ('service_role', 'postgres', 'supabase_admin') and m.member::regrole::text in ('anon', 'authenticated', 'fz_jarvis', 'fz_office_agent', 'fz_auditor', 'backup_reader')
$$;
revoke all on function public.fz_privileged_items() from public, anon, authenticated;

-- the reviewed allowlist: generated by scripts/expected_grants.py from the replica (whose ACLs equal the reviewed ops/ACL_MANIFEST_public.tsv), also in ops/expected_grants.tsv.
-- A change of the expected grants is a reviewed change of this list (the replica step fails while the list and the database disagree).
create or replace function public.fz_expected_grants() returns setof text
language sql immutable set search_path to 'pg_catalog' as $$
  select x from (values
    -- BEGIN EXPECTED GRANTS (generated: scripts/expected_grants.py --write)
    ('column-write:public.tasks:fz_jarvis'),
    ('column-write:public.tasks:fz_office_agent'),
    ('definer:public.public.app_messages(integer):authenticated'),
    ('definer:public.public.app_office():authenticated'),
    ('definer:public.public.app_payments():authenticated'),
    ('definer:public.public.app_push_public_key():authenticated'),
    ('definer:public.public.app_save_push(jsonb,text):authenticated'),
    ('definer:public.public.app_send(text,text,jsonb):authenticated'),
    ('definer:public.public.app_set_agent(text,text):authenticated'),
    ('definer:public.public.app_set_kill(boolean):authenticated'),
    ('definer:public.public.app_snapshot():authenticated'),
    ('definer:public.public.app_venture(text):authenticated'),
    ('definer:public.public.app_venture_extras(text):authenticated'),
    ('definer:public.public.backup_deny_prepare():backup_reader'),
    ('definer:public.public.backup_deny_release(uuid):backup_reader'),
    ('definer:public.public.backup_epoch():backup_reader'),
    ('definer:public.public.backup_export_policy():backup_reader'),
    ('definer:public.public.backup_redaction_meta(jsonb):backup_reader'),
    ('definer:public.public.backup_redaction_status():backup_reader'),
    ('definer:public.public.backup_schema():backup_reader'),
    ('definer:public.public.backup_snapshot(text[]):backup_reader'),
    ('definer:public.public.backup_snapshot_cost():backup_reader'),
    ('definer:public.public.backup_snapshot_page(text,integer,integer,uuid):backup_reader'),
    ('definer:public.public.backup_suppression_export():backup_reader'),
    ('definer:public.public.backup_table_digest(text):backup_reader'),
    ('definer:public.public.current_identity():fz_auditor'),
    ('definer:public.public.current_identity():fz_jarvis'),
    ('definer:public.public.current_identity():fz_office_agent'),
    ('definer:public.public.current_office():fz_auditor'),
    ('definer:public.public.current_office():fz_jarvis'),
    ('definer:public.public.current_office():fz_office_agent'),
    ('definer:public.public.current_office_id():fz_auditor'),
    ('definer:public.public.current_office_id():fz_jarvis'),
    ('definer:public.public.current_office_id():fz_office_agent'),
    ('definer:public.public.fz_agent_in_office(text,uuid):fz_auditor'),
    ('definer:public.public.fz_agent_in_office(text,uuid):fz_jarvis'),
    ('definer:public.public.fz_agent_in_office(text,uuid):fz_office_agent'),
    ('definer:public.public.fz_authorize_action(text,integer,text,text,text,uuid,uuid,jsonb):fz_jarvis'),
    ('definer:public.public.fz_authorize_action(text,integer,text,text,text,uuid,uuid,jsonb):fz_office_agent'),
    ('definer:public.public.fz_identity_now():fz_auditor'),
    ('definer:public.public.fz_identity_now():fz_jarvis'),
    ('definer:public.public.fz_identity_now():fz_office_agent'),
    ('definer:public.public.fz_readable_offices(text):fz_auditor'),
    ('definer:public.public.fz_readable_offices(text):fz_jarvis'),
    ('definer:public.public.fz_readable_offices(text):fz_office_agent'),
    ('definer:public.public.fz_readable_workspaces(text):fz_auditor'),
    ('definer:public.public.fz_readable_workspaces(text):fz_jarvis'),
    ('definer:public.public.fz_readable_workspaces(text):fz_office_agent'),
    ('definer:public.public.fz_whoami():fz_auditor'),
    ('definer:public.public.fz_whoami():fz_jarvis'),
    ('definer:public.public.fz_whoami():fz_office_agent'),
    ('definer:public.public.fz_writable_offices(text):fz_auditor'),
    ('definer:public.public.fz_writable_offices(text):fz_jarvis'),
    ('definer:public.public.fz_writable_offices(text):fz_office_agent'),
    ('definer:public.public.is_app_owner():authenticated'),
    ('definer:public.public.is_group_scope():fz_auditor'),
    ('definer:public.public.is_group_scope():fz_jarvis'),
    ('definer:public.public.is_group_scope():fz_office_agent'),
    ('definer:public.public.redaction_denylist_status():backup_reader'),
    ('definer:public.public.setter_apply(text,text,text,text,text):anon'),
    ('definer:public.public.setter_apply(text,text,text,text,text):authenticated'),
    ('table-read:public.account_requests:anon'),
    ('table-read:public.account_requests:authenticated'),
    ('table-read:public.action_log:anon'),
    ('table-read:public.action_log:authenticated'),
    ('table-read:public.action_policy:anon'),
    ('table-read:public.action_policy:authenticated'),
    ('table-read:public.agent_scorecard:anon'),
    ('table-read:public.agent_scorecard:authenticated'),
    ('table-read:public.agents:anon'),
    ('table-read:public.agents:authenticated'),
    ('table-read:public.approval_requests:anon'),
    ('table-read:public.approval_requests:authenticated'),
    ('table-read:public.bank_accounts:anon'),
    ('table-read:public.bank_accounts:authenticated'),
    ('table-read:public.bank_balances:anon'),
    ('table-read:public.bank_balances:authenticated'),
    ('table-read:public.bank_transactions:anon'),
    ('table-read:public.bank_transactions:authenticated'),
    ('table-read:public.capital_policy:anon'),
    ('table-read:public.capital_policy:authenticated'),
    ('table-read:public.contact_suppressions:anon'),
    ('table-read:public.contact_suppressions:authenticated'),
    ('table-read:public.departments:anon'),
    ('table-read:public.departments:authenticated'),
    ('table-read:public.lead_replies:anon'),
    ('table-read:public.lead_replies:authenticated'),
    ('table-read:public.memory:anon'),
    ('table-read:public.memory:authenticated'),
    ('table-read:public.mission_outcomes:anon'),
    ('table-read:public.mission_outcomes:authenticated'),
    ('table-read:public.missions:anon'),
    ('table-read:public.missions:authenticated'),
    ('table-read:public.org_changes:anon'),
    ('table-read:public.org_changes:authenticated'),
    ('table-read:public.payment_instructions:anon'),
    ('table-read:public.payment_instructions:authenticated'),
    ('table-read:public.push_config:anon'),
    ('table-read:public.push_config:authenticated'),
    ('table-read:public.push_subscriptions:anon'),
    ('table-read:public.push_subscriptions:authenticated'),
    ('table-read:public.spend_reservations:anon'),
    ('table-read:public.spend_reservations:authenticated'),
    ('table-read:public.tasks:anon'),
    ('table-read:public.tasks:authenticated'),
    ('table-read:public.venture_assets:anon'),
    ('table-read:public.venture_assets:authenticated'),
    ('table-read:public.venture_config:anon'),
    ('table-read:public.venture_config:authenticated'),
    ('table-read:public.venture_goals:anon'),
    ('table-read:public.venture_goals:authenticated'),
    ('table-read:public.venture_procedures:anon'),
    ('table-read:public.venture_procedures:authenticated'),
    ('table-read:public.ventures:anon'),
    ('table-read:public.ventures:authenticated'),
    ('table-read:public.web_messages:anon'),
    ('table-read:public.web_messages:authenticated'),
    -- END EXPECTED GRANTS
    ('')
  ) v (x) where x <> ''
$$;
revoke all on function public.fz_expected_grants() from public, anon, authenticated;

-- ---------------------------------------------------------------------------------------------------------------------------- the watch (cron)
-- Writes alerts INLINE (no separately callable alert helper: the service key must not be able to post or pre-empt an alert). One alert per dedupe key:
--   chain_break:<problem>:<first id>   new_privilege:<md5 of the new set>   standing:<md5 of the set>   definer_changed:<function>:<new fingerprint>
create or replace function public.fz_security_watch() returns jsonb
language plpgsql security definer set search_path to 'pg_catalog' as $$
declare v jsonb; b jsonb; it record; v_new text[] := '{}'; v_back text[] := '{}'; v_std text[]; n_alert int := 0; v_role text := coalesce(nullif(current_setting('role', true), ''), 'none');
        v_full boolean; st public.fz_audit_state; al jsonb := '[]'::jsonb; a jsonb; v_id bigint; f record; sb public.fz_security_baseline;
begin
  if v_role in ('fz_jarvis', 'fz_office_agent', 'fz_auditor') then raise exception 'the security watch runs on the service path only' using errcode = '42501'; end if;
  perform public.fz_audit_chain_extend();
  select * into st from public.fz_audit_state where id = 1;
  v_full := v_role in ('none', 'postgres') and (st.last_full_at is null or st.last_full_at < now() - interval '20 hours');   -- a full rescan at most nightly, never on demand by the key
  v := public.fz_audit_verify(v_full);
  if (v ->> 'ok')::boolean then
    update public.fz_audit_state set checkpoint_seq = (v ->> 'last_seq')::bigint, checkpoint_hash = v ->> 'last_hash',
           last_full_at = case when (v ->> 'full')::boolean then now() else last_full_at end, last_full_ok = case when (v ->> 'full')::boolean then true else last_full_ok end where id = 1;
  else
    b := v -> 'breaks' -> 0;
    if (v ->> 'full')::boolean then update public.fz_audit_state set last_full_at = now(), last_full_ok = false where id = 1; end if;
    al := al || jsonb_build_object('kind', 'chain_break', 'item', coalesce(b ->> 'problem', '?'), 'key', 'chain_break:' || coalesce(b ->> 'problem', '?') || ':' || coalesce(b ->> 'audit_id', b ->> 'seq', b ->> 'rows', '?'),
      'detail', v, 'body', format(E'SECURITY: the audit log hash chain is broken (%s finding(s); first: %s at audit row %s). An audit record was changed, deleted or inserted afterwards. Check with: select public.fz_audit_verify(true);',
                                  v ->> 'break_count', b ->> 'problem', coalesce(b ->> 'audit_id', b ->> 'seq', '-')));
  end if;
  -- privileged items vs the reviewed allowlist; revoked items are remembered so their return alerts again
  for it in select x.item, x.category from public.fz_privileged_items() x loop
    if it.category = 'grant' and it.item in (select public.fz_expected_grants()) then
      insert into public.fz_security_baseline (item, category, status) values (it.item, 'grant', 'expected')
      on conflict (item) do update set last_seen = now(), status = case when fz_security_baseline.status = 'revoked' then 'expected' else fz_security_baseline.status end;
      continue;
    end if;
    select * into sb from public.fz_security_baseline where item = it.item;
    if sb.item is null then
      insert into public.fz_security_baseline (item, category, status) values (it.item, it.category, 'alerted');
      if it.category = 'grant' then v_new := v_new || it.item; end if;
    elsif sb.status = 'revoked' then                                        -- it was gone and came back: alert again (a fresh generation)
      update public.fz_security_baseline set status = 'alerted', generation = generation + 1, category = it.category, last_seen = now(), acknowledged_by = null, acknowledged_at = null
       where item = it.item;
      if it.category = 'grant' then v_back := v_back || it.item; end if;
    else
      update public.fz_security_baseline set last_seen = now(), category = it.category where item = it.item;
    end if;
    sb := null;
  end loop;
  -- gone items: revoked (an acknowledgement ends with the item)
  update public.fz_security_baseline s set status = 'revoked', acknowledged_by = null, acknowledged_at = null
   where s.status <> 'revoked' and not exists (select 1 from public.fz_privileged_items() x where x.item = s.item);
  if cardinality(v_new) + cardinality(v_back) > 0 then
    al := al || jsonb_build_object('kind', 'new_privilege', 'item', (v_new || v_back)[1], 'key', 'new_privilege:' || md5(array_to_string(array(select unnest(v_new || v_back) order by 1), ',')) || ':' ||
                                   (select coalesce(max(generation), 1) from public.fz_security_baseline where item = any (v_new || v_back)),
      'detail', jsonb_build_object('new', to_jsonb(v_new), 'returned', to_jsonb(v_back)),
      'body', format(E'SECURITY: %s privileged grant(s) appeared that are not on the reviewed list (%s returned after a revoke): %s. If you did not make them, revoke them now; see /security.',
                     cardinality(v_new) + cardinality(v_back), cardinality(v_back), left(array_to_string(v_new || v_back, ', '), 1500)));
  end if;
  v_std := array(select x.item from public.fz_privileged_items() x where x.category = 'standing' order by 1);
  if cardinality(v_std) > 0 then
    al := al || jsonb_build_object('kind', 'standing', 'item', v_std[1], 'key', 'standing:' || md5(array_to_string(v_std, ',')), 'detail', jsonb_build_object('count', cardinality(v_std)),
      'body', format(E'SECURITY: %s standing finding(s) (API-role writes; the service key can change or delete audit_log / ledger until you apply ops/proposals/audit_ledger_append_only.sql). First: %s. See /security.',
                     cardinality(v_std), left(array_to_string(v_std[1:5], ', '), 800)));
  end if;
  -- SECURITY DEFINER functions any API role can execute: fingerprint body + settings; a change alerts
  for f in select n.nspname || '.' || p.oid::regprocedure::text sig, md5(p.prosrc || '|' || coalesce(array_to_string(p.proconfig, ','), '')) fp
             from pg_proc p join pg_namespace n on n.oid = p.pronamespace
            where n.nspname !~ '^pg_' and n.nspname <> 'information_schema' and p.prosecdef
              and exists (select 1 from pg_roles r where r.rolname in ('anon', 'authenticated', 'service_role', 'fz_jarvis', 'fz_office_agent', 'fz_auditor', 'backup_reader') and has_function_privilege(r.oid, p.oid, 'EXECUTE')) loop
    insert into public.fz_security_fingerprints (sig, fp) values (f.sig, f.fp) on conflict (sig) do nothing;
    if not found and exists (select 1 from public.fz_security_fingerprints where sig = f.sig and fp <> f.fp) then
      update public.fz_security_fingerprints set fp = f.fp, changed_at = now() where sig = f.sig;
      al := al || jsonb_build_object('kind', 'definer_changed', 'item', f.sig, 'key', 'definer_changed:' || f.sig || ':' || f.fp, 'detail', jsonb_build_object('function', f.sig),
        'body', format(E'SECURITY: the body or settings of %s changed (a SECURITY DEFINER function the API roles can run). If this was not a reviewed release, treat it as an incident.', f.sig));
    end if;
  end loop;
  -- the alerts (one per dedupe key), the owner's own Telegram chat only (kind health: never a call)
  for a in select * from jsonb_array_elements(al) loop
    insert into public.fz_security_alerts (kind, item, dedupe_key, detail) values (a ->> 'kind', left(a ->> 'item', 500), left(a ->> 'key', 500), coalesce(a -> 'detail', '{}'::jsonb))
    on conflict (dedupe_key) do nothing returning id into v_id;
    if v_id is not null then
      n_alert := n_alert + 1;
      if exists (select 1 from public.agents where slug = 'jarvis') then
        insert into public.owner_messages (from_agent, kind, channel, body) values ('jarvis', 'health', 'telegram', left(a ->> 'body', 3000));
      end if;
      insert into public.audit_log (actor, action, target, detail) values ('security', 'security_alert_' || (a ->> 'kind'), left(a ->> 'item', 300), jsonb_build_object('key', a ->> 'key'));
      v_id := null;
    end if;
  end loop;
  return jsonb_build_object('chain_ok', (v ->> 'ok')::boolean, 'chain_full', (v ->> 'full')::boolean, 'chain_checked', (v ->> 'checked')::bigint, 'new_items', cardinality(v_new),
                            'returned_items', cardinality(v_back), 'standing', cardinality(v_std), 'alerts_sent', n_alert);
end $$;
revoke all on function public.fz_security_watch() from public, anon, authenticated;

-- ---------------------------------------------------------------------------------------------------------------------------- owner-only
create or replace function public.fz_owner_ack_security(p_item text) returns jsonb
language plpgsql security definer set search_path to 'pg_catalog' as $$
declare s public.fz_security_baseline;
begin
  perform public.fz_money_require_owner();
  select * into s from public.fz_security_baseline where item = p_item;
  if not found or s.status = 'revoked' then raise exception 'unknown or no longer present item %', p_item; end if;
  if s.category = 'standing' then raise exception 'a standing finding cannot be acknowledged: remove the grant (or apply the append-only proposal)'; end if;
  update public.fz_security_baseline set status = 'acknowledged', acknowledged_by = 'owner', acknowledged_at = now() where item = p_item;
  insert into public.audit_log (actor, action, target, detail) values ('owner', 'security_acknowledged', left(p_item, 300), '{}'::jsonb);
  return jsonb_build_object('item', p_item, 'status', 'acknowledged', 'note', 'ends when the item goes away (a return alerts again)');
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
declare v jsonb := public.fz_audit_verify(false); d int := greatest(coalesce(p_days, 14), 1); st public.fz_audit_state;
begin
  if coalesce(nullif(current_setting('role', true), ''), 'none') in ('fz_jarvis', 'fz_office_agent', 'fz_auditor') then
    raise exception 'the security report is for the owner' using errcode = '42501';
  end if;
  select * into st from public.fz_audit_state where id = 1;
  return jsonb_build_object(
    'standing', coalesce((select jsonb_agg(x.item order by x.item) from public.fz_privileged_items() x where x.category = 'standing'), '[]'::jsonb),
    'unexpected', coalesce((select jsonb_agg(jsonb_build_object('item', x.item, 'status', coalesce(s.status, 'NEW (watch not run yet)'), 'generation', s.generation) order by x.item)
                              from public.fz_privileged_items() x left join public.fz_security_baseline s on s.item = x.item
                             where x.category = 'grant' and not x.item in (select public.fz_expected_grants())), '[]'::jsonb),
    'expected_count', (select count(*) from public.fz_expected_grants()),
    'definer_changed', coalesce((select jsonb_agg(jsonb_build_object('function', sig, 'changed_at', changed_at) order by changed_at desc) from public.fz_security_fingerprints where changed_at is not null), '[]'::jsonb),
    'definer_without_search_path', coalesce((select jsonb_agg(p.oid::regprocedure::text order by 1) from pg_proc p
                                               where p.pronamespace = 'public'::regnamespace and p.prosecdef
                                                 and not exists (select 1 from unnest(coalesce(p.proconfig, '{}')) cfg where cfg like 'search_path=%')), '[]'::jsonb),
    'rls_off', coalesce((select jsonb_agg(c.relname::text order by 1) from pg_class c where c.relnamespace = 'public'::regnamespace and c.relkind in ('r', 'p') and not c.relrowsecurity), '[]'::jsonb),
    'identities', coalesce((select jsonb_agg(jsonb_build_object('identity', slug, 'kind', kind, 'status', status, 'role', db_role, 'jti_pinned', token_jti is not null,
                                                               'tokens_valid_after', tokens_valid_after) order by status, slug) from public.fz_identities), '[]'::jsonb),
    'tokens_expiring', coalesce((select jsonb_agg(jsonb_build_object('identity', identity, 'expires_at', expires_at, 'expired', expires_at <= now()) order by expires_at)
                                   from public.fz_token_registry where expires_at <= now() + make_interval(days => d)), '[]'::jsonb),
    'chain', jsonb_build_object('ok', v -> 'ok', 'checked', v -> 'checked', 'break_count', v -> 'break_count', 'head_hash', v -> 'head_hash', 'gaps', v -> 'gaps',
                                'last_full_at', st.last_full_at, 'last_full_ok', st.last_full_ok, 'reinitialised_at', st.reinitialised_at),
    'alerts', coalesce((select jsonb_agg(jsonb_build_object('kind', kind, 'item', item, 'at', at) order by at desc) from (select * from public.fz_security_alerts order by at desc limit 10) a), '[]'::jsonb),
    'note', 'Read-only. Nothing here changes a grant or a token.');
end $$;
revoke all on function public.fz_security_report(integer) from public, anon, authenticated;

do $$
declare f regprocedure;
begin
  for f in select p.oid::regprocedure from pg_proc p where p.pronamespace = 'public'::regnamespace and p.proname in
             ('fz_audit_row_hash', 'fz_audit_link', 'fz_audit_chain_extend', 'fz_audit_verify', 'fz_privileged_items', 'fz_expected_grants', 'fz_security_watch',
              'fz_owner_ack_security', 'fz_owner_register_token', 'fz_security_report') loop
    execute format('revoke all on function %s from fz_jarvis, fz_office_agent, fz_auditor', f);
  end loop;
  if exists (select 1 from pg_namespace where nspname = 'cron') then
    perform cron.unschedule(jobid) from cron.job where jobname = 'fz-security-watch';
    perform cron.schedule('fz-security-watch', '*/15 * * * *', 'select public.fz_security_watch()');
  end if;
end $$;

-- ---------------------------------------------------------------------------------------------------------------------------- after a rollback: seed back, and tell the owner
-- (second review 4) the chain, its state, the baseline and the fingerprints come back from fz_archive, so a rollback + re-apply cannot silently reset them.
do $$
declare v_seeded boolean := false;
begin
  if to_regclass('fz_archive.fz_audit_chain') is not null and not exists (select 1 from public.fz_audit_chain) then
    execute 'insert into public.fz_audit_chain (audit_id, kind, row_hash, chain_hash, chained_at) select audit_id, kind, row_hash, chain_hash, chained_at from fz_archive.fz_audit_chain order by seq';
    v_seeded := true;
  end if;
  if to_regclass('fz_archive.fz_audit_state') is not null and v_seeded then
    execute 'update public.fz_audit_state s set genesis_id = a.genesis_id, last_full_at = a.last_full_at, last_full_ok = a.last_full_ok from fz_archive.fz_audit_state a where s.id = 1 and a.id = 1';
  end if;
  if to_regclass('fz_archive.fz_security_baseline') is not null and not exists (select 1 from public.fz_security_baseline) then
    execute 'insert into public.fz_security_baseline select * from fz_archive.fz_security_baseline on conflict do nothing';
    v_seeded := true;
  end if;
  if to_regclass('fz_archive.fz_security_fingerprints') is not null and not exists (select 1 from public.fz_security_fingerprints) then
    execute 'insert into public.fz_security_fingerprints select * from fz_archive.fz_security_fingerprints on conflict do nothing';
  end if;
  if v_seeded then
    update public.fz_audit_state set reinitialised_at = now(), checkpoint_seq = null, checkpoint_hash = null where id = 1;   -- the next watch verifies the whole re-seeded chain
    insert into public.fz_security_alerts (kind, item, dedupe_key, detail) values ('reinitialised', 'chain/baseline', 'reinitialised:' || now()::text, '{}'::jsonb) on conflict do nothing;
    if exists (select 1 from public.agents where slug = 'jarvis') then
      insert into public.owner_messages (from_agent, kind, channel, body) values ('jarvis', 'health', 'telegram',
        'SECURITY: the audit chain and the security baseline were re-initialised (the security migration was rolled back and applied again). They were restored from the archive and will be verified in full on the next watch run. If you did not do this, treat it as an incident.');
    end if;
    insert into public.audit_log (actor, action, target, detail) values ('migration', 'security_reinitialised', 'fz_audit_chain', jsonb_build_object('chain_rows', (select count(*) from public.fz_audit_chain)));
  end if;
end $$;

-- ---------------------------------------------------------------------------------------------------------------------------- registry (M1) + backup classification
insert into public.fz_table_registry (relname, scope, scope_column, data_class, fz_read, fz_write, fz_insert_columns, fz_update_columns, note) values
  ('fz_audit_chain',           'group', null, 'confidential', false, '{}', null, null, 'security: append-only hash chain over audit_log'),
  ('fz_audit_pending',         'group', null, 'confidential', false, '{}', null, null, 'security: audit rows seen, not yet chained (hash as first seen)'),
  ('fz_audit_state',           'group', null, 'confidential', false, '{}', null, null, 'security: chain genesis, checkpoint, last full scan'),
  ('fz_security_baseline',     'group', null, 'confidential', false, '{}', null, null, 'security: privileged items seen (expected / alerted / acknowledged / revoked)'),
  ('fz_security_fingerprints', 'group', null, 'confidential', false, '{}', null, null, 'security: SECURITY DEFINER body + settings fingerprints'),
  ('fz_security_alerts',       'group', null, 'confidential', false, '{}', null, null, 'security: append-only alerts sent to the owner'),
  ('fz_token_registry',        'group', null, 'confidential', false, '{}', null, null, 'security: minted scoped tokens (id and expiry only, never the token)')
on conflict (relname) do update set scope = excluded.scope, scope_column = excluded.scope_column, data_class = excluded.data_class, fz_read = excluded.fz_read,
  fz_write = excluded.fz_write, fz_insert_columns = excluded.fz_insert_columns, fz_update_columns = excluded.fz_update_columns, note = excluded.note;

-- backup classification (PROTECTED: owner approval): same rows as 20261128_office_money_v1 plus the seven security tables ('secret': not in the off-site export)
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
    -- Security hardening M4 (20261130): 'secret' = not in the off-site export (as the M1 / M2 registries); after a restore the chain is rebuilt from the restored audit_log.
    ('fz_audit_chain', 'secret', 'append-only hash chain over audit_log; rebuilt after a restore'),
    ('fz_audit_pending', 'secret', 'audit rows seen but not chained yet'),
    ('fz_audit_state', 'secret', 'chain genesis / checkpoint / last full scan'),
    ('fz_security_baseline', 'secret', 'privileged items seen and their status'),
    ('fz_security_fingerprints', 'secret', 'SECURITY DEFINER body + settings fingerprints'),
    ('fz_security_alerts', 'secret', 'append-only security alerts sent to the owner'),
    ('fz_token_registry', 'secret', 'minted scoped token ids and expiry (never a token)')
  ) v (table_name, data_class, note)
$$;
revoke all on function public.backup_classification() from public, anon, authenticated;
reset lock_timeout;
