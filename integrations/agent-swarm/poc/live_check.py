import json, threading, time, pathlib, urllib.request
import swarm_adapter as A
KEY = pathlib.Path("/home/claude/sandbox/swarm_run/key.txt").read_text().strip()
c = A.SwarmClient("http://127.0.0.1:13999", KEY)
def n_tasks(): return len(c._call("GET", "/api/tasks?limit=200")["tasks"])
RT = "stub-coder-live-" + str(int(time.time()))
wid = c._call("POST", "/api/agents", {"name": "poc-coder-live-"+RT[-5:], "isLead": False, "role": "coder", "maxTasks": 1, "runtimeInstanceId": RT})["id"]
def worker():  # stub: poll -> claim, finish
    for _ in range(30):
        req = urllib.request.Request("http://127.0.0.1:13999/api/poll", headers={"Authorization": f"Bearer {KEY}", "X-Agent-ID": wid, "X-Runtime-Instance-ID": RT})
        t = json.load(c.opener.open(req, timeout=10)).get("trigger")
        if t and t.get("taskId"):
            pathlib.Path("/home/claude/sandbox/swarm_run/hello2.txt").write_text("hello\n")
            c._http("POST", f"http://127.0.0.1:13999/api/tasks/{t['taskId']}/finish", {"Authorization": f"Bearer {KEY}", "Content-Type": "application/json", "X-Agent-ID": wid}, b'{"status":"completed","output":"wrote hello2.txt"}')
            return
        time.sleep(1)
class R:
    def __init__(s, r): s.r, s.calls = r, []
    def __call__(s, n, a): s.calls.append(n); return s.r if n == "executor_request" else {"ok": True}
before = n_tasks()
for label, resp in [("refused", {"ok": False, "reason": "kill switch is on"}), ("dry_run", {"ok": True, "dry_run": True, "run_id": "r"})]:
    r = R(resp)
    try: print(label, "->", A.run_swarm_task(r, c, agent="builder", hq_task_id="t", est_cents=5, purpose="p", prompt="x", swarm_agent_id=wid)["status"])
    except A.ExecutorRefused as e: print(label, "-> ExecutorRefused:", e)
    print("  tasks before/after:", before, n_tasks(), "rpc:", r.calls)
th = threading.Thread(target=worker); th.start()
r = R({"ok": True, "dry_run": False, "run_id": "run-live"})
out = A.run_swarm_task(r, c, agent="builder", hq_task_id="t", est_cents=5, purpose="p", prompt="Write hello to hello2.txt (stub)", swarm_agent_id=wid, interval_s=1, timeout_s=40)
print("approved ->", out["status"], out["result"], "rpc:", r.calls); th.join()
# timeout path: no worker => cancel
r = R({"ok": True, "dry_run": False, "run_id": "run-to"})
try: A.run_swarm_task(r, c, agent="builder", hq_task_id="t", est_cents=5, purpose="p", prompt="never claimed", swarm_agent_id=wid, interval_s=1, timeout_s=3)
except A.SwarmError as e: print("timeout ->", e, "rpc:", r.calls)
ts = c._call("GET", "/api/tasks?limit=200")["tasks"]; print("final statuses:", [(t["task"][:20], t["status"]) for t in ts if "never" in t["task"] or "hello2" in t["task"]])
