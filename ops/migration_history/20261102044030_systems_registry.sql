create table if not exists public.systems (
  slug text primary key,
  venture_slug text,
  name text not null,
  url text,
  health_url text,
  repo text,
  data_store text,
  host text,
  warmup_local_times text[] default '{}',  -- 'HH:MM' Toronto times to wake/check it
  notes text,
  last_status int,
  last_ms int,
  last_checked_at timestamptz,
  active boolean not null default true
);
alter table public.systems enable row level security;
insert into public.systems (slug, venture_slug, name, url, health_url, repo, data_store, host, warmup_local_times, notes) values
 ('jarvis-hq', null, 'Jarvis + Fendezy HQ engine', null, null, 'thedonnasystem/JARVIS', 'Supabase fendezy-hq', 'Railway (Hobby)', '{}', 'Engine heartbeat is in system_state; reconciliation alerts if it goes quiet.'),
 ('deal-funnel', 'real-estate', 'Wholesale deal funnel', 'https://wholesale-deal-funnel.onrender.com', 'https://wholesale-deal-funnel.onrender.com/healthz', 'thedonnasystem/canada-wholesale-pipeline', 'Supabase wholesale-pipeline', 'Render free + GitHub Actions daily scrape', '{18:55}', 'Daily scrape 13:00 UTC via GitHub Actions. HQ writes AI valuations through rows_merge once WHOLESALE_SUPABASE_SERVICE_KEY is set.'),
 ('dialer', 'day-job-sales', 'Parallel dialer', 'https://dialer-40kq.onrender.com', 'https://dialer-40kq.onrender.com/', 'thedonnasystem/dialer', 'Render disk-less (data wiped on redeploy)', 'Render free', '{07:50}', 'Free tier sleeps after 15 min; HQ wakes it before the shift.'),
 ('call-coach', 'day-job-sales', 'Live call coach', 'https://call-coach-owhl.onrender.com', 'https://call-coach-owhl.onrender.com/healthz', 'thedonnasystem/dialer (coach/)', 'Render (no persistent disk)', 'Render starter', '{07:50}', 'Chrome extension + server; Deepgram + Anthropic keys on Render.'),
 ('donna-stack', 'donna', 'Donna receptionist stack', null, null, null, 'Retell AI, Twilio, Cal.com, Make.com', 'external SaaS', '{}', 'Six Retell agents, seven Twilio CA numbers. Not monitored yet (needs account access).'),
 ('freelance-pipeline', 'donna', 'Freelance proposal pipeline', null, null, 'thedonnasystem/freelance-pipeline', null, 'Railway (offline)', '{}', 'Parked on purpose.')
on conflict (slug) do nothing;