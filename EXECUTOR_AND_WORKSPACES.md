# Executor gate + client workspaces (branch build/executor-ffm) — NOT deployed

Status: built and tested on a local replica only. Nothing pushed, merged, applied to production or deployed. Each of those is an owner gate.

## What it adds
| Piece | File | Purpose |
|---|---|---|
| Executor gate | migrations/20261117_executor_gate_v1.sql | `executor_request` / `executor_complete` / `executor_expire_stale`. The only door for an external executor (e.g. Agent Swarm). |
| Adapter | hq_executor.py (+ test_hq_executor.py) | `run(executor, agent, task, est_cents, purpose, work)`: asks HQ, runs `work` only if allowed and not dry_run, settles cost, settles a crash as failed at the full reservation. |
| Client workspaces | migrations/20261117_client_workspaces_v1.sql | `client_workspaces`, `ws_campaigns`, `ws_leads`, `ws_ledger` + guard. One model, isolated clients. |
| Helper | hq_workspace.py (+ test) | `screen()` before any client text reaches a model; `add_lead()` turns a DB refusal into `SensitiveDataRefused`. |
| Rollback | ops/rollback_executor_ffm.sql | Removes only these objects; idempotent; drilled. |

## Guarantees (each proven by sqltests/*.sql)
Executor: unregistered/disabled/empty-allow-list/zero-cap executors are refused; kill switch, pause_reason, per-run cap, daily run cap, agent cap and company cap all stop a run; dry_run reserves nothing and tells the caller not to execute; refusals are recorded and audited; stale runs release their reservation; the bot (service_role) cannot enable an executor or edit the registry.
Workspaces: composite FKs make cross-client campaign references impossible; summaries are per workspace; sensitive text (SIN-like numbers, card-like numbers, ID documents, banking, credit, application/income terms) is refused on every text column of every table, on insert and update; spend is refused until the owner sets a budget and again past it.

## Expected vs actual
| Check | Expected | Actual |
|---|---|---|
| Strict gate (9 steps) | all PASS | 9/9 PASS (incl. replica e2e, rollback drills, function manifest) |
| executor_gate_check.sql | E1–E32 pass | pass; found and fixed 1 real bug (refusal for an unknown task violated an FK) |
| client_workspaces_check.sql | W1–W22 pass | pass; assertion sanity-checked by forcing a failure |
| Python unit tests | pass | 10 new tests pass |
| Rollback drill | objects gone, re-apply clean | confirmed |

## Independent review (fresh agent, tried to break it) — 8 defects found, all fixed and re-tested
Executor: failed/expired runs escaped the daily caps (now settled as spent at >= reservation); caller-chosen `purpose` could dodge focus mode (now fixed to `task <id>`); `approve_first` ran live (now refused); missing/NULL system_state failed open (now closed); adapter could mask the original error or strand a reservation (now guarded, one retry).
Workspaces: phone-shaped text excused a SIN next to it; digit separators, fullwidth/Arabic-Indic digits, digits split across columns, many keyword gaps (S.I.N, SSN, Experian, FICO, loan application, tax return, OHIP, salary...); service_role kept TRIGGER/REFERENCES. All fixed; 27 isolation/guard assertions + 36 executor assertions pass. Production grants checked read-only: anon/authenticated have no access to llm_calls, audit_log, system_state, agents, tasks, ledger (RLS on); the reviewer's scratch-DB grant finding does not apply to production.

## Known limits (honest)
- `executor_expire_stale` is NOT scheduled yet. Until it is (every 5-10 min, owner-gated deploy), a lost `executor_complete` leaves a reservation counted as spent (safe direction).
- "Only door" is a convention for service_role: it can still call `reserve_llm_budget` directly (pre-existing).
- `actual_cents` from an executor is trusted; overruns are flagged, not clawed back. `executor_runs.purpose` is not screened for sensitive text.
- Guard is regex-based: fails closed, more false positives now (any 7+ digit number, the word "income"), cannot catch base64/leetspeak/homoglyph obfuscation.
- Isolation is write-integrity in the DB; read isolation depends on callers passing the right workspace id.
- The sensitive-data guard is pattern-based and fail-closed. It will refuse some harmless text (e.g. an email containing 9 digits) and cannot catch data it has no pattern for. It is a backstop; the primary control is that no sensitive field exists and clients' sensitive records never leave the broker's own systems.
- Nothing runs an executor yet. Registry is empty, so the whole feature is inert until the owner registers and enables an executor.
- `executor_complete` records an overrun but does not claw it back; per-run cap + reservation bound it.

## To deploy later (owner gates, in order)
1. Review/merge this branch. 2. Apply the two migrations to production (bundle dist/APPLY_ALL.sql is current). 3. Deploy bot code only if adapters are wired in (they are not called by anything yet). 4. Owner registers an executor with real caps (SQL, owner only).
