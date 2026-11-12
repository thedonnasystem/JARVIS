create table if not exists public.company_profile (
  venture_slug text primary key,
  sender_name text,
  brand text,
  mailing_address text,
  reply_email text,
  updated_at timestamptz not null default now()
);
alter table public.company_profile enable row level security;
insert into public.company_profile (venture_slug, sender_name, brand) values ('donna', 'Moe', 'The Donna System') on conflict do nothing;