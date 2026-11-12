-- Security lockdown (found on first live apply): functions made with plain CREATE FUNCTION are executable by anon/authenticated by default.
-- Several take a caller-supplied "p_by" string, so an anonymous caller could have passed 'owner'. Close everything except the
-- owner-checked app_* functions; the bot uses the service role, which keeps explicit access. Safe to re-run; apply LAST.
do $$
declare r record;
begin
  for r in select p.oid::regprocedure as sig from pg_proc p join pg_namespace n on n.oid = p.pronamespace
           where n.nspname = 'public' and p.prokind = 'f'
             and p.proname not in ('is_app_owner','app_snapshot','app_messages','app_send','app_set_kill','app_set_agent','app_venture','app_venture_extras','app_office','app_payments','app_push_public_key','app_save_push')
  loop
    execute format('revoke all on function %s from public, anon, authenticated', r.sig);
  end loop;
end $$;
alter default privileges in schema public revoke execute on functions from public, anon, authenticated;
grant execute on all functions in schema public to service_role;
alter default privileges in schema public grant execute on functions to service_role;
