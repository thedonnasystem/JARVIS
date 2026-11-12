alter table public.owner_messages
  add column if not exists needs_decision boolean not null default false,
  add column if not exists ref_table text,
  add column if not exists ref_id uuid,
  add column if not exists decision text check (decision in ('approved','rejected')),
  add column if not exists decided_at timestamptz;