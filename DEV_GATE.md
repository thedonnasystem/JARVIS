# Dev gate: one command before merge or deploy

```
export PGPASSWORD=pw
export REPLICA_URL=postgresql://postgres:pw@localhost:5432/<your scratch db>   # its public schema is WIPED
scripts/gate.sh --strict
```
CI runs the identical script (`.github/workflows/tests.yml`: job `migrations` = `gate.sh --strict`; job `unit` = the database-free subset).

| step | what it proves | needs |
|---|---|---|
| unit | `python3 -m unittest discover -q` (repo tests) | python |
| scripts-tests | tests of the lint and the function manifest | python |
| lint | `scripts/lint_migrations.py`: order list, naming, lockdown last, explicit REVOKE on new functions, no edits to applied migrations (rules in MIGRATIONS.md) | git history of `origin/overnight-build` (else R6 prints a NOTE and is skipped) |
| bundle | `dist/APPLY_ALL.sql` matches `migrations/` | - |
| replica | every migration twice on a copy of the live schema, e2e, real-engine integration, rollback drill (`scripts/replica/run.sh`) | Postgres at `REPLICA_URL` |
| manifest | generated function added/changed/removed report equals `ops/EXPECTED_NEW_FUNCTIONS.txt` | the replica step |
| backup | `scripts/backup_drill.sh` if the branch has it | Postgres, `pip install cryptography psycopg2-binary` |

Output ends with a PASS / FAIL / SKIPPED table. Exit 1 on any FAIL. Without `REPLICA_URL` (or if it is unreachable, remote, or looks like Supabase) the database steps are SKIPPED and the verdict says `GATE INCOMPLETE ... NOT a full pre-deploy pass`; with `--strict` any required SKIPPED is a failure (the backup drill is `(optional)` while the script does not exist). Run one or more steps: `scripts/gate.sh --only lint,bundle`. Logs of each step are kept in the temp dir printed at the end.

## Function manifest: the one-edit workflow
`ops/EXPECTED_NEW_FUNCTIONS.txt` is generated. It used to be hand-listed and drifted.
1. Add or change a function in a migration (new file, per MIGRATIONS.md).
2. `scripts/replica/run.sh` (or `scripts/gate.sh`, which does it), then `scripts/function_manifest.py --write`.
3. Review the diff of `ops/EXPECTED_NEW_FUNCTIONS.txt` and commit it with the migration. The gate fails (`MISMATCH: ...`) if you forget.

The report (`scripts/function_manifest.py` without flags) lists, against `ops/live_functions_baseline_*.txt` (newest file wins):
- **added**: in the replica, not in live. **removed**: live, gone from the replica. **changed**: md5 differs, and the replica's seed copy was byte-identical to live (so a migration caused it).
- **unverifiable**: md5 differs but the replica's seed copy of the function never matched live (the seed in `scripts/replica/03_funcs.sql` is an approximation, so 30 of 91 functions today). The replica cannot prove those either way; check them against production with `ops/verify_live.sql` before/after deploy, as before.
After a deploy, capture a new `ops/live_functions_baseline_<date>.txt` from production (`function_md5` row of `ops/verify_live.sql`) and regenerate the expected file (it empties).

The file format is unchanged (signature per line under `ADD` / `CHANGE` headers, plus a `REMOVE` section); `ops/verify_live.sql` and `ops/verify_deploy.sh` do not read it and are untouched.
