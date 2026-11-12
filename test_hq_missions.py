import unittest, urllib.parse, uuid, json
from unittest import mock
import hq, hq_missions as M

# Same rules as public.enforce_mission_transition() in migrations/20261112_missions_v1.sql
ALLOWED = {
    "captured": {"evaluated", "rejected", "abandoned", "paused", "failed"},
    "evaluated": {"planned", "rejected", "abandoned", "paused"},
    "planned": {"executing", "blocked", "paused", "abandoned", "failed"},
    "executing": {"verifying", "planned", "blocked", "paused", "abandoned", "failed"},
    "verifying": {"completed", "executing", "planned", "blocked", "failed"},
    "blocked": {"planned", "executing", "verifying", "paused", "abandoned", "failed"},
    "paused": {"captured", "evaluated", "planned", "executing", "abandoned"},
}


class IllegalTransition(Exception):
    pass


class FakeDB:
    def __init__(self, spent=0):
        self.missions, self.tasks, self.msgs, self.audit = {}, {}, [], []
        self.spent = spent
        self.ventures = [{"id": "v-idea", "slug": "idea-lab"}, {"id": "v-donna", "slug": "donna"}]
        self.agents = ["new-ventures-researcher", "new-ventures-auditor", "donna-researcher", "donna-auditor",
                       "compliance-qa", "growth", "jarvis"]

    @staticmethod
    def _filters(path):
        table, _, qs = path.partition("?")
        f = {}
        for part in qs.split("&"):
            if "=" in part:
                k, v = part.split("=", 1)
                f[k] = urllib.parse.unquote(v)
        return table, f

    def __call__(self, method, path, body=None, timeout=30, prefer=None):
        path = path.replace("/rest/v1/", "")
        if path.startswith("rpc/"):
            if path.endswith("mission_spent_cents"):
                return self.spent
            return None
        table, f = self._filters(path)
        if method == "GET":
            if table == "missions":
                rows = list(self.missions.values())
                if "status" in f and f["status"].startswith("in."):
                    allowed = f["status"][4:-1].split(",")
                    rows = [r for r in rows if r["status"] in allowed]
                return [dict(r) for r in rows]
            if table == "tasks":
                rows = list(self.tasks.values())
                if "mission_id" in f:
                    rows = [t for t in rows if t.get("mission_id") == f["mission_id"][3:]]
                return [dict(t) for t in rows]
            if table == "ventures":
                if "slug" in f:
                    return [v for v in self.ventures if v["slug"] == f["slug"][3:]]
                if "id" in f:
                    return [v for v in self.ventures if v["id"] == f["id"][3:]]
            if table == "agents":
                return [{"slug": a} for a in self.agents]
            return []
        if method == "POST":
            if table == "missions":
                m = {"id": str(uuid.uuid4()), "status": "captured", "plan": [], "checkpoint": {}, "attempts": 0,
                     "evidence": [], "priority": 2, "budget_cents": 200, "next_step": 0, "last_progress_at": "2099-01-01T00:00:00+00:00"}
                m.update(body); self.missions[m["id"]] = m
                return [dict(m)]
            if table == "tasks":
                t = {"id": str(uuid.uuid4()), "result": None}; t.update(body); self.tasks[t["id"]] = t
                return [dict(t)]
            if table == "owner_messages":
                self.msgs.append(body); return None
            if table == "audit_log":
                self.audit.append(body); return None
        if method == "PATCH":
            if table == "missions":
                m = self.missions[f["id"][3:]]
                new = body.get("status")
                if new and new != m["status"]:
                    if new not in ALLOWED.get(m["status"], set()):
                        raise IllegalTransition(f"{m['status']} -> {new}")
                    if new == "completed" and not (body.get("evidence") or m.get("evidence")):
                        raise IllegalTransition("completed without evidence")
                m.update(body); return None
            if table == "tasks":
                t = self.tasks[f["id"][3:]]
                if "status" in f and t["status"] != f["status"][3:]:
                    return None
                t.update(body); return None
        return None

    # helpers for tests
    def finish(self, title_prefix, result, status="done"):
        for t in self.tasks.values():
            if t["title"].startswith(M.TITLE_PREFIX + title_prefix) and t["status"] in ("todo", "doing"):
                t["status"], t["result"] = status, result
                return t
        raise AssertionError(f"no open task {title_prefix}")

    def open_tasks(self):
        return [t for t in self.tasks.values() if t["status"] in ("todo", "doing")]


EVAL_GO = """MISSION_VERDICT: GO — demand is real and startup cost is low
NUMBERS: startup cost CAD 400 | expected profit CAD 3000 | days to first cash 30 | confidence medium
SUCCESS: a priced service menu and 20 verified municipal/commercial prospects with sources
RISKS: seasonality; permits
STEP: new-ventures-researcher | Price the service | research competitor prices in Ottawa with sources
STEP: growth | Build prospect list | 20 commercial property managers in Ottawa with public contact pages
STEP: ghost-agent | Draft offer | write a one-page offer for property managers
"""
VERIFY_YES = """VERIFIED: YES
EVIDENCE: price menu backed by 3 competitor sites | https://example.com/a
EVIDENCE: 20 prospects with public sources | task record
"""
VERIFY_NO = """VERIFIED: NO
GAP: only 8 prospects have sources
"""


class T(unittest.TestCase):
    def tick(self, db, n=1):
        with mock.patch.object(hq, "_request", db):
            for _ in range(n):
                M.advance()

    def new(self, db, **kw):
        with mock.patch.object(hq, "_request", db):
            return M.create_mission(kw.pop("objective", "Start a graffiti-removal business in Ottawa"), **kw)

    def test_capture_and_evaluate_task(self):
        db = FakeDB(); r = self.new(db)
        self.assertTrue(r["id"])
        self.tick(db)
        t = db.open_tasks()
        self.assertEqual(len(t), 1)
        self.assertEqual(t[0]["assigned_agent"], "new-ventures-researcher")
        self.assertTrue(t[0]["title"].startswith("Mission: Evaluate"))
        self.assertEqual(t[0]["mission_id"], r["id"])
        self.assertIn("MISSION_VERDICT", t[0]["detail"])
        self.tick(db)  # no duplicate evaluation while it runs
        self.assertEqual(len(db.open_tasks()), 1)

    def test_full_lifecycle_go_to_completed(self):
        db = FakeDB(); r = self.new(db); mid = r["id"]
        self.tick(db); db.finish("Evaluate", EVAL_GO)
        self.tick(db)
        m = db.missions[mid]
        self.assertEqual(m["status"], "planned")
        self.assertEqual(m["verdict"], "GO")
        self.assertEqual(m["expected_cad"], 3000.0); self.assertEqual(m["days_to_cash"], 30)
        self.assertEqual([s["agent"] for s in m["plan"]], ["new-ventures-researcher", "growth", "new-ventures-researcher"])
        self.assertTrue(any("Verdict: GO" in x["body"] for x in db.msgs))
        # steps launch one per tick, max 3 open
        self.tick(db, 3)
        self.assertEqual(db.missions[mid]["status"], "executing")
        self.assertEqual(len([t for t in db.open_tasks() if "Evaluate" not in t["title"]]), 3)
        for t in list(db.open_tasks()):
            t["status"], t["result"] = "done", "result with https://example.com"
        self.tick(db)
        self.assertEqual(db.missions[mid]["status"], "verifying")
        ver = db.open_tasks()[0]
        self.assertTrue(ver["title"].startswith("Mission: Verify"))
        self.assertNotIn(ver["assigned_agent"], {s["agent"] for s in db.missions[mid]["plan"]})  # independent
        db.finish("Verify", VERIFY_YES)
        self.tick(db)
        self.assertEqual(db.missions[mid]["status"], "completed")
        self.assertEqual(len(db.missions[mid]["evidence"]), 2)
        self.assertTrue(any("Mission complete (verified)" in x["body"] for x in db.msgs))

    def test_reject_tells_owner_and_stops(self):
        db = FakeDB(); mid = self.new(db)["id"]
        self.tick(db); db.finish("Evaluate", "MISSION_VERDICT: REJECT — margins are too thin\nNUMBERS: expected profit CAD 200 | days 120")
        self.tick(db)
        self.assertEqual(db.missions[mid]["status"], "rejected")
        self.assertTrue(any("REJECT" in x["body"] and "margins" in x["body"] for x in db.msgs))
        self.assertEqual(db.open_tasks(), [])

    def test_failed_verification_replans_then_fails_after_three(self):
        db = FakeDB(); mid = self.new(db)["id"]
        self.tick(db); db.finish("Evaluate", EVAL_GO)
        for attempt in range(M.MAX_ATTEMPTS):
            self.tick(db, 4)
            for t in list(db.open_tasks()):
                if not t["title"].startswith("Mission: Verify"):
                    t["status"], t["result"] = "done", "work"
            self.tick(db)
            self.assertEqual(db.missions[mid]["status"], "verifying")
            db.finish("Verify", VERIFY_NO)
            self.tick(db)
            if attempt < M.MAX_ATTEMPTS - 1:
                self.assertEqual(db.missions[mid]["status"], "planned")
                rp = db.open_tasks()[0]
                self.assertIn("only 8 prospects", rp["detail"])  # gaps fed into the re-plan
                db.finish("Re-plan", EVAL_GO)
                self.tick(db)
        self.assertEqual(db.missions[mid]["status"], "failed")
        self.assertTrue(any("Mission failed" in x["body"] for x in db.msgs))

    def test_verifier_yes_without_evidence_is_not_completion(self):
        db = FakeDB(); mid = self.new(db)["id"]
        self.tick(db); db.finish("Evaluate", EVAL_GO); self.tick(db, 4)
        for t in list(db.open_tasks()):
            t["status"], t["result"] = "done", "work"
        self.tick(db); db.finish("Verify", "VERIFIED: YES\nLooks good to me.")
        self.tick(db)
        self.assertNotEqual(db.missions[mid]["status"], "completed")

    def test_blocked_step_blocks_mission_and_tells_owner_once(self):
        db = FakeDB(); mid = self.new(db)["id"]
        self.tick(db); db.finish("Evaluate", EVAL_GO); self.tick(db, 2)
        step = next(t for t in db.open_tasks())
        step["status"], step["result"] = "blocked", "error: something"
        self.tick(db, 3)
        self.assertEqual(db.missions[mid]["status"], "blocked")
        self.assertEqual(sum("Mission blocked" in x["body"] for x in db.msgs), 1)

    def test_waiting_on_owner_is_not_blocked(self):
        db = FakeDB(); mid = self.new(db)["id"]
        self.tick(db); db.finish("Evaluate", EVAL_GO); self.tick(db, 2)
        step = next(t for t in db.open_tasks())
        step["status"], step["result"] = "blocked", "waiting on owner: which city?"
        self.tick(db)
        self.assertEqual(db.missions[mid]["status"], "executing")
        self.assertFalse(any("Mission blocked" in x["body"] for x in db.msgs))

    def test_budget_pauses_and_cancels_queued_steps(self):
        db = FakeDB(); mid = self.new(db)["id"]
        self.tick(db); db.finish("Evaluate", EVAL_GO); self.tick(db, 3)
        db.spent = 250
        self.tick(db)
        self.assertEqual(db.missions[mid]["status"], "paused")
        self.assertEqual(db.open_tasks(), [])
        self.assertTrue(any("budget" in x["body"] for x in db.msgs))

    def test_resume_after_pause_relaunches_cancelled_steps(self):
        db = FakeDB(); mid = self.new(db)["id"]
        self.tick(db); db.finish("Evaluate", EVAL_GO); self.tick(db, 3)
        db.spent = 999; self.tick(db); db.spent = 0
        with mock.patch.object(hq, "_request", db):
            for t in db.tasks.values():  # what _sync_plan would have recorded
                pass
            m = db.missions[mid]
            for s in m["plan"]:
                if s["status"] == "todo":
                    s["status"] = "cancelled"
            out = M.set_status(mid[:8], "resume")
        self.assertIn("executing", out)
        self.tick(db)
        self.assertGreaterEqual(len(db.open_tasks()), 1)

    def test_real_estate_sourcing_steps_dropped(self):
        db = FakeDB(); db.ventures.append({"id": "v-re", "slug": "real-estate"})
        db.agents += ["real-estate-researcher", "real-estate-auditor"]
        mid = self.new(db, venture="real-estate")["id"]
        self.tick(db)
        db.finish("Evaluate", "MISSION_VERDICT: GO — fine\nSTEP: real-estate-researcher | Find houses | find distressed houses for sale in Ottawa\n"
                              "STEP: real-estate-researcher | Buyer criteria | list what cash buyers in Ottawa pay for")
        self.tick(db)
        self.assertEqual([s["title"] for s in db.missions[mid]["plan"]], ["Buyer criteria"])

    def test_live_mission_cap_and_input_checks(self):
        db = FakeDB()
        for i in range(M.MAX_LIVE_MISSIONS):
            self.assertIn("id", self.new(db, objective=f"Objective number {i} for testing"))
        self.assertIn("error", self.new(db, objective="One more objective that is too many"))
        self.assertIn("error", self.new(FakeDB(), objective="short"))
        r = self.new(FakeDB(), objective="Big budget objective here", budget_cents=99999)
        self.assertTrue(r["id"])

    def test_parse_helpers(self):
        ev = M.parse_evaluation(EVAL_GO)
        self.assertEqual(ev["verdict"], "GO"); self.assertEqual(len(ev["steps"]), 3)
        v = M.parse_verification(VERIFY_YES)
        self.assertTrue(v["verified"]); self.assertEqual(v["evidence"][0]["source"], "https://example.com/a")

    def test_missing_table_is_inert(self):
        import urllib.error, io
        def boom(*a, **k):
            raise urllib.error.HTTPError("u", 404, "nf", {}, io.BytesIO(b"{}"))
        with mock.patch.object(hq, "_request", boom):
            self.assertEqual(M.advance(), 0)


if __name__ == "__main__":
    unittest.main()


class FocusAndBudgetTests(unittest.TestCase):
    def test_budget_check_fails_closed_when_spend_unreadable(self):
        import hq_missions as M
        with mock.patch.object(M, "_rpc", side_effect=RuntimeError("down")):
            self.assertFalse(M._check_budget({"id": "m1", "status": "executing", "budget_cents": 200, "title": "t"}))

    def test_focus_command_sets_and_clears(self):
        import hq_missions as M
        calls = []
        with mock.patch.object(M, "_rpc", side_effect=lambda n, a: calls.append((n, a))), \
             mock.patch.object(M, "_get", return_value=[{"id": "abcd1234-0000", "title": "First test", "status": "captured"}]):
            self.assertIn("Focus mode ON", M.set_focus("abcd"))
            self.assertIn("off", M.set_focus("off").lower())
        self.assertEqual(calls[0], ("set_focus_mission", {"p_mission": "abcd1234-0000", "p_by": "owner:telegram"}))
        self.assertEqual(calls[1][1]["p_mission"], None)
