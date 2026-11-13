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
                    return [{"to_ref": "info@coolair.example.ca", "body": "Subject: Hi\n\nHello", "lead_id": "L7", "venture_id": "v-d"}]
                if method == "GET" and path.startswith("/rest/v1/leads"): return [{"venture_id": "v-d"}]
                if method == "GET" and path.startswith("/rest/v1/ventures?id="): return [{"slug": "donna"}]
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


class BackupCmd(unittest.TestCase):
    def setUp(self):
        os.environ["JARVIS_OWNER_ID"] = "42"

    def test_non_owner_ignored(self):
        import hq_backup
        u = upd("999")
        with mock.patch.object(hq_backup, "run") as run:
            asyncio.run(C.hq_backup_cmd(u, SimpleNamespace(args=["now"])))
        run.assert_not_called()
        self.assertFalse(u.message.sent)

    def test_status_shows_last_without_secrets(self):
        import hq_backup
        u = upd()
        last = {"at": "2026-11-13T07:05:00+00:00", "file": "hq-x.tar.gz.enc", "bytes": 10, "rows": 5, "tables": 3, "complete": True, "sha256": "ab" * 32}
        with mock.patch.dict(os.environ, {"BACKUP_KEY": "SECRETKEY", "BACKUP_PUT_URL": "b2://b/hq", "BACKUP_AUTH": "id:SECRETAPP"}), \
             mock.patch.object(hq_backup, "last_ok", return_value=last):
            asyncio.run(C.hq_backup_cmd(u, SimpleNamespace(args=[])))
        out = u.message.sent[0]
        self.assertIn("hq-x.tar.gz.enc", out)
        self.assertNotIn("SECRET", out)

    def test_check_reports_without_secrets(self):
        import hq_backup
        u = upd()
        res = [{"check": "BACKUP_KEY is set", "status": "pass", "detail": ""}, {"check": "Key can write files", "status": "fail", "detail": "key needs writeFiles"}]
        with mock.patch.object(hq_backup, "preflight", return_value=res):
            asyncio.run(C.hq_backup_cmd(u, SimpleNamespace(args=["check"])))
        out = u.message.sent[0]
        self.assertIn("FAIL Key can write files", out); self.assertIn("1 problem", out)

    def test_now_runs_forced(self):
        import hq_backup
        u = upd()
        with mock.patch.dict(os.environ, {"BACKUP_KEY": "k", "BACKUP_PUT_URL": "b2://b/hq"}), \
             mock.patch.object(hq_backup, "run", return_value={"ok": True}) as run:
            asyncio.run(C.hq_backup_cmd(u, SimpleNamespace(args=["now"])))
        run.assert_called_once_with(True)

    def test_now_unconfigured_does_not_run(self):
        import hq_backup
        u = upd()
        with mock.patch.dict(os.environ, {}, clear=False), mock.patch.object(hq_backup, "configured", return_value=False), \
             mock.patch.object(hq_backup, "run") as run:
            asyncio.run(C.hq_backup_cmd(u, SimpleNamespace(args=["now"])))
        run.assert_not_called()
        self.assertIn("not configured", u.message.sent[0])


class World:
    """Tiny in-memory PostgREST stand-in for the venture-resolution and CASL tests."""
    def __init__(self, profiles=None, outbox=None):
        self.ventures = [{"id": "v-donna", "slug": "donna", "name": "Donna", "manager_agent": "donna-manager"},
                         {"id": "v-dj", "slug": "day-job-sales", "name": "Day Job Sales", "manager_agent": None},
                         {"id": "v-cl", "slug": "ottawa-cleanouts", "name": "Ottawa Cleanouts Co", "manager_agent": "ottawa-cleanouts-manager"}]
        self.profiles = profiles if profiles is not None else {}
        self.outbox = outbox or {}
        self.calls = []

    def __call__(self, method, path, body=None, timeout=30, prefer=None):
        import urllib.parse as up
        self.calls.append((method, path, body))
        if path.startswith("/rest/v1/rpc/venture_config_get"):  # venture2: offer + CTA on file (ready by default so the CASL tests stay about CASL)
            return {"venture": (body or {}).get("p_venture"), "drafts_ready": True}
        if path.startswith("/rest/v1/ventures"):
            q = up.parse_qs(path.split("?", 1)[1]) if "?" in path else {}
            rows = self.ventures
            if "slug" in q: rows = [v for v in rows if "eq." + v["slug"] == q["slug"][0]]
            if "id" in q: rows = [v for v in rows if "eq." + v["id"] == q["id"][0]]
            return rows
        if path.startswith("/rest/v1/company_profile") and method == "GET":
            slug = up.parse_qs(path.split("?", 1)[1])["venture_slug"][0][3:]
            return [self.profiles[slug]] if slug in self.profiles else []
        if path.startswith("/rest/v1/company_profile") and method == "POST":
            row = self.profiles.setdefault(body["venture_slug"], {})
            row.update({k: v for k, v in body.items() if k != "venture_slug"})
            return []
        if path.startswith("/rest/v1/owner_messages") and method == "PATCH":
            return [{"id": "m9", "body": "draft", "ref_table": "outbox", "ref_id": "ob123456-0"}] if body and body.get("decision") == "approved" else []
        if path.startswith("/rest/v1/outbox?id=eq.ob123456-0&select"):
            return [self.outbox] if self.outbox else []
        if path.startswith("/rest/v1/leads?id="):
            return [{"venture_id": self.outbox.get("lead_venture")}] if self.outbox.get("lead_venture") else []
        if path.startswith("/rest/v1/agents"):
            return [{"slug": "ottawa-cleanouts-manager", "venture_id": "v-cl", "status": "paused"}] if "slug=eq.ottawa-cleanouts-manager" in path else []
        return []


FULL = {"sender_name": "Moe", "brand": "Ottawa Cleanouts Co", "mailing_address": "9 Elm St, Ottawa ON K1A 0A9"}


class Resolve(unittest.TestCase):
    def setUp(self):
        os.environ["JARVIS_OWNER_ID"] = "42"

    def test_old_aliases_resolve_identically(self):
        with mock.patch.object(hq, "_request", World()):
            self.assertEqual(C._venture_id("donna"), ("v-donna", "donna"))
            self.assertEqual(C._venture_id("hvac"), ("v-donna", "donna"))

    def test_real_slug_name_and_at_prefix(self):
        with mock.patch.object(hq, "_request", World()):
            self.assertEqual(C.resolve_venture("ottawa-cleanouts"), ("v-cl", "ottawa-cleanouts", None))
            self.assertEqual(C.resolve_venture("@Ottawa-Cleanouts")[1], "ottawa-cleanouts")
            self.assertEqual(C.resolve_venture("Ottawa_Cleanouts_Co")[1], "ottawa-cleanouts")  # by name
            self.assertEqual(C.resolve_venture(None), (None, None, None))

    def test_unknown_is_an_error_not_company_wide(self):
        with mock.patch.object(hq, "_request", World()):
            vid, slug, err = C.resolve_venture("nonexistent")
        self.assertEqual((vid, slug), (None, None)); self.assertIn("No venture called 'nonexistent'", err)

    def test_money_new_venture_logs_to_it(self):
        w, u = World(), upd()
        with mock.patch.object(hq, "_request", w):
            asyncio.run(C.hq_money(u, SimpleNamespace(args=["in", "200", "ottawa-cleanouts", "first", "job"])))
        post = [c for c in w.calls if c[0] == "POST" and "ledger" in c[1]][0][2]
        self.assertEqual((post["venture_id"], post["note"]), ("v-cl", "first job"))
        self.assertIn("ottawa-cleanouts", u.message.sent[0])

    def test_money_unknown_venture_refused_and_nothing_logged(self):
        w, u = World(), upd()
        with mock.patch.object(hq, "_request", w):
            asyncio.run(C.hq_money(u, SimpleNamespace(args=["in", "200", "ottawa-cleanoutz", "first", "job"])))
        self.assertFalse([c for c in w.calls if c[0] == "POST"])
        self.assertIn("No venture called", u.message.sent[0])

    def test_money_company_word_and_no_venture_stay_company_wide(self):
        for args, note in ((["out", "29", "company", "twilio"], "twilio"), (["out", "29"], None)):
            w, u = World(), upd()
            with mock.patch.object(hq, "_request", w):
                asyncio.run(C.hq_money(u, SimpleNamespace(args=args)))
            post = [c for c in w.calls if c[0] == "POST" and "ledger" in c[1]][0][2]
            self.assertEqual((post["venture_id"], post["note"]), (None, note))

    def test_ask_routes_venture_name_to_its_manager_and_rejects_unknown(self):
        w, u = World(), upd()
        with mock.patch.object(hq, "_request", w):
            asyncio.run(C.hq_ask(u, SimpleNamespace(args=["ottawa-cleanouts", "plan", "week", "one"])))
        task = [c for c in w.calls if c[0] == "POST" and "tasks" in c[1]][0][2]
        self.assertEqual(task["assigned_agent"], "ottawa-cleanouts-manager")

        class NoAgents(World):
            def __call__(s, method, path, body=None, timeout=30, prefer=None):
                if path.startswith("/rest/v1/agents"): s.calls.append((method, path, body)); return []
                return super().__call__(method, path, body, timeout, prefer)
        w2, u2 = NoAgents(), upd()
        with mock.patch.object(hq, "_request", w2):
            asyncio.run(C.hq_ask(u2, SimpleNamespace(args=["nothingness", "do", "x"])))
        self.assertFalse([c for c in w2.calls if c[0] == "POST"]); self.assertIn("No agent or venture", u2.message.sent[0])

    def test_mission_new_at_venture_and_unknown(self):
        u = upd()
        with mock.patch.object(hq, "_request", World()), mock.patch.object(C.hq_missions, "create_mission", return_value={"id": "m-1234567", "title": "T"}) as cm:
            asyncio.run(C.hq_mission_cmd(u, SimpleNamespace(args=["new", "@ottawa-cleanouts", "find", "customers"])))
            self.assertEqual((cm.call_args[0][0], cm.call_args[0][1]), ("find customers", "ottawa-cleanouts"))
            u2 = upd()
            cm.reset_mock()
            asyncio.run(C.hq_mission_cmd(u2, SimpleNamespace(args=["new", "@nope", "find", "customers"])))
            cm.assert_not_called(); self.assertIn("No venture called", u2.message.sent[0])
            cm.reset_mock()
            asyncio.run(C.hq_mission_cmd(upd(), SimpleNamespace(args=["new", "plain", "objective"])))
            self.assertEqual(cm.call_args[0], ("plain objective",))  # old behaviour unchanged


class Casl(unittest.TestCase):
    def setUp(self):
        os.environ["JARVIS_OWNER_ID"] = "42"

    def test_donna_footer_unchanged_and_other_ventures_fail_closed(self):
        with mock.patch.object(hq, "_request", World(profiles={"donna": {"mailing_address": "1 Main St, Ottawa ON"}})):
            f = C.casl_footer()
            self.assertIn("Moe, The Donna System", f); self.assertIn("1 Main St, Ottawa ON", f)
            with self.assertRaises(C.hq_mail.ProfileMissing): C.casl_footer("ottawa-cleanouts")
        with mock.patch.object(hq, "_request", World(profiles={"ottawa-cleanouts": {"mailing_address": "9 Elm St, Ottawa ON"}})):  # no brand/sender
            with self.assertRaises(C.hq_mail.ProfileMissing): C.casl_footer("ottawa-cleanouts")
        with mock.patch.object(hq, "_request", World(profiles={"ottawa-cleanouts": FULL, "donna": {"mailing_address": "1 Main St, Ottawa ON"}})):
            f = C.casl_footer("ottawa-cleanouts")
            self.assertIn("Ottawa Cleanouts Co", f); self.assertIn("9 Elm St", f); self.assertNotIn("Donna", f); self.assertIn("unsubscribe", f)

    def test_setaddress_default_is_donna_and_venture_form_writes_only_that_row(self):
        w, u = World(), upd()
        with mock.patch.object(hq, "_request", w):
            asyncio.run(C.hq_setaddress(u, SimpleNamespace(args="123 Example St, Ottawa ON K1A 0A1".split())))
        self.assertEqual(list(w.profiles), ["donna"])
        w, u = World(), upd()
        with mock.patch.object(hq, "_request", w):
            asyncio.run(C.hq_setaddress(u, SimpleNamespace(args="ottawa-cleanouts 9 Elm St, Ottawa ON K1A 0A9".split())))
        self.assertEqual(list(w.profiles), ["ottawa-cleanouts"]); self.assertEqual(w.profiles["ottawa-cleanouts"]["mailing_address"], "9 Elm St, Ottawa ON K1A 0A9")
        self.assertIn("Not ready yet", u.message.sent[0])  # brand and sender still missing

    def test_setaddress_unknown_venture_writes_nothing(self):
        w, u = World(), upd()
        with mock.patch.object(hq, "_request", w):
            asyncio.run(C.hq_setaddress(u, SimpleNamespace(args="ottawa-cleanoutz 9 Elm St, Ottawa ON K1A 0A9".split())))
        self.assertEqual(w.profiles, {}); self.assertFalse([c for c in w.calls if c[0] == "POST"]); self.assertIn("No venture called", u.message.sent[0])

    def test_profile_command_completes_the_profile(self):
        w = World(profiles={"ottawa-cleanouts": {"mailing_address": "9 Elm St, Ottawa ON K1A 0A9"}})
        with mock.patch.object(hq, "_request", w):
            asyncio.run(C.hq_venture_cmd(upd(), SimpleNamespace(args=["profile", "ottawa-cleanouts", "brand", "Ottawa", "Cleanouts", "Co"])))
            self.assertIsNone(C.hq_mail.profile("ottawa-cleanouts"))  # sender still missing
            u = upd()
            asyncio.run(C.hq_venture_cmd(u, SimpleNamespace(args=["profile", "ottawa-cleanouts", "sender", "Moe"])))
            self.assertIn("can now carry", u.message.sent[0]); self.assertIsNotNone(C.hq_mail.profile("ottawa-cleanouts"))
            self.assertEqual(w.profiles["ottawa-cleanouts"]["brand"], "Ottawa Cleanouts Co")

    def _approve(self, world):
        with mock.patch.object(hq, "_request", world):
            return C.apply_decision("m9", True)

    def test_approving_a_new_venture_draft_without_profile_is_refused_and_untouched(self):
        w = World(outbox={"to_ref": "a@b.co", "body": "Hi", "lead_id": "L1", "venture_id": "v-cl", "lead_venture": "v-cl"})
        out = self._approve(w)
        self.assertIn("Cannot approve yet", out); self.assertIn("/setaddress ottawa-cleanouts", out)
        self.assertFalse([c for c in w.calls if c[0] == "PATCH" and "/outbox?id=" in c[1]])        # draft status never changed
        self.assertFalse([c for c in w.calls if "approved_to_send" in str(c[2])])                   # lead not advanced
        release = [c for c in w.calls if "owner_messages" in c[1] and c[0] == "PATCH" and c[2] == {"decision": None, "decided_at": None}]
        self.assertEqual(len(release), 1)                                                          # the tap is released so it can be retried

    def test_approving_with_profile_uses_that_ventures_footer_from_the_lead(self):
        # the draft row says donna but its LEAD belongs to the new venture: the lead wins
        w = World(profiles={"ottawa-cleanouts": FULL}, outbox={"to_ref": "a@b.co", "body": "Hi", "lead_id": "L1", "venture_id": "v-donna", "lead_venture": "v-cl"})
        out = self._approve(w)
        self.assertIn("9 Elm St", out); self.assertIn("Ottawa Cleanouts Co", out); self.assertNotIn("Donna System", out)
        stamped = [c for c in w.calls if c[0] == "PATCH" and "/outbox?id=" in c[1] and isinstance(c[2], dict) and c[2].get("status") == "qa_passed"]
        self.assertEqual(stamped[0][2].get("venture_id"), "v-cl")  # the sender reads outbox.venture_id: it must equal the lead's venture

    def test_donna_draft_approval_keeps_legacy_address_warning(self):
        w = World(profiles={}, outbox={"to_ref": "a@b.co", "body": "Hi", "lead_id": "L1", "venture_id": "v-donna", "lead_venture": "v-donna"})
        out = self._approve(w)
        self.assertIn("ADD YOUR BUSINESS MAILING ADDRESS", out); self.assertIn("/setaddress", out)

    def test_draft_whose_venture_cannot_be_found_is_refused(self):
        w = World(profiles={"donna": {"mailing_address": "1 Main St"}}, outbox={"to_ref": "a@b.co", "body": "Hi", "lead_id": "L1", "venture_id": "v-ghost"})
        self.assertIn("cannot be found", self._approve(w))
        self.assertFalse([c for c in w.calls if c[0] == "PATCH" and "/outbox?id=" in c[1]])


class KpiCommand(unittest.TestCase):
    def setUp(self):
        os.environ["JARVIS_OWNER_ID"] = "42"

    def test_venture_kpis_and_agents_paths(self):
        k = {"venture": "ottawa-cleanouts", "leads": 5, "emailable_leads": 3, "drafted": 2, "approved": 1, "sent": 1, "won_deals": 1,
             "deals_by_stage": {"won": 1, "pitched": 2}, "revenue_cents": 25000}

        class W(World):
            def __call__(s, method, path, body=None, timeout=30, prefer=None):
                if path.endswith("/rpc/venture_kpis"): s.calls.append((method, path, body)); return k
                if path.endswith("/rpc/ensure_venture_agents"): s.calls.append((method, path, body)); return {"created": ["ottawa-cleanouts-researcher"], "existing": []}
                return super().__call__(method, path, body, timeout, prefer)
        w, u = W(), upd()
        with mock.patch.object(hq, "_request", w):
            asyncio.run(C.hq_venture_cmd(u, SimpleNamespace(args=["kpis", "ottawa-cleanouts"])))
            self.assertIn("Revenue received $250.00", u.message.sent[0]); self.assertIn("Leads 5 (3 emailable)", u.message.sent[0])
            u2 = upd()
            asyncio.run(C.hq_venture_cmd(u2, SimpleNamespace(args=["kpis", "nope"])))
            self.assertIn("No venture called", u2.message.sent[0])
            u3 = upd()
            asyncio.run(C.hq_venture_cmd(u3, SimpleNamespace(args=["agents", "ottawa-cleanouts"])))
            self.assertIn("Created paused", u3.message.sent[0])
        self.assertEqual([c[2] for c in w.calls if c[1].endswith("ensure_venture_agents")][0]["p_slug"], "ottawa-cleanouts")


if __name__ == "__main__":
    unittest.main()
