# Executor sweep release (branch build/executor-sweep) - NOT merged, NOT applied, NOT deployed
Prepared 2026-11-14. Base: local `build/merge-plan` (ade994a; PR #6 release plan on top of PR #5 `build/executor-ffm`). `origin/build/merge-plan` does not exist on the remote (the branch was never pushed), so the local branch was used. Nothing pushed.
**This is a SEPARATE release from PR #5.** The executor registry stays EMPTY until it ships (owner decision). PR #5 migrations are untouched (`20261117_executor_gate_v1.sql` sha256 `a8c2763d...` and `20261117_client_workspaces_v1.sql` `4c8c3832...` unchanged).

## 1. What changed
| File | Change |
|---|---|
| `migrations/20261118_executor_sweep_v1.sql` (new, sha256 `0367f6724978bc8c3e89987057a7b801bb84396656c4415d331ce3f178d76166`) | (a) trigger `llm_calls_executor_guard` + function (security definer, search_path=public, revoked from public/anon/authenticated): a reserved `llm_calls` row that belongs to a `running` executor run cannot be moved to `released`/`failed`; (b) partial index on `executor_runs(llm_call_id) where status='running'`; (c) `executor_complete` re-created: failed run `actual_cents` = charged amount (finding 3); same signature, security definer, search_path, revoke/grant |
| `migrations/APPLY_ORDER.txt` | new file listed after `client_workspaces_v1`, before `lockdown_v1` (still last) |
| `hq_engine.py` `_recover_stale` | belt and braces: the startup release excludes `llm_calls` ids of running executor runs (`id=not.in.(...)`); table missing (400/404) = release as before; run list unreadable = release nothing and retry next tick (fail closed, over-counts spend, never under-counts) |
| `hq_executor.py`, `bot.py`, `test_hq_executor_schedule.py` | `patches/schedule_expire_stale.patch` applied: 10-minute `hq-executor-expire` job, separate from `hq_engine.tick` (works under kill switch / credits pause), never raises, quiet no-op if the function is absent. 4 more tests added (survives errors and recovers, idempotent, no kill/pause dependence, 400 quiet) |
| `sqltests/executor_sweep_check.sql` (new) | defect repro + fix + restart scenario + sweep + finding 3 + security properties (S0-S14, F1-F4, P1-P6) |
| `test_hq_engine.py` | 3 tests for the restart exclusion |
| `ops/rollback_executor_sweep.sql` (new) | removes trigger/function/index, restores the original `executor_complete` text (md5 verified identical to gate-only), refuses while a run is `running`, idempotent |
| `ops/EXPECTED_NEW_FUNCTIONS.txt`, `dist/APPLY_ALL.sql` | regenerated (+1 function: `llm_calls_executor_guard()`) |
Unchanged: `executor_request`, `executor_expire_stale`, `reserve_llm_budget`, `settle_llm_call`, all caps, kill switch, `pause_reason` (still `api_credits`), the 19 protected functions. No executor registered.

## 2. Defect and fix, expected vs actual (scratch DB `sw1`)
Defect: on the first tick after every bot start `_recover_stale` ran `update llm_calls set status='released' where status='reserved' and started_at < cutoff`; a running executor run's reservation then counted 0 in `reserve_llm_budget`'s daily totals.
| Check | Expected | Actual |
|---|---|---|
| Failing test first: `sqltests/executor_sweep_check.sql` before the migration | fails at S1 | `ERROR: S1 restart recovery released a running executor reservation (status released)` |
| Same test after the migration | passes | passes (psql exit 0) |
| Restart scenario: request -> simulated `_recover_stale` (twice) | reservation stays `reserved`; daily total counts 5; with company cap = 5 a 1-cent reserve is refused | S1, S3, S4, S5 pass |
| Ordinary orphan (non-executor) reservation at restart | still released | S2, S13 pass |
| `executor_expire_stale` after restart | settles at full reservation (`done`, 5), run `expired` 5; second call 0 | S6-S9b pass |
| Legacy run already wrongly released | swept and charged in full | S11 pass |
| Bad row (dangling `llm_call_id`) | sweep processes both rows, no error | S12 pass |
| Failed run `executor_runs.actual_cents` | = charged `greatest(actual, est)` (5 for actual 2, est 5; 9 for actual 9) | F1-F3 pass; `done` runs keep caller figure (F4) |
| Security: executor_complete definer + search_path + no anon/authenticated/PUBLIC + service_role execute; guard fn not exposed | as before | P1-P6 pass |
| `sqltests/executor_gate_check.sql` (all prior guarantees E1-E36) | passes | passes |
| Python: `python3 -m unittest test_hq_engine test_hq_executor test_hq_executor_schedule` | pass; the 2 restart tests fail without the fix | pass; 2 failures confirmed with `hq_engine.py` stashed |
| `scripts/gate.sh --strict` | 9/9 | **9/9 PASS** (unit, scripts-tests, lint R1-R6 0 errors, bundle, appcheck, webjs, replica, manifest, backup) |
| Rollback (`ops/rollback_executor_sweep.sql`) twice, then `executor_complete` md5 | idempotent; md5 = gate-only text | idempotent; `9e16fd04...` = `9e16fd04...` |
Limitations: replica only (not production). The simulated `_recover_stale` is the same SQL statement with the cutoff widened to "now+1s" so the test does not depend on wall-clock age or the Toronto day boundary. PostgREST behaviour against real Supabase is unproven (a BEFORE UPDATE trigger returning NULL skips that row silently; the `return=minimal` PATCH still succeeds; confirmed only in Postgres). The bot job was tested with mocks, not a live Telegram job queue. Overall: PASS on the scratch evidence, nothing proven in production.
Residual behaviour to know: a running reservation also survives `ops`/manual attempts to release it (by design); an executor that never completes is charged its full estimate after `p_minutes` (min 5, default 60) by the sweep, so keep estimates honest.

## 3. Owner approval steps (a separate release; I do none of these)
Prerequisite: PR #5 released first (its Gate A + Gate B) or in the same sitting, but the registry stays empty through all of it.
1. Gate A2 (code): push `build/executor-sweep`, open a PR into `overnight-build` (after PR #5/#6 merged, or stacked on them), required checks `unit` + `migrations` green, merge with a MERGE COMMIT. Confirm `git diff --stat` = the 12 files of the commit (section 1 plus these notes).
2. Gate B2 (migration, after the two PR #5 migrations are live): run the read-only preflight (`ops/preflight_executor_ffm.sql`) if not already done; confirm `select count(*) from executor_registry` = 0 and `select count(*) from executor_runs where status='running'` = 0; then ONE `apply_migration` named `executor_sweep_v1` from `migrations/20261118_executor_sweep_v1.sql` (sha256 above); then re-run `20261112_lockdown_v1.sql` last as before (idempotent). Do NOT apply `dist/APPLY_ALL.sql`.
3. Post-apply read-only checks: function count 123+8+1 = 132 (the old `verify_post_release_executor_ffm.sql` row 1/10 expect 8/131 and will read 9/132: update expectation, do not "repair"); `select tgname from pg_trigger where tgrelid='public.llm_calls'::regclass and not tgisinternal` returns `llm_calls_executor_guard`; protected-19 md5 unchanged (`a87bfafa...`); anon/authenticated cannot execute `executor_complete` / `llm_calls_executor_guard`; caps, mode, kill switch, `pause_reason` unchanged.
4. Gate C (Railway deploy of the bot with the 10-minute job): deploy only after Gate B2 (without the function the job is a quiet no-op, so order is safe either way). After deploy, logs must show `hq-executor-expire` registered and no errors; "executor_expire_stale is not installed" must NOT appear after B2.
5. Spending/limits/credits/pause: nothing in this release touches them; do not clear `pause_reason` as part of it.
Rollback: (1) `/kill` if unsure; (2) Railway redeploy of the previous commit removes the job; (3) `select executor_expire_stale(5)` then run `ops/rollback_executor_sweep.sql` (refuses while a run is running); (4) `git revert -m 1 <merge sha>`. Rolling back reopens finding 1: registry must be empty/disabled.

## 4. Conditions to enable the first executor (all must hold; each is an owner decision)
1. PR #5 and this release are live and the section 3 post-apply checks are clean; the 10-minute job has run at least once (a log line or a harmless `executor_expire_stale(5)` returning 0).
2. Re-run `sqltests/executor_sweep_check.sql` is only a scratch proof: do one live dry run first. Mode `dry_run` makes `executor_request` reserve nothing and return `dry_run` (proves the path with zero spend).
3. A restart drill on a non-production copy or in dry_run is acceptable evidence; do not restart the production bot with a live running executor run as a test.
4. `pause_reason=api_credits` is still set by the owner; clearing it, raising caps, or adding credits is a separate owner approval and is not part of this release.
5. Register exactly one executor, by the owner (the bot cannot insert into `executor_registry`), with: `enabled=false` first, `allowed_agents` one agent, `max_cents_per_run` small (e.g. 10), `max_runs_per_day` small (e.g. 2). Enable only after the dry run passes. Keep `p_minutes` of the sweep longer than the longest honest run (60 by default).
6. First real run is supervised: check `select * from executor_runs order by created_at desc limit 5` and `llm_calls` for status/actual, confirm `executor_runs.actual_cents` equals what `llm_calls` charged.
7. Independent of this release and still open: finding 5 (client workspace PII entering the encrypted off-site backup when backups are turned on) needs a deliberate owner decision before any real client data is stored.
