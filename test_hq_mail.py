import os, unittest
from unittest import mock
import hq_mail as M
from hq_policy import Decision

GOOD = "Hi\n\nSent by Moe, The Donna System, 1 Main St, Ottawa ON.\nTo stop receiving emails from us, reply \"unsubscribe\"."
ROW = {"id": "a1", "to_ref": "x@example.com", "body": GOOD, "lead_id": "L1", "agent": "donna-ops"}
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

    def _run(self, decision="allow", posted=True, refused=False):
        row = {**ROW, "body": "no footer"} if refused else ROW
        with mock.patch.dict(os.environ, ENV), mock.patch.object(M, "live", return_value=True), \
             mock.patch.object(M, "_get", side_effect=lambda path: [row] if path.startswith("outbox") else [{"do_not_contact": False}]), \
             mock.patch("hq_policy.authorize", return_value=Decision("send_email", decision, "r")), \
             mock.patch.object(M, "_post", return_value=posted) as post, mock.patch.object(M, "_mark_sent") as mark:
            return M.deliver_approved(), post, mark

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

    def test_never_raises(self):
        with mock.patch.dict(os.environ, ENV), mock.patch.object(M, "live", side_effect=RuntimeError("db down")):
            self.assertEqual(M.deliver_approved()["reason"], "RuntimeError")


if __name__ == "__main__":
    unittest.main()
