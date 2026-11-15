# Release plan: Gate B combined (supersedes the migration table in RELEASE_PLAN_executor_ffm.md)
Prepared 2026-11-15 from `overnight-build` @ `4843401`. PLAN ONLY: nothing here has been applied to production. Every step needs the owner's release authorization. Railway stays on `ecadb31` (no bot redeploy is required for any migration below; the sweep's bot job in `hq_engine.py`/`bot.py` is a separate deploy gate).

## 1. Migrations, in this exact order (one `apply_migration` call per file; stop at the first error; never retry blindly)
| # | Name | File | sha256 |
|---|---|---|---|
| 1 | executor_gate_v1 | migrations/20261117_executor_gate_v1.sql | a8c2763dafdc46f6080c7e8afbf927bcbed6a308fe5ba15440245a6da15b4db6 |
| 2 | client_workspaces_v1 | migrations/20261117_client_workspaces_v1.sql | 4c8c38322cfe026c88ad51335316f5210cb294649e46c6285b6f663b54f837b3 |
| 3 | executor_sweep_v1 | migrations/20261118_executor_sweep_v1.sql | 0367f6724978bc8c3e89987057a7b801bb84396656c4415d331ce3f178d76166 |
| 4 | ffm_onboarding_v1 | migrations/20261118_ffm_onboarding_v1.sql | 6b43a5b87ade668fbb5fcede6de3860a56e22220ffbc5ac95d68b07db1a68de6 |
| 5 | ffm_consent_v1 | migrations/20261119_ffm_consent_v1.sql | ed43dad88d62c5f09f85488de5fd4841e0262c958ef3133b77432566abe268f2 |
| 6 | backup_exclude_client_pii_v1 | migrations/20261119_backup_exclude_client_pii_v1.sql | e91cd85ba7bb49b084430a20067e6c9866bdf525d4caf96dcfbb562d75dbcdc0 |
| 7 (LAST) | lockdown_v1 (re-run, idempotent) | migrations/20261112_lockdown_v1.sql | 19a474d4e0f6f9bc9941ffe4eeaaf6b318aaeb753b367c3cf8026bf78ab9e92a |
Verify before Gate B: `git show <merged sha>:migrations/<file> | sha256sum` equals the table. These hashes are from `4843401`; if any migration changes afterwards, regenerate them.

## 2. What it does to production
- 47 new distinct function names; 1 existing function replaced (`backup_snapshot`: now exports only classified, non-client tables). No existing table is altered except an added unique index on `ws_leads` (new table). New tables: executor (2), workspaces (4), ffm (7), consent (2). All RLS-on, service-role only, closed.
- Executor registry stays EMPTY (nothing can run). FF Marketing stays dry-run (CHECK-constrained). The 7 `app_ffm_*` wrappers ship CLOSED: opening them is a separate owner sign-off (`ops/pending_signoff/ffm_open_app_ffm.txt`).
- Effect on the existing bot: `backup_snapshot` changes shape (adds `policy`). The live `hq_backup.py` (`ecadb31`) is dormant (no BACKUP_* variables), so nothing consumes it. Do NOT set BACKUP_KEY/PUT_URL/AUTH (see DATA_CLASSIFICATION_AND_BACKUP_POLICY.md section 7; the known leak paths need an owner decision).

## 3. Before / after checks
- Before: `ops/preflight_executor_ffm.sql` (all BEFORE-OK); record `select count(*) from pg_proc where pronamespace='public'::regnamespace and prokind='f'` (expected 123).
- After: `ops/verify_post_release_executor_ffm.sql` (function count = before + 47 = 170; protected-19 md5 unchanged; inert counts zero; guards behave); `select public.backup_export_policy()` reviewed by the owner (`unclassified` empty, no client table in `exported`); Supabase advisors; dry_run, kill switch, 330c cap and pause state unchanged.

## 4. Rollback (each is tested on scratch databases, in reverse order)
`ops/rollback_ffm_consent_backup.sql` (drops consent log: irreversible loss of consent rows; restores old `backup_snapshot` which exports client data, so no off-site backups while in effect) -> `ops/rollback_ffm_onboarding.sql` -> `ops/rollback_executor_sweep.sql` -> `ops/rollback_executor_ffm.sql`. Take a provider backup first. After a rollback remove the lines from `migrations/APPLY_ORDER.txt` and rebuild `dist/APPLY_ALL.sql`.

## 5. Limits of the evidence
Scratch-database and synthetic tests only (gate 9/9, replica drills, independent adversarial reviews of #5, #7, #8, #11). The 123 live count and "47 new" were derived from the repo and an old baseline file; confirm the live count with the pre-check. Not production proof.
