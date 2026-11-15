"""POC adapter: HQ executor gate -> Agent Swarm task API.  Standalone (stdlib only), no LLM, no secrets read from the environment.

Flow (mirrors /home/claude/jarvis/hq_executor.run):
  1. executor_request  -> HQ decides.  Refused or dry_run => NOTHING is sent to the swarm (no task is created).
  2. only then POST /api/tasks, poll GET /api/tasks/{id} until terminal or timeout.
  3. executor_complete -> HQ settles cost. Failure/timeout/crash settles at the FULL reservation (never looks free).
On timeout the swarm task is cancelled (POST /api/tasks/{id}/cancel) before settling, so nothing keeps spending after HQ closed the run.
Production swap: replace gated_run() by hq_executor.run(...) and pass work=make_work(...); the work callable is identical.
"""
import hashlib, json, time, urllib.request, urllib.error

TERMINAL_OK = {"completed"}
TERMINAL_BAD = {"failed", "cancelled", "superseded", "skipped"}


class ExecutorRefused(Exception):
    """HQ said no. Nothing was executed, nothing reserved, no swarm task created."""


class SwarmError(Exception):
    pass


class SwarmClient:
    def __init__(self, base, api_key, http=None, timeout=15):
        self.base, self.key, self.timeout = base.rstrip("/"), api_key, timeout
        self._http = http or self._urllib   # injectable: tests never touch the network
        self.opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))

    def _urllib(self, method, url, headers, body):
        req = urllib.request.Request(url, method=method, headers=headers, data=body)
        try:
            with self.opener.open(req, timeout=self.timeout) as r:
                return r.status, r.read().decode()
        except urllib.error.HTTPError as e:
            return e.code, e.read().decode()

    def _call(self, method, path, body=None):
        h = {"Authorization": f"Bearer {self.key}", "Content-Type": "application/json"}
        status, text = self._http(method, self.base + path, h, json.dumps(body).encode() if body is not None else None)
        if status >= 400:
            raise SwarmError(f"{method} {path} -> {status} {text[:200]}")
        return json.loads(text) if text else {}

    def create_task(self, prompt, agent_id, tags=None, note="created via HQ executor gate"):
        # routingReason/routingNote are REQUIRED by the API when agentId is supplied (verified live, 400 otherwise)
        return self._call("POST", "/api/tasks", {"task": prompt, "agentId": agent_id, "source": "api",
                          "routingReason": "human_pinned", "routingNote": note[:200], "tags": list(tags or [])})

    def get_task(self, task_id):
        return self._call("GET", f"/api/tasks/{task_id}")

    def cancel_task(self, task_id):
        return self._call("POST", f"/api/tasks/{task_id}/cancel", {})


def poll_task(client, task_id, timeout_s=300, interval_s=2, sleep=time.sleep, clock=time.monotonic):
    deadline = clock() + timeout_s
    while True:
        t = client.get_task(task_id)
        if t.get("status") in TERMINAL_OK | TERMINAL_BAD:
            return t
        if clock() >= deadline:
            return {**t, "status": "timeout"}
        sleep(interval_s)


def result_sha256(result):
    raw = result if isinstance(result, (str, bytes)) else json.dumps(result, sort_keys=True, default=str)
    return hashlib.sha256(raw.encode() if isinstance(raw, str) else raw).hexdigest()


def make_work(client, prompt, swarm_agent_id, timeout_s=300, interval_s=2, cost_fn=None, sleep=time.sleep, clock=time.monotonic, est_cents=0):
    """Returns work(run_id) -> (result, actual_cents). cost_fn(task)->cents is optional; default charges the full estimate (conservative)."""
    def work(run_id):
        created = client.create_task(prompt, swarm_agent_id, tags=["hq-executor", f"run:{run_id}"])
        tid = created.get("id")
        if not tid:
            raise SwarmError("swarm returned no task id")
        t = poll_task(client, tid, timeout_s, interval_s, sleep, clock)
        if t["status"] == "timeout":
            try: client.cancel_task(tid)
            except SwarmError: pass
            raise SwarmError(f"swarm task {tid} timed out after {timeout_s}s (cancel requested)")
        if t["status"] in TERMINAL_BAD:
            raise SwarmError(f"swarm task {tid} ended {t['status']}: {str(t.get('failureReason') or '')[:200]}")
        cents = cost_fn(t) if cost_fn else est_cents
        return {"swarm_task_id": tid, "status": t["status"], "output": t.get("output")}, cents
    return work


def gated_run(rpc, executor, agent, task_id, est_cents, purpose, work):
    """Same contract as hq_executor.run, with the rpc injected."""
    d = rpc("executor_request", {"p_executor": executor, "p_agent": agent, "p_task": task_id,
                                 "p_est_cents": int(est_cents), "p_purpose": purpose})
    if not d.get("ok"):
        raise ExecutorRefused(d.get("reason") or "refused")
    if d.get("dry_run"):
        return {"status": "dry_run", "dry_run": True, "run_id": d["run_id"], "result": None}
    run_id = d["run_id"]
    try:
        result, actual = work(run_id)
        actual = max(0, int(actual))
    except BaseException:
        try: rpc("executor_complete", {"p_run": run_id, "p_actual_cents": int(est_cents), "p_status": "failed"})
        except Exception: pass
        raise
    args = {"p_run": run_id, "p_actual_cents": actual, "p_status": "done", "p_result_sha256": result_sha256(result)}
    try: rpc("executor_complete", args)
    except Exception: rpc("executor_complete", args)
    return {"status": "done", "dry_run": False, "run_id": run_id, "result": result}


def run_swarm_task(rpc, client, *, executor="swarm", agent, hq_task_id, est_cents, purpose, prompt, swarm_agent_id, **kw):
    return gated_run(rpc, executor, agent, hq_task_id, est_cents, purpose,
                     make_work(client, prompt, swarm_agent_id, est_cents=est_cents, **kw))
