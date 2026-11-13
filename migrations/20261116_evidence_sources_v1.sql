-- Evidence verification v2, phase 1 (EVIDENCE_VERIFICATION_DESIGN.md s.2): a snapshot of the page / search text the engine actually
-- retrieved during a mission task, so a claim can later be compared with the SOURCE TEXT instead of the researcher's paraphrase.
-- Additive: one new table, two new functions. Touches no existing table, function, policy, cap, kill switch or grant.
-- The rows are UNTRUSTED DATA (flag column is fixed true): nothing in this table is ever executed or parsed for instructions.
--   * append-only: UPDATE is refused (the single exception is the FK clearing task_id when the researching task is deleted)
--   * default-deny: RLS on with no policy; anon/authenticated have nothing; service_role may select and insert, nothing else
--   * retention: purge_evidence_sources(days) deletes snapshots of FINISHED missions older than `days` (min 7); service_role only
create table if not exists public.evidence_sources (
  id uuid primary key default gen_random_uuid(),
  mission_id uuid references public.missions(id) on delete cascade,
  task_id uuid references public.tasks(id) on delete set null,
  kind text not null check (kind in ('page', 'search_snippet')),
  title text,
  url text not null,
  final_url text not null,
  host_norm text not null,
  status_code integer,
  content_type text,
  fetched_at timestamptz not null default now(),
  published_at timestamptz,
  content_sha256 text not null check (content_sha256 ~ '^[0-9a-f]{64}$'),
  text text not null check (length(text) <= 40000),
  truncated boolean not null default false,
  bytes_original integer,
  untrusted boolean not null default true check (untrusted),
  flags jsonb not null default '[]'::jsonb,
  created_at timestamptz not null default now()
);
create index if not exists evidence_sources_mission_idx on public.evidence_sources (mission_id);
create index if not exists evidence_sources_task_idx on public.evidence_sources (task_id);
create unique index if not exists evidence_sources_dedupe_idx on public.evidence_sources (task_id, content_sha256, final_url);
alter table public.evidence_sources enable row level security;   -- no policy on purpose: only the service role (which bypasses RLS) reads or writes

create or replace function public.evidence_sources_immutable() returns trigger
language plpgsql set search_path to 'public' as $$
begin
  if new.task_id is null and old.task_id is not null and (to_jsonb(new) - 'task_id') = (to_jsonb(old) - 'task_id') then
    return new;   -- only the foreign key detaching a deleted task is allowed
  end if;
  raise exception 'evidence_sources is append-only: stored source text cannot be changed.' using errcode = 'P0001';
end $$;
drop trigger if exists evidence_sources_immutable on public.evidence_sources;
create trigger evidence_sources_immutable before update on public.evidence_sources
  for each row execute function public.evidence_sources_immutable();

revoke all on public.evidence_sources from public, anon, authenticated;
grant select, insert on public.evidence_sources to service_role;   -- explicit, so the revoke below is a real narrowing
revoke update, delete, truncate on public.evidence_sources from public, anon, authenticated, service_role;

create or replace function public.purge_evidence_sources(p_days integer default 90) returns integer
language plpgsql security definer set search_path to 'public' as $$
declare n integer;
begin
  with gone as (
    delete from public.evidence_sources e
     where e.created_at < now() - make_interval(days => greatest(coalesce(p_days, 90), 7))
       and (e.mission_id is null or exists (select 1 from public.missions m where m.id = e.mission_id
                                            and m.status in ('completed', 'failed', 'rejected', 'abandoned')))
    returning 1)
  select count(*) into n from gone;
  return n;
end $$;

revoke all on function public.evidence_sources_immutable() from public, anon, authenticated;
revoke all on function public.purge_evidence_sources(integer) from public, anon, authenticated;
grant execute on function public.evidence_sources_immutable() to service_role;
grant execute on function public.purge_evidence_sources(integer) to service_role;
