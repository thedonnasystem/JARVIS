# Fendezy HQ: accelerated roadmap (Nov 12-13, 2026)
Evidence base: three independent read-only code audits (mission engine, ventures/sales/finance, owner interface/infra), the Phase 1.5 work, and live read-only checks. Status words mean what the code and tests prove, not what a document claims. Synthetic/mock tests are never counted as production proof.

## 1. Where the company really is
| Area | COMPLETE (code + tests) | PARTIAL | DORMANT (built, needs owner/env) | MISSING |
|---|---|---|---|---|
| Control layer | spend gateway, kill switch, credit pause, caps, focus/strict-step rules, default-deny policy, capital framework | - | - | - |
| Mission loop | capture, evaluate, plan, step fan-out, verify as chained LLM research tasks | evaluation parsing (regex-bound), verification (no evidence checking), error recovery (one retry then dead-end), learning (writes almost nothing) | forecast calibration (`learning_v1` needs pg_cron), self-dev PRs (needs GitHub token) | steps cannot see earlier steps; agents have NO action tools; due dates/recurring missions |
| Venture factory | create/activate/stage/budget/goals, manager agent, P&L, holding view | engine for a new venture (hardcoded team table), lead capture (only `*-researcher`), drafting (needs `*-division`) | wholesale bridge, websites-as-PR (no host) | generic prospecting, per-venture brand/CASL, KPIs from real data, revenue capture, reply tracking |
| Sales/marketing | Donna loop: prospect, store leads with CASL consent, draft, owner approves, owner sends, `/sent` | outreach for any venture other than Donna | automated email (Resend + mode live + policy allow) | reply/booking tracking, invoices/payment capture |
| Finance | ledger, per-venture P&L, bank CSV, payments/accounts/waterfall as approve-then-owner-pays flows | venture budgets vs AI spend | - | revenue capture beyond owner-typed `/money in` |
| Owner HQ | Telegram + PWA, approvals, kill switch, missions/agents/money/feed | web push, voice (input only), health checks | push keys | one unified "needs you" inbox, weekly digest, offline queue, any browser/JS test |
| Reliability | backups built and drilled locally (43 checks, PG16+17.11), heartbeat, CI | - | backups need the B2 account/keys + approval | real restore proof |
Duplicates to consolidate later (not now): 3 task generators, 2 spend paths, 4 hand-kept function lists, 5 approve-and-reserve flows, 3 vendor registries, `predictions` (not calibration), `hq_tools` (misnamed registry).

## 2. Critical path to a usable first autonomous operating company
Definition used here: Jarvis runs the mission loop reliably unattended; one real venture (Donna) runs prospect -> lead -> draft -> owner approval -> send -> reply -> booking -> revenue entry with real KPIs; a second venture can be launched on the same infrastructure by configuration; the owner manages from one inbox. Fully autonomous *actions* by agents (tool layer) come after that and need your design approval because they touch policy/capital gates.

| # | Work package | Stream | Est (focused h) | Needs prod/owner? | Status |
|---|---|---|---|---|---|
| 0 | Phase 1.5 backup system: deploy + real proof | Reliability | owner 20 min + approvals | B2 account, approvals | built, verified synthetically |
| A1 | Step-to-step handoff + scoped research | Mission | 6 | no | building |
| A2 | Blocked step/verifier recovery, stuck-eval fix | Mission | 8 | no | building |
| A3 | Real learning writes, `FACTS:` capture | Mission | 7 | no | building |
| A4 | Evidence-checked verification (URLs resolve, traceable) | Mission | 6 | no | next |
| A5 | Output-format resilience (schema + one cheap repair) | Mission | 8 | no | next |
| A6 | Due dates, recurring missions, fast-tick, coast keeps in-flight | Mission | 8 | no | next |
| B1-B3 | Generic venture resolution, per-venture CASL, generic researcher/division + prospecting | Venture | 8-12 | migration needs approval to apply | building |
| B4 | Venture KPIs from real data | Venture | 4-5 | read-only function | building (kpis) |
| B5 | Deals/revenue capture (owner-confirmed) + reply tracking | Venture | 8-11 | migration | next |
| B6 | Commission-partner program per venture | Venture | 3-4 | no | later |
| C1 | Pre-deploy gate, migration lint, generated function manifest, parallel-work convention | Infra | 7 | no | building |
| C2 | App smoke tests (jsdom) | Owner HQ | 5 | no | next |
| D1 | Unified "Needs you" inbox + weekly digest | Owner HQ | 8 | migration | next |
| E1 | Agent action tools through policy/capital gates | Mission | 24+ | DESIGN APPROVAL (touches protected gates) | proposal only |
| F1 | First real mission (200c, 4 steps, focus, dry-run) | validation | 1 | YOUR authorization + credit | prepared (`FIRST_MISSION_TEST.md`) |

Dependencies: A* and B* are independent of each other and of C1 (different files; see `MIGRATIONS.md` convention from C1). B5 follows B1-B3. A4 follows A1. D1 follows B5 (inbox lists deals). E1 follows A1-A5 and a design review. F1 needs PR #2 deployed (backups) and A1-A3 merged so the test exercises the improved loop.
Estimate: the no-prod-access items sum to roughly 100-120 focused hours of engineering; with parallel streams this fits the 10-14 day window only if your approval gates (merge/deploy/migration batches) are turned around within a day each. E1 and the first real revenue are NOT promised inside that window: E1 needs your design approval, and revenue needs real prospects, your approvals and (for automation) credit.

## 3. Parallel-work rules (prevent conflicts)
One branch per stream off `overnight-build`, each owning disjoint files; migrations as `YYYYMMDD_<stream>_<topic>_vN.sql`, never editing applied ones, each new function ends with explicit REVOKE/GRANT; `dist/APPLY_ALL.sql` rebuilt only on the integration branch; integration order A -> B -> C -> D with the full gate (`scripts/gate.sh`) after each merge into an integration branch. Nothing merges to `overnight-build` or deploys without your approval.

## 4. Consolidated owner checklist (batched; no drip questions)
1. Backblaze B2 account, bucket, two keys, `BACKUP_KEY`, three Railway variables (about 20 minutes; `BACKUP_SETUP_OWNER.md`). Never send secrets to chat.
2. One approval batch when you are ready: merge PR #2 + apply `20261113_backup_schema_v1.sql` (read-only functions), then merge the stream PRs and apply their migrations in order. Each item is listed with its rollback in the final report.
3. `/setaddress` for each venture that will email (CASL).
4. Decision: include push-key tables in the encrypted backup? (default no).
5. Decision (later): approve the E1 design (agent tools through the existing gates).
6. When you choose: authorize and fund the first real mission (F1). I will not do this myself.
