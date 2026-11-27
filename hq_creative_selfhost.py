"""FENDEZY AI CREATIVE STUDIO: the self-hosted generation backend (provider row 'comfyui-selfhost'). Design, models, licences and the cost table are in
docs/architecture/CREATIVE_SELFHOST.md; the GPU worker kits are in creative_studio/selfhost/worker/.

What it is:
- SelfhostAdapter talks to OUR ComfyUI worker (a Kaggle free GPU, an owned card, or an owner-rented pod) through the ComfyUI HTTP API (/prompt, /history,
  /view, /upload/image, /object_info) behind the worker's bearer-token proxy, plus the worker's /fz/tts route (Kokoro-82M). Endpoint and token come from the
  environment only (COMFYUI_SELFHOST_URL, COMFYUI_SELFHOST_TOKEN) and are never logged. All HTTP goes through hq_hands_adapters.http (https only, no
  redirects), the same audited outbound path fal.ai uses; no provider pattern of the protected test_no_bypass is involved.
- Money: every call is 0 cents to the studio, so the router never reserves for it (run_job reserves only when the estimate is above 0). When the selfhost
  row is enabled and configured it wins on price automatically, and fal.ai is dropped from the router unless CREATIVE_FAL_FALLBACK=1 (opt-in fallback).
  The existing fal.ai caps are untouched. A RENTED pod is paid per hour outside the studio: the owner starts it, and the worker stops itself (idle / max hours).
- Content rules (every provider, every job): no minors, no sexual content, no impersonation, no real-person likeness without a recorded consent. A persona
  pack (fictional adult, AI-generated flag mandatory) keeps one AI model consistent across posts: appearance prompt + trigger word + LoRA + reference images.
- BatchQueue: jobs wait until a worker is up, then run grouped by module (weights stay loaded), and stop cleanly when the worker goes away.
"""
from __future__ import annotations

import hashlib
import json
import os
import re
import tempfile
import time
import urllib.parse
import uuid

SLUG = "comfyui-selfhost"
DISCLOSURE = "AI-generated content."
HERE = os.path.dirname(os.path.abspath(__file__))
SELFHOST_DIR = os.path.join(HERE, "creative_studio", "selfhost")
MANIFEST_FILE = os.path.join(SELFHOST_DIR, "manifest.json")
WORKFLOW_DIR = os.path.join(SELFHOST_DIR, "workflows")
PERSONA_DIR = os.path.join(SELFHOST_DIR, "personas")
MAX_DOWNLOAD = 300 * 1024 * 1024
MIN_TOKEN = 24
MIN_PERSONA_AGE = 21                      # apparent age floor for AI personas (a margin above 18)
URL_RX = re.compile(r"https://[A-Za-z0-9.-]+(:\d{2,5})?(/[A-Za-z0-9._~/-]*)?")
IMAGE_SIZE = {"9:16": (720, 1280), "1:1": (1024, 1024), "16:9": (1280, 720)}
VIDEO_SIZE = {"9:16": (704, 1280), "1:1": (960, 960), "16:9": (1280, 704)}          # 720p class (24 GB and up)
VIDEO_SIZE_SMALL = {"9:16": (480, 832), "1:1": (640, 640), "16:9": (832, 480)}      # 16 GB cards (T4): 480p class, ESTIMATED to keep a clip under ~15 min
UGC_SIZE = {"9:16": (480, 832), "1:1": (640, 640), "16:9": (832, 480)}


class SelfhostError(Exception):
    pass


# ------------------------------------------------------------------------------------------------------------------- content rules (all providers)
MINORS = re.compile(
    r"\b(child|children|kids?|kiddie|toddlers?|infants?|preteens?|pre-teens?|teens?|teenagers?|teenaged?|tweens?|underage|under-age|juvenile|"
    r"school ?girls?|school ?boys?|school uniform|high[- ]school(er)?s?|middle[- ]school(er)?s?|junior high|elementary school|grade school|"
    r"little (girl|boy)s?|young (girl|boy)s?|lolita|loli|shota|jailbait|barely legal|"
    r"(1[0-7]|[1-9])[- ]?(yo|y/o|yrs?[- ]old|years?[- ]old|year-olds?))\b", re.I)
MINOR_WORD = re.compile(r"(?<![A-G] )(?<![A-G]# )(?<![A-G]b )\b[Mm][Ii][Nn][Oo][Rr][Ss]?\b(?!\s+(key|chord|scale|third|sixth|seventh|mode|progression))")   # "C minor" is music
SEXUAL = re.compile(
    r"\b(nude|nudes|nudity|naked|nsfw|porn\w*|sex|sexual\w*|sexy|erotic\w*|xxx|topless|bottomless|lingerie|boudoir|fetish\w*|onlyfans|fansly|"
    r"strip(per|pers|tease|club)|seductive\w*|sensual\w*|orgasm\w*|genital\w*|nipples?|cleavage|bdsm|hentai|camgirls?|cam model|escort\w*|"
    r"undress\w*|see-through|lewd|horny|thirst trap|spicy content)\b", re.I)
IMPERSONATION = re.compile(
    r"\b(impersonat\w*|pretend(s|ing)? to be|pos(e|es|ing) as|look-?alikes?|doppelg[aä]ngers?|face ?swap\w*|deep ?fakes?|celebrit(y|ies)|celebs?|"
    r"famous (person|people|singer|actor|actress|rapper|athlete|influencer|model)|real (person|human|celebrity)|official account of|"
    r"(i am|i'm) (a )?real( person| human)?|not (an )?ai\b|not ai-generated|100% real)\b", re.I)
SAFETY_NEGATIVE = "nsfw, nudity, sexual content, child, minor, teenager, school uniform, celebrity likeness"


def content_problems(text: str) -> list[str]:
    """The hard content rules, as refusal reasons (empty list = allowed). Applied to the brief, the prompt and every persona field on every provider."""
    t = text or ""
    out = []
    if MINORS.search(t) or MINOR_WORD.search(t):
        out.append("no content involving minors (people must be adults; persona apparent age 21+)")
    if SEXUAL.search(t):
        out.append("no sexual or sexually suggestive content")
    if IMPERSONATION.search(t):
        out.append("no impersonation or real-person likeness (and AI personas never claim to be real people)")
    return out


def content_refusal(text: str) -> str | None:
    p = content_problems(text)
    return ("refused: " + "; ".join(p)) if p else None


# ------------------------------------------------------------------------------------------------------------------- persona packs
PERSONA_KEYS = {"_about", "slug", "office", "display_name", "fictional", "real_person", "consent_id", "adult_age", "ai_generated", "disclosure", "appearance",
                "negative", "trigger_word", "lora", "references", "voice", "content_rating", "blocked_names"}
REF_SOURCES = ("generated", "consented_photo")


def _slug(name: str) -> str:
    return re.sub(r"[^a-z0-9]+", "-", (name or "").lower()).strip("-")[:40]


def persona_problems(p: dict, office: str | None = None) -> list[str]:
    """Every rule a persona pack must meet before ANY generation uses it. Empty list = ok."""
    if not isinstance(p, dict):
        return ["persona pack is not an object"]
    out = []
    unknown = set(p) - PERSONA_KEYS
    if unknown:
        out.append(f"unknown keys {sorted(unknown)}")
    if not re.fullmatch(r"[a-z][a-z0-9-]{1,39}", str(p.get("slug") or "")):
        out.append("slug must be lowercase letters, digits and dashes")
    if office and p.get("office") != office:
        out.append(f"pack belongs to office {p.get('office')!r}, not {office!r}")
    if p.get("ai_generated") is not True:
        out.append("ai_generated must be true (mandatory AI-generated disclosure flag)")
    if DISCLOSURE.lower().rstrip(".") not in str(p.get("disclosure") or "").lower():
        out.append(f"disclosure must contain '{DISCLOSURE}'")
    real = p.get("real_person")
    if real is True:
        if not p.get("consent_id"):
            out.append("a real person's likeness needs a recorded consent (creative_owner_record_consent) in consent_id")
        if p.get("fictional") is True:
            out.append("a pack cannot be both fictional and a real person")
    elif real is False:
        if p.get("fictional") is not True:
            out.append("a non-real persona must say fictional: true")
    else:
        out.append("real_person must be true or false")
    age = p.get("adult_age")
    if not isinstance(age, int) or isinstance(age, bool) or age < MIN_PERSONA_AGE or age > 120:
        out.append(f"adult_age must be an integer of at least {MIN_PERSONA_AGE} (adults only)")
    if p.get("content_rating") != "sfw":
        out.append("content_rating must be 'sfw'")
    if not str(p.get("appearance") or "").strip():
        out.append("appearance (the consistent look, as a prompt fragment) is required")
    tw = str(p.get("trigger_word") or "")
    if tw and not re.fullmatch(r"[a-z0-9]{3,24}", tw):
        out.append("trigger_word must be 3-24 lowercase letters or digits")
    lora = p.get("lora")
    if lora is not None and not (isinstance(lora, dict) and re.fullmatch(r"[A-Za-z0-9._-]{1,120}\.safetensors", str(lora.get("file") or ""))
                                 and 0 < float(lora.get("strength") or 1.0) <= 1.5):
        out.append("lora must be {file: <name>.safetensors, strength: 0-1.5}")
    for r in p.get("references") or []:
        if not isinstance(r, dict) or r.get("source") not in REF_SOURCES:
            out.append(f"every reference needs source in {REF_SOURCES}")
            break
        if r.get("source") == "consented_photo" and not (real is True and p.get("consent_id")):
            out.append("a photo reference is a real person's likeness: it needs real_person true and a consent_id")
            break
        path = str(r.get("path") or "")
        if not re.fullmatch(r"[a-z][a-z0-9-]{1,39}/(personas|jobs)/[A-Za-z0-9._/-]+\.(png|jpg|jpeg|webp)", path) or ".." in path or \
                (p.get("office") and not path.startswith(f"{p.get('office')}/")):
            out.append(f"reference path {path!r} must be an image in the office's own personas/ or jobs/ folder")
            break
    v = p.get("voice")
    if v is not None and not (isinstance(v, dict) and v.get("engine") == "kokoro-82m" and re.fullmatch(r"[a-z]{2}_[a-z]{2,20}", str(v.get("voice") or ""))):
        out.append("voice must be {engine: kokoro-82m, voice: <stock voice id>} (stock voices only: no voice cloning)")
    text = " ".join(str(p.get(k) or "") for k in ("display_name", "appearance"))        # the negative prompt may name what to avoid, so it is not scanned
    out += [f"persona text: {x}" for x in content_problems(text)]
    for name in p.get("blocked_names") or []:
        if name and str(name).lower() in text.lower():
            out.append(f"persona text names a blocked real person ({name})")
    return out


def load_persona_file(path: str) -> dict:
    with open(path) as f:
        return json.load(f)


def persona_for(claim: dict, store=None, local_dir: str | None = None, tmpdir: str | None = None) -> dict | None:
    """The persona pack of the job's character, checked. Looks in the private bucket (<office>/personas/<slug>/persona.json) and, when local_dir is given
    (tests, the worker's batch mode), in <local_dir>/<slug>.json. No character -> None. A character without a pack -> None (the LoRA path still works).
    A pack that breaks a rule -> SelfhostError, and the job is refused before any generation."""
    ch = claim.get("character") or None
    if not ch:
        return None
    office = claim.get("office")
    slug = _slug(ch.get("slug") or ch.get("name") or "")
    if not slug:
        return None
    pack = None
    if store is not None and hasattr(store, "fetch"):
        dst = os.path.join(tmpdir or tempfile.mkdtemp(prefix="persona-"), "persona.json")
        try:
            pack = load_persona_file(store.fetch(f"{office}/personas/{slug}/persona.json", dst))
        except Exception:
            pack = None
    if pack is None and local_dir:
        path = os.path.join(local_dir, slug + ".json")
        if os.path.isfile(path):
            pack = load_persona_file(path)
    if pack is None:
        return None
    problems = persona_problems(pack, office)
    if ch.get("trigger_word") and pack.get("trigger_word") and ch["trigger_word"] != pack["trigger_word"]:
        problems.append("trigger_word differs from the registered character's")
    if problems:
        raise SelfhostError("persona refused: " + "; ".join(problems))
    return pack


def persona_prompt(persona: dict | None, prompt: str) -> str:
    """Prepend the pack's fixed look (and trigger word) so every post shows the same AI model."""
    if not persona:
        return prompt or ""
    look = str(persona.get("appearance") or "").strip()
    tw = str(persona.get("trigger_word") or "").strip()
    head = look if (not tw or tw in look) else f"{tw} {look}"
    body = (prompt or "").replace(tw, "").strip() if tw else (prompt or "")
    return f"{head}, {body}".strip(", ")


# ------------------------------------------------------------------------------------------------------------------- manifest / workflows
def configured(env: dict) -> bool:
    """COMFYUI_SELFHOST_URL is an https URL and COMFYUI_SELFHOST_TOKEN is long enough (the worker prints both)."""
    return bool(URL_RX.fullmatch((env.get("COMFYUI_SELFHOST_URL") or "").rstrip("/"))) and len(env.get("COMFYUI_SELFHOST_TOKEN") or "") >= MIN_TOKEN


def load_manifest() -> dict:
    with open(MANIFEST_FILE) as f:
        return json.load(f)


def workflows(env: dict | None = None) -> dict:
    """wid -> entry with an absolute 'path'. Ours plus the shared M8c workflows listed in manifest.shared (licence-gated ones only when the owner set the gate)."""
    env = env if env is not None else os.environ
    m = load_manifest()
    out = {wid: dict(w, path=os.path.join(WORKFLOW_DIR, w["file"])) for wid, w in m["workflows"].items()}
    try:
        import hq_creative_presets
        shared = hq_creative_presets.load_manifest()["workflows"]
        comfy_dir = hq_creative_presets.COMFY_DIR
    except Exception:
        shared, comfy_dir = {}, ""
    for wid, extra in m.get("shared", {}).items():
        if wid.startswith("_") or wid not in shared:
            continue
        gate = extra.get("licence_gate")
        if gate and env.get(gate) != "1":
            continue
        out[wid] = dict(shared[wid], min_vram_gb=extra.get("min_vram_gb", 24), path=os.path.join(comfy_dir, shared[wid]["file"]))
    return out


def services() -> dict:
    return {k: v for k, v in load_manifest().get("services", {}).items() if not k.startswith("_")}


def models() -> list[str]:
    """Every model the selfhost row can route (the migration's provider row lists the same set)."""
    return sorted({w["model"] for w in workflows({}).values()} | set(services()))


def video_frames(seconds: int, fps: int, model: str) -> int:
    n = max(1, int(seconds)) * int(fps)
    step = 8 if model.startswith("ltx") else 4
    return (n // step) * step + 1


def fill(path: str, params: dict) -> dict:
    """Load an API-format graph and fill its typed {{placeholders}} (the M8c filler; it refuses gaps)."""
    import hq_creative_presets
    with open(path) as f:
        graph = json.load(f)
    return hq_creative_presets.fill_workflow(graph, params)


# ------------------------------------------------------------------------------------------------------------------- adapter
class SelfhostAdapter:
    """The 'comfyui-selfhost' provider. 0 cents per call. Live mode only (CREATIVE_STUDIO_MODE=live), and only while the worker answers its health check.
    local=True is for the worker's own batch mode (http://127.0.0.1, its own http function); Jarvis never uses it."""
    slug = SLUG
    unit_cost_cents = 0

    def __init__(self, env: dict, http=None, sleep=time.sleep, clock=time.monotonic, deadline_s: int = 2400, poll_s: float = 3.0, health_ttl_s: int = 60,
                 local: bool = False):
        self.env = env
        self.base = (env.get("COMFYUI_SELFHOST_URL") or "").rstrip("/")
        self.token = env.get("COMFYUI_SELFHOST_TOKEN") or ""
        self.local = local
        self.flows = workflows(env)
        self.svc = services()
        self.by_model = {}
        for wid in sorted(self.flows):
            self.by_model.setdefault(self.flows[wid]["model"], wid)
        self._http, self.sleep, self.clock = http, sleep, clock
        self.deadline_s, self.poll_s, self.health_ttl_s = deadline_s, poll_s, health_ttl_s
        self._health_at, self._health = None, None
        self._object_info = None

    # -- plumbing
    def http(self, *a, **k):
        if self._http:
            return self._http(*a, **k)
        import hq_hands_adapters
        return hq_hands_adapters.http(*a, **k)

    def _auth(self, extra: dict | None = None) -> dict:
        return {"Authorization": f"Bearer {self.token}", **(extra or {})}

    def is_configured(self) -> bool:
        if self.local:
            return bool(re.fullmatch(r"http://127\.0\.0\.1:\d{2,5}", self.base))
        return configured(self.env)

    def health(self, force: bool = False) -> dict | None:
        """GET /system_stats through the worker's proxy, cached health_ttl_s. -> {'vram_gb', 'device', 'comfyui'} or None when the worker is down."""
        now = self.clock()
        if not force and self._health_at is not None and now - self._health_at < self.health_ttl_s:
            return self._health
        h = None
        if self.is_configured():
            try:
                st, body, _ = self.http("GET", f"{self.base}/system_stats", headers=self._auth(), timeout=10)
                if st == 200 and isinstance(body, dict):
                    dev = (body.get("devices") or [{}])[0] or {}
                    vram = dev.get("vram_total")
                    h = {"vram_gb": round(float(vram) / 2 ** 30, 1) if vram else None, "device": str(dev.get("name") or "")[:80],
                         "comfyui": str((body.get("system") or {}).get("comfyui_version") or "")[:40]}
            except Exception:
                h = None
        self._health_at, self._health = now, h
        return h

    def available(self, env: dict) -> bool:
        live = self.local or (env.get("CREATIVE_STUDIO_MODE") == "live")
        return live and self.is_configured() and self.health() is not None

    def supports(self, model: str) -> bool:
        if model in self.svc:
            return True
        wid = self.by_model.get(model)
        if not wid:
            return False
        vram = (self._health or {}).get("vram_gb")
        return vram is None or vram + 0.5 >= float(self.flows[wid].get("min_vram_gb") or 24)

    def fits(self, model: str, module: str, spec: dict) -> bool:
        """Job-level fit: a LoRA workflow only with the persona's LoRA (and then ONLY the LoRA workflow, for a consistent face); a talking head only with
        a reference image."""
        persona = spec.get("persona") or {}
        has_lora = bool((persona.get("lora") or {}).get("file") or spec.get("lora_name"))
        wid = self.by_model.get(model)
        if wid and self.flows[wid]["output"] == "image":
            return has_lora == ("lora_name" in self.flows[wid]["params"])
        if wid and "ref_image" in (self.flows[wid].get("uploads") or {}):
            return bool((persona.get("references") and callable(spec.get("resolve_url"))) or spec.get("reference_url"))
        return True

    PREFERENCE = {"z-image-turbo": 0, "z-image-turbo-lora": 0, "flux.1-schnell": 1, "flux.1-schnell-lora": 1, "wan-2.2-s2v-14b": 0, "wan-2.2-ti2v-5b": 1,
                  "wan-2.2-t2v-a14b": 2, "ltx-video": 3, "kokoro-82m": 0}

    def preference(self, model: str) -> int:
        """Quality per GPU-minute order at equal (zero) price; the next ones are the QA-failure escalation."""
        return self.PREFERENCE.get(model, 5)

    def cost_cents(self, model: str, spec: dict) -> int:
        return 0

    # -- ComfyUI calls
    def _get(self, path: str, timeout: int = 60):
        return self.http("GET", f"{self.base}{path}", headers=self._auth(), timeout=timeout)

    def preflight(self, graph: dict) -> None:
        """Every node class and input name must exist on this worker (GET /object_info, cached): a wrong graph fails here, before any GPU time."""
        if self._object_info is None:
            st, info, _ = self._get("/object_info", timeout=60)
            if st != 200 or not isinstance(info, dict):
                raise SelfhostError(f"worker object_info refused ({st})")
            self._object_info = info
        for nid, node in graph.items():
            cls = self._object_info.get(node.get("class_type"))
            if not isinstance(cls, dict):
                raise SelfhostError(f"worker lacks node {node.get('class_type')} (node {nid}): update ComfyUI on the worker")
            spec = cls.get("input") or {}
            names = set((spec.get("required") or {})) | set((spec.get("optional") or {})) | set((spec.get("hidden") or {}))
            bad = set(node.get("inputs") or {}) - names
            if names and bad:
                raise SelfhostError(f"node {node.get('class_type')} (node {nid}) has no input(s) {sorted(bad)} on this worker")

    def upload(self, data: bytes, filename: str, mime: str) -> str:
        """POST /upload/image (ComfyUI's input-folder upload, used for images and audio alike) -> the stored file name."""
        boundary = "----fz" + uuid.uuid4().hex
        safe = re.sub(r"[^A-Za-z0-9._-]", "_", filename)[:80] or "input.bin"
        body = (f"--{boundary}\r\nContent-Disposition: form-data; name=\"overwrite\"\r\n\r\ntrue\r\n"
                f"--{boundary}\r\nContent-Disposition: form-data; name=\"image\"; filename=\"{safe}\"\r\nContent-Type: {mime}\r\n\r\n").encode() + data + \
               f"\r\n--{boundary}--\r\n".encode()
        st, r, _ = self.http("POST", f"{self.base}/upload/image", headers=self._auth({"Content-Type": f"multipart/form-data; boundary={boundary}"}), data=body,
                             timeout=120)
        if st != 200 or not isinstance(r, dict) or not r.get("name"):
            raise SelfhostError(f"worker upload refused ({st})")
        return (r.get("subfolder") + "/" if r.get("subfolder") else "") + r["name"]

    def run_graph(self, graph: dict) -> tuple[dict, int]:
        """Submit, poll /history until done, -> (outputs, wall ms). A worker error or the deadline ends it with SelfhostError."""
        self.preflight(graph)
        t0 = self.clock()
        st, r, _ = self.http("POST", f"{self.base}/prompt", headers=self._auth(), json_body={"prompt": graph, "client_id": "fendezy-" + uuid.uuid4().hex[:12]},
                             timeout=60)
        if st != 200 or not isinstance(r, dict) or not re.fullmatch(r"[A-Za-z0-9-]{8,80}", str(r.get("prompt_id") or "")) or r.get("node_errors"):
            raise SelfhostError(f"worker refused the workflow ({st}{': node errors' if isinstance(r, dict) and r.get('node_errors') else ''})")
        pid = r["prompt_id"]
        while True:
            st, h, _ = self._get(f"/history/{pid}")
            entry = h.get(pid) if isinstance(h, dict) else None
            if isinstance(entry, dict):
                status = entry.get("status") or {}
                if status.get("status_str") == "error":
                    msg = ""
                    for m in status.get("messages") or []:
                        if isinstance(m, list) and len(m) == 2 and m[0] == "execution_error" and isinstance(m[1], dict):
                            msg = str(m[1].get("exception_message") or "")[:160]
                    raise SelfhostError(f"worker job failed: {msg}".strip())
                if status.get("completed") or entry.get("outputs"):
                    return entry.get("outputs") or {}, int((self.clock() - t0) * 1000)
            elif st >= 400:
                raise SelfhostError(f"worker history refused ({st})")
            if self.clock() - t0 > self.deadline_s:
                raise SelfhostError("worker job timed out")
            self.sleep(self.poll_s)

    def fetch_output(self, outputs: dict, kind: str, workdir: str) -> tuple[str, str]:
        exts = {"image": (".png", ".jpg", ".jpeg", ".webp"), "video": (".mp4", ".webm", ".mov")}[kind]
        files = []
        for node in outputs.values():
            for v in (node or {}).values():
                if isinstance(v, list):
                    files += [x for x in v if isinstance(x, dict) and str(x.get("filename") or "").lower().endswith(exts) and x.get("type", "output") == "output"]
        if not files:
            raise SelfhostError(f"worker result has no {kind} file")
        f0 = files[0]
        q = urllib.parse.urlencode({"filename": f0["filename"], "subfolder": f0.get("subfolder") or "", "type": "output"})
        st, data, _ = self._get(f"/view?{q}", timeout=300)
        if st != 200 or not isinstance(data, (bytes, bytearray)) or not data or len(data) > MAX_DOWNLOAD:
            raise SelfhostError(f"worker download refused ({st})")
        ext = os.path.splitext(f0["filename"])[1].lower().replace(".jpeg", ".jpg")
        mime = {".png": "image/png", ".jpg": "image/jpeg", ".webp": "image/webp", ".mp4": "video/mp4", ".webm": "video/webm", ".mov": "video/quicktime"}[ext]
        out = os.path.join(workdir, "raw" + ext)
        with open(out, "wb") as f:
            f.write(data)
        return out, mime

    def tts(self, text: str, voice: str, workdir: str) -> str:
        """Kokoro-82M on the worker (/fz/tts) -> a WAV file."""
        st, data, _ = self.http("POST", f"{self.base}/fz/tts", headers=self._auth(), json_body={"text": text[:3000], "voice": voice}, timeout=300)
        if st != 200 or not isinstance(data, (bytes, bytearray)) or len(data) < 64 or data[:4] != b"RIFF":
            raise SelfhostError(f"worker tts refused ({st})")
        out = os.path.join(workdir, "voice.wav")
        with open(out, "wb") as f:
            f.write(data)
        return out

    # -- generation
    def generate(self, module: str, model: str, spec: dict, workdir: str) -> dict:
        persona = spec.get("persona")
        if persona:
            p = persona_problems(persona)
            if p:
                raise SelfhostError("persona refused: " + "; ".join(p))
        prompt = persona_prompt(persona, spec.get("prompt") or "")
        script = spec.get("script") or spec.get("prompt") or ""
        refusal = content_refusal(" ".join([prompt, script]))
        if refusal:
            raise SelfhostError(refusal)
        meta = {"ai_generated": True, "disclosure": DISCLOSURE, "selfhost": True, "worker": (self._health or {}).get("device") or None}
        if persona:
            meta.update({"persona": persona["slug"], "persona_fictional": bool(persona.get("fictional")), "persona_real_person": bool(persona.get("real_person"))})
        voice = ((persona or {}).get("voice") or {}).get("voice") or spec.get("voice") or "af_heart"
        if model in self.svc:                                                            # voice (Kokoro) -> m4a
            if module != "voice":
                raise SelfhostError(f"{model} only makes voice")
            t0 = self.clock()
            wav = self.tts(script, voice, workdir)
            import hq_creative_media as media
            out = os.path.join(workdir, "raw.m4a")
            media.ff(["-i", wav, "-c:a", "aac", "-b:a", "160k", out])
            return {"file": out, "mime": "audio/mp4", "actual_cents": 0, "gpu_ms": int((self.clock() - t0) * 1000), "meta": dict(meta, voice=voice)}
        wid = spec.get("workflow") if spec.get("workflow") in self.flows and self.flows[spec["workflow"]]["model"] == model else self.by_model.get(model)
        if not wid or not self.supports(model):
            raise SelfhostError(f"{self.slug} cannot run {model} on this worker")
        w = self.flows[wid]
        aspect = spec.get("aspect") or "9:16"
        vram = (self._health or {}).get("vram_gb") or 24
        if w["output"] == "image":
            size = IMAGE_SIZE[aspect]
        elif w.get("module") == "ugc":
            size = UGC_SIZE[aspect]
        else:
            size = (VIDEO_SIZE if vram >= 20 else VIDEO_SIZE_SMALL)[aspect]
        seed = int(hashlib.sha256(f"{(persona or {}).get('slug', '')}|{prompt}".encode()).hexdigest()[:8], 16)
        params = {"prompt": prompt[:2000], "width": size[0], "height": size[1], "seed": seed}
        if "negative" in w["params"]:
            params["negative"] = ", ".join(x for x in (spec.get("negative") or w.get("negative_default") or "", (persona or {}).get("negative") or "",
                                                       SAFETY_NEGATIVE) if x)
        if w["output"] == "video":
            fps = int(w.get("fps") or spec.get("fps") or (16 if "a14b" in model else 24))
            frames = video_frames(int(spec.get("seconds") or 5), fps, model)
            if w.get("max_frames"):
                frames = min(frames, int(w["max_frames"]))
            params.update({"fps": fps, "frames": frames})
        if "lora_name" in w["params"]:
            lora = (persona or {}).get("lora") or {}
            name = lora.get("file") or spec.get("lora_name")
            if not name:
                raise SelfhostError("this workflow needs the persona's LoRA on the worker (models/loras)")
            params.update({"lora_name": name, "lora_strength": float(lora.get("strength") or spec.get("lora_strength") or 1.0)})
        t0 = self.clock()
        for name, kind in (w.get("uploads") or {}).items():
            if kind == "image":
                params[name] = self.upload(self._reference(spec, persona, workdir), "ref.png", "image/png")
            elif kind == "audio":
                params[name] = self.upload(self._voice_track(spec, script, voice, workdir), "voice.wav", "audio/wav")
        graph = fill(w["path"], params)
        outputs, ms = self.run_graph(graph)
        path, mime = self.fetch_output(outputs, w["output"], workdir)
        return {"file": path, "mime": mime, "actual_cents": 0, "gpu_ms": int((self.clock() - t0) * 1000), "queue_and_run_ms": ms,
                "meta": dict(meta, workflow=wid, seed=seed)}

    def _reference(self, spec: dict, persona: dict | None, workdir: str) -> bytes:
        """The talking-head reference: the persona's first reference image (signed URL from the private bucket) or the job's reuse_of image."""
        url = None
        refs = (persona or {}).get("references") or []
        if refs and callable(spec.get("resolve_url")):
            url = spec["resolve_url"](refs[0]["path"])
        url = url or spec.get("reference_url")
        if not url:
            raise SelfhostError("a talking-head video needs a persona reference image (or an approved image as reuse_of)")
        if not str(url).startswith("https://") and not (str(url).startswith("file://") and self.local):
            raise SelfhostError("reference URL is not https")
        if str(url).startswith("file://"):
            with open(url[7:], "rb") as f:
                return f.read()
        st, data, _ = self.http("GET", url, timeout=120)
        if st != 200 or not isinstance(data, (bytes, bytearray)) or not data or len(data) > 30 * 1024 * 1024:
            raise SelfhostError(f"reference download refused ({st})")
        return bytes(data)

    def _voice_track(self, spec: dict, script: str, voice: str, workdir: str) -> bytes:
        if spec.get("audio_file") and os.path.isfile(spec["audio_file"]):
            with open(spec["audio_file"], "rb") as f:
                return f.read()
        with open(self.tts(script, voice, workdir), "rb") as f:
            return f.read()


# ------------------------------------------------------------------------------------------------------------------- router policy (called from hq_creative_studio.adapters_for)
def router_filter(out: dict, providers: list[dict], env: dict) -> dict:
    """Selfhost is the default when it is enabled AND configured: fal.ai is then only an opt-in fallback (CREATIVE_FAL_FALLBACK=1). Selfhost costs 0, so it
    already sorts first; this makes sure a worker that is down never silently turns into fal.ai spending."""
    if any(p.get("slug") == SLUG for p in providers) and configured(env) and env.get("CREATIVE_FAL_FALLBACK") != "1":
        out.pop("fal-hosted", None)
    return out


# ------------------------------------------------------------------------------------------------------------------- batch queue + meter
MODULE_ORDER = ("image", "voice", "video", "ugc")


class BatchQueue:
    """Jobs (already submitted with creative_submit, so they are 'queued' in the database) wait here until a worker is up, then run grouped by module so the
    worker keeps one set of weights loaded. A local JSON file, written atomically; losing it loses only the pointers (the jobs stay queued in the database).
    Selfhost work is metered in GPU-seconds at 0 cents; an optional COMFYUI_SELFHOST_HOURLY_USD shows what a RENTED pod's time costs (paid outside the studio)."""

    def __init__(self, path: str | None = None, clock=time.time):
        self.path = path or os.environ.get("CREATIVE_SELFHOST_QUEUE") or os.path.join(os.path.expanduser("~"), ".fendezy", "creative_selfhost_queue.json")
        self.clock = clock

    def _load(self) -> dict:
        try:
            with open(self.path) as f:
                d = json.load(f)
            return d if isinstance(d, dict) and isinstance(d.get("jobs"), list) else {"jobs": [], "log": []}
        except (OSError, ValueError):
            return {"jobs": [], "log": []}

    def _save(self, d: dict) -> None:
        os.makedirs(os.path.dirname(self.path) or ".", exist_ok=True)
        d["log"] = d.get("log", [])[-500:]
        tmp = self.path + ".tmp"
        with open(tmp, "w") as f:
            json.dump(d, f)
        os.replace(tmp, self.path)

    def enqueue(self, job_id: str, office: str, module: str, brief: str = "", priority: int = 0) -> dict:
        if not re.fullmatch(r"[0-9a-fA-F-]{8,40}", str(job_id or "")):
            raise SelfhostError("bad job id")
        if module not in MODULE_ORDER:
            raise SelfhostError(f"selfhost does not run {module} jobs")
        refusal = content_refusal(brief)
        if refusal:
            raise SelfhostError(refusal)
        d = self._load()
        if any(j["job"] == job_id for j in d["jobs"]):
            return {"job": job_id, "status": "already queued"}
        d["jobs"].append({"job": job_id, "office": office, "module": module, "priority": int(priority), "at": self.clock(), "status": "pending"})
        self._save(d)
        return {"job": job_id, "status": "pending"}

    def pending(self) -> list[dict]:
        rows = [j for j in self._load()["jobs"] if j["status"] == "pending"]
        return sorted(rows, key=lambda j: (MODULE_ORDER.index(j["module"]), -j["priority"], j["at"]))

    def drain(self, run, adapter, env: dict, batch_size: int = 8) -> dict:
        """Run up to batch_size pending jobs while the worker stays up. run(job_id, env=..., extra_adapters=...) is hq_creative_studio.run_job.
        Worker down -> nothing is claimed (the jobs keep waiting, nothing falls through to a paid provider)."""
        todo = self.pending()
        if not todo:
            return {"ran": 0, "waiting": 0, "worker": "unknown", "results": []}
        if not adapter.available(env):
            return {"ran": 0, "waiting": len(todo), "worker": "down", "results": []}
        results = []
        for j in todo[:max(1, int(batch_size))]:
            if adapter.health(force=True) is None:
                break                                                          # worker went away: the rest keep waiting
            t0 = self.clock()
            try:
                r = run(j["job"], env=env, extra_adapters={SLUG: adapter})
                status, reason = r.get("status"), r.get("reason")
                gpu = sum(int(a.get("gpu_ms") or 0) for a in r.get("attempts") or []) or int((self.clock() - t0) * 1000)
            except Exception as e:
                status, reason, gpu = "error", f"{type(e).__name__}: {str(e)[:160]}", int((self.clock() - t0) * 1000)
            self._finish(j["job"], status, reason, gpu, r.get("attempts") if status != "error" else None)
            results.append({"job": j["job"], "status": status, "reason": reason})
        left = len(self.pending())
        return {"ran": len(results), "waiting": left, "worker": "up", "results": results}

    def _finish(self, job_id: str, status: str, reason, gpu_ms: int, attempts) -> None:
        d = self._load()
        for j in d["jobs"]:
            if j["job"] == job_id:
                j["status"] = "done" if status in ("awaiting_approval", "approved", "done") else "failed"
                j["reason"] = (str(reason)[:200] if reason else None)
        providers = sorted({a.get("provider") for a in attempts or [] if a.get("provider")})
        d.setdefault("log", []).append({"job": job_id, "status": status, "gpu_ms": int(gpu_ms), "at": self.clock(), "providers": providers,
                                        "cents": 0 if providers in ([], [SLUG]) else None})
        d["jobs"] = [j for j in d["jobs"] if j["status"] == "pending" or self.clock() - j["at"] < 14 * 86400]
        self._save(d)

    def meter(self, env: dict | None = None) -> dict:
        """Selfhost spend: 0 cents per job. GPU time is shown; with COMFYUI_SELFHOST_HOURLY_USD set (a rented pod) also the ESTIMATED rental value of that time."""
        env = env if env is not None else os.environ
        log = self._load().get("log", [])
        sh = [x for x in log if x.get("cents") == 0]
        gpu_s = sum(int(x.get("gpu_ms") or 0) for x in sh) / 1000.0
        out = {"jobs": len(sh), "done": sum(1 for x in sh if x["status"] in ("awaiting_approval", "approved", "done")), "studio_cents": 0, "gpu_seconds": round(gpu_s, 1)}
        try:
            hourly = float(env.get("COMFYUI_SELFHOST_HOURLY_USD") or 0)
        except ValueError:
            hourly = 0.0
        if hourly > 0:
            out["rental_usd_estimate"] = round(gpu_s / 3600.0 * hourly, 2)
        return out


def status_text(env: dict | None = None, queue: BatchQueue | None = None, adapter: SelfhostAdapter | None = None) -> str:
    env = dict(os.environ) if env is None else env
    q = queue or BatchQueue()
    a = adapter or SelfhostAdapter(env)
    h = a.health() if a.is_configured() else None
    m = q.meter(env)
    state = "not configured (set COMFYUI_SELFHOST_URL / COMFYUI_SELFHOST_TOKEN from the worker's printout)" if not a.is_configured() else (
        f"UP on {h['device'] or 'GPU'} ({h['vram_gb']} GB)" if h else "DOWN (start a worker: docs/architecture/CREATIVE_SELFHOST.md)")
    lines = [f"Self-hosted worker: {state}.", f"Waiting jobs: {len(q.pending())}.",
             f"Selfhost so far: {m['jobs']} jobs, {m['done']} done, $0.00 to the studio, {m['gpu_seconds']} GPU-seconds"
             + (f" (rented-pod time worth about US${m['rental_usd_estimate']}, an estimate)" if "rental_usd_estimate" in m else "") + ".",
             "fal.ai fallback: " + ("ON (CREATIVE_FAL_FALLBACK=1)" if env.get("CREATIVE_FAL_FALLBACK") == "1" else "off while the selfhost worker is configured") + "."]
    return "\n".join(lines)


def _main(argv: list[str]) -> int:
    import argparse
    ap = argparse.ArgumentParser(description="creative studio self-hosted worker: status, queue, drain")
    sub = ap.add_subparsers(dest="cmd", required=True)
    sub.add_parser("status")
    e = sub.add_parser("enqueue")
    e.add_argument("job")
    e.add_argument("--office", required=True)
    e.add_argument("--module", required=True, choices=MODULE_ORDER)
    e.add_argument("--brief", default="")
    d = sub.add_parser("drain")
    d.add_argument("--batch", type=int, default=8)
    args = ap.parse_args(argv)
    env = dict(os.environ)
    q = BatchQueue()
    if args.cmd == "status":
        print(status_text(env, q))
    elif args.cmd == "enqueue":
        print(json.dumps(q.enqueue(args.job, args.office, args.module, args.brief)))
    else:
        import hq_creative_studio
        print(json.dumps(q.drain(hq_creative_studio.run_job, SelfhostAdapter(env), env, args.batch), indent=1))
    return 0


if __name__ == "__main__":
    import sys
    raise SystemExit(_main(sys.argv[1:]))
