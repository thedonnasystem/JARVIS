"""FF Marketing base engine: owner-triggered generation of a full campaign pack for one client workspace, stored as DRAFTS only.

Flow (Telegram, owner only): /ffm new (brief) -> /ffm pack <slug> (generate) -> /ffm show <slug> (summary + files).
- LLM: the same gated path as the owner chat (hq_meter.metered_create -> spend gateway -> existing daily cap), cheap model tier, at most
  MAX_CALLS calls and a per-pack cost ceiling. A refused reservation (kill switch, cap) stops the pack and is reported to the owner.
- Privacy: the brief is screened before any model sees it; every generated free-text string is screened (hq_llm.has_personal_data + the
  database classifier ffm_guard uses, with the workspace's context) and a flagged string is blanked and listed in screened_out; the database
  re-screens everything it stores. In a workspace the classifier treats as insurance context (every vertical except mortgage, by the
  20261122 design) only owner-approved vocabulary passes, so the model is given that vocabulary and anything else is blanked.
- Storage: campaign / ad sets / creatives via the existing ffm_add_* functions (dry_run, status draft); the pack via ffm_engine_save_pack
  (draft, dry_run). Fixed text (compliance items, consent placeholder, opt-out lines, report template, owner actions) and the landing page
  HTML are rendered from code at show time, never stored. Organic posts become hand_actions drafts only on /ffm queue (the owner approves each
  one in the hands flow). Follow-ups stay templates: they have no recipient, so nothing goes to the outbox.
Nothing here launches an ad, calls an ad platform, sends a message, sets a budget, approves anything or changes a control."""
import asyncio
import html
import io
import json
import logging
import os
import re
import urllib.error
from pathlib import Path

import hq
import hq_llm
import hq_meter
from hq_workspace import SensitiveDataRefused, _msg

logger = logging.getLogger(__name__)

VERTICALS = ("generic", "mortgage", "insurance", "home_services", "real_estate")
LEAD_FIELDS = ("name", "email", "phone")          # the only lead fields any pack may ask for (subset of the routing allow-list)
CONSENT_PLACEHOLDER = "[CLIENT TO PROVIDE: exact consent wording shown next to the form]"
SCREENED = ""                                     # a blanked string; its path is listed in pack["screened_out"]
FREE_KEYS = frozenset({"statement", "offer_angle", "differentiators", "name", "description", "pain_point", "audience_description", "placement_note", "headline",
                       "primary_text", "cta", "prompt", "metric", "target", "note", "subheadline", "bullets", "cta_text", "q", "a", "trust_note", "subject", "body",
                       "hook", "caption", "offer", "service_area", "target_customer", "goal", "monthly_budget_stated"})   # = free_keys in ffm_engine_save_pack
AD_SET_FALLBACK = ("First audience", "Second audience", "Audience")   # names that pass the classifier in every workspace context
CAMPAIGN_NAME = "Campaign draft"
OPT_OUT = {"sms": "Reply STOP to opt out.", "email": "To stop these emails, use the unsubscribe link below. [CLIENT TO PROVIDE: sender name and mailing address]"}
AI_DISCLOSURE = "AI-generated visual: label it as AI-made where the platform requires it (e.g. Meta 'AI info'); the client approves it before use."
CTAS = ("Learn More", "Book Now", "Get Quote", "Contact Us", "Sign Up", "Call Now", "Get Offer", "Send Message")
PLATFORMS = ("instagram", "facebook", "tiktok", "linkedin", "youtube", "x")
MODEL = os.environ.get("FFM_ENGINE_MODEL") or os.environ.get("HQ_MODEL_CHEAP") or "claude-haiku-5-5"
PACK_CEILING_CENTS = max(1, min(int(os.environ.get("FFM_PACK_CEILING_CENTS") or 10), 30))   # hard upper bound 30 cents per pack
MAX_CALLS = 5                                     # 3 steps + at most 2 repairs of unparseable output
PROMPTS = Path(__file__).resolve().parent / "prompts" / "ffm"
SLUG = re.compile(r"^[a-z0-9][a-z0-9-]{1,40}$")
BRIEF_KEYS = {"business_name": ("business", "name", "business name", "client"), "offer": ("offer",),
              "service_area": ("area", "service area", "geography", "location"), "target_customer": ("customer", "target", "target customer", "audience"),
              "goal": ("goal",), "monthly_budget_stated": ("budget", "monthly budget"), "vertical": ("vertical", "industry"), "slug": ("slug", "workspace")}
REQUIRED = ("business_name", "offer", "service_area", "target_customer", "goal")
NEW_HELP = ("Sir, send the brief in one message:\n/ffm new\nname: <business name>\nvertical: generic | mortgage | insurance | home_services | real_estate\n"
            "offer: <what they sell / the offer>\narea: <service area exactly as the client states it>\ncustomer: <target customer>\n"
            "goal: <e.g. booked calls>\nbudget: <monthly budget as stated, or unset>\nslug: <optional short id>\n"
            "Business facts only: no client personal, financial or health details.")

STEPS = (
    ("strategy", 4000, """Write the campaign strategy as JSON with exactly these keys:
{"positioning": {"statement": str, "offer_angle": str, "differentiators": [2-4 str]},
 "audience_angles": [3 x {"key": "A"|"B"|"C", "name": str, "description": str (who, situation, interests in words; under 400 chars), "pain_point": str}],
 "ad_sets": [3 x {"angle": "A"|"B"|"C", "name": str (under 80 chars), "audience_description": str (under 400 chars), "placement_note": str}],
 "ad_variants": [9 x {"id": "V1".."V9", "angle": "A"|"B"|"C" (3 per angle), "headline": str (under 60 chars), "primary_text": str (under 450 chars), "cta": one of %s}],
 "creative_briefs": [9 x {"variant": "V1".."V9", "format": "image"|"video", "prompt": str (an image or video generation prompt, under 400 chars)}],
 "kpi_targets": [3-6 x {"metric": str, "target": str, "note": str}] (ratios and counts only, e.g. click-through rate, landing conversion rate, lead-to-booked rate; no money amounts because the budget may be unset)}"""),
    ("funnel", 2200, """Write the landing page copy and the follow-up sequence as JSON with exactly these keys:
{"landing_page": {"headline": str, "subheadline": str, "bullets": [3-5 str], "cta_text": str, "faq": [2-4 x {"q": str, "a": str}], "trust_note": str},
 "follow_up": [5 x {"touch": 1..5, "day": int (0, 1, 3, 6, 10), "channel": "sms"|"email", "subject": str (email only, else ""), "body": str (sms under 300 chars; email under 900 chars)}]}
No merge fields and no opt-out or unsubscribe lines: they are added automatically. Every message names the business. Messages are only sent after consent is recorded."""),
    ("organic", 2400, """Write a 2-week organic content calendar as JSON: {"organic_calendar": [14 x {"day": 1..14, "platform": one of %s, "format": "post"|"reel"|"carousel"|"story", "hook": str (under 100 chars), "caption": str (under 600 chars)}]}
No more than 1 in 3 posts asks for the sale."""),
)


class BriefError(ValueError):
    """The brief is incomplete or malformed. The message is safe to show the owner."""


class PackInvalid(ValueError):
    """The model's output did not fit the pack schema."""


class PackCostCeiling(Exception):
    """The next call would take the pack over its cost ceiling; generation stopped, nothing stored."""


# ------------------------------------------------------------------------------------------------------------------- brief
def slugify(name: str) -> str:
    s = re.sub(r"[^a-z0-9]+", "-", (name or "").lower()).strip("-")[:40].strip("-")
    return s if SLUG.match(s or "") else ""


def parse_brief(text: str) -> dict:
    """'key: value' lines (aliases accepted) -> brief dict. Unknown keys are ignored; the command line itself is skipped."""
    alias = {a: k for k, al in BRIEF_KEYS.items() for a in (k, k.replace("_", " "), *al)}
    out = {}
    for line in (text or "").splitlines():
        m = re.match(r"^\s*([A-Za-z_ ]{2,30})\s*[:=]\s*(.+?)\s*$", line)
        if m and m.group(1).strip().lower() in alias:
            out[alias[m.group(1).strip().lower()]] = m.group(2)
    return out


def validate_brief(raw: dict) -> dict:
    b = {k: str(v).strip() for k, v in (raw or {}).items() if k in BRIEF_KEYS and v is not None and str(v).strip()}
    missing = [k for k in REQUIRED if not b.get(k)]
    if missing:
        raise BriefError("missing: " + ", ".join(missing))
    b["vertical"] = (b.get("vertical") or "generic").lower().replace(" ", "_").replace("-", "_")
    if b["vertical"] not in VERTICALS:
        raise BriefError("vertical must be one of " + ", ".join(VERTICALS))
    b["monthly_budget_stated"] = b.get("monthly_budget_stated") or "unset"
    for k, v in b.items():
        if len(v) > 500:
            raise BriefError(f"{k} is longer than 500 characters")
    if len(b["business_name"]) < 2 or len(b["business_name"]) > 120:
        raise BriefError("business name must be 2-120 characters")
    slug = b.pop("slug", "").lower() or slugify(b["business_name"])
    if not SLUG.match(slug):
        raise BriefError("slug must be lowercase letters, digits and dashes (2-41 characters)")
    for k, v in b.items():                      # client text bound for a model: refuse personal data before anything else sees it
        if hq_llm.has_personal_data(v):
            raise SensitiveDataRefused(f"brief field {k} looks like personal or sensitive data")
    return {**b, "slug": slug}


# ------------------------------------------------------------------------------------------------------------------- prompts
def playbook(vertical: str) -> str:
    v = vertical if vertical in VERTICALS else "generic"
    parts = [(PROMPTS / "generic.md").read_text()]
    if v != "generic":
        parts.append((PROMPTS / f"{v}.md").read_text())
    return "\n\n".join(parts)


def confirm_items(vertical: str) -> list[str]:
    """The 'Confirm with the client' bullets of the playbooks (generic + vertical), verbatim: items to confirm, not legal advice."""
    items = []
    for block in re.findall(r"## Confirm with the client\n(.*?)(?=\n#|\Z)", playbook(vertical), re.S):
        items += [ln[2:].strip() for ln in block.splitlines() if ln.startswith("- ")]
    return items


def build_prompt(step: str, brief: dict, prior: dict | None = None, vocab: str = "") -> tuple[str, str]:
    instr = dict((s, t) for s, _, t in STEPS)[step]
    if step == "strategy":
        instr = instr % (json.dumps(list(CTAS)),)
    elif step == "organic":
        instr = instr % (json.dumps(list(PLATFORMS)),)
    system = (PROMPTS / "system.md").read_text() + "\n\n" + playbook(brief.get("vertical", "generic"))
    if vocab:
        system += ("\n\nSTRICT VOCABULARY for this client: write every sentence ONLY with words from this list (and the business name). "
                   "Any text that uses another word is deleted before storage, so prefer short, simple sentences:\n" + vocab)
    facts = {k: brief[k] for k in ("business_name", "vertical", "offer", "service_area", "target_customer", "goal", "monthly_budget_stated") if k in brief}
    ctx = ""
    if prior and step != "strategy":
        ctx = "\nCampaign so far (stay consistent with it):\n" + json.dumps({"positioning": prior.get("positioning"),
                                                                            "audience_angles": [{"key": a.get("key"), "name": a.get("name")} for a in prior.get("audience_angles", [])]})
    return system, "Client brief:\n" + json.dumps(facts, ensure_ascii=False) + ctx + "\n\n" + instr


def extract_json(text: str) -> dict:
    t = (text or "").strip()
    i, j = t.find("{"), t.rfind("}")
    if i < 0 or j <= i:
        raise PackInvalid("no JSON object in the model output")
    try:
        d = json.loads(t[i:j + 1])
    except ValueError as e:
        raise PackInvalid(f"unparseable JSON: {e}") from None
    if not isinstance(d, dict):
        raise PackInvalid("the model output is not a JSON object")
    return d


# ------------------------------------------------------------------------------------------------------------------- validation
def _s(v, n: int, what: str, required=True) -> str:
    s = re.sub(r"\s+\n", "\n", str(v if v is not None else "")).strip()
    if required and not s:
        raise PackInvalid(f"{what} is empty")
    return s[:n]


def _list(v, lo: int, hi: int, what: str) -> list:
    if not isinstance(v, list) or len(v) < lo:
        raise PackInvalid(f"{what}: expected at least {lo} items")
    return v[:hi]


def normalise_part(step: str, d: dict) -> dict:
    """Shape-checks and trims one step's output to the pack schema (and to the database column limits). Raises PackInvalid."""
    if step == "strategy":
        p = d.get("positioning") or {}
        if not isinstance(p, dict):
            raise PackInvalid("positioning must be an object")
        out = {"positioning": {"statement": _s(p.get("statement"), 400, "positioning.statement"), "offer_angle": _s(p.get("offer_angle"), 300, "positioning.offer_angle"),
                               "differentiators": [_s(x, 200, "differentiator") for x in _list(p.get("differentiators"), 2, 4, "differentiators")]}}
        angles = []
        for i, a in enumerate(_list(d.get("audience_angles"), 3, 3, "audience_angles")):
            angles.append({"key": "ABC"[i], "name": _s(a.get("name"), 80, "angle name"), "description": _s(a.get("description"), 450, "angle description"),
                           "pain_point": _s(a.get("pain_point"), 250, "pain point")})
        out["audience_angles"] = angles
        keys = [a["key"] for a in angles]
        sets = _list(d.get("ad_sets"), 3, 3, "ad_sets")
        out["ad_sets"] = [{"angle": keys[i], "name": _s(s.get("name"), 150, "ad set name"), "audience_description": _s(s.get("audience_description"), 450, "audience"),
                           "placement_note": _s(s.get("placement_note"), 200, "placement", required=False)} for i, s in enumerate(sets)]
        variants = _list(d.get("ad_variants"), 9, 9, "ad_variants")
        out["ad_variants"] = []
        for i, v in enumerate(variants):
            cta = str(v.get("cta") or "").strip()
            out["ad_variants"].append({"id": f"V{i + 1}", "angle": keys[i // 3], "headline": _s(v.get("headline"), 110, "headline"),
                                       "primary_text": _s(v.get("primary_text"), 900, "primary text"), "cta": cta if cta in CTAS else "Learn More"})
        briefs = d.get("creative_briefs") if isinstance(d.get("creative_briefs"), list) else []
        out["creative_briefs"] = []
        for i in range(9):
            c = briefs[i] if i < len(briefs) and isinstance(briefs[i], dict) else {}
            out["creative_briefs"].append({"variant": f"V{i + 1}", "format": "video" if c.get("format") == "video" else "image",
                                           "prompt": _s(c.get("prompt"), 450, f"creative prompt V{i + 1}")})
        out["kpi_targets"] = [{"metric": _s(k.get("metric"), 80, "kpi metric"), "target": _s(k.get("target"), 80, "kpi target"), "note": _s(k.get("note"), 200, "kpi note", required=False)}
                              for k in _list(d.get("kpi_targets"), 3, 6, "kpi_targets")]
        return out
    if step == "funnel":
        lp = d.get("landing_page") or {}
        if not isinstance(lp, dict):
            raise PackInvalid("landing_page must be an object")
        out = {"landing_page": {"headline": _s(lp.get("headline"), 120, "landing headline"), "subheadline": _s(lp.get("subheadline"), 250, "subheadline"),
                                "bullets": [_s(x, 200, "bullet") for x in _list(lp.get("bullets"), 3, 5, "bullets")], "cta_text": _s(lp.get("cta_text"), 60, "cta text"),
                                "faq": [{"q": _s(f.get("q"), 200, "faq q"), "a": _s(f.get("a"), 500, "faq a")} for f in _list(lp.get("faq"), 2, 4, "faq")],
                                "trust_note": _s(lp.get("trust_note"), 300, "trust note", required=False)}}
        days = (0, 1, 3, 6, 10)
        out["follow_up"] = []
        for i, t in enumerate(_list(d.get("follow_up"), 5, 5, "follow_up")):
            ch = "email" if t.get("channel") == "email" else "sms"
            out["follow_up"].append({"touch": i + 1, "day": days[i], "channel": ch, "subject": _s(t.get("subject"), 120, "subject", required=(ch == "email")) if ch == "email" else "",
                                     "body": _s(t.get("body"), 300 if ch == "sms" else 900, "follow-up body")})
        return out
    if step == "organic":
        out = {"organic_calendar": []}
        for i, p in enumerate(_list(d.get("organic_calendar"), 14, 14, "organic_calendar")):
            plat = str(p.get("platform") or "").lower()
            out["organic_calendar"].append({"day": i + 1, "platform": plat if plat in PLATFORMS else "instagram",
                                            "format": p.get("format") if p.get("format") in ("post", "reel", "carousel", "story") else "post",
                                            "hook": _s(p.get("hook"), 100, "hook"), "caption": _s(p.get("caption"), 600, "caption")})
        return out
    raise ValueError(step)


def assemble(brief: dict, parts: dict) -> dict:
    """The stored pack: generated copy plus short codes only. Fixed text is added at show time by expand()."""
    pack = {"schema": "ffm.pack.v1", "workspace": brief["slug"], "vertical": brief["vertical"],
            "brief": {k: brief[k] for k in ("offer", "service_area", "target_customer", "goal", "monthly_budget_stated") if brief.get(k) and brief[k] != "unset"},
            **parts["strategy"], **parts["funnel"], **parts["organic"], "lead_form": {"fields": list(LEAD_FIELDS)},
            "status": "draft", "dry_run": True, "screened_out": []}
    validate_pack(pack)
    return pack


def validate_pack(pack: dict) -> None:
    """The invariants every stored pack must hold. Raises PackInvalid."""
    need = ("positioning", "audience_angles", "ad_sets", "ad_variants", "creative_briefs", "landing_page", "lead_form", "follow_up", "organic_calendar", "kpi_targets")
    missing = [k for k in need if not pack.get(k)]
    if missing:
        raise PackInvalid("pack is missing " + ", ".join(missing))
    counts = {"audience_angles": 3, "ad_sets": 3, "ad_variants": 9, "creative_briefs": 9, "follow_up": 5, "organic_calendar": 14}
    for k, n in counts.items():
        if len(pack[k]) != n:
            raise PackInvalid(f"{k}: expected {n}, got {len(pack[k])}")
    if sorted(v["angle"] for v in pack["ad_variants"]) != ["A"] * 3 + ["B"] * 3 + ["C"] * 3:
        raise PackInvalid("ad variants must be 3 per angle")
    if tuple(pack["lead_form"].get("fields") or ()) != LEAD_FIELDS or set(pack["lead_form"]) != {"fields"}:
        raise PackInvalid("lead form fields must be exactly name, email, phone")
    if pack.get("status") != "draft" or pack.get("dry_run") is not True:
        raise PackInvalid("a pack is always a dry-run draft")


def expand(pack: dict, business_name: str) -> dict:
    """The owner's view: the stored pack plus the fixed text rendered from code (never stored)."""
    full = json.loads(json.dumps(pack))
    full["business_name"] = business_name
    full["lead_form"] = {"fields": list(LEAD_FIELDS), "consent_wording": CONSENT_PLACEHOLDER,
                         "notes": "Only name, email and phone. Never ask for income, credit, documents, health or ID. The consent wording comes from the client, verbatim."}
    for c in full["creative_briefs"]:
        c["ai_disclosure"] = AI_DISCLOSURE
    for t in full["follow_up"]:
        t["opt_out_line"] = OPT_OUT[t["channel"]]
        t["send_only_after"] = "consent recorded and the owner's outreach gate open"
    full["weekly_report"] = {"source": "ffm_weekly_report (rendered by hq_ffm.render_weekly_report)", "period": "weekly, per workspace", "counts_only": True,
                             "sections": ["readiness", "funnel: new leads by stage", "lead-to-booked rate", "spend in period / month / budget / remaining",
                                          "campaigns by status", "creatives awaiting review", "cost per booked (hq_ffm.cost_per_booked)", "KPI targets vs actual (this pack)"]}
    full["compliance_to_confirm"] = confirm_items(pack["vertical"])
    full["owner_actions"] = ["Set the monthly budget (owner-only) and approve activation when the onboarding checklist is complete.",
                             "Have the client approve every ad, the landing page and the follow-ups; then approve creatives yourself (owner-only).",
                             "Get the exact consent wording and the licence / registration display text from the client.",
                             "Rewrite by hand any text listed in screened_out (blanked by the privacy screen).",
                             "Publishing, ad spend and any message to a lead stay separate owner gates."]
    return full


# ------------------------------------------------------------------------------------------------------------------- screening
def _leaves(obj, path="", key=None):
    if isinstance(obj, dict):
        for k, v in obj.items():
            yield from _leaves(v, f"{path}.{k}" if path else k, k)
    elif isinstance(obj, list):
        for i, v in enumerate(obj):
            yield from _leaves(v, f"{path}[{i}]", key)
    elif isinstance(obj, str):
        yield path, key, obj


def _set(obj, path: str, value):
    toks = re.findall(r"[^.\[\]]+|\[\d+\]", path)
    for t in toks[:-1]:
        obj = obj[int(t[1:-1])] if t.startswith("[") else obj[t]
    last = toks[-1]
    if last.startswith("["):
        obj[int(last[1:-1])] = value
    else:
        obj[last] = value


def db_screen(ws_id: str, texts: list[str], rpc=None) -> set[int]:
    """Indexes of texts the database classifier (the one ffm_guard uses, with this workspace's context) would refuse. Stores nothing."""
    rpc = rpc or _rpc
    out = set()
    for start in range(0, len(texts), 400):
        for hit in rpc("ffm_engine_screen_texts", {"p_ws": ws_id, "p_texts": texts[start:start + 400]}) or []:
            out.add(start + int(hit["i"]))
    return out


def screen_pack(pack: dict, ws_id: str, rpc=None) -> list[str]:
    """Blanks every generated free-text string that either detector flags. Returns the flagged paths (never the text)."""
    leaves = [(p, t) for p, k, t in _leaves(pack) if k in FREE_KEYS and t.strip()]
    flagged = {i for i, (_, t) in enumerate(leaves) if hq_llm.has_personal_data(t)}
    flagged |= db_screen(ws_id, [t for _, t in leaves], rpc)
    paths = [leaves[i][0] for i in sorted(flagged)]
    for p in paths:
        _set(pack, p, SCREENED)
    pack["screened_out"] = paths
    return paths


# ------------------------------------------------------------------------------------------------------------------- landing page
def render_landing_html(full: dict) -> str:
    """A simple self-contained page from expand(pack) (no external assets, no scripts, the form posts nowhere: it is a draft)."""
    e = lambda s: html.escape(str(s or ""), quote=True)   # noqa: E731
    lp = full["landing_page"]
    bullets = "".join(f"<li>{e(x)}</li>" for x in lp["bullets"] if x)
    faq = "".join(f"<details><summary>{e(f['q'])}</summary><p>{e(f['a'])}</p></details>" for f in lp["faq"] if f.get("q") and f.get("a"))
    types = {"email": "email", "phone": "tel"}
    fields = "".join(f'<label>{e(f.title())}<input name="{f}" type="{types.get(f, "text")}" required></label>' for f in full["lead_form"]["fields"])
    disclosure = "[CLIENT TO CONFIRM: licence / registration display text as required]" if full["vertical"] in ("mortgage", "insurance", "real_estate") else ""
    area = full.get("brief", {}).get("service_area", "")
    return f"""<!doctype html>
<html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
<title>{e(full['business_name'])}</title>
<style>
body{{margin:0;font-family:system-ui,sans-serif;color:#1d2433;background:#f6f7f9;line-height:1.5}}
main{{max-width:640px;margin:0 auto;padding:24px 16px}}
h1{{font-size:1.9em;margin:.2em 0}} .sub{{font-size:1.1em;color:#4a5468}}
form{{background:#fff;border:1px solid #dde1e8;border-radius:12px;padding:16px;margin:24px 0}}
label{{display:block;margin:8px 0;font-weight:600}} input{{display:block;width:100%;box-sizing:border-box;padding:10px;margin-top:4px;border:1px solid #c5ccd8;border-radius:8px;font:inherit}}
button{{width:100%;padding:12px;margin-top:12px;border:0;border-radius:8px;background:#1f5eff;color:#fff;font:inherit;font-weight:700}}
.consent,.note,footer{{font-size:.85em;color:#5b6475}} details{{background:#fff;border-radius:8px;padding:8px 12px;margin:8px 0}}
.draft{{background:#fff4d6;padding:8px 12px;border-radius:8px;font-size:.85em}}
</style></head><body><main>
<p class="draft">DRAFT for client review. Not published. The form is not connected.</p>
<h1>{e(lp['headline'] or full['business_name'])}</h1><p class="sub">{e(lp['subheadline'])}</p>
<ul>{bullets}</ul>
<form onsubmit="return false">{fields}<p class="consent">{e(full['lead_form']['consent_wording'])}</p><button type="submit">{e(lp['cta_text'] or 'Send')}</button></form>
<p class="note">{e(lp.get('trust_note'))}</p>
{faq}
<footer><p>{e(full['business_name'])}{('. ' + e(area)) if area else ''}</p><p>{e(disclosure)}</p><p>[CLIENT TO PROVIDE: privacy notice link]</p></footer>
</main></body></html>
"""


# ------------------------------------------------------------------------------------------------------------------- LLM (the owner-chat path)
def _anthropic():
    """The existing HQ Anthropic client (hq_engine): no new provider call site; every call below still goes through hq_meter."""
    import hq_engine
    return hq_engine._anthropic()


def _estimate(model: str, in_tokens: int, out_tokens: int) -> int:
    try:
        return int(hq_meter._estimate(model, in_tokens, out_tokens))
    except Exception:
        raise hq_meter.MeterBlocked("no price available for the engine model", "error") from None


def _call_llm(purpose: str, model: str, system: str, user: str, max_tokens: int) -> tuple[str, int]:
    """Through the spend gateway (reserve -> call -> settle), exactly like the owner chat. Returns (text, cents)."""
    resp = hq_meter.metered_create(_anthropic(), purpose, model=model, max_tokens=max_tokens, system=system, messages=[{"role": "user", "content": user}])
    text = "".join(getattr(b, "text", "") for b in resp.content if getattr(b, "type", "") == "text")
    u = getattr(resp, "usage", None)
    return text, _estimate(model, int(getattr(u, "input_tokens", 0) or 0), int(getattr(u, "output_tokens", 0) or 0))


def generate(brief: dict, *, call=None, estimate=None, ceiling: int | None = None, model: str | None = None, vocab: str = "") -> tuple[dict, int, int]:
    """Runs the steps. Returns (parts, cents spent, calls made). Stops BEFORE a call that could take the pack over the ceiling.
    hq_meter.MeterBlocked (kill switch, daily cap, gateway down) propagates: nothing is stored."""
    call, estimate = call or _call_llm, estimate or _estimate
    ceiling = PACK_CEILING_CENTS if ceiling is None else ceiling
    model = model or MODEL
    parts, spent, calls = {}, 0, 0
    for step, max_out, _ in STEPS:
        for attempt in (1, 2):
            system, user = build_prompt(step, brief, parts.get("strategy"), vocab)
            est = estimate(model, hq_llm.estimate_tokens(system + user), max_out)
            if calls >= MAX_CALLS or spent + est > ceiling:
                raise PackCostCeiling(f"stopped before the {step} step: {spent} cents spent, the next call could cost {est}, the pack ceiling is {ceiling} cents")
            text, cents = call(f"ffm engine pack {step}", model, system, user, max_out)
            spent, calls = spent + int(cents or 0), calls + 1
            try:
                parts[step] = normalise_part(step, extract_json(text))
                break
            except PackInvalid:
                if attempt == 2:
                    raise
                logger.info("ffm engine: %s output did not fit the schema, one repair attempt", step)
    return parts, spent, calls


# ------------------------------------------------------------------------------------------------------------------- database
def _rpc(name: str, args: dict):
    return hq._request("POST", f"/rest/v1/rpc/{name}", args)


def _get(path: str):
    return hq._request("GET", path) or []


def _call(name, args, rpc=None):
    try:
        return (rpc or _rpc)(name, args)
    except urllib.error.HTTPError as e:
        m = _msg(e)
        if "Sensitive data refused" in m:
            raise SensitiveDataRefused(m) from None
        raise RuntimeError(m[:200]) from None


def workspace(slug: str, get=None) -> dict | None:
    if not SLUG.match(slug or ""):
        return None
    rows = (get or _get)(f"/rest/v1/client_workspaces?slug=eq.{slug}&select=id,slug,name,vertical,status,monthly_budget_cents")
    return rows[0] if rows else None


def vocabulary(ws: dict, get=None) -> str:
    """'' for a workspace the classifier screens strictly (mortgage); otherwise the owner-approved words and terms the classifier accepts there."""
    if (ws.get("vertical") or "") == "mortgage":
        return ""
    get = get or _get
    words = [r["word"] for r in get("/rest/v1/ws_marketing_vocab?lang=eq.en&removed_at=is.null&select=word&order=word&limit=5000")]
    terms = [r["term"] for r in get(f"/rest/v1/ws_approved_terms?removed_at=is.null&or=(workspace_id.eq.{ws['id']},vertical.eq.{ws.get('vertical') or 'none'})&select=term&limit=500")]
    return " ".join(words) + ("\nApproved terms: " + "; ".join(terms) if terms else "")


def create(brief: dict, by: str = "owner:telegram", rpc=None, get=None) -> str:
    """Draft workspace (no budget, onboarding checklist instantiated) + the brief. Re-sending a brief for an existing slug of the same vertical
    replaces the brief. Returns the workspace id."""
    ws = workspace(brief["slug"], get)
    if ws:
        if ws.get("vertical") != brief["vertical"]:
            raise BriefError(f"workspace {brief['slug']} exists with vertical {ws.get('vertical')}")
        wid = ws["id"]
    else:
        wid = _call("ffm_engine_create_workspace", {"p_slug": brief["slug"], "p_name": brief["business_name"], "p_vertical": brief["vertical"], "p_by": by}, rpc)
    save_brief(wid, brief, by, rpc)
    return wid


def save_brief(ws_id: str, brief: dict, by: str = "owner:telegram", rpc=None):
    body = {k: brief[k] for k in ("offer", "service_area", "target_customer", "goal", "monthly_budget_stated") if brief.get(k) and brief[k] != "unset"}
    bad = db_screen(ws_id, list(body.values()), rpc)
    if bad:
        keys = [list(body)[i] for i in sorted(bad)]
        raise SensitiveDataRefused("brief fields refused by the database screen: " + ", ".join(keys))
    return _call("ffm_engine_save_brief", {"p_ws": ws_id, "p_brief": body, "p_by": by}, rpc)


def store(ws_id: str, pack: dict, cents: int, model: str, by: str = "ffm-engine", rpc=None) -> dict:
    """Campaign -> 3 ad sets -> creatives (all draft, dry_run), then the pack. A variant whose headline or text was blanked is not written as a creative."""
    camp = _call("ffm_add_campaign", {"p_ws": ws_id, "p_name": CAMPAIGN_NAME, "p_channel": "meta"}, rpc)
    sets = {}
    for i, s in enumerate(pack["ad_sets"]):
        sets[s["angle"]] = _call("ffm_add_ad_set", {"p_ws": ws_id, "p_campaign": camp, "p_name": s["name"] if len(s["name"]) >= 2 else AD_SET_FALLBACK[i],
                                                    "p_audience": s["audience_description"] or None, "p_daily_cents": None}, rpc)
    created, skipped = 0, []
    for v in pack["ad_variants"]:
        if len(v["headline"]) < 2 or len(v["primary_text"]) < 2:
            skipped.append(v["id"])
            continue
        _call("ffm_add_creative", {"p_ws": ws_id, "p_campaign": camp, "p_ad_set": sets[v["angle"]], "p_headline": v["headline"], "p_body": v["primary_text"],
                                   "p_cta": v["cta"] or None}, rpc)
        created += 1
    pack["stored"] = {"ad_sets": len(sets), "creatives": created, "creatives_skipped": skipped}
    saved = _call("ffm_engine_save_pack", {"p_ws": ws_id, "p_vertical": pack["vertical"], "p_pack": pack, "p_campaign": camp,
                                           "p_cost_cents": int(cents), "p_model": model, "p_by": by}, rpc)
    return {**(saved or {}), "creatives": created, "skipped": skipped}


def run_pack(slug: str, *, call=None, estimate=None, rpc=None, get=None, ceiling=None) -> dict:
    """The whole engine for one workspace: brief -> generate -> screen -> store -> owner view. Returns a result dict for the owner."""
    get = get or _get
    ws = workspace(slug, get)
    if not ws:
        raise BriefError(f"no workspace '{slug}'")
    if ws.get("status") not in ("draft", "active"):
        raise BriefError(f"workspace '{slug}' is {ws.get('status')}")
    if ws.get("vertical") not in VERTICALS:
        raise BriefError(f"workspace '{slug}' has vertical {ws.get('vertical')!r}; the engine knows " + ", ".join(VERTICALS))
    rows = get(f"/rest/v1/ffm_engine_briefs?workspace_id=eq.{ws['id']}&select=brief")
    if not rows:
        raise BriefError(f"no brief saved for '{slug}': send /ffm new first")
    brief = validate_brief({"monthly_budget_stated": "unset", **rows[0]["brief"], "business_name": ws["name"], "vertical": ws["vertical"], "slug": slug})
    parts, cents, calls = generate(brief, call=call, estimate=estimate, ceiling=ceiling, vocab=vocabulary(ws, get))
    pack = assemble(brief, parts)
    screened = screen_pack(pack, ws["id"], rpc)
    pack.update({"model": MODEL, "cost_cents": cents, "llm_calls": calls})
    res = store(ws["id"], pack, cents, MODEL, rpc=rpc)
    full = expand(pack, ws["name"])
    return {**res, "slug": slug, "cents": cents, "calls": calls, "screened": len(screened), "pack": full, "html": render_landing_html(full)}


# ------------------------------------------------------------------------------------------------------------------- organic -> hands drafts
def queue_organic(slug: str, account_short: str, *, get=None, submit=None) -> str:
    """Submits the latest pack's posts as hand_actions DRAFTS for one connected account (the owner approves each one in the hands flow).
    Refused while a standing approval covers that account or division: it would skip the owner's per-post approval."""
    import hq_hands
    get = get or _get
    ws = workspace(slug, get)
    if not ws:
        return f"Sir, no workspace '{slug}'."
    acc_id = hq_hands._resolve("hand_accounts", account_short, get)
    if not acc_id:
        return "Sir, I could not find that account (use the id shown by /accounts)."
    acc = (get(f"/rest/v1/hand_accounts?id=eq.{acc_id}&select=id,connector,division,status,handle") or [{}])[0]
    if acc.get("status") != "connected":
        return "Sir, that account is not connected yet (/connect)."
    standing = get("/rest/v1/hand_standing?enabled=eq.true&select=scope_kind,scope_ref") or []
    if any((s["scope_kind"] == "account" and s["scope_ref"] == acc_id) or (s["scope_kind"] == "division" and s["scope_ref"] == acc.get("division")) for s in standing):
        return "Sir, a standing approval covers that account, so posts would skip your per-post approval. I queued nothing. Switch the standing approval off first."
    rows = get(f"/rest/v1/ffm_engine_packs?workspace_id=eq.{ws['id']}&status=eq.draft&select=pack&order=version.desc&limit=1")
    if not rows:
        return f"Sir, no pack for '{slug}' yet: /ffm pack {slug}."
    submit = submit or hq_hands.submit
    n = 0
    for p in rows[0]["pack"].get("organic_calendar", []):
        if not p.get("caption"):
            continue
        text = (p["hook"] + "\n\n" if p.get("hook") else "") + p["caption"]
        r = submit(acc["connector"], acc_id, "post", {"text": text}, None, True, "ffm-engine")
        n += 1 if (r or {}).get("ok") else 0
    return f"Sir, {n} organic posts are drafts in the hands queue for @{acc.get('handle')}. Each one waits for your approval (/queue)."


# ------------------------------------------------------------------------------------------------------------------- owner-facing text
def summary_text(row: dict, full: dict) -> str:
    st = full.get("stored") or {}
    lines = [f"Sir, {full['business_name']} ({full['workspace']}, {full['vertical']}) pack v{row['version']}, {row['status']}, dry run.",
             f"Positioning: {full['positioning']['statement'] or '(blanked by the screen)'}",
             "Angles: " + "; ".join(f"{a['key']} {a['name'] or '(blanked)'}" for a in full["audience_angles"]),
             f"Stored: 1 campaign, {st.get('ad_sets', 0)} ad sets, {st.get('creatives', 0)} creatives (all drafts)"
             + (f"; not written (blanked copy): {', '.join(st['creatives_skipped'])}" if st.get("creatives_skipped") else ""),
             f"Follow-up: {len(full['follow_up'])} templates (nothing sent). Organic: {len(full['organic_calendar'])} posts (/ffm queue {full['workspace']} <account> drafts them).",
             f"Blanked by the privacy screen: {len(full.get('screened_out') or [])} text(s). Cost: {row.get('cost_cents', 0)} cents.",
             "Confirm with the client:"] + [f"- {c}" for c in full["compliance_to_confirm"][:8]] + ["Your actions:"] + [f"- {a}" for a in full["owner_actions"]]
    return "\n".join(lines)


def list_text(get=None) -> str:
    get = get or _get
    ws = get("/rest/v1/client_workspaces?select=id,slug,vertical,status&order=created_at.desc&limit=30")
    if not ws:
        return "Sir, no client workspaces yet. /ffm new to add one."
    packs = get("/rest/v1/ffm_engine_packs?status=eq.draft&select=workspace_id,version")
    latest = {p["workspace_id"]: p for p in packs}
    return "Sir, client workspaces:\n" + "\n".join(
        f"{w['slug']} [{w.get('vertical') or '-'}] {w['status']}" + (f", pack v{latest[w['id']]['version']}" if w["id"] in latest else ", no pack") for w in ws)


# ------------------------------------------------------------------------------------------------------------------- Telegram
def _owner(update) -> bool:
    import hq_core
    return hq_core._is_owner(update)


async def _reply(update, text: str):
    import hq_core
    await hq_core.reply(update, text[:4000])


async def _send_files(update, slug: str, full: dict, page: str):
    import hq_core
    await update.message.reply_document(document=io.BytesIO(json.dumps(full, indent=2, ensure_ascii=False).encode()), filename=f"{slug}-pack.json",
                                        caption=hq_core.address(f"{slug} campaign pack (draft)"))
    await update.message.reply_document(document=io.BytesIO(page.encode()), filename=f"{slug}-landing.html", caption=hq_core.address(f"{slug} landing page (draft, not published)"))


def show(slug: str, get=None):
    get = get or _get
    ws = workspace(slug, get)
    if not ws:
        return None, None
    rows = get(f"/rest/v1/ffm_engine_packs?workspace_id=eq.{ws['id']}&select=version,status,pack,cost_cents&order=version.desc&limit=1")
    return ws, (rows[0] if rows else None)


async def ffm_cmd(update, context) -> None:
    """/ffm new | /ffm pack <slug> | /ffm show <slug> | /ffm list | /ffm queue <slug> <account-id>  (owner only)"""
    if not _owner(update):
        return
    args = list(getattr(context, "args", None) or [])
    sub = (args[0].lower() if args else "")
    try:
        if sub == "new":
            raw = parse_brief(update.message.text or "")
            if not raw:
                return await _reply(update, NEW_HELP)
            brief = validate_brief(raw)
            await asyncio.to_thread(create, brief)
            return await _reply(update, f"Sir, workspace {brief['slug']} is drafted ({brief['vertical']}, budget {brief['monthly_budget_stated']} as stated, not set). "
                                        f"Onboarding checklist created. /ffm pack {brief['slug']} generates the campaign pack (at most {PACK_CEILING_CENTS} cents).")
        if sub == "pack" and len(args) > 1:
            await _reply(update, f"Sir, generating the pack for {args[1]} (cheap model, at most {PACK_CEILING_CENTS} cents). This takes about a minute.")
            r = await asyncio.to_thread(run_pack, args[1].lower())
            await _reply(update, f"Sir, pack v{r.get('version')} for {r['slug']} is stored as drafts: 1 campaign, 3 ad sets, {r['creatives']} creatives, "
                                 f"landing page, 5 follow-ups, 14 organic posts. {r['calls']} model calls, {r['cents']} cents. "
                                 f"{r['screened']} text(s) blanked by the privacy screen. Nothing was published, launched or sent.")
            return await _send_files(update, r["slug"], r["pack"], r["html"])
        if sub == "show" and len(args) > 1:
            ws, row = await asyncio.to_thread(show, args[1].lower())
            if not ws:
                return await _reply(update, f"Sir, no workspace '{args[1]}'.")
            if not row:
                return await _reply(update, f"Sir, no pack yet: /ffm pack {ws['slug']}.")
            full = expand(row["pack"], ws["name"])
            await _reply(update, summary_text(row, full))
            return await _send_files(update, ws["slug"], full, render_landing_html(full))
        if sub == "list":
            return await _reply(update, await asyncio.to_thread(list_text))
        if sub == "queue" and len(args) > 2:
            return await _reply(update, await asyncio.to_thread(queue_organic, args[1].lower(), args[2]))
        import hq_ffm_run     # execution: one owner approval per launch, then Jarvis runs ads, posts, leads and reports
        if sub in hq_ffm_run.SUBCOMMANDS:
            return await _reply(update, await asyncio.to_thread(hq_ffm_run.command, sub, args[1:]))
        if sub == "connectads":
            if len(args) > 1:
                return await _reply(update, await asyncio.to_thread(hq_ffm_run.connect_ads_finish, args[1]))
            return await _reply(update, "Sir, open this, approve with the Facebook login that owns the ad account, then send /ffm connectads <the page address you land on>:\n"
                                        + hq_ffm_run.connect_ads_start())
        return await _reply(update, "Sir, FF Marketing engine: /ffm new (brief), /ffm pack <slug>, /ffm show <slug>, /ffm list, /ffm queue <slug> <account-id>. "
                                    "Execution: /ffm launch <slug> <daily $> <total $> [days], /ffm status <slug>, /ffm stop <slug>, /ffm budget <slug> <daily $> <total $>, "
                                    "/ffm lead <id> replied|booked|stop|lost, /ffm connectads.")
    except BriefError as e:
        await _reply(update, f"Sir, the brief is not usable: {e}.")
    except SensitiveDataRefused as e:
        vocab = "unknown_word" in str(e) or "database screen" in str(e)
        await _reply(update, "Sir, I refused that: it looks like personal or sensitive data, or (outside mortgage workspaces) it uses words that are not in the "
                             "owner-approved marketing vocabulary. Business facts only, in plain words. Nothing was stored or sent to a model."
                     + (f" ({str(e)[:160]})" if vocab else ""))
    except hq_meter.MeterBlocked as e:
        await _reply(update, "Sir, the pack stopped: " + hq_meter.status_reply(e))
    except PackCostCeiling as e:
        await _reply(update, f"Sir, the pack stopped at its cost ceiling ({e}). Nothing was stored. Raise FFM_PACK_CEILING_CENTS (max 30) or try again later.")
    except PackInvalid as e:
        await _reply(update, f"Sir, the model's answer did not fit the pack format ({str(e)[:150]}). Nothing was stored. Try /ffm pack again.")
    except Exception as e:
        logger.exception("ffm engine command failed")
        await _reply(update, f"Sir, the FF Marketing command failed: {str(e)[:150]}")


def register(app, CommandHandler) -> None:
    app.add_handler(CommandHandler("ffm", ffm_cmd))
    import hq_ffm_run
    hq_ffm_run.register(app)      # the execution tick (plain code; nothing runs before an owner-approved launch)
