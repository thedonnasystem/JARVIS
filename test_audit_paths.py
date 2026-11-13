"""Adversarial and inventory tests from the send / outbox / spend path audit (see AUDIT_PATHS.md).

1. normalize_addr: every unclean form is "not one address" (None), so no caller can match or send to it.
2. hq_mail delivery is at-most-once (claim first), releases on provider failure, never re-posts after a bookkeeping failure.
3. /build sessions do not inherit secrets; Make / n8n triggers respect the kill switch and need approval.
4. Static inventory: the set of code that can send, mark sent or call out is pinned, so a new route fails the build until reviewed.
"""
import asyncio
import os
import pathlib
import re
import unittest
from unittest import mock

os.environ.setdefault("TELEGRAM_BOT_TOKEN", "test")
os.environ.setdefault("ANTHROPIC_API_KEY", "sk-test")
# hq reads these at import; use the same values as test_hq.py (it sorts after this file) so import order cannot matter
os.environ.setdefault("HQ_SUPABASE_URL", "https://example.supabase.co")
os.environ.setdefault("HQ_SUPABASE_SERVICE_KEY", "test-key")
os.environ.setdefault("JARVIS_OWNER_ID", "12345")

import hq_mail as M  # noqa: E402
from hq_policy import Decision  # noqa: E402

ROOT = pathlib.Path(__file__).parent
GOOD = "Hi\n\nSent by Moe, The Donna System, 1 Main St, Ottawa ON.\nTo stop receiving emails from us, reply \"unsubscribe\"."
PROF = {"sender_name": "Moe", "brand": "The Donna System", "mailing_address": "1 Main St, Ottawa ON"}
ENV = {"RESEND_API_KEY": "k", "MAIL_FROM": "Moe <m@example.com>"}


class Normalize(unittest.TestCase):
    def test_clean_forms_share_one_key(self):
        for p in ("Bob@X.com", " bob@x.com ", "bob+tag@x.com", "Bob <bob@x.com>", "bob@x.com.", "BOB+a+b@X.COM."):
            self.assertEqual(M.normalize_addr(p), "bob@x.com", p)

    def test_unclean_forms_are_not_an_address(self):
        for p in ("bob@x.com\t", "bob\u00a0@x.com", "bob@x.com\u200b", "b\u200bob@x.com", "\uff42ob@x.com",
                  '"bob"@x.com', "bob(c)@x.com", "bob@x.com;eve@y.com", "bob@x.com,eve@y.com", "<a@x.com> <bob@x.com>",
                  "bob@x.com <eve@y.com>x", "bob@@x.com", "@x.com", "bob@", "bob@x..com", "bob@-x.com", "", None, "bob@x.com\n"):
            self.assertIsNone(M.normalize_addr(p), repr(p))

    def test_refusal_rejects_unclean_recipients(self):
        row = {"id": "1", "to_ref": "x@example.com", "body": GOOD, "lead_id": None}
        self.assertIsNone(M.refusal(row, None))
        for bad in ('"x"@example.com', "x@example.com;y@example.com", "x@example.com​", "x@example.com, y@example.com"):
            self.assertTrue(M.refusal({**row, "to_ref": bad}, None), bad)


class FakeOutbox:
    """Minimal stand-in for PostgREST: one approved row, honours the claim filter, can refuse the sent flip."""
    def __init__(self, refuse_sent=False):
        self.row = {"id": "a1", "to_ref": "x@example.com", "body": GOOD, "lead_id": None, "agent": "donna-ops", "venture_id": "v1",
                    "status": "approved", "sent_at": None, "channel": "email"}
        self.refuse_sent = refuse_sent; self.audit = []

    def request(self, method, path, body=None, prefer=None):
        if "audit_log" in path:
            self.audit.append(body); return None
        if "outbox?id=eq.a1" in path and method == "PATCH":
            if "sent_at=is.null" in path and self.row["sent_at"] is not None:
                return []
            if body.get("status") == "sent":
                if self.refuse_sent:
                    raise RuntimeError("policy: daily send cap")
                self.row["status"] = "sent"
            self.row.update({k: v for k, v in body.items() if k in ("sent_at",)})
            return [dict(self.row)]
        return None

    def get(self, path):
        if path.startswith("outbox"):
            r = self.row
            return [dict(r)] if r["status"] == "approved" and r["sent_at"] is None else []
        if path.startswith("ventures"): return [{"slug": "donna"}]
        if path.startswith("company_profile"): return [PROF]
        if path.startswith("contact_suppressions"): return []
        return [{"do_not_contact": False}]


class Delivery(unittest.TestCase):
    def run_ticks(self, db, posts, n=3):
        outs = []
        with mock.patch.dict(os.environ, ENV), mock.patch.object(M, "live", return_value=True), \
             mock.patch.object(M, "_get", side_effect=db.get), mock.patch("hq._request", side_effect=db.request), \
             mock.patch("hq_policy.authorize", return_value=Decision("send_email", "allow", "r")), \
             mock.patch.object(M, "_post", side_effect=posts) as post:
            for _ in range(n):
                outs.append(M.deliver_approved())
            return outs, post

    def test_sent_once_then_never_again(self):
        db = FakeOutbox()
        outs, post = self.run_ticks(db, lambda r: True)
        self.assertEqual(post.call_count, 1); self.assertEqual(outs[0]["sent"], 1); self.assertEqual(db.row["status"], "sent")

    def test_provider_failure_releases_the_claim_for_a_retry(self):
        db = FakeOutbox(); results = iter([False, True])
        outs, post = self.run_ticks(db, lambda r: next(results), n=2)
        self.assertEqual((outs[0]["failed"], outs[1]["sent"]), (1, 1)); self.assertEqual(post.call_count, 2)

    def test_database_refusing_the_sent_flip_never_causes_a_second_email(self):
        db = FakeOutbox(refuse_sent=True)
        outs, post = self.run_ticks(db, lambda r: True, n=4)
        self.assertEqual(post.call_count, 1)                      # the old code re-posted on every later tick
        self.assertEqual(outs[0]["unrecorded"], 1)
        self.assertTrue(any(a and a.get("action") == "email_sent_unrecorded" for a in db.audit))

    def test_an_already_claimed_row_is_not_posted(self):
        db = FakeOutbox(); db.row["sent_at"] = "2026-01-01T00:00:00+00:00"
        with mock.patch("hq._request", side_effect=db.request):
            self.assertFalse(M._claim({"id": "a1"}))

    def test_claim_failure_means_no_post(self):
        db = FakeOutbox()
        with mock.patch("hq._request", side_effect=RuntimeError("down")):
            self.assertFalse(M._claim({"id": "a1"}))
        outs, post = self.run_ticks(db, lambda r: True, n=1)
        self.assertEqual(post.call_count, 1)


class BuildSandbox(unittest.TestCase):
    def setUp(self):
        import bot
        self.bot = bot

    def test_build_env_blanks_secrets_and_keeps_the_model_key(self):
        env = {"HQ_SUPABASE_SERVICE_KEY": "s", "RESEND_API_KEY": "r", "TELEGRAM_BOT_TOKEN": "t", "MAKE_WEBHOOK_URL": "w",
               "DATABASE_URL": "d", "MAIL_FROM": "m", "JARVIS_OWNER_ID": "1", "BW_SESSION": "b", "ANTHROPIC_API_KEY": "a", "PATH": "/bin"}
        with mock.patch.dict(os.environ, env, clear=True):
            out = self.bot._build_env()
        for k in env:
            if k in ("ANTHROPIC_API_KEY", "PATH"):
                self.assertNotIn(k, out)
            else:
                self.assertEqual(out.get(k), "", k)

    def test_bash_and_read_gates_block_parent_environment_reads(self):
        for cmd in ("cat /proc/1/environ", "tr '\\0' '\\n' < /proc/$PPID/environ", "cat .env", "python3 -c 'import os;print(os.environ)'", "printenv"):
            self.assertTrue(self.bot._is_dangerous_bash(cmd)[0], cmd)
        self.assertFalse(self.bot._is_dangerous_bash("ls -la && python3 hello.py")[0])
        for path in ("/proc/self/environ", "/app/.env", "/proc/1/environ"):
            r = asyncio.run(self.bot.build_permission_gate("Read", {"file_path": path}, None))
            self.assertEqual(type(r).__name__, "PermissionResultDeny", path)

    def test_build_env_also_blanks_dsn_auth_and_restore_vars(self):
        env = {"RESTORE_DB_URL": "x", "RESTORE_B2_AUTH": "x", "SOME_DSN": "x", "POSTGRES_URL": "x", "PATH": "/bin"}
        with mock.patch.dict(os.environ, env, clear=True):
            out = self.bot._build_env()
        for k in ("RESTORE_DB_URL", "RESTORE_B2_AUTH", "SOME_DSN", "POSTGRES_URL"):
            self.assertEqual(out.get(k), "", k)

    def test_both_build_sessions_pass_the_clean_env(self):
        src = (ROOT / "bot.py").read_text()
        self.assertEqual(len(re.findall(r"ClaudeAgentOptions\(", src)), src.count("env=_build_env()"))

    def test_make_and_n8n_triggers_refuse_when_kill_switch_is_on(self):
        with mock.patch.object(self.bot, "MAKE_WEBHOOK_URL", "https://example.invalid/h"), \
             mock.patch.object(self.bot.hq_meter, "kill_switch_on", return_value=True), \
             mock.patch("urllib.request.urlopen") as uo:
            self.assertTrue(asyncio.run(self.bot.trigger_make_webhook()).startswith("REFUSED"))
            self.assertTrue(asyncio.run(self.bot.trigger_webhook_path("x")).startswith("REFUSED"))
            uo.assert_not_called()

    def test_make_dispatch_needs_a_per_call_approval(self):
        with mock.patch.object(self.bot, "request_approval", new=mock.AsyncMock(return_value=False)), \
             mock.patch.object(self.bot, "trigger_make_webhook", new=mock.AsyncMock(return_value="ok")) as t:
            out = asyncio.run(self.bot.dispatch_tool_call("trigger_make_scenario", {}, None, 1))
            self.assertTrue(out.startswith("DENIED")); t.assert_not_called()


class RouteInventory(unittest.TestCase):
    """New send, mark-sent or outbound-call routes must be added here on purpose (and to AUDIT_PATHS.md)."""
    def count(self, pattern, files=None):
        out = {}
        for p in sorted(ROOT.glob("*.py")):
            if p.name.startswith("test_") or (files and p.name not in files):
                continue
            n = len(re.findall(pattern, p.read_text()))
            if n:
                out[p.name] = n
        return out

    def test_status_sent_writers(self):
        self.assertEqual(self.count(r'"status":\s*"sent"'), {"hq_commands.py": 1, "hq_mail.py": 1})

    def test_only_one_email_provider_call(self):
        self.assertEqual(self.count(r"api\.resend\.com"), {"hq_mail.py": 1})

    def test_outbound_call_sites(self):
        self.assertEqual(self.count(r"urllib\.request\.urlopen\("),
                         {"bot.py": 5, "hq.py": 1, "hq_backup.py": 1, "hq_dev.py": 1, "hq_mail.py": 1, "hq_systems.py": 1,
                          "hq_voice.py": 1, "hq_wholesale.py": 1})

    def test_policy_authorize_callers_for_send_email(self):
        self.assertEqual(self.count(r'hq_policy\.authorize\(.*"send_email"', files={"hq_mail.py", "hq_commands.py", "hq_engine.py", "hq_web.py", "bot.py"}), {"hq_mail.py": 1})


if __name__ == "__main__":
    unittest.main()
