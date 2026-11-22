-- FENDEZY GROUP Phase 1, milestone M1 "Org & Access core": office tenancy + scoped identities. ADDITIVE. Nothing is deleted; service_role keeps working exactly as before.
-- Design (docs/architecture/PHASE1_M1_ORG_ACCESS.md has the full write-up and the table classification):
--   * ONE database. Tenancy is an `office_id` column (or, for FF Marketing client tables, the existing `workspace_id` -> the workspace's office in fz_workspace_offices) plus
--     RLS policies that apply ONLY to three new narrow roles. No schema or database per office. client_workspaces gets NO new column: ws_guard (never-edit list) screens
--     every column of a workspace row and refuses a uuid full of digits as an account number, so the workspace -> office map is its own table.
--   * fz_offices: the parent "group" scope + eight offices, all DORMANT. Fixed ids, so column defaults are constants (no table rewrite, no backfill scan).
--   * fz_identities: who may act (owner, jarvis, office managers, agents, auditor, backup_reader, release). A scoped JWT only NAMES an identity; the registry decides.
--     Revoking an identity (or moving tokens_valid_after) kills its tokens at once, without rotating the project's JWT secret.
--   * Roles fz_jarvis (group scope, read + task writes, NO approvals / money), fz_office_agent (one office), fz_auditor (group scope, read-only). NOLOGIN, no BYPASSRLS,
--     reached exactly like backup_reader: PostgREST switches to the JWT's `role` claim through `authenticator`.
--   * fz_table_registry: EVERY table in public classified (group | office | shared) with a data class (public | internal | confidential | client_restricted). Grants and
--     policies for the fz roles are generated FROM the registry, so it is the single source of truth; an unregistered table gets nothing (fail closed).
--   * fz_authorize_action(): an office layer IN FRONT OF authorize_action(). It can only refuse more (dormant office, office policy, office limits); it then calls the
--     unchanged authorize_action() for the group decision. authorize_action / action_policy are NOT modified (money control on the never-edit list).
--   * Org re-seed: client_workspaces (and through it every ws_* / ffm_* row) -> ff-marketing; everything else -> group. Old agents / departments / ventures are archived
--     (archived_at stamp; agents and departments that are not live are paused) ONCE, with every decision logged in fz_org_archive. Anything live is KEPT.
-- Ordered BEFORE the lockdown (R3): it only grants to the NEW fz roles (never to public / anon / authenticated), and the lockdown's blanket service_role grant is harmless here
-- (every fz_owner_* function checks is_app_owner() itself). Rollback: ops/rollback_org_access.sql. Safe to re-run.

-- Apply while the bot is idle (short ALTERs on agents / tasks / missions / memory / departments / ventures): give up instead of queueing behind a long transaction.
set lock_timeout = '5s';

-- ---------------------------------------------------------------------------------------------------------------------------- roles (the backup_reader pattern)
do $$
declare r text;
begin
  foreach r in array array['fz_jarvis', 'fz_office_agent', 'fz_auditor'] loop
    if not exists (select 1 from pg_roles where rolname = r) then
      execute format('create role %I nologin noinherit nobypassrls nocreatedb nocreaterole noreplication', r);
    end if;
    execute format('alter role %I set statement_timeout = %L', r, '8s');
    if exists (select 1 from pg_roles where rolname = 'authenticator') then
      begin
        execute format('grant %I to authenticator', r);                      -- PostgREST switches to the JWT's role through authenticator
      exception when others then
        raise notice 'could not grant % to authenticator (%): the owner must run: grant % to authenticator;', r, sqlerrm, r;
      end;
    end if;
  end loop;
end $$;
grant usage on schema public to fz_jarvis, fz_office_agent, fz_auditor;

-- ---------------------------------------------------------------------------------------------------------------------------- registry tables
create table if not exists public.fz_offices (
  id uuid primary key,
  slug text not null unique check (slug ~ '^[a-z][a-z0-9-]{1,40}$'),
  title text not null check (length(title) between 2 and 80),
  kind text not null check (kind in ('group', 'office')),
  purpose text not null default '',
  status text not null default 'dormant' check (status in ('dormant', 'active', 'paused', 'closed')),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  updated_by text not null default 'migration'
);
create unique index if not exists fz_offices_one_group on public.fz_offices ((kind)) where kind = 'group';

create table if not exists public.fz_identities (
  id uuid primary key default gen_random_uuid(),
  slug text not null unique check (slug ~ '^[a-z][a-z0-9:-]{1,80}$'),
  kind text not null check (kind in ('owner', 'jarvis', 'office_manager', 'agent', 'auditor', 'backup_reader', 'release')),
  office_id uuid not null,                                               -- the group id for group-scope identities
  db_role text check (db_role is null or db_role in ('fz_jarvis', 'fz_office_agent', 'fz_auditor', 'backup_reader')),
  agent_slug text,
  status text not null default 'dormant' check (status in ('dormant', 'active', 'revoked')),
  token_jti text,                                                        -- when set, only a token carrying this jti is accepted
  tokens_valid_after timestamptz,                                        -- tokens issued (iat) before this are refused: revokes every older token at once
  note text not null default '',
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  updated_by text not null default 'migration'
);

create table if not exists public.fz_table_registry (
  relname text primary key,
  scope text not null check (scope in ('group', 'office', 'shared')),
  scope_column text check (scope_column is null or scope_column in ('office_id', 'workspace_id', 'workspace_self', 'via_parent')),
  data_class text not null check (data_class in ('public', 'internal', 'confidential', 'client_restricted')),
  fz_read boolean not null default false,                                -- scoped identities may SELECT (rows filtered by the scope column)
  fz_write text[] not null default '{}' check (fz_write <@ array['insert', 'update']::text[]),   -- never delete: no history is removed through a scoped identity
  fz_insert_columns text[],
  fz_update_columns text[],
  note text not null default '',
  check (scope = 'office' or (not fz_read and fz_write = '{}') or relname like 'fz\_%'),
  check (scope <> 'office' or scope_column is not null),
  check (fz_write = '{}' or (fz_read and scope_column = 'office_id'))
);

-- which office serves each client workspace. A workspace with no row belongs to FF Marketing (every client workspace today is FF Marketing's).
create table if not exists public.fz_workspace_offices (
  workspace_id uuid primary key,
  office_id uuid not null,
  assigned_by text not null default 'migration',
  assigned_at timestamptz not null default now()
);

create table if not exists public.fz_office_action_policy (
  office_id uuid not null,
  action text not null check (action ~ '^[a-z][a-z0-9_]{2,60}$'),
  allowed boolean not null default true,
  max_cents_per_action integer check (max_cents_per_action is null or max_cents_per_action >= 0),
  max_count_per_day integer check (max_count_per_day is null or max_count_per_day >= 0),
  updated_by text not null,
  updated_at timestamptz not null default now(),
  primary key (office_id, action)
);

create table if not exists public.fz_org_archive (
  id bigint generated always as identity primary key,
  entity text not null check (entity in ('reseed', 'agent', 'department', 'venture')),
  key text not null,
  decision text not null check (decision in ('archived', 'kept', 'run')),
  prior_status text,
  new_status text,
  reason text not null,
  at timestamptz not null default now()
);
create unique index if not exists fz_org_archive_once on public.fz_org_archive (entity, key);

do $$
declare t text;
begin
  foreach t in array array['fz_offices', 'fz_identities', 'fz_table_registry', 'fz_workspace_offices', 'fz_office_action_policy', 'fz_org_archive'] loop
    execute format('alter table public.%I enable row level security', t);
    execute format('revoke all on public.%I from public, anon, authenticated, service_role', t);   -- default privileges grant them on Supabase / the replica: take them back
  end loop;
end $$;
grant select on public.fz_offices, public.fz_identities, public.fz_table_registry, public.fz_workspace_offices, public.fz_office_action_policy, public.fz_org_archive to service_role;
revoke all on sequence public.fz_org_archive_id_seq from public, anon, authenticated, service_role;

-- the archive log is append-only (it is the record of what the re-seed did and what the rollback restores)
create or replace function public.fz_append_only() returns trigger
language plpgsql set search_path to 'pg_catalog' as $$
begin
  raise exception '% is append-only', tg_relname using errcode = '42501';
end $$;
revoke all on function public.fz_append_only() from public, anon, authenticated;
drop trigger if exists fz_org_archive_append_only on public.fz_org_archive;
create trigger fz_org_archive_append_only before update or delete on public.fz_org_archive for each row execute function public.fz_append_only();
drop trigger if exists fz_org_archive_no_truncate on public.fz_org_archive;
create trigger fz_org_archive_no_truncate before truncate on public.fz_org_archive for each statement execute function public.fz_append_only();

-- ---------------------------------------------------------------------------------------------------------------------------- seed: the group + eight offices (all DORMANT)
-- on conflict do nothing: re-applying never resets a status the owner changed
insert into public.fz_offices (id, slug, title, kind, purpose, status) values
  ('f0000000-0000-4000-8000-000000000000', 'group',            'Fendezy Group',     'group',  'Parent scope: Jarvis, the owner, shared services', 'active'),
  ('f0000000-0000-4000-8000-000000000001', 'b2b-records',      'B2B Records',       'office', 'Music label', 'dormant'),
  ('f0000000-0000-4000-8000-000000000002', 'donna',            'Donna',             'office', 'AI agency', 'dormant'),
  ('f0000000-0000-4000-8000-000000000003', 'the-trap',         'The Trap',          'office', 'E-commerce', 'dormant'),
  ('f0000000-0000-4000-8000-000000000004', 'wolf-squad',       'Wolf Squad',        'office', 'Prospecting and sales', 'dormant'),
  ('f0000000-0000-4000-8000-000000000005', 'pimp-ai',          'Pimp AI',           'office', 'AI model brands', 'dormant'),
  ('f0000000-0000-4000-8000-000000000006', 'monopoly',         'Monopoly',          'office', 'Real estate', 'dormant'),
  ('f0000000-0000-4000-8000-000000000007', 'ff-marketing',     'FF Marketing',      'office', 'Advertising (built; dry run)', 'dormant'),
  ('f0000000-0000-4000-8000-000000000008', 'fruition-factory', 'Fruition Factory',  'office', 'New ventures', 'dormant')
on conflict (slug) do nothing;

-- identities. Office managers are dormant with their office; jarvis + its three helpers and the auditor are active but useless until a signed token exists.
insert into public.fz_identities (slug, kind, office_id, db_role, agent_slug, status, note) values
  ('owner',          'owner',         'f0000000-0000-4000-8000-000000000000', null,             null,           'active',  'the Chairman: app login (is_app_owner) and Telegram; never a scoped token'),
  ('jarvis',         'jarvis',        'f0000000-0000-4000-8000-000000000000', 'fz_jarvis',      'jarvis',       'active',  'group scope; no approvals, no money controls'),
  ('jarvis-chat',    'agent',         'f0000000-0000-4000-8000-000000000000', 'fz_jarvis',      'jarvis-chat',  'dormant', 'Jarvis chat (group); dormant until a token is minted for it'),
  ('jarvis-core',    'agent',         'f0000000-0000-4000-8000-000000000000', 'fz_jarvis',      'jarvis-core',  'dormant', 'Jarvis core v2 (group); dormant until a token is minted for it'),
  ('jarvis-hands',   'agent',         'f0000000-0000-4000-8000-000000000000', 'fz_jarvis',      'jarvis-hands', 'dormant', 'Jarvis hands (group); dormant until a token is minted for it'),
  ('auditor',        'auditor',       'f0000000-0000-4000-8000-000000000000', 'fz_auditor',     null,           'active',  'group read-only'),
  ('backup-reader',  'backup_reader', 'f0000000-0000-4000-8000-000000000000', 'backup_reader',  null,           'active',  'existing backup identity (20261121_postlock_backup_identity_v1); unchanged, listed for completeness'),
  ('release',        'release',       'f0000000-0000-4000-8000-000000000000', null,             null,           'dormant', 'release pipeline (owner-run migrations); no database role in M1'),
  ('office:b2b-records:manager',      'office_manager', 'f0000000-0000-4000-8000-000000000001', 'fz_office_agent', null, 'dormant', 'B2B Records office manager'),
  ('office:donna:manager',            'office_manager', 'f0000000-0000-4000-8000-000000000002', 'fz_office_agent', null, 'dormant', 'Donna office manager'),
  ('office:the-trap:manager',         'office_manager', 'f0000000-0000-4000-8000-000000000003', 'fz_office_agent', null, 'dormant', 'The Trap office manager'),
  ('office:wolf-squad:manager',       'office_manager', 'f0000000-0000-4000-8000-000000000004', 'fz_office_agent', null, 'dormant', 'Wolf Squad office manager'),
  ('office:pimp-ai:manager',          'office_manager', 'f0000000-0000-4000-8000-000000000005', 'fz_office_agent', null, 'dormant', 'Pimp AI office manager'),
  ('office:monopoly:manager',         'office_manager', 'f0000000-0000-4000-8000-000000000006', 'fz_office_agent', null, 'dormant', 'Monopoly office manager'),
  ('office:ff-marketing:manager',     'office_manager', 'f0000000-0000-4000-8000-000000000007', 'fz_office_agent', null, 'dormant', 'FF Marketing office manager'),
  ('office:fruition-factory:manager', 'office_manager', 'f0000000-0000-4000-8000-000000000008', 'fz_office_agent', null, 'dormant', 'Fruition Factory office manager')
on conflict (slug) do nothing;

-- ---------------------------------------------------------------------------------------------------------------------------- office columns (constant defaults: no rewrite)
-- No foreign key to fz_offices on purpose: the off-site backup does not export a table that references a non-exported one, and fz_offices is not exported
-- (backup_export_policy). An unknown office_id is simply invisible to every office identity (fail closed); fz_org_status() reports orphans.
alter table public.agents            add column if not exists office_id uuid not null default 'f0000000-0000-4000-8000-000000000000';
alter table public.departments       add column if not exists office_id uuid not null default 'f0000000-0000-4000-8000-000000000000';
alter table public.ventures          add column if not exists office_id uuid not null default 'f0000000-0000-4000-8000-000000000000';
alter table public.missions          add column if not exists office_id uuid not null default 'f0000000-0000-4000-8000-000000000000';
alter table public.tasks             add column if not exists office_id uuid not null default 'f0000000-0000-4000-8000-000000000000';
alter table public.memory            add column if not exists office_id uuid not null default 'f0000000-0000-4000-8000-000000000000';
alter table public.agents            add column if not exists archived_at timestamptz;
alter table public.departments       add column if not exists archived_at timestamptz;
alter table public.ventures          add column if not exists archived_at timestamptz;
create index if not exists agents_office_id on public.agents (office_id);
create index if not exists departments_office_id on public.departments (office_id);
create index if not exists ventures_office_id on public.ventures (office_id);
create index if not exists missions_office_id on public.missions (office_id);
create index if not exists tasks_office_id on public.tasks (office_id);
create index if not exists memory_office_id on public.memory (office_id);

-- ---------------------------------------------------------------------------------------------------------------------------- identity helpers
-- The claims PostgREST put on this transaction (request.jwt.claims). NULL outside an API request.
create or replace function public.fz_claims() returns jsonb
language plpgsql stable security invoker set search_path to 'pg_catalog' as $$
begin
  return nullif(current_setting('request.jwt.claims', true), '')::jsonb;
exception when others then
  return null;
end $$;
revoke all on function public.fz_claims() from public, anon, authenticated;

-- The resolved identity of this request, or no row. Every rule is checked here, in one place:
--   the SESSION role (what PostgREST set from the JWT; a SECURITY DEFINER caller does not change it) is one of the fz roles and equals the token's role claim; the token carries
--   no `sub` (so it can never pass for a signed-in app user); the named identity exists, is active and is bound to that role; an office identity's office is active; the
--   optional office claim matches; a pinned jti matches; the token was issued after tokens_valid_after.
create or replace function public.fz_identity_now() returns table (slug text, kind text, office_id uuid, office_slug text, db_role text, is_group boolean)
language plpgsql stable security definer set search_path to 'pg_catalog' as $$
declare r text := coalesce(nullif(current_setting('role', true), ''), 'none'); c jsonb := public.fz_claims(); i public.fz_identities; o public.fz_offices; iat numeric;
begin
  if r not in ('fz_jarvis', 'fz_office_agent', 'fz_auditor') or c is null then return; end if;
  if c ->> 'role' is distinct from r or c ? 'sub' then return; end if;
  select * into i from public.fz_identities x where x.slug = c ->> 'identity' and x.status = 'active' and x.db_role = r;
  if not found then return; end if;
  select * into o from public.fz_offices x where x.id = i.office_id;
  if not found or o.status <> 'active' then return; end if;
  if c ? 'office' and c ->> 'office' is distinct from o.slug then return; end if;
  if i.token_jti is not null and c ->> 'jti' is distinct from i.token_jti then return; end if;
  if i.tokens_valid_after is not null then
    begin iat := (c ->> 'iat')::numeric; exception when others then return; end;
    if iat is null or to_timestamp(iat) <= i.tokens_valid_after then return; end if;
  end if;
  if (r = 'fz_office_agent') = (o.kind = 'group') then return; end if;   -- an office role must be bound to an office, a group role to the group
  return query select i.slug, i.kind, o.id, o.slug, r, o.kind = 'group';
end $$;
revoke all on function public.fz_identity_now() from public, anon, authenticated;

create or replace function public.current_identity() returns text
language sql stable security definer set search_path to 'pg_catalog' as $$ select slug from public.fz_identity_now() $$;
revoke all on function public.current_identity() from public, anon, authenticated;

create or replace function public.current_office() returns text
language sql stable security definer set search_path to 'pg_catalog' as $$ select office_slug from public.fz_identity_now() $$;
revoke all on function public.current_office() from public, anon, authenticated;

create or replace function public.current_office_id() returns uuid
language sql stable security definer set search_path to 'pg_catalog' as $$ select office_id from public.fz_identity_now() $$;
revoke all on function public.current_office_id() from public, anon, authenticated;

create or replace function public.is_group_scope() returns boolean
language sql stable security definer set search_path to 'pg_catalog' as $$ select coalesce((select is_group from public.fz_identity_now()), false) $$;
revoke all on function public.is_group_scope() from public, anon, authenticated;

-- Offices whose rows of p_table the current identity may READ. Group scope: every office, except client_restricted tables (client personal data stays with the office that
-- serves the client). Office scope: its own office only. No identity, unregistered table or fz_read=false: none.
create or replace function public.fz_readable_offices(p_table text) returns uuid[]
language plpgsql stable security definer set search_path to 'pg_catalog' as $$
declare i record; g public.fz_table_registry;
begin
  select * into i from public.fz_identity_now();
  if i.slug is null then return '{}'; end if;
  select * into g from public.fz_table_registry where relname = p_table;
  if not found or not g.fz_read or g.scope <> 'office' then return '{}'; end if;
  if i.is_group then
    if g.data_class = 'client_restricted' then return '{}'; end if;
    return array(select id from public.fz_offices);
  end if;
  return array[i.office_id];
end $$;
revoke all on function public.fz_readable_offices(text) from public, anon, authenticated;

-- Offices whose rows of p_table the current identity may WRITE (the auditor never writes): ACTIVE offices only (the group is always active).
create or replace function public.fz_writable_offices(p_table text) returns uuid[]
language plpgsql stable security definer set search_path to 'pg_catalog' as $$
declare i record; g public.fz_table_registry;
begin
  select * into i from public.fz_identity_now();
  if i.slug is null or i.db_role = 'fz_auditor' then return '{}'; end if;
  select * into g from public.fz_table_registry where relname = p_table;
  if not found or g.fz_write = '{}' or g.scope <> 'office' then return '{}'; end if;
  if i.is_group then
    if g.data_class = 'client_restricted' then return '{}'; end if;
    return array(select id from public.fz_offices where status = 'active');
  end if;
  return array[i.office_id];                                              -- fz_identity_now() already requires the office to be active
end $$;
revoke all on function public.fz_writable_offices(text) from public, anon, authenticated;

-- S1: an agent a scoped identity may hand a task to: an agent of the SAME office as the task (so an office token cannot queue work for a group agent such as builder).
create or replace function public.fz_agent_in_office(p_agent text, p_office uuid) returns boolean
language sql stable security definer set search_path to 'pg_catalog' as $$
  select p_agent is null or exists (select 1 from public.agents a where a.slug = p_agent and a.office_id = p_office)
$$;
revoke all on function public.fz_agent_in_office(text, uuid) from public, anon, authenticated;

-- Client workspaces whose rows (the workspace itself, and ws_* / ffm_* rows by workspace_id) the current identity may read: the workspaces of ITS office. Group scope
-- gets none in M1 (client data stays with the office that serves the client).
create or replace function public.fz_readable_workspaces(p_table text) returns uuid[]
language sql stable security definer set search_path to 'pg_catalog' as $$
  select case when public.is_group_scope() then '{}'::uuid[] else
    coalesce(array(select w.id from public.client_workspaces w left join public.fz_workspace_offices m on m.workspace_id = w.id
                    where coalesce(m.office_id, 'f0000000-0000-4000-8000-000000000007'::uuid) = any (public.fz_readable_offices(p_table))), '{}') end
$$;
revoke all on function public.fz_readable_workspaces(text) from public, anon, authenticated;

-- Who am I, for the token holder (and the bot's install check). Says WHY a token is not accepted, never anything about other identities.
create or replace function public.fz_whoami() returns jsonb
language plpgsql stable security definer set search_path to 'pg_catalog' as $$
declare i record; r text := coalesce(nullif(current_setting('role', true), ''), 'none'); c jsonb := public.fz_claims(); x public.fz_identities;
begin
  select * into i from public.fz_identity_now();
  if i.slug is not null then
    return jsonb_build_object('ok', true, 'identity', i.slug, 'kind', i.kind, 'office', i.office_slug, 'scope', case when i.is_group then 'group' else 'office' end, 'role', i.db_role);
  end if;
  select * into x from public.fz_identities where slug = c ->> 'identity';
  return jsonb_build_object('ok', false, 'role', r, 'reason', case
    when r not in ('fz_jarvis', 'fz_office_agent', 'fz_auditor') then 'not a scoped identity session'
    when c is null then 'no token claims'
    when c ->> 'role' is distinct from r then 'token role does not match the session role'
    when c ? 'sub' then 'token carries a sub claim (refused: it could pass for an app user)'
    when x.id is null then 'unknown identity'
    when x.status <> 'active' then 'identity is ' || x.status
    when x.db_role is distinct from r then 'identity is not bound to this role'
    when not exists (select 1 from public.fz_offices o where o.id = x.office_id and o.status = 'active') then 'office is not active'
    else 'token refused (office claim, jti or issue time)' end);
end $$;
revoke all on function public.fz_whoami() from public, anon, authenticated;

-- ---------------------------------------------------------------------------------------------------------------------------- the table registry (classification of EVERY table)
-- scope: group = owner / holding / Jarvis; office = rows belong to one office (by office_id, or by workspace_id -> client_workspaces.office_id, or via a parent row);
--        shared = one service every office relies on, owned by the group (suppression lists, consent gate, redaction keys, reference vocabularies).
-- data_class: public < internal < confidential < client_restricted. Group-scope identities never read client_restricted rows directly; offices read only their own rows.
-- fz_read / fz_write: what the scoped roles get. M1 opens READ on the six office_id tables and WRITE on tasks only; everything else stays service-key-only (unchanged)
-- until a later milestone reviews it table by table. The FF Marketing client tables (client_workspaces, ws_*, ffm_*) are office-owned and mapped to their office, but
-- keep their reviewed design for now: RLS on, NO policy, no grant to anyone but the service key, all access through the guarded FFM functions (sqltests W2 / F2 / G2
-- assert exactly that). Opening scoped read on them is an M2 step with the owner's sign-off; fz_readable_workspaces() is ready for it. Consent tables: never-edit list.
insert into public.fz_table_registry (relname, scope, scope_column, data_class, fz_read, fz_write, fz_insert_columns, fz_update_columns, note) values
  -- office-owned, by office_id
  ('agents',            'office', 'office_id',    'internal',          true,  '{}', null, null, 'agent definitions; old agents archived or kept (fz_org_archive)'),
  ('departments',       'office', 'office_id',    'internal',          true,  '{}', null, null, 'old departments archived or kept'),
  ('ventures',          'office', 'office_id',    'internal',          true,  '{}', null, null, 'old ventures archived or kept'),
  ('missions',          'office', 'office_id',    'internal',          true,  '{}', null, null, 'missions; budget and owner decision columns: read-only for scoped identities'),
  ('tasks',             'office', 'office_id',    'internal',          true,  '{insert,update}',
     '{office_id,venture_id,assigned_agent,title,detail,priority,due_at,dedupe_key}', '{assigned_agent,title,detail,priority,due_at}',
     'work items; the only table scoped identities may write in M1: no status / result / mission columns, only agents of the same office, office and author stamped by trigger'),
  ('memory',            'office', 'office_id',    'internal',          true,  '{}', null, null, 'agent memory'),
  ('client_workspaces', 'office', 'workspace_self', 'confidential',    false,  '{}', null, null, 'FF Marketing client tenants; office in fz_workspace_offices (no row = ff-marketing)'),
  -- office-owned, by workspace_id (FF Marketing tenancy)
  ('ws_campaigns',          'office', 'workspace_id', 'confidential',      false,  '{}', null, null, 'client campaigns'),
  ('ws_leads',              'office', 'workspace_id', 'client_restricted', false,  '{}', null, null, 'client leads: personal data, owning office only'),
  ('ws_ledger',             'office', 'workspace_id', 'confidential',      false,  '{}', null, null, 'client spend ledger (read-only)'),
  ('ws_approved_terms',     'office', 'workspace_id', 'internal',          false,  '{}', null, null, 'per-workspace approved terms (rows without a workspace are global and invisible to offices)'),
  ('ffm_ad_sets',           'office', 'workspace_id', 'confidential',      false,  '{}', null, null, 'ad sets'),
  ('ffm_creatives',         'office', 'workspace_id', 'confidential',      false,  '{}', null, null, 'creatives'),
  ('ffm_approvals',         'office', 'workspace_id', 'confidential',      false,  '{}', null, null, 'owner approvals of client work (read-only: nobody scoped can approve)'),
  ('ffm_onboarding_items',  'office', 'workspace_id', 'confidential',      false,  '{}', null, null, 'onboarding inputs'),
  ('ffm_engine_briefs',     'office', 'workspace_id', 'confidential',      false,  '{}', null, null, 'engine briefs'),
  ('ffm_engine_packs',      'office', 'workspace_id', 'confidential',      false,  '{}', null, null, 'engine packs'),
  ('ffm_routing_rules',     'office', 'workspace_id', 'confidential',      false,  '{}', null, null, 'lead routing rules'),
  ('ffm_route_log',         'office', 'workspace_id', 'client_restricted', false,  '{}', null, null, 'lead routing log'),
  ('ffm_run_launches',      'office', 'workspace_id', 'confidential',      false,  '{}', null, null, 'campaign launches'),
  ('ffm_run_leads',         'office', 'workspace_id', 'client_restricted', false,  '{}', null, null, 'leads of a launch'),
  ('ffm_run_settings',      'office', 'workspace_id', 'confidential',      false,  '{}', null, null, 'run settings'),
  ('ffm_consent_captures',  'office', 'workspace_id', 'client_restricted', false, '{}', null, null, 'CONSENT (never-edit list): no scoped access'),
  ('ffm_consent_log',       'office', 'workspace_id', 'client_restricted', false, '{}', null, null, 'CONSENT (never-edit list): no scoped access'),
  ('ffm_consent_settings',  'office', 'workspace_id', 'client_restricted', false, '{}', null, null, 'CONSENT (never-edit list): no scoped access'),
  ('ffm_consent_wordings',  'office', 'workspace_id', 'client_restricted', false, '{}', null, null, 'CONSENT (never-edit list): no scoped access'),
  -- office-owned through a parent row (launch / lead); no scoped access in M1
  ('ffm_run_budgets',       'office', 'via_parent',   'confidential',      false, '{}', null, null, 'money: launch budgets (via launch_id)'),
  ('ffm_run_email_batches', 'office', 'via_parent',   'confidential',      false, '{}', null, null, 'via launch_id'),
  ('ffm_run_emails',        'office', 'via_parent',   'client_restricted', false, '{}', null, null, 'via launch_id / lead_id'),
  ('ffm_run_metrics',       'office', 'via_parent',   'confidential',      false, '{}', null, null, 'via launch_id'),
  ('ffm_run_objects',       'office', 'via_parent',   'confidential',      false, '{}', null, null, 'via launch_id'),
  ('ffm_run_receipts',      'office', 'via_parent',   'confidential',      false, '{}', null, null, 'money: platform receipts (via launch_id)'),
  ('ffm_run_touches',       'office', 'via_parent',   'client_restricted', false, '{}', null, null, 'via lead_id'),
  -- shared services (owned by the group, used by every office)
  ('contact_suppressions',     'shared', null, 'client_restricted', false, '{}', null, null, 'opt-out list for every office'),
  ('ffm_phone_suppressions',   'shared', null, 'client_restricted', false, '{}', null, null, 'phone opt-outs (consent)'),
  ('ffm_suppression_hashes',   'shared', null, 'client_restricted', false, '{}', null, null, 'suppression integrity (consent)'),
  ('ffm_suppression_expected', 'shared', null, 'client_restricted', false, '{}', null, null, 'suppression integrity (consent)'),
  ('ffm_outreach_gate',        'shared', null, 'confidential',      false, '{}', null, null, 'outreach gate (consent)'),
  ('ffm_gate_config',          'shared', null, 'confidential',      false, '{}', null, null, 'outreach gate config (consent)'),
  ('ffm_epoch',                'shared', null, 'confidential',      false, '{}', null, null, 'redaction epoch (backup)'),
  ('ffm_sender_mark',          'shared', null, 'confidential',      false, '{}', null, null, 'sender attestation (consent)'),
  ('ffm_restore_markers',      'shared', null, 'confidential',      false, '{}', null, null, 'restore markers (audit)'),
  ('ffm_secrets',              'shared', null, 'confidential',      false, '{}', null, null, 'keys'),
  ('ffm_redaction_keys',       'shared', null, 'confidential',      false, '{}', null, null, 'backup redaction keys'),
  ('ffm_redaction_denylist',   'shared', null, 'confidential',      false, '{}', null, null, 'backup redaction deny-list'),
  ('ffm_redaction_found',      'shared', null, 'confidential',      false, '{}', null, null, 'backup redaction cache'),
  ('ffm_onboarding_templates', 'shared', null, 'public',            false, '{}', null, null, 'onboarding checklist templates'),
  ('ws_fixed_phrases',         'shared', null, 'internal',          false, '{}', null, null, 'classifier vocabulary'),
  ('ws_marketing_vocab',       'shared', null, 'internal',          false, '{}', null, null, 'classifier vocabulary'),
  ('ws_place_catalog',         'shared', null, 'public',            false, '{}', null, null, 'place names'),
  ('model_prices',             'shared', null, 'public',            false, '{}', null, null, 'published model prices'),
  ('jarvis_jobs',              'shared', null, 'internal',          false, '{}', null, null, 'Jarvis core job queue (serves every office)'),
  ('jarvis_task_stats',        'shared', null, 'internal',          false, '{}', null, null, 'Jarvis core task statistics'),
  ('jarvis_result_cache',      'shared', null, 'confidential',      false, '{}', null, null, 'cached task output; may contain client data'),
  ('hand_connectors',          'shared', null, 'internal',          false, '{}', null, null, 'Jarvis hands connector registry'),
  -- group-only
  ('action_log',            'group', null, 'confidential',      false, '{}', null, null, 'permission decisions (audit history)'),
  ('action_policy',         'group', null, 'confidential',      false, '{}', null, null, 'autonomy tiers (never-edit list)'),
  ('approval_requests',     'group', null, 'confidential',      false, '{}', null, null, 'owner approvals'),
  ('app_owners',            'group', null, 'confidential',      false, '{}', null, null, 'owner login'),
  ('audit_log',             'group', null, 'confidential',      false, '{}', null, null, 'audit history'),
  ('bank_accounts',         'group', null, 'confidential',      false, '{}', null, null, 'money'),
  ('bank_balances',         'group', null, 'confidential',      false, '{}', null, null, 'money'),
  ('bank_transactions',     'group', null, 'confidential',      false, '{}', null, null, 'money'),
  ('capital_policy',        'group', null, 'confidential',      false, '{}', null, null, 'money controls'),
  ('ledger',                'group', null, 'confidential',      false, '{}', null, null, 'money'),
  ('payment_instructions',  'group', null, 'confidential',      false, '{}', null, null, 'money'),
  ('spend_reservations',    'group', null, 'confidential',      false, '{}', null, null, 'spend gateway'),
  ('llm_calls',             'group', null, 'confidential',      false, '{}', null, null, 'model spend meter'),
  ('system_state',          'group', null, 'confidential',      false, '{}', null, null, 'kill switch and mode'),
  ('waterfall_policy',      'group', null, 'confidential',      false, '{}', null, null, 'money waterfall'),
  ('reconciliation_flags',  'group', null, 'confidential',      false, '{}', null, null, 'money reconciliation'),
  ('owner_messages',        'group', null, 'confidential',      false, '{}', null, null, 'only Jarvis contacts the owner'),
  ('web_messages',          'group', null, 'confidential',      false, '{}', null, null, 'owner chat'),
  ('push_config',           'group', null, 'confidential',      false, '{}', null, null, 'push keys'),
  ('push_subscriptions',    'group', null, 'confidential',      false, '{}', null, null, 'push endpoints'),
  ('jarvis_core_config',    'group', null, 'confidential',      false, '{}', null, null, 'Jarvis core switches (never-edit list)'),
  ('jarvis_large_approvals','group', null, 'confidential',      false, '{}', null, null, 'owner approvals'),
  ('jarvis_self_fund_credits','group', null, 'confidential',    false, '{}', null, null, 'money'),
  ('jarvis_seed_staging',   'group', null, 'confidential',      false, '{}', null, null, 'owner profile import'),
  ('jarvis_call_criteria',  'group', null, 'confidential',      false, '{}', null, null, 'emergency call criteria'),
  ('jarvis_call_log',       'group', null, 'confidential',      false, '{}', null, null, 'append-only call ledger'),
  ('jarvis_changelog',      'group', null, 'confidential',      false, '{}', null, null, 'append-only changelog'),
  ('jarvis_job_events',     'group', null, 'confidential',      false, '{}', null, null, 'append-only queue audit'),
  ('jarvis_agent_wakes',    'group', null, 'internal',          false, '{}', null, null, 'agent wake / sleep log'),
  ('executor_registry',     'group', null, 'confidential',      false, '{}', null, null, 'executor limits (never-edit list)'),
  ('executor_runs',         'group', null, 'confidential',      false, '{}', null, null, 'executor audit'),
  ('accounts_registry',     'group', null, 'confidential',      false, '{}', null, null, 'service accounts (vault refs)'),
  ('account_requests',      'group', null, 'confidential',      false, '{}', null, null, 'vendor sign-up requests'),
  ('hand_accounts',         'group', null, 'confidential',      false, '{}', null, null, 'Jarvis hands accounts (vault refs)'),
  ('hand_standing',         'group', null, 'confidential',      false, '{}', null, null, 'owner standing approvals'),
  ('hand_actions',          'group', null, 'confidential',      false, '{}', null, null, 'Jarvis hands action queue'),
  ('org_changes',           'group', null, 'confidential',      false, '{}', null, null, 'org proposals and owner decisions'),
  ('dayjob_days',           'group', null, 'confidential',      false, '{}', null, null, 'owner day-job counters'),
  ('dayjob_targets',        'group', null, 'confidential',      false, '{}', null, null, 'owner day-job targets'),
  ('setter_terms',          'group', null, 'confidential',      false, '{}', null, null, 'sales partner commission terms'),
  ('setter_payouts',        'group', null, 'confidential',      false, '{}', null, null, 'money: sales partner payouts'),
  ('setters',               'group', null, 'client_restricted', false, '{}', null, null, 'sales partner contact data'),
  ('setter_events',         'group', null, 'client_restricted', false, '{}', null, null, 'client names per setter event'),
  ('leads',                 'group', null, 'client_restricted', false, '{}', null, null, 'legacy prospect pipeline (pre-office)'),
  ('outbox',                'group', null, 'client_restricted', false, '{}', null, null, 'legacy outreach drafts'),
  ('lead_replies',          'group', null, 'client_restricted', false, '{}', null, null, 'legacy lead replies'),
  ('deals',                 'group', null, 'client_restricted', false, '{}', null, null, 'legacy deals'),
  ('agent_runs',            'group', null, 'internal',          false, '{}', null, null, 'run summaries'),
  ('alert_state',           'group', null, 'internal',          false, '{}', null, null, 'alert throttling'),
  ('build_requests',        'group', null, 'internal',          false, '{}', null, null, 'build queue'),
  ('company_profile',       'group', null, 'internal',          false, '{}', null, null, 'sender identity of the owner ventures'),
  ('escalations',           'group', null, 'internal',          false, '{}', null, null, 'escalations to Jarvis'),
  ('evidence_sources',      'group', null, 'internal',          false, '{}', null, null, 'fetched public pages'),
  ('handbook',              'group', null, 'internal',          false, '{}', null, null, 'handbook'),
  ('human_handoffs',        'group', null, 'internal',          false, '{}', null, null, 'tasks for the owner'),
  ('ideas',                 'group', null, 'internal',          false, '{}', null, null, 'idea lab'),
  ('integration_status',    'group', null, 'internal',          false, '{}', null, null, 'integration health'),
  ('mission_outcomes',      'group', null, 'internal',          false, '{}', null, null, 'mission outcomes'),
  ('predictions',           'group', null, 'internal',          false, '{}', null, null, 'predictions'),
  ('systems',               'group', null, 'internal',          false, '{}', null, null, 'registered systems'),
  ('tool_registry',         'group', null, 'internal',          false, '{}', null, null, 'tools'),
  ('venture_assets',        'group', null, 'internal',          false, '{}', null, null, 'legacy venture assets (by venture_id)'),
  ('venture_config',        'group', null, 'internal',          false, '{}', null, null, 'legacy venture config'),
  ('venture_goals',         'group', null, 'internal',          false, '{}', null, null, 'legacy venture goals'),
  ('venture_procedures',    'group', null, 'internal',          false, '{}', null, null, 'legacy venture procedures'),
  -- this migration's own tables
  ('fz_offices',              'group', null, 'public',       true,  '{}', null, null, 'the group and the eight offices: every scoped identity may read the list'),
  ('fz_table_registry',       'group', null, 'internal',     true,  '{}', null, null, 'this classification: every scoped identity may read it'),
  ('fz_identities',           'group', null, 'confidential', false, '{}', null, null, 'identity registry (status, pinned jti)'),
  ('fz_workspace_offices',    'group', null, 'confidential', false, '{}', null, null, 'which office serves each client workspace (owner-assigned)'),
  ('fz_office_action_policy', 'group', null, 'confidential', false, '{}', null, null, 'per-office permission overlay (tighten-only)'),
  ('fz_org_archive',          'group', null, 'internal',     false, '{}', null, null, 'append-only log of the org re-seed')
on conflict (relname) do update set scope = excluded.scope, scope_column = excluded.scope_column, data_class = excluded.data_class, fz_read = excluded.fz_read,
  fz_write = excluded.fz_write, fz_insert_columns = excluded.fz_insert_columns, fz_update_columns = excluded.fz_update_columns, note = excluded.note;

-- ---------------------------------------------------------------------------------------------------------------------------- grants + policies, generated from the registry
-- Reset first (so the registry is the only source of what the fz roles hold), then grant table by table. A table that does not exist here is skipped.
do $$
declare r record; t regclass; rls_before boolean; rd text; wr text; roles text := 'fz_jarvis, fz_office_agent, fz_auditor';
begin
  execute 'revoke all on all tables in schema public from ' || roles;
  execute 'revoke all on all sequences in schema public from ' || roles;
  for r in select * from public.fz_table_registry order by relname loop
    t := to_regclass('public.' || quote_ident(r.relname));
    continue when t is null;
    execute format('drop policy if exists fz_scope_read on %s', t);
    execute format('drop policy if exists fz_scope_insert on %s', t);
    execute format('drop policy if exists fz_scope_update on %s', t);
    continue when not r.fz_read;
    select c.relrowsecurity into rls_before from pg_class c where c.oid = t;
    if not rls_before then
      execute format('alter table %s enable row level security', t);
      -- Supabase's service_role has BYPASSRLS; this keeps the same "all rows" for it on any Postgres where it does not (the replica), so nothing that works today changes
      if not exists (select 1 from pg_policy p where p.polrelid = t and p.polname = 'fz_service_all') then
        execute format('create policy fz_service_all on %s for all to service_role using (true) with check (true)', t);
      end if;
    end if;
    execute format('grant select on %s to %s', t, roles);
    if r.relname like 'fz\_%' then
      execute format('create policy fz_scope_read on %s for select to %s using ((select public.current_identity()) is not null)', t, roles);
      continue;
    end if;
    rd := case r.scope_column when 'office_id' then format('office_id = any (coalesce((select public.fz_readable_offices(%L)), ''{}''::uuid[]))', r.relname)
                              when 'workspace_id' then format('workspace_id = any (coalesce((select public.fz_readable_workspaces(%L)), ''{}''::uuid[]))', r.relname)
                              when 'workspace_self' then format('id = any (coalesce((select public.fz_readable_workspaces(%L)), ''{}''::uuid[]))', r.relname) end;
    execute format('create policy fz_scope_read on %s for select to %s using (%s)', t, roles, rd);
    wr := format('office_id = any (coalesce((select public.fz_writable_offices(%L)), ''{}''::uuid[]))', r.relname);
    if 'insert' = any (r.fz_write) then
      execute format('grant insert (%s) on %s to fz_jarvis, fz_office_agent', (select string_agg(quote_ident(c), ', ') from unnest(r.fz_insert_columns) c), t);
      execute format('create policy fz_scope_insert on %s for insert to fz_jarvis, fz_office_agent with check (%s and public.fz_agent_in_office(assigned_agent, office_id))', t, wr);
    end if;
    if 'update' = any (r.fz_write) then
      execute format('grant update (%s) on %s to fz_jarvis, fz_office_agent', (select string_agg(quote_ident(c), ', ') from unnest(r.fz_update_columns) c), t);
      execute format('create policy fz_scope_update on %s for update to fz_jarvis, fz_office_agent using (%s) with check (%s and public.fz_agent_in_office(assigned_agent, office_id))', t, wr, wr);
    end if;
  end loop;
end $$;

-- writes by a scoped identity are stamped: an office identity always writes into ITS office, the author is the identity (not a name the caller typed), and no scoped write
-- moves a row to another office
create or replace function public.fz_stamp_scoped_write() returns trigger
language plpgsql security definer set search_path to 'pg_catalog' as $$
declare i record;
begin
  if coalesce(nullif(current_setting('role', true), ''), 'none') not in ('fz_jarvis', 'fz_office_agent', 'fz_auditor') then return new; end if;
  select * into i from public.fz_identity_now();
  if i.slug is null then raise exception 'scoped write refused: no valid identity' using errcode = '42501'; end if;
  if tg_op = 'INSERT' then
    if not i.is_group then new.office_id := i.office_id; end if;
    new.created_by := i.slug;
  else
    if old.mission_id is not null then raise exception 'scoped write refused: mission tasks are changed only by the mission engine' using errcode = '42501'; end if;
    new.office_id := old.office_id;
    new.created_by := old.created_by;
  end if;
  return new;
end $$;
revoke all on function public.fz_stamp_scoped_write() from public, anon, authenticated;
drop trigger if exists tasks_fz_stamp on public.tasks;
create trigger tasks_fz_stamp before insert or update on public.tasks for each row execute function public.fz_stamp_scoped_write();

-- ---------------------------------------------------------------------------------------------------------------------------- per-office permissions (tighten-only overlay)
-- An office row can only be STRICTER than the group policy: it may forbid an action in that office or set a lower per-action / per-day limit. Anyone with the service key
-- may tighten; relaxing an office rule (allow again, raise or remove a limit) needs the signed-in owner. The group policy itself (action_policy) is untouched.
create or replace function public.fz_office_policy_guard() returns trigger
language plpgsql security definer set search_path to 'pg_catalog' as $$
declare g public.action_policy; owner_ok boolean := coalesce(public.is_app_owner(), false);
begin
  if tg_op = 'DELETE' then
    if not owner_ok then raise exception 'only the owner can remove an office rule (it would relax it)' using errcode = '42501'; end if;
    return old;
  end if;
  select * into g from public.action_policy where action = new.action;
  if not found then raise exception 'unknown action %: office rules can only narrow an existing group action', new.action; end if;
  if g.max_cents_per_action is not null and new.max_cents_per_action is not null and new.max_cents_per_action > g.max_cents_per_action then
    raise exception 'office limit $% is above the group limit $%: an office rule can only be stricter', new.max_cents_per_action / 100.0, g.max_cents_per_action / 100.0;
  end if;
  if g.max_count_per_day is not null and new.max_count_per_day is not null and new.max_count_per_day > g.max_count_per_day then
    raise exception 'office daily count % is above the group count %: an office rule can only be stricter', new.max_count_per_day, g.max_count_per_day;
  end if;
  if tg_op = 'UPDATE' and not owner_ok and (
       (new.allowed and not old.allowed)
    or (old.max_cents_per_action is not null and (new.max_cents_per_action is null or new.max_cents_per_action > old.max_cents_per_action))
    or (old.max_count_per_day is not null and (new.max_count_per_day is null or new.max_count_per_day > old.max_count_per_day))) then
    raise exception 'only the owner can relax an office rule' using errcode = '42501';
  end if;
  new.updated_at := now();
  if owner_ok then new.updated_by := 'owner'; end if;
  insert into public.audit_log (actor, action, target, detail)
    values (new.updated_by, 'office_policy_' || lower(tg_op), 'fz_office_action_policy/' || new.office_id || '/' || new.action,
            jsonb_build_object('allowed', new.allowed, 'per_action', new.max_cents_per_action, 'per_day', new.max_count_per_day));
  return new;
end $$;
revoke all on function public.fz_office_policy_guard() from public, anon, authenticated;
drop trigger if exists fz_office_policy_guard on public.fz_office_action_policy;
create trigger fz_office_policy_guard before insert or update or delete on public.fz_office_action_policy for each row execute function public.fz_office_policy_guard();

create or replace function public.fz_set_office_policy(p_office text, p_action text, p_allowed boolean, p_max_cents_per_action integer default null,
                                                       p_max_count_per_day integer default null, p_by text default 'jarvis') returns jsonb
language plpgsql security definer set search_path to 'pg_catalog' as $$
declare o public.fz_offices;
        v_by text := case when coalesce(public.is_app_owner(), false) then 'owner' else 'bot:' || left(coalesce(nullif(btrim(p_by), ''), 'unknown'), 76) end;   -- a caller cannot record itself as the owner
begin
  select * into o from public.fz_offices where slug = p_office and kind = 'office';
  if not found then raise exception 'unknown office %', p_office; end if;
  insert into public.fz_office_action_policy (office_id, action, allowed, max_cents_per_action, max_count_per_day, updated_by)
    values (o.id, p_action, coalesce(p_allowed, false), p_max_cents_per_action, p_max_count_per_day, v_by)
  on conflict (office_id, action) do update set allowed = excluded.allowed, max_cents_per_action = excluded.max_cents_per_action,
    max_count_per_day = excluded.max_count_per_day, updated_by = excluded.updated_by;
  return jsonb_build_object('office', o.slug, 'action', p_action, 'allowed', coalesce(p_allowed, false), 'max_cents_per_action', p_max_cents_per_action, 'max_count_per_day', p_max_count_per_day);
end $$;
revoke all on function public.fz_set_office_policy(text, text, boolean, integer, integer, text) from public, anon, authenticated;

-- Read-only preview of what authorize_action() would decide (same order of rules), WITHOUT consuming an approval or writing anything. A decision that would need an
-- owner approval is always ask_owner here: a scoped identity can never use (burn) an approval, and an allow it gets is never counted toward the caps.
create or replace function public.fz_policy_preview(p_action text, p_cents integer) returns jsonb
language plpgsql stable security definer set search_path to 'pg_catalog' as $$
declare pol public.action_policy; st record; v_today int; v_week int; v_start timestamptz; c int := greatest(coalesce(p_cents, 0), 0);
begin
  select kill_switch, mode into st from public.system_state where id = 1;
  select * into pol from public.action_policy where action = p_action;
  if coalesce(st.kill_switch, true) then return jsonb_build_object('decision', 'deny', 'reason', 'Kill switch is on.', 'tier', pol.tier); end if;
  if pol.action is null then return jsonb_build_object('decision', 'deny', 'reason', 'Unknown action: everything not in the policy is refused.'); end if;
  if pol.tier = 'prohibited' then return jsonb_build_object('decision', 'deny', 'reason', 'Prohibited by policy: ' || pol.description, 'tier', pol.tier); end if;
  if pol.live_only and st.mode = 'dry_run' then return jsonb_build_object('decision', 'deny', 'reason', 'Dry-run mode: external actions are switched off.', 'tier', pol.tier); end if;
  if pol.tier = 'red' or (pol.tier = 'yellow' and st.mode = 'approve_first') then
    return jsonb_build_object('decision', 'ask_owner', 'tier', pol.tier, 'reason', 'Needs the owner''s decision; a scoped identity never uses an approval (the service path does, through authorize_action).');
  end if;
  v_start := date_trunc('day', now() at time zone 'America/Toronto') at time zone 'America/Toronto';
  select count(*) into v_today from public.action_log where action = p_action and decision = 'allow' and at >= v_start;
  select coalesce(sum(cents), 0) into v_week from public.action_log where action = p_action and decision = 'allow' and at >= now() - interval '7 days';
  if pol.max_cents_per_action is not null and c > pol.max_cents_per_action then return jsonb_build_object('decision', 'ask_owner', 'tier', pol.tier, 'reason', 'Over the per-action limit.'); end if;
  if pol.max_count_per_day is not null and v_today >= pol.max_count_per_day then return jsonb_build_object('decision', 'deny', 'tier', pol.tier, 'reason', format('Daily limit reached (%s per day).', pol.max_count_per_day)); end if;
  if pol.max_cents_per_week is not null and v_week + c > pol.max_cents_per_week then return jsonb_build_object('decision', 'ask_owner', 'tier', pol.tier, 'reason', 'Weekly limit would be passed.'); end if;
  return jsonb_build_object('decision', 'allow', 'tier', pol.tier, 'reason', initcap(pol.tier) || ' action within policy (evaluated only: nothing consumed or counted).');
end $$;
revoke all on function public.fz_policy_preview(text, integer) from public, anon, authenticated;

-- The office layer, in one place (also used by the office spend gates of later milestones): why office p_office refuses p_action for p_cents now, or NULL.
-- Refuses when the office is not active, or an office rule forbids the action, sets a lower per-action limit, or its daily count is reached (allows of this action
-- logged with detail.office = the office). The caller takes the 7332 lock first. Read-only.
create or replace function public.fz_office_refusal(p_office uuid, p_action text, p_cents integer) returns text
language plpgsql stable security definer set search_path to 'pg_catalog' as $$
declare o public.fz_offices; op public.fz_office_action_policy; v_today int; v_start timestamptz; v_cents int := greatest(coalesce(p_cents, 0), 0);
begin
  select * into o from public.fz_offices where id = p_office;
  if not found then return 'Unknown office: refused.'; end if;
  if o.kind <> 'office' then return null; end if;                        -- the group itself has no office layer
  if o.status <> 'active' then return format('Office %s is %s: its actions are refused until the owner activates it.', o.title, o.status); end if;
  select * into op from public.fz_office_action_policy where office_id = o.id and action = p_action;
  if not found then return null; end if;
  if not op.allowed then return format('Not allowed in office %s (office rule).', o.title); end if;
  if op.max_cents_per_action is not null and v_cents > op.max_cents_per_action then
    return format('Over the %s office limit ($%s > $%s).', o.title, v_cents / 100.0, op.max_cents_per_action / 100.0);
  end if;
  if op.max_count_per_day is not null then
    v_start := date_trunc('day', now() at time zone 'America/Toronto') at time zone 'America/Toronto';
    select count(*) into v_today from public.action_log where action = p_action and decision = 'allow' and at >= v_start and detail ->> 'office' = o.slug;
    if v_today >= op.max_count_per_day then return format('Office %s daily limit reached (%s per day).', o.title, op.max_count_per_day); end if;
  end if;
  return null;
end $$;
revoke all on function public.fz_office_refusal(uuid, text, integer) from public, anon, authenticated;

-- The office-aware gate. Office layer first (can only refuse). Then:
--   a SCOPED caller (fz roles) gets fz_policy_preview(): evaluate only. It never consumes an owner approval and never writes an allow row (allows count toward the caps);
--     only refusals are logged. The real action still goes through authorize_action() on the service path when it is carried out.
--   the SERVICE path calls the UNCHANGED authorize_action() for the group decision (kill switch, mode, tiers, approvals, caps), exactly as calling it directly would.
-- A scoped caller cannot choose who it is: the actor is its identity and an office identity's office is its own. The auditor cannot act.
create or replace function public.fz_authorize_action(p_action text, p_cents integer default 0, p_ref text default null, p_office text default null, p_actor text default null,
                                                      p_venture uuid default null, p_mission uuid default null, p_detail jsonb default '{}'::jsonb) returns jsonb
language plpgsql security definer set search_path to 'pg_catalog' as $$
declare r text := coalesce(nullif(current_setting('role', true), ''), 'none'); i record; o public.fz_offices;
        v_actor text; v_ident text; v_reason text; v_cents int := greatest(coalesce(p_cents, 0), 0); res jsonb;
begin
  if r in ('fz_jarvis', 'fz_office_agent', 'fz_auditor') then
    select * into i from public.fz_identity_now();
    if i.slug is null then raise exception 'no valid scoped identity for this token' using errcode = '42501'; end if;
    if i.db_role = 'fz_auditor' then raise exception 'the auditor identity is read-only' using errcode = '42501'; end if;
    v_actor := i.slug; v_ident := i.slug;
    if not i.is_group then
      if p_office is not null and p_office is distinct from i.office_slug then raise exception 'office mismatch: this identity acts only for %', i.office_slug using errcode = '42501'; end if;
      select * into o from public.fz_offices where id = i.office_id;
    elsif p_office is not null then
      select * into o from public.fz_offices where slug = p_office;
      if not found then raise exception 'unknown office %', p_office; end if;
    end if;
  else
    v_actor := nullif(btrim(coalesce(p_actor, '')), '');
    if v_actor is null then raise exception 'p_actor is required'; end if;
    if p_office is not null then
      select * into o from public.fz_offices where slug = p_office;
      if not found then raise exception 'unknown office %', p_office; end if;
    end if;
  end if;
  if o.id is not null and o.kind = 'office' then
    perform pg_advisory_xact_lock(7332);                                  -- the same lock authorize_action takes: office counts and the group decision are one critical section
    v_reason := public.fz_office_refusal(o.id, p_action, v_cents);
    if v_reason is not null then
      insert into public.action_log (actor, action, tier, decision, reason, cents, venture_id, mission_id, ref, detail)
        values (v_actor, p_action, (select tier from public.action_policy where action = p_action), 'deny', v_reason, v_cents, p_venture, p_mission, p_ref,
                coalesce(p_detail, '{}'::jsonb) || jsonb_build_object('office', o.slug, 'identity', coalesce(v_ident, 'service'), 'layer', 'office'));
      return jsonb_build_object('decision', 'deny', 'reason', v_reason, 'tier', (select tier from public.action_policy where action = p_action), 'office', o.slug);
    end if;
  end if;
  if v_ident is not null then
    res := public.fz_policy_preview(p_action, v_cents) || jsonb_build_object('evaluated_only', true);
    if res ->> 'decision' <> 'allow' then                                -- a refusal / ask is logged (it never counts toward a cap); an allow is not
      insert into public.action_log (actor, action, tier, decision, reason, cents, venture_id, mission_id, ref, detail)
        values (v_actor, p_action, res ->> 'tier', res ->> 'decision', res ->> 'reason', v_cents, p_venture, p_mission, p_ref,
                coalesce(p_detail, '{}'::jsonb) || jsonb_build_object('office', coalesce(o.slug, 'group'), 'identity', v_ident, 'layer', 'scoped_preview'));
    end if;
    return res || jsonb_build_object('office', coalesce(o.slug, 'group'));
  end if;
  res := public.authorize_action(v_actor, p_action, v_cents, p_ref, p_venture, p_mission,
                                 coalesce(p_detail, '{}'::jsonb) || jsonb_build_object('office', coalesce(o.slug, 'group'), 'identity', 'service'));
  return res || jsonb_build_object('office', coalesce(o.slug, 'group'));
end $$;
revoke all on function public.fz_authorize_action(text, integer, text, text, text, uuid, uuid, jsonb) from public, anon, authenticated;

-- ---------------------------------------------------------------------------------------------------------------------------- owner-only controls
create or replace function public.fz_owner_set_office_status(p_office text, p_status text) returns jsonb
language plpgsql security definer set search_path to 'pg_catalog' as $$
declare o public.fz_offices;
begin
  if not coalesce(public.is_app_owner(), false) then raise exception 'owner approval required: this action is refused for the bot' using errcode = '42501'; end if;
  if p_status not in ('dormant', 'active', 'paused', 'closed') then raise exception 'status must be dormant, active, paused or closed'; end if;
  update public.fz_offices set status = p_status, updated_at = now(), updated_by = 'owner' where slug = p_office and kind = 'office' returning * into o;
  if not found then raise exception 'unknown office %', p_office; end if;
  insert into public.audit_log (actor, action, target, detail) values ('owner', 'office_status', 'fz_offices/' || o.slug, jsonb_build_object('status', p_status));
  return jsonb_build_object('office', o.slug, 'status', o.status);
end $$;
revoke all on function public.fz_owner_set_office_status(text, text) from public, anon, authenticated;

-- activate / revoke an identity; pin a token id; or void every token issued so far (p_void_tokens)
create or replace function public.fz_owner_set_identity(p_identity text, p_status text, p_token_jti text default null, p_void_tokens boolean default false) returns jsonb
language plpgsql security definer set search_path to 'pg_catalog' as $$
declare x public.fz_identities;
begin
  if not coalesce(public.is_app_owner(), false) then raise exception 'owner approval required: this action is refused for the bot' using errcode = '42501'; end if;
  if p_status not in ('dormant', 'active', 'revoked') then raise exception 'status must be dormant, active or revoked'; end if;
  update public.fz_identities set status = p_status, token_jti = coalesce(nullif(btrim(p_token_jti), ''), token_jti),
         tokens_valid_after = case when p_void_tokens then now() else tokens_valid_after end, updated_at = now(), updated_by = 'owner'
   where slug = p_identity and kind <> 'owner' returning * into x;
  if not found then raise exception 'unknown identity %', p_identity; end if;
  insert into public.audit_log (actor, action, target, detail)
    values ('owner', 'identity_status', 'fz_identities/' || x.slug, jsonb_build_object('status', p_status, 'jti_pinned', x.token_jti is not null, 'tokens_voided', p_void_tokens));
  return jsonb_build_object('identity', x.slug, 'status', x.status, 'jti_pinned', x.token_jti is not null, 'tokens_valid_after', x.tokens_valid_after);
end $$;
revoke all on function public.fz_owner_set_identity(text, text, text, boolean) from public, anon, authenticated;

-- move a client workspace (and so all its ws_* / ffm_* rows) to another office
create or replace function public.fz_owner_set_workspace_office(p_workspace uuid, p_office text) returns jsonb
language plpgsql security definer set search_path to 'pg_catalog' as $$
declare o public.fz_offices;
begin
  if not coalesce(public.is_app_owner(), false) then raise exception 'owner approval required: this action is refused for the bot' using errcode = '42501'; end if;
  select * into o from public.fz_offices where slug = p_office and kind = 'office';
  if not found then raise exception 'unknown office %', p_office; end if;
  if not exists (select 1 from public.client_workspaces where id = p_workspace) then raise exception 'unknown workspace'; end if;
  insert into public.fz_workspace_offices (workspace_id, office_id, assigned_by, assigned_at) values (p_workspace, o.id, 'owner', now())
  on conflict (workspace_id) do update set office_id = excluded.office_id, assigned_by = 'owner', assigned_at = now();
  insert into public.audit_log (actor, action, target, detail) values ('owner', 'workspace_office', 'client_workspaces/' || p_workspace, jsonb_build_object('office', o.slug));
  return jsonb_build_object('workspace', p_workspace, 'office', o.slug);
end $$;
revoke all on function public.fz_owner_set_workspace_office(uuid, text) from public, anon, authenticated;

-- the bot may only ever make an identity SAFER (fail closed): revoke it or void its tokens. It can never activate one.
create or replace function public.fz_revoke_identity(p_identity text, p_reason text) returns jsonb
language plpgsql security definer set search_path to 'pg_catalog' as $$
declare x public.fz_identities;
begin
  update public.fz_identities set status = 'revoked', tokens_valid_after = now(), updated_at = now(), updated_by = 'revoke'
   where slug = p_identity and kind not in ('owner', 'backup_reader') returning * into x;
  if not found then raise exception 'unknown identity %', p_identity; end if;
  insert into public.audit_log (actor, action, target, detail) values ('jarvis', 'identity_revoked', 'fz_identities/' || x.slug, jsonb_build_object('reason', left(coalesce(p_reason, ''), 300)));
  return jsonb_build_object('identity', x.slug, 'status', x.status);
end $$;
revoke all on function public.fz_revoke_identity(text, text) from public, anon, authenticated;

-- ---------------------------------------------------------------------------------------------------------------------------- org re-seed (runs ONCE; every decision logged)
-- Mapping: every existing client workspace -> ff-marketing (fz_workspace_offices; every ws_* / ffm_* row follows its workspace); everything else is the group (column defaults).
-- Archive = an archived_at STAMP only. No status changes at apply time: nothing that runs today stops because of this migration. Pausing an archived row is a later owner
-- action (fz_reseed_preview() shows the list first). A row is NOT archived when something live uses it:
--   agents      named by live code (bot.py, hq_engine, hq_missions, hq_llm, hq_hands, hq_ffm_run, hq_mail, hq_meter, hq_commands), open tasks, a model call in the last 14 days,
--               or belonging to / managing a kept venture
--   ventures    the mission engine's venture teams (idea-lab, donna, real-estate, day-job-sales), status active or proposed (an open owner decision), or open tasks / live missions
--   departments holding / research, a kept agent in it, or its venture kept
create or replace function public.fz_reseed_decisions() returns table (entity text, key text, decision text, status text, reason text)
language plpgsql stable security definer set search_path to 'pg_catalog' as $$
declare
  live_agents text[] := array['jarvis', 'jarvis-chat', 'jarvis-core', 'jarvis-hands', 'builder', 'research', 'auditor', 'compliance-qa', 'mission-manager', 'donna-ops',
                              'new-ventures-researcher', 'new-ventures-auditor', 'donna-researcher', 'donna-auditor', 'real-estate-researcher', 'real-estate-auditor',
                              'day-job-sales-researcher', 'day-job-sales-auditor'];
  live_ventures text[] := array['idea-lab', 'donna', 'real-estate', 'day-job-sales'];
  kept_v uuid[] := '{}'; kept_vslug text[] := '{}'; kept_a text[] := '{}'; v record; why text;
begin
  for v in select * from public.ventures x order by x.slug loop
    why := case
      when v.slug = any (live_ventures) then 'mission engine venture team (hq_missions.VENTURE_TEAM)'
      when v.status = 'active' then 'active venture'
      when v.status = 'proposed' then 'proposed: an open owner decision'
      when exists (select 1 from public.tasks t where t.venture_id = v.id and t.status in ('todo', 'doing', 'blocked')) then 'has open tasks'
      when exists (select 1 from public.missions m where m.venture_id = v.id and m.status not in ('completed', 'rejected', 'abandoned', 'failed')) then 'has a live mission'
    end;
    if why is not null then kept_v := kept_v || v.id; kept_vslug := kept_vslug || v.slug; end if;
    entity := 'venture'; key := v.slug; status := v.status; decision := case when why is null then 'archived' else 'kept' end; reason := coalesce(why, 'old plan, not live (status ' || v.status || ')');
    return next;
  end loop;
  for v in select * from public.agents x order by x.slug loop
    why := case
      when v.slug = any (live_agents) then 'used by live code'
      when exists (select 1 from public.tasks t where t.assigned_agent = v.slug and t.status in ('todo', 'doing', 'blocked')) then 'has open tasks'
      when exists (select 1 from public.llm_calls c where c.agent_slug = v.slug and c.started_at > now() - interval '14 days') then 'made a model call in the last 14 days'
      when v.venture_id = any (kept_v) or exists (select 1 from public.ventures x where x.manager_agent = v.slug and x.id = any (kept_v)) then 'belongs to or manages a kept venture'
    end;
    if why is not null then kept_a := kept_a || v.slug; end if;
    entity := 'agent'; key := v.slug; status := v.status; decision := case when why is null then 'archived' else 'kept' end; reason := coalesce(why, 'old plan, not live');
    return next;
  end loop;
  for v in select * from public.departments x order by x.slug loop
    why := case
      when v.slug in ('holding', 'research') then 'core department (holding / research)'
      when exists (select 1 from public.agents a where a.department_slug = v.slug and a.slug = any (kept_a)) then 'a kept agent works in it'
      when v.venture_id = any (kept_v) then 'its venture is kept'
    end;
    entity := 'department'; key := v.slug; status := v.status; decision := case when why is null then 'archived' else 'kept' end; reason := coalesce(why, 'old plan, not live');
    return next;
  end loop;
end $$;
revoke all on function public.fz_reseed_decisions() from public, anon, authenticated;

-- read-only: what the rule archives on TODAY's data (before apply: run the function body by hand; after apply: what a new pass would add). Owner input for any later pausing.
create or replace function public.fz_reseed_preview() returns table (entity text, key text, status text, reason text, already_logged boolean)
language sql stable security definer set search_path to 'pg_catalog' as $$
  select d.entity, d.key, d.status, d.reason, exists (select 1 from public.fz_org_archive a where a.entity = d.entity and a.key = d.key)
    from public.fz_reseed_decisions() d where d.decision = 'archived' order by 1, 2
$$;
revoke all on function public.fz_reseed_preview() from public, anon, authenticated;

do $$
declare n_arch int; n_kept int;
begin
  if exists (select 1 from public.fz_org_archive where entity = 'reseed') then return; end if;
  insert into public.fz_workspace_offices (workspace_id, office_id) select id, 'f0000000-0000-4000-8000-000000000007' from public.client_workspaces on conflict do nothing;
  create temp table fz_d on commit drop as select * from public.fz_reseed_decisions();
  insert into public.fz_org_archive (entity, key, decision, prior_status, new_status, reason) select entity, key, decision, status, status, reason from fz_d;
  update public.ventures x set archived_at = now() from fz_d d where d.entity = 'venture' and d.decision = 'archived' and d.key = x.slug;
  update public.agents x set archived_at = now() from fz_d d where d.entity = 'agent' and d.decision = 'archived' and d.key = x.slug;
  update public.departments x set archived_at = now() from fz_d d where d.entity = 'department' and d.decision = 'archived' and d.key = x.slug;
  select count(*) filter (where decision = 'archived'), count(*) filter (where decision = 'kept') into n_arch, n_kept from fz_d;
  drop table fz_d;
  insert into public.fz_org_archive (entity, key, decision, reason) values ('reseed', 'm1', 'run', format('%s archived (stamp only, no status change), %s kept', n_arch, n_kept));
  insert into public.audit_log (actor, action, target, detail) values ('migration', 'org_reseed', 'fz_org_archive', jsonb_build_object('archived', n_arch, 'kept', n_kept, 'status_changes', 0));
end $$;

-- ---------------------------------------------------------------------------------------------------------------------------- reports
create or replace function public.fz_unregistered_tables() returns setof text
language sql stable security definer set search_path to 'pg_catalog' as $$
  select c.relname::text from pg_class c where c.relnamespace = 'public'::regnamespace and c.relkind in ('r', 'p')
     and not exists (select 1 from public.fz_table_registry g where g.relname = c.relname) order by 1
$$;
revoke all on function public.fz_unregistered_tables() from public, anon, authenticated;

create or replace function public.fz_org_status() returns jsonb
language plpgsql stable security definer set search_path to 'pg_catalog' as $$
declare orphans jsonb := '{}'::jsonb; t text; v_n bigint;
begin
  foreach t in array array['agents', 'departments', 'ventures', 'missions', 'tasks', 'memory'] loop
    execute format('select count(*) from public.%I x where not exists (select 1 from public.fz_offices o where o.id = x.office_id)', t) into v_n;
    if v_n > 0 then orphans := orphans || jsonb_build_object(t, v_n); end if;
  end loop;
  return jsonb_build_object(
    'offices', (select jsonb_agg(jsonb_build_object('slug', slug, 'title', title, 'status', status) order by kind, slug) from public.fz_offices),
    'identities', (select jsonb_agg(jsonb_build_object('slug', slug, 'kind', kind, 'status', status, 'role', db_role) order by slug) from public.fz_identities),
    'archive', (select jsonb_object_agg(entity || ':' || decision, n) from (select entity, decision, count(*) n from public.fz_org_archive where entity <> 'reseed' group by 1, 2) a),
    'registry', (select jsonb_object_agg(scope, n) from (select scope, count(*) n from public.fz_table_registry group by 1) s),
    'unregistered_tables', coalesce((select jsonb_agg(x) from public.fz_unregistered_tables() x), '[]'::jsonb),
    'orphan_office_ids', orphans,
    'client_workspaces', (select jsonb_object_agg(o, n) from (select coalesce((select f.slug from public.fz_offices f where f.id = m.office_id), 'ff-marketing (default)') o, count(*) n
                                                                 from public.client_workspaces w left join public.fz_workspace_offices m on m.workspace_id = w.id group by 1) x));
end $$;
revoke all on function public.fz_org_status() from public, anon, authenticated;

-- ---------------------------------------------------------------------------------------------------------------------------- function grants for the scoped roles (allowlist)
-- Start from nothing, then grant exactly the helpers the policies call plus the identity's own tools. No approval, owner, money, consent or backup function is here.
do $$
declare f regprocedure;
begin
  for f in select p.oid::regprocedure from pg_proc p where p.pronamespace = 'public'::regnamespace and p.prokind in ('f', 'p') loop
    execute format('revoke all on routine %s from fz_jarvis, fz_office_agent, fz_auditor', f);
  end loop;
end $$;
grant execute on function public.fz_claims(), public.fz_identity_now(), public.current_identity(), public.current_office(), public.current_office_id(), public.is_group_scope(),
  public.fz_readable_offices(text), public.fz_writable_offices(text), public.fz_readable_workspaces(text), public.fz_whoami(), public.fz_agent_in_office(text, uuid)
  to fz_jarvis, fz_office_agent, fz_auditor;
grant execute on function public.fz_authorize_action(text, integer, text, text, text, uuid, uuid, jsonb) to fz_jarvis, fz_office_agent;

-- ---------------------------------------------------------------------------------------------------------------------------- backup classification (PROTECTED: owner approval)
-- Same rows as 20261124_jarvis_hands_v1 (unchanged, same order) plus the six fz_* tables. Without this the backup fails closed on unclassified tables.
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
    ('fz_org_archive', 'secret', 'append-only log of the org re-seed decisions; off-site export pending')
  ) v (table_name, data_class, note)
$$;
revoke all on function public.backup_classification() from public, anon, authenticated;
reset lock_timeout;
