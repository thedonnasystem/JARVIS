"""Open brain (Nov 22 2026): owner chat and mission tasks on free open models through hq_llm's rotation.

Proves: provider failover; a tool-call round trip in OpenAI format (and its Anthropic conversion); a provider whose tool calls are broken is skipped;
privacy routing (client data never goes to a free provider, even with the owner's switch on; owner chat refused while the switch is off; owner data only
to the no-training providers); Anthropic is never used while paid providers are off and is the last resort when on; every call goes through the spend
gateway first (free = 0 cents) and a gateway refusal means no provider call; the bot's chat loop and the engine's task path on the open brain."""
import asyncio
import json
import os
import unittest
from unittest import mock

os.environ.setdefault("TELEGRAM_BOT_TOKEN", "test")
os.environ.setdefault("ANTHROPIC_API_KEY", "sk-test")
os.environ.setdefault("JARVIS_OWNER_ID", "1")

import hq  # noqa: E402
import hq_engine as E  # noqa: E402
import hq_llm as L  # noqa: E402
import hq_meter as MT  # noqa: E402
import hq_open_brain as OB  # noqa: E402

ENV = {"GROQ_API_KEY": "g", "CEREBRAS_API_KEY": "c", "OPENROUTER_API_KEY": "o", "GITHUB_MODELS_TOKEN": "h", "NVIDIA_API_KEY": "n",
       "ANTHROPIC_API_KEY": "a", "JARVIS_OPEN_BRAIN": "1"}
TOOLS = [{"name": "hq_company_status", "description": "status", "input_schema": {"type": "object", "properties": {}}},
         {"name": "web_search", "type": "web_search_20250305"}]            # a server tool: dropped for open models


def ok(text="hi", calls=None):
    return {"choices": [{"message": {"content": text, "tool_calls": calls}}], "usage": {"prompt_tokens": 10, "completion_tokens": 5}}


class Post:
    """Fake transport: per-provider host -> list of answers (dict = return, Exception = raise)."""

    def __init__(self, plan):
        self.plan, self.calls = plan, []

    def __call__(self, url, body, headers, timeout):
        host = url.split("/")[2]
        self.calls.append((host, body))
        for key, answers in self.plan.items():
            if key in host:
                a = answers.pop(0) if len(answers) > 1 else answers[0]
                if isinstance(a, Exception):
                    raise a
                return a
        raise AssertionError(f"unexpected provider {host}")

    def hosts(self):
        return [h for h, _ in self.calls]


class Gate:
    def __init__(self, refuse=None):
        self.refuse, self.reserved, self.settled = refuse, [], []

    def reserve(self, agent, cents, model, purpose):
        if self.refuse:
            raise MT.MeterBlocked(self.refuse, "cap")
        self.reserved.append((agent, cents, model, purpose))
        return f"c{len(self.reserved)}"


def run(**kw):
    gate = kw.pop("gate", Gate())
    with mock.patch.object(MT, "_reserve_cents", side_effect=gate.reserve), \
            mock.patch.object(L, "_settle", side_effect=lambda cid, cents, status: gate.settled.append((cid, cents, status))):
        r = L.complete(kw.pop("system", "sys"), kw.pop("messages", [{"role": "user", "content": "what is our plan today"}]), division="jarvis",
                       task_class=kw.pop("task_class", "owner.chat"), tier=kw.pop("tier", "medium"), env=kw.pop("env", ENV),
                       tracker=kw.pop("tracker", L.RateTracker()), fund=kw.pop("fund", lambda: {"paid_allowed": False}), **kw)
    return r, gate


class Failover(unittest.TestCase):
    def test_rate_limited_provider_rotates_to_the_next(self):
        post = Post({"groq": [L.ProviderError("HTTP 429", 30, True)], "cerebras": [ok("from cerebras")]})
        tr = L.RateTracker()
        r, gate = run(post=post, sources=["system"], tracker=tr)
        self.assertEqual((r["provider"], r["text"]), ("cerebras", "from cerebras"))
        self.assertEqual(post.hosts(), ["api.groq.com", "api.cerebras.ai"])
        self.assertIn("groq", tr.status())                                         # groq is cooling down now
        self.assertEqual([s[1:] for s in gate.settled], [(0, "failed"), (0, "done")])  # free: reserved and settled at 0
        self.assertTrue(all(c == 0 for _, c, _, _ in gate.reserved))

    def test_everything_exhausted_without_paid_is_exhausted_reply_and_no_anthropic(self):
        err = L.ProviderError("HTTP 429", 30, True)
        post = Post({"groq": [err], "cerebras": [err], "openrouter": [err], "github": [err], "nvidia": [err], "anthropic": [ok()]})
        with self.assertRaises(L.AllProvidersExhausted) as cm:
            run(post=post, sources=["system"])
        self.assertTrue(str(cm.exception).startswith(L.EXHAUSTED_REPLY))
        self.assertNotIn("api.anthropic.com", post.hosts())

    def test_anthropic_is_the_last_resort_only_with_paid_on(self):
        err = L.ProviderError("HTTP 429", 30, True)
        anth = {"content": [{"type": "text", "text": "paid"}], "usage": {"input_tokens": 10, "output_tokens": 5}}
        post = Post({"groq": [err], "cerebras": [err], "openrouter": [err], "github": [err], "nvidia": [err], "anthropic": [anth]})
        with mock.patch.object(MT, "_estimate", return_value=5):
            r, gate = run(post=post, sources=["system"], fund=lambda: {"paid_allowed": True, "available_cents": 500})
        self.assertEqual(r["provider"], "anthropic")
        self.assertEqual(post.hosts()[-1], "api.anthropic.com")
        self.assertEqual(post.hosts().index("api.anthropic.com"), len(post.hosts()) - 1)       # after every free provider
        self.assertGreater(gate.reserved[-1][1], 0)                                               # paid: a real reservation

    def test_gateway_refusal_means_no_provider_call(self):
        post = Post({"groq": [ok()]})
        with self.assertRaises(MT.MeterBlocked):
            run(post=post, sources=["system"], gate=Gate(refuse="The company daily spend cap would be exceeded."))
        self.assertEqual(post.calls, [])


class ToolCalling(unittest.TestCase):
    def test_round_trip_openai_format(self):
        call = [{"id": "call_1", "type": "function", "function": {"name": "hq_company_status", "arguments": "{}"}}]
        post = Post({"groq": [ok("", call)]})
        r, _ = run(post=post, sources=["system"], tools=TOOLS)
        body = post.calls[0][1]
        self.assertEqual([t["function"]["name"] for t in body["tools"]], ["hq_company_status"])      # server tool dropped
        self.assertEqual(body["tools"][0]["function"]["parameters"], {"type": "object", "properties": {}})
        self.assertEqual(r["tool_calls"], [{"id": "call_1", "name": "hq_company_status", "arguments": {}}])
        # the next round carries the assistant tool turn and the tool result
        msgs = [{"role": "user", "content": "status?"}, OB.assistant_turn(r), OB.tool_turn("call_1", "all good")]
        post2 = Post({"groq": [ok("All good, sir.")]})
        r2, _ = run(post=post2, sources=["system"], tools=TOOLS, messages=msgs)
        sent = post2.calls[0][1]["messages"]
        self.assertEqual(sent[-1], {"role": "tool", "tool_call_id": "call_1", "content": "all good"})
        self.assertEqual(sent[-2]["tool_calls"][0]["function"]["name"], "hq_company_status")
        self.assertEqual(r2["text"], "All good, sir.")

    def test_broken_tool_calls_rotate_to_the_next_provider(self):
        bad_name = [{"id": "x", "function": {"name": "rm_rf", "arguments": "{}"}}]
        bad_json = [{"id": "y", "function": {"name": "hq_company_status", "arguments": "{not json"}}]
        good = [{"id": "z", "function": {"name": "hq_company_status", "arguments": "{}"}}]
        post = Post({"groq": [ok("", bad_name)], "cerebras": [ok("", bad_json)], "openrouter": [ok("", good)]})
        r, gate = run(post=post, sources=["system"], tools=TOOLS)
        self.assertEqual(r["provider"], "openrouter")
        self.assertEqual([s[2] for s in gate.settled], ["failed", "failed", "done"])

    def test_anthropic_conversion(self):
        msgs = [{"role": "user", "content": "q"},
                {"role": "assistant", "content": "", "tool_calls": [{"id": "t1", "type": "function", "function": {"name": "a", "arguments": "{\"k\": 1}"}},
                                                                      {"id": "t2", "type": "function", "function": {"name": "b", "arguments": "{}"}}]},
                {"role": "tool", "tool_call_id": "t1", "content": "r1"}, {"role": "tool", "tool_call_id": "t2", "content": "r2"}]
        out = L._anthropic_messages(msgs)
        self.assertEqual(out[1]["content"][0], {"type": "tool_use", "id": "t1", "name": "a", "input": {"k": 1}})
        self.assertEqual([b["tool_use_id"] for b in out[2]["content"]], ["t1", "t2"])                  # results merged into one user turn
        p = [x for x in L.load_providers(ENV) if x.name == "anthropic"][0]
        _, body, _ = L.request_body(p, "m", "s", msgs, 100, TOOLS)
        self.assertEqual(body["tools"], [{"name": "hq_company_status", "description": "status", "input_schema": {"type": "object", "properties": {}}}])
        calls = L.normalize_calls(p, [{"type": "tool_use", "id": "t9", "name": "hq_company_status", "input": {}}], {"hq_company_status"})
        self.assertEqual(calls, [{"id": "t9", "name": "hq_company_status", "arguments": {}}])


class Privacy(unittest.TestCase):
    def test_owner_chat_refused_while_the_switch_is_off(self):
        post = Post({"groq": [ok()]})
        with self.assertRaises(L.OwnerChatRefused):
            run(post=post, sources=["owner_chat"], owner_free=False)
        self.assertEqual(post.calls, [])

    def test_unreadable_switch_counts_as_off(self):
        post = Post({"groq": [ok()]})
        with mock.patch.object(hq, "_request", side_effect=RuntimeError("db down")):
            self.assertFalse(L.owner_free_allowed())
            with self.assertRaises(L.OwnerChatRefused):
                run(post=post, sources=["owner_chat"])
        self.assertEqual(post.calls, [])

    def test_owner_chat_with_the_switch_on_only_reaches_no_training_providers(self):
        err = L.ProviderError("HTTP 429", 30, True)
        post = Post({"groq": [err], "cerebras": [err], "openrouter": [err], "github": [ok()], "nvidia": [ok()]})
        with self.assertRaises(L.AllProvidersExhausted):
            run(post=post, sources=["owner_chat", "owner_tool"], owner_free=True)
        self.assertEqual(post.hosts(), ["api.groq.com", "api.cerebras.ai", "openrouter.ai"])           # never github / nvidia
        post = Post({"groq": [ok("yes")]})
        r, _ = run(post=post, sources=["owner_chat"], owner_free=True)
        self.assertEqual((r["provider"], r["data_class"]), ("groq", "owner"))
        self.assertEqual(post.calls[0][1].get("provider") if "openrouter" in post.hosts()[0] else None, None)

    def test_openrouter_is_routed_with_data_collection_deny(self):
        err = L.ProviderError("HTTP 429", 30, True)
        post = Post({"groq": [err], "cerebras": [err], "openrouter": [ok()]})
        run(post=post, sources=["owner_chat"], owner_free=True)
        self.assertEqual(post.calls[-1][1]["provider"], {"data_collection": "deny"})

    def test_client_data_never_goes_to_a_free_provider_even_with_the_switch_on(self):
        for msgs, sources in (([{"role": "user", "content": "Call client Jane Roe at 613-555-0199 about her mortgage"}], ["owner_chat"]),
                              ([{"role": "user", "content": "summarise this"}], ["owner_chat", "leads"]),
                              ([{"role": "user", "content": "ok"}, {"role": "tool", "tool_call_id": "1", "content": "lead: jane@example.com"}], ["owner_chat", "owner_tool"])):
            post = Post({"groq": [ok()], "cerebras": [ok()], "openrouter": [ok()], "github": [ok()], "nvidia": [ok()], "anthropic": [ok()]})
            with self.assertRaises(L.ClientDataRefused):
                run(post=post, sources=sources, messages=msgs, owner_free=True, fund=lambda: {"paid_allowed": True, "available_cents": 500})
            self.assertEqual(post.calls, [], sources)

    def test_client_data_goes_to_the_self_hosted_model_only(self):
        env = {**ENV, "JARVIS_SELFHOST_BASE_URL": "https://brain.example.org/v1", "JARVIS_SELFHOST_API_KEY": "s"}
        post = Post({"brain.example.org": [ok("local")], "groq": [ok()]})
        r, _ = run(post=post, sources=["owner_chat"], env=env, owner_free=True,
                   messages=[{"role": "user", "content": "Call client Jane Roe at 613-555-0199"}])
        self.assertEqual((r["provider"], post.hosts()), ("selfhost", ["brain.example.org"]))

    def test_client_data_never_reaches_a_non_catalog_provider_marked_client_ok(self):
        rogue = L.Provider({"name": "rogue", "base_url": "https://rogue.example.org/v1", "key_env": "ROGUE_KEY", "paid": False, "trains": False,
                            "client_data_ok": True, "models": {"small": "m", "medium": "m"}}, {"ROGUE_KEY": "k"})
        post = Post({"rogue.example.org": [ok()]})
        with self.assertRaises(L.ClientDataRefused):
            run(post=post, providers=[rogue], sources=["owner_chat"], owner_free=True,
                messages=[{"role": "user", "content": "Call client Jane Roe at 613-555-0199"}])
        self.assertEqual(post.calls, [])

    def test_owner_data_never_reaches_a_training_provider_even_with_training_allowed(self):
        env = {"GEMINI_API_KEY": "gm", "JARVIS_OPEN_BRAIN": "1", "JARVIS_ALLOW_TRAINING_PROVIDERS": "1", "JARVIS_LLM_ORDER": "gemini"}
        post = Post({"generativelanguage.googleapis.com": [ok()]})
        with self.assertRaises(L.OwnerChatRefused):
            run(post=post, env=env, sources=["owner_chat"], owner_free=True, training_ok=True)
        self.assertEqual(post.calls, [])

    def test_chat_wrapper_declares_owner_sources(self):
        with mock.patch.object(L, "complete", return_value={"text": "x"}) as cp:
            OB.chat("s", [{"role": "user", "content": "hi"}], None, "owner chat")
            self.assertEqual(cp.call_args.kwargs["sources"], ["owner_chat"])
            OB.chat("s", [{"role": "user", "content": "hi"}, {"role": "tool", "tool_call_id": "1", "content": "r"}], None, "owner chat (tool round)")
            self.assertEqual(cp.call_args.kwargs["sources"], ["owner_chat", "owner_tool"])
        post = Post({"groq": [ok()]})
        with mock.patch.object(MT, "_reserve_cents", return_value="c1"), mock.patch.object(L, "_settle"):
            with self.assertRaises(L.OwnerChatRefused):                                             # switch off: refused, nothing sent
                OB.chat("s", [{"role": "user", "content": "plan my week"}], None, "owner chat", owner_free=False, post=post,
                        env=ENV, fund=lambda: {"paid_allowed": False})
        self.assertEqual(post.calls, [])

    def test_public_prompts_still_use_every_free_provider(self):
        err = L.ProviderError("HTTP 500")
        post = Post({"groq": [err], "cerebras": [err], "openrouter": [err], "github": [ok("gh")]})
        r, _ = run(post=post, sources=["system"])
        self.assertEqual(r["provider"], "github")


class Budgets(unittest.TestCase):
    def test_per_provider_prompt_budget_and_env_override(self):
        p = {x.name: x for x in L.load_providers({**ENV, "JARVIS_GROQ_MAX_PROMPT_TOKENS": "3000"})}
        self.assertEqual(p["groq"].max_prompt, 3000)
        self.assertEqual(p["cerebras"].max_prompt, 24000)
        big = [{"role": "user", "content": "word " * 9000}]                                # ~13k tokens: too big for groq (3000), fine for cerebras
        post = Post({"cerebras": [ok("c")]})
        r, _ = run(post=post, sources=["system"], messages=big, env={**ENV, "JARVIS_GROQ_MAX_PROMPT_TOKENS": "3000"})
        self.assertEqual(r["provider"], "cerebras")

    def test_models_come_from_env_without_code(self):
        p = {x.name: x for x in L.load_providers({**ENV, "JARVIS_GROQ_MODEL_MEDIUM": "openai/gpt-oss-120b", "JARVIS_OPENROUTER_MODEL_MEDIUM": "deepseek/deepseek-r1:free"})}
        self.assertEqual(p["groq"].model("medium"), "openai/gpt-oss-120b")
        self.assertEqual(p["openrouter"].model("medium"), "deepseek/deepseek-r1:free")

    def test_history_fits_and_starts_with_the_owner(self):
        h = [{"role": "assistant", "content": "x"}] + [{"role": r, "content": "y" * 400} for r in ("user", "assistant") * 20]
        out = OB.fit_history(h)
        self.assertLessEqual(len(out), OB.HISTORY_MAX_MESSAGES)
        self.assertEqual(out[0]["role"], "user")
        self.assertLessEqual(sum(L.estimate_tokens(m["content"]) for m in out), OB.HISTORY_TOKENS)


class BotChat(unittest.TestCase):
    def setUp(self):
        import bot
        self.bot = bot

    def _reply(self, chat_results, dispatch=None, kill=False):
        b = self.bot
        saved = []
        it = iter(chat_results)

        def fake_chat(system, msgs, tools, purpose, **kw):
            self.sent.append((purpose, [dict(m) for m in msgs]))
            self.sys.append(system)
            x = next(it)
            if isinstance(x, Exception):
                raise x
            return x
        self.sent, self.sys = [], []
        ctx = mock.MagicMock()
        ctx.bot.send_chat_action = mock.AsyncMock()
        with mock.patch.dict(os.environ, {"JARVIS_OPEN_BRAIN": "1"}), mock.patch.object(b, "load_history", return_value=[]), \
                mock.patch.object(b, "save_message", side_effect=lambda c, r, t: saved.append((r, t))), \
                mock.patch.object(OB, "chat", side_effect=fake_chat), mock.patch.object(b.hq, "hq_enabled", return_value=False), \
                mock.patch.object(OB, "memory_facts", return_value=[]), mock.patch.object(OB, "refresh_summary", side_effect=lambda h, prev, save, **k: prev), \
                mock.patch.object(b, "recall", return_value=[]), \
                mock.patch.object(b, "dispatch_tool_call", new=dispatch or mock.AsyncMock(return_value="done")), \
                mock.patch.object(MT, "kill_switch_on", return_value=kill), \
                mock.patch.object(b.anthropic_client.messages, "create", side_effect=AssertionError("Anthropic must not be called")):
            out = asyncio.run(b.jarvis_reply(1, "status please", ctx, typing=False))
        return out, saved

    def test_tool_round_then_answer_and_credentials_withheld(self):
        call = {"text": "", "tool_calls": [{"id": "c1", "name": "get_credential", "arguments": {"name": "x"}}]}

        async def dispatch(name, args, context, chat_id, redact):
            redact.append("SECRET123")
            return "the key is SECRET123"
        out, saved = self._reply([call, {"text": "Here you go, sir.", "tool_calls": []}], dispatch=dispatch)
        self.assertEqual(out, "Here you go, sir.")
        tool_msg = self.sent[1][1][-1]
        self.assertEqual(tool_msg["role"], "tool")
        self.assertNotIn("SECRET123", tool_msg["content"])
        self.assertEqual(self.sent[1][0], "owner chat (tool round)")
        self.assertEqual(saved, [("user", "status please"), ("assistant", "Here you go, sir.")])

    def test_many_tool_results_are_trimmed_before_the_next_round(self):
        calls = {"text": "", "tool_calls": [{"id": f"c{i}", "name": "hq_company_status", "arguments": {}} for i in range(20)]}
        out, _ = self._reply([calls, {"text": "Done.", "tool_calls": []}], dispatch=mock.AsyncMock(return_value="r " * 2000))
        self.assertEqual(out, "Done.")
        self.assertLessEqual(OB.packet_tokens(self.sys[1], self.sent[1][1], None), OB.PACKET_CAP)

    def test_exhausted_is_the_exhausted_reply_and_not_saved(self):
        out, saved = self._reply([L.AllProvidersExhausted(L.EXHAUSTED_REPLY + " (groq: at its limit)")])
        self.assertEqual(out, L.EXHAUSTED_REPLY)
        self.assertEqual(saved, [])

    def test_owner_chat_refused_and_kill_switch_first(self):
        out, _ = self._reply([L.OwnerChatRefused(L.OWNER_CHAT_REPLY)])
        self.assertEqual(out, L.OWNER_CHAT_REPLY)
        out, _ = self._reply([L.OwnerChatRefused(L.OWNER_CHAT_REPLY)], kill=True)
        self.assertIn("Kill switch is ON", out)

    def test_budget_refusal_is_the_deterministic_status(self):
        out, saved = self._reply([MT.MeterBlocked("The company daily spend cap would be exceeded.", "cap")])
        self.assertIn("budget limit", out)
        self.assertEqual(saved, [])

    def test_off_by_default(self):
        with mock.patch.dict(os.environ, {"JARVIS_OPEN_BRAIN": ""}):
            self.assertFalse(OB.enabled())
        with mock.patch.dict(os.environ, {"JARVIS_OPEN_BRAIN": "1"}):
            self.assertTrue(OB.enabled())


class EngineTask(unittest.TestCase):
    def test_mission_task_uses_the_rotation_booked_to_the_agent(self):
        seen = {}

        def fake_complete(system, messages, **kw):
            seen.update(kw)
            return {"text": "done", "provider": "groq", "model": "llama-3.3-70b-versatile", "input_tokens": 5, "output_tokens": 2, "cents": 0}
        agent = [{"slug": "builder", "title": "B", "charter": "c", "metric": "m", "model_tier": "strong", "role": "worker", "status": "active"}]
        with mock.patch.dict(os.environ, {"JARVIS_OPEN_BRAIN": "1"}), mock.patch.object(E, "_get", side_effect=[agent, []]), \
                mock.patch.object(E, "_insert"), mock.patch.object(L, "complete", side_effect=fake_complete), \
                mock.patch.object(E, "_anthropic", side_effect=AssertionError("Anthropic must not be called")):
            out = E.run_turn_sync("builder", "do the thing", 900, "mission:abc task:1")
        self.assertEqual(out, "done")
        self.assertEqual((seen["agent"], seen["purpose_text"], seen["tier"], seen["sources"], seen["job"]), ("builder", "mission:abc task:1", "reason", ["owner_mission"], "reason"))

    def test_gateway_refusal_becomes_gateway_blocked(self):
        agent = [{"slug": "builder", "title": "B", "charter": "c", "metric": "m", "model_tier": "cheap", "role": "worker", "status": "active"}]
        with mock.patch.dict(os.environ, {"JARVIS_OPEN_BRAIN": "1"}), mock.patch.object(E, "_get", side_effect=[agent, []]), mock.patch.object(E, "_insert"), \
                mock.patch.object(L, "complete", side_effect=MT.MeterBlocked("Kill switch is on.", "kill")):
            with self.assertRaises(E.GatewayBlocked):
                E.run_turn_sync("builder", "do the thing", 900, "task x")


class Status(unittest.TestCase):
    def test_status_text(self):
        tr = L.RateTracker()
        p = [x for x in L.load_providers(ENV) if x.name == "groq"][0]
        tr.answered(p, "llama-3.3-70b-versatile", "owner.chat")
        tr.penalize([x for x in L.load_providers(ENV) if x.name == "cerebras"][0], 120)
        with mock.patch.dict(os.environ, {**ENV, "JARVIS_OPEN_BRAIN": "1"}), mock.patch.object(L, "TRACKER", tr), \
                mock.patch.object(L, "owner_free_allowed", return_value=False):
            t = OB.status_text()
        self.assertIn("Last answer: groq / llama-3.3-70b-versatile (owner.chat", t)
        self.assertIn("- cerebras: COOLING", t)
        self.assertIn("- github: ready", t)
        self.assertIn("public prompts only", t)
        self.assertIn("Owner chat on free providers: off", t)


FULL = {"GROQ_API_KEY": "g", "CEREBRAS_API_KEY": "c", "OPENROUTER_API_KEY": "o", "GITHUB_MODELS_TOKEN": "h", "NVIDIA_API_KEY": "n",
        "CLOUDFLARE_ACCOUNT_ID": "abc123", "CLOUDFLARE_API_TOKEN": "cf", "GEMINI_API_KEY": "gm", "ANTHROPIC_API_KEY": "a",
        "JARVIS_SELFHOST_BASE_URL": "https://oracle.example.org/v1", "JARVIS_SELFHOST_API_KEY": "s1",
        "JARVIS_SELFHOST2_BASE_URL": "https://mac.example.org/v1", "JARVIS_SELFHOST2_API_KEY": "ollama", "JARVIS_OPEN_BRAIN": "1"}
HOST = {"groq": "api.groq.com", "cerebras": "api.cerebras.ai", "openrouter": "openrouter.ai", "github": "models.github.ai", "nvidia": "integrate.api.nvidia.com",
        "cloudflare": "api.cloudflare.com", "gemini": "generativelanguage.googleapis.com", "selfhost": "oracle.example.org", "selfhost2": "mac.example.org",
        "anthropic": "api.anthropic.com"}
ANTH_OK = {"content": [{"type": "text", "text": "paid"}], "usage": {"input_tokens": 3, "output_tokens": 1}}


class PrivacyMatrix(unittest.TestCase):
    """Which data class can reach which provider: each provider alone, every switch combination."""

    def reach(self, name, klass, owner_on=False, train_on=False, paid=False):
        env = {k: v for k, v in FULL.items() if k in ("JARVIS_OPEN_BRAIN", "CLOUDFLARE_ACCOUNT_ID") or name.upper() in k.upper() or
               (name == "selfhost" and k.startswith("JARVIS_SELFHOST_")) or (name == "selfhost2" and k.startswith("JARVIS_SELFHOST2_"))
               or (name == "github" and k == "GITHUB_MODELS_TOKEN") or (name == "cloudflare" and k.startswith("CLOUDFLARE"))}
        env["JARVIS_LLM_ORDER"] = name
        msg = {"public": ("what is the capital of france", ["system"]), "owner": ("plan my week", ["owner_chat"]),
               "client": ("Call client Jane Roe at 613-555-0199", ["owner_chat"])}[klass]
        post = Post({HOST[name]: [ANTH_OK if name == "anthropic" else ok("x")]})
        try:
            with mock.patch.object(MT, "_estimate", return_value=1):
                run(post=post, env=env, sources=msg[1], messages=[{"role": "user", "content": msg[0]}], job="bulk", owner_free=owner_on,
                    training_ok=train_on, cache=L.ResponseCache(ttl=0), fund=lambda: {"paid_allowed": paid, "available_cents": 500})
        except L.BrainOffline:
            return False
        return bool(post.calls)

    def test_matrix(self):
        names = ["groq", "cerebras", "openrouter", "github", "nvidia", "cloudflare", "gemini", "selfhost", "selfhost2", "anthropic"]
        cases = {
            ("public", False, False, False): {"groq", "cerebras", "openrouter", "github", "nvidia", "cloudflare", "selfhost", "selfhost2"},
            ("public", False, True, False): {"groq", "cerebras", "openrouter", "github", "nvidia", "cloudflare", "gemini", "selfhost", "selfhost2"},
            ("public", False, False, True): {"groq", "cerebras", "openrouter", "github", "nvidia", "cloudflare", "selfhost", "selfhost2", "anthropic"},
            ("owner", False, True, False): {"selfhost", "selfhost2"},
            ("owner", True, True, False): {"groq", "cerebras", "openrouter", "selfhost", "selfhost2"},
            ("owner", True, True, True): {"groq", "cerebras", "openrouter", "selfhost", "selfhost2", "anthropic"},
            ("client", True, True, True): {"selfhost", "selfhost2"},
            ("client", False, False, False): {"selfhost", "selfhost2"},
        }
        for (klass, owner_on, train_on, paid), want in cases.items():
            got = {n for n in names if self.reach(n, klass, owner_on, train_on, paid)}
            self.assertEqual(got, want, (klass, owner_on, train_on, paid))

    def test_gemini_never_takes_owner_or_client_data_and_is_marked_training(self):
        p = {x.name: x for x in L.load_providers(FULL)}
        self.assertTrue(p["gemini"].trains)
        self.assertFalse(p["cloudflare"].trains)
        self.assertNotIn("gemini", L.OWNER_DATA_PROVIDERS)
        self.assertNotIn("cloudflare", L.OWNER_DATA_PROVIDERS)
        self.assertEqual(p["cloudflare"].base_url, "https://api.cloudflare.com/client/v4/accounts/abc123/ai/v1")

    def test_legacy_rotation_unchanged_without_the_open_brain(self):
        names = [x.name for x in L.load_providers({})]
        self.assertNotIn("gemini", names)
        self.assertNotIn("selfhost2", names)


class Routes(unittest.TestCase):
    def go(self, job, klass_msg, sources, plan, **kw):
        post = Post(plan)
        r, _ = run(post=post, env=FULL, sources=sources, messages=[{"role": "user", "content": klass_msg}], job=job, owner_free=True,
                   training_ok=kw.pop("training_ok", True), cache=L.ResponseCache(ttl=0), tier=ROUTE_TIER[job], **kw)
        return r, post

    def test_chat_route_order(self):
        err = L.ProviderError("HTTP 429", 30, True)
        r, post = self.go("chat", "plan my week", ["owner_chat"], {"api.groq.com": [err], "api.cerebras.ai": [err], "openrouter.ai": [ok("or")]})
        self.assertEqual(post.hosts(), ["api.groq.com", "api.cerebras.ai", "openrouter.ai"])
        self.assertEqual(r["provider"], "openrouter")

    def test_chat_route_falls_to_selfhost_then_queue(self):
        err = L.ProviderError("HTTP 429", 30, True)
        plan = {"api.groq.com": [err], "api.cerebras.ai": [err], "openrouter.ai": [err], "oracle.example.org": [err], "mac.example.org": [ok("mac")]}
        r, post = self.go("chat", "plan my week", ["owner_chat"], plan)
        self.assertEqual(r["provider"], "selfhost2")
        plan["mac.example.org"] = [err]
        with self.assertRaises(L.AllProvidersExhausted):
            self.go("chat", "plan my week", ["owner_chat"], plan)

    def test_long_route_prefers_gemini_for_public_and_skips_it_for_owner(self):
        r, post = self.go("long", "summarise this public report", ["public_web"], {"generativelanguage.googleapis.com": [ok("g")]})
        self.assertEqual(r["provider"], "gemini")
        r, post = self.go("long", "summarise my notes", ["owner_chat"], {"openrouter.ai": [ok("o")]})
        self.assertEqual(post.hosts(), ["openrouter.ai"])
        r, post = self.go("long", "summarise this public report", ["public_web"], {"openrouter.ai": [ok("o")]}, training_ok=False)
        self.assertEqual(post.hosts(), ["openrouter.ai"])                                           # gemini needs the owner switch

    def test_reason_route_uses_the_reasoning_models(self):
        r, post = self.go("reason", "plan the launch", ["system"], {"api.groq.com": [ok("plan")]})
        self.assertEqual(post.calls[0][1]["model"], "openai/gpt-oss-120b")
        err = L.ProviderError("HTTP 429", 30, True)
        r, post = self.go("reason", "plan the launch", ["system"], {"api.groq.com": [err], "openrouter.ai": [ok("plan")]})
        self.assertEqual(post.calls[-1][1]["model"], "deepseek/deepseek-r1:free")

    def test_private_route_is_self_hosted_only(self):
        r, post = self.go("private", "Call client Jane Roe at 613-555-0199", ["owner_chat"], {"oracle.example.org": [ok("local")]})
        self.assertEqual(post.hosts(), ["oracle.example.org"])
        err = L.ProviderError("HTTP 500")
        with self.assertRaises(L.AllProvidersExhausted):
            self.go("private", "Call client Jane Roe at 613-555-0199", ["owner_chat"], {"oracle.example.org": [err], "mac.example.org": [err]})

    def test_bulk_route_prefers_headroom(self):
        tr = L.RateTracker()
        p = {x.name: x for x in L.load_providers(FULL)}
        for _ in range(int(p["groq"].limits["rpd"] * 0.95)):
            tr.req.setdefault("groq", []).append(tr.clock() - 3600)                                # used an hour ago: inside rpm, low on rpd
        post = Post({"api.cerebras.ai": [ok("c")], "api.groq.com": [ok("g")]})
        r, _ = run(post=post, env=FULL, sources=["system"], job="bulk", tracker=tr, cache=L.ResponseCache(ttl=0), training_ok=False)
        self.assertNotEqual(r["provider"], "groq")
        self.assertLess(tr.headroom(p["groq"]), 0.1)

    def test_unknown_job_refused(self):
        with self.assertRaises(ValueError):
            run(post=Post({}), env=FULL, sources=["system"], job="everything")


ROUTE_TIER = {"chat": "medium", "long": "medium", "reason": "reason", "private": "medium", "bulk": "small"}


class Cache(unittest.TestCase):
    def test_identical_public_prompt_answered_from_cache(self):
        c = L.ResponseCache(ttl=60)
        post = Post({"api.groq.com": [ok("first"), ok("second")]})
        r1, g1 = run(post=post, env=FULL, sources=["system"], job="bulk", cache=c, training_ok=False)
        r2, g2 = run(post=post, env=FULL, sources=["system"], job="bulk", cache=c, training_ok=False)
        self.assertEqual((r2["text"], r2["provider"], r2["cached"]), ("first", "cache", True))
        self.assertEqual(len(post.calls), 1)
        self.assertEqual(g2.reserved, [])                                                          # no gateway call for a cache hit

    def test_owner_and_client_prompts_never_cached(self):
        c = L.ResponseCache(ttl=60)
        post = Post({"api.groq.com": [ok("a"), ok("b")]})
        run(post=post, env=FULL, sources=["owner_chat"], job="chat", cache=c, owner_free=True)
        run(post=post, env=FULL, sources=["owner_chat"], job="chat", cache=c, owner_free=True)
        self.assertEqual(len(post.calls), 2)
        self.assertEqual(c.items, {})


class LeanPacket(unittest.TestCase):
    TOOLS = [{"name": f"tool_{i}", "description": ("Does thing %d. " % i) + "x " * 300,
              "input_schema": {"type": "object", "properties": {"a": {"type": "string", "description": "y " * 100}}}} for i in range(27)] + \
            [{"name": "hq_company_status", "description": "Fendezy HQ status: spend vs cap, task board.", "input_schema": {"type": "object", "properties": {}}}]

    def test_plain_chat_sends_no_tools(self):
        _, msgs, tools, n = OB.build_packet([], "thanks, that sounds good", self.TOOLS)
        self.assertIsNone(tools)
        self.assertLess(n, 600)

    def test_action_message_gets_few_compact_tools_and_the_named_one(self):
        _, _, tools, n = OB.build_packet([], "show me the hq_company_status please", self.TOOLS)
        self.assertLessEqual(len(tools), OB.MAX_TOOLS)
        self.assertEqual(tools[0]["name"], "hq_company_status")
        self.assertTrue(all(len(t["description"]) <= 140 for t in tools))
        self.assertLessEqual(n, OB.PACKET_CAP)

    def test_packet_never_exceeds_the_cap(self):
        hist = [{"role": r, "content": "z " * 2000} for r in ("user", "assistant") * 10]
        mem = ["fact " * 400] * 10
        for text in ("status of everything " + "q " * 100, "hello", "run the mission " + "w " * 1500):
            system, msgs, tools, n = OB.build_packet(hist, text, self.TOOLS, "s " * 3000, mem)
            self.assertLessEqual(n, OB.PACKET_CAP, text[:20])
            self.assertEqual(n, OB.packet_tokens(system, msgs, tools))
            self.assertLess(OB.PACKET_CAP + OB.CHAT_MAX_OUTPUT, L.FREE_PROMPT_TOKENS)
        with self.assertRaises(L.PromptTooLarge):
            OB.build_packet([], "w " * 20000, self.TOOLS)

    def test_summary_and_memory_are_used_and_only_recent_turns_verbatim(self):
        hist = [{"role": r, "content": f"{r} turn {i}"} for i in range(20) for r in ("user", "assistant")]
        system, msgs, _, _ = OB.build_packet(hist, "what did we decide?", None, "We decided to launch Donna first.", ["Donna serves HVAC"])
        self.assertIn("We decided to launch Donna first.", system)
        self.assertIn("Donna serves HVAC", system)
        self.assertLessEqual(len(msgs), OB.HISTORY_MAX_MESSAGES + 1)
        self.assertNotIn("turn 0", json.dumps(msgs))

    def test_tool_rounds_are_trimmed_under_the_cap(self):
        msgs = [{"role": "user", "content": "status"}, {"role": "assistant", "content": "", "tool_calls": []}] + \
               [{"role": "tool", "tool_call_id": str(i), "content": "r " * 3000} for i in range(4)]
        out = OB.shrink_round(OB.COMPACT_SYSTEM, msgs, None)
        self.assertLessEqual(OB.packet_tokens(OB.COMPACT_SYSTEM, out, None), OB.PACKET_CAP)
        self.assertEqual(out[0], {"role": "user", "content": "status"})

    def test_rolling_summary_refresh(self):
        hist = [{"role": r, "content": f"{r} {i}"} for i in range(10) for r in ("user", "assistant")]
        saved = []
        with mock.patch.object(L, "complete", return_value={"text": "Summary: launch Donna."}) as cp:
            out = OB.refresh_summary(hist, {}, saved.append)
        self.assertEqual(out["summary"], "Summary: launch Donna.")
        self.assertEqual(out["upto"], len(hist) - OB.HISTORY_MAX_MESSAGES)
        self.assertEqual(cp.call_args.kwargs["sources"], ["owner_chat"])                           # same privacy routing as the chat
        self.assertEqual(json.loads(saved[0])["summary"], "Summary: launch Donna.")
        with mock.patch.object(L, "complete") as cp:                                                # nothing new: no call
            self.assertEqual(OB.refresh_summary(hist, out, saved.append), out)
        cp.assert_not_called()
        with mock.patch.object(L, "complete", side_effect=L.OwnerChatRefused("x")):                 # refusal keeps the old summary
            self.assertEqual(OB.refresh_summary(hist + hist, out, saved.append), out)

    def test_packet_size_is_logged_for_status(self):
        tr = L.RateTracker()
        post = Post({"api.groq.com": [ok("x")]})
        r, _ = run(post=post, env=FULL, sources=["system"], job="bulk", tracker=tr, cache=L.ResponseCache(ttl=0), training_ok=False)
        self.assertEqual(tr.last["packet_tokens"], r["packet_tokens"])
        self.assertGreater(r["packet_tokens"], 0)


if __name__ == "__main__":
    unittest.main()
