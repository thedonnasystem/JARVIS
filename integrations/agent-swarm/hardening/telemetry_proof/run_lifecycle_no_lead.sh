#!/usr/bin/env bash
# Local only. Reduced CAPABILITIES, no lead agent, per-agent worker token drives one stub task (no LLM).
# Proves: (1) worker token can register/poll/finish; (2) NO lead follow-up task is spawned; (3) worker token cannot act as admin.
set -u
SW=/home/claude/sandbox/swarm; R=/home/claude/sandbox/swarm_hardening/telemetry_proof/run_lc; rm -rf $R; mkdir -p $R/data $R/home
KEY="lc-$(head -c12 /dev/urandom | od -An -tx1 | tr -d ' \n')"; P=13995
( cd $SW && env -i PATH="$PATH" HOME=$R/home PORT=$P API_KEY=$KEY DATABASE_PATH=$R/data/db.sqlite ANONYMIZED_TELEMETRY=false \
   HEARTBEAT_DISABLE=true IMPROVEMENTS_ENABLED=false SLACK_DISABLE=true MEMORY_RATERS= \
   CAPABILITIES=core,task-pool,config,mcp,profiles,memory,metrics,kv bun src/http.ts > $R/api.log 2>&1 & echo $! > $R/pid )
for i in $(seq 1 40); do curl -s --noproxy '*' -o /dev/null http://127.0.0.1:$P/health && break; sleep 0.5; done
python3 - "$P" "$KEY" <<'PY'
import json, sys, urllib.request
P, KEY = sys.argv[1], sys.argv[2]
op = urllib.request.build_opener(urllib.request.ProxyHandler({}))
def call(m, path, tok, body=None, hdr=None):
    h = {"Authorization": f"Bearer {tok}", "Content-Type": "application/json"}; h.update(hdr or {})
    r = urllib.request.Request(f"http://127.0.0.1:{P}{path}", method=m, headers=h, data=json.dumps(body).encode() if body is not None else None)
    try:
        with op.open(r, timeout=15) as x: return x.status, json.loads(x.read() or b"null")
    except urllib.error.HTTPError as e:
        t = e.read().decode(); return e.code, (json.loads(t) if t[:1] in "{[" else t)
s, tk = call("POST", "/api/agents/pilot-worker-1/token", KEY, {"name": "pilot-worker"}); print("mint worker token:", s, sorted(tk))
WT = tk["plaintext"]; RT = {"X-Agent-ID": "pilot-worker-1", "X-Runtime-Instance-ID": "rt-pilot-1"}
s, a = call("POST", "/api/agents", WT, {"name": "pilot-worker", "isLead": False, "role": "coder", "capabilities": ["code"], "maxTasks": 1, "runtimeInstanceId": "rt-pilot-1"}, RT); print("worker registers with its token:", s)
s, a2 = call("POST", "/api/agents", WT, {"name": "evil-lead", "isLead": True, "role": "lead", "runtimeInstanceId": "rt-evil"}, {"X-Agent-ID": "pilot-worker-1"}); print("worker token tries to register a LEAD agent:", s, str(a2)[:120])
s, t = call("POST", "/api/tasks", KEY, {"task": "stub task", "agentId": "pilot-worker-1", "source": "api", "routingReason": "human_pinned", "tags": ["run:test"]}); tid = t.get("id"); print("operator creates task:", s, t.get("status"))
s, p = call("GET", "/api/poll", WT, None, RT); print("worker polls with token:", s, str(p)[:90])
s, f = call("POST", f"/api/tasks/{tid}/finish", WT, {"status": "completed", "output": "stub"}, RT); print("worker finishes:", s)
s, lst = call("GET", "/api/tasks?limit=50", KEY); tasks = lst.get("tasks", lst) if isinstance(lst, dict) else lst
print("tasks after finish:", [(x["status"], x["task"][:40]) for x in tasks])
s, _ = call("POST", "/api/tasks", WT, {"task": "worker-created task", "source": "api"}, RT); print("worker token creates a new task:", s)
s, _ = call("GET", "/api/agents", WT, None, RT); print("worker token lists agents:", s)
s, _ = call("PUT", "/api/config", WT, {"scope": "global", "key": "X", "value": "1"}, RT); print("worker token writes global config:", s)
s, b = call("GET", "/api/budgets", KEY); print("GET /api/budgets (operator):", s, str(b)[:100])
PY
kill $(cat $R/pid) 2>/dev/null; pkill -f "src/http.ts"
