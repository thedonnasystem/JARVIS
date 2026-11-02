import unittest, urllib.error, io, json
from unittest import mock
import hq, hq_engine as E


def http_err(code, msg):
    return urllib.error.HTTPError("u", code, msg, {}, io.BytesIO(json.dumps({"message": msg}).encode()))


class Board:
    """Fake HQ database behind hq._request."""
    def __init__(self, tasks=None, escalations=None, kill=False, block=False):
        self.tasks = tasks or []; self.esc = escalations or []; self.kill = kill; self.block = block
        self.patches = []; self.inserts = []; self.rpcs = []

    def __call__(self, method, path, body=None, timeout=30, prefer=None):
        if path.startswith("/rest/v1/rpc/"):
            name = path.split("/")[-1]; self.rpcs.append((name, body))
            if name == "reserve_llm_budget" and self.block:
                raise http_err(400, "daily cap reached")
            return {"estimate_call_cents": 1}.get(name, 1 if name != "reserve_llm_budget" else "call-1")
        if method == "GET":
            if path.startswith("/rest/v1/system_state"): return [{"kill_switch": self.kill}]
            if path.startswith("/rest/v1/agents"): return [{"slug": "x", "title": "X", "model_tier": "cheap", "role": "r", "metric": "m", "charter": "c"}]
            if path.startswith("/rest/v1/handbook"): return [{"content": "rules"}]
            if path.startswith("/rest/v1/tasks"): return list(self.tasks)
            if path.startswith("/rest/v1/escalations"): return list(self.esc)
        if method == "PATCH":
            self.patches.append((path, body)); return [{"id": 1}] if prefer == "return=representation" else None
        if method == "POST":
            self.inserts.append((path, body)); return None


class T(unittest.TestCase):
    def run_tick(self, board, reply="done"):
        with mock.patch.object(hq, "_request", board), mock.patch.object(E, "_complete", return_value=(reply, 10, 5)):
            E.tick_sync()

    def test_task_done(self):
        b = Board(tasks=[{"id": "t1", "assigned_agent": "x", "title": "T", "detail": "d"}])
        self.run_tick(b)
        self.assertTrue(any(p[1].get("status") == "done" for p in b.patches))
        self.assertIn("settle_llm_call", [r[0] for r in b.rpcs])

    def test_escalate_creates_escalation(self):
        b = Board(tasks=[{"id": "t1", "assigned_agent": "x", "title": "T", "detail": ""}])
        self.run_tick(b, "ESCALATE needs contract")
        self.assertTrue(any("escalations" in p[0] for p in b.inserts))
        self.assertTrue(any(p[1].get("status") == "blocked" for p in b.patches))

    def test_gateway_block_returns_task(self):
        b = Board(tasks=[{"id": "t1", "assigned_agent": "x", "title": "T", "detail": ""}], block=True)
        self.run_tick(b)
        self.assertTrue(any(p[1].get("status") == "todo" for p in b.patches))

    def test_kill_switch_does_nothing(self):
        b = Board(tasks=[{"id": "t1", "assigned_agent": "x", "title": "T", "detail": ""}], kill=True)
        self.run_tick(b)
        self.assertEqual(b.patches, []); self.assertEqual(b.rpcs, [])

    def test_triage_send_to_owner(self):
        b = Board(escalations=[{"id": "e1", "from_agent": "x", "kind": "uncertain", "summary": "sign this"}])
        self.run_tick(b, '{"action":"send_to_owner","kind":"contract","message":"Sign X"}')
        om = [i for i in b.inserts if "owner_messages" in i[0]]
        self.assertEqual(om[0][1]["kind"], "contract")

    def test_triage_bad_kind_defaults_and_bad_json_surfaces(self):
        b = Board(escalations=[{"id": "e1", "from_agent": "x", "kind": "u", "summary": "s"}])
        self.run_tick(b, '{"action":"send_to_owner","kind":"weird","message":"m"}')
        self.assertEqual([i for i in b.inserts if "owner_messages" in i[0]][0][1]["kind"], "proposal")
        b2 = Board(escalations=[{"id": "e2", "from_agent": "x", "kind": "u", "summary": "s"}])
        self.run_tick(b2, "not json")
        self.assertEqual([i for i in b2.inserts if "owner_messages" in i[0]][0][1]["kind"], "health")

    def test_triage_close(self):
        b = Board(escalations=[{"id": "e1", "from_agent": "x", "kind": "u", "summary": "s"}])
        self.run_tick(b, '{"action":"close","message":"fine"}')
        self.assertTrue(any(p[1].get("status") == "closed" for p in b.patches))
        self.assertFalse(any("owner_messages" in i[0] for i in b.inserts))


if __name__ == "__main__":
    unittest.main()
