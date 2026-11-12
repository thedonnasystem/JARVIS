"""
Permissions engine client (Phase 4). The rules live in the database (action_policy + authorize_action()),
so an agent, a prompt or a bug in Python can't widen them. This module only asks and reports.

    d = hq_policy.authorize("donna-ops", "send_email", ref=outbox_id)
    if d.allowed: ...do it...; hq_policy.record(d, "ok", evidence="provider id 123", verified=True)
    elif d.ask_owner: hq_policy.request_approval(...)
    else: log d.reason and stop

If the database function is missing (migration not applied) or unreachable, the local fallback allows
only Green actions and refuses everything else. It fails closed.
"""

from __future__ import annotations

import logging
import urllib.error
import urllib.parse
from dataclasses import dataclass

import hq

logger = logging.getLogger(__name__)

# Fallback only: mirrors the Green rows of the seed policy. Never used to *allow* anything non-green.
LOCAL_GREEN = {
    "research", "internal_document", "write_code", "build_internal_tool", "build_website_preview",
    "manage_tasks", "create_temp_agent", "update_internal_records", "fix_routine_issue", "llm_call",
}
TIERS = ("green", "yellow", "red", "prohibited")


@dataclass
class Decision:
    action: str
    decision: str  # allow | deny | ask_owner
    reason: str
    tier: str | None = None
    source: str = "database"

    @property
    def allowed(self) -> bool:
        return self.decision == "allow"

    @property
    def ask_owner(self) -> bool:
        return self.decision == "ask_owner"


def _local(action: str, why: str) -> Decision:
    if action in LOCAL_GREEN:
        return Decision(action, "allow", f"Green (local fallback: {why})", "green", "fallback")
    return Decision(action, "deny", f"Refused: the permissions engine is unavailable ({why}); only Green actions run.",
                    None, "fallback")


def authorize(actor: str, action: str, cents: int = 0, ref: str | None = None, venture_id: str | None = None,
              mission_id: str | None = None, detail: dict | None = None) -> Decision:
    try:
        r = hq._request("POST", "/rest/v1/rpc/authorize_action", {
            "p_actor": actor, "p_action": action, "p_cents": int(max(cents, 0)), "p_ref": ref,
            "p_venture": venture_id, "p_mission": mission_id, "p_detail": detail or {},
        })
    except urllib.error.HTTPError as e:
        return _local(action, f"HTTP {e.code}")
    except Exception as e:  # network, timeout
        return _local(action, type(e).__name__)
    if not isinstance(r, dict) or r.get("decision") not in ("allow", "deny", "ask_owner"):
        return _local(action, "unreadable reply")
    return Decision(action, r["decision"], r.get("reason") or "", r.get("tier"))


def request_approval(actor: str, action: str, recommendation: str, cents: int = 0, ref: str | None = None) -> str:
    """Red (or approve-first Yellow) action: put the case in front of the owner with Approve/Reject buttons.
    The recommendation should cover: what and why, the numbers, risks, alternatives, and what happens if we do nothing."""
    rows = hq._request("POST", "/rest/v1/approval_requests", {
        "actor": actor, "action": action, "cents": int(max(cents, 0)), "ref": ref, "recommendation": recommendation[:3000],
    }, prefer="return=representation") or []
    req = rows[0] if isinstance(rows, list) and rows else {}
    money = f" (${cents / 100:,.2f} CAD)" if cents else ""
    hq._request("POST", "/rest/v1/owner_messages", {
        "from_agent": "jarvis", "kind": "proposal", "channel": "telegram", "needs_decision": True,
        "ref_table": "approval_requests", "ref_id": req.get("id"),
        "body": f"Needs your decision: {action.replace('_', ' ')}{money}, asked by {actor}.\n\n{recommendation[:3000]}",
    }, prefer="return=minimal")
    return req.get("id") or ""


def decide_approval(request_id: str, approved: bool) -> None:
    from datetime import datetime, timezone
    hq._request("PATCH", f"/rest/v1/approval_requests?id=eq.{urllib.parse.quote(str(request_id), safe='')}&status=eq.pending",
                {"status": "approved" if approved else "rejected", "decided_at": datetime.now(timezone.utc).isoformat()},
                prefer="return=minimal")


def policy_text() -> str:
    rows = hq._request("GET", "/rest/v1/action_policy?order=tier.asc,action.asc&select=action,tier,max_cents_per_action,"
                              "max_count_per_day,max_cents_per_week,live_only") or []
    if not rows:
        return "Policy not installed yet."
    out = {t: [] for t in TIERS}
    for r in rows:
        lim = []
        if r.get("max_cents_per_action") is not None:
            lim.append(f"≤${r['max_cents_per_action'] / 100:,.0f}/each")
        if r.get("max_count_per_day") is not None:
            lim.append(f"{r['max_count_per_day']}/day")
        if r.get("max_cents_per_week") is not None:
            lim.append(f"≤${r['max_cents_per_week'] / 100:,.0f}/wk")
        out.setdefault(r["tier"], []).append(r["action"] + (f" ({', '.join(lim)})" if lim else ""))
    names = {"green": "GREEN (just do it)", "yellow": "YELLOW (within limits)", "red": "RED (asks you)",
             "prohibited": "PROHIBITED (never)"}
    return "\n\n".join(f"{names[t]}:\n" + "\n".join(f"- {a}" for a in out[t]) for t in TIERS if out.get(t))


def set_policy(action: str, field: str, value: str) -> str:
    """Owner-only edit (the database refuses edits not marked as from the owner)."""
    action = (action or "").strip().lower()
    body: dict = {"updated_by": "owner:telegram"}
    if field == "tier":
        if value not in TIERS:
            return f"Tier must be one of {', '.join(TIERS)}."
        body["tier"] = value
    elif field in ("each", "week"):
        try:
            cents = int(round(float(value.replace("$", "")) * 100))
        except ValueError:
            return "Give a dollar amount."
        body["max_cents_per_action" if field == "each" else "max_cents_per_week"] = max(cents, 0)
    elif field == "day":
        if not value.isdigit():
            return "Give a whole number per day."
        body["max_count_per_day"] = int(value)
    else:
        return "Use: /policy <action> tier|each|week|day <value>"
    hq._request("PATCH", f"/rest/v1/action_policy?action=eq.{urllib.parse.quote(action, safe='')}", body, prefer="return=minimal")
    return f"Policy updated: {action} {field} = {value}."
