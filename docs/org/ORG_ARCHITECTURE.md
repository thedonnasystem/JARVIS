# FENDEZY GROUP: company organization architecture (WS3)

Status: **PROPOSAL on branch `build/org-architecture`. Not merged, not deployed, not applied to any database.**
Nothing in this work activates a division, creates or enables an agent, spends money, or changes the kill switch, the spend caps
(the $3.30/day AI cap stays), the action policy, the executor registry (stays empty, default deny) or any privacy control.
All tests are synthetic (scratch Postgres, unit tests). They are not production proof.

| Deliverable | File |
|---|---|
| This document | `docs/org/ORG_ARCHITECTURE.md` |
| Contract (single source for the UI and the seed) | `ops/org/divisions.json`, schema `ops/org/divisions.schema.json`, notes `ops/org/README.md` |
| Validator and tests | `scripts/org_contract.py`, `scripts/test_org_contract.py` |
| Unreleased migration draft | `migrations/20261123_org_divisions_v1.sql`, rollback `ops/rollback_org_architecture.sql` |
| Database proofs | `sqltests/org_architecture_check.sql` (runs inside `scripts/replica/run.sh`, so inside the gate) |

## 1. What already exists (inspected, reused, not duplicated)

| Need | Existing object | Used how |
|---|---|---|
| Group of agents | `departments` (slug, kind venture/shared/holding, status) and `agents.department_slug` | Team membership stays here. No second membership table. |
| Agents and their limits | `agents` (status, `daily_spend_cap_cents`, `can_contact_owner`), `create_agent`, `ensure_venture_agents` (creates paused) | Division seats become agents only through these, later. |
| Business units | `ventures`, `venture_config`, `venture_goals`, `venture_kpis`, `activate_venture` | A division may point at a venture (`existing_refs`). |
| Corporate office | `office_data()` view over nine functions (`20261112_office_v1`) | The corporate offices. No new table. |
| Org proposals | `org_changes` (kinds agent/department/venture/workflow/tool/shutdown) | How Jarvis or a manager proposes change. |
| Missions and tasks | `missions`, `tasks`, `mission_guard`, plan and step limits | Division missions are ordinary missions. |
| Spend | `reserve_llm_budget`, `reserve_spend`, `spend_reservations`, `llm_calls`, `capital_policy`, `system_state.daily_spend_cap_cents` | The only spend path. The org layer adds no second path. |
| Permissions | `action_policy`, `authorize_action`, `approval_requests`, kill switch in `system_state` | Unchanged. The org layer can only narrow. |
| Executors | `executor_registry`, `executor_request` | Unchanged, empty. Not delegable to a division. |
| Books | `ledger`, `ws_ledger` (per client workspace) | Division ledger is a filtered view of these, later. No new ledger. |
| Client isolation | `client_workspaces`, `ws_*`, `ffm_*` with guarded functions | Unchanged. Divisions get no direct access. |
| Performance | `agent_scorecard`, `venture_kpis`, `lead_funnel`, `ffm_weekly_report` | KPI values are computed from these. |

What the existing schema could **not** hold: a division's lifecycle state that is independent of `departments.status` (which only
knows active/paused/parked and defaults to active), a per-division allow-list of delegated permissions, and a per-division budget
proposal. Those three things are the whole migration. Charters, objectives, manager profiles, team skeletons, KPI definitions and
mission templates are text and stay in the git-reviewed contract file, not in the database (section 9 explains why).

## 2. Model

```
Chairman (owner)  -- the only principal that can stage, grant, fund or activate
   |
 Jarvis (COO)     -- routes, consolidates, proposes; cannot activate, grant or fund
   |
 Corporate offices (9 existing functions: views over real agents and data)
   |
 Division  --1:1-->  division manager (role profile; an agent only after activation)
   |-- team seats (role skeleton; agents only after activation, created paused through create_agent)
   |-- delegated permissions (allow-list rows; default deny)
   |-- budget envelope (a sub-limit of the company cap; zero until activation)
   |-- KPIs (definitions in the contract; values from existing views)
   `-- mission templates (become ordinary missions through the mission engine)
```

Entities and where they live:

| Entity | Contract (`divisions.json`) | Database (migration draft) |
|---|---|---|
| Division identity, state | `id`, `name`, `status` | `org_divisions` (slug, name, status, contract_version) |
| Charter, objectives, responsibilities | yes | no |
| Manager profile, team skeleton | yes | no (agents later, through `create_agent`) |
| Delegated permissions | `delegated_permissions.allow` | `org_division_grants` (dormant rows) |
| Budget envelope | `budget` | `org_divisions.envelope_daily_cents` (fixed 0), `proposed_daily_cents` |
| KPI definitions, mission templates | yes | no |

### Lifecycle

| State | Meaning | Contract v1 | Database v1 |
|---|---|---|---|
| `dormant` | Listed. Nothing granted, nothing funded, no agents. | the only allowed value | default; all 8 seeded rows |
| `staged` | The Chairman has read the charter and allow-list and puts the division forward. May hold a non-binding budget proposal. Still grants nothing and spends nothing. | not allowed in the file | owner-only `org_stage_division` |
| `active` | Grants effective, envelope above zero, agents may be woken. | not allowed | **refused by CHECK constraint**; needs a later migration |

Who may change what:

| Change | Chairman | Jarvis / any agent / bot (`service_role`) | Engineering (PR) |
|---|---|---|---|
| Edit charter, objectives, KPIs, templates | approves | may propose through `org_changes` | edits the contract in a reviewed PR |
| dormant to staged, staged to dormant, budget proposal | yes (owner-only functions) | **no** | no |
| Grant or widen a permission | only through the activation release | **no** | writes the migration, cannot apply it without release authorization |
| Set an envelope above zero, activate | only through the activation release | **no** | same |
| Kill switch, spend caps, executor registry, privacy controls | existing owner controls | no | not touched by this layer |

## 3. The eight divisions

**The repository does not define eight divisions.** It defines four ventures in the seed (`donna`, `idea-lab`, `day-job-sales`,
`real-estate`), names two parked ventures in the audit document (music, soccer), has FF Marketing as a client-workspace system, and
has one shared department (`research`). The list below is assembled from those. Rows marked *inferred* are my inference and are
flagged `"inferred": true` in the contract. This is OWNER DECISION D1. No strategy was invented for the parked ones: their charter
says "Parked. No charter has been written by the owner."

| # | id | Name | Basis in the repo | Inferred |
|---|---|---|---|---|
| 1 | `donna` | Donna System | venture `donna` | no |
| 2 | `ffm` | FF Marketing | `client_workspaces`, `ffm_*` (FFM_OS_OVERVIEW.md) | no |
| 3 | `real-estate` | Real Estate | venture `real-estate`, wholesale bridge | no |
| 4 | `day-job-sales` | Day-job Sales | venture `day-job-sales`, `dayjob_*` tables | no |
| 5 | `idea-lab` | Idea Lab / New Ventures | venture `idea-lab`, venture factory | no |
| 6 | `research` | Research & Intelligence | shared department `research`; overlaps the office function of the same name | **yes** |
| 7 | `music` | Music | audit document only ("parked"); slug not verified | **yes** |
| 8 | `soccer` | Soccer | audit document only ("parked"); slug not verified | **yes** |

Every charter in the contract is an operator draft (`authored_by: operator_draft`, `owner_approved: false`). None is approved.

## 4. Corporate offices and Jarvis

Corporate offices are the nine functions that already exist as live views in `office_data()`: Executive, Business Development,
Research & Intelligence, Engineering & Technology, Marketing & Media, Sales & Customer Acquisition, Finance & Treasury, Operations,
Agent Management. They are shared services across divisions, computed from real agents and data. This layer adds no office table
and no office agents. The contract lists them (`corporate_offices`) so the UI can show them next to the divisions.

Jarvis is the chief operating officer. He is the only agent that contacts the Chairman (existing `can_contact_owner` rule; the
validator refuses any division manager with it). He routes work to division managers, consolidates their reports and files
proposals in `org_changes`. He may **not** activate a division, grant or widen a permission, set or raise an envelope, or change
the kill switch, caps, executor registry or privacy controls. In the database he is the bot like every other agent: he runs as
`service_role`, which has read-only access to the org tables and is refused by every owner function.

## 5. Delegation and permission model

1. **Default deny.** No row means no. `org_division_may(division, capability)` is true only when the kill switch is readable and
   off, the division is `active`, and a `granted` row exists. In v1 neither state can exist, so it is false for everything.
2. **Least privilege.** A division's allow-list names single capabilities from a fixed catalog of twelve (`global.capability_catalog`),
   each scoped to `own_division` (or `own_workspaces` for FF Marketing only). There is no wildcard and no cross-division scope.
3. **Owner-only grants.** No function writes `org_division_grants`. Rows come from a migration, which needs release authorization.
4. **Never delegable.** Capabilities that would let a division change its own limits or reach a protected control are refused in
   three places: the validator's built-in list (the contract cannot shrink it), the contract's own list, and a CHECK constraint on
   the table. Prefixes: `kill_switch. spend_cap. budget. grant. delegation. division. permission. executor. payment. bank. backup.
   deploy. migration. owner. privacy. consent. secret.` plus `outbox.send`, `agent.create`, `agent.activate`.
5. **Kill-switch supremacy.** With the kill switch on (or unreadable) the guard is false, staging and proposals are refused, and
   only the step back to dormant is allowed. The existing gateway, executor gate and `authorize_action` already stop on it.
6. **Narrow only.** A division grant is necessary, never sufficient. `authorize_action`, the autonomy tiers, approvals, the spend
   gateway and the executor gate still decide. The org layer never widens what they allow.

## 6. Budget and ledger

- **One spend path.** Every cent goes through the existing gateway (`reserve_llm_budget` for model calls, `reserve_spend` for the
  rest), which already enforces the kill switch, capital mode, the per-agent cap and the company cap. The contract fixes
  `spend_path: spend_gateway_only` (schema constant).
- **Envelope = sub-limit, not extra money.** A division envelope is a ceiling inside the company cap. It can never add to it.
  In v1 `envelope_daily_cents` is CHECK-constrained to 0.
- **Proposal.** A staged division may carry `proposed_daily_cents`, an owner note for the activation review. A trigger keeps the
  sum of all proposals at or below `system_state.daily_spend_cap_cents` for every writer; if the cap is unreadable a non-zero
  proposal is refused. The contract validator applies the same rule against the stated 330 cents.
- **No second ledger.** A division's books are a filter over existing rows: `llm_calls` by agent (agents belong to the division's
  department), `spend_reservations`, `ledger` by venture, `ws_ledger` by workspace. A read-only view is future work for the
  activation release, when membership exists.
- **Not done here, required before any activation:** the envelope check must sit inside the gateway (a new, reviewed version of
  `reserve_llm_budget`). Until then an envelope would be advisory, which is why this schema cannot hold a non-zero one.

## 7. KPIs and reporting

KPI definitions (id, name, unit, direction, source, target) live in the contract. Every division carries three common ones from
`agent_scorecard` (spend 7d, tasks done 7d, cost per done task) plus its own, each naming the existing view or table that produces
the number. Targets are `null`: the Chairman sets them (D5). Values are computed, never typed by an agent. Reporting path: division
manager publishes numbers (`kpi.report`), Jarvis consolidates, the Chairman sees one report. If history is wanted later, a
numbers-only snapshot table (no text) is the right addition.

## 8. Missions and workflow

A division mission is an ordinary row in `missions`, run by the existing mission engine with its guards and limits. Templates in
the contract give title, objective, success definition and the capabilities needed. Rules checked by the validator: a template
cannot need a capability outside its division's allow-list, its budget is 0 and its status is dormant. Flow after activation:
manager proposes (`mission.propose`), the Chairman or the existing approval path accepts, the engine runs it, spend goes through
the gateway inside the envelope, evidence and outcomes land in the existing tables. Template text is operator-authored and is
passed as data, never as instructions, to any agent.

## 9. How divisions stay inactive, and how one is activated later

Inactive by default, in layers:
1. Contract: validator refuses any status but `dormant`, any non-zero budget, any non-dormant grant, any created agent.
2. Database: `active`, a non-zero envelope and `granted` violate CHECK constraints, for every role including the table owner.
3. Privileges: RLS on with no policy; anon and authenticated have nothing; `service_role` may only read; owner functions call
   `is_app_owner()`; no `app_*` wrapper is opened, so in production nobody can call them until a release opens one.
4. Nothing else looks at these tables: no existing function, trigger, engine path or UI reads them.

Activation gate (a separate owner-approved release, one division at a time), in order:
1. Chairman approves the charter (D2) and the allow-list for that division; contract PR sets `owner_approved`.
2. New migration: widen the status and grant CHECKs, add the envelope check to the spend gateway, add an owner-only
   `org_activate_division` that requires an `approval_requests` row and kill switch off, bind the division to its department.
3. Gate 9/9, independent security review, release authorization, apply, post-release verification.
4. Agents are created **paused** through `create_agent`, then woken one by one by the Chairman.
5. First week: one-by-one approvals; envelope starts at the smallest useful amount.

## 10. Isolation

- **Between divisions.** Grants are scoped to `own_division`; the schema has no cross-division scope and the validator refuses
  `reads_other_divisions`. The guard takes the division as an argument and answers for that division only. Honest limit: row-level
  separation of `memory`, `tasks` and `missions` by division does not exist yet (those tables have no division column and this
  work does not add one). It must be built in the activation release before two divisions are active at once.
- **From client workspaces.** No org table references `client_workspaces`, `ws_*` or `ffm_*`. Only FF Marketing may hold the
  `own_workspaces` scope, and only for `workspace.read` meaning aggregate figures through the existing guarded functions. Client
  personal data stays behind `ws_guard` / `ffm_guard` and out of off-site backups (deny by name pattern, unchanged).
- **From the money and control plane.** Never-delegable list, section 5.

## 11. Data classification

| Table | Class | Why |
|---|---|---|
| `org_divisions` | `internal` (exported) | slug, operator-seeded name, state, integers. No function updates `name`. No free text from agents, no json column. |
| `org_division_grants` | `internal` (exported) | constrained identifiers only (regex and enum CHECKs). |

Added to `backup_classification()` in the same migration (the function is re-declared with the full 20261119 list plus two rows;
`B5 no unclassified table` still passes). Charters and other prose are not in the database at all, so the rule "free text written
by agents is BLANK/STRICT" is met by having no such column. If a later version stores agent-written text for a division, that
column must be classified BLANK or STRICT in the export policy before it ships.

## 12. Threat model for the org layer

| Threat | Control | Proof |
|---|---|---|
| A division (or the bot) activates itself or another | `active` refused by CHECK; no write privilege; owner functions refuse the bot | sqltest B1, C; unit `NoActivation` |
| Privilege escalation between divisions | no cross scope; no function writes grants; never-delegable list in three places | sqltest E; unit `NoSelfEscalation` |
| A manager grants itself a capability | grants are not writable by any function or by `service_role` | sqltest B1, E2 |
| Budget bypass (spend outside the gateway) | the layer has no spend function; envelope fixed at 0; guard is "necessary, never sufficient" | sqltest C1, C2, D |
| Envelopes that add up to more than the cap | trigger on every write; validator S6 | sqltest C; unit `Budget` |
| Cap lowered after proposals were made | proposals are non-binding; the gateway cap decides at spend time; re-validate at activation | design; **not tested** |
| Agent-written text leaks PII into backups | no free-text or json column; names only from the migration seed; validator S12 screens the contract for email/phone shapes | sqltest G4, G5; unit `Hygiene` |
| Prompt-injected mission ("activate division X", "raise the budget") | no capability for it exists; templates are operator text; a mission can only use capabilities on its division's allow-list | unit S8; sqltest E |
| Injected text in an `org_changes` proposal persuades the owner | proposals remain owner-decided; this layer adds no auto-apply path | existing behaviour, unchanged |
| Kill switch ignored | guard false, staging refused while on or unreadable | sqltest F |
| Contract edited to look active for the UI | validator in the gate (`scripts-tests`), seed drift test | unit `Seed`, `NoActivation` |
| Migration re-declares the classification and drops a row | count and class checks; md5 equal after rollback and re-apply | sqltest G6, G7, H |

## 13. Org layer security self-review

| # | Property | Result | Evidence |
|---|---|---|---|
| R1 | No division can be activated by the bot / service role | PASS (scratch) | sqltest B: 13 statements refused with `permission denied for table` or `owner approval required`; A4 no write privilege |
| R2 | No division can be activated by anyone with this schema | PASS (scratch) | sqltest C: CHECK refuses `active`, envelope > 0, `granted` |
| R3 | Budget envelope cannot exceed the global cap | PASS (scratch) | sqltest C: cap+1 refused, sum rule refused through function and direct write; unit `Budget` |
| R4 | A dormant division cannot create missions or spend | PASS (scratch) | sqltest D: guard false for 8 divisions x 12 capabilities and all amounts; no org trigger or column on existing tables |
| R5 | Delegation cannot self-escalate | PASS (scratch) | sqltest E: 21 protected capabilities refused; unit: contract cannot shrink the list |
| R6 | Kill-switch supremacy | PASS (scratch) | sqltest F |
| R7 | New tables classified; nothing became exported that was excluded | PASS (scratch) | sqltest G |
| R8 | Rollback removes exactly this layer; migration re-applies | PASS (scratch) | sqltest H (rollback twice, then re-apply, in one rolled-back transaction) |

The SQL checks were mutation-tested by hand once (grant update to the bot, drop the status CHECK, disable the trigger, make
`is_app_owner` return true): each mutation made the test fail.

Findings and limits of this review (read before relying on it):
1. **R4 is true because nothing is wired, not because the gateway checks it.** Today's missions, tasks and spend do not consult
   the org layer at all. Existing active agents (the audit counted 31) keep working under the existing controls, whatever their
   division's state. "Dormant" governs the new layer only. Binding existing agents to divisions is D3.
2. The replica's `service_role` does not bypass RLS; production's does. The proof that matters for production is the table
   privilege (revoked) and the owner check, both tested. Not verified on a real Supabase project.
3. `backup_classification()` is re-declared. If another branch also re-declares it, the later file wins and can silently drop
   rows (fails closed: the table becomes unclassified and is not exported, and `B5` fails). Checked: the leak, consent and
   insurance branches do not re-declare it (one alters its `search_path` after lockdown, which still applies).
4. The owner functions are callable only in tests today. No app wrapper exists, by design.
5. Self-review by the author. An independent review is still required before any release.

## 14. Migration-free fallback

If the migration is judged too early, drop `migrations/20261123_org_divisions_v1.sql`, `ops/rollback_org_architecture.sql`,
`sqltests/org_architecture_check.sql`, the `APPLY_ORDER.txt` line and the six `org_*` lines in `ops/EXPECTED_NEW_FUNCTIONS.txt`,
remove the two seed tests in `scripts/test_org_contract.py`, and rebuild the bundle. The contract, schema, validator and this
document stand on their own; the UI needs only the JSON. My assessment: the migration is low risk (additive, nothing reads it,
cannot activate anything) but has no user until activation, so shipping docs + JSON first and the migration with the activation
release is equally defensible. That is D6.

## 15. Owner decisions

| ID | Decision | Options | Consequence |
|---|---|---|---|
| D1 | Which eight divisions | (a) accept the list in section 3; (b) drop music/soccer and research, run five; (c) name different ones | (a) reserves places for parked items with empty charters; (b) is closest to what the repo proves; (c) needs your list. Contract and seed change with it; cheap now, a new migration after release. |
| D2 | Charters | approve, edit or rewrite each draft | No division can be staged for activation without an approved charter. |
| D3 | Existing agents | (a) leave them outside the org layer until each division activates; (b) bind them to divisions now (they keep running); (c) pause them until their division is active | (a) default, changes nothing; (c) stops current work. |
| D4 | Envelope rule | (a) proposals sum to at most the company cap (built); (b) each at most the cap, overlap allowed | (b) lets divisions compete for the same cents; the gateway cap still wins either way. |
| D5 | KPI targets | set per division, or leave empty | Empty targets mean reports show numbers without pass/fail. |
| D6 | Ship the migration now or with activation | (a) now, dormant; (b) docs + JSON only for now | (a) schema is in place and proven early; (b) fewer objects in production with no user. |
| D7 | Research: division or corporate office | division (as listed) or office only | Affects D1 count and who pays for research. |
| D8 | First division to activate, and when | any one, after first mission proof | Starts the activation release in section 9. |

## 16. Not verified

- Nothing was run against production, Supabase, Railway or Render. All database results are from a private scratch Postgres 16.
- The slugs `music` and `soccer` and the live value of the company cap (330 cents stated; replica seed says 300) were not checked
  against the live database.
- `scripts/acl_manifest.py` and `ops/ACL_MANIFEST_public.tsv` do not exist on `overnight-build`, so no ACL manifest was
  regenerated here. Integration must regenerate it, the bundle, `APPLY_ORDER.txt` and `EXPECTED_NEW_FUNCTIONS.txt`.
- Interaction with the 20261120 to 20261122 migrations was read, not run together.
- The UI (WS2) reading the contract was not tested by me.
