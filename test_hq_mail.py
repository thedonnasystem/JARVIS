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

    def _run(self, decision="allow", posted=True, refused=False, slug="donna", prof=PROF, venture_id="v1", suppressed=()):
        row = {**ROW, "body": "no footer"} if refused else {**ROW, "venture_id": venture_id}
        def get(path):
            if path.startswith("outbox"): return [row]
            if path.startswith("ventures"): return [{"slug": slug}] if slug else []
            if path.startswith("company_profile"): return [prof] if prof else []
            if path.startswith("contact_suppressions"): return suppressed
            return [{"do_not_contact": False}]
        with mock.patch.dict(os.environ, ENV), mock.patch.object(M, "live", return_value=True), \
             mock.patch.object(M, "_get", side_effect=get), \
             mock.patch("hq_policy.authorize", return_value=Decision("send_email", decision, "r")), \
             mock.patch.object(M, "_post", return_value=posted) as post, mock.patch.object(M, "_mark_sent") as mark:
            return M.deliver_approved(), post, mark

    def test_suppressed_address_is_never_posted_even_when_the_lead_row_is_clean(self):
        out, post, mark = self._run(suppressed=[{"address": "x@example.com"}])
        self.assertEqual((out["sent"], out["skipped"]), (0, 1)); post.assert_not_called(); mark.assert_not_called()

    def test_suppression_check_fails_closed(self):
        import urllib.error
        for exc in (RuntimeError("boom"), urllib.error.HTTPError("u", 500, "x", {}, None)):
            with mock.patch.object(M, "_get", side_effect=exc):
                self.assertTrue(M.suppressed("a@b.co"))
        with mock.patch.object(M, "_get", side_effect=urllib.error.HTTPError("u", 404, "x", {}, None)):
            self.assertFalse(M.suppressed("a@b.co"))  # migration not applied yet
        with mock.patch.object(M, "_get", return_value=[]):
            self.assertFalse(M.suppressed("a@b.co")); self.assertFalse(M.suppressed(""))

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

    def test_never_raises(self):
        with mock.patch.dict(os.environ, ENV), mock.patch.object(M, "live", side_effect=RuntimeError("db down")):
            self.assertEqual(M.deliver_approved()["reason"], "RuntimeError")


if __name__ == "__main__":
    unittest.main()
