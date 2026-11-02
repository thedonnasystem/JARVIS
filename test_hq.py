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

        with mock.patch.object(hq, "_request", side_effect=fake):
            asyncio.run(hq.deliver_owner_messages(Ctx(bot)))
        return calls

    def test_sends_to_owner_only_then_marks_sent(self):
        bot = FakeBot()
        rows = [{"id": "a1", "kind": "money", "channel": "telegram", "body": "Profit: $0"}]
        calls = self.run_job(rows, bot)
        self.assertEqual(bot.sent, [(12345, "Money\n\nProfit: $0")])
        self.assertEqual(calls[1][0], "PATCH")
        self.assertIn("sent_at", calls[1][2])

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


if __name__ == "__main__":
    unittest.main()
