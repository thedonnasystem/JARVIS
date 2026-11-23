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
    "veo-3.1": "hero", "veo-3.1-fast": "hero", "kling-3.0": "hero", "gen-4": "hero", "gen-4-turbo": "hero", "multilingual-v2": "hero",
}
MODEL_MODULES = {
    "flux.1-schnell": {"image"}, "sdxl-1.0": {"image"}, "flux.1-dev": {"image"}, "flux.1-dev-lora": {"image"},
    "wan-2.2-ti2v-5b": {"video", "ugc"}, "wan-2.2": {"video", "ugc"}, "wan-2.2-t2v-a14b": {"video", "ugc"}, "ltx-2": {"video", "ugc"},
    "hunyuanvideo-1.5": {"video"}, "kokoro-tts": {"voice"}, "ace-step": {"music"}, "musicgen": {"music"}, "flux-lora-trainer": {"train"},
    "veo-3.1": {"video", "ugc"}, "veo-3.1-fast": {"video", "ugc"}, "kling-3.0": {"video", "ugc"}, "gen-4": {"video", "ugc"}, "gen-4-turbo": {"video", "ugc"},
    "multilingual-v2": {"voice"}, "hq_llm": {"copy"}, "sandbox-testsrc": {"video", "image", "ugc", "voice", "music"},
}
# ESTIMATED GPU-seconds per unit of output on a 48GB-class GPU (per image, or per second of video / audio). Real numbers replace these after M8b runs.
GPU_SECONDS = {"flux.1-schnell": 4, "sdxl-1.0": 6, "flux.1-dev": 20, "flux.1-dev-lora": 22, "wan-2.2-ti2v-5b": 25, "wan-2.2-t2v-a14b": 90,
               "ltx-2": 12, "hunyuanvideo-1.5": 80, "kokoro-tts": 1, "ace-step": 2, "flux-lora-trainer": 1800}
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
    """Hosted open-weight models through a per-call API (fal.ai queue API, Replicate predictions API): the v1 generation path, no GPU infrastructure.
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
        h = {"Authorization": f"Bearer {key}", "Content-Type": "application/json", "Prefer": "wait=60"}
        st, r, _ = self.http("POST", f"https://api.replicate.com/v1/models/{ep}/predictions", headers=h, json_body={"input": body})
        if st not in (200, 201, 202) or not isinstance(r, dict):
            raise StudioError(f"replicate submit refused ({st})")
        while r.get("status") not in ("succeeded", "failed", "canceled"):
            if time.monotonic() > t_end:
                raise StudioError("replicate prediction timed out")
            self.sleep(self.poll_s)
            st, r, _ = self.http("GET", (r.get("urls") or {}).get("get") or "", headers=h)
            if st >= 400 or not isinstance(r, dict):
                raise StudioError(f"replicate poll refused ({st})")
        if r["status"] != "succeeded":
            raise StudioError(f"replicate prediction {r['status']}")
        o = r.get("output")
        o = o[0] if isinstance(o, list) and o else o
        if not isinstance(o, str):
            raise StudioError("replicate result has no file")
        return o

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


def adapters_for(providers: list[dict], env: dict, extra: dict | None = None) -> dict:
    out = {}
    for p in providers:
        a = (extra or {}).get(p["slug"])
        if a is None:
            if p["slug"] == "sandbox":
                a = SandboxAdapter()
            elif p["slug"] in ("fal-hosted", "replicate-hosted"):
                a = HostedAdapter(p["slug"], p.get("env_key") or "", env)
            else:
                a = LiveAdapter(p["slug"], p.get("env_key") or "")
        if a.available(env) and (p["slug"] == "sandbox" or mode(env) == "live"):
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
    if claim["module"] in ("image", "video", "ugc") and not (info["width"] and info["height"]):
        return {"passed": False, "score": 0.0, "issues": ["no picture in the file"]}
    if platform and claim["module"] in ("image", "video", "ugc"):
        if (info["width"], info["height"]) != PLATFORMS[platform]:
            issues.append(f"frame {info['width']}x{info['height']} is not {platform}")
    if claim["module"] in ("video", "ugc") and info["duration"] <= 0:
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
def _plan(claim: dict, llm, facts: list[dict]) -> dict:
    """Research -> strategy -> script -> direction. Templates by default; with llm (hq_llm.complete-shaped) ONE call writes the script."""
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
    return plan


def run_job(job_id: str, *, rpc=None, store=None, env: dict | None = None, llm=None, money=None, settle=None, release=None, brain=None,
            extra_adapters: dict | None = None, workdir: str | None = None, clock=time.monotonic) -> dict:
    """One job end to end, up to QA and 'awaiting_approval'. Returns a summary. Every failure ends the open attempt (no dangling reservations)."""
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
    plan = _plan(claim, llm, facts)
    for st in ("research", "strategy", "script", "direction"):
        rpc("creative_stage", {"p_job": job_id, "p_stage": st, "p_plan": {st: plan[st]}})
    caption = f"{plan['script'][:300]} {DISCLOSURE}".strip()
    spec = {"prompt": plan["script"], "seconds": int(env.get("CREATIVE_VIDEO_SECONDS") or 5) if module in ("video", "ugc") else None, "count": 1,
            "aspect": (claim.get("platforms") or ["9:16"])[0]}
    if claim.get("reuse_of") and store is not None:
        try:
            spec["reference_url"] = store.url(claim["reuse_of"]["path"])      # the approved asset this job builds on
        except Exception:
            pass
    if claim.get("character") and claim["character"].get("lora") and store is not None:
        spec["lora_url"] = store.url(claim["character"]["lora"])
        spec["prompt"] = f"{claim['character']['trigger_word']} {spec['prompt']}"
    adapters = adapters_for(claim.get("providers") or [], env, extra_adapters)
    attempts: list[dict] = []
    max_n = min(int(claim.get("max_attempts") or 3), MAX_ATTEMPTS_HARD)
    tmp = workdir or tempfile.mkdtemp(prefix="creative-")
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
    assets = []
    for platform in claim.get("platforms") or ["9:16"]:
        ext = ".png" if out["mime"].startswith("image/") else (".mp4" if out["mime"].startswith("video/") else ".m4a")
        tag = platform.replace(":", "x")
        dst = os.path.join(tmp, f"final-{tag}{ext}")
        try:
            if ext == ".m4a":
                shutil.copyfile(out["file"], dst)
            else:
                render(out["file"], platform, dst, captions=srt(plan["script"], probe(out["file"])["duration"] or 3) if ext == ".mp4" else None)
        except Exception as e:
            return _finish_failed(rpc, job_id, attempts, f"editing failed: {str(e)[:200]}")
        final_qa = qa(claim, dst, caption, platform if ext != ".m4a" else None)
        if not final_qa["passed"]:
            return _finish_failed(rpc, job_id, attempts, "rendered file failed QA: " + "; ".join(final_qa["issues"]))
        path = f"{office}/jobs/{job_id}/{tag}{ext}"
        (store or LocalStore(os.path.join(tmp, "bucket"))).put(path, dst, out["mime"])
        with open(dst, "rb") as f:
            data = f.read()
        a = rpc("creative_asset_add", {"p_office": office, "p_job": job_id, "p_kind": "generated", "p_name": f"job-{job_id[:8]}-{tag}", "p_path": path,
                                       "p_mime": out["mime"], "p_bytes": len(data), "p_sha256": hashlib.sha256(data).hexdigest(), "p_platform": platform if ext != ".m4a" else None,
                                       "p_meta": {"ai_generated": True, "provider": c["provider"], "model": c["model"], "disclosure": DISCLOSURE}})
        assets.append({"asset": a["asset"], "path": path, "platform": platform})
    rpc("creative_stage", {"p_job": job_id, "p_stage": "qa"})
    fin = rpc("creative_finish", {"p_job": job_id, "p_passed": True, "p_caption": caption, "p_qa": {"score": verdict["score"], "provider": c["provider"], "model": c["model"]}})
    return {"job": job_id, "status": fin["status"], "assets": assets, "attempts": attempts, "caption": caption}


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
