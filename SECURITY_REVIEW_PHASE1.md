# Self-review of the Phase 1 changes (security, financial, operational)
Reviewed 2026-11-12 against the diff of PR #1. "Fixed" items were found during this review and corrected in the PR.

## Fixed during review
| # | Finding | Severity | Fix |
|---|---|---|---|
| 1 | `hq_meter.reserve` (owner chat path) treats unrecognised gateway errors as "run unmetered". A focus-mode or mission-budget refusal has neither "cap" nor "paused" in its text, so it would have let the call through, unmetered | High (financial) | Those two messages are now hard blocks (tightening only); unit-tested |
| 2 | A backlog TASK assigned to the chat agent could have used the chat exemption to bypass focus mode | High | Exemption applies only to non-task purposes; e2e-tested |
| 3 | A mission-budget refusal made `_work_tasks` pause the whole board every tick (it never clears) | High (operational) | The mission's task is stopped with the reason; the board continues; tested in unit and real-DB integration |
| 4 | A `blocked` draft task would have held its dedupe key forever, silently ending drafting for a venture | Medium | Key covers todo/doing only; 12 h cool-down kept; new circuit breaker (max 3 draft tasks/venture/day); e2e-tested |
| 5 | Step limit counted evaluation/verification tasks as steps and could be dodged by a model-chosen title | Medium | Tasks carry a database `mission_role`; unknown counts as a step (fail-safe); strict vs per-attempt allowance |
| 6 | `_check_budget` continued when spend could not be read (fail-open) | Medium | Now stops advancing that mission for the tick |
| 7 | New engine on an un-migrated database would crash the tick (selecting `focus_mission`) | Medium | Tolerated with a fallback select; tested |
| 8 | A step-limit refusal handler could mislabel any HTTP 400 | Low | Only the database's own "step limit" message blocks the mission |

## Residual risks (not changed; owner should know)
- **Pre-existing fail-open in the meter:** other unrecognised gateway errors on the owner-chat path still run unmetered (design choice to avoid outages). Not changed because it is a policy decision.
- **Credit probe** (`_credits_back`) is a direct 1-token call outside the gateway (<1 cent/hour while paused).
- **Owner-initiated paths are not blocked by focus mode:** Telegram chat (metered, `jarvis-chat` cap 150c/day, separate from the mission), the `/build` SDK builder (recorded after the fact) and voice. They are not backlog but do spend from the company daily cap.
- **`hq-run` edge function** (`verify_jwt` false) is guarded by a constant-time service-role bearer check and spends only through `reserve_llm_budget`, so focus mode and mission budgets bind it too. It is not called by anything today.
- **Owner identity is a string:** `set_focus_mission(p_by)` and similar functions trust a caller-supplied `owner%` label, like the existing `activate_venture`. Only the service role can call them (anon/authenticated revoked, re-asserted by lockdown). Anyone holding the service key already has full control.
- **Audit detail** includes the first 300 characters of the triggering SQL; it can contain task text. The audit table is service-role only and pruned at 90 days.
- **Migration drift:** the repo holds only the Nov 12 migrations; 30 earlier live migrations (Nov 2–11) exist only in the live ledger and the replica capture. `ops/live_functions_baseline_20261112.txt` pins every function body (md5) so drift is detectable.
- **Default privileges:** functions created by role `supabase_admin` get anon/authenticated EXECUTE by default. Everything created through the SQL/migration path runs as `postgres` and is safe; `ops/verify_live.sql` detects a leak.
- **Single-owner approval:** no branch protection exists; one person approves, merges and deploys.

## Financial controls: unchanged or tightened only
No limit, cap, threshold or policy value is raised. Additions refuse more (mission budget, focus mode, step limit, duplicate drafts). `dry_run`, the kill switch, capital controller, permission engine and outbox rules are untouched. Protected files changed: `hq_meter.py` (tightened, see finding 1) and `migrations/` — flagged for explicit owner review.

## What the tests prove and do not prove
Proved: SQL behaviour of every new trigger/function on a faithful copy of the live schema, run twice; the real Python mission/engine code against that database (full 4-step mission, budget stop, focus isolation, cleanup, no external send); rollback restores live definitions byte-for-byte; 240 unit tests; CI green on the PR.
Not proved: the real model's output format (scripted in tests), PostgREST itself (a test adapter stands in), Railway/Supabase behaviour after deploy, Telegram delivery of alert messages. The first live mission is the first test of those.

## Pre-deployment audit additions (2026-11-12, second pass)
9. **Lifetime step ceiling had a hole.** The step trigger ignored cancelled steps, so in a strict mission a *paid* step could be cancelled and replaced (pause then resume), allowing more than `max_steps` paid steps over the mission's life. Fixed: in a strict mission a cancelled step keeps its slot if it ever spent (`llm_calls`). Tested (`lifetime_ceiling_ok`).
10. **Unmetered paths, listed explicitly (all pre-existing, none added by Phase 1).** `test_spend_paths.py` now fails the build if a new direct model call appears.
    - Owner chat when the kill switch is ON, or when the database is unreachable or returns an unrecognised error: runs unmetered by design ("the control channel never goes dark"). A cap, pause, focus or mission-budget refusal is always a hard block.
    - `/build` and its plan phase (Claude Agent SDK): owner-only and approval-gated, no pre-spend check against the kill switch, focus mode or caps, and no per-session dollar ceiling. Cost is recorded after the fact. **Owner decision needed:** add a gateway pre-check and `max_budget_usd`? Not changed here because it alters the owner's own tooling.
    - Hourly 1-token credit probe while paused for credits (not while the kill switch is on): at most 24 calls/day at under 0.01 cent each.
    - Voice transcription (OpenAI, off until `OPENAI_API_KEY` is set) is a different vendor and outside the Anthropic gateway.
11. **Default privileges for `supabase_admin`** still grant EXECUTE on new functions to anon/authenticated (the migrations alter only the migration role's defaults). Functions created through the Supabase dashboard SQL editor under that role would be exposed until `lockdown_v1` is re-run. Mitigation: re-run lockdown after any dashboard-created function; `ops/verify_live.sql` detects it.
12. **The repository is public.** Secret scan of the working tree and all 141 commits found no keys or tokens (only a placeholder in README and the Supabase *publishable* key in `webapp/app.js`, which is designed to be public and is safe only because RLS is on and all non-allowlisted functions are revoked). Business logic, prompts and system URLs are visible to anyone.
