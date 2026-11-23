"""Self-hosted generation backend (hq_creative_selfhost): content rules, persona packs, the ComfyUI adapter against a FAKE worker (no GPU, no network: any
real HTTP raises), router default + opt-in fal.ai fallback, $0 metering, the batch queue, the licence manifest and the worker kit files."""
import json
import os
import re
import shutil
import subprocess
import tempfile
import unittest
import urllib.parse

import hq_creative_presets as hp
import hq_creative_selfhost as sh
import hq_creative_studio as cs


def _no_network(*a, **k):
    raise AssertionError("a test tried to reach the network")


sh.SelfhostAdapter.http = lambda self, *a, **k: (self._http or _no_network)(*a, **k)
cs.HostedAdapter.http = lambda self, *a, **k: (self._http or _no_network)(*a, **k)
cs._reserve = cs._settle = cs._release = _no_network
HAVE_FFMPEG = bool(shutil.which("ffmpeg") and shutil.which("ffprobe"))
HERE = os.path.dirname(os.path.abspath(__file__))
JOB = "11111111-2222-4333-8444-555555555555"
TOKEN = "t" * 40
BASE = "https://worker-example.trycloudflare.com"
ENV = {"CREATIVE_STUDIO_MODE": "live", "COMFYUI_SELFHOST_URL": BASE, "COMFYUI_SELFHOST_TOKEN": TOKEN}
PACK = sh.load_persona_file(os.path.join(sh.PERSONA_DIR, "nova-example.json"))


def media_bytes(kind):
    """Small real media made by ffmpeg (so the studio's QA probe passes), or placeholder bytes without ffmpeg."""
    if not HAVE_FFMPEG:
        return {"png": b"\x89PNG fake", "mp4": b"fake mp4", "wav": b"RIFF" + b"\0" * 100}[kind]
    d = tempfile.mkdtemp()
    out = os.path.join(d, "x." + kind)
    args = {"png": ["-f", "lavfi", "-i", "color=c=0x336699:size=512x512", "-frames:v", "1"],
            "mp4": ["-f", "lavfi", "-i", "testsrc2=size=480x832:rate=16:duration=2", "-f", "lavfi", "-i", "sine=frequency=300:duration=2", "-c:v", "libx264",
                    "-pix_fmt", "yuv420p", "-c:a", "aac", "-shortest"],
            "wav": ["-f", "lavfi", "-i", "sine=frequency=440:duration=1"]}[kind]
    subprocess.run(["ffmpeg", "-hide_banner", "-loglevel", "error", "-y", *args, out], check=True)
    with open(out, "rb") as f:
        return f.read()


def object_info():
    """What a real worker answers on /object_info, built from every shipped graph (so preflight passes unless a test removes something)."""
    info = {}
    for w in sh.workflows({"CREATIVE_LTX_LICENCE_OK": "1"}).values():
        with open(w["path"]) as f:
            for n in json.load(f).values():
                c = info.setdefault(n["class_type"], {"input": {"required": {}, "optional": {}}})
                for k in n["inputs"]:
                    c["input"]["required"][k] = ["*"]
    return info


class FakeWorker:
    def __init__(self, vram_gb=24, up=True, fail=None, info=None, polls=1, output="png"):
        self.calls, self.vram, self.up, self.fail, self.polls, self.output = [], vram_gb, up, fail, polls, output
        self.info = info if info is not None else object_info()
        self.graphs, self.uploads = [], []

    def __call__(self, method, url, headers=None, json_body=None, data=None, timeout=60, form=None):
        self.calls.append((method, url, dict(headers or {})))
        if url.startswith(BASE):
            assert (headers or {}).get("Authorization") == f"Bearer {TOKEN}", "every worker call carries the token"
        if not self.up:
            raise RuntimeError("network error: URLError")
        p = urllib.parse.urlparse(url)
        if url.startswith("https://bucket.example/"):
            return 200, media_bytes("png"), {}
        if p.path == "/system_stats":
            return 200, {"system": {"comfyui_version": "0.3.test"}, "devices": [{"name": "cuda:0 Tesla T4", "vram_total": int(self.vram * 2 ** 30)}]}, {}
        if p.path == "/object_info":
            return 200, self.info, {}
        if p.path == "/upload/image":
            name = re.search(rb'filename="([^"]+)"', data).group(1).decode()
            self.uploads.append(name)
            return 200, {"name": name, "subfolder": "", "type": "input"}, {}
        if p.path == "/prompt":
            self.graphs.append(json_body["prompt"])
            return 200, {"prompt_id": "abcd1234-0000-4000-8000-000000000001", "number": 1, "node_errors": {}}, {}
        if p.path.startswith("/history/"):
            self.polls -= 1
            if self.polls > 0:
                return 200, {}, {}
            pid = p.path.rsplit("/", 1)[1]
            if self.fail:
                return 200, {pid: {"status": {"status_str": "error", "completed": False,
                                              "messages": [["execution_error", {"exception_message": self.fail}]]}, "outputs": {}}}, {}
            fn = "fendezy_00001_." + self.output
            return 200, {pid: {"status": {"status_str": "success", "completed": True}, "outputs": {"9": {"images": [{"filename": fn, "subfolder": "", "type": "output"}]}}}}, {}
        if p.path == "/view":
            return 200, media_bytes(self.output), {}
        if p.path == "/fz/tts":
            return 200, media_bytes("wav"), {}
        raise AssertionError(f"unexpected call {method} {url}")

    def paths(self):
        return [urllib.parse.urlparse(u).path for _, u, _ in self.calls]


def adapter(worker, env=ENV, **k):
    return sh.SelfhostAdapter(env, http=worker, sleep=lambda s: None, **k)


class ContentRulesTest(unittest.TestCase):
    def test_refusals(self):
        for bad in ("a teen girl dancing", "two kids at the beach", "a 16 year old model", "schoolgirl outfit", "a minor in a car",
                    "sexy lingerie shoot", "nude portrait", "NSFW", "a Taylor Swift lookalike", "impersonate the CEO", "deepfake of my boss",
                    "say: I'm a real person, not AI"):
            self.assertTrue(sh.content_problems(bad), bad)

    def test_allowed(self):
        for ok in ("A beat in C minor, minor chord progression", "Heavy cotton hoodie on a 30 year old man", "adult woman, 27, streetwear, studio light",
                   "Product shot of a ceramic mug", "The minor key gives it a dark mood"):
            self.assertEqual(sh.content_problems(ok), [], ok)

    def test_every_provider_refuses_at_submit_time(self):
        rpc = FakeRpcLite({"job": JOB, "office": "pimp-ai", "module": "image", "brief": "sexy teen photo", "platforms": ["9:16"], "providers": []})
        r = cs.run_job(JOB, rpc=rpc, env={}, workdir=tempfile.mkdtemp())
        self.assertEqual(r["status"], "failed")
        self.assertIn("minors", r["reason"])
        self.assertNotIn("creative_attempt_begin", [n for n, _ in rpc.calls])


class PersonaTest(unittest.TestCase):
    def test_example_pack_is_valid(self):
        self.assertEqual(sh.persona_problems(PACK, "pimp-ai"), [])

    def test_each_rule(self):
        cases = {"ai_generated": (dict(PACK, ai_generated=False), "ai_generated"),
                 "consent": (dict(PACK, real_person=True, fictional=False), "consent"),
                 "age": (dict(PACK, adult_age=19), "adult_age"),
                 "rating": (dict(PACK, content_rating="spicy"), "sfw"),
                 "photo": (dict(PACK, references=[{"path": "pimp-ai/personas/x/a.png", "source": "consented_photo"}]), "consent_id"),
                 "path": (dict(PACK, references=[{"path": "the-trap/personas/x/a.png", "source": "generated"}]), "own personas"),
                 "voice": (dict(PACK, voice={"engine": "clone", "voice": "someone"}), "no voice cloning"),
                 "text": (dict(PACK, appearance="lookalike of a famous singer"), "impersonation"),
                 "minor": (dict(PACK, appearance="teenage girl"), "minors"),
                 "office": (PACK, "belongs to office")}
        for name, (p, needle) in cases.items():
            probs = sh.persona_problems(p, "the-trap" if name == "office" else "pimp-ai")
            self.assertTrue(any(needle in x for x in probs), (name, probs))

    def test_persona_for_loads_checks_and_refuses(self):
        claim = {"office": "pimp-ai", "character": {"name": "Nova Example", "trigger_word": "nv4x"}}
        self.assertEqual(sh.persona_for(claim, local_dir=sh.PERSONA_DIR)["slug"], "nova-example")
        self.assertIsNone(sh.persona_for({"office": "pimp-ai"}, local_dir=sh.PERSONA_DIR))
        with self.assertRaises(sh.SelfhostError):
            sh.persona_for(dict(claim, character={"name": "Nova Example", "trigger_word": "other1"}), local_dir=sh.PERSONA_DIR)
        with self.assertRaises(sh.SelfhostError):
            sh.persona_for(dict(claim, office="the-trap"), local_dir=sh.PERSONA_DIR)

    def test_persona_prompt_keeps_the_look(self):
        p = sh.persona_prompt(PACK, "nv4x drinking coffee in a cafe")
        self.assertTrue(p.startswith(PACK["appearance"]))
        self.assertEqual(p.count("nv4x"), 1)


class ManifestTest(unittest.TestCase):
    def test_licence_safe_and_complete(self):
        m = sh.load_manifest()
        names = {w["model"] for w in sh.workflows({"CREATIVE_LTX_LICENCE_OK": "1"}).values()} | set(sh.services())
        for bad in ("flux.1-dev", "flux.1-dev-lora", "f5-tts", "instantid", "pulid"):
            self.assertNotIn(bad, names)
        for d in m["downloads"].values():
            self.assertRegex(d["licence"], r"^(Apache-2\.0|MIT)")
        for wid, w in m["workflows"].items():
            self.assertIn(w["model"], cs.MODEL_TIER, wid)
            self.assertIn(w["module"], cs.MODEL_MODULES[w["model"]], wid)
            with open(os.path.join(sh.WORKFLOW_DIR, w["file"])) as f:
                graph = json.load(f)
            holes = {mm.group(1) for n in graph.values() for v in n["inputs"].values() if isinstance(v, str) for mm in [hp.PLACEHOLDER.match(v)] if mm}
            self.assertEqual(holes, set(w["params"]), wid)
            for n in graph.values():
                for v in n["inputs"].values():
                    if isinstance(v, list):
                        self.assertIn(v[0], graph, wid)
            weights = {n["inputs"][k] for n in graph.values() for k in n["inputs"] if k in ("unet_name", "clip_name", "vae_name", "ckpt_name", "audio_encoder_name")}
            self.assertEqual(weights, set(w["files"]), wid)
        for wid, s in m["shared"].items():
            if not wid.startswith("_"):
                self.assertIn(wid, hp.load_manifest()["workflows"])
        for prof, p in m["profiles"].items():
            if prof.startswith("_"):
                continue
            for wid in p["workflows"]:
                w = m["workflows"].get(wid) or m["shared"].get(wid)
                self.assertIsNotNone(w, (prof, wid))
                for f in w["files"]:
                    self.assertIn(f, m["downloads"], (prof, f))
            self.assertAlmostEqual(p["disk_gb"], sum(m["downloads"][f]["gb"] for f in set(sum(((m["workflows"].get(w) or m["shared"][w])["files"]
                                                                                              for w in p["workflows"]), []))), delta=3)

    def test_ltx_only_behind_the_owner_gate(self):
        self.assertNotIn("ltx-video", {w["model"] for w in sh.workflows({}).values()})
        self.assertIn("ltx-video", {w["model"] for w in sh.workflows({"CREATIVE_LTX_LICENCE_OK": "1"}).values()})

    def test_migration_row_matches_the_manifest(self):
        sql = re.sub(r"--[^\n]*", "", open(os.path.join(HERE, "migrations", "20261209_creative_selfhost_v1.sql")).read())
        row = re.search(r"\('comfyui-selfhost',.*?array\[([^\]]+)\],\s*array\[([^\]]+)\],\s*'([A-Z_]*)',\s*([0-9.]+),\s*'(\w+)'", sql, re.S)
        self.assertIsNotNone(row)
        self.assertEqual({x.strip(" '") for x in row.group(2).split(",")}, set(sh.models()))
        self.assertEqual((row.group(3), float(row.group(4)), row.group(5)), ("COMFYUI_SELFHOST_URL", 0.0, "job"))
        self.assertNotRegex(sql, r"enabled\s*=\s*true|,\s*true\s*\)")


class AdapterTest(unittest.TestCase):
    def test_configuration_and_mode(self):
        self.assertTrue(sh.configured(ENV))
        for env in ({**ENV, "COMFYUI_SELFHOST_URL": "http://worker.example"}, {**ENV, "COMFYUI_SELFHOST_TOKEN": "short"}, {}):
            self.assertFalse(sh.configured(env))
        self.assertFalse(adapter(FakeWorker(), env={**ENV, "CREATIVE_STUDIO_MODE": "sandbox"}).available({**ENV, "CREATIVE_STUDIO_MODE": "sandbox"}))
        self.assertFalse(adapter(FakeWorker(up=False)).available(ENV))
        self.assertTrue(adapter(FakeWorker()).available(ENV))

    def test_vram_decides_what_the_worker_runs(self):
        a = adapter(FakeWorker(vram_gb=16))
        a.available(ENV)
        self.assertTrue(a.supports("z-image-turbo") and a.supports("wan-2.2-ti2v-5b") and a.supports("kokoro-82m"))
        self.assertFalse(a.supports("wan-2.2-s2v-14b") or a.supports("wan-2.2-t2v-a14b") or a.supports("flux.1-dev"))
        b = adapter(FakeWorker(vram_gb=24))
        b.available(ENV)
        self.assertTrue(b.supports("wan-2.2-s2v-14b"))

    def test_image_flow_costs_nothing_and_keeps_the_persona(self):
        w = FakeWorker(polls=3)
        a = adapter(w)
        a.available(ENV)
        r = a.generate("image", "z-image-turbo-lora", {"prompt": "nv4x at a cafe", "persona": PACK, "aspect": "9:16"}, tempfile.mkdtemp())
        self.assertEqual(r["actual_cents"], 0)
        self.assertTrue(r["meta"]["ai_generated"])
        self.assertEqual((r["meta"]["persona"], r["meta"]["persona_fictional"]), ("nova-example", True))
        self.assertEqual(w.paths(), ["/system_stats", "/object_info", "/prompt", "/history/abcd1234-0000-4000-8000-000000000001",
                                     "/history/abcd1234-0000-4000-8000-000000000001", "/history/abcd1234-0000-4000-8000-000000000001", "/view"])
        g = w.graphs[0]
        texts = [n["inputs"]["text"] for n in g.values() if n["class_type"] == "CLIPTextEncode"]
        self.assertTrue(texts[0].startswith(PACK["appearance"]))
        lora = [n for n in g.values() if n["class_type"] == "LoraLoaderModelOnly"][0]["inputs"]
        self.assertEqual((lora["lora_name"], lora["strength_model"]), ("nova-example.safetensors", 0.9))
        a2 = adapter(FakeWorker())
        a2.available(ENV)
        a2.generate("image", "z-image-turbo-lora", {"prompt": "nv4x at a cafe", "persona": PACK}, tempfile.mkdtemp())
        seed = lambda gr: [n for n in gr.values() if n["class_type"] == "KSampler"][0]["inputs"]["seed"]
        self.assertEqual(seed(g), seed(a2._http.graphs[0]))                     # same persona + prompt -> same seed (repeatable look)

    def test_talking_head_uploads_reference_and_voice(self):
        w = FakeWorker(output="mp4")
        a = adapter(w)
        a.available(ENV)
        spec = {"prompt": "talking to camera in a kitchen", "script": "Three things I love about this hoodie.", "persona": PACK, "seconds": 5,
                "resolve_url": lambda path: "https://bucket.example/" + path}
        r = a.generate("ugc", "wan-2.2-s2v-14b", spec, tempfile.mkdtemp())
        self.assertEqual(r["mime"], "video/mp4")
        self.assertEqual(w.uploads, ["ref.png", "voice.wav"])
        self.assertIn("/fz/tts", w.paths())
        node = [n for n in w.graphs[0].values() if n["class_type"] == "WanSoundImageToVideo"][0]["inputs"]
        self.assertEqual(node["length"], 77)                                     # one S2V chunk
        neg = [n for n in w.graphs[0].values() if n["class_type"] == "CLIPTextEncode"][1]["inputs"]["text"]
        self.assertIn(sh.SAFETY_NEGATIVE, neg)
        with self.assertRaises(sh.SelfhostError):
            adapter(FakeWorker()).generate("ugc", "wan-2.2-s2v-14b", {"prompt": "x", "script": "hi"}, tempfile.mkdtemp())

    def test_refusals_happen_before_any_gpu_call(self):
        w = FakeWorker()
        a = adapter(w)
        with self.assertRaises(sh.SelfhostError):
            a.generate("image", "z-image-turbo", {"prompt": "nude teen"}, tempfile.mkdtemp())
        with self.assertRaises(sh.SelfhostError):
            a.generate("image", "z-image-turbo", {"prompt": "portrait", "persona": dict(PACK, adult_age=17)}, tempfile.mkdtemp())
        self.assertNotIn("/prompt", w.paths())

    def test_preflight_catches_a_graph_the_worker_cannot_run(self):
        info = object_info()
        del info["ModelSamplingAuraFlow"]
        w = FakeWorker(info=info)
        a = adapter(w)
        a.available(ENV)
        with self.assertRaisesRegex(sh.SelfhostError, "ModelSamplingAuraFlow"):
            a.generate("image", "z-image-turbo", {"prompt": "a mug"}, tempfile.mkdtemp())
        self.assertNotIn("/prompt", w.paths())

    def test_worker_error_and_timeout(self):
        a = adapter(FakeWorker(fail="CUDA out of memory"))
        a.available(ENV)
        with self.assertRaisesRegex(sh.SelfhostError, "out of memory"):
            a.generate("image", "z-image-turbo", {"prompt": "a mug"}, tempfile.mkdtemp())
        t = [0.0]

        def clock():
            t[0] += 100
            return t[0]
        b = sh.SelfhostAdapter(ENV, http=FakeWorker(polls=10 ** 6), sleep=lambda s: None, clock=clock, deadline_s=500)
        b.available(ENV)
        with self.assertRaisesRegex(sh.SelfhostError, "timed out"):
            b.generate("image", "z-image-turbo", {"prompt": "a mug"}, tempfile.mkdtemp())

    def test_token_never_appears_in_errors(self):
        a = adapter(FakeWorker(fail="boom"))
        a.available(ENV)
        try:
            a.generate("image", "z-image-turbo", {"prompt": "a mug"}, tempfile.mkdtemp())
        except sh.SelfhostError as e:
            self.assertNotIn(TOKEN, str(e))

    @unittest.skipUnless(HAVE_FFMPEG, "ffmpeg missing")
    def test_voice_is_kokoro_on_the_worker(self):
        w = FakeWorker()
        a = adapter(w)
        r = a.generate("voice", "kokoro-82m", {"script": "Hello there.", "persona": PACK}, tempfile.mkdtemp())
        self.assertEqual((r["mime"], r["actual_cents"], r["meta"]["voice"]), ("audio/mp4", 0, "af_heart"))
        self.assertEqual(cs.probe(r["file"])["streams"], ["audio"])


PROVIDERS = [{"slug": "comfyui-selfhost", "kind": "local", "models": sh.models(), "est_cents": 0, "unit": "job", "env_key": "COMFYUI_SELFHOST_URL"},
             {"slug": "fal-hosted", "kind": "hosted", "models": ["flux.1-schnell", "wan-2.2-ti2v-5b"], "est_cents": 3.5, "unit": "output", "env_key": "FAL_KEY"}]


class RouterTest(unittest.TestCase):
    def test_selfhost_is_default_and_fal_is_opt_in(self):
        env = {**ENV, "FAL_KEY": "k"}
        ad = cs.adapters_for(PROVIDERS, env, {"comfyui-selfhost": adapter(FakeWorker(), env=env)})
        self.assertEqual(set(ad), {"comfyui-selfhost"})
        ad = cs.adapters_for(PROVIDERS, {**env, "CREATIVE_FAL_FALLBACK": "1"}, {"comfyui-selfhost": adapter(FakeWorker(), env=env)})
        self.assertEqual(set(ad), {"comfyui-selfhost", "fal-hosted"})
        cands = cs.candidates({"module": "image", "quality": "standard", "providers": PROVIDERS}, [], ad, {"count": 1})
        self.assertEqual((cands[0]["provider"], cands[0]["est"]), ("comfyui-selfhost", 0))
        self.assertEqual(cands[-1]["provider"], "fal-hosted")
        # worker down: still no silent fal.ai spending
        ad = cs.adapters_for(PROVIDERS, env, {"comfyui-selfhost": adapter(FakeWorker(up=False), env=env)})
        self.assertEqual(set(ad), set())

    def test_without_selfhost_fal_behaves_as_before(self):
        env = {"CREATIVE_STUDIO_MODE": "live", "FAL_KEY": "k"}
        self.assertEqual(set(cs.adapters_for(PROVIDERS[1:], env)), {"fal-hosted"})
        self.assertEqual(set(cs.adapters_for(PROVIDERS, env)), {"fal-hosted"})          # row enabled but not configured: fal unchanged

    def test_vram_gate_reaches_the_router(self):
        a = adapter(FakeWorker(vram_gb=16))
        ad = cs.adapters_for(PROVIDERS[:1], ENV, {"comfyui-selfhost": a})
        models = {c["model"] for c in cs.candidates({"module": "ugc", "quality": "standard", "providers": PROVIDERS[:1]}, [], ad, {"seconds": 5})}
        self.assertEqual(models, {"wan-2.2-ti2v-5b"})


class FakeRpcLite:
    def __init__(self, claim):
        self.c, self.calls = claim, []

    def __call__(self, name, args):
        self.calls.append((name, args))
        if name == "creative_claim":
            return self.c
        if name == "creative_attempt_begin":
            return {"attempt": f"att-{len(self.calls)}"}
        if name == "creative_asset_add":
            return {"asset": f"asset-{len(self.calls)}", "version": 1}
        if name == "creative_finish":
            return {"job": JOB, "status": "awaiting_approval" if args["p_passed"] else "failed"}
        if name in ("creative_job_template", "creative_rank"):
            return None
        return {}


@unittest.skipUnless(HAVE_FFMPEG, "ffmpeg missing")
class RunJobTest(unittest.TestCase):
    def test_image_job_on_the_worker_end_to_end_at_zero_cost(self):
        claim = {"job": JOB, "office": "pimp-ai", "module": "image", "brief": "Nova drinking coffee in a sunny cafe", "quality": "standard", "platforms": ["9:16"],
                 "premium_allowed": False, "preset": None, "max_attempts": 3, "providers": PROVIDERS,
                 "character": {"id": "c1", "name": "nova-example", "trigger_word": "nv4x", "lora": None}, "brand_kit": {}}
        rpc, root = FakeRpcLite(claim), tempfile.mkdtemp()
        store = cs.LocalStore(root)
        os.makedirs(os.path.join(root, "pimp-ai", "personas", "nova-example"))
        shutil.copyfile(os.path.join(sh.PERSONA_DIR, "nova-example.json"), os.path.join(root, "pimp-ai", "personas", "nova-example", "persona.json"))
        env = {**ENV, "FAL_KEY": "k"}
        money = lambda *a: (_ for _ in ()).throw(AssertionError("a $0 selfhost attempt must never reserve"))
        r = cs.run_job(JOB, rpc=rpc, env=env, store=store, workdir=tempfile.mkdtemp(), money=money,
                       extra_adapters={"comfyui-selfhost": adapter(FakeWorker(), env=env)})
        self.assertEqual(r["status"], "awaiting_approval", r)
        begin = [a for n, a in rpc.calls if n == "creative_attempt_begin"]
        self.assertEqual([(b["p_provider"], b["p_est_cents"]) for b in begin], [("comfyui-selfhost", 0)])
        end = [a for n, a in rpc.calls if n == "creative_attempt_end"][0]
        self.assertEqual((end["p_actual_cents"], end["p_reservation"]), (0, None))
        meta = [a for n, a in rpc.calls if n == "creative_asset_add"][0]["p_meta"]
        self.assertTrue(meta["ai_generated"])
        self.assertEqual((meta["persona"], meta["provider"], meta["disclosure"]), ("nova-example", "comfyui-selfhost", cs.DISCLOSURE))

    def test_a_bad_persona_pack_stops_the_job(self):
        claim = {"job": JOB, "office": "pimp-ai", "module": "image", "brief": "Nova at the gym", "platforms": ["9:16"], "providers": PROVIDERS,
                 "character": {"name": "nova-example", "trigger_word": "nv4x"}}
        root = tempfile.mkdtemp()
        os.makedirs(os.path.join(root, "pimp-ai", "personas", "nova-example"))
        with open(os.path.join(root, "pimp-ai", "personas", "nova-example", "persona.json"), "w") as f:
            json.dump(dict(PACK, adult_age=18), f)
        rpc = FakeRpcLite(claim)
        r = cs.run_job(JOB, rpc=rpc, env=ENV, store=cs.LocalStore(root), workdir=tempfile.mkdtemp(), extra_adapters={"comfyui-selfhost": adapter(FakeWorker())})
        self.assertEqual(r["status"], "failed")
        self.assertIn("adult_age", r["reason"])
        self.assertNotIn("creative_attempt_begin", [n for n, _ in rpc.calls])


class BatchQueueTest(unittest.TestCase):
    def setUp(self):
        self.q = sh.BatchQueue(os.path.join(tempfile.mkdtemp(), "q.json"))

    def test_enqueue_checks_and_orders(self):
        with self.assertRaises(sh.SelfhostError):
            self.q.enqueue(JOB, "pimp-ai", "image", "a sexy shoot")
        with self.assertRaises(sh.SelfhostError):
            self.q.enqueue(JOB, "pimp-ai", "train")
        ids = [f"{i:08d}-0000-4000-8000-000000000000" for i in range(4)]
        for i, m in zip(ids, ("ugc", "image", "video", "image")):
            self.q.enqueue(i, "the-trap", m)
        self.assertEqual(self.q.enqueue(ids[0], "the-trap", "ugc")["status"], "already queued")
        self.assertEqual([j["module"] for j in self.q.pending()], ["image", "image", "video", "ugc"])

    def test_worker_down_claims_nothing(self):
        self.q.enqueue(JOB, "the-trap", "image")
        ran = []
        r = self.q.drain(lambda *a, **k: ran.append(a), adapter(FakeWorker(up=False)), ENV)
        self.assertEqual((r["ran"], r["waiting"], r["worker"], ran), (0, 1, "down", []))

    def test_batch_runs_and_stops_when_the_worker_goes(self):
        ids = [f"{i:08d}-0000-4000-8000-000000000000" for i in range(5)]
        for i in ids:
            self.q.enqueue(i, "the-trap", "image")
        w = FakeWorker()
        a = adapter(w, health_ttl_s=0)
        seen = []

        def run(job, env, extra_adapters):
            seen.append(job)
            self.assertIs(extra_adapters["comfyui-selfhost"], a)
            if len(seen) == 2:
                w.up = False                                                     # the free session ended mid-batch
            return {"status": "awaiting_approval", "attempts": [{"provider": "comfyui-selfhost"}]}
        r = self.q.drain(run, a, ENV, batch_size=4)
        self.assertEqual((r["ran"], r["waiting"]), (2, 3))
        m = self.q.meter({"COMFYUI_SELFHOST_HOURLY_USD": "0.89"})
        self.assertEqual((m["jobs"], m["done"], m["studio_cents"]), (2, 2, 0))
        self.assertIn("rental_usd_estimate", m)
        self.assertIn("$0.00 to the studio", sh.status_text(ENV, self.q, adapter(FakeWorker())))


class SurfaceTest(unittest.TestCase):
    SRC = re.sub(r'"""[\s\S]*?"""', "", open(sh.__file__).read())

    def test_no_new_network_or_money_paths(self):
        for bad in ("urlopen", "requests.", "http.client", "socket", "hq_capital", "hq_office_money", "reserve(", "settle(", "subprocess", "fal.run",
                    "replicate", "runpod.ai"):
            self.assertNotIn(bad, self.SRC, bad)
        self.assertIn("hq_hands_adapters.http", self.SRC)

    def test_no_bypass_patterns(self):
        import test_no_bypass as nb
        t = nb.strip_comments_and_docstrings(open(sh.__file__).read())
        for pat in nb.PROVIDER_PATTERNS:
            self.assertIsNone(re.search(pat, t, re.M | re.I), pat)

    def test_worker_kit(self):
        wdir = os.path.join(sh.SELFHOST_DIR, "worker")
        src = open(os.path.join(wdir, "fz_worker.py")).read()
        compile(src, "fz_worker.py", "exec")
        self.assertIn("hmac.compare_digest", src)
        self.assertNotRegex(src, r"(?i)(api[_-]?key|token)\s*=\s*['\"][A-Za-z0-9_-]{20,}")
        for nb_name in ("kaggle_worker.ipynb", "colab_batch.ipynb"):
            nbj = json.load(open(os.path.join(wdir, nb_name)))
            self.assertEqual(nbj["nbformat"], 4)
            code = "".join("".join(c["source"]) for c in nbj["cells"] if c["cell_type"] == "code")
            self.assertIn("fz_worker.py", code)
            self.assertNotRegex(code, r"[A-Za-z0-9_-]{40,}")                     # no keys or tokens baked in
            if nb_name.startswith("colab"):
                self.assertIn("--batch", code)                                   # Colab terms: no tunnel / web service
                self.assertNotIn("cloudflared", code)
        tpl = json.load(open(os.path.join(wdir, "runpod_template.json")))
        self.assertIn("8189/http", tpl["ports"])
        self.assertFalse(any(re.search(r"(?i)key|token", k) and v for k, v in tpl["env"].items() if k != "FZ_WORKER_TOKEN"))
        self.assertEqual(tpl["env"].get("FZ_WORKER_TOKEN"), "")


if __name__ == "__main__":
    unittest.main()
