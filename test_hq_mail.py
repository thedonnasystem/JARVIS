import os, unittest
from unittest import mock
import hq_mail as M
from hq_policy import Decision

GOOD = "Hi\n\nSent by Moe, The Donna System, 1 Main St, Ottawa ON.\nTo stop receiving emails from us, reply \"unsubscribe\"."
ROW = {"id": "a1", "to_ref": "x@example.com", "body": GOOD, "lead_id": "L1", "agent": "donna-ops", "venture_id": "v1"}
PROF = {"sender_name": "Moe", "brand": "The Donna System", "mailing_address": "1 Main St, Ottawa ON"}
ENV = {"RESEND_API_KEY": "k", "MAIL_FROM": "Moe <m@example.com>"}


class T(unittest.TestCase):
    def test_off_without_config(self):
        with mock.patch.dict(os.environ, {}, clear=True):
            self.assertFalse(M.configured())
            self.assertEqual(M.deliver_approved()["reason"], "not configured")

    def test_refusals(self):
        self.assertIsNone(M.refusal(ROW, {"do_not_contact": False}))
        self.assertIn("recipient", M.refusal({**ROW, "to_ref": "nope"}))
        self.assertIn("do-not-contact", M.refusal(ROW, {"do_not_contact": True}))
        self.assertIn("CASL", M.refusal({**ROW, "body": "Hi, buy now"}))
        self.assertIn("CASL", M.refusal({**ROW, "body": GOOD + "\n[ADD YOUR BUSINESS MAILING ADDRESS - required by CASL]"}))

    def test_not_live_sends_nothing(self):
        with mock.patch.dict(os.environ, ENV), mock.patch.object(M, "live", return_value=False), mock.patch.object(M, "_post") as p:
            self.assertEqual(M.deliver_approved()["reason"], "not live"); p.assert_not_called()

    def _run(self, decision="allow", posted=True, refused=False, slug="donna", prof=PROF, venture_id="v1", suppressed=(), allowed=(True, True)):
        row = {**ROW, "body": "no footer"} if refused else {**ROW, "venture_id": venture_id}
        def get(path):
            if path.startswith("outbox"): return [row]
            if path.startswith("ventures"): return [{"slug": slug}] if slug else []
            if path.startswith("company_profile"): return [prof] if prof else []
            return [{"do_not_contact": False}]
        answers = list(allowed)
        def rpc(method, path, body=None, **k):          # the database RPCs (hq._request): is_suppressed, outreach_send_allowed
            if path.endswith("/rpc/is_suppressed"): return bool(suppressed)
            if path.endswith("/rpc/outreach_send_allowed"): return {"allowed": answers.pop(0) if answers else False}
            raise AssertionError(path)
        with mock.patch.dict(os.environ, ENV), mock.patch.object(M, "live", return_value=True), \
             mock.patch.object(M, "_get", side_effect=get), mock.patch.object(M.hq, "_request", side_effect=rpc), \
             mock.patch("hq_policy.authorize", return_value=Decision("send_email", decision, "r")), \
             mock.patch.object(M, "_claim", return_value=True), mock.patch.object(M, "_release"), \
             mock.patch.object(M, "_post", return_value=posted) as post, mock.patch.object(M, "_mark_sent") as mark:
            return M.deliver_approved(), post, mark

    def test_suppressed_address_is_never_posted_even_when_the_lead_row_is_clean(self):
        out, post, mark = self._run(suppressed=[{"address": "x@example.com"}])
        self.assertEqual((out["sent"], out["skipped"]), (0, 1)); post.assert_not_called(); mark.assert_not_called()

    def test_suppression_check_fails_closed(self):
        import urllib.error
        # PR #15 review: the check is the database's is_suppressed (plaintext AND hash-only); ANY error, a missing function included, is "suppressed"
        for exc in (RuntimeError("boom"), urllib.error.HTTPError("u", 500, "x", {}, None), urllib.error.HTTPError("u", 404, "x", {}, None), TimeoutError()):
            with mock.patch.object(M.hq, "_request", side_effect=exc):
                self.assertTrue(M.suppressed("a@b.co"), repr(exc))
        for odd in (None, "false", 0, {}, []):
            with mock.patch.object(M.hq, "_request", return_value=odd):
                self.assertTrue(M.suppressed("a@b.co"), repr(odd))
        with mock.patch.object(M.hq, "_request", return_value=False) as rq:
            self.assertFalse(M.suppressed("a@b.co")); self.assertFalse(M.suppressed(""))
            self.assertEqual(rq.call_args[0][:2], ("POST", "/rest/v1/rpc/is_suppressed"))
        with mock.patch.object(M.hq, "_request", return_value=True):
            self.assertTrue(M.suppressed("a@b.co")); self.assertTrue(M.suppressed("not an address"))

    def test_sends_and_marks(self):
        out, post, mark = self._run()
        self.assertEqual(out["sent"], 1); post.assert_called_once(); mark.assert_called_once()

    def test_policy_deny_or_ask_skips(self):
        for d in ("deny", "ask_owner"):
            out, post, mark = self._run(decision=d)
            self.assertEqual((out["sent"], out["skipped"]), (0, 1)); post.assert_not_called(); mark.assert_not_called()

    def test_provider_failure_leaves_approved(self):
        out, post, mark = self._run(posted=False)
        self.assertEqual((out["failed"], out["sent"]), (1, 0)); mark.assert_not_called()

    def test_missing_footer_never_posted(self):
        out, post, mark = self._run(refused=True)
        self.assertEqual(out["skipped"], 1); post.assert_not_called()

    def test_new_venture_without_profile_is_never_sent(self):
        for prof in (None, {"mailing_address": "1 Main St, Ottawa ON"}, {"brand": "B", "sender_name": "S"}):
            out, post, mark = self._run(slug="new-venture", prof=prof)
            self.assertEqual((out["sent"], out["skipped"]), (0, 1)); post.assert_not_called(); mark.assert_not_called()

    def test_new_venture_with_full_profile_sends_only_with_its_own_address(self):
        mine = {"sender_name": "Moe", "brand": "Cleanouts", "mailing_address": "9 Elm St, Ottawa ON"}
        out, post, mark = self._run(slug="new-venture", prof=mine)           # body carries Donna's address, not this venture's
        self.assertEqual((out["sent"], out["skipped"]), (0, 1)); post.assert_not_called()
        mine2 = {**mine, "mailing_address": "1 Main St, Ottawa ON"}          # body's address now matches this venture's profile
        out, post, mark = self._run(slug="new-venture", prof=mine2)
        self.assertEqual(out["sent"], 1)

    def test_draft_without_a_venture_is_never_sent(self):
        out, post, mark = self._run(slug=None)
        self.assertEqual((out["sent"], out["skipped"]), (0, 1)); post.assert_not_called()

    def test_donna_without_address_is_never_sent(self):
        out, post, mark = self._run(slug="donna", prof={"sender_name": "Moe"})
        self.assertEqual((out["sent"], out["skipped"]), (0, 1)); post.assert_not_called()

    def test_profile_rules(self):
        with mock.patch.object(M, "_get", return_value=[{"mailing_address": "1 Main St"}]):
            self.assertEqual(M.profile("donna"), {"sender_name": "Moe", "brand": "The Donna System", "mailing_address": "1 Main St"})  # donna defaults
            self.assertIsNone(M.profile("other"))                                  # no defaults for anyone else
            self.assertIsNone(M.profile(None))
        with mock.patch.object(M, "_get", return_value=[{"sender_name": "S", "brand": "B", "mailing_address": M.PLACEHOLDER}]):
            self.assertIsNone(M.profile("other"))
        with mock.patch.object(M, "_get", return_value=[{"sender_name": "S", "brand": "B", "mailing_address": "2 Elm St"}]):
            f = M.footer("other")
            self.assertIn("S, B\n2 Elm St", f); self.assertIn("unsubscribe", f)
        with mock.patch.object(M, "_get", return_value=[]):
            with self.assertRaises(M.ProfileMissing): M.footer("other")

    # ---- PR #15 review finding 2: the sender asks the database before the claim and again right before the provider call ----
    def test_gate_closed_after_approval_no_claim_no_provider_call(self):
        out, post, mark = self._run(allowed=(False,))
        post.assert_not_called(); mark.assert_not_called()

    def test_send_allowed_is_strictly_a_yes(self):
        for reply in ({"allowed": False}, {"allowed": "true"}, {"allowed": 1}, {}, None, "ok", [], [{"allowed": False}], [{"allowed": True}, {"allowed": True}]):
            with mock.patch.object(M.hq, "_request", return_value=reply):
                self.assertFalse(M.send_allowed("a1"), repr(reply))
        import urllib.error
        for exc in (RuntimeError("x"), urllib.error.HTTPError("u", 404, "x", {}, None), urllib.error.HTTPError("u", 500, "x", {}, None), TimeoutError()):
            with mock.patch.object(M.hq, "_request", side_effect=exc):
                self.assertFalse(M.send_allowed("a1"), repr(exc))
        with mock.patch.object(M.hq, "_request", return_value={"allowed": True, "reason": "ok"}) as rq:
            self.assertTrue(M.send_allowed("a1"))
            self.assertEqual(rq.call_args[0][:3], ("POST", "/rest/v1/rpc/outreach_send_allowed", {"p_outbox": "a1"}))
        with mock.patch.object(M.hq, "_request", return_value=[{"allowed": True}]):
            self.assertTrue(M.send_allowed("a1"))

    def test_claim_asks_before_it_patches(self):
        with mock.patch.object(M, "send_allowed", return_value=False), mock.patch.object(M.hq, "_request") as rq:
            self.assertFalse(M._claim(ROW)); rq.assert_not_called()          # not even the PATCH is attempted
        with mock.patch.object(M, "send_allowed", return_value=True), mock.patch.object(M.hq, "_request", return_value=[{"id": "a1"}]) as rq:
            self.assertTrue(M._claim(ROW)); self.assertEqual(rq.call_args[0][0], "PATCH")

    def test_gate_closes_between_claim_and_post_claim_is_released_and_nothing_is_posted(self):
        out, post, mark = self._run(allowed=(False,))     # (the claim is stubbed here, so this is the check IMMEDIATELY before the provider call; the HTTP-level test below runs both)
        post.assert_not_called(); mark.assert_not_called()
        self.assertEqual((out["sent"], out["failed"]), (0, 1))

    def test_hash_only_suppression_is_honoured(self):
        out, post, mark = self._run(suppressed=[True])         # is_suppressed answers true (hash-only entries never appear in contact_suppressions)
        post.assert_not_called(); self.assertEqual(out["skipped"], 1)

    def test_end_to_end_over_the_http_layer_gate_closed_means_zero_provider_calls(self):
        """No mock of hq_mail internals: a fake HTTP layer stands in for PostgREST and for the email provider. With the gate closed after approval the claim is refused
        and the provider endpoint is never contacted; with it open exactly one provider call happens; closing it between the claim and the POST also gives zero."""
        import io, json, urllib.request
        class Resp(io.BytesIO):
            status = 200
            def __enter__(s): return s
            def __exit__(s, *a): return False
        def run(gate):
            provider, claims = [], []
            answers = list(gate)
            def urlopen(req, timeout=None):
                url, method = req.full_url, req.get_method()
                body = json.loads(req.data) if req.data else None
                if "api.resend.com" in url:
                    provider.append(url); return Resp(b'{"id":"x"}')
                path = url.split("supabase.test", 1)[1]
                if path.startswith("/rest/v1/system_state"): return Resp(json.dumps([{"mode": "live", "kill_switch": False}]).encode())
                if path.startswith("/rest/v1/outbox?status=eq.approved&channel=eq.email"): return Resp(json.dumps([ROW]).encode())
                if path.startswith("/rest/v1/outbox?id=eq.a1&status=eq.approved&sent_at=is.null"): claims.append(path); return Resp(json.dumps([{"id": "a1"}]).encode())
                if path.startswith("/rest/v1/outbox?id=eq.a1&status=eq.approved"): return Resp(b"")   # release / mark sent
                if path.endswith("/rpc/is_suppressed"): return Resp(b"false")
                if path.endswith("/rpc/outreach_send_allowed"): return Resp(json.dumps({"allowed": answers.pop(0) if answers else False}).encode())
                if path.startswith("/rest/v1/leads?id=eq.L1"): return Resp(json.dumps([{"do_not_contact": False}]).encode()) if method == "GET" else Resp(b"")
                if path.startswith("/rest/v1/ventures"): return Resp(json.dumps([{"slug": "donna"}]).encode())
                if path.startswith("/rest/v1/company_profile"): return Resp(json.dumps([PROF]).encode())
                if path.startswith("/rest/v1/audit_log"): return Resp(b"")
                raise AssertionError(f"unexpected {method} {path}")
            with mock.patch.dict(os.environ, ENV), mock.patch.object(M.hq, "HQ_SUPABASE_URL", "https://supabase.test"), mock.patch.object(urllib.request, "urlopen", urlopen), \
                 mock.patch("hq_policy.authorize", return_value=Decision("send_email", "allow", "r")):
                out = M.deliver_approved()
            return out, provider, claims
        out, provider, claims = run([False])
        self.assertEqual((provider, claims, out["sent"]), ([], [], 0))        # gate closed after approval: no claim, NO provider call
        out, provider, claims = run([True, False])
        self.assertEqual((len(provider), out["sent"]), (0, 0))                # closed mid-flow: claimed, then released, still no provider call
        out, provider, claims = run([True, True])
        self.assertEqual((len(provider), len(claims)), (1, 1))                # open: exactly one provider call

    def test_never_raises(self):
        with mock.patch.dict(os.environ, ENV), mock.patch.object(M, "live", side_effect=RuntimeError("db down")):
            self.assertEqual(M.deliver_approved()["reason"], "RuntimeError")


if __name__ == "__main__":
    unittest.main()
