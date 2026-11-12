import unittest
from unittest import mock
import hq_waterfall as W

WF = {"days": 30, "revenue_cents": 100000, "tax_setaside_cents": 33000, "running_costs_cents": 20000, "buffer_target_cents": 30000,
      "buffer_have_cents": 25000, "buffer_fill_cents": 5000, "owner_draw_cents": 10000, "pool_cents": 32000, "pool_best_cents": 19200,
      "pool_research_cents": 8000, "pool_deal_cents": 4800, "shortfall_cents": 0, "tax_pct": 33, "trailing_12m_revenue_cents": 2500000,
      "hst": "WATCH: close"}


class T(unittest.TestCase):
    def test_text(self):
        with mock.patch("hq._request", return_value=WF):
            t = W.text(30)
        for frag in ("$1,000.00", "Tax set-aside (33%)", "Reinvestment pool: $320.00", "HST: WATCH", "not financial advice"):
            self.assertIn(frag, t)

    def test_text_fails_soft(self):
        with mock.patch("hq._request", side_effect=RuntimeError("x")):
            self.assertIn("not available", W.text())

    def test_coast_fail_open_and_true(self):
        with mock.patch("hq._request", side_effect=RuntimeError("x")):
            self.assertFalse(W.coast())
        with mock.patch("hq._request", return_value={"coast": True}):
            self.assertTrue(W.coast())

    def test_touch_throttled(self):
        W._last_touch = None
        with mock.patch("hq._request") as r:
            W.touch(); W.touch()
            self.assertEqual(r.call_count, 1)

    def test_coast_blocks_payment_and_account(self):
        import hq_payments, hq_accounts
        with mock.patch("hq_waterfall.coast", return_value=True):
            self.assertIn("Coast mode", hq_payments.prepare("jarvis", "Twilio", 1000, "phone number"))
            self.assertIn("Coast mode", hq_accounts.request("jarvis", "Vendor", "need an account"))


if __name__ == "__main__":
    unittest.main()
