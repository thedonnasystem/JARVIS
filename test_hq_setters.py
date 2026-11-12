import unittest
from unittest import mock
import hq_setters as S


class T(unittest.TestCase):
    def test_log_kinds_and_first_booking(self):
        with mock.patch("hq._request", return_value={"ok": True, "name": "Sam", "first_booking": True}) as r:
            out = S.log("sam", "booked", "Acme")
            self.assertIn("group chat", out); self.assertEqual(r.call_args[0][2]["p_kind"], "booked")
        self.assertIn("Kind must", S.log("sam", "bogus"))
        with mock.patch("hq._request", return_value={"error": "No setter with that name."}):
            self.assertEqual(S.log("x", "closed"), "No setter with that name.")

    def test_paid_amount_validation_and_fail_closed(self):
        self.assertIn("Amount", S.paid("sam", "close", "abc"))
        with mock.patch("hq._request", side_effect=RuntimeError("x")):
            self.assertIn("Could not", S.paid("sam", "close", "120"))
        with mock.patch("hq._request", return_value={"ok": True, "name": "Sam"}) as r:
            self.assertIn("$120.00", S.paid("sam", "close", "120", "ref"))
            self.assertEqual(r.call_args[0][2]["p_cents"], 12000)

    def test_owed_text(self):
        rows = [{"name": "Sam", "status": "active", "booked": 4, "closes": 3, "active_clients": 3, "owed_close_cents": 36000, "owed_recurring_cents": 15000, "recurring_on": True}]
        with mock.patch("hq._request", return_value=rows):
            t = S.owed_text()
        self.assertIn("$510.00", t); self.assertIn("Sam", t)
        with mock.patch("hq._request", side_effect=RuntimeError("x")):
            self.assertIn("No setters", S.owed_text())


if __name__ == "__main__":
    unittest.main()
