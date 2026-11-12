import asyncio
import unittest
from unittest import mock

import hq
import hq_commands as C
import hq_payments as P


class Calls:
    def __init__(self, reply=None, boom=False):
        self.calls, self.reply, self.boom = [], reply, boom

    def __call__(self, method, path, body=None, timeout=30, prefer=None):
        self.calls.append((method, path, body))
        if self.boom:
            raise RuntimeError("404 function not found")
        return self.reply(method, path, body) if callable(self.reply) else self.reply


class Payments(unittest.TestCase):
    def test_parse_amount(self):
        self.assertEqual(P.parse_amount("$1,250.50"), 125050)
        self.assertEqual(P.parse_amount("15"), 1500)
        for bad in ("0", "-5", "abc", "", "1e3"):
            self.assertIsNone(P.parse_amount(bad))

    def test_prepare_validates_before_calling_database(self):
        c = Calls({})
        with mock.patch.object(hq, "_request", c):
            self.assertIn("needs a payee", P.prepare("jarvis", "", 100, "Phone number"))
            self.assertIn("needs a payee", P.prepare("jarvis", "Twilio", 0, "Phone number"))
            self.assertIn("needs a payee", P.prepare("jarvis", "Twilio", 100, "x"))
        self.assertEqual(c.calls, [])

    def test_prepare_allow_deny_and_missing_migration(self):
        with mock.patch.object(hq, "_request", Calls({"decision": "allow", "instruction_id": "i1"})):
            self.assertIn("reserved and waiting", P.prepare("jarvis", "Twilio", 1500, "Phone number for Donna"))
        with mock.patch.object(hq, "_request", Calls({"decision": "deny", "reason": "Would break the minimum reserve"})):
            self.assertIn("minimum reserve", P.prepare("jarvis", "Twilio", 1500, "Phone number for Donna"))
        with mock.patch.object(hq, "_request", Calls(boom=True)):
            self.assertIn("nothing was reserved", P.prepare("jarvis", "Twilio", 1500, "Phone number for Donna"))

    def test_confirm_needs_one_match_amount_and_reference(self):
        def reply(m, path, body):
            if m == "GET":
                return [{"id": "abc12345-0000-0000-0000-000000000000"}]
            return "Recorded."
        c = Calls(reply)
        with mock.patch.object(hq, "_request", c):
            self.assertEqual(P.confirm("abc12345", "15", "RBC-99812"), "Recorded.")
            rpc = [b for m, p, b in c.calls if "confirm_payment" in p][0]
            self.assertEqual((rpc["p_paid_cents"], rpc["p_receipt"], rpc["p_by"]), (1500, "RBC-99812", "owner:telegram"))
            self.assertIn("bank reference", P.confirm("abc12345", "15", "x"))
            self.assertIn("Amount must", P.confirm("abc12345", "lots", "RBC-99812"))
        with mock.patch.object(hq, "_request", Calls(lambda m, p, b: [])):
            self.assertIn("exactly one", P.confirm("abc12345", "15", "RBC-99812"))
        with mock.patch.object(hq, "_request", Calls({})):
            self.assertIn("exactly one", P.confirm("zz", "15", "RBC-99812"))

    def test_decision_hook_calls_decide_as_owner(self):
        claimed = [{"id": "m1", "ref_table": "payment_instructions", "ref_id": "p1", "body": "Payment to approve"}]

        def req(method, path, body=None, timeout=30, prefer=None):
            if method == "PATCH" and "owner_messages" in path:
                return claimed
            if "decide_payment" in path:
                req.decided = body
                return "Approved: $15.00"
        with mock.patch.object(hq, "_request", req):
            out = C.apply_decision("m1", True)
        self.assertEqual(out, "Approved: $15.00")
        self.assertEqual((req.decided["p_approved"], req.decided["p_by"]), (True, "owner:telegram"))

    def test_chat_tool_and_finances_include_payments(self):
        self.assertIn("hq_prepare_payment", [t["name"] for t in C.HQ_CHAT_TOOLS])
        with mock.patch.object(hq, "_request", Calls({"decision": "allow"})):
            out = asyncio.run(C.handle_chat_tool("hq_prepare_payment", {"payee": "Twilio", "amount_cents": 1500, "purpose": "Phone number", "alternatives": "none"}))
        self.assertIn("reserved", out)


if __name__ == "__main__":
    unittest.main()
