"""FENDEZY AI CREATIVE STUDIO M8c: template library (hq_creative_presets), editing step (hq_creative_media), ComfyUI + local-edit adapters, template choice
and the analytics loop (hq_creative_studio). No network (any real HTTP raises), no money path, no database (the DB gates are proven in
sqltests/creative_studio_v2_check.sql). Media tests use the real ffmpeg when present; faster-whisper is replaced by a fake transcriber."""
import base64
import copy
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import unittest

import hq_creative_media as media
import hq_creative_presets as hp
import hq_creative_studio as cs


def _no_network(*a, **k):
    raise AssertionError("a test tried to reach the network")


cs.HostedAdapter.http = lambda self, *a, **k: (self._http or _no_network)(*a, **k)
cs.ComfyUIAdapter.http = lambda self, *a, **k: (self._http or _no_network)(*a, **k)
cs._reserve = cs._settle = cs._release = _no_network
HAVE_FFMPEG = bool(shutil.which("ffmpeg") and shutil.which("ffprobe"))
HERE = os.path.dirname(os.path.abspath(__file__))
JOB = "11111111-2222-4333-8444-555555555555"
LIB = hp.load_library()


class LibraryTest(unittest.TestCase):
    def test_shipped_library_is_valid_and_covers_the_offices(self):
        slugs = hp.validate(LIB)
        self.assertGreaterEqual(len(slugs), 20)
        offices = {t["office"] for t in LIB["templates"]}
        self.assertTrue({"b2b-records", "pimp-ai", "the-trap", "ff-marketing", "group"} <= offices)
        kinds = {t["kind"] for t in LIB["templates"]}
        self.assertTrue({"product", "ugc", "visualizer", "lyric_video", "character", "hero_ad", "edit"} <= kinds)

    def bad(self, mutate):
        lib = copy.deepcopy(LIB)
        mutate(lib)
        with self.assertRaises(hp.PresetError) as e:
            hp.validate(lib)
        return str(e.exception)

    def test_a_template_cannot_route_price_or_switch_off_the_disclosure(self):
        t0 = lambda lib: lib["templates"][0]
        self.assertIn("unknown keys", self.bad(lambda lib: t0(lib).update(provider="kling")))
        self.assertIn("unknown keys", self.bad(lambda lib: t0(lib).update(model="veo-3.1")))
        self.assertIn("unknown keys", self.bad(lambda lib: t0(lib).update(disclosure=False)))
        self.assertIn("unknown edit keys", self.bad(lambda lib: t0(lib)["edit"].update(label=False)))
        self.assertIn("routing / price words", self.bad(lambda lib: t0(lib).update(title="Premium Kling hero")))

    def test_deceptive_framing_and_imitation_are_refused(self):
        self.assertIn("banned framing", self.bad(lambda lib: lib["templates"][0].update(title="Customer testimonial reel")))
        self.assertIn("banned framing", self.bad(lambda lib: lib["templates"][0]["prompt"].update(base="in the style of a famous rapper")))
        self.assertIn("banned framing", self.bad(lambda lib: lib["hooks"][0].update(text="Real customer review: {subject}")))
        self.assertIn("vocab carries banned framing", self.bad(lambda lib: lib["vocab"]["ugc_formats"].update(x="5-star review by a buyer")))

    def test_references_must_exist(self):
        self.assertIn("unknown hook", self.bad(lambda lib: lib["templates"][0]["hooks"].append("nope")))
        self.assertIn("not in vocab.camera_moves", self.bad(lambda lib: lib["templates"][2]["prompt"].update(move="barrel-roll")))
        self.assertIn("unknown ComfyUI workflow", self.bad(lambda lib: lib["templates"][0].update(workflow="flux-dev")))
        self.assertIn("unknown office", self.bad(lambda lib: lib["templates"][0].update(office="nowhere")))
        self.assertIn("beat_sync / broll need module 'edit'", self.bad(lambda lib: lib["templates"][0]["edit"].update(broll=True)))
        self.assertIn("loudnorm", self.bad(lambda lib: lib["templates"][2]["edit"].update(loudnorm=-3)))

    def test_compile_prompt_uses_the_higgsfield_order_and_the_brief(self):
        p = hp.compile_prompt(LIB, hp.template(LIB, "trap-turntable"), cs._subject("New drop: The black hoodie. Heavy cotton."))
        self.assertTrue(p.startswith("The black hoodie rotating on a turntable"))
        for part in ("360-degree turntable rotation", "shot on a premium large-format digital cinema camera", "at 85mm (classic portrait perspective)",
                     "aperture f/4", "large softbox key light"):
            self.assertIn(part, p)

    def test_hooks_need_their_values(self):
        self.assertEqual(hp.hook_text(LIB, "drop-reveal", {"subject": "the hoodie"}), "New drop: the hoodie")
        self.assertIsNone(hp.hook_text(LIB, "stop-scroll", {"subject": "the hoodie"}))           # {pain} unknown -> next hook
        self.assertEqual(hp.hook_text(LIB, "countdown", {"subject": "x", "outcome": "fresh fits"}), "3 seconds to fresh fits")

    def test_caption_style_takes_the_brand_kit(self):
        st = hp.caption_style(LIB, "karaoke", {"colours": ["#111111", "#F4C430"], "fonts": ["Inter"]})
        self.assertEqual((st["highlight"], st["font"], st["name"]), ("#F4C430", "Inter", "karaoke"))
        self.assertIsNone(hp.caption_style(LIB, "none"))
        st = hp.caption_style(LIB, "pop", {"colours": ["red", "javascript:x"], "fonts": ["a;b{}"]})
        self.assertEqual(st["font"], LIB["caption_styles"]["pop"]["font"])

    def test_seed_in_the_migration_matches_the_library(self):
        r = subprocess.run([sys.executable, os.path.join(HERE, "scripts", "creative_presets_seed.py"), "--check"], capture_output=True, text=True, timeout=60)
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)


class WorkflowTest(unittest.TestCase):
    def test_manifest_is_licence_safe_and_complete(self):
        m = hp.load_manifest()["workflows"]
        models = {w["model"] for w in m.values()}
        self.assertNotIn("flux.1-dev", models)                    # FLUX.1 [dev] weights are non-commercial when self-hosted
        self.assertNotIn("flux.1-dev-lora", models)
        for wid, w in m.items():
            self.assertIn(w["model"], cs.MODEL_TIER, wid)
            self.assertIn(w["module"] if w["module"] != "video" else "video", cs.MODEL_MODULES[w["model"]], wid)
            with open(os.path.join(hp.COMFY_DIR, w["file"])) as f:
                graph = json.load(f)
            holes = {mm.group(1) for n in graph.values() for v in n["inputs"].values() if isinstance(v, str) for mm in [hp.PLACEHOLDER.match(v)] if mm}
            self.assertEqual(holes, set(w["params"]), wid)
            for n in graph.values():                               # every link points at a node of the graph
                for v in n["inputs"].values():
                    if isinstance(v, list):
                        self.assertIn(v[0], graph, wid)
        sql = open(os.path.join(HERE, "migrations", "20261207_creative_studio_v2.sql")).read()
        listed = re.search(r"update fz_creative.providers set models = array\[([^\]]+)\]", sql).group(1)
        self.assertEqual({x.strip(" '") for x in listed.split(",")}, models)

    def test_fill_types_and_refuses_gaps(self):
        g = hp.workflow("wan22-ti2v-5b", {"prompt": "x", "width": 704, "height": 1280, "frames": hp.video_frames(5, 24, "wan"), "fps": 24, "seed": 7})
        self.assertEqual(g["55"]["inputs"]["length"], 121)
        self.assertIsInstance(g["3"]["inputs"]["seed"], int)
        self.assertTrue(g["7"]["inputs"]["text"])                  # the default negative prompt
        with self.assertRaises(hp.PresetError):
            hp.workflow("flux-schnell-t2i", {"prompt": "x", "width": 1, "height": 1})
        with self.assertRaises(hp.PresetError):
            hp.workflow("flux-schnell-t2i", {"prompt": "x", "width": 1, "height": 1, "seed": 1, "ckpt_name": "flux1-dev.safetensors"})
        self.assertEqual(hp.video_frames(5, 24, "ltx-video") % 8, 1)


class CaptionTest(unittest.TestCase):
    WORDS = [{"word": "New", "start": 0.0, "end": 0.3}, {"word": "drop.", "start": 0.3, "end": 0.7}, {"word": "The", "start": 1.6, "end": 1.8},
             {"word": "black", "start": 1.8, "end": 2.1}, {"word": "hoodie", "start": 2.1, "end": 2.6}]

    def test_lines_break_on_punctuation_pauses_and_length(self):
        self.assertEqual([[w["word"] for w in ln] for ln in media.lines(self.WORDS, 2)], [["New", "drop."], ["The", "black"], ["hoodie"]])

    def test_srt(self):
        s = media.to_srt(self.WORDS, 7)
        self.assertIn("1\n00:00:00,000 --> 00:00:00,700\nNew drop.\n", s)
        self.assertIn("2\n00:00:01,600 --> 00:00:02,600\nThe black hoodie\n", s)

    def test_ass_always_draws_the_ai_label(self):
        for style in (None, LIB["caption_styles"]["karaoke"]):
            a = media.to_ass(self.WORDS if style else [], style, (1080, 1920), 3.0)
            self.assertRegex(a, r"Dialogue: 2,0:00:00.00,0:00:03.00,Label,,0,0,0,,AI-generated")
        a = media.to_ass(self.WORDS, dict(LIB["caption_styles"]["karaoke"]), (1080, 1920), 3.0, hook="New drop {\\pos(0,0)}")
        self.assertIn("Hook", a)
        self.assertNotIn("\\pos", a)                               # override tags from text are stripped
        self.assertEqual(a.count(",Cap,"), 5)                     # one event per word (word highlight)

    def test_script_alignment_keeps_timing_and_spelling(self):
        heard = [{"word": "the", "start": 0.0, "end": 0.2}, {"word": "black", "start": 0.2, "end": 0.5}, {"word": "haudest", "start": 0.5, "end": 0.9},
                 {"word": "is", "start": 1.0, "end": 1.1}, {"word": "here", "start": 1.1, "end": 1.4}]
        out, ok = media.align_to_script(heard, "The black hoodie is here.")
        self.assertTrue(ok)
        self.assertEqual([w["word"] for w in out], ["The", "black", "hoodie", "is", "here."])
        self.assertEqual((out[2]["start"], out[2]["end"]), (0.5, 0.9))
        _, ok = media.align_to_script(heard, "Completely different words about shoes and socks today")
        self.assertFalse(ok)

    def test_script_words_cover_the_duration(self):
        w = media.script_words("one two three", 3.0)
        self.assertEqual((w[0]["start"], round(w[-1]["end"], 2)), (0.0, 3.0))


class EditPlanTest(unittest.TestCase):
    CLIPS = [{"path": "a", "duration": 4.0, "score": 1.0}, {"path": "b", "duration": 4.0, "score": 9.0}]

    def test_cuts_land_on_beats_and_hook_goes_first(self):
        beats = [0.5 * i for i in range(1, 21)]
        segs = media.plan_cuts(self.CLIPS, beats, 2, 6.0, hook_first=True)
        self.assertEqual(segs[0]["clip"], 1)                       # the liveliest clip opens
        ends = [round(s["at"] + s["dur"], 3) for s in segs]
        self.assertTrue(all(any(abs(e - b) < 1e-6 for b in beats) for e in ends), ends)
        self.assertLessEqual(ends[-1], 6.0)

    def test_without_beats_even_cuts(self):
        segs = media.plan_cuts(self.CLIPS, [], None, 5.0, hook_first=False, default_cut=2.0)
        self.assertEqual([s["clip"] for s in segs], [0, 1, 0])
        with self.assertRaises(media.MediaError):
            media.plan_cuts([], [], None, 5.0)

    def test_fit_filters(self):
        f = media.fit_filter(1920, 1080, "9:16", "auto_reframe", 0.9)
        self.assertTrue(f.startswith("crop=606:1080:1314:0"), f)   # right-hand subject, clamped to the frame
        self.assertIn("color=0x111111", media.fit_filter(1920, 1080, "1:1", "pad", pad_colour="#111111"))
        self.assertIn("color=black", media.fit_filter(1920, 1080, "1:1", "pad", pad_colour="red;drawtext"))


@unittest.skipUnless(HAVE_FFMPEG, "ffmpeg missing")
class MediaFfmpegTest(unittest.TestCase):
    def setUp(self):
        self.d = tempfile.mkdtemp()
        self.src = os.path.join(self.d, "src.mp4")
        media.ff(["-f", "lavfi", "-i", "testsrc2=size=1280x720:rate=24:duration=3", "-f", "lavfi", "-i", "sine=f=300:d=3", "-c:v", "libx264", "-preset", "ultrafast",
                  "-pix_fmt", "yuv420p", "-c:a", "aac", "-shortest", self.src])

    def tearDown(self):
        shutil.rmtree(self.d, ignore_errors=True)

    def test_finish_burns_captions_label_and_normalises(self):
        fake = lambda path: [{"word": "hello", "start": 0.2, "end": 0.6}, {"word": "world", "start": 0.6, "end": 1.0}]
        out = os.path.join(self.d, "out.mp4")
        r = media.finish(self.src, "9:16", out, script="hello world", style=LIB["caption_styles"]["pop"], hook="Hi", fit="auto_reframe", transcriber=fake, workdir=self.d)
        self.assertEqual(r["caption_source"], "whisper+script")
        self.assertIn("hello", r["srt"])
        p = media.probe(out)
        self.assertEqual((p["width"], p["height"]), (1080, 1920))
        tags = subprocess.run(["ffprobe", "-v", "error", "-show_entries", "format_tags=comment:stream=codec_type", "-of", "json", out], capture_output=True, text=True).stdout
        self.assertIn("AI-generated content.", tags)
        self.assertIn("subtitle", tags)
        self.assertIsNotNone(r["loudness"])

    def test_finish_without_whisper_falls_back_to_the_script(self):
        def broken(path):
            raise media.MediaError("faster-whisper is not installed")
        r = media.finish(self.src, "1:1", os.path.join(self.d, "o.mp4"), script="one two three", style=LIB["caption_styles"]["subtle"], transcriber=broken, workdir=self.d)
        self.assertEqual(r["caption_source"], "script")
        r = media.finish(self.src, "1:1", os.path.join(self.d, "o2.mp4"), script="one two three", style=LIB["caption_styles"]["subtle"], transcriber=broken,
                         workdir=self.d, script_fallback=False)
        self.assertIsNone(r["caption_source"])

    def test_beats_on_a_120_bpm_kick(self):
        kick = os.path.join(self.d, "kick.wav")
        media.ff(["-f", "lavfi", "-i", "aevalsrc='0.8*sin(2*PI*60*t)*exp(-12*mod(t,0.5))':d=8:s=22050", kick])
        b = media.beats(kick)
        self.assertTrue(110 <= b["bpm"] <= 130, b)

    def test_stitch_and_visualizer(self):
        clips = [{"path": self.src, "duration": 3.0, "width": 1280, "height": 720, "audio": True, "score": 1}]
        segs = media.plan_cuts(clips, [], None, 4.0, default_cut=1.0)
        out = os.path.join(self.d, "st.mp4")
        r = media.stitch(clips, segs, "9:16", out, crossfade=0.2, workdir=self.d)
        self.assertEqual(r["segments"], 4)
        self.assertEqual((media.probe(out)["width"], media.probe(out)["height"]), (1080, 1920))
        wav = os.path.join(self.d, "a.wav")
        media.ff(["-f", "lavfi", "-i", "sine=f=220:d=2", wav])
        v = media.visualizer(wav, "1:1", os.path.join(self.d, "viz.mp4"), kind="spectrum")
        self.assertAlmostEqual(media.probe(v)["duration"], 2.0, delta=0.2)


class ComfyUITest(unittest.TestCase):
    ENV = {"CREATIVE_STUDIO_MODE": "live", "RUNPOD_API_KEY": "k-rp", "COMFYUI_RUNPOD_ENDPOINT": "abc123def"}

    def http(self, calls, status="COMPLETED", exec_ms=3000, out=None):
        png = base64.b64encode(b"\x89PNG fake").decode()

        def h(method, url, headers=None, json_body=None, timeout=60, **k):
            calls.append((method, url, headers, json_body))
            if method == "POST":
                return 200, {"id": "job-123456", "status": "IN_QUEUE"}, {}
            n = sum(1 for c in calls if "/status/" in c[1])
            if n < 2:
                return 200, {"status": "IN_PROGRESS"}, {}
            return 200, {"status": status, "executionTime": exec_ms, "delayTime": 900,
                         "output": out if out is not None else {"images": [{"filename": "fendezy_0001.png", "type": "base64", "data": png}]}}, {}
        return h

    def adapter(self, calls, **k):
        return cs.ComfyUIAdapter("runpod-comfyui", "RUNPOD_API_KEY", self.ENV, 0.075, http=self.http(calls, **k), sleep=lambda s: None)

    def test_flow_budget_and_cost(self):
        calls = []
        a = self.adapter(calls)
        self.assertTrue(a.available(self.ENV))
        r = a.generate("image", "flux.1-schnell", {"prompt": "hoodie", "aspect": "1:1"}, tempfile.mkdtemp())
        self.assertEqual(calls[0][1], "https://api.runpod.ai/v2/abc123def/run")
        self.assertEqual(calls[0][2]["Authorization"], "Bearer k-rp")
        body = calls[0][3]
        self.assertEqual(body["policy"]["executionTimeout"], 10000)                 # capped at the reserved GPU-seconds (min 10 s)
        self.assertEqual(body["input"]["workflow"]["27"]["inputs"]["width"], 1024)
        self.assertEqual(r["actual_cents"], 1)                                      # 3 s x 0.075 c/s, rounded up
        self.assertTrue(open(r["file"], "rb").read().startswith(b"\x89PNG"))

    def test_measured_time_never_exceeds_the_reserved_budget(self):
        calls = []
        r = self.adapter(calls, exec_ms=10 ** 7).generate("video", "wan-2.2-ti2v-5b", {"prompt": "x", "seconds": 5, "aspect": "9:16"}, tempfile.mkdtemp())
        self.assertEqual(r["gpu_ms"], 125 * 1000)
        self.assertEqual(r["actual_cents"], cs.estimate_cents({"slug": "runpod-comfyui", "est_cents": 0.075, "unit": "gpu-second"}, "wan-2.2-ti2v-5b", "video", {"seconds": 5}))

    def test_refusals(self):
        calls = []
        a = self.adapter(calls)
        self.assertFalse(a.supports("flux.1-dev"))
        with self.assertRaises(cs.StudioError):
            a.generate("image", "flux.1-dev", {"prompt": "x"}, tempfile.mkdtemp())
        self.assertEqual(calls, [])
        with self.assertRaises(cs.StudioError):
            self.adapter([], status="FAILED").generate("image", "flux.1-schnell", {"prompt": "x"}, tempfile.mkdtemp())
        with self.assertRaises(cs.StudioError):
            self.adapter([], out={"images": [{"filename": "x.png", "type": "s3_url", "data": "http://insecure/x.png"}]}).generate(
                "image", "flux.1-schnell", {"prompt": "x"}, tempfile.mkdtemp())
        with self.assertRaises(cs.StudioError):                                      # LoRA workflow without the character's LoRA
            a.generate("image", "flux.1-schnell-lora", {"prompt": "x"}, tempfile.mkdtemp())
        for env in ({}, {**self.ENV, "CREATIVE_STUDIO_MODE": "sandbox"}, {**self.ENV, "COMFYUI_RUNPOD_ENDPOINT": "../x"}, {**self.ENV, "RUNPOD_API_KEY": ""}):
            self.assertFalse(cs.ComfyUIAdapter("runpod-comfyui", "RUNPOD_API_KEY", env, 0.075).available(env))

    def test_router_skips_models_without_a_workflow(self):
        prov = [{"slug": "runpod-comfyui", "kind": "serverless", "models": ["flux.1-dev", "flux.1-schnell"], "est_cents": 0.075, "unit": "gpu-second", "env_key": "RUNPOD_API_KEY"}]
        ad = cs.adapters_for(prov, self.ENV)
        self.assertIn("runpod-comfyui", ad)
        c = {"module": "image", "quality": "standard", "providers": prov, "premium_allowed": False}
        self.assertEqual([r["model"] for r in cs.candidates(c, [], ad, {"count": 1})], ["flux.1-schnell"])
        self.assertNotIn("modal-comfyui", cs.adapters_for([dict(prov[0], slug="modal-comfyui", env_key="MODAL_TOKEN_ID")], {**self.ENV, "MODAL_TOKEN_ID": "x"}))


class FakeRpc:
    def __init__(self, claim, template=None, rank=None):
        self.c, self.template, self.rank, self.calls = claim, template, rank or {}, []

    def __call__(self, name, args):
        self.calls.append((name, args))
        if name == "creative_claim":
            return self.c
        if name == "creative_job_template":
            return self.template
        if name == "creative_job_set_template":
            self.template = {"template": args["p_template"], "module": self.c["module"], "spec": {k: v for k, v in hp.template(LIB, args["p_template"]).items()
                                                                                                 if k in ("prompt", "negative", "video", "edit", "workflow", "requires")},
                             "hook": args["p_hook"], "hook_text": args["p_hook_text"], "chosen_by": args["p_chosen_by"], "inputs": []}
            return {"job": JOB}
        if name == "creative_rank":
            return self.rank
        if name == "creative_attempt_begin":
            return {"attempt": f"att-{len(self.calls)}", "n": 1, "kind": "local"}
        if name == "creative_asset_add":
            return {"asset": f"asset-{len(self.calls)}", "version": 1}
        if name == "creative_finish":
            return {"job": JOB, "status": "awaiting_approval" if args["p_passed"] else "failed"}
        return {}

    def names(self):
        return [n for n, _ in self.calls]


SANDBOX = [{"slug": "sandbox", "kind": "local", "models": ["sandbox-testsrc"], "est_cents": 0, "unit": "job", "env_key": ""}]


def claim(module="video", office="the-trap", providers=SANDBOX, platforms=("9:16",), brief="The black hoodie. Heavy cotton.", **k):
    return {"job": JOB, "office": office, "module": module, "brief": brief, "quality": "standard", "platforms": list(platforms), "premium_allowed": False,
            "preset": None, "max_attempts": 3, "providers": providers, "brand_kit": {"group": {"dont": ["guaranteed"]}, "office": {"colours": ["#111111", "#F4C430"]}}, **k}


class TemplateChoiceTest(unittest.TestCase):
    def test_requested_template_wins(self):
        t = {"template": "trap-turntable", "spec": {}, "chosen_by": "request"}
        rpc = FakeRpc(claim(), template=t)
        self.assertEqual(cs.choose_template(rpc.c, JOB, rpc, hp, LIB), t)
        self.assertNotIn("creative_job_set_template", rpc.names())

    def test_ranked_then_default(self):
        rpc = FakeRpc(claim(), rank={"templates": [{"template": "group-short-explainer"}], "hooks": [{"hook": "pov"}]})
        job = next(j for j in (f"{i:08d}-0000-4000-8000-000000000000" for i in range(50)) if int(cs.hashlib.sha256(j.encode()).hexdigest()[:8], 16) % 5)
        t = cs.choose_template(rpc.c, job, rpc, hp, LIB)
        self.assertEqual((t["template"], t["chosen_by"], t["hook"]), ("group-short-explainer", "ranked", "pov"))
        rpc = FakeRpc(claim())
        self.assertEqual(cs.choose_template(rpc.c, job, rpc, hp, LIB)["chosen_by"], "default")

    def test_explore_one_in_five(self):
        job = next(j for j in (f"{i:08d}-0000-4000-8000-000000000000" for i in range(50)) if int(cs.hashlib.sha256(j.encode()).hexdigest()[:8], 16) % 5 == 0)
        rpc = FakeRpc(claim(), rank={"templates": [{"template": "trap-turntable"}]})
        t = cs.choose_template(rpc.c, job, rpc, hp, LIB)
        self.assertEqual(t["chosen_by"], "explore")
        self.assertNotEqual(t["template"], "trap-turntable")

    def test_never_for_edit_jobs_and_lora_needs_a_character(self):
        rpc = FakeRpc(claim(module="edit"))
        self.assertIsNone(cs.choose_template(rpc.c, JOB, rpc, hp, LIB))
        rpc = FakeRpc(claim(module="image", office="pimp-ai"))
        t = cs.choose_template(rpc.c, JOB, rpc, hp, LIB)
        self.assertFalse((hp.template(LIB, t["template"]).get("requires") or {}).get("character_lora"))

    def test_v1_database_without_m8c_runs_without_a_template(self):
        def rpc(name, args):
            if name == "creative_job_template":
                raise cs.StudioError("function public.creative_job_template does not exist")
            return {}
        self.assertIsNone(cs.choose_template(claim(), JOB, rpc, hp, LIB))


@unittest.skipUnless(HAVE_FFMPEG, "ffmpeg missing")
class RunJobM8cTest(unittest.TestCase):
    def test_templated_video_gets_burned_captions_label_and_meta(self):
        rpc, root = FakeRpc(claim(platforms=("9:16", "1:1"))), tempfile.mkdtemp()
        fake = lambda path: [{"word": "The", "start": 0.1, "end": 0.3}, {"word": "black", "start": 0.3, "end": 0.6}, {"word": "hoodie.", "start": 0.6, "end": 1.0}]
        r = cs.run_job(JOB, rpc=rpc, env={"CREATIVE_VIDEO_SECONDS": "2"}, store=cs.LocalStore(root), workdir=tempfile.mkdtemp(), transcriber=fake)
        self.assertEqual(r["status"], "awaiting_approval", r)
        self.assertTrue(r["template"])
        adds = [a for n, a in rpc.calls if n == "creative_asset_add"]
        self.assertEqual(len(adds), 2)
        for a in adds:
            self.assertTrue(a["p_meta"]["ai_generated"] and a["p_meta"]["disclosure_overlay"])
            self.assertEqual(a["p_meta"]["captions"]["source"], "whisper+script")
            self.assertTrue(os.path.exists(os.path.join(root, a["p_meta"]["captions"]["srt"])))
        stage = [a for n, a in rpc.calls if n == "creative_stage" and a["p_stage"] == "direction"][0]
        self.assertIn("template:", stage["p_plan"]["direction"])

    def test_spoken_deceptive_words_fail_qa(self):
        rpc = FakeRpc(claim())
        fake = lambda path: [{"word": "verified", "start": 0.1, "end": 0.3}, {"word": "buyer", "start": 0.3, "end": 0.6}]
        r = cs.run_job(JOB, rpc=rpc, env={"CREATIVE_VIDEO_SECONDS": "2"}, store=cs.LocalStore(tempfile.mkdtemp()), workdir=tempfile.mkdtemp(), transcriber=fake)
        self.assertEqual(r["status"], "failed")
        self.assertIn("spoken words carry deceptive framing", r["reason"])
        self.assertNotIn("creative_asset_add", rpc.names())

    def test_edit_job_on_local_edit(self):
        root = tempfile.mkdtemp()
        store = cs.LocalStore(root)
        for i in range(2):
            src = os.path.join(root, f"c{i}.mp4")
            media.ff(["-f", "lavfi", "-i", f"testsrc2=size=640x360:rate=24:duration=2", "-c:v", "libx264", "-preset", "ultrafast", "-pix_fmt", "yuv420p", src])
            store.put(f"the-trap/library/c{i}.mp4", src, "video/mp4")
        t = {"template": "trap-hyper-motion-edit", "module": "edit", "spec": {k: v for k, v in hp.template(LIB, "trap-hyper-motion-edit").items() if k in ("prompt", "edit")},
             "hook": "drop-reveal", "hook_text": "New drop: the hoodie", "chosen_by": "request",
             "inputs": [{"id": f"in{i}", "path": f"the-trap/library/c{i}.mp4", "mime": "video/mp4"} for i in range(2)]}
        prov = [{"slug": "local-edit", "kind": "local", "models": ["ffmpeg-edit"], "est_cents": 0, "unit": "job", "env_key": ""}]
        rpc = FakeRpc(claim(module="edit", providers=prov), template=t)
        r = cs.run_job(JOB, rpc=rpc, env={}, store=store, workdir=tempfile.mkdtemp())
        self.assertEqual(r["status"], "awaiting_approval", r)
        self.assertEqual(r["attempts"][0]["provider"], "local-edit")
        meta = [a for n, a in rpc.calls if n == "creative_asset_add"][0]["p_meta"]
        self.assertGreaterEqual(meta["edit"]["segments"], 2)
        self.assertIsNone(meta["captions"]["source"])                                    # no speech, no script captions on an edit
        # an input outside the office is refused before anything runs
        t2 = dict(t, inputs=[{"id": "x", "path": "b2b-records/x.mp4", "mime": "video/mp4"}])
        rpc = FakeRpc(claim(module="edit", providers=prov), template=t2)
        r = cs.run_job(JOB, rpc=rpc, env={}, store=store, workdir=tempfile.mkdtemp())
        self.assertEqual(r["status"], "failed")
        self.assertNotIn("creative_attempt_begin", rpc.names())


class AnalyticsTest(unittest.TestCase):
    def test_csv_wide_and_long(self):
        wide = cs.parse_metrics_csv("asset,connector,window_end,views,likes,bogus\nA1,tiktok,2026-11-20,1,000,2\n")
        self.assertEqual([(r["metric"], r["value"]) for r in wide], [("views", 1.0), ("likes", 0.0)])
        wide = cs.parse_metrics_csv('asset,connector,views,likes\nA1,tiktok,"1,000",20\n')
        self.assertEqual([(r["metric"], r["value"]) for r in wide], [("views", 1000.0), ("likes", 20.0)])
        long = cs.parse_metrics_csv("hand_action,connector,metric,value\nH1,instagram,shares,3\n,instagram,shares,3\n")
        self.assertEqual(long, [{"hand_action": "H1", "connector": "instagram", "window_end": None, "metric": "shares", "value": 3.0}])

    def test_hands_insights_mapping(self):
        rows = cs.hands_metrics("H1", "instagram", {"reach": 500, "like_count": 20, "saved": 4, "flag": True, "weird": 1})
        self.assertEqual({r["metric"]: r["value"] for r in rows}, {"impressions": 500.0, "likes": 20.0, "saves": 4.0})

    def test_import_chunks_and_offsets_rejected_rows(self):
        seen = []

        def rpc(name, args):
            seen.append(len(args["p_rows"]))
            return {"inserted": len(args["p_rows"]) - 1, "updated": 0, "rejected": [{"row": 1, "reason": "x"}]}
        r = cs.import_metrics("the-trap", [{"asset": "a", "metric": "views", "value": 1}] * 1001, rpc=rpc)
        self.assertEqual(seen, [500, 500, 1])
        self.assertEqual([x["row"] for x in r["rejected"]], [1, 501, 1001])
        self.assertEqual(r["inserted"], 998)

    def test_rank_text(self):
        txt = cs.rank_text("the-trap", rpc=lambda n, a: {"templates": [{"template": "trap-turntable", "rank_score": 12.5, "posts": 3}], "hooks": []})
        self.assertIn("trap-turntable 12.5 (3 posts)", txt)


class SurfaceTest(unittest.TestCase):
    def test_no_new_network_or_money_paths(self):
        for mod in (media, hp):
            src = re.sub(r'"""[\s\S]*?"""', "", open(mod.__file__).read())
            for bad in ("urlopen", "requests.", "http.client", "socket", "hq_capital", "hq_office_money", "reserve", "settle"):
                self.assertNotIn(bad, src, (mod.__name__, bad))
        src = re.sub(r'"""[\s\S]*?"""', "", open(cs.__file__).read())
        self.assertNotIn("urlopen", src)
        self.assertNotIn("api.runpod.ai/v2/{ep}/runsync", src)


if __name__ == "__main__":
    unittest.main()
