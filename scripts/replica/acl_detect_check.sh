#!/usr/bin/env bash
# Round 8 (S4): a MISSING or DISABLED event trigger ffm_backup_acl_sweep must be DETECTED by both activation checks, not only prevented.
#   expected, trigger enabled : scripts/acl_manifest.py has no event-trigger complaint; the preflight prints PASS for it
#   expected, trigger disabled: acl_manifest.py exits non-zero naming it DISABLED; the preflight prints FAIL ... BLOCKING OWNER ACTION (with --require-pii-exclusion)
#   expected, trigger dropped : acl_manifest.py exits non-zero naming it MISSING;  the preflight prints FAIL ... BLOCKING OWNER ACTION
# The trigger is restored exactly (the migration is re-applied) whatever happens. Scratch replica only.
set -uo pipefail
here="$(cd "$(dirname "$0")" && pwd)"; root="$here/../.."
: "${REPLICA_URL:?set REPLICA_URL to a scratch Postgres database}"
echo "$REPLICA_URL" | grep -qi supabase && { echo "refusing: not a scratch database"; exit 2; }
restore() { psql "$REPLICA_URL" -q -v ON_ERROR_STOP=1 -f "$root/migrations/20261122_postlock_backup_identity_v2.sql" >/dev/null 2>&1; }
trap restore EXIT
fail=0
manifest() { python3 "$root/scripts/acl_manifest.py" --url "$REPLICA_URL" 2>&1 >/dev/null; echo "rc=$?"; }
pre() { env -i PATH="$PATH" HOME="${HOME:-/tmp}" PII_CHECK_DB_URL="$REPLICA_URL" bash "$root/ops/backup_activation_preflight.sh" --require-pii-exclusion 2>&1 | grep -i "event trigger" || true; }
expect() { if echo "$2" | grep -Eq "$3"; then echo "ok    $1"; else echo "FAIL  $1: expected /$3/, actual: $(echo "$2" | tr '\n' ' ' | cut -c1-240)"; fail=1; fi; }
reject() { if echo "$2" | grep -Eq "$3"; then echo "FAIL  $1: did not expect /$3/, actual: $(echo "$2" | tr '\n' ' ' | cut -c1-240)"; fail=1; else echo "ok    $1"; fi; }

restore
m="$(manifest)"; p="$(pre)"
reject "enabled: manifest has no event-trigger complaint" "$m" "event trigger ffm_backup_acl_sweep is"
expect "enabled: preflight PASS" "$p" "^PASS  event trigger ffm_backup_acl_sweep is present and enabled"
psql "$REPLICA_URL" -q -v ON_ERROR_STOP=1 -c "alter event trigger ffm_backup_acl_sweep disable" >/dev/null
m="$(manifest)"; p="$(pre)"
expect "disabled: manifest check fails and names it" "$m" "event trigger ffm_backup_acl_sweep is DISABLED"
expect "disabled: manifest exit code is non-zero" "$m" "rc=[1-9]"
expect "disabled: preflight FAIL, blocking owner action" "$p" "^FAIL  BLOCKING OWNER ACTION: event trigger ffm_backup_acl_sweep is DISABLED"
psql "$REPLICA_URL" -q -v ON_ERROR_STOP=1 -c "drop event trigger ffm_backup_acl_sweep" >/dev/null
m="$(manifest)"; p="$(pre)"
expect "dropped: manifest check fails and names it" "$m" "event trigger ffm_backup_acl_sweep is MISSING"
expect "dropped: manifest exit code is non-zero" "$m" "rc=[1-9]"
expect "dropped: preflight FAIL, blocking owner action" "$p" "^FAIL  BLOCKING OWNER ACTION: event trigger ffm_backup_acl_sweep is MISSING"
restore
m="$(manifest)"
reject "restored: manifest has no event-trigger complaint" "$m" "event trigger ffm_backup_acl_sweep is"
[ "$fail" = 0 ] && echo "ACL DETECTION OK" || { echo "ACL DETECTION FAILED"; exit 1; }
