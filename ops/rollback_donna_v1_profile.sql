-- Rollback of migrations/20261204_donna_v1_profile_v1.sql. Idempotent. Run from the repo root:
--   psql -v ON_ERROR_STOP=1 -f ops/rollback_donna_v1_profile.sql          (one transaction: it opens and commits its own)
-- (sqltests/donna_v1_profile_check.sql sets fz_in_txn and runs it INSIDE its own rolled-back transaction.)
-- Order: BEFORE ops/rollback_office_os.sql (this file only changes one M7 row back).
-- Restores Donna's mission, roles, integrations, tiers, data class and rank from fz_archive.donna_profile_before_v1. Refused unless Donna is dormant.
-- Keeps the archive row (history). Writes audit_log by INSERT only. No-op when there is nothing to restore.
\if :{?fz_in_txn}
\else
begin;
\endif
do $$
declare a fz_archive.donna_profile_before_v1; p fz_office_os.fz_office_profiles;
begin
  if to_regclass('fz_archive.donna_profile_before_v1') is null or to_regclass('fz_office_os.fz_office_profiles') is null then return; end if;
  select * into a from fz_archive.donna_profile_before_v1 order by archived_at limit 1;
  if not found then return; end if;
  select * into p from fz_office_os.fz_office_profiles where slug = 'donna' for update;
  if not found or (p.mission = a.mission and p.agent_roles = a.agent_roles and p.integrations = a.integrations and p.autonomy = a.autonomy) then return; end if;
  if p.status <> 'dormant' or exists (select 1 from public.fz_offices where id = p.office_id and status <> 'dormant') then
    raise exception 'refused: Donna is %; deactivate her before restoring the previous profile', p.status using errcode = '42501';
  end if;
  update fz_office_os.fz_office_profiles set mission = a.mission, agent_roles = a.agent_roles, integrations = a.integrations, autonomy = a.autonomy,
         confidentiality = a.confidentiality, activation_rank = a.activation_rank, updated_at = now(), updated_by = 'rollback:donna_v1_profile' where slug = 'donna';
  insert into public.audit_log (actor, action, target, detail) values ('rollback', 'office_profile_v1_rolled_back', 'fz_office_profiles/donna', '{}'::jsonb);
end $$;
\if :{?fz_in_txn}
\else
commit;
\endif
