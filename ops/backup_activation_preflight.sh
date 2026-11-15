#!/usr/bin/env bash
# Backup activation preflight. Checks everything verifiable WITHOUT showing any value: only presence, length, format and PASS/WARN/FAIL.
# Run where the three variables are in the environment WITHOUT typing them anywhere, e.g.:   railway run ops/backup_activation_preflight.sh
# (railway run puts the service variables into this one process only; nothing is printed or written.) Add --network to also ask the
# destination (Backblaze) whether the key is accepted and limited correctly: one authorize call, no upload, no data sent.
# --require-pii-exclusion: the PII check (section 7) becomes a FAIL instead of a WARN (also when the DB cannot be checked). The check reads the
# table list of the target DB through psql using PII_CHECK_DB_URL (or REPLICA_URL); it prints table NAMES only, never rows or the URL.
# Never prints BACKUP_KEY / BACKUP_AUTH / BACKUP_PUT_URL. Exit 0 = no FAIL, 1 = at least one FAIL.
set -u
here="$(cd "$(dirname "$0")" && pwd)"; root="$here/.."
fails=0; warns=0
ok()   { echo "PASS  $1"; }
warn() { echo "WARN  $1"; warns=$((warns+1)); }
bad()  { echo "FAIL  $1"; fails=$((fails+1)); }
net=0; reqpii=0
for a in "$@"; do case "$a" in --network) net=1;; --require-pii-exclusion) reqpii=1;; *) echo "unknown arg $a"; exit 2;; esac; done

key="${BACKUP_KEY:-}"; url="${BACKUP_PUT_URL:-}"; auth="${BACKUP_AUTH:-}"

# 1 presence + length
for v in BACKUP_KEY BACKUP_PUT_URL BACKUP_AUTH; do
  val="${!v:-}"; if [ -n "$val" ]; then ok "$v is set (length ${#val})"; else bad "$v is NOT set"; fi
done
# 2 key format
if [ -n "$key" ]; then
  [ "${#key}" = 44 ] && [ "${key: -1}" = "=" ] && ok "BACKUP_KEY has Fernet shape (44 chars, ends with =)" || bad "BACKUP_KEY must be 44 characters ending in = (re-generate; do not edit by hand)"
  case "$key" in *[[:space:]]*|\"*|\'*) bad "BACKUP_KEY contains whitespace or quote characters (paste the bare key, no quotes)";; esac
  if python3 -c "import cryptography" 2>/dev/null; then
    if BK="$key" python3 -c "import os,sys;from cryptography.fernet import Fernet;f=Fernet(os.environ['BK'].encode());sys.exit(0 if f.decrypt(f.encrypt(b'x'))==b'x' else 1)" 2>/dev/null; then ok "BACKUP_KEY works (encrypt/decrypt round trip)"; else bad "BACKUP_KEY is not a valid Fernet key"; fi
  else warn "python 'cryptography' not installed here; key round trip skipped (pip install cryptography)"; fi
fi
# 3 destination shape (prints the scheme only, never the host/path: a path can hold a token)
kind=""
case "$url" in
  b2://*) kind=b2; ok "BACKUP_PUT_URL scheme: b2 (Backblaze)"
          printf '%s' "$url" | grep -Eq '^b2://[A-Za-z0-9]{8,64}(/[^ ]*)?$' && ok "BACKUP_PUT_URL looks like b2://<bucketId>[/prefix]" || bad "BACKUP_PUT_URL must look like b2://<bucketId>/hq"
          case "$url" in */hq|*/hq/) ok "prefix is hq (what ops/restore_local.sh looks for by default)";; *) warn "prefix is not /hq; restore needs RESTORE_B2_PREFIX to match";; esac
          case "$auth" in *:*) ok "BACKUP_AUTH has the keyId:applicationKey shape";; "") ;; *) bad "BACKUP_AUTH for b2 must be <keyId>:<applicationKey>";; esac ;;
  https://*) kind=put; ok "BACKUP_PUT_URL scheme: https (generic PUT)"
          case "$url" in *"{name}"*) ok "BACKUP_PUT_URL contains {name}";; *) bad "BACKUP_PUT_URL must contain {name} (else the backup and its checksum overwrite each other)";; esac
          case "$auth" in "Basic "*|"Bearer "*) ok "BACKUP_AUTH starts with a valid HTTP auth scheme (Basic/Bearer)";; "") warn "BACKUP_AUTH empty: destination would be unauthenticated";; *) warn "BACKUP_AUTH is sent verbatim as the Authorization header; usually 'Basic <base64>' or 'Bearer <token>'";; esac ;;
  "") ;;
  http://*) bad "BACKUP_PUT_URL is http:// (refused by the bot: https:// or b2:// only)";;
  *) bad "BACKUP_PUT_URL must start with b2:// or https://";;
esac
# 4 variables that must NOT be in the bot's environment
for v in RESTORE_B2_AUTH RESTORE_B2_BUCKET_ID RESTORE_DB_URL; do
  [ -n "${!v:-}" ] && bad "$v is set here; restore variables must never live in Railway" || ok "$v is not set (good)"
done
# 5 repo pieces the flow depends on
for f in hq_backup.py hq_backup_keep.py hq_scrub.py ops/restore_backup.py ops/restore_local.sh migrations/20261113_backup_schema_v1.sql migrations/20261120_backup_redact_leak_paths_v1.sql migrations/20261120_redaction_denylist_v1.sql migrations/20261120_leak_source_prevention_v1.sql; do
  [ -f "$root/$f" ] && ok "found $f" || bad "missing $f"
done
python3 -c "import psycopg2" 2>/dev/null && ok "psycopg2 available (needed by the restore tool on YOUR computer)" || warn "psycopg2-binary not installed here (needed only where you run the restore drill)"
# 6 optional destination check (Backblaze only). Output is PASS/WARN/FAIL lines only.
if [ "$net" = 1 ]; then
  if [ "$kind" != b2 ]; then warn "--network check is implemented for b2:// only"
  elif [ -z "$auth" ]; then bad "--network needs BACKUP_AUTH"
  else
    out="$(cd "$root" && python3 - <<'PY' 2>&1
import hq_backup as B
try:
    for r in B.preflight():
        if "Backblaze" in r["check"] or r["check"].startswith("Key"):
            print(r["status"].upper().ljust(4), r["check"], ("- " + r["detail"]) if r["detail"] else "")
except Exception as e:
    print("FAIL ", "network check could not run:", type(e).__name__)
PY
)"
    echo "$out"; echo "$out" | grep -q '^FAIL' && fails=$((fails+1)); echo "$out" | grep -q '^WARN' && warns=$((warns+1))
  fi
fi
# 7 client-PII exclusion. The DATABASE decides what is exported (public.backup_export_policy(), migration 20261119_backup_exclude_client_pii_v1). This check reads that decision
# (table NAMES only, never rows or the URL) and requires: the function exists; no client table is on the exported list; nothing is unclassified.
# WARN (FAIL with --require-pii-exclusion) otherwise. Then section 8 below requires the client-text leak paths to be closed (redaction installed).
pii_flag() { if [ "$reqpii" = 1 ]; then bad "$1"; else warn "$1"; fi; }
dburl="${PII_CHECK_DB_URL:-${REPLICA_URL:-}}"
if [ -z "$dburl" ]; then pii_flag "client-PII policy check could not run: set PII_CHECK_DB_URL (read-only connection string of the target DB)"
elif ! command -v psql >/dev/null 2>&1; then pii_flag "client-PII policy check could not run: psql not installed"
else
  pol="$(psql "$dburl" -Atqc "select jsonb_array_length(p->'exported') || ' ' || jsonb_array_length(p->'unclassified') || ' ' || coalesce((select string_agg(e, ',') from jsonb_array_elements_text(p->'exported') e where e ~ '^(ws_|ffm_)' or e in ('client_workspaces','leads','outbox','lead_replies','deals','contact_suppressions','setters','setter_events','setter_payouts')), '-') || ' ' || coalesce((select string_agg(e, ',') from jsonb_array_elements_text(p->'unclassified') e), '-') from (select public.backup_export_policy() p) q" 2>/dev/null)"; rc=$?
  if [ $rc != 0 ] || [ -z "$pol" ]; then pii_flag "client-PII policy check could not run: database not reachable or backup_export_policy() is not installed (apply migration 20261119_backup_exclude_client_pii_v1 first)"
  else
    set -- $pol; nexp="$1"; nun="$2"; bad_exp="$3"; uncl="$4"
    if [ "$bad_exp" != "-" ]; then pii_flag "client tables are on the EXPORT list: ${bad_exp} - DO NOT ACTIVATE"
    elif [ "$nun" != "0" ]; then pii_flag "unclassified tables (not exported until classified in a migration): ${uncl} - review before activating"
    else ok "export policy: ${nexp} tables exported, no client table on the list, nothing unclassified"; fi
  fi
fi
# 8 the known client-text leak paths (audit_log.detail.reason, ledger.note of setter payouts, tasks.result, agent_runs.summary; DATA_CLASSIFICATION_AND_BACKUP_POLICY.md section 2) are CLOSED when both
# layers are installed in the target database: the source fixes (migration 20261120_leak_source_prevention_v1), the export redaction inside backup_snapshot() (20261120_backup_redact_leak_paths_v1) and the deny-list that remembers erased names (20261120_redaction_denylist_v1).
# The check reads public.backup_redaction_status(), which inspects the definitions actually in force (not a flag anyone can set). BACKUP_LEAK_PATHS_ACCEPTED=1 no longer passes this check:
# accepting the leak was option (c); the owner chose (a)+(b), so the only way to pass is to have the redaction installed.
if [ -z "$dburl" ] || ! command -v psql >/dev/null 2>&1; then pii_flag "KNOWN LEAK PATHS: cannot check whether the redaction is installed (set PII_CHECK_DB_URL, psql needed)"
else
  st="$(psql "$dburl" -Atqc "select concat_ws(' ', coalesce(s->>'snapshot_redacts','f'), coalesce(s->>'sources_fixed','f'), coalesce(s->>'redactor_installed','f'), coalesce(s->>'agent_runs_trigger','f'), coalesce(s->>'denylist','f')) from (select public.backup_redaction_status() s) q" 2>/dev/null)"; rc=$?
  if [ $rc != 0 ] || [ -z "$st" ]; then pii_flag "KNOWN LEAK PATHS: backup_redaction_status() is not installed - apply migrations 20261120_backup_redact_leak_paths_v1 and 20261120_leak_source_prevention_v1 (see DATA_CLASSIFICATION_AND_BACKUP_POLICY.md section 2)"
  elif [ "$st" = "true true true true true" ]; then ok "client-text leak paths closed: source fixes + export redaction + deny-list triggers are installed (backup_redaction_status)"
  else pii_flag "KNOWN LEAK PATHS: redaction only partly installed (snapshot_redacts/sources_fixed/redactor_installed/agent_runs_trigger/denylist = $st) - DO NOT ACTIVATE"; fi
  [ "${BACKUP_LEAK_PATHS_ACCEPTED:-0}" = 1 ] && warn "BACKUP_LEAK_PATHS_ACCEPTED=1 is ignored: it no longer substitutes for the redaction (owner decision: close the leak paths, do not accept them)"
fi
# the backup identity (owner directive D): the migration 20261121_postlock_backup_identity_v1 takes the backup functions away from service_role, so the backup must carry its own token
if [ -n "$dburl" ] && command -v psql >/dev/null 2>&1; then
  idn="$(psql "$dburl" -Atqc "select (exists (select 1 from pg_roles where rolname = 'backup_reader'))::text || ' ' || coalesce(has_function_privilege('service_role', to_regprocedure('public.backup_epoch()'), 'execute')::text, 'none') || ' ' || coalesce(has_function_privilege('backup_reader', to_regprocedure('public.backup_epoch()'), 'execute')::text, 'none')" 2>/dev/null)"
  case "$idn" in
    "true false true") ok "backup identity installed: role backup_reader can run the backup functions, service_role cannot";;
    *) pii_flag "BACKUP IDENTITY: not as expected (role exists / service_role may execute / backup_reader may execute = $idn) - apply migration 20261121_postlock_backup_identity_v1 (after the lockdown)";;
  esac
fi
if [ -n "${BACKUP_READER_JWT:-}" ]; then ok "BACKUP_READER_JWT is set (the backup calls its functions as role backup_reader, never with the service key)"
else warn "BACKUP_READER_JWT is not set: after the post-lockdown migration the backup is refused by the database (fail closed, nothing uploaded). Owner decision: see DATA_CLASSIFICATION_AND_BACKUP_POLICY.md rule 12"; fi
echo; echo "Result: $fails FAIL, $warns WARN."; echo "Not checked here (check by eye): bucket is Private; lifecycle rule set; BACKUP_KEY stored in 2 places; migration 20261113_backup_schema_v1.sql applied (the Telegram /backup check shows it)."
[ "$fails" = 0 ]
