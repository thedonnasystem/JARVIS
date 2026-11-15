#!/usr/bin/env bash
# Performance check of the export redactor on a SCRATCH database (never production: it inserts synthetic rows and refuses a supabase host).
#   scripts/perf_redaction.sh postgresql://postgres:pw@localhost:5432/<scratch> [audit_rows=2000] [task_rows=200] [budget_seconds=30]
# Applies nothing: the redaction migrations must already be installed. Prints one line per measurement and exits 1 when over the budget.
# Measured on the 2-core scratch machine (single statement, ms):  2,284 audit + 226 tasks = 4.9 s;  50,284 audit + 10,026 tasks (11.5k chars each) = 129 s;
# paged: tasks 500 rows = 6.5 s, audit_log 5,000 rows = 3.8 s per call. See DATA_CLASSIFICATION_AND_BACKUP_POLICY.md section 2 for the scaling table.
set -euo pipefail
url="${1:?scratch database url}"; audit="${2:-2000}"; tasks="${3:-200}"; budget="${4:-30}"
case "$url" in *supabase*|*pooler*) echo "refusing: not a scratch database" >&2; exit 2;; esac
here="$(cd "$(dirname "$0")" && pwd)"
# one transaction, rolled back: the synthetic rows never stay in the scratch database (the drill and other checks share it)
out="$(psql "$url" -At -q -v ON_ERROR_STOP=1 -v audit="$audit" -v tasks="$tasks" -v leads=40 <<SQL | tail -n 1
begin;
\\i $here/perf_redaction_seed.sql
select (public.backup_snapshot() -> 'redaction' ->> 'ms_total')::numeric / 1000 || '|' || (public.backup_snapshot_cost() ->> 'est_seconds')::numeric;
rollback;
SQL
)"
secs="${out%%|*}"; est="${out##*|}"
echo "audit=$audit tasks=$tasks single_statement_s=$secs estimated_s=$est budget_s=$budget"
awk -v s="$secs" -v b="$budget" 'BEGIN { exit (s <= b) ? 0 : 1 }' || { echo "OVER BUDGET" >&2; exit 1; }
