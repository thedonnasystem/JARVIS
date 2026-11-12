import asyncio
import unittest
from unittest import mock

import hq
import hq_accounts as A
import hq_commands as C


def reqf(reply, log=None):
    def f(method, path, body=None, timeout=30, prefer=None):
        if log is not None:
            log.append((method, path, body))
        if isinstance(reply, Exception):
            raise reply
        return reply(method, path, body) if callable(reply) else reply
    return f


class Accounts(unittest.TestCase):
    def test_request_validates_and_filters_needs(self):
        log = []
        with mock.patch.object(hq, "_request", reqf({"decision": "ask_owner"}, log)), mock.patch("hq_waterfall.coast", return_value=False):
            self.assertIn("needs a vendor", A.request("jarvis", "", "Phone numbers"))
            self.assertIn("https://", A.request("jarvis", "Twilio", "Phone number for Donna", url="http://x"))
            self.assertEqual(log, [])
            out = A.request("jarvis", "Twilio", "Phone number for Donna", "donna", "https://twilio.com", 0, ["sms_code", "bogus", "captcha"])
        self.assertIn("I cannot sign up myself", out)
        self.assertEqual(log[0][2]["p_needs"], ["sms_code", "captcha"])

    def test_request_deny_and_missing_migration(self):
        with mock.patch.object(hq, "_request", reqf({"decision": "deny", "reason": "An open request for that vendor already exists."})):
            self.assertIn("already exists", A.request("jarvis", "Twilio", "Phone number for Donna"))
        with mock.patch.object(hq, "_request", reqf(RuntimeError("404"))):
            self.assertIn("not available yet", A.request("jarvis", "Twilio", "Phone number for Donna"))

    def test_complete_needs_unique_id_and_passes_owner(self):
        log = []

        def reply(m, p, b):
            return [{"id": "11111111-0000-0000-0000-000000000000"}] if m == "GET" else "Recorded."
        with mock.patch.object(hq, "_request", reqf(reply, log)):
            self.assertEqual(A.complete("11111111", "moe@biz.ca"), "Recorded.")
        rpc = [c for c in log if "complete_account" in c[1]][0][2]
        self.assertEqual((rpc["p_login"], rpc["p_by"]), ("moe@biz.ca", "owner:telegram"))
        with mock.patch.object(hq, "_request", reqf(lambda m, p, b: [])):
            self.assertIn("exactly one", A.complete("11111111", "x@y.ca"))

    def test_decision_hook_and_tool_registered(self):
        claimed = [{"id": "m1", "ref_table": "account_requests", "ref_id": "a1", "body": "Account to create"}]

        def reply(m, p, b):
            if m == "PATCH" and "owner_messages" in p:
                return claimed
            if "decide_account" in p:
                reply.got = b
                return "Approved: Twilio."
        with mock.patch.object(hq, "_request", reqf(reply)):
            self.assertEqual(C.apply_decision("m1", True), "Approved: Twilio.")
        self.assertEqual((reply.got["p_approved"], reply.got["p_by"]), (True, "owner:telegram"))
        self.assertIn("hq_request_account", [t["name"] for t in C.HQ_CHAT_TOOLS])


if __name__ == "__main__":
    unittest.main()
