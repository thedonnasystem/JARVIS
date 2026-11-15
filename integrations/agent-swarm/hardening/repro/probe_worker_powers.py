"""What can a compromised per-agent worker token actually DO (realistic bodies) on a throwaway server?"""
import json
from lib import *
with Server() as S:
    b, K = S.base, S.key
    s, tk = call(b, "POST", "/api/agents/pilot-worker-1/token", K, {"name": "pilot-worker"}); WT = tk["plaintext"]
    RT = {"X-Agent-ID": "pilot-worker-1"}
    call(b, "POST", "/api/agents", WT, {"name": "pilot-worker", "isLead": False, "role": "coder", "capabilities": ["code"], "maxTasks": 1, "runtimeInstanceId": "rt1"}, RT)
    s, other = call(b, "POST", "/api/agents", K, {"name": "other", "isLead": False, "role": "x", "runtimeInstanceId": "rt-o"}, {"X-Agent-ID": "other-agent"}); oid = other.get("id") or (other.get("agent") or {}).get("id"); print("other agent:", s, oid)
    s, t = call(b, "POST", "/api/tasks", K, {"task": "operator task for other", "agentId": oid, "source": "api", "routingReason": "human_pinned"}); tid = t.get("id"); print("op task for other:", s, tid)
    s, t2 = call(b, "POST", "/api/tasks", K, {"task": "operator pool task", "source": "api"}); tid2 = t2.get("id")
    def w(label, m, path, body=None):
        s, r = call(b, m, path, WT, body, RT); print(f"{label:58s} {m:6s} {path[:48]:48s} -> {s} {json.dumps(r)[:110]}"); return s
    w("mint worker token (own agent)", "POST", "/api/agents/pilot-worker-1/token", {"name": "x"})
    w("mint worker token for other agent", "POST", f"/api/agents/{oid}/token", {})
    w("rotate token", "POST", "/api/agents/pilot-worker-1/token/rotate", {})
    w("revoke other's token", "DELETE", f"/api/agents/{oid}/token")
    w("create task", "POST", "/api/tasks", {"task": "x", "source": "api"})
    w("create task assigned to other agent", "POST", "/api/tasks", {"task": "x", "agentId": oid, "source": "api", "routingReason": "human_pinned"})
    w("cancel operator task (other agent's)", "POST", f"/api/tasks/{tid}/cancel", {})
    w("finish operator task (other agent's)", "POST", f"/api/tasks/{tid}/finish", {"status": "completed", "output": "forged"})
    w("finish unassigned pool task", "POST", f"/api/tasks/{tid2}/finish", {"status": "completed", "output": "forged"})
    w("steer other's task", "POST", f"/api/tasks/{tid}/steer", {"message": "do evil"})
    w("read other's task", "GET", f"/api/tasks/{tid}")
    w("register another agent", "POST", "/api/agents", {"name": "sybil", "isLead": False, "role": "x", "runtimeInstanceId": "rt-s"})
    w("create budget (PUT)", "PUT", "/api/budgets/global/_", {"dailyBudgetUsd": 99999})
    w("create schedule", "POST", "/api/schedules", {"name": "s", "cronExpression": "* * * * *", "taskTemplate": "x"})
    w("upsert script", "POST", "/api/scripts/upsert", {"name": "evil", "source": "export default async()=>1"})
    w("run script", "POST", "/api/scripts/run", {"source": "export default async()=>1"})
    w("create mcp-server (stdio)", "POST", "/api/mcp-servers", {"name": "evil", "transport": "stdio", "command": "id", "args": []})
    w("create skill", "POST", "/api/skills", {"name": "evil", "content": "---\nname: evil\ndescription: x\n---\nx"})
    w("create user", "POST", "/api/users", {"name": "evil"})
    w("create invite", "POST", "/api/invites", {})
    w("raw-llm (spend path)", "POST", "/api/internal/raw-llm", {"prompt": "hi"})
    w("kv set", "PUT", "/api/kv/hq", {"value": "x"})
    w("reload config", "POST", "/api/config/reload")
    w("internal reload-config", "POST", "/internal/reload-config")
    w("config pool-keys write", "POST", "/api/config/pool-keys", {"provider": "claude", "key": "k"})
    w("fs agent-credentials", "POST", "/api/fs/agent-credentials", {})
    w("GET /api/keys/status", "GET", "/api/keys/status")
    w("GET /api/users", "GET", "/api/users")
    w("GET /api/stats", "GET", "/api/stats")
    s, lst = call(b, "GET", "/api/tasks", K); print("tasks now:", [(x["task"][:28], x["status"]) for x in lst["tasks"]])
