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
echo "REPLICA OK"
