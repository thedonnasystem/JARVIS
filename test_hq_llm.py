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
        if path.endswith("/estimate_call_cents"):
            return 7
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
        kw.setdefault("sources", ["system"])
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
        r = L.complete("s", [{"role": "user", "content": "x"}], division="ffm", task_class="c", env=env(GROQ_API_KEY="a", OPENROUTER_API_KEY="b"), post=post, tracker=tr,
                       sources=["system"])
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
        with self.assertRaises(L.AllProvidersExhausted) as c:
            self.call(e, post)
        self.assertIn("queued the work", str(c.exception))          # the worker leaves the job queued (retry); the Chairman is told plainly
        self.assertIn("sir", str(c.exception).lower())

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
            L.complete("s", [{"role": "user", "content": big}], division="donna", task_class="c", env=env(GROQ_API_KEY="a"), post=lambda *a: ok_resp(), tracker=L.RateTracker(),
                       sources=["system"])
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
        self.assertEqual(L.choose_tier("chat", large_approval="a1"), "large")      # the approval itself is consumed in complete()

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
    def test_cache_hit_makes_no_call(self):
        with mock.patch("hq._request", side_effect=lambda m, p, b=None, **k: "cached text" if p.endswith("jarvis_cache_get") else None):
            r = L.cached_complete("s", [{"role": "user", "content": "x"}], task_class="c", division="donna", env=env(GROQ_API_KEY="a"),
                                  post=lambda *a: self.fail("model called"), sources=["system"])
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


class EnforcedRoutingTests(Base):
    """RVJC B5: client / personal data routing is decided here from the sources and the text, not by a caller flag."""
    E = {"GROQ_API_KEY": "a", "OPENROUTER_API_KEY": "b"}
    SELF = {"GROQ_API_KEY": "a", "JARVIS_SELFHOST_BASE_URL": "http://localhost:8080/v1", "JARVIS_SELFHOST_API_KEY": "s"}

    def test_default_flag_with_client_details_is_refused_for_free_providers(self):
        msg = [{"role": "user", "content": "Call Jane Roe at 613-555-0142 about policy AB12345678"}]
        with self.assertRaises(L.ClientDataRefused):
            L.complete("s", msg, division="ffm", task_class="x", env=self.E, post=lambda *a: self.fail("sent to groq"), tracker=L.RateTracker(), sources=["system"])
        r = L.complete("s", msg, division="ffm", task_class="x", env=self.SELF, post=lambda *a: ok_resp(), tracker=L.RateTracker(), sources=["system"])
        self.assertEqual((r["provider"], r["route"]), ("selfhost", "private"))

    def test_unknown_or_missing_sources_default_deny(self):
        for src in (None, [], ["leads"], ["memory:owner_profile"], ["workspace:acme"], ["job:lead.followup"], ["system", "something_new"]):
            with self.assertRaises(L.ClientDataRefused, msg=src):
                L.complete("s", [{"role": "user", "content": "plain text"}], division="donna", task_class="x", env=self.E, post=lambda *a: self.fail("sent"),
                           tracker=L.RateTracker(), sources=src)

    def test_extra_provider_cannot_take_client_data(self):
        extra = '[{"name": "mine", "base_url": "https://mine.example/v1", "key_env": "M", "client_data_ok": true, "models": {"small": "m"}}]'
        names = [p.name for p in L.load_providers({"M": "k", "JARVIS_LLM_EXTRA_PROVIDERS": extra})]
        self.assertNotIn("mine", names)
        extra = '[{"name": "mine", "base_url": "https://mine.example/v1", "key_env": "M", "models": {"small": "m"}}]'
        with self.assertRaises(L.ClientDataRefused):
            L.complete("s", [{"role": "user", "content": "x"}], division="d", task_class="x", env={"M": "k", "JARVIS_LLM_EXTRA_PROVIDERS": extra},
                       post=lambda *a: self.fail("sent"), tracker=L.RateTracker(), sources=["leads"])

    def test_memory_rows_carry_their_kind(self):
        rows = [{"kind": "owner_profile", "content": "private line"}, {"kind": "fact", "content": "public fact"}]
        with mock.patch("hq._request", side_effect=lambda m, p, b=None, **k: rows if p.endswith("jarvis_memory_search") else None) as rq:
            texts, src = L.retrieve_memory("q", with_sources=True)
        self.assertEqual(src, ["memory:fact", "memory:owner_profile"])
        self.assertEqual(rq.call_args[0][2]["p_destination"], "external")
        self.assertEqual(L.route_class(["identity"] + src, texts), "private")

    def test_private_prompts_are_never_cached(self):
        calls = []
        with mock.patch("hq._request", side_effect=lambda m, p, b=None, **k: calls.append(p) or ({"paid_allowed": False} if "self_fund" in p else None)):
            L.cached_complete("s", [{"role": "user", "content": "x"}], task_class="c", division="d", env=self.SELF, post=lambda *a: ok_resp(),
                              tracker=L.RateTracker(), sources=["leads"])
        self.assertFalse([c for c in calls if "jarvis_cache" in c])


class MoneyHoleTests(Base):
    """RVJC B8 / S1-S3."""
    def test_large_tier_needs_the_single_use_approval_in_complete(self):
        e = env(ANTHROPIC_API_KEY="paid")
        fund = lambda: {"paid_allowed": True, "available_cents": 10000}   # noqa: E731
        with self.assertRaises(L.LargeTierRefused):
            self.call(e, lambda *a: self.fail("large called"), tier="large", fund=fund)
        with self.assertRaises(L.LargeTierRefused):
            self.call(e, lambda *a: self.fail("large called"), tier="large", large_approval="a1", use_approval=lambda a, m: False, fund=fund)
        used = []
        anth = {"content": [{"type": "text", "text": "ok sir"}], "usage": {"input_tokens": 10, "output_tokens": 5}}
        r = self.call(e, lambda *a: anth, tier="large", large_approval="a1", use_approval=lambda a, m: used.append(a) or True, fund=fund)
        self.assertEqual((r["model"], used), ("claude-opus-5-5", ["a1"]))

    def test_extra_providers_cannot_redeclare_paid_vendors_or_builtins(self):
        for extra in ('[{"name": "anthropic", "base_url": "https://api.anthropic.com", "key_env": "K", "paid": false, "models": {"small": "m"}}]',
                      '[{"name": "cheap", "base_url": "https://api.anthropic.com/v1", "key_env": "K", "models": {"small": "m"}}]',
                      '[{"name": "cheap", "base_url": "https://api.openai.com/v1", "key_env": "K", "models": {"small": "m"}}]',
                      '[{"name": "cheap", "base_url": "https://x.example/v1", "key_env": "K", "paid": true, "models": {"small": "m"}}]'):
            ps = {p.name: p for p in L.load_providers({"K": "k", "JARVIS_LLM_EXTRA_PROVIDERS": extra})}
            self.assertFalse("cheap" in ps, extra)
            self.assertTrue(ps["anthropic"].paid)
            self.assertEqual(ps["anthropic"].base_url, "https://api.anthropic.com")

    def test_builtin_prices_cannot_be_overridden(self):
        p = L.Provider(L.CATALOG[7], {"ANTHROPIC_API_KEY": "k", "JARVIS_LLM_PRICES": '{"claude-opus-5-5": {"in": 0, "out": 0}, "other-model": {"in": 1, "out": 1}}'})
        self.assertNotIn("claude-opus-5-5", p.prices); self.assertIn("other-model", p.prices)

    def test_list_content_and_tools_are_counted(self):
        big = "x" * 2_000_000
        with self.assertRaises(L.PromptTooLarge):
            L.complete("s", [{"role": "user", "content": [{"type": "text", "text": big}]}], division="d", task_class="c", env=env(GROQ_API_KEY="a"),
                       post=lambda *a: self.fail("sent"), tracker=L.RateTracker(), sources=["system"])
        tools = [{"name": "t", "description": "y" * 500_000, "parameters": {}}]
        with self.assertRaises(L.PromptTooLarge):
            self.call(env(GROQ_API_KEY="a"), lambda *a: self.fail("sent"), tools=tools)
        self.assertGreaterEqual(L.estimate_tokens("\u4e2d" * 6000), 6000)       # CJK: one token per character, not 1,715

    def test_anthropic_cache_creation_tokens_are_counted(self):
        p = L.Provider(L.CATALOG[7], {"ANTHROPIC_API_KEY": "k"})
        _, tin, _, _ = L.parse(p, {"content": [], "usage": {"input_tokens": 10, "cache_creation_input_tokens": 50000}})
        self.assertGreaterEqual(tin, 50010)

    def test_paid_timeout_and_malformed_answer_settle_at_the_estimate(self):
        e = env(ANTHROPIC_API_KEY="paid")
        fund = lambda: {"paid_allowed": True, "available_cents": 10000}    # noqa: E731

        def timeout(*a):
            raise L.ProviderError("TimeoutError", sent=True)
        with self.assertRaises(L.AllProvidersExhausted):
            self.call(e, timeout, fund=fund)
        self.assertGreater(self.g.settled[-1][1], 0); self.assertEqual(self.g.settled[-1][2], "failed")
        with self.assertRaises(L.AllProvidersExhausted):
            self.call(e, lambda *a: {"weird": True}, fund=fund)
        self.assertEqual(len(self.g.settled), len(self.g.reserved))          # every reservation settled
        self.assertGreater(self.g.settled[-1][1], 0)

    def test_no_redirects_with_the_key_and_bad_base_urls(self):
        import http.server
        import threading
        hits = []

        class H(http.server.BaseHTTPRequestHandler):
            def do_POST(self):
                hits.append((self.path, self.headers.get("Authorization")))
                self.send_response(302); self.send_header("Location", f"http://127.0.0.1:{srv.server_port}/stolen"); self.end_headers()

            def log_message(self, *a):
                pass
        srv = http.server.HTTPServer(("127.0.0.1", 0), H)
        threading.Thread(target=srv.handle_request, daemon=True).start()
        with self.assertRaises(L.ProviderError):
            L._post(f"http://127.0.0.1:{srv.server_port}/v1/chat/completions", {}, {"Authorization": "Bearer secret"}, 5)
        srv.server_close()
        self.assertEqual([h[0] for h in hits], ["/v1/chat/completions"])     # the redirect target was never requested
        for url in ("https://169.254.169.254/v1", "https://user:pw@vm.example/v1", "https://metadata.google.internal/v1"):
            p = L.Provider(L.CATALOG[5], {"JARVIS_SELFHOST_BASE_URL": url, "JARVIS_SELFHOST_API_KEY": "k"})
            self.assertTrue(p.problems(), url)


if __name__ == "__main__":
    unittest.main()
