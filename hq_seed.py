"""
Memory seed import (owner only). The Chairman sends a PRIVATE markdown file to the bot with the caption /seedmemory. The file is parsed in memory,
never written to disk and never stored in the repository; each bullet / paragraph becomes one memory row (kind 'owner_profile') through
jarvis_seed_memory(), which dedupes against what is already there and writes one audit row with counts and the file's sha256 only.
"""
from __future__ import annotations

import hashlib
import re

import hq

MAX_BYTES = 200_000
MAX_ITEMS = 500
MAX_LEN = 600


def parse_markdown(text: str) -> list[dict]:
    """[{section, content}]: headings name the section; bullets, numbered items and paragraph lines are items. Code blocks, tables, front matter,
    HTML comments and link-only lines are skipped. Markdown emphasis is removed. Long items are cut at MAX_LEN."""
    items, section, in_code, in_front = [], "", False, False
    lines = (text or "").replace("\r\n", "\n").split("\n")
    text_no_comments = re.sub(r"<!--.*?-->", "", "\n".join(lines), flags=re.S)
    for i, raw in enumerate(text_no_comments.split("\n")):
        line = raw.strip()
        if i == 0 and line == "---":
            in_front = True; continue
        if in_front:
            if line == "---":
                in_front = False
            continue
        if line.startswith("```") or line.startswith("~~~"):
            in_code = not in_code; continue
        if in_code or not line or line.startswith("|") or re.fullmatch(r"[-*_]{3,}", line):
            continue
        h = re.match(r"^#{1,6}\s+(.*)$", line)
        if h:
            section = _clean(h.group(1))[:80]; continue
        line = re.sub(r"^([-*+]|\d+[.)])\s+(\[[ xX]\]\s+)?", "", line)
        c = _clean(line)
        if len(c) < 3 or re.fullmatch(r"https?://\S+", c):
            continue
        items.append({"section": section, "content": c[:MAX_LEN]})
        if len(items) >= MAX_ITEMS:
            break
    return items


def _clean(s: str) -> str:
    s = re.sub(r"!\[[^\]]*\]\([^)]*\)", "", s)
    s = re.sub(r"\[([^\]]+)\]\([^)]*\)", r"\1", s)
    s = re.sub(r"(\*\*|__|\*|_|`)", "", s)
    return re.sub(r"\s+", " ", s).strip()


def import_bytes(raw: bytes, rpc=None) -> dict:
    if len(raw) > MAX_BYTES:
        raise ValueError("file too large")
    text = raw.decode("utf-8", errors="replace")
    items = parse_markdown(text)
    if not items:
        return {"added": 0, "duplicates": 0, "rejected": 0}
    sha = hashlib.sha256(raw).hexdigest()
    rpc = rpc or (lambda args: hq._request("POST", "/rest/v1/rpc/jarvis_seed_memory", args))
    return rpc({"p_items": items, "p_file_sha256": sha, "p_actor": "owner"}) or {}


def owner_profile(limit: int = 12) -> list[str]:
    """What Jarvis knows about the Chairman (seeded rows), newest first."""
    try:
        rows = hq._request("GET", f"/rest/v1/memory?kind=eq.owner_profile&order=created_at.desc&limit={int(limit)}&select=content") or []
    except Exception:
        return []
    return [r["content"] for r in rows if r.get("content")]
