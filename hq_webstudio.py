"""Web Studio: one pipeline for every website Jarvis makes (each office's site, and Donna's client websites, service line B).

  brief + brand kit --(hq_llm fills CONTENT SLOTS only)--> sites/<slug>/site.json --(pull request, versioned)--> build (vetted template)
  --> QA --> Netlify preview (hands 'deploy', draft) --> owner approves in Telegram --> publish (hands 'deploy', production) --> domain (owner)

Design rules:
- **Layout is the template's.** The model never writes HTML, CSS or layout: it returns JSON for the slots in SLOT_KEYS, validated here.
  The spacing, type scale and motion come from the curated template (TEMPLATES), and art direction comes from the brand kit (palette, variant).
- **Prices are the owner's.** Package prices come from the brief or brand kit, never from the model. A draft or an edit that changes a price
  is refused.
- **Content rules apply to every site** (validate + qa_dist):
  - no testimonials, reviews, client counts or logos; empty case-study slots only;
  - no guarantee or refund wording;
  - no AI clichés;
  - no HTML in copy;
  - the CASL form wording is fixed here (CONSENT), not by the model;
  - privacy and terms are placeholders flagged for the owner.
- **Nothing goes live by itself.**
  - A draft or an edit is a pull request (hq_dev); the owner merges it.
  - A preview or a publish is a hands 'deploy' action, which the owner approves in Telegram before it runs.
  - The domain is the owner's step.

CLI (local and CI):  python3 hq_webstudio.py build <slug> [--out DIR]   |   python3 hq_webstudio.py check <slug>
"""
import argparse
import copy
import html
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import zipfile

ROOT = os.path.dirname(os.path.abspath(__file__))
SITES = os.path.join(ROOT, "sites")
SLUG = re.compile(r"^[a-z][a-z0-9-]{1,40}$")
HEX = re.compile(r"^#[0-9a-fA-F]{6}$")
SAFE_NAME = re.compile(r"^[A-Za-z0-9][A-Za-z0-9 .&'-]{0,40}$")
TEMPLATES = {
    "astrowind": {
        "path": "sites/_templates/astrowind", "upstream": "https://github.com/onwidget/astrowind", "commit": "14e1a691f80548dcc36370847b1a02c0d0b12821",
        "license": "MIT", "variants": ("futuristic", "local"),
        "about": "AstroWind (Astro 7 + Tailwind 4), with the Web Studio art-direction layer: futuristic (dark, glow, glass, voice-orb hero, call demo "
                 "panel, scroll reveals; all motion off under prefers-reduced-motion) or local (the template's own light/dark look)."},
}
SLOT_KEYS = ("meta", "hero", "demo", "services", "steps", "offer", "faq", "contact", "results")
CONSENT_VERSION = "webstudio-consent-v1"
CLICHES = [r"\bunlock", r"revolution", r"\bseamless", r"\belevate", r"fast[- ]paced world", r"game[- ]chang", r"cutting[- ]edge", r"supercharg",
           r"\bempower", r"\bharness", r"\bleverag", r"next[- ]level", r"\bsynerg", r"\bdelve", r"\btapestry", r"\bunleash", r"\bstreamline",
           r"world[- ]class", r"state[- ]of[- ]the[- ]art", r"\brobust\b", r"in today'?s", r"look no further"]
CLAIMS = [r"\bguarantee", r"\brefund", r"risk[- ]free", r"money[- ]back", r"\b100\s*%", r"testimonial", r"\b(customer|client|google|yelp|5[- ]star|five[- ]star)\s+reviews?\b",
          r"\d[\d,]*\s*\+?\s*(happy\s+|satisfied\s+)?(clients|customers|businesses)\b", r"trusted by", r"as seen (on|in)", r"award[- ]winning", r"#1\b", r"\bbest in\b"]
LEFTOVERS = [r"astrowind", r"arthelokyo", r"lorem ipsum", r"\bstars? on github"]
ICON = re.compile(r"^tabler:[a-z0-9-]{1,40}$")


class StudioError(Exception):
    pass


def consent(site: dict) -> dict:
    """The CASL wording every Web Studio form shows (fixed here; the model never writes it). The brand name and legal contact come from site.json."""
    b = site["brand"]["name"]
    return {"version": CONSENT_VERSION, "form_name": f"{site['slug']}-contact",
            "inquiry_notice": f"By sending this form you ask {b} to contact you about your inquiry by phone, text or email. We use your details only to answer it.",
            "marketing_checkbox": f"Yes, {b} may also send me occasional emails or texts about its services. I can unsubscribe at any time.",
            "sender": f"{b}, {site['brand'].get('city', '')}, {site['brand'].get('region', '')}. Contact: {(site.get('legal') or {}).get('contact', '[OWNER: contact]')}"}


def _strings(x, path=""):
    if isinstance(x, str):
        yield path, x
    elif isinstance(x, dict):
        for k, v in x.items():
            yield from _strings(v, f"{path}.{k}" if path else k)
    elif isinstance(x, list):
        for i, v in enumerate(x):
            yield from _strings(v, f"{path}[{i}]")


def copy_problems(text: str) -> list[str]:
    out = []
    for rx in CLAIMS:
        if re.search(rx, text, re.I):
            out.append(f"claim not allowed /{rx}/")
    for rx in CLICHES:
        if re.search(rx, text, re.I):
            out.append(f"AI cliché /{rx}/")
    return out


def prices(site: dict) -> list:
    return [(g.get("id"), i.get("title"), i.get("price"), i.get("note")) for g in site.get("pricing") or [] for i in g.get("items") or []]


def validate(site: dict) -> list[str]:
    """Problems with a site.json (empty = valid). Run on every draft, edit and build."""
    p = []
    if not isinstance(site, dict):
        return ["site.json must be an object"]
    if not SLUG.match(str(site.get("slug") or "")):
        p.append("slug must be lowercase letters, digits and dashes")
    if not isinstance(site.get("version"), int) or site["version"] < 1:
        p.append("version must be a positive integer")
    t = TEMPLATES.get(site.get("template"))
    if not t:
        p.append(f"unknown template {site.get('template')!r} (library: {', '.join(TEMPLATES)})")
    elif site.get("variant") not in t["variants"]:
        p.append(f"variant must be one of {', '.join(t['variants'])}")
    b = site.get("brand") or {}
    if not SAFE_NAME.match(str(b.get("name") or "")):
        p.append("brand.name: letters, digits, spaces and . & ' - only (max 41)")
    for k in ("primary", "accent"):
        if not HEX.match(str(b.get(k) or "")):
            p.append(f"brand.{k} must be a #rrggbb colour")
    links = site.get("links") or {}
    bk = str(links.get("booking") or "")
    if bk and not (bk == "#contact" or re.match(r"^https://[A-Za-z0-9.-]+(/[A-Za-z0-9._~/-]*)?$", bk)):
        p.append("links.booking must be #contact or an https link")
    if links.get("demo_phone") and not re.fullmatch(r"\+?[0-9 ()-]{7,20}", str(links["demo_phone"])):
        p.append("links.demo_phone must be a phone number")
    for k in ("meta", "hero", "services", "steps", "contact", "legal"):
        if not isinstance(site.get(k), dict):
            p.append(f"{k} is missing")
    demo = site.get("demo")
    if demo is not None and "illustration" not in str((demo or {}).get("label", "")).lower():
        p.append("demo.label must say it is an illustration (not a real customer)")
    if any(k in site for k in ("testimonials", "reviews", "clients", "logos", "stats")):
        p.append("testimonials, reviews, client lists, logos and stats are not allowed (empty case-study slots only)")
    for item in (site.get("services") or {}).get("items") or []:
        if item.get("icon") and not ICON.match(str(item["icon"])):
            p.append(f"icon {item['icon']!r} must be tabler:<name>")
    for path, s in _strings({k: v for k, v in site.items() if k not in ("owner_review",)}):
        if "<" in s or ">" in s or "javascript:" in s.lower():
            p.append(f"{path}: no HTML or scripts in copy")
        if path.startswith(("legal", "links", "brand.primary", "brand.accent")):
            continue
        for why in copy_problems(s):
            p.append(f"{path}: {why}")
    return p


# ------------------------------------------------------------------------------------------------------------------- the model fills slots
SLOT_PROMPT = """You write website copy for a small business. Return ONLY a JSON object with these keys: {keys}.
Match the shapes in the EXAMPLE exactly (same keys, same nesting; lists may be shorter or longer). Plain text only: no HTML, no markdown.
Tone: confident, specific, short. Concrete nouns and verbs. No clichés (never: unlock, revolutionize, seamless, elevate, empower, leverage,
cutting-edge, game-changing, "in today's fast-paced world"). No testimonials, reviews, client counts, ratings, guarantees or refunds.
Never invent prices, numbers of clients or results. demo.label must say it is an illustration, not a real customer.
Icons are tabler:<name> (e.g. tabler:phone-call)."""


def _json_from(text: str) -> dict:
    m = re.search(r"\{.*\}", text or "", re.S)
    if not m:
        raise StudioError("the model returned no JSON")
    try:
        return json.loads(m.group(0))
    except ValueError as e:
        raise StudioError(f"the model returned broken JSON ({e})") from None


def _merge_slots(site: dict, slots: dict, keys=SLOT_KEYS) -> dict:
    out = copy.deepcopy(site)
    for k, v in (slots or {}).items():
        if k not in keys:
            continue                                   # layout, brand, prices, legal and consent are never the model's
        if k == "results" and isinstance(v, dict):
            out.setdefault("results", {})["content"] = str(v.get("content") or out.get("results", {}).get("content") or "")
            continue
        out[k] = v
    return out


def _complete(system, user, complete=None):
    import hq_llm
    complete = complete or hq_llm.complete
    r = complete(system, [{"role": "user", "content": user}], division="jarvis", task_class="webstudio.copy", tier="medium", max_output=1800,
                 sources=["owner_chat"], purpose_text="web studio copy", job="chat")
    return r.get("text") or ""


def skeleton(slug: str, office: str, template: str, variant: str, brand: dict, pricing: list | None = None, legal: dict | None = None) -> dict:
    return {"schema": 1, "slug": slug, "version": 1, "office": office, "template": template, "variant": variant, "brand": dict(brand),
            "meta": {"title": brand.get("name", ""), "description": ""}, "links": {"booking": "#contact", "booking_is_placeholder": True, "demo_phone": ""},
            "hero": {"tagline": "", "title": "", "title_accent": "", "subtitle": ""}, "services": {"tagline": "", "title": "", "items": []},
            "steps": {"title": "How it works", "items": []}, "pricing": pricing or [], "results": {"title": "Client results", "content": "", "slots": 3},
            "faq": [], "contact": {"title": "Contact us", "subtitle": ""},
            "legal": legal or {"entity": "[OWNER: legal entity name]", "contact": "[OWNER: business mailing address and email before launch]"},
            "owner_review": ["Privacy policy and terms are placeholders for owner and counsel review.", "Booking link and phone are placeholders."]}


def example() -> dict:
    with open(os.path.join(SITES, "donna", "site.json"), encoding="utf-8") as f:
        ex = json.load(f)
    return {k: ex[k] for k in SLOT_KEYS if k in ex}


def draft(slug, office, template, variant, brand: dict, brief: str, pricing: list | None = None, complete=None) -> dict:
    """A new site.json: the skeleton (brand, owner prices, legal placeholders) plus the model's copy for the slots. Raises StudioError."""
    site = skeleton(slug, office, template, variant, brand, pricing)
    problems = [x for x in validate(site) if not x.startswith(("meta", "hero", "services", "steps", "contact"))]
    if problems:
        raise StudioError("; ".join(problems))
    system = SLOT_PROMPT.format(keys=", ".join(SLOT_KEYS)) + "\nEXAMPLE:\n" + json.dumps(example(), ensure_ascii=False)
    user = f"Business: {brand.get('name')} in {brand.get('city', '')}. Brief:\n{brief}"
    site = _merge_slots(site, _json_from(_complete(system, user, complete)))
    if prices(site) != prices(skeleton(slug, office, template, variant, brand, pricing)):
        raise StudioError("the model changed a price")
    problems = validate(site)
    if problems:
        raise StudioError("the draft breaks the content rules: " + "; ".join(problems[:8]))
    return site


def edit(site: dict, instruction: str, complete=None) -> dict:
    """A new version of the site: the model returns only the slots it changes ("change the hero text"). Prices and layout cannot change."""
    current = {k: site[k] for k in SLOT_KEYS if k in site}
    system = SLOT_PROMPT.format(keys="only the keys you change, from " + ", ".join(SLOT_KEYS)) + "\nCURRENT:\n" + json.dumps(current, ensure_ascii=False)
    new = _merge_slots(site, _json_from(_complete(system, f"Change request: {instruction}", complete)))
    if prices(new) != prices(site):
        raise StudioError("the model changed a price")
    if new == site:
        raise StudioError("the change request changed nothing")
    new["version"] = int(site["version"]) + 1
    problems = validate(new)
    if problems:
        raise StudioError("the edit breaks the content rules: " + "; ".join(problems[:8]))
    return new


# ------------------------------------------------------------------------------------------------------------------- build + QA
def load(slug: str) -> dict:
    if not SLUG.match(slug or ""):
        raise StudioError("bad slug")
    with open(os.path.join(SITES, slug, "site.json"), encoding="utf-8") as f:
        return json.load(f)


def config_yaml(site: dict) -> str:
    m, b = site["meta"], site["brand"]
    theme = "dark:only" if site["variant"] == "futuristic" else "system"
    q = lambda s: json.dumps(str(s), ensure_ascii=False)       # noqa: E731  (JSON strings are valid YAML scalars)
    return (f"site:\n  name: {q(b['name'])}\n  site: 'https://example.invalid'\n  base: '/'\n  trailingSlash: false\n  googleSiteVerificationId: null\n"
            f"metadata:\n  title:\n    default: {q(m['title'])}\n    template: {q('%s | ' + b['name'])}\n  description: {q(m.get('description', ''))}\n"
            f"  robots:\n    index: true\n    follow: true\n  openGraph:\n    site_name: {q(b['name'])}\n    images:\n      - url: '~/assets/images/default.png'\n"
            f"        width: 1200\n        height: 628\n    type: website\ni18n:\n  language: en-CA\n  textDirection: ltr\n"
            "apps:\n  blog:\n    isEnabled: false\n    postsPerPage: 8\n    post: {isEnabled: false, permalink: '/%slug%', robots: {index: false}}\n"
            "    list: {isEnabled: false, pathname: 'blog', robots: {index: false}}\n    category: {isEnabled: false, pathname: 'category', robots: {index: false}}\n"
            "    tag: {isEnabled: false, pathname: 'tag', robots: {index: false}}\n    isRelatedPostsEnabled: false\n    relatedPostsCount: 4\n"
            f"analytics:\n  vendors:\n    googleAnalytics:\n      id: null\nui:\n  theme: '{theme}'\n")


def stage(site: dict, out: str) -> str:
    """Copy the template to out/ and write the site's data and config. No network, no code from the site."""
    problems = validate(site)
    if problems:
        raise StudioError("; ".join(problems))
    src = os.path.join(ROOT, TEMPLATES[site["template"]]["path"])
    shutil.copytree(src, out, ignore=shutil.ignore_patterns("node_modules", "dist", ".astro"), dirs_exist_ok=True)
    with open(os.path.join(out, "src", "data", "site.json"), "w", encoding="utf-8") as f:
        json.dump({**site, "consent": consent(site)}, f, ensure_ascii=False, indent=1)
    with open(os.path.join(out, "src", "config.yaml"), "w", encoding="utf-8") as f:
        f.write(config_yaml(site))
    return out


def build(slug: str, out: str | None = None, run=subprocess.run) -> dict:
    """Stage, install (lockfile, no install scripts), build and QA. -> {'dist', 'zip', 'problems', 'owner_review'}."""
    site = load(slug)
    out = out or tempfile.mkdtemp(prefix=f"webstudio-{slug}-")
    stage(site, out)
    for cmd in (["npm", "ci", "--ignore-scripts", "--no-audit", "--no-fund", "--loglevel=error"],    # the template's lockfile, no install scripts
                ["npx", "--no-install", "astro", "build"]):
        try:
            run(cmd, cwd=out, check=True, capture_output=True, text=True)
        except subprocess.CalledProcessError as e:
            raise StudioError(f"{' '.join(cmd[:3])} failed: {((e.stdout or '') + (e.stderr or ''))[-1500:]}") from None
    dist = os.path.join(out, "dist")
    problems, review = qa_dist(dist, site)
    z = os.path.join(out, f"{slug}-v{site['version']}.zip")
    with zipfile.ZipFile(z, "w", zipfile.ZIP_DEFLATED) as zf:
        for base, _, files in os.walk(dist):
            for n in files:
                full = os.path.join(base, n)
                zf.write(full, os.path.relpath(full, dist))
    return {"dist": dist, "zip": z, "problems": problems, "owner_review": review}


PAGES = ("index.html", "privacy/index.html", "terms/index.html", "thanks/index.html", "404.html")


def qa_dist(dist: str, site: dict) -> tuple[list[str], list[str]]:
    """QA of the built pages. -> (problems that block a preview, items the owner must clear before a publish)."""
    out, review = [], []
    c = consent(site)
    pages = {}
    for p in PAGES:
        f = os.path.join(dist, p)
        if not os.path.exists(f):
            out.append(f"missing page {p}")
            continue
        with open(f, encoding="utf-8") as fh:
            pages[p] = fh.read()
    for p, t in pages.items():
        for m in re.finditer(r"<script\b[^>]*\bsrc\s*=\s*\"?([^\"\s>]+)", t, re.I):
            if not m.group(1).startswith("/") or m.group(1).startswith("//"):
                out.append(f"{p}: external script {m.group(1)}")
        if re.search(r"<iframe\b", t, re.I):
            out.append(f"{p}: iframe")
        for m in re.finditer(r"<(?:img|link|source|video|audio)\b[^>]*\b(?:src|href)\s*=\s*\"?(https?:)?//([^\"\s>/]+)", t, re.I):
            if m.group(2) != "example.invalid":
                out.append(f"{p}: remote asset from {m.group(2)}")
        visible = re.sub(r"<(script|style)\b.*?</\1>", " ", t, flags=re.S | re.I)
        text = html.unescape(re.sub(r"<[^>]+>", " ", visible))
        out += [f"{p}: {why}" for why in copy_problems(text)]
        out += [f"{p}: template leftover /{rx}/" for rx in LEFTOVERS if re.search(rx, text, re.I)]
        title = re.search(r"<title>([^<]*)</title>", t)
        if not title or site["brand"]["name"] not in html.unescape(title.group(1)):
            out.append(f"{p}: title without the brand name")
        if "[OWNER:" in text and p not in ("privacy/index.html", "terms/index.html"):
            review.append(f"{p}: has an [OWNER: ...] placeholder")
    idx = pages.get("index.html", "")
    if not any("width=device-width" in m for m in re.findall(r"<meta\b[^>]*viewport[^>]*>", idx)):
        out.append("index.html: no mobile viewport meta")
    form = re.search(r"<form\b[^>]*>.*?</form>", idx, re.S | re.I)
    if not form:
        out.append("index.html: no contact form")
    else:
        f = form.group(0)
        head = re.match(r"<form\b[^>]*>", f).group(0)
        if f'name="{c["form_name"]}"' not in head or 'data-netlify="true"' not in head or 'method="POST"' not in head:
            out.append("contact form is not the same-site Netlify form")
        if re.search(r"action\s*=\s*\"?\s*(https?:)?//", head, re.I):
            out.append("contact form posts to another site")
        if 'netlify-honeypot="bot-field"' not in head or 'name="bot-field"' not in f:
            out.append("contact form has no honeypot")
        ftext = html.unescape(re.sub(r"\s+", " ", re.sub(r"<[^>]+>", " ", f)))
        for k in ("inquiry_notice", "marketing_checkbox"):
            if c[k] not in ftext:
                out.append(f"contact form does not show the consent wording '{k}' verbatim")
        box = re.search(r"<input\b[^>]*name=\"marketing_consent\"[^>]*>", f)
        if not box or re.search(r"\b(checked|required)\b", box.group(0)):
            out.append("marketing consent box must exist, unticked and optional")
        if f'value="{c["version"]}"' not in f:
            out.append("contact form does not carry the consent wording version")
    for p in ("privacy/index.html", "terms/index.html"):
        if p in pages and "DRAFT PLACEHOLDER" not in pages[p]:
            out.append(f"{p}: owner-review banner missing")
        elif p in pages:
            review.append(f"{p}: placeholder legal text (owner and counsel)")
    if (site.get("links") or {}).get("booking_is_placeholder"):
        review.append("booking link is a placeholder")
    review += list(site.get("owner_review") or [])
    return out, review


# ------------------------------------------------------------------------------------------------------------------- PRs, preview, publish
def site_file(site: dict) -> dict:
    return {"path": f"sites/{site['slug']}/site.json", "content": json.dumps(site, ensure_ascii=False, indent=2) + "\n"}


def propose(site: dict, what: str, propose_change=None) -> str:
    """The site (or its new version) as a pull request: the owner merges it. Nothing is published."""
    if propose_change is None:
        import hq_dev
        propose_change = hq_dev.propose_change
    problems = validate(site)
    if problems:
        return "Refused: " + "; ".join(problems[:8])
    return propose_change(f"Web Studio: {site['slug']} v{site['version']} {what}"[:80],
                          f"Web Studio {what} for {site['brand']['name']} (office {site.get('office')}), template {site['template']}/{site['variant']}, "
                          f"version {site['version']}. Content slots only; prices, consent wording and layout unchanged by the model.", [site_file(site)])


def zip_url(site: dict, env=None) -> str:
    base = ((env if env is not None else os.environ).get("JARVIS_WEBSTUDIO_ZIP_BASE") or "").strip().rstrip("/")
    if not base.startswith("https://"):
        raise StudioError("JARVIS_WEBSTUDIO_ZIP_BASE (https, where the CI build uploads <slug>-v<version>.zip) is not set")
    return f"{base}/{site['slug']}-v{site['version']}.zip"


def deploy(site: dict, publish: bool, accounts=None, submit=None, env=None) -> str:
    """Queue a Netlify deploy through the hands connector: a draft (preview URL) or a production publish. The owner approves it in Telegram first."""
    import hq_hands
    accounts = accounts or (lambda: hq_hands._rest("GET", "/rest/v1/hand_accounts?connector=eq.netlify&status=eq.active&select=id,handle&limit=50") or [])
    submit = submit or hq_hands.submit
    acct = next((a for a in accounts() if a.get("handle") == site["slug"]), None)
    if not acct:
        return f"No Netlify site connected for {site['slug']}. /connect netlify <division> with the handle {site['slug']} first."
    r = submit("netlify", acct["id"], "deploy", {"zip_url": zip_url(site, env), "draft": not publish, "site_version": site["version"],
                                                "caption": f"{'Publish' if publish else 'Preview'} {site['brand']['name']} v{site['version']}"}, ai_generated=True)
    if not r.get("ok", True) or r.get("reason"):
        return f"Refused: {r.get('reason') or 'the hands queue refused it'}"
    return (f"{'Publish' if publish else 'Preview'} of {site['slug']} v{site['version']} queued for your approval (hands). "
            + ("It goes live on approval." if publish else "Approve it to get a Netlify preview link."))


def list_sites() -> list[dict]:
    out = []
    for n in sorted(os.listdir(SITES)) if os.path.isdir(SITES) else []:
        f = os.path.join(SITES, n, "site.json")
        if not n.startswith("_") and os.path.exists(f):
            with open(f, encoding="utf-8") as fh:
                s = json.load(fh)
            out.append({"slug": s.get("slug"), "version": s.get("version"), "office": s.get("office"), "template": f"{s.get('template')}/{s.get('variant')}",
                        "brand": (s.get("brand") or {}).get("name")})
    return out


# ------------------------------------------------------------------------------------------------------------------- /site (owner)
USAGE = ("Web Studio:\n/site list\n/site new <slug> <office> <template>/<variant> <Brand name> | <city> | <#primary> <#accent> | <brief>\n"
         "/site edit <slug> | <change request>\n/site preview <slug>\n/site publish <slug>\n/site leads <slug>  (import new form submissions into the CRM)")


def command_text(args: list[str], complete=None, propose_change=None, deploy_fn=None, leads_fn=None) -> str:
    verb = (args[0] if args else "").lower()
    rest = " ".join(args[1:])
    try:
        if verb == "list":
            rows = list_sites()
            return "Sites:\n" + "\n".join(f"{r['slug']} v{r['version']} [{r['office']}] {r['template']}: {r['brand']}" for r in rows) if rows else "No sites yet."
        if verb == "new":
            head, *parts = [x.strip() for x in rest.split("|")]
            w = head.split()
            if len(w) < 4 or len(parts) < 3 or "/" not in w[2]:
                return USAGE
            template, variant = w[2].split("/", 1)
            colours = parts[1].split()
            brand = {"name": " ".join(w[3:]), "city": parts[0], "region": "Ontario", "primary": colours[0] if colours else "", "accent": colours[1] if len(colours) > 1 else ""}
            site = draft(w[0], w[1], template, variant, brand, parts[2], complete=complete)
            return propose(site, "new site", propose_change)
        if verb == "edit":
            slug, _, instruction = rest.partition("|")
            if not instruction.strip():
                return USAGE
            site = edit(load(slug.strip()), instruction.strip(), complete=complete)
            return propose(site, "edit: " + instruction.strip()[:40], propose_change)
        if verb == "leads":
            return (leads_fn or pull_leads)(load(rest.strip()))
        if verb in ("preview", "publish"):
            return (deploy_fn or deploy)(load(rest.strip()), publish=verb == "publish")
    except (StudioError, OSError, ValueError) as e:
        return f"Web Studio: {e}"
    return USAGE


async def site_cmd(update, context) -> None:
    import asyncio
    import hq_core
    if not hq_core._is_owner(update):
        return
    text = await asyncio.to_thread(command_text, list(context.args or []))
    await hq_core.reply_to(update.message, text)


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description="Web Studio build / check")
    ap.add_argument("verb", choices=("build", "check"))
    ap.add_argument("slug")
    ap.add_argument("--out")
    a = ap.parse_args(argv)
    site = load(a.slug)
    if a.verb == "check":
        probs = validate(site)
        for x in probs:
            print("PROBLEM:", x)
        print(f"webstudio check {a.slug}: {len(probs)} problem(s)")
        return 1 if probs else 0
    r = build(a.slug, a.out)
    for x in r["problems"]:
        print("PROBLEM:", x)
    for x in r["owner_review"]:
        print("OWNER REVIEW:", x)
    print(f"webstudio build {a.slug} v{site['version']}: {len(r['problems'])} problem(s), zip {r['zip']}")
    return 1 if r["problems"] else 0


if __name__ == "__main__":
    sys.exit(main())


# ------------------------------------------------------------------------------------------------------------------- form leads -> CRM
def wording_sha256(c: dict) -> str:
    import hashlib
    return hashlib.sha256((c["inquiry_notice"] + "\n" + c["marketing_checkbox"]).encode()).hexdigest()


def lead_from_submission(sub: dict, site: dict) -> dict | None:
    """A Netlify form submission -> a leads row, or None (wrong form, honeypot filled, no way to reply). Consent is recorded as stated:
    the inquiry itself (CASL implied consent, to answer it) and the optional marketing box, with the wording version and its hash."""
    c = consent(site)
    d = sub.get("data") or {}
    if (sub.get("form_name") or d.get("form-name")) != c["form_name"] or (d.get("bot-field") or "").strip():
        return None
    name = str(d.get("name") or "").strip()[:120]
    phone, email = str(d.get("phone") or "").strip()[:40], str(d.get("email") or "").strip()[:200]
    if not name or not (phone or email):
        return None
    marketing = str(d.get("marketing_consent") or "").lower() in ("yes", "on", "true")
    when = str(sub.get("created_at") or "")[:40]
    basis = (f"website inquiry {when} via {site['slug']} form: implied consent to answer the inquiry (CASL); express marketing consent: "
             f"{'YES (box ticked)' if marketing else 'no'}; wording {d.get('consent_version') or c['version']} sha256 {wording_sha256(c)[:16]}")
    note = " | ".join(x for x in (str(d.get("business") or "").strip()[:160], str(d.get("message") or "").strip()[:1500]) if x)
    return {"name": name, "phone": phone or None, "email": email or None, "source": f"website:{site['slug']}", "status": "new",
            "consent_basis": basis, "do_not_contact": False, "notes": (note + f" [ref netlify:{sub.get('id')}]").strip()}


def import_leads(site: dict, submissions: list, venture_id: str, get, post) -> str:
    """Save new form submissions as leads (idempotent on the Netlify submission id). Suppression and DNC triggers on leads still apply;
    nothing is sent: follow-up goes through the normal outbox drafts and owner approval."""
    added = skipped = 0
    for sub in submissions or []:
        lead = lead_from_submission(sub, site)
        sid = re.sub(r"[^A-Za-z0-9]", "", str(sub.get("id") or ""))
        if not lead or not sid:
            skipped += 1
            continue
        if get(f"/rest/v1/leads?source=eq.website:{site['slug']}&notes=like.*netlify:{sid}*&select=id&limit=1"):
            skipped += 1
            continue
        post("/rest/v1/leads", {**lead, "venture_id": venture_id})
        added += 1
    return f"{site['brand']['name']} website: {added} new lead(s) saved, {skipped} skipped (already saved, spam or no contact)."


def pull_leads(site: dict, http=None) -> str:
    """Read the site's Netlify form submissions with the connected account's token (hands vault) and import them."""
    import hq
    import hq_commands
    import hq_hands
    import hq_hands_adapters as A
    rows = hq_hands._rest("GET", "/rest/v1/hand_accounts?connector=eq.netlify&status=eq.active&select=id,handle,external_id,token_vault_ref&limit=50") or []
    acct = next((a for a in rows if a.get("handle") == site["slug"]), None)
    if not acct:
        return f"No Netlify site connected for {site['slug']}."
    vid, _ = hq_commands._venture_id(site.get("office") or site["slug"])
    if not vid:
        return f"No venture for office {site.get('office')!r}: leads need one."
    token = hq_hands._load_token(acct.get("token_vault_ref"))["api_key"]
    st, body, _ = (http or A.http)("GET", f"https://api.netlify.com/api/v1/sites/{acct['external_id']}/submissions?per_page=100",
                                   headers={"Authorization": "Bearer " + token})
    if st != 200 or not isinstance(body, list):
        return f"Netlify submissions could not be read (HTTP {st})."
    return import_leads(site, body, vid, lambda path: hq._request("GET", path), lambda path, row: hq._request("POST", path, row, prefer="return=minimal"))
