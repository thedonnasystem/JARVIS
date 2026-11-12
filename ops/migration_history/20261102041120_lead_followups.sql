alter table public.leads
  add column if not exists next_followup_at date,
  add column if not exists last_contact_at timestamptz,
  add column if not exists contact_count integer not null default 0,
  add column if not exists short_id serial;