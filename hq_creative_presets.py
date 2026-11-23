"""FENDEZY AI CREATIVE STUDIO M8c: the template / preset library and the ComfyUI workflow templates (data in creative_studio/presets/library.json and
creative_studio/comfyui/). Pure functions, no network, no database.

- validate(lib) refuses a library that could weaken a gate: a template may not switch off the AI disclosure or captions' disclosure line, may not carry
  testimonial / review / real-customer framing or real-artist imitation, may not name a provider, a model or a price (the router decides those), must belong
  to a known office (or 'group') and module, and may only reference vocabulary, hooks, caption styles and ComfyUI workflows that exist.
- compile_prompt() is the Open-Higgsfield prompt compiler (src/lib/promptUtils.js buildNanoBananaPrompt, MIT) extended with shot type, camera move and UGC
  format, filled from the job brief.
- fill_workflow() turns an API-format ComfyUI template into a ready prompt graph (typed placeholder substitution; an unknown or missing placeholder refuses).
"""
from __future__ import annotations

import copy
import json
import os
import re

HERE = os.path.dirname(os.path.abspath(__file__))
LIBRARY_FILE = os.path.join(HERE, "creative_studio", "presets", "library.json")
COMFY_DIR = os.path.join(HERE, "creative_studio", "comfyui")
OFFICES = ("group", "b2b-records", "donna", "the-trap", "wolf-squad", "pimp-ai", "monopoly", "ff-marketing", "fruition-factory")
MODULES = ("video", "image", "ugc", "voice", "music", "copy", "edit", "train")
KINDS = ("shot", "product", "ugc", "character", "visualizer", "lyric_video", "hero_ad", "edit")
FITS = ("pad", "auto_reframe")
VISUALIZERS = ("waves", "spectrum")
EDIT_KEYS = {"fit", "beat_sync", "hook_first", "broll", "loudnorm", "captions", "max_seconds", "crossfade", "visualizer"}
PROMPT_KEYS = {"base", "shot", "move", "camera", "lens", "focal", "aperture", "lighting", "mood", "ugc_format"}
TEMPLATE_KEYS = {"slug", "office", "module", "kind", "title", "prompt", "negative", "video", "edit", "hooks", "workflow", "requires", "source"}
# words a template may never carry (same rules as the studio's QA): deceptive framing and imitation of a real artist / person
BANNED = re.compile(r"\b(testimonial|customer review|real customer|verified (buyer|purchase)|i bought|5[- ]star|as seen on|unpaid review|review|"
                    r"in the style of|sounds? like|voice of|imitat\w*|clone|deepfake|no disclosure|without (the )?(ai )?label)\b", re.I)
ROUTING_WORDS = re.compile(r"\b(provider|premium|price|cents|usd|cad|kling|veo|runway|fal|replicate|runpod|modal)\b", re.I)


class PresetError(ValueError):
    pass


def load_library(path: str = LIBRARY_FILE) -> dict:
    with open(path) as f:
        lib = json.load(f)
    validate(lib)
    return lib


def load_manifest() -> dict:
    with open(os.path.join(COMFY_DIR, "manifest.json")) as f:
        return json.load(f)


def _strings(x):
    if isinstance(x, str):
        yield x
    elif isinstance(x, dict):
        for v in x.values():
            yield from _strings(v)
    elif isinstance(x, list):
        for v in x:
            yield from _strings(v)


def validate(lib: dict, manifest: dict | None = None) -> list[str]:
    """Raise PresetError listing every problem; return the template slugs when the library is clean."""
    problems: list[str] = []
    vocab = lib.get("vocab") or {}
    hooks = {h.get("id"): h for h in lib.get("hooks") or []}
    styles = lib.get("caption_styles") or {}
    workflows = (manifest or load_manifest()).get("workflows") or {}
    for need in ("cameras", "lenses", "focal", "aperture", "lighting", "mood", "shot_types", "camera_moves", "ugc_formats"):
        if not isinstance(vocab.get(need), dict) or not vocab[need]:
            problems.append(f"vocab.{need} missing")
    for hid, h in hooks.items():
        if not re.fullmatch(r"[a-z0-9-]{2,40}", hid or "") or not isinstance(h.get("text"), str) or not h["text"].strip():
            problems.append(f"hook {hid!r} malformed")
        if set(h.get("fits") or []) - set(MODULES):
            problems.append(f"hook {hid}: unknown module in fits")
    for sid, st in styles.items():
        for k in ("font", "size", "primary", "highlight", "outline", "position", "words_per_line"):
            if k not in st:
                problems.append(f"caption style {sid}: {k} missing")
        for k in ("primary", "highlight", "outline"):
            if k in st and not re.fullmatch(r"#[0-9A-Fa-f]{6}", str(st[k])):
                problems.append(f"caption style {sid}: {k} is not #RRGGBB")
        if st.get("position") not in ("lower", "center", "upper"):
            problems.append(f"caption style {sid}: bad position")
    for text in _strings({k: v for k, v in vocab.items()}):
        if BANNED.search(text):
            problems.append(f"vocab carries banned framing: {text[:60]!r}")
    for h in hooks.values():
        if BANNED.search(h.get("text") or ""):
            problems.append(f"hook {h.get('id')} carries banned framing")
    seen = set()
    for t in lib.get("templates") or []:
        s = t.get("slug") or "?"
        if s in seen:
            problems.append(f"template {s}: duplicate slug")
        seen.add(s)
        if not re.fullmatch(r"[a-z][a-z0-9-]{2,59}", s):
            problems.append(f"template {s}: bad slug")
        extra = set(t) - TEMPLATE_KEYS
        if extra:
            problems.append(f"template {s}: unknown keys {sorted(extra)} (a template never sets providers, models, prices or the disclosure)")
        if t.get("office") not in OFFICES:
            problems.append(f"template {s}: unknown office {t.get('office')!r}")
        if t.get("module") not in MODULES:
            problems.append(f"template {s}: unknown module")
        if t.get("kind") not in KINDS:
            problems.append(f"template {s}: unknown kind")
        if not (t.get("title") or "").strip():
            problems.append(f"template {s}: title missing")
        p = t.get("prompt") or {}
        if not isinstance(p, dict) or not (p.get("base") or "").strip():
            problems.append(f"template {s}: prompt.base missing")
        if set(p) - PROMPT_KEYS:
            problems.append(f"template {s}: unknown prompt keys {sorted(set(p) - PROMPT_KEYS)}")
        for key, voc in (("shot", "shot_types"), ("move", "camera_moves"), ("camera", "cameras"), ("lens", "lenses"), ("focal", "focal"), ("aperture", "aperture"),
                         ("mood", "mood"), ("ugc_format", "ugc_formats")):
            if p.get(key) is not None and str(p[key]) not in (vocab.get(voc) or {}):
                problems.append(f"template {s}: {key} {p[key]!r} is not in vocab.{voc}")
        for li in p.get("lighting") or []:
            if li not in (vocab.get("lighting") or {}):
                problems.append(f"template {s}: lighting {li!r} unknown")
        positive = [t.get("title") or "", *[str(v) for k, v in p.items() if k != "lighting"]]
        for text in positive:
            if BANNED.search(text):
                problems.append(f"template {s}: banned framing in {text[:50]!r}")
            if ROUTING_WORDS.search(text):
                problems.append(f"template {s}: routing / price words belong to the router, not a template ({text[:40]!r})")
        e = t.get("edit") or {}
        if not isinstance(e, dict) or set(e) - EDIT_KEYS:
            problems.append(f"template {s}: unknown edit keys {sorted(set(e) - EDIT_KEYS) if isinstance(e, dict) else e}")
        else:
            if e.get("fit") is not None and e["fit"] not in FITS:
                problems.append(f"template {s}: bad fit")
            if e.get("captions") not in (None, "none", *styles):
                problems.append(f"template {s}: unknown caption style {e.get('captions')!r}")
            if e.get("visualizer") is not None and e["visualizer"] not in VISUALIZERS:
                problems.append(f"template {s}: bad visualizer")
            if e.get("loudnorm") is not None and not (-24 <= float(e["loudnorm"]) <= -9):
                problems.append(f"template {s}: loudnorm target outside -24..-9 LUFS")
            bs = e.get("beat_sync")
            if bs is not None and not (isinstance(bs, dict) and int(bs.get("beats_per_cut") or 0) in (1, 2, 4, 8)):
                problems.append(f"template {s}: beat_sync.beats_per_cut must be 1, 2, 4 or 8")
            if e.get("max_seconds") is not None and not (3 <= float(e["max_seconds"]) <= 60):
                problems.append(f"template {s}: max_seconds outside 3..60")
            if e.get("crossfade") is not None and not (0 <= float(e["crossfade"]) <= 1):
                problems.append(f"template {s}: crossfade outside 0..1 s")
            if (e.get("beat_sync") or e.get("broll")) and t.get("module") != "edit":
                problems.append(f"template {s}: beat_sync / broll need module 'edit'")
            if e.get("visualizer") and t.get("module") != "music":
                problems.append(f"template {s}: a visualizer needs module 'music'")
        v = t.get("video")
        if v is not None and not (isinstance(v, dict) and 1 <= int(v.get("seconds") or 0) <= 10 and int(v.get("fps") or 0) in (16, 24, 25, 30)):
            problems.append(f"template {s}: video.seconds 1..10 and fps 16/24/25/30")
        for h in t.get("hooks") or []:
            if h not in hooks:
                problems.append(f"template {s}: unknown hook {h}")
            elif t.get("module") not in (hooks[h].get("fits") or []):
                problems.append(f"template {s}: hook {h} does not fit module {t.get('module')}")
        if t.get("workflow") is not None:
            w = workflows.get(t["workflow"])
            if not w:
                problems.append(f"template {s}: unknown ComfyUI workflow {t['workflow']}")
            elif w.get("module") != ("video" if t.get("module") in ("video", "ugc") else t.get("module")):
                problems.append(f"template {s}: workflow {t['workflow']} is for {w.get('module')}")
        req = t.get("requires") or {}
        if not isinstance(req, dict) or set(req) - {"character_lora", "images_min"}:
            problems.append(f"template {s}: unknown requires")
    if problems:
        raise PresetError("; ".join(problems))
    return sorted(seen)


def templates_for(lib: dict, office: str, module: str) -> list[dict]:
    """The office's own templates first, then the group's, for one module."""
    rows = [t for t in lib["templates"] if t["module"] == module and t["office"] in (office, "group")]
    return sorted(rows, key=lambda t: (t["office"] != office, t["slug"]))


def template(lib: dict, slug: str) -> dict:
    for t in lib["templates"]:
        if t["slug"] == slug:
            return t
    raise PresetError(f"unknown template {slug}")


def _fill(text: str, values: dict) -> str:
    return re.sub(r"\{([a-z_]+)\}", lambda m: str(values.get(m.group(1)) or values.get("subject") or "").strip(), text or "")


def compile_prompt(lib: dict, tpl: dict, brief: str, values: dict | None = None) -> str:
    """Open-Higgsfield order: base, shot on <camera>, using <lens> at <focal>mm (<perspective>), aperture, depth effect, lighting, colour science, quality;
    plus our shot type, camera move and UGC format. {placeholders} come from values, falling back to the brief."""
    v = {"subject": (brief or "").strip().rstrip("."), "product": None, **(values or {})}
    if not v.get("product"):
        v["product"] = v["subject"]
    voc = lib["vocab"]
    p = tpl.get("prompt") or {}
    parts = [_fill(p.get("base", ""), v)]
    if p.get("ugc_format"):
        parts.append(voc["ugc_formats"][p["ugc_format"]])
    if p.get("shot"):
        parts.append(voc["shot_types"][p["shot"]])
    if p.get("move"):
        parts.append(voc["camera_moves"][p["move"]])
    if p.get("camera"):
        parts.append("shot on a " + voc["cameras"][p["camera"]])
    if p.get("lens"):
        focal = str(p.get("focal") or "")
        persp = voc["focal"].get(focal, "")
        parts.append(f"using a {voc['lenses'][p['lens']]}" + (f" at {focal}mm" if focal else "") + (f" ({persp})" if persp else ""))
    if p.get("aperture"):
        parts += [f"aperture {p['aperture']}", voc["aperture"][p["aperture"]]]
    parts += [voc["lighting"][x] for x in p.get("lighting") or []]
    if p.get("mood"):
        parts.append(voc["mood"][p["mood"]])
    if tpl.get("module") in ("image", "video", "ugc"):
        parts += list(voc.get("quality") or [])
    if brief and v["subject"] not in parts[0]:
        parts.append(v["subject"])
    return ", ".join(x for x in parts if x and x.strip())[:2000]


def hook_text(lib: dict, hook_id: str, values: dict) -> str | None:
    h = next((x for x in lib.get("hooks") or [] if x["id"] == hook_id), None)
    if not h:
        raise PresetError(f"unknown hook {hook_id}")
    v = {"n": 3, **{k: x for k, x in values.items() if x}}
    v.setdefault("title", v.get("subject"))
    v.setdefault("product", v.get("subject"))
    if any(name not in v for name in re.findall(r"\{([a-z_]+)\}", h["text"])):
        return None                                                              # this hook needs a value the job does not have: the caller tries the next one
    out = _fill(h["text"], v)
    return re.sub(r"\s+", " ", out).strip()[:80]


def caption_style(lib: dict, name: str | None, brand_kit: dict | None = None) -> dict | None:
    """The template's caption style with the office brand kit's first two colours (primary, highlight) and first font applied."""
    if not name or name == "none":
        return None
    st = dict(lib["caption_styles"][name])
    kit = brand_kit or {}
    colours = [c for c in kit.get("colours") or [] if re.fullmatch(r"#[0-9A-Fa-f]{6}", str(c))]
    if len(colours) >= 2:
        st["highlight"] = colours[1]
    fonts = [f for f in kit.get("fonts") or [] if isinstance(f, str) and re.fullmatch(r"[A-Za-z0-9 ._-]{2,60}", f)]
    if fonts:
        st["font"] = fonts[0]
    st["name"] = name
    return st


# ------------------------------------------------------------------------------------------------------------------- ComfyUI workflow templates
PLACEHOLDER = re.compile(r"^\{\{([a-z_]+)\}\}$")
INT_PARAMS = {"width", "height", "frames", "fps", "seed"}
FLOAT_PARAMS = {"lora_strength"}


def workflow(workflow_id: str, params: dict) -> dict:
    """The API-format graph for workflow_id with every {{placeholder}} filled (ints / floats typed). Refuses unknown or missing params."""
    m = load_manifest()["workflows"].get(workflow_id)
    if not m:
        raise PresetError(f"unknown workflow {workflow_id}")
    with open(os.path.join(COMFY_DIR, m["file"])) as f:
        graph = json.load(f)
    vals = dict(params)
    if "negative" in m.get("params", []) and not vals.get("negative"):
        vals["negative"] = m.get("negative_default", "")
    unknown = set(vals) - set(m["params"])
    if unknown:
        raise PresetError(f"{workflow_id}: unknown params {sorted(unknown)}")
    return fill_workflow(graph, vals)


def fill_workflow(graph: dict, values: dict) -> dict:
    g = copy.deepcopy(graph)
    missing = set()

    def conv(name, v):
        if name in INT_PARAMS:
            return int(v)
        if name in FLOAT_PARAMS:
            return float(v)
        return str(v)

    for node in g.values():
        for k, v in list((node.get("inputs") or {}).items()):
            if isinstance(v, str):
                m = PLACEHOLDER.match(v)
                if m:
                    if m.group(1) not in values or values[m.group(1)] is None:
                        missing.add(m.group(1))
                    else:
                        node["inputs"][k] = conv(m.group(1), values[m.group(1)])
    if missing:
        raise PresetError(f"workflow placeholders not filled: {sorted(missing)}")
    return g


def video_frames(seconds: int, fps: int, model: str) -> int:
    """Frame counts the video models accept: Wan wants 4n+1, LTX 8n+1."""
    n = max(1, int(seconds)) * int(fps)
    step = 8 if model.startswith("ltx") else 4
    return (n // step) * step + 1


def seed_rows(lib: dict) -> list[dict]:
    """Rows for fz_creative.templates (the migration seed), in slug order."""
    return [{"slug": t["slug"], "office": t["office"], "module": t["module"], "kind": t["kind"], "title": t["title"], "hooks": list(t.get("hooks") or []),
             "spec": {k: t[k] for k in ("prompt", "negative", "video", "edit", "workflow", "requires") if k in t}, "source": t.get("source") or "fendezy"}
            for t in sorted(lib["templates"], key=lambda x: x["slug"])]
