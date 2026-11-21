"""Office operating system (FENDEZY GROUP Phase 1, M7): the template + 8 office instances, the owner's /office <name> status, office agent prompts and the
shared-brain read scope.

Database side: migrations/20261203_office_os_v1.sql (profiles; owner-only office_os_set_manager / office_os_activate / office_os_deactivate; office_os_status).
Repo side: offices/TEMPLATE.json (rules + prompt header) and offices/<slug>.json (each office's core agents).
Nothing here activates, appoints, spends or sends: status is read-only, prompts are text, and brain reads are OFF unless FZ_BRAIN_FACTS=1.

Shared brain (M6 fz_brain_facts, built by another milestone): an office agent reads group facts plus its OWN office only. The filter is put in the request AND
re-checked on every returned row (a row of another office, or one without office_id, is dropped). With the flag unset no request is made at all.
"""
from __future__ import annotations

import json
import logging
import os
import re
import urllib.parse

import hq

logger = logging.getLogger(__name__)
DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)), "offices")
GROUP_ID = "f0000000-0000-4000-8000-000000000000"
OFFICES = {   # M1 fz_offices ids (fixed)
    "b2b-records": "f0000000-0000-4000-8000-000000000001", "donna": "f0000000-0000-4000-8000-000000000002",
    "the-trap": "f0000000-0000-4000-8000-000000000003", "wolf-squad": "f0000000-0000-4000-8000-000000000004",
    "pimp-ai": "f0000000-0000-4000-8000-000000000005", "monopoly": "f0000000-0000-4000-8000-000000000006",
    "ff-marketing": "f0000000-0000-4000-8000-000000000007", "fruition-factory": "f0000000-0000-4000-8000-000000000008",
}
ALIASES = {"b2b": "b2b-records", "b2brecords": "b2b-records", "trap": "the-trap", "thetrap": "the-trap", "wolf": "wolf-squad", "wolfsquad": "wolf-squad",
           "pimp": "pimp-ai", "pimpai": "pimp-ai", "ffm": "ff-marketing", "ff": "ff-marketing", "ffmarketing": "ff-marketing",
           "fruition": "fruition-factory", "fruitionfactory": "fruition-factory"}
BRAIN_FLAG = "FZ_BRAIN_FACTS"


def resolve(name: str) -> str | None:
    """'Wolf Squad' / 'wolf' / 'wolf-squad' -> 'wolf-squad'; None if unknown."""
    k = re.sub(r"[^a-z0-9-]", "", str(name or "").strip().lower().replace(" ", "-"))
    if k in OFFICES:
        return k
    return ALIASES.get(k.replace("-", ""))


def template() -> dict:
    with open(os.path.join(DIR, "TEMPLATE.json")) as f:
        return json.load(f)


def agents(office: str) -> list[dict]:
    slug = resolve(office)
    if not slug:
        raise ValueError(f"unknown office {office!r}")
    with open(os.path.join(DIR, f"{slug}.json")) as f:
        return json.load(f)["agents"]


def _money(cents) -> str:
    return "n/a" if cents is None else f"${int(cents) / 100:,.2f}"


def status_text(name: str, rpc=None) -> str:
    """The owner's /office <name>: read-only, service path."""
    slug = resolve(name)
    if not slug:
        return "Unknown office. One of: " + ", ".join(OFFICES)
    try:
        s = (rpc or hq._request)("POST", "/rest/v1/rpc/office_os_status", {"p_office": slug})
    except Exception as e:
        logger.warning("office_os_status failed: %s", str(e)[:120])
        return "Office status is not installed yet (migration 20261203_office_os_v1)."
    if not isinstance(s, dict) or s.get("office") != slug:
        return "Office status unreadable."
    a = s.get("autonomy") or {}
    lines = [f"{s.get('title') or slug} ({slug}): {str(s.get('status')).upper()}" + (" (DRIFT: M1 says " + str(s.get("m1_status")) + ")" if s.get("drift") else ""),
             f"Manager: {s.get('manager') or 'none appointed (owner only)'}",
             f"Available money: {_money(s.get('available_cents'))} (no fixed budget; allocate on need)"]
    if s.get("approval_status"):
        lines.append(f"Activation approval: {s['approval_status']}")
    if s.get("activation_rank"):
        lines.append(f"Activation order: #{s['activation_rank']}")
    lines += [f"Mission: {s.get('mission')}", "Agents: " + ", ".join(s.get("agent_roles") or []), "Integrations: " + ", ".join(s.get("integrations") or []),
              f"Data class: {s.get('confidentiality')}"]
    for t in ("green", "yellow", "red", "prohibited"):
        lines.append(f"{t.capitalize()}: " + (", ".join(a.get(t) or []) or "-"))
    if s.get("status") != "active":
        lines.append("To activate (owner only, one office at a time): appoint a manager, office_os_activate, tap Approve, office_os_activate again.")
    return "\n".join(lines)


def brain_scope(office: str) -> list[str]:
    """Office ids an office agent may read from the shared brain: the group and its own office. Nothing else, ever."""
    slug = resolve(office)
    if not slug:
        raise ValueError(f"unknown office {office!r}")
    return [GROUP_ID, OFFICES[slug]]


def brain_facts(office: str, limit: int = 20, rpc=None) -> list[dict]:
    """Shared-brain facts for an office agent (M6 interface: table fz_brain_facts with an office_id column). [] when the flag is off or on any error."""
    if os.environ.get(BRAIN_FLAG) != "1":
        return []
    scope = brain_scope(office)
    q = "fz_brain_facts?select=*&office_id=in.(" + ",".join(urllib.parse.quote(i, safe="-") for i in scope) + f")&limit={max(1, min(int(limit), 100))}"
    try:
        rows = (rpc or hq._request)("GET", "/rest/v1/" + q) or []
    except Exception as e:
        logger.warning("brain read failed (fail closed): %s", str(e)[:120])
        return []
    return [r for r in rows if isinstance(r, dict) and r.get("office_id") in scope]


def system_prompt(profile: dict, role: str, facts: list[dict] | None = None) -> str:
    """Office agent system prompt: the template header (mission, tiers, read scope) + the role's own prompt + up to 20 brain facts."""
    slug = profile.get("office")
    if not resolve(slug or ""):
        raise ValueError("profile has no known office")
    if role not in (profile.get("agent_roles") or []):
        raise ValueError(f"role {role!r} is not allowed in {slug}")
    agent = next((x for x in agents(slug) if x["role"] == role), None)
    if not agent:
        raise ValueError(f"no agent definition for {role!r} in offices/{slug}.json")
    a = profile.get("autonomy") or {}
    head = template()["prompt_header"].format(role=role, title=profile.get("title") or slug, mission=profile.get("mission") or "",
                                              **{t: ", ".join(a.get(t) or []) or "-" for t in ("green", "yellow", "red", "prohibited")})
    scope = set(brain_scope(slug))
    fs = [str(f.get("fact") or f.get("text") or "")[:300] for f in (facts or []) if isinstance(f, dict) and f.get("office_id") in scope][:20]
    return head + "\n\n" + agent["prompt"] + ("\n\nKnown facts:\n" + "\n".join("- " + x for x in fs if x) if fs else "")
