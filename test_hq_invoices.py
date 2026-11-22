"""hq_invoices (Phase 1 M7, Donna bills clients): every Stripe call mocked, no network."""
import os
import re
import unittest
from unittest import mock

import hq_invoices as I

ENV = {"FZ_STRIPE_INVOICING": "1", "STRIPE_SECRET_KEY": "sk_test_" + "x" * 24}
INV_ID = "11111111-2222-4333-8444-555555555555"


class FakeDB:
    """Stands in for the database functions (their own refusals are proven in sqltests/office_os_check.sql O14/O15)."""

    def __init__(self, active=True, status=None):
        self.calls, self.active = [], active
        self.status = status or {"office": "donna", "status": "active", "m1_status": "active", "drift": False}
        self.claim = {"invoice": INV_ID, "stripe_id": "in_abc123456", "mode": "test", "cents": 49700, "currency": "cad"}
        self.plans = [{"id": "p1", "office": "donna", "client": "Fzo Plumbing", "customer": "cus_abc123456", "cents": 49700, "currency": "cad", "interval": "month", "status": "approved"},
                      {"id": "p2", "office": "donna", "client": "Old", "customer": "cus_abc999999", "cents": 100, "currency": "cad", "interval": "month", "status": "revoked"}]
        self.refuse = set()

    def __call__(self, method, path, body=None):
        name = path.rsplit("/", 1)[-1]
        self.calls.append((name, body))
        if name in self.refuse:
            raise RuntimeError("refused by the database")
        if name == "office_os_status":
            return self.status if self.active else dict(self.status, status="dormant", m1_status="dormant")
        if name == "office_os_invoice_record":
            return {"invoice": INV_ID, "status": "draft"}
        if name == "office_os_invoice_claim_send":
            return self.claim
        if name == "office_os_plans":
            return self.plans
        if name == "office_os_invoice_record_plan":
            return {"invoice": INV_ID, "status": "approved", "period": "2026-12"}
        return {"ok": True}


class FakeStripe:
    def __init__(self, invoice=None):
        self.calls = []
        self.invoice = invoice or {"id": "in_abc123456", "status": "draft", "amount_due": 49700, "currency": "cad"}

    def __call__(self, method, path, form):
        self.calls.append((method, path, dict(form)))
        if path == "/v1/invoices" and method == "POST":
            return {"id": "in_abc123456"}
        if method == "GET":
            return self.invoice
        if path == "/v1/prices":
            return {"id": "price_1"}
        if path == "/v1/payment_links":
            return {"id": "plink_abc123456", "url": "https://buy.stripe.com/test_x"}
        return {"ok": True}


class Gates(unittest.TestCase):
    def test_flag_off_makes_no_call(self):
        for env in ({}, {"FZ_STRIPE_INVOICING": "0", "STRIPE_SECRET_KEY": ENV["STRIPE_SECRET_KEY"]}):
            db, st = FakeDB(), FakeStripe()
            for fn in (lambda: I.draft_invoice("donna", "cus_abc123456", 100, "cad", "x", env=env, http=st, rpc=db),
                       lambda: I.draft_payment_link("donna", 100, "cad", "x", env=env, http=st, rpc=db),
                       lambda: I.request_send(INV_ID, env=env, rpc=db), lambda: I.send(INV_ID, env=env, http=st, rpc=db),
                       lambda: I.propose_plan("donna", "A", "cus_abc123456", 100, "cad", "month", env=env, rpc=db),
                       lambda: I.bill_plans("donna", env=env, http=st, rpc=db)):
                with self.assertRaisesRegex(I.InvoiceError, "invoicing is off"):
                    fn()
            self.assertEqual((db.calls, st.calls), ([], []))
        import hq_hands_adapters
        with mock.patch.dict(os.environ, {}, clear=True), mock.patch.object(hq_hands_adapters, "http", side_effect=AssertionError("network")):
            with self.assertRaises(I.InvoiceError):
                I.draft_invoice("donna", "cus_abc123456", 100, "cad", "x")

    def test_keys(self):
        self.assertEqual(I.mode(ENV), "test")
        self.assertEqual(I.mode({"FZ_STRIPE_INVOICING": "1", "STRIPE_SECRET_KEY": "rk_test_abc"}), "test")
        live = {"FZ_STRIPE_INVOICING": "1", "STRIPE_SECRET_KEY": "sk_live_" + "x" * 24}
        with self.assertRaisesRegex(I.InvoiceError, "FZ_STRIPE_LIVE"):
            I.mode(live)
        with self.assertRaisesRegex(I.InvoiceError, "FZ_STRIPE_LIVE"):
            I.mode(dict(live, FZ_STRIPE_LIVE="yes"))
        self.assertEqual(I.mode(dict(live, FZ_STRIPE_LIVE="1")), "live")
        for bad in ("", "pk_test_abc", "whsec_abc", "sk_tes_abc"):
            with self.assertRaises(I.InvoiceError):
                I.mode({"FZ_STRIPE_INVOICING": "1", "STRIPE_SECRET_KEY": bad})
        db, st = FakeDB(), FakeStripe()
        with self.assertRaisesRegex(I.InvoiceError, "FZ_STRIPE_LIVE"):
            I.draft_invoice("donna", "cus_abc123456", 100, "cad", "x", env=live, http=st, rpc=db)
        self.assertEqual((db.calls, st.calls), ([], []))

    def test_dormant_office_refused(self):
        db, st = FakeDB(active=False), FakeStripe()
        for fn in (lambda: I.draft_invoice("donna", "cus_abc123456", 100, "cad", "x", env=ENV, http=st, rpc=db),
                   lambda: I.draft_payment_link("donna", 100, "cad", "x", env=ENV, http=st, rpc=db),
                   lambda: I.propose_plan("donna", "A", "cus_abc123456", 100, "cad", "month", env=ENV, rpc=db),
                   lambda: I.bill_plans("donna", env=ENV, http=st, rpc=db)):
            with self.assertRaisesRegex(I.InvoiceError, "nothing runs until the owner activates it"):
                fn()
        self.assertEqual(st.calls, [])
        self.assertEqual({c[0] for c in db.calls}, {"office_os_status"})


class Flow(unittest.TestCase):
    def test_draft_records_and_never_sends(self):
        db, st = FakeDB(), FakeStripe()
        r = I.draft_invoice("donna", "cus_abc123456", 49700, "CAD", "Answer setup", env=ENV, http=st, rpc=db)
        self.assertEqual((r["status"], r["mode"]), ("draft", "test"))
        self.assertEqual([(m, p) for m, p, _ in st.calls], [("POST", "/v1/invoices"), ("POST", "/v1/invoiceitems")])
        self.assertEqual(st.calls[0][2]["auto_advance"], "false")
        rec = [b for n, b in db.calls if n == "office_os_invoice_record"][0]
        self.assertEqual((rec["p_office"], rec["p_cents"], rec["p_currency"], rec["p_mode"]), ("donna", 49700, "cad", "test"))
        with self.assertRaises(I.InvoiceError):
            I.draft_invoice("donna", "someone@example.invalid", 100, "cad", "x", env=ENV, http=st, rpc=db)    # a customer id, never client details

    def test_unrecorded_draft_is_deleted(self):
        db, st = FakeDB(), FakeStripe()
        db.refuse.add("office_os_invoice_record")
        with self.assertRaisesRegex(I.InvoiceError, "draft deleted"):
            I.draft_invoice("donna", "cus_abc123456", 100, "cad", "x", env=ENV, http=st, rpc=db)
        self.assertEqual(st.calls[-1][:2], ("DELETE", "/v1/invoices/in_abc123456"))

    def test_send_without_approval_refused(self):
        db, st = FakeDB(), FakeStripe()
        db.refuse.add("office_os_invoice_claim_send")             # the database refuses a claim without the owner's decision (O14)
        with self.assertRaises(RuntimeError):
            I.send(INV_ID, env=ENV, http=st, rpc=db)
        self.assertEqual(st.calls, [])
        self.assertNotIn("office_os_invoice_mark_sent", [c[0] for c in db.calls])

    def test_send_rechecks_stripe(self):
        for inv in ({"status": "draft", "amount_due": 99700, "currency": "cad"}, {"status": "open", "amount_due": 49700, "currency": "cad"},
                    {"status": "draft", "amount_due": 49700, "currency": "usd"}):
            db, st = FakeDB(), FakeStripe(invoice=inv)
            with self.assertRaisesRegex(I.InvoiceError, "no longer matches"):
                I.send(INV_ID, env=ENV, http=st, rpc=db)
            self.assertEqual([p for m, p, _ in st.calls], ["/v1/invoices/in_abc123456"])        # no finalize / send
            self.assertEqual([b for n, b in db.calls if n == "office_os_invoice_mark_sent"], [{"p_invoice": INV_ID, "p_ok": False}])
        db, st = FakeDB(), FakeStripe()
        db.claim["mode"] = "live"
        with self.assertRaisesRegex(I.InvoiceError, "recorded in live mode"):
            I.send(INV_ID, env=ENV, http=st, rpc=db)
        self.assertEqual(st.calls, [])

    def test_send_approved(self):
        db, st = FakeDB(), FakeStripe()
        self.assertTrue(I.send(INV_ID, env=ENV, http=st, rpc=db)["sent"])
        self.assertEqual([p for m, p, _ in st.calls], ["/v1/invoices/in_abc123456", "/v1/invoices/in_abc123456/finalize", "/v1/invoices/in_abc123456/send"])
        self.assertEqual([b for n, b in db.calls if n == "office_os_invoice_mark_sent"], [{"p_invoice": INV_ID, "p_ok": True}])

    def test_payment_link_recorded_not_sent(self):
        db, st = FakeDB(), FakeStripe()
        r = I.draft_payment_link("donna", 79700, "cad", "Capture", env=ENV, http=st, rpc=db)
        self.assertEqual(r["stripe_id"], "plink_abc123456")
        self.assertFalse(any("send" in p or "finalize" in p for _, p, _ in st.calls))


class Plans(unittest.TestCase):
    def test_bill_only_approved_plans_exact_amount(self):
        db, st = FakeDB(), FakeStripe()
        r = I.bill_plans("donna", env=ENV, http=st, rpc=db)
        self.assertEqual([x["plan"] for x in r["sent"]], ["p1"])                  # the revoked plan is not billed
        rp = [b for n, b in db.calls if n == "office_os_invoice_record_plan"]
        self.assertEqual(rp, [{"p_plan": "p1", "p_stripe_id": "in_abc123456", "p_mode": "test", "p_cents": 49700, "p_currency": "cad", "p_interval": "month"}])
        item = [f for m, p, f in st.calls if p == "/v1/invoiceitems"][0]
        self.assertEqual((item["amount"], item["currency"]), (49700, "cad"))

    def test_database_refusal_deletes_the_draft(self):
        # above the plan, another interval, twice in a period or a revoked plan: the database refuses (O15) and nothing is sent
        db, st = FakeDB(), FakeStripe()
        db.refuse.add("office_os_invoice_record_plan")
        r = I.bill_plans("donna", env=ENV, http=st, rpc=db)
        self.assertEqual((r["sent"], len(r["refused"])), ([], 1))
        self.assertEqual(st.calls[-1][:2], ("DELETE", "/v1/invoices/in_abc123456"))
        self.assertFalse(any(p.endswith("/send") or p.endswith("/finalize") for _, p, _ in st.calls))

    def test_revoked_plan_stops_auto_send(self):
        db, st = FakeDB(), FakeStripe()
        db.plans = [dict(p, status="revoked") for p in db.plans]
        self.assertEqual(I.bill_plans("donna", env=ENV, http=st, rpc=db)["sent"], [])
        self.assertEqual(st.calls, [])
        db, st = FakeDB(), FakeStripe()
        db.refuse.add("office_os_invoice_claim_send")             # revoked between recording and sending: the claim refuses (O15)
        r = I.bill_plans("donna", env=ENV, http=st, rpc=db)
        self.assertEqual(r["sent"], [])
        self.assertFalse(any(p.endswith("/send") for _, p, _ in st.calls))

    def test_propose_plan(self):
        db = FakeDB()
        I.propose_plan("donna", "Fzo; Plumbing", "cus_abc123456", 49700, "cad", "month", env=ENV, rpc=db)
        b = [b for n, b in db.calls if n == "office_os_plan_propose"][0]
        self.assertEqual((b["p_client_label"], b["p_interval"], b["p_cents"]), ("Fzo Plumbing", "month", 49700))
        with self.assertRaises(I.InvoiceError):
            I.propose_plan("donna", "A", "cus_abc123456", 100, "cad", "week", env=ENV, rpc=db)


class NoRefundsOrPayouts(unittest.TestCase):
    def test_no_refund_payout_or_transfer_path(self):
        src = open(I.__file__).read().lower()
        code = re.sub(r'"""[\s\S]*?"""', "", src)
        for bad in ("/v1/refunds", "/v1/payouts", "/v1/transfers", "/v1/credit_notes", "/v1/balance", "refund(", "payout(", "def refund", "def payout"):
            self.assertNotIn(bad, code)
        for m, p in I.ALLOWED_CALLS:
            self.assertTrue(p.startswith(("/v1/invoices", "/v1/invoiceitems", "/v1/prices", "/v1/payment_links")), p)
        for path in ("/v1/refunds", "/v1/payouts", "/v1/transfers", "/v1/credit_notes", "/v1/invoices/in_abc123456/void", "/v1/invoices/in_abc123456/pay"):
            with self.assertRaisesRegex(I.InvoiceError, "not allowed"):
                I._stripe("POST", path, {}, ENV, http=lambda *a: self.fail("called"))

    def test_never_writes_money_tables(self):
        src = re.sub(r'"""[\s\S]*?"""', "", open(I.__file__).read())
        for bad in ("ledger", "reserve_spend", "fz_reserve_office_spend", "prepare_payment", "payment_instructions", "capital_policy", "daily_spend_cap", "fz_owner_"):
            self.assertNotIn(bad, src)

    def test_command_owner_only(self):
        import asyncio, types
        import hq_commands
        out = []
        with mock.patch.object(hq_commands, "_owner", return_value=False), mock.patch.object(hq_commands.hq_core, "reply_to", new=mock.AsyncMock(side_effect=lambda m, t: out.append(t))):
            asyncio.run(hq_commands.hq_invoices_cmd(types.SimpleNamespace(message=object()), types.SimpleNamespace(args=["send", INV_ID])))
        self.assertEqual(out, [])
        with mock.patch.object(hq_commands, "_owner", return_value=True), mock.patch.object(hq_commands.hq_core, "reply_to", new=mock.AsyncMock(side_effect=lambda m, t: out.append(t))), \
             mock.patch.dict(os.environ, {}, clear=True):
            asyncio.run(hq_commands.hq_invoices_cmd(types.SimpleNamespace(message=object()), types.SimpleNamespace(args=["send", INV_ID])))
        self.assertEqual(out, ["Refused: invoicing is off (FZ_STRIPE_INVOICING is not 1)"])


    def test_transport_is_the_existing_official_api_opener(self):
        import hq_hands_adapters
        seen = []
        def fake(method, url, headers=None, form=None, timeout=60, **k):
            seen.append((method, url, form, headers))
            return 200, {"id": "in_abc123456"}, {}
        with mock.patch.object(hq_hands_adapters, "http", side_effect=fake):
            self.assertEqual(I._stripe("POST", "/v1/invoices", {"customer": "cus_abc123456"}, ENV)["id"], "in_abc123456")
        (m, url, form, headers), = seen
        self.assertEqual((m, url, form), ("POST", "https://api.stripe.com/v1/invoices", {"customer": "cus_abc123456"}))
        self.assertTrue(headers["Authorization"].startswith("Basic "))
        with mock.patch.object(hq_hands_adapters, "http", return_value=(402, {"error": {"message": "x"}}, {})):
            with self.assertRaisesRegex(I.InvoiceError, "HTTP 402"):
                I._stripe("POST", "/v1/invoices", {}, ENV)
        src = open(I.__file__).read()
        self.assertNotIn("urlopen", src)


if __name__ == "__main__":
    unittest.main()
