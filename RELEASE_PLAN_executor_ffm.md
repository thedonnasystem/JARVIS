# Release plan: executor gate + client workspaces (branch build/executor-ffm)
Prepared 2026-11-14 by an independent second review. PLAN ONLY: nothing pushed, merged, applied or deployed. Every gate below is an owner approval.
Code under review: `build/executor-ffm` = `76821d5` + `8f5293c` on `integration/sprint2` `2eda0f0`. Production code = `ecadb31` (its tree is byte-identical to `2eda0f0`: `git diff ecadb31 integration/sprint2` is empty), so the PR diff is exactly the 14 files of the 2 commits. This worktree branch `build/merge-plan` adds only plan/ops/patch files on top.

## 0. What ships, in one table
| Piece | In this release | Effect on production |
|---|---|---|
| `migrations/20261117_executor_gate_v1.sql` | yes (apply) | 2 new tables, 3 new functions. Registry is empty and default-deny: inert. |
| `migrations/20261117_client_workspaces_v1.sql` | yes (apply) | 4 new tables, 5 new functions, 4 triggers on the new tables. Inert (no workspaces). |
| `hq_executor.py`, `hq_workspace.py` + tests | merged, **not imported by `bot.py`** | Dead code on Railway. No behaviour change. |
| `patches/schedule_expire_stale.patch` | **NOT in the PR** (proposed file only) | Would add a 10-minute bot job. Separate later gate. |
| `ops/*_executor_ffm.sql` | read-only/rollback helpers | Run by hand. |
Existing objects touched: **none**. Verified: the two migrations contain no `create or replace`, `alter`, `grant`, `revoke`, `insert`, `update` or `delete` on any pre-existing object, no cron call, and no `system_state`/cap/policy write. The 19 protected functions are not redefined; their md5 on the scratch replica is identical with the executor/workspace objects present, absent (after `ops/rollback_executor_ffm.sql`) and re-applied (`0bdecc95...` on the replica; live must read `a87bfafa3ead42601588b302c0b56d18`).

## 1. Gate A: PR and merge (owner approves each line)
1. Pre-check (read-only): `git ls-remote origin refs/heads/overnight-build` must print `ecadb31327e1c26f1e4db2b30186f02ddffa1c21`. If not, stop and re-review.
2. Owner pushes the branch (I do not): `git push origin build/executor-ffm`.
3. Open PR `build/executor-ffm` -> `overnight-build` (title "Executor gate + client workspaces (inert)"). Required checks: `unit`, `migrations` (both run `scripts/gate.sh --strict`). Expected: green. Diff must be 14 files: `git diff --stat origin/overnight-build...build/executor-ffm`.
4. Merge with a **MERGE COMMIT** (same rule as Gate 1B; not squash, not rebase). `overnight-build` is also the PWA source; no `webapp/` file changes, so the Render republish is a no-op in behaviour.
5. Do NOT fast-forward `claude/telegram-claude-bot-59nusk` (Railway deploy branch). Nothing in this release needs a bot redeploy. Railway stays on its current commit; that is correct.
6. Record the merged sha. Confirm file hashes from the merged commit before Gate B: `git show <sha>:migrations/<file> | sha256sum` must equal section 2.

## 2. Gate B: migrations (owner approves; one file per call; stop at first error, never retry blindly)
Run `ops/preflight_executor_ffm.sql` first (section 3). All rows `BEFORE-OK` or stop.
| Order | `mcp__Supabase__apply_migration` name (PLAN, not called) | Source file | sha256 |
|---|---|---|---|
| 1 | `executor_gate_v1` | `migrations/20261117_executor_gate_v1.sql` | `a8c2763dafdc46f6080c7e8afbf927bcbed6a308fe5ba15440245a6da15b4db6` |
| 2 | `client_workspaces_v1` | `migrations/20261117_client_workspaces_v1.sql` | `4c8c38322cfe026c88ad51335316f5210cb294649e46c6285b6f663b54f837b3` |
| 3 (LAST) | `lockdown_v1` (re-run, idempotent) | `migrations/20261112_lockdown_v1.sql` | `19a474d4e0f6f9bc9941ffe4eeaaf6b318aaeb753b367c3cf8026bf78ab9e92a` (same as in `ecadb31`) |
Notes: 1 and 2 are independent of each other (no cross reference) and each is one atomic call; order follows `APPLY_ORDER.txt`. Step 3 re-asserts the revoke-all/grant-service_role sweep over the new functions and keeps the ledger's last entry `lockdown_v1` (the old convention and what row 9 below expects). The migrations already revoke anon/authenticated/PUBLIC themselves, so there is no window with exposed grants even if step 3 is skipped. Do not apply `dist/APPLY_ALL.sql`. Do not create missions or enable anything between steps.
Why this is safe on the LIVE schema (not only the replica): both files are `create ... if not exists` / `create or replace` / `drop trigger if exists`, so a second run is a no-op (the replica applies every file twice); they reference only `tasks(id uuid, venture_id)`, `system_state`, `audit_log`, `reserve_llm_budget(text,integer,text,text)->uuid`, `settle_llm_call(uuid,integer,text)`, which preflight rows 3-5 prove exist with those types before anything is written. If a same-named object already existed with a different shape, `if not exists` would silently keep it: preflight rows 1-2 require none exist.

## 3. Pre-flight (read-only; Supabase SQL editor)
File: `ops/preflight_executor_ffm.sql` (12 rows, all `BEFORE-OK`). Highlights: new tables/functions absent (0/0); prerequisite column types; spend function signatures; `mission_guard` present (Sprint 1-2 live); no anon/authenticated exposure; protected fingerprint `a87bfafa...`; function count 123; ledger ends `lockdown_v1`; `dry_run / kill=false / focus=off / cap=330 / pause=api_credits`; no AI reservation younger than 10 minutes. Tested on the scratch DB in the pre-state: 12/12 `BEFORE-OK` (live-only rows print `n/a (scratch)`).

## 4. Post-release verification (read-only)
File: `ops/verify_post_release_executor_ffm.sql` (15 rows; PASS/FAIL, `N/A` only on scratch). Run after step 3 and again after any later deploy. It never calls `executor_request` (that writes).
| Row | Check | Expected |
|---|---|---|
| 1 | 8 new functions, nothing else named `executor_%`/`ws_%` | `8 / 8` |
| 2 | 6 tables, RLS on, not FORCE, zero policies | `6 / 0` |
| 3 | anon/authenticated/PUBLIC table grants / EXECUTE on the 8 | `0 / 0` |
| 4 | service_role table privileges / EXECUTE | `SELECT / 8` |
| 5 | definer functions pin `search_path=public`; guard fns not definer | `6 / 2` |
| 6 | `ws_guard` trigger on the 4 workspace tables | `4` |
| 7 | registry rows / enabled / runs / workspaces | `0 / 0 / 0 / 0` |
| 8 | guard behaves (SIN, zero-width via `chr()`, credit+bank, clean text) | `true/true/true/true` |
| 9 | ledger: both names, last = lockdown_v1 (live) | `2 / last=lockdown_v1` |
| 10 | function count 123 + 8 (live) | `131` |
| 11 | protected 19 md5 (live) | `a87bfafa3ead42601588b302c0b56d18` |
| 12 | mode/kill/focus/cap/pause (live) | `dry_run / kill=false / focus=off / cap=330 / pause=api_credits` |
| 13 | capital + policy fingerprints (live) | `30000 / 5000 / 2000 / 10000+100 / 2500 / 7500 / 6ef239a2... / 3db891d4...` |
| 14 | cron + agents (live) | `18 / f6eb1879... / 32 / 951eebac...` |
| 15 | security rows (exec leak / PUBLIC / service_role missing / table grants / RLS off) | `none / none / none / none / none` |
Rows 9-14 evaluate only on the real project. The OLD `ops/verify_post_release.sql` row 2 (`123`) will now read `131` and FAIL by design; use the new file for this release. Any FAIL: stop, report, do not "repair" protected settings.
Also read-only: `select count(*) from audit_log where action like 'executor_%' or action like 'ws_%';` must stay `0` (nothing has run). Then `bash ops/verify_deploy.sh` must still say Railway == deploy branch (unchanged).

## 5. Rollback (`ops/rollback_executor_ffm.sql`)
Order: (1) if the schedule patch was ever deployed, redeploy without it; (2) confirm no executor is enabled / `/kill` if unsure; (3) run the file: refuses while any `executor_runs` row is `running` (settle with `select executor_expire_stale(5)` first), drops only the 8 functions and 6 tables, idempotent; (4) optional ledger cleanup line is in the file comments; (5) re-run section 4 rows 1, 2, 10, 11 (function count back to 123, fingerprint unchanged). Data lost: executor/workspace rows only; `audit_log` rows stay (append-only). Tested on the scratch DB: runs twice with no error; afterwards 0 matching functions and 0 matching tables; objects re-apply cleanly. PR side: `git revert -m 1 <merge sha>` on `overnight-build`.

## 6. Expected vs actual
| Check | Expected | Actual (scratch `mp1`, 2026-11-14) |
|---|---|---|
| `scripts/gate.sh --strict` | 9/9 PASS | 9/9 PASS (see final run in the report) |
| Migrations apply twice, in order, incl. lockdown last | no error | no error (replica + my manual apply/re-apply) |
| Verify SQL on scratch after apply | all non-N/A PASS | rows 1-8 and 15 PASS, 9-14 N/A |
| Verify SQL catches a regression | FAIL on injected `grant select ... to authenticated` | rows 3 and 15 FAIL |
| Preflight on pre-state scratch | 12/12 BEFORE-OK | 12/12 BEFORE-OK |
| Protected-19 md5 with objects present / rolled back / re-applied | identical | identical (`0bdecc95...`, replica build) |
| Rollback twice | idempotent, 0 objects left | idempotent, 0 functions, 0 tables |
| Schedule patch | applies cleanly, tests pass | `git apply --check` OK; 638 repo tests pass with it applied |
| LIVE protected md5 / counts / caps | per section 4 | **not measured**: no production read was made in this review. Measured only at the time the owner runs section 3/4 |

## 7. NOT deployed after this release (still owner-gated)
- Bot wiring: nothing imports `hq_executor` / `hq_workspace`; no executor can be called by Jarvis.
- `executor_expire_stale` is not scheduled. Proposed: `patches/schedule_expire_stale.patch` (a 10-minute `job_queue` job in `bot.py`, separate from `hq_engine.tick` so it keeps working under kill switch / credits pause; quiet no-op when the function is absent; never raises). Apply only with its own PR + Railway deploy approval, and only before any executor is enabled.
- No executor registered or enabled; caps untouched; `pause_reason=api_credits` untouched; no workspace created; no client budget set.
- Agent Swarm / any external executor install, and any real client data (mortgage client) in workspaces.

## 8. Owner checklist (everything that needs you)
1. Approve and run Gate A (push, PR, merge commit). 2. Approve Gate B (3 `apply_migration` calls) after preflight is clean. 3. Run section 4 and send me the table. 4. Decide on the schedule patch (separate gate) and keep the registry empty until it ships. 5. Decide whether client-workspace PII should be in the nightly backup (see finding 5 in the review notes).

## 9. Second-review findings (ranked; none blocks the inert release)
1. MEDIUM, latent: the engine's `_recover_stale()` (hq_engine.py) marks every `llm_calls` row still `reserved` after a bot restart as `released`. An in-flight executor run's reservation then counts 0 against the daily caps until `executor_complete`/`executor_expire_stale` re-settles it (reproduced on scratch: counted 0, then 8 after expire). With nothing scheduled, a hung or restart-interrupted run can hide spend indefinitely. Mitigation: keep the registry empty/disabled until the schedule patch is deployed; consider a shorter `p_minutes` than 60 once executor runtimes are known. Not exploitable while registry is empty and `pause_reason=api_credits`.
2. FIXED (commit after 8f5293c): `ws_sensitive_hits` embedded four invisible literal characters (U+200B, U+200D, U+2060, U+FEFF) in a regex. If any copy/paste or transport strips them the regex degrades to `[-]` and zero-width stripping silently stops. Verify row 8 tests this with `chr()`, so it is caught right after apply. Safer source form would be `​-‍⁠﻿` escapes (not changed here: it would change the approved file hash and bundle).
3. LOW: for a `failed` run `executor_runs.actual_cents` stores the caller's figure while `llm_calls` is charged `greatest(actual, est)`. Spend caps are right; reporting joins will under-state failed-run cost.
4. LOW: refused requests each write an `executor_runs` and an `audit_log` row and `purpose` is unscreened (documented); a looping caller could bloat both. service_role-only, so a trust issue, not exposure.
5. LOW: `backup_schema()` enumerates tables dynamically, so `ws_leads` (client name/email/phone) will enter the encrypted off-site backup when backups are enabled. Decide deliberately.
6. INFO: old `ops/verify_post_release.sql` row 2 expects 123 functions; after this release it reads 131 and fails by design (section 4).
7. INFO: scratch replica grants all table privileges to anon/authenticated by default (mirrors Supabase defaults); both migrations revoke explicitly, and verify rows 3/4/15 prove 0 anon/authenticated grants on the new tables. Live defaults must be confirmed by the owner's preflight row 7.
8. Cleared: advisory lock 7331 is re-entrant with `reserve_llm_budget`'s (no deadlock); `settle_llm_call` is a plain update (no error on an already-released row); no existing function/grant/cron/policy/cap is altered; lockdown ordering is safe with either order because the new objects self-revoke.
