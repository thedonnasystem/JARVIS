# Fendezy HQ runbook

Fendezy HQ is a company of AI agents that works its own task board. Jarvis (this Telegram bot) is the only agent that can contact the owner. The company runs in **dry-run**: agents research and draft, but nobody is contacted, nothing is signed and no money is spent beyond the AI bill.

## Where things live

| Piece | Where |
|---|---|
| Bot + engine | Railway project `remarkable-exploration`, service JARVIS. It auto-deploys from GitHub branch `claude/telegram-claude-bot-59nusk`. |
| Company database | Supabase project `fendezy-hq`. Tables are locked with row-level security; the bot uses the service key. |
| Bot variables | `HQ_SUPABASE_URL`, `HQ_SUPABASE_SERVICE_KEY`, `ANTHROPIC_API_KEY`, `TELEGRAM_BOT_TOKEN`, `JARVIS_OWNER_ID`, `CLAUDE_MODEL` |

## Code

- `hq.py`: the database bridge, plus delivery of owner messages (every 60 s) with Approve/Reject buttons when a decision is needed.
- `hq_engine.py`: the engine, which ticks every 5 minutes. Each tick:
  1. Checks the kill switch.
  2. Writes a heartbeat.
  3. Requeues orphaned work. On the first tick after a restart this happens immediately and releases spend holds.
  4. Runs up to 3 tasks. Each one reserves budget through the spend gateway, then gets one agent turn with web search for researchers and auditors.
  5. Saves the outputs (see below).
  6. Triages escalations.
- `hq_commands.py`: the owner's Telegram commands.

### What happens to an agent's output

| Output | Goes to |
|---|---|
| Any research task | A prediction row (finished? sourced?) and an independent audit task |
| Auditor `FACTS:` lines | `memory` as facts (official source URL, 90-day expiry). A `VERDICT: FAIL` becomes a lesson. |
| Researcher `LEADS:` lines | `leads` (status new, do-not-contact until a consent basis exists) |
| Idea-lab `IDEA:` lines | `ideas` (status new, auto-scored) |
| `Draft outreach…` tasks for a `*-division` agent | `outbox` drafts plus one ping to the owner. They are reviewed with /drafts and are never sent automatically. |
| Jarvis `Daily planning…` | Up to 3 new tasks (queue capped at 8) |
| Jarvis weekly review `PROPOSAL:` lines | Up to 3 owner messages with Approve/Reject |
| A line starting `ESCALATE` | Task goes to `blocked`, an escalation is opened, and Jarvis triages it (close, or one short message to the owner) |

Every task prompt includes the venture's **company knowledge** (recent facts, decisions and lessons), so agents build on earlier work.

## Scheduled jobs (pg_cron, UTC)

| Job | When (Toronto) | What |
|---|---|---|
| `daily-planning` | 7:00 | Jarvis plans the day |
| `hq-followups-0815` | 8:15 Mon–Sat | Sales follow-ups due today |
| `hq-brief-2300utc` / `hq-brief-0000utc` | 6pm / 7pm | Daily brief |
| `weekly-self-review` | Sun 8pm | Weekly review and proposals |
| `hq-queue-drafts` | :07 and :37 | When a venture has 3+ emailable new leads, queues one "Draft outreach" task for its GM |
| `hq-reconcile` | every 15 min | Releases stuck spend holds; flags stuck or stale tasks; overdue money, engine down, spend at 80% |
| `hq-prune` | Sun 3am | Removes audit log and agent-run rows older than 90 days |
| `hq-heartbeat` | off | Old fake heartbeat, switched off. Only the engine writes the heartbeat now, so "engine down" alerts are real. |

## Money safety

- Every model call goes through `reserve_llm_budget`, which enforces the kill switch, the agent's daily cap and the company's daily cap (`system_state.daily_spend_cap_cents`, normally 330 = $3.30). It is settled afterwards with the real cost.
- `/kill` stops every agent instantly and `/resume` restarts them.
- The day for spend runs on Toronto time.

## Owner commands (Telegram)

`/hq` status · `/brief` daily brief · `/due` follow-ups · `/day dials pitches submissions` · `/paid name` · `/lead name | phone | note | days` · `/done # days note` · `/money in|out amount venture note` · `/ask agent task` · `/agents` · `/leads` · `/drafts` · `/sent code` · `/systems` · `/ideas` · `/testidea name` · `/parkidea name` · `/kill` · `/resume`

## The Donna money loop

1. A researcher finds shops and records each one's **published business email**. Under CASL that gives implied consent if the site has no "no unsolicited messages" notice. Leads without such an email stay do-not-contact.
2. Once 3 or more emailable leads exist, `hq-queue-drafts` queues a draft task. Donna's GM writes short emails using the offer saved in memory (AI receptionist, $297–397/mo plus $250 setup; call to action: free strategy meeting).
3. Moe gets one ping. He runs `/drafts` and taps **Approve** on each, and Jarvis replies with the exact email to send.
4. Moe sends it, then `/sent <code>`. The lead is marked contacted and a 3-day follow-up appears in the 8:15am list.

## Rooms (each system stays separate; HQ watches and supports)

| Room | System | How HQ connects |
|---|---|---|
| Real estate | Deal funnel (Render + GitHub Actions + Supabase `wholesale-pipeline`) | Reads `hq_valuation_candidates()`. The researcher values the best unvalued fixers (search + page fetch) and writes AI ARV fields via the funnel's `rows_merge`. The funnel judges them with its own opportunity rules and shows comp links. Off until `WHOLESALE_SUPABASE_SERVICE_KEY` is set. `hq-value-fixers` runs at 9:45am and 4:45pm. |
| Donna | Leads, drafts and outbox in HQ; Retell/Twilio/Cal.com outside | `hq-donna-prospects` runs daily at 10:15am. It rotates Ontario markets and trades, and skips when 15+ emailable leads are waiting. Drafts are queued automatically. |
| Day job | Dialer and call coach (Render) | Health checked and woken at 7:50am. The follow-up tracker lives in HQ. |
| Company | Jarvis + engine (Railway) | Heartbeat, plus reconciliation alerts. |

`/systems` shows each one's last health check. The registry lives in the `systems` table.

## Messages to the owner

- **Quiet hours:** 10pm–7am Toronto. Only `emergency` messages are delivered at night; everything else waits until 7am.
- **Scheduling:** `owner_messages.deliver_after` holds a message until a set time (used for the 7am morning brief).
- **Decisions:** `contract` and `proposal` messages carry Approve/Reject buttons. Approving `set_cap:<cents>` changes the daily cap (hard ceiling $20); approving `pause_venture` pauses that venture's agents.

## Company knowledge

Every task gets the venture's decisions and lessons first (up to 20), then its 10 newest facts, then 5 company-wide facts. Decisions can never be pushed out by a pile of facts. (On Nov 2 that had happened: drafts came out with `[OFFER]` placeholders, and the engine now drops any draft with a placeholder.)

## Sales scoreboard

`/day 280 6 2` logs today's dials, pitches and submissions against the targets in `dayjob_targets` (250, 6, 2 a day; 5 paid deals a week). `/paid` adds a paid deal and $1,000 revenue to the ledger. The daily brief shows the week so far.

## Results rule

The daily planner must give every task an `expected_cad` and a `days_to_cash`, or the task is discarded. Cash within 14 days runs first.

## Owner rules built into the database

- At most 3 revenue ventures at once (a trigger on `ideas`; the day job does not count).
- Standing decisions live in `memory` (kind `decision`). Approving or rejecting with a button adds one.
- Unverified facts are labeled and never acted on. Auditors only save facts they confirmed from official or primary sources.

## When something breaks

1. **No heartbeat for 20+ minutes:** reconciliation messages the owner. Check the Railway deploy logs and Railway credit.
2. **Tasks stuck in `doing`:** they requeue after a restart or after 15 minutes. Stuck spend holds release after 30 minutes.
3. **Agents not running but the heartbeat is fine:** check the caps. Look at `llm_calls` for today versus `system_state.daily_spend_cap_cents` and `agents.daily_spend_cap_cents`.
4. **Tests:** `python3 -m unittest test_hq test_hq_engine test_hq_commands`

## Missions (Mission Manager v1, Nov 12 2026)

A mission is a broad objective HQ pursues on its own across ticks, restarts and nights. State lives in
`missions` + `tasks.mission_id` (same task queue, same spend gateway). Code: `hq_missions.py`, run every tick by
`hq_engine.tick_sync` (database-only, no model calls of its own).

Lifecycle (enforced by the `missions_lifecycle` trigger):
CAPTURED → EVALUATED → PLANNED → EXECUTING → VERIFYING → COMPLETED, plus BLOCKED / PAUSED / REJECTED / ABANDONED / FAILED.
- Evaluate: the venture's researcher returns `MISSION_VERDICT: GO|TEST|DEFER|REJECT`, `NUMBERS`, `SUCCESS`, `RISKS`, `STEP:` lines.
  DEFER/REJECT stop the mission and tell the owner why.
- Execute: plan steps become `Mission: …` tasks, one new step per tick, max 3 open per mission. Steps are research/drafting only
  until the permissions engine (Phase 4) exists. Real-estate house sourcing steps are dropped (funnel's job).
- Verify: an agent that did none of the steps returns `VERIFIED: YES|NO`, `EVIDENCE: claim | source`, `GAP:` lines.
  COMPLETED is impossible without evidence (database trigger). NO → re-plan with the gaps; 3 failed verifications → FAILED.
- Guards: max 5 live missions; AI budget per mission (default 200c CAD, max 1000c) measured from `llm_calls`, over budget → PAUSED
  and queued steps cancelled; blocked step → mission BLOCKED, owner told once; Task Brief questions wait instead of blocking;
  no progress for 48h → owner told once, mission stays open.
- Mission steps skip the per-task auditor and NEXT chains (the mission verifier replaces them).

Owner: say a goal in chat ("I want to start X") → Jarvis calls `hq_create_mission`. Commands: `/missions [all]`,
`/mission <id>`, `/mission new <objective>`, `/mission pause|resume|abandon <id>`, `/mission budget <id> <cents>`.
The 7pm brief has a Missions section.

Security (Nov 12): Jarvis chat answers only JARVIS_OWNER_ID; anyone else gets one line and no model call.
Migrations: `migrations/20261112_missions_v1.sql`, then `migrations/20261112_brief_missions.sql`.

## Bank (Section 10, manual-first)
- Migration `20261112_bank_v1.sql` (after capital_v1). Tested on a local Postgres 16: balance cap, owner-only guard, CSV re-import dedupe, one-to-one reconcile.
- `/bank balance 412.50` records the real RBC balance. Spendable cash = lowest of ledger and bank (minus reservations and unsettled spend).
- Send an RBC CSV export to the bot with caption `bank`: rows are imported, de-duplicated, matched to the ledger and to settled spend. `/bank unmatched` lists the gaps.
- Daily alert (once/23h) for stale balance (>7d), unmatched rows older than 3 days, ledger above bank, balance under the reserve floor.
- Only the last 4 account digits are kept. No credentials, ever. Payments stay with the owner in RBC.

## Proactive initiative (Section 12)
- Migration `20261112_org_v1.sql`: `org_changes` (every proposal with gain, cost, time to results, risk, alternative, disagreement), `agent_scorecard` (7-day cost vs finished work, flags idle/spending-with-nothing-done/failing), and a weekly review prompt that asks for those fields.
- Jarvis's weekly `PROPOSAL:` lines now carry `kind | gain | cost | time | risk | alt | disagree`. Old 4-field lines still work.
- Approve on a proposal opens a mission for it (budget, evidence and verification apply); Reject closes it and is remembered as an owner decision.
- Nothing here lets an agent spend or commit beyond limits: external commitments and money still go through approvals and the capital controller.

## Venture factory (Section 11)
- Migration `20261112_ventures_v1.sql` (tested on local Postgres 16: slug rules, inert-until-owner, stage gates need evidence, workspace JSON, kill).
- "Start a new venture" in chat (tool `hq_start_venture`) or `/venture new Name | what it does`: creates the venture INACTIVE (manager paused, own department, budget ceiling capped at $50/month by the database), opens a validation mission under Idea Lab (planning only, independent verifier), and sends you one Approve card.
- Approve (or `/venture activate <slug>`) wakes the manager inside a 25c/day cap. Only the owner can activate; stages move one gate at a time with evidence (`set_venture_stage`); kill pauses everything.
- On activation the manager is queued a first task (30-day operating plan, planning only), then a weekly review every Monday (skipped when the venture is over budget).
- `/venture <slug>` shows the workspace: stage, budget used, money, agents, leads, goals. The engine skips tasks of a venture that used its monthly budget (retries next day).
- Not built yet: venture-specific tools/websites and the sandboxed self-dev environment (needs a repo-per-venture decision and your approval of the deploy path).

## Learning loop (Phase 7, no model spend)
- Migration `20261112_learning_v1.sql` (tested on local Postgres 16). Every 6 hours a completed mission whose `days_to_cash + 7` days have passed is measured once: expected CAD vs cash RECEIVED in that venture since completion (approximate attribution, and the lesson says so).
- Result lands in `mission_outcomes` and as a `lesson` in memory, which every agent prompt already reads (hit / partial / miss / no_forecast, with advice to discount optimistic forecasts).
- `forecast_bias_text()` feeds the weekly review so Jarvis sees whether past forecasts held.

## Holding company and earn-your-keep
- Migration `20261112_holding_v1.sql` (after org_v1; tested locally). `/pnl [days]` and the app's Money tab show per-venture and total P&L: received cash only, intercompany excluded, company-level AI cost counted as overhead; signed/qualified pipeline and forecasts are shown apart and never added to cash.
- Every Monday the review flags agents older than 14 days that spent 50+ cents and finished nothing, or cost over 3x the median per finished task. Each becomes a 'shutdown' proposal with Approve/Reject. Approve pauses that one agent (reversible); Jarvis himself is never flagged. Nothing is paused without your tap.

## Self-development (Section 11), pull requests only
- `hq_dev.py` + chat tool `hq_propose_code_change`. Needs `GITHUB_TOKEN` (fine-grained, this repo only, contents + pull requests) and `GITHUB_REPO` on Railway; without them it says "not set up".
- Dependencies: a PR that edits requirements.txt is refused unless every package is on the approved list in `hq_dev.APPROVED_DEPS` (no git or URL installs). Add a package by editing that list yourself.
- Jarvis branches off the base branch, commits 1-5 files (60 KB max each), opens a PR. He cannot merge or push to the deploy branch. You merge; Railway redeploys; rollback is reverting the PR.
- Refused outright: secrets (key patterns scanned), `.env`, key files, path traversal. PRs touching money/permissions/spend/bank/migrations/requirements are labelled PROTECTED in the PR body.
- Tests must pass before you merge. Next step when you are ready: a GitHub Action that runs the tests on every `jarvis/*` branch and posts the result on the PR.

## Organizational growth (Section 12)
- Migration `20261112_agents_v1.sql` (after org_v1). Chat tools `hq_create_department` / `hq_create_agent` ("create a marketing department"). Limits live in the database: cheap/standard tier, cap 50c/day max, cannot contact you, max 3 new agents per rolling week, created ASLEEP if all active agent caps would exceed 3x the daily company cap. Each creation is logged in `org_changes` (built) and `audit_log`.
- Strong tier, owner contact, bigger caps, external commitments: always you.


## Payments (manual approval, spec section 10)
- Jarvis prepares a payment (`hq_prepare_payment`): the capital controller reserves the funds first (per-transaction and weekly limits, minimum reserve, bank balance cap).
- You get an Approve/Reject card. Approve means: pay it yourself in RBC.
- Then `/pay done <id> <amount> <RBC reference>` (or the Money tab, I paid it). The amount cannot exceed what was approved. The ledger records the expense; the bank statement import matches it later.
- Unanswered requests expire after 3 days and approved-but-unpaid after 14 days past due; reserved funds are released.
- `/pay` lists open payments. Jarvis never holds credentials, never sees an authenticated bank session, never moves money.
