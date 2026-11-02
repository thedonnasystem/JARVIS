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
    from zoneinfo import ZoneInfo
    local_midnight = datetime.now(ZoneInfo("America/Toronto")).replace(hour=0, minute=0, second=0, microsecond=0)
    since = local_midnight.astimezone(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
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
        f"- Spend today: ${spent/100:.2f} of ${(state.get('daily_spend_cap_cents') or 0)/100:.2f}",
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


async def hq_brief(update, context) -> None:
    if not _owner(update):
        return
    try:
        text = hq._request("POST", "/rest/v1/rpc/daily_brief_text", {}) or "No brief available."
    except Exception as e:
        text = f"Brief failed: {str(e)[:200]}"
    await update.message.reply_text(str(text)[:4000])


async def hq_ideas(update, context) -> None:
    if not _owner(update):
        return
    rows = _get("ideas?status=in.(new,testing,scaled)&order=score.desc.nullslast&limit=10"
                "&select=name,status,score,startup_cost_cents,test_ends_on,kill_metric")
    if not rows:
        await update.message.reply_text("No ideas in the lab.")
        return
    out = []
    for r in rows:
        tag = f"TESTING until {r['test_ends_on']}" if r["status"] == "testing" else r["status"]
        out.append(f"- {r['name']} [{tag}] score {r.get('score')}, start ${(r.get('startup_cost_cents') or 0)/100:,.0f}")
    await update.message.reply_text("Idea lab (best first):\n" + "\n".join(out) + "\n\nStart a 7-day test: /testidea <name>   Park: /parkidea <name>")


async def _set_idea_status(update, context, status: str) -> None:
    if not _owner(update):
        return
    frag = " ".join(context.args or []).strip()
    if len(frag) < 3:
        await update.message.reply_text("Give at least 3 letters of the idea's name.")
        return
    rows = _get(f"ideas?name=ilike.*{_q(frag)}*&select=id,name&limit=2")
    if len(rows) != 1:
        await update.message.reply_text("No match." if not rows else "More than one match; be more specific.")
        return
    try:
        hq._request("PATCH", f"/rest/v1/ideas?id=eq.{_q(rows[0]['id'])}", {"status": status}, prefer="return=minimal")
    except Exception as e:
        msg = str(e)
        try:
            import json as _j
            msg = _j.loads(e.read().decode()).get("message", msg)
        except Exception:
            pass
        await update.message.reply_text(f"Not changed: {msg[:200]}")
        return
    await update.message.reply_text(f"{rows[0]['name']} is now {status}." + (" 7-day test clock started." if status == "testing" else ""))


async def hq_testidea(update, context) -> None:
    await _set_idea_status(update, context, "testing")


async def hq_parkidea(update, context) -> None:
    await _set_idea_status(update, context, "parked")


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


DAYJOB_SLUG = "day-job-sales"
DEFAULT_FOLLOWUP_DAYS = 2


def _toronto_today():
    from zoneinfo import ZoneInfo
    return datetime.now(ZoneInfo("America/Toronto")).date()


def parse_lead(text: str) -> dict | None:
    """'Jane Doe | 613-555-0101 | wants fixed rate | 3' -> fields. Name required; phone, note, days optional."""
    parts = [p.strip() for p in text.split("|")]
    if not parts or not parts[0]:
        return None
    days = DEFAULT_FOLLOWUP_DAYS
    if len(parts) >= 4 and parts[3].isdigit():
        days = int(parts[3])
    phone = parts[1] if len(parts) > 1 else ""
    if phone and not re.fullmatch(r"[0-9+()\-.\s]{7,20}", phone):
        return None
    return {"name": parts[0][:120], "phone": phone or None, "note": (parts[2] if len(parts) > 2 else "")[:300], "days": min(days, 90)}


async def hq_lead(update, context) -> None:
    if not _owner(update):
        return
    lead = parse_lead(" ".join(context.args or []))
    if not lead:
        await update.message.reply_text("Use: /lead Jane Doe | 613-555-0101 | wants fixed rate | 3\n(name | phone | note | follow up in N days)")
        return
    vid, _ = _venture_id("dayjob")
    from datetime import timedelta
    due = _toronto_today() + timedelta(days=lead["days"])
    rows = hq._request("POST", "/rest/v1/leads", {
        "venture_id": vid, "name": lead["name"], "phone": lead["phone"], "source": "owner", "status": "new",
        "consent_basis": "owner-entered; owner dials personally", "do_not_contact": False,
        "notes": lead["note"] or None, "next_followup_at": due.isoformat(),
    }, prefer="return=representation") or [{}]
    await update.message.reply_text(f"Saved #{rows[0].get('short_id', '?')} {lead['name']}. Follow up {due:%a %b %d}.")


async def hq_done(update, context) -> None:
    """/done <#id> [days] [outcome...]  -- logs a contact and sets the next follow-up (0 days = close it)."""
    if not _owner(update):
        return
    args = context.args or []
    if not args or not args[0].lstrip("#").isdigit():
        await update.message.reply_text("Use: /done 12 3 left voicemail   (lead #, follow up in N days, note). /done 12 0 signed  closes it.")
        return
    sid = int(args[0].lstrip("#"))
    days = int(args[1]) if len(args) > 1 and args[1].isdigit() else DEFAULT_FOLLOWUP_DAYS
    outcome = " ".join(args[2:] if len(args) > 1 and args[1].isdigit() else args[1:])[:200]
    rows = _get(f"leads?short_id=eq.{sid}&select=id,name,notes,contact_count&limit=1")
    if not rows:
        await update.message.reply_text(f"No lead #{sid}.")
        return
    lead = rows[0]
    from datetime import timedelta
    stamp = _toronto_today().isoformat()
    notes = ((lead.get("notes") or "") + (f"\n{stamp}: {outcome}" if outcome else f"\n{stamp}: contacted")).strip()[-2000:]
    body = {"last_contact_at": datetime.now(timezone.utc).isoformat(), "contact_count": (lead.get("contact_count") or 0) + 1,
            "notes": notes, "status": "contacted"}
    if days == 0:
        body.update({"next_followup_at": None, "status": "closed"})
        reply = f"#{sid} {lead['name']} closed."
    else:
        due = _toronto_today() + timedelta(days=days)
        body["next_followup_at"] = due.isoformat()
        reply = f"#{sid} {lead['name']} logged. Next follow-up {due:%a %b %d}."
    hq._request("PATCH", f"/rest/v1/leads?id=eq.{_q(lead['id'])}", body, prefer="return=minimal")
    await update.message.reply_text(reply)


async def hq_due(update, context) -> None:
    if not _owner(update):
        return
    today = _toronto_today().isoformat()
    rows = _get(f"leads?next_followup_at=lte.{today}&do_not_contact=eq.false&status=neq.closed"
                "&order=next_followup_at.asc&limit=30&select=short_id,name,phone,notes,next_followup_at")
    if not rows:
        await update.message.reply_text("No follow-ups due.")
        return
    lines = [f"#{r['short_id']} {r['name']}  {r.get('phone') or ''}  ({r['next_followup_at']})" for r in rows]
    await update.message.reply_text("Due now:\n" + "\n".join(lines) + "\n\nAfter each call: /done <#> <days> <note>")


DECISION_TABLES = {"escalations", "outbox"}


def apply_decision(msg_id: str, approved: bool) -> str:
    """Record the owner's tap. Returns a short status line. Idempotent: a second tap changes nothing."""
    verdict = "approved" if approved else "rejected"
    now = datetime.now(timezone.utc).isoformat()
    claimed = hq._request("PATCH", f"/rest/v1/owner_messages?id=eq.{_q(msg_id)}&decision=is.null&needs_decision=eq.true",
                          {"decision": verdict, "decided_at": now}, prefer="return=representation") or []
    if not claimed:
        return "Already decided."
    msg = claimed[0]
    ref_table, ref_id = msg.get("ref_table"), msg.get("ref_id")
    if ref_table == "escalations" and ref_id:
        hq._request("PATCH", f"/rest/v1/escalations?id=eq.{_q(ref_id)}",
                    {"status": "closed", "resolution": f"Owner {verdict}", "resolved_at": now}, prefer="return=minimal")
        esc = _get(f"escalations?id=eq.{_q(ref_id)}&select=summary&limit=1")
        if esc:
            import hq_engine
            hq_engine.unblock_task_for(esc[0].get("summary") or "")
    elif ref_table == "outbox" and ref_id:
        hq._request("PATCH", f"/rest/v1/outbox?id=eq.{_q(ref_id)}&status=in.(draft,qa_passed)",
                    {"status": verdict, "decided_at": now}, prefer="return=minimal")
    hq._request("POST", "/rest/v1/memory", {"agent": "owner", "kind": "decision", "confidence": "high",
                                            "content": f"Owner {verdict}: {(msg.get('body') or '')[:500]}"}, prefer="return=minimal")
    hq._request("POST", "/rest/v1/audit_log", {"actor": "owner", "action": f"decision_{verdict}", "target": f"owner_messages/{msg_id}",
                                               "detail": {"ref_table": ref_table, "ref_id": ref_id, "via": "telegram"}}, prefer="return=minimal")
    return f"Decision saved: {verdict.upper()}. Agents will follow it."


async def hq_decision_callback(update, context) -> None:
    query = update.callback_query
    if not _owner(update):
        await query.answer()
        return
    try:
        _, choice, msg_id = query.data.split(":", 2)
        result = apply_decision(msg_id, choice == "ok")
    except Exception as e:
        logger.exception("HQ decision failed")
        result = f"Could not save the decision: {str(e)[:150]}"
    await query.answer(result[:190])
    try:
        await query.edit_message_reply_markup(reply_markup=None)
        await query.message.reply_text(result)
    except Exception:
        pass


MENU = [
    ("hq", "Company status"), ("brief", "Full daily brief now"), ("due", "Follow-ups due now"), ("lead", "Save a lead: name | phone | note | days"),
    ("done", "Log a call: # days note"), ("money", "Log money: in/out amount venture note"),
    ("ask", "Give an agent a task"), ("ideas", "Idea lab, best first"), ("testidea", "Start a 7-day test"), ("parkidea", "Park an idea"), ("agents", "List agents"), ("leads", "Lead counts"),
    ("kill", "Stop all agents"), ("resume", "Restart agents"),
]


async def set_menu(app) -> None:
    """Show HQ commands in Telegram's menu, keeping the bot's existing ones."""
    try:
        from telegram import BotCommand
        existing = await app.bot.get_my_commands()
        names = {c.command for c in existing}
        cmds = list(existing) + [BotCommand(n, d[:256]) for n, d in MENU if n not in names]
        await app.bot.set_my_commands(cmds[:100])
    except Exception as e:
        logger.warning("HQ: could not set the command menu: %s", e)


def register(app, CommandHandler, CallbackQueryHandler=None) -> None:
    for name, fn in (("hq", hq_status), ("kill", hq_kill), ("resume", hq_resume), ("money", hq_money),
                     ("ask", hq_ask), ("agents", hq_agents), ("leads", hq_leads),
                     ("lead", hq_lead), ("done", hq_done), ("due", hq_due), ("brief", hq_brief),
                     ("ideas", hq_ideas), ("testidea", hq_testidea), ("parkidea", hq_parkidea)):
        app.add_handler(CommandHandler(name, fn))
    if CallbackQueryHandler is not None:
        app.add_handler(CallbackQueryHandler(hq_decision_callback, pattern=r"^hqd:"))
    if getattr(app, "job_queue", None) is not None:
        app.job_queue.run_once(_menu_job, when=10, name="hq-menu")


async def _menu_job(context) -> None:
    await set_menu(context.application)
