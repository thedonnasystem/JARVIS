import io, json, unittest, urllib.error
from unittest import mock
import hq, hq_policy as P, hq_commands as C


def http_err(code):
    return urllib.error.HTTPError("u", code, "x", {}, io.BytesIO(b"{}"))


class Rec:
    def __init__(self, reply=None, exc=None):
        self.calls = []; self.reply = reply; self.exc = exc

    def __call__(self, method, path, body=None, timeout=30, prefer=None):
        self.calls.append((method, path, body))
        if self.exc and "authorize_action" in path:
            raise self.exc
        if "authorize_action" in path:
            return self.reply
        if path.startswith("/rest/v1/approval_requests") and method == "POST":
            return [{"id": "req-1"}]
        if path.startswith("/rest/v1/action_policy") and method == "GET":
            return [{"action": "research", "tier": "green"}, {"action": "send_email", "tier": "yellow", "max_count_per_day": 20},
                    {"action": "take_loan", "tier": "red"}, {"action": "fabricate", "tier": "prohibited"}]
        return None


class T(unittest.TestCase):
    def test_database_decision_is_used(self):
        r = Rec(reply={"decision": "ask_owner", "reason": "Red", "tier": "red"})
        with mock.patch.object(hq, "_request", r):
            d = P.authorize("ceo", "take_loan", 10000, ref="L1")
        self.assertTrue(d.ask_owner); self.assertFalse(d.allowed); self.assertEqual(d.source, "database")
        body = r.calls[0][2]
        self.assertEqual((body["p_actor"], body["p_action"], body["p_cents"], body["p_ref"]), ("ceo", "take_loan", 10000, "L1"))

    def test_fails_closed_when_engine_missing(self):
        for exc in (http_err(404), http_err(500), TimeoutError()):
            with mock.patch.object(hq, "_request", Rec(exc=exc)):
                self.assertTrue(P.authorize("x", "research").allowed)          # green still works
                d = P.authorize("x", "send_email")
                self.assertFalse(d.allowed); self.assertEqual(d.decision, "deny")  # nothing else does
                self.assertFalse(P.authorize("x", "take_loan").allowed)
                self.assertFalse(P.authorize("x", "made_up").allowed)

    def test_garbage_reply_fails_closed(self):
        with mock.patch.object(hq, "_request", Rec(reply={"decision": "sure"})):
            self.assertFalse(P.authorize("x", "send_email").allowed)

    def test_negative_cents_clamped(self):
        r = Rec(reply={"decision": "allow", "reason": "", "tier": "yellow"})
        with mock.patch.object(hq, "_request", r):
            P.authorize("x", "routine_expense", -500)
        self.assertEqual(r.calls[0][2]["p_cents"], 0)

    def test_request_approval_puts_buttons_in_front_of_owner(self):
        r = Rec()
        with mock.patch.object(hq, "_request", r):
            rid = P.request_approval("ceo", "sign_contract", "Recommend signing: numbers, risks, alternatives", 50000, ref="C1")
        self.assertEqual(rid, "req-1")
        msg = [c for c in r.calls if c[1] == "/rest/v1/owner_messages"][0][2]
        self.assertTrue(msg["needs_decision"]); self.assertEqual(msg["ref_table"], "approval_requests")
        self.assertEqual(msg["ref_id"], "req-1"); self.assertIn("$500.00", msg["body"])

    def test_owner_tap_decides_the_request(self):
        r = Rec()
        def fake(method, path, body=None, timeout=30, prefer=None):
            r.calls.append((method, path, body))
            if path.startswith("/rest/v1/owner_messages?id=eq.") and method == "PATCH":
                return [{"id": "m1", "ref_table": "approval_requests", "ref_id": "req-1", "body": "Needs your decision"}]
            return None
        with mock.patch.object(hq, "_request", fake):
            C.apply_decision("m1", True)
        p = [c for c in r.calls if c[1].startswith("/rest/v1/approval_requests?id=eq.req-1")]
        self.assertEqual(p[0][2]["status"], "approved")
        self.assertIn("status=eq.pending", p[0][1])  # can't re-approve a used/rejected request

    def test_owner_approving_a_draft_passes_qa_first(self):
        r = Rec()
        def fake(method, path, body=None, timeout=30, prefer=None):
            r.calls.append((method, path, body))
            if path.startswith("/rest/v1/owner_messages?id=eq.") and method == "PATCH":
                return [{"id": "m1", "ref_table": "outbox", "ref_id": "ob1", "body": "draft"}]
            if path.startswith("/rest/v1/outbox?id=eq.ob1&select"):
                return [{"to_ref": "a@b.co", "body": "hi", "lead_id": None}]
            return []
        with mock.patch.object(hq, "_request", fake):
            C.apply_decision("m1", True)
        ob = [c for c in r.calls if c[1].startswith("/rest/v1/outbox?id=eq.ob1&status")]
        self.assertEqual(ob[0][2]["status"], "qa_passed"); self.assertEqual(ob[0][2]["qa_agent"], "owner")
        self.assertEqual(ob[1][2]["status"], "approved")

    def test_policy_text_and_edits(self):
        with mock.patch.object(hq, "_request", Rec()):
            t = P.policy_text()
        self.assertIn("RED (asks you)", t); self.assertIn("send_email (20/day)", t); self.assertIn("PROHIBITED", t)
        r = Rec()
        with mock.patch.object(hq, "_request", r):
            self.assertIn("updated", P.set_policy("send_email", "day", "10"))
            self.assertIn("Tier must", P.set_policy("send_email", "tier", "purple"))
            P.set_policy("advertising", "week", "$75")
        edits = [c for c in r.calls if c[0] == "PATCH"]
        self.assertEqual(edits[0][2]["max_count_per_day"], 10)
        self.assertEqual(edits[0][2]["updated_by"], "owner:telegram")  # the database only accepts owner edits
        self.assertEqual(edits[1][2]["max_cents_per_week"], 7500)


if __name__ == "__main__":
    unittest.main()
