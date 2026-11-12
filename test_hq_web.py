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
