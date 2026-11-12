-- Venture independence (spec 11): each venture records its websites/assets/integrations and its operating procedures.
-- Needs ventures_v1 and webapp_v1. No credentials are ever stored here: only names, URLs and status.
create table if not exists public.venture_assets (
  id uuid primary key default gen_random_uuid(),
  venture_id uuid references public.ventures(id) on delete cascade,        -- null = company-wide
  kind text not null check (kind in ('website','domain','account','integration','asset','repo')),
  name text not null check (length(name) >= 2),
  url text,
  status text not null default 'planned' check (status in ('planned','live','retired')),
  notes text,
  created_by text not null default 'jarvis',
  created_at timestamptz not null default now()
);
alter table public.venture_assets enable row level security;
create index if not exists venture_assets_v_idx on public.venture_assets(venture_id, status);

create table if not exists public.venture_procedures (
  id uuid primary key default gen_random_uuid(),
  venture_id uuid references public.ventures(id) on delete cascade,        -- null = company-wide
  title text not null check (length(title) >= 4),
  steps text not null check (length(steps) >= 20),
  owner_agent text,
  version int not null default 1,
  status text not null default 'active' check (status in ('active','retired')),
  created_by text not null default 'jarvis',
  updated_at timestamptz not null default now(),
  unique (venture_id, title)
);
alter table public.venture_procedures enable row level security;

create or replace function public.app_venture_extras(p_slug text) returns jsonb
language plpgsql stable security definer set search_path to 'public' as $$
declare v_id uuid;
begin
  if not public.is_app_owner() then raise exception 'not authorized' using errcode = '42501'; end if;
  select id into v_id from ventures where slug = p_slug;
  return jsonb_build_object(
    'assets', (select coalesce(jsonb_agg(jsonb_build_object('kind', kind, 'name', name, 'url', url, 'status', status) order by created_at desc), '[]'::jsonb)
               from (select * from venture_assets where venture_id is not distinct from v_id and status <> 'retired' order by created_at desc limit 12) a),
    'procedures', (select coalesce(jsonb_agg(jsonb_build_object('title', title, 'version', version, 'owner', owner_agent) order by title), '[]'::jsonb)
                   from (select * from venture_procedures where venture_id is not distinct from v_id and status = 'active' order by title limit 12) p));
end $$;
revoke all on function public.app_venture_extras(text) from public, anon;
grant execute on function public.app_venture_extras(text) to authenticated;
