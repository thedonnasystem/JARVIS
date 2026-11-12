# Release process: approval, merge, migrations, deploy, rollback
Written 2026-11-12 from what was observed on the live accounts. Nothing here was executed against production.

## 1. How the three systems actually deploy (observed)
| System | Trigger | Evidence |
|---|---|---|
| Render `fendezy-hq-app` (static PWA, publishes `webapp/`) | **Any commit to `overnight-build`** deploys automatically (`autoDeploy: yes`, trigger `commit`). Other branches do not deploy; PR previews are off | Render API service record; deploy list shows one deploy per commit on overnight-build and none for `phase1-repair` pushes |
| Railway service `JARVIS` (the Jarvis bot + engine), env `remarkable-exploration / production` | **Any push to `claude/telegram-claude-bot-59nusk`** (also the repo's default branch). Other branches do not deploy | Railway reports each deploy to GitHub: deployments `7748709172 … a3d7d7d`; none for `phase1-repair` |
| Supabase `ihxzvpwbqydqtblvazbq` | **Manual only**. No workflow applies migrations. CI applies them to a scratch Postgres only | `.github/workflows/tests.yml`; ledger `list_migrations` |

Consequences:
- Merging a PR into `overnight-build` publishes the PWA. It does not touch Railway or Supabase. If the PR changes nothing under `webapp/`, the publish is a no-op.
- Railway is deployed by moving the deploy branch. Nothing else moves it.
- There is no branch protection on any branch (re-checked 2026-11-12: `protected: false` on all six branches). Optional hardening, needs owner approval: protect `claude/telegram-claude-bot-59nusk` (require PR + passing checks), and set a Render build filter to `webapp/**` so non-web merges do not redeploy.

## 2. The four gates (each is a separate, explicit authorization)
1. **Approve**: owner approves the PR. Required before anything below. CI (`unit`, `migrations`) must be green; it also runs the replica end-to-end, the real-engine integration run and the rollback drill.
2. **Merge** to `overnight-build`: publishes the PWA only. Safe to do alone.
3. **Migrate**: apply the migrations to Supabase in the order in section 3. Must come BEFORE the Railway deploy.
4. **Deploy**: fast-forward the Railway deploy branch to the merged commit.
After each gate, run the verification in section 4. Do not start gate N+1 until gate N verifies.

## 3. Exact production procedure for Phase 1 (needs the owner's go-ahead for gates 2–4)
Pre-flight (read-only, safe any time):
```
ops/verify_deploy.sh                       # Railway live commit vs branch tips (GitHub deployments API)
# Supabase: run ops/verify_live.sql (read-only). Expect every security row = none, mode dry_run, pause api_credits, focus off.
# Supabase: run ops/preflight_live.sql (read-only). Proves the migrations will apply cleanly on live data and that lockdown_v1 is a no-op on current privileges.
#   Expected on 2026-11-12: no duplicate drafts; none of the new columns/objects present; triggers = build_requests:build_rules, missions:missions_lifecycle;
#   function md5s equal the baseline; lockdown_would_revoke = none; lockdown_would_grant_service_role = none; policies = none; grants = postgres + service_role only.
```
Any difference from those expectations means production changed since the audit: stop and re-review before gate 3.
Gate 2: merge PR #1 into `overnight-build`. Render redeploys (webapp unchanged).
Gate 3: apply, in this order, via `apply_migration` (which also writes the migration ledger, closing the `lockdown_v1` gap):
1. `20261113_phase1_repair_v1.sql`
2. `20261113_mission_guard_v1.sql`
3. `20261112_lockdown_v1.sql`  (re-run LAST; idempotent; records `lockdown_v1` in the ledger and re-asserts privileges on the new functions)
Then run `ops/verify_live.sql` and check: security rows all `none`; drift vs `ops/live_functions_baseline_20261112.txt` equals `ops/EXPECTED_NEW_FUNCTIONS.txt` (3 changed, 8 new, `enforce_build_rules` unchanged); `to_regclass('integration_status')` exists.
Do not start or create missions between gate 3 and gate 4 (old code does not tag mission tasks with a role, so evaluation/verification would count as steps).
Gate 4: `git push origin <merged sha>:claude/telegram-claude-bot-59nusk` (fast-forward only; never force). This is a fast-forward only if `overnight-build` still equals `a3d7d7d` plus the merge; check with `git merge-base --is-ancestor a3d7d7d <merged sha>`. A squash or merge commit both qualify. Then `ops/verify_deploy.sh` must report `Railway LIVE commit == deploy branch tip`, and `ops/verify_live.sql` `integrations` must show `engine_build ... commit <first 12 of the sha>` within ~10 minutes (the bot writes it every tick). The `ALERT: HQ is paused: Anthropic credits are out` message will arrive once; that is expected while credits are out.

Compatibility (tested): new code on the OLD database keeps the engine alive (focus_mission column missing → tolerated; integration_status missing → warning only; missions stay inert until migrated). New database with the OLD code is safe except the mission-role note above.

## 4. Verification after each gate
| Gate | Check | Expected |
|---|---|---|
| Merge | Render `list_deploys` for `fendezy-hq-app` | newest deploy `live` at the merge commit |
| Migrate | `ops/verify_live.sql` | security rows `none`; md5 drift = expected list; `mode_and_pause = dry_run / pause=api_credits / kill=false / focus=off` |
| Deploy | `ops/verify_deploy.sh`; `integration_status.engine_build` | live commit == tip; engine_build shows the same sha; `system_state.last_heartbeat` < 2 min old |

## 5. Rollback
Order matters; each step is independent and idempotent.
1. **Stop spending first (if anything looks wrong):** Telegram `/kill` or the app kill switch. This is the existing kill switch; it needs no deploy.
2. **Code (Railway):** move the deploy branch back: `git push --force-with-lease=claude/telegram-claude-bot-59nusk:<bad sha> origin a3d7d7d:claude/telegram-claude-bot-59nusk` (a3d7d7d = last known good). Railway also offers "Redeploy" on the previous deployment in its dashboard. Verify with `ops/verify_deploy.sh`.
3. **Database:** apply `ops/rollback_phase1.sql`. It clears focus mode, removes the alert cron job, drops the Phase 1 triggers and functions, and restores `reserve_llm_budget`, `queue_outreach_drafts` and `queue_valuation_task` to their exact Nov 12 definitions (md5-verified in CI by the rollback drill). Then re-run `20261112_lockdown_v1.sql` and `ops/verify_live.sql`. Added columns, tables and unique indexes are left in place (inert; dropping them would delete data; optional drops are commented in the file).
4. **PWA (Render):** `git revert` the merge commit on `overnight-build` and push, or redeploy the previous Render deploy.
What a rollback does not undo: audit rows, alert messages and any missions/tasks created while Phase 1 was live (they are data).

## 6. Branch hygiene going forward
- Work only on `phase*/` or `jarvis/**` branches; they deploy nothing.
- The only commands that change production are: merge to `overnight-build` (PWA), `apply_migration` (database), push to the deploy branch (bot). Each is its own gate.
