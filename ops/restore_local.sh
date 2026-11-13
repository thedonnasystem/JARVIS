#!/usr/bin/env bash
# Local, ISOLATED disaster-recovery restore + verification. Run this on YOUR computer (or any machine you control), never in chat.
#   ops/restore_local.sh --file hq-20261114T070000Z.tar.gz.enc [--expect-sha256 <hash from /backup>]
#   ops/restore_local.sh --b2-latest [--expect-sha256 <hash>]          (reads from Backblaze with the READ-ONLY key)
# What it does: starts a throwaway PostgreSQL 17.11 in Docker bound to 127.0.0.1 only, restores the backup into it with ops/restore_backup.py
# (which refuses anything that is not a local scratch database), prints the verification report, writes a per-table fingerprint you can
# compare with production, then DESTROYS the container. Secrets are typed at hidden prompts (or taken from your shell environment):
# they are never put on a command line, in a file, in the report, or in any log.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
command -v docker >/dev/null || { echo "Docker is required (it keeps the restore isolated from everything else)."; exit 2; }
python3 - <<'PY' || { echo "Run: pip install cryptography psycopg2-binary"; exit 2; }
import cryptography, psycopg2
PY
args=("$@")
use_b2=0; for a in "$@"; do [ "$a" = "--b2-latest" ] || [ "$a" = "--b2-name" ] && use_b2=1; done
if [ -z "${BACKUP_KEY:-}" ]; then read -rsp "BACKUP_KEY (hidden): " BACKUP_KEY; echo; fi
export BACKUP_KEY
if [ "$use_b2" = 1 ]; then
  if [ -z "${RESTORE_B2_AUTH:-}" ]; then read -rsp "Read-only B2 key as keyId:applicationKey (hidden): " RESTORE_B2_AUTH; echo; fi
  if [ -z "${RESTORE_B2_BUCKET_ID:-}" ]; then read -rp "B2 bucket ID (not secret): " RESTORE_B2_BUCKET_ID; fi
  export RESTORE_B2_AUTH RESTORE_B2_BUCKET_ID RESTORE_B2_PREFIX="${RESTORE_B2_PREFIX:-hq/}"
fi
name="fendezy-restore-$$"; pw="$(python3 -c 'import secrets;print(secrets.token_urlsafe(24))')"
cleanup() { docker rm -f "$name" >/dev/null 2>&1 || true; unset BACKUP_KEY RESTORE_B2_AUTH RESTORE_DB_URL POSTGRES_PASSWORD pw; }
trap cleanup EXIT
export POSTGRES_PASSWORD="$pw"      # passed to docker by NAME (-e POSTGRES_PASSWORD), so the value never appears in ps / docker inspect arguments or bash -x output
if ! docker run -d --name "$name" -e POSTGRES_PASSWORD -p 127.0.0.1::5432 postgres:17.11 >/dev/null; then
  echo "Could not start the throwaway PostgreSQL 17.11 container (is Docker running, and can it pull postgres:17.11?)."; exit 2
fi
unset POSTGRES_PASSWORD
port="$(docker port "$name" 5432/tcp | head -1 | sed 's/.*://')"
ready=0
for i in $(seq 1 60); do   # -h 127.0.0.1: the image's temporary init server only listens on the unix socket, so TCP readiness means the real server is up
  docker exec "$name" pg_isready -h 127.0.0.1 -U postgres >/dev/null 2>&1 && { ready=1; break; }; sleep 1
done
[ "$ready" = 1 ] || { echo "The throwaway database did not become ready in 60 seconds."; exit 2; }
docker exec "$name" psql -h 127.0.0.1 -U postgres -Atqc "create database restore_local" >/dev/null
export RESTORE_DB_URL="postgresql://postgres:${pw}@127.0.0.1:${port}/restore_local"
stamp="$(date -u +%Y%m%dT%H%M%SZ)"
report="restore_report_${stamp}.json"
set +e
python3 "$here/restore_backup.py" --wipe --report "$report" "${args[@]}" >/dev/null
code=$?
set -e
echo "restore exit code: $code   (0 = clean pass, 1 = verification failed, 2 = refused/bad input, 3 = error, 4 = restored with foreign-key warnings)"
python3 - "$report" <<'PY'
import json, sys
r = json.load(open(sys.argv[1]))
print("RESULT:", r.get("result"), "| file:", r.get("file", {}).get("name"), "| sha256:", r.get("file", {}).get("sha256"))
print("consistency of the backup:", (r.get("archive") or {}).get("consistency"))
for k, v in (r.get("steps") or {}).items(): print(f"  {k}: {v}")
if r.get("error"): print("ERROR:", r["error"])
for k, v in (r.get("business_data") or {}).items(): print(f"  business data {k}: {'identical' if v.get('all_identical') else 'DIFFERS'}")
if r.get("not_restored"): print("not restored / notes:", json.dumps(r["not_restored"])[:400])
PY
if [ "$code" = 0 ] || [ "$code" = 4 ]; then
  fp="restore_fingerprint_${stamp}.txt"
  docker exec -i "$name" psql -U postgres -d restore_local -Atq < "$here/table_fingerprint.sql" > "$fp"
  echo "wrote $report and $fp (no secrets inside)."
  echo "INDEPENDENT CHECK: run ops/table_fingerprint.sql on production (Supabase SQL editor, read-only) and diff the output with $fp."
  echo "Rows that change constantly (audit_log, llm_calls, owner_messages, system_state...) may differ by the activity since the backup; everything else must match."
fi
echo "Destroying the throwaway database container..."
exit "$code"
