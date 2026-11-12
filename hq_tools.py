"""Tool and subscription registry: every recurring charge has an owner, a purpose and a price, and idle ones get flagged
(Master Plan: 'Monthly CFO audit: every recurring charge has an owner and a metric, and idle ones are cancelled').
Only the OWNER records prices and cancels here; HQ never cancels or pays anything on its own. Amounts are CAD."""
from __future__ import annotations

import logging
import re
import urllib.parse
from datetime import date, datetime, timedelta, timezone

import hq
from hq_payments import parse_amount

logger = logging.getLogger(__name__)
KINDS = ("api", "saas", "bot", "workflow", "number", "domain", "other")
IDLE_DAYS = 30


def _q(v: str) -> str:
    return urllib.parse.quote(str(v), safe="")


def _d(c) -> str:
    return f"${int(c or 0) / 100:,.2f}"


def _slug(s: str) -> str:
    return re.sub(r"[^a-z0-9]+", "-", (s or "").lower()).strip("-")[:40]


def add(name: str, kind: str, purpose: str, monthly_text: str = "0", status: str = "active") -> str:
    slug = _slug(name)
    kind = (kind or "other").lower()
    cents = parse_amount(monthly_text) if str(monthly_text).strip() not in ("0", "0.00", "free", "") else 0
    if len(slug) < 2 or kind not in KINDS or len((purpose or "").strip()) < 5 or cents is None:
        return f"Use: /tool add <name> | <{'/'.join(KINDS)}> | <what it is for> | <CAD per month or 0>"
    row = {"slug": slug, "kind": kind, "purpose": purpose.strip()[:200], "monthly_cost_cents": cents, "status": status if status in ("active", "trial") else "active",
           "last_used_at": datetime.now(timezone.utc).isoformat(), "review_by": (date.today() + timedelta(days=30)).isoformat()}
    try:
        hq._request("POST", "/rest/v1/tool_registry?on_conflict=slug", row, prefer="resolution=merge-duplicates,return=minimal")
    except Exception as e:
        logger.warning("tool add failed: %s", str(e)[:100])
        return "Could not save that tool."
    return f"Saved {slug}: {_d(cents)}/month, review by {row['review_by']}."


def mark(slug: str, what: str) -> str:
    slug = _slug(slug)
    patch = {"used": {"last_used_at": datetime.now(timezone.utc).isoformat(), "status": "active", "review_by": (date.today() + timedelta(days=30)).isoformat()},
             "cancel": {"status": "cancelled"}, "idle": {"status": "idle"}}.get(what)
    if not patch:
        return "Use /tool used <name>, /tool idle <name> or /tool cancel <name> (cancel here only records it; you cancel with the vendor)."
    try:
        r = hq._request("PATCH", f"/rest/v1/tool_registry?slug=eq.{_q(slug)}", patch, prefer="return=representation")
    except Exception as e:
        logger.warning("tool mark failed: %s", str(e)[:100])
        return "Could not update that tool."
    return f"Marked {slug} {what}." if r else f"No tool called {slug}."


def audit(rows: list[dict], today: date | None = None) -> dict:
    """-> {'active_cents', 'flags': [(slug, reason, cents)]}. Pure, so it is testable."""
    today = today or date.today()
    flags, total = [], 0
    for r in rows:
        if r.get("status") not in ("active", "trial", "idle"):
            continue
        cents = int(r.get("monthly_cost_cents") or 0)
        if r.get("status") != "idle":
            total += cents
        last = (r.get("last_used_at") or "")[:10]
        reason = None
        if r.get("status") == "idle":
            reason = "marked idle but still listed: cancel it or use it"
        elif cents and not last:
            reason = "paid but never recorded as used"
        elif cents and last and (today - date.fromisoformat(last)).days > IDLE_DAYS:
            reason = f"not used in {(today - date.fromisoformat(last)).days} days"
        elif r.get("review_by") and r["review_by"] < today.isoformat():
            reason = f"review date {r['review_by']} has passed"
        if reason:
            flags.append((r["slug"], reason, cents))
    return {"active_cents": total, "flags": flags}


def text() -> str:
    try:
        rows = hq._request("GET", "/rest/v1/tool_registry?select=slug,kind,purpose,monthly_cost_cents,status,last_used_at,review_by&order=monthly_cost_cents.desc") or []
    except Exception as e:
        logger.warning("tool list failed: %s", str(e)[:100])
        return "Tool registry unavailable."
    if not rows:
        return "No tools recorded yet. Add each recurring charge: /tool add Retell | api | AI phone calls | 0   (price in CAD per month)."
    a = audit(rows)
    lines = [f"Recurring tools: {_d(a['active_cents'])}/month across {sum(1 for r in rows if r['status'] in ('active', 'trial'))} active."]
    lines += [f"- {r['slug']} ({r['kind']}) {_d(r['monthly_cost_cents'])}/mo [{r['status']}]: {r['purpose'][:60]}" for r in rows if r["status"] != "cancelled"][:25]
    if a["flags"]:
        lines.append("Review these (idle spend is a leak):")
        lines += [f"  ! {s}: {why}" + (f" ({_d(c)}/mo)" if c else "") for s, why, c in a["flags"]]
    return "\n".join(lines)
