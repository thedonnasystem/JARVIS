"""Venture websites as pull requests (static sites only).

An agent drafts a static site (HTML/CSS/SVG/text). It lands as a PR under sites/<venture-slug>/ for the owner to merge; nothing is
published automatically. Publishing is a later, separate step (a static host pointed at sites/<slug>/) and stays a yellow, live-only
action in the permission policy ('deploy_website'). Checks here keep drafts safe by default: no external scripts, no iframes, no
redirects, no forms that post to other sites, no credentials."""
import re

import hq_dev

ALLOWED_EXT = (".html", ".css", ".svg", ".txt", ".xml", ".webmanifest")
MAX_SITE_FILES = 5
_SLUG = re.compile(r"^[a-z][a-z0-9-]{1,40}$")
_EXTERNAL_SCRIPT = re.compile(r"<script[^>]+src\s*=\s*[\"']?\s*(?:https?:)?//", re.I)
_BAD = [
    (re.compile(r"<iframe", re.I), "iframes are not allowed"),
    (re.compile(r"<meta[^>]+http-equiv\s*=\s*[\"']?refresh", re.I), "meta refresh redirects are not allowed"),
    (re.compile(r"<form[^>]+action\s*=\s*[\"']?\s*(?:https?:)?//", re.I), "forms may not post to another site"),
    (re.compile(r"type\s*=\s*[\"']?password", re.I), "no password fields"),
    (_EXTERNAL_SCRIPT, "no external scripts"),
]


def check_site(slug: str, files: list[dict]) -> tuple[list[dict], list[str]]:
    """-> (files re-pathed under sites/<slug>/, problems)."""
    slug = (slug or "").strip().lower()
    if not _SLUG.match(slug):
        return [], ["Venture slug must be lowercase letters, digits and dashes."]
    if not files or len(files) > MAX_SITE_FILES:
        return [], [f"Send 1 to {MAX_SITE_FILES} files."]
    problems: list[str] = []
    out: list[dict] = []
    has_index = False
    for f in files:
        name = str((f or {}).get("path") or "").strip().lstrip("/")
        content = (f or {}).get("content")
        if not name or ".." in name.split("/") or "/" in name or not isinstance(content, str):
            problems.append(f"{name or '(no name)'}: use a plain file name, no folders.")
            continue
        if not name.lower().endswith(ALLOWED_EXT):
            problems.append(f"{name}: type not allowed (html, css, svg, txt, xml only).")
            continue
        for rx, msg in _BAD:
            if rx.search(content):
                problems.append(f"{name}: {msg}.")
        if name == "index.html":
            has_index = True
            if not re.search(r"<title>\s*\S", content, re.I):
                problems.append("index.html needs a <title>.")
        out.append({"path": f"sites/{slug}/{name}", "content": content})
    if not has_index and not problems:
        problems.append("A site needs an index.html.")
    return out, problems


def propose_site(venture_slug: str, title: str, rationale: str, files: list[dict]) -> str:
    clean, problems = check_site(venture_slug, files)
    if problems:
        return "Refused: " + " ".join(problems)
    return hq_dev.propose_change(f"Website draft: {title}", rationale, clean)
