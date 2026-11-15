-- Rollback for 20261122_insurance_classifier_v1 (run with psql from the repo root, or paste into the SQL editor). Idempotent.
-- Restores ws_guard() and ffm_guard() to their 20261117 / 20261118 definitions (the strict ws_sensitive_hits screen on every table, no approved-term waiver),
-- then drops the classifier functions and the approved-terms table. ws_sensitive_hits (health detector, 20261119) is NOT touched by the migration and not by this rollback.
-- DATA LOSS (by design, small): the ws_approved_terms rows (the owner's list and its soft-removal history) are deleted. Export them first if you want to keep them:
--   select workspace_id, vertical, kind, term, created_at, removed_at from public.ws_approved_terms order by created_at;
-- Rows that were stored under an approved term stay in place (rollback never rewrites client rows); their next UPDATE will be refused again by the old strict guard.
-- Afterwards delete the 20261122_insurance_classifier_v1.sql line from migrations/APPLY_ORDER.txt and run scripts/build_bundle.sh, or the next apply recreates everything.
begin;
-- 1. the guards go back first, because the new versions call the classifier
create or replace function public.ws_guard() returns trigger
language plpgsql set search_path to 'public' as $$
declare k text; v text; hits text[]; allv text := '';
begin
  -- a value split across columns (name / phone / note) is caught by also scanning every scanned column joined together
  for k, v in select key, value from jsonb_each_text(to_jsonb(new) - array['id', 'workspace_id', 'campaign_id', 'created_at', 'status', 'stage', 'amount_cents', 'monthly_budget_cents']) loop
    allv := allv || ' ' || coalesce(v, '');
  end loop;
  hits := public.ws_sensitive_hits(allv);
  if array_length(hits, 1) > 0 then
    raise exception 'Sensitive data refused in % (%). Applications, banking, credit, ID and sensitive financial data must never be stored here.', tg_table_name, array_to_string(hits, ', ') using errcode = 'P0001';
  end if;
  for k, v in select key, value from jsonb_each_text(to_jsonb(new) - array['id', 'workspace_id', 'campaign_id', 'created_at', 'status', 'stage', 'amount_cents', 'monthly_budget_cents']) loop
    hits := public.ws_sensitive_hits(v);
    if array_length(hits, 1) > 0 then
      raise exception 'Sensitive data refused in %.% (%). Applications, banking, credit, ID and sensitive financial data must never be stored here.', tg_table_name, k, array_to_string(hits, ', ')
        using errcode = 'P0001';
    end if;
  end loop;
  return new;
end $$;

create or replace function public.ffm_guard() returns trigger
language plpgsql set search_path to 'public' as $$
declare k text; v text; hits text[]; allv text := ''; j jsonb := to_jsonb(new);
begin
  for k, v in select e.key, e.value #>> '{}' from jsonb_each(j) e
              where jsonb_typeof(e.value) = 'string'
                and not exists (select 1 from pg_attribute a where a.attrelid = tg_relid and a.attname = e.key and a.attnum > 0 and not a.attisdropped
                                  and a.atttypid in ('uuid'::regtype, 'timestamptz'::regtype)) loop
    hits := public.ws_sensitive_hits(v);
    if array_length(hits, 1) > 0 then
      raise exception 'Sensitive data refused in %.% (%). Applications, banking, credit, ID and sensitive financial data must never be stored here.', tg_table_name, k, array_to_string(hits, ', ') using errcode = 'P0001';
    end if;
    allv := allv || ' ' || v;
  end loop;
  hits := public.ws_sensitive_hits(allv);   -- a value split across columns
  if array_length(hits, 1) > 0 then
    raise exception 'Sensitive data refused in % (%). Applications, banking, credit, ID and sensitive financial data must never be stored here.', tg_table_name, array_to_string(hits, ', ') using errcode = 'P0001';
  end if;
  return new;
end $$;

-- 2. the classifier objects (guards no longer reference them)
drop function if exists public.ws_remove_approved_term(uuid);
drop function if exists public.ws_add_approved_term(uuid, text, text, text);
drop function if exists public.ws_classify_text(text, uuid);
drop function if exists public.ws_identifier_hit(text);
drop function if exists public.ws_personal_context_hit(text);
drop function if exists public.ws_health_extra_hit(text);
drop function if exists public.ws_leet_text(text, integer);
drop function if exists public.ws_fold_text(text);
drop table if exists public.ws_approved_terms;
drop function if exists public.ws_terms_immutable();
-- the replaced guards keep their grants (create or replace keeps ACLs); restate them so the file is safe on its own
revoke all on function public.ws_guard() from public, anon, authenticated;
revoke all on function public.ffm_guard() from public, anon, authenticated;
grant execute on function public.ws_guard() to service_role;
grant execute on function public.ffm_guard() to service_role;
commit;
