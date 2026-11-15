import json
from lib import *
HDR = {"Accept": "application/json, text/event-stream"}
def mcp(b, tok, method, params=None, sid=None, id_=1, extra=None):
    h = dict(HDR); h["X-Agent-ID"] = "pilot-worker-1"
    if sid: h["mcp-session-id"] = sid
    h.update(extra or {})
    body = {"jsonrpc": "2.0", "id": id_, "method": method}
    if params is not None: body["params"] = params
    r = urllib.request.Request(b + "/mcp", method="POST", data=json.dumps(body).encode(), headers={"Content-Type": "application/json", "Authorization": f"Bearer {tok}", **h})
    try:
        with NOPROXY.open(r, timeout=20) as x: return x.status, x.headers.get("mcp-session-id"), x.read().decode()
    except urllib.error.HTTPError as e: return e.code, None, e.read().decode()
with Server() as S:
    b, K = S.base, S.key
    s, tk = call(b, "POST", "/api/agents/pilot-worker-1/token", K, {"name": "pilot-worker"}); WT = tk["plaintext"]
    RT = {"X-Agent-ID": "pilot-worker-1"}
    call(b, "POST", "/api/agents", WT, {"name": "pilot-worker", "isLead": False, "role": "coder", "capabilities": ["code"], "maxTasks": 1, "runtimeInstanceId": "rt1"}, RT)
    call(b, "PUT", "/api/config", K, {"scope": "global", "key": "FAKE_GLOBAL_SECRET", "value": "THROWAWAY-GLOBAL-SECRET-VALUE", "isSecret": True})
    s, sid, t = mcp(b, WT, "initialize", {"protocolVersion": "2025-03-26", "capabilities": {}, "clientInfo": {"name": "t", "version": "0"}})
    print("initialize", s, sid, t[:120])
    mcp(b, WT, "notifications/initialized", sid=sid, id_=None)
    s, _, t = mcp(b, WT, "tools/list", {}, sid=sid, id_=2)
    names = sorted(set(__import__("re").findall(r'"name":"([a-z0-9-]+)"', t)))
    print("tools/list", s, len(names)); print(" ".join(names))
    open("mcp_tools_worker.txt", "w").write("\n".join(names))
    def tc(name, args, i):
        s, _, t = mcp(b, WT, "tools/call", {"name": name, "arguments": args}, sid=sid, id_=i)
        print(f"tools/call {name} {json.dumps(args)[:80]} -> {s} {t[:260].replace(chr(10),' ')}")
    tc("send-task", {"task": "mcp-created task"}, 3)
    tc("get-config", {"includeSecrets": True, "scope": "global"}, 4)
    tc("list-config", {"includeSecrets": True}, 5)
    tc("set-config", {"scope": "global", "key": "X", "value": "1"}, 6)
    s, lst = call(b, "GET", "/api/tasks", K); print("tasks now:", [t["task"][:30] for t in lst["tasks"]])
