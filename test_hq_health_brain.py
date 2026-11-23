"""Unit tests for Phase 1 M6: /health (hq_health) and /brain (hq_brain), read-only."""

import asyncio
import unittest
from unittest import mock

import hq
import hq_brain
import hq_commands
import hq_health

HEALTH = {"overall": "warn", "alerts_enabled": False, "checks": [
    {"check": "ai_cap_day", "status": "ok", "used_cents": 150, "cap_cents": 2000, "headroom_cents": 1850},
    {"check": "spend_week", "status": "warn", "used_cents": 6500, "cap_cents": 7500, "headroom_cents": 1000},
    {"check": "kill_switch", "status": "warn", "on": True, "mode": "normal", "pause_reason": "owner pause"},
    {"check": "job_backlog", "status": "ok", "queued": 3, "overdue": 0, "stale_leases": 0},
    {"check": "failed_jobs", "status": "warn", "dead_24h": 2},
    {"check": "approval_backlog", "status": "ok", "pending": 1},
    {"check": "audit_chain", "status": "bad", "checked": 900, "breaks": 1, "gaps": 0},
    {"check": "security", "status": "warn", "standing": 4, "unexpected": 0, "definer_changed": 0}]}
BRAIN = {"facts": [{"topic": "policy", "fact": "Group-wide fact", "source": "owner", "confidence": 0.9, "created_by_office": "group", "scope": "group"}],
         "by_office": {"group": 1, "the-trap": 3}, "promotions_pending": 2, "jarvis_may_approve": False}


class HealthBrainTests(unittest.TestCase):
    def test_health_text(self):
        with mock.patch.object(hq, "_request", return_value=HEALTH) as rq:
            t = hq_health.health_text()
        self.assertEqual(rq.call_args[0][:2], ("POST", "/rest/v1/rpc/fz_health_report"))
        self.assertIn("Health: WARN (alerts off)", t)
        self.assertIn("OK AI cap today: $1.50 of $20.00 ($18.50 left)", t)
        self.assertIn("WARN Kill switch ON; mode normal (owner pause)", t)
        self.assertIn("BAD Audit chain: 900 links, 1 break(s), 0 gap(s)", t)
        self.assertIn("WARN Failed jobs (24h): 2", t)
        with mock.patch.object(hq, "_request", side_effect=RuntimeError("404")):
            self.assertIn("not installed", hq_health.health_text())

    def test_brain_text_and_query_is_trimmed(self):
        with mock.patch.object(hq, "_request", return_value=BRAIN) as rq:
            t = hq_brain.brain_text("  late   payers  " + "x" * 300)
        self.assertEqual(rq.call_args[0][:2], ("POST", "/rest/v1/rpc/fz_brain_report"))
        self.assertLessEqual(len(rq.call_args[0][2]["p_query"]), 100)
        self.assertTrue(rq.call_args[0][2]["p_query"].startswith("late payers"))
        self.assertIn("[policy] Group-wide fact (owner, conf 0.9, from group)", t)
        self.assertIn("Facts by office: group 1, the-trap 3", t)
        self.assertIn("Promotions waiting: 2", t)
        with mock.patch.object(hq, "_request", return_value=BRAIN) as rq:
            hq_brain.brain_text("")
        self.assertIsNone(rq.call_args[0][2]["p_query"])

    def test_brain_never_writes_and_never_calls_a_model(self):
        import ast
        for mod, rpc in ((hq_brain, "fz_brain_report"), (hq_health, "fz_health_report")):
            tree = ast.parse(open(mod.__file__).read())
            imports = {a.name for n in ast.walk(tree) if isinstance(n, (ast.Import, ast.ImportFrom)) for a in n.names} | \
                      {n.module for n in ast.walk(tree) if isinstance(n, ast.ImportFrom) and n.module}
            self.assertEqual(imports - {"annotations", "__future__", "logging", "re"}, {"hq"})       # no hq_llm, no other module
            calls = [n for n in ast.walk(tree) if isinstance(n, ast.Call) and getattr(n.func, "attr", "") == "_request"]
            self.assertEqual(len(calls), 1)
            self.assertEqual([a.value for a in calls[0].args[:2]], ["POST", f"/rest/v1/rpc/{rpc}"])

    def test_commands_owner_only_and_in_menu(self):
        for cmd, data in ((hq_commands.hq_health_cmd, HEALTH), (hq_commands.hq_brain_cmd, BRAIN)):
            upd = mock.MagicMock()
            with mock.patch.object(hq_commands, "_owner", return_value=False), mock.patch.object(hq_commands.hq_core, "reply_to", new=mock.AsyncMock()) as rep:
                asyncio.run(cmd(upd, mock.MagicMock(args=[])))
            rep.assert_not_called()
            with mock.patch.object(hq_commands, "_owner", return_value=True), mock.patch.object(hq_commands.hq_core, "reply_to", new=mock.AsyncMock()) as rep, \
                    mock.patch.object(hq, "_request", return_value=data):
                asyncio.run(cmd(upd, mock.MagicMock(args=["x"])))
            rep.assert_called_once()
        names = [m[0] for m in hq_commands.MENU]
        self.assertIn("health", names)
        self.assertIn("brain", names)


if __name__ == "__main__":
    unittest.main()
