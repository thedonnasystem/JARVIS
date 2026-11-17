"""hq_core (identity, quiet hours, worker, daily report, self-automation) and hq_seed (memory import). No network: HQ is mocked."""
import json
import unittest
from datetime import datetime
from unittest import mock
from zoneinfo import ZoneInfo

import hq_core as C
import hq_seed as S

TZ = ZoneInfo("America/Toronto")


def at(y, mo, d, h, mi=0):
    return datetime(y, mo, d, h, mi, tzinfo=TZ)


class IdentityTests(unittest.TestCase):
    def test_identity_says_sir(self):
        self.assertIn('address the Chairman as "sir"', C.IDENTITY)
        self.assertIn("fund yourself", C.IDENTITY)

    def test_address(self):
        self.assertEqual(C.address("Queue full."), "Sir, Queue full.")
        self.assertEqual(C.address("Good morning, sir. x"), "Good morning, sir. x")


class QuietHoursTests(unittest.TestCase):
    # Mon Nov 16 2026 is a Monday
    def test_night_emergencies_only(self):
        for h in (22, 23, 0, 3, 6):
            self.assertTrue(C.notify_allowed("critical", at(2026, 11, 16, h)))
            self.assertFalse(C.notify_allowed("urgent", at(2026, 11, 16, h)))
            self.assertFalse(C.notify_allowed("normal", at(2026, 11, 16, h)))

    def test_weekday_work_hours_urgent_only(self):
        self.assertTrue(C.notify_allowed("urgent", at(2026, 11, 16, 9)))
        self.assertFalse(C.notify_allowed("normal", at(2026, 11, 16, 9)))
        self.assertFalse(C.notify_allowed("low", at(2026, 11, 16, 16, 59)))
        self.assertTrue(C.notify_allowed("normal", at(2026, 11, 16, 17)))
        self.assertTrue(C.notify_allowed("normal", at(2026, 11, 16, 7, 30)))

    def test_weekend_daytime_anything(self):
        self.assertTrue(C.notify_allowed("low", at(2026, 11, 21, 10)))     # Saturday

    def test_next_allowed(self):
        self.assertEqual(C.next_allowed("normal", at(2026, 11, 16, 23, 10)), at(2026, 11, 17, 7, 0))
        self.assertEqual(C.next_allowed("normal", at(2026, 11, 17, 9, 0)), at(2026, 11, 17, 17, 0))
        self.assertEqual(C.next_allowed("critical", at(2026, 11, 17, 3, 0)), at(2026, 11, 17, 3, 0))

    def test_send_owner_holds_and_addresses_sir(self):
        rows = []
        with mock.patch("hq._request", side_effect=lambda m, p, b=None, **k: rows.append((p, b))):
            r = C.send_owner("report ready", "normal", now=at(2026, 11, 16, 10))
        self.assertEqual(rows[0][0], "/rest/v1/owner_messages")
        self.assertTrue(r["body"].startswith("Sir, "))
        self.assertIn("deliver_after", r)                                  # held until 17:00
        self.assertTrue(r["deliver_after"].startswith("2026-11-16T22:00"))  # 17:00 Toronto = 22:00 UTC


class WorkerTests(unittest.TestCase):
    def test_worker_runs_and_reports_each_job(self):
        done = []
        jobs = [{"id": "j1", "kind": "report.daily", "division": "donna", "payload": {}}, {"id": "j2", "kind": "unknown.kind", "division": "ffm", "payload": {}}]
        with mock.patch.object(C, "daily_report", return_value="Good morning, sir."), mock.patch.object(C, "send_owner"):
            n = C.worker_once(lease=lambda: jobs, finish=lambda j, ok, err, c, ai: done.append((j["id"], ok, err)),
                              wake=lambda a, j, r: None, sleep=lambda a, r, d, c: None, lease_more=lambda div: [])
        self.assertEqual(n, 2)
        self.assertEqual(done[0], ("j1", True, None))
        self.assertFalse(done[1][1]); self.assertIn("no handler", done[1][2])

    def test_agents_wake_for_a_job_drain_their_queue_and_sleep(self):
        log = []
        more = {"donna": [[{"id": "j2", "kind": "lead.research", "division": "donna", "payload": {"prompt": "x"}}], []]}
        first = [{"id": "j1", "kind": "lead.research", "division": "donna", "payload": {"prompt": "x", "reason": "owner asked for leads"}},
                 {"id": "j9", "kind": "report.daily", "division": "donna", "payload": {}}]
        with mock.patch.object(C, "_ai_job", return_value={"cents": 0, "ai": True}), mock.patch.object(C, "daily_report", return_value="Good morning, sir."), \
             mock.patch.object(C, "send_owner"):
            n = C.worker_once(lease=lambda: first, finish=lambda j, ok, err, c, ai: log.append(("finish", j["id"], ok)),
                              wake=lambda a, j, r: log.append(("wake", a, j["id"], r)), sleep=lambda a, r, d, c: log.append(("sleep", a, r, d)),
                              lease_more=lambda div: more[div].pop(0))
        self.assertEqual(n, 3)
        self.assertEqual(log[0], ("wake", "donna-gm", "j1", "lead.research: owner asked for leads"))
        self.assertEqual([e for e in log if e[0] == "sleep"], [("sleep", "donna-gm", "queue empty", 2)])
        self.assertIn(("finish", "j9", True), log)                       # Jarvis's own plain-code job: no wake
        self.assertEqual(sum(1 for e in log if e[0] == "wake"), 1)

    def test_no_progress_puts_the_agent_back_to_sleep(self):
        log = []
        jobs = [{"id": f"j{i}", "kind": "lead.research", "division": "ffm", "payload": {"prompt": "x"}} for i in range(5)]
        with mock.patch.object(C, "_ai_job", side_effect=RuntimeError("bad")):
            C.worker_once(lease=lambda: jobs[:1], finish=lambda *a: None, wake=lambda a, j, r: log.append("wake"),
                          sleep=lambda a, r, d, c: log.append(("sleep", r, d)), lease_more=lambda div: [jobs.pop()])
        self.assertEqual(log, ["wake", ("sleep", "no progress", 0)])

    def test_handler_crash_is_a_failure_not_a_crash(self):
        C.HANDLERS["test.boom"] = lambda job: 1 / 0
        try:
            ok, err, cents, ai = C.run_job({"id": "x", "kind": "test.boom"})
        finally:
            C.HANDLERS.pop("test.boom")
        self.assertFalse(ok); self.assertIn("ZeroDivisionError", err)

    def test_exhausted_providers_mean_retry_later(self):
        import hq_llm
        C.HANDLERS["test.ai"] = lambda job: (_ for _ in ()).throw(hq_llm.AllProvidersExhausted("full"))
        try:
            ok, err, _, _ = C.run_job({"id": "x", "kind": "test.ai"})
        finally:
            C.HANDLERS.pop("test.ai")
        self.assertFalse(ok); self.assertIn("retried later", err)

    def test_nothing_runs_when_the_database_hands_out_nothing(self):
        self.assertEqual(C.worker_once(lease=lambda: [], finish=lambda *a: self.fail("finished"), wake=lambda *a: self.fail("woke")), 0)


REPORT = {"day": "2026-11-15", "spend_cents": 0, "cap_cents": 330, "revenue_cents": 12500, "expense_cents": 2000, "cost_per_division": {"donna": 0},
          "missions": {"running": 1}, "missions_active": ["Chairman briefing"], "approvals_waiting": 2, "jobs": {"done": 4},
          "changelog": [{"kind": "self_edit_merge", "summary": "merged #12"}], "kill_switch": False,
          "wakes": {"donna-gm": {"wakes": 2, "sleeps": 2, "jobs": 3, "cost_cents": 0, "reasons": ["lead.research: owner asked"]}},
          "self_fund": {"confirmed_revenue_cents": 0, "pct": 0, "available_cents": 0, "paid_allowed": False}, "capital": {"available_cents": 30000, "bank_as_of": None}}


class ReportTests(unittest.TestCase):
    def test_daily_report_template_says_sir_and_has_every_section(self):
        t = C.format_daily_report(REPORT)
        self.assertTrue(t.startswith("Good morning, sir."))
        for want in ("revenue $125.00", "costs $20.00", "net $105.00", "Runway:", "Self-funding:", "would buy", "Cost per division: donna $0.00",
                     "Missions: running 1", "Approvals waiting for you: 2", "Changelog: [self_edit_merge] merged #12", "running on the free stack",
                     "donna-gm woke 2x, slept 2x, 3 jobs", "only I am always on"):
            self.assertIn(want, t)
        self.assertNotIn("kill switch is ON", t)

    def test_kill_switch_line(self):
        self.assertIn("The kill switch is ON.", C.format_daily_report({**REPORT, "kill_switch": True}))


class AutomationTests(unittest.TestCase):
    def test_off_lists_candidates_only(self):
        calls = []

        def req(m, p, b=None, **k):
            calls.append(p)
            if p.endswith("jarvis_automation_candidates"):
                self.assertIn("money", b["p_protected"])
                return [{"task_class": "lead.followup", "runs": 40}]
            if p.endswith("jarvis_core_status"):
                return {"config": {"self_automation_enabled": False}}
            raise AssertionError(p)
        with mock.patch("hq._request", side_effect=req):
            rows = C.automation_scan(draft=lambda r: self.fail("drafted while off"))
        self.assertEqual(rows[0]["task_class"], "lead.followup")

    def test_on_drafts_and_marks(self):
        marked = []

        def req(m, p, b=None, **k):
            if p.endswith("jarvis_automation_candidates"):
                return [{"task_class": "lead.followup", "runs": 40}]
            if p.endswith("jarvis_core_status"):
                return {"config": {"self_automation_enabled": True}}
            if p.endswith("jarvis_mark_automation"):
                marked.append(b); return None
            raise AssertionError(p)
        with mock.patch("hq._request", side_effect=req):
            C.automation_scan(draft=lambda r: "https://example.invalid/pr/1")
        self.assertEqual(marked[0]["p_state"], "drafted")


class SeedTests(unittest.TestCase):
    SAMPLE = """---
title: synthetic
---
# Role
- Synthetic chairman of a test holding company
- Runs **three** test ventures ([link](https://example.invalid))

## Style
Prefers short bullet answers.

```
code block: ignored
```
| a | b |
<!-- hidden note -->
https://example.invalid/only-a-link
1. [x] Approves builds himself
"""

    def test_parse(self):
        items = S.parse_markdown(self.SAMPLE)
        self.assertEqual(items, [{"section": "Role", "content": "Synthetic chairman of a test holding company"},
                                 {"section": "Role", "content": "Runs three test ventures (link)"},
                                 {"section": "Style", "content": "Prefers short bullet answers."},
                                 {"section": "Style", "content": "Approves builds himself"}])

    def test_import_sends_items_and_hash_only(self):
        got = {}
        r = S.import_bytes(self.SAMPLE.encode(), rpc=lambda a: got.update(a) or {"added": 4, "duplicates": 0, "rejected": 0})
        self.assertEqual(r["added"], 4)
        self.assertRegex(got["p_file_sha256"], r"^[0-9a-f]{64}$")
        self.assertEqual(len(got["p_items"]), 4)
        with self.assertRaises(ValueError):
            S.import_bytes(b"x" * (S.MAX_BYTES + 1), rpc=lambda a: {})


if __name__ == "__main__":
    unittest.main()


class SirEverywhereTests(unittest.TestCase):
    def test_chat_engine_and_call_prompts_say_sir(self):
        import pathlib
        root = pathlib.Path(__file__).resolve().parent
        self.assertIn('Always address the user (the Chairman) as "sir".', (root / "bot.py").read_text())
        self.assertIn('addresses him as "sir"', (root / "hq_engine.py").read_text())
        self.assertIn("sir", json.loads((root / "ops" / "CRITICAL_EVENTS.json").read_text())["script"].lower())


if __name__ == "__main__":
    unittest.main()
