# Agent Swarm POC Report (Fendezy HQ, Workstream 2)

Date: 2026-11-15 (sandbox clock). Repo: desplega-ai/agent-swarm, commit 0b75197, package v2.13.2. Everything ran in `/home/claude/sandbox/`. No production credentials, no model key, no push, no external contact (see Telemetry for the one deliberate loopback test).

## Verdict
**Conditional GO for a gated pilot, NO-GO for any live run today.**
- The control plane works offline and the HQ gate can wrap it cleanly (proven with fake RPC + a live local server).
- Nothing involving a real LLM worker, container isolation, or cost has been verified. Those need Docker plus a funded key, both owner actions.

## 1. License and project facts
- MIT, "Copyright (c) 2025-2026 desplega.sh". Commercial use and modification are allowed. The only obligation is keeping the notice.
- SECURITY.md: private report by email; no LTS, no backport promise, no response SLA.
- Solo/small-vendor project (maintainer Taras). Very fast release cadence: 2.13.2, compose examples at 1.150.0. Version pinning is mandatory.
- Dependency licenses were not audited. One dependency, `xlsx`, is pulled from `cdn.sheetjs.com` (a tarball URL, not the npm registry).

## 2. Architecture (from code and docs)
- **API server**: Bun + TypeScript (`src/http.ts`), SQLite (WAL) with sqlite-vec, port 3013 (compose) or `PORT`. Holds tasks, agents, memory, schedules and the dashboard API. It also serves MCP and has Slack/GitHub/GitLab/Linear/Jira/Email integrations.
- **Lead and workers**: one image (`Dockerfile.worker`, Ubuntu 24.04). Each runs a harness: Claude Code, Codex, pi, opencode, and others. Workers poll `GET /api/poll`, claim a task, work, then call `/finish`. Workers only talk to the API over HTTP.
- **Compose reference** (`docker-compose.example.yml`, 1102 lines): minio + agent-fs, api, lead, 9 workers, caddy.
- Task state machine (`AgentTaskStatusSchema`): draft, backlog, unassigned, offered, reviewing, pending, in_progress, paused, completed, failed, cancelled, superseded, skipped.

## 3. Deployment requirements
| Item | Finding |
|---|---|
| Runtime | Bun 1.4.4 (pinned). Server needs no Node. |
| Storage | SQLite file (`DATABASE_PATH`, `/app/data` volume) plus an auto-generated `.encryption-key` next to the DB. **Back it up: losing it loses all encrypted secrets.** The worker mounts `/logs` and `/workspace/shared`. The compose stack also runs MinIO and agent-fs. |
| Ports | API 3013; worker 3000 (published per worker in compose); agent-fs 7433; MinIO 9000/9001. |
| Auth | One shared `API_KEY` (any string you choose), sent as `Authorization: Bearer`. Workers also send `X-Agent-ID` and `X-Runtime-Instance-ID`. Per-agent worker tokens (`/api/agents/{id}/token`) and per-user `aswt_` tokens exist. SSO is via oauth2-proxy/trusted headers. |
| Model creds (workers) | `CLAUDE_CODE_OAUTH_TOKEN` or `ANTHROPIC_API_KEY`, `OPENAI_API_KEY`, `OPENROUTER_API_KEY`, or Bedrock keys. |
| Other | The reference compose gives every worker the same `API_KEY` plus `GITHUB_TOKEN`. |

## 4. Outbound network calls and how to disable
Found by grepping `src/` and docs, then confirmed by running the server.

| Destination | Purpose | Default | Disable |
|---|---|---|---|
| `proxy.desplega.sh/v1/events` | Anonymized telemetry (server and workers) | **ON** | `ANONYMIZED_TELEMETRY=false` on the API **and** each worker. Also settable in dashboard config, and the stored value wins over env. |
| `proxy.desplega.sh/v1/logo` | Org logo, only if the org website is set | Only when used | Don't set `SWARM_ORG_WEBSITE`. |
| Improvements and feedback send to Desplega | Explicit user action. The install id is sent **even with telemetry off**. | User-triggered | `IMPROVEMENTS_ENABLED=false` |
| `@desplega.ai/business-use` SDK | Flow events, including task `data` scrubbed by `secret-scrubber` | **No-op unless `BUSINESS_USE_API_KEY` is set** (logs one harmless ERROR line at boot: "API key not provided") | Leave `BUSINESS_USE_API_KEY` and `BUSINESS_USE_URL` empty. The SDK default backend is `localhost:13370`. |
| `models.dev/api.json` | Model price catalog refresh at boot and every 12h, plus a vendored offline snapshot | **ON, no off-switch found** | None found. It's a GET that carries no HQ data, but it exposes the server IP. Block it at egress if needed. The snapshot still works, per the code comments. |
| `templates.agent-swarm.dev` | Worker template registry (`TEMPLATE_REGISTRY_URL` in the worker image) | ON for workers | Not tested. Override the env var; unverified. |
| Model provider (`api.anthropic.com`, `api.openai.com`, `openrouter.ai`) | The actual LLM calls | Needs a key | Don't provide a key |
| ghcr.io images (`pull_policy: always`, `:latest` default) | Deployment | | Pin `AGENT_SWARM_VERSION` and digests |
| Integration hosts (Slack, GitHub, Linear, Jira, GitLab, etc.) | Only when configured | Off until configured | |
| `app.agent-swarm.dev` dashboard | Hosted dashboard that connects to your API from the browser | Optional | Use the self-hosted UI (`Dockerfile.ui`) instead |

**Telemetry evidence.**
- **ON by default.** Booting a second instance on loopback with `ANONYMIZED_TELEMETRY` unset and `DESPLEGA_TELEMETRY_ENDPOINT` pointed at a local sink captured 2 events: `telemetry.enabled` and `server.started`. They carried a random `install_...` id, an `org_id`, version, deployment and booleans for channels. Task text was not in them. The sink was loopback, so nothing left the sandbox.
- **OFF works.** With `ANONYMIZED_TELEMETRY=false`, the server pid held no established sockets (`ss -tnp`), and the log showed no telemetry traffic.
- **Not checked.** `models.dev` fetches were not independently observed; the proxy status noted failed connections during the run, which I could not attribute.

## 5. What worked (evidence)
- `bun install --frozen-lockfile`: 1759 packages in 12.7s through the allowlisted registry. This included the `cdn.sheetjs.com` tarball.
- **Docker is unavailable** ("Cannot connect to the Docker daemon"). I ran the API server directly: `bun src/http.ts` with a clean env (`env -i`), a generated throwaway `API_KEY`, `PORT=13999`, SQLite in the sandbox, and telemetry off.
  - 341 migrations applied. `GET /health` returned `{"status":"ok","version":"2.13.2"}`.
  - Auth: no key gave 401, a wrong key gave 401, the right key gave 200.
- **Lifecycle with a stub worker** (`swarm_poc/stub_lifecycle.py`, no LLM; log in `lifecycle.log`):
  - `POST /api/agents` ×2 gave 201 (lead and coder).
  - `POST /api/tasks` gave 201 with status `pending`.
  - `GET /api/poll` as the worker returned `task_assigned`, and the task became `in_progress`.
  - `POST /progress` gave 200. `POST /finish {"status":"completed"}` gave 200 and the task became `completed`.
  - The stub wrote `hello` to `swarm_run/hello.txt`.
- **Gotchas discovered live**:
  - Agent registration requires `runtimeInstanceId`, because multi-runtime mode is on by default.
  - Polling needs the `X-Runtime-Instance-ID` header.
  - `POST /api/tasks` with an `agentId` requires `routingReason` (e.g. `human_pinned`).
  - A finished worker task auto-spawns a lead task: "Worker task completed — review needed" (source `system`, `follow-up`). With a real lead agent, that is an **extra LLM run per worker task**. It must be accounted for in any cost gate or disabled.
- **Offline test subset**: 11 files, **233 pass / 0 fail**, 841 expects, 3.0s. Files: api-key, poll-probe-readonly, secret-scrubber, task-cancellation, task-lifecycle-telemetry, tasks-readable-row, telemetry-context/-endpoint-override/-init/-enable/-trigger. Log is in `swarm_poc/tests.log`. The full suite (1145 test files) was not run.

## 6. HQ integration boundary and prototype
Files are in `/home/claude/sandbox/swarm_poc/`:
- `swarm_adapter.py`: stdlib only, reads no env, takes an injected RPC and HTTP.
  - `SwarmClient`: `create_task` (POST /api/tasks), `get_task`, `cancel_task`.
  - `poll_task`: polls to a terminal state or timeout.
  - `make_work`: builds the `work(run_id)` callable.
  - `gated_run`: line-for-line the same contract as `hq_executor.run`.
  - `run_swarm_task`: ties the above together.
- `test_swarm_adapter.py`: 8 unit tests, **8/8 pass** (`python3 -m unittest test_swarm_adapter`).
- `live_check.py`: the adapter against the live local server (`live_check.log`).

**The wrap.**
1. `executor_request('swarm', agent, hq_task, est_cents, purpose)`. HQ decides: kill switch, registry enabled, allowed agents, per-run cap, daily run cap, `reserve_llm_budget`. If it refuses, or the mode is `dry_run`, **the swarm is never called**.
2. Only on approval: create the swarm task (tagged `run:<run_id>`), then poll.
3. `executor_complete` settles cost. Failed, timed-out or crashed runs settle at the **full reservation**. On timeout the adapter cancels the swarm task first. The default actual cost equals the estimate (conservative) until a real cost source is wired in via `cost_fn`.
4. `executor_expire_stale` in HQ is the backstop if the adapter dies mid-run.

**Evidence the gate holds.**
- Unit tests: a refusal produces zero HTTP calls; a dry_run produces zero HTTP calls; neither settles anything.
- Live, against the real server: a refused run and a dry_run left the task count unchanged (3 → 3) with RPC calls of only `executor_request`.
- Live approved run: the task went pending → completed through a stub worker, then settled `executor_complete`.
- Live timeout: the swarm task ended `cancelled` and the run settled as failed.

**Production swap**: import `hq_executor` and call `hq_executor.run('swarm', agent, task, est, purpose, make_work(...))`. I did not import `hq_executor`, because that imports `hq`, which touches production config.

**Boundary gaps (design, not built).**
- HQ's gate controls only start and settlement. Swarm workers hold their own model key and spend independently. An HQ cap works only if the key is **dedicated, spend-limited at the provider, and used by nothing else**. HQ can't stop a running worker except by `cancel` (POST /api/tasks/{id}/cancel) or by revoking the key.
- The swarm's own lead can create more tasks (the auto follow-up, schedules, Slack and GitHub triggers). Disable those, or only allow HQ-created tasks.
- Real cost is not read back. `/api/session-costs`-style data exists (the OpenAPI schema has `totalCostUsd`), but I did not wire or test it. Settlement is estimate-based until that is done.

## 7. Security findings
- **Container isolation: unverified.** Docker is unavailable, so no worker container was started.
  - From static reading of Dockerfile and compose: workers run as non-root user `worker` via `gosu` after a root entrypoint.
  - The Claude harness runs with `--dangerously-skip-permissions` / `bypassPermissions` inside the container. The container is therefore the only sandbox.
  - I found no `privileged`, `cap_drop`, `read_only` or docker.sock mount in the example compose. I did not look for a `security_opt` setting. Only the api service sets `pids_limit`.
  - Worker ports are published to the host.
- **Auth.** A single bearer key gates everything in the reference deployment, and every worker gets the same `API_KEY`, so a compromised worker holds admin on the swarm. Mitigation: per-agent tokens, and an HQ-controlled network where only the adapter can reach the API.
- **Secrets.** Worker env holds the model key and `GITHUB_TOKEN` in plaintext env. The `.encryption-key` file sits beside the DB. An output scrubber exists (`secret-scrubber`) but wasn't audited.
- **Supply chain.** `:latest` plus `pull_policy: always` by default. An unsigned community MinIO image, which the compose file pins by digest. A tarball dependency from `cdn.sheetjs.com`. Most prominent: very high release churn.
- **Unrequested egress.** Telemetry is on by default and `models.dev` has no off-switch (see section 4).
- **Dashboard.** `app.agent-swarm.dev` is a hosted UI that connects to your API from the browser. Prefer the self-hosted UI.

## 8. What failed or was blocked
- Docker daemon not running: no compose stack, no worker image, no isolation test.
- First stub attempts failed 400 (runtime instance, routing reason, and `agentId` null from the earlier errors). These were API-contract discoveries, not bugs.
- One misleading first live-check failure was my own stub bug (runtime id lookup). It was fixed and re-run.
- A proxy notice about unreachable `example.supabase.co` appeared during one command. I didn't originate that traffic (the server ran with an empty environment); it is probably another workstream.

## 9. Unverified
- Any real LLM worker run, Claude or other harness, and its actual token cost and latency.
- Container isolation, resource limits, network egress from a worker.
- `models.dev` and `templates.agent-swarm.dev` calls in a live run.
- The full test suite (1145 files). The remaining ones may need Docker, network or keys.
- Lead behavior (planning, auto follow-up spend), schedules, memory and embeddings, and the dashboard UI.
- Dependency license audit; backup and restore of SQLite plus the `.encryption-key`.
- `ANONYMIZED_TELEMETRY=false` on a worker container (only verified on the API server).

## 10. Cost drivers (no numbers invented)
- LLM tokens per task: the worker's model, context size and task length. This is the dominant cost and I have no measurements.
- The auto-created lead "review needed" task per worker completion (another LLM run).
- Lead heartbeats, schedules, memory raters (`MEMORY_RATERS` defaults on) and embeddings (an embedding provider key if configured).
- Retries and long-running or stuck tasks. The adapter's timeout plus cancel bounds these.
- Hosting: API container, per-worker containers, MinIO/agent-fs storage. Provider pricing was not looked up.

## 11. Recommendation
- Proceed only as a **pilot with one worker, one lead-free path** (HQ creates tasks; the lead and schedules stay off), `ANONYMIZED_TELEMETRY=false` everywhere, `BUSINESS_USE_*` empty, pinned image versions, and egress limited to the model provider.
- Treat the swarm as an untrusted executor behind HQ. Register it in `executor_registry` as `enabled=false` with small `max_cents_per_run` and `max_runs_per_day`. The owner enables it.
- Before any production use: wire real cost readback, then test one dry-run through the real HQ RPC.

## 12. Exact owner steps still needed
1. Decide the approval gate: provide Docker on a host (not this sandbox) to test container isolation.
2. Create a dedicated model key (Anthropic or OpenRouter) with a **provider-side hard spend limit**. That is a spend decision for you; I have not requested it. Store it only in the worker host's environment, never in the HQ database.
3. Apply `20261117_executor_gate_v1.sql` (already in the production approval package) and insert the `swarm` registry row as `enabled=false` with the caps you choose. This is your action, never Jarvis's.
4. Approve a first live test: one task, small cap, reviewed afterwards. Merges and deploys remain separate gates.
5. Approve production wiring of `hq_executor` to the adapter (a code change that needs review).
6. Decide whether to block `models.dev` and `proxy.desplega.sh` at egress.
7. Optional: send questions to the vendor (external contact), only with your approval.

## Files
- `/home/claude/sandbox/swarm/` (repo copy, `node_modules` installed, 3.5 GB)
- `/home/claude/sandbox/swarm_poc/swarm_adapter.py`, `test_swarm_adapter.py`, `stub_lifecycle.py`, `live_check.py`
- Logs: `swarm_poc/lifecycle.log`, `live_check.log`, `tests.log`; `swarm_run/server.log`, `sink.log`
- The throwaway API key file was deleted, and the server and sink are stopped.
