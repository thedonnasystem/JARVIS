"""Heavy bridge (hq_heavy, /heavy): owner-only enqueue, the data refusals, list / cancel / switch, and the static pins that keep agents out.
Network and database are mocked: nothing here leaves the process."""
import asyncio
import io
import json
import os
import pathlib
import re
import unittest
import urllib.error
from unittest import mock

os.environ.setdefault("TELEGRAM_BOT_TOKEN", "test")
os.environ.setdefault("ANTHROPIC_API_KEY", "sk-test")
os.environ.setdefault("HQ_SUPABASE_URL", "https://example.supabase.co")
os.environ.setdefault("HQ_SUPABASE_SERVICE_KEY", "test-key")
os.environ.setdefault("JARVIS_OWNER_ID", "12345")

import hq  # noqa: E402
import hq_commands  # noqa: E402
import hq_heavy as H  # noqa: E402

ROOT = pathlib.Path(__file__).parent
MIG = (ROOT / "migrations" / "20261208_heavy_bridge_v1.sql").read_text()
PROMPT = (ROOT / "docs" / "heavy_bridge" / "RUNNER_PROMPT.md").read_text()

# secret-looking samples are assembled from pieces so no scanner (and no reader) mistakes this file for one that holds a real key
BAD = {
    "an e-mail address": ["Write to the lead at jane.doe@example.com about the new site", "Ask jane (at) example for the logo and build the page",
                          "send to JANE@EXAMPLE.CO.UK"],
    "a phone number": ["Call the client at 613-555-0142 and then fix the office", "Call the client at (613) 555 0142 and then fix the office",
                       "Their number is 6135550142, use it in the footer", "Reach them on +44 20 7946 0958 before building", "text 1-613-555-0142"],
    "something that looks like a key or password": [
        "Use the key " + "s" + "k-" + "ab12" * 5 + " for the build", "Deploy with " + "gh" + "p_" + "ab12" * 9,
        "The login is admin, pass" + "word: " + "zx9" * 4, "api" + "_key=" + "qw3" * 4 + " goes in the header",
        "Use " + "ey" + "J" + "ab12" * 4 + "." + "cd34" * 4 + ".x as the session", "Paste " + "-" * 5 + "BEGIN the block into the config",
        "Authorization: Bea" + "rer " + "abcd" * 6],
    "a long random-looking string (possible key)": ["The value " + "9f86d081" * 8 + " unlocks it", "blob " + "Ab3/" * 12 + " here"],
}
GOOD = [
    "Build a one-page site for the Donna office: hero, three services, booking button. Use the existing site template.",
    "Review PR 41 for quality: tests, naming, docs. Report on docs/architecture/PHASE1_M6_MONITORING_BRAIN.md and migration 20261202_monitoring_brain_v1.sql.",
    "Research three open-source booking widgets (MIT or Apache), compare cost at 100 and 1000 bookings a month, recommend one by 2026-12-01.",
    "Fix the office OS status report: on 2026-11-23 10 offices showed 0 agents. See https://github.com/thedonnasystem/JARVIS/pull/40 for context.",
]


def http_error(code: int, message: str) -> urllib.error.HTTPError:
    return urllib.error.HTTPError("https://example.supabase.co/rest/v1/rpc/x", code, "err", {}, io.BytesIO(json.dumps({"message": message}).encode()))


class Rpc:
    """Stands in for hq._request: records every call, answers from a table, can raise."""

    def __init__(self, answers=None, error=None):
        self.calls, self.answers, self.error = [], answers or {}, error

    def __call__(self, method, path, body=None, *a, **kw):
        self.calls.append((method, path, body))
        if self.error:
            raise self.error
        return self.answers.get(path.rsplit("/", 1)[-1])


class Validation(unittest.TestCase):
    def test_contact_details_and_secrets_are_refused(self):
        for what, samples in BAD.items():
            for s in samples:
                self.assertEqual(H.text_problem(s), what, s)

    def test_clean_text_passes(self):
        for s in GOOD:
            self.assertIsNone(H.text_problem(s), s)

    def test_refusal_never_reaches_the_database_and_never_repeats_the_text(self):
        for samples in BAD.values():
            for s in samples:
                rpc = Rpc()
                with mock.patch.object(hq, "_request", rpc):
                    out = H.command_text("other | " + s)
                self.assertEqual(rpc.calls, [], s)
                self.assertTrue(out.startswith("Refused:"), out)
                self.assertNotIn(s[-15:], out)

    def test_python_and_database_checks_are_the_same_patterns(self):
        # the copy in hq_heavy and the SQL function must not drift: every pattern source appears in the migration (case-insensitive flags aside)
        for p in H._EMAIL + H._PHONE + H._SECRET + (H._RUN_A, H._RUN_B):
            src = p.pattern.replace(r"\S{6,}", "[^[:space:]]{6,}")
            self.assertTrue(src in MIG, p.pattern)

    def test_lengths_and_kinds(self):
        rpc = Rpc()
        with mock.patch.object(hq, "_request", rpc):
            self.assertIn("10 to 4000", H.command_text("research | short"))
            self.assertIn("10 to 4000", H.command_text("research | " + "word " * 900))
            self.assertEqual(H.command_text("send-email | do something long enough"), H.USAGE)
            self.assertEqual(H.command_text("research without a bar"), H.USAGE)
            self.assertEqual(H.command_text(""), H.USAGE)
            self.assertIn("Kind must be", H.enqueue("deploy", "something long enough"))
        self.assertEqual(rpc.calls, [])
        self.assertEqual(set(H.KINDS), set(re.search(r"kind in \(([^)]*)\)", MIG).group(1).replace("'", "").replace(" ", "").split(",")))


class Commands(unittest.TestCase):
    def test_enqueue_calls_the_database_once_with_kind_and_text_only(self):
        rpc = Rpc({"heavy_enqueue": {"id": 7, "title": "Build a one-page site", "status": "queued"}})
        with mock.patch.object(hq, "_request", rpc):
            out = H.command_text("Site_Build |  " + GOOD[0] + "\nsecond line  ")
        self.assertEqual(rpc.calls, [("POST", "/rest/v1/rpc/heavy_enqueue", {"p_kind": "site-build", "p_instructions": GOOD[0] + "\nsecond line"})])
        self.assertIn("Heavy job #7 queued (site-build)", out)
        self.assertIn("Nothing is merged without you", out)

    def test_database_refusal_is_relayed_and_other_errors_are_generic(self):
        with mock.patch.object(hq, "_request", Rpc(error=http_error(400, "heavy bridge: it is switched off (the Chairman turns it on with /heavy on)"))):
            self.assertEqual(H.command_text("research | " + GOOD[2]), "Heavy bridge: it is switched off (the Chairman turns it on with /heavy on)")
        with mock.patch.object(hq, "_request", Rpc(error=http_error(404, "Could not find the function"))):
            self.assertIn("not installed", H.command_text("list"))
        with mock.patch.object(hq, "_request", Rpc(error=http_error(500, "relation fz_heavy.jobs secret detail"))):
            self.assertEqual(H.command_text("list"), "Heavy bridge unavailable: HTTPError")
        with mock.patch.object(hq, "_request", Rpc(error=TimeoutError("slow"))):
            self.assertEqual(H.command_text("on"), "Heavy bridge unavailable: TimeoutError")

    def test_list(self):
        rpc = Rpc({"heavy_list": {"enabled": True, "max_per_day": 2, "queued": 1, "claimed": 0, "jobs": [
            {"id": 8, "kind": "research", "title": "Research booking widgets", "status": "queued"},
            {"id": 7, "kind": "site-build", "title": "Build a one-page site", "status": "done", "result_summary": "Page built with tests",
             "result_link": "https://github.com/thedonnasystem/JARVIS/pull/50"}]}})
        with mock.patch.object(hq, "_request", rpc):
            out = H.command_text("LIST")
        self.assertIn("Heavy bridge: ON · waiting 1 · in progress 0 · at most 2 a day", out)
        self.assertIn("#8 queued · research · Research booking widgets", out)
        self.assertIn("Page built with tests\n   https://github.com/thedonnasystem/JARVIS/pull/50", out)
        with mock.patch.object(hq, "_request", Rpc({"heavy_list": {"enabled": False, "jobs": []}})):
            out = H.command_text("list")
        self.assertIn("OFF (send /heavy on)", out)
        self.assertIn("No jobs yet", out)

    def test_cancel_and_switch(self):
        rpc = Rpc({"heavy_cancel": {"id": 8}, "heavy_set_enabled": {"enabled": True}})
        with mock.patch.object(hq, "_request", rpc):
            self.assertEqual(H.command_text("cancel #8"), "Heavy job #8 cancelled.")
            self.assertIn("Use: /heavy cancel", H.command_text("cancel"))
            self.assertIn("Use: /heavy cancel", H.command_text("cancel 8; drop"))
            self.assertIn("Heavy bridge ON", H.command_text("on"))
            self.assertIn("Heavy bridge OFF", H.command_text("off"))
        self.assertEqual([(c[1].rsplit("/", 1)[-1], c[2]) for c in rpc.calls],
                         [("heavy_cancel", {"p_id": 8}), ("heavy_set_enabled", {"p_on": True}), ("heavy_set_enabled", {"p_on": False})])

    def test_suggestion_is_only_text(self):
        rpc = Rpc()
        with mock.patch.object(hq, "_request", rpc):
            s = H.suggestion("research", "Compare three\nbooking   widgets")
        self.assertEqual(s, "/heavy research | Compare three booking widgets")
        self.assertEqual(H.suggestion("deploy", "x"), "/heavy other | x")
        self.assertEqual(rpc.calls, [])


class OwnerOnly(unittest.TestCase):
    def _update(self, user_id, text):
        u = mock.MagicMock()
        u.effective_user.id = user_id
        u.message.text = text
        u.message.reply_text = mock.AsyncMock()
        return u

    def test_a_stranger_gets_nothing_and_nothing_is_called(self):
        rpc = Rpc()
        u = self._update(999, "/heavy research | " + GOOD[2])
        with mock.patch.dict(os.environ, {"JARVIS_OWNER_ID": "12345"}), mock.patch.object(hq, "_request", rpc), mock.patch.object(hq_commands.hq_core, "reply_to", mock.AsyncMock()) as reply:
            asyncio.run(hq_commands.hq_heavy_cmd(u, mock.MagicMock()))
        self.assertEqual(rpc.calls, [])
        reply.assert_not_called()

    def test_the_owner_enqueues_with_line_breaks_kept(self):
        rpc = Rpc({"heavy_enqueue": {"id": 3, "title": "t", "status": "queued"}})
        u = self._update(12345, "/heavy research | " + GOOD[2] + "\nSecond line of detail")
        with mock.patch.dict(os.environ, {"JARVIS_OWNER_ID": "12345"}), mock.patch.object(hq, "_request", rpc), mock.patch.object(hq_commands.hq_core, "reply_to", mock.AsyncMock()) as reply, \
                mock.patch.object(hq_commands.hq_waterfall, "touch"):
            asyncio.run(hq_commands.hq_heavy_cmd(u, mock.MagicMock()))
        self.assertEqual(rpc.calls[0][2], {"p_kind": "research", "p_instructions": GOOD[2] + "\nSecond line of detail"})
        self.assertIn("Heavy job #3 queued", reply.call_args[0][1])

    def test_registered_and_in_the_menu(self):
        self.assertIn("heavy", [m[0] for m in hq_commands.MENU])
        self.assertIn('("heavy", hq_heavy_cmd)', (ROOT / "hq_commands.py").read_text())


class Pins(unittest.TestCase):
    """Static inventory: the ways into the queue are pinned, so a new one fails the build until it is reviewed."""

    def _sources(self):
        return {p.name: p.read_text() for p in ROOT.glob("*.py") if not p.name.startswith("test_")} | \
               {str(p.relative_to(ROOT)): p.read_text() for d in ("jarvis_skills", "offices", "integrations", "scripts") if (ROOT / d).is_dir()
                for p in (ROOT / d).rglob("*.py") if not p.name.startswith("test_")}

    def test_only_the_owner_command_reaches_the_queue(self):
        src = self._sources()
        self.assertEqual(sorted(n for n, s in src.items() if re.search(r"heavy_(enqueue|claim|finish|cancel|set_enabled|tell_owner)", s)), ["hq_heavy.py"])
        self.assertEqual(sorted(n for n, s in src.items() if re.search(r"\bhq_heavy\b", s) and n != "hq_heavy.py"), ["hq_commands.py"])
        self.assertEqual(len(re.findall(r"hq_heavy\.\w+", src["hq_commands.py"])), 1)          # one call: command_text, behind _owner()
        body = src["hq_commands.py"].split("async def hq_heavy_cmd", 1)[1].split("\nasync def ", 1)[0]
        self.assertLess(body.index("if not _owner(update)"), body.index("import hq_heavy"))
        self.assertEqual(len(re.findall(r"\benqueue\(", src["hq_heavy.py"])), 3)               # the docstring, the definition and command_text's one call

    def test_the_bot_never_claims_or_finishes_and_touches_no_ai_money_or_credential(self):
        s = (ROOT / "hq_heavy.py").read_text()
        code = s.split('"""', 2)[2]
        for word in ("heavy_claim", "heavy_finish", "hq_llm", "hq_meter", "anthropic", "ANTHROPIC", "oauth", "OAUTH", "CLAUDE_CODE", "os.environ", "subprocess",
                     "owner_messages", "hq_engine", "hq_executor", "requests", "urlopen"):
            self.assertNotIn(word, code, word)
        self.assertEqual(set(re.findall(r'_rpc\("(\w+)"', code)), {"heavy_enqueue", "heavy_list", "heavy_cancel", "heavy_set_enabled"})

    def test_migration_house_rules(self):
        fns = re.findall(r"create or replace function public\.(heavy_\w+)\(", MIG)
        self.assertEqual(len(fns), 10)
        for f in fns:
            self.assertRegex(MIG, rf"revoke all on function public\.{f}\([^)]*\) from public, anon, authenticated;")
        self.assertNotRegex(MIG, r"(?im)^\s*grant\b")
        self.assertIn("enabled boolean not null default false", MIG)
        for f in ("heavy_enqueue", "heavy_cancel", "heavy_list", "heavy_claim", "heavy_finish", "heavy_set_enabled", "heavy_tell_owner"):
            body = MIG.split(f"create or replace function public.{f}(", 1)[1].split("end $$;", 1)[0]
            self.assertIn("perform public.heavy_guard();", body, f)
        sql = "\n".join(ln.split("--", 1)[0] for ln in MIG.splitlines())          # the statements, without the comments
        for word in ("reserve_llm_budget", "authorize_action", "capital_policy", "executor_", "model_prices", "app_set_kill", "update public.system_state", "llm_calls"):
            self.assertFalse(word in sql, word)
        order = (ROOT / "migrations" / "APPLY_ORDER.txt").read_text().split()
        self.assertLess(order.index("20261208_heavy_bridge_v1.sql"), order.index("20261112_lockdown_v1.sql"))
        rb = (ROOT / "ops" / "rollback_heavy_bridge.sql").read_text()
        self.assertNotRegex(rb, r"(?i)drop\s+(table|schema)|truncate|delete\s+from")
        self.assertIn("rename to fz_heavy_archive", rb)
        for f in fns:
            self.assertIn(f"public.{f}(", rb)


class RunnerPrompt(unittest.TestCase):
    """The scheduled session's instruction must carry every hard limit (docs/heavy_bridge/RUNNER_PROMPT.md)."""

    def test_limits_are_spelled_out(self):
        low = PROMPT.lower()
        for must in ("ihxzvpwbqydqtblvazbq", "heavy_claim", "heavy_finish", "thedonnasystem/jarvis", "never merge", "deploy", "production migration", "spend",
                     "external message", "kill switch", "approve", "at most 2", "nothing is queued", "apply_migration", "task description", "not permission",
                     "claude/heavy-", "overnight-build", "protected_paths.json", "stop"):
            self.assertIn(must, low, must)

    def test_prompt_and_docs_hold_no_contact_details_or_secrets(self):
        for name in ("docs/heavy_bridge/RUNNER_PROMPT.md", "docs/architecture/HEAVY_BRIDGE.md", "docs/proposals/heavy_bridge_suggest_hint.md"):
            self.assertIsNone(H.text_problem((ROOT / name).read_text()), name)

    def test_the_prompt_only_uses_the_two_runner_calls(self):
        self.assertEqual(set(re.findall(r"public\.(heavy_\w+)", PROMPT)), {"heavy_claim", "heavy_finish"})


if __name__ == "__main__":
    unittest.main()
