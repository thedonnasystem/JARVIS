# FENDEZY GROUP — Open-source evaluation (Phase 1-3), Nov 14 2026

Status: READ-ONLY research. Nothing installed, deployed, or changed in production. Evidence = cloned source (shallow, HEAD as of Nov 14-15) plus each project's own docs.
Limits: I read code structure, licenses, security docs, CI and test layout. I did NOT run any of them, so "works" claims are unverified. Costs are not invented; see section 5.

## 1. Existing system audit (what is real today)
- Production DB: release complete. 72 migrations, 123 public functions, all 13 post-release checks PASS (dry_run, kill=false, cap=330c, pause=api_credits, capital framework unchanged, 0 sent / 0 deals / 0 missions).
- Railway: live = ecadb31327e1 (verified by Railway deployment 2cf186bd, GitHub deployments API, and the bot's own engine_build row). Heartbeat fresh.
- Code: 66 Python files (~18.5k lines), 35 migrations, SQL and web test suites. System of record = Supabase Postgres.
- Already built and worth keeping: spend gateway, kill switch, dry-run (DB-enforced), approvals, capital controller, audit log, mission engine (unproven on real output), Needs You inbox, backup helper (dormant), venture factory.
- Known gaps (from CAPABILITY_GAP_ANALYSIS.md): no persistent browser/computer environment, no isolated code-execution workforce, PWA views partly placeholders, mission engine unproven with real LLM output, backup dormant.
- Open items from this release: Telegram commands /hq /needs /missions /backup check not run by me (Telegram Web needs a QR login from the phone). DB equivalents verified: needs_you() returns 19 items (alert/approval/draft/escalation), missions = 0.

## 2. Candidate comparison (code-inspected)

| | OC8 | Agent Swarm | Windmill | Agent HQ |
|---|---|---|---|---|
| Repo | oc8-ai/oc8 | desplega-ai/agent-swarm | windmill-labs/windmill | nordinit/agent-hq |
| License | LGPL-3.0-or-later (backend/, frontend/); each "capa" has its own license | MIT | AGPLv3 core; proprietary EE code; Apache-2.0 clients/OpenAPI. Official Docker "Community Edition" image includes proprietary code and bars selling, reselling, managed service, modify or wrap | MIT |
| Last commit seen | Nov 2 2026 | Nov 15 2026 (v2.13.2) | Nov 14 2026 (v1.875.0) | Nov 13 2026 |
| Size / tests | 2,925 files, 779 test files, no .github/workflows found | 7,300 files, 1,780 test files, 12+ CI workflows incl. nightly e2e | 11,527 files, 945 test files, large CI | 1,156 files, 360 test files, CI with Postgres 17 |
| Maturity (own words) | "pre-release"; SECURITY.md has no approved reporting channel | Active daily releases, security contact exists, no SLA | Mature, vendor-backed | Pre-1.0, 1 star |
| Storage | Postgres + pgvector + Redis | SQLite (bun:sqlite + sqlite-vec) | Postgres (required) | Postgres 17 |
| Isolation | in-process by default; Docker opt-in; backend mounts Docker socket ("root-equivalent", own docs) | Docker worker containers | nsjail + PID isolation | none: agents run host CLIs as the OS user ("operator access is shell access") |
| Auth | dev-login = unauthenticated admin if OC8_ENV=dev | API_KEY + encryption key | OAuth/SSO, roles, path-scoped secrets | operator token (>=32 chars) + per-agent MCP keys |
| MCP | gateway | MCP.md, server.json | dedicated mcp mode | 200+ tools |
| Approvals | value thresholds, inbox, Telegram/WhatsApp | not a headline feature | not a headline feature | review gates; richer approvals listed as unbuilt |

## 3. Decisions (preliminary, code-informed)

| Project | Decision | Reason |
|---|---|---|
| Agent Swarm | ADOPT candidate (engineering workforce), subject to a proof of concept | MIT, very active, isolated Docker workers, GitHub/GitLab flows, large test suite. Risks: SQLite store is a second data silo (Jarvis stays system of record, swarm is an executor); each worker burns Claude tokens, so the 330c cap must gate it; telemetry SDK (@desplega.ai/business-use) must be checked and disabled or pinned before any use. |
| Windmill | ADAPT/EXTRACT only after a legal call; do not adopt by default | Internal use of the AGPL build is fine. For FF Marketing client work we would be running it for third parties; the Community Edition terms forbid modifying or wrapping and the AGPL network clause applies to modified versions we expose. Needs a licensing decision (build from source without enterprise flag, or buy a commercial license) before any client-facing use. Until then use it internally only, or use n8n/Make/Python in HQ for workflows. |
| OC8 | REFERENCE (maybe ADAPT later) | It duplicates what HQ already enforces (approvals, thresholds, audit, secret store) and ships its own permission model, so two competing governance systems. Self-described pre-release with no security channel; Docker-socket root exposure; dev-login footgun. Worth borrowing ideas: HMAC-chained audit, capa trust boundary, per-agent credential scoping. |
| Agent HQ | REFERENCE | Overlaps Swarm and OC8, 1 star, pre-1.0, no isolation (agents run on host). Its gate model (commit-matched QA) is a good pattern to copy into our mission engine. |

## 4. Recommended architecture (smallest reliable set)
1. FENDEZY HQ (Supabase + Railway bot + PWA) stays the system of record and the ONLY authority for money, permissions, kill switch, audit.
2. Jarvis stays the single front door and talks to executors through a thin adapter, so any executor can be swapped.
3. Agent Swarm = optional execution workforce for coding/engineering tasks, run in the smallest config (one lead + one worker), every task created and approved through HQ (spend reserved first via reserve_llm_budget), results returned to HQ tasks with evidence.
4. Workflows = keep the current HQ cron/engine plus n8n/Make until the Windmill license question is settled.
5. We build: executor adapter + budget gate, division/client isolation (workspace_id on every record), FF Marketing OS (client workspaces, ads reporting, lead routing that never receives sensitive mortgage data), unified reporting.

## 5. Cost assessment (no invented numbers)
- Subscriptions: Claude Max (your decision). Not usable as API credit.
- Operating costs that exist regardless of "free" software: Anthropic API/inference (currently paused for credits; cap 330c/day), Railway, Render, Supabase, worker compute (Swarm workers are Docker; cost depends on where hosted), storage for backups.
- Measured so far: HQ spent $18.19 across 70 real calls (gap analysis). Swarm/OC8/Windmill costs are unmeasured. They will be measured in the proof of concept; I will not quote hosting figures until then.

## 6. Roadmap with completion criteria
| # | Milestone | Done when | Needs you? |
|---|---|---|---|
| 0 | Release verified | 13/13 PASS, deployed SHA matches | DONE (Telegram commands: your phone) |
| 1 | Agent Swarm local proof of concept in an isolated sandbox with NO production credentials | Test: restricted agent does a harmless task, consequential action blocked until approved, result + audit row returned, failure/retry handled | No |
| 2 | Executor adapter + budget gate in HQ (isolated branch, tests, replica) | Unit + replica tests green; cannot start a worker without reserve_llm_budget; kill switch stops it | No for build; merge/deploy are your gates |
| 3 | FF Marketing OS data model (workspaces, ledger separation, no sensitive-data ingestion rule enforced in code) | Replica tests prove cross-client isolation | No |
| 4 | Mortgage broker non-sensitive workflow in dry-run | Campaign/lead-routing runs with no sensitive fields; dry-run only | Needs broker's real inputs (budget, CRM, geography); I will not invent them |
| 5 | Second client in a separate workspace | Isolation test passes | Same as above |

## 7. Owner-only items (what I cannot do)
- Telegram Web login (QR from phone) so I can run the commands myself, or you run /hq /needs /missions /backup check once.
- Real values: FF Marketing budget, pricing, geography, CRM, deadlines, whether life-insurance recruiting means licensed agents, trainees, or both.
- Windmill licensing choice (commercial license vs build-from-source vs skip).
- Any spending, credits, subscriptions, live mode, external contact, merges/deploys/migrations to production, protected controls (all unchanged and unauthorized).
