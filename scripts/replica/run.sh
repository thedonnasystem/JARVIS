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
guards_before=""
for f in $(grep -v '^#' "$root/migrations/APPLY_ORDER.txt"); do
  if [ "$f" = "20261122_insurance_classifier_v1.sql" ]; then guards_before="$(psql "$REPLICA_URL" -At -c "select md5(pg_get_functiondef('public.ws_guard()'::regprocedure)) || ' ' || md5(pg_get_functiondef('public.ffm_guard()'::regprocedure))")"; fi
  # office money M2: the money controls (protected functions + ACLs, triggers, money table contents + ACLs, capital_snapshot, the authorize_action / reserve_spend decision
  # matrix) must be IDENTICAL right before and right after it is applied (sqltests/include/money_fingerprint.sql; the sqltest repeats this for rollback and re-apply)
  if [ "$f" = "20261128_office_money_v1.sql" ] || [ "$f" = "20261129_approvals_kernel_v1.sql" ] || [ "$f" = "20261130_security_hardening_v1.sql" ] || [ "$f" = "20261201_shared_services_v1.sql" ]; then psql "$REPLICA_URL" -q -At -v ON_ERROR_STOP=1 -f "$root/sqltests/include/money_fingerprint.sql" -c "select k || ' ' || md5(v) from pg_temp.fz_money_fp() order by k" >"${TMPDIR:-/tmp}/money_fp_before" 2>"${TMPDIR:-/tmp}/replica.err" || { cat "${TMPDIR:-/tmp}/replica.err"; echo "MONEY FINGERPRINT FAILED"; exit 1; }; fi
  psql "$REPLICA_URL" -q -v ON_ERROR_STOP=1 -f "$root/migrations/$f" >/dev/null 2>"${TMPDIR:-/tmp}/replica.err" || { cat "${TMPDIR:-/tmp}/replica.err"; echo "FAILED: $f"; exit 1; }
  if [ "$f" = "20261128_office_money_v1.sql" ] || [ "$f" = "20261129_approvals_kernel_v1.sql" ] || [ "$f" = "20261130_security_hardening_v1.sql" ] || [ "$f" = "20261201_shared_services_v1.sql" ]; then
    psql "$REPLICA_URL" -q -At -v ON_ERROR_STOP=1 -f "$root/sqltests/include/money_fingerprint.sql" -c "select k || ' ' || md5(v) from pg_temp.fz_money_fp() order by k" >"${TMPDIR:-/tmp}/money_fp_after" 2>"${TMPDIR:-/tmp}/replica.err" || { cat "${TMPDIR:-/tmp}/replica.err"; echo "MONEY FINGERPRINT FAILED"; exit 1; }
    [ "$(wc -l <"${TMPDIR:-/tmp}/money_fp_before")" -ge 300 ] || { echo "MONEY FINGERPRINT too small"; exit 1; }
    diff "${TMPDIR:-/tmp}/money_fp_before" "${TMPDIR:-/tmp}/money_fp_after" >/dev/null || { diff "${TMPDIR:-/tmp}/money_fp_before" "${TMPDIR:-/tmp}/money_fp_after" | head -20; echo "OFFICE MONEY CHANGED THE MONEY CONTROLS (fingerprint before vs after $f)"; exit 1; }
    echo "money controls identical before and after $f ($(wc -l <"${TMPDIR:-/tmp}/money_fp_after") fingerprint rows)"
  fi
  echo "applied $f"
done
echo "re-applying every migration (must be safe to run twice)"
for f in $(grep -v '^#' "$root/migrations/APPLY_ORDER.txt"); do
  psql "$REPLICA_URL" -q -v ON_ERROR_STOP=1 -f "$root/migrations/$f" >/dev/null 2>"${TMPDIR:-/tmp}/replica.err" || { cat "${TMPDIR:-/tmp}/replica.err"; echo "FAILED on second apply: $f"; exit 1; }
done
# M4: the privileged grants of the fresh database are exactly the reviewed allowlist (ops/expected_grants.tsv == fz_expected_grants())
python3 "$root/scripts/expected_grants.py" --url "$REPLICA_URL" --check || { echo "EXPECTED GRANTS CHECK FAILED (a grant changed: review it, then scripts/expected_grants.py --write)"; exit 1; }
psql "$REPLICA_URL" -q -At -v ON_ERROR_STOP=1 -f "$here/e2e.sql" 2>&1 | grep -v NOTICE | cut -c1-200
echo "perf: backup_snapshot() redaction cost on 2,000 audit rows + 200 tasks of 11.5k characters (budget 60 s, normal 5-8 s on the scratch machine)"
"$root/scripts/perf_redaction.sh" "$REPLICA_URL" 2000 200 60 || { echo "PERF CHECK FAILED"; exit 1; }
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
echo "perf: write-path cost of the redaction epoch triggers at 50,000 leads + 50,000 outbox rows (round 8, S5; budget 1500 ms for a 150-row lead insert; rolled back)"
"$root/scripts/perf_epoch_triggers.sh" "$REPLICA_URL" 50000 1500 || { echo "EPOCH TRIGGER PERF CHECK FAILED"; exit 1; }
echo "acl detection drill (round 8, S4): a disabled or dropped event trigger must fail the manifest check and the preflight"
"$here/acl_detect_check.sh" || { echo "ACL DETECTION DRILL FAILED"; exit 1; }
if python3 -c "import psycopg2" 2>/dev/null; then   # isolated-per-variant leak matrix + paged == single property check (round 4); each case is its own rolled-back transaction
  echo "isolated leak matrix (quick) and paged == single property check"
  REPLICA_URL="$REPLICA_URL" python3 "$here/isolated_leak_check.py" quick || { echo "ISOLATED LEAK MATRIX FAILED"; exit 1; }
  REPLICA_URL="$REPLICA_URL" python3 "$here/prop_paged_check.py" 1 || { echo "PAGED != SINGLE PROPERTY CHECK FAILED"; exit 1; }
  echo "backup consistency race matrix (item A/B): real hq_backup.run() with committed changes between pages"
  REPLICA_URL="$REPLICA_URL" python3 "$here/backup_race_check.py" || { echo "BACKUP RACE CHECK FAILED"; exit 1; }
elif [ -n "${REQUIRE_INTEGRATION:-}" ]; then echo "psycopg2 missing but REQUIRE_INTEGRATION is set"; exit 1; fi
echo "consent-integrity rollback drill: ops/rollback_consent_integrity.sql removes the evidence/suppression/gate objects, restores the previous functions, and the migrations re-apply"
psql "$REPLICA_URL" -q -v ON_ERROR_STOP=1 -f "$root/ops/rollback_consent_integrity.sql" >/dev/null 2>"${TMPDIR:-/tmp}/replica.err" || { cat "${TMPDIR:-/tmp}/replica.err"; echo "CONSENT ROLLBACK FAILED to run"; exit 1; }
psql "$REPLICA_URL" -q -v ON_ERROR_STOP=1 -f "$root/ops/rollback_consent_integrity.sql" >/dev/null 2>"${TMPDIR:-/tmp}/replica.err" || { cat "${TMPDIR:-/tmp}/replica.err"; echo "CONSENT ROLLBACK is not idempotent"; exit 1; }
left="$(psql "$REPLICA_URL" -At -c "select count(*) from pg_proc where pronamespace='public'::regnamespace and proname in ('ffm_hmac_sha256','normalize_phone','ffm_set_key','ffm_ingest_capture','ffm_register_capture_owner','ffm_outreach_gate_open','ffm_verify_suppression','backup_suppression_export','ffm_is_phone_suppressed','ffm_suppression_mac','ffm_close_outreach_gate','ffm_lp','ffm_cc_len','ffm_key_problem','ffm_sup_message','outreach_send_allowed','outreach_recipient_problem')")"
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
echo "leak-redaction rollback drill: ops/rollback_leak_redaction.sql must restore the live (Nov 15) definitions of the writers and the repo-head backup_snapshot exactly"
# round 8 (integration rehearsal S2): the leak rollback must restore ONLY its own functions. is_suppressed / outbox_dnc_guard live in the same older migration files and are replaced by another PR
# (consent integrity); here they are replaced by marked copies, and the marker must still be there after the rollback (it used to re-run those files wholesale and revert them).
psql "$REPLICA_URL" -q -v ON_ERROR_STOP=1 -c "do \$\$ declare r record; begin for r in select p.oid from pg_proc p where p.pronamespace = 'public'::regnamespace and p.proname in ('is_suppressed', 'outbox_dnc_guard', 'normalize_addr', 'leads_suppression_guard') loop execute regexp_replace(pg_get_functiondef(r.oid), '\\\$function\\\$', '\$function\$ /* zz replaced by another migration */ '); end loop; end \$\$;" >/dev/null 2>"${TMPDIR:-/tmp}/replica.err" || { cat "${TMPDIR:-/tmp}/replica.err"; echo "LEAK ROLLBACK DRILL: could not mark the foreign functions"; exit 1; }
marked="$(psql "$REPLICA_URL" -At -c "select count(*) from pg_proc p where p.pronamespace = 'public'::regnamespace and p.prosrc like '%zz replaced by another migration%'")"
[ "$marked" -ge 2 ] || { echo "LEAK ROLLBACK DRILL: premise failed, only $marked foreign functions marked"; exit 1; }
(cd "$root" && psql "$REPLICA_URL" -q -v ON_ERROR_STOP=1 -f ops/rollback_leak_redaction.sql >/dev/null 2>&1) || { echo "LEAK ROLLBACK FAILED to run"; exit 1; }
still="$(psql "$REPLICA_URL" -At -c "select count(*) from pg_proc p where p.pronamespace = 'public'::regnamespace and p.prosrc like '%zz replaced by another migration%'")"
[ "$still" = "$marked" ] || { echo "LEAK ROLLBACK DRILL FAILED: the rollback re-created functions it does not own (expected $marked marked functions to survive, actual $still)"; exit 1; }
(cd "$root" && psql "$REPLICA_URL" -q -v ON_ERROR_STOP=1 -f ops/rollback_leak_redaction.sql >/dev/null 2>&1) || { echo "LEAK ROLLBACK is not idempotent"; exit 1; }
got="$(psql "$REPLICA_URL" -At -c "select p.oid::regprocedure::text||' '||md5(pg_get_functiondef(p.oid)) from pg_proc p where p.pronamespace='public'::regnamespace and p.prokind='f' and p.proname in ('mark_do_not_contact','record_lead_reply','setter_record_payout','set_deal_stage','confirm_deal_won','backup_snapshot') order by 1")"
want="$(grep -E '^[a-z_]+\(' "$root/ops/live_function_md5_20261115.txt" | sort)"
[ "$got" = "$want" ] || { echo "LEAK ROLLBACK DRILL FAILED"; diff <(echo "$got") <(echo "$want"); exit 1; }
left="$(psql "$REPLICA_URL" -At -c "select count(*) from pg_proc where pronamespace='public'::regnamespace and proname in ('backup_unescape_text','backup_normalise','backup_redaction_context','backup_redact_patterns','backup_probe_encoded','backup_redact_text','backup_redact_text_full','backup_redact_json','backup_redact_json_k','backup_redaction_spec','backup_redact_row','backup_redaction_status','agent_runs_scrub','backup_effective_spec','backup_deny_scan','backup_snapshot_page','backup_table_digest','backup_snapshot_cost','backup_table_expr','backup_redaction_meta','backup_topic_fast','backup_ctx_hot')")"
[ "$left" = "0" ] || { echo "LEAK ROLLBACK DRILL FAILED: $left redaction functions remain"; exit 1; }
kept="$(psql "$REPLICA_URL" -At -c "select (select count(*) from pg_tables where schemaname='public' and tablename in ('ffm_redaction_denylist','ffm_redaction_keys'))||'/'||(select count(*) from pg_trigger where tgname='redaction_capture' and not tgisinternal)||'/'||(select count(*) from pg_proc where proname in ('redaction_capture','redaction_capture_trg','backup_fold_text','backup_stopwords'))")"
case "$kept" in 2/0/*|*/0/*|2/*/[0-3]) echo "LEAK ROLLBACK DRILL FAILED: the deny-list / capture chain must stay in place (got $kept)"; exit 1;; esac
psql "$REPLICA_URL" -q -At -c "insert into public.leads (venture_id, name, status) select id, 'Rollback Window Fixture', 'new' from public.ventures limit 1; delete from public.leads where name = 'Rollback Window Fixture'" >/dev/null 2>&1 || { echo "LEAK ROLLBACK DRILL FAILED: writing to leads fails while the rollback is in force"; exit 1; }
for f in $(grep -v '^#' "$root/migrations/APPLY_ORDER.txt"); do
  psql "$REPLICA_URL" -q -v ON_ERROR_STOP=1 -f "$root/migrations/$f" >/dev/null 2>"${TMPDIR:-/tmp}/replica.err" || { cat "${TMPDIR:-/tmp}/replica.err"; echo "FAILED re-applying after the leak rollback: $f"; exit 1; }
done
echo "leak rollback drill OK (live definitions restored exactly, then the migrations re-apply cleanly)"
echo "rollback drill: ops/rollback_insurance_classifier.sql restores the strict guards and removes the classifier objects (twice = idempotent), then everything re-applies"
psql "$REPLICA_URL" -q -v ON_ERROR_STOP=1 -f "$root/ops/rollback_insurance_classifier.sql" >/dev/null 2>&1 || { echo "INSURANCE ROLLBACK FAILED to run"; exit 1; }
psql "$REPLICA_URL" -q -v ON_ERROR_STOP=1 -f "$root/ops/rollback_insurance_classifier.sql" >/dev/null 2>&1 || { echo "INSURANCE ROLLBACK is not idempotent"; exit 1; }
ic="$(psql "$REPLICA_URL" -At -c "select (select count(*) from pg_proc where pronamespace='public'::regnamespace and proname in ('ws_classify_text','ws_classify_core','ws_capitalised_name','ws_insurance_context','ws_text_insurance_word','ws_residual_check','ws_vocab_denied','ws_condition_hit','ws_fold_text','ws_leet_text','ws_health_extra_hit','ws_personal_context_hit','ws_identifier_hit','ws_add_approved_term','ws_remove_approved_term','ws_add_vocab_word','ws_remove_vocab_word','ws_terms_immutable','ws_place_catalog_immutable','ws_add_fixed_phrase','ws_remove_fixed_phrase','ws_onboarding_value_check','ws_structural_value','ws_health_word_hit','ws_name_word_hit','ws_stem_match','ws_number_words','ws_financial_hit','ws_feature_context_ok','ws_vertical_insurance','ws_person_name_check','ws_person_column_check')) || '/' || coalesce(to_regclass('public.ws_approved_terms')::text, 'none') || coalesce(to_regclass('public.ws_marketing_vocab')::text, '') || coalesce(to_regclass('public.ws_place_catalog')::text, '') || coalesce(to_regclass('public.ws_fixed_phrases')::text, '') || '/' || (position('ws_classify' in pg_get_functiondef('public.ws_guard()'::regprocedure)) + position('ws_classify' in pg_get_functiondef('public.ffm_guard()'::regprocedure)))")"
[ "$ic" = "0/none/0" ] || { echo "INSURANCE ROLLBACK DRILL FAILED: $ic"; exit 1; }
guards_after="$(psql "$REPLICA_URL" -At -c "select md5(pg_get_functiondef('public.ws_guard()'::regprocedure)) || ' ' || md5(pg_get_functiondef('public.ffm_guard()'::regprocedure))")"
[ -n "$guards_before" ] && [ "$guards_before" = "$guards_after" ] || { echo "INSURANCE ROLLBACK DRILL FAILED: guards not restored exactly ($guards_before vs $guards_after)"; exit 1; }
echo "insurance rollback restored ws_guard() and ffm_guard() byte-identically"
psql "$REPLICA_URL" -q -v ON_ERROR_STOP=1 -c "do \$\$ declare w uuid; begin insert into public.client_workspaces (slug, name, vertical) values ('ic-drill', 'Drill', 'insurance') returning id into w; begin insert into public.ws_campaigns (workspace_id, name) values (w, 'Critical illness insurance'); raise exception 'DRILL: old strict guard let health wording through'; exception when sqlstate 'P0001' then if sqlerrm like 'DRILL%' then raise; end if; end; delete from public.client_workspaces where id = w; end \$\$;" >/dev/null 2>"${TMPDIR:-/tmp}/replica.err" || { cat "${TMPDIR:-/tmp}/replica.err"; echo "INSURANCE ROLLBACK DRILL FAILED: strict guard not restored"; exit 1; }
for f in $(grep -v '^#' "$root/migrations/APPLY_ORDER.txt"); do
  psql "$REPLICA_URL" -q -v ON_ERROR_STOP=1 -f "$root/migrations/$f" >/dev/null 2>"${TMPDIR:-/tmp}/replica.err" || { cat "${TMPDIR:-/tmp}/replica.err"; echo "FAILED re-applying after insurance rollback: $f"; exit 1; }
done
echo "insurance rollback drill OK (and the migrations re-apply cleanly afterwards)"
echo "jarvis hands rollback drill: ops/rollback_jarvis_hands.sql removes the hand objects (twice = idempotent), restores the export policy, then everything re-applies"
(cd "$root" && psql "$REPLICA_URL" -q -v ON_ERROR_STOP=1 -f ops/rollback_shared_services.sql >/dev/null 2>"${TMPDIR:-/tmp}/replica.err") || { cat "${TMPDIR:-/tmp}/replica.err"; echo "SHARED SERVICES ROLLBACK (before the security hardening rollback) FAILED"; exit 1; }   # M5 sits on M4
(cd "$root" && psql "$REPLICA_URL" -q -v ON_ERROR_STOP=1 -f ops/rollback_security_hardening.sql >/dev/null 2>"${TMPDIR:-/tmp}/replica.err") || { cat "${TMPDIR:-/tmp}/replica.err"; echo "SECURITY HARDENING ROLLBACK (before the approvals kernel rollback) FAILED"; exit 1; }   # security hardening uses the office money owner check
(cd "$root" && psql "$REPLICA_URL" -q -v ON_ERROR_STOP=1 -f ops/rollback_approvals_kernel.sql >/dev/null 2>"${TMPDIR:-/tmp}/replica.err") || { cat "${TMPDIR:-/tmp}/replica.err"; echo "APPROVALS KERNEL ROLLBACK (before the office money rollback) FAILED"; exit 1; }   # the approvals kernel reads office money
(cd "$root" && psql "$REPLICA_URL" -q -v ON_ERROR_STOP=1 -f ops/rollback_office_money.sql >/dev/null 2>"${TMPDIR:-/tmp}/replica.err") || { cat "${TMPDIR:-/tmp}/replica.err"; echo "OFFICE MONEY ROLLBACK (before the hands rollback) FAILED"; exit 1; }   # office money depends on org access
(cd "$root" && psql "$REPLICA_URL" -q -v ON_ERROR_STOP=1 -f ops/rollback_org_access.sql >/dev/null 2>"${TMPDIR:-/tmp}/replica.err") || { cat "${TMPDIR:-/tmp}/replica.err"; echo "ORG ACCESS ROLLBACK (before the hands rollback) FAILED"; exit 1; }   # org access re-creates the hands backup classification
(cd "$root" && psql "$REPLICA_URL" -q -v ON_ERROR_STOP=1 -f ops/rollback_jarvis_hands.sql >/dev/null 2>"${TMPDIR:-/tmp}/replica.err") || { cat "${TMPDIR:-/tmp}/replica.err"; echo "JARVIS HANDS ROLLBACK FAILED to run"; exit 1; }
(cd "$root" && psql "$REPLICA_URL" -q -v ON_ERROR_STOP=1 -f ops/rollback_jarvis_hands.sql >/dev/null 2>"${TMPDIR:-/tmp}/replica.err") || { cat "${TMPDIR:-/tmp}/replica.err"; echo "JARVIS HANDS ROLLBACK is not idempotent"; exit 1; }
jh="$(psql "$REPLICA_URL" -At -c "select (select count(*) from pg_proc where pronamespace='public'::regnamespace and proname like 'hands\_%')||'/'||(select count(*) from pg_class where relnamespace='public'::regnamespace and relname like 'hand\_%' and relkind='r')||'/'||(select count(*) from public.executor_registry where slug like 'hands-%')||'/'||(select count(*) from public.backup_redaction_spec() where table_name like 'hand\_%')||'/'||(select public.backup_export_policy()->>'unclassified')")"
[ "$jh" = "0/0/0/0/[]" ] || { echo "JARVIS HANDS ROLLBACK DRILL FAILED: $jh"; exit 1; }
for f in $(grep -v '^#' "$root/migrations/APPLY_ORDER.txt"); do
  psql "$REPLICA_URL" -q -v ON_ERROR_STOP=1 -f "$root/migrations/$f" >/dev/null 2>"${TMPDIR:-/tmp}/replica.err" || { cat "${TMPDIR:-/tmp}/replica.err"; echo "FAILED re-applying after the jarvis hands rollback: $f"; exit 1; }
done
psql "$REPLICA_URL" -q -At -v ON_ERROR_STOP=1 -f "$root/sqltests/jarvis_hands_check.sql" >/dev/null 2>"${TMPDIR:-/tmp}/replica.err" || { cat "${TMPDIR:-/tmp}/replica.err"; echo "jarvis_hands_check failed after the rollback + re-apply"; exit 1; }
echo "jarvis hands rollback drill OK"
echo "jarvis core rollback drill: ops/rollback_jarvis_core.sql removes the core objects (twice = idempotent), keeps the export policy classified, then everything re-applies"
(cd "$root" && psql "$REPLICA_URL" -q -v ON_ERROR_STOP=1 -f ops/rollback_shared_services.sql >/dev/null 2>"${TMPDIR:-/tmp}/replica.err") || { cat "${TMPDIR:-/tmp}/replica.err"; echo "SHARED SERVICES ROLLBACK (before the security hardening rollback) FAILED"; exit 1; }   # M5 sits on M4
(cd "$root" && psql "$REPLICA_URL" -q -v ON_ERROR_STOP=1 -f ops/rollback_security_hardening.sql >/dev/null 2>"${TMPDIR:-/tmp}/replica.err") || { cat "${TMPDIR:-/tmp}/replica.err"; echo "SECURITY HARDENING ROLLBACK (before the approvals kernel rollback) FAILED"; exit 1; }   # security hardening uses the office money owner check
(cd "$root" && psql "$REPLICA_URL" -q -v ON_ERROR_STOP=1 -f ops/rollback_approvals_kernel.sql >/dev/null 2>"${TMPDIR:-/tmp}/replica.err") || { cat "${TMPDIR:-/tmp}/replica.err"; echo "APPROVALS KERNEL ROLLBACK (before the office money rollback) FAILED"; exit 1; }   # the approvals kernel reads office money
(cd "$root" && psql "$REPLICA_URL" -q -v ON_ERROR_STOP=1 -f ops/rollback_office_money.sql >/dev/null 2>"${TMPDIR:-/tmp}/replica.err") || { cat "${TMPDIR:-/tmp}/replica.err"; echo "OFFICE MONEY ROLLBACK (before the core rollback) FAILED"; exit 1; }   # office money depends on org access
(cd "$root" && psql "$REPLICA_URL" -q -v ON_ERROR_STOP=1 -f ops/rollback_org_access.sql >/dev/null 2>"${TMPDIR:-/tmp}/replica.err") || { cat "${TMPDIR:-/tmp}/replica.err"; echo "ORG ACCESS ROLLBACK (before the core rollback) FAILED"; exit 1; }   # org access depends on hands
(cd "$root" && psql "$REPLICA_URL" -q -v ON_ERROR_STOP=1 -f ops/rollback_jarvis_hands.sql >/dev/null 2>"${TMPDIR:-/tmp}/replica.err") || { cat "${TMPDIR:-/tmp}/replica.err"; echo "JARVIS HANDS ROLLBACK (before the core rollback) FAILED"; exit 1; }   # hands depend on the core
(cd "$root" && psql "$REPLICA_URL" -q -v ON_ERROR_STOP=1 -f ops/rollback_jarvis_core.sql >/dev/null 2>"${TMPDIR:-/tmp}/replica.err") || { cat "${TMPDIR:-/tmp}/replica.err"; echo "JARVIS CORE ROLLBACK FAILED to run"; exit 1; }
(cd "$root" && psql "$REPLICA_URL" -q -v ON_ERROR_STOP=1 -f ops/rollback_jarvis_core.sql >/dev/null 2>"${TMPDIR:-/tmp}/replica.err") || { cat "${TMPDIR:-/tmp}/replica.err"; echo "JARVIS CORE ROLLBACK is not idempotent"; exit 1; }
jc="$(psql "$REPLICA_URL" -At -c "select (select count(*) from pg_proc where pronamespace='public'::regnamespace and proname like 'jarvis\_%')||'/'||(select count(*) from pg_class where relnamespace='public'::regnamespace and relname like 'jarvis\_%' and relkind='r')||'/'||(select public.backup_export_policy()->>'unclassified')")"
[ "$jc" = "0/0/[]" ] || { echo "JARVIS CORE ROLLBACK DRILL FAILED: $jc"; exit 1; }
for f in $(grep -v '^#' "$root/migrations/APPLY_ORDER.txt"); do
  psql "$REPLICA_URL" -q -v ON_ERROR_STOP=1 -f "$root/migrations/$f" >/dev/null 2>"${TMPDIR:-/tmp}/replica.err" || { cat "${TMPDIR:-/tmp}/replica.err"; echo "FAILED re-applying after the jarvis core rollback: $f"; exit 1; }
done
psql "$REPLICA_URL" -q -At -v ON_ERROR_STOP=1 -f "$root/sqltests/jarvis_core_check.sql" >/dev/null 2>"${TMPDIR:-/tmp}/replica.err" || { cat "${TMPDIR:-/tmp}/replica.err"; echo "jarvis_core_check failed after the rollback + re-apply"; exit 1; }
echo "jarvis core rollback drill OK"
echo "ffm engine rollback drill: ops/rollback_ffm_engine.sql removes the engine objects (twice = idempotent), then everything re-applies"
for i in 1 2; do
  (cd "$root" && psql "$REPLICA_URL" -q -v ON_ERROR_STOP=1 -f ops/rollback_ffm_engine.sql >/dev/null 2>"${TMPDIR:-/tmp}/replica.err") || { cat "${TMPDIR:-/tmp}/replica.err"; echo "FFM ENGINE ROLLBACK FAILED (run $i)"; exit 1; }
done
fe="$(psql "$REPLICA_URL" -At -c "select (select count(*) from pg_proc where pronamespace='public'::regnamespace and proname like 'ffm\_engine\_%')||'/'||(select count(*) from pg_class where relnamespace='public'::regnamespace and relname like 'ffm\_engine\_%' and relkind='r')||'/'||(select public.backup_export_policy()->>'unclassified')")"
[ "$fe" = "0/0/[]" ] || { echo "FFM ENGINE ROLLBACK DRILL FAILED: $fe"; exit 1; }
for f in $(grep -v '^#' "$root/migrations/APPLY_ORDER.txt"); do
  psql "$REPLICA_URL" -q -v ON_ERROR_STOP=1 -f "$root/migrations/$f" >/dev/null 2>"${TMPDIR:-/tmp}/replica.err" || { cat "${TMPDIR:-/tmp}/replica.err"; echo "FAILED re-applying after the ffm engine rollback: $f"; exit 1; }
done
psql "$REPLICA_URL" -q -At -v ON_ERROR_STOP=1 -f "$root/sqltests/ffm_engine_check.sql" >/dev/null 2>"${TMPDIR:-/tmp}/replica.err" || { cat "${TMPDIR:-/tmp}/replica.err"; echo "ffm_engine_check failed after the rollback + re-apply"; exit 1; }
echo "ffm engine rollback drill OK"
if python3 -c "import psycopg2" 2>/dev/null; then   # FF Marketing execution end to end: the REAL engine + REAL SQL, platform APIs mocked, each test rolled back
  echo "ffm execution: approve -> launch -> post -> lead -> follow-up -> optimize -> report, hard stop, kill switch, dry run, opt-out, guard (test_hq_ffm_run.DbTests)"
  (cd "$root" && FFM_RUN_DB_TESTS=1 REPLICA_URL="$REPLICA_URL" python3 -m unittest -q test_hq_ffm_run.DbTests) 2>&1 | tail -3
  (cd "$root" && FFM_RUN_DB_TESTS=1 REPLICA_URL="$REPLICA_URL" python3 -m unittest -q test_hq_ffm_run.DbTests >/dev/null 2>&1) || { echo "FFM EXECUTION DB TESTS FAILED"; exit 1; }
  n_skip="$(cd "$root" && FFM_RUN_DB_TESTS=1 REPLICA_URL="$REPLICA_URL" python3 -m unittest -v test_hq_ffm_run.DbTests 2>&1 | grep -c 'skipped' || true)"
  [ "$n_skip" = "0" ] || { echo "FFM EXECUTION DB TESTS were skipped"; exit 1; }
elif [ -n "${REQUIRE_INTEGRATION:-}" ]; then echo "psycopg2 missing but REQUIRE_INTEGRATION is set"; exit 1; fi
echo "ffm execution rollback drill: ops/rollback_ffm_run.sql removes the execution objects (twice = idempotent), then everything re-applies"
for i in 1 2; do
  (cd "$root" && psql "$REPLICA_URL" -q -v ON_ERROR_STOP=1 -f ops/rollback_ffm_run.sql >/dev/null 2>"${TMPDIR:-/tmp}/replica.err") || { cat "${TMPDIR:-/tmp}/replica.err"; echo "FFM RUN ROLLBACK FAILED (run $i)"; exit 1; }
done
fr="$(psql "$REPLICA_URL" -At -c "select (select count(*) from pg_proc where pronamespace='public'::regnamespace and proname like 'ffm\_run\_%')||'/'||(select count(*) from pg_class where relnamespace='public'::regnamespace and relname like 'ffm\_run\_%' and relkind='r')||'/'||(select count(*) from public.hand_connectors where slug='meta-ads')||'/'||(select public.backup_export_policy()->>'unclassified')")"
[ "$fr" = "0/0/0/[]" ] || { echo "FFM RUN ROLLBACK DRILL FAILED: $fr"; exit 1; }
for f in $(grep -v '^#' "$root/migrations/APPLY_ORDER.txt"); do
  psql "$REPLICA_URL" -q -v ON_ERROR_STOP=1 -f "$root/migrations/$f" >/dev/null 2>"${TMPDIR:-/tmp}/replica.err" || { cat "${TMPDIR:-/tmp}/replica.err"; echo "FAILED re-applying after the ffm run rollback: $f"; exit 1; }
done
psql "$REPLICA_URL" -q -At -v ON_ERROR_STOP=1 -f "$root/sqltests/ffm_run_check.sql" >/dev/null 2>"${TMPDIR:-/tmp}/replica.err" || { cat "${TMPDIR:-/tmp}/replica.err"; echo "ffm_run_check failed after the rollback + re-apply"; exit 1; }
echo "ffm execution rollback drill OK"
if python3 -c "import psycopg2" 2>/dev/null; then   # the REAL hq._request token choice against the REAL RLS (pg_adapter plays PostgREST: role + claims), rolled back
  echo "scoped identities through hq.py: offices isolated, fallback to the service path without tokens, stamped writes, refused approvals (test_hq_scoped.DbTests)"
  (cd "$root" && FZ_DB_TESTS=1 REPLICA_URL="$REPLICA_URL" python3 -m unittest -q test_hq_scoped.DbTests >/dev/null 2>&1) || { (cd "$root" && FZ_DB_TESTS=1 REPLICA_URL="$REPLICA_URL" python3 -m unittest -q test_hq_scoped.DbTests 2>&1 | tail -20); echo "SCOPED IDENTITY DB TESTS FAILED"; exit 1; }
  n_skip="$(cd "$root" && FZ_DB_TESTS=1 REPLICA_URL="$REPLICA_URL" python3 -m unittest -v test_hq_scoped.DbTests 2>&1 | grep -c 'skipped' || true)"
  [ "$n_skip" = "0" ] || { echo "SCOPED IDENTITY DB TESTS were skipped"; exit 1; }
elif [ -n "${REQUIRE_INTEGRATION:-}" ]; then echo "psycopg2 missing but REQUIRE_INTEGRATION is set"; exit 1; fi
echo "office money rollback drill: ops/rollback_office_money.sql keeps the allocation record in audit_log, removes the M2 views / functions / tables / registry rows and the stamp job (twice = idempotent), restores the org-access backup classification exactly, leaves M1 and every money control in place, then everything re-applies"
mc0="$(psql "$REPLICA_URL" -At -c "select md5(string_agg(p.oid::regprocedure::text || md5(pg_get_functiondef(p.oid)) || coalesce(p.proacl::text, ''), ',' order by p.oid::regprocedure::text)) from pg_proc p where p.pronamespace='public'::regnamespace and p.prokind='f' and p.proname in ('authorize_action','reserve_spend','settle_spend','release_spend','capital_snapshot','reserve_llm_budget','settle_llm_call','app_set_kill','fz_authorize_action','fz_policy_preview')")|$(psql "$REPLICA_URL" -At -c "select count(*) from pg_trigger t where not t.tgisinternal and t.tgrelid in ('public.ledger'::regclass,'public.llm_calls'::regclass,'public.spend_reservations'::regclass,'public.action_log'::regclass,'public.approval_requests'::regclass,'public.capital_policy'::regclass,'public.system_state'::regclass,'public.action_policy'::regclass)")"
echo "shared services rollback drill: ops/rollback_shared_services.sql archives the registry and every stamped office_id (no stamp lost), removes the M5 columns / triggers / view / functions (twice = idempotent), restores the security-hardening classification exactly, then everything re-applies and the owner's decisions come back"
psql "$REPLICA_URL" -q -c "select public.fz_owner_set_service('content', true)" >/dev/null 2>"${TMPDIR:-/tmp}/replica.err" || { cat "${TMPDIR:-/tmp}/replica.err"; echo "SHARED SERVICES DRILL: owner decision failed"; exit 1; }
psql "$REPLICA_URL" -q -c "insert into public.venture_assets (kind, name) values ('asset', 'drill asset')" >/dev/null 2>"${TMPDIR:-/tmp}/replica.err" || { cat "${TMPDIR:-/tmp}/replica.err"; echo "SHARED SERVICES DRILL: stamped insert failed"; exit 1; }
ss0="$(psql "$REPLICA_URL" -At -c "select (select count(*) from public.fz_services)||'/'||((select count(*) from public.leads where office_id is not null)+(select count(*) from public.lead_replies where office_id is not null)+(select count(*) from public.deals where office_id is not null)+(select count(*) from public.outbox where office_id is not null)+(select count(*) from public.owner_messages where office_id is not null)+(select count(*) from public.jarvis_jobs where office_id is not null)+(select count(*) from public.hand_actions where office_id is not null)+(select count(*) from public.venture_assets where office_id is not null))")"
sx0="$(psql "$REPLICA_URL" -At -c "select count(*) from public.audit_log where action='shared_services_export'")"
mcs0="$(psql "$REPLICA_URL" -At -c "select md5(string_agg(p.oid::regprocedure::text || md5(pg_get_functiondef(p.oid)) || coalesce(p.proacl::text, ''), ',' order by p.oid::regprocedure::text)) from pg_proc p where p.pronamespace='public'::regnamespace and p.proname in ('authorize_action','reserve_spend','settle_spend','capital_snapshot','app_set_kill','enforce_outbox_rules','outbox_dnc_guard','is_suppressed')")"
for i in 1 2; do
  (cd "$root" && psql "$REPLICA_URL" -q -v ON_ERROR_STOP=1 -f ops/rollback_shared_services.sql >/dev/null 2>"${TMPDIR:-/tmp}/replica.err") || { cat "${TMPDIR:-/tmp}/replica.err"; echo "SHARED SERVICES ROLLBACK FAILED (run $i)"; exit 1; }
done
ss1="$(psql "$REPLICA_URL" -At -c "select (select count(*) from fz_archive.fz_services)||'/'||(select count(*) from fz_archive.fz_service_attribution)")"
[ "$ss0" = "$ss1" ] || { echo "SHARED SERVICES ROLLBACK DRILL FAILED: stamps or registry rows lost ($ss0 live, $ss1 archived)"; exit 1; }
sv="$(psql "$REPLICA_URL" -At -c "select (select count(*) from pg_proc where pronamespace='public'::regnamespace and proname in ('fz_services_report','fz_owner_set_service','fz_service_stamp_office','fz_services_guard'))||'/'||(select count(*) from pg_attribute a join pg_class c on c.oid=a.attrelid where c.relnamespace='public'::regnamespace and a.attname='office_id' and not a.attisdropped and c.relname in ('leads','lead_replies','deals','outbox','owner_messages','jarvis_jobs','hand_actions','venture_assets'))||'/'||(select count(*) from pg_trigger where tgname='zz_fz_service_office')||'/'||coalesce(to_regclass('public.fz_service_rows')::text,'-')||'/'||((select count(*) from public.audit_log where action='shared_services_export') - $sx0)||'/'||(public.backup_export_policy()->'unclassified')::text")"
[ "$sv" = "0/0/0/-/1/[]" ] || { echo "SHARED SERVICES ROLLBACK DRILL FAILED: $sv (want 0/0/0/-/1/[]: no M5 object, ONE new export record (the second run is a no-op), nothing unclassified)"; exit 1; }
[ "$(psql "$REPLICA_URL" -At -c "select count(*) from pg_namespace n where n.nspname like 'fz\_archive%' and (has_schema_privilege('anon', n.oid, 'usage') or has_schema_privilege('authenticated', n.oid, 'usage') or has_schema_privilege('service_role', n.oid, 'usage'))")" = "0" ] || { echo "SHARED SERVICES ROLLBACK DRILL FAILED: an API role can reach the archive"; exit 1; }
mcs1="$(psql "$REPLICA_URL" -At -c "select md5(string_agg(p.oid::regprocedure::text || md5(pg_get_functiondef(p.oid)) || coalesce(p.proacl::text, ''), ',' order by p.oid::regprocedure::text)) from pg_proc p where p.pronamespace='public'::regnamespace and p.proname in ('authorize_action','reserve_spend','settle_spend','capital_snapshot','app_set_kill','enforce_outbox_rules','outbox_dnc_guard','is_suppressed')")"
[ "$mcs0" = "$mcs1" ] || { echo "SHARED SERVICES ROLLBACK DRILL FAILED: the money / consent controls changed"; exit 1; }
c1="$(psql "$REPLICA_URL" -At -c "select md5(pg_get_functiondef('public.backup_classification()'::regprocedure))")"
for f in 20261130_security_hardening_v1.sql 20261121_postlock_backup_identity_v1.sql 20261122_postlock_backup_identity_v2.sql; do
  psql "$REPLICA_URL" -q -v ON_ERROR_STOP=1 -f "$root/migrations/$f" >/dev/null 2>"${TMPDIR:-/tmp}/replica.err" || { cat "${TMPDIR:-/tmp}/replica.err"; echo "SHARED SERVICES ROLLBACK DRILL: could not re-apply $f"; exit 1; }
done
c2="$(psql "$REPLICA_URL" -At -c "select md5(pg_get_functiondef('public.backup_classification()'::regprocedure))")"
[ "$c1" = "$c2" ] || { echo "SHARED SERVICES ROLLBACK DRILL FAILED: backup_classification() is not the security-hardening text"; exit 1; }
for f in $(grep -v '^#' "$root/migrations/APPLY_ORDER.txt"); do
  psql "$REPLICA_URL" -q -v ON_ERROR_STOP=1 -f "$root/migrations/$f" >/dev/null 2>"${TMPDIR:-/tmp}/replica.err" || { cat "${TMPDIR:-/tmp}/replica.err"; echo "FAILED re-applying after the shared services rollback: $f"; exit 1; }
done
[ "$(psql "$REPLICA_URL" -At -c "select scoped_reads from public.fz_services where service = 'content'")" = "t" ] || { echo "SHARED SERVICES ROLLBACK DRILL FAILED: the owner decision was lost"; exit 1; }
psql "$REPLICA_URL" -q -c "select public.fz_owner_set_service('content', false)" >/dev/null
psql "$REPLICA_URL" -q -At -v ON_ERROR_STOP=1 -f "$root/sqltests/shared_services_check.sql" >/dev/null 2>"${TMPDIR:-/tmp}/replica.err" || { cat "${TMPDIR:-/tmp}/replica.err"; echo "shared_services_check failed after the rollback + re-apply"; exit 1; }
python3 "$root/scripts/expected_grants.py" --url "$REPLICA_URL" --check || { echo "EXPECTED GRANTS CHECK FAILED after the shared services re-apply"; exit 1; }
echo "shared services rollback drill OK (archived, no stamp lost, money / consent controls untouched, security-hardening classification exact, owner decision kept, then the checks pass again)"
echo "token rotation drill (ops/TOKEN_ROTATION_RUNBOOK.md): rotate, void, revoke on leak, re-activate, expiry warning"
psql "$REPLICA_URL" -q -At -v ON_ERROR_STOP=1 -f "$root/scripts/replica/token_drill.sql" 2>"${TMPDIR:-/tmp}/replica.err" >/dev/null || { cat "${TMPDIR:-/tmp}/replica.err"; echo "TOKEN ROTATION DRILL FAILED"; exit 1; }
grep -q "token rotation drill OK" "${TMPDIR:-/tmp}/replica.err" || { cat "${TMPDIR:-/tmp}/replica.err"; echo "TOKEN ROTATION DRILL did not finish"; exit 1; }
echo "token rotation drill OK"
echo "security hardening rollback drill: ops/rollback_security_hardening.sql archives the chain / baseline / alerts / tokens (no row lost), removes the M4 functions and job (twice = idempotent), restores the office-money classification exactly, then everything re-applies"
psql "$REPLICA_URL" -q -c "select public.fz_security_watch()" >/dev/null 2>&1 || true
sr0="$(psql "$REPLICA_URL" -At -c "select (select count(*) from public.fz_audit_chain)||'/'||(select count(*) from public.fz_audit_pending)||'/'||(select count(*) from public.fz_audit_state)||'/'||(select count(*) from public.fz_security_baseline)||'/'||(select count(*) from public.fz_security_fingerprints)||'/'||(select count(*) from public.fz_security_alerts)||'/'||(select count(*) from public.fz_token_registry)")"
head0="$(psql "$REPLICA_URL" -At -c "select coalesce((select chain_hash from public.fz_audit_chain order by seq desc limit 1), 'none')")"
for i in 1 2; do
  (cd "$root" && psql "$REPLICA_URL" -q -v ON_ERROR_STOP=1 -f ops/rollback_shared_services.sql >/dev/null 2>"${TMPDIR:-/tmp}/replica.err") || { cat "${TMPDIR:-/tmp}/replica.err"; echo "SHARED SERVICES ROLLBACK (before the security hardening rollback) FAILED"; exit 1; }   # M5 sits on M4
  (cd "$root" && psql "$REPLICA_URL" -q -v ON_ERROR_STOP=1 -f ops/rollback_security_hardening.sql >/dev/null 2>"${TMPDIR:-/tmp}/replica.err") || { cat "${TMPDIR:-/tmp}/replica.err"; echo "SECURITY HARDENING ROLLBACK FAILED (run $i)"; exit 1; }
done
sr1="$(psql "$REPLICA_URL" -At -c "select (select count(*) from fz_archive.fz_audit_chain)||'/'||(select count(*) from fz_archive.fz_audit_pending)||'/'||(select count(*) from fz_archive.fz_audit_state)||'/'||(select count(*) from fz_archive.fz_security_baseline)||'/'||(select count(*) from fz_archive.fz_security_fingerprints)||'/'||(select count(*) from fz_archive.fz_security_alerts)||'/'||(select count(*) from fz_archive.fz_token_registry)")"
[ "$sr0" = "$sr1" ] || { echo "SECURITY HARDENING ROLLBACK DRILL FAILED: rows lost ($sr0 before, $sr1 archived)"; exit 1; }
sh="$(psql "$REPLICA_URL" -At -c "select (select count(*) from pg_proc where pronamespace='public'::regnamespace and proname in ('fz_audit_chain_extend','fz_audit_verify','fz_security_watch','fz_security_report','fz_privileged_items','fz_expected_grants','fz_security_alert','fz_owner_ack_security','fz_owner_register_token','fz_audit_row_hash','fz_audit_link'))||'/'||(select count(*) from cron.job where jobname='fz-security-watch')||'/'||(select count(*) from pg_class where relnamespace='public'::regnamespace and relname in ('fz_audit_chain','fz_audit_pending','fz_audit_state','fz_security_baseline','fz_security_fingerprints','fz_security_alerts','fz_token_registry'))||'/'||(select public.backup_export_policy()->>'unclassified')")"
[ "$sh" = "0/0/0/[]" ] || { echo "SECURITY HARDENING ROLLBACK DRILL FAILED: $sh"; exit 1; }
c1="$(psql "$REPLICA_URL" -At -c "select md5(pg_get_functiondef('public.backup_classification()'::regprocedure))")"
for f in 20261128_office_money_v1.sql 20261121_postlock_backup_identity_v1.sql 20261122_postlock_backup_identity_v2.sql; do
  psql "$REPLICA_URL" -q -v ON_ERROR_STOP=1 -f "$root/migrations/$f" >/dev/null 2>"${TMPDIR:-/tmp}/replica.err" || { cat "${TMPDIR:-/tmp}/replica.err"; echo "SECURITY HARDENING ROLLBACK DRILL: could not re-apply $f"; exit 1; }
done
c2="$(psql "$REPLICA_URL" -At -c "select md5(pg_get_functiondef('public.backup_classification()'::regprocedure))")"
[ "$c1" = "$c2" ] || { echo "SECURITY HARDENING ROLLBACK DRILL FAILED: backup_classification() is not the office-money text"; exit 1; }
for f in $(grep -v '^#' "$root/migrations/APPLY_ORDER.txt"); do
  psql "$REPLICA_URL" -q -v ON_ERROR_STOP=1 -f "$root/migrations/$f" >/dev/null 2>"${TMPDIR:-/tmp}/replica.err" || { cat "${TMPDIR:-/tmp}/replica.err"; echo "FAILED re-applying after the security hardening rollback: $f"; exit 1; }
done
[ "$(psql "$REPLICA_URL" -At -c "select coalesce((select chain_hash from public.fz_audit_chain order by seq desc limit 1), 'none')")" = "$head0" ] || { echo "SECURITY HARDENING ROLLBACK DRILL FAILED: the chain head was not seeded back from the archive"; exit 1; }
psql "$REPLICA_URL" -q -At -v ON_ERROR_STOP=1 -f "$root/sqltests/security_hardening_check.sql" >/dev/null 2>"${TMPDIR:-/tmp}/replica.err" || { cat "${TMPDIR:-/tmp}/replica.err"; echo "security_hardening_check failed after the rollback + re-apply"; exit 1; }
echo "security hardening rollback drill OK (archived, nothing lost, office-money classification exact, then the migrations re-apply and the checks pass again)"
(cd "$root" && psql "$REPLICA_URL" -q -v ON_ERROR_STOP=1 -f ops/rollback_shared_services.sql >/dev/null 2>"${TMPDIR:-/tmp}/replica.err") || { cat "${TMPDIR:-/tmp}/replica.err"; echo "SHARED SERVICES ROLLBACK (before the security hardening rollback) FAILED"; exit 1; }   # M5 sits on M4
(cd "$root" && psql "$REPLICA_URL" -q -v ON_ERROR_STOP=1 -f ops/rollback_security_hardening.sql >/dev/null 2>"${TMPDIR:-/tmp}/replica.err") || { cat "${TMPDIR:-/tmp}/replica.err"; echo "SECURITY HARDENING ROLLBACK (before the approvals kernel drill) FAILED"; exit 1; }   # security hardening uses the office money owner check
echo "approvals kernel rollback drill: ops/rollback_approvals_kernel.sql keeps a queue snapshot in audit_log, removes the M3 view / trigger / functions / job (twice = idempotent), leaves M2, M1 and every money control in place, then everything re-applies"
ak0="$(psql "$REPLICA_URL" -At -c "select count(*) from public.audit_log where action='approval_queue_export'")"
for i in 1 2; do
  (cd "$root" && psql "$REPLICA_URL" -q -v ON_ERROR_STOP=1 -f ops/rollback_approvals_kernel.sql >/dev/null 2>"${TMPDIR:-/tmp}/replica.err") || { cat "${TMPDIR:-/tmp}/replica.err"; echo "APPROVALS KERNEL ROLLBACK FAILED (run $i)"; exit 1; }
done
ak="$(psql "$REPLICA_URL" -At -c "select (select count(*) from pg_proc where pronamespace='public'::regnamespace and proname in ('fz_queue_expire','fz_queue_audit_proposal','fz_prepare_office_payment'))||'/'||(select count(*) from pg_class where relnamespace='public'::regnamespace and relname='fz_approval_queue')||'/'||(select count(*) from pg_trigger where tgname='fz_office_money_proposals_audit')||'/'||(select count(*) from cron.job where jobname='fz-queue-expire')||'/'||(select count(*) from pg_class where relnamespace='public'::regnamespace and relname='fz_office_money')||'/'||(select count(*) from public.audit_log where action='approval_queue_export')-$ak0")"
[ "$ak" = "0/0/0/0/1/1" ] || { echo "APPROVALS KERNEL ROLLBACK DRILL FAILED: $ak (want 0/0/0/0/1/1: no M3 object, M2 kept, the snapshot kept once)"; exit 1; }
for f in $(grep -v '^#' "$root/migrations/APPLY_ORDER.txt"); do
  psql "$REPLICA_URL" -q -v ON_ERROR_STOP=1 -f "$root/migrations/$f" >/dev/null 2>"${TMPDIR:-/tmp}/replica.err" || { cat "${TMPDIR:-/tmp}/replica.err"; echo "FAILED re-applying after the approvals kernel rollback: $f"; exit 1; }
done
psql "$REPLICA_URL" -q -At -v ON_ERROR_STOP=1 -f "$root/sqltests/approvals_kernel_check.sql" >/dev/null 2>"${TMPDIR:-/tmp}/replica.err" || { cat "${TMPDIR:-/tmp}/replica.err"; echo "approvals_kernel_check failed after the rollback + re-apply"; exit 1; }
echo "approvals kernel rollback drill OK (M3 removed, snapshot kept, M2 / M1 / money controls untouched, then the migrations re-apply and the checks pass again)"
(cd "$root" && psql "$REPLICA_URL" -q -v ON_ERROR_STOP=1 -f ops/rollback_shared_services.sql >/dev/null 2>"${TMPDIR:-/tmp}/replica.err") || { cat "${TMPDIR:-/tmp}/replica.err"; echo "SHARED SERVICES ROLLBACK (before the security hardening rollback) FAILED"; exit 1; }   # M5 sits on M4
(cd "$root" && psql "$REPLICA_URL" -q -v ON_ERROR_STOP=1 -f ops/rollback_security_hardening.sql >/dev/null 2>"${TMPDIR:-/tmp}/replica.err") || { cat "${TMPDIR:-/tmp}/replica.err"; echo "SECURITY HARDENING ROLLBACK (before the approvals kernel rollback) FAILED"; exit 1; }   # security hardening uses the office money owner check
(cd "$root" && psql "$REPLICA_URL" -q -v ON_ERROR_STOP=1 -f ops/rollback_approvals_kernel.sql >/dev/null 2>"${TMPDIR:-/tmp}/replica.err") || { cat "${TMPDIR:-/tmp}/replica.err"; echo "APPROVALS KERNEL ROLLBACK (before the office money drill) FAILED"; exit 1; }   # the approvals kernel reads office money
ex0="$(psql "$REPLICA_URL" -At -c "select count(*) from public.audit_log where action='office_money_export'")"
# review fix 3: the rollback archives (never drops) the money tables: every row must be in fz_archive afterwards, and a re-apply keeps the original cutover
rows0="$(psql "$REPLICA_URL" -At -c "select (select count(*) from public.fz_office_allocations)||'/'||(select count(*) from public.fz_office_money_proposals)||'/'||(select count(*) from public.fz_office_money_policy)||'/'||(select count(*) from public.fz_money_attribution)||'/'||(select count(*) from public.fz_money_config)")"
cut0="$(psql "$REPLICA_URL" -At -c "select cutover_at from public.fz_money_config where id = 1")"
for i in 1 2; do
  (cd "$root" && psql "$REPLICA_URL" -q -v ON_ERROR_STOP=1 -f ops/rollback_office_money.sql >/dev/null 2>"${TMPDIR:-/tmp}/replica.err") || { cat "${TMPDIR:-/tmp}/replica.err"; echo "OFFICE MONEY ROLLBACK FAILED (run $i)"; exit 1; }
done
om="$(psql "$REPLICA_URL" -At -c "select (select count(*) from pg_proc where pronamespace='public'::regnamespace and (proname like 'fz\_money%' or proname in ('fz_reserve_office_spend','fz_unallocated_cents','fz_office_available_cents','fz_propose_office_money','fz_owner_allocate','fz_owner_clawback','fz_owner_set_reinvest','fz_owner_decide_office_proposal','fz_owner_attribute_ledger')))||'/'||(select count(*) from pg_class where relnamespace='public'::regnamespace and relname in ('fz_money_config','fz_office_allocations','fz_office_money_policy','fz_office_money_proposals','fz_money_attribution','fz_office_money','fz_office_allocation_log'))||'/'||(select count(*) from public.fz_table_registry where relname in ('fz_money_config','fz_office_allocations','fz_office_money_policy','fz_office_money_proposals','fz_money_attribution'))||'/'||(select count(*) from cron.job where jobname='fz-money-stamp')||'/'||(select count(*) from public.fz_offices)||'/'||(select count(*) from public.audit_log where action='office_money_export')-$ex0||'/'||(select public.backup_export_policy()->>'unclassified')")"
[ "$om" = "0/0/0/0/9/1/[]" ] || { echo "OFFICE MONEY ROLLBACK DRILL FAILED: $om (want 0/0/0/0/9/1/[]: no M2 object, M1 offices kept, the record kept once (second run is a no-op), nothing unclassified)"; exit 1; }
rows1="$(psql "$REPLICA_URL" -At -c "select (select count(*) from fz_archive.fz_office_allocations)||'/'||(select count(*) from fz_archive.fz_office_money_proposals)||'/'||(select count(*) from fz_archive.fz_office_money_policy)||'/'||(select count(*) from fz_archive.fz_money_attribution)||'/'||(select count(*) from fz_archive.fz_money_config)")"
[ "$rows0" = "$rows1" ] || { echo "OFFICE MONEY ROLLBACK DRILL FAILED: history rows lost ($rows0 before, $rows1 archived)"; exit 1; }
[ "$(psql "$REPLICA_URL" -At -c "select count(*) from pg_namespace n where n.nspname = 'fz_archive' and (has_schema_privilege('anon', n.oid, 'usage') or has_schema_privilege('authenticated', n.oid, 'usage') or has_schema_privilege('service_role', n.oid, 'usage'))")" = "0" ] || { echo "OFFICE MONEY ROLLBACK DRILL FAILED: an API role can reach fz_archive"; exit 1; }
mc1="$(psql "$REPLICA_URL" -At -c "select md5(string_agg(p.oid::regprocedure::text || md5(pg_get_functiondef(p.oid)) || coalesce(p.proacl::text, ''), ',' order by p.oid::regprocedure::text)) from pg_proc p where p.pronamespace='public'::regnamespace and p.prokind='f' and p.proname in ('authorize_action','reserve_spend','settle_spend','release_spend','capital_snapshot','reserve_llm_budget','settle_llm_call','app_set_kill','fz_authorize_action','fz_policy_preview')")|$(psql "$REPLICA_URL" -At -c "select count(*) from pg_trigger t where not t.tgisinternal and t.tgrelid in ('public.ledger'::regclass,'public.llm_calls'::regclass,'public.spend_reservations'::regclass,'public.action_log'::regclass,'public.approval_requests'::regclass,'public.capital_policy'::regclass,'public.system_state'::regclass,'public.action_policy'::regclass)")"
[ "$mc0" = "$mc1" ] || { echo "OFFICE MONEY ROLLBACK DRILL FAILED: the money controls changed ($mc0 vs $mc1)"; exit 1; }
c1="$(psql "$REPLICA_URL" -At -c "select md5(pg_get_functiondef('public.backup_classification()'::regprocedure))")"
for f in 20261127_org_access_v1.sql 20261121_postlock_backup_identity_v1.sql 20261122_postlock_backup_identity_v2.sql; do
  psql "$REPLICA_URL" -q -v ON_ERROR_STOP=1 -f "$root/migrations/$f" >/dev/null 2>"${TMPDIR:-/tmp}/replica.err" || { cat "${TMPDIR:-/tmp}/replica.err"; echo "OFFICE MONEY ROLLBACK DRILL: could not re-apply $f"; exit 1; }
done
c2="$(psql "$REPLICA_URL" -At -c "select md5(pg_get_functiondef('public.backup_classification()'::regprocedure))")"
[ "$c1" = "$c2" ] || { echo "OFFICE MONEY ROLLBACK DRILL FAILED: backup_classification() is not the org-access text ($c1 vs $c2)"; exit 1; }
for f in $(grep -v '^#' "$root/migrations/APPLY_ORDER.txt"); do
  psql "$REPLICA_URL" -q -v ON_ERROR_STOP=1 -f "$root/migrations/$f" >/dev/null 2>"${TMPDIR:-/tmp}/replica.err" || { cat "${TMPDIR:-/tmp}/replica.err"; echo "FAILED re-applying after the office money rollback: $f"; exit 1; }
done
[ "$(psql "$REPLICA_URL" -At -c "select cutover_at from public.fz_money_config where id = 1")" = "$cut0" ] || { echo "OFFICE MONEY ROLLBACK DRILL FAILED: re-apply moved the cutover"; exit 1; }
psql "$REPLICA_URL" -q -At -v ON_ERROR_STOP=1 -f "$root/sqltests/office_money_check.sql" >/dev/null 2>"${TMPDIR:-/tmp}/replica.err" || { cat "${TMPDIR:-/tmp}/replica.err"; echo "office_money_check failed after the rollback + re-apply"; exit 1; }
echo "office money rollback drill OK (M2 removed, record kept, M1 and the money controls untouched, org-access classification exact, then the migrations re-apply and the checks pass again)"
echo "org access rollback drill: ops/rollback_org_access.sql un-archives, removes the scoped roles / policies / columns / fz objects (twice = idempotent), restores the jarvis-hands backup classification exactly, then everything re-applies"
(cd "$root" && psql "$REPLICA_URL" -q -v ON_ERROR_STOP=1 -f ops/rollback_shared_services.sql >/dev/null 2>"${TMPDIR:-/tmp}/replica.err") || { cat "${TMPDIR:-/tmp}/replica.err"; echo "SHARED SERVICES ROLLBACK (before the security hardening rollback) FAILED"; exit 1; }   # M5 sits on M4
(cd "$root" && psql "$REPLICA_URL" -q -v ON_ERROR_STOP=1 -f ops/rollback_security_hardening.sql >/dev/null 2>"${TMPDIR:-/tmp}/replica.err") || { cat "${TMPDIR:-/tmp}/replica.err"; echo "SECURITY HARDENING ROLLBACK (before the approvals kernel rollback) FAILED"; exit 1; }   # security hardening uses the office money owner check
(cd "$root" && psql "$REPLICA_URL" -q -v ON_ERROR_STOP=1 -f ops/rollback_approvals_kernel.sql >/dev/null 2>"${TMPDIR:-/tmp}/replica.err") || { cat "${TMPDIR:-/tmp}/replica.err"; echo "APPROVALS KERNEL ROLLBACK (before the office money rollback) FAILED"; exit 1; }   # the approvals kernel reads office money
(cd "$root" && psql "$REPLICA_URL" -q -v ON_ERROR_STOP=1 -f ops/rollback_office_money.sql >/dev/null 2>"${TMPDIR:-/tmp}/replica.err") || { cat "${TMPDIR:-/tmp}/replica.err"; echo "OFFICE MONEY ROLLBACK (before the org access rollback) FAILED"; exit 1; }   # office money depends on org access
arch="$(psql "$REPLICA_URL" -At -c "select coalesce(string_agg(entity || ':' || key || ':' || prior_status, ',' order by entity, key), '') from public.fz_org_archive where decision = 'archived' and entity in ('agent', 'department')")"
for i in 1 2; do
  (cd "$root" && psql "$REPLICA_URL" -q -v ON_ERROR_STOP=1 -f ops/rollback_org_access.sql >/dev/null 2>"${TMPDIR:-/tmp}/replica.err") || { cat "${TMPDIR:-/tmp}/replica.err"; echo "ORG ACCESS ROLLBACK FAILED (run $i)"; exit 1; }
done
oa="$(psql "$REPLICA_URL" -At -c "select (select count(*) from pg_proc where pronamespace='public'::regnamespace and (proname like 'fz\_%' or proname in ('current_identity','current_office','current_office_id','is_group_scope')))||'/'||(select count(*) from pg_class where relnamespace='public'::regnamespace and relname like 'fz\_%')||'/'||(select count(*) from pg_policies where schemaname='public' and policyname like 'fz\_%')||'/'||(select count(*) from pg_attribute a join pg_class c on c.oid=a.attrelid where c.relnamespace='public'::regnamespace and a.attname in ('office_id','archived_at') and not a.attisdropped and c.relname in ('agents','departments','ventures','missions','tasks','memory','client_workspaces'))||'/'||(select count(*) from pg_roles r where r.rolname in ('fz_jarvis','fz_office_agent','fz_auditor') and (has_schema_privilege(r.rolname, 'public', 'usage') or exists (select 1 from pg_class c where c.relnamespace='public'::regnamespace and c.relkind in ('r','p','v','m') and has_table_privilege(r.rolname, c.oid, 'select,insert,update,delete')) or exists (select 1 from pg_proc p where p.pronamespace='public'::regnamespace and has_function_privilege(r.rolname, p.oid, 'execute'))))||'/'||(select count(*) from pg_trigger where tgname='tasks_fz_stamp')||'/'||(select public.backup_export_policy()->>'unclassified')")"
[ "$oa" = "0/0/0/0/0/0/[]" ] || { echo "ORG ACCESS ROLLBACK DRILL FAILED: $oa"; exit 1; }
if [ -n "$arch" ]; then
  back="$(psql "$REPLICA_URL" -At -c "select string_agg(x, ',' order by x) from (select 'agent:' || slug || ':' || status x from public.agents union all select 'department:' || slug || ':' || status from public.departments) q where x = any (string_to_array('$arch', ','))")"
  [ "$back" = "$arch" ] || { echo "ORG ACCESS ROLLBACK DRILL FAILED: archived rows not restored to their prior status (want $arch, got $back)"; exit 1; }
fi
c1="$(psql "$REPLICA_URL" -At -c "select md5(pg_get_functiondef('public.backup_classification()'::regprocedure))")"
for f in 20261124_jarvis_hands_v1.sql 20261121_postlock_backup_identity_v1.sql 20261122_postlock_backup_identity_v2.sql; do
  psql "$REPLICA_URL" -q -v ON_ERROR_STOP=1 -f "$root/migrations/$f" >/dev/null 2>"${TMPDIR:-/tmp}/replica.err" || { cat "${TMPDIR:-/tmp}/replica.err"; echo "ORG ACCESS ROLLBACK DRILL: could not re-apply $f"; exit 1; }
done
c2="$(psql "$REPLICA_URL" -At -c "select md5(pg_get_functiondef('public.backup_classification()'::regprocedure))")"
[ "$c1" = "$c2" ] || { echo "ORG ACCESS ROLLBACK DRILL FAILED: backup_classification() is not the jarvis-hands text ($c1 vs $c2)"; exit 1; }
for f in $(grep -v '^#' "$root/migrations/APPLY_ORDER.txt"); do
  psql "$REPLICA_URL" -q -v ON_ERROR_STOP=1 -f "$root/migrations/$f" >/dev/null 2>"${TMPDIR:-/tmp}/replica.err" || { cat "${TMPDIR:-/tmp}/replica.err"; echo "FAILED re-applying after the org access rollback: $f"; exit 1; }
done
psql "$REPLICA_URL" -q -At -v ON_ERROR_STOP=1 -f "$root/sqltests/org_access_check.sql" >/dev/null 2>"${TMPDIR:-/tmp}/replica.err" || { cat "${TMPDIR:-/tmp}/replica.err"; echo "org_access_check failed after the rollback + re-apply"; exit 1; }
echo "org access rollback drill OK (archived rows restored, every M1 object removed, jarvis-hands classification exact, then the migrations re-apply and the checks pass again)"
echo "REPLICA OK"
