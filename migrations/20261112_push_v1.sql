-- Web push for the private app (iOS 16.4+ installed Home Screen apps, desktop browsers). No third-party service, no subscription.
-- Depends on 20261112_webapp_v1.sql (is_app_owner). The VAPID private key lives ONLY in push_config (RLS locked, service key only);
-- it is inserted at apply time, never committed to git. The app can read the PUBLIC key and save its own subscription, nothing else.

create table if not exists public.push_config (
  id int primary key default 1 check (id = 1),
  vapid_public text,
  vapid_private text,
  subject text not null default 'mailto:owner@example.invalid'
);
alter table public.push_config enable row level security;
insert into public.push_config (id) values (1) on conflict (id) do nothing;

create table if not exists public.push_subscriptions (
  endpoint text primary key,
  p256dh text not null,
  auth text not null,
  user_agent text,
  created_at timestamptz not null default now(),
  last_ok_at timestamptz,
  fail_count int not null default 0
);
alter table public.push_subscriptions enable row level security;

create or replace function public.app_push_public_key() returns text
language plpgsql stable security definer set search_path to 'public' as $$
begin
  if not public.is_app_owner() then raise exception 'Not authorized'; end if;
  return (select vapid_public from public.push_config where id = 1);
end $$;

create or replace function public.app_save_push(p_sub jsonb, p_ua text default null) returns void
language plpgsql security definer set search_path to 'public' as $$
begin
  if not public.is_app_owner() then raise exception 'Not authorized'; end if;
  if coalesce(p_sub->>'endpoint', '') !~ '^https://' or coalesce(p_sub#>>'{keys,p256dh}', '') = '' or coalesce(p_sub#>>'{keys,auth}', '') = '' then
    raise exception 'Bad subscription';
  end if;
  insert into public.push_subscriptions (endpoint, p256dh, auth, user_agent)
  values (p_sub->>'endpoint', p_sub#>>'{keys,p256dh}', p_sub#>>'{keys,auth}', left(p_ua, 200))
  on conflict (endpoint) do update set p256dh = excluded.p256dh, auth = excluded.auth, fail_count = 0;
end $$;

revoke all on function public.app_push_public_key(), public.app_save_push(jsonb, text) from public, anon;
grant execute on function public.app_push_public_key(), public.app_save_push(jsonb, text) to authenticated;
