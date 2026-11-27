-- Donna v1 profile (migrations/20261204_donna_v1_profile_v1.sql). ONE transaction, rolled back. Fresh apply, repo root.
-- Runs under the production append-only lock on audit_log and ledger (added here, as in ops/proposals/audit_ledger_append_only.sql), so it proves the migration and its
-- rollback never update or delete those rows. Proves: Donna's profile is v1 (mission, 4 roles, integrations, tiers, the 8 real action_policy prohibitions + advisory ones);
-- the other 7 offices, the money controls and every other M7 row are untouched; rollback restores the archived previous values exactly; re-apply is idempotent;
-- the migration refuses while Donna is active.
begin;
\ir include/money_fingerprint.sql
-- the production lock (rolled back with the test)
create or replace function pg_temp.fzd_append_only() returns trigger language plpgsql as $$
begin raise exception '% is append-only', tg_relname using errcode = '42501'; end $$;
create trigger fzd_audit_lock before update or delete on public.audit_log for each row execute function pg_temp.fzd_append_only();
create trigger fzd_audit_trunc before truncate on public.audit_log for each statement execute function pg_temp.fzd_append_only();
create trigger fzd_ledger_lock before update or delete on public.ledger for each row execute function pg_temp.fzd_append_only();
create trigger fzd_ledger_trunc before truncate on public.ledger for each statement execute function pg_temp.fzd_append_only();
insert into auth.users (id, email) values ('99999999-9999-9999-9999-99999999f0d1', 'fzd-owner@example.invalid') on conflict do nothing;
insert into public.app_owners (email) values ('fzd-owner@example.invalid') on conflict do nothing;
select set_config('app.uid', '99999999-9999-9999-9999-99999999f0d1', true);
\set fz_in_txn 1
create temp table fzd_fp0 as select * from pg_temp.fz_money_fp();
create temp table fzd_others as select slug, md5(row(mission, agent_roles, integrations, autonomy, confidentiality, activation_rank, status, manager)::text) h
  from fz_office_os.fz_office_profiles where slug <> 'donna';
create temp table fzd_v1 as select mission, agent_roles, integrations, autonomy from fz_office_os.fz_office_profiles where slug = 'donna';
create temp table fzd_audit0 as select count(*) n from public.audit_log;
do $$
declare p record; s jsonb; a text;
begin
  -- D1 the v1 profile is in place
  select * into p from fz_office_os.fz_office_profiles where slug = 'donna';
  foreach a in array array['Ottawa AI infrastructure and digital-presence agency', '3 paying clients', 'Service line A', 'Service line B', 'No niche is locked',
                           '$497 first month, setup waived', 'Guarantee terms TBD by owner'] loop
    if position(a in p.mission) = 0 then raise exception 'D1 mission lacks: %', a; end if;
  end loop;
  if p.mission ilike '%refund%' then raise exception 'D1 mission mentions a refund'; end if;
  if p.agent_roles <> array['market-research', 'offer-pricing', 'outreach-prep', 'delivery-onboarding'] then raise exception 'D1 roles %', p.agent_roles; end if;
  if not ('stripe' = any (p.integrations)) or not ('resend' = any (p.integrations)) then raise exception 'D1 integrations %', p.integrations; end if;
  if p.status <> 'dormant' or p.manager is not null then raise exception 'D1 status / manager touched'; end if;
  s := public.office_os_status('donna');
  if (s -> 'prohibited_enforced') <> '["deceptive_communication", "deploy_website", "evade_platform_restrictions", "fabricate", "financial_transfer", "modify_own_permissions", "sign_contract", "spend_outside_budget"]'::jsonb then
    raise exception 'D1 enforced %', s -> 'prohibited_enforced'; end if;
  if not (s -> 'prohibited_advisory') ? 'client_portal_or_saas' or not (s -> 'prohibited_advisory') ? 'refund_or_guarantee_promise' then raise exception 'D1 advisory %', s -> 'prohibited_advisory'; end if;
  if exists (select 1 from jsonb_each(p.autonomy) t(tier, l), jsonb_array_elements_text(l) x group by x having count(*) > 1) then raise exception 'D1 an action in two tiers'; end if;
  if (select count(*) from fz_archive.donna_profile_before_v1) <> 1 or (select mission from fz_archive.donna_profile_before_v1) not like 'Run Donna, the AI agency:%' then
    raise exception 'D1 previous values not archived'; end if;
  if has_schema_privilege('service_role', 'fz_archive', 'usage') or has_schema_privilege('anon', 'fz_archive', 'usage') then raise exception 'D1 the archive is reachable'; end if;
end $$;
-- D2 idempotent re-apply (no change, no audit row), rollback restores the archive exactly, re-apply gives v1 again; all under the lock
\ir ../migrations/20261204_donna_v1_profile_v1.sql
do $$ begin
  if (select count(*) from public.audit_log) <> (select n from fzd_audit0) then raise exception 'D2 a no-op re-apply wrote'; end if;
end $$;
\ir ../ops/rollback_donna_v1_profile.sql
\ir ../ops/rollback_donna_v1_profile.sql
do $$ begin
  if exists (select 1 from fz_office_os.fz_office_profiles p, fz_archive.donna_profile_before_v1 a where p.slug = 'donna'
              and (p.mission, p.agent_roles, p.integrations, p.autonomy, p.confidentiality, p.activation_rank) is distinct from (a.mission, a.agent_roles, a.integrations, a.autonomy, a.confidentiality, a.activation_rank)) then
    raise exception 'D2 rollback did not restore the archived values'; end if;
  if (select count(*) from public.audit_log where action = 'office_profile_v1_rolled_back') <> 1 then raise exception 'D2 rollback not audited once'; end if;
end $$;
\ir ../migrations/20261204_donna_v1_profile_v1.sql
do $$ begin
  if exists (select 1 from fz_office_os.fz_office_profiles p, fzd_v1 v where p.slug = 'donna' and (p.mission, p.agent_roles, p.integrations, p.autonomy) is distinct from (v.mission, v.agent_roles, v.integrations, v.autonomy)) then
    raise exception 'D2 re-apply is not v1'; end if;
  if (select count(*) from fz_archive.donna_profile_before_v1) <> 1 then raise exception 'D2 the archive was overwritten'; end if;
end $$;
-- D3 refused while Donna is active (profile or M1); a no-op re-apply on an already-v1 Donna is still fine while active
\ir ../ops/rollback_donna_v1_profile.sql
update fz_office_os.fz_office_profiles set manager = 'fzd lead', status = 'active' where slug = 'donna';
savepoint fzd_s1;
\set ON_ERROR_STOP 0
\ir ../migrations/20261204_donna_v1_profile_v1.sql
\set fzd_err :ERROR
\set fzd_msg :LAST_ERROR_MESSAGE
\set ON_ERROR_STOP 1
rollback to savepoint fzd_s1;
select set_config('fzd.err', :'fzd_err', true), set_config('fzd.msg', :'fzd_msg', true);
do $$ begin
  if current_setting('fzd.err') <> 'true' or current_setting('fzd.msg') not like 'refused: Donna is %' then
    raise exception 'fzd_s1: not refused (error=%, message=%)', current_setting('fzd.err'), current_setting('fzd.msg'); end if;
end $$;
do $$ begin
  if (select mission from fz_office_os.fz_office_profiles where slug = 'donna') like 'Run Donna, an Ottawa%' then raise exception 'D3 applied while Donna is active'; end if;
end $$;
update fz_office_os.fz_office_profiles set status = 'dormant', manager = null where slug = 'donna';
update public.fz_offices set status = 'active' where slug = 'donna';
savepoint fzd_s2;
\set ON_ERROR_STOP 0
\ir ../migrations/20261204_donna_v1_profile_v1.sql
\set fzd_err :ERROR
\set fzd_msg :LAST_ERROR_MESSAGE
\set ON_ERROR_STOP 1
rollback to savepoint fzd_s2;
select set_config('fzd.err', :'fzd_err', true), set_config('fzd.msg', :'fzd_msg', true);
do $$ begin
  if current_setting('fzd.err') <> 'true' or current_setting('fzd.msg') not like 'refused: Donna is %' then
    raise exception 'fzd_s2: not refused (error=%, message=%)', current_setting('fzd.err'), current_setting('fzd.msg'); end if;
end $$;
do $$ begin
  if (select mission from fz_office_os.fz_office_profiles where slug = 'donna') like 'Run Donna, an Ottawa%' then raise exception 'D3 applied while Donna is active in M1'; end if;
end $$;
update public.fz_offices set status = 'dormant' where slug = 'donna';
\ir ../migrations/20261204_donna_v1_profile_v1.sql
update fz_office_os.fz_office_profiles set manager = 'fzd lead', status = 'active' where slug = 'donna';
\ir ../migrations/20261204_donna_v1_profile_v1.sql
savepoint fzd_s3;
\set ON_ERROR_STOP 0
\ir ../ops/rollback_donna_v1_profile.sql
\set fzd_err :ERROR
\set fzd_msg :LAST_ERROR_MESSAGE
\set ON_ERROR_STOP 1
rollback to savepoint fzd_s3;
select set_config('fzd.err', :'fzd_err', true), set_config('fzd.msg', :'fzd_msg', true);
do $$ begin
  if current_setting('fzd.err') <> 'true' or current_setting('fzd.msg') not like 'refused: Donna is %' then
    raise exception 'fzd_s3: not refused (error=%, message=%)', current_setting('fzd.err'), current_setting('fzd.msg'); end if;
end $$;
do $$ begin
  if (select mission from fz_office_os.fz_office_profiles where slug = 'donna') not like 'Run Donna, an Ottawa%' then raise exception 'D3 rolled back while Donna is active'; end if;
end $$;
update fz_office_os.fz_office_profiles set status = 'dormant', manager = null where slug = 'donna';
-- D4 nothing else changed: the other 7 offices, the money controls; the lock is still there and still refuses
create temp table fzd_fp1 as select * from pg_temp.fz_money_fp();
do $$ begin
  if exists (select 1 from fzd_others o full join (select slug, md5(row(mission, agent_roles, integrations, autonomy, confidentiality, activation_rank, status, manager)::text) h
                                                     from fz_office_os.fz_office_profiles where slug <> 'donna') n using (slug) where o.h is distinct from n.h) then
    raise exception 'D4 another office changed'; end if;
  if exists (select 1 from fzd_fp0 a full join fzd_fp1 b using (k) where a.v is distinct from b.v and a.k not like '%audit_log%') then raise exception 'D4 the money controls changed'; end if;
  begin update public.audit_log set detail = '{}' where false or id = (select id from public.audit_log limit 1); raise exception 'D4 the lock is gone'; exception when insufficient_privilege then null; end;
  if (select mission from fz_office_os.fz_office_profiles where slug = 'donna') not like 'Run Donna, an Ottawa%' then raise exception 'D4 donna is not v1 at the end'; end if;
  if has_schema_privilege('service_role', 'fz_archive', 'usage') or has_schema_privilege('anon', 'fz_archive', 'usage') then raise exception 'D4 the archive is reachable'; end if;
  raise notice 'donna_v1_profile_check: all checks passed';
end $$;
rollback;
