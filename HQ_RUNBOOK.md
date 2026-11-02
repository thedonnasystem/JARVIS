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
| `hq-reconcile` | every 15 min | Releases stuck spend holds; flags stuck or stale tasks; overdue money, engine down, spend at 80% |
| `hq-heartbeat`, `hq-prune` | daily / weekly | Housekeeping |

## Money safety

- Every model call goes through `reserve_llm_budget`, which enforces the kill switch, the agent's daily cap and the company's daily cap (`system_state.daily_spend_cap_cents`, normally 330 = $3.30). It is settled afterwards with the real cost.
- `/kill` stops every agent instantly and `/resume` restarts them.
- The day for spend runs on Toronto time.

## Owner commands (Telegram)

`/hq` status · `/brief` daily brief · `/due` follow-ups · `/lead name | phone | note | days` · `/done # days note` · `/money in|out amount venture note` · `/ask agent task` · `/agents` · `/leads` · `/drafts` · `/ideas` · `/testidea name` · `/parkidea name` · `/kill` · `/resume`

## Owner rules built into the database

- At most 3 revenue ventures at once (a trigger on `ideas`; the day job does not count).
- Standing decisions live in `memory` (kind `decision`). Approving or rejecting with a button adds one.
- Unverified facts are labeled and never acted on. Auditors only save facts they confirmed from official or primary sources.

## When something breaks

1. **No heartbeat for 20+ minutes:** reconciliation messages the owner. Check the Railway deploy logs and Railway credit.
2. **Tasks stuck in `doing`:** they requeue after a restart or after 15 minutes. Stuck spend holds release after 30 minutes.
3. **Agents not running but the heartbeat is fine:** check the caps. Look at `llm_calls` for today versus `system_state.daily_spend_cap_cents` and `agents.daily_spend_cap_cents`.
4. **Tests:** `python3 -m unittest test_hq test_hq_engine test_hq_commands`
