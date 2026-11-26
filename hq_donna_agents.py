"""Donna Client Agents v1: a paying client's own Donna phone agent on the owner's Retell account, and the monthly report that shows the client what it caught.
Design: docs/architecture/DONNA_CLIENT_AGENTS_V1.md. Database: migrations/20261211_donna_client_agents_v1.sql.

  /donna agent <client>                 preview the agent built from the client's onboarding intake (hours, services, FAQs, urgent-call number, booking) and a
                                        6-character confirm code (the start of the spec's SHA-256)
  /donna agent <client> create <code>   the owner's go: creates the Retell LLM + agent (free on Retell; NO phone number is bought here) and records the ids.
                                        A changed intake changes the code, so he always confirms exactly what gets created.
  /donna clientreport <client>          last month's numbers from Retell (calls, outside 9-to-5, booked, urgent, messages) as an email to the client,
                                        staged for the owner's tap like every Donna email. The tick sends each client's report draft once a month.

The spec is plain code from the intake (no model). Retell keys come from RETELL_API_KEY (Railway). Nothing here sends, pays or deploys.
"""
from __future__ import annotations

import datetime as dt
import hashlib
import json
import os
import re

import hq_donna
import hq_donna_revenue as R

API = "https://api.retellai.com"
DAYS = ("mon", "tue", "wed", "thu", "fri", "sat", "sun")


class AgentError(Exception):
    pass


def _hours_text(hours: dict) -> str:
    out = []
    for d in DAYS:
        spans = (hours or {}).get(d) or []
        out.append(f"{d.title()}: " + (", ".join(f"{a}-{b}" for a, b in spans) if spans else "closed"))
    return "; ".join(out)


def spec(intake: dict) -> dict:
    """Intake row (donna_intake_for_agent) -> {"llm": ..., "agent": ...} Retell bodies (same fields as the live demo-line agent)."""
    c = intake.get("reception_config") or {}
    biz = str(c.get("business_name") or intake.get("client_label") or "").strip()[:80]
    if not biz:
        raise AgentError("the intake has no business name")
    esc = str(c.get("escalation_number") or "")
    has_esc = bool(re.fullmatch(r"\+1\d{10}", esc))
    services = [s for s in (c.get("services") or []) if s.get("name")][:30]
    faqs = [q for q in (c.get("faqs") or []) if q.get("q") and q.get("a")][:30]
    booking = c.get("booking") or {}
    book_url = str(booking.get("public_url") or "")
    lines = [
        f"You are Donna, the virtual receptionist for {biz}. You answer the phone for {biz}, warmly and briefly, like an experienced front-desk person.",
        "At the start you said you are an AI and the call is recorded; if asked again, say so plainly.",
        f"Business hours ({c.get('timezone') or 'America/Toronto'}): {_hours_text(c.get('hours') or {})}.",
        "Your job on every call: understand what the caller needs, answer from the facts below only, and make sure nothing is lost: take the caller's name, "
        "the best callback number (repeat it back), and what they need.",
    ]
    if services:
        lines.append("Services: " + "; ".join(
            s["name"] + (f" (from ${int(s['price_cents']) / 100:,.0f})" if int(s.get("price_cents") or 0) > 0 else "") for s in services) + ".")
        lines.append("Only quote a price listed here. For anything else say the team will confirm the price.")
    else:
        lines.append("You do not quote prices; the team confirms them.")
    if faqs:
        lines.append("Answers you can give:")
        lines += [f"- Q: {q['q']} A: {q['a']}" for q in faqs]
    lines.append("If you don't know, never guess: say you'll pass it to the team and take a message.")
    if book_url.startswith("https://"):
        lines.append(f"To book, offer to text or email the booking link ({book_url}), or take their preferred day and time for the team to confirm.")
    else:
        lines.append("To book, take their preferred day and time and tell them the team will confirm by text or call.")
    if has_esc:
        lines.append("If it is urgent (an emergency, a safety issue, or a very upset customer) or they insist on a person, transfer the call with transfer_to_team.")
    else:
        lines.append("If it is urgent, mark it urgent in your notes and tell the caller the team will call back as soon as possible.")
    lines += ["Never promise a time, a result, a refund or a discount. Never take card details. Keep answers short. End politely with end_call."]
    tools = [{"type": "end_call", "name": "end_call", "description": "End the call after the wrap-up, or when the caller says goodbye."}]
    if has_esc:
        tools.append({"type": "transfer_call", "name": "transfer_to_team", "description": "Transfer urgent calls, or when the caller insists on a person.",
                      "transfer_destination": {"type": "predefined", "number": esc}})
    llm = {"model_config": {"type": "cascading", "primary": {"model": "gpt-4.1-mini"}, "temperature": 0.3}, "start_speaker": "agent",
           "begin_message": f"Thanks for calling {biz}, this is Donna, the virtual assistant. Just so you know, I'm an AI and this call is recorded. How can I help?",
           "general_tools": tools, "general_prompt": "\n".join(lines)[:28000]}
    analysis = [{"type": "string", "name": "caller_name", "description": "The caller's name, if given.", "required": False},
                {"type": "string", "name": "callback_number", "description": "The callback number the caller confirmed, E.164. Empty if not confirmed.", "required": False},
                {"type": "string", "name": "reason", "description": "What the caller needed, in one short sentence.", "required": False},
                {"type": "boolean", "name": "urgent", "description": "True if the caller said it was urgent or an emergency.", "required": False},
                {"type": "boolean", "name": "booked", "description": "True if a booking request (day and time) was taken.", "required": False},
                {"type": "string", "name": "appointment_time", "description": "The day and time the caller asked for, if any.", "required": False}]
    agent = {"agent_name": f"Client - {biz}"[:90], "voice_id": "11labs-Kate", "voice_model": "eleven_flash_v2_5", "language": "en-US",
             "timezone": c.get("timezone") or "America/Toronto", "responsiveness": 0.9, "interruption_sensitivity": 0.8, "enable_backchannel": True,
             "end_call_after_silence_ms": 30000, "max_call_duration_ms": 900000, "data_storage_setting": "everything", "data_storage_retention_days": 30,
             "post_call_analysis_model": "gpt-4.1-mini", "post_call_analysis_data": analysis}
    hook = os.environ.get("DONNA_CLIENT_WEBHOOK_URL", "")
    if hook.startswith("https://"):
        agent |= {"webhook_url": hook, "webhook_events": ["call_analyzed"]}
    return {"llm": llm, "agent": agent}


def spec_sha(s: dict) -> str:
    return hashlib.sha256(json.dumps(s, sort_keys=True, separators=(",", ":")).encode()).hexdigest()


def preview(intake: dict) -> str:
    s = spec(intake)
    c = intake.get("reception_config") or {}
    code = spec_sha(s)[:6]
    warn = [str(x) for x in (intake.get("open_items") or [])][:6]
    tools = [t["name"] for t in s["llm"]["general_tools"]]
    lines = [f"Donna agent for {intake.get('client_label')}:",
             f"- hours: {_hours_text(c.get('hours') or {})}",
             f"- {len(c.get('services') or [])} services, {len(c.get('faqs') or [])} FAQs, urgent calls: {'transfer to ' + c['escalation_number'] if 'transfer_to_team' in tools else 'callback note (no valid number)'}",
             f"- voice: Kate (Retell voice library); calls kept 30 days",
             f"- prompt: {len(s['llm']['general_prompt'])} characters, from the intake only"]
    if warn:
        lines.append("Open items from the intake: " + "; ".join(warn))
    if intake.get("agent"):
        lines.append(f"Already created: {intake['agent']['retell_agent_id']} ({str(intake['agent']['created_at'])[:10]}).")
    else:
        lines.append(f"To create it on your Retell account (free; no phone number is bought): /donna agent {intake.get('client_label')} create {code}")
    return "\n".join(lines)


def _retell(method: str, path: str, key: str, body: dict | None = None, http=R.http_json):
    return http(method, API + path, {"Authorization": f"Bearer {key}", "User-Agent": "DonnaAgents/1.0"}, body)


def agent_cmd(text: str, rpc=None, env: dict | None = None, http=R.http_json) -> str:
    env = os.environ if env is None else env
    rpc = rpc or hq_donna._rpc_default
    m = re.match(r"^\s*(.+?)(?:\s+create\s+([0-9a-f]{6}))?\s*$", text or "", re.I)
    if not m or not m.group(1).strip():
        return "Use: /donna agent <client>  (preview), then /donna agent <client> create <code>"
    try:
        intake = rpc("donna_intake_for_agent", {"p_ref": m.group(1).strip()}) or {}
        s = spec(intake)
    except Exception as e:
        return f"Not ready: {str(e)[:200]}"
    if not m.group(2):
        return preview(intake)
    if intake.get("agent"):
        return f"{intake['client_label']} already has an agent: {intake['agent']['retell_agent_id']}."
    sha = spec_sha(s)
    if m.group(2).lower() != sha[:6]:
        return "That code doesn't match the current intake (it changed). Run /donna agent <client> again for the new code."
    key = env.get("RETELL_API_KEY")
    if not key:
        return "RETELL_API_KEY isn't set in Railway yet."
    try:
        llm_id = (_retell("POST", "/create-retell-llm", key, s["llm"], http) or {})["llm_id"]
        agent_id = (_retell("POST", "/create-agent", key, {**s["agent"], "response_engine": {"type": "retell-llm", "llm_id": llm_id}}, http) or {})["agent_id"]
    except Exception as e:
        return f"Retell refused: {str(e)[:200]}"
    try:
        rpc("donna_record_client_agent", {"p_intake": intake["intake"], "p_agent": agent_id, "p_llm": llm_id, "p_spec_sha": sha})
    except Exception as e:
        return f"Created on Retell ({agent_id}) but not recorded: {str(e)[:150]}. Tell Claude."
    return (f"Created {intake['client_label']}'s Donna: {agent_id}. Test it in Retell (Test call). When it sounds right, buy or port the client's number in Retell "
            "and attach this agent (that step costs money, so it's yours).")


# ------------------------------------------------------------------------------------------------------------------- the monthly client report
def _period(today: dt.date) -> tuple[str, int, int]:
    first = today.replace(day=1)
    prev_last = first - dt.timedelta(days=1)
    start = prev_last.replace(day=1)
    to_ms = lambda d: int(dt.datetime(d.year, d.month, d.day, tzinfo=R.TZ).timestamp() * 1000)
    return start.strftime("%Y-%m"), to_ms(start), to_ms(first)


def _outside(ts_ms: int, hours: dict) -> bool:
    t = dt.datetime.fromtimestamp(ts_ms / 1000, tz=R.TZ)
    spans = (hours or {}).get(DAYS[t.weekday()]) or []
    hm = t.strftime("%H:%M")
    return not any(a <= hm < b for a, b in spans)


def stats(calls: list, hours: dict) -> dict:
    ended = [c for c in calls if c.get("call_status") == "ended"]
    cd = lambda c: ((c.get("call_analysis") or {}).get("custom_analysis_data") or {})
    return {"calls": len(ended),
            "outside_hours": sum(1 for c in ended if c.get("start_timestamp") and _outside(c["start_timestamp"], hours)),
            "booked": sum(1 for c in ended if cd(c).get("booked")),
            "urgent": sum(1 for c in ended if cd(c).get("urgent")),
            "messages": sum(1 for c in ended if cd(c).get("callback_number") or cd(c).get("reason")),
            "minutes": round(sum(int(c.get("duration_ms") or 0) for c in ended) / 60000)}


def report_email(label: str, person: str | None, period: str, st: dict, address: str, c: dict | None = None) -> tuple[str, str]:
    c = c or R.cfg()
    month = dt.date.fromisoformat(period + "-01").strftime("%B %Y")
    lines = [f"Hi {R.first_name(person)},", "", f"Here's what Donna handled for {label} in {month}:", "",
             f"- Calls answered: {st['calls']}",
             f"- Calls outside your business hours: {st['outside_hours']}",
             f"- Booking requests taken: {st['booked']}",
             f"- Urgent calls flagged: {st['urgent']}",
             f"- Messages and callbacks captured: {st['messages']}", "",
             "Every number comes from your call log. Reply if you'd like anything changed in how Donna answers.", "", "Thanks,", R.rev(c)["brand"], "",
             R.footer(address, c)]
    return f"Donna's {month} report for {label}"[:150], "\n".join(lines)


def client_report_run(ctx, inputs: dict, *, env: dict | None = None, http=R.http_json, address_get=None, today: dt.date | None = None) -> dict:
    """outreach-prep mode 'client_report': one email per client agent for last month, staged for the owner's tap; recorded once per month."""
    env = os.environ if env is None else env
    ctx.check("draft_outreach")
    key = env.get("RETELL_API_KEY")
    if not key:
        raise hq_donna.DonnaRefused("RETELL_API_KEY isn't set")
    address = R.mailing_address(address_get)
    if address == R.PLACEHOLDER_ADDRESS:
        raise hq_donna.DonnaRefused("no mailing address yet: /setaddress donna <P.O. box>")
    period, lo, hi = _period(today or dt.datetime.now(R.TZ).date())
    want = {str(x).lower() for x in inputs.get("clients") or []}
    out = []
    for a in ctx.rpc("donna_client_agents", {}) or []:
        if want and a["client_label"].lower() not in want:
            continue
        if a.get("last_report") == period or not a.get("lead"):
            continue
        calls = _retell("POST", "/v2/list-calls", key, {"filter_criteria": {"agent_id": [a["retell_agent_id"]],
                        "start_timestamp": {"lower_threshold": lo, "upper_threshold": hi}}, "limit": 1000}, http) or []
        st = stats(calls if isinstance(calls, list) else [], (a.get("reception_config") or {}).get("hours") or {})
        lc = ctx.rpc("donna_lead_context", {"p_lead": a["lead"]}) or {}
        subject, body = report_email(a["client_label"], lc.get("person"), period, st, address)
        r = R._save_and_stage(ctx, a["lead"], subject, body, "client_report")
        ctx.rpc("donna_record_client_report", {"p_agent": a["id"], "p_period": period, "p_draft": r.get("draft"), "p_stats": st})
        out.append(r | {"client": a["client_label"], "stats": st})
    return {"mode": "client_report", "period": period, "results": out}


def clientreport_cmd(label: str, rpc=None, runner=None, approve=R.post_for_approval) -> str:
    if not (label or "").strip():
        return "Use: /donna clientreport <client>"
    runner = runner or (lambda mission, inputs: hq_donna.run(mission, inputs, rpc=rpc))
    r = runner("outreach-prep", {"mode": "client_report", "clients": [label.strip()]}) or {}
    if not r.get("ok"):
        return f"Report not drafted: {r.get('refused') or r.get('error') or 'refused'}"
    res = (r.get("result") or {}).get("results") or []
    if not res:
        return f"No report: no agent for {label}, or last month's report was already drafted."
    if res[0].get("outbox") and res[0].get("new"):
        approve(res[0]["outbox"], "Donna drafted the monthly report for your client. Approve to send it.")
    return f"{label}: {res[0]['stats']}. " + ("Approve it in the message above." if res[0].get("outbox") else f"Not ready to send: {res[0].get('not_staged') or res[0].get('refused')}")
