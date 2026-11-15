import json
from lib import *
def mcp_call(b, tok, agent, method, params=None, sid=None, id_=1):
    h = {"Accept": "application/json, text/event-stream", "X-Agent-ID": agent, "Content-Type": "application/json", "Authorization": f"Bearer {tok}"}
    if sid: h["mcp-session-id"] = sid
    body = {"jsonrpc": "2.0", "id": id_, "method": method}
    if params is not None: body["params"] = params
    r = urllib.request.Request(b + "/mcp", method="POST", data=json.dumps(body).encode(), headers=h)
    try:
        with NOPROXY.open(r, timeout=20) as x: return x.status, x.headers.get("mcp-session-id"), x.read().decode()
    except urllib.error.HTTPError as e: return e.code, None, e.read().decode()
