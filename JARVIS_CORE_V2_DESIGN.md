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
| GitHub label by the owner account (`owner-approved-<head sha12>`) | Kept, but counts only when its actor is `owner_login`, which must not be an agent account or the PR author (RVJC B1: fails closed today). Bound to the head SHA; checked in issue events (actor) and still on the PR |
| GitHub APPROVED review by the owner on `commit_id == head` | **Chosen** for PRs from Jarvis's machine account. One tap in GitHub mobile |
| Signed approval file (owner GPG/SSH key) | Rejected: secure but not one tap |
Both chosen markers are forgeable by anyone holding the owner's GitHub credentials, so `hq_selfedit.setup` refuses a token whose login is the owner.
Detection limits: copies / renames below 50 % similarity are not linked to the protected source; SQL is matched by name + write verb per line (a statement split across lines or built dynamically can pass). The judge files and every migration are path-protected, so the realistic bypass is a disguised edit of an unprotected Python file: such PRs still need reading.
CI wiring: one step appended to the `unit` job (`permissions: pull-requests: read` added to that job only), triggers `labeled/unlabeled` and `pull_request_review` added so an approval re-runs CI. No existing step changed. This workflow edit is itself protected: it needs the owner's release approval.

## B. Queue semantics
Lease = `for update skip locked`, urgency order critical > urgent > normal > low; expired leases are reclaimed (event `reclaimed`); only the lease holder may finish; failure -> `run_after = now + min(30 s x 2^(attempt-1), 1 h)`; `dead` after `max_attempts`. Dedupe on an open job's `dedupe_key`. Divisions outside `active_divisions` are refused at enqueue (dormant).
Wakes: Jarvis (plain-code handlers) never wakes; model work wakes the division agent with `<kind>: <payload.reason>`; the agent drains its own queued jobs and sleeps on: queue empty / 2 failures in a row / 10 jobs. Both events append-only with jobs done and cost.

## C. Provider rotation
Order `JARVIS_LLM_ORDER` (default groq, cerebras, openrouter, github, nvidia, selfhost, gpu, anthropic). Eligible = configured AND (not training OR owner opt-in) AND (not paid OR `jarvis_self_fund_status().paid_allowed`) AND (not client data OR `client_data_ok`). Per attempt: in-memory rpm / rpd / tpm check, reserve at the gateway (0 cents for free), call, settle; 429 or transport error -> cool-down (Retry-After or 30 s doubling to 1 h) and next provider. All exhausted -> `AllProvidersExhausted`; the worker reports the job failed and the queue retries it with backoff (dead after max_attempts). Free-tier prompts are limited to about 6k tokens; hard limit 90k.

## D. Deploy topology and activation proposal
- `overnight-build` -> Render PWA redeploys on every commit. `claude/telegram-claude-bot-59nusk` (default branch) -> Railway bot redeploys on every push.
- Jarvis auto-merges only into `jarvis/integration` (`FORBIDDEN_BASES` + `jarvis/` prefix rule). Promotion is an owner-approved PR into `overnight-build`, then the documented fast-forward of the Railway branch (DEPLOY_RUNBOOK.md). Note the CI workflow already runs on pushes to `jarvis/**`.
- Rollback: `post_deploy_check(health, open_revert, previous_sha)`, wired as the `release.check` job (payload `previous_sha`): `open_revert` = an owner_messages decision for the owner's one-tap approval; a changelog / alert failure never reverts a healthy release (Render: redeploy previous; Railway: move the branch back). A fully automatic revert of a deploy branch needs a separate owner decision because it is itself a protected-branch write.

## Expected vs actual (local, scratch Postgres 16 on 127.0.0.1:5701, Nov 16 2026)
See the final report of this build for counts; `sqltests/jarvis_core_check.sql` J1-J16 cover: dormant defaults, owner-only switches, dormant divisions, dedupe, kill switch stops leasing, urgency order, lease ownership, backoff 30 s, dead-letter, reclaim, append-only (update/delete/truncate), ACLs, call limit/dedupe/criteria/no numbers, large-tier single use, seed dedupe + audit without content, retrieval limit, cost meter / report, the $10 design cap through the real gateway, automation candidates exclude protected classes, backup classification, self-funding, wake/sleep.

## E. Fix-up after independent review RVJC (Nov 16 2026)
| Finding | Now |
|---|---|
| B1 forgeable approval | `owner_login` must not be in `agent_logins` nor the PR author; the label counts only when its latest `labeled` actor is `owner_login` (and not an agent / the author). Methods configurable (`approval.methods`). Today owner and agents share one account, so the gate FAILS CLOSED until the owner decision (second account, repo moved into an org he owns, agents' account Write only, rulesets without bypass: OWNER_GUIDE section 4). |
| B2 PR judges itself | `.github/workflows/protected-paths.yml` on `pull_request_target` (+ `edited`): the BASE branch's checker and config judge the PR's commits as data (no PR code runs). The unit job also checks the base out separately (`_trusted/`). Diff against the CURRENT base (`origin/<base ref>` fetched fresh; the run fails if the PR's base or head moved). Pushes to protected branches FAIL unless they are exactly the merge of an approved PR. Bootstrap: the PR that introduces the checker is judged by its own copy once (stated in the log); it fails closed anyway. |
| B3 bypasses | New top-level modules, packages named like protected modules, any `__init__.py`, `sitecustomize` / `usercustomize` / `.pth` / `conftest.py`, deploy configs, `.gitattributes` / `.gitmodules`, unscanned file types, module patching lines (`hq_x.attr = ...`, `setattr`, `sys.modules`, `__import__`, `exec`), `++` lines, statements split over up to 4 lines or glued from string pieces, `EXECUTE` dynamic SQL, `U&` identifiers, `rpc(...)` writes; `--text` diff so `-diff` attributes cannot blind it; `hq_core.py`, `hq_channels.py`, `hq_seed.py`, `hq_skills.py` and every `test_*.py` protected. Self-edit mode `ops/SELF_EDIT_MODE` (allowlist default, denylist kept). |
| B4 self-edit | Review of `compare/<base sha>...<head sha>` (whole diff, refused over 60k chars), exactly one final VERDICT line, same model id = not independent; merge only if head == reviewed sha (`sha` pinned in the merge call); all PR file pages (refused over 300 files); author stage refuses `# ? % \ ..`, control characters and (allowlist) anything outside the zone; contents URLs percent-encoded; `protected-paths` is a required check. |
| B5 client data | `hq_llm.route_class(sources, texts)`: public only if every source is on the code-only `PUBLIC_SOURCES` and hq_scrub finds no personal data; else only catalog `client_data_ok` providers. Memory rows tag their kind; `jarvis_memory_search` returns `owner_profile` only for `p_destination = 'selfhost'` and matches any word. Extra providers can never be `client_data_ok`. |
| B6 crash loops | `jarvis_lease` dead-letters an expired lease at `max_attempts` (sqltest: 40 expiries -> dead after 2). `LEASE_SECONDS = 900` (> 600 s slowest timeout) and the worker calls `jarvis_extend_lease` before every provider attempt. |
| B7 call criteria | `jarvis_call_criteria` (seeded from `ops/CRITICAL_EVENTS.json`, a test keeps them equal); `jarvis_call_allowed` ignores the caller's boolean; unlisted events are `refused_criteria` and never count toward the limit. |
| B8 money | `mission_guard` / `mission_spent_cents` also parse `jarvis:<division>:<mission uuid>:...` (unknown mission refused); `complete(tier="large")` consumes the single-use approval itself; extra providers cannot reuse a catalog name, a paid vendor host, paid / GPU metering; `JARVIS_LLM_PRICES` cannot override a catalog model. `choose_tier` and `cached_complete` are used by the worker; `MissionGuard` and `complete_or_queue` were dead code and are deleted. |
| S1-S10 | list content / tool schemas / non-ASCII counted; cache-creation tokens counted; paid timeouts and malformed answers settle at the estimate; no redirects (one no-redirect opener), credentials / link-local / metadata hosts refused; `jarvis_require_owner` = `is_app_owner()` only; self-funding needs an exact amount match and stops counting when unmatched / changed; `post_deploy_check` never reverts on a changelog failure and never raises; automation filter by category word (DB and Python); `jarvis_seed_memory` owner-only in SQL (bot stages, owner applies); `EmergencyCall.call` never raises. |
| "sir" | One helper: `hq_core.address` via `reply_to` / `send_to` (all 100 `reply_text` and 14 `send_message` calls in bot.py / hq_commands.py, owner chat only) and `hq.deliver_owner_messages` (every owner_messages row, whichever module or SQL function wrote it). Message edits of buttons (`edit_message_text`, status edits) keep their wording. |

Residual (stated): a copy of a protected module under a new non-top-level name that nothing imports yet; table names built from variables across more than 4 lines; the AST sandbox for skills is defence in depth; the bootstrap PR; `pull_request_review` events still re-run `tests.yml` (not the trusted job).

