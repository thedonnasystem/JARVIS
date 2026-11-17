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

    def test_import_stages_items_and_hash_only(self):
        got = {}
        r = S.import_bytes(self.SAMPLE.encode(), rpc=lambda a: got.update(a) or "stage-1")
        self.assertEqual((r["stage"], r["items"], r["dropped"]), ("stage-1", 4, 0))
        self.assertRegex(got["p_file_sha256"], r"^[0-9a-f]{64}$")
        self.assertEqual(len(got["p_items"]), 4)
        self.assertNotIn("p_actor", got)                       # the bot cannot claim to be the owner: it only stages
        with self.assertRaises(ValueError):
            S.import_bytes(b"x" * (S.MAX_BYTES + 1), rpc=lambda a: {})

    def test_items_beyond_the_limit_are_reported(self):
        raw = "\n".join(f"- synthetic item number {i}" for i in range(601)).encode()
        r = S.import_bytes(raw, rpc=lambda a: "s")
        self.assertEqual((r["items"], r["dropped"]), (500, 101))


class SirEverywhereTests(unittest.TestCase):
    """Chairman instruction: every owner-facing reply path says "sir" through ONE helper (hq_core.address via reply_to / send_to / deliver_owner_messages)."""
    def test_no_raw_reply_paths_left(self):
        import pathlib
        import re
        root = pathlib.Path(__file__).resolve().parent
        for f in ("bot.py", "hq_commands.py", "hq_core.py"):
            t = (root / f).read_text()
            raw = [m.group(0) for m in re.finditer(r"(?<!def )\b(?:update|query)\.message\.reply_text\(|context\.bot\.send_message\(", t)]
            self.assertEqual(raw, [], f)
        self.assertIn("hq_core.address(format_owner_message(msg))", (root / "hq.py").read_text())

    def test_helpers_address_only_the_owner_chat(self):
        import asyncio

        class Msg:
            def __init__(self, cid):
                self.chat, self.sent = type("C", (), {"id": cid})(), []

            async def reply_text(self, text, **kw):
                self.sent.append(text)

        class Bot:
            def __init__(self):
                self.sent = []

            async def send_message(self, cid, text, **kw):
                self.sent.append((cid, text))
        with mock.patch.dict("os.environ", {"JARVIS_OWNER_ID": "42"}):
            m, o, b = Msg(42), Msg(7), Bot()
            asyncio.run(C.reply_to(m, "Queue full.")); asyncio.run(C.reply_to(o, "Not for you."))
            asyncio.run(C.send_to(b, 42, "Done.")); asyncio.run(C.send_to(b, 7, text="Hello."))
        self.assertEqual(m.sent, ["Sir, Queue full."]); self.assertEqual(o.sent, ["Not for you."])
        self.assertEqual(b.sent, [(42, "Sir, Done."), (7, "Hello.")])
        self.assertEqual(C.address(""), "Sir.")

    def test_chat_engine_and_call_prompts_say_sir(self):
        import pathlib
        root = pathlib.Path(__file__).resolve().parent
        self.assertIn('Always address the user (the Chairman) as "sir".', (root / "bot.py").read_text())
        self.assertIn('addresses him as "sir"', (root / "hq_engine.py").read_text())
        self.assertIn("sir", json.loads((root / "ops" / "CRITICAL_EVENTS.json").read_text())["script"].lower())


if __name__ == "__main__":
    unittest.main()


class AiJobRoutingTests(unittest.TestCase):
    def test_job_sources_drive_routing_and_the_lease_is_extended(self):
        import hq_llm
        seen, rpcs = {}, []

        def fake_cached(system, msgs, **kw):
            seen.update(kw)
            kw["on_attempt"]()
            return {"text": "ok", "cents": 0}
        with mock.patch.object(hq_llm, "retrieve_memory", return_value=(["a fact"], ["memory:fact"])), \
                mock.patch.object(hq_llm, "cached_complete", side_effect=fake_cached), mock.patch.object(C, "_rpc", side_effect=lambda n, a=None: rpcs.append(n)):
            C._ai_job({"id": "j1", "kind": "lead.followup", "division": "donna", "payload": {"prompt": "hi", "contains_client_data": False}})
        self.assertEqual(seen["sources"], ["identity", "job:lead.followup", "memory:fact"])
        self.assertEqual(seen["tier"], "small")
        self.assertEqual(rpcs, ["jarvis_extend_lease"])
        self.assertGreater(C.LEASE_SECONDS, 600)                  # longer than the slowest provider timeout

    def test_release_check_opens_the_revert_for_the_owner(self):
        posted = []
        import hq_selfedit
        with mock.patch.object(C, "core_status", return_value={"error": "down"}), mock.patch("hq._request", side_effect=lambda *a, **k: posted.append(a)), \
                mock.patch.object(hq_selfedit.time, "sleep") as slept:
            C.HANDLERS["release.check"]({"payload": {"previous_sha": "d" * 40}})
        self.assertEqual(slept.call_count, 2)
        bodies = [a[2] for a in posted if a[1] == "/rest/v1/owner_messages"]
        self.assertTrue(any(b.get("needs_decision") and "d" * 12 in b["body"] for b in bodies), posted)


class TelegramLimitTests(unittest.TestCase):
    """R1: "Sir, " is added once, before splitting, so no piece exceeds Telegram's 4,096 characters; only the first piece carries it.
    SF7: status edits and button pop-ups are addressed too and stay inside their limits."""
    def _send(self, text):
        import asyncio

        class Msg:
            def __init__(self):
                self.chat, self.sent, self.kws = type("C", (), {"id": 42})(), [], []

            async def reply_text(self, t, **kw):
                self.sent.append(t); self.kws.append(kw)
                return len(self.sent)

        class Bot:
            def __init__(self):
                self.sent, self.kws = [], []

            async def send_message(self, cid, t, **kw):
                self.sent.append(t); self.kws.append(kw)
        with mock.patch.dict("os.environ", {"JARVIS_OWNER_ID": "42"}):
            m, b = Msg(), Bot()
            first = asyncio.run(C.reply_to(m, text, reply_markup="KB"))
            asyncio.run(C.send_to(b, 42, text, reply_markup="KB"))
        self.assertEqual(first, 1)
        self.assertEqual(m.sent, b.sent)
        self.assertEqual([bool(k) for k in m.kws], [False] * (len(m.sent) - 1) + [True])     # buttons only on the last piece
        return m.sent

    def test_lengths(self):
        for n in (4095, 4096, 5000, 9000):
            for body in ("x" * n, "Sir, " + "y" * (n - 5)):
                sent = self._send(body)
                self.assertTrue(all(len(p) <= 4096 for p in sent), (n, [len(p) for p in sent]))
                self.assertEqual("".join(sent), C.address(body))                      # nothing lost, nothing added twice
                self.assertTrue(sent[0].startswith("Sir, "))
                self.assertEqual(sum(p.startswith("Sir, ") for p in sent), 1, n)      # only the first piece is prefixed
        self.assertEqual([len(p) for p in self._send("x" * 4095)], [4096, 4])
        self.assertEqual([len(p) for p in self._send("x" * 5000)], [4096, 909])
        self.assertEqual([len(p) for p in self._send("x" * 9000)], [4096, 4096, 813])
        self.assertEqual([len(p) for p in self._send("x" * 4091)], [4096])

    def test_not_owner_chat_is_split_but_not_addressed(self):
        self.assertEqual([len(p) for p in C.parts_for(7, "z" * 9000)], [4096, 4096, 808])

    def test_status_edits_and_popups(self):
        import asyncio

        class Status:
            async def edit_text(self, t, **kw):
                self.t = t

        class Query:
            def __init__(self):
                self.message = type("M", (), {"chat": type("C", (), {"id": 42})()})()

            async def edit_message_text(self, t, **kw):
                self.t = t
        with mock.patch.dict("os.environ", {"JARVIS_OWNER_ID": "42"}):
            s, q = Status(), Query()
            asyncio.run(C.edit_to(s, 42, "Starting..."))
            self.assertEqual(s.t, "Sir, Starting...")
            asyncio.run(C.edit_to(s, 42, "w" * 5000))
            self.assertEqual(len(s.t), 4096)
            asyncio.run(C.edit_callback(q, "Cancelled - no changes were made."))
            self.assertEqual(q.t, "Sir, Cancelled - no changes were made.")
            self.assertEqual(C.popup_for(42, "Saved."), "Sir, Saved.")
            self.assertEqual(len(C.popup_for(42, "p" * 400)), C.POPUP_LIMIT)
            self.assertEqual(C.popup_for(7, "Saved."), "Saved.")

    def test_no_per_chunk_prefix_left_in_the_bot(self):
        import pathlib
        root = pathlib.Path(__file__).resolve().parent
        bot = (root / "bot.py").read_text()
        self.assertNotRegex(bot, r"for chunk in split_for_telegram\([^)]*\):\s*\n\s*await hq_core\.(reply_to|send_to)")
        self.assertNotIn("query_cb.edit_message_text(", bot)
        self.assertNotIn("status_message.edit_text(", bot)
        self.assertNotIn("query.answer(result", (root / "hq_commands.py").read_text())


class DryRunHoldTests(unittest.TestCase):
    """N10: external-effect jobs do nothing in dry_run (or when the mode cannot be read); internal jobs still run."""
    def test_hold(self):
        ran = []
        C.HANDLERS["test.send.email"] = lambda j: ran.append("send") or {}
        C.HANDLERS["test.tally"] = lambda j: ran.append("tally") or {}
        try:
            for mode in (lambda: "dry_run", lambda: None, lambda: "weird", lambda: 1 / 0):
                ok, err, _, _ = C.run_job({"id": "j", "kind": "test.send.email"}, mode=mode)
                self.assertFalse(ok); self.assertIn("held", err)
            self.assertEqual(ran, [])
            self.assertTrue(C.run_job({"id": "j", "kind": "test.send.email"}, mode=lambda: "approve_first")[0])
            self.assertTrue(C.run_job({"id": "j", "kind": "test.tally"}, mode=lambda: "dry_run")[0])
            self.assertFalse(C.run_job({"id": "j", "kind": "test.tally", "payload": {"recipient": "x"}}, mode=lambda: "dry_run")[0])
            with mock.patch.object(C, "core_status", return_value={"error": "down"}):
                self.assertIn("held", C.run_job({"id": "j", "kind": "release.check"})[1])
            self.assertEqual(ran, ["send", "tally"])
        finally:
            C.HANDLERS.pop("test.send.email"); C.HANDLERS.pop("test.tally")
