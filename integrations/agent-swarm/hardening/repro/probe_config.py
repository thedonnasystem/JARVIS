import json, sys
from lib import *
with Server() as S:
    b = S.base; K = S.key
    print("port", S.port)
    # seed throwaway secrets as operator
    for sc, sid, key, val in [("global", None, "FAKE_GLOBAL_SECRET", "THROWAWAY-GLOBAL-SECRET-VALUE"),
                              ("agent", "pilot-worker-1", "FAKE_OWN_AGENT_SECRET", "THROWAWAY-OWN-AGENT-SECRET"),
                              ("agent", "other-agent", "FAKE_OTHER_AGENT_SECRET", "THROWAWAY-OTHER-AGENT-SECRET")]:
        body = {"scope": sc, "key": key, "value": val, "isSecret": True}
        if sid: body["scopeId"] = sid
        s, r = call(b, "PUT", "/api/config", K, body); print("seed", key, s)
    s, r = call(b, "PUT", "/api/config", K, {"scope": "global", "key": "PLAIN_KEY", "value": "plain", "isSecret": False}); print("seed plain", s)
    s, tk = call(b, "POST", "/api/agents/pilot-worker-1/token", K, {"name": "pilot-worker"}); WT = tk["plaintext"]
    print("worker token prefix:", WT[:6], "keys:", sorted(tk))
    RT = {"X-Agent-ID": "pilot-worker-1"}
    call(b, "POST", "/api/agents", WT, {"name": "pilot-worker", "isLead": False, "role": "coder", "capabilities": ["code"], "maxTasks": 1, "runtimeInstanceId": "rt1"}, RT)
    def show(label, m, path, body=None, tok=WT, hdr=RT):
        s, r = call(b, m, path, tok, body, hdr)
        txt = json.dumps(r)
        leak = [v for v in ("THROWAWAY-GLOBAL", "THROWAWAY-OWN", "THROWAWAY-OTHER") if v in txt]
        print(f"{label:62s} -> {s}  leaked={leak}  {txt[:170]}")
        return s, r
    for tok_label, tok in (("operator", K), ("worker", WT)):
        print("=== as", tok_label)
        h = RT if tok is WT else {}
        show("GET /api/config?scope=global&includeSecrets=true", "GET", "/api/config?scope=global&includeSecrets=true", tok=tok, hdr=h)
        show("GET /api/config?includeSecrets=true (all scopes)", "GET", "/api/config?includeSecrets=true", tok=tok, hdr=h)
        show("GET /api/config?scope=agent&scopeId=pilot-worker-1&includeSecrets=true", "GET", "/api/config?scope=agent&scopeId=pilot-worker-1&includeSecrets=true", tok=tok, hdr=h)
        show("GET /api/config?scope=agent&scopeId=other-agent&includeSecrets=true", "GET", "/api/config?scope=agent&scopeId=other-agent&includeSecrets=true", tok=tok, hdr=h)
        show("GET /api/config/resolved?includeSecrets=true", "GET", "/api/config/resolved?includeSecrets=true", tok=tok, hdr=h)
        show("GET /api/config/resolved?agentId=pilot-worker-1&includeSecrets=true", "GET", "/api/config/resolved?agentId=pilot-worker-1&includeSecrets=true", tok=tok, hdr=h)
        show("GET /api/config/resolved?agentId=other-agent&includeSecrets=true", "GET", "/api/config/resolved?agentId=other-agent&includeSecrets=true", tok=tok, hdr=h)
    # by id
    s, lst = call(b, "GET", "/api/config?includeSecrets=true", K)
    for c in lst["configs"]:
        show(f"GET /api/config/{c['key']} (by id) includeSecrets", "GET", f"/api/config/{c['id']}?includeSecrets=true")
    show("GET /api/config/env-presence", "GET", "/api/config/env-presence")
    show("PUT /api/config global", "PUT", "/api/config", {"scope": "global", "key": "X", "value": "1"})
    show("PUT /api/config agent own scope", "PUT", "/api/config", {"scope": "agent", "scopeId": "pilot-worker-1", "key": "X", "value": "1"})
    show("POST /internal/reload-config", "POST", "/internal/reload-config")
    show("POST /api/tasks (create)", "POST", "/api/tasks", {"task": "worker-created", "source": "api"})
