#!/usr/bin/env bash
# Rebuilds the replica schema into a scratch "source" DB, installs backup_schema(), then runs the end-to-end backup + restore drill.
# Needs a local Postgres (superuser) and: pip install cryptography psycopg2-binary. Touches only the two scratch databases named below.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
export PGPASSWORD="${PGPASSWORD:-pw}"
export REPLICA_URL="${REPLICA_URL:-postgresql://postgres:pw@${PGHOST:-localhost}:${PGPORT:-5432}/drill_src}"
export RESTORE_URL="${RESTORE_URL:-postgresql://postgres:pw@${PGHOST:-localhost}:${PGPORT:-5432}/drill_restore}"
for d in drill_src drill_restore; do psql -h "${PGHOST:-localhost}" -p "${PGPORT:-5432}" -U postgres -Atqc "drop database if exists $d" -c "create database $d" >/dev/null; done
bash "$here/replica/run.sh" >/dev/null
psql "$REPLICA_URL" -q -v ON_ERROR_STOP=1 -f "$here/../migrations/20261113_backup_schema_v1.sql" >/dev/null
python3 "$here/backup_drill.py"
