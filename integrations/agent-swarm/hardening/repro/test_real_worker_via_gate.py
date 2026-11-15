"""Run the REAL worker process (bun src/cli.tsx worker, NO model key, no LLM) against a throwaway API THROUGH the gate.
Shows which requests the real worker boot/poll path makes and whether the gate denies any that it needs."""
import json, os, random, subprocess, sys, time, tempfile, shutil
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from lib import *
GATE = "/home/claude/sandbox/swarm_hardening/config/worker_gate.py"
with Server() as S:
    b, K = S.base, S.key
    gport = random.randint(41000, 58000)
    gate = subprocess.Popen([sys.executable, GATE], env={"PATH": os.environ["PATH"], "GATE_AGENT_ID": "pilot-worker-1", "GATE_UPSTREAM": f"127.0.0.1:{S.port}",
                            "GATE_LISTEN": f"127.0.0.1:{gport}", "GATE_LOG": S.dir + "/gate.log"}, stderr=subprocess.DEVNULL)
    time.sleep(1)
    try:
        s, tk = call(b, "POST", "/api/agents/pilot-worker-1/token", K, {"name": "pilot-worker"}); WT = tk["plaintext"]
        s, t = call(b, "POST", "/api/tasks", K, {"task": "stub (no worker will run it: no model key)", "agentId": "pilot-worker-1", "source": "api", "routingReason": "human_pinned"})
        wh = tempfile.mkdtemp(prefix="wk_home_"); ws = tempfile.mkdtemp(prefix="wk_ws_")
        env = {"PATH": os.environ["PATH"], "HOME": wh, "AGENT_ID": "pilot-worker-1", "AGENT_ROLE": "worker", "HARNESS_PROVIDER": "claude",
               "MCP_BASE_URL": f"http://127.0.0.1:{gport}", "API_KEY": WT, "ANONYMIZED_TELEMETRY": "false", "IMPROVEMENTS_ENABLED": "false",
               "BUSINESS_USE_API_KEY": "", "BUSINESS_USE_URL": "", "MEMORY_RATERS": "", "SLACK_DISABLE": "true", "TEMPLATE_ID": "",
               "TEMPLATE_REGISTRY_URL": "http://127.0.0.1:9", "DISABLE_TELEMETRY": "1", "DISABLE_ERROR_REPORTING": "1", "DISABLE_AUTOUPDATER": "1",
               "CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC": "1", "NO_PROXY": "127.0.0.1,localhost", "WORKER_LOG_DIR": ws + "/logs"}
        wl = open(S.dir + "/worker.log", "w")
        w = subprocess.Popen(["bun", "src/cli.tsx", "worker"], cwd=SW, env=env, stdout=wl, stderr=subprocess.STDOUT)
        time.sleep(22)
        w.terminate()
        try: w.wait(10)
        except Exception: w.kill()
        wl.close()
        recs = [json.loads(l) for l in open(S.dir + "/gate.log") if l.strip()]
        from collections import Counter
        c = Counter((r["method"], r["path"].rstrip("/") if not r["path"].count("/") > 3 else "/".join(r["path"].split("/")[:4]) + "/...", r["decision"], r["status"]) for r in recs)
        print("worker requests seen by the gate (method, path, decision, upstream/status):")
        for k, n in sorted(c.items()): print("  %3d  %-6s %-48s %-5s %s" % (n, k[0], k[1], k[2], k[3]))
        den = [r for r in recs if r["decision"] == "DENY"]
        print("\nDENIED requests from the real worker:", len(den))
        for r in den[:20]: print("  ", r["method"], r["path"], "-", r["reason"])
        print("\nworker log tail:"); print("".join(open(S.dir + "/worker.log").readlines()[-12:])[:1800])
        s, ag = call(b, "GET", "/api/agents", K); print("agents registered:", [(a["id"], a["status"], a.get("isLead")) for a in ag.get("agents", ag)] if isinstance(ag, dict) else ag)
        shutil.rmtree(wh, ignore_errors=True); shutil.rmtree(ws, ignore_errors=True)
    finally:
        gate.terminate(); gate.wait(5)
