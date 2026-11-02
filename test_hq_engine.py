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
        with mock.patch.object(hq, "_request", board), mock.patch.object(E, "_complete", return_value=(reply, 10, 5, 0)):
            E.tick_sync()

    def test_search_flag_and_cost(self):
        self.assertTrue(E.can_search("real-estate-researcher")); self.assertTrue(E.can_search("donna-auditor"))
        self.assertFalse(E.can_search("ceo")); self.assertFalse(E.can_search("jarvis"))
        b = Board(tasks=[{"id": "t1", "assigned_agent": "real-estate-researcher", "title": "T", "detail": ""}])
        with mock.patch.object(hq, "_request", b), mock.patch.object(E, "_complete", return_value=("ok", 10, 5, 2)) as c:
            E.tick_sync()
        self.assertTrue(c.call_args[0][4] is True)
        settle = [r for r in b.rpcs if r[0] == "settle_llm_call"][0][1]
        self.assertEqual(settle["p_actual_cents"], 1 + 2 * E.SEARCH_CENTS)

    def test_stale_doing_tasks_requeued(self):
        b = Board()
        self.run_tick(b)
        self.assertTrue(any("status=eq.doing" in p[0] and p[1].get("status") == "todo" for p in b.patches))

    def test_plan_creates_guarded_tasks(self):
        plan = '[{"agent":"donna-researcher","title":"A","detail":"d"},{"agent":"ghost","title":"B","detail":"d"},{"agent":"jarvis","title":"C","detail":"d"},{"agent":"donna-researcher","title":"D","detail":"d"},{"agent":"donna-researcher","title":"E","detail":"d"}]'
        b = Board(tasks=[{"id": "t1", "assigned_agent": "jarvis", "title": "Daily planning 2026-11-02", "detail": ""}])
        orig = b.__call__
        def fake(method, path, body=None, timeout=30, prefer=None):
            if path.startswith("/rest/v1/agents?status=eq.active"): return [{"slug": "donna-researcher"}, {"slug": "jarvis"}]
            return orig(method, path, body, timeout, prefer)
        with mock.patch.object(hq, "_request", fake), mock.patch.object(E, "_complete", return_value=(plan, 10, 5, 0)):
            E.tick_sync()
        made = [i for i in b.inserts if i[0].endswith("/tasks")]
        self.assertEqual([m[1]["title"] for m in made], ["A"])  # only the first 3 proposals are read; ghost and self-assigned are skipped
        self.assertIn("No contacting anyone", made[0][1]["detail"])

    def test_research_task_logs_prediction_and_queues_audit(self):
        b = Board(tasks=[{"id": "t1", "assigned_agent": "donna-researcher", "title": "Map", "detail": ""}])
        self.run_tick(b, "Found it. Source: https://example.com/page.")
        pred = [i for i in b.inserts if i[0].endswith("/predictions")][0][1]
        self.assertTrue(pred["correct"]); self.assertEqual(pred["action_ref"], "task:t1")
        audit = [i for i in b.inserts if i[0].endswith("/tasks")][0][1]
        self.assertEqual(audit["assigned_agent"], "donna-auditor"); self.assertTrue(audit["title"].startswith("Audit: "))
        self.assertIn("<<<", audit["detail"])

    def test_cut_off_or_unsourced_research_is_a_wrong_prediction(self):
        b = Board(tasks=[{"id": "t1", "assigned_agent": "donna-researcher", "title": "Map", "detail": ""}])
        self.run_tick(b, "Found it, and then the answer stops mid sen")
        self.assertFalse([i for i in b.inserts if i[0].endswith("/predictions")][0][1]["correct"])

    def test_audit_of_audit_not_queued_and_fail_escalates(self):
        b = Board(tasks=[{"id": "t2", "assigned_agent": "donna-auditor", "title": "Audit: Map", "detail": ""}])
        self.run_tick(b, "Claim 2 is wrong.\nVERDICT: FAIL, price outdated.")
        self.assertFalse([i for i in b.inserts if i[0].endswith("/tasks")])
        self.assertTrue([i for i in b.inserts if i[0].endswith("/escalations")])

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
