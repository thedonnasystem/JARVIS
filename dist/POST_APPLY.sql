-- Run after APPLY_ALL.sql. Registers Moe as app owner (login via emailed code).
insert into public.app_owners (email) values ('moeaalafandi@gmail.com'), ('thedonnasystem@gmail.com') on conflict do nothing;
select 'owners' k, count(*) from public.app_owners
union all select 'policies', count(*) from public.action_policy;
