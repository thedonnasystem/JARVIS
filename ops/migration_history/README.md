# Historical migrations: preserved, verified, and what cannot be reconstructed
Captured read-only from the live Supabase ledger (`supabase_migrations.schema_migrations`) on 2026-11-12. Nothing here was fabricated.

## What is here
- `<version>_<name>.sql` x 37: the **exact SQL text the ledger recorded** for every migration applied before the Nov 12 evening batch (Nov 2 to Nov 11).
  These were applied through the dashboard/`apply_migration` by the owner's account and never committed to git until now.
- `MANIFEST.tsv`: version, name, length, the ledger's md5, the md5 of the file here, and `MATCH`. **All 37 match the ledger byte for byte** (md5 and length).
  Re-verify any time: `ops/migration_history/verify.sql` (read-only) prints the ledger md5s; compare to `MANIFEST.tsv`.

## The 25 newer ledger entries (Nov 12) are already in `migrations/`
Comparison of repo file vs ledger text, comments and whitespace ignored:
- 21 of 25 identical code.
- 4 differ only by added `drop trigger if exists ...` lines in the repo, made after they were applied so that re-running is safe
  (`permissions_v1` x3, `bank_v1`, `capital_v1`, `finance_rules_v1`). Verified line by line. Live state is the same either way.
- `lockdown_v1`, `phase1_repair_v1`, `mission_guard_v1` are NOT in the ledger (lockdown was run as raw SQL; the other two are not applied yet).

## What these files are, and are not
They are the *recorded history*, useful for audit and for rebuilding from scratch **in principle**. They are not a safe replay script:
1. **Order-dependent patches.** Eight of them rewrite an existing function by `pg_get_functiondef(...)` + `replace(...)` (e.g. `daily_planning_fix_nested_agg`,
   `planning_results_rule`, `engine_pause_reason`, `station_snapshot_pause`). They only work on the exact prior function text.
2. **Objects created outside the ledger.** Some live functions are called by these migrations but created by none of them (e.g. `daily_brief_core()`).
   They were created with raw SQL. Their definitions exist only in the live database and in the md5 baseline.
3. **Cron jobs and data.** Several create pg_cron jobs and seed rows (`model_prices`, `systems`, `company_profile`). Live data has since changed.
4. **Not covered at all:** edge functions, RLS flag state, grants made by hand, and any change made in the dashboard UI without a migration.

## Recovery strategy (in order of trust)
1. **Supabase backups / point-in-time recovery** is the authoritative way to restore production. Confirm the plan's retention in the dashboard (owner action; not checked here).
2. **Live function bodies** are pinned by md5 in `ops/live_functions_baseline_20261112.txt` (91 functions). Drift detection: `ops/verify_live.sql`. The three functions Phase 1 changes are restorable byte-for-byte from `ops/rollback_phase1.sql`.
3. **Schema** (tables, constraints, triggers) for a rebuild or rehearsal: `scripts/replica/01_tables.sql`, `02_constraints.sql`, `03_funcs.sql` (captured live Nov 12), then `migrations/` in `APPLY_ORDER.txt` order. This is what CI uses.
4. **Full-text history**: this directory.
5. **Before the next change to production**, take the owner-side backup and record the ledger row count (`select count(*) from supabase_migrations.schema_migrations` = 62 on 2026-11-12).

## Not recoverable from anything in the repo or ledger
The *original text* of objects created by raw SQL (item 2 above). Their *current* definitions are readable from the live database (`pg_get_functiondef`) and are fingerprinted; if the database were lost with no backup, those would need to be rewritten from their documented behaviour.
