-- FENDEZY GROUP: "Linked memory" for the open brain (Nov 23 2026). ADDITIVE. Needs 20261127_org_access_v1 (fz_offices, agents.office_id).
-- Design (docs/architecture/LINKED_MEMORY.md): the mem0 pattern (extract facts -> compare with what is already known -> add / update / retract / no-op),
-- implemented natively on the existing Postgres. No extension (no pgvector needed: embeddings are small normalised real[] vectors, scored in SQL),
-- no new service, no new Python dependency.
--   * fz_memory.memories: one fact per row, ALWAYS bound to one office (the group or one of the eight offices) and one data class:
--       public | owner | client. Client facts are returned only to an office's OWN self-hosted path (p_destination = 'selfhost'), never to the group,
--       never to another office. The class never goes down on an update (an owner fact updated with client data becomes client).
--     History is kept: an update writes a NEW row and marks the old one superseded (superseded_by); a contradiction without replacement marks it retracted;
--     the owner's /memory forget marks it forgotten (audited, ids only). Nothing is deleted.
--   * fz_memory.entities / memory_entities / relations: the links (people, ventures, offices, decisions, ...). Composite foreign keys (office_id, id)
--     make a link between two different offices impossible in the database, not only in code.
--   * fz_memory.provider_quota / provider_state: the free-provider counters (requests and tokens per provider per hour, 24 hourly slots reused, and the
--     cool-down), so a restart no longer forgets them. No money: these are request counts of FREE providers. The spend gateway, llm_calls and the caps
--     are not touched.
--   * The schema fz_memory has NO privilege for any API role; only the functions below reach it (as fz_office_os, M7). So it is outside the public
--     table registry and the off-site export. Functions: service key (the bot) and database sessions only; anon / authenticated / the scoped fz roles
--     are refused by grant AND in the body.
-- No change to caps, the kill switch, mode, the spend gateway, authorize_action, the table registry, backup classification or any money control.
-- Function names avoid the fz_ prefix (the M1 rollback drill asserts no public fz_* survives it) and open_brain_ (the open-brain rollback check).
-- Ordered BEFORE the lockdown (R3). Rollback: ops/rollback_linked_memory.sql (moves the schema to fz_memory_archive; a re-apply restores it). Safe to re-run.

set lock_timeout = '5s';

do $$
begin
  if to_regnamespace('fz_memory') is null and to_regnamespace('fz_memory_archive') is not null then
    alter schema fz_memory_archive rename to fz_memory;                    -- re-apply after a rollback: the kept memories come back
  end if;
end $$;
create schema if not exists fz_memory;
revoke all on schema fz_memory from public;
do $$ declare r text; begin
  foreach r in array array['anon', 'authenticated', 'service_role', 'fz_jarvis', 'fz_office_agent', 'fz_auditor', 'backup_reader'] loop
    if exists (select 1 from pg_roles where rolname = r) then execute format('revoke all on schema fz_memory from %I', r); end if;
  end loop;
end $$;

-- ---------------------------------------------------------------------------------------------------------------------------- tables
create table if not exists fz_memory.memories (
  id uuid primary key default gen_random_uuid(),
  office_id uuid not null,                                               -- no FK to fz_offices (as M1: the archive / export never depends on it)
  data_class text not null check (data_class in ('public', 'owner', 'client')),
  kind text not null check (kind in ('fact', 'preference', 'decision', 'person', 'plan', 'lesson', 'outcome')),
  content text not null check (length(content) between 3 and 600),
  content_hash text not null check (content_hash ~ '^[0-9a-f]{32}$'),
  embedding real[] not null check (cardinality(embedding) between 8 and 1024),
  embedder text not null check (embedder ~ '^[a-z0-9:._-]{1,60}$'),
  importance real not null default 0.5 check (importance >= 0 and importance <= 1),
  status text not null default 'active' check (status in ('active', 'superseded', 'retracted', 'forgotten')),
  supersedes uuid,
  superseded_by uuid,
  source text not null default '' check (length(source) <= 120),
  seen_count integer not null default 1 check (seen_count >= 1),
  created_at timestamptz not null default now(),
  last_seen_at timestamptz not null default now(),
  status_at timestamptz,
  status_by text check (status_by is null or length(status_by) <= 60),
  unique (office_id, id)
);
create unique index if not exists memories_live_dedupe on fz_memory.memories (office_id, content_hash) where status = 'active';
create index if not exists memories_live on fz_memory.memories (office_id, last_seen_at desc) where status = 'active';
create index if not exists memories_fts on fz_memory.memories using gin (to_tsvector('simple', content)) where status = 'active';

create table if not exists fz_memory.entities (
  id uuid primary key default gen_random_uuid(),
  office_id uuid not null,
  kind text not null check (kind in ('person', 'venture', 'office', 'decision', 'org', 'project', 'place', 'product', 'other')),
  name text not null check (length(name) between 1 and 120),
  norm text not null check (length(norm) between 1 and 120),
  created_at timestamptz not null default now(),
  last_seen_at timestamptz not null default now(),
  unique (office_id, kind, norm),
  unique (office_id, id)
);

create table if not exists fz_memory.memory_entities (
  office_id uuid not null,
  memory_id uuid not null,
  entity_id uuid not null,
  primary key (memory_id, entity_id),
  foreign key (office_id, memory_id) references fz_memory.memories (office_id, id),     -- same office, enforced by the database
  foreign key (office_id, entity_id) references fz_memory.entities (office_id, id)
);
create index if not exists memory_entities_entity on fz_memory.memory_entities (entity_id);

create table if not exists fz_memory.relations (
  id bigint generated always as identity primary key,
  office_id uuid not null,
  src uuid not null,
  rel text not null check (rel ~ '^[a-z][a-z0-9_]{1,40}$'),
  dst uuid not null,
  memory_id uuid not null,
  status text not null default 'active' check (status in ('active', 'superseded')),
  created_at timestamptz not null default now(),
  foreign key (office_id, src) references fz_memory.entities (office_id, id),
  foreign key (office_id, dst) references fz_memory.entities (office_id, id),
  foreign key (office_id, memory_id) references fz_memory.memories (office_id, id)
);
create unique index if not exists relations_live on fz_memory.relations (office_id, src, rel, dst) where status = 'active';

create table if not exists fz_memory.provider_quota (                   -- 24 hourly slots per provider, reused (no delete needed)
  provider text not null check (provider ~ '^[a-z][a-z0-9_-]{1,30}$'),
  slot smallint not null check (slot between 0 and 23),
  hour timestamptz not null,
  requests integer not null default 0 check (requests >= 0),
  tokens bigint not null default 0 check (tokens >= 0),
  primary key (provider, slot)
);
create table if not exists fz_memory.provider_state (
  provider text primary key check (provider ~ '^[a-z][a-z0-9_-]{1,30}$'),
  cooling_until timestamptz,
  fails integer not null default 0 check (fails between 0 and 1000),
  updated_at timestamptz not null default now()
);

do $$
declare t text; r text;
begin
  foreach t in array array['memories', 'entities', 'memory_entities', 'relations', 'provider_quota', 'provider_state'] loop
    execute format('alter table fz_memory.%I enable row level security', t);
    execute format('revoke all on fz_memory.%I from public', t);
    foreach r in array array['anon', 'authenticated', 'service_role', 'fz_jarvis', 'fz_office_agent', 'fz_auditor', 'backup_reader'] loop
      if exists (select 1 from pg_roles where rolname = r) then execute format('revoke all on fz_memory.%I from %I', t, r); end if;
    end loop;
  end loop;
end $$;
revoke all on sequence fz_memory.relations_id_seq from public;

-- ---------------------------------------------------------------------------------------------------------------------------- helpers
-- Who may call: the bot (service key) and database sessions. Anyone else (anon, a signed-in app user, a scoped office / jarvis / auditor token,
-- the backup identity) is refused here, whatever a later grant says. The SESSION role is read (a SECURITY DEFINER caller does not change it).
create or replace function public.jmem_guard() returns void
language plpgsql stable security definer set search_path to 'pg_catalog' as $$
begin
  if coalesce(nullif(current_setting('role', true), ''), 'none') not in ('service_role', 'none', 'postgres') then
    raise exception 'linked memory: the bot and database sessions only' using errcode = '42501';
  end if;
end $$;
revoke all on function public.jmem_guard() from public, anon, authenticated;

create or replace function public.jmem_norm(p_text text) returns text
language sql immutable set search_path to 'pg_catalog' as $$
  select btrim(regexp_replace(lower(coalesce(p_text, '')), '[^a-z0-9]+', ' ', 'g'))
$$;
revoke all on function public.jmem_norm(text) from public, anon, authenticated;

-- The office a call works in. p_agent wins (the agent's office from public.agents: an office's agents can only ever reach their own office);
-- p_office, if also given, must agree. Unknown office / agent: refused.
create or replace function public.jmem_office(p_office text, p_agent text default null) returns uuid
language plpgsql stable security definer set search_path to 'pg_catalog' as $$
declare v uuid; a uuid;
begin
  if p_agent is not null then
    select x.office_id into a from public.agents x where x.slug = p_agent;
    if a is null then raise exception 'linked memory: unknown agent %', left(p_agent, 60) using errcode = '22023'; end if;
  end if;
  if p_office is not null then
    select o.id into v from public.fz_offices o where o.slug = p_office;
    if v is null then raise exception 'linked memory: unknown office %', left(p_office, 60) using errcode = '22023'; end if;
  end if;
  if a is not null and v is not null and a <> v then raise exception 'linked memory: agent % is not in office %', left(p_agent, 60), left(p_office, 60) using errcode = '42501'; end if;
  v := coalesce(a, v);
  if v is null then raise exception 'linked memory: office or agent required' using errcode = '22023'; end if;
  return v;
end $$;
revoke all on function public.jmem_office(text, text) from public, anon, authenticated;

create or replace function public.jmem_dot(a real[], b real[]) returns real
language sql immutable parallel safe set search_path to 'pg_catalog' as $$
  select case when a is null or b is null or cardinality(a) <> cardinality(b) then 0::real
              else coalesce((select sum(x * y) from unnest(a, b) as t(x, y)), 0)::real end
$$;
revoke all on function public.jmem_dot(real[], real[]) from public, anon, authenticated;

-- ---------------------------------------------------------------------------------------------------------------------------- retrieval
-- Top-k memories for one office, scored: 0.50 semantic (same embedder only) + 0.20 lexical + 0.15 importance + 0.10 recency (45-day half-life-ish
-- decay of last_seen_at) + 0.15 when a linked entity is named in the query. Scope:
--   office  -> its own rows only; client rows only when p_destination = 'selfhost'
--   group   -> the group's rows and every office's NON-client rows (M1: group scope reads all offices except client data); never client rows
create or replace function public.jmem_search(p_office text, p_query text, p_qvec real[] default null, p_embedder text default null, p_k integer default 5,
                                              p_destination text default 'external', p_agent text default null)
returns table (id uuid, office text, kind text, data_class text, content text, score real, entities text[], last_seen_at timestamptz)
language plpgsql stable security definer set search_path to 'pg_catalog' as $$
#variable_conflict use_column
declare v_office uuid; v_group boolean; v_client boolean; q text := left(coalesce(p_query, ''), 1000); qn text; tq tsquery;
begin
  perform public.jmem_guard();
  v_office := public.jmem_office(p_office, p_agent);
  v_group := exists (select 1 from public.fz_offices o where o.id = v_office and o.kind = 'group');
  v_client := not v_group and coalesce(p_destination, 'external') = 'selfhost';
  qn := ' ' || public.jmem_norm(q) || ' ';
  tq := nullif(replace(plainto_tsquery('simple', q)::text, ' & ', ' | '), '')::tsquery;
  return query
  with hit as (
    select e.id from fz_memory.entities e
     where length(e.norm) >= 3 and position(' ' || e.norm || ' ' in qn) > 0
       and (e.office_id = v_office or v_group)
  ), cand as (
    select m.*, case when m.embedder = p_embedder then public.jmem_dot(m.embedding, p_qvec) else 0 end as sem,
           case when tq is null then 0 else ts_rank_cd(to_tsvector('simple', m.content), tq, 32) end as lex,
           exists (select 1 from fz_memory.memory_entities me where me.memory_id = m.id and me.entity_id in (select hit.id from hit)) as ent
      from fz_memory.memories m
     where m.status = 'active'
       and (m.office_id = v_office or (v_group and m.data_class <> 'client'))
       and (m.data_class <> 'client' or (v_client and m.office_id = v_office))
  )
  select c.id, (select o.slug from public.fz_offices o where o.id = c.office_id), c.kind, c.data_class, c.content,
         (0.50 * greatest(c.sem, 0) + 0.20 * c.lex + 0.15 * c.importance
          + 0.10 * exp(-greatest(extract(epoch from now() - c.last_seen_at), 0) / 86400.0 / 45.0) + 0.15 * c.ent::int)::real,
         array(select e.name from fz_memory.memory_entities me join fz_memory.entities e on e.id = me.entity_id where me.memory_id = c.id order by e.name),
         c.last_seen_at
    from cand c
   where c.sem > 0.15 or c.lex > 0 or c.ent
   order by 6 desc, c.last_seen_at desc
   limit greatest(1, least(coalesce(p_k, 5), 20));
end $$;
revoke all on function public.jmem_search(text, text, real[], text, integer, text, text) from public, anon, authenticated;

-- ---------------------------------------------------------------------------------------------------------------------------- writes
-- One batch of operations from one extraction (at most 20). Every op stays inside the call's office: an update / retract whose target is not an
-- ACTIVE memory of THAT office is skipped (never an error that would lose the rest). Ops:
--   {"op": "add",     "content", "kind", "data_class", "importance" 0..1, "embedding": [...], "entities": [{"name", "kind"}], "relations": [["src", "rel", "dst"]]}
--   {"op": "update",  "id": <target>, ...same as add}        -> new row (supersedes the target), the target becomes superseded
--   {"op": "retract", "id": <target>}                          -> contradicted, no replacement
-- An add whose normalised text is already active, or whose embedding is >= 0.95 similar to an active row of the same office, class and embedder,
-- is a duplicate: the existing row is seen again (last_seen_at, seen_count, max importance) instead.
create or replace function public.jmem_apply(p_office text, p_ops jsonb, p_source text default '', p_embedder text default 'hash-v1', p_agent text default null)
returns jsonb
language plpgsql security definer set search_path to 'pg_catalog' as $$
declare v_office uuid; op jsonb; v_kind text; v_class text; v_content text; v_hash text; v_vec real[]; v_imp real; v_target fz_memory.memories; v_dup uuid;
        v_new uuid; e jsonb; r jsonb; v_eid uuid; v_src uuid; v_dst uuid; added int := 0; updated int := 0; retracted int := 0; deduped int := 0; skipped int := 0;
        rank_ text[] := array['public', 'owner', 'client'];
begin
  perform public.jmem_guard();
  v_office := public.jmem_office(p_office, p_agent);
  if jsonb_typeof(p_ops) <> 'array' or jsonb_array_length(p_ops) > 20 then raise exception 'linked memory: 0 to 20 operations' using errcode = '22023'; end if;
  if coalesce(p_embedder, '') !~ '^[a-z0-9:._-]{1,60}$' then raise exception 'linked memory: bad embedder name' using errcode = '22023'; end if;
  for op in select * from jsonb_array_elements(p_ops) loop
    begin
      v_target := null;
      if op ->> 'op' in ('update', 'retract') then
        select * into v_target from fz_memory.memories m
         where m.id = (case when (op ->> 'id') ~ '^[0-9a-f-]{36}$' then (op ->> 'id')::uuid end) and m.office_id = v_office and m.status = 'active';
        if v_target.id is null then skipped := skipped + 1; continue; end if;
        if op ->> 'op' = 'retract' then
          update fz_memory.memories set status = 'retracted', status_at = now(), status_by = left(coalesce(nullif(p_source, ''), 'extraction'), 60) where id = v_target.id;
          update fz_memory.relations set status = 'superseded' where memory_id = v_target.id and status = 'active';
          retracted := retracted + 1; continue;
        end if;
      elsif coalesce(op ->> 'op', '') <> 'add' then
        skipped := skipped + 1; continue;
      end if;
      v_content := btrim(left(regexp_replace(coalesce(op ->> 'content', ''), '\s+', ' ', 'g'), 600));
      v_kind := coalesce(nullif(op ->> 'kind', ''), 'fact');
      v_class := coalesce(op ->> 'data_class', 'client');                -- missing class = client (default deny)
      if v_class not in ('public', 'owner', 'client') then v_class := 'client'; end if;
      if v_target.id is not null and array_position(rank_, v_target.data_class) > array_position(rank_, v_class) then v_class := v_target.data_class; end if;
      v_imp := least(1, greatest(0, coalesce((op ->> 'importance')::real, 0.5)));
      v_vec := array(select x::real from jsonb_array_elements_text(coalesce(op -> 'embedding', '[]')) x);
      if length(v_content) < 3 or cardinality(v_vec) not between 8 and 1024
         or v_kind not in ('fact', 'preference', 'decision', 'person', 'plan', 'lesson', 'outcome') then skipped := skipped + 1; continue; end if;
      v_hash := md5(public.jmem_norm(v_content));
      select m.id into v_dup from fz_memory.memories m
       where m.office_id = v_office and m.status = 'active' and m.id is distinct from v_target.id
         and (m.content_hash = v_hash or (m.embedder = p_embedder and m.data_class = v_class and public.jmem_dot(m.embedding, v_vec) >= 0.95))
       order by (m.content_hash = v_hash) desc, m.last_seen_at desc limit 1;
      if v_dup is not null then
        update fz_memory.memories set last_seen_at = now(), seen_count = seen_count + 1, importance = greatest(importance, v_imp),
               data_class = case when array_position(rank_, v_class) > array_position(rank_, data_class) then v_class else data_class end
         where id = v_dup;
        if v_target.id is not null then                                   -- the update says the same as another live row: the target is superseded by it
          update fz_memory.memories set status = 'superseded', superseded_by = v_dup, status_at = now(), status_by = 'extraction' where id = v_target.id;
          update fz_memory.relations set status = 'superseded' where memory_id = v_target.id and status = 'active';
        end if;
        deduped := deduped + 1; continue;
      end if;
      insert into fz_memory.memories (office_id, data_class, kind, content, content_hash, embedding, embedder, importance, supersedes, source)
        values (v_office, v_class, v_kind, v_content, v_hash, v_vec, p_embedder, v_imp, v_target.id, left(coalesce(p_source, ''), 120))
        returning id into v_new;
      if v_target.id is not null then
        update fz_memory.memories set status = 'superseded', superseded_by = v_new, status_at = now(), status_by = 'extraction' where id = v_target.id;
        update fz_memory.relations set status = 'superseded' where memory_id = v_target.id and status = 'active';
        updated := updated + 1;
      else
        added := added + 1;
      end if;
      for e in select * from jsonb_array_elements(case when jsonb_typeof(op -> 'entities') = 'array' then op -> 'entities' else '[]' end) limit 8 loop
        v_eid := public.jmem_entity_upsert(v_office, e ->> 'name', e ->> 'kind');
        if v_eid is not null then
          insert into fz_memory.memory_entities (office_id, memory_id, entity_id) values (v_office, v_new, v_eid) on conflict do nothing;
        end if;
      end loop;
      for r in select * from jsonb_array_elements(case when jsonb_typeof(op -> 'relations') = 'array' then op -> 'relations' else '[]' end) limit 6 loop
        if jsonb_typeof(r) <> 'array' or jsonb_array_length(r) <> 3 then continue; end if;
        v_src := public.jmem_entity_upsert(v_office, r ->> 0, null);
        v_dst := public.jmem_entity_upsert(v_office, r ->> 2, null);
        if v_src is null or v_dst is null or v_src = v_dst
           or left(regexp_replace(lower(coalesce(r ->> 1, '')), '[^a-z0-9]+', '_', 'g'), 40) !~ '^[a-z][a-z0-9_]{1,40}$' then continue; end if;
        insert into fz_memory.memory_entities (office_id, memory_id, entity_id) values (v_office, v_new, v_src), (v_office, v_new, v_dst) on conflict do nothing;
        insert into fz_memory.relations (office_id, src, rel, dst, memory_id)
          values (v_office, v_src, left(regexp_replace(lower(r ->> 1), '[^a-z0-9]+', '_', 'g'), 40), v_dst, v_new) on conflict do nothing;
      end loop;
    exception when invalid_text_representation or numeric_value_out_of_range or check_violation or string_data_right_truncation then
      skipped := skipped + 1;
    end;
  end loop;
  return jsonb_build_object('added', added, 'updated', updated, 'retracted', retracted, 'deduped', deduped, 'skipped', skipped);
end $$;
revoke all on function public.jmem_apply(text, jsonb, text, text, text) from public, anon, authenticated;

-- An entity of THIS office by (kind, normalised name); a NULL kind finds any kind with that name first, else creates 'other'. Bad names: NULL.
create or replace function public.jmem_entity_upsert(p_office uuid, p_name text, p_kind text) returns uuid
language plpgsql security definer set search_path to 'pg_catalog' as $$
declare v_name text := btrim(left(regexp_replace(coalesce(p_name, ''), '\s+', ' ', 'g'), 120)); v_norm text; v_kind text; v uuid;
begin
  perform public.jmem_guard();
  v_norm := left(public.jmem_norm(v_name), 120);
  if length(v_norm) < 2 then return null; end if;
  v_kind := case when p_kind in ('person', 'venture', 'office', 'decision', 'org', 'project', 'place', 'product', 'other') then p_kind end;
  if v_kind is null then
    select e.id into v from fz_memory.entities e where e.office_id = p_office and e.norm = v_norm order by (e.kind = 'other'), e.created_at limit 1;
    if v is not null then update fz_memory.entities set last_seen_at = now() where id = v; return v; end if;
    v_kind := 'other';
  end if;
  insert into fz_memory.entities (office_id, kind, name, norm) values (p_office, v_kind, v_name, v_norm)
    on conflict (office_id, kind, norm) do update set last_seen_at = now()
    returning id into v;
  return v;
end $$;
revoke all on function public.jmem_entity_upsert(uuid, text, text) from public, anon, authenticated;

-- ---------------------------------------------------------------------------------------------------------------------------- owner commands (/memory)
-- Newest (or matching) active memories of one office. Client rows are listed MASKED (the bot sends this text to Telegram; client data stays with the
-- office's own path). The group view lists only the group's own rows.
create or replace function public.jmem_list(p_office text, p_query text default null, p_limit integer default 15)
returns table (id uuid, kind text, data_class text, content text, importance real, seen_count integer, last_seen_at timestamptz, entities text[])
language plpgsql stable security definer set search_path to 'pg_catalog' as $$
#variable_conflict use_column
declare v_office uuid; qn text := nullif(public.jmem_norm(p_query), '');
begin
  perform public.jmem_guard();
  v_office := public.jmem_office(p_office, null);
  return query
  select m.id, m.kind, m.data_class, case when m.data_class = 'client' then '[client data: hidden]' else m.content end, m.importance, m.seen_count, m.last_seen_at,
         array(select e.name from fz_memory.memory_entities me join fz_memory.entities e on e.id = me.entity_id where me.memory_id = m.id order by e.name)
    from fz_memory.memories m
   where m.office_id = v_office and m.status = 'active'
     and (qn is null or (m.data_class <> 'client' and position(qn in public.jmem_norm(m.content)) > 0)
          or exists (select 1 from fz_memory.memory_entities me join fz_memory.entities e on e.id = me.entity_id where me.memory_id = m.id and e.norm = qn))
   order by m.last_seen_at desc
   limit greatest(1, least(coalesce(p_limit, 15), 50));
end $$;
revoke all on function public.jmem_list(text, text, integer) from public, anon, authenticated;

-- Forget: by id prefix (at least 8 hex characters, unique in the office) or every active memory linked to an entity name. Soft (status 'forgotten'):
-- never retrieved again, kept as history; one audit_log row with ids and counts only, never content.
create or replace function public.jmem_forget(p_office text, p_id_prefix text default null, p_entity text default null, p_actor text default 'owner')
returns jsonb
language plpgsql security definer set search_path to 'pg_catalog' as $$
declare v_office uuid; ids uuid[]; v_norm text := nullif(public.jmem_norm(p_entity), '');
begin
  perform public.jmem_guard();
  v_office := public.jmem_office(p_office, null);
  if p_id_prefix is not null then
    if lower(p_id_prefix) !~ '^[0-9a-f-]{8,36}$' then raise exception 'linked memory: give at least 8 characters of the memory id' using errcode = '22023'; end if;
    ids := array(select m.id from fz_memory.memories m where m.office_id = v_office and m.status = 'active' and m.id::text like lower(p_id_prefix) || '%');
    if cardinality(ids) > 1 then raise exception 'linked memory: % memories start with %; give more characters', cardinality(ids), p_id_prefix using errcode = '22023'; end if;
  elsif v_norm is not null then
    ids := array(select distinct m.id from fz_memory.memories m join fz_memory.memory_entities me on me.memory_id = m.id join fz_memory.entities e on e.id = me.entity_id
                  where m.office_id = v_office and m.status = 'active' and e.norm = v_norm limit 200);
  else
    raise exception 'linked memory: id prefix or entity name required' using errcode = '22023';
  end if;
  if cardinality(ids) = 0 then return jsonb_build_object('forgotten', 0); end if;
  update fz_memory.memories set status = 'forgotten', status_at = now(), status_by = left(coalesce(p_actor, 'owner'), 60) where id = any (ids);
  update fz_memory.relations set status = 'superseded' where memory_id = any (ids) and status = 'active';
  insert into public.audit_log (actor, action, target, detail)
    values (left(coalesce(p_actor, 'owner'), 60), 'memory_forget', 'fz_memory.memories',
            jsonb_build_object('office', p_office, 'count', cardinality(ids), 'ids', to_jsonb(ids[1:50]), 'by', case when p_id_prefix is not null then 'id' else 'entity' end));
  return jsonb_build_object('forgotten', cardinality(ids));
end $$;
revoke all on function public.jmem_forget(text, text, text, text) from public, anon, authenticated;

-- The links of one entity in one office (/memory links <name>): its live relations, both directions.
create or replace function public.jmem_links(p_office text, p_name text, p_limit integer default 20)
returns table (src text, rel text, dst text, since timestamptz)
language plpgsql stable security definer set search_path to 'pg_catalog' as $$
#variable_conflict use_column
declare v_office uuid; v_norm text := public.jmem_norm(p_name);
begin
  perform public.jmem_guard();
  v_office := public.jmem_office(p_office, null);
  return query
  select s.name, r.rel, d.name, r.created_at
    from fz_memory.relations r join fz_memory.entities s on s.id = r.src join fz_memory.entities d on d.id = r.dst
    join fz_memory.memories m on m.id = r.memory_id
   where r.office_id = v_office and r.status = 'active' and m.data_class <> 'client' and (s.norm = v_norm or d.norm = v_norm)
   order by r.created_at desc
   limit greatest(1, least(coalesce(p_limit, 20), 50));
end $$;
revoke all on function public.jmem_links(text, text, integer) from public, anon, authenticated;

create or replace function public.jmem_stats() returns jsonb
language plpgsql stable security definer set search_path to 'pg_catalog' as $$
begin
  perform public.jmem_guard();
  return jsonb_build_object(
    'by_office', coalesce((select jsonb_object_agg(x.slug, x.n) from (select o.slug, count(*) n from fz_memory.memories m join public.fz_offices o on o.id = m.office_id
                                                                      where m.status = 'active' group by o.slug) x), '{}'),
    'by_class', coalesce((select jsonb_object_agg(x.data_class, x.n) from (select data_class, count(*) n from fz_memory.memories where status = 'active' group by data_class) x), '{}'),
    'history', (select count(*) from fz_memory.memories where status <> 'active'),
    'entities', (select count(*) from fz_memory.entities),
    'relations', (select count(*) from fz_memory.relations where status = 'active'));
end $$;
revoke all on function public.jmem_stats() from public, anon, authenticated;

-- ---------------------------------------------------------------------------------------------------------------------------- free-provider quota
-- Add counts to the provider's current hourly slot (a slot from an older day is restarted) and store its cool-down. Only counts: no prompt, no money.
create or replace function public.jquota_record(p_provider text, p_requests integer, p_tokens bigint, p_cooling_until timestamptz default null, p_fails integer default 0)
returns void
language plpgsql security definer set search_path to 'pg_catalog' as $$
declare h timestamptz := date_trunc('hour', now()); s smallint := extract(hour from (now() at time zone 'UTC'))::smallint;
begin
  perform public.jmem_guard();
  if coalesce(p_provider, '') !~ '^[a-z][a-z0-9_-]{1,30}$' or coalesce(p_requests, -1) not between 0 and 10000 or coalesce(p_tokens, -1) not between 0 and 100000000
     or coalesce(p_fails, 0) not between 0 and 1000 or (p_cooling_until is not null and p_cooling_until > now() + interval '1 day') then
    raise exception 'quota: bad values' using errcode = '22023';
  end if;
  if p_requests > 0 or p_tokens > 0 then
    insert into fz_memory.provider_quota as q (provider, slot, hour, requests, tokens) values (p_provider, s, h, p_requests, p_tokens)
      on conflict (provider, slot) do update set
        requests = case when q.hour = excluded.hour then q.requests + excluded.requests else excluded.requests end,
        tokens = case when q.hour = excluded.hour then q.tokens + excluded.tokens else excluded.tokens end,
        hour = excluded.hour;
  end if;
  insert into fz_memory.provider_state as st (provider, cooling_until, fails, updated_at) values (p_provider, p_cooling_until, coalesce(p_fails, 0), now())
    on conflict (provider) do update set cooling_until = excluded.cooling_until, fails = excluded.fails, updated_at = now();
end $$;
revoke all on function public.jquota_record(text, integer, bigint, timestamptz, integer) from public, anon, authenticated;

-- What the bot loads at start: the last 24 hours of slots and every live cool-down.
create or replace function public.jquota_load() returns jsonb
language plpgsql stable security definer set search_path to 'pg_catalog' as $$
begin
  perform public.jmem_guard();
  return jsonb_build_object(
    'hours', coalesce((select jsonb_agg(jsonb_build_object('provider', q.provider, 'hour', extract(epoch from q.hour)::bigint, 'requests', q.requests, 'tokens', q.tokens)
                                        order by q.provider, q.hour)
                         from fz_memory.provider_quota q where q.hour > now() - interval '24 hours'), '[]'),
    'state', coalesce((select jsonb_object_agg(s.provider, jsonb_build_object('cooling_until', extract(epoch from s.cooling_until), 'fails', s.fails))
                         from fz_memory.provider_state s), '{}'),
    'now', extract(epoch from now()));
end $$;
revoke all on function public.jquota_load() from public, anon, authenticated;

do $$
declare f text;
begin
  if exists (select 1 from pg_roles where rolname = 'fz_jarvis') then
    foreach f in array array['jmem_guard()', 'jmem_norm(text)', 'jmem_office(text,text)', 'jmem_dot(real[],real[])', 'jmem_search(text,text,real[],text,integer,text,text)',
                             'jmem_apply(text,jsonb,text,text,text)', 'jmem_entity_upsert(uuid,text,text)', 'jmem_list(text,text,integer)', 'jmem_forget(text,text,text,text)',
                             'jmem_links(text,text,integer)', 'jmem_stats()', 'jquota_record(text,integer,bigint,timestamptz,integer)', 'jquota_load()'] loop
      execute format('revoke all on function public.%s from fz_jarvis, fz_office_agent, fz_auditor', f);
    end loop;
  end if;
  if exists (select 1 from pg_roles where rolname = 'backup_reader') then
    foreach f in array array['jmem_search(text,text,real[],text,integer,text,text)', 'jmem_apply(text,jsonb,text,text,text)', 'jmem_list(text,text,integer)',
                             'jmem_forget(text,text,text,text)', 'jmem_links(text,text,integer)', 'jmem_stats()', 'jquota_record(text,integer,bigint,timestamptz,integer)', 'jquota_load()'] loop
      execute format('revoke all on function public.%s from backup_reader', f);
    end loop;
  end if;
end $$;

reset lock_timeout;
