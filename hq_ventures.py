"""
Venture factory client (Section 11). Jarvis can start a venture from a one-line idea:
  1. the structure is created INERT (status 'proposed': manager paused, no spend, own department and budget ceiling)
  2. a lifecycle mission validates the idea first (Idea Lab agents do the research; the verifier is independent)
  3. only the owner activates it (one tap), which wakes the venture manager inside its own small cap
Stages move one gate at a time and need evidence. Every venture has its own budget, goals, memory, leads and ledger rows.
"""

from __future__ import annotations

import logging
import re
import urllib.parse
from datetime import datetime, timezone

import hq
import hq_missions

logger = logging.getLogger(__name__)

LIFECYCLE = (
    "Take this idea through the venture lifecycle, one gate at a time, with evidence at each gate:\n"
    "1 VALIDATE: real demand, named competitors and their prices, who pays and how much (cite sources).\n"
    "2 MODEL: unit economics in CAD, cost to acquire a customer, time to first dollar, startup cost under the budget.\n"
    "3 BUILD PLAN: the cheapest thing that can earn the first dollar (no build before validation passes).\n"
    "4 LAUNCH PLAN: channels, the first 10 customers, compliance (CASL/CRTC/licensing).\n"
    "5 MEASURE: the 3 numbers that decide scale or kill, and the date to decide.\n"
    "Recommend KILL early if the numbers do not work. Do not spend money or contact anyone: planning only."
)


def slugify(name: str) -> str:
    s = re.sub(r"[^a-z0-9]+", "-", (name or "").lower()).strip("-")
    if not s or not s[0].isalpha():
        s = "v-" + s
    return s[:40].strip("-")


def _rpc(name: str, args: dict):
    return hq._request("POST", f"/rest/v1/rpc/{name}", args)


def _d(cents) -> str:
    return f"${int(cents or 0) / 100:,.2f}"


def start(name: str, description: str, metric: str | None = None, budget_cents: int = 0, by: str = "jarvis") -> dict:
    """Create the inert venture, its validation mission, and the owner's activation card. Returns {slug, mission} or {error}."""
    name = (name or "").strip()
    description = (description or "").strip()
    if len(name) < 3 or len(description) < 15:
        return {"error": "Give the venture a name and at least a sentence on what it does."}
    slug = slugify(name)
    try:
        _rpc("create_venture", {"p_slug": slug, "p_name": name[:80], "p_kind": "revenue", "p_metric": metric or "verified revenue (CAD)",
                                "p_budget_cents": int(budget_cents or 0), "p_description": description[:1000], "p_by": by})
    except Exception as e:
        return {"error": _err(e) or "Could not create the venture (migration pending?)."}
    m = hq_missions.create_mission(f"Venture '{name}' ({slug}): {description}\n\n{LIFECYCLE}", "idea-lab",
                                   title=f"Validate venture: {name}"[:60], created_by=by)
    hq._request("POST", "/rest/v1/owner_messages", {
        "from_agent": "jarvis", "kind": "proposal", "channel": "telegram", "needs_decision": True,
        "ref_table": f"activate_venture:{slug}",
        "body": (f"New venture set up, inactive: {name}.\n{description[:300]}\n"
                 f"It spends nothing until you approve. Validation research is running first (mission). "
                 f"Approve to wake its manager (cap 25c/day, venture ceiling {_d(min(max(int(budget_cents or 0), 0), 5000))}/month)."),
    }, prefer="return=minimal")
    return {"slug": slug, "mission": m.get("title") or m.get("error")}


def _err(e: Exception) -> str:
    try:
        import json
        return json.loads(e.read().decode()).get("message", "")  # type: ignore[attr-defined]
    except Exception:
        return ""


def activate(slug: str, by: str = "owner:telegram") -> str:
    try:
        _rpc("activate_venture", {"p_slug": slug, "p_by": by})
        return f"{slug} is active. Its manager is awake inside its own cap."
    except Exception as e:
        return _err(e) or f"Could not activate {slug}."


def set_stage(slug: str, stage: str, by: str, evidence: str) -> str:
    try:
        _rpc("set_venture_stage", {"p_slug": slug, "p_stage": stage, "p_by": by, "p_evidence": evidence or ""})
        return f"{slug} moved to {stage}."
    except Exception as e:
        return _err(e) or "Stage change refused."


def add_goal(slug: str, metric: str, target: float | None, unit: str | None = None, by: str = "jarvis") -> str:
    v = hq._request("GET", f"/rest/v1/ventures?slug=eq.{slug}&select=id&limit=1") or []
    if not v:
        return f"No venture {slug}."
    hq._request("POST", "/rest/v1/venture_goals", {"venture_id": v[0]["id"], "metric": metric[:200], "target_value": target,
                                                    "unit": unit, "created_by": by}, prefer="return=minimal")
    return f"Goal saved for {slug}: {metric}" + (f" -> {target}" if target is not None else "")


def workspace_text(slug: str) -> str:
    try:
        w = _rpc("venture_workspace", {"p_slug": slug})
    except Exception:
        return "Venture workspaces are not installed yet (migration pending)."
    if not w:
        return f"No venture '{slug}'."
    lines = [f"{w['name']} [{w['status']} / {w['stage']}] manager {w.get('manager') or 'none'}",
             f"Budget ceiling {_d(w['monthly_budget_cents'])}/month; AI used 30d {_d(w['ai_spend_30d_cents'])}",
             f"Money in {_d(w['in_cents'])}, out {_d(w['out_cents'])}",
             f"{w['agents']} agents, {w['leads']} leads, {w['memory']} memory items, {w['missions_live']} live missions"]
    for g in w.get("goals") or []:
        lines.append(f"Goal [{g['status']}]: {g['metric']} {g.get('current') if g.get('current') is not None else '-'}/{g.get('target') if g.get('target') is not None else '-'} {g.get('unit') or ''}")
    try:
        vid, _ = _venture_row(slug)
        for a in hq._request("GET", f"/rest/v1/venture_assets?venture_id=eq.{vid}&status=neq.retired&order=created_at.desc&limit=8&select=kind,name,url,status") or []:
            lines.append(f"Asset [{a['status']}]: {a['kind']} {a['name']} {a.get('url') or ''}".rstrip())
        for p in hq._request("GET", f"/rest/v1/venture_procedures?venture_id=eq.{vid}&status=eq.active&order=title&limit=8&select=title,version") or []:
            lines.append(f"Procedure: {p['title']} (v{p['version']})")
    except Exception:
        pass  # assets/procedures migration not applied yet
    return "\n".join(lines)


ASSET_KINDS = ("website", "domain", "account", "integration", "asset", "repo")
_SECRET = re.compile(r"(?i)(password|passwd|pwd|secret|api[_-]?key|token|pin)\s*[:=]|sk-[A-Za-z0-9]{10,}|eyJ[A-Za-z0-9_-]{20,}")


def _venture_row(slug: str | None):
    if not slug:
        return None, None
    rows = hq._request("GET", f"/rest/v1/ventures?slug=eq.{re.sub(r'[^a-z0-9-]', '', slug.lower())}&select=id,slug&limit=1") or []
    return (rows[0]["id"], rows[0]["slug"]) if rows else (None, "missing")


def register_asset(venture: str | None, kind: str, name: str, url: str = "", status: str = "planned", notes: str = "", by: str = "jarvis") -> str:
    """Record a venture's website/domain/account/integration/repo. Names and URLs only: credentials are refused."""
    if kind not in ASSET_KINDS:
        return f"Kind must be one of: {', '.join(ASSET_KINDS)}."
    if len((name or "").strip()) < 2:
        return "Give the asset a name."
    if _SECRET.search(f"{name} {url} {notes}"):
        return "Refused: that looks like a password, key or token. Credentials are never stored here; tell the owner where to enter them."
    if url and not re.match(r"^https?://[^\s]+$", url):
        return "URL must start with http:// or https://."
    vid, vslug = _venture_row(venture)
    if vslug == "missing":
        return f"No venture '{venture}'."
    hq._request("POST", "/rest/v1/venture_assets", {"venture_id": vid, "kind": kind, "name": name.strip()[:120], "url": url or None,
                "status": status if status in ("planned", "live", "retired") else "planned", "notes": (notes or "")[:300] or None, "created_by": by},
                prefer="return=minimal")
    return f"Recorded {kind} '{name.strip()}'" + (f" for {vslug}." if vslug else " (company-wide).")


def save_procedure(venture: str | None, title: str, steps: str, owner_agent: str = "", by: str = "jarvis") -> str:
    """Create or update an operating procedure (new version when the title already exists)."""
    if len((title or "").strip()) < 4 or len((steps or "").strip()) < 20:
        return "A procedure needs a title and real steps (20+ characters)."
    if _SECRET.search(f"{title} {steps}"):
        return "Refused: procedures must not contain passwords, keys or tokens."
    vid, vslug = _venture_row(venture)
    if vslug == "missing":
        return f"No venture '{venture}'."
    q = f"venture_procedures?title=eq.{urllib.parse.quote(title.strip(), safe='')}&" + (f"venture_id=eq.{vid}" if vid else "venture_id=is.null") + "&select=id,version&limit=1"
    ex = hq._request("GET", "/rest/v1/" + q) or []
    now = datetime.now(timezone.utc).isoformat()
    if ex:
        hq._request("PATCH", f"/rest/v1/venture_procedures?id=eq.{ex[0]['id']}", {"steps": steps.strip()[:4000], "version": ex[0]["version"] + 1,
                    "owner_agent": owner_agent or None, "status": "active", "updated_at": now}, prefer="return=minimal")
        return f"Procedure '{title.strip()}' updated to v{ex[0]['version'] + 1}."
    hq._request("POST", "/rest/v1/venture_procedures", {"venture_id": vid, "title": title.strip()[:120], "steps": steps.strip()[:4000],
                "owner_agent": owner_agent or None, "created_by": by}, prefer="return=minimal")
    return f"Procedure '{title.strip()}' saved" + (f" for {vslug}." if vslug else " (company-wide).")


def list_text() -> str:
    rows = hq._request("GET", "/rest/v1/ventures?order=created_at.asc&select=slug,name,status,stage") or []
    return "\n".join(f"{r['slug']}: {r['status']}" + (f" / {r.get('stage')}" if r.get("stage") else "") + f" - {r['name']}" for r in rows) or "No ventures."
