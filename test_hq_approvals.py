"""Unit tests for Phase 1 M3: the read-only approval queue (hq_approvals, /approvals) and the flag-gated office payment wiring (hq_payments)."""

import asyncio
import inspect
import os
import unittest
from unittest import mock

import hq_approvals as qa
import hq_commands
import hq_payments

ROWS = [
    {"request_type": "action_approval", "source_id": "11111111-aaaa", "office": "b2b-records", "requester": "fzq-agent-a", "action": "take_loan",
     "amount_cents": 0, "risk": "red", "status": "pending", "expires_at": "2026-11-27T10:00:00Z"},
    {"request_type": "office_money_allocate", "source_id": "22222222-bbbb", "office": "donna", "requester": "jarvis", "action": "allocate",
     "amount_cents": 250000, "risk": "money", "status": "pending", "expires_at": "2026-11-26T10:00:00Z"},
]


class QueueTests(unittest.TestCase):
    def test_one_line_per_pending_item(self):
        with mock.patch.object(qa.hq, "_request", return_value=ROWS) as rq:
            t = qa.queue_text()
        path = rq.call_args[0][1]
        self.assertTrue(path.startswith("/rest/v1/fz_approval_queue?status=eq.pending"))
        self.assertEqual(rq.call_args[0][0], "GET")
        lines = t.splitlines()
        self.assertEqual(lines[0], "Waiting on you: 2")
        self.assertIn("[red] b2b-records: take loan by fzq-agent-a, expires 2026-11-27 (tap its message) id 11111111", lines[1])
        self.assertIn("[money] donna: allocate $2,500.00 by jarvis, expires 2026-11-26 (owner session) id 22222222", lines[2])

    def test_empty_and_not_installed(self):
        with mock.patch.object(qa.hq, "_request", return_value=[]):
            self.assertEqual(qa.queue_text(), "Nothing is waiting on you.")
        with mock.patch.object(qa.hq, "_request", side_effect=RuntimeError("404")):
            self.assertIn("not installed", qa.queue_text())

    def test_read_only(self):
        src = inspect.getsource(qa).split('"""', 2)[2]   # the code, without the module docstring
        for forbidden in ("PATCH", "POST", "DELETE", "approval_requests", "fz_owner_", "decide", "rpc/"):
            self.assertNotIn(forbidden, src)

    def test_command_registered_and_owner_only(self):
        self.assertIn("approvals", [m[0] for m in hq_commands.MENU])
        upd = mock.MagicMock()
        with mock.patch.object(hq_commands, "_owner", return_value=False), mock.patch.object(qa, "queue_text") as qt:
            asyncio.run(hq_commands.hq_approvals_cmd(upd, mock.MagicMock()))
        qt.assert_not_called()
        with mock.patch.object(hq_commands, "_owner", return_value=True), mock.patch.object(qa, "queue_text", return_value="Q"), \
                mock.patch.object(hq_commands.hq_core, "reply_to", new=mock.AsyncMock()) as rep:
            asyncio.run(hq_commands.hq_approvals_cmd(upd, mock.MagicMock()))
        self.assertEqual(rep.await_args[0][1], "Q")


class PaymentWiringTests(unittest.TestCase):
    def _call(self, env, venture):
        with mock.patch.dict(os.environ, env, clear=False), mock.patch.object(hq_payments.hq, "_request", return_value={"decision": "allow"}) as rq, \
                mock.patch("hq_waterfall.coast", return_value=False):
            hq_payments.prepare("jarvis", "Twilio", 1500, "Phone number for Donna", venture=venture)
        return rq.call_args[0][1], rq.call_args[0][2]

    def test_default_off_is_todays_call(self):
        env = {k: v for k, v in os.environ.items() if k != "FZ_OFFICE_SPEND_GATE"}
        with mock.patch.dict(os.environ, env, clear=True):
            path, args = self._call({}, "donna")
        self.assertEqual(path, "/rest/v1/rpc/prepare_payment")
        self.assertEqual(args["p_venture_slug"], "donna")
        for off in ("0", "", "true", "yes"):
            self.assertEqual(self._call({"FZ_OFFICE_SPEND_GATE": off}, "donna")[0], "/rest/v1/rpc/prepare_payment")

    def test_flag_on_routes_venture_payments_through_the_office_gate(self):
        path, args = self._call({"FZ_OFFICE_SPEND_GATE": "1"}, "donna")
        self.assertEqual(path, "/rest/v1/rpc/fz_prepare_office_payment")
        self.assertEqual(set(args), {"p_actor", "p_payee", "p_cents", "p_purpose", "p_alternatives", "p_due", "p_venture_slug"})

    def test_flag_on_without_venture_is_unchanged(self):
        self.assertEqual(self._call({"FZ_OFFICE_SPEND_GATE": "1"}, None)[0], "/rest/v1/rpc/prepare_payment")

    def test_office_refusal_is_relayed_and_nothing_reserved(self):
        with mock.patch.dict(os.environ, {"FZ_OFFICE_SPEND_GATE": "1"}), mock.patch("hq_waterfall.coast", return_value=False), \
                mock.patch.object(hq_payments.hq, "_request", return_value={"decision": "deny", "reason": "Office Donna is dormant"}):
            self.assertIn("Not prepared: Office Donna is dormant", hq_payments.prepare("jarvis", "Twilio", 1500, "Phone number", venture="donna"))


if __name__ == "__main__":
    unittest.main()
