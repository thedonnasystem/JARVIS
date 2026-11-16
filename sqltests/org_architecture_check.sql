-- SQL-level checks for migrations/20261123_org_divisions_v1.sql (docs/org/ORG_ARCHITECTURE.md, security self-review). SCRATCH replica only.
-- One transaction, rolled back: leaves nothing behind, including the rollback drill at the end (DDL is transactional).
-- Proves: (1) nobody can activate a division, the bot least of all; (2) envelopes are zero and proposals cannot exceed the company cap;
-- (3) a dormant division cannot create missions or spend (the guard answers false for everything); (4) delegation cannot self-escalate;
-- (5) kill-switch supremacy; (6) classification and export policy; (7) rollback script removes exactly this layer and the migration re-applies.
begin;
create function pg_temp.expect_fail(p_sql text, p_pat text) returns void language plpgsql as $$
begin
  begin execute p_sql; exception when others then
    if sqlerrm like p_pat then return; end if;
    raise exception 'wrong error for [%]: got [%], wanted like [%]', p_sql, sqlerrm, p_pat;
  end;
  raise exception 'NOT REFUSED: %', p_sql;
end $$;
create function pg_temp.as_owner(p boolean) returns void language plpgsql as $$
begin
  if p then perform set_config('app.uid', '99999999-9999-9999-9999-9999999999a1', true);
  else perform set_config('app.uid', '', true); end if;
end $$;

-- ---- A. structure, grants, seed ---------------------------------------------------------------------------------------
do $$
declare t text; r text; f text; n int;
begin
  insert into auth.users (id, email) values ('99999999-9999-9999-9999-9999999999a1', 'org-owner@example.com'), ('99999999-9999-9999-9999-9999999999a2', 'org-stranger@example.com');
  insert into public.app_owners (email) values ('org-owner@example.com');
  perform pg_temp.as_owner(false);
  foreach t in array array['org_divisions', 'org_division_grants'] loop
    if not (select relrowsecurity from pg_class where oid = ('public.' || t)::regclass) then raise exception 'A1 RLS off on %', t; end if;
    if exists (select 1 from pg_policies where schemaname = 'public' and tablename = t) then raise exception 'A2 % has a policy', t; end if;
    foreach r in array array['anon', 'authenticated'] loop
      if has_table_privilege(r, 'public.' || t, 'select') or has_table_privilege(r, 'public.' || t, 'insert') or has_table_privilege(r, 'public.' || t, 'update')
         or has_table_privilege(r, 'public.' || t, 'delete') then raise exception 'A3 % can touch %', r, t; end if;
    end loop;
    foreach r in array array['insert', 'update', 'delete', 'truncate', 'references', 'trigger'] loop
      if has_table_privilege('service_role', 'public.' || t, r) then raise exception 'A4 service_role can % %', r, t; end if;
    end loop;
    if not has_table_privilege('service_role', 'public.' || t, 'select') then raise exception 'A5 service_role cannot read %', t; end if;
  end loop;
  foreach f in array array['public.org_divisions_guard()', 'public.org_division_may(text,text)', 'public.org_division_spend_allowed(text,integer)',
                           'public.org_stage_division(text)', 'public.org_unstage_division(text)', 'public.org_propose_envelope(text,integer)'] loop
    foreach r in array array['anon', 'authenticated'] loop
      if has_function_privilege(r, f, 'execute') then raise exception 'A6 % can execute %', r, f; end if;
    end loop;
  end loop;
  -- no function of this layer can activate, grant or fund: the only org_* functions are the six above (org_scorecard_text is the existing 20261112 report)
  select count(*) into n from pg_proc where pronamespace = 'public'::regnamespace and proname like 'org\_%' and proname <> 'org_scorecard_text';
  if n <> 6 then raise exception 'A7 expected exactly 6 org_ functions, found %', n; end if;
  -- seed: 8 divisions, all dormant, all zero; every grant dormant
  select count(*) into n from public.org_divisions; if n <> 8 then raise exception 'A8 expected 8 seeded divisions, found %', n; end if;
  if exists (select 1 from public.org_divisions where status <> 'dormant' or proposed_daily_cents <> 0 or envelope_daily_cents <> 0 or staged_at is not null) then raise exception 'A9 a seeded division is not dormant/zero'; end if;
  if exists (select 1 from public.org_division_grants where status <> 'dormant') then raise exception 'A10 a seeded grant is not dormant'; end if;
  if not exists (select 1 from public.org_division_grants) then raise exception 'A11 no seeded allow-list rows'; end if;
end $$;

-- ---- B. the bot (service_role): no activation, no writes, no owner functions ------------------------------------------
-- the replica's public schema grants no USAGE to service_role (Supabase does). Grant it here so the refusals below are the TABLE and OWNER checks, not the schema.
grant usage on schema public to service_role;
set local role service_role;
do $$
declare q text; ok boolean;
begin
  foreach q in array array[
    $q$update public.org_divisions set status = 'active' where slug = 'donna'$q$,
    $q$update public.org_divisions set status = 'staged' where slug = 'donna'$q$,
    $q$update public.org_divisions set envelope_daily_cents = 1 where slug = 'donna'$q$,
    $q$update public.org_divisions set proposed_daily_cents = 1 where slug = 'donna'$q$,
    $q$insert into public.org_divisions (slug, name, contract_version) values ('rogue', 'Rogue', '1.0.0')$q$,
    $q$delete from public.org_divisions where slug = 'soccer'$q$,
    $q$insert into public.org_division_grants (division_slug, capability, scope) values ('donna', 'outbox.draft', 'own_division')$q$,
    $q$update public.org_division_grants set status = 'granted'$q$,
    $q$delete from public.org_division_grants$q$,
    $q$truncate public.org_division_grants$q$,
    $q$select public.org_stage_division('donna')$q$,
    $q$select public.org_unstage_division('donna')$q$,
    $q$select public.org_propose_envelope('donna', 1)$q$] loop
    ok := false;
    begin execute q; exception when others then
      if sqlerrm like 'permission denied for table org_division%' or sqlerrm like 'owner approval required%' then ok := true; else raise exception 'B1 wrong error for [%]: %', q, sqlerrm; end if; end;
    if not ok then raise exception 'B1 the bot was NOT refused: %', q; end if;
  end loop;
  -- the bot can ask the guard, and the answer is no
  if public.org_division_may('donna', 'llm.spend') then raise exception 'B2 guard said yes to the bot'; end if;
end $$;
reset role;
do $$ begin
  if (select count(*) from public.org_divisions where status = 'dormant' and proposed_daily_cents = 0) <> 8 or (select count(*) from public.org_division_grants where status <> 'dormant') <> 0
    then raise exception 'B3 the bot changed a division or a grant'; end if;
end $$;

-- a signed-in stranger (not an owner) is refused by the owner functions too
do $$ begin
  perform set_config('app.uid', '99999999-9999-9999-9999-9999999999a2', true);
  perform pg_temp.expect_fail($q$select public.org_stage_division('donna')$q$, 'owner approval required%');
  perform pg_temp.expect_fail($q$select public.org_propose_envelope('donna', 1)$q$, 'owner approval required%');
  perform pg_temp.as_owner(false);
end $$;

-- ---- C. nobody can activate, fund or grant: not the owner, not the table owner ---------------------------------------
do $$
declare cap int;
begin
  perform pg_temp.expect_fail($q$update public.org_divisions set status = 'active' where slug = 'donna'$q$, '%org_divisions_status_check%');
  perform pg_temp.expect_fail($q$insert into public.org_divisions (slug, name, status, contract_version) values ('x-new', 'X new', 'active', '1.0.0')$q$, '%org_divisions_status_check%');
  perform pg_temp.expect_fail($q$update public.org_divisions set envelope_daily_cents = 1 where slug = 'donna'$q$, '%org_divisions_envelope_daily_cents_check%');
  perform pg_temp.expect_fail($q$update public.org_division_grants set status = 'granted' where division_slug = 'donna'$q$, '%org_division_grants_status_check%');
  -- a dormant division holds no proposal either
  perform pg_temp.expect_fail($q$update public.org_divisions set proposed_daily_cents = 1 where slug = 'donna'$q$, '%org_divisions_dormant_has_nothing%');
  perform pg_temp.expect_fail($q$update public.org_divisions set slug = 'donna2' where slug = 'donna'$q$, '%slug cannot change%');

  -- owner path: stage, propose inside the cap, refused above it (single and combined), unstage clears
  perform pg_temp.as_owner(true);
  select daily_spend_cap_cents into cap from public.system_state where id = 1;
  if cap is null or cap <= 2 then raise exception 'C0 test needs a readable company cap above 2 cents, got %', cap; end if;
  perform pg_temp.expect_fail($q$select public.org_propose_envelope('donna', 1)$q$, '%not staged%');
  perform public.org_stage_division('donna');
  perform pg_temp.expect_fail($q$select public.org_stage_division('donna')$q$, '%not dormant%');
  perform pg_temp.expect_fail($q$select public.org_stage_division('no-such')$q$, '%unknown division%');
  perform pg_temp.expect_fail($q$select public.org_propose_envelope('donna', -1)$q$, '%zero or more%');
  perform pg_temp.expect_fail($q$select public.org_propose_envelope('donna', null)$q$, '%zero or more%');
  perform pg_temp.expect_fail(format($q$select public.org_propose_envelope('donna', %s)$q$, cap + 1), '%would exceed the company daily AI cap%');
  perform public.org_propose_envelope('donna', cap);                       -- exactly the cap is allowed
  perform public.org_stage_division('ffm');
  perform pg_temp.expect_fail($q$select public.org_propose_envelope('ffm', 1)$q$, '%would exceed the company daily AI cap%');   -- sum rule
  perform public.org_propose_envelope('donna', cap - 2);
  perform public.org_propose_envelope('ffm', 2);
  perform pg_temp.expect_fail($q$select public.org_propose_envelope('ffm', 3)$q$, '%would exceed the company daily AI cap%');
  -- the sum rule is a trigger, so it binds the table owner too, not only the function
  perform pg_temp.expect_fail($q$update public.org_divisions set proposed_daily_cents = proposed_daily_cents + 1 where slug = 'ffm'$q$, '%would exceed the company daily AI cap%');
  -- a staged division with a proposal still has a zero envelope and may do nothing
  if (select envelope_daily_cents from public.org_divisions where slug = 'donna') <> 0 then raise exception 'C1 staging created an envelope'; end if;
  if public.org_division_may('donna', 'llm.spend') or public.org_division_spend_allowed('donna', 1) then raise exception 'C2 a staged division may spend'; end if;
  if (select count(*) from public.audit_log where action in ('org_division_staged', 'org_envelope_proposed')) < 5 then raise exception 'C3 owner actions were not audited'; end if;
  perform public.org_unstage_division('donna');
  if (select status || ':' || proposed_daily_cents || ':' || coalesce(staged_at::text, 'null') from public.org_divisions where slug = 'donna') <> 'dormant:0:null' then raise exception 'C4 unstage did not clear'; end if;
  perform public.org_unstage_division('ffm');
  perform pg_temp.as_owner(false);
end $$;

-- ---- D. a dormant division cannot create missions or spend: the guard is false for every division x capability ------
do $$
declare r record; c text; n int;
begin
  for r in select slug from public.org_divisions loop
    foreach c in array array['mission.propose', 'mission.create', 'mission.run', 'task.create', 'llm.spend', 'memory.read', 'memory.write', 'research.fetch',
                             'outbox.draft', 'kpi.report', 'org.propose', 'workspace.read'] loop
      if public.org_division_may(r.slug, c) then raise exception 'D1 dormant division % may %', r.slug, c; end if;
    end loop;
    foreach n in array array[0, 1, 330] loop
      if public.org_division_spend_allowed(r.slug, n) then raise exception 'D2 dormant division % may spend % cents', r.slug, n; end if;
    end loop;
  end loop;
  if public.org_division_may('no-such', 'llm.spend') or public.org_division_may(null, null) or public.org_division_may('donna', 'no.such')
     or public.org_division_spend_allowed(null, null) or public.org_division_spend_allowed('donna', -5) then raise exception 'D3 guard said yes to nonsense'; end if;
  -- the guard has no path to yes in this schema: no row can be active or granted (checked in C), and it never writes
  if (select provolatile from pg_proc where oid = 'public.org_division_may(text,text)'::regprocedure) <> 's' then raise exception 'D4 guard is not read-only (stable)'; end if;
  -- the org layer added nothing to the existing mission/spend tables: no column, no trigger
  if exists (select 1 from pg_trigger t join pg_proc p on p.oid = t.tgfoid where p.proname like 'org\_%' and proname <> 'org_scorecard_text' and t.tgrelid <> 'public.org_divisions'::regclass) then raise exception 'D5 an org trigger sits on a table outside the org layer'; end if;
  if exists (select 1 from information_schema.columns where table_schema = 'public' and table_name in ('missions', 'tasks', 'agents', 'llm_calls', 'spend_reservations', 'executor_registry') and column_name like '%division%') then raise exception 'D6 the org layer changed an existing table'; end if;
end $$;

-- ---- E. delegation cannot self-escalate -------------------------------------------------------------------------------
do $$
declare c text;
begin
  foreach c in array array['grant.create', 'delegation.grant', 'division.activate', 'budget.set', 'permission.change', 'spend_cap.change', 'kill_switch.set',
                           'executor.register', 'executor.run', 'payment.send', 'bank.read', 'backup.run', 'deploy.release', 'migration.apply', 'owner.contact',
                           'privacy.change', 'consent.record', 'secret.read', 'outbox.send', 'agent.create', 'agent.activate'] loop
    perform pg_temp.expect_fail(format($q$insert into public.org_division_grants (division_slug, capability, scope) values ('donna', %L, 'own_division')$q$, c), '%org_division_grants_capability_check%');
  end loop;
  perform pg_temp.expect_fail($q$insert into public.org_division_grants (division_slug, capability, scope) values ('donna', 'LLM.SPEND', 'own_division')$q$, '%org_division_grants_capability_check%');
  perform pg_temp.expect_fail($q$insert into public.org_division_grants (division_slug, capability, scope) values ('donna', 'research.fetch', 'all_divisions')$q$, '%org_division_grants_scope_check%');
  perform pg_temp.expect_fail($q$insert into public.org_division_grants (division_slug, capability, scope) values ('no-such', 'research.fetch', 'own_division')$q$, '%foreign key%');
  -- no seeded row is on the forbidden list, and no division holds a client-workspace scope except ffm
  if exists (select 1 from public.org_division_grants where scope = 'own_workspaces' and division_slug <> 'ffm') then raise exception 'E1 a non-FFM division has a client-workspace scope'; end if;
  -- there is no function a division (or the bot) could call to add or widen a grant
  if exists (select 1 from pg_proc p where p.pronamespace = 'public'::regnamespace and p.proname like 'org\_%' and proname <> 'org_scorecard_text' and pg_get_functiondef(p.oid) ~* 'insert\s+into\s+public\.org_division_grants|update\s+public\.org_division_grants')
    then raise exception 'E2 a function writes org_division_grants'; end if;
end $$;

-- ---- F. kill-switch supremacy -----------------------------------------------------------------------------------------
do $$ begin
  perform pg_temp.as_owner(true);
  perform public.org_stage_division('research');
  update public.system_state set kill_switch = true where id = 1;      -- scratch database, rolled back with this transaction
  perform pg_temp.expect_fail($q$select public.org_stage_division('donna')$q$, '%kill switch is on%');
  perform pg_temp.expect_fail($q$select public.org_propose_envelope('research', 1)$q$, '%kill switch is on%');
  if public.org_division_may('research', 'research.fetch') then raise exception 'F1 guard said yes under the kill switch'; end if;
  perform public.org_unstage_division('research');                      -- stepping back is always allowed
  update public.system_state set kill_switch = false where id = 1;
  perform pg_temp.as_owner(false);
end $$;

-- ---- G. data classification and export policy -------------------------------------------------------------------------
do $$
declare pol jsonb := public.backup_export_policy(); t text;
begin
  if jsonb_array_length(pol -> 'unclassified') <> 0 then raise exception 'G1 unclassified tables: %', pol -> 'unclassified'; end if;
  foreach t in array array['org_divisions', 'org_division_grants'] loop
    if (select data_class from public.backup_classification() where table_name = t) is distinct from 'internal' then raise exception 'G2 % is not classified internal', t; end if;
    if not (t = any (array(select jsonb_array_elements_text(pol -> 'exported')))) then raise exception 'G3 % is not exported (column drift or foreign key closure?)', t; end if;
    -- no column an agent could write free text into: only the operator-seeded name is unconstrained text, and no function updates it
    if exists (select 1 from information_schema.columns where table_schema = 'public' and table_name = t and data_type in ('jsonb', 'json')) then raise exception 'G4 % has a free-form json column', t; end if;
  end loop;
  if exists (select 1 from pg_proc p where p.pronamespace = 'public'::regnamespace and p.proname like 'org\_%' and proname <> 'org_scorecard_text' and pg_get_functiondef(p.oid) ~* '\mname\s*=') then raise exception 'G5 a function writes org_divisions.name'; end if;
  -- the 20261119 classifications are all still there (this migration re-declares the function)
  if (select count(*) from public.backup_classification()) < 62 then raise exception 'G6 classification list shrank'; end if;
  foreach t in array array['leads', 'outbox', 'setters', 'contact_suppressions', 'client_workspaces', 'push_config'] loop
    if t = any (array(select jsonb_array_elements_text(pol -> 'exported'))) then raise exception 'G7 % became exported', t; end if;
  end loop;
end $$;

-- ---- H. rollback drill: the rollback script twice (idempotent), layer gone, classification restored; then the migration re-applies ----
create temp table org_drill as select md5(pg_get_functiondef('public.backup_classification()'::regprocedure)) as with_org;
\ir ../ops/rollback_org_architecture.sql
\ir ../ops/rollback_org_architecture.sql
do $$ begin
  if to_regclass('public.org_divisions') is not null or to_regclass('public.org_division_grants') is not null then raise exception 'H1 rollback left a table'; end if;
  if exists (select 1 from pg_proc where pronamespace = 'public'::regnamespace and proname like 'org\_%' and proname <> 'org_scorecard_text') then raise exception 'H2 rollback left a function'; end if;
  if exists (select 1 from public.backup_classification() where table_name like 'org\_%' and table_name <> 'org_changes') then raise exception 'H3 rollback left the classification rows'; end if;
  if (select count(*) from public.backup_classification()) <> 62 then raise exception 'H4 classification is not the 20261119 list (% rows)', (select count(*) from public.backup_classification()); end if;
  if jsonb_array_length(public.backup_export_policy() -> 'unclassified') <> 0 then raise exception 'H5 unclassified tables after rollback'; end if;
  if has_function_privilege('anon', 'public.backup_classification()', 'execute') or has_function_privilege('authenticated', 'public.backup_classification()', 'execute') then raise exception 'H6 rollback opened backup_classification'; end if;
  if to_regclass('public.missions') is null or to_regclass('public.system_state') is null or to_regclass('public.org_changes') is null then raise exception 'H7 rollback damaged an existing table'; end if;
end $$;
\ir ../migrations/20261123_org_divisions_v1.sql
do $$ begin
  if (select count(*) from public.org_divisions where status = 'dormant' and proposed_daily_cents = 0) <> 8 then raise exception 'H8 re-apply did not restore 8 dormant divisions'; end if;
  if md5(pg_get_functiondef('public.backup_classification()'::regprocedure)) <> (select with_org from org_drill) then raise exception 'H9 classification differs after re-apply'; end if;
  if has_table_privilege('service_role', 'public.org_divisions', 'update') or has_table_privilege('authenticated', 'public.org_divisions', 'select') then raise exception 'H10 grants wrong after re-apply'; end if;
end $$;
rollback;
