"""hq_llm: free-tier rotation, client-data rule, paid gating, gateway use, prompt budget, mission guard. No network: transport and HQ are mocked."""
import unittest
from unittest import mock

import hq_llm as L
import hq_meter


def env(**kw):
    return {k: v for k, v in kw.items()}


class Gateway:
    """Records reserve / settle calls; the gateway mock for every test."""

    def __init__(self, refuse=None):
        self.reserved, self.settled, self.refuse, self.n = [], [], refuse, 0

    def reserve(self, agent, est, model, purpose):
        if self.refuse:
            raise hq_meter.MeterBlocked(self.refuse, "kill")
        self.n += 1
        self.reserved.append((agent, est, model, purpose))
        return f"call-{self.n}"

    def request(self, method, path, body=None, **kw):
        if path.endswith("/settle_llm_call"):
            self.settled.append((body["p_id"], body["p_actual_cents"], body["p_status"]))
            return None
        if path.endswith("/jarvis_enqueue"):
            return "job-1"
        if path.endswith("/jarvis_cache_get"):
            return None
        if path.endswith("/jarvis_cache_put"):
            return None
        if path.endswith("/jarvis_self_fund_status"):
            return {"paid_allowed": False}
        raise AssertionError(path)


def ok_resp(text="hi sir"):
    return {"choices": [{"message": {"content": text}}], "usage": {"prompt_tokens": 10, "completion_tokens": 5}}


class Base(unittest.TestCase):
    def setUp(self):
        self.g = Gateway()
        p1 = mock.patch.object(hq_meter, "_reserve_cents", side_effect=self.g.reserve)
        p2 = mock.patch("hq._request", side_effect=self.g.request)
        p3 = mock.patch.object(hq_meter, "_fx", return_value=1.4)
        for p in (p1, p2, p3):
            p.start(); self.addCleanup(p.stop)

    def call(self, e, post, **kw):
        return L.complete("You are Jarvis.", [{"role": "user", "content": "hello"}], division="donna", task_class="chat", env=e, post=post,
                          tracker=L.RateTracker(), **kw)


class RotationTests(Base):
    def test_nothing_configured_is_offline_and_spends_nothing(self):
        with self.assertRaises(L.BrainOffline) as c:
            self.call(env(), lambda *a: self.fail("no call"))
        self.assertIn("sir", str(c.exception).lower())
        self.assertIn("did not switch to a paid provider", str(c.exception))
        self.assertEqual(self.g.reserved, [])

    def test_free_provider_answers_at_zero_cents_through_the_gateway(self):
        r = self.call(env(GROQ_API_KEY="k"), lambda url, body, h, t: ok_resp())
        self.assertEqual((r["provider"], r["cents"]), ("groq", 0))
        self.assertEqual(self.g.reserved[0][0], "jarvis-core")
        self.assertEqual(self.g.reserved[0][1], 0)
        self.assertTrue(self.g.reserved[0][3].startswith("jarvis:donna:-:chat:groq"))
        self.assertEqual(self.g.settled, [("call-1", 0, "done")])

    def test_kill_switch_at_the_gateway_stops_before_any_request(self):
        self.g.refuse = "Kill switch is on."
        with self.assertRaises(hq_meter.MeterBlocked):
            self.call(env(GROQ_API_KEY="k"), lambda *a: self.fail("request sent"))

    def test_rate_limited_provider_rotates_to_the_next(self):
        seen = []

        def post(url, body, h, t):
            seen.append(url)
            if "groq" in url:
                raise L.ProviderError("HTTP 429", 20, True)
            return ok_resp()
        tr = L.RateTracker()
        r = L.complete("s", [{"role": "user", "content": "x"}], division="ffm", task_class="c", env=env(GROQ_API_KEY="a", OPENROUTER_API_KEY="b"), post=post, tracker=tr)
        self.assertEqual(r["provider"], "openrouter")
        self.assertIn("groq: HTTP 429", r["tried"][0])
        self.assertEqual(self.g.settled, [("call-1", 0, "failed"), ("call-2", 0, "done")])
        self.assertGreater(tr.cool["groq"], 0)
        # OpenRouter is asked not to route to providers that collect data
        self.assertTrue(any("openrouter" in u for u in seen))

    def test_all_exhausted_queues_and_tells_the_chairman(self):
        def post(url, body, h, t):
            raise L.ProviderError("HTTP 429", None, True)
        e = env(GROQ_API_KEY="a")
        with self.assertRaises(L.AllProvidersExhausted):
            self.call(e, post)
        r = L.complete_or_queue("s", [{"role": "user", "content": "x"}], division="donna", task_class="c", payload={"q": 1}, env=e, post=post, tracker=L.RateTracker())
        self.assertEqual(r["queued_job"], "job-1")
        self.assertIn("queued the work", r["owner_message"])
        self.assertIn("sir", r["owner_message"].lower())

    def test_paid_provider_is_never_used_without_the_self_funded_budget(self):
        r = self.call(env(ANTHROPIC_API_KEY="paid", GROQ_API_KEY="free"), lambda url, b, h, t: ok_resp(), fund=lambda: {"paid_allowed": False})
        self.assertEqual(r["provider"], "groq")
        with self.assertRaises(L.BrainOffline):
            self.call(env(ANTHROPIC_API_KEY="paid"), lambda *a: self.fail("paid call"), fund=lambda: {"paid_allowed": False})

    def test_paid_gpu_with_budget_is_metered_by_gpu_hour(self):
        clock = iter([100.0, 100.0 + 360.0])
        e = env(JARVIS_GPU_BASE_URL="https://pod.example/v1", JARVIS_GPU_API_KEY="k", JARVIS_GPU_USD_PER_HOUR="1.0", JARVIS_LLM_ORDER="gpu")
        r = L.complete("s", [{"role": "user", "content": "x"}], division="donna", task_class="c", env=e, post=lambda *a: ok_resp(), tracker=L.RateTracker(),
                       fund=lambda: {"paid_allowed": True, "available_cents": 500}, clock=lambda: next(clock))
        self.assertEqual(r["provider"], "gpu")
        self.assertEqual(r["cents"], 14)                       # 0.1 h x $1.00 x 1.4 CAD = 14 cents
        self.assertEqual(self.g.reserved[0][1], 5)             # worst case reserved first: 120 s x $1/h x 1.4 = 4.67 -> ceil 5
        # budget smaller than the estimate: skipped, and nothing else configured
        with self.assertRaises(L.AllProvidersExhausted):
            L.complete("s", [{"role": "user", "content": "x"}], division="donna", task_class="c", env=e, post=lambda *a: ok_resp(), tracker=L.RateTracker(),
                       fund=lambda: {"paid_allowed": True, "available_cents": 1})

    def test_client_data_never_goes_to_a_free_provider(self):
        with self.assertRaises(L.ClientDataRefused) as c:
            self.call(env(GROQ_API_KEY="a", OPENROUTER_API_KEY="b"), lambda *a: self.fail("client data sent"), contains_client_data=True)
        self.assertIn("sir", str(c.exception).lower())
        r = self.call(env(GROQ_API_KEY="a", JARVIS_SELFHOST_BASE_URL="http://localhost:8080/v1", JARVIS_SELFHOST_API_KEY="s"),
                      lambda url, b, h, t: ok_resp(), contains_client_data=True)
        self.assertEqual(r["provider"], "selfhost")

    def test_training_providers_need_the_owner_opt_in(self):
        extra = '[{"name": "trainer", "base_url": "https://t.example/v1", "key_env": "T_KEY", "trains": true, "models": {"small": "m"}}]'
        e = env(T_KEY="x", JARVIS_LLM_EXTRA_PROVIDERS=extra)
        with self.assertRaises(L.BrainOffline):
            self.call(e, lambda *a: self.fail("trainer used"))
        e["JARVIS_ALLOW_TRAINING_PROVIDERS"] = "1"
        self.assertEqual(self.call(e, lambda *a: ok_resp())["provider"], "trainer")

    def test_plain_http_only_for_localhost_and_a_key_is_required(self):
        p = L.Provider(L.CATALOG[5], env(JARVIS_SELFHOST_BASE_URL="http://203.0.113.5:8080/v1", JARVIS_SELFHOST_API_KEY="k"))
        self.assertTrue(any("https" in x for x in p.problems()))
        p = L.Provider(L.CATALOG[5], env(JARVIS_SELFHOST_BASE_URL="https://vm.example/v1"))
        self.assertTrue(any("not set" in x for x in p.problems()))

    def test_free_prompt_size_limit(self):
        big = "word " * 30000
        with self.assertRaises(L.AllProvidersExhausted) as c:
            L.complete("s", [{"role": "user", "content": big}], division="donna", task_class="c", env=env(GROQ_API_KEY="a"), post=lambda *a: ok_resp(), tracker=L.RateTracker())
        self.assertIn("too big for a free tier", str(c.exception))


class LimitTests(unittest.TestCase):
    def test_rpm_rpd_tpm_and_backoff(self):
        t = [1000.0]
        tr = L.RateTracker(clock=lambda: t[0])
        p = L.Provider({"name": "x", "base_url": "https://x.example/v1", "key_env": "K", "models": {"small": "m"}, "limits": {"rpm": 2, "rpd": 3, "tpm": 100}}, {"K": "k"})
        self.assertTrue(tr.allows(p, 10)); tr.record(p, 10)
        self.assertTrue(tr.allows(p, 10)); tr.record(p, 10)
        self.assertFalse(tr.allows(p, 10))                 # 2 per minute
        t[0] += 61
        self.assertFalse(tr.allows(p, 200))                # over tokens per minute
        self.assertTrue(tr.allows(p, 10)); tr.record(p, 10)
        t[0] += 61
        self.assertFalse(tr.allows(p, 10))                 # 3 per day
        t[0] += 86400
        self.assertTrue(tr.allows(p, 10))
        self.assertEqual(tr.penalize(p), 30.0); self.assertEqual(tr.penalize(p), 60.0)
        self.assertFalse(tr.allows(p, 1))
        self.assertEqual(tr.penalize(p, retry_after=5), 5)


class PromptAndRoutingTests(unittest.TestCase):
    def test_stable_prefix_and_retrieval_trimming(self):
        system, msgs, used = L.build_messages("IDENTITY sir", "core facts", ["m1 " * 10, "m2 " * 3000, "m3"], "the task", max_tokens=600, max_output=100)
        self.assertTrue(system.startswith("IDENTITY sir"))
        self.assertIn("core facts", system)
        self.assertIn("m1", msgs[0]["content"])
        self.assertNotIn("m2", msgs[0]["content"])       # dropped: does not fit
        self.assertTrue(msgs[0]["content"].endswith("the task"))
        self.assertLessEqual(used, 600)
        with self.assertRaises(L.PromptTooLarge):
            L.build_messages("I", "", [], "x" * 10000, max_tokens=600)

    def test_tiers(self):
        self.assertEqual(L.choose_tier("chat"), "small")
        self.assertEqual(L.choose_tier("chat", quality_failed=True), "medium")
        self.assertEqual(L.choose_tier("code.review"), "medium")
        with self.assertRaises(L.LargeTierRefused):
            L.choose_tier("chat", large_approval="a1", use_approval=lambda a, m: False)
        self.assertEqual(L.choose_tier("chat", large_approval="a1", use_approval=lambda a, m: True), "large")

    def test_prompt_caching_only_where_supported(self):
        anth = L.Provider(L.CATALOG[7], {"ANTHROPIC_API_KEY": "k"})
        _, body, _ = L.request_body(anth, "claude-haiku-5-5", "SYS", [{"role": "user", "content": "x"}], 10, None)
        self.assertEqual(body["system"][0]["cache_control"], {"type": "ephemeral"})
        orr = L.Provider(L.CATALOG[2], {"OPENROUTER_API_KEY": "k"})
        url, body, h = L.request_body(orr, "m", "SYS", [{"role": "user", "content": "x"}], 10, None)
        self.assertNotIn("cache_control", str(body))
        self.assertEqual(body["messages"][0], {"role": "system", "content": "SYS"})
        self.assertEqual(body["provider"], {"data_collection": "deny"})
        self.assertTrue(url.endswith("/chat/completions"))

    def test_default_order_is_free_first_and_paid_last(self):
        names = [p.name for p in L.load_providers({})]
        self.assertEqual(names[:6], ["groq", "cerebras", "openrouter", "github", "nvidia", "selfhost"])
        self.assertEqual({p.name for p in L.load_providers({}) if p.paid}, {"gpu", "anthropic"})
        self.assertTrue(all(not p.trains for p in L.load_providers({})))
        self.assertEqual([p.name for p in L.load_providers({}) if p.client_data_ok], ["selfhost", "gpu"])


class GuardAndCacheTests(Base):
    def test_mission_guard(self):
        g = L.MissionGuard(budget_cents=10, max_steps=5, repeat_limit=2, stall_limit=2)
        g.before_step(5); g.after_step("a", 5, True)
        with self.assertRaises(L.MissionStopped):
            g.before_step(6)
        g2 = L.MissionGuard(100, repeat_limit=2)
        g2.after_step("Same  answer", 0, True)
        with self.assertRaises(L.MissionStopped):
            g2.after_step("same answer", 0, True)
        g3 = L.MissionGuard(100, stall_limit=2)
        g3.after_step("a", 0, False)
        with self.assertRaises(L.MissionStopped):
            g3.after_step("b", 0, False)

    def test_cache_hit_makes_no_call(self):
        with mock.patch("hq._request", side_effect=lambda m, p, b=None, **k: "cached text" if p.endswith("jarvis_cache_get") else None):
            r = L.cached_complete("s", [{"role": "user", "content": "x"}], task_class="c", division="donna", env=env(GROQ_API_KEY="a"),
                                  post=lambda *a: self.fail("model called"))
        self.assertEqual((r["text"], r["cents"], r["cached"]), ("cached text", 0, True))

    def test_tool_calling_check(self):
        p = L.Provider(L.CATALOG[0], {"GROQ_API_KEY": "k"})
        resp = {"choices": [{"message": {"content": "", "tool_calls": [{"function": {"name": "get_time", "arguments": "{\"city\":\"Ottawa\"}"}}]}}], "usage": {}}
        r = L.check_tool_calling(p, post=lambda url, body, h, t: resp, tracker=L.RateTracker(), env={"GROQ_API_KEY": "k"})
        self.assertTrue(r["ok"])

    def test_health_reports_missing_model(self):
        p = L.Provider(L.CATALOG[5], {"JARVIS_SELFHOST_BASE_URL": "https://vm.example/v1", "JARVIS_SELFHOST_API_KEY": "k"})
        self.assertTrue(L.health(p, get=lambda u: {"data": [{"id": "hermes-8b-q4"}]})["ok"])
        self.assertFalse(L.health(p, get=lambda u: {"data": [{"id": "other"}]})["ok"])
        self.assertFalse(L.health(p, get=lambda u: (_ for _ in ()).throw(OSError("down")))["ok"])


if __name__ == "__main__":
    unittest.main()
