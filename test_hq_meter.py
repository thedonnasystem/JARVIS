import io, json, types, unittest, urllib.error
from unittest import mock
import hq, hq_meter as MT


def http_err(msg, code=400):
    return urllib.error.HTTPError("u", code, msg, {}, io.BytesIO(json.dumps({"message": msg}).encode()))


class Gate:
    def __init__(self, reserve_exc=None, price_missing=()):
        self.calls = []; self.reserve_exc = reserve_exc; self.price_missing = set(price_missing)

    def __call__(self, method, path, body=None, timeout=30, prefer=None):
        name = path.rsplit("/", 1)[-1]; self.calls.append((name, body))
        if name == "estimate_call_cents":
            if body["p_model"] in self.price_missing:
                raise http_err("No verified price")
            return 1 + (body["p_input_tokens"] + body["p_max_output_tokens"]) // 1000
        if name == "reserve_llm_budget":
            if self.reserve_exc:
                raise self.reserve_exc
            return "call-1"
        return None


def resp(tin=1000, tout=500, searches=0):
    usage = types.SimpleNamespace(input_tokens=tin, output_tokens=tout,
                                  server_tool_use=types.SimpleNamespace(web_search_requests=searches))
    return types.SimpleNamespace(usage=usage, content=[])


class Client:
    def __init__(self, exc=None, r=None):
        self.messages = self; self.exc = exc; self.r = r or resp(); self.kw = None

    def create(self, **kw):
        self.kw = kw
        if self.exc:
            raise self.exc
        return self.r


class T(unittest.TestCase):
    def run_it(self, gate, client=None, **kw):
        client = client or Client()
        with mock.patch.object(hq, "_request", gate), mock.patch.object(hq, "hq_enabled", return_value=True):
            return MT.metered_create(client, "owner chat", model="claude-opus-5-5", max_tokens=2048,
                                     messages=[{"role": "user", "content": "hi"}], **kw), client

    def test_reserves_then_settles_actual(self):
        g = Gate()
        _, c = self.run_it(g, Client(r=resp(3000, 800, searches=2)),
                           tools=[{"type": "web_search_20250305", "name": "web_search", "max_uses": 5}])
        names = [n for n, _ in g.calls]
        self.assertEqual(names.index("reserve_llm_budget") < names.index("settle_llm_call"), True)
        res = [b for n, b in g.calls if n == "reserve_llm_budget"][0]
        self.assertEqual(res["p_agent"], "jarvis-chat")
        st = [b for n, b in g.calls if n == "settle_llm_call"][0]
        self.assertEqual((st["p_id"], st["p_status"]), ("call-1", "done"))
        self.assertEqual(st["p_actual_cents"], 1 + 3800 // 1000 + 2 * MT.SEARCH_CENTS)  # tokens + 2 searches
        self.assertNotIn("tools_meter", c.kw)  # kwargs pass through untouched

    def test_cap_blocks_with_owner_readable_reason(self):
        g = Gate(reserve_exc=http_err("The company daily spend cap would be exceeded."))
        with self.assertRaises(MT.MeterBlocked) as cm:
            self.run_it(g)
        self.assertIn("cap", str(cm.exception))

    def test_kill_switch_and_missing_agent_run_unmetered(self):
        for msg in ("Kill switch is on.", "Unknown agent jarvis-chat."):
            g = Gate(reserve_exc=http_err(msg))
            r, c = self.run_it(g)
            self.assertIsNotNone(c.kw)  # the owner's chat still ran
            self.assertNotIn("settle_llm_call", [n for n, _ in g.calls])

    def test_hq_down_runs_unmetered(self):
        g = Gate(reserve_exc=urllib.error.URLError("down"))
        r, c = self.run_it(g)
        self.assertIsNotNone(c.kw)

    def test_failed_model_call_releases_reservation(self):
        g = Gate()
        with self.assertRaises(RuntimeError):
            self.run_it(g, Client(exc=RuntimeError("boom")))
        st = [b for n, b in g.calls if n == "settle_llm_call"][0]
        self.assertEqual((st["p_actual_cents"], st["p_status"]), (0, "failed"))

    def test_unknown_model_priced_as_strong_tier(self):
        g = Gate(price_missing={"claude-opus-4-8"})
        client = Client()
        with mock.patch.object(hq, "_request", g), mock.patch.object(hq, "hq_enabled", return_value=True):
            MT.metered_create(client, "owner chat", model="claude-opus-4-8", max_tokens=100, messages=[])
        models = [b["p_model"] for n, b in g.calls if n == "estimate_call_cents"]
        self.assertIn(MT.PRICE_FALLBACK_MODEL, models)
        self.assertIn("reserve_llm_budget", [n for n, _ in g.calls])

    def test_hq_disabled_is_a_plain_call(self):
        g = Gate(); c = Client()
        with mock.patch.object(hq, "_request", g), mock.patch.object(hq, "hq_enabled", return_value=False):
            MT.metered_create(c, "x", model="m", max_tokens=10, messages=[])
        self.assertEqual(g.calls, [])


if __name__ == "__main__":
    unittest.main()


class Record(unittest.TestCase):
    def test_build_cost_recorded_in_cad(self):
        calls = []
        def fake(method, path, body=None, timeout=30, prefer=None):
            calls.append((method, path, body))
            if path.startswith("/rest/v1/system_state"):
                return [{"usd_to_cad": 1.4}]
            return None
        with mock.patch.object(hq, "_request", fake), mock.patch.object(hq, "hq_enabled", return_value=True):
            MT.record_spent_usd("builder", 0.50, "/build: site")
            MT.record_spent_usd("builder", 0, "/build: nothing")  # zero cost writes nothing
        rows = [b for m, p, b in calls if p == "/rest/v1/llm_calls"]
        self.assertEqual(len(rows), 1)
        self.assertEqual((rows[0]["agent_slug"], rows[0]["actual_cents"], rows[0]["status"]), ("builder", 70, "done"))
