import unittest
from unittest import mock
import hq_executor as EX


class Fake:
    def __init__(self, request):
        self.request = request; self.calls = []
    def __call__(self, name, args):
        self.calls.append((name, args))
        return self.request if name == "executor_request" else {"ok": True}


def patch(fake):
    return mock.patch.object(EX, "_rpc", fake)


class Run(unittest.TestCase):
    def test_refused_runs_nothing_and_does_not_settle(self):
        f = Fake({"ok": False, "reason": "kill switch is on"}); called = []
        with patch(f), self.assertRaises(EX.ExecutorRefused) as c:
            EX.run("swarm", "builder", "t", 5, "p", lambda r: called.append(r))
        self.assertIn("kill switch", str(c.exception)); self.assertEqual(called, [])
        self.assertEqual([n for n, _ in f.calls], ["executor_request"])

    def test_dry_run_never_executes(self):
        f = Fake({"ok": True, "dry_run": True, "run_id": "r1"}); called = []
        with patch(f):
            out = EX.run("swarm", "builder", "t", 5, "p", lambda r: called.append(r))
        self.assertEqual(out["status"], "dry_run"); self.assertEqual(called, [])
        self.assertEqual([n for n, _ in f.calls], ["executor_request"])

    def test_success_settles_actual_cost_with_hash(self):
        f = Fake({"ok": True, "dry_run": False, "run_id": "r1"})
        with patch(f):
            out = EX.run("swarm", "builder", "t", 5, "p", lambda r: ({"a": 1}, 3))
        self.assertEqual(out["status"], "done")
        n, a = f.calls[-1]
        self.assertEqual((n, a["p_actual_cents"], a["p_status"]), ("executor_complete", 3, "done"))
        self.assertEqual(len(a["p_result_sha256"]), 64)

    def test_crash_settles_failed_at_full_reservation_and_reraises(self):
        f = Fake({"ok": True, "dry_run": False, "run_id": "r1"})
        def boom(r): raise RuntimeError("worker died")
        with patch(f), self.assertRaises(RuntimeError):
            EX.run("swarm", "builder", "t", 5, "p", boom)
        n, a = f.calls[-1]
        self.assertEqual((n, a["p_actual_cents"], a["p_status"]), ("executor_complete", 5, "failed"))

    def test_negative_actual_is_clamped(self):
        f = Fake({"ok": True, "dry_run": False, "run_id": "r1"})
        with patch(f):
            EX.run("swarm", "builder", "t", 5, "p", lambda r: ("x", -4))
        self.assertEqual(f.calls[-1][1]["p_actual_cents"], 0)

    def test_hash_is_stable(self):
        self.assertEqual(EX.result_sha256({"b": 1, "a": 2}), EX.result_sha256({"a": 2, "b": 1}))


if __name__ == "__main__":
    unittest.main()
