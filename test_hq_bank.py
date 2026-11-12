import unittest
from unittest import mock
import hq, hq_bank as B

RBC = '''Account Type,Account Number,Transaction Date,Cheque Number,Description 1,Description 2,CAD$,USD$
Chequing,12345-5551234,11/03/2026,,E-TRANSFER RECEIVED,Moe,500.00,
Chequing,12345-5551234,11/04/2026,,ANTHROPIC,SAN FRANCISCO,-25.40,
Chequing,12345-5551234,not a date,,X,,1,
'''


class Rec:
    def __init__(self, replies=None):
        self.calls = []; self.replies = replies or {}

    def __call__(self, method, path, body=None, timeout=30, prefer=None):
        self.calls.append((method, path, body))
        key = path.rsplit("/", 1)[-1].split("?")[0]
        return self.replies.get(key)


class T(unittest.TestCase):
    def test_rbc_csv_parses_and_keeps_only_last4(self):
        rows, last4, problems = B.parse_statement(RBC)
        self.assertEqual(rows[0], {"date": "2026-11-03", "description": "E-TRANSFER RECEIVED Moe", "cents": 50000})
        self.assertEqual(rows[1]["cents"], -2540)
        self.assertEqual(last4, "1234")
        self.assertEqual(len(problems), 1)
        self.assertNotIn("12345", str(rows))

    def test_generic_debit_credit_columns(self):
        rows, _, _ = B.parse_statement("Date,Description,Debit,Credit\n2026-11-01,Rent,1200.00,\n2026-11-02,Refund,,15.5\n")
        self.assertEqual([r["cents"] for r in rows], [-120000, 1550])

    def test_no_header_is_reported(self):
        rows, _, problems = B.parse_statement("hello\nworld\n")
        self.assertEqual(rows, [])
        self.assertTrue(problems)

    def test_to_cents(self):
        self.assertEqual(B.to_cents("$1,234.50"), 123450)
        self.assertEqual(B.to_cents("(12.00)"), -1200)
        self.assertIsNone(B.to_cents("abc"))

    def test_set_balance_records_owner_entry(self):
        r = Rec({"bank_accounts": [{"id": "a1", "last4": None}]})
        with mock.patch.object(hq, "_request", r):
            out = B.set_balance("412.50", "2026-11-12")
        post = [c for c in r.calls if c[0] == "POST" and c[1].endswith("bank_balances")][0][2]
        self.assertEqual((post["balance_cents"], post["as_of"], post["entered_by"]), (41250, "2026-11-12", "owner:telegram"))
        self.assertIn("$412.50", out)

    def test_set_balance_rejects_garbage(self):
        with mock.patch.object(hq, "_request", Rec()):
            self.assertIn("number", B.set_balance("lots"))

    def test_import_sends_rows_then_reconciles(self):
        r = Rec({"bank_accounts": [{"id": "a1", "last4": "1234"}], "bank_import": {"rows": 2, "new": 2, "duplicates": 0},
                 "bank_reconcile": {"matched_ledger": 1, "matched_spend": 0, "unmatched": 1}})
        with mock.patch.object(hq, "_request", r):
            out = B.import_statement(RBC)
        names = [c[1].rsplit("/", 1)[-1] for c in r.calls]
        self.assertLess(names.index("bank_import"), names.index("bank_reconcile"))
        sent = [c for c in r.calls if c[1].endswith("bank_import")][0][2]
        self.assertEqual(len(sent["p_rows"]), 2)
        self.assertIn("Unmatched: 1", out)

    def test_status_and_alerts_fail_soft(self):
        with mock.patch.object(hq, "_request", side_effect=RuntimeError("down")):
            self.assertEqual(B.alerts(), [])
            self.assertIn("not installed", B.status_text())

    def test_status_shows_lower_number_rules(self):
        snap = {"bank_balance_cents": 20000, "bank_as_of": "2026-11-12", "bank_age_days": 0, "available_cents": 20000,
                "ledger_available_cents": 30000}
        with mock.patch.object(hq, "_request", Rec({"capital_snapshot": snap, "bank_alerts": ["x gap"]})):
            t = B.status_text()
        self.assertIn("$200.00", t); self.assertIn("lower number rules", t); self.assertIn("! x gap", t)

    def test_engine_bank_watch_sends_once_and_stays_quiet_when_clear(self):
        import hq_engine as E
        ins = []
        with mock.patch.object(E, "_get", return_value=[]), mock.patch.object(E, "_insert", lambda t, r: ins.append((t, r))), \
                mock.patch.object(B, "alerts", return_value=["stale"]):
            E._bank_watch()
        self.assertEqual(ins[0][1]["body"], "Bank: stale")
        ins.clear()
        with mock.patch.object(E, "_get", return_value=[{"id": 1}]), mock.patch.object(E, "_insert", lambda t, r: ins.append(r)), \
                mock.patch.object(B, "alerts", return_value=["stale"]):
            E._bank_watch()
        with mock.patch.object(E, "_get", return_value=[]), mock.patch.object(E, "_insert", lambda t, r: ins.append(r)), \
                mock.patch.object(B, "alerts", return_value=[]):
            E._bank_watch()
        self.assertEqual(ins, [])


if __name__ == "__main__":
    unittest.main()
