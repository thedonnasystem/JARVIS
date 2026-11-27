"""Tests for hq_donna_replies (Donna Replies v1). The provider API, database and Telegram are mocked; SQL rules: sqltests/donna_replies_check.sql."""
import unittest

import hq_donna_replies as P

LIST = {"data": [{"id": "rid-111111", "from": "Pat Lee <Pat@PinePlumbing.example>", "subject": "Re: Your free Revenue Leak Audit", "created_at": "2026-11-27T14:00:00Z"},
                 {"id": "rid-222222", "from": "hi@elm.example", "subject": "Re: Where is Elm Auto losing revenue?", "created_at": "2026-11-27T14:01:00Z"},
                 {"id": "rid-333333", "from": "news@spam.example", "subject": "Big sale", "created_at": "2026-11-27T14:02:00Z"},
                 {"id": "rid-old000", "from": "old@x.example", "subject": "Re: hi", "created_at": "2026-11-20T14:02:00Z"}]}
BODIES = {"rid-111111": "Yes, Thursday works.\n\nOn Wed, Nov 26, 2026 at 3:00 PM Donna.AI wrote:\n> To stop these emails, reply \"unsubscribe\".",
          "rid-222222": "Please remove me from your list.\n\nOn Wed wrote:\n> hi",
          "rid-333333": "Huge sale today"}


class Replies(unittest.TestCase):
    def test_sender_and_own_text(self):
        self.assertEqual(P.sender("Pat Lee <Pat@PinePlumbing.example>"), "pat@pineplumbing.example")
        self.assertEqual(P.sender({"email": "A@B.example"}), "a@b.example")
        self.assertEqual(P.own_text(BODIES["rid-111111"]), "Yes, Thursday works.")
        self.assertFalse(P.is_unsubscribe("Re: Your audit", P.own_text(BODIES["rid-111111"])), "our quoted footer never counts")
        self.assertTrue(P.is_unsubscribe("Re: x", P.own_text(BODIES["rid-222222"])))
        self.assertTrue(P.is_unsubscribe("Unsubscribe", ""))
        self.assertFalse(P.is_unsubscribe("Re: unsubscribe link broken?", "Thanks, interested"))

    def test_check(self):
        fetched, posted = [], []
        def rpc(name, args):
            if name == "donna_unseen_messages":
                return [i for i in args["p_ids"] if i != "rid-old000"]
            sender = args["p_from"]
            if sender == "pat@pineplumbing.example":
                self.assertFalse(args["p_unsubscribe"])
                return {"matched": True, "kind": "reply", "name": "Pine Plumbing", "short_id": 7}
            if sender == "hi@elm.example":
                self.assertTrue(args["p_unsubscribe"])
                return {"matched": True, "kind": "unsubscribe", "name": "Elm Auto", "short_id": 9}
            return {"matched": False}
        r = P.check(rpc=rpc, post=posted.append, list_fn=lambda n: LIST["data"], text_fn=lambda i: fetched.append(i) or BODIES[i])
        self.assertEqual((r["new"], r["replies"], r["unsubscribes"], r["unmatched"]), (3, 1, 1, 1))
        self.assertNotIn("rid-old000", fetched, "an already-seen message body is never fetched again")
        self.assertIn("Pine Plumbing (#7) replied: “Yes, Thursday works.”", posted[0])
        self.assertIn("Elm Auto (#9) asked to unsubscribe", posted[1])

    def test_off_without_key(self):
        import os
        from unittest import mock
        with mock.patch.dict(os.environ, {}, clear=False):
            os.environ.pop("RESEND_API_KEY", None)
            self.assertIn("off", P.check(rpc=lambda *a: self.fail("no key, no calls")))


if __name__ == "__main__":
    unittest.main()
