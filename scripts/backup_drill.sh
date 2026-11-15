#!/usr/bin/env bash
# Rebuilds the replica schema (all migrations) into a scratch "source" DB, then runs the end-to-end backup + restore drill.
# Needs a local Postgres (superuser) and: pip install cryptography psycopg2-binary. Touches only the two scratch databases named below.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
export PGPASSWORD="${PGPASSWORD:-pw}"
SRC_DB="${DRILL_SRC_DB:-drill_src}"; RESTORE_DB="${DRILL_RESTORE_DB:-drill_restore}"      # two drills on one Postgres server need different names (set DRILL_SRC_DB / DRILL_RESTORE_DB)
export REPLICA_URL="${REPLICA_URL:-postgresql://postgres:pw@${PGHOST:-localhost}:${PGPORT:-5432}/$SRC_DB}"
export RESTORE_URL="${RESTORE_URL:-postgresql://postgres:pw@${PGHOST:-localhost}:${PGPORT:-5432}/$RESTORE_DB}"
for d in "$SRC_DB" "$RESTORE_DB"; do psql -h "${PGHOST:-localhost}" -p "${PGPORT:-5432}" -U postgres -Atqc "drop database if exists $d" -c "create database $d" >/dev/null; done
bash "$here/replica/run.sh" >/dev/null
# (all migrations, including backup_schema_v1 and backup_exclude_client_pii_v1, are already applied by replica/run.sh; re-applying the old backup_snapshot here would overwrite the policy-aware one)
python3 "$here/backup_drill.py"
