import asyncio, os, unittest
from types import SimpleNamespace
from unittest import mock
import hq, hq_commands as C


class Msg:
    def __init__(self): self.sent = []
    async def reply_text(self, t): self.sent.append(t)


def upd(uid="42"):
    return SimpleNamespace(effective_user=SimpleNamespace(id=uid), message=Msg())


class Fake:
    def __init__(self): self.calls = []
    def __call__(self, method, path, body=None, timeout=30, prefer=None):
        self.calls.append((method, path, body))
        if method == "GET" and path.startswith("/rest/v1/ventures"): return [{"id": "v-dj", "slug": "day-job-sales"}]
        if method == "GET" and path.startswith("/rest/v1/agents"): return [{"slug": "donna-researcher", "venture_id": "v-d", "status": "active"}]
        return []


class T(unittest.TestCase):
    def setUp(self):
        os.environ["JARVIS_OWNER_ID"] = "42"

    def test_parse_amount(self):
        self.assertEqual(C.parse_amount("450"), 45000)
        self.assertEqual(C.parse_amount("$1,250.5"), 125050)
        self.assertIsNone(C.parse_amount("-5"))
        self.assertIsNone(C.parse_amount("abc"))
        self.assertIsNone(C.parse_amount("0"))

    def test_money_logs_revenue_to_venture(self):
        f, u = Fake(), upd()
        with mock.patch.object(hq, "_request", f):
            asyncio.run(C.hq_money(u, SimpleNamespace(args=["in", "450", "dayjob", "Nov", "commission"])))
        post = [c for c in f.calls if c[0] == "POST" and "ledger" in c[1]][0][2]
        self.assertEqual((post["kind"], post["amount_cents"], post["venture_id"], post["note"]), ("revenue", 45000, "v-dj", "Nov commission"))
        self.assertIn("$450.00", u.message.sent[0])

    def test_non_owner_ignored(self):
        f, u = Fake(), upd("999")
        with mock.patch.object(hq, "_request", f):
            asyncio.run(C.hq_kill(u, SimpleNamespace(args=[])))
        self.assertFalse(f.calls)
        self.assertFalse(u.message.sent)

    def test_ask_queues_task_for_agent(self):
        f, u = Fake(), upd()
        with mock.patch.object(hq, "_request", f):
            asyncio.run(C.hq_ask(u, SimpleNamespace(args=["donna-researcher", "find", "10", "HVAC", "shops"])))
        task = [c for c in f.calls if c[0] == "POST" and "tasks" in c[1]][0][2]
        self.assertEqual((task["assigned_agent"], task["venture_id"], task["title"]), ("donna-researcher", "v-d", "find 10 HVAC shops"))

    def test_kill_sets_switch_and_audits(self):
        f, u = Fake(), upd()
        with mock.patch.object(hq, "_request", f):
            asyncio.run(C.hq_kill(u, SimpleNamespace(args=[])))
        self.assertTrue(any(c[0] == "PATCH" and c[2] == {"kill_switch": True} for c in f.calls))
        self.assertTrue(any("audit_log" in c[1] for c in f.calls))


if __name__ == "__main__":
    unittest.main()
