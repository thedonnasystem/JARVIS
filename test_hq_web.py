import asyncio, io, unittest, urllib.error
from unittest import mock
import hq, hq_web as W, hq_commands, hq_missions


class DB:
    def __init__(self, rows=None, missing=False):
        self.rows = rows or []; self.calls = []; self.missing = missing

    def __call__(self, method, path, body=None, timeout=30, prefer=None):
        self.calls.append((method, path, body))
        if self.missing:
            raise urllib.error.HTTPError("u", 404, "nf", {}, io.BytesIO(b"{}"))
        if method == "GET" and path.startswith("/rest/v1/web_messages"):
            return list(self.rows)
        if method == "PATCH" and "status=eq.new" in path:
            return [{"id": 1}]
        return None

    def said(self):
        return [b for m, p, b in self.calls if m == "POST" and p == "/rest/v1/web_messages"]

    def closed(self):
        return [b["status"] for m, p, b in self.calls if m == "PATCH" and "status=eq.new" not in p]


def run(db, reply=None):
    async def fake_reply(chat_id, text, context, typing=True):
        if isinstance(reply, Exception):
            raise reply
        return f"echo:{text}:{chat_id}:{typing}"
    W.configure(fake_reply)
    with mock.patch.object(hq, "_request", db), mock.patch.object(hq, "hq_enabled", return_value=True), \
         mock.patch.dict("os.environ", {"JARVIS_OWNER_ID": "42"}):
        asyncio.run(W.poll(None))


class T(unittest.TestCase):
    def test_chat_goes_to_jarvis_and_reply_is_posted(self):
        db = DB([{"id": "m1", "kind": "chat", "body": "what happened overnight?", "payload": {}}])
        run(db)
        s = db.said()[0]
        self.assertEqual((s["role"], s["reply_to"], s["status"]), ("jarvis", "m1", "done"))
        self.assertEqual(s["body"], "echo:what happened overnight?:42:False")  # owner's shared history, no Telegram typing
        self.assertEqual(db.closed(), ["done"])

    def test_decision_answer_mission_routes(self):
        db = DB([{"id": "d1", "kind": "decision", "body": "", "payload": {"msg_id": "om1", "approved": True}},
                 {"id": "a1", "kind": "answer", "body": "", "payload": {"msg_id": "om2", "idx": 1}},
                 {"id": "x1", "kind": "mission", "body": "", "payload": {"verb": "pause", "id": "abcd1234"}}])
        with mock.patch.object(hq_commands, "apply_decision", return_value="Decision saved") as d, \
             mock.patch.object(hq_commands, "apply_answer", return_value="Answer saved") as a, \
             mock.patch.object(hq_missions, "set_status", return_value="paused.") as m:
            run(db)
        d.assert_called_once_with("om1", True); a.assert_called_once_with("om2", 1); m.assert_called_once_with("abcd1234", "pause")
        self.assertEqual([s["body"] for s in db.said()], ["Decision saved", "Answer saved", "paused."])

    def test_failure_tells_owner_and_marks_failed(self):
        db = DB([{"id": "m1", "kind": "chat", "body": "hi", "payload": {}}])
        run(db, reply=RuntimeError("boom"))
        self.assertIn("didn't go through", db.said()[0]["body"]); self.assertEqual(db.closed(), ["failed"])

    def test_inert_before_migration(self):
        db = DB(missing=True)
        run(db)
        self.assertEqual(db.said(), [])


class BankVenture(unittest.TestCase):
    def test_bank_and_venture_actions_route_to_owner_functions(self):
        import hq_web as W
        with mock.patch.object(W.hq_bank, "set_balance", return_value="ok") as sb, \
                mock.patch.object(W.hq_bank, "import_rows", return_value="imp") as ir, \
                mock.patch.object(W.hq_bank, "reconcile", return_value="rec"), \
                mock.patch.object(W.hq_ventures, "start", return_value={"slug": "x-y", "mission": "m"}) as st, \
                mock.patch.object(W.hq_ventures, "activate", return_value="on") as ac:
            self.assertEqual(W._bank({"verb": "balance", "amount": "412.50"}), "ok")
            self.assertEqual(sb.call_args.kwargs["by"], "owner:app")
            rows = [{"date": "2026-11-03", "description": "a  b", "cents": 5}, {"date": "junk", "cents": 1}, {"date": "2026-11-04", "cents": "x"}]
            W._bank({"verb": "rows", "rows": rows})
            self.assertEqual(ir.call_args[0][0], [{"date": "2026-11-03", "description": "a b", "cents": 5}])  # junk rows never reach the database
            self.assertEqual(W._bank({"verb": "reconcile"}), "rec")
            self.assertEqual(W._bank({"verb": "wire money"}), "Unknown bank action.")
            self.assertIn("x-y", W._venture({"verb": "new", "name": "X Y", "idea": "a long enough idea text"}))
            self.assertEqual(W._venture({"verb": "activate", "slug": "X-Y"}), "on")
            self.assertEqual(ac.call_args.kwargs["by"], "owner:app")
            self.assertEqual(W._venture({"verb": "delete"}), "Unknown venture action.")


class Day(unittest.TestCase):
    def test_day_actions_validate_and_route(self):
        import hq_web as W
        with mock.patch.object(W.hq_commands, "log_day", return_value="ok") as ld, mock.patch.object(W.hq_commands, "log_paid", return_value="paid") as lp:
            self.assertEqual(W._day({"verb": "log", "dials": "280", "pitches": 6, "submissions": "2"}), "ok")
            self.assertEqual(ld.call_args[0], (280, 6, 2))
            W._day({"verb": "log", "dials": "999999", "pitches": "-4", "submissions": ""})
            self.assertEqual(ld.call_args[0], (5000, 0, 0))  # clamped, never trusted
            self.assertIn("numbers", W._day({"verb": "log", "dials": "abc"}))
            self.assertEqual(W._day({"verb": "paid", "who": "Acme"}), "paid")
            self.assertEqual(W._day({"verb": "wipe"}), "Unknown day-job action.")


class Draft(unittest.TestCase):
    def test_draft_actions_route(self):
        import hq_web as W
        with mock.patch.object(W.hq_commands, "draft_decision", return_value="ready") as dd, mock.patch.object(W.hq_commands, "mark_sent", return_value="sent") as ms:
            self.assertEqual(W._draft({"verb": "approve", "id": "o1"}), "ready")
            self.assertEqual(dd.call_args[0], ("o1", True))
            W._draft({"verb": "reject", "id": "o1"}); self.assertEqual(dd.call_args[0], ("o1", False))
            self.assertEqual(W._draft({"verb": "sent", "id": "o1"}), "sent")
            self.assertEqual(W._draft({"verb": "send now"}), "Unknown draft action.")

    def test_draft_decision_creates_card_then_applies_owner_decision(self):
        calls = []

        def req(method, path, body=None, timeout=30, prefer=None):
            calls.append((method, path, body))
            if method == "GET" and "owner_messages" in path:
                return []
            if method == "GET" and "outbox" in path:
                return [{"id": "o1", "body": "Hi", "to_ref": "a@b.co", "agent": "donna-writer"}]
            if method == "POST" and path.endswith("owner_messages"):
                return [{"id": "m9"}]
        with mock.patch.object(hq, "_request", req), mock.patch.object(hq_commands, "apply_decision", return_value="Approved.") as ad:
            self.assertEqual(hq_commands.draft_decision("o1", True), "Approved.")
        self.assertEqual(ad.call_args[0], ("m9", True))
        with mock.patch.object(hq, "_request", lambda *a, **k: []):
            self.assertIn("not waiting", hq_commands.draft_decision("zz", True))


class Idea(unittest.TestCase):
    def test_idea_actions(self):
        import hq_web as W
        with mock.patch.object(hq_commands, "set_idea_status_by_id", return_value="ok") as si:
            W._idea({"verb": "test", "id": "i1"}); self.assertEqual(si.call_args[0], ("i1", "testing"))
            W._idea({"verb": "park", "id": "i1"}); self.assertEqual(si.call_args[0], ("i1", "parked"))
            W._idea({"verb": "scale", "id": "i1"}); self.assertEqual(si.call_args[0], ("i1", ""))
        self.assertEqual(hq_commands.set_idea_status_by_id("i1", ""), "Unknown idea action.")


class Lead(unittest.TestCase):
    def test_lead_actions_validate_and_log(self):
        import hq_web as W
        with mock.patch.object(hq_commands, "log_contact", return_value="ok") as lc:
            self.assertEqual(W._lead({"sid": "12", "days": 3, "outcome": "called"}), "ok")
            self.assertEqual(lc.call_args[0], (12, 3, "called"))
            W._lead({"sid": 7, "days": 0}); self.assertEqual(lc.call_args[0][:2], (7, 0))
            W._lead({"sid": 7, "days": 9999}); self.assertEqual(lc.call_args[0][1], 60)
            self.assertEqual(W._lead({"sid": "x"}), "Bad lead action.")

    def test_log_contact_closes_or_schedules(self):
        calls = []

        def req(method, path, body=None, timeout=30, prefer=None):
            calls.append((method, path, body))
            if method == "GET":
                return [{"id": "L1", "name": "Sam", "notes": "", "contact_count": 1}]
        with mock.patch.object(hq, "_request", req):
            self.assertIn("closed", hq_commands.log_contact(5, 0, "signed"))
            self.assertEqual([b for m, p, b in calls if m == "PATCH"][-1]["status"], "closed")
            self.assertIn("Next follow-up", hq_commands.log_contact(5, 3, "vm"))
