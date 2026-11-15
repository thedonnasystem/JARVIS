# Agent Swarm pilot gate: conditions before ONE real LLM test task

Scope: Fendezy HQ, isolated development. Status as of 2026-11-15 (sandbox clock; revised after the worker-token and root-start investigation, sections 5 and 6): **no real LLM worker has run, none may run
until every box in section 2 is ticked.** No Docker daemon existed in the sandbox (`docker info`: "Cannot connect to the Docker daemon";
CLI and `docker compose config` work, so the compose file is schema-valid, but nothing was ever started).

Files: `docker-compose.hardened.yml`, `config/squid.conf`, `config/nginx-ingress.conf`, `config/worker_gate.py` (new), `worker/Dockerfile.worker-hardened` +
`worker/entrypoint-hardened.sh` (new), `secrets.example/`, `verify_swarm_controls.py` (C01-C21), `tests/`, `repro/` (throwaway-server probes), `evidence/`, `telemetry_proof/`.

## 1. What is verified now vs only specified

| Item | State | Evidence |
|---|---|---|
| Compose has every static control (digests, pull never, ro rootfs+tmpfs, cap_drop ALL, no-new-privileges, non-root, pids/mem/cpu, no sock, no host mounts, 1 scratch volume, loopback ports, internal networks, telemetry off, no lead, separate worker key, secrets outside repo) | VERIFIED statically | `evidence/verifier_good.txt`: C01-C21 PASS (C18-C21 are new: gate topology, gate policy behaviour, non-root image, env-only secrets); `docker compose config -q` OK (with `FENDEZY_SECRETS_DIR` set to a dir holding the two env files) |
| Verifier rejects the bad cases (:latest, docker.sock, privileged, missing telemetry flag, shared key, no limits, 0.0.0.0 ports, plus the new gate/topology/non-root cases: worker on api_net, direct API URL, gate allowing POST /api/tasks, send-task, config write, token mint, scripts, operator key, batch MCP, secrets not forced false, entrypoint with gosu/chown/config-fetch/no root refusal, Dockerfile USER root, stock image, wrong tmpfs uid; 56 compose mutations + 26 weakened-file fixtures + the gate's own 20 unit tests) | VERIFIED | `tests/`: 32 tests, all pass (`evidence/unittest.txt`) |
| Worker telemetry off with `ANONYMIZED_TELEMETRY=false` | VERIFIED at the boot/poll path (no key, no task) | `evidence/worker_telemetry_proof.log`; see section 4 |
| Per-agent worker token supported, worker can poll/finish with it, cannot mint tokens/write config/become lead | VERIFIED on a local server | `evidence/lifecycle_no_lead.log` |
| No lead agent => no auto "review needed" task | VERIFIED in source and live | `src/tasks/worker-follow-up.ts:499-502`; live: 1 task before and after finish |
| Worker can reach the API only through `worker-gate` (default-deny allow-list, 54 of 509 operations, no task creation, `includeSecrets` forced false, operator key refused) | VERIFIED live on a throwaway local server with the real worker process and a stub lifecycle; topology VERIFIED statically only | `evidence/gate_live_test.log` (60 asserts), `evidence/real_worker_via_gate.log`, `evidence/gate_surface_reduction.txt`, `evidence/gate_sse_test.log`; verifier C18/C19 |
| Hardened worker entrypoint needs no root, no caps, no writable rootfs | EMULATED (uid 1001, empty cap bounding set, no_new_privs, read-only root via mount namespace, stub agent); `Dockerfile.worker-hardened` LINTED only (hadolint, shellcheck), **never built** | `evidence/entrypoint_emulation.txt` (18 asserts), `evidence/hadolint.txt`, `evidence/shellcheck.txt`; verifier C20 |
| Container isolation, resource limits enforced, non-root boot under read-only rootfs, egress proxy blocking | **SPECIFIED ONLY** | needs Docker host |
| Real cost per run, model-host list actually needed by the harness | **UNMEASURED** | needs one real run |
| Claude harness telemetry/phone-home when a task runs | **UNVERIFIED** (worker had no key, never started `claude`) | only mitigated by env flags + proxy deny |

## 2. Gate conditions (all required; owner signs each)

### 2.1 Docker host
- [ ] Dedicated Linux host or VM, rootful or rootless Docker, **no other workloads, no HQ production secrets, no cloud metadata credentials worth having**. Not this sandbox.
- [ ] Images pulled out-of-band, digests recorded, placeholders in the compose replaced. (SC review 2026-11-15, proposal branch: registry index digests for api, worker-gate, egress-proxy, api-ingress, the Dockerfile `# syntax=` and `ARG BASE_IMAGE` are now resolved and committed, see `evidence/image_digests_resolved_20261115.md`; `worker.image` stays a placeholder BY DESIGN until the derived image is built on the Docker host; `resolve_image_digests.py` re-checks drift. The pins are NOT signature-verified: upstream publishes BuildKit provenance only.) `verify_swarm_controls.py docker-compose.hardened.yml --strict --require-runtime` exits 0 with the stack up.
- [ ] Derived worker image built on the host (never pulled, never built by compose): `docker build --build-arg BASE_IMAGE=ghcr.io/desplega-ai/agent-swarm-worker:2.13.2@sha256:<verified digest> -t fendezy/swarm-worker-hardened:2.13.2 -f worker/Dockerfile.worker-hardened worker/`; the build itself asserts uid 1001, ownership of `/workspace` and `/logs`, and that `claude --version` runs as 1001. Put `docker image inspect -f '{{.Id}}'` into the compose `worker.image` (`sha256:<id>`).
- [ ] Boot smoke test with NO model key (`ANTHROPIC_API_KEY` blank): api healthy, worker-gate healthy, worker registers (through the gate), then sits at "waiting for ANTHROPIC_API_KEY". The worker runs as uid 1001 with `read_only`, `cap_drop ALL`, `no-new-privileges`; no `--entrypoint-exception` is needed. If the derived image cannot boot, STOP and report the exact failure; the root-start exception stays an owner decision (it also disables C20), never a hand edit.
- [ ] Config holds no secrets: operator `GET /api/config?includeSecrets=true` shows zero `isSecret` rows (model key lives in `worker.env` only). The gate masks them for the worker anyway; a masked secret row would be exported as `********`, so a leaked row fails loudly rather than leaking.
- [ ] Gate log reviewed after the smoke test (`docker compose logs worker-gate`): every DENY is explained; the only expected deny from the boot path is `POST /api/fs/agent-credentials` (agent-fs is off). Any other denied path the real harness needs is an owner decision to add to `RULES`, then re-run the verifier and `tests/`.

### 2.2 Isolation tests (run inside the worker container with `docker compose exec -u worker worker bash`; record command, output, pass/fail)
| # | Test | Pass means |
|---|---|---|
| I1 | `cat /etc/hostname /proc/1/cgroup; ls /host /root /home` and `find / -xdev -name "*.pem" -o -name ".env"` | Only image/scratch content. No host file visible. `mount` shows no host bind mounts |
| I2 | `ls -l /var/run/docker.sock; docker ps` | No socket, no docker CLI access |
| I3 | `touch /usr/bin/x; touch /etc/x` | Read-only file system. Writes succeed only in `/tmp`, `/logs`, `/home/worker`, `/workspace` |
| I4 | `curl -m5 http://169.254.169.254/ ; curl -m5 http://127.0.0.1:3013/ ; curl -m5 http://<host-LAN-IP>:22/ ; curl -m5 http://172.17.0.1/` | All fail. (The API on the compose network is the one allowed local peer: `http://api:3013`) |
| I5 | `curl -m5 -x "" https://example.com; curl -m5 https://models.dev; curl -m5 https://proxy.desplega.sh; curl -m5 https://templates.agent-swarm.dev; getent hosts example.com` | All fail without proxy (no route, no external DNS). Through the proxy `https://models.dev` etc. return 403 |
| I6 | `https_proxy=http://egress-proxy:3128 curl -sS -m10 -o /dev/null -w '%{http_code}' https://api.anthropic.com/` | Reaches the host (any HTTP status). Squid log shows only CONNECT api.anthropic.com:443 |
| I7 | `curl -m5 http://other-container` / `nc -z egress-proxy 22` / `getent hosts api api-ingress` / `curl -m5 http://api:3013/health` | Only `worker-gate:3014` and `egress-proxy:3128` answer. `api` and `api-ingress` do not resolve and are unreachable (the worker is not on `api_net`) |
| I8 | `id; cat /proc/self/status \| grep -i cap; sudo -n true; unshare -U true; chmod u+s /tmp/x && /tmp/x` | uid != 0, `CapEff: 0000000000000000`, NoNewPrivs 1, no escalation |
| I9 | `:(){ :\|:& };:` style fork bomb capped (`pids_limit`), `python3 -c "x=bytearray(3<<30)"` OOM-killed (`mem_limit`), busy loop capped near 1.5 CPU | Container survives or is killed alone; host stays responsive |
| I10 | API side: `docker compose exec api sh -c 'wget -T5 -qO- https://models.dev'` | Fails. Logs show models.dev refresh failing, harmless |
| I11 | Host side: `ss -ltnp` | Only `127.0.0.1:13013` published. Nothing on 0.0.0.0 |
| I13 | Gate policy from inside the worker with its real token: `for r in 'POST /api/tasks' 'GET /api/config?scope=global&includeSecrets=true' 'PUT /api/config' 'POST /api/agents/pilot-worker-1/token' 'PUT /api/budgets/global/x' 'POST /api/scripts/run' 'POST /api/db-query'; do curl -s -o /dev/null -w "$r %{http_code}\n" -X ${r%% *} -H "Authorization: Bearer $API_KEY" -H 'X-Agent-ID: pilot-worker-1' -H 'Content-Type: application/json' -d '{}' "http://worker-gate:3014${r#* }"; done` | Every line 403 (400 is acceptable only for malformed forms). `GET /api/config/resolved?agentId=pilot-worker-1&includeSecrets=true` returns 200 and no secret value |
| I14 | MCP through the gate: `tools/call send-task`, `tools/call task-action {action:create}`, `tools/call db-query`, `tools/call set-config`, and a JSON-RPC batch | Each returns a JSON-RPC error `denied by worker-gate`; `GET /api/tasks` (operator) shows no new task |
| I15 | Operator key refused at the worker door: `curl -H "Authorization: Bearer <operator key>" http://worker-gate:3014/api/poll` (run by the owner from a throwaway shell, never pasted into the worker) | 403 |
| I16 | Non-root start: `id` = 1001:1001; `ls -ld /home/worker /workspace /logs` all owned 1001; `mount \| grep ' / '` shows `ro`; `ls -A /home/worker/.claude` has `settings.json`; `cat /workspace/.mcp.json` points at `worker-gate:3014`; `stat -c %a /workspace/.mcp.json` = 600; `ps -o user= -p 1` is root or the init only if docker `init: true` (it runs as the container's user) | All as stated; no `gosu`, `su`, `sudo` binary in `/usr/sbin`, `/usr/bin` |
| I17 | Fresh named volume ownership: `docker volume rm swarm-pilot_swarm_worker_scratch` then `up`; worker can write `/workspace`. Then recreate the container with a volume that pre-exists root-owned | First: writes work (volume inherited uid 1001 from the image). Second: the entrypoint exits 64 with "never changes ownership" (fix = delete and recreate the volume) |
| I12 | Egress observation: while the api and worker idle 10 min, squid log is empty; `tcpdump` on the egress bridge shows nothing but proxy traffic | Zero unexpected destinations |

### 2.3 Dedicated key and PROVIDER-SIDE hard monthly cap (owner action)
- [ ] A new Anthropic Console workspace/key used by nothing else. Owner sets a **hard monthly spend limit at the provider** (not an HQ number, not a dashboard alert). Owner records the figure here: `$____`. Cost per run is **unmeasured**; set the cap from what the owner is willing to lose outright, not from an estimate.
- [ ] Key lives only in `$FENDEZY_SECRETS_DIR/worker.env` (mode 600, outside the repo) on the Docker host. Never in HQ's DB, never in the API container's env.
- [ ] Owner confirms in the console that the cap is enforced (a key at its limit returns an error) before the run, if the provider lets them test it.
- [ ] Per-run estimate for the HQ executor registration: **UNMEASURED.** Procedure to measure: run the one pilot task, read `session_costs`/`totalCostUsd` from the swarm API and the provider usage page, record both; only then fill the number in. Until then HQ settles at the full reservation (conservative, per the adapter).
- [ ] Secondary, in-swarm guard (not a substitute): `PUT /api/budgets/global/<id>` with a small `dailyBudgetUsd`. Admission at poll time per `src/be/budget-admission.ts`. Untested live.

### 2.4 Kill procedure (rehearse it once with NO key before the real run; target under 60 s)
1. `curl -X POST $API/api/tasks/<id>/cancel` (operator key) for the running task.
2. `curl -X DELETE $API/api/agents/pilot-worker-1/token` revokes the worker token and its task tokens; open connections close.
3. `docker compose -p swarm-pilot kill worker` then `docker compose -p swarm-pilot down -v` (this also destroys the ephemeral API database).
4. **Revoke the provider key in the console.** This is the real stop; the others only stop the swarm. Then confirm usage stops rising.
5. Rotate `api.env` operator key if it was ever pasted anywhere.

### 2.5 Review procedure (after the run, before anything else is enabled)
- Export first (the API DB is a tmpfs and dies with the stack): task JSON, `/logs` from the worker, squid access log, `docker compose logs`, provider usage page screenshot/CSV, `docker inspect` of both containers, `verify_swarm_controls.py --require-runtime` output.
- Diff `/workspace` against what the task needed; look for network tools, new files outside the workspace, credentials in output (the scrubber exists but is unaudited).
- Squid log: every line is `CONNECT api.anthropic.com:443`. Any other host = FAIL, add it only by owner decision.
- Export `docker compose logs worker-gate` too (one JSON line per request: method, path, ALLOW/DENY, reason; no tokens, no bodies, no query strings).
- No task other than the HQ-created one exists (`GET /api/tasks`). The worker token CAN create tasks when it talks to the API directly (observed, section 5), and the gate is what stops it; any extra task means the gate failed and is a finding.

### 2.6 What PASS means (all of these)
1. Verifier `--strict --require-runtime` exits 0 before and after the run.
2. I1-I12 all pass and are recorded.
3. The task completes (or is cleanly cancelled) with output matching a pre-written expected result.
4. Squid log shows only the model host. No telemetry/registry/models.dev attempt reached the proxy.
5. Measured cost recorded from two sources (swarm session cost and provider usage), within the owner's per-run cap.
6. Kill procedure rehearsed and the key was revoked at the end of the test (a new key for any later run).
7. Zero extra tasks, zero lead tasks, zero schedule firings, zero budget/config changes by the worker token (operator `GET /api/budgets`, `GET /api/config`).
Any single failure = FAIL; fix and repeat from 2.1, no partial credit.

## 3. Mapping to HQ executor registration
- Registry row for `swarm`: **`enabled=false`**, `max_cents_per_run` tiny (owner picks; unmeasured, so start at the smallest that the owner would accept losing), `max_runs_per_day=1`, `allowed_agents=['pilot-worker-1']`. Applied by the owner via the approved `20261117_executor_gate_v1.sql` package, never by Jarvis.
- Owner flips `enabled=true` for exactly one run (kill switch stays reachable), then back to `false`. The adapter (`swarm_poc/swarm_adapter.py`) goes through `executor_request` first; a refusal or `dry_run` makes zero HTTP calls (tested). The adapter holds the operator key (HQ side), never the worker.
- Expected HQ outcome for the run: one `executor_request` approved, one `executor_complete` settled at measured cost; failure or timeout settles at the full reservation and cancels the swarm task first.
- **Registry stays empty (no rows) until the separately approved sweep release.** The pilot row is a pilot-only exception that exists in the pilot environment, not in the sweep registry, and does not ship.
- HQ's cap only covers start and settlement. Mid-run spend is bounded only by the provider key cap, the adapter timeout plus cancel, and the kill procedure.

## 4. Telemetry-off proof, exactly what was shown
Source (`src/telemetry.ts`): the only network call is one `fetch(TELEMETRY_ENDPOINT)` at line 762, inside `emit()`, which returns at line 681 when `isTelemetryEnabled()` is false (`ANONYMIZED_TELEMETRY` = `false` or `0`; unrecognized values fall back to ON). `initTelemetry` (called by the worker, `runner.ts:6359`) returns at line 396. The flag is also hot-reloadable from API config on workers (`RELOADABLE_ENV_KEYS`); a stored dashboard value wins over env, so do not set it in the dashboard.

Live (`telemetry_proof/run_worker_proof.sh`, stdlib sink, loopback only, no external host contacted):
- Control, flag unset, same DB, same API: worker sent `session.started` and `session.ended` to the loopback sink (2 POSTs) and tried `templates.agent-swarm.dev:443` (refused by the sink acting as proxy). So the path is real and the harness would have caught a leak.
- Hardened, `ANONYMIZED_TELEMETRY=false`, no `TEMPLATE_ID`: sink received nothing, and `strace -f -e trace=connect` shows one destination, the loopback API. Worker idled at "waiting for ANTHROPIC_API_KEY".
- Limits: connect() only (no UDP/DNS tracing); the claude harness and hooks never ran; the worker run was ~30 s. Task-time telemetry (`session` events inside a task) uses the same gated `emit()`, but that was not exercised.

## 5. Findings that change the plan

### 5.1 The 2026-11-14 finding was half right (investigated 2026-11-15, v2.13.2, throwaway local server, `evidence/config_exposure_repro.log`)
- **`GET /api/config?scope=global&includeSecrets=true` with a worker token returns 200 but the secret values are MASKED (`********`).** Source: `src/http/config.ts` `requestSecretReadScope` returns `"none"` for an agent principal that is not a lead (`config.read.secrets` is `leadOnly`, `src/rbac/legacy-policy.ts:325`), and `maskConfigRead` masks. The real worker itself calls exactly this URL at boot (`src/commands/runner.ts:6364`, telemetry install-id lookup) and expects it to work. The "200 with secrets" in the first note was a status code, not a leak.
- **The real leak is `GET /api/config/resolved?includeSecrets=true`** (what the worker uses to build its env, `runner.ts:953`, and the stock entrypoint `docker-entrypoint.sh:393`). `requestSecretReadScope` returns `"self"` when the resolved scope is the token's own agent, and the resolved view includes **global** rows. Result: a worker token reads unmasked **global + own-agent** secrets, never another agent's (reproduced: other agent's secrets stay masked). Upstream states this is by design (`src/http/sessions.ts` comment: "a worker token carries the target agent's privileges and reads that agent's resolved config, global secrets included").
- Auth scoping (how tokens work): `src/http/auth.ts` resolves `Bearer aseph_...` to an `agent` principal (`resolveSessionToken`, `src/be/users.ts:1044`): token kind `task` (has taskId), `runtime` (has runtimeId) or `agent` (the minted per-agent worker token). `core.ts:565-617` pins `X-Agent-ID` to the token's agent and blocks other agents' `/api/agents/{id}/*` unless `agent.act.any` (lead). **There is no per-route allow-list for agent tokens**: every route not individually RBAC-gated is open to any valid token. Measured: the worker token reaches **313 of 509** documented operations (`evidence/route_sweep_worker_token.log`).
- What a compromised per-agent worker token can do **directly against the API** (`evidence/worker_token_powers.log`, `dbquery_secret_probe.log`, `mcp_worker_probe.log`):
  - READ: global + own-agent unmasked config secrets (`/api/config/resolved`); `swarm_config` rows via `db-query` (secret values come back as ciphertext, encrypted at rest with or without `SECRETS_ENCRYPTION_KEY`, so useless without the key; `session_tokens`, `user_tokens`, OAuth tables are refused); all agents, users, stats, tasks (read by uuid, list via MCP `get-tasks`), events, repos, models, key-pool status, any task's content.
  - WRITE: create tasks (REST `POST /api/tasks` 201, MCP `send-task`, MCP `task-action {create}`), supersede-created resume tasks, set budgets (`PUT /api/budgets/global/_` with 99999: defeats the in-swarm budget guard in 2.3), create schedules, create skills, upsert and RUN scripts (executes in the API container; the sandbox executor may or may not work under `cap_drop ALL`), register another agent record, KV writes, reload config, finish an unassigned pool task with forged output, memory writes.
  - CANNOT (403, good): mint/rotate/revoke tokens, write or delete config, register as lead, touch another agent's config/tokens/profile, cancel/steer/finish another agent's assigned task, create users.
- Why no upstream switch fixes it: there is no env flag or config key that narrows a worker token; RBAC verbs cover only a few mutations; `RBAC_ENABLED` applies to user tokens (`core.ts:628`), not agent tokens.

### 5.2 Mitigation without forking Swarm: `worker-gate` (proxy in front of the API, worker has no other path)
- Why not an nginx/caddy deny list on the existing ingress: the worker never goes through `api-ingress` (that is HQ's loopback door), so denying `/api/config*`, `/api/agents/*/token`, `POST /api/tasks` there protects nothing. A deny list is also the wrong shape: 313 reachable operations, and task creation exists in three places (REST, MCP `send-task`, MCP `task-action create`), where the MCP ones are JSON-RPC bodies that path rules cannot see. nginx, caddy and squid are not installable in this sandbox (no package route), so the filter is a stdlib Python proxy that was written and tested.
- Design: `config/worker_gate.py`. Networks split into `worker_net` (worker, gate, egress-proxy) and `api_net` (api, gate, api-ingress); the worker cannot resolve or route to `api` (verifier C18 asserts disjoint networks and the gate as the only bridge). The gate is **default deny**: 54 of 509 operations are allowed (`evidence/gate_surface_reduction.txt`), all derived from what the real worker and harness call (`runner.ts`, hooks), validated by running the real worker through it. Specific controls: only `aseph_` session tokens pass (the operator key is refused, so it cannot be used through the worker's door even if it leaks into the worker env); agent id pinned in paths, `X-Agent-ID` and resolved-config `agentId`; `includeSecrets`/`resolveSecrets` forced to `false` on every query; no task creation anywhere (REST, `supersede`, MCP `send-task`, MCP `task-action{create}`); MCP tool allow-list with JSON-RPC batch refusal and a JSON-RPC error body on denial; path hygiene (no encoded, dot, or double-slash paths); duplicate query keys refused; chunked bodies refused; body size cap; token-free, body-free, query-free JSON log.
- Proven locally (`evidence/gate_live_test.log`, 60 asserts, throwaway server on a random port, throwaway keys, telemetry off, stopped and deleted afterwards): direct, the worker token leaks secrets, creates tasks, sets budgets, schedules, db-queries (the finding reproduced); through the gate each of those is 403/masked, **while register, ping, me, poll, get task, progress and finish still work** (task reached `completed` in the API DB), `/api/config/resolved` returns 200 with masked values, MCP `initialize`/`tools/list`/`my-agent-info` work and `send-task`, `task-action create`, `db-query`, `get-config`, `set-config`, batch are denied, and **no task is created through the gate**. The real worker binary (`bun src/cli.tsx worker`, no key) booted through the gate: registered, resolved config, rendered templates, only `POST /api/fs/agent-credentials` denied (agent-fs off), parked at "waiting for ANTHROPIC_API_KEY".
- Source patch: **not needed**, so no patch file was written. (If Swarm ever adds scoped token kinds, the gate becomes redundant; until then do not upgrade the pinned version without re-running `repro/` and the verifier.)

### 5.3 Residual risk inside the 54 allowed operations (the gate narrows, it does not make the worker harmless)
- The worker can still: read any task by uuid (`GET /api/tasks/{id}`) and `GET /api/events`; write memory, events, session logs/costs, its own profile; call key-pool report endpoints (can mark the pilot key rate-limited, a self-DoS); finish an unassigned pool task with forged output (HQ pins `agentId` on the pilot task, so there is no unassigned pool task; keep it that way); trigger `/api/active-sessions/recover-orphaned-tasks` (own agent).
- `supersede` is denied, so hitting a context limit or provider fallback fails the task instead of creating a resume task (this is what keeps "zero extra tasks" true). That is a capability cost the owner accepts for the pilot.
- A task's content and output are untrusted. The gate does nothing about prompt injection inside the task or exfiltration through model output.
- The gate is one process: if it dies the worker loses the API (fail closed). HTTP/1.0, one request per connection; the real Claude CLI's streamable-HTTP MCP client has not been run through it (a raw SSE `GET /mcp` stream and `DELETE /mcp` were, `evidence/gate_sse_test.log`).
- The gate's allow-list was derived from source and one idle real-worker boot. A real task run will exercise more paths (hooks, memory, steering). The first pilot attempt must be run with the gate log open; a denied path the harness needs shows up as a 403 and is an owner decision.

### 5.4 Other findings (unchanged unless marked)
1. A worker token can **create tasks** when it can reach the API (201, observed). **Now stopped by the gate**; extra tasks still fail 2.6.
2. The per-task `followUpConfig.disabled` is **not** exposed on `POST /api/tasks` (only on MCP send-task). The effective switch is "no lead agent exists" (verified). Never register a lead in the pilot. The gate additionally refuses `isLead:true` registration.
3. `models.dev` has no off switch; it is blocked by network topology (api has no route out), not by configuration.
4. **Corrected:** the previous note said the stock entrypoint "expects root" and that non-root + read-only was an untested bet. Reading the entrypoint shows it cannot run read-only even as root (section 6): `set -e` plus `mkdir -p /usr/local/share/agent-swarm/git-template` aborts on a read-only filesystem. The existing compose also mounted a tmpfs over `/home/worker`, which hides the baked-in hook settings and onboarding flag. Both are fixed by the derived image (section 6).
5. Telemetry install id is sent on vendor-facing improvements even when telemetry is off: `IMPROVEMENTS_ENABLED=false` is set.
6. The API DB is ephemeral (tmpfs) by design for a one-task pilot; do not restart the api mid-run.

## 6. Root start: what actually needs root (read from `Dockerfile.worker` and `docker-entrypoint.sh`, v2.13.2)
| Stock step (entrypoint line) | Needs root? | Hardened answer |
|---|---|---|
| `useradd -m worker` (Dockerfile:112) | build time only | done in the base image; derived image asserts uid/gid 1001 |
| chown `/workspace/personal`, `/logs`, per-agent dirs, `~/.claude`, `~/.local`, skills trees (266-347, 963, 1028-1049) | yes, because root creates files then hands them over | not needed: tmpfs mounted with `uid=1001,gid=1001`; new named volume inherits the image's 1001-owned `/workspace` (base image `chown worker /workspace /logs`); entrypoint only `mkdir`s inside them and refuses (exit 64) a volume that is not writable instead of chowning |
| `git config --system ...` (304, 321, 324), create `/usr/local/share/agent-swarm/git-template` (314-322) | yes (writes `/etc/gitconfig`, `/usr/local`); the unguarded `mkdir -p` kills the boot on a read-only rootfs | dropped: no repos are cloned, git stays strict (`safe.directory` not widened) |
| GitHub/GitLab/AzDO/Bitbucket auth, `ln -sf` over `/usr/local/bin/gh`, repo clone loop (525-830) | yes (`/usr/local/bin/gh`, `gosu worker`) | dropped: no git credentials exist in the pilot (also removes credential material from the worker) |
| `gosu worker` for codex login, github token probe, repo clone, hooks (279, 531, 738, 784-820, 1215) | needs root to switch user | not needed: already uid 1001 from process start |
| Fetch `/api/config/resolved?includeSecrets=true` and export to env (393-419) | no | dropped on purpose: config never becomes env; secrets only from `worker.env` |
| Fetch `/api/agents/{id}/setup-script` and execute it as worker at every boot (850-922, bootstrap 1078+) | no | dropped on purpose: remote-defined code at boot from the API DB |
| write `/workspace/.mcp.json` (481), `/tmp/*` (393, 749, 1071) | no (workspace/tmp are writable) | kept, mode 0600 |
| `exec tini -- gosu worker bootstrap` (1215) | tini no; gosu yes | `init: true` in compose provides the reaper; `exec agent-swarm worker` directly |
| optional postgres/redis init (1050-1066) | yes | off by default; dropped |
Conclusion: **the Claude-harness worker needs no root at runtime.** Everything root did was either a chown to cover its own root-owned writes, a write to the root filesystem that a read-only deployment must not allow anyway, or an integration the pilot disables. `worker/Dockerfile.worker-hardened` + `worker/entrypoint-hardened.sh` run it with `user: 1001:1001`, `cap_drop: ALL`, `read_only: true`, `no-new-privileges`, HOME on a seeded tmpfs.

What is verified, by what:
- **Read from source:** the table above; uid 1001 follows from `useradd` on ubuntu:24.04 (user `ubuntu` holds 1000); the claude CLI is installed with `npm -g` into `/usr/lib` (root-owned, read-only is fine, `Dockerfile.worker:142-146`); baked HOME content is small (settings, hooks, skills, `.claude.json`).
- **Static tests:** `hadolint` clean, `shellcheck` clean, verifier C20 (+ 26 weakened-file fixtures in `tests/`, each must fail its expected check).
- **Emulated here, no Docker:** `tests/run_entrypoint_emulation.sh` runs the real `entrypoint-hardened.sh` as uid 1001 with an empty capability bounding set, `no_new_privs`, a read-only root (private mount namespace), tmpfs HOME/logs/tmp and a 1001-owned workspace, with stub `bun`/`agent-swarm`: it reaches `exec`, seeds HOME, writes `.mcp.json` 0600, cannot write `/usr`, `/etc`, `/usr/local/bin`, and refuses root, a non-session-token key, a non-gate URL (including userinfo tricks), role=lead, bad agent id, and a root-owned workspace (18/18).
- **NOT verified (needs a Docker host):** that the derived image builds; that `claude` and the real `agent-swarm` binary run with `HOME` on the seeded tmpfs (writes outside `$HOME`, `/workspace`, `/logs`, `/tmp` by the harness are only grep-checked, not exhaustively known); named-volume ownership inheritance; Docker's own seccomp/AppArmor/cgroup behaviour; python alpine image runs the gate; compose network DNS (`worker-gate` resolvable only from `worker_net`, `api` only from `api_net`); gate healthcheck; the real Claude CLI MCP client through the gate; the script sandbox executor under `cap_drop ALL` (irrelevant to the worker now that scripts are denied, relevant to the API); **isolation tests I1-I17 are all unrun**.
