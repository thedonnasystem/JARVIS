"""Owner-only Telegram commands for Fendezy HQ.

/hq                      company status: spend, tasks, escalations, leads, memory, heartbeat
/kill  /resume           stop or restart every agent (the spend gateway refuses all calls while killed)
/money <in|out> <amount> [venture] [note]   log revenue or an expense in CAD
/ask <agent> <task>      put a task on an agent's board (research/drafting only in dry-run)
/agents                  list agent slugs
/leads                   lead counts per venture
"""
from __future__ import annotations

import asyncio

import logging
import os
import re
import urllib.parse
from datetime import datetime, timezone

import hq
import hq_missions
import hq_policy
import hq_bank
import hq_dev
import hq_sites
import hq_setters
import hq_verify
import hq_waterfall
import hq_succession
import hq_tools
import hq_org
import hq_ventures
import hq_venture_ops
import hq_mail
import hq_capital
import hq_payments
import hq_accounts
import hq_office
import hq_inbox  # hqui

logger = logging.getLogger(__name__)

VENTURE_ALIASES = {
    "dayjob": "day-job-sales", "day-job": "day-job-sales", "sales": "day-job-sales", "energy": "day-job-sales",
    "donna": "donna", "hvac": "donna", "aaa": "donna",
    "re": "real-estate", "realestate": "real-estate", "real-estate": "real-estate", "wholesale": "real-estate",
    "lab": "idea-lab", "ideas": "idea-lab", "idea-lab": "idea-lab", "new": "idea-lab",
}


def _owner(update) -> bool:
    owner = os.environ.get("JARVIS_OWNER_ID")
    ok = bool(owner) and str(update.effective_user.id) == str(owner)
    if ok:
        hq_waterfall.touch()
    return ok


def _q(v: str) -> str:
    return urllib.parse.quote(str(v), safe="")


def _get(path: str) -> list:
    return hq._request("GET", f"/rest/v1/{path}") or []


def _count(path: str) -> int:
    return len(_get(path))


COMPANY_WORDS = ("company", "holding", "all")  # explicit words for "not a venture" in /money


def resolve_venture(word: str | None) -> tuple[str | None, str | None, str | None]:
    """Venture argument -> (id, slug, error). Order: the old short aliases (unchanged), then a real slug, then a venture name.
    An empty word is (None, None, None). An unknown word is an error, never a silent fall-through to company-wide."""
    w = (word or "").strip().lstrip("@").lower()
    if not w:
        return None, None, None
    slug = VENTURE_ALIASES.get(w)
    if slug:
        rows = _get(f"ventures?slug=eq.{_q(slug)}&select=id,slug&limit=1")
        if rows:
            return rows[0]["id"], rows[0]["slug"], None
    norm = re.sub(r"[^a-z0-9]+", "-", w).strip("-")
    if norm:
        rows = _get(f"ventures?slug=eq.{_q(norm)}&select=id,slug&limit=1")
        if rows:
            return rows[0]["id"], rows[0]["slug"], None
        for r in _get("ventures?select=id,slug,name&limit=500"):  # name match, exact, case-insensitive
            if re.sub(r"[^a-z0-9]+", "-", (r.get("name") or "").lower()).strip("-") == norm:
                return r["id"], r["slug"], None
    return None, None, f"No venture called '{word}'. /venture list shows them."


def _venture_id(word: str | None) -> tuple[str | None, str | None]:
    vid, vslug, _ = resolve_venture(word)
    return vid, vslug


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
    vid, vslug, err = resolve_venture(args[2] if len(args) > 2 else None)
    company = len(args) > 2 and args[2].lower() in COMPANY_WORDS and not vid
    if err and not company:
        await update.message.reply_text(err + " Use a venture name, or the word 'company' for a company-wide entry.")
        return
    note = " ".join(args[3:] if (vid or company) else args[2:])[:300]
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
        # not an agent: maybe a venture, which routes to its manager
        vid, vslug, _err = resolve_venture(slug)
        mgr = (_get(f"ventures?id=eq.{_q(vid)}&select=manager_agent&limit=1") or [{}])[0].get("manager_agent") if vid else None
        rows = _get(f"agents?slug=eq.{_q(mgr)}&select=slug,venture_id,status&limit=1") if mgr else []
        if not rows:
            await update.message.reply_text(f"No agent or venture called {slug}. /agents and /venture list show them.")
            return
        slug = rows[0]["slug"]
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
    # --- hqui begin: inbox count in the brief ---
    text = hq_inbox.append_to_brief(str(text))
    # --- hqui end ---
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


def set_idea_status_by_id(idea_id: str, status: str) -> str:
    """Move an idea to testing/parked (the database enforces the gates, e.g. test budget). Shared with the app."""
    if status not in ("testing", "parked"):
        return "Unknown idea action."
    rows = _get(f"ideas?id=eq.{_q(idea_id)}&select=id,name&limit=1")
    if not rows:
        return "No such idea."
    try:
        hq._request("PATCH", f"/rest/v1/ideas?id=eq.{_q(idea_id)}", {"status": status}, prefer="return=minimal")
    except Exception as e:
        msg = str(e)
        try:
            import json as _j
            msg = _j.loads(e.read().decode()).get("message", msg)
        except Exception:
            pass
        return f"Not changed: {msg[:200]}"
    return f"{rows[0]['name']} is now {status}." + (" 7-day test clock started." if status == "testing" else "")


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


async def hq_drafts(update, context) -> None:
    if not _owner(update):
        return
    rows = _get("outbox?status=eq.draft&order=created_at.asc&limit=5&select=id,body,to_ref,agent")
    if not rows:
        await update.message.reply_text("No drafts waiting.")
        return
    for r in rows:
        body = f"Draft by {r.get('agent')} to {r.get('to_ref') or 'unknown'}:\n\n{r['body']}"[:3500]
        msg = (hq._request("POST", "/rest/v1/owner_messages", {
            "from_agent": "jarvis", "kind": "proposal", "channel": "telegram", "body": body, "needs_decision": True,
            "ref_table": "outbox", "ref_id": r["id"], "sent_at": datetime.now(timezone.utc).isoformat(),
        }, prefer="return=representation") or [{}])[0]
        await update.message.reply_text(body, reply_markup=hq.decision_buttons(msg["id"]) if msg.get("id") else None)


def mark_sent(outbox_id: str) -> str:
    """The owner sent an approved email himself: record it and set the 3-day follow-up. Shared by /sent and the app."""
    now = datetime.now(timezone.utc).isoformat()
    rows = _get(f"outbox?id=eq.{_q(outbox_id)}&status=eq.approved&select=id,lead_id&limit=1")
    if not rows:
        return "No approved draft with that id."
    body = {"status": "sent", "sent_at": now, "sent_by": "owner"}
    try:
        hq._request("PATCH", f"/rest/v1/outbox?id=eq.{_q(rows[0]['id'])}", body, prefer="return=minimal")
    except Exception:  # before the sent_by migration: record it the old way
        body.pop("sent_by")
        hq._request("PATCH", f"/rest/v1/outbox?id=eq.{_q(rows[0]['id'])}", body, prefer="return=minimal")
    if rows[0].get("lead_id"):
        from datetime import timedelta
        due = (_toronto_today() + timedelta(days=3)).isoformat()
        hq._request("PATCH", f"/rest/v1/leads?id=eq.{_q(rows[0]['lead_id'])}",
                    {"status": "contacted", "last_contact_at": now, "next_followup_at": due}, prefer="return=minimal")
    return "Marked sent. Follow-up reminder set for 3 days from now."


def draft_decision(outbox_id: str, approved: bool) -> str:
    """Approve or reject a draft from the app: same path as the Telegram buttons (owner is the QA step)."""
    open_ = _get(f"owner_messages?ref_table=eq.outbox&ref_id=eq.{_q(outbox_id)}&decision=is.null&needs_decision=eq.true&limit=1&select=id")
    if open_:
        msg_id = open_[0]["id"]
    else:
        d = _get(f"outbox?id=eq.{_q(outbox_id)}&status=in.(draft,qa_passed)&select=id,body,to_ref,agent&limit=1")
        if not d:
            return "That draft is not waiting for a decision."
        r = d[0]
        made = (hq._request("POST", "/rest/v1/owner_messages", {
            "from_agent": "jarvis", "kind": "proposal", "channel": "telegram", "needs_decision": True, "ref_table": "outbox", "ref_id": r["id"],
            "body": f"Draft by {r.get('agent')} to {r.get('to_ref') or 'unknown'}:\n\n{r['body']}"[:3500],
            "sent_at": datetime.now(timezone.utc).isoformat()}, prefer="return=representation") or [{}])[0]
        msg_id = made.get("id")
        if not msg_id:
            return "Could not record the decision."
    return apply_decision(msg_id, approved)


async def hq_sent(update, context) -> None:
    """/sent <first 8 chars of draft id>: the owner sent an approved email himself."""
    if not _owner(update):
        return
    frag = (context.args or [""])[0].strip().lower()
    if not re.fullmatch(r"[0-9a-f]{8}", frag):
        await update.message.reply_text("Use: /sent <8-character code from the approval message>")
        return
    rows = [r for r in _get("outbox?status=eq.approved&select=id,lead_id&limit=200") if r["id"].startswith(frag)]
    if len(rows) != 1:
        await update.message.reply_text("No approved draft with that code.")
        return
    await update.message.reply_text(mark_sent(rows[0]["id"]))


async def hq_systems_cmd(update, context) -> None:
    if not _owner(update):
        return
    import hq_systems
    await update.message.reply_text("Systems:\n" + "\n".join(hq_systems.status_lines()))


def log_day(d: int, p: int, sub: int) -> str:
    """Today's sales numbers (overwrites today's entry). Shared by /day and the app."""
    today = _toronto_today().isoformat()
    hq._request("POST", "/rest/v1/dayjob_days?on_conflict=day",
                {"day": today, "dials": d, "pitches": p, "submissions": sub, "updated_at": datetime.now(timezone.utc).isoformat()},
                prefer="resolution=merge-duplicates,return=minimal")
    t = (_get("dayjob_targets?id=eq.1&select=*") or [{}])[0]
    marks = [f"dials {d}/{t.get('dials_per_day', 250)}", f"pitches {p}/{t.get('pitches_per_day', 6)}",
             f"submissions {sub}/{t.get('submissions_per_day', 2)}"]
    week = hq._request("POST", "/rest/v1/rpc/dayjob_week_text", {}) or ""
    return "Logged: " + ", ".join(marks) + f"\n{week}"


async def hq_day(update, context) -> None:
    """/day <dials> <pitches> <submissions>: log today's sales numbers (overwrites today's entry)."""
    if not _owner(update):
        return
    args = context.args or []
    if len(args) != 3 or not all(a.isdigit() for a in args):
        await update.message.reply_text("Use: /day 280 6 2   (dials pitches submissions for today)")
        return
    await update.message.reply_text(log_day(*(int(a) for a in args)))


def log_paid(who: str = "") -> str:
    """A deal paid out after install: counts toward the weekly target and logs revenue. Shared by /paid and the app."""
    who = (who or "")[:120]
    t = (_get("dayjob_targets?id=eq.1&select=payout_cents_per_deal") or [{}])[0]
    cents = int(t.get("payout_cents_per_deal") or 100000)
    today = _toronto_today().isoformat()
    row = (_get(f"dayjob_days?day=eq.{today}&select=paid_deals") or [{}])[0]
    hq._request("POST", "/rest/v1/dayjob_days?on_conflict=day",
                {"day": today, "paid_deals": int(row.get("paid_deals") or 0) + 1,
                 "updated_at": datetime.now(timezone.utc).isoformat()},
                prefer="resolution=merge-duplicates,return=minimal")
    vid, _ = _venture_id("dayjob")
    hq._request("POST", "/rest/v1/ledger", {"venture_id": vid, "kind": "revenue", "amount_cents": cents, "currency": "CAD",
                                            "status": "received", "note": f"Paid deal {who}".strip(),
                                            "occurred_on": today}, prefer="return=minimal")
    week = hq._request("POST", "/rest/v1/rpc/dayjob_week_text", {}) or ""
    return f"Paid deal logged (+${cents/100:,.0f}).\n{week}"


async def hq_paid(update, context) -> None:
    """/paid [name]: a deal paid out after install."""
    if not _owner(update):
        return
    await update.message.reply_text(log_paid(" ".join(context.args or [])))


NIGHT_MAX_CENTS = 2000  # $20 hard ceiling, same as budget proposals


def _next_7am_utc() -> str:
    from datetime import timedelta
    from zoneinfo import ZoneInfo
    tz = ZoneInfo("America/Toronto")
    now = datetime.now(tz)
    seven = now.replace(hour=7, minute=0, second=0, microsecond=0)
    if now >= seven:
        seven += timedelta(days=1)
    return seven.astimezone(timezone.utc).isoformat()


async def hq_nightshift(update, context) -> None:
    """/nightshift [dollars]: StarNet-style Night Shift. Overnight budget leash, backlog queued, cap restored at 7am,
    and a morning report of every task worked and what it cost."""
    if not _owner(update):
        return
    args = context.args or []
    if args and args[0].lower() in ("off", "stop", "end"):
        st = (_get("system_state?id=eq.1&select=day_cap_cents,night_until") or [{}])[0]
        if not st.get("night_until"):
            await update.message.reply_text("Night Shift isn't running.")
            return
        hq._request("PATCH", "/rest/v1/system_state?id=eq.1", {"daily_spend_cap_cents": st.get("day_cap_cents") or 330,
                    "night_until": datetime.now(timezone.utc).isoformat()}, prefer="return=minimal")
        await update.message.reply_text("Night Shift ending. The normal cap is back, and the report arrives within 5 minutes.")
        return
    cents = parse_amount(args[0]) if args else 500
    if not cents:
        await update.message.reply_text("Use: /nightshift 8   (overnight AI budget in dollars, max $20)   or /nightshift off")
        return
    cents = min(cents, NIGHT_MAX_CENTS)
    st = (_get("system_state?id=eq.1&select=daily_spend_cap_cents,night_until,pause_reason") or [{}])[0]
    if st.get("pause_reason") == "api_credits":
        await update.message.reply_text("Can't start Night Shift: the Anthropic API account is out of credit. Top up at "
                                        "console.anthropic.com > Settings > Billing, then try again.")
        return
    day_cap = st.get("daily_spend_cap_cents") or 330
    if st.get("night_until"):  # already running: just change the leash
        hq._request("PATCH", "/rest/v1/system_state?id=eq.1", {"daily_spend_cap_cents": cents}, prefer="return=minimal")
        await update.message.reply_text(f"Night Shift budget changed to ${cents/100:.2f}.")
        return
    hq._request("PATCH", "/rest/v1/system_state?id=eq.1", {
        "day_cap_cents": day_cap, "daily_spend_cap_cents": max(cents, day_cap), "night_until": _next_7am_utc(),
        "night_started_at": datetime.now(timezone.utc).isoformat()}, prefer="return=minimal")
    queued = []
    for fn, label in (("queue_prospect_task", "Donna prospecting"), ("queue_valuation_task", "deal valuations"),
                      ("queue_outreach_drafts", "outreach drafts")):
        try:
            r = hq._request("POST", f"/rest/v1/rpc/{fn}", {})
            if r:
                queued.append(label)
        except Exception:
            logger.exception("Night Shift could not queue %s", fn)
    hq._request("POST", "/rest/v1/audit_log", {"actor": "owner", "action": "night_shift_start", "target": "system_state",
                                               "detail": {"cap_cents": cents, "via": "telegram"}}, prefer="return=minimal")
    await update.message.reply_text(
        f"Night Shift on until 7am with a ${max(cents, day_cap)/100:.2f} budget. "
        + (f"Queued: {', '.join(queued)}. " if queued else "No new backlog to queue; agents work what's on the board. ")
        + "You get a report of every task and its cost in the morning. /nightshift off ends it early.")


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


def add_lead(lead: dict) -> str:
    """Save an owner-entered dayjob lead. Shared by /lead and the app."""
    vid, _ = _venture_id("dayjob")
    from datetime import timedelta
    due = _toronto_today() + timedelta(days=lead["days"])
    rows = hq._request("POST", "/rest/v1/leads", {
        "venture_id": vid, "name": lead["name"], "phone": lead["phone"], "source": "owner", "status": "new",
        "consent_basis": "owner-entered; owner dials personally", "do_not_contact": False,
        "notes": lead["note"] or None, "next_followup_at": due.isoformat(),
    }, prefer="return=representation") or [{}]
    return f"Saved #{rows[0].get('short_id', '?')} {lead['name']}. Follow up {due:%a %b %d}."


async def hq_lead(update, context) -> None:
    if not _owner(update):
        return
    lead = parse_lead(" ".join(context.args or []))
    if not lead:
        await update.message.reply_text("Use: /lead Jane Doe | 613-555-0101 | wants fixed rate | 3\n(name | phone | note | follow up in N days)")
        return
    await update.message.reply_text(add_lead(lead))


def log_contact(sid: int, days: int, outcome: str = "") -> str:
    """Log a contact on a lead and set the next follow-up (0 days = close). Shared by /done and the app."""
    rows = _get(f"leads?short_id=eq.{int(sid)}&select=id,name,notes,contact_count&limit=1")
    if not rows:
        return f"No lead #{sid}."
    lead = rows[0]
    from datetime import timedelta
    stamp = _toronto_today().isoformat()
    outcome = (outcome or "")[:200]
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
    return reply


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
    await update.message.reply_text(log_contact(sid, days, outcome))


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


def _mailing_address(venture: str = "donna") -> str:
    rows = _get(f"company_profile?venture_slug=eq.{_q(venture)}&select=mailing_address&limit=1")
    return ((rows or [{}])[0].get("mailing_address") or "").strip()


def casl_footer(venture: str = "donna") -> str:
    """CASL identification + unsubscribe: sender, mailing address and a working way to opt out.
    Donna keeps its legacy behaviour (defaults, and a visible placeholder if the address is unset). Any other venture FAILS CLOSED:
    hq_mail.ProfileMissing is raised unless sender, brand and mailing address are all set for that venture."""
    if venture != hq_mail.DONNA:
        return hq_mail.footer(venture)
    rows = _get(f"company_profile?venture_slug=eq.{_q(venture)}&select=sender_name,brand,mailing_address&limit=1")
    p = (rows or [{}])[0]
    addr = (p.get("mailing_address") or "").strip() or "[ADD YOUR BUSINESS MAILING ADDRESS - required by CASL]"
    return (f"\n\n--\n{p.get('sender_name') or 'Moe'}, {p.get('brand') or 'The Donna System'}\n{addr}\n"
            "To stop receiving emails from us, reply \"unsubscribe\" and we will remove you within 10 business days.")


def _save_profile(slug: str, **fields) -> None:
    body = {"venture_slug": slug, "updated_at": datetime.now(timezone.utc).isoformat()}
    body.update({k: v for k, v in fields.items() if v})
    hq._request("POST", "/rest/v1/company_profile?on_conflict=venture_slug", body, prefer="resolution=merge-duplicates,return=minimal")


def set_profile_field(slug: str, field: str, value: str) -> str:
    """Set one CASL profile field for a venture: address | sender | brand. Never touches another venture's row."""
    col = {"address": "mailing_address", "sender": "sender_name", "brand": "brand"}.get(field)
    value = (value or "").strip()
    if not col:
        return "Field must be address, sender or brand."
    if col == "mailing_address" and (len(value) < 10 or not re.search(r"\d", value)):
        return "That does not look like a mailing address (street number, street, city, province, postal code)."
    if col != "mailing_address" and len(value) < 2:
        return f"Give a {field}."
    _save_profile(slug, **{col: value[:200]})
    p = hq_mail.profile(slug)
    return f"Saved {field} for {slug}. " + ("Its emails can now carry a CASL footer." if p else
            "Still incomplete: a venture needs sender, brand and address before any of its emails can be approved or sent.")


async def hq_setaddress(update, context) -> None:
    """/setaddress [venture] <address>. With no venture it is Donna's, exactly as before."""
    if not _owner(update):
        return
    args = list(context.args or [])
    slug = hq_mail.DONNA
    if len(args) > 1 and not re.search(r"\d", args[0]):
        # a leading word with no digit may be a venture ("/setaddress ottawa-cleanouts 1 Main St ..."); an unknown one is an error, not an address
        vid, vslug, err = resolve_venture(args[0])
        if vid:
            slug, args = vslug, args[1:]
        elif args[0].startswith("@") or re.fullmatch(r"[a-z][a-z0-9-]{2,40}", args[0]):
            await update.message.reply_text(err or f"No venture called '{args[0]}'.")
            return
    addr = " ".join(args).strip()
    if len(addr) < 10 or not re.search(r"\d", addr):
        await update.message.reply_text("Use: /setaddress [venture] 123 Example St, Ottawa ON K1A 0A1  (the business mailing address, required by CASL; no venture word means Donna)")
        return
    _save_profile(slug, mailing_address=addr[:200])
    if slug == hq_mail.DONNA:
        await update.message.reply_text("Saved. Every approved email now ends with your name, this address and an unsubscribe line.")
    else:
        done = hq_mail.profile(slug)
        await update.message.reply_text(f"Saved the address for {slug}. " + ("Its emails can now carry a CASL footer." if done else
            f"Not ready yet: also set the sender and brand with /venture profile {slug} sender <name> and /venture profile {slug} brand <name>."))


def _outbox_venture_id(outbox_id: str) -> tuple[str | None, bool]:
    """(venture id, has a lead). The one place that decides which venture a draft belongs to: the LEAD's venture wins,
    else the draft's own. The sender (hq_mail.deliver_approved) reads outbox.venture_id, so approval stamps this value there."""
    ob = (_get(f"outbox?id=eq.{_q(outbox_id)}&select=venture_id,lead_id&limit=1") or [{}])[0]
    vid = ob.get("venture_id")
    if ob.get("lead_id"):
        vid = (_get(f"leads?id=eq.{_q(ob['lead_id'])}&select=venture_id&limit=1") or [{}])[0].get("venture_id") or vid
    return vid, bool(ob.get("lead_id"))


def _outbox_casl_gate(outbox_id: str) -> tuple[str | None, str | None]:
    """(venture slug, problem) for approving this draft. The venture comes from the draft's LEAD (else the draft itself).
    Donna keeps its legacy flow (a warning, not a block); every other venture is refused without a complete profile."""
    _v2_problem = hq_venture_ops.dnc_problem(outbox_id)  # venture2 hook: do-not-contact first
    if _v2_problem:
        return None, _v2_problem
    vid, has_lead = _outbox_venture_id(outbox_id)
    if not vid and not has_lead:
        return hq_mail.DONNA, None  # legacy hand-made draft with no venture at all: today's Donna flow (hq_mail still refuses to SEND it)
    slug = hq_mail.venture_slug(vid)
    if not slug:
        return None, "Cannot approve: this draft's venture cannot be found, so there is no CASL sender profile to put on it."
    if slug != hq_mail.DONNA and not hq_mail.profile(slug):
        return slug, (f"Cannot approve yet: {slug} has no complete CASL profile (sender, brand, mailing address), and every email must carry one. "
                      f"Set it with /setaddress {slug} <address>, /venture profile {slug} sender <name>, /venture profile {slug} brand <name>, then tap Approve again.")
    _v2_cfg = hq_venture_ops.config_problem(slug)  # venture2 hook: offer + call to action on file (donna exempt)
    if _v2_cfg:
        return slug, _v2_cfg
    return slug, None


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
    elif ref_table and ref_table.startswith("set_cap:") and approved:
        # Approving a budget proposal applies it: the gateway reads this cap on every call.
        cents = int(ref_table.split(":", 1)[1])
        if 0 < cents <= 2000:  # hard ceiling of $20/day no matter what a message says
            hq._request("PATCH", "/rest/v1/system_state?id=eq.1", {"daily_spend_cap_cents": cents}, prefer="return=minimal")
    elif ref_table == "pause_venture" and ref_id and approved:
        # Approving a pause stops the venture's spend: the gateway refuses calls from paused agents.
        hq._request("PATCH", f"/rest/v1/agents?venture_id=eq.{_q(ref_id)}", {"status": "paused"}, prefer="return=minimal")
        hq._request("PATCH", f"/rest/v1/tasks?venture_id=eq.{_q(ref_id)}&status=eq.todo",
                    {"status": "cancelled", "result": "Cancelled: owner paused this venture."}, prefer="return=minimal")
    elif ref_table and ref_table.startswith("activate_venture:") and approved:
        hq_ventures.activate(ref_table.split(":", 1)[1], by="owner:telegram")
    elif ref_table == "account_requests" and ref_id:
        out = hq_accounts.decide(ref_id, approved, by="owner:telegram")
        _record_decision_memory(msg, verdict, msg_id, ref_table, ref_id)
        return out
    elif ref_table == "payment_instructions" and ref_id:
        out = hq_payments.decide(ref_id, approved, by="owner:telegram")
        _record_decision_memory(msg, verdict, msg_id, ref_table, ref_id)
        return out
    elif ref_table == "org_changes" and ref_id:
        hq._request("PATCH", f"/rest/v1/org_changes?id=eq.{_q(ref_id)}", {"status": verdict, "decided_at": now}, prefer="return=minimal")
        if approved:
            oc = _get(f"org_changes?id=eq.{_q(ref_id)}&select=kind,change,gain,cost,time_to_results,risk,target&limit=1")
            if oc and oc[0].get("kind") == "shutdown" and oc[0].get("target"):
                # Earn-your-keep: approving pauses that one agent. Reversible any time (/agents or the app).
                hq._request("PATCH", f"/rest/v1/agents?slug=eq.{_q(oc[0]['target'])}&role=neq.owner_contact", {"status": "paused"}, prefer="return=minimal")
            elif oc:
                c = oc[0]
                made = hq_missions.create_mission(
                    f"Implement approved {c['kind']} change: {c['change']} Expected gain: {c.get('gain') or 'unstated'}. "
                    f"Budget guide: {c.get('cost') or 'unstated'}. Stay inside the budget and permission limits.",
                    title=f"Org change: {c['change'][:60]}", created_by="owner")
    elif ref_table == "approval_requests" and ref_id:
        # Red action (or approve-first Yellow): the tap approves this one action, once. authorize_action consumes it.
        hq_policy.decide_approval(ref_id, approved)
    elif ref_table == "outbox" and ref_id:
        if approved:
            gate_slug, problem = _outbox_casl_gate(ref_id)
            if problem:  # fail closed: release the tap so the same draft can be approved after the profile is set
                hq._request("PATCH", f"/rest/v1/owner_messages?id=eq.{_q(msg_id)}", {"decision": None, "decided_at": None}, prefer="return=minimal")
                return problem
            # The owner is a reviewer independent of the writing agent, so his approval is the QA step too.
            # The database requires draft -> qa_passed -> approved; before this, Approve on a draft was refused.
            gate_vid, _hl = _outbox_venture_id(ref_id)
            qa = {"status": "qa_passed", "qa_agent": "owner", "qa_notes": "Reviewed by the owner on Telegram"}
            if gate_vid:
                qa["venture_id"] = gate_vid  # sender and approval gate must agree on the venture (review finding)
            hq._request("PATCH", f"/rest/v1/outbox?id=eq.{_q(ref_id)}&status=eq.draft", qa, prefer="return=minimal")
        hq._request("PATCH", f"/rest/v1/outbox?id=eq.{_q(ref_id)}&status=in.(draft,qa_passed)",
                    {"status": verdict, "decided_at": now}, prefer="return=minimal")
        if approved:
            ob = _get(f"outbox?id=eq.{_q(ref_id)}&select=to_ref,body,lead_id&limit=1")
            if ob:
                if ob[0].get("lead_id"):
                    hq._request("PATCH", f"/rest/v1/leads?id=eq.{_q(ob[0]['lead_id'])}", {"status": "approved_to_send"},
                                prefer="return=minimal")
                ready = (f"Approved. Send this from your business email:\n\nTo: {ob[0].get('to_ref')}\n"
                         f"{ob[0].get('body')}{casl_footer(gate_slug)}\n\nOnce sent, reply /sent {ref_id[:8]}")
                if gate_slug == hq_mail.DONNA and not _mailing_address():
                    ready += ("\n\nBefore sending: CASL requires your business mailing address in every email. "
                              "Set it once with /setaddress 123 Example St, Ottawa ON K1A 0A1 and it is added from then on.")
                _record_decision_memory(msg, verdict, msg_id, ref_table, ref_id)
                return ready
    _record_decision_memory(msg, verdict, msg_id, ref_table, ref_id)
    return f"Decision saved: {verdict.upper()}. Agents will follow it."


def _record_decision_memory(msg: dict, verdict: str, msg_id: str, ref_table, ref_id) -> None:
    if ref_table != "outbox":  # individual email approvals are not company policy
        hq._request("POST", "/rest/v1/memory", {"agent": "owner", "kind": "decision", "confidence": "high",
                                                "content": f"Owner {verdict}: {(msg.get('body') or '')[:500]}"}, prefer="return=minimal")
    hq._request("POST", "/rest/v1/audit_log", {"actor": "owner", "action": f"decision_{verdict}", "target": f"owner_messages/{msg_id}",
                                               "detail": {"ref_table": ref_table, "ref_id": ref_id, "via": "telegram"}}, prefer="return=minimal")


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


async def hq_missions_cmd(update, context) -> None:
    if not _owner(update):
        return
    show_all = bool(context.args) and context.args[0].lower() == "all"
    try:
        text = hq_missions.list_text(include_done=show_all)
    except Exception as e:
        text = f"Missions unavailable: {str(e)[:150]}"
    await update.message.reply_text(text[:4000])


async def hq_mission_cmd(update, context) -> None:
    """/mission <id> | /mission new <objective> | /mission pause|resume|abandon <id> | /mission budget <id> <cents>"""
    if not _owner(update):
        return
    args = list(context.args or [])
    if not args:
        await update.message.reply_text("Usage:\n/mission new [@venture] <objective>\n/mission <id>\n/mission pause|resume|abandon <id>\n"
                                        "/mission budget <id> <cents CAD>\n/mission steps <id> <n>\n/mission focus <id>|off\n/mission due <id> <YYYY-MM-DD|+3d|off>\n/mission repeat <id> <weekly|daily|Nd|off> [runs]\n/mission unstick <id>  (a repeat that never started its next run)\nOr just tell me the goal in chat.")
        return
    try:
        verb = args[0].lower()
        if verb == "new":
            vslug = None
            if len(args) > 1 and args[1].startswith("@"):  # /mission new @venture <objective>
                _vid, vslug, err = resolve_venture(args[1])
                if err:
                    await update.message.reply_text(err)
                    return
                args = args[:1] + args[2:]
            r = hq_missions.create_mission(" ".join(args[1:]), vslug, created_by="owner") if vslug else hq_missions.create_mission(" ".join(args[1:]), created_by="owner")
            text = r.get("error") or f"Mission opened: {r['title']} ({str(r['id'])[:8]}). Evaluation starts on the next tick."
        elif verb in ("pause", "resume", "abandon", "retry") and len(args) >= 2:
            text = hq_missions.set_status(args[1], verb)
        elif verb == "unstick" and len(args) >= 2:
            text = hq_missions.unstick_recurrence(args[1])
        elif verb == "steps" and len(args) >= 3 and args[2].isdigit():
            text = hq_missions.set_steps(args[1], int(args[2]))
        elif verb == "due" and len(args) >= 3:
            text = hq_missions.set_due(args[1], args[2])
        elif verb == "repeat" and len(args) >= 3:
            text = hq_missions.set_recurrence(args[1], args[2], int(args[3]) if len(args) > 3 and args[3].isdigit() else None)
        elif verb == "focus" and len(args) >= 2:
            text = hq_missions.set_focus(args[1])
        elif verb == "budget" and len(args) >= 3 and args[2].isdigit():
            text = hq_missions.set_budget(args[1], int(args[2]))
        else:
            text = hq_missions.detail_text(args[0])
    except Exception as e:
        logger.exception("HQ mission command failed")
        text = f"Mission command failed: {str(e)[:150]}"
    await update.message.reply_text(text[:4000])


async def hq_policy_cmd(update, context) -> None:
    """/policy  shows the tiers. /policy <action> tier|each|week|day <value> changes one (owner only)."""
    if not _owner(update):
        return
    args = list(context.args or [])
    try:
        if len(args) >= 3:
            text = hq_policy.set_policy(args[0], args[1].lower(), args[2])
        else:
            text = hq_policy.policy_text() + "\n\nChange one: /policy <action> tier|each|week|day <value>"
    except Exception as e:
        logger.exception("HQ policy command failed")
        text = f"Policy command failed: {str(e)[:150]}"
    await update.message.reply_text(text[:4000])


async def hq_venture_cmd(update, context) -> None:
    """/venture list | new <name> | <idea> | activate <slug> | kpis <slug> | profile <slug> sender|brand|address <v> | agents <slug> | budget [<slug> <dollars>] | <slug> (workspace)  (owner only)."""
    if not _owner(update):
        return
    args = list(context.args or [])
    try:
        sub = args[0].lower() if args else "list"
        if sub == "list":
            text = hq_ventures.list_text()
        elif sub == "budget" and len(args) == 1:
            text = hq_ventures.allocation_text()
        elif sub == "budget" and len(args) == 3:
            text = hq_ventures.set_budget(args[1], args[2])
        elif sub == "budget":
            text = "Use: /venture budget   (show)   or   /venture budget <slug> <dollars per month>"
        elif sub == "kpis" and len(args) > 1:
            vid, vslug, err = resolve_venture(args[1])
            text = err or hq_ventures.kpis_text(vslug)
        elif sub == "profile" and len(args) >= 4:
            vid, vslug, err = resolve_venture(args[1])
            text = err or set_profile_field(vslug, args[2].lower(), " ".join(args[3:]))
        elif sub == "profile":
            text = "Use: /venture profile <venture> sender|brand|address <value>"
        elif sub == "agents" and len(args) > 1:
            vid, vslug, err = resolve_venture(args[1])
            text = err or hq_ventures.ensure_agents(vslug)
        elif sub in ("config", "funnel", "deals"):  # venture2 hook
            text = venture2_sub(sub, args)
        elif sub == "activate" and len(args) > 1:
            text = hq_ventures.activate(args[1].lower())
        elif sub == "new" and len(args) > 1:
            name, _, idea = " ".join(args[1:]).partition("|")
            r = hq_ventures.start(name.strip(), idea.strip(), by="owner")
            text = r.get("error") or f"Venture {r['slug']} set up (inactive). Validation mission: {r['mission']}"
        else:
            text = hq_ventures.workspace_text(sub)
    except Exception as e:
        logger.exception("HQ venture command failed")
        text = f"Venture command failed: {str(e)[:150]}"
    await update.message.reply_text(text[:4000])


async def hq_pnl_cmd(update, context) -> None:
    """/pnl [days]  holding-company P&L: received cash only; pipeline and forecasts shown apart."""
    if not _owner(update):
        return
    days = 30
    if context.args and str(context.args[0]).isdigit():
        days = max(1, min(int(context.args[0]), 365))
    try:
        text = hq_capital.pnl_text(days)
    except Exception as e:
        logger.exception("HQ pnl failed")
        text = f"P&L failed: {str(e)[:150]}"
    await update.message.reply_text(text[:4000])


async def hq_bank_cmd(update, context) -> None:
    """/bank status | balance <amt> [date] | unmatched | reconcile  (owner only)."""
    if not _owner(update):
        return
    args = list(context.args or [])
    try:
        sub = args[0].lower() if args else ""
        if sub == "balance" and len(args) >= 2:
            text = hq_bank.set_balance(args[1], args[2] if len(args) > 2 else None)
        elif sub == "unmatched":
            text = hq_bank.unmatched_text()
        elif sub == "reconcile":
            text = hq_bank.reconcile()
        else:
            text = hq_bank.status_text()
    except Exception as e:
        logger.exception("HQ bank command failed")
        text = f"Bank command failed: {str(e)[:150]}"
    await update.message.reply_text(text[:4000])


async def hq_bank_file(update, context) -> None:
    """A statement CSV sent with the caption 'bank' (owner only). The file is read in memory and not kept."""
    if not _owner(update):
        return
    doc = update.message.document
    try:
        if doc.file_size and doc.file_size > 1_000_000:
            text = "That file is too big for a statement (1 MB max)."
        else:
            f = await doc.get_file()
            raw = bytes(await f.download_as_bytearray()).decode("utf-8", errors="replace")
            text = hq_bank.import_statement(raw)
    except Exception as e:
        logger.exception("HQ bank import failed")
        text = f"Statement import failed: {str(e)[:150]}"
    await update.message.reply_text(text[:4000])


async def hq_pay_cmd(update, context) -> None:
    """/pay  (list)   |   /pay done <id> <amount> <bank reference>   (after YOU paid it in RBC)"""
    if not _owner(update):
        return
    a = context.args or []
    if a and a[0].lower() == "done":
        if len(a) < 4:
            await update.message.reply_text("Use: /pay done <id> <amount> <RBC reference>")
            return
        await update.message.reply_text(hq_payments.confirm(a[1], a[2], " ".join(a[3:])))
        return
    await update.message.reply_text(hq_payments.open_text() + "\n\nAfter you pay in RBC: /pay done <id> <amount> <reference>")


async def hq_setter_cmd(update, context) -> None:
    """/setter | /setter add Name | contact | niche | /setter booked|closed|cancelled Name | client | /setter paid Name kind amount ref"""
    if not _owner(update):
        return
    a = context.args or []
    if not a:
        await update.message.reply_text(hq_setters.owed_text())
        return
    verb, rest = a[0].lower(), " ".join(a[1:])
    if verb == "add" and rest:
        parts = [p.strip() for p in rest.split("|")] + ["", ""]
        await update.message.reply_text(hq_setters.add(parts[0], parts[1], parts[2]))
    elif verb in ("booked", "closed", "cancelled") and rest:
        parts = [p.strip() for p in rest.split("|")] + [""]
        await update.message.reply_text(hq_setters.log(parts[0], verb, parts[1]))
    elif verb == "paid" and len(a) >= 4:
        await update.message.reply_text(hq_setters.paid(a[1], a[2], a[3], " ".join(a[4:])))
    else:
        await update.message.reply_text("Use: /setter  |  /setter add Name | contact | niche  |  /setter booked Name | client  |  /setter closed Name | client  |  /setter paid Name close|recurring|bonus amount ref")


async def hq_waterfall_cmd(update, context) -> None:
    """/waterfall [days]: where received cash goes (tax, costs, buffer, draw, reinvestment) and the HST watch."""
    if not _owner(update):
        return
    a = context.args or []
    days = int(a[0]) if a and a[0].isdigit() else 30
    await update.message.reply_text(await asyncio.to_thread(hq_waterfall.text, days))


async def hq_succession_cmd(update, context) -> None:
    """/succession: the continuity sheet (ventures, accounts and where logins live, tools, assets, runbooks). No secrets."""
    if not _owner(update):
        return
    text = await asyncio.to_thread(hq_succession.build)
    for i in range(0, len(text), 3800):
        await update.message.reply_text(text[i:i + 3800])


async def hq_autonomy_cmd(update, context) -> None:
    """/autonomy: evidence for moving a message type from approve-first toward auto-send."""
    if not _owner(update):
        return
    await update.message.reply_text(await asyncio.to_thread(hq_waterfall.autonomy_text))


async def hq_tool_cmd(update, context) -> None:
    """/tool | /tool add Name | kind | purpose | CAD/month | /tool used|idle|cancel Name   (the recurring-charge registry and idle audit)"""
    if not _owner(update):
        return
    a = context.args or []
    verb, rest = (a[0].lower() if a else ""), " ".join(a[1:])
    if verb == "add" and rest:
        p = [x.strip() for x in rest.split("|")] + ["", "", "", ""]
        out = await asyncio.to_thread(hq_tools.add, p[0], p[1], p[2], p[3] or "0")
    elif verb in ("used", "idle", "cancel") and rest:
        out = await asyncio.to_thread(hq_tools.mark, rest, verb)
    else:
        out = await asyncio.to_thread(hq_tools.text)
    await update.message.reply_text(out)


async def hq_account_cmd(update, context) -> None:
    """/account  (list)   |   /account done <id> <login email or username>   (never the password)"""
    if not _owner(update):
        return
    a = context.args or []
    if a and a[0].lower() == "done":
        if len(a) < 3:
            await update.message.reply_text("Use: /account done <id> <login email or username>  (never the password)")
            return
        await update.message.reply_text(hq_accounts.complete(a[1], " ".join(a[2:])))
        return
    await update.message.reply_text(hq_accounts.open_text() + "\n\nAfter you sign up: /account done <id> <login>")


async def hq_office_cmd(update, context) -> None:
    if not _owner(update):
        return
    await update.message.reply_text(hq_office.office_text()[:4000])


async def hq_capital_cmd(update, context) -> None:
    """/capital  shows the operating fund. /capital set <field> <value> changes a limit (owner only)."""
    if not _owner(update):
        return
    args = list(context.args or [])
    try:
        if len(args) >= 3 and args[0].lower() == "set":
            text = hq_capital.set_field(args[1], args[2])
        else:
            text = hq_capital.status_text()
    except Exception as e:
        logger.exception("HQ capital command failed")
        text = f"Capital command failed: {str(e)[:150]}"
    await update.message.reply_text(text[:4000])


async def hq_backup_cmd(update, context) -> None:
    """/backup -> status of the encrypted off-site backup; /backup now -> run one immediately (owner only). Never shows secrets."""
    if not _owner(update):
        return
    import hq_backup
    args = [a.lower() for a in (context.args or [])]
    try:
        if args and args[0] == "check":
            res = await asyncio.to_thread(hq_backup.preflight)
            icon = {"pass": "OK  ", "warn": "WARN", "fail": "FAIL"}
            lines = [f"{icon.get(r['status'], '?   ')} {r['check']}" + (f" - {r['detail']}" if r.get("detail") else "") for r in res]
            bad = sum(r["status"] == "fail" for r in res)
            text = "Backup configuration check (read-only, nothing uploaded):\n" + "\n".join(lines) + ("\n\nReady for /backup now." if not bad else f"\n\n{bad} problem(s) to fix first.")
        elif args and args[0] == "now":
            if not hq_backup.configured():
                text = "Backup is not configured (BACKUP_KEY or BACKUP_PUT_URL missing)."
            else:
                await update.message.reply_text("Running backup now. This can take a minute.")
                r = await asyncio.to_thread(hq_backup.run, True)
                text = "Backup finished. Check /backup for details." if r.get("ok") else f"Backup did not complete: {str(r.get('reason'))[:200]}"
        else:
            last = await asyncio.to_thread(hq_backup.last_ok)
            conf = "configured" if hq_backup.configured() else "NOT configured"
            if last:
                text = (f"Backup {conf}. Last good: {str(last.get('at'))[:19]} UTC\nFile: {last.get('file')}\n"
                        f"Size: {last.get('bytes')} bytes, rows: {last.get('rows')}, tables: {last.get('tables')}, complete: {last.get('complete')}\n"
                        f"sha256: {last.get('sha256')}")
            else:
                text = f"Backup {conf}. No successful backup recorded yet."
    except Exception as e:
        logger.exception("HQ backup command failed")
        text = f"Backup command failed: {type(e).__name__}"
    await update.message.reply_text(text[:4000])


# --- hqui begin: /needs (unified Needs-you inbox; read-only, buttons reuse the existing hqd:/hqq: callbacks) ---
async def hq_needs_cmd(update, context) -> None:
    if not _owner(update):
        return
    try:
        items = hq_inbox.fetch()
    except Exception as e:
        logger.exception("HQ /needs failed")
        await update.message.reply_text(f"Could not read the inbox: {type(e).__name__}. Is migration 20261115_inbox_needs_you_v1 applied?")
        return
    await update.message.reply_text(hq_inbox.format_inbox(items))
    for it in items[:3]:  # tap-to-act for the top items only, through the same Approve/Reject and answer callbacks as the original message
        markup = hq_inbox.action_buttons(it)
        if markup is not None:
            await update.message.reply_text(f"{it.get('title', '')[:200]}", reply_markup=markup)


MENU_HQUI = [("needs", "Everything waiting on you, ranked")]
# --- hqui end ---


MENU = [
    ("hq", "Company status"), ("backup", "Encrypted off-site backup: status, check, now"), ("missions", "Live missions"), ("mission", "Mission detail / new / pause / resume"), ("policy", "What agents may do alone"), ("capital", "Operating fund and spending limits"), ("bank", "Bank balance, statements, reconciliation"), ("pay", "Payments waiting; /pay done after you pay in RBC"), ("account", "Accounts to create; /account done after you sign up"), ("office", "Corporate office: the nine functions and who staffs them"), ("setter", "Donna setters: standings, log booked/closed, record payouts"), ("waterfall", "Where received cash goes: tax, buffer, draw, reinvestment, HST watch"), ("succession", "Continuity sheet: ventures, accounts, vault pointers, tools, runbooks"), ("autonomy", "Evidence for promoting a message type to auto-send"), ("tool", "Recurring charges: add, mark used, cancel; idle audit"), ("venture", "Ventures: list, new, activate, workspace"), ("pnl", "Holding company profit and loss"), ("systems", "Every system and its health"), ("brief", "Full daily brief now"), ("due", "Follow-ups due now"), ("day", "Log today: dials pitches submissions"), ("paid", "A deal paid out"), ("lead", "Save a lead: name | phone | note | days"),
    ("done", "Log a call: # days note"), ("money", "Log money: in/out amount venture note"),
    ("ask", "Give an agent a task"), ("drafts", "Review outreach drafts"), ("sent", "Mark an approved email as sent"), ("setaddress", "Business mailing address for emails (CASL)"), ("ideas", "Idea lab, best first"), ("testidea", "Start a 7-day test"), ("parkidea", "Park an idea"), ("agents", "List agents"), ("leads", "Lead counts"),
    ("nightshift", "Overnight work with a budget: /nightshift 8"), ("kill", "Stop all agents"), ("resume", "Restart agents"),
]

MENU += MENU_HQUI  # hqui


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


def apply_answer(msg_id: str, idx: int) -> str:
    """Owner tapped an option on a Task Brief: save it as a standing decision and resume the task with it."""
    rows = _get(f"owner_messages?id=eq.{_q(msg_id)}&select=id,body,options,answer,ref_table,ref_id,from_agent&limit=1")
    if not rows:
        return "That question no longer exists."
    m = rows[0]
    opts = m.get("options") or []
    if m.get("answer"):
        return f"Already answered: {m['answer']}"
    if not 0 <= idx < len(opts):
        return "That option is no longer valid."
    choice = str(opts[idx])
    claimed = hq._request("PATCH", f"/rest/v1/owner_messages?id=eq.{_q(msg_id)}&answer=is.null",
                          {"answer": choice, "decided_at": datetime.now(timezone.utc).isoformat()},
                          prefer="return=representation") or []
    if not claimed:
        return "Already answered."
    question = (m.get("body") or "").split("\n", 1)[-1][:300]
    venture = None
    if m.get("ref_table") == "tasks" and m.get("ref_id"):
        t = (_get(f"tasks?id=eq.{_q(m['ref_id'])}&select=id,detail,venture_id&limit=1") or [{}])[0]
        venture = t.get("venture_id")
        if t.get("id"):
            hq._request("PATCH", f"/rest/v1/tasks?id=eq.{_q(t['id'])}", {
                "status": "todo", "updated_at": datetime.now(timezone.utc).isoformat(),
                "detail": ((t.get("detail") or "") + f"\n\nOwner's answer to \"{question}\": {choice}. Continue with it.")[:8000],
            }, prefer="return=minimal")
    hq._request("POST", "/rest/v1/memory", {"agent": "owner", "kind": "decision", "confidence": "high", "venture_id": venture,
                                            "content": f"Owner decided: {question} -> {choice}"}, prefer="return=minimal")
    hq._request("POST", "/rest/v1/audit_log", {"actor": "owner", "action": "answered_question", "target": f"owner_messages/{msg_id}",
                                               "detail": {"choice": choice, "via": "telegram"}}, prefer="return=minimal")
    return f"Got it: {choice}. Saved as a decision and the task is back to work."


async def hq_answer_callback(update, context) -> None:
    query = update.callback_query
    if not _owner(update):
        await query.answer()
        return
    try:
        _, idx, msg_id = query.data.split(":", 2)
        result = apply_answer(msg_id, int(idx))
    except Exception as e:
        logger.exception("HQ answer failed")
        result = f"Could not save the answer: {str(e)[:150]}"
    await query.answer(result[:190])
    try:
        await query.edit_message_reply_markup(reply_markup=None)
        await query.message.reply_text(result)
    except Exception:
        pass


def register(app, CommandHandler, CallbackQueryHandler=None) -> None:
    for name, fn in (("hq", hq_status), ("kill", hq_kill), ("resume", hq_resume), ("money", hq_money),
                     ("ask", hq_ask), ("agents", hq_agents), ("leads", hq_leads),
                     ("lead", hq_lead), ("done", hq_done), ("due", hq_due), ("brief", hq_brief),
                     ("ideas", hq_ideas), ("testidea", hq_testidea), ("parkidea", hq_parkidea), ("drafts", hq_drafts), ("sent", hq_sent), ("systems", hq_systems_cmd), ("day", hq_day), ("paid", hq_paid), ("setaddress", hq_setaddress), ("nightshift", hq_nightshift),
                     ("missions", hq_missions_cmd), ("mission", hq_mission_cmd), ("policy", hq_policy_cmd), ("capital", hq_capital_cmd), ("bank", hq_bank_cmd), ("venture", hq_venture_cmd), ("pnl", hq_pnl_cmd), ("pay", hq_pay_cmd), ("account", hq_account_cmd), ("office", hq_office_cmd), ("setter", hq_setter_cmd), ("waterfall", hq_waterfall_cmd), ("succession", hq_succession_cmd), ("autonomy", hq_autonomy_cmd), ("tool", hq_tool_cmd), ("backup", hq_backup_cmd)):
        app.add_handler(CommandHandler(name, fn))
    register_venture2(app, CommandHandler)  # venture2 hook
    # --- hqui begin ---
    app.add_handler(CommandHandler("needs", hq_needs_cmd))
    # --- hqui end ---
    try:
        from telegram.ext import MessageHandler, filters
        app.add_handler(MessageHandler(filters.Document.ALL & filters.CaptionRegex(r"(?i)^/?bank"), hq_bank_file))
    except Exception:  # never block startup over an optional handler
        logger.exception("bank file handler not registered")
    if CallbackQueryHandler is not None:
        app.add_handler(CallbackQueryHandler(hq_decision_callback, pattern=r"^hqd:"))
        app.add_handler(CallbackQueryHandler(hq_answer_callback, pattern=r"^hqq:"))
    if getattr(app, "job_queue", None) is not None:
        app.job_queue.run_once(_menu_job, when=10, name="hq-menu")


async def _menu_job(context) -> None:
    await set_menu(context.application)


# ---- Chat tools: let Jarvis answer HQ questions in normal conversation (owner only) ----

HQ_CHAT_TOOLS = [
    {
        "name": "hq_company_status",
        "description": "Fendezy HQ status: spend vs cap, task board, escalations, leads, memory, today's brief. "
                       "Use when the owner asks how the company, agents or ventures are doing.",
        "input_schema": {"type": "object", "properties": {}},
    },
    {
        "name": "hq_search_knowledge",
        "description": "Search Fendezy HQ's company memory (verified facts with sources, decisions, lessons) and finished "
                       "task results for a keyword. Use before answering questions about rules, research or past work.",
        "input_schema": {"type": "object", "properties": {"query": {"type": "string", "description": "one or two keywords"}},
                         "required": ["query"]},
    },
    {
        "name": "hq_assign_task",
        "description": "Put a research or drafting task on a Fendezy HQ agent's board (runs within ~5 minutes, dry-run only). "
                       "Only when the owner asks for it. Agents: <venture>-researcher, <venture>-auditor, <venture>-division "
                       "where venture is day-job-sales, donna, real-estate or new-ventures; plus jarvis and research "
                       "(Research & Intelligence: use for 'research this industry').",
        "input_schema": {"type": "object", "properties": {"agent": {"type": "string"}, "task": {"type": "string"}},
                         "required": ["agent", "task"]},
    },
    {
        "name": "hq_create_mission",
        "description": "Open a Fendezy HQ MISSION: a broad objective HQ pursues on its own over many ticks (evaluate GO/TEST/"
                       "DEFER/REJECT with numbers, plan, run the steps, independently verify). Use when the owner gives a goal "
                       "or business idea ('I want to start X', 'get us into Y', 'figure out Z', 'find another revenue opportunity'), not for a single quick task. "
                       "Confirm the objective in one line in your reply.",
        "input_schema": {"type": "object", "properties": {
            "objective": {"type": "string", "description": "the owner's goal in full, with any constraints he gave"},
            "venture": {"type": "string", "enum": ["idea-lab", "donna", "real-estate", "day-job-sales"],
                        "description": "existing venture it belongs to; idea-lab for new businesses"},
            "title": {"type": "string", "description": "short name, under 60 characters"},
            "budget_cents": {"type": "integer", "description": "AI spend budget in CAD cents (default 200, max 1000)"}},
            "required": ["objective"]},
    },
    {
        "name": "hq_start_venture",
        "description": "Set up a NEW business inside Fendezy HQ from the owner's idea ('start a new venture', 'build me a business'). "
                       "Creates an inactive venture (own manager, department, budget ceiling) plus a validation mission; the owner "
                       "activates it with one tap. Nothing is spent or contacted until then.",
        "input_schema": {"type": "object", "properties": {
            "name": {"type": "string"}, "description": {"type": "string", "description": "what it sells, to whom, how it makes money"},
            "metric": {"type": "string"}, "budget_cents": {"type": "integer", "description": "monthly AI budget ceiling in CAD cents, max 5000"}},
            "required": ["name", "description"]},
    },
    {
        "name": "hq_propose_code_change",
        "description": "Propose a change to Jarvis's own code as a GitHub pull request (never merged by you: the owner merges). Use only when "
                       "the owner asks for a code change or after he approves an engineering proposal. Send complete file contents (1-5 files). "
                       "Money, permission, spend, bank and migration files are protected and flagged in the PR. Never include secrets.",
        "input_schema": {"type": "object", "properties": {
            "title": {"type": "string"}, "rationale": {"type": "string", "description": "why, and what it changes"},
            "files": {"type": "array", "items": {"type": "object", "properties": {"path": {"type": "string"}, "content": {"type": "string"}},
                                                  "required": ["path", "content"]}}},
            "required": ["title", "rationale", "files"]},
    },
    {
        "name": "hq_propose_site",
        "description": "Draft a static website for a venture as a GitHub pull request under sites/<venture-slug>/ (index.html required; html/css/svg only, "
                       "no external scripts, iframes, redirects or password fields). Never published automatically: the owner merges. "
                       "Use after the owner asks for a site or approves one.",
        "input_schema": {"type": "object", "properties": {
            "venture_slug": {"type": "string"}, "title": {"type": "string"}, "rationale": {"type": "string"},
            "files": {"type": "array", "items": {"type": "object", "properties": {"path": {"type": "string"}, "content": {"type": "string"}},
                                                  "required": ["path", "content"]}}},
            "required": ["venture_slug", "title", "rationale", "files"]},
    },
    {
        "name": "hq_verify_url",
        "description": "Check that a public https page is really live and says what it should (HTTP status, title, expected phrases). Use it as evidence "
                       "before claiming a site or page is live or a mission step is done. Public websites only.",
        "input_schema": {"type": "object", "properties": {"url": {"type": "string"}, "expect": {"type": "array", "items": {"type": "string"}, "description": "phrases that must appear"}},
                         "required": ["url"]},
    },
    {
        "name": "hq_create_department",
        "description": "Create a new department (e.g. marketing, engineering) when the owner asks for one or the numbers justify it. "
                       "Optionally attach it to a venture slug; otherwise it is a shared company department.",
        "input_schema": {"type": "object", "properties": {"slug": {"type": "string"}, "name": {"type": "string"}, "venture_slug": {"type": "string"}},
                         "required": ["slug", "name"]},
    },
    {
        "name": "hq_create_agent",
        "description": "Create a new HQ agent in an existing department. Hard limits (enforced by the database): cheap or standard tier, cap at most 50 "
                       "cents/day, cannot contact the owner, max 3 new agents per week, created asleep if the company agent budget is full. "
                       "Roles: researcher, specialist, ops, finance, auditor, builder, compliance, gm. Give a real charter and a measurable metric.",
        "input_schema": {"type": "object", "properties": {
            "slug": {"type": "string"}, "title": {"type": "string"}, "department": {"type": "string"},
            "role": {"type": "string"}, "tier": {"type": "string", "enum": ["cheap", "standard"]}, "cap_cents": {"type": "integer"},
            "charter": {"type": "string"}, "metric": {"type": "string"}},
            "required": ["slug", "title", "department", "role", "tier", "charter", "metric"]},
    },
    {
        "name": "hq_finances",
        "description": "Full financial review: operating fund and reserve, verified bank balance and reconciliation gaps, profit and loss "
                       "by venture (received cash only; expected revenue is never counted as money). Use for 'review our finances', "
                       "'how much do we have', 'are we on budget'.",
        "input_schema": {"type": "object", "properties": {}},
    },
    {
        "name": "hq_office",
        "description": "The corporate office: Executive, Business Development, Research, Engineering, Marketing, Sales, Finance, Operations and Agent Management, "
                       "with who staffs each and real numbers. Use for 'how is the company organised', 'which departments are empty', 'who is on what'.",
        "input_schema": {"type": "object", "properties": {}},
    },
    {
        "name": "hq_request_account",
        "description": "Ask the owner to create a business software account you need (e.g. a phone/SMS provider, a hosting service). You cannot sign up yourself: "
                       "he approves, signs up with his business email/number, and confirms the login. Say which steps only he can do. Never ask for passwords.",
        "input_schema": {"type": "object", "properties": {
            "vendor": {"type": "string"}, "purpose": {"type": "string"}, "venture": {"type": "string"},
            "url": {"type": "string", "description": "https sign-up page"}, "monthly_cents": {"type": "integer"},
            "needs": {"type": "array", "items": {"type": "string", "enum": ["captcha", "email_code", "sms_code", "id", "payment"]}}},
            "required": ["vendor", "purpose"]},
    },
    {
        "name": "hq_prepare_payment",
        "description": "Prepare a payment for the owner: reserves the funds (capital limits and minimum reserve apply), then asks him to approve. "
                       "He pays it himself in RBC and confirms with the bank reference. You never move money. Use only for a real operating cost "
                       "with a known payee and amount; give the cheaper alternatives you considered.",
        "input_schema": {"type": "object", "properties": {
            "payee": {"type": "string"}, "amount_cents": {"type": "integer"}, "purpose": {"type": "string"},
            "alternatives": {"type": "string"}, "due_on": {"type": "string", "description": "YYYY-MM-DD, optional"},
            "venture": {"type": "string", "description": "venture slug, optional"}},
            "required": ["payee", "amount_cents", "purpose", "alternatives"]},
    },
    {
        "name": "hq_register_asset",
        "description": "Record a venture's website, domain, account, integration or repo (name and URL only; passwords, keys and tokens are refused). "
                       "Omit venture for a company-wide asset.",
        "input_schema": {"type": "object", "properties": {
            "venture": {"type": "string"}, "kind": {"type": "string", "enum": ["website", "domain", "account", "integration", "asset", "repo"]},
            "name": {"type": "string"}, "url": {"type": "string"}, "status": {"type": "string", "enum": ["planned", "live", "retired"]},
            "notes": {"type": "string"}}, "required": ["kind", "name"]},
    },
    {
        "name": "hq_save_procedure",
        "description": "Write or update an operating procedure (a real step-by-step SOP) for a venture or the whole company; updating bumps the version. "
                       "Never include credentials.",
        "input_schema": {"type": "object", "properties": {
            "venture": {"type": "string"}, "title": {"type": "string"}, "steps": {"type": "string"}, "owner_agent": {"type": "string"}},
            "required": ["title", "steps"]},
    },
    {
        "name": "hq_venture",
        "description": "Show one venture's workspace: stage, budget used, money, agents, leads, goals. Use for 'how is X doing'.",
        "input_schema": {"type": "object", "properties": {"slug": {"type": "string"}}, "required": ["slug"]},
    },
    {
        "name": "hq_missions",
        "description": "List Fendezy HQ missions with status, spend, verdict and next action. Use for 'what are you working on', "
                       "'how's the X mission', 'what happened overnight'.",
        "input_schema": {"type": "object", "properties": {}},
    },
]
HQ_CHAT_TOOL_NAMES = {t["name"] for t in HQ_CHAT_TOOLS}


def _search_knowledge(query: str) -> str:
    q = re.sub(r"[^\w\s-]", " ", query or "").strip()[:60]
    if len(q) < 2:
        return "Give a keyword."
    pat = _q(f"*{q}*")
    mem = _get(f"memory?content=ilike.{pat}&order=created_at.desc&limit=8&select=kind,content,source,confidence")
    tasks = _get(f"tasks?status=in.(done,blocked)&or=(title.ilike.{pat},result.ilike.{pat})&order=updated_at.desc&limit=3"
                 "&select=title,assigned_agent,result")
    try:  # app chat history (table exists once webapp_v1 is applied)
        chat = _get(f"web_messages?body=ilike.{pat}&role=in.(owner,jarvis)&order=created_at.desc&limit=4&select=role,body,created_at")
    except Exception:
        chat = []
    out = []
    for c in chat:
        out.append(f"[chat {str(c.get('created_at'))[:10]} {c['role']}] {c['body'][:400]}")
    for m in mem:
        out.append(f"[{m['kind']}/{m.get('confidence')}] {m['content']}" + (f" (source: {m['source']})" if m.get("source") else ""))
    for t in tasks:
        out.append(f"[task by {t['assigned_agent']}] {t['title']}: {(t.get('result') or '')[:1200]}")
    return "\n\n".join(out) if out else f"Nothing in HQ memory or task results mentions '{q}'."


def _assign(agent: str, task: str) -> str:
    rows = [] if (agent or "").lower() == "jarvis-chat" else _get(f"agents?slug=eq.{_q((agent or '').lower())}&status=eq.active&select=slug,venture_id&limit=1")
    if not rows:
        return f"No active agent called {agent}."
    hq._request("POST", "/rest/v1/tasks", {
        "assigned_agent": rows[0]["slug"], "venture_id": rows[0].get("venture_id"), "created_by": "owner", "priority": 1,
        "status": "todo", "title": task[:140],
        "detail": task + "\n\nAsked by the owner in chat. Research or drafting only: no contacting anyone, no spending, no signing.",
    }, prefer="return=minimal")
    return f"Queued for {rows[0]['slug']}; it runs within about 5 minutes."


def finances_text() -> str:
    """Capital + bank + P&L in one answer. Each part fails soft (its migration may not be applied yet)."""
    parts = []
    for label, fn in (("Capital", hq_capital.status_text), ("Bank", hq_bank.status_text), ("Profit and loss", hq_capital.pnl_text), ("Payments waiting", hq_payments.open_text), ("Venture budgets", hq_ventures.allocation_text)):
        try:
            parts.append(f"{label}:\n{fn()}")
        except Exception:
            parts.append(f"{label}: not available yet.")
    return "\n\n".join(parts)


async def handle_chat_tool(name: str, tool_input: dict) -> str:
    try:
        if name == "hq_company_status":
            brief = hq._request("POST", "/rest/v1/rpc/daily_brief_text", {}) or ""
            return status_text() + "\n\n" + str(brief)[:3000]
        if name == "hq_search_knowledge":
            return _search_knowledge(tool_input.get("query", ""))
        if name == "hq_assign_task":
            return _assign(tool_input.get("agent", ""), tool_input.get("task", ""))
        if name == "hq_create_mission":
            r = hq_missions.create_mission(tool_input.get("objective", ""), tool_input.get("venture"),
                                           tool_input.get("title"), tool_input.get("budget_cents"), created_by="owner-chat")
            return r.get("error") or (f"Mission opened: {r['title']} (id {str(r['id'])[:8]}). It's evaluated on the next engine "
                                      "tick (about 5 minutes); the owner gets the verdict and plan by Telegram.")
        if name == "hq_start_venture":
            r = hq_ventures.start(tool_input.get("name", ""), tool_input.get("description", ""), tool_input.get("metric"),
                                  tool_input.get("budget_cents") or 0, by="owner-chat")
            return r.get("error") or (f"Venture {r['slug']} created inactive. Validation mission: {r['mission']}. "
                                      "The owner has a card to activate it; nothing is spent before that.")
        if name == "hq_propose_code_change":
            import asyncio
            return await asyncio.to_thread(hq_dev.propose_change, tool_input.get("title", ""), tool_input.get("rationale", ""),
                                           tool_input.get("files") or [])
        if name == "hq_propose_site":
            import asyncio
            return await asyncio.to_thread(hq_sites.propose_site, tool_input.get("venture_slug", ""), tool_input.get("title", ""),
                                           tool_input.get("rationale", ""), tool_input.get("files") or [])
        if name == "hq_verify_url":
            import asyncio
            return await asyncio.to_thread(hq_verify.report, tool_input.get("url", ""), tool_input.get("expect") or [])
        if name == "hq_create_department":
            return hq_org.create_department(tool_input.get("slug", ""), tool_input.get("name", ""), tool_input.get("venture_slug"), by="owner-chat")
        if name == "hq_create_agent":
            return hq_org.create_agent(tool_input.get("slug", ""), tool_input.get("title", ""), tool_input.get("department", ""), tool_input.get("role", ""),
                                       tool_input.get("tier", "cheap"), tool_input.get("cap_cents") or 15, tool_input.get("charter", ""),
                                       tool_input.get("metric", ""), by="owner-chat")
        if name == "hq_office":
            return hq_office.office_text()
        if name == "hq_request_account":
            return hq_accounts.request("jarvis", tool_input.get("vendor", ""), tool_input.get("purpose", ""), tool_input.get("venture") or None,
                                       tool_input.get("url", ""), int(tool_input.get("monthly_cents") or 0), tool_input.get("needs") or [])
        if name == "hq_prepare_payment":
            return hq_payments.prepare("jarvis", tool_input.get("payee", ""), int(tool_input.get("amount_cents") or 0), tool_input.get("purpose", ""),
                                       tool_input.get("alternatives", ""), tool_input.get("due_on") or None, tool_input.get("venture") or None)
        if name == "hq_register_asset":
            return hq_ventures.register_asset(tool_input.get("venture"), tool_input.get("kind", ""), tool_input.get("name", ""), tool_input.get("url", ""),
                                              tool_input.get("status", "planned"), tool_input.get("notes", ""))
        if name == "hq_save_procedure":
            return hq_ventures.save_procedure(tool_input.get("venture"), tool_input.get("title", ""), tool_input.get("steps", ""), tool_input.get("owner_agent", ""))
        if name == "hq_finances":
            return finances_text()
        if name == "hq_venture":
            return hq_ventures.workspace_text((tool_input.get("slug") or "").lower())
        if name == "hq_missions":
            return hq_missions.list_text(include_done=True)
    except Exception as e:
        logger.exception("HQ chat tool failed")
        return f"HQ tool error: {str(e)[:200]}"
    return f"Unknown HQ tool {name}"


# --- venture2 begin ---
# Deals, reply tracking, do-not-contact, funnel and per-venture config (hq_venture_ops.py). Everything here is an owner command;
# nothing sends anything. Hooks outside this block: _outbox_casl_gate (draft_problem), hq_venture_cmd (config/funnel/deals), register().

def venture2_sub(sub: str, args: list) -> str:
    """/venture config <v> [offer|cta|sla|brief <value>] | /venture funnel <v> | /venture deals [<v>]"""
    if sub == "deals":
        if len(args) > 1:
            _vid, vslug, err = resolve_venture(args[1])
            return err or hq_venture_ops.deals_text(vslug)
        return hq_venture_ops.deals_text()
    if len(args) < 2:
        return f"Use: /venture {sub} <venture>" + (" [offer|cta|sla|brief <value>]" if sub == "config" else "")
    _vid, vslug, err = resolve_venture(args[1])
    if err:
        return err
    if sub == "funnel":
        return hq_venture_ops.funnel_text(vslug)
    if len(args) == 2:
        return hq_venture_ops.config_text(vslug)
    return hq_venture_ops.set_config(vslug, args[2], " ".join(args[3:]))


async def hq_reply_cmd(update, context) -> None:
    """/reply <lead#> <interested|not_interested|question|unsubscribe|booked> [note]  (owner only)"""
    if not _owner(update):
        return
    args = list(context.args or [])
    if len(args) < 2:
        await update.message.reply_text("Use: /reply 12 interested wants a call Tuesday\nKinds: " + ", ".join(hq_venture_ops.REPLY_KINDS) +
                                        "\n'unsubscribe' stops all contact with that address in every venture, at once.")
        return
    try:
        text = hq_venture_ops.record_reply(args[0], args[1], " ".join(args[2:]))
    except Exception as e:
        logger.exception("HQ reply command failed")
        text = f"Reply failed: {str(e)[:150]}"
    await update.message.reply_text(text[:4000])


async def hq_deal_cmd(update, context) -> None:
    """/deal new <lead#> [value] | list [venture] | move <code> pitched|negotiating|lost [note] | won <code> <amount> received|expected [note]"""
    if not _owner(update):
        return
    args = list(context.args or [])
    sub = args[0].lower() if args else "list"
    try:
        if sub == "list":
            text = hq_venture_ops.deals_text(None)
            if len(args) > 1:
                _vid, vslug, err = resolve_venture(args[1])
                text = err or hq_venture_ops.deals_text(vslug)
        elif sub == "new" and len(args) >= 2:
            text = hq_venture_ops.deal_new(args[1], args[2] if len(args) > 2 else "", " ".join(args[3:]))
        elif sub == "move" and len(args) >= 3:
            text = hq_venture_ops.deal_move(args[1], args[2], " ".join(args[3:]))
        elif sub == "won" and len(args) >= 4:
            text = hq_venture_ops.deal_won(args[1], args[2], args[3], " ".join(args[4:]))
        elif sub == "won":
            text = "Use: /deal won <code> <amount> received|expected [note]   (only this records revenue)"
        else:
            text = ("Use:\n/deal list [venture]\n/deal new <lead#> [value]\n/deal move <code> pitched|negotiating|lost [note]\n"
                    "/deal won <code> <amount> received|expected [note]")
    except Exception as e:
        logger.exception("HQ deal command failed")
        text = f"Deal command failed: {str(e)[:150]}"
    await update.message.reply_text(text[:4000])


def register_venture2(app, CommandHandler) -> None:
    for name, fn in (("reply", hq_reply_cmd), ("deal", hq_deal_cmd)):
        app.add_handler(CommandHandler(name, fn))


MENU.extend([("reply", "Record a lead's reply; unsubscribe = do not contact"), ("deal", "Deals: new, move, won (owner confirms revenue)")])
# --- venture2 end ---
