# FENDEZY HQ — Current State Audit

Audited: Nov 11, 2026 (evening, Toronto). Read-only inspection, with one exception: the daily brief fix noted in "Broken", made earlier that day.
Method: read the code, ran the tests, queried the live HQ and wholesale databases, read the deployed edge function, and ran the Supabase security advisor.
Each claim below is tagged **[verified]** (I saw it in code, data or a test run) or **[unverified]** (I couldn't reach it, so this is an inference).

---

## 1. What I can access

| System | Access | Notes |
|---|---|---|
| Jarvis repo (`/home/claude/jarvis`) | Full | The `fendezy-hq-integration` branch is identical to the Railway deploy branch `claude/telegram-claude-bot-59nusk` (0 ahead, 0 behind). 73/73 tests pass **[verified]** |
| HQ database (Supabase `ihxzvpwbqydqtblvazbq`) | Full SQL + migrations | 28 tables, 11 cron jobs, 21 functions, 1 edge function (`hq-run`) **[verified]** |
| Wholesale database (Supabase `ojjxtdapusncwdrdybhy`) | Full SQL | `pipeline` 8,492 rows, `buyers` 0, `api_tokens` 1 **[verified]** |
| Wholesale repo (`canada-wholesale-pipeline`) | Full | Flask webapp, scraper, GitHub Actions |
| Dialer / call coach repo | Full | Call-coach knowledge base |
| Retell dashboard | Through the owner's Chrome | Hvacciana agent |
| FENDEZY Station | Claude artifact | Reads HQ through the Supabase connector |
| Railway | **No direct access** | Uptime inferred from the engine heartbeat (last beat Nov 12 04:34 UTC) **[unverified: env vars, plan, cost]** |
| Render | Tool connected, workspace not selected | **[unverified: service health]**. Scraper data is fresh (Nov 11) |
| Anthropic billing | No access | The out-of-credit state is shown by API errors |

---

## 2. Actual architecture

```
Moe ⇄ Telegram ⇄ Jarvis bot (Railway, python-telegram-bot, bot.py 2,480 lines)
                   │  chat: Claude + tools (research/content/ops/social agents, n8n, Make,
                   │        Google Calendar, Bitwarden vault, HQ tools: status/search/assign_task)
                   │  /build: Claude Agent SDK coding session in a workspace folder (owner only)
                   │  bot memory + chat history: Railway Postgres (DATABASE_URL)  ← 2nd memory store
                   │
                   ├─ hq.py           delivers owner_messages (quiet hours, buttons)
                   ├─ hq_commands.py  /hq … /nightshift, decision + answer callbacks
                   ├─ hq_engine.py    tick every 5 min: heartbeat → night shift → credit pause
                   │                   → recover stale → system checks → triage → ≤3 tasks
                   ├─ hq_systems.py   systems registry health checks
                   └─ hq_wholesale.py bridge to the deal funnel (dormant: key not set)
                          │
                          ▼
HQ Supabase: tasks · memory · leads · outbox · ideas · ledger · ventures · departments · agents(31)
             llm_calls (spend gateway) · audit_log · predictions · escalations · owner_messages
             systems · tool_registry(0) · accounts_registry(0) · build_requests · human_handoffs · deals(0)
             RLS on every table, no policies, no anon grants = service key only
             cron: planning, drafts, prospects, valuations, reconcile/15m, briefs, weekly review, prune
             edge fn hq-run: one gated agent turn (service-key auth, constant-time compare)

Wholesale: GitHub Actions scrape → Supabase `pipeline` → Flask app (Render) → ARV engine + AI valuation lane
Station:   Claude artifact → Supabase connector → station_snapshot()
```

---

## 3. What works [verified]

- **Spend gateway.** `reserve_llm_budget` takes an advisory lock and checks the kill switch, agent status, the per-agent daily cap and the company daily cap (330¢). It reserves before every engine call and `settle_llm_call` records the actual cost. Cost is estimated from `model_prices` (USD per million tokens), so **caps are in USD cents**. `usd_to_cad` = 1.45 is marked **unverified**.
- **Kill switch.** It's enforced in three places: the engine tick, the gateway, and the outbox trigger.
- **Dry-run mode.** It's enforced in a database trigger: the outbox can't move to `sent` while `mode = dry_run`, which is the current mode.
- **Outbox state machine** (database trigger). Messages go draft → qa_passed → approved → sent. QA must be done by a different agent from the writer, the do-not-contact list is enforced, and there's at most one send per lead per day.
- **Stuck-work recovery.** Orphaned `doing` tasks are requeued, and stale `reserved` spend is released on startup.
- **Credit failure.** The engine auto-pauses, notifies Moe once, probes hourly and resumes on its own, then requeues stalled tasks. This is working right now: it has been paused since Nov 8.
- **Retry policy.** One retry after 20 minutes, then the task is blocked with the error.
- **Output parsers.** FACTS, LEADS, DRAFT, IDEA, NEXT, PROPOSAL, VALUATION, QUESTION and ESCALATE each become database rows. There are guards for placeholders, dedupe, chain depth and queue caps.
- **Independent audits.** Each researcher has a paired auditor that re-verifies claims (VERDICT PASS/FAIL).
- **Predictions.** 47 rows. Each records whether a task delivered a finished, sourced answer.
- **Audit log.** 235 rows of model calls, failures and applied plans, pruned at 90 days.
- **Owner messaging.** Quiet hours, scheduled delivery, decision buttons and Task Brief options.
- **Structure.** 6 ventures (4 active, music and soccer parked) and 31 active agents.

---

## 4. Built but unused or dormant

| Piece | State |
|---|---|
| `tool_registry`, `accounts_registry` | Tables exist, 0 rows |
| `ledger` | Exists with FX columns, 0 rows, so no real P&L yet |
| `deals` | 0 rows |
| `build_requests`, `human_handoffs` | Tables exist, not used by the engine |
| Bitwarden vault | Code exists in the bot. **[unverified]** whether `BW_ACCESS_TOKEN` is set |
| Wholesale AI valuation | Code is ready. Valuation tasks auto-cancel because `WHOLESALE_SUPABASE_SERVICE_KEY` isn't set in Railway |

---

## 5. Missing (compared with the master spec)

| Spec capability | Today |
|---|---|
| **Mission Manager** (persistent objectives, lifecycle, verification) | **Missing.** Only flat tasks, daily planning and NEXT chains (max depth 2) |
| **Permissions engine (Green/Yellow/Red/Prohibited in code)** | **Partial.** The outbox trigger, spend gateway and owner-contact trigger are enforced in code. There is no general `authorize(action)` layer |
| **Capital controller** (operating fund, reserve, weekly/per-transaction limits, recurring commitments, hard stop) | **Partial.** Only AI spend is capped. There's no operating-fund balance, no non-AI spend, and no recurring-commitment tracking |
| **Computer/browser runtime** | **Minimal.** `/build` gives a coding agent in a folder on Railway. No browser, no deploy pipeline, no per-venture isolation |
| **Venture P&L / portfolio view** | **Missing data.** The ledger is empty. The brief shows $0 everywhere |
| **Outbound email** | **No provider.** The outbox can't actually send even when approved |
| **Voice notes in/out** | **Missing.** The bot only handles text |
| **Learning loop** (lessons → process change) | **Partial.** Predictions and the weekly self-review exist, but no lessons table and no measured before/after |
| **Verification engine** (evidence before "done") | **Partial.** Auditor tasks and a URL heuristic exist. A task is marked done whenever the model replies |
| **Jarvis chat → mission creation** | **Missing.** Chat can only assign a single task |
| **"What happened overnight?"** | **Partial.** The night shift report and daily brief exist, but no mission view |

---

## 6. Broken or risky right now

1. **HQ has been paused since Nov 8: the Anthropic API credit is empty.** No agent work has finished since Nov 5. The engine is alive and will resume on its own after a top-up **[verified]**.
2. **The daily brief said "GREEN, all clear" while paused.** Fixed Nov 11: the brief now leads with "RED, HQ PAUSED, reason, fix" **[verified]**.
3. **Spend overran the cap on Nov 2** ($12.45 against $3.30), before the measured-cost fix. Reservations are estimates, so one call can still settle above its reservation **[verified]**.
4. **The deal funnel has nothing past "Sourced"**: 3,451 Sourced, 5,041 Dead, 0 opportunities, 0 buyers. The scrape itself is fresh (Nov 11) **[verified]**.
5. **The Donna outbox has 15 drafts stuck.** There's no CASL mailing address (`/setaddress`) and no send provider **[verified]**.
6. **Retell test calls cost $2.18–$2.66 each** (about $0.25/min), and the Retell credit balance was flagged low **[verified on dashboard]**.

---

## 7. Security issues

| Severity | Issue | Fix |
|---|---|---|
| **CRITICAL** | **Jarvis chat answers anyone who messages the bot.** `handle_message` has no owner check: tools are owner-only, but every message still runs a Claude call on Moe's API key. Anyone who finds the bot's username can spend his money | **Fixed in step 1 below:** non-owner text gets one canned line and no model call |
| HIGH | **Bot chat, research, content and /build call Anthropic directly, outside the spend gateway.** That spend is uncapped and unlogged | Route through the gateway (Phase 1) |
| HIGH | The Telegram bot token appeared in old Railway logs (httpx logging since silenced) | **Moe: rotate it in @BotFather → /revoke, then paste the new one into Railway** |
| MEDIUM | Two memory stores (bot Postgres + HQ memory). OAuth refresh tokens sit in a bot Postgres table ("interim") | Consolidate; move tokens to Bitwarden |
| MEDIUM | The Station artifact runs arbitrary `execute_sql` through the connector. Fine while private, dangerous if shared | Point it at the read-only `station_snapshot()` only |
| LOW | Wholesale `api_tokens` has 1 row **[unverified: hashed?]** | Check, and hash it if not |
| OK | `hq-run` edge function (`verify_jwt=false`) still demands the service key with a constant-time compare. RLS deny-all with 0 anon grants. Agents never get SQL | — |

---

## 8. Financial picture

- **AI spend to date:** $18.19 USD, all Nov 2–6. Nov 2 alone was $12.45. Since Nov 6 there have been 199 failed calls at $0.
- **Retell:** about $0.25/min. Every 10-minute test call costs about $2.50.
- **Fixed infrastructure [unverified amounts]:** Railway (bot + bot Postgres), Render (free tier, sleeps), Supabase (2 projects, probably free tier), Retell pay-as-you-go, Anthropic API.
- **Revenue recorded:** $0 (the ledger is empty).
- **Risk:** the only hard cap covers HQ engine AI spend. Bot chat, /build, Retell and infrastructure are uncapped and not in the ledger, so the "$300 operating fund" rule can't be enforced yet.

---

## 9. Lowest-cost architecture for what's missing

| Capability | Approach | Added cost |
|---|---|---|
| Mission Manager | Postgres `missions` table + `tasks.mission_id`, a lifecycle trigger, and an engine loop. Reuses the task queue, gateway and audit log | $0 |
| Permissions engine | `action_policy` table + an `authorize_action()` SQL function. Database triggers on outbox, spend, accounts and ledger. Agents can't edit their own policy (no write path) | $0 |
| Capital controller | Extend the existing gateway: `capital_policy` (fund, reserve, weekly, per-transaction, hard stop) + a generic `spend_reservations` alongside `llm_calls`. Ledger in CAD with FX | $0 |
| Verification | Missions can't reach `completed` without `verifying` → evidence (enforced by trigger) and a separate verifier agent | AI calls only |
| Computer runtime | Phase 3: a separate Railway worker running Claude Agent SDK + headless Playwright Chromium, one workspace per venture, every action gated by `authorize_action`. No CAPTCHA/KYC bypass; identity steps become `human_handoffs` | ~one small Railway service **[price to verify]** |
| Email sending | One transactional provider behind the outbox trigger (YELLOW, per-day cap, CASL footer) | Free tier likely **[price to verify]** |
| Voice notes | Telegram voice → transcription API; text replies by default, TTS optional | Per-minute API cost **[price to verify]** |
| Portfolio P&L | Fill the ledger (manual `/paid` and agent-recorded spend). Separate actual / signed / qualified / forecast by `status` | $0 |

---

## 10. Phased plan

| Phase | Work | Depends on |
|---|---|---|
| **0** | This audit | Done |
| **1 Reliability** | Owner-only chat (done in step 1). Route bot/build spend through the gateway. Gateway idempotency + over-reservation guard. Retell/infra in the ledger | — |
| **2 Mission Manager** | v1 built in step 1: schema, lifecycle, engine loop, chat tool, /missions, brief section | — |
| **3 Computer use** | Worker service + Playwright, per-venture workspaces, deploy-and-verify loop | Phase 4 policy hooks |
| **4 Autonomy engine** | Policy table + `authorize_action`, triggers, bypass tests | — |
| **5 Holding company** | Venture budgets, P&L from the ledger, capital allocation recommendations | 4 |
| **6 Communication** | Voice notes, voice replies, calling/WhatsApp research with real prices | — |
| **7 Learning** | Lessons table, expected-vs-actual on every mission, process changes tested | 2 |
| **8 Earn-your-keep** | Per-agent value score with sales-cycle allowance; retire idle agents | 5, 7 |

---

## 11. Step 1 (built with this audit)

1. **Security: chat locked to the owner.** Non-owner messages get one line, no model call, no history saved.
2. **Mission Manager v1** (additive, nothing removed):
   - `missions` table with the full spec lifecycle (CAPTURED → EVALUATED → PLANNED → EXECUTING → VERIFYING → COMPLETED, plus BLOCKED/PAUSED/REJECTED/ABANDONED/FAILED), budget, expected CAD, days to cash, evidence, checkpoint, next action and owner decision.
   - `tasks.mission_id` links the existing queue (no second queue).
   - A database trigger enforces legal transitions and refuses COMPLETED without passing VERIFYING and attaching evidence.
   - Each engine tick: evaluate (GO/TEST/DEFER/REJECT with numbers) → plan → create linked tasks (max 3 open per mission) → when the work is done, an independent verifier checks the evidence → completed, or back to planning (3 tries, then FAILED and escalated). Missions with no progress for 48h are escalated, so nothing is silently abandoned.
   - Mission spend is measured from the gateway's `llm_calls`, and a mission over budget is paused.
   - Jarvis chat gets a `hq_create_mission` tool. New `/missions` and `/mission <id>` commands, and the daily brief gets a missions section.

Not yet done: everything in Phases 3–8, routing bot spend through the gateway, and owner steps (API credit top-up, Telegram token rotation, wholesale key, CASL address).
