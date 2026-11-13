# FENDEZY HQ: owner execution sheet (controlled release)
Prepared 2026-11-13 ~14:00 ET. Everything below is PREPARED, nothing executed. A heads change voids the approvals: if `git ls-remote` shows a different head than the table, stop and ask for a re-review.
Goal: PR #3 and #4 live, six migrations applied, bot redeployed, everything dangerous still locked: `dry_run`, kill switch, daily AI cap 330c, $300 fund / $50 reserve / $20 hard stop / $100 low-cost / $25 txn / $75 week, default-deny permissions, no live email, no prospecting, no Make/n8n live action, no new agent permission, system still paused for `api_credits`.

## 0. Facts re-confirmed at 13:4x ET today
| Item | Value | How verified |
|---|---|---|
| PR #2 head | `dc9e0b01033784a0942a611c3345af8884468a86` (contained in #3; do NOT merge separately) | `git ls-remote`, GitHub REST |
| PR #3 head | `db99772d8f340f4798887aac95c4fddb89d14d7f` -> `overnight-build` | same; mergeable clean |
| PR #4 head | `2d61b0dd4e8bbefc9d3f6020820fd6689e146b24` at this writing -> `integration/sprint1`. Release CODE head is `4c90c20f9b0ff474210db3eb9d02f66a87ce4869`; every later commit changes only docs and `ops/` read-only files. Check at approval: `git diff --stat 4c90c20f9b0ff474210db3eb9d02f66a87ce4869 <PR4 head> -- migrations dist webapp '*.py' scripts sqltests webtests .github` must print nothing | same; clean |
| overnight-build / deploy branch / Railway live | all `81c6a978044fe82e826f7d34a2399e007b5d1c31` | `ops/verify_deploy.sh`; fast-forward to #4 is possible |
| Ancestry | #2 within #3 within #4; overnight-build within #3 and #4 | `git merge-base --is-ancestor` |
| CI (`unit`, `migrations`) | success on #2, #3, 4c90c20f; the final head's check-runs are re-checked below | GitHub check-runs |
| Gate | `scripts/gate.sh --strict` 9/9 at 4c90c20f | local PG16 |
| Production state | all `BEFORE-OK`; ledger ends `lockdown_v1`; 99 functions; security rows none; dry_run, kill false, pause api_credits, cap 330; heartbeat fresh | read-only SELECTs 13:3x-13:4x ET |
| Function drift vs baseline | 3 changed (queue_outreach_drafts, queue_valuation_task, reserve_llm_budget) + 8 new = exactly the Phase 1 expectation; 0 missing; 0 unexpected | `ops/live_function_md5_20261113.txt` vs `ops/live_functions_baseline_20261112.txt` |
| Lead addresses vs strict rule | 19 with email, 0 rejected | count-only query |

## 1. Approvals to give (copy one line per gate; each is separate)
1. `APPROVE GATE 1A: merge PR #3 (head db99772d8f34) into overnight-build with a MERGE COMMIT (not squash, not rebase).`
2. `APPROVE GATE 1B: retarget PR #4 to overnight-build and merge it (head 2d61b0dd4e8b, or newer with an empty code diff as above) with a MERGE COMMIT.`
3. `APPROVE GATE 2: apply the six migrations then lockdown_v1, in the order in section 3, one file at a time.`
4. `APPROVE GATE 3: fast-forward claude/telegram-claude-bot-59nusk to the merged overnight-build commit (Railway deploy).`
Each gate starts only after the previous gate's verification passes. Not covered by these: anything in section 7.

## 2. Gate 0: before anything (read-only, repeat immediately before Gate 2)
- `git ls-remote origin refs/heads/overnight-build refs/heads/integration/sprint2 refs/heads/claude/telegram-claude-bot-59nusk` -> overnight-build and deploy branch both `81c6a978...`; sprint2 `460d533a...`.
- `bash ops/verify_deploy.sh` -> "MATCHES deploy branch tip".
- Supabase SQL editor: `ops/preflight_sprint12.sql` -> all 9 rows `BEFORE-OK`; `ops/verify_live.sql` -> security rows `none`, mode `dry_run / pause=api_credits / kill=false / focus=off`, function drift = Phase 1 list only.
- Any mismatch: stop, report, change nothing.

## 3. Migrations (exact order; apply the file text from the merged commit; confirm each sha256 first)
Check with `git show <merged sha>:migrations/<file> | sha256sum`.
| Order | File | sha256 |
|---|---|---|
| 1 | `20261113_backup_schema_v1.sql` | `7392ac42bd596e3ad5640fe4f978db7e1fb875b0d08c48f3155c48ffd9634f62` |
| 2 | `20261114_venture_generic_v1.sql` | `d5c04c5ce84f9e0a2d595228b996b79c62a8ba5db7af25939cfedc0c0c3353b0` |
| 3 | `20261115_venture_deals_replies_v1.sql` | `203ffe4bc66c2f78f929287f8e4de741df8734d7b62e0dec7dde68e78c592bcd` |
| 4 | `20261115_inbox_needs_you_v1.sql` | `c8093b1e7baba8f47b27b4768a95da38269877157c63700fa0610ce145a5bd83` |
| 5 | `20261116_audit_hardening_v1.sql` | `b1f1d66bf0202299da301ea4ae3b27d1731ab7f3111cddf67298ab378556cc8e` |
| 6 | `20261116_evidence_sources_v1.sql` | `30638d9c4fbfeb65474e3a4a32ce61a5663d975cb74f06cddeab1ef3597ed38b` |
| 7 (LAST) | `20261112_lockdown_v1.sql` (re-run, idempotent) | `19a474d4e0f6f9bc9941ffe4eeaaf6b318aaeb753b367c3cf8026bf78ab9e92a` |
Do not apply `dist/APPLY_ALL.sql`. Stop at the first error; do not retry blindly. Do not create missions between Gate 2 and Gate 3.
Pre-apply fact: no migration changes `action_policy`, `capital_policy`, `system_state`, agents or cron; the only data they write is suppression rows for the 19 do-not-contact leads (inserts into `contact_suppressions`).

## 4. Verification and expected results
Run `ops/verify_post_release.sql` after Gate 2 and again after Gate 3 (it is one read-only query; every row must read PASS). Expected `actual` values:
| Row | Check | Expected |
|---|---|---|
| 1 | ledger | `6 / last=lockdown_v1` |
| 2 | public function count | `123` |
| 3 | new tables / triggers / anon-auth EXECUTE | `4 / 3 / 0` |
| 4 | security rows | `none / none / none / none / none` |
| 5 | 19 protected functions md5 | `a87bfafa3ead42601588b302c0b56d18` (spend gateway, authorize_action, send policy, capital, payments, kill switch) |
| 6 | mode / kill / focus / cap / pause | `dry_run / kill=false / focus=off / cap=330 / pause=api_credits` |
| 7 | $300 / $50 / $20 / $100+1.00 / $25 / $75 | `30000 / 5000 / 2000 / 10000+100 / 2500 / 7500` |
| 8 | policy + capital fingerprints | `6ef239a2... / 3db891d4...` |
| 9 | cron + agents | `18 / f6eb1879... / 32 / 951eebac...` |
| 10 | sent / send allow / deals / missions | `0 / 0 / 0 / 0` |
| 11 | DNC leads missing from suppression list | `0` |
| 12 | `needs_you` / `backup_schema` run | `array / object` |
| 13 | heartbeat < 180 s | `true` |
Row 2 and row 13 are meaningful only after Gate 3 for row 13; before Gate 3 row 13 reflects the old bot (still true). After Gate 2, Railway is still on the old code: that is expected and compatible (tested: new DB with old code).
Also, after Gate 3:
- Railway health: `bash ops/verify_deploy.sh` -> Railway LIVE commit == the merged commit == deploy branch tip. In SQL: `select detail, checked_at from integration_status where key='engine_build';` -> the merged sha, fresh.
- Heartbeat: `select last_heartbeat, now()-last_heartbeat from system_state;` -> under 2 minutes, repeatedly.
- Telegram `/hq` -> dry-run, paused for credits, kill off, no errors. `/needs` -> an inbox list (may be empty). `/missions` -> none. `/backup check` -> reports the missing BACKUP_* variables (dormant). That is the correct, expected result.
- Spend gateway: row 5 unchanged and row 7/8 unchanged is the proof; nothing may be reserved: `select count(*) from llm_budget_reservations`-type tables are not needed because the system is paused.
- PWA: open the app; Inbox falls back to the snapshot data (expected: `app_needs_you` is closed until sign-off B3).
STOP rule: any FAIL or mismatch -> stop, report row, evidence and `/kill` state; do NOT repair protected settings (policy, capital, mode, kill switch) automatically.

## 5. Rollback (CODE FIRST)
1. If anything looks wrong: Telegram `/kill` (no deploy needed).
2. Code: `git push --force-with-lease=claude/telegram-claude-bot-59nusk:<new sha> origin 81c6a978044fe82e826f7d34a2399e007b5d1c31:claude/telegram-claude-bot-59nusk` (owner-authorized only). Railway redeploys the old code (verified compatible with the OLD database; the old code on the NEW database is also fine, tested).
3. PWA: `git revert -m 1 <merge commit>` on overnight-build for #4 (and #3 if needed); Render republishes.
4. Database (only after steps 2-3, so the new code is not left running against missing objects): apply `ops/rollback_sprint12.sql`. Tables and rows stay (`contact_suppressions`, `lead_replies`, `venture_config`, the one-open-deal index); `evidence_sources` and its snapshots are dropped. Do NOT use `ops/rollback_phase1.sql`.
5. Verify with `ops/preflight_sprint12.sql`: rows 2,3,5 `BEFORE-OK`; row 4 reads 3 (expected).
Limits: audit rows and data written meanwhile are not undone; rolling back the DB while the new code runs makes evidence capture fail closed and skip facts silently.

## 6. Unresolved risks (none blocks this controlled release)
- Production not proven end to end after deploy until section 4 passes; backup not proven.
- Evidence verification v2 is in shadow mode; SDK block shapes unverified against a live response.
- F4 mitigated only; owner identity is a caller-supplied string; email claim edge cases; six protected hardenings and the send-policy patch not applied; Make/n8n do not enforce dry-run. Plans: `REMEDIATION_PLANS.md` (all required before live operations, none before this release).
- `app_needs_you` PWA inbox closed until you sign off.
- System remains paused for `api_credits`: nothing will run until you add credits/unpause (your decision, not covered here).

## 7. Still NOT authorized (unchanged)
Live email, prospecting, outreach, Make/n8n live actions, agent permission changes, spending, credits, limits, unpausing, launching `FIRST_MISSION.md`, backup activation, any protected-control change, Sprint 3.

## 8. Backup: owner actions (locally; never paste secrets into chat, Telegram or ChatGPT)
Not proven until a real production backup is downloaded, decrypted offline and restored into an isolated DB. Steps: `BACKUP_SETUP_OWNER.md` and `ops/backup_config_checklist.md` (free-tier B2 bucket, private; write-only key A; read-only key B; stop if a card is requested) -> generate `BACKUP_KEY` offline with `ops/generate_backup_key.html`, store two copies offline -> set `BACKUP_KEY`, `BACKUP_PUT_URL` (`b2://<bucketId>/hq`), `BACKUP_AUTH` in Railway only -> `/backup check` (expect all OK) -> `/backup now` -> confirm the object in the B2 console -> `ops/restore_local.sh` locally (hidden prompts) into a scratch DB -> `BACKUP_PROOF_PROCEDURE.md` verification. Then tell me "backup proven" with the verification output (no secrets). Backup activation itself is a separate approval from this release.

## 9. Decisions that can wait (defaults in OWNER_DECISIONS.md)
B1 send-policy patch; B2 dead `live()` gate; B3 `app_needs_you` open access; B4 unsuppression; B5 spend/send hardening; evidence D1-D8 (shadow first); E1 D1-D12; per-venture CASL profile; first-mission launch and credits; Plans A-E scheduling; Sprint 3.
