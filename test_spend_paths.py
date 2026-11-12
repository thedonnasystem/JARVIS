"""Static + behavioural guard: every model-spend call site is known, and a gateway refusal never reaches Anthropic.

If this fails after a change, someone added a new way to spend money. Route it through the spend gateway
(hq_meter.metered_create for chat-side calls, hq_engine._run for engine calls) or add it here on purpose, with a reason.
"""
import io
import json
import pathlib
import re
import unittest
import urllib.error
from unittest import mock

import hq
import hq_meter as MT

ROOT = pathlib.Path(__file__).parent

# file -> number of direct `.messages.create(` call sites allowed, with the reason each exists.
ALLOWED = {
    "hq_meter.py": 1,    # metered_create: reserve -> create -> settle
    "hq_engine.py": 3,   # _complete (x2: normal + search-only retry, both after reserve_llm_budget) + hourly 1-token credit probe
}


def _sources():
    for p in sorted(ROOT.glob("*.py")):
        if p.name.startswith("test_") or p.name in ("hq_pg_adapter.py",):
            continue
        yield p


class SpendSurface(unittest.TestCase):
    def test_no_unlisted_direct_model_call_sites(self):
        found = {}
        for p in _sources():
            n = len(re.findall(r"(?:^|=\s*|\breturn\s+)\s*\w+(?:\(\))?\.messages\.create\(", p.read_text(), re.M))
            if n:
                found[p.name] = n
        self.assertEqual(found, ALLOWED, "a direct model call was added or removed; see test docstring")

    def test_bot_chat_side_calls_all_use_the_meter(self):
        src = (ROOT / "bot.py").read_text()
        self.assertNotIn(".messages.create(", src)
        self.assertGreaterEqual(src.count("hq_meter.metered_create"), 3)  # research, content, owner chat

    def test_only_known_agent_sdk_entrypoints(self):
        # /build and plan phase use the Agent SDK: owner-only, approval-gated, cost recorded after the fact (documented residual risk).
        src = (ROOT / "bot.py").read_text()
        self.assertEqual(len(re.findall(r"\bquery\(\s*$|\bquery\(\n|async for message in query\(", src)) >= 1, True)
        self.assertEqual(src.count("ClaudeSDKClient("), 1)

    def test_engine_reserves_before_every_normal_completion(self):
        src = (ROOT / "hq_engine.py").read_text()
        i_res, i_comp = src.index('_rpc("reserve_llm_budget"'), src.index("text, tin, tout, searches = _complete(")
        self.assertLess(i_res, i_comp)


class RefusalNeverReachesAnthropic(unittest.TestCase):
    def test_gateway_refusals_block_before_the_client_is_touched(self):
        for msg in ("Focus mode: only mission abc may use AI right now.",
                    "Mission budget would be exceeded (190 of 200 cents used).",
                    "Daily cap reached (330 of 330 cents).",
                    "Agent \"jarvis-chat\" is over its daily cap",
                    "HQ is paused: credits out"):
            e = urllib.error.HTTPError("u", 400, msg, {}, io.BytesIO(json.dumps({"message": msg}).encode()))
            client = mock.Mock()
            with mock.patch.object(hq, "hq_enabled", return_value=True), \
                 mock.patch.object(hq, "_request", side_effect=[1, e]):  # price lookup ok, reserve refused
                with self.assertRaises(MT.MeterBlocked, msg=msg):
                    MT.metered_create(client, "chat", model="claude-haiku-5-5", max_tokens=50, messages=[])
            client.messages.create.assert_not_called()


if __name__ == "__main__":
    unittest.main()
