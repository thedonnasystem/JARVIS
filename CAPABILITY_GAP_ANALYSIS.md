# FENDEZY HQ — capability gap analysis against the Nov 12 2026 Master Directive
Date: 2026-11-12. Evidence rules: mocked unit tests and a replica database prove logic, not real-world operation. A table, a dashboard or an
agent configuration is not a working capability. "Verified" here means exercised against the live system or a real external service.
Cost figures are rough planning numbers, not quotes. "Dev" = engineering time by Claude (no cash). Ongoing = cash per month.

Classes: IV implemented and verified | INV implemented, not verified | PART partial | DORM dormant | NB not built | BLK blocked by external dependency

## A. Foundation (sections 1, 2, 14, 17, 18, 19)
| Capability | Class | Where | Tests / deploy | Remaining | Dev / ongoing | Security note |
|---|---|---|---|---|---|---|
| Default-deny permissions, tiers, approval engine | IV | `hq_policy.py`, tables `action_policy`, `authorize_action` | tests + live (22 live_only rows) | none now | – | core control; keep outside self-edit scope |
| Kill switch, dry_run (DB-enforced) | IV | `system_state`, `enforce_outbox_rules`, `authorize_action` | live | prove in the first mission | – | enforced in DB, not Python |
| Spend gateway + budget reservation | IV | `reserve_llm_budget`, `settle_llm_call`, `llm_calls` | live, 70 real calls, $18.19 | – | – | mission guard added (below) |
| Per-mission hard budget, step limit, focus mode | INV (new, dev branch) | `20261113_mission_guard_v1.sql`, `hq_missions.set_focus`, engine filter | replica e2e + unit; NOT deployed | owner review, deploy, first live use | done / $0 | additive; never raises a limit |
| Duplicate-task protection | INV (new, dev branch) | `tasks.dedupe_key` unique index, `outbox_one_draft_per_lead`, `queue_outreach_drafts` | replica e2e + unit; NOT deployed | deploy | done / $0 | – |
| Bulk-change audit | INV (new) | `audit_task_bulk_update/delete` triggers | replica e2e; NOT deployed | extend to other tables if wanted | done / $0 | Nov 8 cancel cannot be attributed: no record existed |
| Operational alerts | INV (new) | `ops_alerts()`, cron `hq-ops-alerts` every 10 min | replica e2e; NOT deployed | live fire test; Telegram delivery of kind 'health' to confirm; failed-deployment alerts need Railway/Render API (NB) | done / $0 | cooldowns prevent noise |
| Integration gate (value-fixer) | INV (new) | `integration_status`, `queue_valuation_task`, `sync_integrations()` | unit + replica; NOT deployed | – | done / $0 | unknown = missing, so no recurring noise |
| Migration integrity | PART | repo migrations; `enforce_build_rules` captured (md5 identical to live); `lockdown_v1` reconstructed from live (live privileges verified: 0 leaks) and recorded in the ledger by re-running it last at deploy; `ops/live_functions_baseline_20261112.txt` pins all 91 live functions; rollback in `ops/rollback_phase1.sql` verified in CI | replica applies all twice; rollback drill | 30 pre-Nov-12 live migrations are not in the repo (only in the live ledger + replica capture) | small / $0 | never remove live security rules |
| Capital controller ($300 framework, $50 reserve, $20 stop, $25/txn, $75/wk, $100 low-cost) | INV | `20261112_capital_v1.sql`, `hq_capital.py` | unit + replica; live | bank balance never entered (zero recorded) so "real bank balance is the ceiling" is unproven | – | – |
| Waterfall (33% / 1.5 mo / draw / 60-25-15) | INV | `20261112_finance_rules_v1.sql`, `hq_waterfall.py` | replica | zero revenue/expense rows, so never exercised; accountant must confirm tax/HST | – | not accounting advice |
| Coast mode | INV | `coast_state`, `hq_waterfall.coast()` | unit | needs `owner_seen` calls verified | – | – |
| Backup + restore test | DORM | `hq_backup.py` | unit only | BACKUP_KEY, BACKUP_PUT_URL, then an actual restore drill | small / storage ~$0–5 | encrypted client-side |
| Deployment verification | IV for Railway/Render (a3d7d7d, 2026-11-12) | `ops/verify_deploy.sh` (Railway reports deploys to GitHub), Render API, `integration_status.engine_build` written by the bot each tick (after deploy) | scripts run read-only | engine_build runtime proof only exists after the Phase 1 deploy | done / $0 | read-only |
| Retries, stuck-task recovery, mission timeouts | INV | `_recover_stale`, retry mark, 48h stale | unit | live evidence needed | – | – |
| Provider outage handling | PART | credit pause + hourly probe + auto-resume | live (it did pause) | non-credit outages: only the failed-call alert | small | – |

## B. Execution and the company interface (sections 3, 4, 5, 7)
| Capability | Class | Where | Remaining | Dev / ongoing | Notes |
|---|---|---|---|---|---|
| Mission engine on real LLM output | INV, UNPROVEN | `hq_missions.py` | the first mission test (FIRST_MISSION_TEST.md) | – / ~$1–2 once | regex-parsed output is the main risk |
| Jarvis chat + tool use | INV | `hq_commands.py` tools | works in Telegram; paused now | – | – |
| Private PWA | INV | `webapp/` on Render, `app_*` RPCs | live; screenshots only. No device testing logged | audit real screens vs section 4 list | medium / $0 | owner-only via `is_app_owner` |
| PWA sections: command centre, missions, feed, ventures, financials, approvals, health | PART | `webapp/` | several of the 24 listed views are placeholders or read-only: org chart, notifications centre, autonomy settings, deployment health, software dev activity are thin or absent | medium–large / $0 | do not call placeholders implemented |
| Voice | DORM | `hq_voice.py` | OPENAI_API_KEY | small / usage | – |
| Persistent browser / computer environment | NB | none (research uses Anthropic web_search/fetch only) | pick a hosted browser or a worker box; secrets vault; approvals; CAPTCHA hands-off | large / $10–60 | no passwords in prompts; human verification for CAPTCHA |
| Self-development (code, tests, PRs, rollback) | PART | `hq_dev.py` can open PRs to the repo (protected files flagged) | sandbox, test runner, review gate, rollback; critical controls must sit outside editable scope | large / low | PR-only token still needed from owner |

## C. Workforce, departments, ventures (sections 8, 9, 10, 21)
| Capability | Class | Remaining | Dev / ongoing |
|---|---|---|---|
| 32 agent configs → functioning agents | PART: configs exist; ~all have no operating history | per-agent metrics (missions, success, cost, quality) not tracked as a view | medium / $0 |
| Sub-agents, delegation, comparing outputs | PART (task delegation exists; agent-creation limits exist; no comparison/evaluation loop) | build after first mission | large |
| Departments / org chart | PART: `hq_org.py`, `hq_office.py`, 9 office functions, tables; "dashboard is not a department" applies | prove each does measurable work | medium |
| Venture factory (idea → business case → build → operate) | PART: ideas table, `new-ventures-researcher`, `hq_create_venture`, validation mission, activate_venture; no autonomous build/launch/operate | needs execution layer first | large |
| Existing ventures: Donna, real-estate, day-job, idea-lab | Donna INV; real-estate DORM (funnel key missing); day-job INV (manual logging); idea-lab INV | – | – |

## D. Intelligence, marketing, memory (sections 11, 12, 13)
| Capability | Class | Remaining | Dev / ongoing |
|---|---|---|---|
| Research pipeline | PART: web research per task; no continuous scan loop beyond `hq-opportunity-scan` weekly cron | targeted source list, verification step, storage | medium / ~$1–5 |
| Company memory | PART: facts + lessons tables, `_company_knowledge` | semantic retrieval (pgvector + embeddings provider), source tracking, dedupe, versions, retention, quality scoring | medium–large / ~$1–5 |
| Marketing / social / content / publishing / attribution | NB (only draft emails exist) | needs execution layer + platform integrations + legitimate accounts | large / variable |

## E. Money and models (sections 14, 15)
| Capability | Class | Remaining |
|---|---|---|
| Revenue/expense ledger, P&L, forecasts | PART: ledger, `/money`, P&L exist; zero rows | enter real data; manual statement import + reconciliation exists (`hq_bank.py`) but unused |
| Bank API | BLK: RBC business API eligibility unknown; manual import is the interim | owner/RBC |
| Model/provider abstraction | PART: model tiers (cheap/standard) via `model_tier`; Anthropic only | provider interface, second provider, per-task routing, cost-per-successful-mission views |
| Self-hosted models | NB | honest evaluation doc only; likely not worth it at this volume |

## F. Donna separation (section 20) — needs the first mission validated first (owner's rule)
Donna-specific, hardcoded today: `webapp/apply/*` (terms $120/close, $50/mo after 3, 90-day lapse, Friday pay in page copy), `setters` table (no venture_id), `setter_apply` + `setter_record_payout` (global), `hq_setters.py`, `casl_footer` + `/setaddress` default, cron `hq-donna-prospects` + `queue_prospect_task`, `queue_daily_planning`, draft prompt text, `VENTURE_TEAM`, Telegram `/setter`. Plan: `venture_config` table (terms, address, footer) → add `venture_id` to setters/payouts (backfill = Donna) → parameterize functions with a default of Donna for backward compatibility → move the apply page to `/donna/apply` with a redirect from `/apply` → generic per-venture prospecting cron → tests: HQ with Donna parked, Donna with a second venture. Live `setter_apply` is public: change last, behind e2e tests.

## G. Phased plan (order, gates)
1. Phase 1 repair — DONE IN DEV BRANCH, awaiting owner review/deploy (this PR).
2. Phase 2 — deploy, then run the first mission (gate: owner authorizes + adds credit). Fix parser issues found.
3. Phase 3 — HQ app audit on a real phone; fill real gaps; Donna stays untouched until Phase 2 passes.
4. Donna separation (after Phase 2 pass).
5. Phases 4–9 in directive order, each with an acceptance test and a stated cash cost before building. Execution layer (browser + sandbox) is the gating dependency for most of phases 5, 7, 8.
