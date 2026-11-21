"""hq_office_os (Phase 1 M7): office template + 8 instances, /office <name>, prompts, shared-brain read scope."""
import asyncio
import json
import os
import re
import sys
import types
import unittest
from unittest import mock

import hq_office_os as O

ROOT = os.path.dirname(os.path.abspath(__file__))
MIG = open(os.path.join(ROOT, "migrations", "20261203_office_os_v1.sql")).read()
SEED = {m.group(2): {"id": m.group(1), "roles": re.findall(r"'([^']+)'", m.group(3)), "integrations": re.findall(r"'([^']+)'", m.group(4))}
        for m in re.finditer(r"\('(f0000000-[0-9a-f-]+)', '([a-z0-9-]+)', '.*?', array\[(.*?)\], array\[(.*?)\]", MIG)}
sys.path.insert(0, os.path.join(ROOT, "scripts"))
import check_integrations  # noqa: E402

PROFILE = {"office": "donna", "title": "Donna", "status": "active", "m1_status": "active", "drift": False, "manager": "Donna lead", "activation_rank": 1,
           "approval_status": "approved", "available_cents": 4950, "mission": "Run Donna, the AI agency.", "agent_roles": SEED.get("donna", {}).get("roles", []),
           "integrations": ["telegram"], "autonomy": {"green": ["research"], "yellow": [], "red": ["send_email"], "prohibited": ["email_without_consent"]},
           "confidentiality": "client_restricted", "prohibited_enforced": ["deceptive_communication"], "prohibited_advisory": ["email_without_consent"]}


class Template(unittest.TestCase):
    def test_seed_matches_m1_and_files(self):
        self.assertEqual(set(SEED), set(O.OFFICES))
        for slug, s in SEED.items():
            self.assertEqual(s["id"], O.OFFICES[slug])
            self.assertTrue(set(s["integrations"]) <= set(check_integrations.KEYS), slug)
            d = json.load(open(os.path.join(O.DIR, f"{slug}.json")))
            self.assertEqual(d["office"], slug)
            self.assertEqual(d["brain_scope"], ["group", slug])
            self.assertEqual(sorted(a["role"] for a in d["agents"]), sorted(s["roles"]), slug)   # every allowed role has exactly one core agent
            for a in d["agents"]:
                self.assertIn(a["model_tier"], ("small", "medium"))
                self.assertGreater(len(a["prompt"]), 40)
        self.assertEqual(sorted(f for f in os.listdir(O.DIR)), sorted(["TEMPLATE.json"] + [f"{s}.json" for s in O.OFFICES]))

    def test_no_personal_data_in_offices(self):
        blob = "".join(open(os.path.join(O.DIR, f)).read() for f in os.listdir(O.DIR)) + MIG
        self.assertIsNone(re.search(r"[\w.+-]+@[\w-]+\.[a-z]{2,}|(?<![\w-])\(?\d{3}\)?[ .-]\d{3}-\d{4}(?![\w-])", blob))

    def test_resolve(self):
        for k, v in {"Wolf Squad": "wolf-squad", "wolf": "wolf-squad", "FFM": "ff-marketing", "ff marketing": "ff-marketing", "B2B": "b2b-records",
                     "the trap": "the-trap", "donna": "donna", "Fruition Factory": "fruition-factory", "Pimp AI": "pimp-ai"}.items():
            self.assertEqual(O.resolve(k), v, k)
        self.assertIsNone(O.resolve("group"))
        self.assertIsNone(O.resolve("nowhere"))


class Status(unittest.TestCase):
    def test_text(self):
        calls = []
        t = O.status_text("Donna", rpc=lambda *a: calls.append(a) or PROFILE)
        self.assertEqual(calls, [("POST", "/rest/v1/rpc/office_os_status", {"p_office": "donna"})])
        for want in ("ACTIVE", "Manager: Donna lead", "$49.50", "Red: send_email", "advisory only: in prompts, not a database rule): email_without_consent", "enforced as office blocks on activation): deceptive_communication", "#1"):
            self.assertIn(want, t)
        self.assertNotIn("DRIFT", t)

    def test_drift_dormant_unknown_and_errors(self):
        t = O.status_text("wolf", rpc=lambda *a: dict(PROFILE, office="wolf-squad", status="dormant", manager=None, drift=True, m1_status="active", available_cents=None))
        self.assertTrue(t.startswith("!!! DRIFT ALERT: M1 says active but the office OS says dormant"))
        self.assertIn("office_os_deactivate('wolf-squad')", t)
        self.assertIn("none appointed (owner only)", t)
        self.assertIn("n/a", t)
        self.assertIn("To activate", t)
        self.assertTrue(O.status_text("nowhere", rpc=lambda *a: self.fail("called")).startswith("Unknown office"))
        self.assertIn("not installed", O.status_text("donna", rpc=mock.Mock(side_effect=RuntimeError("404"))))
        self.assertEqual(O.status_text("donna", rpc=lambda *a: dict(PROFILE, office="monopoly")), "Office status unreadable.")
        self.assertEqual(O.status_text("donna", rpc=lambda *a: [PROFILE]), "Office status unreadable.")


class Brain(unittest.TestCase):
    ROWS = [{"scope": "group", "fact": "group fact"}, {"scope": "donna", "fact": "donna fact"},
            {"scope": "wolf-squad", "fact": "wolf secret"}, {"fact": "no scope"}, "junk"]

    def test_flag_off_makes_no_request(self):
        calls = []
        with mock.patch.dict(os.environ, {}, clear=False):
            os.environ.pop(O.BRAIN_FLAG, None)
            self.assertEqual(O.brain_facts("donna", rpc=lambda *a: calls.append(a) or self.ROWS), [])
        with mock.patch.dict(os.environ, {O.BRAIN_FLAG: "yes"}):
            self.assertEqual(O.brain_facts("donna", rpc=lambda *a: calls.append(a) or self.ROWS), [])
        with mock.patch.dict(os.environ, {}, clear=False), mock.patch.object(O.hq, "_request", side_effect=AssertionError("called")):
            os.environ.pop(O.BRAIN_FLAG, None)
            self.assertEqual(O.brain_facts("donna"), [])
        self.assertEqual(calls, [])

    def test_rpc_and_scope(self):
        self.assertEqual(O.brain_scope("donna"), ["group", "donna"])
        with self.assertRaises(ValueError):
            O.brain_scope("group")
        seen = []
        with mock.patch.dict(os.environ, {O.BRAIN_FLAG: "1"}):
            got = O.brain_facts("donna", query="leads", limit=500, rpc=lambda m, p, b: seen.append((m, p, b)) or self.ROWS)
        self.assertEqual([r["fact"] for r in got], ["group fact", "donna fact"])           # another office's fact is dropped even if the database returned it
        self.assertEqual(seen, [("POST", "/rest/v1/rpc/fz_brain_read", {"p_query": "leads", "p_limit": 50})])
        with mock.patch.dict(os.environ, {O.BRAIN_FLAG: "1"}):
            O.brain_facts("donna", limit=0, rpc=lambda m, p, b: seen.append(b) or [])
            self.assertEqual(seen[-1], {"p_query": None, "p_limit": 1})
            self.assertEqual(O.brain_facts("donna", rpc=mock.Mock(side_effect=RuntimeError("x"))), [])
            self.assertEqual(O.brain_facts("donna", rpc=lambda *a: {"error": "x"}), [])

    def test_reads_through_the_office_identity(self):
        with mock.patch.dict(os.environ, {O.BRAIN_FLAG: "1"}), mock.patch.object(O.hq, "_request", return_value=self.ROWS) as rq:
            got = O.brain_facts("wolf")
        rq.assert_called_once_with("POST", "/rest/v1/rpc/fz_brain_read", {"p_query": None, "p_limit": 20}, identity="office:wolf-squad:manager")
        self.assertEqual([r["fact"] for r in got], ["group fact", "wolf secret"])

    def test_prompt(self):
        p = O.system_prompt(PROFILE, "client-success", facts=self.ROWS)
        for want in ("client-success agent of Donna", "Run Donna, the AI agency.", "(red): send_email", "(prohibited): email_without_consent", "donna fact", "group fact"):
            self.assertIn(want, p)
        self.assertNotIn("wolf secret", p)
        with self.assertRaises(ValueError):
            O.system_prompt(PROFILE, "prospector")            # a Wolf Squad role is not allowed in Donna
        with self.assertRaises(ValueError):                    # defined in offices/donna.json but not allowed by the database profile
            O.system_prompt(dict(PROFILE, agent_roles=["agency-manager"]), "client-success")
        with self.assertRaises(ValueError):
            O.system_prompt(dict(PROFILE, office="group"), "client-success")


class Command(unittest.TestCase):
    def run_cmd(self, args, owner=True):
        import hq_commands
        out = []
        upd = types.SimpleNamespace(message=object())
        with mock.patch.object(hq_commands, "_owner", return_value=owner), \
             mock.patch.object(hq_commands.hq_core, "reply_to", new=mock.AsyncMock(side_effect=lambda m, t: out.append(t))), \
             mock.patch.object(hq_commands.hq_office, "office_text", return_value="CORPORATE"), \
             mock.patch.object(O, "status_text", return_value="OFFICE STATUS") as st:
            asyncio.run(hq_commands.hq_office_cmd(upd, types.SimpleNamespace(args=args)))
        return out, st

    def test_office_name_and_plain(self):
        out, st = self.run_cmd(["wolf", "squad"])
        self.assertEqual(out, ["OFFICE STATUS"])
        st.assert_called_once_with("wolf squad")
        out, st = self.run_cmd([])
        self.assertEqual(out, ["CORPORATE"])
        st.assert_not_called()
        out, st = self.run_cmd(["donna"], owner=False)
        self.assertEqual(out, [])

    def test_module_never_calls_an_owner_function_or_writes(self):
        src = open(O.__file__).read()
        self.assertEqual(sorted(set(re.findall(r"/rpc/(\w+)", src))), ["fz_brain_read", "office_os_status"])
        for bad in ("fz_owner_", "\"PATCH\"", "\"DELETE\"", "\"PUT\""):
            self.assertNotIn(bad, src)


if __name__ == "__main__":
    unittest.main()
