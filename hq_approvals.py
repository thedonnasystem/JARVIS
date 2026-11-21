"""
Approvals kernel (FENDEZY GROUP Phase 1, M3): ONE read-only view of everything waiting on the owner.
The queue is the database view fz_approval_queue (action approvals + office money proposals). This module only reads it.
Decisions keep their existing owner paths: an action approval by tapping its Telegram message; a money proposal in the owner
session (fz_owner_decide_office_proposal). Nothing here can approve, reject or change a request.
"""

from __future__ import annotations

import logging

import hq

logger = logging.getLogger(__name__)
FIELDS = "request_type,source_id,office,requester,action,amount_cents,risk,status,created_at,expires_at"


def pending(limit: int = 30) -> list | None:
    try:
        rows = hq._request("GET", f"/rest/v1/fz_approval_queue?status=eq.pending&order=created_at.asc&limit={int(limit)}&select={FIELDS}")
    except Exception as e:  # not installed yet, or unreachable
        logger.info("approval queue unavailable: %s", e)
        return None
    return rows if isinstance(rows, list) else None


def _line(r: dict) -> str:
    amt = int(r.get("amount_cents") or 0)
    money = f" ${amt / 100:,.2f}" if amt else ""
    kind = "money" if str(r.get("request_type", "")).startswith("office_money") else str(r.get("risk") or "?")
    how = "tap its message" if r.get("request_type") == "action_approval" else "owner session"
    return (f"- [{kind}] {r.get('office') or 'group'}: {str(r.get('action') or '').replace('_', ' ')}{money} by {r.get('requester')}, "
            f"expires {str(r.get('expires_at') or '')[:10]} ({how}) id {str(r.get('source_id') or '')[:8]}")


def queue_text() -> str:
    rows = pending()
    if rows is None:
        return "Approval queue is not installed yet (migration pending)."
    if not rows:
        return "Nothing is waiting on you."
    return "\n".join([f"Waiting on you: {len(rows)}"] + [_line(r) for r in rows])
