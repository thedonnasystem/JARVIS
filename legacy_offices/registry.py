"""Legacy offices registry: the systems Moe built before Jarvis, described as offices (legacy_offices/offices/<slug>.json).

Reads JSON only. The private repos are named, never copied: no lead, contact, key or personal data lives in these files.
"""
from __future__ import annotations

import json
import os
import re

HERE = os.path.dirname(os.path.abspath(__file__))
OFFICE_DIR = os.path.join(HERE, "offices")
REGISTRY = os.path.join(HERE, "registry.json")


def registry() -> dict:
    with open(REGISTRY, encoding="utf-8") as f:
        return json.load(f)


def systems() -> list[dict]:
    return registry()["systems"]


def slugs(viable_only: bool = True) -> list[str]:
    return [s["slug"] for s in systems() if s.get("viable") or not viable_only]


def resolve(name: str | None) -> str | None:
    """'Real Estate' / 'wholesale' / 'realestate-ca' -> 'realestate-ca'; None if unknown. Non-viable systems resolve too (the doctor explains them)."""
    k = re.sub(r"[^a-z0-9-]", "", str(name or "").strip().lower().replace(" ", "-")).strip("-")
    if not k:
        return None
    for s in systems():
        if k == s["slug"] or k in s.get("aliases", []) or k.replace("-", "") in (a.replace("-", "") for a in [s["slug"], *s.get("aliases", [])]):
            return s["slug"]
    return None


def system(slug: str) -> dict:
    for s in systems():
        if s["slug"] == slug:
            return s
    raise KeyError(slug)


def office(slug: str) -> dict:
    """The office file of a viable system; a non-viable system gets a stub carrying its registry entry."""
    s = system(slug)
    if not s.get("viable"):
        return {"office": slug, "title": slug, "viable": False, "why_not": s.get("why_not", ""), "legacy": {"repo": s["repo"]}, "qc": {}}
    with open(os.path.join(OFFICE_DIR, f"{slug}.json"), encoding="utf-8") as f:
        d = json.load(f)
    d["viable"] = True
    return d


def checkout(slug: str, src_dir: str | None = None) -> str | None:
    """Local clone of the office's repo under LEGACY_SRC_DIR (<dir>/<repo name>), or None. Production has no clones: remote checks only."""
    base = src_dir if src_dir is not None else os.environ.get("LEGACY_SRC_DIR", "")
    if not base:
        return None
    path = os.path.join(base, system(slug)["repo"].split("/", 1)[1])
    return path if os.path.isdir(path) else None
