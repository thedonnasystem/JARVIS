# Jarvis core v2: engineering notes

Branch `build/jarvis-core` (from `integration/rc1`). Everything dormant. Owner-facing summary: `OWNER_GUIDE_JARVIS_V2.md`.

## Reused, not duplicated
| Need | Reused | New |
|---|---|---|
| Spend control | `reserve_llm_budget` / `settle_llm_call` via `hq_meter._reserve_cents`, `mission_guard`, caps, kill switch | agent `jarvis-core` (seeded PAUSED); purposes `jarvis:<division>:<mission>:<class>:<provider>` |
| Owner messages | `owner_messages` + `hq.deliver_owner_messages` (Telegram), `deliver_after` | `hq_core.send_owner` (quiet hours), `hq_channels` |
| Scheduler | python-telegram-bot `job_queue` in `bot.py` (via `hq_commands.register`) | worker every 30 s and `run_daily` 07:00, only with `JARVIS_CORE=1` |
| Memory | `public.memory` | kind `owner_profile`, FTS index, `jarvis_memory_search`, `jarvis_seed_memory` |
| Self-development | `hq_dev.check_files` (secrets, blocked paths, approved deps) | `hq_selfedit` pipeline |
| Owner identity in SQL | `is_app_owner()` | `jarvis_require_owner()`: PWA owner, or a direct (SQL editor) session that is not an API role |

## A. Approval marker: options considered
| Option | Verdict |
|---|---|
| Owner-signed approval row in the production DB, tapped in Telegram | Rejected: CI would need a database secret; the bot holds the service key and could write the same row |
| GitHub label by the owner account (`owner-approved-<head sha12>`) | **Chosen** for PRs opened from the owner's account (GitHub forbids self-review). Bound to the head SHA; checked in issue events (actor) and still on the PR |
| GitHub APPROVED review by the owner on `commit_id == head` | **Chosen** for PRs from Jarvis's machine account. One tap in GitHub mobile |
| Signed approval file (owner GPG/SSH key) | Rejected: secure but not one tap |
Both chosen markers are forgeable by anyone holding the owner's GitHub credentials, so `hq_selfedit.setup` refuses a token whose login is the owner.
Detection limits: copies / renames below 50 % similarity are not linked to the protected source; SQL is matched by name + write verb per line (a statement split across lines or built dynamically can pass). The judge files and every migration are path-protected, so the realistic bypass is a disguised edit of an unprotected Python file: such PRs still need reading.
CI wiring: one step appended to the `unit` job (`permissions: pull-requests: read` added to that job only), triggers `labeled/unlabeled` and `pull_request_review` added so an approval re-runs CI. No existing step changed. This workflow edit is itself protected: it needs the owner's release approval.

## B. Queue semantics
Lease = `for update skip locked`, urgency order critical > urgent > normal > low; expired leases are reclaimed (event `reclaimed`); only the lease holder may finish; failure -> `run_after = now + min(30 s x 2^(attempt-1), 1 h)`; `dead` after `max_attempts`. Dedupe on an open job's `dedupe_key`. Divisions outside `active_divisions` are refused at enqueue (dormant).
Wakes: Jarvis (plain-code handlers) never wakes; model work wakes the division agent with `<kind>: <payload.reason>`; the agent drains its own queued jobs and sleeps on: queue empty / 2 failures in a row / 10 jobs. Both events append-only with jobs done and cost.

## C. Provider rotation
Order `JARVIS_LLM_ORDER` (default groq, cerebras, openrouter, github, nvidia, selfhost, gpu, anthropic). Eligible = configured AND (not training OR owner opt-in) AND (not paid OR `jarvis_self_fund_status().paid_allowed`) AND (not client data OR `client_data_ok`). Per attempt: in-memory rpm / rpd / tpm check, reserve at the gateway (0 cents for free), call, settle; 429 or transport error -> cool-down (Retry-After or 30 s doubling to 1 h) and next provider. All exhausted -> `AllProvidersExhausted` -> `complete_or_queue` enqueues a low-urgency batchable job and returns the plain message. Free-tier prompts are limited to about 6k tokens; hard limit 90k.

## D. Deploy topology and activation proposal
- `overnight-build` -> Render PWA redeploys on every commit. `claude/telegram-claude-bot-59nusk` (default branch) -> Railway bot redeploys on every push.
- Jarvis auto-merges only into `jarvis/integration` (`FORBIDDEN_BASES` + `jarvis/` prefix rule). Promotion is an owner-approved PR into `overnight-build`, then the documented fast-forward of the Railway branch (DEPLOY_RUNBOOK.md). Note the CI workflow already runs on pushes to `jarvis/**`.
- Rollback: `post_deploy_check(health, revert, previous_sha)`; proposed `revert` = open a revert PR for owner approval (Render: redeploy previous; Railway: move the branch back). A fully automatic revert of a deploy branch needs a separate owner decision because it is itself a protected-branch write.

## Expected vs actual (local, scratch Postgres 16 on 127.0.0.1:5701, Nov 16 2026)
See the final report of this build for counts; `sqltests/jarvis_core_check.sql` J1-J16 cover: dormant defaults, owner-only switches, dormant divisions, dedupe, kill switch stops leasing, urgency order, lease ownership, backoff 30 s, dead-letter, reclaim, append-only (update/delete/truncate), ACLs, call limit/dedupe/criteria/no numbers, large-tier single use, seed dedupe + audit without content, retrieval limit, cost meter / report, the $10 design cap through the real gateway, automation candidates exclude protected classes, backup classification, self-funding, wake/sleep.
