"""Unit tests for hq_office_money (Phase 1 M2): the bot reads office money, proposes, and asks the office gate; it fails closed and can never allocate."""

import asyncio
import inspect
import unittest
import urllib.error
from unittest import mock

import hq_commands
import hq_office_money as om

REPORT = {
    "since": "2026-11-28T10:00:00-05:00",
    "offices": [
        {"office": "donna", "title": "Donna", "status": "active", "allocated_cents": 50000, "spent_cents": 1250, "reserved_cents": 300,
         "revenue_cents": 9000, "profit_cents": 7750, "reinvest_pct": 25, "available_cents": 50387},
        {"office": "monopoly", "title": "Monopoly", "status": "dormant", "allocated_cents": 0, "spent_cents": 0, "reserved_cents": 0,
         "revenue_cents": 0, "profit_cents": 0, "reinvest_pct": 0, "available_cents": 0},
    ],
    "group": {"spent_cents": 4200, "revenue_cents": 0},
    "totals": {"allocated_cents": 50000, "spent_cents": 5450, "revenue_cents": 9000, "profit_cents": 3550},
    "capital_available_cents": 80000, "capital_mode": "normal", "unallocated_cents": 29613,
    "pending_proposals": [{"id": "p-1", "office": "monopoly", "kind": "allocate", "cents": 2500, "by": "jarvis"}],
}


class ReportTests(unittest.TestCase):
    def test_text_lists_each_office_and_totals(self):
        with mock.patch.object(om.hq, "_request", return_value=REPORT) as rq:
            t = om.offices_text()
        rq.assert_called_once_with("POST", "/rest/v1/rpc/fz_money_report", {})
        self.assertIn("Donna: available $503.87 | allocated $500.00, spent $12.50 (+$3.00 reserved), revenue $90.00, profit $77.50, reinvest 25%", t)
        self.assertIn("Monopoly [DORMANT]: available $0.00", t)
        self.assertIn("TOTAL allocated $500.00", t)
        self.assertIn("not allocated to an office $296.13", t)
        self.assertIn("monopoly: allocate $25.00 (by jarvis) id p-1", t)
        self.assertIn("only you", t)

    def test_negative_balance_formats(self):
        r = dict(REPORT, offices=[dict(REPORT["offices"][0], available_cents=-125)])
        with mock.patch.object(om.hq, "_request", return_value=r):
            self.assertIn("available -$1.25", om.offices_text())

    def test_not_installed(self):
        with mock.patch.object(om.hq, "_request", side_effect=urllib.error.HTTPError("u", 404, "nf", {}, None)):
            self.assertIn("not installed", om.offices_text())
        with mock.patch.object(om.hq, "_request", return_value=[]):
            self.assertIsNone(om.report())


class ProposeTests(unittest.TestCase):
    def test_propose_allocate(self):
        with mock.patch.object(om.hq, "_request", return_value={"proposal": "x1", "status": "pending"}) as rq:
            r = om.propose("donna", "allocate", 5000, rationale="first client test needs ad money")
        self.assertTrue(r["ok"])
        name, args = rq.call_args[0][1], rq.call_args[0][2]
        self.assertEqual(name, "/rest/v1/rpc/fz_propose_office_money")
        self.assertEqual(args["p_kind"], "allocate")
        self.assertEqual(args["p_cents"], 5000)
        self.assertIsNone(args["p_reinvest_pct"])

    def test_propose_reinvest_drops_cents(self):
        with mock.patch.object(om.hq, "_request", return_value={"proposal": "x2"}) as rq:
            om.propose("donna", "reinvest", 999, reinvest_pct=25, rationale="keep a quarter of the profit")
        self.assertIsNone(rq.call_args[0][2]["p_cents"])
        self.assertEqual(rq.call_args[0][2]["p_reinvest_pct"], 25)

    def test_propose_validates_before_calling(self):
        with mock.patch.object(om.hq, "_request") as rq:
            self.assertFalse(om.propose("donna", "spend", 100, rationale="not a kind at all")["ok"])
            self.assertFalse(om.propose("donna", "allocate", 0, rationale="zero is not an allocation")["ok"])
            self.assertFalse(om.propose("donna", "reinvest", reinvest_pct=101, rationale="too much reinvestment")["ok"])
            self.assertFalse(om.propose("donna", "allocate", 100, rationale="short")["ok"])
        rq.assert_not_called()

    def test_propose_error_is_reported(self):
        with mock.patch.object(om.hq, "_request", side_effect=urllib.error.HTTPError("u", 400, "bad", {}, None)):
            r = om.propose("donna", "allocate", 100, rationale="a valid rationale here")
        self.assertFalse(r["ok"])


class GateTests(unittest.TestCase):
    ARGS = ("donna", "donna-ops", "routine_expense", "vendor", "a purpose", "a benefit", "none", 1500)

    def test_passes_through_the_database_decision(self):
        with mock.patch.object(om.hq, "_request", return_value={"decision": "allow", "reservation_id": "r1", "office": "donna"}) as rq:
            r = om.reserve(*self.ARGS)
        self.assertEqual(r["decision"], "allow")
        self.assertEqual(rq.call_args[0][1], "/rest/v1/rpc/fz_reserve_office_spend")
        self.assertEqual(rq.call_args[0][2]["p_office"], "donna")
        self.assertEqual(rq.call_args[0][2]["p_cents"], 1500)

    def test_fails_closed(self):
        for err in (urllib.error.HTTPError("u", 500, "x", {}, None), TimeoutError(), ValueError()):
            with mock.patch.object(om.hq, "_request", side_effect=err):
                self.assertEqual(om.reserve(*self.ARGS)["decision"], "deny")
        for reply in (None, [], {"decision": "maybe"}, "allow"):
            with mock.patch.object(om.hq, "_request", return_value=reply):
                self.assertEqual(om.reserve(*self.ARGS)["decision"], "deny")


class NoOwnerPathTests(unittest.TestCase):
    def test_module_never_calls_an_owner_function_or_writes_a_money_table(self):
        src = inspect.getsource(om)
        for forbidden in ("fz_owner_", "fz_office_allocations", "fz_office_money_policy", "fz_money_attribution", "PATCH", "DELETE"):
            self.assertNotIn(forbidden, src)


class CommandTests(unittest.TestCase):
    def test_offices_command_is_registered_and_owner_only(self):
        self.assertIn("offices", [m[0] for m in hq_commands.MENU])
        upd = mock.MagicMock()
        with mock.patch.object(hq_commands, "_owner", return_value=False), mock.patch.object(om, "offices_text") as ot:
            asyncio.run(hq_commands.hq_offices_cmd(upd, mock.MagicMock()))
        ot.assert_not_called()
        with mock.patch.object(hq_commands, "_owner", return_value=True), mock.patch.object(om, "offices_text", return_value="OFFICES"), \
                mock.patch.object(hq_commands.hq_core, "reply_to", new=mock.AsyncMock()) as rep:
            asyncio.run(hq_commands.hq_offices_cmd(upd, mock.MagicMock()))
        rep.assert_awaited_once()
        self.assertEqual(rep.await_args[0][1], "OFFICES")


if __name__ == "__main__":
    unittest.main()
