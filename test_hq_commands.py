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


class L(unittest.TestCase):
    def setUp(self):
        os.environ["JARVIS_OWNER_ID"] = "42"

    def test_parse_lead(self):
        self.assertEqual(C.parse_lead("Jane Doe | 613-555-0101 | fixed rate | 3"),
                         {"name": "Jane Doe", "phone": "613-555-0101", "note": "fixed rate", "days": 3})
        self.assertEqual(C.parse_lead("Bob")["days"], C.DEFAULT_FOLLOWUP_DAYS)
        self.assertIsNone(C.parse_lead("Bob | call me maybe"))  # not a phone number
        self.assertIsNone(C.parse_lead(""))

    def test_done_zero_days_closes(self):
        class F(Fake):
            def __call__(s, method, path, body=None, timeout=30, prefer=None):
                s.calls.append((method, path, body))
                if method == "GET" and "leads" in path: return [{"id": "L1", "name": "Jane", "notes": "", "contact_count": 1}]
                return []
        f, u = F(), upd()
        with mock.patch.object(hq, "_request", f):
            asyncio.run(C.hq_done(u, SimpleNamespace(args=["#7", "0", "signed", "contract"])))
        patch = [c[2] for c in f.calls if c[0] == "PATCH"][0]
        self.assertEqual((patch["status"], patch["next_followup_at"], patch["contact_count"]), ("closed", None, 2))
        self.assertIn("signed contract", patch["notes"])


class ChatTools(unittest.TestCase):
    def test_search_knowledge_formats_and_sanitizes(self):
        class F(Fake):
            def __call__(s, method, path, body=None, timeout=30, prefer=None):
                s.calls.append((method, path, body))
                if "memory" in path: return [{"kind": "fact", "content": "RECO registration needed", "source": "https://reco.on.ca", "confidence": "high"}]
                return []
        f = F()
        with mock.patch.object(hq, "_request", f):
            out = asyncio.run(C.handle_chat_tool("hq_search_knowledge", {"query": "RECO);drop"}))
        self.assertIn("RECO registration needed", out)
        self.assertNotIn(";", f.calls[0][1].split("content=ilike.")[1].split("&")[0])

    def test_assign_rejects_unknown_agent(self):
        with mock.patch.object(hq, "_request", lambda *a, **k: []):
            self.assertIn("No active agent", C._assign("nobody", "x"))


class DecisionFake(Fake):
    def __init__(self, already=False):
        super().__init__(); self.already = already
    def __call__(self, method, path, body=None, timeout=30, prefer=None):
        self.calls.append((method, path, body))
        if method == "PATCH" and "owner_messages" in path:
            return [] if self.already else [{"id": "m1", "body": "Sign the pilot?", "ref_table": "escalations", "ref_id": "e1"}]
        return []


class D(unittest.TestCase):
    def test_approve_closes_escalation_and_saves_decision(self):
        f = DecisionFake()
        with mock.patch.object(hq, "_request", f):
            out = C.apply_decision("m1", True)
        self.assertIn("APPROVED", out)
        self.assertTrue(any(c[0] == "PATCH" and "escalations?id=eq.e1" in c[1] and c[2]["status"] == "closed" for c in f.calls))
        mem = [c[2] for c in f.calls if c[0] == "POST" and "memory" in c[1]][0]
        self.assertEqual((mem["kind"], mem["agent"]), ("decision", "owner"))
        self.assertIn("approved", mem["content"])

    def test_second_tap_changes_nothing(self):
        f = DecisionFake(already=True)
        with mock.patch.object(hq, "_request", f):
            self.assertEqual(C.apply_decision("m1", False), "Already decided.")
        self.assertFalse(any(c[0] == "POST" for c in f.calls))


if __name__ == "__main__":
    unittest.main()
