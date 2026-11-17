"""Chairman briefing (first mission): plain code, addresses the Chairman as sir, every required section, needs listed by env NAME only."""
import unittest
from unittest import mock

import hq_briefing as B

DATA = {"status": {"daily_cap_cents": 330, "kill_switch": False, "mode": "dry_run"},
        "config": {"active_divisions": ["donna", "wolf-squad", "ffm"], "core_enabled": False},
        "departments": [{"slug": "donna", "name": "Donna", "status": "active"}],
        "agents": [{"slug": "donna-gm", "role": "gm"}, {"slug": "jarvis", "role": "owner_contact"}],
        "owner": [], "providers": [], "missing": [(("GROQ_API_KEY",), "a free model key")], "self_fund": {"pct": 0, "available_cents": 0}, "approvals": 1}


class BriefingTests(unittest.TestCase):
    def test_sections_and_sir(self):
        t = B.build(DATA)
        self.assertTrue(t.startswith("Good morning, sir."))
        for h in ("WHO I AM", "WHO YOU ARE", "WHAT I AM READY TO DO", "MY LIMITS", "MY STANDING OBJECTIVE: FUND MYSELF", "WHAT STILL NEEDS YOU, SIR"):
            self.assertIn(h, t)
        self.assertIn("Donna (AI automation agency, HVAC first)", t)
        self.assertIn("Wolf Squad", t)
        self.assertIn("I report to you, sir", t)
        self.assertIn("/seedmemory", t)                                     # not seeded yet
        self.assertIn("brain is offline", t)
        self.assertIn("set GROQ_API_KEY in Railway Variables", t)
        self.assertIn("confirm after bank reconciliation", t)
        self.assertIn("Approvals waiting: 1", t)

    def test_seeded_owner_profile_is_used(self):
        t = B.build({**DATA, "owner": ["Role: synthetic chairman"]})
        self.assertIn("- Role: synthetic chairman", t)
        self.assertNotIn("Not seeded yet", t)

    def test_gather_reads_names_never_values(self):
        env = {"GROQ_API_KEY": "secret-value-not-shown"}
        with mock.patch("hq._request", return_value=[]):
            d = B.gather(env)
        t = B.build(d)
        self.assertNotIn("secret-value-not-shown", t)
        self.assertIn("groq", d["providers"])

    def test_deliver_goes_through_the_telegram_channel(self):
        rows = []
        with mock.patch("hq._request", side_effect=lambda m, p, b=None, **k: rows.append((p, b))), mock.patch("hq.hq_enabled", return_value=True):
            r = B.deliver("Good morning, sir. test")
        self.assertTrue(r["ok"])
        self.assertEqual(rows[0][0], "/rest/v1/owner_messages")
        self.assertEqual(rows[0][1]["kind"], "brief")


if __name__ == "__main__":
    unittest.main()
