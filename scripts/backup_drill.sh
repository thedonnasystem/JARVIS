#!/usr/bin/env bash
# Rebuilds the replica schema (all migrations) into a scratch "source" DB, then runs the end-to-end backup + restore drill.
# Needs a local Postgres (superuser) and: pip install cryptography psycopg2-binary. Touches only the two scratch databases named below.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
export PGPASSWORD="${PGPASSWORD:-pw}"
# Per-process database names (suffix $DRILL_SUFFIX, default this shell's PID) so two concurrent drills (two worktrees, CI + a local run) never drop each other's database.
sfx="${DRILL_SUFFIX:-$$}"
src="drill_src_${sfx}"; dst="drill_restore_${sfx}"
export DRILL_SUFFIX="$sfx"
export REPLICA_URL="${REPLICA_URL:-postgresql://postgres:pw@${PGHOST:-localhost}:${PGPORT:-5432}/$src}"
export RESTORE_URL="${RESTORE_URL:-postgresql://postgres:pw@${PGHOST:-localhost}:${PGPORT:-5432}/$dst}"
# drop only the databases THIS run created (names derived from the URLs, so an explicit REPLICA_URL/RESTORE_URL keeps working)
src="${REPLICA_URL##*/}"; dst="${RESTORE_URL##*/}"
cleanup() { for d in "$src" "$dst"; do psql -h "${PGHOST:-localhost}" -p "${PGPORT:-5432}" -U postgres -Atqc "drop database if exists \"$d\"" >/dev/null 2>&1 || true; done; }
trap cleanup EXIT
for d in "$src" "$dst"; do psql -h "${PGHOST:-localhost}" -p "${PGPORT:-5432}" -U postgres -Atqc "drop database if exists \"$d\"" -c "create database \"$d\"" >/dev/null; done
bash "$here/replica/run.sh" >/dev/null
# (all migrations, including backup_schema_v1 and backup_exclude_client_pii_v1, are already applied by replica/run.sh; re-applying the old backup_snapshot here would overwrite the policy-aware one)
python3 "$here/backup_drill.py"
