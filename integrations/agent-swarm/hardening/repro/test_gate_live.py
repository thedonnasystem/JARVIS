"""LIVE proof: throwaway swarm API + worker_gate.py, per-agent worker token. Asserts (exit 1 on any mismatch):
  DIRECT (no gate)  : the worker token can do the dangerous things (reproduces the finding)
  VIA GATE          : same requests get 403 / masked, while register/poll/progress/finish still work.
Loopback only, throwaway keys, telemetry off, everything stopped and deleted afterwards."""
import json, os, random, subprocess, sys, threading, time
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from lib import *
from probe_mcp_helpers import mcp_call

GATE = "/home/claude/sandbox/swarm_hardening/config/worker_gate.py"
fails = []
def expect(label, got, want, note=""):
    ok = (got in want) if isinstance(want, (set, tuple, list)) else got == want
    print(f"  [{'PASS' if ok else 'FAIL'}] {label:66s} got={got} want={want} {note}")
    if not ok: fails.append(label)

with Server() as S:
    b, K = S.base, S.key
    gport = random.randint(41000, 58000)
    gl = open(S.dir + "/gate.log", "w")
    gate = subprocess.Popen([sys.executable, GATE], env={"PATH": os.environ["PATH"], "GATE_AGENT_ID": "pilot-worker-1",
                            "GATE_UPSTREAM": f"127.0.0.1:{S.port}", "GATE_LISTEN": f"127.0.0.1:{gport}", "GATE_LOG": S.dir + "/gate.log"},
                            stderr=subprocess.DEVNULL)
    G = f"http://127.0.0.1:{gport}"
    for _ in range(40):
        if call(G, "GET", "/health")[0] == 200: break
        time.sleep(0.25)
    try:
        # operator seeds (direct, operator key never goes through the gate)
        call(b, "PUT", "/api/config", K, {"scope": "global", "key": "FAKE_GLOBAL_SECRET", "value": "THROWAWAY-GLOBAL-SECRET-VALUE", "isSecret": True})
        call(b, "PUT", "/api/config", K, {"scope": "agent", "scopeId": "pilot-worker-1", "key": "FAKE_OWN_AGENT_SECRET", "value": "THROWAWAY-OWN-AGENT-SECRET", "isSecret": True})
        s, tk = call(b, "POST", "/api/agents/pilot-worker-1/token", K, {"name": "pilot-worker"}); WT = tk["plaintext"]
        RT = {"X-Agent-ID": "pilot-worker-1", "X-Runtime-Instance-ID": "rt-pilot-1"}
        s, t = call(b, "POST", "/api/tasks", K, {"task": "operator stub task", "agentId": "pilot-worker-1", "source": "api", "routingReason": "human_pinned"}); TID = t["id"]

        print("\n== A. DIRECT to the API (no gate): the finding")
        s, r = call(b, "GET", "/api/config/resolved?agentId=pilot-worker-1&includeSecrets=true", WT, None, RT)
        expect("direct: resolved?includeSecrets=true leaks secrets", "THROWAWAY-GLOBAL-SECRET-VALUE" in json.dumps(r), True)
        expect("direct: worker creates a task", call(b, "POST", "/api/tasks", WT, {"task": "evil direct", "source": "api"}, RT)[0], 201)
        expect("direct: worker sets budget", call(b, "PUT", "/api/budgets/global/_", WT, {"dailyBudgetUsd": 99999}, RT)[0], 200)
        expect("direct: worker creates schedule", call(b, "POST", "/api/schedules", WT, {"name": "s", "cronExpression": "* * * * *", "taskTemplate": "x"}, RT)[0], 201)
        expect("direct: worker db-query", call(b, "POST", "/api/db-query", WT, {"sql": "SELECT id FROM agents"}, RT)[0], 200)

        print("\n== B. VIA GATE: required worker flow still works")
        expect("register itself", call(G, "POST", "/api/agents", WT, {"name": "pilot-worker", "isLead": False, "role": "coder", "capabilities": ["code"], "maxTasks": 1, "runtimeInstanceId": "rt-pilot-1"}, RT)[0], 200)
        expect("/ping", call(G, "POST", "/ping", WT, None, RT)[0], 204)
        expect("/me", call(G, "GET", "/me", WT, None, RT)[0], 200)
        s, p = call(G, "GET", "/api/poll", WT, None, RT); expect("poll", s, 200, str(p)[:60])
        expect("get own task", call(G, "GET", f"/api/tasks/{TID}", WT, None, RT)[0], 200)
        expect("progress", call(G, "POST", f"/api/tasks/{TID}/progress", WT, {"progress": "working"}, RT)[0], 200)
        expect("finish", call(G, "POST", f"/api/tasks/{TID}/finish", WT, {"status": "completed", "output": "stub done"}, RT)[0], 200)
        s, st = call(b, "GET", f"/api/tasks/{TID}", K); expect("task completed in DB", st.get("status"), "completed")
        expect("/api/config/resolved works (200)", call(G, "GET", "/api/config/resolved?agentId=pilot-worker-1&includeSecrets=true", WT, None, RT)[0], 200)
        s, r = call(G, "GET", "/api/config/resolved?agentId=pilot-worker-1&includeSecrets=true", WT, None, RT)
        txt = json.dumps(r)
        expect("resolved via gate: global secret NOT in body", "THROWAWAY-GLOBAL" in txt, False)
        expect("resolved via gate: own-agent secret NOT in body", "THROWAWAY-OWN" in txt, False)
        expect("resolved via gate: secrets present but masked", "********" in txt, True)
        s, r = call(G, "GET", "/api/config/resolved?agentId=pilot-worker-1&includeSecrets=true&includeSecrets=true", WT, None, RT)
        expect("duplicate includeSecrets refused", s, 400)

        print("\n== C. VIA GATE: previously-open dangerous paths are 403")
        for label, m, path, body in [
            ("GET /api/config?scope=global&includeSecrets=true", "GET", "/api/config?scope=global&includeSecrets=true", None),
            ("PUT /api/config", "PUT", "/api/config", {"scope": "global", "key": "X", "value": "1"}),
            ("POST /api/config/reload", "POST", "/api/config/reload", {}),
            ("POST /internal/reload-config", "POST", "/internal/reload-config", {}),
            ("POST /api/tasks (create task)", "POST", "/api/tasks", {"task": "evil via gate", "source": "api"}),
            ("POST /api/tasks/{id}/supersede", "POST", f"/api/tasks/{TID}/supersede", {"reason": "manual_supersede"}),
            ("POST /api/agents/x/token (mint)", "POST", "/api/agents/pilot-worker-1/token", {"name": "x"}),
            ("DELETE /api/agents/x/token (revoke)", "DELETE", "/api/agents/pilot-worker-1/token", None),
            ("PUT /api/budgets/global/_", "PUT", "/api/budgets/global/_", {"dailyBudgetUsd": 99999}),
            ("POST /api/schedules", "POST", "/api/schedules", {"name": "s", "cronExpression": "* * * * *", "taskTemplate": "x"}),
            ("POST /api/scripts/upsert", "POST", "/api/scripts/upsert", {"name": "evil", "source": "export default async()=>1"}),
            ("POST /api/scripts/run", "POST", "/api/scripts/run", {"source": "export default async()=>1"}),
            ("POST /api/skills", "POST", "/api/skills", {"name": "evil", "content": "x"}),
            ("POST /api/db-query", "POST", "/api/db-query", {"sql": "SELECT id FROM agents"}),
            ("GET /api/agents (list)", "GET", "/api/agents", None),
            ("GET /api/users", "GET", "/api/users", None),
            ("GET /api/tasks (list)", "GET", "/api/tasks", None),
            ("GET /api/stats", "GET", "/api/stats", None),
            ("PUT /api/kv/hq", "PUT", "/api/kv/hq", {"value": "x"}),
            ("path trick /api//tasks", "POST", "/api//tasks", {"task": "x"}),
            ("path trick /api/tasks/../tasks", "POST", "/api/tasks/../tasks", {"task": "x"}),
            ("path trick %2e%2e", "POST", "/api/tasks/%2e%2e/tasks", {"task": "x"}),
            ("path trick encoded slash", "POST", "/api%2Ftasks", {"task": "x"}),
            ("other agent's resolved config", "GET", "/api/config/resolved?agentId=other-agent", None),
            ("other agent's profile", "PUT", "/api/agents/other-agent/profile", {}),
            ("register as lead", "POST", "/api/agents", {"name": "evil", "isLead": True, "role": "lead", "runtimeInstanceId": "rt-evil"}),
        ]:
            expect("gate 4xx: " + label, call(G, m, path, WT, body, RT)[0], {400, 403})
        expect("operator key through gate refused", call(G, "GET", "/api/poll", K, None, {})[0], 403)
        expect("no token through gate refused", call(G, "GET", "/api/poll", None, None, {})[0], 403)
        expect("wrong X-Agent-ID refused", call(G, "GET", "/api/poll", WT, None, {"X-Agent-ID": "other-agent"})[0], 403)
        expect("method override header has no effect (GET stays GET)", call(G, "GET", "/api/config", WT, None, {**RT, "X-HTTP-Method-Override": "PUT"})[0], 403)

        print("\n== D. VIA GATE: MCP")
        def gmcp(method, params=None, sid=None, i=1): return mcp_call(G, WT, "pilot-worker-1", method, params, sid, i)
        s, sid, t = gmcp("initialize", {"protocolVersion": "2025-03-26", "capabilities": {}, "clientInfo": {"name": "t", "version": "0"}})
        expect("mcp initialize", s, 200); 
        gmcp("notifications/initialized", sid=sid, i=None)
        s, _, t = gmcp("tools/list", {}, sid, 2); expect("mcp tools/list", s, 200)
        def tc(name, args, i):
            s, _, t = gmcp("tools/call", {"name": name, "arguments": args}, sid, i); return s, t
        s, t = tc("my-agent-info", {}, 3); expect("mcp my-agent-info allowed", ("denied by worker-gate" in t), False, t[:60].replace("\n", " "))
        s, t = tc("send-task", {"task": "mcp evil"}, 4); expect("mcp send-task denied", "denied by worker-gate" in t, True)
        s, t = tc("task-action", {"action": "create", "task": "mcp evil via task-action"}, 5); expect("mcp task-action create denied", "denied by worker-gate" in t, True)
        s, t = tc("task-action", {"action": "claim", "taskId": "00000000-0000-0000-0000-000000000000"}, 6); expect("mcp task-action claim passes the gate", "denied by worker-gate" in t, False)
        s, t = tc("db-query", {"sql": "select 1"}, 7); expect("mcp db-query denied", "denied by worker-gate" in t, True)
        s, t = tc("get-config", {"includeSecrets": True, "scope": "global"}, 8); expect("mcp get-config denied", "denied by worker-gate" in t, True)
        s, t = tc("set-config", {"scope": "global", "key": "x", "value": "1"}, 9); expect("mcp set-config denied", "denied by worker-gate" in t, True)
        s, _, t = gmcp("tools/list", None, sid, 10)
        # batch refused
        r = urllib.request.Request(G + "/mcp", method="POST", data=json.dumps([{"jsonrpc": "2.0", "id": 1, "method": "tools/call", "params": {"name": "send-task", "arguments": {"task": "x"}}}]).encode(),
                                   headers={"Content-Type": "application/json", "Authorization": f"Bearer {WT}", "Accept": "application/json, text/event-stream", "X-Agent-ID": "pilot-worker-1", "mcp-session-id": sid or ""})
        try:
            with NOPROXY.open(r, timeout=10) as x: bs, bt = x.status, x.read().decode()
        except urllib.error.HTTPError as e: bs, bt = e.code, e.read().decode()
        expect("mcp JSON-RPC batch refused", "denied by worker-gate" in bt, True)
        s, lst = call(b, "GET", "/api/tasks?limit=50", K)
        extra = [x["task"] for x in lst["tasks"] if x["task"] in ("evil via gate", "mcp evil", "mcp evil via task-action")]
        expect("no task created through the gate (REST or MCP)", len(extra), 0, str(extra))
        s, bl = call(b, "GET", "/api/budgets", K)
        print("  note: budgets after direct section (A) set by the direct worker call:", [x.get("dailyBudgetUsd") for x in bl.get("budgets", [])])
        s, sc = call(b, "GET", "/api/config?includeSecrets=true", K)
        print("\n== gate log (counts):", end=" ")
        recs = [json.loads(l) for l in open(S.dir + "/gate.log") if l.strip()]
        from collections import Counter
        print(dict(Counter(r["decision"] for r in recs)))
        leaked_log = any(WT in l or "THROWAWAY" in l or "Bearer" in l for l in open(S.dir + "/gate.log"))
        expect("gate log contains no token or secret", leaked_log, False)
        import shutil; shutil.copy(S.dir + "/gate.log", os.path.join(os.path.dirname(os.path.abspath(__file__)), "gate_live_requests.jsonl"))
    finally:
        gate.terminate(); gate.wait(5); gl.close()
print("\nRESULT:", "FAIL " + str(fails) if fails else "ALL PASS")
sys.exit(1 if fails else 0)
