import unittest
from datetime import date
from unittest import mock
import hq_tools as T


class Tools(unittest.TestCase):
    def test_audit_flags(self):
        rows = [{"slug": "twilio", "status": "active", "monthly_cost_cents": 1500, "last_used_at": "2026-09-01T00:00:00+00:00", "review_by": "2026-12-01"},
                {"slug": "retell", "status": "active", "monthly_cost_cents": 0, "last_used_at": "2026-11-10T00:00:00+00:00", "review_by": "2026-10-01"},
                {"slug": "make", "status": "active", "monthly_cost_cents": 900, "last_used_at": None, "review_by": None},
                {"slug": "old", "status": "idle", "monthly_cost_cents": 500, "last_used_at": None, "review_by": None},
                {"slug": "gone", "status": "cancelled", "monthly_cost_cents": 999}]
        a = T.audit(rows, date(2026, 11, 12))
        self.assertEqual(a["active_cents"], 2400)
        why = {s: w for s, w, _ in a["flags"]}
        self.assertIn("not used in", why["twilio"]); self.assertIn("review date", why["retell"])
        self.assertIn("never recorded", why["make"]); self.assertIn("idle", why["old"]); self.assertNotIn("gone", why)

    def test_add_validation_and_save(self):
        self.assertIn("Use:", T.add("x", "bogus", "something long", "5"))
        with mock.patch("hq._request") as r:
            out = T.add("Retell AI", "api", "AI phone calls", "25")
            self.assertIn("retell-ai", out); self.assertEqual(r.call_args[0][2]["monthly_cost_cents"], 2500)
        with mock.patch("hq._request") as r:
            T.add("Render", "saas", "Hosting the app", "free"); self.assertEqual(r.call_args[0][2]["monthly_cost_cents"], 0)

    def test_mark(self):
        with mock.patch("hq._request", return_value=[{"slug": "make"}]) as r:
            self.assertIn("Marked make used", T.mark("Make", "used"))
        with mock.patch("hq._request", return_value=[]):
            self.assertIn("No tool called", T.mark("zzz", "cancel"))
        self.assertIn("Use /tool", T.mark("a", "bogus"))


if __name__ == "__main__":
    unittest.main()
