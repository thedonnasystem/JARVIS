"""
Self-service development, safely (Section 11). Jarvis can propose changes to his own code as a pull request:
new branch -> files committed -> PR opened. He never pushes to the deploy branch and never merges. The owner merges
(Railway then redeploys; rollback = revert the PR). Paths that control money, permissions, spend, identity and the
database are PROTECTED: a PR touching them is labelled so and must be read carefully before merging.

Needs GITHUB_TOKEN (fine-grained, this repo only: contents + pull requests write) and GITHUB_REPO=owner/name.
Without them every call returns a plain "not set up" message. Secrets are never committed: content is scanned first.
"""

from __future__ import annotations

import base64
import json
import logging
import os
import re
import time
import urllib.error
import urllib.request

logger = logging.getLogger(__name__)

API = "https://api.github.com"
BASE_BRANCH = os.environ.get("GITHUB_BASE_BRANCH", "overnight-build")
MAX_FILES = 5
MAX_BYTES = 60_000
PROTECTED = ("hq_policy.py", "hq_capital.py", "hq_meter.py", "hq_bank.py", "hq_dev.py", "hq_web.py", "migrations/", ".env", "Procfile",
             "requirements.txt", "test_hq_policy.py", "test_hq_capital.py", "test_hq_meter.py", "test_hq_bank.py")
BLOCKED = (".env", ".git/", "id_rsa", ".pem", ".key")
SECRET_PATTERNS = [re.compile(p) for p in (
    r"sk-ant-[A-Za-z0-9_\-]{20,}", r"sb_secret_[A-Za-z0-9_\-]{10,}", r"eyJ[A-Za-z0-9_\-]{20,}\.[A-Za-z0-9_\-]{20,}\.[A-Za-z0-9_\-]{10,}",
    r"ghp_[A-Za-z0-9]{30,}", r"github_pat_[A-Za-z0-9_]{30,}", r"\b\d{9}:[A-Za-z0-9_\-]{30,}\b", r"-----BEGIN [A-Z ]*PRIVATE KEY-----")]


def configured() -> bool:
    return bool(os.environ.get("GITHUB_TOKEN") and os.environ.get("GITHUB_REPO"))


def _call(method: str, path: str, body: dict | None = None):
    req = urllib.request.Request(f"{API}/repos/{os.environ['GITHUB_REPO']}{path}", method=method,
                                 data=json.dumps(body).encode() if body is not None else None)
    req.add_header("Authorization", f"Bearer {os.environ['GITHUB_TOKEN']}")
    req.add_header("Accept", "application/vnd.github+json")
    req.add_header("User-Agent", "fendezy-jarvis")
    with urllib.request.urlopen(req, timeout=30) as r:
        raw = r.read()
        return json.loads(raw) if raw else None


# Dependencies Jarvis may add (spec 11: approved dependencies only). Anything else needs the owner to edit requirements.txt himself.
APPROVED_DEPS = {"anthropic", "python-telegram-bot", "python-dotenv", "claude-agent-sdk", "psycopg2-binary", "bitwarden-sdk", "pywebpush",
                 "requests", "httpx", "aiohttp", "pydantic", "python-dateutil", "pytz", "tzdata", "beautifulsoup4", "lxml", "jinja2",
                 "pandas", "numpy", "openpyxl", "pypdf", "pillow", "feedparser", "markdown", "tenacity", "cachetools"}


def bad_dependencies(content: str) -> list[str]:
    out = []
    for line in content.splitlines():
        line = line.split("#", 1)[0].strip()
        if not line or line.startswith(("-", "git+", "http")):
            if line:
                out.append(line[:60])  # options, VCS and URL installs are never approved
            continue
        name = re.split(r"[\[<>=~!;\s@]", line, 1)[0].lower().replace("_", "-")
        if name not in APPROVED_DEPS:
            out.append(name)
    return out


def check_files(files: list[dict]) -> tuple[list[dict], list[str], list[str]]:
    """-> (clean files, problems, protected paths touched). Any problem means nothing is committed."""
    problems: list[str] = []
    clean: list[dict] = []
    if not files or len(files) > MAX_FILES:
        return [], [f"Send 1 to {MAX_FILES} files."], []
    touched: list[str] = []
    for f in files:
        path = str((f or {}).get("path") or "").strip().lstrip("/")
        content = (f or {}).get("content")
        if not path or ".." in path.split("/") or path.startswith("/") or not isinstance(content, str):
            problems.append(f"Bad file entry: {path or '(no path)'}")
            continue
        if any(b in path for b in BLOCKED):
            problems.append(f"{path}: not allowed (secrets/keys/git internals).")
            continue
        if len(content.encode()) > MAX_BYTES:
            problems.append(f"{path}: over {MAX_BYTES // 1000} KB.")
            continue
        if any(p.search(content) for p in SECRET_PATTERNS):
            problems.append(f"{path}: looks like it contains a secret. Refused.")
            continue
        if path == "requirements.txt":
            bad = bad_dependencies(content)
            if bad:
                problems.append(f"requirements.txt: not on the approved dependency list: {', '.join(bad)}.")
                continue
        if any(path == p or (p.endswith("/") and path.startswith(p)) for p in PROTECTED):
            touched.append(path)
        clean.append({"path": path, "content": content})
    return clean, problems, touched


def propose_change(title: str, rationale: str, files: list[dict]) -> str:
    if not configured():
        return "Self-development is not set up: it needs GITHUB_TOKEN (repo-limited, pull requests only) and GITHUB_REPO on the bot."
    title = (title or "").strip()[:80]
    if len(title) < 8 or len((rationale or "").strip()) < 30:
        return "Give the change a clear title and at least a couple of sentences on why."
    clean, problems, touched = check_files(files)
    if problems:
        return "Refused: " + " ".join(problems)
    try:
        base = _call("GET", f"/git/ref/heads/{BASE_BRANCH}")["object"]["sha"]
        branch = f"jarvis/{re.sub(r'[^a-z0-9]+', '-', title.lower()).strip('-')[:40]}-{int(time.time()) % 100000}"
        _call("POST", "/git/refs", {"ref": f"refs/heads/{branch}", "sha": base})
        for f in clean:
            existing = None
            try:
                existing = _call("GET", f"/contents/{f['path']}?ref={branch}")
            except urllib.error.HTTPError as e:
                if e.code != 404:
                    raise
            body = {"message": f"Jarvis: {title}", "branch": branch, "content": base64.b64encode(f["content"].encode()).decode()}
            if existing and isinstance(existing, dict) and existing.get("sha"):
                body["sha"] = existing["sha"]
            _call("PUT", f"/contents/{f['path']}", body)
        warn = ("\n\n**PROTECTED PATHS TOUCHED (read every line before merging):** " + ", ".join(touched)) if touched else ""
        pr = _call("POST", "/pulls", {"title": f"[Jarvis] {title}", "head": branch, "base": BASE_BRANCH,
                                      "body": f"{rationale.strip()}{warn}\n\nProposed by Jarvis. Not merged automatically. Tests must pass before merging; rollback = revert this PR."})
        return f"Pull request opened: {pr.get('html_url')}" + (" (touches protected files: review carefully)" if touched else "")
    except urllib.error.HTTPError as e:
        logger.warning("GitHub call failed: %s", e.code)
        return f"GitHub refused the change (HTTP {e.code}). Nothing was merged."
    except Exception as e:
        logger.warning("dev proposal failed: %s", str(e)[:120])
        return "Could not open the pull request. Nothing was merged."
