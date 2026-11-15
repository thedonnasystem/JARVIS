import unittest
import swarm_adapter as A


class FakeHTTP:
    """Records every request; scripted task statuses."""
    def __init__(self, statuses=("pending", "in_progress", "completed"), fail_create=False):
        self.calls, self.statuses, self.i, self.fail_create = [], list(statuses), 0, fail_create
    def __call__(self, method, url, headers, body):
        self.calls.append((method, url.split("//", 1)[1].split("/", 1)[1], body))
        if method == "POST" and url.endswith("/api/tasks"):
            return (500, "boom") if self.fail_create else (201, '{"id":"T1"}')
        if method == "GET":
            s = self.statuses[min(self.i, len(self.statuses) - 1)]; self.i += 1
            return 200, '{"id":"T1","status":"%s","output":"wrote hello.txt","failureReason":"bad"}' % s
        if method == "POST" and url.endswith("/cancel"):
            return 200, "{}"
        return 404, "{}"
    def creates(self): return [c for c in self.calls if c[0] == "POST" and c[1] == "api/tasks"]


class Rpc:
    def __init__(self, req): self.req, self.calls = req, []
    def __call__(self, name, args):
        self.calls.append((name, args))
        return self.req if name == "executor_request" else {"ok": True}


def go(rpc, http, **kw):
    c = A.SwarmClient("http://x", "k", http=http)
    d = dict(agent="builder", hq_task_id="hq1", est_cents=5, purpose="p", prompt="write hello", swarm_agent_id="W",
             interval_s=0, sleep=lambda s: None); d.update(kw)
    return A.run_swarm_task(rpc, c, **d)


class Gate(unittest.TestCase):
    def test_hq_refusal_creates_no_swarm_task(self):
        h, r = FakeHTTP(), Rpc({"ok": False, "reason": "kill switch is on"})
        with self.assertRaises(A.ExecutorRefused) as e: go(r, h)
        self.assertIn("kill switch", str(e.exception))
        self.assertEqual(h.calls, [])                                  # zero HTTP traffic at all
        self.assertEqual([n for n, _ in r.calls], ["executor_request"])  # nothing settled

    def test_dry_run_creates_no_swarm_task(self):
        h, r = FakeHTTP(), Rpc({"ok": True, "dry_run": True, "run_id": "r1"})
        out = go(r, h)
        self.assertEqual(out["status"], "dry_run"); self.assertEqual(h.calls, [])
        self.assertEqual([n for n, _ in r.calls], ["executor_request"])

    def test_happy_path_creates_polls_and_settles_with_hash(self):
        h, r = FakeHTTP(), Rpc({"ok": True, "dry_run": False, "run_id": "r1"})
        out = go(r, h)
        self.assertEqual(out["status"], "done"); self.assertEqual(len(h.creates()), 1)
        self.assertEqual(out["result"]["swarm_task_id"], "T1")
        n, a = r.calls[-1]
        self.assertEqual((n, a["p_status"], a["p_actual_cents"]), ("executor_complete", "done", 5))  # default = full estimate
        self.assertEqual(len(a["p_result_sha256"]), 64)
        body = h.creates()[0][2].decode(); self.assertIn("human_pinned", body); self.assertIn("run:r1", body)

    def test_cost_fn_settles_actual(self):
        h, r = FakeHTTP(), Rpc({"ok": True, "dry_run": False, "run_id": "r1"})
        go(r, h, cost_fn=lambda t: 2)
        self.assertEqual(r.calls[-1][1]["p_actual_cents"], 2)

    def test_swarm_failure_settles_failed_at_full_reservation(self):
        h, r = FakeHTTP(statuses=("in_progress", "failed")), Rpc({"ok": True, "dry_run": False, "run_id": "r1"})
        with self.assertRaises(A.SwarmError): go(r, h)
        n, a = r.calls[-1]; self.assertEqual((n, a["p_status"], a["p_actual_cents"]), ("executor_complete", "failed", 5))

    def test_create_error_settles_failed(self):
        h, r = FakeHTTP(fail_create=True), Rpc({"ok": True, "dry_run": False, "run_id": "r1"})
        with self.assertRaises(A.SwarmError): go(r, h)
        self.assertEqual(r.calls[-1][1]["p_status"], "failed")

    def test_timeout_cancels_swarm_task_then_settles_failed(self):
        h, r = FakeHTTP(statuses=("pending",)), Rpc({"ok": True, "dry_run": False, "run_id": "r1"})
        t = iter(range(0, 1000, 10))
        with self.assertRaises(A.SwarmError): go(r, h, timeout_s=25, clock=lambda: next(t))
        self.assertTrue(any(c[1].endswith("/cancel") for c in h.calls))
        self.assertEqual(r.calls[-1][1]["p_status"], "failed")

    def test_complete_retried_once(self):
        n = {"c": 0}
        def rpc(name, args):
            if name == "executor_request": return {"ok": True, "dry_run": False, "run_id": "r1"}
            n["c"] += 1
            if n["c"] == 1: raise RuntimeError("net")
            return {"ok": True}
        self.assertEqual(go(rpc, FakeHTTP())["status"], "done"); self.assertEqual(n["c"], 2)


if __name__ == "__main__":
    unittest.main()
