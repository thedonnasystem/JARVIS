"""Office operating system (FENDEZY GROUP Phase 1, M7): the template + 8 office instances, the owner's /office <name> status, office agent prompts and the
shared-brain read scope.

Database side: migrations/20261203_office_os_v1.sql (profiles; owner-only office_os_set_manager / office_os_activate / office_os_deactivate; office_os_status).
Repo side: offices/TEMPLATE.json (rules + prompt header) and offices/<slug>.json (each office's core agents).
Nothing here activates, appoints, spends or sends: status is read-only, prompts are text, and brain reads are OFF unless FZ_BRAIN_FACTS=1.

Shared brain (M6): the ONLY read path is RPC fz_brain_read(p_query, p_limit 1-50), which returns group facts plus the CALLER's own office facts (the brain tables have
no API privileges). An office agent reads through its office identity (office:<slug>:manager, M1 scoped token): without installed tokens the service key reads, and the
database then returns group facts only. Every returned fact is re-checked here (scope must be 'group' or the office's own slug). With FZ_BRAIN_FACTS unset no request is made.
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
    lines = []
    if s.get("drift"):
        lines.append(f"!!! DRIFT ALERT: M1 says {s.get('m1_status')} but the office OS says {s.get('status')}. This office was changed outside office_os_activate. "
                     f"If that was not you: office_os_deactivate('{slug}').")
    lines += [f"{s.get('title') or slug} ({slug}): {str(s.get('status')).upper()}",
             f"Manager: {s.get('manager') or 'none appointed (owner only)'}",
             f"Available money: {_money(s.get('available_cents'))} (no fixed budget; allocate on need)"]
    if s.get("approval_status"):
        lines.append(f"Activation approval: {s['approval_status']}")
    if s.get("activation_rank"):
        lines.append(f"Activation order: #{s['activation_rank']}")
    lines += [f"Mission: {s.get('mission')}", "Agents: " + ", ".join(s.get("agent_roles") or []), "Integrations: " + ", ".join(s.get("integrations") or []),
              f"Data class: {s.get('confidentiality')}"]
    for t in ("green", "yellow", "red"):
        lines.append(f"{t.capitalize()}: " + (", ".join(a.get(t) or []) or "-"))
    lines.append("Prohibited (enforced as office blocks on activation): " + (", ".join(s.get("prohibited_enforced") or []) or "-"))
    lines.append("Prohibited (advisory only: in prompts, not a database rule): " + (", ".join(s.get("prohibited_advisory") or []) or "-"))
    if s.get("status") != "active":
        lines.append("To activate (owner only, one office at a time): office_os_set_manager, office_os_activate, office_os_decide(<nonce>), office_os_activate again.")
    return "\n".join(lines)


def brain_scope(office: str) -> list[str]:
    """Scopes an office agent may read from the shared brain: the group and its own office. Nothing else, ever."""
    slug = resolve(office)
    if not slug:
        raise ValueError(f"unknown office {office!r}")
    return ["group", slug]


def brain_facts(office: str, query: str | None = None, limit: int = 20, rpc=None) -> list[dict]:
    """Shared-brain facts for an office agent via M6's fz_brain_read. [] when the flag is off or on any error (fail closed)."""
    if os.environ.get(BRAIN_FLAG) != "1":
        return []
    scope = brain_scope(office)
    body = {"p_query": (str(query)[:200] if query else None), "p_limit": max(1, min(int(limit), 50))}
    try:
        if rpc:
            rows = rpc("POST", "/rest/v1/rpc/fz_brain_read", body)
        else:
            rows = hq._request("POST", "/rest/v1/rpc/fz_brain_read", body, identity=f"office:{scope[1]}:manager")
    except Exception as e:
        logger.warning("brain read failed (fail closed): %s", str(e)[:120])
        return []
    return [r for r in (rows if isinstance(rows, list) else []) if isinstance(r, dict) and r.get("scope") in scope]


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
    fs = [str(f.get("fact") or "")[:300] for f in (facts or []) if isinstance(f, dict) and f.get("scope") in scope][:20]
    brief = office_config(slug).get("brief")
    return head + ("\n\n" + brief if brief else "") + "\n\n" + agent["prompt"] + ("\n\nKnown facts:\n" + "\n".join("- " + x for x in fs if x) if fs else "")


# ---------------------------------------------------------------------------------------------------------------- office brief, missions, money requests
def office_config(office: str) -> dict:
    slug = resolve(office)
    if not slug:
        raise ValueError(f"unknown office {office!r}")
    with open(os.path.join(DIR, f"{slug}.json")) as f:
        return json.load(f)


def _active(slug: str, rpc=None) -> tuple[bool, str]:
    """(True, '') only when office_os_status says active and not drifting. Any error: refused (fail closed)."""
    try:
        s = (rpc or hq._request)("POST", "/rest/v1/rpc/office_os_status", {"p_office": slug})
    except Exception as e:
        return False, f"office status unreadable ({type(e).__name__})"
    if not isinstance(s, dict) or s.get("office") != slug:
        return False, "office status unreadable"
    if s.get("status") != "active" or s.get("m1_status") != "active" or s.get("drift"):
        return False, f"{slug} is {s.get('status')} (M1: {s.get('m1_status')}); nothing runs until the owner activates it"
    return True, ""


def missions(office: str) -> list[dict]:
    """The office's first-mission templates (offices/<slug>_missions.json); [] if it has none."""
    slug = resolve(office)
    path = os.path.join(DIR, f"{slug}_missions.json") if slug else ""
    if not path or not os.path.exists(path):
        return []
    with open(path) as f:
        return json.load(f)["missions"]


def queue_missions(office: str, rpc=None, create=None, get=None) -> dict:
    """Queue the office's first missions through hq_missions.create_mission, ONLY while the office is active. Idempotent by title.
    Queued missions still run step by step through the task board, the owner approvals and authorize_action like every mission."""
    slug = resolve(office)
    if not slug:
        return {"ok": False, "reason": f"unknown office {office!r}"}
    ok, why = _active(slug, rpc)
    if not ok:
        return {"ok": False, "reason": why, "queued": []}
    get = get or (lambda p: hq._request("GET", "/rest/v1/" + p) or [])
    if not get(f"ventures?slug=eq.{urllib.parse.quote(slug)}&select=id&limit=1"):
        return {"ok": False, "reason": f"no '{slug}' venture: missions would land in the idea lab, so none were queued", "queued": []}
    if create is None:
        import hq_missions
        create = hq_missions.create_mission
    queued, skipped = [], []
    for m in missions(slug):
        if get("missions?title=eq." + urllib.parse.quote(m["title"]) + "&select=id&limit=1"):
            skipped.append(m["key"])
            continue
        r = create(m["objective"], venture=m["venture"], title=m["title"], budget_cents=m.get("budget_cents", 0), created_by=f"office:{slug}",
                   priority=m.get("priority", 2), max_steps=m.get("max_steps"), checkpoint=dict(m.get("checkpoint") or {}, mission_key=m["key"]))
        if r.get("error"):
            return {"ok": False, "reason": r["error"], "queued": queued, "skipped": skipped}
        queued.append(m["key"])
    return {"ok": True, "queued": queued, "skipped": skipped}


REQUEST_FIELDS = ("purpose", "expected_return", "payback", "cheapest_alternative", "deadline")


def request_money(office: str, cents: int, purpose: str, expected_return: str, payback: str, cheapest_alternative: str, deadline: str,
                  by: str = "agent", rpc=None, propose=None) -> dict:
    """A funding request from an office agent. It is ONLY an M2 allocation proposal (fz_propose_office_money via hq_office_money.propose):
    it lands in the owner's /approvals queue; no money moves and no cap or limit changes. Refused unless the office is active."""
    slug = resolve(office)
    if not slug:
        return {"ok": False, "reason": f"unknown office {office!r}"}
    ok, why = _active(slug, rpc)
    if not ok:
        return {"ok": False, "reason": why}
    try:
        cents = int(cents)
    except (TypeError, ValueError):
        return {"ok": False, "reason": "amount must be a whole number of cents"}
    if cents <= 0:
        return {"ok": False, "reason": "amount must be above $0"}
    vals = dict(zip(REQUEST_FIELDS, (purpose, expected_return, payback, cheapest_alternative, deadline)))
    missing = [k for k, v in vals.items() if len(str(v or "").strip()) < 3]
    if missing:
        return {"ok": False, "reason": "a funding request needs: " + ", ".join(missing)}
    rationale = (f"FUNDING REQUEST ${cents / 100:,.2f}. Purpose: {vals['purpose']}. Expected return: {vals['expected_return']}. Payback: {vals['payback']}. "
                 f"Cheapest alternative considered: {vals['cheapest_alternative']}. Deadline: {vals['deadline']}. "
                 "Existing limits apply after approval ($25 per transaction, $75 per week, low-cost mode, hard stop).")
    if propose is None:
        import hq_office_money
        propose = hq_office_money.propose
    by = re.sub(r"[^A-Za-z0-9:_.-]", "", f"{slug}:{by}")[:60]
    return propose(slug, "allocate", cents=cents, rationale=rationale[:2000], by=by)
