"""Stub worker (NO LLM): drives one task through the real swarm HTTP API. Local sandbox only."""
import json, sys, time, urllib.request, pathlib
BASE = "http://127.0.0.1:13999"
KEY = pathlib.Path("/home/claude/sandbox/swarm_run/key.txt").read_text().strip()
RUN = str(int(time.time()))
OUT = pathlib.Path("/home/claude/sandbox/swarm_run/hello.txt")
opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
def call(m, path, body=None, agent=None):
    h = {"Authorization": f"Bearer {KEY}", "Content-Type": "application/json"}
    if agent: h["X-Agent-ID"] = agent; h["X-Runtime-Instance-ID"] = "stub-coder-"+RUN
    r = urllib.request.Request(BASE + path, method=m, headers=h, data=json.dumps(body).encode() if body is not None else None)
    try:
        with opener.open(r, timeout=15) as x: s, t = x.status, x.read().decode()
    except urllib.error.HTTPError as e: s, t = e.code, e.read().decode()
    print(f"{m} {path} -> {s} {t[:350]}")
    return s, (json.loads(t) if t[:1] in "{[" else t)
_, lead = call("POST", "/api/agents", {"name": "poc-lead", "isLead": True, "role": "lead", "capabilities": ["plan"], "runtimeInstanceId": "stub-lead-"+RUN})
_, wk = call("POST", "/api/agents", {"name": "poc-coder", "isLead": False, "role": "coder", "capabilities": ["code"], "maxTasks": 1, "runtimeInstanceId": "stub-coder-"+RUN})
wid = wk.get("id") or wk.get("agent", {}).get("id")
_, t = call("POST", "/api/tasks", {"task": "Write 'hello' to hello.txt (stub POC)", "agentId": wid, "source": "api", "routingReason": "human_pinned", "routingNote": "POC", "tags": ["poc"]})
tid = t.get("id") or t.get("task", {}).get("id")
call("GET", f"/api/tasks/{tid}")
s, p = call("GET", "/api/poll", agent=wid)
call("GET", f"/api/tasks/{tid}")
call("POST", f"/api/tasks/{tid}/progress", {"progress": "stub worker writing file"}, agent=wid)
OUT.write_text("hello\n")
call("POST", f"/api/tasks/{tid}/finish", {"status": "completed", "output": "wrote hello.txt"}, agent=wid)
call("GET", f"/api/tasks/{tid}")
print("FILE:", OUT.read_text().strip())
