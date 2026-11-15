"""How much of the 509-operation API surface does the gate leave reachable for the worker token?"""
import json, re, sys
sys.path.insert(0, "../config")
import worker_gate as g
rows = json.load(open("sweep_rows.json"))
H = {"authorization": "Bearer aseph_" + "a" * 32, "x-agent-id": "pilot-worker-1"}
U = "00000000-0000-0000-0000-000000000000"
def conc(p): return re.sub(r"\{[^}]+\}", lambda m: "pilot-worker-1" if "agent" in p.lower() and m.group(0) in ("{id}", "{agentId}") and "/agents/" in p else U, p)
reached = [r for r in rows if r[2] not in (401, 403, 404)]
allowed = []
for m, p, st in rows:
    body = json.dumps({"name": "x"}).encode() if m == "POST" and p == "/api/agents" else b"{}"
    d = g.decide(m, conc(p), H, body, "pilot-worker-1")
    if d.allow: allowed.append((m, p, st))
print(f"documented operations: {len(rows)}")
print(f"reachable by the worker token directly (not 401/403/404): {len(reached)}")
print(f"allowed through the gate: {len(allowed)}  ({100*len(allowed)//len(rows)}% of the surface)")
print("\nallowed operations:")
for m, p, st in sorted(allowed, key=lambda x: x[1]): print(f"  {m:6s} {p}")
print("\nreachable-directly but denied by the gate (sample of high-risk ones):")
risky = ("/api/config", "/api/tasks", "/api/budgets", "/api/schedules", "/api/scripts", "/api/skills", "/api/db-query", "/api/mcp-servers", "/api/users", "/api/internal", "/api/kv", "/api/workflows", "/api/apps", "/api/pages", "/api/oauth")
for m, p, st in rows:
    if st not in (401, 403, 404) and (m, p, st) not in allowed and p.startswith(risky) and m != "GET": print(f"  {m:6s} {p}  (direct status {st})")
