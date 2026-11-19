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
  psql "$REPLICA_URL" -q -v ON_ERROR_STOP=1 -f "$root/migrations/$f" >/dev/null 2>"${TMPDIR:-/tmp}/replica.err" || { cat "${TMPDIR:-/tmp}/replica.err"; echo "FAILED: $f"; exit 1; }
  echo "applied $f"
done
echo "re-applying every migration (must be safe to run twice)"
for f in $(grep -v '^#' "$root/migrations/APPLY_ORDER.txt"); do
  psql "$REPLICA_URL" -q -v ON_ERROR_STOP=1 -f "$root/migrations/$f" >/dev/null 2>"${TMPDIR:-/tmp}/replica.err" || { cat "${TMPDIR:-/tmp}/replica.err"; echo "FAILED on second apply: $f"; exit 1; }
done
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
echo "REPLICA OK"
