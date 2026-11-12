import asyncio
import os
import unittest
from unittest import mock

os.environ["HQ_SUPABASE_URL"] = "https://example.supabase.co"
os.environ["HQ_SUPABASE_SERVICE_KEY"] = "test-key"
os.environ["JARVIS_OWNER_ID"] = "12345"

import hq  # noqa: E402


class FakeBot:
    def __init__(self, fail=False):
        self.sent, self.fail = [], fail

    async def send_message(self, chat_id, text, reply_markup=None):
        if self.fail:
            raise RuntimeError("telegram down")
        self.sent.append((chat_id, text))


class Ctx:
    def __init__(self, bot):
        self.bot = bot


class HQBridge(unittest.TestCase):
    def run_job(self, rows, bot):
        calls = []

        def fake(method, path, body=None, timeout=30, prefer=None):
            calls.append((method, path, body))
            return rows if method == "GET" else None

        import hq_push
        with mock.patch.object(hq, "_request", side_effect=fake), mock.patch.object(hq, "in_quiet_hours", return_value=False), \
                mock.patch.object(hq_push, "notify", mock.AsyncMock()) as push:
            asyncio.run(hq.deliver_owner_messages(Ctx(bot)))
        self.pushed = push.await_count
        return calls

    def test_sends_to_owner_only_then_marks_sent(self):
        bot = FakeBot()
        rows = [{"id": "a1", "kind": "money", "channel": "telegram", "body": "Profit: $0"}]
        calls = self.run_job(rows, bot)
        self.assertEqual(bot.sent, [(12345, "Money\n\nProfit: $0")])
        self.assertEqual(calls[1][0], "PATCH")
        self.assertIn("sent_at", calls[1][2])
        self.assertEqual(self.pushed, 1)  # push goes out after Telegram, once per delivered message

    def test_emergency_on_unwired_call_channel_is_flagged(self):
        text = hq.format_owner_message({"kind": "emergency", "channel": "call", "body": "Smoke alarm"})
        self.assertTrue(text.startswith("\U0001F6A8 EMERGENCY"))
        self.assertIn("not connected yet", text)

    def test_failed_telegram_send_stays_unsent(self):
        bot = FakeBot(fail=True)
        calls = self.run_job([{"id": "a1", "kind": "brief", "channel": "telegram", "body": "x"}], bot)
        self.assertEqual([c[0] for c in calls], ["GET"])  # no PATCH, so it retries next minute

    def test_disabled_without_config(self):
        with mock.patch.object(hq, "HQ_SUPABASE_SERVICE_KEY", ""):
            bot = FakeBot()
            with mock.patch.object(hq, "_request") as r:
                asyncio.run(hq.deliver_owner_messages(Ctx(bot)))
            r.assert_not_called()
            self.assertFalse(hq.hq_enabled())

    def test_run_agent_unconfigured(self):
        with mock.patch.object(hq, "HQ_SUPABASE_URL", ""):
            self.assertEqual(hq.run_agent("ceo", "x"), {"error": "HQ is not configured"})


class Quiet(unittest.TestCase):
    def test_non_emergency_held_at_night_emergency_sent(self):
        class Bot:
            def __init__(s): s.sent = []
            async def send_message(s, chat_id, text, reply_markup=None): s.sent.append(text)
        class C:
            def __init__(s, b): s.bot = b
        rows = [{"id": "a", "kind": "proposal", "body": "drafts ready"}, {"id": "b", "kind": "emergency", "body": "fire"}]
        bot = Bot()
        with mock.patch.object(hq, "_request", side_effect=lambda m, *a, **k: rows if m == "GET" else None), \
             mock.patch.object(hq, "in_quiet_hours", return_value=True):
            asyncio.run(hq.deliver_owner_messages(C(bot)))
        self.assertEqual(len(bot.sent), 1)
        self.assertIn("fire", bot.sent[0])

    def test_quiet_hours(self):
        from datetime import datetime
        from zoneinfo import ZoneInfo
        tz = ZoneInfo("America/Toronto")
        self.assertTrue(hq.in_quiet_hours(datetime(2026, 11, 2, 1, 0, tzinfo=tz)))
        self.assertTrue(hq.in_quiet_hours(datetime(2026, 11, 2, 22, 30, tzinfo=tz)))
        self.assertFalse(hq.in_quiet_hours(datetime(2026, 11, 2, 7, 0, tzinfo=tz)))


if __name__ == "__main__":
    unittest.main()
