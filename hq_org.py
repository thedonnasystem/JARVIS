"""
Organizational growth (Section 12). Jarvis can create departments and agents himself, inside hard limits enforced by the
database (see migration agents_v1): cheap/standard tier only, cap <= 50c/day, cannot contact the owner, max 3 new agents a week,
created asleep when the company's agent caps are already full. Every creation is logged and reported to the owner.
Strong-tier agents, owner contact, higher caps and external commitments always need the owner.
"""

from __future__ import annotations

import json
import logging
import urllib.error

import hq

logger = logging.getLogger(__name__)


def _rpc(name: str, args: dict):
    return hq._request("POST", f"/rest/v1/rpc/{name}", args)


def _err(e: Exception) -> str:
    if isinstance(e, urllib.error.HTTPError):
        try:
            return json.loads(e.read().decode()).get("message") or f"HTTP {e.code}"
        except Exception:
            return f"HTTP {e.code}"
    return "the organization functions are not installed yet (migration pending)"


def create_department(slug: str, name: str, venture_slug: str | None = None, by: str = "jarvis") -> str:
    try:
        _rpc("create_department", {"p_slug": (slug or "").lower(), "p_name": name or "", "p_venture_slug": venture_slug or None, "p_by": by})
        return f"Department {slug} created."
    except Exception as e:
        return f"Not created: {_err(e)}"


def create_agent(slug: str, title: str, department: str, role: str, tier: str, cap_cents: int, charter: str, metric: str, by: str = "jarvis") -> str:
    try:
        status = _rpc("create_agent", {"p_slug": (slug or "").lower(), "p_title": title or slug, "p_department": department, "p_role": role,
                                       "p_tier": tier, "p_cap_cents": int(cap_cents or 15), "p_charter": charter or "", "p_metric": metric or "", "p_by": by})
    except Exception as e:
        return f"Not created: {_err(e)}"
    if status == "paused":
        return f"Agent {slug} created but ASLEEP: the company's agent budget is full. Pause another agent or ask the owner to raise the cap."
    return f"Agent {slug} created and active ({tier}, cap {min(max(int(cap_cents or 15), 1), 50)}c/day, cannot contact the owner)."
