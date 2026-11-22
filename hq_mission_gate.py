"""Missions follow their office (FENDEZY GROUP Phase 1, M7 review): a mission whose venture belongs to an office that is not ACTIVE is refused at creation,
and a live mission is PAUSED (not failed) when its office stops being active, then resumed when the office is active again. Database reads/writes only,
no model calls. Hooked from hq_missions.create_mission and hq_missions.advance (each engine tick); hq_engine.py is not changed.

The group office is always active. A mission with no venture, or a database without the M1 office columns yet, behaves exactly as before.
Paused-by-office missions carry checkpoint.office_paused = <office slug>; the owner's own pause / resume (/mission) is never undone here.
"""
from __future__ import annotations

import logging
import urllib.error
import urllib.parse
from datetime import datetime, timezone

import hq

logger = logging.getLogger(__name__)
LIVE = ("captured", "evaluated", "planned", "executing", "verifying", "blocked")
ROW_LIMIT = 200
OFFICE_KEYS = ("office_paused", "office_paused_from")


def without_office_marks(checkpoint) -> dict:
    """The checkpoint minus this gate's marks: an owner pause / abandon must never be resumed by an office reactivation."""
    return {k: v for k, v in dict(checkpoint or {}).items() if k not in OFFICE_KEYS}


def _q(v) -> str:
    return urllib.parse.quote(str(v), safe="")


def _get(path: str, get=None) -> list:
    return (get or (lambda p: hq._request("GET", "/rest/v1/" + p) or []))(path) or []


def _patch(path: str, body: dict, patch=None) -> None:
    (patch or (lambda p, b: hq._request("PATCH", "/rest/v1/" + p, b, prefer="return=minimal")))(path, body)


def office_of_venture(venture_id, get=None) -> tuple[str, bool] | None:
    """(office slug, active?) for a venture, or None when there is nothing to gate (no venture, M1 not migrated). Unreadable office: not active."""
    if not venture_id:
        return None
    try:
        v = _get(f"ventures?id=eq.{_q(venture_id)}&select=office_id&limit=1", get)
    except urllib.error.HTTPError as e:
        if e.code in (400, 404):                    # no office_id column yet (M1 not applied): unchanged behaviour
            return None
        raise
    oid = (v[0] if v else {}).get("office_id")
    if not oid:
        return None
    o = _get(f"fz_offices?id=eq.{_q(oid)}&select=slug,kind,status&limit=1", get)
    if not o:
        return ("unknown", False)                    # fail closed: an office we cannot see is not active
    return (o[0].get("slug") or "unknown", o[0].get("kind") == "group" or o[0].get("status") == "active")


def create_refusal(venture_id, get=None) -> str | None:
    """None if a mission for this venture may be created; otherwise the reason (the office is not active)."""
    try:
        r = office_of_venture(venture_id, get)
    except Exception as e:
        return f"Refused: the venture's office could not be checked ({type(e).__name__}); try again."
    if r and not r[1]:
        return f"Refused: office {r[0]} is not active. Missions for it start only after the owner activates it."
    return None


def sweep(get=None, patch=None) -> dict:
    """Pause live missions of inactive offices; resume the ones this gate paused once their office is active again.
    An office whose status cannot be read is skipped this tick: nothing is paused or cancelled, but its missions are returned in 'blocked'
    so the caller does not advance them (fail closed without churn)."""
    paused, resumed, blocked = [], [], []
    sel = "&select=id,title,status,venture_id,plan,checkpoint&order=created_at.asc&limit=" + str(ROW_LIMIT)
    rows = _get("missions?status=in.(" + ",".join(LIVE) + ")" + sel, get)
    rows += _get("missions?status=eq.paused&checkpoint->>office_paused=not.is.null" + sel, get)   # only the ones this gate paused
    cache: dict = {}
    seen: set = set()
    for m in rows:
        if m["id"] in seen:
            continue
        seen.add(m["id"])
        vid = m.get("venture_id")
        if vid not in cache:
            try:
                cache[vid] = office_of_venture(vid, get)
            except Exception:
                logger.exception("mission office check failed: venture skipped this tick")
                cache[vid] = "unreadable"
        r = cache[vid]
        if r == "unreadable":
            if m["status"] in LIVE:
                blocked.append(m["id"])
            continue
        cp = dict(m.get("checkpoint") or {})
        if m["status"] in LIVE and r and not r[1]:
            cp["office_paused"] = r[0]
            cp["office_paused_from"] = m["status"]
            _patch(f"missions?id=eq.{_q(m['id'])}&status=eq.{_q(m['status'])}",
                   {"status": "paused", "checkpoint": cp, "next_action": f"Paused: office {r[0]} is not active; resumes when it is."}, patch)
            for t in _get(f"tasks?mission_id=eq.{_q(m['id'])}&status=eq.todo&select=id", get):
                _patch(f"tasks?id=eq.{_q(t['id'])}&status=eq.todo", {"status": "cancelled", "updated_at": datetime.now(timezone.utc).isoformat(),
                                                                       "result": f"Cancelled: office {r[0]} is not active (the mission is paused, not failed)."}, patch)
            paused.append(m["id"])
        elif m["status"] == "paused" and cp.get("office_paused") and (r is None or r[1]):
            plan = m.get("plan") or []
            for s in plan:                                   # steps cancelled by the pause run again
                if s.get("status") == "cancelled":
                    s["status"], s["task_id"] = "pending", None
            back = cp.pop("office_paused_from", None)
            cp.pop("office_paused", None)
            target = "executing" if plan else ("captured" if back in (None, "captured") else back)
            _patch(f"missions?id=eq.{_q(m['id'])}&status=eq.paused", {"status": target, "plan": plan, "checkpoint": cp,
                                                                       "next_action": "Resumed: the office is active again."}, patch)
            resumed.append(m["id"])
    return {"paused": paused, "resumed": resumed, "blocked": blocked}
