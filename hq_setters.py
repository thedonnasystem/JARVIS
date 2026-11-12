"""Donna setter program: commission-only appointment setters. Tracks bookings, closes and what is owed.
Terms live in the database (setter_terms). The OWNER pays setters (Fridays); /setter paid records it. Nothing here moves money."""
from __future__ import annotations

import logging
import urllib.parse

import hq
from hq_payments import parse_amount

logger = logging.getLogger(__name__)


def _d(cents: int) -> str:
    return f"${cents / 100:,.2f}"


def _rpc(name: str, args: dict):
    return hq._request("POST", f"/rest/v1/rpc/{name}", args)


def add(name: str, contact: str = "", niche: str = "") -> str:
    try:
        _rpc("setter_add", {"p_name": name, "p_contact": contact or None, "p_niche": niche or None})
    except Exception as e:
        logger.warning("setter_add failed: %s", str(e)[:120])
        return "Could not save the setter (migration setters_v1 may not be applied yet)."
    return f"Setter {name.strip()} saved. They become active when they log their first booked appointment."


def log(name: str, kind: str, client: str = "", note: str = "") -> str:
    k = {"booked": "booked", "closed": "closed", "close": "closed", "cancelled": "client_cancelled", "canceled": "client_cancelled"}.get((kind or "").lower())
    if not k:
        return "Kind must be booked, closed or cancelled."
    try:
        r = _rpc("setter_log", {"p_name": name, "p_kind": k, "p_client": client or None, "p_note": note or None})
    except Exception as e:
        logger.warning("setter_log failed: %s", str(e)[:120])
        return "Could not log that (migration setters_v1 may not be applied yet)."
    if not isinstance(r, dict) or r.get("error"):
        return (r or {}).get("error", "Unreadable reply.")
    extra = " First booking: they are active now; add them to the group chat and send your personal contact." if r.get("first_booking") else ""
    return f"Logged {k} for {r['name']}.{extra}"


def standing() -> list[dict]:
    try:
        return hq._request("GET", "/rest/v1/setter_standing?select=*&status=neq.removed&order=closes.desc,booked.desc") or []
    except Exception as e:
        logger.warning("setter_standing failed: %s", str(e)[:120])
        return []


def paid(name: str, kind: str, amount_text: str, reference: str = "") -> str:
    cents = parse_amount(amount_text)
    if cents is None:
        return "Amount must be a positive number, like 120 or 1,250.50."
    try:
        r = _rpc("setter_record_payout", {"p_name": name, "p_kind": (kind or "").lower(), "p_cents": cents, "p_reference": reference or None, "p_period": None})
    except Exception as e:
        logger.warning("setter payout failed: %s", str(e)[:120])
        return "Could not record that payout."
    if not isinstance(r, dict) or r.get("error"):
        return (r or {}).get("error", "Unreadable reply.")
    return f"Recorded {_d(cents)} {kind} payout to {r['name']} and logged it as a Donna expense."


def owed_text() -> str:
    rows = standing()
    if not rows:
        return "No setters yet. /setter add <name> | <contact> | <niche>"
    lines, total = [], 0
    for s in rows:
        owed = int(s.get("owed_close_cents") or 0) + int(s.get("owed_recurring_cents") or 0)
        total += owed
        flag = "" if s.get("recurring_on") or int(s.get("closes") or 0) < 3 else " (recurring lapsed)"
        lines.append(f"- {s['name']} [{s['status']}]: {s['booked']} booked, {s['closes']} closed, {s['active_clients']} active clients; owed {_d(owed)}{flag}")
    return "Setters:\n" + "\n".join(lines) + f"\n\nOwed to setters now: {_d(total)}. Pay Fridays in RBC, then /setter paid <name> <close|recurring|bonus> <amount> <ref>."
