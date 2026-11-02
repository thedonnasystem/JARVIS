"""Owner-only Telegram commands for Fendezy HQ.

/hq                      company status: spend, tasks, escalations, leads, memory, heartbeat
/kill  /resume           stop or restart every agent (the spend gateway refuses all calls while killed)
/money <in|out> <amount> [venture] [note]   log revenue or an expense in CAD
/ask <agent> <task>      put a task on an agent's board (research/drafting only in dry-run)
/agents                  list agent slugs
/leads                   lead counts per venture
"""
from __future__ import annotations

import logging
import os
import re
import urllib.parse
from datetime import datetime, timezone

import hq

logger = logging.getLogger(__name__)

VENTURE_ALIASES = {
    "dayjob": "day-job-sales", "day-job": "day-job-sales", "sales": "day-job-sales", "energy": "day-job-sales",
    "donna": "donna", "hvac": "donna", "aaa": "donna",
    "re": "real-estate", "realestate": "real-estate", "real-estate": "real-estate", "wholesale": "real-estate",
    "lab": "idea-lab", "ideas": "idea-lab", "idea-lab": "idea-lab", "new": "idea-lab",
}


def _owner(update) -> bool:
    owner = os.environ.get("JARVIS_OWNER_ID")
    return bool(owner) and str(update.effective_user.id) == str(owner)


def _q(v: str) -> str:
    return urllib.parse.quote(str(v), safe="")


def _get(path: str) -> list:
    return hq._request("GET", f"/rest/v1/{path}") or []


def _count(path: str) -> int:
    return len(_get(path))


def _venture_id(word: str | None) -> tuple[str | None, str | None]:
    if not word:
        return None, None
    slug = VENTURE_ALIASES.get(word.lower())
    if not slug:
        return None, None
    rows = _get(f"ventures?slug=eq.{_q(slug)}&select=id,slug&limit=1")
    return (rows[0]["id"], rows[0]["slug"]) if rows else (None, None)


def parse_amount(s: str) -> int | None:
    """'1,250.50' or '$450' -> cents. None if not a positive number."""
    m = re.fullmatch(r"\$?\s*([0-9][0-9,]*)(?:\.([0-9]{1,2}))?", s.strip())
    if not m:
        return None
    dollars = int(m.group(1).replace(",", ""))
    cents = int((m.group(2) or "0").ljust(2, "0"))
    total = dollars * 100 + cents
    return total if total > 0 else None


def status_text() -> str:
    state = (_get("system_state?id=eq.1&select=kill_switch,mode,daily_spend_cap_cents,last_heartbeat") or [{}])[0]
    since = datetime.now(timezone.utc).replace(hour=0, minute=0, second=0).strftime("%Y-%m-%dT%H:%M:%SZ")
    calls = _get(f"llm_calls?started_at=gte.{since}&status=in.(reserved,done)&select=actual_cents,reserved_cents")
    spent = sum((c.get("actual_cents") if c.get("actual_cents") is not None else c.get("reserved_cents") or 0) for c in calls)
    hb = state.get("last_heartbeat")
    hb_txt = "never"
    if hb:
        age = (datetime.now(timezone.utc) - datetime.fromisoformat(hb.replace("Z", "+00:00"))).total_seconds() / 60
        hb_txt = f"{age:.0f} min ago"
    lines = [
        "Fendezy HQ",
        f"- Mode: {state.get('mode')}  Kill switch: {'ON' if state.get('kill_switch') else 'off'}",
        f"- Spend today (UTC): ${spent/100:.2f} of ${(state.get('daily_spend_cap_cents') or 0)/100:.2f}",
        f"- Engine heartbeat: {hb_txt}",
        f"- Tasks: {_count('tasks?status=eq.todo&select=id')} queued, {_count('tasks?status=eq.doing&select=id')} running, "
        f"{_count('tasks?status=eq.blocked&select=id')} blocked, {_count('tasks?status=eq.done&select=id')} done",
        f"- Open escalations: {_count('escalations?status=in.(open,with_jarvis)&select=id')}",
        f"- Leads: {_count('leads?select=id')}   Memory items: {_count('memory?select=id')}",
    ]
    return "\n".join(lines)


async def hq_status(update, context) -> None:
    if not _owner(update):
        return
    try:
        await update.message.reply_text(status_text())
    except Exception as e:
        logger.exception("HQ status failed")
        await update.message.reply_text(f"HQ status failed: {str(e)[:200]}")


async def _set_kill(update, on: bool) -> None:
    if not _owner(update):
        return
    hq._request("PATCH", "/rest/v1/system_state?id=eq.1", {"kill_switch": on}, prefer="return=minimal")
    hq._request("POST", "/rest/v1/audit_log", {"actor": "owner", "action": "kill_switch_on" if on else "kill_switch_off",
                                               "target": "system_state", "detail": {"via": "telegram"}}, prefer="return=minimal")
    await update.message.reply_text("All agents stopped. /resume to restart." if on else "Agents running again.")


async def hq_kill(update, context) -> None:
    await _set_kill(update, True)


async def hq_resume(update, context) -> None:
    await _set_kill(update, False)


async def hq_money(update, context) -> None:
    if not _owner(update):
        return
    args = context.args or []
    if len(args) < 2 or args[0].lower() not in ("in", "out"):
        await update.message.reply_text("Use: /money in 450 dayjob commission Nov   or   /money out 29 donna twilio")
        return
    cents = parse_amount(args[1])
    if cents is None:
        await update.message.reply_text("Amount must be a positive number, like 450 or 1,250.50")
        return
    vid, vslug = _venture_id(args[2] if len(args) > 2 else None)
    note = " ".join(args[3:] if vid else args[2:])[:300]
    kind = "revenue" if args[0].lower() == "in" else "expense"
    hq._request("POST", "/rest/v1/ledger", {"venture_id": vid, "kind": kind, "amount_cents": cents, "currency": "CAD",
                                            "status": "received", "note": note or None,
                                            "occurred_on": datetime.now().date().isoformat()}, prefer="return=minimal")
    await update.message.reply_text(f"Logged {kind}: ${cents/100:,.2f} CAD{(' to ' + vslug) if vslug else ''}.")


async def hq_ask(update, context) -> None:
    if not _owner(update):
        return
    args = context.args or []
    if len(args) < 2:
        await update.message.reply_text("Use: /ask donna-researcher find 10 Ottawa HVAC companies with no online booking")
        return
    slug, text = args[0].lower(), " ".join(args[1:])
    rows = _get(f"agents?slug=eq.{_q(slug)}&select=slug,venture_id,status&limit=1")
    if not rows:
        await update.message.reply_text(f"No agent called {slug}. /agents lists them.")
        return
    hq._request("POST", "/rest/v1/tasks", {
        "assigned_agent": slug, "venture_id": rows[0].get("venture_id"), "created_by": "owner", "priority": 1,
        "status": "todo", "title": text[:140],
        "detail": text + "\n\nAsked directly by the owner. Research or drafting only: no contacting anyone, no spending, no signing.",
    }, prefer="return=minimal")
    await update.message.reply_text(f"Queued for {slug}. It runs within about 5 minutes; Jarvis reports anything that matters.")


async def hq_agents(update, context) -> None:
    if not _owner(update):
        return
    rows = _get("agents?status=eq.active&select=slug&order=slug.asc")
    await update.message.reply_text("Agents:\n" + "\n".join(r["slug"] for r in rows))


async def hq_leads(update, context) -> None:
    if not _owner(update):
        return
    ventures = {v["id"]: v["slug"] for v in _get("ventures?select=id,slug")}
    counts: dict[str, int] = {}
    for r in _get("leads?select=venture_id&limit=5000"):
        name = ventures.get(r.get("venture_id"), "unassigned")
        counts[name] = counts.get(name, 0) + 1
    if not counts:
        await update.message.reply_text("No leads yet.")
        return
    await update.message.reply_text("Leads:\n" + "\n".join(f"- {k}: {v}" for k, v in sorted(counts.items())))


def register(app, CommandHandler) -> None:
    for name, fn in (("hq", hq_status), ("kill", hq_kill), ("resume", hq_resume), ("money", hq_money),
                     ("ask", hq_ask), ("agents", hq_agents), ("leads", hq_leads)):
        app.add_handler(CommandHandler(name, fn))
