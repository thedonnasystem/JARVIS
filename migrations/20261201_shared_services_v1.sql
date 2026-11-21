-- FENDEZY GROUP Phase 1, milestone M5 "Shared services re-home". ADDITIVE. Needs M1 (20261127) .. M4 (20261130).
-- Design (docs/architecture/PHASE1_M5_SHARED_SERVICES.md):
--   * fz_services: ONE registry of the shared services (payments, comms, crm, content, llm_routing, scheduler): the owner office (from the M1 office registry), the
--     tables each service writes and reads, their data classes (always recomputed from the M1 table registry, never typed by hand), how its rows are attributed to an
--     office, the scoped identity its reads may use and the flag that turns that on (scoped_reads, default FALSE). Written only by the migration and the owner.
--   * attribution (only attribution: no row is refused, no value other than office_id is ever changed):
--       - tables NOT on the never-edit list (leads, lead_replies, deals, outbox, owner_messages, jarvis_jobs, hand_actions, venture_assets) get a nullable office_id
--         column, stamped on every insert by a trigger: the venture decides; else the lead, the mission, the sending agent or the division; else a scoped caller's own
--         office; else the group. Historical rows are NOT rewritten (no update of history; the view below resolves them).
--       - the protected money tables (payment_instructions, llm_calls) are NOT altered: their office is DERIVED in the view (the M2 attribution, else the venture or
--         the agent, else the group).
--   * fz_service_rows: every row of every service table with its office and how it was decided ('stamped' | 'derived' | 'historical'); allow-list row filter.
--   * fz_services_report() for the /services owner command; fz_owner_set_service() for the owner's decisions (scoped reads on/off, status, owner office).
--   Reads through scoped identities: only for tables the M1 registry lets a scoped role read (fz_read), only when the row flag AND the bot's FZ_SERVICES_SCOPED_READS=1
--   are set (hq_services.py), and then fail-closed (never a silent fall back to the service key).
--   No change to any protected object: no money table, kill switch, mode, authorize_action, action_policy, the consent / suppression guards, executors.
-- Ordered BEFORE the lockdown (R3). Rollback: ops/rollback_shared_services.sql (archives the registry and every stamped office_id, then removes the columns). Safe to re-run.

set lock_timeout = '5s';

-- ---------------------------------------------------------------------------------------------------------------------------- registry table
create table if not exists public.fz_services (
  service text primary key check (service ~ '^[a-z][a-z0-9_]{1,30}$'),
  title text not null,
  owner_office uuid not null references public.fz_offices (id),
  writes text[] not null default '{}',
  reads text[] not null default '{}',
  data_classes text[] not null default '{}',                             -- recomputed by the guard from fz_table_registry
  attribution text not null check (attribution in ('column', 'derived', 'mixed')),
  scoped_identity text,                                                  -- fz_identities.slug; used only when scoped_reads
  scoped_reads boolean not null default false,
  status text not null default 'active' check (status in ('active', 'dormant', 'retired')),
  modules text not null default '',
  note text not null default '',
  attributed_since timestamptz not null default now(),                   -- when the current stamping started (kept on every update; restarts after a rollback)
  updated_at timestamptz not null default now(),
  updated_by text not null default 'migration'
);
alter table public.fz_services enable row level security;
do $$
begin
  revoke all on public.fz_services from public, anon, authenticated, service_role;
  if exists (select 1 from pg_roles where rolname = 'fz_jarvis') then execute 'revoke all on public.fz_services from fz_jarvis, fz_office_agent, fz_auditor'; end if;
end $$;
grant select on public.fz_services to service_role;                              -- the bot reads; only the migration / the owner write (guard)

-- writes: the migration (a database session: role none / postgres) or the signed-in owner. Never deleted (the rollback archives the table).
create or replace function public.fz_services_guard() returns trigger
language plpgsql security definer set search_path to 'pg_catalog' as $$
declare v_role text := coalesce(nullif(current_setting('role', true), ''), 'none'); v_owner boolean := coalesce(public.is_app_owner(), false); v_missing text;
begin
  if tg_op = 'DELETE' then raise exception 'fz_services rows are never deleted (retire a service with status = retired)' using errcode = '42501'; end if;
  if not (v_owner or v_role in ('none', 'postgres')) then
    raise exception 'owner approval required: fz_services is written by the migration or the signed-in owner only' using errcode = '42501';
  end if;
  if tg_op = 'UPDATE' then
    new.attributed_since := old.attributed_since;
    if v_owner and v_role not in ('none', 'postgres') and (new.service, new.writes, new.reads, new.attribution, new.modules)
                                                   is distinct from (old.service, old.writes, old.reads, old.attribution, old.modules) then
      raise exception 'the owner changes only owner_office, scoped_identity, scoped_reads, status and note (the tables are defined by the migration)' using errcode = '42501';
    end if;
  end if;
  select string_agg(t, ', ' order by t) into v_missing from unnest(new.writes || new.reads) t
   where not exists (select 1 from public.fz_table_registry r where r.relname = t);
  if v_missing is not null then raise exception 'service % names tables the M1 registry does not know: %', new.service, v_missing using errcode = '23514'; end if;
  new.data_classes := array(select distinct r.data_class from public.fz_table_registry r where r.relname = any (new.writes || new.reads) order by 1);
  if new.scoped_reads then
    if new.scoped_identity is null or not exists (select 1 from public.fz_identities i where i.slug = new.scoped_identity and i.db_role in ('fz_jarvis', 'fz_office_agent', 'fz_auditor')) then
      raise exception 'scoped reads need a scoped identity (an fz_identities row with a scoped role)' using errcode = '23514';
    end if;
  end if;
  new.updated_at := now();
  new.updated_by := case when v_owner and v_role not in ('none', 'postgres') then 'owner' else left(coalesce(nullif(new.updated_by, ''), 'migration'), 60) end;
  return new;
end $$;
revoke all on function public.fz_services_guard() from public, anon, authenticated;
drop trigger if exists fz_services_guard on public.fz_services;
create trigger fz_services_guard before insert or update or delete on public.fz_services for each row execute function public.fz_services_guard();
drop trigger if exists fz_services_no_truncate on public.fz_services;
create trigger fz_services_no_truncate before truncate on public.fz_services for each statement execute function public.fz_append_only();

-- ---------------------------------------------------------------------------------------------------------------------------- office_id stamping (attribution only)
-- One trigger function for the eight non-protected service tables. It only ever sets office_id; it never refuses a row and never changes another column.
create or replace function public.fz_service_stamp_office() returns trigger
language plpgsql security definer set search_path to 'pg_catalog' as $$
declare j jsonb := to_jsonb(new); v uuid; i record; v_role text := coalesce(nullif(current_setting('role', true), ''), 'none');
begin
  if (j ->> 'venture_id') is not null then select x.office_id into v from public.ventures x where x.id = (j ->> 'venture_id')::uuid; end if;
  if v is null and (j ->> 'lead_id') is not null then
    select coalesce(l.office_id, x.office_id) into v from public.leads l left join public.ventures x on x.id = l.venture_id where l.id = (j ->> 'lead_id')::uuid;
  end if;
  if v is null and (j ->> 'mission_id') is not null then select m.office_id into v from public.missions m where m.id = (j ->> 'mission_id')::uuid; end if;
  if v is null and tg_table_name = 'owner_messages' and (j ->> 'from_agent') is not null then select a.office_id into v from public.agents a where a.slug = j ->> 'from_agent'; end if;
  if v is null and (j ->> 'division') is not null then select d.office_id into v from public.departments d where d.slug = j ->> 'division'; end if;
  if v is null and v_role in ('fz_jarvis', 'fz_office_agent', 'fz_auditor') then
    select * into i from public.fz_identity_now();
    if i.slug is not null and not i.is_group then v := i.office_id; end if;
  end if;
  if v is null and tg_op = 'UPDATE' then v := old.office_id; end if;               -- nothing to derive from: the office does not move
  if v is null and tg_op = 'INSERT' and (j ->> 'office_id') is not null then         -- a caller-given office, only if it is a real office
    select o.id into v from public.fz_offices o where o.id = (j ->> 'office_id')::uuid;
  end if;
  new.office_id := coalesce(v, (select o.id from public.fz_offices o where o.slug = 'group'));
  return new;
end $$;
revoke all on function public.fz_service_stamp_office() from public, anon, authenticated;

do $$
declare t text; v_cols text;
begin
  foreach t in array array['leads', 'lead_replies', 'deals', 'outbox', 'owner_messages', 'jarvis_jobs', 'hand_actions', 'venture_assets'] loop
    continue when to_regclass('public.' || t) is null;
    execute format('alter table public.%I add column if not exists office_id uuid', t);
    -- re-derive only when an input of the derivation (or office_id itself) changes
    select string_agg(quote_ident(c), ', ' order by c) into v_cols from unnest(array['office_id', 'venture_id', 'lead_id', 'mission_id', 'from_agent', 'division']) c
     where exists (select 1 from pg_attribute a where a.attrelid = ('public.' || t)::regclass and a.attname = c and a.attnum > 0 and not a.attisdropped);
    execute format('drop trigger if exists zz_fz_service_office on public.%I', t);
    execute format('create trigger zz_fz_service_office before insert or update of %s on public.%I for each row execute function public.fz_service_stamp_office()', v_cols, t);
    execute format('create index if not exists %I on public.%I (office_id)', t || '_fz_office_idx', t);
  end loop;
end $$;

-- re-apply after a rollback: the archived stamps (fz_archive.fz_service_attribution) are NOT written back, because an UPDATE of an old outbox / lead row would fire
-- the consent and redaction triggers on history. Those rows read as 'historical' and the view derives their office again (the same rule); the archive keeps the stamps.

-- ---------------------------------------------------------------------------------------------------------------------------- seed (owner decisions kept on re-apply)
do $$
begin
  if not exists (select 1 from public.fz_services) and to_regclass('fz_archive.fz_services') is not null then
    insert into public.fz_services (service, title, owner_office, writes, reads, attribution, scoped_identity, scoped_reads, status, modules, note, attributed_since, updated_by)
      select a.service, a.title, a.owner_office, a.writes, a.reads, a.attribution, a.scoped_identity, a.scoped_reads, a.status, a.modules, a.note, now(), 'migration (restored from archive)'
        from fz_archive.fz_services a where exists (select 1 from public.fz_offices o where o.id = a.owner_office)
      on conflict (service) do nothing;
    -- the owner's decisions come back from the archive; attributed_since restarts now (the columns were re-added empty)
  end if;
end $$;
insert into public.fz_services (service, title, owner_office, writes, reads, attribution, scoped_identity, modules, note) values
  ('payments',    'Payment instructions (prepare, approve, confirm)', (select id from public.fz_offices where slug = 'group'),
   '{payment_instructions}', '{ventures,agents}', 'derived', 'jarvis', 'hq_payments.py, hq_approvals.py',
   'payment_instructions is protected (never-edit): its office is derived (M2 attribution, else the venture)'),
  ('comms',       'Owner messages and the outbound outbox', (select id from public.fz_offices where slug = 'group'),
   '{owner_messages,outbox}', '{agents,ventures}', 'column', 'jarvis', 'hq_core.py, hq_mail.py, hq_inbox.py, hq_push.py', ''),
  ('crm',         'Leads, replies and deals', (select id from public.fz_offices where slug = 'group'),
   '{leads,lead_replies,deals}', '{ventures}', 'column', 'jarvis', 'hq_commands.py, hq_hands_adapters.py, hq_mail.py', ''),
  ('content',     'Content and action queue, venture assets', (select id from public.fz_offices where slug = 'group'),
   '{hand_actions,venture_assets}', '{ventures,departments}', 'column', 'jarvis', 'hq_hands.py, hq_ventures.py', ''),
  ('llm_routing', 'Model routing and the model-call meter', (select id from public.fz_offices where slug = 'group'),
   '{llm_calls,model_prices}', '{agents}', 'derived', 'jarvis', 'hq_llm.py, hq_meter.py',
   'llm_calls is protected (never-edit): its office is derived (M2 attribution, else the agent); model_prices is reference data'),
  ('scheduler',   'Missions, tasks and the job queue', (select id from public.fz_offices where slug = 'group'),
   '{jarvis_jobs}', '{missions,tasks,ventures,agents}', 'column', 'jarvis', 'hq_missions.py, hq_core.py',
   'missions / tasks already carry office_id (M1); the job queue is stamped here')
on conflict (service) do update set title = excluded.title, writes = excluded.writes, reads = excluded.reads, attribution = excluded.attribution,
  modules = excluded.modules, note = excluded.note, updated_by = 'migration';
-- ---------------------------------------------------------------------------------------------------------------------------- every service row with its office
-- (every column of every union branch is named: the restore rebuilds views from pg_get_viewdef and compares them)
create or replace view public.fz_service_rows with (security_barrier = true) as
with grp as (select id from public.fz_offices where slug = 'group'),
rows_ as (
  select 'crm'::text as service, 'leads'::text as tbl, t.id as row_id, coalesce(t.office_id, x.office_id, grp.id) as office_id,
         case when t.office_id is not null then 'stamped' else 'historical' end as how, t.created_at as created_at
    from public.leads t cross join grp left join public.ventures x on x.id = t.venture_id
  union all
  select 'crm' as service, 'lead_replies' as tbl, t.id as row_id, coalesce(t.office_id, x.office_id, grp.id) as office_id, case when t.office_id is not null then 'stamped' else 'historical' end as how, t.created_at as created_at
    from public.lead_replies t cross join grp left join public.ventures x on x.id = t.venture_id
  union all
  select 'crm' as service, 'deals' as tbl, t.id as row_id, coalesce(t.office_id, x.office_id, grp.id) as office_id, case when t.office_id is not null then 'stamped' else 'historical' end as how, t.created_at as created_at
    from public.deals t cross join grp left join public.ventures x on x.id = t.venture_id
  union all
  select 'comms' as service, 'outbox' as tbl, t.id as row_id, coalesce(t.office_id, x.office_id, grp.id) as office_id, case when t.office_id is not null then 'stamped' else 'historical' end as how, t.created_at as created_at
    from public.outbox t cross join grp left join public.ventures x on x.id = t.venture_id
  union all
  select 'comms' as service, 'owner_messages' as tbl, t.id as row_id, coalesce(t.office_id, a.office_id, grp.id) as office_id, case when t.office_id is not null then 'stamped' else 'historical' end as how, t.created_at as created_at
    from public.owner_messages t cross join grp left join public.agents a on a.slug = t.from_agent
  union all
  select 'scheduler' as service, 'jarvis_jobs' as tbl, t.id as row_id, coalesce(t.office_id, m.office_id, grp.id) as office_id, case when t.office_id is not null then 'stamped' else 'historical' end as how, t.created_at as created_at
    from public.jarvis_jobs t cross join grp left join public.missions m on m.id = t.mission_id
  union all
  select 'content' as service, 'hand_actions' as tbl, t.id as row_id, coalesce(t.office_id, d.office_id, grp.id) as office_id, case when t.office_id is not null then 'stamped' else 'historical' end as how, t.created_at as created_at
    from public.hand_actions t cross join grp left join public.departments d on d.slug = t.division
  union all
  select 'content' as service, 'venture_assets' as tbl, t.id as row_id, coalesce(t.office_id, x.office_id, grp.id) as office_id, case when t.office_id is not null then 'stamped' else 'historical' end as how, t.created_at as created_at
    from public.venture_assets t cross join grp left join public.ventures x on x.id = t.venture_id
  union all
  select 'payments' as service, 'payment_instructions' as tbl, t.id as row_id, coalesce(ma.office_id, x.office_id, grp.id) as office_id, 'derived' as how, t.created_at as created_at
    from public.payment_instructions t cross join grp left join public.ventures x on x.id = t.venture_id
    left join public.fz_money_attribution ma on ma.source = 'reservation' and ma.source_id = t.reservation_id
  union all
  select 'llm_routing' as service, 'llm_calls' as tbl, t.id as row_id, coalesce(ma.office_id, a.office_id, grp.id) as office_id, 'derived' as how, t.started_at as created_at
    from public.llm_calls t cross join grp left join public.agents a on a.slug = t.agent_slug
    left join public.fz_money_attribution ma on ma.source = 'llm_call' and ma.source_id = t.id
)
select r.service, r.tbl, r.row_id, r.office_id, o.slug as office_slug, r.how, r.created_at
  from rows_ r left join public.fz_offices o on o.id = r.office_id
 where coalesce(nullif(current_setting('role', true), ''), 'none') in ('none', 'postgres', 'service_role')
    or (coalesce(nullif(current_setting('role', true), ''), 'none') in ('fz_jarvis', 'fz_office_agent', 'fz_auditor')
        and (coalesce(public.is_group_scope(), false) or r.office_id = public.current_office_id()));
revoke all on public.fz_service_rows from public, anon, authenticated, service_role;
grant select on public.fz_service_rows to service_role;

-- ---------------------------------------------------------------------------------------------------------------------------- report + owner decisions
create or replace function public.fz_services_report() returns jsonb
language plpgsql stable security definer set search_path to 'pg_catalog' as $$
declare v jsonb;
begin
  select coalesce(jsonb_agg(jsonb_build_object(
           'service', s.service, 'title', s.title, 'owner_office', o.slug, 'writes', to_jsonb(s.writes), 'reads', to_jsonb(s.reads),
           'data_classes', to_jsonb(s.data_classes), 'attribution', s.attribution, 'scoped_identity', s.scoped_identity, 'scoped_reads', s.scoped_reads,
           'scoped_read_tables', to_jsonb(array(select r.relname from public.fz_table_registry r where r.relname = any (s.reads || s.writes) and r.fz_read order by 1)),
           'status', s.status, 'modules', s.modules, 'note', s.note, 'attributed_since', s.attributed_since, 'updated_at', s.updated_at, 'updated_by', s.updated_by,
           'rows', (select jsonb_object_agg(q.how, q.n) from (select x.how, count(*) n from public.fz_service_rows x where x.service = s.service group by x.how) q),
           'unstamped_since_start', (select count(*) from public.fz_service_rows x where x.service = s.service and x.how = 'historical' and x.created_at > s.attributed_since),
           'offices', (select jsonb_object_agg(q.office_slug, q.n) from (select coalesce(x.office_slug, '?') office_slug, count(*) n from public.fz_service_rows x
                                                                          where x.service = s.service group by 1) q)
         ) order by s.service), '[]'::jsonb)
    into v from public.fz_services s left join public.fz_offices o on o.id = s.owner_office;
  return jsonb_build_object('services', v, 'scoped_reads_on', (select count(*) from public.fz_services where scoped_reads));
end $$;
revoke all on function public.fz_services_report() from public, anon, authenticated;

-- the owner's decisions (SQL editor or a signed-in owner session; the service key is refused). Each change is audited.
create or replace function public.fz_owner_set_service(p_service text, p_scoped_reads boolean default null, p_status text default null,
                                                      p_owner_office text default null, p_note text default null) returns jsonb
language plpgsql security definer set search_path to 'pg_catalog' as $$
declare v_role text := coalesce(nullif(current_setting('role', true), ''), 'none'); s public.fz_services; v_office uuid; v_by text;
begin
  if not (coalesce(public.is_app_owner(), false) or v_role in ('none', 'postgres')) then
    raise exception 'owner approval required: only the signed-in owner changes a shared service' using errcode = '42501';
  end if;
  v_by := case when coalesce(public.is_app_owner(), false) then 'owner' else 'owner:sql' end;
  select * into s from public.fz_services where service = p_service for update;
  if not found then raise exception 'unknown service %', p_service using errcode = '22023'; end if;
  if p_owner_office is not null then
    select id into v_office from public.fz_offices where slug = p_owner_office;
    if v_office is null then raise exception 'unknown office %', p_owner_office using errcode = '22023'; end if;
  end if;
  update public.fz_services set scoped_reads = coalesce(p_scoped_reads, scoped_reads), status = coalesce(p_status, status),
         owner_office = coalesce(v_office, owner_office), note = coalesce(left(p_note, 300), note), updated_by = v_by
   where service = p_service returning * into s;
  insert into public.audit_log (actor, action, target, detail) values (v_by, 'service_registry_change', 'fz_services:' || p_service,
    jsonb_build_object('scoped_reads', s.scoped_reads, 'status', s.status, 'owner_office', s.owner_office));
  return jsonb_build_object('ok', true, 'service', s.service, 'scoped_reads', s.scoped_reads, 'status', s.status);
end $$;
revoke all on function public.fz_owner_set_service(text, boolean, text, text, text) from public, anon, authenticated;

-- ---------------------------------------------------------------------------------------------------------------------------- registry (M1) + backup classification
insert into public.fz_table_registry (relname, scope, scope_column, data_class, fz_read, fz_write, fz_insert_columns, fz_update_columns, note) values
  ('fz_services', 'group', null, 'internal', false, '{}', null, null, 'shared services registry (owner office, tables, scoped-read flag)')
on conflict (relname) do update set scope = excluded.scope, scope_column = excluded.scope_column, data_class = excluded.data_class, fz_read = excluded.fz_read,
  fz_write = excluded.fz_write, fz_insert_columns = excluded.fz_insert_columns, fz_update_columns = excluded.fz_update_columns, note = excluded.note;

-- backup classification (PROTECTED: owner approval): same rows as 20261130_security_hardening_v1 plus fz_services ('secret': not in the off-site export)
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
    ('fz_token_registry', 'secret', 'minted scoped token ids and expiry (never a token)'),
    -- Shared services M5 (20261201): the services registry ('secret' = not in the off-site export, as the M1 registries; re-seeded by the migration)
    ('fz_services', 'secret', 'shared services registry and the owner scoped-read decisions; re-seeded by the migration')
  ) v (table_name, data_class, note)
$$;
revoke all on function public.backup_classification() from public, anon, authenticated;
reset lock_timeout;
