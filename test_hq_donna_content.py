"""Tests for hq_donna_content (Donna Content v1)."""
import datetime as dt
import tempfile
import unittest

import hq_donna_content as C

MON = dt.datetime(2026, 11, 30, 9, 30, tzinfo=C.R.TZ)


class Plan(unittest.TestCase):
    def test_five_a_week_hook_pinned_and_rules_in_every_brief(self):
        p = C.plan(MON.date())
        self.assertEqual(len(p), 5)
        self.assertEqual(p[0]["theme"], "hook")
        self.assertIn("We turn your missed calls and missed leads into booked appointments.", p[0]["brief"])
        for x in p:
            self.assertIn("no statistics", x["brief"])
            self.assertIn("label AI-generated media", x["brief"])
            self.assertIn(x["module"], ("video", "image"))
        self.assertNotEqual([x["theme"] for x in C.plan(MON.date())], [x["theme"] for x in C.plan((MON + dt.timedelta(days=7)).date())], "rotates")

    def test_offer_dropped_after_the_deadline(self):
        for wk in range(6):
            day = dt.date(2027, 1, 4) + dt.timedelta(days=7 * wk)
            self.assertNotIn("audit-offer", [x["theme"] for x in C.plan(day)])


class Submit(unittest.TestCase):
    def test_off_not_due_and_once_a_week(self):
        self.assertIn("off", C.submit_week(rpc=lambda *a: self.fail("off"), env={}))
        with tempfile.TemporaryDirectory() as d:
            env = {"DONNA_CONTENT": "1", "DONNA_STATE_DIR": d}
            self.assertTrue(C.submit_week(rpc=lambda *a: self.fail("tuesday"), env=env, now=MON + dt.timedelta(days=1))["not_due"])
            got = []
            r = C.submit_week(rpc=lambda n, a: got.append((n, a)) or {"job": "J"}, env=env, now=MON)
            self.assertEqual(len(r["submitted"]), 5)
            self.assertTrue(all(n == "creative_submit" and a["p_office"] == "donna" and a["p_by"] == "donna:content" for n, a in got))
            self.assertTrue(C.submit_week(rpc=lambda *a: self.fail("twice"), env=env, now=MON + dt.timedelta(hours=3))["not_due"])

    def test_refusals_recorded(self):
        with tempfile.TemporaryDirectory() as d:
            def rpc(n, a):
                raise RuntimeError("refused: office donna is not active")
            r = C.submit_week(rpc=rpc, env={"DONNA_CONTENT": "1", "DONNA_STATE_DIR": d}, now=MON)
            self.assertEqual(len(r["refused"]), 5)
            self.assertTrue(C.due(MON, {"DONNA_STATE_DIR": d}), "nothing submitted, so it tries again")


if __name__ == "__main__":
    unittest.main()
