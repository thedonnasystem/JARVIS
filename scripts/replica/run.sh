#!/usr/bin/env bash
# Applies every migration, in APPLY_ORDER.txt order, to a copy of the live HQ schema (tables, constraints, triggers, key
# functions captured Nov 12 2026), then runs an end-to-end script as a fake owner. Fails on the first SQL error.
# Usage: REPLICA_URL=postgresql://postgres:pw@localhost:5432/postgres scripts/replica/run.sh   (a scratch database; it is wiped)
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"; root="$here/../.."
: "${REPLICA_URL:?set REPLICA_URL to a scratch Postgres database}"
cd "$root"   # sqltests use \copy with repo-relative paths (sqltests/data/...)
psql_() { psql -q -v ON_ERROR_STOP=1 "$REPLICA_URL" "$@" 2>&1 | grep -v "NOTICE\|^DETAIL\|^drop cascades" || true; }
psql "$REPLICA_URL" -q -v ON_ERROR_STOP=1 -c "drop schema if exists public cascade; create schema public; drop schema if exists auth cascade; drop schema if exists cron cascade;" >/dev/null 2>&1
psql "$REPLICA_URL" -q -c "do \$\$ begin create role authenticated nologin; exception when duplicate_object then null; end \$\$; do \$\$ begin create role service_role nologin; exception when duplicate_object then null; end \$\$; do \$\$ begin create role anon nologin; exception when duplicate_object then null; end \$\$;" >/dev/null
# mirror Supabase: tables created later in schema public are granted to the API roles by default (RLS is what protects them)
psql "$REPLICA_URL" -q -c "alter default privileges in schema public grant all on tables to service_role, anon, authenticated;" >/dev/null
for f in 01_tables 02_constraints 03_funcs; do psql "$REPLICA_URL" -q -v ON_ERROR_STOP=1 -f "$here/$f.sql" >/dev/null 2>"${TMPDIR:-/tmp}/replica.err" || { cat "${TMPDIR:-/tmp}/replica.err"; echo "FAILED: $f"; exit 1; }; done
for f in $(grep -v '^#' "$root/migrations/APPLY_ORDER.txt"); do
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
echo "consent-integrity rollback drill: ops/rollback_consent_integrity.sql removes the evidence/suppression/gate objects, restores the previous functions, and the migrations re-apply"
psql "$REPLICA_URL" -q -v ON_ERROR_STOP=1 -f "$root/ops/rollback_consent_integrity.sql" >/dev/null 2>"${TMPDIR:-/tmp}/replica.err" || { cat "${TMPDIR:-/tmp}/replica.err"; echo "CONSENT ROLLBACK FAILED to run"; exit 1; }
psql "$REPLICA_URL" -q -v ON_ERROR_STOP=1 -f "$root/ops/rollback_consent_integrity.sql" >/dev/null 2>"${TMPDIR:-/tmp}/replica.err" || { cat "${TMPDIR:-/tmp}/replica.err"; echo "CONSENT ROLLBACK is not idempotent"; exit 1; }
left="$(psql "$REPLICA_URL" -At -c "select count(*) from pg_proc where pronamespace='public'::regnamespace and proname in ('ffm_hmac_sha256','normalize_phone','ffm_set_key','ffm_ingest_capture','ffm_register_capture_owner','ffm_outreach_gate_open','ffm_verify_suppression','backup_suppression_export','ffm_is_phone_suppressed','ffm_suppression_mac','ffm_close_outreach_gate')")"
tabs="$(psql "$REPLICA_URL" -At -c "select count(*) from pg_class where relnamespace='public'::regnamespace and relname in ('ffm_secrets','ffm_consent_captures','ffm_consent_wordings','ffm_phone_suppressions','ffm_suppression_hashes','ffm_suppression_expected','ffm_outreach_gate')")"
[ "$left" = "0" ] && [ "$tabs" = "0" ] || { echo "CONSENT ROLLBACK left $left functions and $tabs tables behind"; exit 1; }
old="$(psql "$REPLICA_URL" -At -c "select (select count(*) from pg_proc where proname='ffm_can_contact' and pronamespace='public'::regnamespace and pg_get_functiondef(oid) like '%ffm_contact_status%'), (select count(*) from pg_proc where proname='ffm_contact_status' and pronamespace='public'::regnamespace and pg_get_functiondef(oid) not like '%ffm_outreach_gate_open%'), (select count(*) from pg_proc where proname='outbox_dnc_guard' and pg_get_functiondef(oid) not like '%ffm_outreach_gate_open%'), (select count(*) from pg_proc where proname='is_suppressed' and pg_get_functiondef(oid) not like '%ffm_suppression_hashes%')")"
[ "$old" = "1|1|1|1" ] || { echo "CONSENT ROLLBACK did not restore the previous function definitions: $old"; exit 1; }
for f in $(grep -v '^#' "$root/migrations/APPLY_ORDER.txt"); do
  psql "$REPLICA_URL" -q -v ON_ERROR_STOP=1 -f "$root/migrations/$f" >/dev/null 2>"${TMPDIR:-/tmp}/replica.err" || { cat "${TMPDIR:-/tmp}/replica.err"; echo "FAILED re-applying after the consent-integrity rollback: $f"; exit 1; }
done
psql "$REPLICA_URL" -q -At -v ON_ERROR_STOP=1 -f "$root/sqltests/consent_integrity_check.sql" >/dev/null 2>"${TMPDIR:-/tmp}/replica.err" || { cat "${TMPDIR:-/tmp}/replica.err"; echo "consent_integrity_check failed after rollback + re-apply"; exit 1; }
echo "consent-integrity rollback drill OK (previous behaviour restored, then migrations re-apply and the consent checks pass again)"
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
echo "REPLICA OK"
