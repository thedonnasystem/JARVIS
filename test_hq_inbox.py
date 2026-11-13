import asyncio
import os
import re
import unittest
import urllib.error
from types import SimpleNamespace
from unittest import mock

os.environ.setdefault("HQ_SUPABASE_URL", "https://example.supabase.co")
os.environ.setdefault("HQ_SUPABASE_SERVICE_KEY", "test-key")
os.environ.setdefault("JARVIS_OWNER_ID", "12345")

import hq  # noqa: E402
import hq_commands as C  # noqa: E402
import hq_inbox as I  # noqa: E402


def item(rank, kind, title, **kw):
    d = {"rank": rank, "kind": kind, "ref_table": "owner_messages", "ref_id": f"id-{rank}", "title": title, "age_minutes": 5, "why": "because",
         "score": 80, "expires_at": None, "action": "review", "actions": [], "command": None}
    d.update(kw)
    return d


APPROVAL = item(1, "approval", "Spend $5 on ads", action="approve_or_reject", ref_id="msg-1", age_minutes=3000,
                actions=[{"verb": "approve"}, {"verb": "reject"}])
QUESTION = item(2, "question", "Which city first?", action="answer", ref_id="msg-2", actions=[{"label": "Ottawa"}, {"label": "Toronto"}])
MISSION = item(3, "mission", "Cold email test", ref_table="missions", ref_id="m-1", action="resume_or_abandon", command="/mission retry abcd1234", age_minutes=130)
PAY = item(4, "payment", "$15.00 to Twilio", ref_table="payment_instructions", action="pay", command="/pay done p1 <amount> <reference>")


class Msg:
    def __init__(self): self.sent = []
    async def reply_text(self, t, reply_markup=None): self.sent.append((t, reply_markup))


def upd(uid="42"):
    return SimpleNamespace(effective_user=SimpleNamespace(id=uid), message=Msg())


class Format(unittest.TestCase):
    def test_age_text(self):
        self.assertEqual([I.age_text(m) for m in (0, 1, 45, 120, 3000, 60 * 24 * 4, None, "x")], ["now", "now", "45m", "2h", "2d", "4d", "now", ""])

    def test_empty(self):
        self.assertEqual(I.format_inbox([]), "Nothing is waiting on you.")

    def test_lists_in_given_order_with_numbers_why_and_do(self):
        t = I.format_inbox([APPROVAL, QUESTION, MISSION, PAY])
        self.assertTrue(t.startswith("Needs you: 4 waiting"))
        pos = [t.index(x) for x in ("1. [Approve/Reject] Spend $5 on ads (2d)", "2. [Question] Which city first?", "3. [Blocked mission] Cold email test (2h)", "4. [Payment] $15.00 to Twilio")]
        self.assertEqual(pos, sorted(pos))
        self.assertIn("Do: tap Approve or Reject", t)
        self.assertIn("Do: pick an option", t)
        self.assertIn("Do: /mission retry abcd1234", t)   # an explicit command beats the generic hint
        self.assertIn("Do: /pay done p1", t)
        self.assertIn("because", t)

    def test_limit_and_trim(self):
        many = [item(i, "task", f"task {i}") for i in range(1, 31)]
        t = I.format_inbox(many, limit=5)
        self.assertIn("Needs you: 30 waiting (top 5)", t)
        self.assertIn("...and 25 more", t)
        self.assertNotIn("6. [", t)
        long = [item(i, "task", "x" * 140, why="y" * 300) for i in range(1, 60)]
        self.assertLessEqual(len(I.format_inbox(long, limit=59)), 3800)

    def test_unknown_kind_does_not_crash(self):
        self.assertIn("[weird]", I.format_inbox([item(1, "weird", "t")]))


class Fetch(unittest.TestCase):
    def test_calls_the_rpc_with_limit(self):
        f = mock.Mock(return_value=[APPROVAL, "junk"])
        with mock.patch.object(hq, "_request", f):
            self.assertEqual(I.fetch(7), [APPROVAL])
        f.assert_called_once_with("POST", "/rest/v1/rpc/needs_you", {"p_limit": 7})

    def test_non_list_is_an_error_not_an_empty_inbox(self):
        with mock.patch.object(hq, "_request", return_value=None):
            with self.assertRaises(ValueError):
                I.fetch()

    def test_database_error_propagates(self):
        with mock.patch.object(hq, "_request", side_effect=urllib.error.HTTPError("u", 404, "nf", {}, None)):
            with self.assertRaises(urllib.error.HTTPError):
                I.fetch()


class Brief(unittest.TestCase):
    def test_nothing(self):
        self.assertEqual(I.brief_line([]), "Needs you: nothing waiting.")

    def test_count_oldest_and_top(self):
        s = I.brief_line([QUESTION, APPROVAL, MISSION])
        self.assertIn("3 waiting", s)
        self.assertIn("oldest 2d", s)          # the oldest, not the top-ranked
        self.assertIn("Top: Which city first?", s)
        self.assertIn("/needs", s)

    def test_unreadable_inbox_gives_no_line_and_keeps_the_brief(self):
        with mock.patch.object(hq, "_request", side_effect=RuntimeError("down")):
            self.assertEqual(I.brief_line(), "")
            self.assertEqual(I.append_to_brief("Health: GREEN"), "Health: GREEN")

    def test_append(self):
        self.assertEqual(I.append_to_brief("Health: GREEN", [APPROVAL]).splitlines()[0], "Health: GREEN")
        self.assertIn("Needs you: 1 waiting", I.append_to_brief("Health: GREEN", [APPROVAL]))


class Digest(unittest.TestCase):
    def test_digest(self):
        s = I.weekly_digest([APPROVAL, QUESTION, item(5, "approval", "second", expires_at="2026-11-20T00:00:00Z", age_minutes=10)])
        self.assertIn("3 item(s)", s)
        self.assertIn("2 approve/reject", s)
        self.assertIn("1 question", s)
        self.assertIn("Oldest: Spend $5 on ads (2d)", s)
        self.assertIn("Expiring: 1 (soonest: second)", s)
        self.assertEqual(I.weekly_digest([]), "Weekly digest: nothing is waiting on you.")


class Buttons(unittest.TestCase):
    def test_approval_uses_the_existing_decision_callbacks(self):
        m = I.action_buttons(APPROVAL)
        self.assertEqual([b.callback_data for b in m.inline_keyboard[0]], ["hqd:ok:msg-1", "hqd:no:msg-1"])

    def test_question_uses_the_existing_answer_callbacks(self):
        m = I.action_buttons(QUESTION)
        self.assertEqual([r[0].callback_data for r in m.inline_keyboard], ["hqq:0:msg-2", "hqq:1:msg-2"])
        self.assertEqual([r[0].text for r in m.inline_keyboard], ["Ottawa", "Toronto"])

    def test_nothing_else_gets_a_tap_action(self):
        for it in (MISSION, PAY, item(9, "draft", "d"), item(8, "approval", "wrong table", action="approve_or_reject", ref_table="missions")):
            self.assertIsNone(I.action_buttons(it))

    def test_module_has_no_way_to_decide(self):
        import ast
        tree = ast.parse(open(os.path.join(os.path.dirname(__file__), "hq_inbox.py")).read())
        tree.body = [n for n in tree.body if not (isinstance(n, ast.Expr) and isinstance(n.value, ast.Constant))]   # drop the docstring
        seen = {n.attr for n in ast.walk(tree) if isinstance(n, ast.Attribute)} | {n.id for n in ast.walk(tree) if isinstance(n, ast.Name)} \
            | {n.value for n in ast.walk(tree) if isinstance(n, ast.Constant) and isinstance(n.value, str)}
        for forbidden in ("apply_decision", "apply_answer", "PATCH", "decide_approval", "hq_policy", "hq_capital", "hq_meter", "hq_commands"):
            self.assertNotIn(forbidden, seen)
        calls = [(n.args[0].value, n.args[1].value) for n in ast.walk(tree) if isinstance(n, ast.Call) and isinstance(n.func, ast.Attribute)
                 and n.func.attr == "_request"]
        self.assertEqual(calls, [("POST", "/rest/v1/rpc/needs_you")])


class Command(unittest.TestCase):
    def setUp(self):
        os.environ["JARVIS_OWNER_ID"] = "42"

    def test_non_owner_gets_nothing(self):
        f, u = mock.Mock(), upd("999")
        with mock.patch.object(hq, "_request", f):
            asyncio.run(C.hq_needs_cmd(u, SimpleNamespace(args=[])))
        f.assert_not_called()
        self.assertEqual(u.message.sent, [])

    def test_owner_gets_list_then_buttons_for_actionable_items_only(self):
        u = upd()
        with mock.patch.object(hq, "_request", return_value=[APPROVAL, MISSION, QUESTION, PAY]):
            asyncio.run(C.hq_needs_cmd(u, SimpleNamespace(args=[])))
        texts = [t for t, _ in u.message.sent]
        self.assertTrue(texts[0].startswith("Needs you: 4 waiting"))
        self.assertEqual(u.message.sent[0][1], None)
        # the top three are APPROVAL, MISSION, QUESTION: approval and question get taps, the mission does not
        self.assertEqual(len(u.message.sent), 3)
        self.assertEqual(u.message.sent[1][0], "Spend $5 on ads")
        self.assertEqual(u.message.sent[1][1].inline_keyboard[0][0].callback_data, "hqd:ok:msg-1")
        self.assertEqual(u.message.sent[2][1].inline_keyboard[0][0].callback_data, "hqq:0:msg-2")

    def test_empty(self):
        u = upd()
        with mock.patch.object(hq, "_request", return_value=[]):
            asyncio.run(C.hq_needs_cmd(u, SimpleNamespace(args=[])))
        self.assertEqual(u.message.sent, [("Nothing is waiting on you.", None)])

    def test_database_error_is_reported_not_swallowed(self):
        u = upd()
        with mock.patch.object(hq, "_request", side_effect=urllib.error.HTTPError("u", 404, "nf", {}, None)):
            asyncio.run(C.hq_needs_cmd(u, SimpleNamespace(args=[])))
        self.assertEqual(len(u.message.sent), 1)
        self.assertIn("Could not read the inbox", u.message.sent[0][0])
        self.assertIn("HTTPError", u.message.sent[0][0])

    def test_registered_and_in_menu(self):
        added = []
        app = SimpleNamespace(add_handler=lambda h: added.append(h), job_queue=None)
        C.register(app, lambda name, fn: (name, fn))
        self.assertIn(("needs", C.hq_needs_cmd), added)
        self.assertIn("needs", [n for n, _ in C.MENU])

    def test_brief_command_carries_the_count(self):
        u = upd()

        def req(method, path, body=None, timeout=30, prefer=None):
            return "Health: GREEN" if path.endswith("daily_brief_text") else [APPROVAL]
        with mock.patch.object(hq, "_request", side_effect=req):
            asyncio.run(C.hq_brief(u, SimpleNamespace(args=[])))
        t = u.message.sent[0][0]
        self.assertTrue(t.startswith("Health: GREEN"))
        self.assertIn("Needs you: 1 waiting", t)


class FakeBot:
    def __init__(self): self.sent = []
    async def send_message(self, chat_id, text, reply_markup=None): self.sent.append(text)


class Delivery(unittest.TestCase):
    def run_job(self, rows, inbox):
        bot = FakeBot()

        def fake(method, path, body=None, timeout=30, prefer=None):
            if method == "POST" and path.endswith("needs_you"):
                if isinstance(inbox, Exception):
                    raise inbox
                return inbox
            return rows if method == "GET" else None
        import hq_push
        with mock.patch.object(hq, "_request", side_effect=fake), mock.patch.object(hq, "in_quiet_hours", return_value=False), \
                mock.patch.object(hq_push, "notify", mock.AsyncMock()):
            asyncio.run(hq.deliver_owner_messages(SimpleNamespace(bot=bot)))
        return bot.sent

    def test_brief_gets_the_inbox_line(self):
        sent = self.run_job([{"id": "b1", "kind": "brief", "channel": "telegram", "body": "Health: GREEN"}], [APPROVAL, QUESTION])
        self.assertEqual(len(sent), 1)
        self.assertTrue(sent[0].startswith("Daily brief\n\nHealth: GREEN"))
        self.assertIn("Needs you: 2 waiting", sent[0])

    def test_other_kinds_are_untouched(self):
        sent = self.run_job([{"id": "m1", "kind": "money", "channel": "telegram", "body": "Profit: $0"}], [APPROVAL])
        self.assertEqual(sent, ["Money\n\nProfit: $0"])

    def test_inbox_failure_never_blocks_the_brief(self):
        sent = self.run_job([{"id": "b1", "kind": "brief", "channel": "telegram", "body": "Health: GREEN"}], RuntimeError("down"))
        self.assertEqual(sent, ["Daily brief\n\nHealth: GREEN"])


if __name__ == "__main__":
    unittest.main()
