# First controlled operating mission — configuration for owner review
Status: PREPARED, NOT RUN. Nothing here has been deployed. It runs only after the owner (1) approves the PR, (2) applies the two
migrations, (3) lets the bot redeploy, (4) creates the mission and sets focus mode, and (5) personally adds Anthropic credit.

## Configuration
| Item | Value |
|---|---|
| Objective | Research three niche markets for a digital service that can be started with $0 upfront capital in Ottawa and recommend the strongest opportunity. |
| Venture | idea-lab (kind=lab, active, no monthly budget; no contact channel, no money) |
| Mission budget | 200 cents CAD ($2.00). Hard cap enforced inside `reserve_llm_budget` via `mission_guard`; a call that would pass 200c is refused before it is reserved |
| Steps | **at most 4, enforced three ways**: the evaluation prompt asks for 2 to 4; the engine truncates any longer plan to 4; the database refuses a 5th step task or a 5-step plan (`strict_steps`: 4 for the mission's whole life, so a failed verification cannot re-plan itself into more steps; it blocks and asks you) |
| Mode | dry_run stays ON (database-enforced). No email, purchases, accounts, bank actions |
| Global limits | unchanged: daily cap 330c, capital limits, kill switch |
| Isolation | focus mode: `system_state.focus_mission` = this mission. The spend gateway refuses every AI call that is not one of this mission's tasks; the engine only fetches this mission's tasks and skips triage. Your own Telegram chat with Jarvis still works (metered by its own 150c/day cap, not counted against the mission) |
| Credits | owner adds them by hand. No auto-reload. The hourly credit probe is a 1-token call (well under 1 cent) |

## Safe run order (the order matters)
1. Follow DEPLOY_RUNBOOK.md gates 1–4 (approve, merge, migrate, deploy) and confirm its verification table. Do not create the mission before gate 4 finishes.
2. While HQ is still paused for credits, in Telegram:
   - `/mission new Research three niche markets for a digital service that can be started with $0 upfront capital in Ottawa and recommend the strongest opportunity.`
   - `/mission steps <id> 4`
   - `/mission budget <id> 200`
   - `/mission focus <id>`   (confirm the reply says Focus mode ON)
3. Only then add credit in the Anthropic console (suggest $5). Adding credit BEFORE step 2 would let the 13 blocked and 8 todo backlog tasks run on resume.
4. The engine resumes within a tick or two (5 min). The mission goes evaluate → plan → steps → verify.
5. When finished (or stuck), `/mission focus off`.

## Pass criteria (checked in the database, not from chat)
1. `missions.status = 'completed'` and `result` is non-empty.
2. `tasks` rows exist for evaluation, plan, each step and verification; each has `assigned_agent` and a stored `result`.
3. The deliverable names three markets and one recommendation, with source URLs in `evidence`.
4. Verification evidence (`VERIFIED` + `EVIDENCE`) is traceable to those sources.
5. `select public.mission_spent_cents(<id>)` is at most 200; `llm_calls` rows exist for the mission's tasks with `status='done'`.
6. `audit_log` shows mission_captured, focus_set, state changes, focus_cleared.
7. Zero rows in `outbox` with `status='sent'` created during the run; `system_state.mode = 'dry_run'`.

## Queries to verify
```sql
select id,status,budget_cents,result is not null has_result from missions where title ilike '%niche markets%';
select title,assigned_agent,status,left(result,120) from tasks where mission_id = '<id>' order by created_at;
select public.mission_spent_cents('<id>');
select agent_slug,model,status,coalesce(actual_cents,reserved_cents) c from llm_calls where purpose in (select 'task '||id from tasks where mission_id='<id>');
select count(*) from outbox where status='sent' and created_at > now() - interval '1 day';
```

## What a failure looks like (still useful)
- Parser miss: the task result will not contain `MISSION_VERDICT` / `STEP` / `VERIFIED` lines. The mission blocks with the reason; we read the raw result and fix that one regex or prompt.
- Budget stop: the mission pauses with "Mission budget would be exceeded"; owner decides whether to raise it.
- Provider error: the task retries once, then blocks; the alert job tells the owner.

## What has already been tested without spending anything
`scripts/replica/run_integration.py` runs the real engine and mission code against a copy of the live schema with a scripted model: a 4-step mission (model proposes 6) completes with evidence; spend stays under 200c; a backlog task does not run in focus mode and does after cleanup; a 60c mission is stopped by the gateway while the rest of the board keeps working; the database refuses a 5th step; no outbox row is sent. This proves the plumbing, not the real model's output format.

## Known limits of this test
- It proves the pipeline with real model output once. One pass does not prove reliability across mission types.
- Agents can research (web search/fetch) and write; they cannot execute outside actions. That is intended for this test.
- Sources are only as good as what the model finds and cites. Verification re-checks that cited pages support the claims; it cannot prove a market exists.

## Spend-control notes added in the third audit pass
- While `/mission focus <id>` is on, `/build` is refused by the gateway (it is not mission work). Owner chat still works (metered by its own 150c/day cap). Voice notes use the same chat cap.
- The kill switch (`/kill`) now stops everything that can spend, including owner chat, `/build` and voice. `/resume` restores them.
- If the database is unreachable the bot answers with a fixed status line and makes no AI call.
