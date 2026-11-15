#!/usr/bin/env bash
# Applies every migration, in APPLY_ORDER.txt order, to a copy of the live HQ schema (tables, constraints, triggers, key
# functions captured Nov 12 2026), then runs an end-to-end script as a fake owner. Fails on the first SQL error.
# Usage: REPLICA_URL=postgresql://postgres:pw@localhost:5432/postgres scripts/replica/run.sh   (a scratch database; it is wiped)
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"; root="$here/../.."
: "${REPLICA_URL:?set REPLICA_URL to a scratch Postgres database}"
psql_() { psql -q -v ON_ERROR_STOP=1 "$REPLICA_URL" "$@" 2>&1 | grep -v "NOTICE\|^DETAIL\|^drop cascades" || true; }
psql "$REPLICA_URL" -q -v ON_ERROR_STOP=1 -c "drop schema if exists public cascade; create schema public; drop schema if exists auth cascade; drop schema if exists cron cascade;" >/dev/null 2>&1
psql "$REPLICA_URL" -q -c "do \$\$ begin create role authenticated nologin; exception when duplicate_object then null; end \$\$; do \$\$ begin create role service_role nologin; exception when duplicate_object then null; end \$\$; do \$\$ begin create role anon nologin; exception when duplicate_object then null; end \$\$;" >/dev/null
# mirror Supabase: tables created later in schema public are granted to the API roles by default (RLS is what protects them)
psql "$REPLICA_URL" -q -c "alter default privileges in schema public grant all on tables to service_role, anon, authenticated;" >/dev/null
for f in 01_tables 02_constraints 03_funcs; do psql "$REPLICA_URL" -q -v ON_ERROR_STOP=1 -f "$here/$f.sql" >/dev/null 2>"${TMPDIR:-/tmp}/replica.err" || { cat "${TMPDIR:-/tmp}/replica.err"; echo "FAILED: $f"; exit 1; }; done
guards_before=""
for f in $(grep -v '^#' "$root/migrations/APPLY_ORDER.txt"); do
  if [ "$f" = "20261122_insurance_classifier_v1.sql" ]; then guards_before="$(psql "$REPLICA_URL" -At -c "select md5(pg_get_functiondef('public.ws_guard()'::regprocedure)) || ' ' || md5(pg_get_functiondef('public.ffm_guard()'::regprocedure))")"; fi
  psql "$REPLICA_URL" -q -v ON_ERROR_STOP=1 -f "$root/migrations/$f" >/dev/null 2>"${TMPDIR:-/tmp}/replica.err" || { cat "${TMPDIR:-/tmp}/replica.err"; echo "FAILED: $f"; exit 1; }
  echo "applied $f"
done
echo "re-applying every migration (must be safe to run twice)"
for f in $(grep -v '^#' "$root/migrations/APPLY_ORDER.txt"); do
  psql "$REPLICA_URL" -q -v ON_ERROR_STOP=1 -f "$root/migrations/$f" >/dev/null 2>"${TMPDIR:-/tmp}/replica.err" || { cat "${TMPDIR:-/tmp}/replica.err"; echo "FAILED on second apply: $f"; exit 1; }
done
psql "$REPLICA_URL" -q -At -v ON_ERROR_STOP=1 -f "$here/e2e.sql" 2>&1 | grep -v NOTICE | cut -c1-200
if python3 -c "import psycopg2" 2>/dev/null; then
  echo "integration: real engine + mission code against the replica database"
  python3 "$here/run_integration.py" 2>&1 | grep -v '^Traceback\|^  File\|^    \|~\|^HQ ' | tail -40
  python3 "$here/run_integration.py" >/dev/null 2>&1 || { echo "INTEGRATION FAILED"; exit 1; }
elif [ -n "${REQUIRE_INTEGRATION:-}" ]; then echo "psycopg2 missing but REQUIRE_INTEGRATION is set"; exit 1
else echo "integration: skipped (pip install psycopg2-binary to enable)"; fi
for f in "$root"/sqltests/*.sql; do   # SQL-level checks (grants, behaviour) run in CI, not only by hand
  [ -e "$f" ] || continue
  echo "sqltest: $(basename "$f")"
  psql "$REPLICA_URL" -q -At -v ON_ERROR_STOP=1 -f "$f" >/dev/null 2>"${TMPDIR:-/tmp}/sqltest.err" || { cat "${TMPDIR:-/tmp}/sqltest.err"; echo "SQLTEST FAILED: $f"; exit 1; }
done
echo "sprint rollback drill: ops/rollback_sprint12.sql removes only the Sprint 1-2 objects and leaves Phase 1 and the suppression list in place"
psql "$REPLICA_URL" -q -v ON_ERROR_STOP=1 -f "$root/ops/rollback_sprint12.sql" >/dev/null 2>&1 || { echo "SPRINT ROLLBACK FAILED to run"; exit 1; }
psql "$REPLICA_URL" -q -v ON_ERROR_STOP=1 -f "$root/ops/rollback_sprint12.sql" >/dev/null 2>&1 || { echo "SPRINT ROLLBACK is not idempotent"; exit 1; }
p1="$(psql "$REPLICA_URL" -At -c "select count(*) from pg_proc where pronamespace='public'::regnamespace and proname in ('ops_alerts','mission_guard','set_focus_mission','_queue_alert','audit_task_bulk_update','audit_task_bulk_delete','enforce_mission_step_limit','enforce_mission_plan_limit')")"
[ "$p1" = "8" ] || { echo "SPRINT ROLLBACK DAMAGED PHASE 1: only $p1 of 8 Phase 1 functions remain"; exit 1; }
gone="$(psql "$REPLICA_URL" -At -c "select count(*) from pg_proc where pronamespace='public'::regnamespace and (proname in ('backup_schema','backup_snapshot','ensure_venture_agents','queue_all_prospect_tasks','venture_kpis','lead_funnel','is_suppressed','normalize_addr','mark_do_not_contact','record_lead_reply','create_deal','set_deal_stage','confirm_deal_won','venture_config_get','set_venture_config','needs_you','app_needs_you','purge_evidence_sources','evidence_sources_immutable') or (proname='queue_prospect_task' and pronargs=1))")"
[ "$gone" = "0" ] || { echo "SPRINT ROLLBACK left $gone Sprint 1-2 functions behind"; exit 1; }
[ "$(psql "$REPLICA_URL" -At -c "select to_regclass('public.contact_suppressions') is not null")" = "t" ] || { echo "SPRINT ROLLBACK dropped the suppression list"; exit 1; }
for f in $(grep -v '^#' "$root/migrations/APPLY_ORDER.txt"); do
  psql "$REPLICA_URL" -q -v ON_ERROR_STOP=1 -f "$root/migrations/$f" >/dev/null 2>"${TMPDIR:-/tmp}/replica.err" || { cat "${TMPDIR:-/tmp}/replica.err"; echo "FAILED re-applying after sprint rollback: $f"; exit 1; }
done
echo "sprint rollback drill OK (Phase 1 intact, suppression list kept, migrations re-apply cleanly)"
echo "rollback drill: Phase 1 rollback must restore the live (Nov 12) function definitions exactly"
psql "$REPLICA_URL" -q -v ON_ERROR_STOP=1 -f "$root/ops/rollback_phase1.sql" >/dev/null 2>&1
psql "$REPLICA_URL" -q -v ON_ERROR_STOP=1 -f "$root/ops/rollback_phase1.sql" >/dev/null 2>&1   # idempotent
psql "$REPLICA_URL" -q -v ON_ERROR_STOP=1 -f "$root/migrations/20261112_lockdown_v1.sql" >/dev/null 2>&1
got="$(psql "$REPLICA_URL" -At -c "select p.oid::regprocedure::text||' '||md5(pg_get_functiondef(p.oid)) from pg_proc p where p.pronamespace='public'::regnamespace and p.prokind='f' and p.proname in ('queue_outreach_drafts','queue_valuation_task','reserve_llm_budget','enforce_build_rules') order by 1")"
want="$(grep -E '^(queue_outreach_drafts|queue_valuation_task|reserve_llm_budget|enforce_build_rules)\(' "$root/ops/live_functions_baseline_20261112.txt" | sort)"
[ "$got" = "$want" ] || { echo "ROLLBACK DRILL FAILED"; diff <(echo "$got") <(echo "$want"); exit 1; }
left="$(psql "$REPLICA_URL" -At -c "select count(*) from pg_proc where pronamespace='public'::regnamespace and proname in ('ops_alerts','mission_guard','set_focus_mission','_queue_alert','audit_task_bulk_update','audit_task_bulk_delete','enforce_mission_step_limit','enforce_mission_plan_limit','backup_schema','backup_snapshot','ensure_venture_agents','queue_all_prospect_tasks','venture_kpis','lead_funnel','is_suppressed','normalize_addr','mark_do_not_contact','record_lead_reply','create_deal','set_deal_stage','confirm_deal_won','venture_config_get','set_venture_config','leads_suppression_guard','leads_dnc_cascade','outbox_dnc_guard','needs_you','app_needs_you','purge_evidence_sources','evidence_sources_immutable')")"
left2="$(psql "$REPLICA_URL" -At -c "select count(*) from pg_proc where pronamespace='public'::regnamespace and proname='queue_prospect_task' and pronargs=1")"
[ "$left2" = "0" ] || { echo "ROLLBACK DRILL FAILED: queue_prospect_task(text) remains"; exit 1; }
[ "$left" = "0" ] || { echo "ROLLBACK DRILL FAILED: $left Phase 1 functions remain"; exit 1; }
for f in $(grep -v '^#' "$root/migrations/APPLY_ORDER.txt"); do   # the whole order again, so the state afterwards equals a fresh apply
  psql "$REPLICA_URL" -q -v ON_ERROR_STOP=1 -f "$root/migrations/$f" >/dev/null 2>"${TMPDIR:-/tmp}/replica.err" || { cat "${TMPDIR:-/tmp}/replica.err"; echo "FAILED re-applying after rollback: $f"; exit 1; }
done
echo "rollback drill OK (and the migrations re-apply cleanly afterwards)"
echo "rollback drill: ops/rollback_insurance_classifier.sql restores the strict guards and removes the classifier objects (twice = idempotent), then everything re-applies"
psql "$REPLICA_URL" -q -v ON_ERROR_STOP=1 -f "$root/ops/rollback_insurance_classifier.sql" >/dev/null 2>&1 || { echo "INSURANCE ROLLBACK FAILED to run"; exit 1; }
psql "$REPLICA_URL" -q -v ON_ERROR_STOP=1 -f "$root/ops/rollback_insurance_classifier.sql" >/dev/null 2>&1 || { echo "INSURANCE ROLLBACK is not idempotent"; exit 1; }
ic="$(psql "$REPLICA_URL" -At -c "select (select count(*) from pg_proc where pronamespace='public'::regnamespace and proname in ('ws_classify_text','ws_classify_core','ws_insurance_context','ws_text_insurance_word','ws_residual_check','ws_vocab_denied','ws_condition_hit','ws_fold_text','ws_leet_text','ws_health_extra_hit','ws_personal_context_hit','ws_identifier_hit','ws_add_approved_term','ws_remove_approved_term','ws_add_vocab_word','ws_remove_vocab_word','ws_terms_immutable','ws_place_catalog_immutable')) || '/' || coalesce(to_regclass('public.ws_approved_terms')::text, 'none') || coalesce(to_regclass('public.ws_marketing_vocab')::text, '') || coalesce(to_regclass('public.ws_place_catalog')::text, '') || '/' || (position('ws_classify' in pg_get_functiondef('public.ws_guard()'::regprocedure)) + position('ws_classify' in pg_get_functiondef('public.ffm_guard()'::regprocedure)))")"
[ "$ic" = "0/none/0" ] || { echo "INSURANCE ROLLBACK DRILL FAILED: $ic"; exit 1; }
guards_after="$(psql "$REPLICA_URL" -At -c "select md5(pg_get_functiondef('public.ws_guard()'::regprocedure)) || ' ' || md5(pg_get_functiondef('public.ffm_guard()'::regprocedure))")"
[ -n "$guards_before" ] && [ "$guards_before" = "$guards_after" ] || { echo "INSURANCE ROLLBACK DRILL FAILED: guards not restored exactly ($guards_before vs $guards_after)"; exit 1; }
echo "insurance rollback restored ws_guard() and ffm_guard() byte-identically"
psql "$REPLICA_URL" -q -v ON_ERROR_STOP=1 -c "do \$\$ declare w uuid; begin insert into public.client_workspaces (slug, name, vertical) values ('ic-drill', 'Drill', 'insurance') returning id into w; begin insert into public.ws_campaigns (workspace_id, name) values (w, 'Critical illness insurance'); raise exception 'DRILL: old strict guard let health wording through'; exception when sqlstate 'P0001' then if sqlerrm like 'DRILL%' then raise; end if; end; delete from public.client_workspaces where id = w; end \$\$;" >/dev/null 2>"${TMPDIR:-/tmp}/replica.err" || { cat "${TMPDIR:-/tmp}/replica.err"; echo "INSURANCE ROLLBACK DRILL FAILED: strict guard not restored"; exit 1; }
for f in $(grep -v '^#' "$root/migrations/APPLY_ORDER.txt"); do
  psql "$REPLICA_URL" -q -v ON_ERROR_STOP=1 -f "$root/migrations/$f" >/dev/null 2>"${TMPDIR:-/tmp}/replica.err" || { cat "${TMPDIR:-/tmp}/replica.err"; echo "FAILED re-applying after insurance rollback: $f"; exit 1; }
done
echo "insurance rollback drill OK (and the migrations re-apply cleanly afterwards)"
echo "REPLICA OK"
