import unittest, urllib.error
from unittest import mock
import hq, hq_capital as K, hq_engine as E


class Rec:
    def __init__(self, replies=None, exc=None):
        self.calls = []; self.replies = replies or {}; self.exc = exc

    def __call__(self, method, path, body=None, timeout=30, prefer=None):
        self.calls.append((method, path, body))
        name = path.rsplit("/", 1)[-1]
        if self.exc and path.startswith("/rest/v1/rpc/"):
            raise self.exc
        return self.replies.get(name)


SNAP = {"available_cents": 28010, "mode": "normal", "fund_cents": 30000, "revenue_cents": 0, "expense_cents": 1990,
        "ai_spend_cents": 0, "reserved_cents": 0, "week_spend_cents": 1990, "recurring_monthly_cents": 2000,
        "min_reserve_cents": 5000, "weekly_limit_cents": 7500, "per_transaction_limit_cents": 2500,
        "reinvest_pct": 50, "since": "2026-11-12"}


class T(unittest.TestCase):
    def test_reserve_passes_everything_and_returns_decision(self):
        r = Rec({"reserve_spend": {"decision": "allow", "reservation_id": "res-1"}})
        with mock.patch.object(hq, "_request", r):
            out = K.reserve("donna-ops", "subscription_purchase", "Acme", "CRM for leads", "track leads", "free tier", 2000,
                            recurring=True, monthly_cents=2000)
        self.assertEqual(out["reservation_id"], "res-1")
        body = r.calls[0][2]
        self.assertEqual((body["p_cents"], body["p_recurring"], body["p_alternatives"]), (2000, True, "free tier"))

    def test_fails_closed(self):
        for exc in (urllib.error.URLError("down"), TimeoutError()):
            with mock.patch.object(hq, "_request", Rec(exc=exc)):
                self.assertEqual(K.reserve("a", "routine_expense", "v", "purpose", "benefit", "alt", 100)["decision"], "deny")
        with mock.patch.object(hq, "_request", Rec({"reserve_spend": "weird"})):
            self.assertEqual(K.reserve("a", "routine_expense", "v", "purpose", "benefit", "alt", 100)["decision"], "deny")

    def test_status_text(self):
        with mock.patch.object(hq, "_request", Rec({"capital_snapshot": SNAP})):
            t = K.status_text()
        self.assertIn("$280.10 available — NORMAL", t); self.assertIn("$20.00/month", t)
        with mock.patch.object(hq, "_request", Rec({"capital_snapshot": None})):
            self.assertIn("not installed", K.status_text())

    def test_owner_edits_marked_as_owner(self):
        r = Rec()
        with mock.patch.object(hq, "_request", r):
            self.assertIn("set", K.set_field("fund", "$500"))
            self.assertIn("0-100", K.set_field("reinvest", "150"))
            self.assertIn("Fields", K.set_field("bogus", "1"))
            K.set_field("reinvest", "60%")
        edits = [c[2] for c in r.calls if c[0] == "PATCH"]
        self.assertEqual(edits[0], {"operating_fund_cents": 50000, "updated_by": "owner:telegram"})
        self.assertEqual(edits[1]["reinvest_pct"], 60)

    def test_low_cost_mode_downgrades_models(self):
        rows = {"agents": [{"slug": "donna-researcher", "title": "R", "charter": "c", "metric": "m", "model_tier": "standard",
                            "role": "researcher", "status": "active"}]}
        def fake(method, path, body=None, timeout=30, prefer=None):
            if path.startswith("/rest/v1/agents"): return rows["agents"]
            if path.startswith("/rest/v1/handbook"): return []
            if path.endswith("/capital_mode"): return "low_cost"
            if path.endswith("/reserve_llm_budget"): return "call-1"
            if "/rpc/" in path: return 1
            if path.startswith("/rest/v1/llm_calls"): return []
            return None
        with mock.patch.object(hq, "_request", fake), mock.patch.object(E, "_complete", return_value=("ok", 1, 1, 0)) as c:
            E._refresh_capital_mode()
            E.run_turn_sync("donna-researcher", "task", 100, "p")
            self.assertEqual(c.call_args[0][0], E.TIER_MODEL["cheap"])
        E._CAPITAL_MODE = "normal"


if __name__ == "__main__":
    unittest.main()
