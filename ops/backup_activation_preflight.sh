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
for f in hq_backup.py ops/restore_backup.py ops/restore_local.sh migrations/20261113_backup_schema_v1.sql; do
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
# 7 client-PII exclusion: DO NOT ACTIVATE until it ships. backup_schema()/backup_snapshot() enumerate every public table dynamically, so
# ws_* / ffm_* / client_workspaces would be exported off-site. WARN (FAIL with --require-pii-exclusion) if any such table exists.
pii_flag() { if [ "$reqpii" = 1 ]; then bad "$1"; else warn "$1"; fi; }
dburl="${PII_CHECK_DB_URL:-${REPLICA_URL:-}}"
if [ -z "$dburl" ]; then pii_flag "client-PII table check could not run: set PII_CHECK_DB_URL (read-only connection string of the target DB)"
elif ! command -v psql >/dev/null 2>&1; then pii_flag "client-PII table check could not run: psql not installed"
else
  tl="$(psql "$dburl" -Atqc "select relname from pg_class where relnamespace='public'::regnamespace and relkind in ('r','p') and relname not in ('push_config','push_subscriptions') order by 1" 2>/dev/null)"; rc=$?
  if [ $rc != 0 ]; then pii_flag "client-PII table check could not run: database not reachable"
  else
    hits="$(printf '%s\n' "$tl" | grep -E '^(ws_|ffm_|client_workspaces$)' | tr '\n' ' ')"
    if [ -n "$hits" ]; then pii_flag "client-PII tables would be included in off-site backups: ${hits}- DO NOT ACTIVATE until the PII exclusion ships (see BACKUP_ACTIVATION_RUNBOOK.md)"
    else ok "no ws_* / ffm_* / client_workspaces tables in the backup table list ($(printf '%s\n' "$tl" | grep -c .) tables checked)"; fi
  fi
fi
echo; echo "Result: $fails FAIL, $warns WARN."; echo "Not checked here (check by eye): bucket is Private; lifecycle rule set; BACKUP_KEY stored in 2 places; migration 20261113_backup_schema_v1.sql applied (the Telegram /backup check shows it)."
[ "$fails" = 0 ]
