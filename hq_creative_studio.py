"""FENDEZY AI CREATIVE STUDIO (Phase 1, M8a): one shared group studio for the 8 offices. Thin Python around the database gates of
migrations/20261205_creative_studio_v1.sql; design in docs/architecture/PHASE1_M8_CREATIVE_STUDIO.md, components in CREATIVE_STUDIO_COMPONENTS.md.

One pipeline worker runs the 11 agent ROLES as steps (not 11 processes): Brief -> Research -> Strategy -> Script -> Creative direction -> Generation ->
Editing -> QA -> Approval -> Publishing -> Analytics. LLM steps are optional and go through hq_llm.complete (the provider-independent router; nothing is
hard-coded to one vendor); without an llm the worker uses templates, so a sandbox run costs nothing.

Model router per request: content type -> tier and resolution -> estimate -> cheapest QUALIFIED model of an enabled provider -> generate -> QA -> escalate
(next candidate; premium only after an open-source QA failure, or a 'hero' job whose office preset says so, and only where the owner allowed premium) ->
record actual cost and time. The database re-checks every one of these gates (creative_attempt_begin / creative_attempt_end) and caps retries.

Money: a paid attempt is reserved through the EXISTING office spend gate (hq_office_money.reserve -> fz_reserve_office_spend -> reserve_spend: caps,
per-transaction / weekly limits, owner approval rules) BEFORE the provider is called, then settled (hq_capital.settle) or released. A deny / ask_owner
stops the attempt: nothing is spent. Sandbox providers cost 0 and never reserve.

Mode: CREATIVE_STUDIO_MODE=sandbox (default) uses only the sandbox adapter (deterministic ffmpeg test media, no network). 'live' also needs the
provider enabled by the owner AND its key in the environment; the live adapters arrive in M8b.

M8c: templates / hooks (hq_creative_presets, data in creative_studio/presets), the editing step (hq_creative_media: word-timed burned captions with
faster-whisper, AI label, loudness, auto-reframe, B-roll / beat-synced edits, visualizers), a self-hosted ComfyUI adapter (RunPod worker-comfyui, through
hq_hands_adapters.http like fal) and the analytics loop (creative_metrics_import -> creative_rank -> template choice for the next job).
"""
from __future__ import annotations

import hashlib
import json
import logging
import math
import os
import re
import shutil
import subprocess
import tempfile
import time

logger = logging.getLogger(__name__)

STAGES = ("brief", "research", "strategy", "script", "direction", "generation", "editing", "qa", "approval", "publishing", "analytics")
# role -> (stage, uses an LLM when one is given). One worker runs them in order; only the marked ones may call hq_llm.
ROLES = {
    "market-research": ("research", True), "trend-analysis": ("research", False), "content-strategy": ("strategy", True),
    "copy-scripts": ("script", True), "creative-direction": ("direction", True), "image-gen": ("generation", False), "video-gen": ("generation", False),
    "editing": ("editing", False), "qa": ("qa", False), "publishing": ("publishing", False), "analytics": ("analytics", False),
}
TIERS = ("draft", "standard", "high", "hero")
PLATFORMS = {"9:16": (1080, 1920), "1:1": (1080, 1080), "16:9": (1920, 1080)}
DISCLOSURE = "AI-generated content."
BUCKET = "creative-studio"
MAX_ATTEMPTS_HARD = 5

# the best tier each model can serve (premium models serve hero). An open model qualifies for 'hero' when it serves 'high'.
MODEL_TIER = {
    "sandbox-testsrc": "hero", "flux.1-schnell": "standard", "sdxl-1.0": "standard", "flux.1-dev": "high", "flux.1-dev-lora": "high",
    "wan-2.2-ti2v-5b": "standard", "wan-2.2": "high", "wan-2.2-t2v-a14b": "high", "ltx-2": "high", "hunyuanvideo-1.5": "high",
    "kokoro-tts": "high", "ace-step": "high", "musicgen": "standard", "flux-lora-trainer": "high", "hq_llm": "high",
    "flux.1-schnell-lora": "standard", "ltx-video": "standard", "ffmpeg-edit": "hero",
    "veo-3.1": "hero", "veo-3.1-fast": "hero", "kling-3.0": "hero", "gen-4": "hero", "gen-4-turbo": "hero", "multilingual-v2": "hero",
}
MODEL_MODULES = {
    "flux.1-schnell": {"image"}, "sdxl-1.0": {"image"}, "flux.1-dev": {"image"}, "flux.1-dev-lora": {"image"},
    "wan-2.2-ti2v-5b": {"video", "ugc"}, "wan-2.2": {"video", "ugc"}, "wan-2.2-t2v-a14b": {"video", "ugc"}, "ltx-2": {"video", "ugc"},
    "hunyuanvideo-1.5": {"video"}, "kokoro-tts": {"voice"}, "ace-step": {"music"}, "musicgen": {"music"}, "flux-lora-trainer": {"train"},
    "veo-3.1": {"video", "ugc"}, "veo-3.1-fast": {"video", "ugc"}, "kling-3.0": {"video", "ugc"}, "gen-4": {"video", "ugc"}, "gen-4-turbo": {"video", "ugc"},
    "multilingual-v2": {"voice"}, "hq_llm": {"copy"}, "sandbox-testsrc": {"video", "image", "ugc", "voice", "music"},
    "flux.1-schnell-lora": {"image"}, "ltx-video": {"video", "ugc"}, "ffmpeg-edit": {"edit"},
}
# ESTIMATED GPU-seconds per unit of output on a 48GB-class GPU (per image, or per second of video / audio). Real numbers replace these after M8b runs.
GPU_SECONDS = {"flux.1-schnell": 4, "sdxl-1.0": 6, "flux.1-dev": 20, "flux.1-dev-lora": 22, "wan-2.2-ti2v-5b": 25, "wan-2.2-t2v-a14b": 90,
               "ltx-2": 12, "hunyuanvideo-1.5": 80, "kokoro-tts": 1, "ace-step": 2, "flux-lora-trainer": 1800, "flux.1-schnell-lora": 5, "ltx-video": 12}
# deceptive framing (action_policy prohibited: deceptive_communication / fabricate) and real-artist imitation
DECEPTIVE = re.compile(r"\b(testimonial|customer review|real customer|verified (buyer|purchase)|i bought|5[- ]star review|as seen on|unpaid review)\b", re.I)
IMITATION = re.compile(r"\b(in the style of|sounds? like|voice of|imitat\w*|clone (the |his |her )?voice|deepfake)\b", re.I)


class StudioError(Exception):
    pass


def mode(env: dict | None = None) -> str:
    return "live" if (env if env is not None else os.environ).get("CREATIVE_STUDIO_MODE") == "live" else "sandbox"


def _rpc_default(name: str, args: dict):
    import hq
    return hq._request("POST", f"/rest/v1/rpc/{name}", args)


# ------------------------------------------------------------------------------------------------------------------- storage
class LocalStore:
    """Sandbox store: a folder that mirrors the bucket layout (<office>/...)."""

    def __init__(self, root: str):
        self.root = root

    def put(self, path: str, src_file: str, mime: str) -> str:
        _check_path(path)
        dst = os.path.join(self.root, path)
        os.makedirs(os.path.dirname(dst), exist_ok=True)
        shutil.copyfile(src_file, dst)
        return path

    def url(self, path: str, expires: int = 3600) -> str:
        _check_path(path)
        return "file://" + os.path.join(self.root, path)

    def fetch(self, path: str, dst: str) -> str:
        _check_path(path)
        shutil.copyfile(os.path.join(self.root, path), dst)
        return dst


class SupabaseStore:
    """ONE private bucket ('creative-studio', created by the owner: public = false, no listing policy), paths <office>/..., signed URLs only.
    All HTTP goes through hq_hands_adapters.http (the audited outbound path)."""

    def __init__(self, base_url: str, service_key: str, bucket: str = BUCKET, http=None):
        if not base_url.startswith("https://"):
            raise StudioError("storage needs an https Supabase URL")
        self.base, self.key, self.bucket = base_url.rstrip("/"), service_key, bucket
        self._http = http

    def _h(self):
        if self._http:
            return self._http
        import hq_hands_adapters
        return hq_hands_adapters.http

    def put(self, path: str, src_file: str, mime: str) -> str:
        _check_path(path)
        with open(src_file, "rb") as f:
            data = f.read()
        st, body, _ = self._h()("POST", f"{self.base}/storage/v1/object/{self.bucket}/{path}",
                                headers={"Authorization": f"Bearer {self.key}", "apikey": self.key, "Content-Type": mime, "x-upsert": "false"}, data=data)
        if st not in (200, 201):
            raise StudioError(f"storage upload refused ({st})")
        return path

    def url(self, path: str, expires: int = 3600) -> str:
        _check_path(path)
        st, body, _ = self._h()("POST", f"{self.base}/storage/v1/object/sign/{self.bucket}/{path}",
                                headers={"Authorization": f"Bearer {self.key}", "apikey": self.key}, json_body={"expiresIn": int(min(max(expires, 60), 7 * 86400))})
        if st != 200 or not isinstance(body, dict) or not body.get("signedURL"):
            raise StudioError(f"signed URL refused ({st})")
        return self.base + "/storage/v1" + body["signedURL"]

    def fetch(self, path: str, dst: str) -> str:
        """Download one of the office's files (edit inputs) through a short-lived signed URL."""
        st, data, _ = self._h()("GET", self.url(path, 300), timeout=300)
        if st != 200 or not isinstance(data, (bytes, bytearray)) or len(data) > MAX_DOWNLOAD:
            raise StudioError(f"storage download refused ({st})")
        with open(dst, "wb") as f:
            f.write(data)
        return dst


def _check_path(path: str) -> None:
    if not re.fullmatch(r"[a-z][a-z0-9-]{1,39}/[A-Za-z0-9._/-]+", path or "") or ".." in path or len(path) > 340:
        raise StudioError(f"bad asset path {path!r}")


# ------------------------------------------------------------------------------------------------------------------- media (ffmpeg)
def _ff(args: list[str], timeout: int = 120) -> None:
    r = subprocess.run(["ffmpeg", "-hide_banner", "-loglevel", "error", "-y", *args], capture_output=True, timeout=timeout)
    if r.returncode != 0:
        raise StudioError("ffmpeg failed: " + r.stderr.decode(errors="replace")[-300:])


def probe(path: str) -> dict:
    r = subprocess.run(["ffprobe", "-v", "error", "-show_entries", "stream=codec_type,width,height:format=duration", "-of", "json", path],
                       capture_output=True, timeout=60)
    if r.returncode != 0:
        raise StudioError("ffprobe failed")
    j = json.loads(r.stdout or b"{}")
    v = next((s for s in j.get("streams", []) if s.get("codec_type") == "video"), {})
    return {"width": v.get("width"), "height": v.get("height"), "duration": float((j.get("format") or {}).get("duration") or 0),
            "streams": sorted({s.get("codec_type") for s in j.get("streams", [])})}


def srt(text: str, seconds: float) -> str:
    """Even-timed captions from the script (M8b swaps in faster-whisper timings)."""
    lines = [x.strip() for x in re.split(r"(?<=[.!?])\s+", text or "") if x.strip()][:20] or ["(no caption)"]
    step = max(seconds / len(lines), 0.5)
    ts = lambda s: f"{int(s // 3600):02d}:{int(s % 3600 // 60):02d}:{int(s % 60):02d},{int(round((s % 1) * 1000)):03d}"
    return "".join(f"{i + 1}\n{ts(i * step)} --> {ts(min((i + 1) * step, seconds))}\n{line}\n\n" for i, line in enumerate(lines))


def render(src: str, platform: str, out: str, captions: str | None = None) -> str:
    """Platform-ready file: scale + pad to the platform frame; video gets H.264/AAC, soft captions (mov_text) and the AI label in metadata."""
    w, h = PLATFORMS[platform]
    vf = f"scale={w}:{h}:force_original_aspect_ratio=decrease,pad={w}:{h}:(ow-iw)/2:(oh-ih)/2,setsar=1"
    if out.endswith(".png"):
        _ff(["-i", src, "-vf", vf, "-frames:v", "1", out])
        return out
    args = ["-i", src]
    if captions:
        cap = out + ".srt"
        with open(cap, "w") as f:
            f.write(captions)
        args += ["-i", cap, "-map", "0:v", "-map", "0:a?", "-map", "1:s", "-c:s", "mov_text"]
    args += ["-vf", vf, "-c:v", "libx264", "-preset", "veryfast", "-pix_fmt", "yuv420p", "-c:a", "aac", "-movflags", "+faststart",
             "-metadata", "comment=" + DISCLOSURE, out]
    _ff(args, timeout=600)
    return out


# ------------------------------------------------------------------------------------------------------------------- adapters
class SandboxAdapter:
    """Deterministic local test media (ffmpeg lavfi): proves the edit / render / QA path for real without a network or a GPU."""
    slug = "sandbox"
    unit_cost_cents = 0

    def available(self, env: dict) -> bool:
        return True

    def generate(self, module: str, model: str, spec: dict, workdir: str) -> dict:
        seed = int(hashlib.sha256((spec.get("prompt") or "").encode()).hexdigest()[:6], 16)
        colour = f"0x{seed:06x}"
        if module == "image":
            out = os.path.join(workdir, "raw.png")
            _ff(["-f", "lavfi", "-i", f"testsrc2=size=1024x1024:rate=1", "-f", "lavfi", "-i", f"color=c={colour}:size=1024x1024",
                 "-filter_complex", "[0][1]blend=all_mode=average", "-frames:v", "1", out])
            return {"file": out, "mime": "image/png", "actual_cents": 0}
        if module in ("video", "ugc"):
            out = os.path.join(workdir, "raw.mp4")
            d = str(max(1, min(int(spec.get("seconds") or 3), 10)))
            _ff(["-f", "lavfi", "-i", f"testsrc2=size=1280x720:rate=24:duration={d}", "-f", "lavfi", "-i", f"sine=frequency={200 + seed % 600}:duration={d}",
                 "-c:v", "libx264", "-preset", "ultrafast", "-pix_fmt", "yuv420p", "-c:a", "aac", "-shortest", out])
            return {"file": out, "mime": "video/mp4", "actual_cents": 0}
        if module in ("voice", "music"):
            out = os.path.join(workdir, "raw.m4a")
            _ff(["-f", "lavfi", "-i", f"sine=frequency={200 + seed % 600}:duration=3", "-c:a", "aac", out])
            return {"file": out, "mime": "audio/mp4", "actual_cents": 0}
        raise StudioError(f"sandbox has no {module}")


class LiveAdapter:
    """Registry slot for a provider without an adapter yet (ComfyUI on RunPod / Modal, the premium APIs, the aggregator slot). Never available, so the
    router skips it even when the owner enabled it and the key is set."""

    def __init__(self, slug: str, env_key: str):
        self.slug, self.env_key = slug, env_key

    def available(self, env: dict) -> bool:
        return False                                                            # never routed to until its adapter exists

    def generate(self, module, model, spec, workdir):
        raise StudioError(f"{self.slug}: adapter not built yet")


HOSTED_FILE = os.path.join(os.path.dirname(os.path.abspath(__file__)), "creative_studio", "hosted_models.json")
FX_CAD = 1.40
ASPECT_FAL = {"9:16": "portrait_16_9", "1:1": "square_hd", "16:9": "landscape_16_9"}
MAX_DOWNLOAD = 300 * 1024 * 1024


def hosted_models() -> dict:
    with open(HOSTED_FILE) as f:
        return {k: v for k, v in json.load(f).items() if not k.startswith("_")}


class HostedAdapter:
    """Hosted open-weight models through fal.ai's per-call queue API: the v1 generation path, no GPU infrastructure. (A Replicate adapter is NOT included:
    the protected test_no_bypass allow-lists the files that may call such providers; see ops/proposals/creative_studio_registry.md.)
    Keys come from the environment only and are never logged. Every request and download goes through hq_hands_adapters.http (https only).
    actual_cents = the per-call ESTIMATE (neither API itemises the bill per call); reconcile against the monthly invoice."""

    def __init__(self, slug: str, env_key: str, env: dict, http=None, sleep=time.sleep, deadline_s: int = 900, poll_s: float = 3.0):
        self.slug, self.env_key, self.env = slug, env_key, env
        self.cfg = hosted_models().get(slug, {})
        self._http, self.sleep, self.deadline_s, self.poll_s = http, sleep, deadline_s, poll_s

    def available(self, env: dict) -> bool:
        return mode(env) == "live" and bool(self.cfg) and bool(env.get(self.env_key))

    def http(self, *a, **k):
        if self._http:
            return self._http(*a, **k)
        import hq_hands_adapters
        return hq_hands_adapters.http(*a, **k)

    def cost_cents(self, model: str, spec: dict) -> int:
        m = self.cfg[model]
        units = max(1, int(spec.get("seconds") or 1)) if m["unit"] == "video-second" else 1
        return int(math.ceil(m["usd"] * FX_CAD * 100 * units))

    def _input(self, module: str, model: str, spec: dict) -> dict:
        aspect = spec.get("aspect") or "9:16"
        body = {"prompt": (spec.get("prompt") or "")[:2000]}
        if module == "train":
            return {"images_data_url": spec["training_zip_url"], "trigger_word": spec["trigger_word"]}
        if module == "image":
            body.update({"image_size": ASPECT_FAL[aspect], "num_images": 1} if self.slug == "fal-hosted" else {"aspect_ratio": aspect, "num_outputs": 1})
            if spec.get("lora_url"):
                body["loras"] = [{"path": spec["lora_url"], "scale": 1.0}]
        else:
            body["aspect_ratio"] = aspect
            if spec.get("seconds") and self.slug == "fal-hosted":
                body["duration"] = str(int(spec["seconds"]))
        if spec.get("reference_url"):
            body["image_url" if self.slug == "fal-hosted" else "image"] = spec["reference_url"]
        return body

    def _call(self, model: str, body: dict):
        key = self.env.get(self.env_key) or ""
        ep = self.cfg[model]["endpoint"]
        t_end = time.monotonic() + self.deadline_s
        if self.slug == "fal-hosted":
            h = {"Authorization": f"Key {key}", "Content-Type": "application/json"}
            st, r, _ = self.http("POST", f"https://queue.fal.run/{ep}", headers=h, json_body=body)
            if st not in (200, 201, 202) or not isinstance(r, dict) or not r.get("request_id"):
                raise StudioError(f"fal submit refused ({st})")
            status_url = r.get("status_url") or f"https://queue.fal.run/{ep}/requests/{r['request_id']}/status"
            response_url = r.get("response_url") or f"https://queue.fal.run/{ep}/requests/{r['request_id']}"
            while True:
                st, s, _ = self.http("GET", status_url, headers=h)
                state = (s or {}).get("status") if isinstance(s, dict) else None
                if state == "COMPLETED":
                    break
                if st >= 400 or state in ("FAILED", "ERROR", "CANCELLED"):
                    raise StudioError(f"fal job failed ({st} {state})")
                if time.monotonic() > t_end:
                    raise StudioError("fal job timed out")
                self.sleep(self.poll_s)
            st, out, _ = self.http("GET", response_url, headers=h)
            if st != 200 or not isinstance(out, dict):
                raise StudioError(f"fal result refused ({st})")
            for k in ("images", "video", "audio", "diffusers_lora_file"):
                v = out.get(k)
                v = v[0] if isinstance(v, list) and v else v
                if isinstance(v, dict) and v.get("url"):
                    return v["url"]
            raise StudioError("fal result has no file")
        raise StudioError(f"{self.slug}: no adapter (fal.ai only in v1)")

    def generate(self, module: str, model: str, spec: dict, workdir: str) -> dict:
        if model not in self.cfg:
            raise StudioError(f"{self.slug} has no endpoint for {model}")
        url = self._call(model, self._input(module, model, spec))
        if not str(url).startswith("https://"):
            raise StudioError("result URL is not https")
        st, data, hdr = self.http("GET", url, timeout=300)
        if st != 200 or not isinstance(data, (bytes, bytearray)) or not data or len(data) > MAX_DOWNLOAD:
            raise StudioError(f"download refused ({st})")
        ext, mime = {"image": (".png", "image/png"), "train": (".safetensors", "application/octet-stream")}.get(module, (".mp4", "video/mp4"))
        ctype = str((hdr or {}).get("Content-Type") or (hdr or {}).get("content-type") or "")
        if module == "image" and "jpeg" in ctype:
            ext, mime = ".jpg", "image/jpeg"
        if module == "image" and "webp" in ctype:
            ext, mime = ".webp", "image/webp"
        out = os.path.join(workdir, "raw" + ext)
        with open(out, "wb") as f:
            f.write(data)
        return {"file": out, "mime": mime, "actual_cents": self.cost_cents(model, spec)}


class ComfyUIAdapter:
    """Our own ComfyUI workflows (creative_studio/comfyui, API format) on a RunPod serverless endpoint running worker-comfyui UNMODIFIED (AGPL-3.0: we only
    call it over HTTPS). Every request goes through hq_hands_adapters.http. Live only, and only with the owner-enabled provider row, RUNPOD_API_KEY and
    COMFYUI_RUNPOD_ENDPOINT (the endpoint id) set. Only models with a shipped, commercially usable workflow are supported (supports()).
    Cost: the run is capped at the reserved GPU-seconds (policy.executionTimeout), and actual_cents = measured executionTime x the registry rate per GPU-second
    (an ESTIMATE until reconciled with the RunPod invoice; cold starts are billed by RunPod too)."""

    def __init__(self, slug: str, env_key: str, env: dict, rate_cents: float, http=None, sleep=time.sleep, deadline_s: int = 1200, poll_s: float = 4.0):
        import hq_creative_presets
        self.slug, self.env_key, self.env, self.rate = slug, env_key, env, float(rate_cents or 0)
        self.manifest = hq_creative_presets.load_manifest()["workflows"]
        self.by_model = {w["model"]: wid for wid, w in self.manifest.items()}
        self._http, self.sleep, self.deadline_s, self.poll_s = http, sleep, deadline_s, poll_s

    def available(self, env: dict) -> bool:
        return (mode(env) == "live" and self.slug == "runpod-comfyui" and bool(env.get(self.env_key))
                and bool(re.fullmatch(r"[a-z0-9]{6,40}", env.get("COMFYUI_RUNPOD_ENDPOINT") or "")))

    def supports(self, model: str) -> bool:
        return model in self.by_model

    def http(self, *a, **k):
        if self._http:
            return self._http(*a, **k)
        import hq_hands_adapters
        return hq_hands_adapters.http(*a, **k)

    def gpu_seconds(self, model: str, spec: dict) -> int:
        units = max(1, int(spec.get("seconds") or 1)) if model in ("wan-2.2-ti2v-5b", "wan-2.2-t2v-a14b", "ltx-video") else 1
        return int(GPU_SECONDS.get(model, 60) * units)

    def graph(self, model: str, spec: dict) -> dict:
        import hq_creative_presets as hp
        wid = spec.get("workflow") if spec.get("workflow") in self.manifest and self.manifest[spec["workflow"]]["model"] == model else self.by_model[model]
        w = self.manifest[wid]
        size = {"9:16": (720, 1280), "1:1": (1024, 1024), "16:9": (1280, 720)}[spec.get("aspect") or "9:16"]
        if w["output"] == "video":
            size = {"9:16": (704, 1280), "1:1": (960, 960), "16:9": (1280, 704)}[spec.get("aspect") or "9:16"]
        seed = int(hashlib.sha256((spec.get("prompt") or "").encode()).hexdigest()[:8], 16)
        p = {"prompt": spec.get("prompt") or "", "width": size[0], "height": size[1], "seed": seed}
        if "negative" in w["params"]:
            p["negative"] = spec.get("negative") or ""
        if w["output"] == "video":
            fps = int(spec.get("fps") or (16 if model == "wan-2.2-t2v-a14b" else 24))
            p.update({"fps": fps, "frames": hp.video_frames(int(spec.get("seconds") or 5), fps, model)})
        if "lora_name" in w["params"]:
            if not spec.get("lora_name"):
                raise StudioError("this workflow needs the character's LoRA on the ComfyUI volume")
            p.update({"lora_name": spec["lora_name"], "lora_strength": float(spec.get("lora_strength") or 1.0)})
        return hp.workflow(wid, p)

    def generate(self, module: str, model: str, spec: dict, workdir: str) -> dict:
        import base64
        if not self.supports(model):
            raise StudioError(f"{self.slug} has no workflow for {model}")
        key, ep = self.env.get(self.env_key) or "", self.env.get("COMFYUI_RUNPOD_ENDPOINT") or ""
        h = {"Authorization": f"Bearer {key}", "Content-Type": "application/json"}
        budget_ms = self.gpu_seconds(model, spec) * 1000
        st, r, _ = self.http("POST", f"https://api.runpod.ai/v2/{ep}/run", headers=h,
                             json_body={"input": {"workflow": self.graph(model, spec)}, "policy": {"executionTimeout": max(budget_ms, 10000)}})
        if st not in (200, 201) or not isinstance(r, dict) or not re.fullmatch(r"[A-Za-z0-9-]{6,80}", str(r.get("id") or "")):
            raise StudioError(f"runpod submit refused ({st})")
        t_end = time.monotonic() + self.deadline_s
        while True:
            st, s, _ = self.http("GET", f"https://api.runpod.ai/v2/{ep}/status/{r['id']}", headers=h)
            state = s.get("status") if isinstance(s, dict) else None
            if state == "COMPLETED":
                break
            if st >= 400 or state in ("FAILED", "CANCELLED", "TIMED_OUT"):
                raise StudioError(f"runpod job failed ({st} {state})")
            if time.monotonic() > t_end:
                raise StudioError("runpod job timed out")
            self.sleep(self.poll_s)
        files = []
        out = s.get("output") or {}
        for k in ("images", "videos", "gifs"):
            files += [x for x in out.get(k) or [] if isinstance(x, dict)]
        if not files:
            raise StudioError("runpod result has no file")
        f0 = files[0]
        name = str(f0.get("filename") or "out")
        if f0.get("type") == "base64":
            data = base64.b64decode(f0.get("data") or "", validate=True)
        elif f0.get("type") == "s3_url" and str(f0.get("data") or "").startswith("https://"):
            st, data, _ = self.http("GET", f0["data"], timeout=300)
            if st != 200 or not isinstance(data, (bytes, bytearray)):
                raise StudioError(f"download refused ({st})")
        else:
            raise StudioError("runpod result file has an unknown type")
        if not data or len(data) > MAX_DOWNLOAD:
            raise StudioError("runpod result is empty or too large")
        ext = os.path.splitext(name)[1].lower() if os.path.splitext(name)[1].lower() in (".png", ".jpg", ".webp", ".mp4", ".webm") else (".png" if module == "image" else ".mp4")
        mime = {".png": "image/png", ".jpg": "image/jpeg", ".webp": "image/webp", ".mp4": "video/mp4", ".webm": "video/webm"}[ext]
        path = os.path.join(workdir, "raw" + ext)
        with open(path, "wb") as f:
            f.write(data)
        ms = min(float(s.get("executionTime") or budget_ms), float(budget_ms))
        return {"file": path, "mime": mime, "actual_cents": int(math.ceil(ms / 1000.0 * self.rate)), "gpu_ms": int(ms), "delay_ms": int(s.get("delayTime") or 0)}


class LocalEditAdapter:
    """'local-edit': free ffmpeg editing on the Jarvis host (module 'edit'). B-roll stitch of the job's input clips, beat-synced cuts on the music input,
    hook-first order; captions, the AI label and loudness come in the editing step like every other job. No network."""
    slug = "local-edit"
    unit_cost_cents = 0

    def available(self, env: dict) -> bool:
        return bool(shutil.which("ffmpeg"))

    def supports(self, model: str) -> bool:
        return model == "ffmpeg-edit"

    def generate(self, module: str, model: str, spec: dict, workdir: str) -> dict:
        import hq_creative_media as media
        if module != "edit" or model != "ffmpeg-edit":
            raise StudioError("local-edit only edits")
        recipe = spec.get("edit") or {}
        clips, music = [], None
        for i, x in enumerate(spec.get("edit_inputs") or []):
            if x["mime"].startswith("audio/"):
                music = music or x["file"]
                continue
            path = x["file"]
            if x["mime"].startswith("image/"):                                   # a still becomes a 3 s clip
                path = os.path.join(workdir, f"still{i}.mp4")
                media.ff(["-loop", "1", "-t", "3", "-i", x["file"], "-vf", "scale=trunc(iw/2)*2:trunc(ih/2)*2,fps=30", "-c:v", "libx264", "-pix_fmt", "yuv420p", path])
            info = media.probe(path)
            clips.append({"path": path, "duration": info["duration"] or 3.0, "width": info["width"], "height": info["height"], "audio": info["audio"],
                          "score": media.motion_score(path) if recipe.get("hook_first") else 0})
        if not clips:
            raise StudioError("the edit has no input clips")
        bt = media.beats(music) if (music and recipe.get("beat_sync")) else {"beats": [], "bpm": None, "method": None}
        max_s = float(recipe.get("max_seconds") or 15)
        if music:
            max_s = min(max_s, media.probe(music)["duration"] or max_s)
        segs = media.plan_cuts(clips, bt["beats"], int((recipe.get("beat_sync") or {}).get("beats_per_cut") or 0) or None, max_s,
                               hook_first=bool(recipe.get("hook_first")))
        out = os.path.join(workdir, "raw.mp4")
        r = media.stitch(clips, segs, spec.get("aspect") or "9:16", out, music=music, fit=recipe.get("fit") or "auto_reframe",
                         crossfade=float(recipe.get("crossfade") or 0), workdir=workdir)
        return {"file": out, "mime": "video/mp4", "actual_cents": 0, "edit": {"segments": r["segments"], "seconds": r["seconds"], "bpm": bt.get("bpm"),
                                                                           "beat_method": bt.get("method")}}


def adapters_for(providers: list[dict], env: dict, extra: dict | None = None) -> dict:
    out = {}
    for p in providers:
        a = (extra or {}).get(p["slug"])
        if a is None:
            if p["slug"] == "sandbox":
                a = SandboxAdapter()
            elif p["slug"] == "local-edit":
                a = LocalEditAdapter()
            elif p["slug"] == "fal-hosted":
                a = HostedAdapter(p["slug"], p.get("env_key") or "", env)
            elif p["slug"] == "runpod-comfyui":
                a = ComfyUIAdapter(p["slug"], p.get("env_key") or "", env, float(p.get("est_cents") or 0))
            else:
                a = LiveAdapter(p["slug"], p.get("env_key") or "")
        if a.available(env) and (p["slug"] in ("sandbox", "local-edit") or mode(env) == "live"):
            out[p["slug"]] = a
    return out


# ------------------------------------------------------------------------------------------------------------------- router
def tier_ok(model: str, tier: str) -> bool:
    need = min(TIERS.index(tier), TIERS.index("high"))
    return TIERS.index(MODEL_TIER.get(model, "draft")) >= need


def estimate_cents(provider: dict, model: str, module: str, spec: dict) -> int:
    """ESTIMATE in CAD cents (rounded up). gpu-second: our GPU-seconds table x output units; per-output / per-second / per-minute: the registry price."""
    hosted = hosted_models().get(provider.get("slug"), {}).get(model)
    if hosted:
        units = max(1, int(spec.get("seconds") or 1)) if hosted["unit"] == "video-second" else 1
        return int(math.ceil(hosted["usd"] * FX_CAD * 100 * units))
    price = float(provider.get("est_cents") or 0)
    units = max(1, int(spec.get("seconds") or 1)) if module in ("video", "ugc", "voice", "music") else max(1, int(spec.get("count") or 1))
    unit = provider.get("unit")
    if unit == "gpu-second":
        q = GPU_SECONDS.get(model, 60) * (units if module != "train" else 1)
    elif unit == "minute":
        q = max(1, math.ceil(units / 60))
    elif unit in ("video-second", "output", "image"):
        q = units if unit != "output" or module in ("video", "ugc") else max(1, int(spec.get("count") or 1))
    else:
        q = 1
    return int(math.ceil(price * q))


def candidates(claim: dict, attempts: list[dict], adapters: dict, spec: dict) -> list[dict]:
    """Ordered (provider, model, est) list: cheapest qualified first. Premium only when allowed AND (an open attempt failed QA, or hero + preset)."""
    module, tier = claim["module"], claim.get("quality") or "standard"
    preset = claim.get("preset") or {}
    pref = list(preset.get("models") or [])
    allowed = bool(claim.get("premium_allowed"))
    open_failed = any(a["outcome"] == "qa_failed" and a["kind"] != "premium" for a in attempts)
    hero_direct = tier == "hero" and bool(preset.get("hero_premium")) and allowed
    tried = {(a["provider"], a["model"]) for a in attempts}
    rows = []
    for p in claim.get("providers") or []:
        if p["slug"] not in adapters:
            continue
        for m in p.get("models") or []:
            if module not in MODEL_MODULES.get(m, set()) or not tier_ok(m, tier) or (p["slug"], m) in tried:
                continue
            if hasattr(adapters[p["slug"]], "supports") and not adapters[p["slug"]].supports(m):
                continue                                                         # e.g. a ComfyUI slot without a (licence-safe) workflow for m
            if p["kind"] == "premium" and not (allowed and (open_failed or hero_direct)):
                continue
            est = estimate_cents(p, m, module, spec)
            rank = pref.index(m) if m in pref else len(pref)
            prem = p["kind"] == "premium"
            group = (0 if prem else 1) if hero_direct else (1 if prem else 0)      # hero + preset: premium first; otherwise open first
            rows.append({"provider": p["slug"], "model": m, "kind": p["kind"], "est": est, "key": (group, est, rank, p["slug"], m)})
    rows.sort(key=lambda r: r["key"])
    return rows


# ------------------------------------------------------------------------------------------------------------------- QA
def policy_refusal(brief: str, module: str) -> str | None:
    if DECEPTIVE.search(brief or ""):
        return "deceptive_communication / fabricate: AI content is never presented as a real customer, testimonial or review"
    if module in ("music", "voice", "ugc", "video") and IMITATION.search(brief or ""):
        return "no imitation of a real artist's or person's voice or style"
    return None


def qa(claim: dict, file: str, caption: str, platform: str | None = None) -> dict:
    """Deterministic checks first (cheap): file readable, platform frame, disclosure, brand-kit dont-list, deceptive framing. Score 0..1."""
    issues = []
    try:
        info = probe(file)
    except Exception:
        return {"passed": False, "score": 0.0, "issues": ["unreadable file"]}
    if claim["module"] in ("image", "video", "ugc", "edit") and not (info["width"] and info["height"]):
        return {"passed": False, "score": 0.0, "issues": ["no picture in the file"]}
    if platform and claim["module"] in ("image", "video", "ugc", "edit"):
        if (info["width"], info["height"]) != PLATFORMS[platform]:
            issues.append(f"frame {info['width']}x{info['height']} is not {platform}")
    if claim["module"] in ("video", "ugc", "edit") and info["duration"] <= 0:
        issues.append("empty video")
    if DISCLOSURE.lower().rstrip(".") not in (caption or "").lower():
        issues.append("missing AI-generated disclosure")
    kits = claim.get("brand_kit") or {}
    for kit in (kits.get("group") or {}, kits.get("office") or {}):
        for bad in kit.get("dont") or []:
            if bad and str(bad).lower() in (caption or "").lower():
                issues.append(f"brand kit: avoid '{bad}'")
        for need in kit.get("disclaimers") or []:
            if need and str(need).lower() not in (caption or "").lower():
                issues.append(f"brand kit: missing disclaimer '{need}'")
    if DECEPTIVE.search(caption or ""):
        issues.append("deceptive framing")
    score = max(0.0, 1.0 - 0.25 * len(issues))
    return {"passed": not issues, "score": round(score, 3), "issues": issues, "probe": info}


# ------------------------------------------------------------------------------------------------------------------- pipeline worker
def _plan(claim: dict, llm, facts: list[dict], tpl: dict | None = None, lib: dict | None = None) -> dict:
    """Research -> strategy -> script -> direction. Templates by default; with llm (hq_llm.complete-shaped) ONE call writes the script. With a template
    (M8c) the generation prompt is compiled from the template's shot / camera / lens / lighting vocabulary and the brief."""
    brief = claim["brief"]
    kit = (claim.get("brand_kit") or {}).get("office") or (claim.get("brand_kit") or {}).get("group") or {}
    plan = {"research": [f.get("fact", "")[:160] for f in facts[:3]], "strategy": f"{claim['module']} for {', '.join(claim.get('platforms') or [])}",
            "script": brief[:400], "direction": f"tone: {kit.get('tone', 'brand default')}; colours: {', '.join(kit.get('colours') or []) or 'brand default'}"}
    if llm:
        r = llm("You write short ad scripts. Plain text, 2-4 sentences, no claims of real customers or reviews.",
                [{"role": "user", "content": f"Brief: {brief[:1500]}\nTone: {kit.get('tone', '')}"}],
                division="ffm", task_class="creative_script", tier="small", max_output=300)
        text = (r or {}).get("text") if isinstance(r, dict) else None
        if text:
            plan["script"] = text.strip()[:800]
    plan["prompt"] = plan["script"]
    if tpl and lib:
        import hq_creative_presets as hp
        t = {"module": tpl.get("module") or claim["module"], **(tpl.get("spec") or {})}
        plan["prompt"] = hp.compile_prompt(lib, t, _subject(brief), _values(claim))
        plan["negative"] = (tpl.get("spec") or {}).get("negative") or ""
        plan["direction"] += f"; template: {tpl.get('template')}" + (f"; hook: {tpl.get('hook_text')}" if tpl.get("hook_text") else "")
    return plan


def _subject(brief: str) -> str:
    first = re.split(r"(?<=[.!?])\s+", (brief or "").strip())[0]
    first = re.sub(r"^[A-Za-z ]{1,20}:\s+", "", first)                          # "Second drop: the hoodie" -> "the hoodie"
    return first.rstrip(".!?")[:120]


def _values(claim: dict) -> dict:
    ch = claim.get("character") or {}
    v = {"subject": _subject(claim["brief"]), "title": _subject(claim["brief"])[:60]}
    if ch.get("name"):
        v["character"] = f"{ch.get('trigger_word') or ''} {ch['name']}".strip()
    return v


def _library():
    """(hq_creative_presets, library) or (None, None): a broken library never stops a job, it only means no template."""
    try:
        import hq_creative_presets as hp
        return hp, hp.load_library()
    except Exception as e:                                                       # pragma: no cover - logged, then v1 behaviour
        logger.warning("creative template library unavailable: %s", type(e).__name__)
        return None, None


def choose_template(claim: dict, job_id: str, rpc, hp=None, lib=None) -> dict | None:
    """The job's template: the one requested (creative_job_template), else the office's best-ranked one (creative_rank), exploring a different one for
    1 job in 5, else the office default. Edit jobs need explicit inputs, so they are never auto-templated. The DB re-checks office, module and hook."""
    try:
        t = rpc("creative_job_template", {"p_job": job_id})
    except Exception:
        return None                                                              # M8c not applied: v1 behaviour
    if isinstance(t, dict) and t.get("template"):
        return t
    if hp is None or lib is None or claim["module"] == "edit":
        return None
    has_lora = bool((claim.get("character") or {}).get("lora"))
    options = [x for x in hp.templates_for(lib, claim["office"], claim["module"]) if has_lora or not (x.get("requires") or {}).get("character_lora")]
    if not options:
        return None
    try:
        rank = rpc("creative_rank", {"p_office": claim["office"], "p_module": claim["module"]}) or {}
    except Exception:
        rank = {}
    order = [x.get("template") for x in rank.get("templates") or []]
    hook_order = [x.get("hook") for x in rank.get("hooks") or []]
    h = int(hashlib.sha256(str(job_id).encode()).hexdigest()[:8], 16)
    ranked = sorted(options, key=lambda x: order.index(x["slug"]) if x["slug"] in order else len(order))
    if order and h % 5 == 0 and len(options) > 1:
        pick, how = ranked[1 + (h // 5) % (len(ranked) - 1)], "explore"
    else:
        pick, how = ranked[0], ("ranked" if order and ranked[0]["slug"] in order else "default")
    hook_id = hook_txt = None
    for hid in sorted(pick.get("hooks") or [], key=lambda x: hook_order.index(x) if x in hook_order else len(hook_order)):
        txt = hp.hook_text(lib, hid, _values(claim))
        if txt and not DECEPTIVE.search(txt) and not IMITATION.search(txt):
            hook_id, hook_txt = hid, txt
            break
    try:
        rpc("creative_job_set_template", {"p_job": job_id, "p_template": pick["slug"], "p_hook": hook_id, "p_hook_text": hook_txt, "p_inputs": [], "p_chosen_by": how})
        t = rpc("creative_job_template", {"p_job": job_id})
    except Exception as e:
        logger.info("template not attached (%s); the job runs without one", str(e)[:120])
        return None
    return t if isinstance(t, dict) and t.get("template") else None


def _fetch_inputs(tpl: dict | None, claim: dict, store, tmp: str) -> list[dict]:
    """Edit inputs (same office: the DB checked it) downloaded to the work folder."""
    items = list((tpl or {}).get("inputs") or [])
    if claim.get("reuse_of") and not any(x.get("id") == claim["reuse_of"].get("id") for x in items):
        items.append(claim["reuse_of"])
    if not items:
        return []
    if store is None or not hasattr(store, "fetch"):
        raise StudioError("edit inputs need the asset store")
    d = os.path.join(tmp, "inputs")
    os.makedirs(d, exist_ok=True)
    out = []
    for i, x in enumerate(items):
        if not str(x.get("path") or "").startswith(claim["office"] + "/"):
            raise StudioError("an edit input is outside the job's office")
        dst = os.path.join(d, f"in{i}{os.path.splitext(x['path'])[1][:8]}")
        out.append({"file": store.fetch(x["path"], dst), "mime": x.get("mime") or "video/mp4", "id": x.get("id")})
    return out


DEFAULT_STYLE = {"font": "DejaVu Sans", "size": 52, "bold": False, "primary": "#FFFFFF", "highlight": "#FFFFFF", "outline": "#000000", "outline_px": 3,
                 "shadow_px": 1, "position": "lower", "words_per_line": 7, "uppercase": False, "animation": "none", "name": "subtle"}


def _edit_options(claim: dict, tpl: dict | None, hp, lib) -> dict:
    """Editing recipe for the job: the template's, else defaults (burned 'karaoke' captions for UGC, 'subtle' for video, pad to the frame, -14 LUFS)."""
    edit = dict(((tpl or {}).get("spec") or {}).get("edit") or {})
    kits = claim.get("brand_kit") or {}
    kit = kits.get("office") or kits.get("group") or {}
    name = edit.get("captions", "karaoke" if claim["module"] == "ugc" else "subtle")
    style = None
    if name and name != "none":
        try:
            style = hp.caption_style(lib, name, kit) if hp and lib else dict(DEFAULT_STYLE)
        except Exception:
            style = dict(DEFAULT_STYLE)
    colours = [c for c in kit.get("colours") or [] if re.fullmatch(r"#[0-9A-Fa-f]{6}", str(c))]
    return {"style": style, "fit": edit.get("fit") or "pad", "loudnorm": float(edit["loudnorm"]) if edit.get("loudnorm") is not None else -14.0,
            "pad_colour": colours[0] if colours else "black", "visualizer": edit.get("visualizer"), "highlight": (style or {}).get("highlight") or "#F4C430"}


def _spoken_issues(claim: dict, words: list[dict]) -> list[str]:
    """QA of the burned / spoken words (transcripts can say what the brief did not)."""
    text = " ".join(w["word"] for w in words or [])
    issues = []
    if DECEPTIVE.search(text):
        issues.append("spoken words carry deceptive framing")
    kits = claim.get("brand_kit") or {}
    for kit in (kits.get("group") or {}, kits.get("office") or {}):
        for bad in kit.get("dont") or []:
            if bad and str(bad).lower() in text.lower():
                issues.append(f"spoken words: brand kit says avoid '{bad}'")
    return issues


def run_job(job_id: str, *, rpc=None, store=None, env: dict | None = None, llm=None, money=None, settle=None, release=None, brain=None,
            extra_adapters: dict | None = None, workdir: str | None = None, clock=time.monotonic, transcriber=None) -> dict:
    """One job end to end, up to QA and 'awaiting_approval'. Returns a summary. Every failure ends the open attempt (no dangling reservations)."""
    import hq_creative_media as media
    rpc = rpc or _rpc_default
    env = dict(os.environ) if env is None else env
    claim = rpc("creative_claim", {"p_job": job_id})
    module, office = claim["module"], claim["office"]
    refusal = policy_refusal(claim["brief"], module)
    if refusal:
        rpc("creative_finish", {"p_job": job_id, "p_passed": False, "p_caption": "", "p_qa": {"refused": refusal}})
        return {"job": job_id, "status": "failed", "reason": refusal}
    facts = []
    if brain:
        try:
            facts = brain(office, claim["brief"][:200]) or []
        except Exception:
            facts = []
    hp, lib = _library()
    tpl = choose_template(claim, job_id, rpc, hp, lib)
    plan = _plan(claim, llm, facts, tpl, lib)
    for st in ("research", "strategy", "script", "direction"):
        rpc("creative_stage", {"p_job": job_id, "p_stage": st, "p_plan": {st: plan[st]}})
    caption = f"{plan['script'][:300]} {DISCLOSURE}".strip()
    vid = ((tpl or {}).get("spec") or {}).get("video") or {}
    spec = {"prompt": plan["prompt"], "negative": plan.get("negative") or "", "count": 1, "aspect": (claim.get("platforms") or ["9:16"])[0],
            "seconds": (int(vid.get("seconds") or env.get("CREATIVE_VIDEO_SECONDS") or 5)) if module in ("video", "ugc") else None,
            "fps": vid.get("fps"), "workflow": ((tpl or {}).get("spec") or {}).get("workflow"), "edit": ((tpl or {}).get("spec") or {}).get("edit") or {}}
    tmp = workdir or tempfile.mkdtemp(prefix="creative-")
    if claim.get("reuse_of") and store is not None:
        try:
            spec["reference_url"] = store.url(claim["reuse_of"]["path"])      # the approved asset this job builds on
        except Exception:
            pass
    if claim.get("character") and claim["character"].get("lora") and store is not None:
        spec["lora_url"] = store.url(claim["character"]["lora"])
        spec["lora_name"] = os.path.basename(claim["character"]["lora"])
        spec["prompt"] = f"{claim['character']['trigger_word']} {spec['prompt']}"
    if module == "edit":
        try:
            spec["edit_inputs"] = _fetch_inputs(tpl, claim, store, tmp)
        except Exception as e:
            return _finish_failed(rpc, job_id, [], f"edit inputs: {str(e)[:200]}")
    adapters = adapters_for(claim.get("providers") or [], env, extra_adapters)
    attempts: list[dict] = []
    max_n = min(int(claim.get("max_attempts") or 3), MAX_ATTEMPTS_HARD)
    winner = None
    while len(attempts) < max_n:
        cands = candidates(claim, attempts, adapters, spec)
        if not cands:
            break
        c = cands[0]
        begin = rpc("creative_attempt_begin", {"p_job": job_id, "p_provider": c["provider"], "p_model": c["model"], "p_est_cents": c["est"]})
        att = {"id": begin["attempt"], "provider": c["provider"], "model": c["model"], "kind": c["kind"], "outcome": "open"}
        attempts.append(att)
        reservation = None
        t0 = clock()
        if c["est"] > 0:
            gate = (money or _reserve)(office, c, job_id)
            if gate.get("decision") != "allow" or not gate.get("reservation_id"):
                att["outcome"] = "error"
                rpc("creative_attempt_end", {"p_attempt": att["id"], "p_outcome": "error", "p_actual_cents": 0, "p_reservation": None, "p_qa_score": None,
                                             "p_ms": 0, "p_error": f"spend gate: {gate.get('decision')}: {str(gate.get('reason'))[:150]}"})
                return _finish_failed(rpc, job_id, attempts, f"spend gate said {gate.get('decision')}: {gate.get('reason')}", gate=gate)
            reservation = gate["reservation_id"]
        adir = os.path.join(tmp, f"a{len(attempts)}")
        os.makedirs(adir, exist_ok=True)
        try:
            out = adapters[c["provider"]].generate(module, c["model"], spec, adir)
        except Exception as e:
            if reservation:
                (release or _release)(reservation)
            att["outcome"] = "error"
            rpc("creative_attempt_end", {"p_attempt": att["id"], "p_outcome": "error", "p_actual_cents": 0, "p_reservation": None, "p_qa_score": None,
                                         "p_ms": int((clock() - t0) * 1000), "p_error": str(e)[:200]})
            continue
        actual = int(out.get("actual_cents") or 0)
        if reservation:
            (settle or _settle)(reservation, actual, f"creative {job_id} attempt {len(attempts)} {c['provider']}/{c['model']}")
        verdict = qa(claim, out["file"], caption)
        att["outcome"] = "ok" if verdict["passed"] else "qa_failed"
        rpc("creative_attempt_end", {"p_attempt": att["id"], "p_outcome": att["outcome"], "p_actual_cents": actual, "p_reservation": reservation if actual > 0 else None,
                                     "p_qa_score": verdict["score"], "p_ms": int((clock() - t0) * 1000), "p_error": "; ".join(verdict["issues"])[:300] or None})
        if verdict["passed"]:
            winner = (c, out, verdict)
            break
    if not winner:
        return _finish_failed(rpc, job_id, attempts, "no candidate passed QA within the retry limit")
    c, out, verdict = winner
    rpc("creative_stage", {"p_job": job_id, "p_stage": "editing"})
    opts = _edit_options(claim, tpl, hp, lib)
    hook = (tpl or {}).get("hook_text")
    st_ = store or LocalStore(os.path.join(tmp, "bucket"))
    is_image, is_audio = out["mime"].startswith("image/"), out["mime"].startswith("audio/")
    base_meta = {"ai_generated": True, "provider": c["provider"], "model": c["model"], "disclosure": DISCLOSURE, "disclosure_overlay": not is_audio,
                 "template": (tpl or {}).get("template"), "hook": (tpl or {}).get("hook"), "hook_text": hook}
    if out.get("edit"):
        base_meta["edit"] = out["edit"]
    assets = []

    def register(path_rel: str, dst: str, mime: str, platform, name: str, meta: dict):
        st_.put(path_rel, dst, mime)
        with open(dst, "rb") as f:
            data = f.read()
        a = rpc("creative_asset_add", {"p_office": office, "p_job": job_id, "p_kind": "generated", "p_name": name, "p_path": path_rel, "p_mime": mime,
                                       "p_bytes": len(data), "p_sha256": hashlib.sha256(data).hexdigest(), "p_platform": platform, "p_meta": {**base_meta, **meta}})
        assets.append({"asset": a["asset"], "path": path_rel, "platform": platform})

    def finish_video(src: str, platform: str, tag: str, name_suffix: str = ""):
        dst = os.path.join(tmp, f"final-{tag}{name_suffix}.mp4")
        r = media.finish(src, platform, dst, script=plan["script"], style=opts["style"], hook=hook, fit=opts["fit"], pad_colour=opts["pad_colour"],
                         loudnorm=opts["loudnorm"], transcriber=transcriber, workdir=tmp, script_fallback=module in ("video", "ugc", "music"))
        issues = _spoken_issues(claim, r["words"])
        final_qa = qa(dict(claim, module="video"), dst, caption, platform)
        if issues or not final_qa["passed"]:
            raise StudioError("rendered file failed QA: " + "; ".join(issues + final_qa["issues"]))
        path = f"{office}/jobs/{job_id}/{tag}{name_suffix}.mp4"
        meta = {"captions": {"source": r["caption_source"], "style": (opts["style"] or {}).get("name"), "words": len(r["words"])},
                "loudness_in": (r["loudness"] or {}).get("input_i"), "loudness_target": opts["loudnorm"], "fit": opts["fit"]}
        if r["srt"]:
            srt_file = dst + ".srt"
            with open(srt_file, "w") as f:
                f.write(r["srt"])
            st_.put(path + ".srt", srt_file, "application/x-subrip")
            meta["captions"]["srt"] = path + ".srt"
        register(path, dst, "video/mp4", platform, f"job-{job_id[:8]}-{tag}{name_suffix}", meta)

    try:
        for platform in claim.get("platforms") or ["9:16"]:
            tag = platform.replace(":", "x")
            if is_audio:
                dst = os.path.join(tmp, f"final-{tag}.m4a")
                if not assets:                                               # one audio master (v1 stored one per platform; the file is identical)
                    shutil.copyfile(out["file"], dst)
                    final_qa = qa(claim, dst, caption, None)
                    if not final_qa["passed"]:
                        raise StudioError("rendered file failed QA: " + "; ".join(final_qa["issues"]))
                    register(f"{office}/jobs/{job_id}/{tag}.m4a", dst, "audio/mp4", None, f"job-{job_id[:8]}-{tag}", {})
                if opts["visualizer"]:
                    cover = None
                    if claim.get("reuse_of") and str(claim["reuse_of"].get("mime") or "").startswith("image/") and store is not None:
                        cover = store.fetch(claim["reuse_of"]["path"], os.path.join(tmp, "cover" + os.path.splitext(claim["reuse_of"]["path"])[1][:8]))
                    viz = media.visualizer(out["file"], platform, os.path.join(tmp, f"viz-{tag}.mp4"), kind=opts["visualizer"], cover=cover, colour=opts["highlight"])
                    finish_video(viz, platform, tag, "-viz")
            elif is_image:
                dst = os.path.join(tmp, f"final-{tag}.png")
                media.finish(out["file"], platform, dst, fit=opts["fit"], pad_colour=opts["pad_colour"], workdir=tmp)
                final_qa = qa(claim, dst, caption, platform)
                if not final_qa["passed"]:
                    raise StudioError("rendered file failed QA: " + "; ".join(final_qa["issues"]))
                register(f"{office}/jobs/{job_id}/{tag}.png", dst, "image/png", platform, f"job-{job_id[:8]}-{tag}", {"fit": opts["fit"]})
            else:
                finish_video(out["file"], platform, tag)
    except Exception as e:
        return _finish_failed(rpc, job_id, attempts, f"editing failed: {str(e)[:250]}" if not str(e).startswith("rendered file failed QA") else str(e)[:300])
    rpc("creative_stage", {"p_job": job_id, "p_stage": "qa"})
    fin = rpc("creative_finish", {"p_job": job_id, "p_passed": True, "p_caption": caption, "p_qa": {"score": verdict["score"], "provider": c["provider"], "model": c["model"],
                                                                                                "template": (tpl or {}).get("template")}})
    return {"job": job_id, "status": fin["status"], "assets": assets, "attempts": attempts, "caption": caption, "template": (tpl or {}).get("template"), "hook": hook}


def _finish_failed(rpc, job_id, attempts, reason, gate=None) -> dict:
    rpc("creative_finish", {"p_job": job_id, "p_passed": False, "p_caption": "", "p_qa": {"reason": reason[:300]}})
    out = {"job": job_id, "status": "failed", "reason": reason, "attempts": attempts}
    if gate is not None:
        out["gate"] = gate
    return out


def _reserve(office: str, c: dict, job_id: str) -> dict:
    import hq_office_money
    return hq_office_money.reserve(office, "creative_studio", "routine_expense", c["provider"], f"creative job {job_id}: {c['model']}",
                                   "content for the office's marketing", "open-source and free models are tried first", int(c["est"]))


def _settle(reservation_id: str, actual: int, receipt: str) -> None:
    import hq_capital
    hq_capital.settle(reservation_id, actual, receipt)


def _release(reservation_id: str) -> None:
    import hq_capital
    hq_capital.release(reservation_id)


# ------------------------------------------------------------------------------------------------------------------- publishing (existing hands pipeline)
def schedule_post(asset_id: str, connector: str, account_id: str, scheduled_at: str, caption: str, media_url: str, *, rpc=None, hands_submit=None) -> dict:
    """A DRAFT post on the calendar: the Jarvis hands pipeline asks the owner (or applies his standing rule) and publishes via the official API."""
    rpc = rpc or _rpc_default
    if DISCLOSURE.lower().rstrip(".") not in (caption or "").lower():
        caption = f"{caption} {DISCLOSURE}".strip()
    entry = rpc("creative_calendar_add", {"p_asset": asset_id, "p_connector": connector, "p_account": account_id, "p_scheduled_at": scheduled_at, "p_caption": caption})
    if hands_submit is None:
        import hq_hands
        hands_submit = hq_hands.submit
    r = hands_submit(connector, account_id, "post", {"text": caption, "media_url": media_url}, scheduled_at=scheduled_at, ai_generated=True, by="creative_studio")
    if not isinstance(r, dict) or not r.get("action_id"):
        return {"entry": entry["entry"], "status": "planned", "reason": (r or {}).get("reason", "hands refused")}
    rpc("creative_calendar_link", {"p_entry": entry["entry"], "p_hand_action": r["action_id"]})
    return {"entry": entry["entry"], "status": "drafted", "hand_action": r["action_id"]}


# ------------------------------------------------------------------------------------------------------------------- /creative
def report_text(rpc=None) -> str:
    try:
        r = (rpc or _rpc_default)("creative_report", {}) or {}
    except Exception as e:
        return f"Creative studio: report unavailable ({type(e).__name__})."
    m = lambda c: f"${int(c or 0) / 100:,.2f}"
    lines = [f"FENDEZY AI CREATIVE STUDIO ({'registered' if r.get('registered') else 'NOT registered: run ops/OWNER_CREATIVE_STUDIO.sql'})",
             "Queue: " + (", ".join(f"{k} {v}" for k, v in sorted((r.get("queue") or {}).items())) or "empty")]
    for c in r.get("cost") or []:
        lines.append(f"- {c['module']}: {c['jobs']} jobs, {c['approved']} approved, {m(c['cents'])}"
                     + (f", {m(c['cents_per_approved'])}/approved" if c.get("cents_per_approved") is not None else "")
                     + (f", {c['attempts_per_job']} attempts/job" if c.get("attempts_per_job") is not None else ""))
    for o in r.get("offices") or []:
        lim = "no limit" if o.get("weekly_limit_cents") is None else f"limit {m(o['weekly_limit_cents'])}/wk"
        lines.append(f"- {o['office']}: {m(o['week_cents'])} this week, {m(o['all_cents'])} total ({lim}{', premium allowed' if o.get('allow_premium') else ''})")
    on = [p["slug"] for p in r.get("providers") or [] if p.get("enabled")]
    lines.append("Providers on: " + (", ".join(on) or "none") + f". Mode: {mode()}. Prices are estimates.")
    return "\n".join(lines)


# ------------------------------------------------------------------------------------------------------------------- analytics loop (M8c)
METRICS = ("impressions", "views", "views_3s", "watch_seconds", "completion_rate", "likes", "comments", "shares", "saves", "follows", "clicks", "leads",
           "conversions", "revenue_cents")


def parse_metrics_csv(text: str) -> list[dict]:
    """A platform export (or a hand-made sheet) -> metric rows. Columns: asset or hand_action, connector, window_end, then one column per metric
    (wide) OR metric + value columns (long). Unknown columns are ignored; the database validates every row again."""
    import csv
    import io
    rows = []
    for r in csv.DictReader(io.StringIO(text or "")):
        r = {(k or "").strip().lower(): (v or "").strip() for k, v in r.items()}
        ref = {"asset": r["asset"]} if r.get("asset") else ({"hand_action": r["hand_action"]} if r.get("hand_action") else None)
        if not ref:
            continue
        base = {**ref, "connector": r.get("connector") or "manual", "window_end": r.get("window_end") or None}
        pairs = [(r["metric"], r.get("value"))] if r.get("metric") else [(m, r.get(m)) for m in METRICS if r.get(m) not in (None, "")]
        for m, v in pairs:
            try:
                rows.append({**base, "metric": m, "value": float(str(v).replace(",", ""))})
            except (TypeError, ValueError):
                continue
    return rows


def import_metrics(office: str, rows: list[dict], source: str = "manual", ref: str | None = None, rpc=None) -> dict:
    """Manual (CSV) or hands-pipeline metrics into creative_metrics_import, in chunks of 500. Returns the database's counts and rejected rows."""
    rpc = rpc or _rpc_default
    tot = {"inserted": 0, "updated": 0, "rejected": []}
    for i in range(0, len(rows), 500):
        r = rpc("creative_metrics_import", {"p_office": office, "p_rows": rows[i:i + 500], "p_source": source, "p_ref": ref}) or {}
        tot["inserted"] += int(r.get("inserted") or 0)
        tot["updated"] += int(r.get("updated") or 0)
        tot["rejected"] += [dict(x, row=int(x.get("row") or 0) + i) for x in r.get("rejected") or []]
    return tot


def hands_metrics(hand_action_id: str, connector: str, insights: dict, window_end: str | None = None) -> list[dict]:
    """A hands-pipeline result (a connector's insights dict for one published post) -> metric rows keyed by the hand action (the calendar maps it to the
    asset). Common platform names are mapped; anything else is dropped."""
    alias = {"impressions": "impressions", "reach": "impressions", "views": "views", "video_views": "views", "plays": "views", "play_count": "views",
             "views_3s": "views_3s", "three_second_views": "views_3s", "avg_watch_time": "watch_seconds", "total_watch_time": "watch_seconds",
             "completion_rate": "completion_rate", "likes": "likes", "like_count": "likes", "comments": "comments", "comment_count": "comments",
             "shares": "shares", "share_count": "shares", "saves": "saves", "saved": "saves", "follows": "follows", "clicks": "clicks",
             "link_clicks": "clicks", "leads": "leads", "conversions": "conversions", "revenue_cents": "revenue_cents"}
    out = {}
    for k, v in (insights or {}).items():
        m = alias.get(str(k).lower())
        if m and isinstance(v, (int, float)) and not isinstance(v, bool):
            out[m] = float(v)
    return [{"hand_action": hand_action_id, "connector": connector, "metric": m, "value": v, "window_end": window_end} for m, v in out.items()]


def rank_text(office: str, module: str | None = None, rpc=None) -> str:
    """What works for an office (owner / Jarvis): top templates and hooks by recorded performance."""
    try:
        r = (rpc or _rpc_default)("creative_rank", {"p_office": office, "p_module": module}) or {}
    except Exception as e:
        return f"Creative ranking unavailable ({type(e).__name__})."
    t = ", ".join(f"{x['template']} {x['rank_score']} ({x['posts']} posts)" for x in (r.get("templates") or [])[:3]) or "no data yet"
    h = ", ".join(f"{x['hook']} {x['rank_score']}" for x in (r.get("hooks") or [])[:3]) or "no data yet"
    return f"{office}{' ' + module if module else ''}: best templates {t}; best hooks {h}."
