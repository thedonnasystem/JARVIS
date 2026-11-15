"""Probe every documented route with the per-agent worker token vs the operator key on a throwaway server.
Bodies are empty/minimal, so 400/404/422 = reached the handler (auth passed); 401/403 = denied at auth/RBAC."""
import json, re, sys
from lib import *
with Server() as S:
    b, K = S.base, S.key
    s, spec = call(b, "GET", "/openapi.json"); paths = spec["paths"]
    s, tk = call(b, "POST", "/api/agents/pilot-worker-1/token", K, {"name": "pilot-worker"}); WT = tk["plaintext"]
    RT = {"X-Agent-ID": "pilot-worker-1"}
    call(b, "POST", "/api/agents", WT, {"name": "pilot-worker", "isLead": False, "role": "coder", "capabilities": ["code"], "maxTasks": 1, "runtimeInstanceId": "rt1"}, RT)
    rows = []
    for p, ops in sorted(paths.items()):
        url = re.sub(r"\{[^}]+\}", "pilot-worker-1" if "agent" in p.lower() else "00000000-0000-0000-0000-000000000000", p)
        for m, op in ops.items():
            if m not in ("get", "post", "put", "patch", "delete"): continue
            if "token" in p and m == "delete": pass
            body = {} if m != "get" else None
            sw, _ = call(b, m.upper(), url, WT, body, RT)
            rows.append((m.upper(), p, sw))
    from collections import Counter
    c = Counter(r[2] for r in rows)
    print("total ops", len(rows), "by status", dict(c))
    denied = [r for r in rows if r[2] in (401, 403)]
    reached = [r for r in rows if r[2] not in (401, 403, 404)]
    print("\nDENIED (401/403) for worker token:", len(denied))
    print("\nREACHED handler (not 401/403/404) for worker token:", len(reached))
    for r in reached: print("  %-6s %-70s %s" % r)
    json.dump(rows, open("sweep_rows.json", "w"))
