"""No AI call can bypass the budget, the kill switch or the permission controls.

Two layers:
1. STATIC: every provider call site in the codebase is listed here with the reason it is allowed, and each one is checked to
   sit behind a gateway reservation. A new provider call anywhere fails the build until it is metered and added on purpose.
2. BEHAVIOURAL: the real bot/engine code is driven with a fake spend gateway and a fake provider. For every refusal the
   gateway can give (kill switch, daily cap, agent cap, focus, mission budget, outage, not configured) the provider is
   asserted NEVER to have been called, and the owner gets a deterministic (non-AI) reply.
"""
import asyncio
import io
import json
import os
import pathlib
import re
import types
import unittest
import urllib.error
from unittest import mock

os.environ.setdefault("TELEGRAM_BOT_TOKEN", "test")
os.environ.setdefault("ANTHROPIC_API_KEY", "sk-test")
os.environ.setdefault("JARVIS_OWNER_ID", "1")

import hq  # noqa: E402
import hq_engine as E  # noqa: E402
import hq_meter as MT  # noqa: E402
import hq_voice  # noqa: E402

ROOT = pathlib.Path(__file__).parent
import bot  # noqa: E402

REFUSALS = {
    "kill": "Kill switch is on.",
    "cap-company": "The company daily spend cap would be exceeded.",
    "cap-agent": "Agent builder would exceed its daily cap.",
    "cap-paused": "Agent builder is paused.",
    "focus": "Focus mode: only mission 1111 may use AI right now.",
    "mission": "Mission budget would be exceeded (190 of 200 cents used).",
    "hard-stop": "Capital hard stop: the operating fund is nearly empty. AI calls are paused.",
    "unknown-agent": "Unknown agent builder.",
    "weird": "some database hiccup nobody planned for",
}


def http_err(msg, code=400):
    return urllib.error.HTTPError("u", code, msg, {}, io.BytesIO(json.dumps({"message": msg}).encode()))


class Gateway:
    """Fake HQ database. mode: 'ok' | refusal text | 'down'. Records every RPC."""

    def __init__(self, mode="ok", kill=False):
        self.mode, self.kill, self.calls = mode, kill, []

    def __call__(self, method, path, body=None, timeout=30, prefer=None):
        name = path.rsplit("/", 1)[-1].split("?")[0]
        self.calls.append((name, body))
        if self.mode == "down":
            raise urllib.error.URLError("connection refused")
        if "system_state" in path:
            return [{"kill_switch": self.kill, "usd_to_cad": 1.45}]
        if name == "estimate_call_cents":
            return 3
        if name == "reserve_llm_budget":
            if self.mode != "ok":
                raise http_err(self.mode)
            return "call-1"
        return None

    def reserved(self):
        return [b for n, b in self.calls if n == "reserve_llm_budget"]

    def settled(self):
        return [b for n, b in self.calls if n == "settle_llm_call"]


class Provider:
    """Fake Anthropic client: counts calls."""

    def __init__(self):
        self.n = 0
        self.messages = self

    def create(self, **kw):
        self.n += 1
        usage = types.SimpleNamespace(input_tokens=10, output_tokens=5, server_tool_use=None)
        return types.SimpleNamespace(usage=usage, stop_reason="end_turn", content=[types.SimpleNamespace(type="text", text="hi")])


def patched(gw, enabled=True):
    return (mock.patch.object(hq, "_request", gw), mock.patch.object(hq, "hq_enabled", return_value=enabled))


def run(coro):
    return asyncio.run(coro)


# ----------------------------------------------------------------------------------------------------------------- static
SRC = {p.name: p.read_text() for p in ROOT.glob("*.py") if not p.name.startswith("test_")}
PROVIDER_PATTERNS = [r"api\.anthropic\.com", r"api\.openai\.com", r"deepgram", r"elevenlabs", r"assemblyai", r"api\.groq\.com",
                     r"generativelanguage\.googleapis", r"api\.cohere", r"api\.mistral", r"replicate\.com", r"api\.together",
                     r"^\s*(?:import|from)\s+(?:openai|cohere|mistralai|groq|replicate|google\.generativeai)\b",
                     r"\bAnthropic\(", r"\bClaudeSDKClient\(", r"async for \w+ in query\(", r"\.messages\.create\("]
ALLOWED_FILES = {"bot.py", "hq_engine.py", "hq_meter.py", "hq_voice.py"}


def strip_comments_and_docstrings(t):
    t = re.sub(r'"""(.|\n)*?"""', "", t)
    return re.sub(r"(?m)#.*$", "", t)


class StaticSurface(unittest.TestCase):
    def test_provider_calls_exist_only_in_the_four_known_files(self):
        hits = {}
        for name, text in SRC.items():
            t = strip_comments_and_docstrings(text)
            for pat in PROVIDER_PATTERNS:
                if re.search(pat, t, re.M | re.I):
                    hits.setdefault(name, []).append(pat)
        self.assertLessEqual(set(hits), ALLOWED_FILES, f"provider call in an unexpected file: {hits}")

    def test_every_sdk_session_reserves_first_and_is_capped(self):
        t = SRC["bot.py"]
        for fn, opener in (("run_plan_phase", "async for message in query("), ("run_build_phase", "async with ClaudeSDKClient(")):
            body = t[t.index(f"async def {fn}("):]
            body = body[: body.index("\nasync def ", 10)] if "\nasync def " in body[10:] else body
            self.assertIn("begin_session", body, fn)
            self.assertLess(body.index("begin_session"), body.index(opener), f"{fn} must reserve before opening the SDK session")
            self.assertIn("max_budget_usd=sess.max_usd", body, fn)
            self.assertIn("kill_switch_on", body, fn)
            self.assertIn("end_session", body, fn)
        self.assertEqual(len(re.findall(r"async for \w+ in query\(", t)), 1)
        self.assertEqual(t.count("ClaudeSDKClient("), 1)
        self.assertNotIn("record_spent_usd", t, "after-the-fact recording would double count the reserved session")

    def test_build_tool_gate_checks_kill_switch_first(self):
        t = SRC["bot.py"]
        body = t[t.index("async def build_permission_gate("):][:1600]
        self.assertLess(body.index("kill_switch_on"), body.index("if tool_name in"))

    def test_chat_side_model_calls_all_go_through_the_meter(self):
        t = strip_comments_and_docstrings(SRC["bot.py"])
        self.assertNotIn(".messages.create(", t)
        self.assertEqual(t.count("hq_meter.metered_create"), 3)  # owner chat, research agent, content agent

    def test_voice_provider_only_called_inside_metered_call(self):
        t = SRC["bot.py"]
        self.assertEqual(t.count("hq_voice.transcribe"), 1)
        i = t.index("hq_voice.transcribe")
        self.assertIn("hq_meter.metered_call", t[i - 400: i])
        # nothing else in the codebase calls the provider function
        for name, text in SRC.items():
            if name not in ("bot.py", "hq_voice.py"):
                self.assertNotIn("transcribe(", strip_comments_and_docstrings(text), name)

    def test_engine_provider_calls_follow_a_reservation(self):
        t = SRC["hq_engine.py"]
        run_turn = t[t.index("def run_turn_sync("):t.index("def _now()")]
        self.assertLess(run_turn.index('"reserve_llm_budget"'), run_turn.index("_complete("))
        probe = t[t.index("def _credits_back("):t.index("def resume_after_credits")]
        self.assertLess(probe.index('"reserve_llm_budget"'), probe.index(".messages.create("))
        self.assertEqual(len(re.findall(r"\.messages\.create\(", strip_comments_and_docstrings(t))), 3)  # _complete x2 + probe

    def test_meter_has_no_unmetered_fallthrough(self):
        t = strip_comments_and_docstrings(SRC["hq_meter.py"])
        reserve = t[t.index("def reserve("):t.index("def settle(")]
        self.assertNotIn("return None", reserve)
        self.assertNotIn("running unmetered", t)

    def test_phase1_migrations_do_not_raise_any_limit(self):
        for f in ("20261113_phase1_repair_v1.sql", "20261113_mission_guard_v1.sql"):
            t = (ROOT / "migrations" / f).read_text().lower()
            self.assertNotRegex(t, r"update\s+public\.agents|update\s+agents|set\s+daily_spend_cap_cents|set\s+budget_cents\s*=\s*\w+\s*\+")
            self.assertNotRegex(t, r"update\s+public\.system_state\s+set\s+daily_spend_cap")

    def test_build_ceiling_defaults_equal_builder_daily_cap_not_more(self):
        self.assertLessEqual(bot.BUILD_SESSION_CENTS, 50)   # builder agent daily cap on production is 50c
        self.assertLessEqual(bot.BUILD_PLAN_SHARE, 0.5)


# -------------------------------------------------------------------------------------------------------------- owner chat
class ChatCannotBypass(unittest.TestCase):
    def reply(self, gw, enabled=True):
        prov = Provider()
        a, b = patched(gw, enabled)
        with a, b, mock.patch.object(bot, "anthropic_client", prov), mock.patch.object(bot, "load_history", return_value=[]), \
             mock.patch.object(bot, "save_message"):
            out = run(bot.jarvis_reply(1, "hello", mock.AsyncMock(), typing=False))
        return out, prov

    def test_every_refusal_blocks_chat_before_the_provider(self):
        for key, msg in REFUSALS.items():
            out, prov = self.reply(Gateway(msg))
            self.assertEqual(prov.n, 0, key)
            self.assertIn("nothing was spent", out, key)
            self.assertIn("/hq", out, key)

    def test_kill_switch_reply_is_deterministic_and_names_the_way_back(self):
        out, prov = self.reply(Gateway(REFUSALS["kill"]))
        self.assertEqual(prov.n, 0)
        self.assertIn("Kill switch is ON", out)
        self.assertIn("/resume", out)

    def test_database_outage_blocks_chat(self):
        out, prov = self.reply(Gateway("down"))
        self.assertEqual(prov.n, 0)
        self.assertIn("can't reach my database", out)

    def test_hq_not_configured_blocks_chat(self):
        out, prov = self.reply(Gateway(), enabled=False)
        self.assertEqual(prov.n, 0)
        self.assertIn("not configured", out)

    def test_allowed_call_is_reserved_before_and_settled_after(self):
        gw = Gateway()
        out, prov = self.reply(gw)
        self.assertEqual(prov.n, 1)
        names = [n for n, _ in gw.calls]
        self.assertLess(names.index("reserve_llm_budget"), len(names))
        self.assertIn("settle_llm_call", names)
        self.assertEqual(gw.reserved()[0]["p_agent"], "jarvis-chat")

    def test_research_and_content_agents_blocked_the_same_way(self):
        for handler in (bot.handle_research_agent, bot.handle_content_agent):
            for msg in (REFUSALS["kill"], REFUSALS["cap-company"], "down"):
                prov = Provider(); gw = Gateway(msg)
                a, b = patched(gw)
                with a, b, mock.patch.object(bot, "anthropic_client", prov), mock.patch.object(bot, "recall", return_value=[]):
                    with self.assertRaises(MT.MeterBlocked):
                        run(handler({"task": "x", "topic": "x", "brief": "x", "request": "x", "query": "x", "platform": "x"}))
                self.assertEqual(prov.n, 0, (handler.__name__, msg))


# ---------------------------------------------------------------------------------------------------------------- /build
def result_msg(usd=0.05, subtype="success"):
    return bot.ResultMessage(subtype=subtype, duration_ms=1, duration_api_ms=1, is_error=False, num_turns=1, session_id="s1", total_cost_usd=usd)


def ctx():
    c = mock.Mock()
    c.bot.send_message = mock.AsyncMock(return_value=mock.Mock(edit_text=mock.AsyncMock()))
    return c


class BuildCannotBypass(unittest.TestCase):
    def setUp(self):
        bot.build_sessions.clear()
        MT._kill_cache.update(at=0.0, val=False)

    def plan(self, gw, messages=None, kill_after=None):
        calls = {"opts": None, "n": 0}

        async def fake_query(prompt, options):
            calls["opts"] = options
            calls["n"] += 1
            for m in (messages if messages is not None else [result_msg()]):
                yield m

        c = ctx()
        a, b = patched(gw)
        bot.build_sessions[5] = {"status": "planning", "task": "t", "session_id": None}
        with a, b, mock.patch.object(bot, "query", fake_query):
            run(bot.run_plan_phase(5, c, "make a thing"))
        return calls, c

    def test_plan_phase_refused_by_every_gateway_answer_never_opens_a_session(self):
        for key, msg in REFUSALS.items():
            calls, c = self.plan(Gateway(msg))
            self.assertEqual(calls["n"], 0, key)
            self.assertNotIn(5, bot.build_sessions, key)
            sent = " ".join(str(a) for a in c.bot.send_message.call_args_list)
            self.assertIn("/hq", sent, key)

    def test_plan_phase_blocked_by_database_outage(self):
        calls, c = self.plan(Gateway("down"))
        self.assertEqual(calls["n"], 0)
        self.assertIn("can't reach my database", str(c.bot.send_message.call_args_list))

    def test_plan_phase_reserves_its_share_and_caps_the_sdk_in_dollars(self):
        gw = Gateway()
        calls, _ = self.plan(gw)
        self.assertEqual(calls["n"], 1)
        r = gw.reserved()[0]
        self.assertEqual(r["p_agent"], "builder")
        self.assertEqual(r["p_est_cents"], int(bot.BUILD_SESSION_CENTS * bot.BUILD_PLAN_SHARE))
        self.assertAlmostEqual(calls["opts"].max_budget_usd, r["p_est_cents"] / 100 / 1.45, places=3)
        self.assertLess(calls["opts"].max_budget_usd * 1.45 * 100, r["p_est_cents"] + 0.01)

    def test_plan_phase_settles_real_cost_and_state_keeps_it_for_the_build_phase(self):
        gw = Gateway()
        self.plan(gw, [result_msg(usd=0.05)])
        st = gw.settled()[0]
        self.assertEqual(st["p_status"], "done")
        self.assertEqual(st["p_actual_cents"], 8)          # ceil(0.05 * 1.45 * 100)
        self.assertEqual(bot.build_sessions[5]["plan_cents"], 8)

    def test_unknown_cost_settles_at_full_reservation_never_zero(self):
        gw = Gateway()
        self.plan(gw, [result_msg(usd=None)])
        self.assertEqual(gw.settled()[0]["p_actual_cents"], int(bot.BUILD_SESSION_CENTS * bot.BUILD_PLAN_SHARE))

    def test_kill_switch_flipped_mid_plan_stops_the_session(self):
        gw = Gateway()
        seen = []

        async def fake_query(prompt, options):
            for i in range(5):
                if i == 1:
                    gw.kill = True
                    MT._kill_cache.update(at=0.0)
                seen.append(i)
                yield bot.AssistantMessage(content=[bot.TextBlock(text="x")], model="m")

        c = ctx(); a, b = patched(gw)
        bot.build_sessions[5] = {"status": "planning", "task": "t", "session_id": None}
        with a, b, mock.patch.object(bot, "query", fake_query):
            run(bot.run_plan_phase(5, c, "make a thing"))
        self.assertLessEqual(len(seen), 2)
        self.assertNotIn(5, bot.build_sessions)
        self.assertIn("Kill switch is ON", str(c.bot.send_message.call_args_list))
        self.assertTrue(gw.settled())  # the reservation is settled, not leaked

    def test_build_phase_is_refused_when_gateway_says_no_and_sdk_never_opens(self):
        for key, msg in REFUSALS.items():
            opened = []
            gw = Gateway(msg); c = ctx(); a, b = patched(gw)
            with a, b, mock.patch.object(bot, "ClaudeSDKClient", side_effect=lambda **k: opened.append(1)):
                run(bot.run_build_phase(5, c, {"status": "building", "task": "t", "session_id": "s", "plan_cents": 8}))
            self.assertEqual(opened, [], key)

    def test_build_phase_ceiling_is_session_minus_plan_and_never_more(self):
        gw = Gateway(); c = ctx(); a, b = patched(gw)
        captured = {}

        class FakeClient:
            def __init__(self, options): captured["opts"] = options
            async def __aenter__(self): return self
            async def __aexit__(self, *x): return False
            async def query(self, p): pass
            async def interrupt(self): captured["interrupted"] = True
            async def receive_response(self):
                yield result_msg(usd=0.10)

        with a, b, mock.patch.object(bot, "ClaudeSDKClient", FakeClient), mock.patch.object(bot, "_snapshot_workspace", return_value={}):
            run(bot.run_build_phase(5, c, {"status": "building", "task": "t", "session_id": "s", "plan_cents": 20}))
        r = gw.reserved()[0]
        self.assertEqual(r["p_est_cents"], bot.BUILD_SESSION_CENTS - 20)
        self.assertAlmostEqual(captured["opts"].max_budget_usd, r["p_est_cents"] / 100 / 1.45, places=3)
        self.assertEqual(gw.settled()[0]["p_actual_cents"], 15)  # ceil(0.10 * 1.45 * 100)

    def test_plan_that_used_the_whole_session_leaves_nothing_to_build_with(self):
        gw = Gateway(); c = ctx(); a, b = patched(gw); opened = []
        with a, b, mock.patch.object(bot, "ClaudeSDKClient", side_effect=lambda **k: opened.append(1)):
            run(bot.run_build_phase(5, c, {"status": "building", "task": "t", "session_id": "s", "plan_cents": bot.BUILD_SESSION_CENTS}))
        self.assertEqual(opened, [])
        self.assertEqual(gw.reserved(), [])

    def test_kill_switch_mid_build_interrupts_and_settles(self):
        gw = Gateway(); c = ctx(); a, b = patched(gw); captured = {}

        class FakeClient:
            def __init__(self, options): pass
            async def __aenter__(self): return self
            async def __aexit__(self, *x): return False
            async def query(self, p): pass
            async def interrupt(self): captured["interrupted"] = True
            async def receive_response(self):
                yield bot.AssistantMessage(content=[bot.TextBlock(text="a")], model="m")
                gw.kill = True; MT._kill_cache.update(at=0.0)
                yield bot.AssistantMessage(content=[bot.TextBlock(text="b")], model="m")
                captured["reached_third"] = True
                yield result_msg()

        with a, b, mock.patch.object(bot, "ClaudeSDKClient", FakeClient), mock.patch.object(bot, "_snapshot_workspace", return_value={}):
            run(bot.run_build_phase(5, c, {"status": "building", "task": "t", "session_id": "s", "plan_cents": 5}))
        self.assertTrue(captured.get("interrupted"))
        self.assertNotIn("reached_third", captured)
        self.assertTrue(gw.settled())

    def test_tool_gate_denies_and_interrupts_when_kill_switch_is_on(self):
        MT._kill_cache.update(at=0.0, val=False)
        gw = Gateway(kill=True); a, b = patched(gw)
        with a, b:
            res = run(bot.build_permission_gate("Bash", {"command": "echo hi"}, None))
        self.assertEqual(type(res).__name__, "PermissionResultDeny")
        self.assertTrue(res.interrupt)

    def test_tool_gate_fails_closed_when_database_unreachable(self):
        MT._kill_cache.update(at=0.0, val=False)
        a, b = patched(Gateway("down"))
        with a, b:
            res = run(bot.build_permission_gate("Bash", {"command": "echo hi"}, None))
        self.assertEqual(type(res).__name__, "PermissionResultDeny")

    def test_existing_permission_rules_still_apply_when_kill_switch_is_off(self):
        a, b = patched(Gateway())
        with a, b:
            res = run(bot.build_permission_gate("Write", {"file_path": "/etc/passwd"}, None))
        self.assertEqual(type(res).__name__, "PermissionResultDeny")
        self.assertIn("outside the allowed workspace", res.message)


# ----------------------------------------------------------------------------------------------------------------- voice
class VoiceCannotBypass(unittest.TestCase):
    def setUp(self):
        p = mock.patch.object(bot, "JARVIS_OWNER_ID", "1")  # whichever test module imported bot first decided the env
        p.start(); self.addCleanup(p.stop)

    def update(self, seconds=30):
        u = mock.Mock()
        u.effective_user.id = 1
        u.effective_chat.id = 1
        u.message.voice = types.SimpleNamespace(duration=seconds, file_size=1000, file_id="f")
        u.message.audio = None
        u.message.reply_text = mock.AsyncMock()
        c = mock.Mock()
        f = mock.Mock(); f.download_as_bytearray = mock.AsyncMock(return_value=bytearray(b"audio"))
        c.bot.get_file = mock.AsyncMock(return_value=f)
        return u, c

    def go(self, gw, seconds=30):
        u, c = self.update(seconds)
        provider = mock.Mock(return_value="hello there")
        a, b = patched(gw)
        with a, b, mock.patch.object(hq_voice, "configured", return_value=True), mock.patch.object(hq_voice, "transcribe", provider), \
             mock.patch.object(bot, "jarvis_reply", mock.AsyncMock(return_value="ok")):
            run(bot.handle_voice(u, c))
        return provider, u, gw

    def test_every_refusal_stops_voice_before_the_provider(self):
        for key, msg in list(REFUSALS.items()) + [("down", "down")]:
            provider, u, _ = self.go(Gateway(msg))
            provider.assert_not_called()
            self.assertIn("/hq", str(u.message.reply_text.call_args_list), key)

    def test_voice_reserves_a_flat_estimate_before_and_settles_after(self):
        provider, u, gw = self.go(Gateway(), seconds=30)
        provider.assert_called_once()
        r = gw.reserved()[0]
        self.assertEqual((r["p_agent"], r["p_model"], r["p_purpose"]), ("jarvis-chat", "whisper-1", "voice transcription"))
        self.assertEqual(r["p_est_cents"], hq_voice.estimate_cents(30))
        self.assertEqual(gw.settled()[0]["p_actual_cents"], r["p_est_cents"])

    def test_estimate_rounds_up_and_unknown_length_is_priced_as_the_maximum(self):
        self.assertEqual(hq_voice.estimate_cents(180), 3)
        self.assertEqual(hq_voice.estimate_cents(0), hq_voice.estimate_cents(hq_voice.MAX_SECONDS))
        self.assertEqual(hq_voice.estimate_cents(1), 1)
        self.assertEqual(hq_voice.estimate_cents(10_000), hq_voice.estimate_cents(hq_voice.MAX_SECONDS))

    def test_transcription_failure_releases_the_reservation(self):
        u, c = self.update(); gw = Gateway(); a, b = patched(gw)
        with a, b, mock.patch.object(hq_voice, "configured", return_value=True), \
             mock.patch.object(hq_voice, "transcribe", side_effect=RuntimeError("boom")):
            with self.assertRaises(RuntimeError):
                run(bot.handle_voice(u, c))
        self.assertEqual(gw.settled()[0]["p_status"], "failed")


# ---------------------------------------------------------------------------------------------------------------- engine
class EngineCannotBypass(unittest.TestCase):
    def test_credit_probe_blocked_by_every_refusal_and_outage(self):
        for key, msg in list(REFUSALS.items()) + [("down", "down")]:
            prov = Provider(); E._last_probe = None
            with mock.patch.object(E, "_rpc", side_effect=http_err(msg) if msg != "down" else urllib.error.URLError("x")), \
                 mock.patch.object(E, "_anthropic", return_value=prov):
                self.assertFalse(E._credits_back(None), key)
            self.assertEqual(prov.n, 0, key)

    def test_credit_probe_is_one_cent_through_the_gateway_and_settled(self):
        prov = Provider(); E._last_probe = None; calls = []
        with mock.patch.object(E, "_rpc", side_effect=lambda n, a: (calls.append((n, a)), "id-1")[1]), \
             mock.patch.object(E, "_anthropic", return_value=prov):
            self.assertTrue(E._credits_back(None))
        self.assertEqual(prov.n, 1)
        self.assertEqual(calls[0][0], "reserve_llm_budget")
        self.assertEqual((calls[0][1]["p_agent"], calls[0][1]["p_est_cents"], calls[0][1]["p_purpose"]), ("jarvis", 1, "credit probe"))
        self.assertEqual(calls[1][0], "settle_llm_call")

    def test_agent_turn_never_calls_the_provider_when_the_database_is_down(self):
        prov = Provider()
        agent = [{"slug": "builder", "title": "t", "charter": "c", "metric": "m", "model_tier": "cheap", "role": "builder", "status": "active"}]

        def get(path, *a, **k):
            return agent if path.startswith("agents?") else []

        def rpc(name, args):
            if name == "reserve_llm_budget":
                raise urllib.error.URLError("down")
            return 3

        with mock.patch.object(E, "_get", side_effect=get), mock.patch.object(E, "_rpc", side_effect=rpc), \
             mock.patch.object(E, "_anthropic", return_value=prov):
            with self.assertRaises(Exception):
                E.run_turn_sync("builder", "do a thing", 100, "task x")
        self.assertEqual(prov.n, 0)

    def test_agent_turn_refused_by_gateway_never_calls_the_provider(self):
        agent = [{"slug": "builder", "title": "t", "charter": "c", "metric": "m", "model_tier": "cheap", "role": "builder", "status": "active"}]
        for key, msg in REFUSALS.items():
            prov = Provider()

            def rpc(name, args, msg=msg):
                if name == "reserve_llm_budget":
                    raise http_err(msg)
                return 3

            with mock.patch.object(E, "_get", side_effect=lambda p, *a, **k: agent if p.startswith("agents?") else []), \
                 mock.patch.object(E, "_rpc", side_effect=rpc), mock.patch.object(E, "_anthropic", return_value=prov):
                with self.assertRaises(E.GatewayBlocked):
                    E.run_turn_sync("builder", "do a thing", 100, "task x")
            self.assertEqual(prov.n, 0, key)


if __name__ == "__main__":
    unittest.main()
