# Roadmap: Sections 10-12 (banking, venture factory, executive initiative)
Design only. Nothing here is live. Every item sits behind the existing budget gateway, permissions engine and capital controller.

## Standing rules from the owner (Nov 12)
- Jarvis can create agents, sub-agents, departments, and edit his own code. Freedom is inside the budget: the spend gateway, per-agent caps and the capital controller stay in the database where agents cannot edit them.
- Never over budget. Limited capital: low-cost mode already downgrades models and stops non-essential spend.
- Endless memory: store everything (messages, decisions, missions, lessons) in Supabase; retrieval is search over knowledge/lessons so prompts stay small and cheap.
- Jarvis is not a single point of failure: work is done by agents; Jarvis coordinates, the engine runs without him.
- Accounts: Jarvis may register accounts with the email/number the owner provides, through normal sign-up. Captcha bypass is NOT built: it breaks most sites' terms, risks bans and legal exposure. Where a captcha appears the task parks as "needs owner" (one tap), or we use the vendor's official API instead.

## Section 12: proactive initiative and org evolution
Build on: missions, ideas pipeline, predictions, auditors.
1. `opportunity_scan` weekly mission per venture: finds bottlenecks, cost cuts, new revenue. Output is a PROPOSAL with: problem, why it matters, expected $ impact, implementation cost, time to results, risks/alternatives, recommendation. (Format already exists for PROPOSAL; add the six fields as required.)
2. Agent/department scorecards: spend vs verified outcome per agent per week; underperformers flagged in the brief.
3. `org_changes` table: Jarvis proposes new department/agent/workflow. Internal org changes inside caps = auto (green); external commitments or spend above limits = approval request.
4. Disagreement rule: a proposal may include `disagrees_with_owner` with evidence; shown in the app Needs-you card.

## Section 11: venture factory and self-service development
1. Venture workspace record: own budget, agents, ledger rows, leads, memory namespace, manager agent, goals/metrics. (Schema is mostly there via ventures + capital ledger; add `venture_memory` and `venture_goals`.)
2. Venture lifecycle as a mission template: validate -> model -> build -> launch -> measure -> scale/kill, each gate needing evidence (already enforced by mission trigger).
3. Corporate office tabs in the app, each wired to real tables: Executive, Business Dev (ideas), Research, Engineering, Marketing, Sales (leads), Finance (capital), Operations (systems), Agent Mgmt. Only after the data exists; no decorative tabs.
4. Controlled dev environment: Jarvis writes code on a branch via the GitHub API, CI runs tests, deploy to a staging service, owner (or later a policy rule) promotes to production. Rollback = redeploy previous commit. Policy, capital and spend code paths are protected: changes there always need owner approval. Dependencies from an approved list only.
5. Dev cost goes through the same meter (builder agent already metered).

## Section 10: banking and operating capital
1. Bank is the source of truth. Add `bank_accounts`, `bank_transactions`, `bank_reconciliation` tables. The internal ledger never exceeds the verified bank balance: `available = min(ledger_available, bank_balance - reserve)`.
2. Integration path, in order:
   a. Manual reconciliation now: owner uploads/pastes the RBC statement CSV in the app; Jarvis matches against ledger, flags discrepancies.
   b. RBC Business API only if RBC approves eligibility (needs owner application; unknown timeline). Use an aggregator only if cheaper and RBC-supported.
   c. Payments: Jarvis prepares payment instructions; the owner approves and authenticates in RBC. Jarvis never holds banking credentials, never sees an authenticated session, never moves money on its own.
3. Alerts: low balance, unusual activity, upcoming commitments, reconciliation gaps go to the owner via Jarvis.
4. Audit trail: action_log + ledger + reconciliation rows are append-only.

## Build order after the green light
1. Apply migrations and enable owner login (see WEBAPP.md).
2. Bank tables + manual reconciliation (cheapest, real value, enforces "money must exist").
3. Proposal format + weekly opportunity scan.
4. Venture workspace tables and mission template.
5. Branch-based self-dev with protected paths.
6. Web push, then emergency phone call.
