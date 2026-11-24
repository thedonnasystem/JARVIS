-- Rollback of migrations/20261208_heavy_bridge_v1.sql. Idempotent. One transaction. NON-DESTRUCTIVE: every job and its result is KEPT (the schema
-- fz_heavy is renamed to fz_heavy_archive, which has no privilege for any API role); only the functions go. Re-applying the migration renames it
-- back, so nothing is lost. The bot keeps working: with the functions gone, /heavy answers "not installed" (hq_heavy fails soft) and the scheduled
-- Claude Code run finds no claim function and stops. To switch the bridge off WITHOUT a rollback, send /heavy off (instant) and pause the scheduled task.
\if :{?fz_in_txn}
\else
begin;
\endif
drop function if exists public.heavy_enqueue(text, text, text), public.heavy_cancel(bigint), public.heavy_list(integer), public.heavy_claim(text),
  public.heavy_finish(bigint, text, text, text), public.heavy_set_enabled(boolean), public.heavy_tell_owner(text), public.heavy_job_json(bigint, boolean),
  public.heavy_guard();
do $$
begin
  if to_regnamespace('fz_heavy') is not null then
    -- the text check is a public function used by one table constraint: the constraint goes with it (the kept rows were checked when written);
    -- re-applying the migration puts it back
    alter table fz_heavy.jobs drop constraint if exists jobs_text_clean;
    if to_regnamespace('fz_heavy_archive') is null then
      alter schema fz_heavy rename to fz_heavy_archive;
      insert into public.audit_log (actor, action, target, detail) values ('rollback', 'heavy_bridge_archived', 'fz_heavy_archive',
        jsonb_build_object('jobs', (select count(*) from fz_heavy_archive.jobs)));
    else
      raise notice 'fz_heavy_archive already exists: fz_heavy left in place (nothing is dropped); reconcile by hand';
    end if;
  end if;
end $$;
drop function if exists public.heavy_text_problem(text);
\if :{?fz_in_txn}
\else
commit;
\endif
