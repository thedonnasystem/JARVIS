# Spec traceability: Sections 10, 11, 12 (and your Nov 12 notes)
Status: BUILT = code and tests on `overnight-build`, not live until you apply migrations (see GO_LIVE_CHECKLIST.md). PARTLY = built with a stated gap. NOT BUILT = needs something only you can provide, or I chose not to.

## Section 10: banking and operating capital
| Requirement | Status | Where / note |
|---|---|---|
| 1 RBC Business API | NOT BUILT | Needs RBC eligibility and approval (your application). Manual reconciliation is the specified fallback and is built. |
| 2 Retrieve balances and transactions | BUILT (manual) | `/bank balance`, statement CSV import (Telegram + app). bank_v1 |
| 3 Sync real balance with ledger | BUILT | `available = min(ledger, bank - reserve)`; the lower number rules. bank_v1 |
| 4 Track deposits, withdrawals, expenses, transfers, commitments | BUILT | bank_transactions, ledger, payment_instructions, tool_registry renewals |
| 5 Allocate capital across ventures and expenses | BUILT | `/venture budget`: you set each venture's monthly ceiling; the database refuses totals above real available money; shown in the finance review. Reallocation is your call (Jarvis can propose). allocation_v1 |
| 6 Reserve before spending | BUILT | `reserve_spend` for every purchase and payment instruction |
| 7 Prepare payment instructions; execute permitted transactions | PARTLY | Instructions are prepared, reserved and approved (payments_v1). You pay in RBC and confirm; Jarvis never moves money. This is the specified manual path until an authorized API exists. |
| 8 Reconcile and report discrepancies | BUILT | `/bank reconcile`, unmatched list, brief |
| 9 Complete audit trail | BUILT | action_log, audit_log, ledger, reservations, payment_instructions |
| 10 Alerts: unusual activity, low balance, upcoming commitments | BUILT | bank_alerts (balance age, reserve floor, ledger vs bank, unmatched, approved payments, renewals in 7 days, unusually large debits) |
| Never: exceed budget, overdraw, unauthorized recipients, raise own limits, personal accounts, bypass authentication | BUILT | DB-enforced: capital limits, owner-only limit changes, payee must be approved by you per payment, no credentials stored |
| Never store RBC passwords/PINs | BUILT | No field exists; asset and procedure writers refuse secrets |

## Section 11: corporate office and venture factory
| Requirement | Status | Where / note |
|---|---|---|
| Receive an idea and run the lifecycle | BUILT | hq_start_venture, lifecycle mission, evidence-gated stages. ventures_v1 |
| Research and validate, competition, demand, costs, revenue | BUILT | Idea Lab agents + independent verifier, forecast-accuracy learning |
| Business model, venture workspace | BUILT | create_venture, venture_workspace, goals, memory namespace |
| Build websites, software, automations | PARTLY | Jarvis can open code PRs (hq_propose_code_change). No staging deploy or website hosting pipeline yet: needs a repo-scoped GitHub token and a staging service from you. |
| Specialist agents and departments | BUILT | hq_create_agent / hq_create_department with DB-enforced limits (agents_v1) |
| Operating procedures | BUILT | venture_procedures, versioned (assets_procedures_v1) |
| Marketing and customer acquisition, leads | BUILT (dry-run) | Donna outreach drafts and approval flow, leads, follow-ups. Sending stays owner-approved. |
| Monitor performance, optimize, scale or shut down | BUILT | scorecards, earn-your-keep review, weekly opportunity scan, shutdown proposals |
| Nine corporate-office departments wired to real data | BUILT | app_office (office_v1): each function computed from real agents, tasks, spend and data; empty ones say "unstaffed" |
| Venture independence: workspace, agents, budget and ledger, memory, goals, leads, assets/integrations, manager | BUILT | ventures_v1, assets_procedures_v1 |
| Self-service dev: source access, modify, approved dependencies, test, deploy, monitor, roll back | PARTLY | PR-only with protected paths and secret scan, approved-dependency allowlist, CI runs tests, rollback = revert the PR. Auto-deploy and staging are not built: they need your token and service. |
| Owner phrases ("Start a new venture", "Research this industry", "Build me a new business", "Create a marketing department", "Review our finances", "Find another revenue opportunity") | BUILT | Chat tools: hq_start_venture, hq_assign_task (research agent), hq_create_mission, hq_create_department, hq_finances, hq_create_mission (opportunity) |
| Involve the owner only for reserved decisions | BUILT | Needs-you cards: signing, money, health, proposals only |

## Section 12: proactive initiative and organizational evolution
| Requirement | Status | Where / note |
|---|---|---|
| Continuously evaluate performance; spot bottlenecks, cost cuts, revenue; underperformers | BUILT | weekly self-review, scorecards, earn-your-keep, per-venture weekly opportunity scan (opportunity_v1) |
| Recommend ventures, tools, technologies | BUILT | proposals with kind venture/tool |
| Propose and create offices, departments, divisions, units, teams, agents, sub-agents, systems, workflows | BUILT | org_changes kinds; approved changes become missions; creation tools inside DB limits |
| Create internal structures within budget and permissions; external commitments need authorization | BUILT | agents_v1 limits; spend and contact stay behind policy and capital gates |
| Recommendations carry opportunity, why, impact, cost, time, risks/alternatives, recommendation | BUILT | structured PROPOSAL format, stored in org_changes |
| Willing to disagree with the owner | BUILT | `disagree:` field shown on the decision card |
| No fixed org chart | BUILT | agents/departments are rows; the office view is computed, not hard-coded per agent |

## Your Nov 12 notes
| Note | Status |
|---|---|
| Jarvis edits own code | BUILT (PR-only; you merge) |
| Creates agents and sub-agents | BUILT inside limits |
| Creates accounts with the email/number you provide | PARTLY: request -> your approval -> you sign up (captcha, codes, ID, payment are always yours) -> `/account done` records the login. Agents have no browser here, so they cannot sign up alone. accounts_v1 |
| Bypass captcha | NOT BUILT, by decision: it breaks sites' terms and risks bans. Captcha steps park as one tap for you. |
| Never go over budget | BUILT (DB-enforced) |
| Limited capital | BUILT (low-cost mode, hard stop, reserve) |
| Endless memory | BUILT: everything stored in Supabase; search covers memory, task results and app chat history |
| Don't over-weight Jarvis | BUILT: engine runs without him; work sits with agents |

## Still needs you
Migration green light, Auth setup, merge to the Railway branch, VAPID keys, Anthropic credit top-up, `WHOLESALE_SUPABASE_SERVICE_KEY`, `/setaddress`, repo-scoped GitHub token (PR-only) and a staging service for self-deploy, RBC API application (optional), phone-call vendor if you want the emergency call.
