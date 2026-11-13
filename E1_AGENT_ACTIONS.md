# E1: Agent action tools (design proposal)
Status: DESIGN ONLY. Nothing here is built, migrated or approved. All SQL/Python below is a proposal.
Method: read the files named in section 1 on branch `stream/e1-design` (base db99772). Not verified: live DB state (no live access used), live `action_policy` rows beyond the seed in `20261112_permissions_v1.sql` (CAPABILITY_GAP_ANALYSIS says 22 `live_only` rows exist live), how the 30 pre-Nov-12 live migrations define `agents`/`tasks`/`audit_log`, and runtime behaviour of any tool.

## 1. Controls that exist today
| Control | Where | Protects |
|---|---|---|
| Spend gateway | `reserve_llm_budget` (`20261113_mission_guard_v1.sql`, latest body), `settle_llm_call`, table `llm_calls` | Model spend: kill switch, capital hard-stop/low-cost, agent status, per-agent and company daily caps, then `mission_guard`. Advisory lock 7331 |
| Mission guard | `mission_guard`, `set_focus_mission`, step-limit triggers | Per-mission AI budget; focus mode (only the focused mission's tasks spend); `max_steps` |
| Python meters | `hq_meter.reserve/_reserve_cents/MeterBlocked` (fail closed), `hq_engine.run_turn_sync` (reserve, then `_complete`, then settle) | Every provider call is reserved first; a refusal never reaches the provider |
| Permission engine | `action_policy` (default-deny, tiers green/yellow/red/prohibited, per-action/day/week limits, `live_only`), `authorize_action`, `action_log`, `record_action_result`, `audit_policy_change` (owner-only edits), no-delete trigger | Any external action. Order: kill switch, unknown=deny, prohibited, dry_run vs `live_only`, red/approve_first needs an `approval_requests` row (one use), then limits. Python client `hq_policy.authorize` falls back to green-only if the DB is unreachable |
| Owner approval | `approval_requests` (pending/approved/used/expired, 7-day expiry), `hq_policy.request_approval/decide_approval` | Matches on `(action, ref, cents >= requested)`; consumed on use |
| Capital controller | `capital_policy`, `capital_snapshot`, `reserve_spend`/`settle_spend`/`release_spend`, `spend_reservations`, `hq_capital` | Non-AI money: $25/txn, $75/week, $50 reserve, $20 hard stop; receipt required to settle; calls `authorize_action` itself |
| Payments | `prepare_payment/decide_payment/confirm_payment`, `payment_instructions`, `hq_payments` | Agents never move money: owner pays in RBC and confirms |
| Outbox rules | `enforce_outbox_rules` (draft, then a different QA agent, then approved, then sent; DNC; kill switch; dry_run; 1 contact per lead per day), `outbox_send_policy` trigger, `hq_mail.refusal/profile_refusal/deliver_approved` | Email: CASL footer per venture, DNC, owner approval, `sent_by='owner'` bypass only for the owner's own record |
| Org limits | `create_agent` (cheap/standard only, cap <= 50c, no owner contact, 3/week), `hq_org` | Agent sprawl |
| Kill switch / dry_run | `system_state.kill_switch`, `.mode`; enforced in engine tick, gateway, `authorize_action`, outbox trigger, `hq_mail.live()` | Global stop |
| Lockdown | `lockdown_v1` (revoke anon/authenticated on all functions; service_role only) | Only the bot's service key calls RPCs |
| No-bypass tests | `test_no_bypass.py` (36), `test_spend_paths.py` (allowlist of 4 `.messages.create` sites; `reserve_llm_budget` before `_complete`) | Static plus behavioural proof that spend paths are gated |
| Tool registry | `hq_tools.py`/`tool_registry` | Records recurring charges only; it does not authorize or execute anything |

Gaps found while reading (all observations; none changed):
1. **Agents have no execution tools.** `_complete` only offers Anthropic `web_search`/`web_fetch`; agent output is parsed by regex (`_store_leads`, `_store_drafts`, `_queue_next`). Side effects happen only via the engine's own code (`hq_mail.deliver_approved`).
2. **No per-agent tool allowlist.** `action_policy` is keyed by action only, not by actor. Any actor name passes if the action is green. Default-deny is per action, not per agent-action.
3. **`authorize_action` is not idempotent.** Each call writes an `allow` row that counts toward the daily/weekly limits. `hq_mail.deliver_approved` calls `authorize`, then the PATCH to `sent` fires `outbox_send_policy`, which authorizes again: two `allow` rows per send, so `send_email` 20/day is likely about 10 real sends (from code reading; not run). A retry after a provider failure also burns allowance.
4. **Approval match is loose:** `cents >= p_cents` and `ref` equality only. Approval binds to a ref string, not to a hash of the payload, so a ref whose content changes after approval would still match.
5. **`action_log.result` is write-once and set by the caller** (`record_action_result ... where result is null`), so a crash between acting and recording leaves "unknown".
6. `reserve_spend` finds its `action_log` row with `order by id desc limit 1` per actor/action. This races with concurrent calls (the lock 7333 differs from authorize's 7332).

## 2. Action tool catalogue
Tiers: A read-only; B reversible internal; C external or communication; D money; E irreversible.
Approval modes: A none; B none (audited); C owner approval per item (draft, approve, send), with batch approval only by owner; D reserve plus owner approval plus owner executes; E owner approval plus typed confirmation, and no agent executes in E1.
Every tool: runs `dry_run=true` by default (returns the exact would-be request, writes only an `agent_action_runs` row with `status='dry'`), and the live path needs `live` flag, mode live, and policy allow.

| Tool (action name) | Tier | Gate(s) | Irreversible part | Idempotency key | Audit rows | Dry-run | Rollback |
|---|---|---|---|---|---|---|---|
| `fetch_url` (new, green) | A | kill switch, allowlist, rate limit, mission budget (counts as a fetch) | none (SSRF risk, see 4) | `sha256(url)` per task | `agent_action_runs`, `action_log` | resolve and validate URL, do not request | n/a |
| `read_lead`, `read_ledger`, `read_memory` (green) | A | allowlist | none | n/a | runs row | schema-check only | n/a |
| `write_file` (workspace only, `internal_document`) | B | allowlist, size cap, path jail | overwrite | `(task_id, path, sha256(content))` | runs row plus content hash | write to `…/.dry/` shadow, diff only | prior version kept |
| `update_lead`, `update_deal` (`update_internal_records`) | B | allowlist, field allowlist, DNC cannot be unset by agents | none | `(entity, id, patch hash)` | runs row with before/after JSON | return diff | restore `before` JSON |
| `create_task` (`manage_tasks`) | B | `dedupe_key`, mission step limit trigger | none | existing `tasks.dedupe_key` | runs row | return would-be row | cancel task |
| `draft_email` (writes `outbox` draft) | B | `enforce_outbox_rules`, one draft per lead index | none | `(lead_id, sequence)` | runs row, outbox row | return text | delete draft |
| `create_calendar_event` (new yellow `calendar_event`, internal calendar only, no invitees) | B/C | policy limit/day | event exists | `(title,start,end)` hash | runs row plus provider id | return payload | delete event by provider id |
| `calendar_invite_external` | C | owner approval per event | invite sent | as above plus attendee list | as above | payload | cancel (apology cannot be recalled) |
| `send_approved_email` (`send_email`) | C | existing outbox chain (draft, QA by a different agent, owner approved), CASL profile, DNC, dry_run, kill switch, policy | email delivered | `outbox.id` (state `approved` to `sent` is single-shot) | runs row, `action_log`, outbox, provider id | render final message and footer, run all refusals, no send | none (recall impossible): the reason it is tier C |
| `publish_post` (`publish_content`) | C | owner approval of exact text hash, 5/day | public | `(channel, text hash)` | runs row plus post URL | render | delete post where API allows |
| `deploy_website` | C | policy 3/day, owner approval | public | `(site, commit sha)` | runs row | preview URL only | redeploy previous sha |
| `create_account` | C | policy 2/day; no KYC/payment/CAPTCHA (prohibited `bypass_verification`) | account exists | `(vendor, email)` | runs row | validate only | close account (manual) |
| `spend_on_tool` (`subscription_purchase`/`software_purchase`/`routine_expense`) | D | `reserve_spend` (capital) then `authorize_action`; E1d: owner approval always | money spent | `spend_reservations.id` | reservation, `action_log`, ledger, `tool_registry` | `reserve_spend` is NOT dry (it writes a reservation). Dry path calls `capital_snapshot` only and reports "would be allowed/denied" | `release_spend` before pay; refund is manual |
| `prepare_payment` | D | existing `prepare_payment`; owner pays | none by agent | `payment_instructions.id` | existing rows | snapshot check only | `decide_payment(false)` releases funds |
| `sign_contract`, `financial_transfer`, `close_venture` | E | red tier | all | n/a | n/a | n/a | **Not implemented as tools in E1.** Agents may only `request_approval`; a human does it |

Rule: a tool exists only if its row exists in `action_policy` (or in `agent_tool_grants` below, for green A/B tools) and in the code registry. Missing in either place means deny.

## 3. Architecture: one execution gateway
Single chokepoint `hq_actions.execute()` (Python) backed by one DB function `gate_action()`. No other module may import a provider client (enforced by a no-bypass test, section 6). The model never holds credentials or calls providers: it emits a structured *action request*; the engine executes it through the gateway.

```
agent turn (run_turn_sync) -> emits ACTION blocks (JSON, schema-validated)
   -> hq_actions.execute(req)
        1. validate schema (per-tool JSON Schema, extra keys rejected, size caps)
        2. gate_action(): kill switch, agent grant, policy (authorize_action), mission/focus, rate limit, idempotency
        3. dry_run default: run adapter.plan() only
        4. live: adapter.run() inside the claim row; record result and evidence
        5. verifier-visible evidence row
```

### Proposed tables (new migration, additive)
```sql
create table agent_tool_grants (            -- default-deny allowlist per agent per tool
  agent_slug text references agents(slug), action text references action_policy(action),
  max_per_day int not null default 0 check (max_per_day >= 0),
  max_per_mission int, live_enabled boolean not null default false,   -- dry-run only until the owner flips it
  granted_by text not null check (granted_by like 'owner%'), granted_at timestamptz default now(),
  primary key (agent_slug, action));          -- trigger: only owner%, no delete by agents, audited like audit_policy_change
create table agent_action_runs (
  id uuid primary key default gen_random_uuid(),
  idem_key text not null, agent_slug text not null, action text not null,
  task_id uuid, mission_id uuid, venture_id uuid,
  args jsonb not null, args_hash text not null,           -- sha256 of canonical args
  status text not null check (status in ('dry','denied','awaiting_owner','claimed','ok','failed','unknown','rolled_back')),
  dry_run boolean not null default true,
  action_log_id bigint, approval_id uuid, reservation_id uuid,
  result jsonb, evidence text, provider_ref text, before_state jsonb,
  created_at timestamptz default now(), finished_at timestamptz,
  unique (action, idem_key, dry_run));                   -- double execution is a unique violation
```
Plus `action_rate_limits` is not needed: counts come from `agent_action_runs` plus the existing `max_count_per_day`.

### Interfaces (proposed)
```python
# hq_actions.py
@dataclass
class ActionRequest: agent: str; action: str; args: dict; task_id: str|None; mission_id: str|None; venture_id: str|None; idem_key: str|None=None
@dataclass
class ActionResult: status: str; run_id: str; dry_run: bool; reason: str; evidence: str|None=None
def execute(req: ActionRequest, *, live: bool=False) -> ActionResult   # the only public entry; never raises, fails closed
TOOLS: dict[str, ToolSpec]  # ToolSpec(schema, tier, plan(args)->dict, run(args)->Evidence, rollback(run)->None, egress_hosts)
```
```sql
create function gate_action(p_agent text, p_action text, p_args_hash text, p_idem text, p_cents int,
   p_task uuid, p_mission uuid, p_venture uuid, p_dry boolean) returns jsonb  -- security definer, service_role only
```
`gate_action` does, in one transaction under one advisory lock: (1) kill switch; (2) grant row exists and (live requires `live_enabled`); (3) mission still active and, if `system_state.focus_mission` is set, the request's mission equals it (same rule as `mission_guard`, so tools cannot run for the backlog during focus mode); (4) per-day / per-mission counts from `agent_action_runs`; (5) idempotency (`insert … on conflict do nothing`; a duplicate returns the earlier result); (6) **only for non-dry** calls, calls `authorize_action` ONCE, passing `p_ref = args_hash` so owner approval binds to the exact payload. Dry runs never call `authorize_action` (they must not consume limits or approvals; they read the policy row instead).

This fixes gap 3 (one authorization per execution, keyed idempotently) and gap 4 (approval bound to a payload hash). `send_approved_email` keeps its existing path; the gateway wraps it and `hq_mail.deliver_approved` is routed through `execute` in E1c (the outbox trigger's second `authorize` call must be removed or de-duplicated; see section 5).

### Composition with the mission engine
- A mission step may request actions only by emitting ACTION blocks that `execute()` handles; `hq_missions` gets no provider access. Steps are tasks, so `mission_id` flows into `gate_action`; mission budget (`mission_guard`) still applies to the model call that proposed the action, and action cost (tier D) is charged to the mission via `reserve_spend(p_mission)`.
- Verifier evidence: the verification prompt is given the step's `agent_action_runs` rows (status, `provider_ref`, `evidence`) as DATA. `VERIFIED: YES` for a step that claims an action requires a matching row with `status='ok'`; an `ok` row with null evidence is treated as unverified. Dry rows do not count as done. (Proposed change to `hq_missions` verifier prompt; code outside the protected set.)
- `blocked` classification gets one new kind, `owner_action` (status `awaiting_owner`), which waits like an owner question.

## 4. Threat model
| Threat | Mitigation |
|---|---|
| Prompt injection via fetched pages/emails ("send this email", "call tool X") | Fetched/inbound text is wrapped as DATA and never grants anything: authority comes only from `agent_tool_grants` + policy + owner approval. Actions that carry tainted content (anything following a `fetch_url` in the same task) are forced to tier-C handling: owner approval of the exact text hash. Tool args are re-validated against schema; URLs/emails in args must be allowlisted or owner-approved |
| Confused deputy (low-privilege agent asks a high-privilege one/engine to act) | Grant is checked on `req.agent`, derived from the task's assigned agent by the engine, never from model text. No tool accepts `agent` or `as_user` args. Cross-agent delegation creates a task; it does not transfer grants |
| Replay (old approved request re-submitted) | `approval_requests` is one-use and expires in 7 days; approval bound to `args_hash`; `unique(action, idem_key, dry_run)` |
| Double execution (retry after timeout, parallel tick) | Claim row inserted before the provider call; `status='claimed'` with no finish within N minutes becomes `unknown` and is never auto-retried for tiers C-E (owner reconciles); provider-side idempotency keys where supported (Resend `Idempotency-Key`) |
| Budget bypass via tools (tool that calls an LLM or buys something) | No tool may call a model except through `hq_meter`/`run_turn_sync`; paid tools must call `reserve_spend`; `test_spend_paths`-style test forbids provider hosts outside adapters. Tool outputs fed back to the model are metered because the next turn reserves normally |
| Exfiltration (secrets or leads in URLs/emails/files) | Egress host allowlist per tool (default none); `fetch_url` GET only, no query strings carrying `lead`/`memory` data (reject args containing registered secret patterns or >N chars of internal data); SSRF block for private IPs/metadata hosts and redirects re-validated; `write_file` path-jailed, no read of env/secrets; outbound email recipients limited to existing leads or owner-approved addresses |
| Agent edits its own grants/policy | `agent_tool_grants` trigger requires `granted_by like 'owner%'` (same pattern as `audit_policy_change`); `modify_own_permissions` stays prohibited. **Weakness to state honestly:** `owner%` is a caller-supplied string (SECURITY_REVIEW residual risk); real protection is that only the service key can reach it, and the bot never exposes it to model output |
| Compromised/over-eager model fabricates "done" | Verifier needs `agent_action_runs.status='ok'` with evidence; `fabricate` stays prohibited |
| Kill switch race | `gate_action` checks it at claim time; adapters re-check before the provider call (as `build_permission_gate` does per tool call) |

## 5. Protected gates: modifications needed
Target: **none to the spend gateway, `reserve_llm_budget`, `mission_guard`, capital functions, `action_policy` rows' semantics, kill switch, or `enforce_outbox_rules`.** The design only adds tables/functions and new `action_policy` rows (insert-only, `on conflict do nothing`, as in existing migrations).

Items that touch protected areas, each needing a separate owner decision:
1. **New `action_policy` rows** (e.g. `fetch_url` green, `calendar_event` yellow): additive. Approval: owner reviews the migration PR. Defaults must be `live_only=true` for anything external.
2. **Double-authorization in the send path** (gap 3). Fix options: (a) leave it and halve the practical `send_email` limit (no change; lowest risk); (b) change `outbox_send_policy` to skip when a fresh matching allow row exists. (b) edits a protected trigger. Recommend (a) for E1c, (b) later. Approval for (b): explicit written owner OK to modify `outbox_send_policy`, with replica SQL tests and rollback script in `ops/`.
3. **`authorize_action` approval match** (gap 4) is NOT changed; the gateway passes `args_hash` as `p_ref` instead, which the existing function already binds on. No edit.
4. **Re-running `lockdown_v1`** after the migration so new functions are service_role only (existing procedure).
5. `hq_meter.py`/`hq_engine.py` are marked protected in the Phase 1 review. E1 adds a new module `hq_actions.py` and a small hook in `hq_engine._work_tasks` result handling (to call `execute` on ACTION blocks). That hook edit needs owner approval as a protected-file change.

## 6. Phased plan
| Phase | Scope | Estimate | Flag | Acceptance |
|---|---|---|---|---|
| E1a read-only | Gateway skeleton, tables, grants, `fetch_url`, `read_*`; dry-run only | 3-4 days | `ACTIONS_ENABLED=0` default; grants `live_enabled=false` | All tools run dry; every call has a runs row; zero provider side effects; injection corpus passes |
| E1b reversible internal | `write_file`, `update_lead/deal`, `create_task`, `draft_email`, `create_calendar_event` (internal) with rollback | 4-5 days | per-tool `live_enabled` | Rollback restores `before_state` byte-for-byte; duplicate call returns earlier result; DNC unaffected |
| E1c external, owner-approved | `send_approved_email` via gateway, `publish_post`, `deploy_website`, `calendar_invite_external` | 5-7 days | needs `mode=live` + grant live + approval | No send without approved row bound to hash; dry_run and kill switch refuse; first live item is one owner-chosen email |
| E1d money | `spend_on_tool` via `reserve_spend` + owner approval; `prepare_payment` wrapper | 3-4 days | off until E1c has 2 weeks of clean runs | Nothing exceeds $25/txn, $75/week; reservation released on failure; ledger+receipt on success |
Total about 15-20 working days. Estimates are rough.

### Kill-switch behaviour
Kill on: `execute()` returns `denied` immediately (no adapter call); in-flight `claimed` rows are re-checked by adapters before the provider call; claimed-then-killed rows become `unknown` and are listed for the owner. Resume does not auto-run denied requests; the agent must re-request.

### Tests
- **Unit:** schema validation, canonical `args_hash`, idempotency, every adapter's `plan()` has no network (patch socket), rollback functions.
- **Replica SQL** (in `sqltests/`, run twice, like Phase 1): `gate_action` under kill switch, dry_run, focus mode, missing grant, daily cap, duplicate key, approval reuse, concurrent claims (two sessions), grant-table owner-only trigger, rollback script.
- **Adversarial/negative:** injected page text asking for email send; tool args with extra keys, oversized, private-IP URL, redirect to metadata host; agent naming another agent; replay of an `used` approval; approval for text A, execution with text B; provider timeout then retry; kill switch flipped mid-run.
- **No-bypass extension** (`test_no_bypass.py` style): static scan that provider hosts/`urllib.request` to non-HQ hosts appear only in `hq_actions.py` adapters, `hq_mail._post`, `hq_meter`/`hq_engine` (known list); every adapter's `run` is reachable only from `execute`; `execute` calls `gate_action` before any adapter `run` (ordering assertion like `test_engine_reserves_before_every_normal_completion`); no `live=True` default anywhere.
- Synthetic tests prove logic only. Real provider behaviour is unproven until the first live item in each phase.

## 7. Open decisions for the owner (recommended default)
1. Approve E1 as designed and in this phase order? (yes, E1a first)
2. Which tools get a first live trial? (`send_approved_email` for one prospect only)
3. Allow the engine hook edit in protected `hq_engine.py`? (yes, minimal, separately reviewed)
4. Double-authorization on send: leave (a) or fix trigger (b)? (a)
5. Batch approval for C-tier items, or strictly one-by-one? (one-by-one for 2 weeks, then batch with a cap of 5)
6. Calendar provider and publishing channels to integrate? (internal calendar only; no social until accounts exist)
7. Per-agent grants: who may hold C-tier tools? (only `donna-ops` and one named agent per venture)
8. Tainted-content rule: force owner approval for any action after `fetch_url` in the same task? (yes)
9. Money tools in E1d at all, or keep `prepare_payment` only forever? (prepare_payment only; revisit after revenue)
10. Fetch allowlist: open web with SSRF block, or curated hosts only? (curated plus owner-added hosts)
11. Unknown-state rows (`claimed` with no result): who reconciles? (owner via Telegram list, never auto-retry)
12. Rate defaults: `max_per_day` for new grants. (0, so owner must set each)
