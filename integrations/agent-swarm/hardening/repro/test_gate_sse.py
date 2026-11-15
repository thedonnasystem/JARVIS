"""GET /mcp (SSE stream) and DELETE /mcp through the gate behave like direct (status + streaming not buffered)."""
import json, os, random, subprocess, sys, time, socket
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from lib import *
from probe_mcp_helpers import mcp_call
def raw_get(host, port, path, hdr, secs=4):
    s = socket.create_connection((host, port), timeout=secs)
    s.sendall((f"GET {path} HTTP/1.1\r\nHost: x\r\n" + "".join(f"{k}: {v}\r\n" for k, v in hdr.items()) + "Connection: close\r\n\r\n").encode())
    buf = b""; t0 = time.time()
    try:
        while time.time() - t0 < secs:
            d = s.recv(4096)
            if not d: break
            buf += d
    except socket.timeout: pass
    s.close(); return buf.decode(errors="replace")
with Server() as S:
    gport = random.randint(41000, 58000)
    g = subprocess.Popen([sys.executable, "/home/claude/sandbox/swarm_hardening/config/worker_gate.py"], env={"PATH": os.environ["PATH"], "GATE_AGENT_ID": "pilot-worker-1", "GATE_UPSTREAM": f"127.0.0.1:{S.port}", "GATE_LISTEN": f"127.0.0.1:{gport}", "GATE_LOG": S.dir + "/g.log"}, stderr=subprocess.DEVNULL)
    time.sleep(1)
    try:
        s, tk = call(S.base, "POST", "/api/agents/pilot-worker-1/token", S.key, {"name": "w"}); WT = tk["plaintext"]
        call(S.base, "POST", "/api/agents", WT, {"name": "w", "isLead": False, "role": "coder", "capabilities": ["code"], "maxTasks": 1, "runtimeInstanceId": "rt1"}, {"X-Agent-ID": "pilot-worker-1"})
        s, sid, t = mcp_call(f"http://127.0.0.1:{gport}", WT, "pilot-worker-1", "initialize", {"protocolVersion": "2025-03-26", "capabilities": {}, "clientInfo": {"name": "t", "version": "0"}})
        h = {"Authorization": f"Bearer {WT}", "X-Agent-ID": "pilot-worker-1", "Accept": "text/event-stream", "mcp-session-id": sid}
        w = raw_get("127.0.0.1", gport, "/mcp", h)
        s2, sid2, _ = mcp_call(S.base, WT, "pilot-worker-1", "initialize", {"protocolVersion": "2025-03-26", "capabilities": {}, "clientInfo": {"name": "t", "version": "0"}})
        h2 = {**h, "mcp-session-id": sid2}; d = raw_get("127.0.0.1", S.port, "/mcp", h2)
        print("direct  GET /mcp ->", d.split("\r\n")[0], "| content-type:", [l for l in d.split("\r\n") if l.lower().startswith("content-type")][:1])
        print("gate    GET /mcp ->", w.split("\r\n")[0], "| content-type:", [l for l in w.split("\r\n") if l.lower().startswith("content-type")][:1])
        print("same status line:", d.split("\r\n")[0].split()[1] == w.split("\r\n")[0].split()[1])
        r = urllib.request.Request(f"http://127.0.0.1:{gport}/mcp", method="DELETE", headers={"Authorization": f"Bearer {WT}", "X-Agent-ID": "pilot-worker-1", "mcp-session-id": sid})
        try:
            with NOPROXY.open(r, timeout=5) as x: print("gate DELETE /mcp ->", x.status)
        except urllib.error.HTTPError as e: print("gate DELETE /mcp ->", e.code)
    finally:
        g.terminate(); g.wait(5)
