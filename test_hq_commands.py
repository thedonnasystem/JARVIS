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

    def test_search_includes_chat_history_and_survives_missing_table(self):
        def req(method, path, body=None, timeout=30, prefer=None):
            if path.startswith("web_messages") or "/web_messages" in path or "web_messages?" in path:
                return [{"role": "owner", "body": "We decided to target HVAC first", "created_at": "2026-11-10T12:00:00Z"}]
            return []
        with mock.patch.object(hq, "_request", req):
            self.assertIn("target HVAC first", C._search_knowledge("HVAC"))

        def boom(method, path, body=None, timeout=30, prefer=None):
            if "web_messages" in path: raise RuntimeError("404")
            return []
        with mock.patch.object(hq, "_request", boom):
            self.assertIn("Nothing in HQ memory", C._search_knowledge("HVAC"))

    def test_finances_tool_combines_parts_and_fails_soft(self):
        with mock.patch.object(C.hq_capital, "status_text", return_value="fund $250"), \
             mock.patch.object(C.hq_bank, "status_text", side_effect=RuntimeError("no table")), \
             mock.patch.object(C.hq_capital, "pnl_text", return_value="net $0"):
            out = asyncio.run(C.handle_chat_tool("hq_finances", {}))
        self.assertIn("fund $250", out); self.assertIn("Bank: not available yet.", out); self.assertIn("net $0", out)
        self.assertIn("hq_finances", [t["name"] for t in C.HQ_CHAT_TOOLS])

    def test_assign_rejects_unknown_agent(self):
        with mock.patch.object(hq, "_request", lambda *a, **k: []):
            self.assertIn("No active agent", C._assign("nobody", "x"))


class Score(unittest.TestCase):
    def setUp(self):
        os.environ["JARVIS_OWNER_ID"] = "42"

    def test_day_upserts_today(self):
        f, u = Fake(), upd()
        with mock.patch.object(hq, "_request", f):
            asyncio.run(C.hq_day(u, SimpleNamespace(args=["280", "6", "2"])))
        post = [c for c in f.calls if c[0] == "POST" and "dayjob_days" in c[1]][0]
        self.assertIn("on_conflict=day", post[1])
        self.assertEqual((post[2]["dials"], post[2]["pitches"], post[2]["submissions"]), (280, 6, 2))
        self.assertIn("dials 280/250", u.message.sent[0])

    def test_day_rejects_bad_input(self):
        f, u = Fake(), upd()
        with mock.patch.object(hq, "_request", f):
            asyncio.run(C.hq_day(u, SimpleNamespace(args=["lots"])))
        self.assertFalse([c for c in f.calls if c[0] == "POST"])

    def test_paid_logs_revenue(self):
        f, u = Fake(), upd()
        with mock.patch.object(hq, "_request", f):
            asyncio.run(C.hq_paid(u, SimpleNamespace(args=["Smith"])))
        led = [c[2] for c in f.calls if c[0] == "POST" and "ledger" in c[1]][0]
        self.assertEqual((led["kind"], led["amount_cents"]), ("revenue", 100000))


class Answers(unittest.TestCase):
    def test_answer_saves_decision_and_resumes_task(self):
        calls = []
        def fake(method, path, body=None, timeout=30, prefer=None):
            calls.append((method, path, body))
            if method == "GET" and "owner_messages" in path:
                return [{"id": "m1", "body": "Question from x (task: y):\nWhich niche?", "options": ["HVAC", "Plumbing"],
                         "answer": None, "ref_table": "tasks", "ref_id": "t9"}]
            if method == "PATCH" and "owner_messages" in path:
                return [{"id": "m1"}]
            if method == "GET" and "tasks" in path:
                return [{"id": "t9", "detail": "do it", "venture_id": "vd"}]
            return []
        with mock.patch.object(hq, "_request", fake):
            out = C.apply_answer("m1", 1)
        self.assertIn("Plumbing", out)
        task = [c[2] for c in calls if c[0] == "PATCH" and "tasks?id=eq.t9" in c[1]][0]
        self.assertEqual(task["status"], "todo"); self.assertIn("Plumbing", task["detail"])
        mem = [c[2] for c in calls if c[0] == "POST" and "memory" in c[1]][0]
        self.assertEqual((mem["kind"], mem["venture_id"]), ("decision", "vd"))

    def test_second_answer_ignored(self):
        def fake(method, path, body=None, timeout=30, prefer=None):
            if method == "GET": return [{"id": "m1", "options": ["a", "b"], "answer": "a"}]
            return []
        with mock.patch.object(hq, "_request", fake):
            self.assertIn("Already answered", C.apply_answer("m1", 1))


class Night(unittest.TestCase):
    def setUp(self):
        os.environ["JARVIS_OWNER_ID"] = "42"

    def _fake(self, state):
        calls = []
        def fake(method, path, body=None, timeout=30, prefer=None):
            calls.append((method, path, body))
            if method == "GET" and "system_state" in path:
                return [state]
            if method == "POST" and "/rpc/queue_prospect_task" in path:
                return "some-id"
            return None
        return fake, calls

    def test_start_sets_leash_until_7am_and_queues_backlog(self):
        fake, calls = self._fake({"daily_spend_cap_cents": 330, "night_until": None, "pause_reason": None})
        u = upd()
        with mock.patch.object(hq, "_request", fake):
            asyncio.run(C.hq_nightshift(u, SimpleNamespace(args=["8"])))
        st = [c[2] for c in calls if c[0] == "PATCH" and "system_state" in c[1]][0]
        self.assertEqual((st["daily_spend_cap_cents"], st["day_cap_cents"]), (800, 330))
        self.assertTrue(st["night_until"])
        self.assertIn("Donna prospecting", u.message.sent[0])

    def test_ceiling_and_credit_guard(self):
        fake, calls = self._fake({"daily_spend_cap_cents": 330, "night_until": None, "pause_reason": None})
        with mock.patch.object(hq, "_request", fake):
            asyncio.run(C.hq_nightshift(upd(), SimpleNamespace(args=["500"])))
        self.assertEqual([c[2] for c in calls if c[0] == "PATCH"][0]["daily_spend_cap_cents"], C.NIGHT_MAX_CENTS)
        fake2, calls2 = self._fake({"daily_spend_cap_cents": 330, "night_until": None, "pause_reason": "api_credits"})
        u = upd()
        with mock.patch.object(hq, "_request", fake2):
            asyncio.run(C.hq_nightshift(u, SimpleNamespace(args=["8"])))
        self.assertFalse([c for c in calls2 if c[0] == "PATCH"])
        self.assertIn("out of credit", u.message.sent[0])


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

    def test_approved_draft_returns_ready_to_send_email(self):
        class F(DecisionFake):
            def __call__(s, method, path, body=None, timeout=30, prefer=None):
                s.calls.append((method, path, body))
                if method == "PATCH" and "owner_messages" in path:
                    return [{"id": "m2", "body": "draft", "ref_table": "outbox", "ref_id": "abcdef12-0000"}]
                if method == "GET" and "outbox" in path:
                    return [{"to_ref": "info@coolair.example.ca", "body": "Subject: Hi\n\nHello", "lead_id": "L7"}]
                return []
        f = F()
        with mock.patch.object(hq, "_request", f):
            out = C.apply_decision("m2", True)
        self.assertIn("To: info@coolair.example.ca", out)
        self.assertIn("/sent abcdef12", out)
        self.assertFalse(any(c[0] == "POST" and "memory" in c[1] for c in f.calls))  # single emails are not policy

    def test_cap_proposal_applies_with_ceiling(self):
        class F(DecisionFake):
            def __init__(s, ref): super().__init__(); s.ref = ref
            def __call__(s, method, path, body=None, timeout=30, prefer=None):
                s.calls.append((method, path, body))
                if method == "PATCH" and "owner_messages" in path:
                    return [{"id": "m3", "body": "raise cap", "ref_table": s.ref, "ref_id": None}]
                return []
        ok = F("set_cap:500")
        with mock.patch.object(hq, "_request", ok):
            C.apply_decision("m3", True)
        self.assertTrue(any("system_state" in c[1] and c[2] == {"daily_spend_cap_cents": 500} for c in ok.calls))
        crazy = F("set_cap:999999")
        with mock.patch.object(hq, "_request", crazy):
            C.apply_decision("m3", True)
        self.assertFalse(any("system_state" in c[1] for c in crazy.calls))

    def test_casl_footer_flags_missing_address(self):
        with mock.patch.object(hq, "_request", lambda *a, **k: [{"sender_name": "Moe", "brand": "The Donna System", "mailing_address": None}]):
            f = C.casl_footer()
        self.assertIn("ADD YOUR BUSINESS MAILING ADDRESS", f)
        self.assertIn("unsubscribe", f)
        with mock.patch.object(hq, "_request", lambda *a, **k: [{"sender_name": "Moe", "brand": "The Donna System", "mailing_address": "1 Main St, Ottawa ON"}]):
            self.assertIn("1 Main St, Ottawa ON", C.casl_footer())

    def test_second_tap_changes_nothing(self):
        f = DecisionFake(already=True)
        with mock.patch.object(hq, "_request", f):
            self.assertEqual(C.apply_decision("m1", False), "Already decided.")
        self.assertFalse(any(c[0] == "POST" for c in f.calls))


if __name__ == "__main__":
    unittest.main()
