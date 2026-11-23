"""FENDEZY AI CREATIVE STUDIO M8 (hq_creative_studio.py): router, money flow, QA, hosted adapters, storage, publishing. Mocked providers, no network.
The database gates themselves are proven in sqltests/creative_studio_check.sql; the end-to-end sandbox demo (real DB + real ffmpeg) runs here only when
CREATIVE_E2E_URL points at a scratch replica."""
import os
import shutil
import subprocess
import sys
import tempfile
import unittest

import hq_creative_studio as cs



def _no_network(*a, **k):
    raise AssertionError("a test tried to reach the network")


cs.HostedAdapter.http = lambda self, *a, **k: (self._http or _no_network)(*a, **k)   # tests never call a real provider
cs._reserve = cs._settle = cs._release = _no_network                                  # nor the real money path
HAVE_FFMPEG = bool(shutil.which("ffmpeg") and shutil.which("ffprobe"))
JOB = "11111111-2222-4333-8444-555555555555"
LIVE = {"CREATIVE_STUDIO_MODE": "live", "FAL_KEY": "k-fal", "REPLICATE_API_TOKEN": "k-rep"}
PROVIDERS = [
    {"slug": "sandbox", "kind": "local", "models": ["sandbox-testsrc"], "est_cents": 0, "unit": "job", "env_key": ""},
    {"slug": "replicate-hosted", "kind": "hosted", "models": ["flux.1-schnell", "flux.1-dev", "wan-2.2-ti2v-5b"], "est_cents": 0.42, "unit": "output", "env_key": "REPLICATE_API_TOKEN"},
    {"slug": "fal-hosted", "kind": "hosted", "models": ["flux.1-schnell", "flux.1-dev", "wan-2.2-ti2v-5b", "wan-2.2-t2v-a14b", "ltx-2"], "est_cents": 3.5, "unit": "output", "env_key": "FAL_KEY"},
    {"slug": "kling", "kind": "premium", "models": ["kling-3.0"], "est_cents": 15, "unit": "video-second", "env_key": "KLING_API_KEY"},
]


def claim(module="image", quality="standard", premium=False, preset=None, providers=None, max_attempts=3, platforms=("1:1",)):
    return {"job": JOB, "office": "the-trap", "module": module, "brief": "Product photo of the black hoodie on concrete.", "quality": quality,
            "platforms": list(platforms), "premium_allowed": premium, "preset": preset, "max_attempts": max_attempts,
            "providers": providers if providers is not None else PROVIDERS, "brand_kit": {"group": {"dont": ["guaranteed"]}, "office": None}}


class FakeRpc:
    def __init__(self, c):
        self.c, self.calls, self.n = c, [], 0

    def __call__(self, name, args):
        self.calls.append((name, args))
        if name == "creative_claim":
            return self.c
        if name == "creative_attempt_begin":
            self.n += 1
            kind = next(p["kind"] for p in self.c["providers"] if p["slug"] == args["p_provider"])
            return {"attempt": f"att-{self.n}", "n": self.n, "kind": kind}
        if name == "creative_asset_add":
            return {"asset": f"asset-{len([x for x in self.calls if x[0] == name])}", "version": 1}
        if name == "creative_finish":
            return {"job": JOB, "status": "awaiting_approval" if args["p_passed"] else "failed"}
        if name == "creative_calendar_add":
            return {"entry": "entry-1", "status": "planned"}
        return {}

    def names(self):
        return [n for n, _ in self.calls]


class FileAdapter:
    """A paid mock provider that writes a real image (ffmpeg) or a broken file."""

    def __init__(self, broken=False, cents=7, fail=False):
        self.broken, self.cents, self.fail, self.calls = broken, cents, fail, 0

    def available(self, env):
        return True

    def generate(self, module, model, spec, workdir):
        self.calls += 1
        if self.fail:
            raise cs.StudioError("provider down")
        out = os.path.join(workdir, "raw.png")
        if self.broken:
            open(out, "wb").write(b"not an image")
        else:
            subprocess.run(["ffmpeg", "-loglevel", "error", "-y", "-f", "lavfi", "-i", "color=c=red:size=512x512", "-frames:v", "1", out], check=True)
        return {"file": out, "mime": "image/png", "actual_cents": self.cents}


class RouterTest(unittest.TestCase):
    def setUp(self):
        self.ad = {p["slug"]: object() for p in PROVIDERS}

    def test_open_source_first_cheapest_qualified(self):
        rows = cs.candidates(claim(), [], self.ad, {"count": 1})
        self.assertEqual(rows[0]["provider"], "sandbox")
        self.assertNotIn("premium", {r["kind"] for r in rows})
        costs = [r["est"] for r in rows if r["kind"] != "premium"]
        self.assertEqual(costs, sorted(costs))

    def test_tier_filters_models(self):
        rows = cs.candidates(claim(quality="high", providers=PROVIDERS[1:3]), [], self.ad, {"count": 1})
        self.assertTrue(rows and all(r["model"] == "flux.1-dev" for r in rows))
        rows = cs.candidates(claim(quality="draft", providers=PROVIDERS[1:3]), [], self.ad, {"count": 1})
        self.assertEqual(rows[0]["model"], "flux.1-schnell")

    def test_premium_only_after_qa_fail_and_permission(self):
        c = claim(module="video", providers=PROVIDERS[2:])
        failed = [{"provider": "fal-hosted", "model": "wan-2.2-ti2v-5b", "kind": "hosted", "outcome": "qa_failed"}]
        self.assertNotIn("kling", [r["provider"] for r in cs.candidates(c, failed, self.ad, {"seconds": 5})])          # no permission
        c["premium_allowed"] = True
        self.assertNotIn("kling", [r["provider"] for r in cs.candidates(c, [], self.ad, {"seconds": 5})])              # no QA failure
        rows = cs.candidates(c, failed, self.ad, {"seconds": 5})
        self.assertEqual(rows[-1]["provider"], "kling")
        self.assertEqual(rows[0]["kind"], "hosted")                                                                     # open models still first
        errored = [dict(failed[0], outcome="error")]
        self.assertNotIn("kling", [r["provider"] for r in cs.candidates(c, errored, self.ad, {"seconds": 5})])          # an error is not a QA failure

    def test_hero_direct_premium_needs_preset_and_permission(self):
        pre = {"hero_premium": True, "models": ["kling-3.0"]}
        rows = cs.candidates(claim(module="video", quality="hero", premium=True, preset=pre, providers=PROVIDERS[2:]), [], self.ad, {"seconds": 5})
        self.assertEqual(rows[0]["provider"], "kling")
        for c in (claim(module="video", quality="hero", premium=False, preset=pre, providers=PROVIDERS[2:]),
                  claim(module="video", quality="hero", premium=True, preset={"hero_premium": False}, providers=PROVIDERS[2:]),
                  claim(module="video", quality="high", premium=True, preset=pre, providers=PROVIDERS[2:])):
            self.assertNotIn("kling", [r["provider"] for r in cs.candidates(c, [], self.ad, {"seconds": 5})])

    def test_tried_pairs_are_skipped(self):
        tried = [{"provider": "sandbox", "model": "sandbox-testsrc", "kind": "local", "outcome": "qa_failed"}]
        self.assertNotIn("sandbox", [r["provider"] for r in cs.candidates(claim(), tried, self.ad, {})])

    def test_estimates_from_hosted_table(self):
        fal = PROVIDERS[2]
        self.assertEqual(cs.estimate_cents(fal, "flux.1-schnell", "image", {}), 1)          # US$0.003 x 1.40 -> 0.42 -> 1 cent (rounded up)
        self.assertEqual(cs.estimate_cents(fal, "wan-2.2-ti2v-5b", "video", {"seconds": 5}), 21)
        self.assertEqual(cs.estimate_cents(PROVIDERS[3], "kling-3.0", "video", {"seconds": 5}), 75)
        self.assertEqual(cs.estimate_cents(PROVIDERS[0], "sandbox-testsrc", "image", {}), 0)

    def test_adapters_need_live_mode_and_key(self):
        self.assertEqual(set(cs.adapters_for(PROVIDERS, {})), {"sandbox"})
        self.assertEqual(set(cs.adapters_for(PROVIDERS, {"CREATIVE_STUDIO_MODE": "live"})), {"sandbox"})
        self.assertEqual(set(cs.adapters_for(PROVIDERS, LIVE)), {"sandbox", "fal-hosted"})   # kling: no key, no adapter yet
        self.assertEqual(set(cs.adapters_for(PROVIDERS, dict(LIVE, KLING_API_KEY="x"))), {"sandbox", "fal-hosted"})


class PolicyTest(unittest.TestCase):
    @unittest.skipUnless(HAVE_FFMPEG, "ffmpeg not installed")
    def test_qa_needs_disclosure_and_respects_brand_kit(self):
        d = tempfile.mkdtemp()
        f = os.path.join(d, "x.png")
        subprocess.run(["ffmpeg", "-loglevel", "error", "-y", "-f", "lavfi", "-i", "color=c=red:size=1080x1080", "-frames:v", "1", f], check=True)
        c = claim()
        self.assertTrue(cs.qa(c, f, "Drop. AI-generated content.", "1:1")["passed"])
        self.assertIn("missing AI-generated disclosure", cs.qa(c, f, "Drop.", "1:1")["issues"])
        self.assertIn("brand kit: avoid 'guaranteed'", cs.qa(c, f, "Guaranteed results. AI-generated content.", "1:1")["issues"])
        self.assertIn("frame 1080x1080 is not 9:16", cs.qa(c, f, "AI-generated content.", "9:16")["issues"])
        self.assertIn("deceptive framing", cs.qa(c, f, "Verified buyer says wow. AI-generated content.", "1:1")["issues"])

    def test_refusals(self):
        self.assertIn("deceptive", cs.policy_refusal("A customer review video: 'I bought this and love it'", "ugc"))
        self.assertIn("imitation", cs.policy_refusal("A track in the style of a famous rapper", "music"))
        self.assertIsNone(cs.policy_refusal("A bright product video of the hoodie", "video"))

    def test_deceptive_brief_stops_before_any_attempt(self):
        c = claim()
        c["brief"] = "Fake testimonial from a real customer about the hoodie"
        rpc = FakeRpc(c)
        r = cs.run_job(JOB, rpc=rpc, env={}, workdir=tempfile.mkdtemp())
        self.assertEqual(r["status"], "failed")
        self.assertNotIn("creative_attempt_begin", rpc.names())
        self.assertFalse(rpc.calls[-1][1]["p_passed"])


@unittest.skipUnless(HAVE_FFMPEG, "ffmpeg not installed")
class PipelineMoneyTest(unittest.TestCase):
    def run_paid(self, adapter, gate):
        c = claim(providers=[PROVIDERS[2]])
        rpc, log = FakeRpc(c), []
        money = lambda office, cand, job: log.append(("reserve", office, cand["est"])) or gate
        settle = lambda rid, actual, receipt: log.append(("settle", rid, actual))
        release = lambda rid: log.append(("release", rid))
        r = cs.run_job(JOB, rpc=rpc, env=LIVE, money=money, settle=settle, release=release, extra_adapters={"fal-hosted": adapter},
                       store=cs.LocalStore(tempfile.mkdtemp()), workdir=tempfile.mkdtemp())
        return r, rpc, log

    def test_paid_attempt_reserves_before_generating_and_settles(self):
        ad = FileAdapter(cents=7)
        r, rpc, log = self.run_paid(ad, {"decision": "allow", "reservation_id": "res-1"})
        self.assertEqual(r["status"], "awaiting_approval")
        self.assertEqual(log[0], ("reserve", "the-trap", 1))                      # cheapest qualified: flux.1-schnell on fal, 1 cent (estimate)
        self.assertEqual(log[1], ("settle", "res-1", 7))
        end = [a for n, a in rpc.calls if n == "creative_attempt_end"][0]
        self.assertEqual((end["p_outcome"], end["p_actual_cents"], end["p_reservation"]), ("ok", 7, "res-1"))
        names = rpc.names()
        self.assertLess(names.index("creative_attempt_begin"), names.index("creative_attempt_end"))
        add = [a for n, a in rpc.calls if n == "creative_asset_add"][0]
        self.assertTrue(add["p_path"].startswith("the-trap/") and add["p_meta"]["ai_generated"])
        fin = rpc.calls[-1][1]
        self.assertIn("AI-generated", fin["p_caption"])

    def test_gate_deny_spends_nothing(self):
        for gate in ({"decision": "deny", "reason": "over the weekly limit"}, {"decision": "ask_owner", "reason": "over per-transaction"}, {"decision": "allow"}):
            ad = FileAdapter()
            r, rpc, log = self.run_paid(ad, gate)
            self.assertEqual(r["status"], "failed")
            self.assertEqual(ad.calls, 0)
            self.assertEqual([x[0] for x in log], ["reserve"])
            end = [a for n, a in rpc.calls if n == "creative_attempt_end"][0]
            self.assertEqual((end["p_outcome"], end["p_actual_cents"], end["p_reservation"]), ("error", 0, None))

    def test_provider_error_releases_the_reservation(self):
        ad = FileAdapter(fail=True)
        r, rpc, log = self.run_paid(ad, {"decision": "allow", "reservation_id": "res-9"})
        self.assertIn(("release", "res-9"), log)
        self.assertNotIn("settle", [x[0] for x in log])
        self.assertEqual(r["status"], "failed")
        self.assertLessEqual(ad.calls, 3)                                          # bounded by the retry limit / candidate list

    def test_qa_failure_escalates_to_the_next_candidate(self):
        c = claim(providers=PROVIDERS[:3])
        rpc = FakeRpc(c)
        broken, good = FileAdapter(broken=True, cents=0), FileAdapter(cents=0)
        r = cs.run_job(JOB, rpc=rpc, env=LIVE, extra_adapters={"sandbox": broken, "replicate-hosted": good, "fal-hosted": good},
                       money=lambda *a: {"decision": "allow", "reservation_id": "r"}, settle=lambda *a: None, release=lambda *a: None,
                       store=cs.LocalStore(tempfile.mkdtemp()), workdir=tempfile.mkdtemp())
        outcomes = [a["p_outcome"] for n, a in rpc.calls if n == "creative_attempt_end"]
        self.assertEqual(outcomes, ["qa_failed", "ok"])
        self.assertEqual(r["status"], "awaiting_approval")

    def test_retry_limit_bounds_attempts(self):
        c = claim(providers=PROVIDERS[:3], max_attempts=2)
        rpc = FakeRpc(c)
        bad = FileAdapter(broken=True, cents=0)
        r = cs.run_job(JOB, rpc=rpc, env=LIVE, extra_adapters={"sandbox": bad, "replicate-hosted": bad, "fal-hosted": bad},
                       money=lambda *a: {"decision": "allow", "reservation_id": "r"}, settle=lambda *a: None, release=lambda *a: None, workdir=tempfile.mkdtemp())
        self.assertEqual(rpc.names().count("creative_attempt_begin"), 2)
        self.assertEqual(r["status"], "failed")

    def test_sandbox_video_renders_every_platform(self):
        c = claim(module="video", providers=PROVIDERS[:1], platforms=("9:16", "16:9"))
        rpc, root = FakeRpc(c), tempfile.mkdtemp()
        r = cs.run_job(JOB, rpc=rpc, env={"CREATIVE_VIDEO_SECONDS": "2"}, store=cs.LocalStore(root), workdir=tempfile.mkdtemp())
        self.assertEqual(r["status"], "awaiting_approval")
        sizes = {x["platform"]: cs.probe(os.path.join(root, x["path"])) for x in r["assets"]}
        self.assertEqual((sizes["9:16"]["width"], sizes["9:16"]["height"]), (1080, 1920))
        self.assertEqual((sizes["16:9"]["width"], sizes["16:9"]["height"]), (1920, 1080))
        self.assertIn("subtitle", sizes["9:16"]["streams"])


class HostedAdapterTest(unittest.TestCase):
    def fal_http(self, calls, final_url="https://v3.fal.media/files/x.png"):
        def http(method, url, headers=None, json_body=None, timeout=60, **k):
            calls.append((method, url, headers, json_body))
            if method == "POST":
                return 200, {"request_id": "rq1", "status_url": "https://queue.fal.run/fal-ai/flux/requests/rq1/status",
                             "response_url": "https://queue.fal.run/fal-ai/flux/requests/rq1"}, {}
            if url.endswith("/status"):
                n = sum(1 for c in calls if c[1].endswith("/status"))
                return 200, {"status": "IN_PROGRESS" if n < 2 else "COMPLETED"}, {}
            if url.endswith("/rq1"):
                return 200, {"images": [{"url": final_url}]}, {}
            return 200, b"\x89PNG fake", {"Content-Type": "image/png"}
        return http

    def test_fal_queue_flow(self):
        calls = []
        a = cs.HostedAdapter("fal-hosted", "FAL_KEY", LIVE, http=self.fal_http(calls), sleep=lambda s: None)
        out = a.generate("image", "flux.1-schnell", {"prompt": "hoodie", "aspect": "9:16"}, tempfile.mkdtemp())
        self.assertEqual(calls[0][1], "https://queue.fal.run/fal-ai/flux/schnell")
        self.assertEqual(calls[0][2]["Authorization"], "Key k-fal")
        self.assertEqual(calls[0][3]["image_size"], "portrait_16_9")
        self.assertEqual(open(out["file"], "rb").read(), b"\x89PNG fake")
        self.assertEqual(out["actual_cents"], 1)
        self.assertNotIn("k-fal", repr(out))

    def test_fal_refuses_non_https_result(self):
        a = cs.HostedAdapter("fal-hosted", "FAL_KEY", LIVE, http=self.fal_http([], final_url="http://evil/x.png"), sleep=lambda s: None)
        with self.assertRaises(cs.StudioError):
            a.generate("image", "flux.1-schnell", {"prompt": "x"}, tempfile.mkdtemp())

    def test_fal_failure_and_timeout(self):
        def failing(method, url, **k):
            return (200, {"request_id": "r"}, {}) if method == "POST" else (200, {"status": "FAILED"}, {})
        with self.assertRaises(cs.StudioError):
            cs.HostedAdapter("fal-hosted", "FAL_KEY", LIVE, http=failing, sleep=lambda s: None).generate("image", "flux.1-schnell", {}, tempfile.mkdtemp())
        def stuck(method, url, **k):
            return (200, {"request_id": "r"}, {}) if method == "POST" else (200, {"status": "IN_QUEUE"}, {})
        with self.assertRaises(cs.StudioError):
            cs.HostedAdapter("fal-hosted", "FAL_KEY", LIVE, http=stuck, sleep=lambda s: None, deadline_s=-1).generate("image", "flux.1-schnell", {}, tempfile.mkdtemp())

    def test_replicate_has_no_adapter(self):
        self.assertNotIn("replicate-hosted", cs.adapters_for(PROVIDERS, LIVE))
        with self.assertRaises(cs.StudioError):
            cs.HostedAdapter("replicate-hosted", "REPLICATE_API_TOKEN", LIVE, http=_no_network).generate("video", "wan-2.2-ti2v-5b", {}, tempfile.mkdtemp())

    def test_unknown_model_and_unavailable(self):
        a = cs.HostedAdapter("fal-hosted", "FAL_KEY", LIVE, http=lambda *x, **k: (500, None, {}))
        with self.assertRaises(cs.StudioError):
            a.generate("video", "kling-3.0", {}, tempfile.mkdtemp())
        self.assertFalse(cs.HostedAdapter("fal-hosted", "FAL_KEY", {"FAL_KEY": "x"}).available({"FAL_KEY": "x"}))


class StoreAndPublishTest(unittest.TestCase):
    def test_paths_are_office_prefixed(self):
        for bad in ("../x", "the-trap/../donna/x", "/abs", "Trap/x", "the-trap"):
            with self.assertRaises(cs.StudioError):
                cs._check_path(bad)
        cs._check_path("the-trap/jobs/1/9x16.mp4")

    def test_supabase_store_signed_urls_only(self):
        calls = []
        def http(method, url, headers=None, json_body=None, data=None, timeout=60, **k):
            calls.append((method, url, json_body))
            return (200, {"Key": "x"}, {}) if "/sign/" not in url else (200, {"signedURL": "/object/sign/creative-studio/the-trap/a.png?token=t"}, {})
        f = tempfile.NamedTemporaryFile(delete=False)
        f.write(b"x")
        f.close()
        s = cs.SupabaseStore("https://p.supabase.co", "svc", http=http)
        s.put("the-trap/a.png", f.name, "image/png")
        self.assertEqual(calls[0][1], "https://p.supabase.co/storage/v1/object/creative-studio/the-trap/a.png")
        self.assertEqual(s.url("the-trap/a.png", 10), "https://p.supabase.co/storage/v1/object/sign/creative-studio/the-trap/a.png?token=t")
        self.assertEqual(calls[1][2], {"expiresIn": 60})
        with self.assertRaises(cs.StudioError):
            cs.SupabaseStore("http://p", "svc")

    def test_schedule_post_goes_through_hands_and_adds_disclosure(self):
        rpc, sub = FakeRpc(claim()), []
        hands = lambda *a, **k: sub.append((a, k)) or {"ok": True, "action_id": "ha-1", "status": "draft"}
        r = cs.schedule_post("asset-1", "tiktok", "acct", "2026-12-01T17:00:00Z", "New drop", "https://x", rpc=rpc, hands_submit=hands)
        self.assertEqual(r["status"], "drafted")
        self.assertIn("AI-generated", sub[0][0][3]["text"])
        self.assertTrue(sub[0][1]["ai_generated"])
        self.assertEqual(rpc.calls[-1], ("creative_calendar_link", {"p_entry": "entry-1", "p_hand_action": "ha-1"}))
        r = cs.schedule_post("asset-1", "tiktok", "acct", "2026-12-01T17:00:00Z", "x", "https://x", rpc=FakeRpc(claim()), hands_submit=lambda *a, **k: {"ok": False, "reason": "pii"})
        self.assertEqual(r["status"], "planned")

    def test_report_text(self):
        rep = {"registered": True, "queue": {"approved": 2}, "cost": [{"module": "video", "jobs": 2, "approved": 1, "cents": 150, "cents_per_approved": 150, "attempts_per_job": 1.5}],
               "offices": [{"office": "the-trap", "week_cents": 150, "all_cents": 1350, "weekly_limit_cents": None, "allow_premium": False}],
               "providers": [{"slug": "fal-hosted", "enabled": True}, {"slug": "veo", "enabled": False}]}
        t = cs.report_text(rpc=lambda n, a: rep)
        self.assertIn("video: 2 jobs, 1 approved, $1.50, $1.50/approved", t)
        self.assertIn("the-trap: $1.50 this week, $13.50 total (no limit)", t)
        self.assertIn("Providers on: fal-hosted.", t)
        self.assertIn("unavailable", cs.report_text(rpc=lambda n, a: (_ for _ in ()).throw(RuntimeError())))


class CommandAndSourceTest(unittest.TestCase):
    def test_creative_command_owner_only(self):
        import asyncio
        import types
        from unittest import mock
        import hq_commands
        out = []
        reply = mock.AsyncMock(side_effect=lambda m, t: out.append(t))
        with mock.patch.object(hq_commands, "_owner", return_value=False), mock.patch.object(hq_commands.hq_core, "reply_to", new=reply):
            asyncio.run(hq_commands.hq_creative_cmd(types.SimpleNamespace(message=object()), types.SimpleNamespace(args=[])))
        self.assertEqual(out, [])
        with mock.patch.object(hq_commands, "_owner", return_value=True), mock.patch.object(hq_commands.hq_core, "reply_to", new=reply), \
             mock.patch.object(cs, "report_text", return_value="STUDIO"):
            asyncio.run(hq_commands.hq_creative_cmd(types.SimpleNamespace(message=object()), types.SimpleNamespace(args=[])))
        self.assertEqual(out, ["STUDIO"])

    def test_no_direct_money_or_network_paths(self):
        import re
        src = re.sub(r'"""[\s\S]*?"""', "", open(cs.__file__).read())
        for bad in ("urlopen", "reserve_spend(", "ledger", "settle_spend", "fz_owner_", "anthropic", "requests."):
            self.assertNotIn(bad, src)
        self.assertIn("hq_office_money.reserve(", src)


@unittest.skipUnless(os.environ.get("CREATIVE_E2E_URL") and HAVE_FFMPEG, "set CREATIVE_E2E_URL to a scratch replica")
class SandboxEndToEndTest(unittest.TestCase):
    def test_demo(self):
        here = os.path.dirname(os.path.abspath(__file__))
        r = subprocess.run([sys.executable, os.path.join(here, "scripts", "creative_studio_demo.py"), "--db", os.environ["CREATIVE_E2E_URL"], "--out", tempfile.mkdtemp()],
                           capture_output=True, text=True, timeout=600)
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertIn("8. reused asset", r.stdout)
        self.assertIn("rolled back", r.stdout)


if __name__ == "__main__":
    unittest.main()
