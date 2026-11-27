"""Donna Revenue Loop v1: the money loop around Donna Ops v1. Design: docs/architecture/DONNA_REVENUE_LOOP_V1.md. Database: migrations/20261210_donna_revenue_loop_v1.sql.

  inbound   website form (Netlify Forms API) and Donna calls (Retell list-calls) -> donna_ingest_inbound -> a lead of the 'donna' venture, consent basis from what
            the person did (the unticked marketing box = express; otherwise an inquiry = implied). PULL only: no new public endpoint, idempotent per source + ref.
            OFF unless DONNA_INBOUND=1. Works while Donna is dormant (it records inquiries the owner already got as Telegram alerts; nothing is sent).
  replies   outreach-prep mode "inbound_reply": a plain-code reply to each new inquiry (booked or not), with the leak estimate they entered.
  follow-up outreach-prep mode "follow_up": at most 3 emails in total per lead (hq_mail sets next_followup_at after each send), never on top of one waiting.
  proposal  outreach-prep mode "proposal": after the audit, the owner's package and price + his findings -> a proposal email (no payment request, nothing to sign).
  brief     offer-pricing mode "audit_brief": for each booked audit, an internal brief to the owner: their numbers, the likely package, the owner's price guide,
            the questions to ask. Never sent to the lead.
  cold      once a day, outreach-prep drafts first emails for up to 10 researched prospects (contact published on their own site); they are staged for the
            owner's tap too: at most 20 a day, 5 at a time.
  tick      every 5 minutes from the bot: inbound sync; then, only with DONNA_AUTODRAFT=1 and Donna ACTIVE, the replies, briefs, follow-ups and cold stages above.

Every email is a DRAFT that goes to the EXISTING outreach gate: donna_stage_outbox puts it in public.outbox as 'draft' (needs_owner) and this module posts it to the
owner's Telegram with Approve / Reject. Only his Approve lets hq_mail send it, through the CASL profile check, suppression, the kill switch, the policy caps and the
outreach gate. The mailing address in the footer is company_profile's (Telegram /setaddress), the same one hq_mail requires, so nothing can go out without it.
Templates are plain code, never the model: lead data never reaches a free AI provider. This module never sends, pays, signs, deploys or changes a permission.
"""
from __future__ import annotations

import datetime as dt
import json
import logging
import os
import re
import urllib.parse
import urllib.request

import hq_donna

logger = logging.getLogger(__name__)

FLAG_INBOUND = "DONNA_INBOUND"
FLAG_AUTODRAFT = "DONNA_AUTODRAFT"
HOSTS = {"api.netlify.com", "api.retellai.com"}
PLACEHOLDER_ADDRESS = "[OWNER: mailing address]"
MODES = ("inbound_reply", "follow_up", "proposal", "onboarding", "client_report")
TZ = dt.timezone(dt.timedelta(hours=-5))          # Ottawa (EST); used only to word dates


class RevenueError(Exception):
    pass


def cfg() -> dict:
    return hq_donna.config()


def rev(c: dict | None = None) -> dict:
    return (c or cfg())["revenue"]


# ------------------------------------------------------------------------------------------------------------------- outbound HTTP (two read-only APIs)
def http_json(method: str, url: str, headers: dict, body: dict | None = None, timeout: int = 20, hosts: set | None = None):
    """https only, to the allowed APIs only (HOSTS, or a caller's own fixed set); the final host after any redirect is checked too."""
    allowed = HOSTS if hosts is None else hosts
    u = urllib.parse.urlparse(url)
    if u.scheme != "https" or u.hostname not in allowed:
        raise RevenueError(f"refused host {u.hostname!r}")
    req = urllib.request.Request(url, data=json.dumps(body).encode() if body is not None else None, method=method)
    for k, v in headers.items():
        req.add_header(k, v)
    req.add_header("Accept", "application/json")
    if body is not None:
        req.add_header("Content-Type", "application/json")
    with urllib.request.urlopen(req, timeout=timeout) as r:
        if urllib.parse.urlparse(r.geturl()).hostname not in allowed:
            raise RevenueError("redirected off the allowed hosts")
        return json.loads(r.read().decode("utf-8") or "null")


def _iso(v) -> str | None:
    if v is None or v == "":
        return None
    if isinstance(v, (int, float)):                                     # Retell: epoch milliseconds
        return dt.datetime.fromtimestamp(v / 1000, tz=dt.timezone.utc).isoformat()
    return str(v)


def _yes(v) -> bool:
    return str(v or "").strip().lower() in ("yes", "on", "true", "1", "checked")


def _clip(v, n: int) -> str | None:
    s = re.sub(r"\s+", " ", str(v or "")).strip()
    return s[:n] or None


# ------------------------------------------------------------------------------------------------------------------- inbound sources
def netlify_items(env: dict, http=http_json) -> list[dict]:
    """Website form submissions (Netlify Forms API). Needs NETLIFY_TOKEN + NETLIFY_SITE_ID. Spam (the honeypot filled) is skipped."""
    token, site = env.get("NETLIFY_TOKEN"), env.get("NETLIFY_SITE_ID")
    if not (token and site):
        return []
    form = env.get("DONNA_FORM_NAME") or rev().get("netlify_form") or "donna-contact"
    rows = http("GET", f"https://api.netlify.com/api/v1/sites/{urllib.parse.quote(site, safe='')}/submissions?per_page=100",
                {"Authorization": f"Bearer {token}", "User-Agent": "DonnaInbound/1.0"}) or []
    out = []
    for s in rows if isinstance(rows, list) else []:
        d = s.get("data") or {}
        if (s.get("form_name") or d.get("form-name")) != form or _clip(d.get("bot-field"), 5):
            continue
        sid = re.sub(r"[^A-Za-z0-9]", "", str(s.get("id") or ""))[:60]
        if not sid:
            continue
        out.append({"p_source": "website_form", "p_ref": f"nf-{sid}", "p_received_at": _iso(s.get("created_at")),
                    "p_person": _clip(d.get("name"), 120), "p_business": _clip(d.get("business"), 160), "p_email": _clip(d.get("email"), 200),
                    "p_phone": _clip(d.get("phone"), 40), "p_marketing_consent": _yes(d.get("marketing_consent")),
                    "p_consent_version": _clip(d.get("consent_version"), 60) if _yes(d.get("marketing_consent")) else None,
                    "p_booked": False, "p_appointment": None, "p_leak_estimate": _clip(d.get("leak_estimate"), 900), "p_summary": _clip(d.get("message"), 600)})
    return out


def retell_items(env: dict, http=http_json) -> list[dict]:
    """Analyzed Donna calls (Retell list-calls). Needs RETELL_API_KEY; DONNA_AGENT_IDS (comma-separated) limits it to Donna's agents. No transcript is kept."""
    key = env.get("RETELL_API_KEY")
    if not key:
        return []
    ids = [x.strip() for x in (env.get("DONNA_AGENT_IDS") or "").split(",") if x.strip()]
    body = {"sort_order": "descending", "limit": 50}
    if ids:
        body["filter_criteria"] = {"agent_id": ids}
    rows = http("POST", "https://api.retellai.com/v2/list-calls", {"Authorization": f"Bearer {key}", "User-Agent": "DonnaInbound/1.0"}, body) or []
    out = []
    for c in rows if isinstance(rows, list) else []:
        a = c.get("call_analysis") or {}
        if c.get("call_status") != "ended" or not a or (ids and c.get("agent_id") not in ids):
            continue
        cd = a.get("custom_analysis_data") or {}
        web = c.get("call_type") == "web_call"
        cid = re.sub(r"[^A-Za-z0-9_-]", "", str(c.get("call_id") or ""))[:90]
        if not cid:
            continue
        booked = bool(cd.get("booked") or cd.get("demo_booked"))
        problem = _clip(cd.get("main_problem"), 300)
        summary = " ".join(x for x in [_clip(a.get("call_summary"), 500), f"Problem: {problem}." if problem else None] if x)
        out.append({"p_source": "web_call" if web else "phone_call", "p_ref": f"rc-{cid}", "p_received_at": _iso(c.get("start_timestamp")),
                    "p_person": _clip(cd.get("caller_name"), 120), "p_business": _clip(cd.get("business_name"), 160), "p_email": _clip(cd.get("email"), 200),
                    "p_phone": _clip(cd.get("callback_number") or ("" if web else c.get("from_number")), 40), "p_marketing_consent": False, "p_consent_version": None,
                    "p_booked": booked, "p_appointment": _clip(cd.get("appointment_time") or cd.get("demo_appointment_time"), 120) if booked else None,
                    "p_leak_estimate": None, "p_summary": _clip(summary, 1000)})
    return out


def sync(rpc=None, env: dict | None = None, http=http_json) -> dict:
    """Pull both sources into the CRM. Never raises; returns counts and the new leads."""
    env = os.environ if env is None else env
    out = {"new": [], "updated": 0, "duplicate": 0, "skipped": 0, "errors": []}
    if env.get(FLAG_INBOUND) != "1":
        out["off"] = f"{FLAG_INBOUND} is not 1"
        return out
    rpc = rpc or hq_donna._rpc_default
    items = []
    for name, fn in (("netlify", netlify_items), ("retell", retell_items)):
        try:
            items += fn(env, http)
        except Exception as e:                                          # one source down never blocks the other
            out["errors"].append(f"{name}: {type(e).__name__}")
    for it in items:
        if not it.get("p_received_at"):
            out["skipped"] += 1
            continue
        try:
            r = rpc("donna_ingest_inbound", it) or {}
        except Exception as e:
            out["errors"].append(f"ingest: {str(e)[:120]}")
            continue
        if r.get("duplicate"):
            out["duplicate"] += 1
        elif r.get("new_lead"):
            out["new"].append({"lead": r.get("lead"), "status": r.get("status"), "contactable": r.get("contactable")})
        else:
            out["updated"] += 1
    return out


# ------------------------------------------------------------------------------------------------------------------- the footer (one address, the send gate's)
def mailing_address(get=None) -> str:
    """company_profile's Donna mailing address (set with /setaddress), else the placeholder: staging refuses a placeholder, so nothing goes out without it."""
    try:
        import hq_mail
        p = hq_mail.profile(hq_mail.DONNA) if get is None else get()
        return (p or {}).get("mailing_address") or PLACEHOLDER_ADDRESS
    except Exception:
        return PLACEHOLDER_ADDRESS


def fill_footer(body: str, c: dict | None = None, get=None) -> str:
    """Replace the runners.json placeholders in a fixed CASL footer with the real address (company_profile) and contact, once they exist. Never invents one."""
    c = c or cfg()
    addr = mailing_address(get)
    if addr != PLACEHOLDER_ADDRESS:
        body = body.replace(c["casl"]["address"], f"Mailing address: {addr}")
    contact = (c.get("revenue") or {}).get("contact")
    if contact:
        body = body.replace(c["casl"]["contact"], contact)
    return body


def footer(address: str, c: dict | None = None) -> str:
    c = c or cfg()
    k = c["casl"]
    return f"--\n{k['sender']}\nMailing address: {address}\n{c['revenue'].get('contact') or k['contact']}\n{k['unsubscribe_email']}"


# ------------------------------------------------------------------------------------------------------------------- templates (plain code)
LEAK_TOTAL = re.compile(r"\$([\d,]+)\s*/\s*month")
LEAK_PART = re.compile(r"\b([a-z]+):\s*\$([\d,]+)/mo")


def leaks(estimate: str | None) -> dict:
    """{'total': cents|None, 'parts': {key: cents}} from the site's leak calculator text. The numbers are the visitor's own; nothing is estimated here."""
    s = str(estimate or "")
    m = LEAK_TOTAL.search(s)
    parts = {k: int(v.replace(",", "")) * 100 for k, v in LEAK_PART.findall(s)}
    return {"total": int(m.group(1).replace(",", "")) * 100 if m else None, "parts": parts}


def money(cents: int | None) -> str:
    return "" if cents is None else f"${cents / 100:,.0f}"


def first_name(person: str | None) -> str:
    n = (person or "").strip().split(" ")[0]
    return n if re.fullmatch(r"[A-Za-zÀ-ÿ'’-]{1,30}", n) else "there"


def setup_line(today: dt.date | None = None, c: dict | None = None) -> str:
    until = dt.date.fromisoformat(rev(c)["setup_free_until"])
    today = today or dt.datetime.now(TZ).date()
    return f"Book before {until.strftime('%B')} {until.day} and setup is free on any plan." if today <= until else ""


def book_line(env: dict | None = None, c: dict | None = None) -> str:
    url = (env if env is not None else os.environ).get(rev(c).get("booking_url_env") or "DONNA_BOOKING_URL", "")
    if url.startswith("https://"):
        return f"Pick a time that suits you here: {url}"
    return "Reply with two or three times that suit you this week and we'll lock one in."


def reply_email(ctx: dict, address: str, *, env: dict | None = None, today: dt.date | None = None, c: dict | None = None) -> tuple[str, str]:
    """The reply to a new inquiry. ctx = donna_lead_context."""
    c = c or cfg()
    r = rev(c)
    biz = ctx.get("business") or "your business"
    inb = ctx.get("inbound") or {}
    hi = f"Hi {first_name(ctx.get('person'))},"
    if inb.get("booked"):
        when = f" ({inb['appointment']})" if inb.get("appointment") else ""
        subject = f"Your free Revenue Leak Audit{when}"
        lines = [hi, "", f"Thanks for booking your free 20-minute Revenue Leak Audit{when}. Our AI specialist will walk through how {biz} handles calls, leads, "
                 "quotes, bookings and admin, and show you where revenue is slipping and what we'd build first.", "",
                 "To make the 20 minutes count, reply with three quick things:",
                 "1. Roughly how many calls you get in a week, and how many you miss",
                 "2. How new leads reach you today (calls, website, social, referrals)",
                 "3. The tools you use for booking, your customer list and invoicing"]
    else:
        subject = f"Your free Revenue Leak Audit, {biz}" if ctx.get("business") else "Your free Revenue Leak Audit"
        lines = [hi, "", f"Thanks for reaching out to {r['brand']}. {r['hook']}"]
        total = leaks(inb.get("leak_estimate"))["total"]
        if total:
            lines += ["", f"Your leak check came out at about {money(total)} a month. Those were your own numbers; on the audit we replace them with real ones."]
        lines += ["", f"The next step is your {r['offer']}. We look at how {biz} handles calls, leads, quotes, bookings and admin, show you where revenue is "
                  "slipping and what we'd build first. No cost, no obligation.", "", book_line(env, c)]
    extra = setup_line(today, c)
    lines += (["", extra] if extra else []) + ["", "Talk soon,", r["brand"], "", footer(address, c)]
    return subject[:150], "\n".join(lines)


def followup_email(ctx: dict, step: int, address: str, *, env: dict | None = None, today: dt.date | None = None, c: dict | None = None) -> tuple[str, str]:
    c = c or cfg()
    r = rev(c)
    biz = ctx.get("business") or "your business"
    hi = f"Hi {first_name(ctx.get('person'))},"
    if step >= int(r.get("max_emails", 3)):
        subject = f"Should I close your file, {biz}?" if ctx.get("business") else "Should I close your file?"
        body = [hi, "", f"This is my last note about the {r['offer']}. If now isn't the right time, no problem: reply \"later\" and we'll check back in a few months.",
                "", "If you'd like to find out where calls, leads and quotes are slipping through, " + book_line(env, c)[0].lower() + book_line(env, c)[1:]]
    else:
        subject = f"Where is {biz} losing revenue?" if ctx.get("business") else "Where is your business losing revenue?"
        body = [hi, "", f"A quick follow-up on my email about a {r['offer']}.", "",
                "Most of the revenue a local business loses is quiet: a call that goes to voicemail, a quote nobody chases, a booking that doesn't show. "
                "In 20 minutes we show you which of these is costing you the most and what we'd do about it.", "", book_line(env, c)]
    extra = setup_line(today, c)
    body += (["", extra] if extra else []) + ["", "Thanks,", r["brand"], "", footer(address, c)]
    return subject[:150], "\n".join(body)


def proposal_email(ctx: dict, package: str, monthly_cents: int, findings: list[str], address: str, *, today: dt.date | None = None,
                   c: dict | None = None) -> tuple[str, str]:
    """After the audit. The package and the price are the OWNER's (typed by him); the findings are his notes from the call."""
    c = c or cfg()
    r = rev(c)
    p = r["packages"].get(package)
    if not p:
        raise RevenueError(f"unknown package {package!r} (one of: {', '.join(r['packages'])})")
    if not (isinstance(monthly_cents, int) and 1000 <= monthly_cents <= 2_000_000):
        raise RevenueError("the monthly price must be between $10 and $20,000")
    if package == "essential" and monthly_cents < p["from_cents"]:
        raise RevenueError(f"Essential starts at {money(p['from_cents'])} a month (owner price)")
    biz = ctx.get("business") or "your business"
    found = [f"- {_clip(f, 240)}" for f in findings if _clip(f, 240)][:6]
    lines = [f"Hi {first_name(ctx.get('person'))},", "", f"Thanks for your time on the Revenue Leak Audit. Here's what we found and what we'd set up for {biz}."]
    if found:
        lines += ["", "What we found:"] + found
    lines += ["", f"What we'd set up ({p['title']}, {p['line']}):"] + [f"- {x}" for x in p["deliverables"]]
    lines += ["", f"Price: {money(monthly_cents)} a month, month-to-month. Monitoring, fixes and tuning are included."]
    until = dt.date.fromisoformat(r["setup_free_until"])
    if (today or dt.datetime.now(TZ).date()) <= until:
        lines.append(f"Setup is free because you're starting before {until.strftime('%B')} {until.day}.")
    lines += ["", "To go ahead, reply \"yes\" and we'll send the invoice and a short onboarding form. Questions first? Just reply.", "", "Thanks,", r["brand"], "",
              footer(address, c)]
    return f"Your {r['brand']} plan: {p['title']}"[:150], "\n".join(lines)


def onboarding_email(ctx: dict, package: str, address: str, *, c: dict | None = None) -> tuple[str, str]:
    """After the client said yes (the owner recorded the win): what we need to build it. The questions map to the receptionist intake (delivery-onboarding)."""
    c = c or cfg()
    r = rev(c)
    p = r["packages"].get(package) or {"title": "your plan"}
    biz = ctx.get("business") or "your business"
    lines = [f"Hi {first_name(ctx.get('person'))},", "", f"Welcome to {r['brand']}. To set up {p['title']} for {biz}, reply to this email with:", "",
             "1. Your business hours, and what should happen after hours",
             "2. Your main services, with typical prices or price ranges you're happy for us to share",
             "3. The 5 to 10 questions customers ask most, with your answers",
             "4. The number we should text or transfer urgent calls to",
             "5. How you book today (calendar or booking tool), and who should get new leads",
             "6. Anything we should never say or promise",
             "", "Once we have these, we build it, test it with you on a test line, and only then switch it on. Questions? Just reply.",
             "", "Thanks,", r["brand"], "", footer(address, c)]
    return f"Welcome to {r['brand']}: what we need to set up {p['title']}"[:150], "\n".join(lines)


def audit_brief(ctx: dict, c: dict | None = None) -> str:
    """Internal: what the owner needs before a booked audit. Never sent to the lead."""
    c = c or cfg()
    r = rev(c)
    inb = ctx.get("inbound") or {}
    lk = leaks(inb.get("leak_estimate"))
    names = r["leak_names"]
    order = sorted(lk["parts"].items(), key=lambda kv: -kv[1])
    lines = [f"Audit brief: {ctx.get('business') or 'unknown business'} (lead #{ctx.get('short_id')})",
             f"When: {inb.get('appointment') or 'not given: confirm the time'}" + (f" · contact {ctx['person']}" if ctx.get("person") else ""),
             f"Came in by: {(inb.get('source') or ctx.get('source') or '').replace('_', ' ')}"]
    if inb.get("summary"):
        lines.append(f"What they said: {_clip(inb['summary'], 400)}")
    if lk["total"]:
        lines.append(f"Their own leak check: {money(lk['total'])}/month ({money(lk['total'] * 12)}/year). Their numbers, not ours.")
        lines += [f"  {names.get(k, k)}: {money(v)}/month" for k, v in order if v]
    else:
        lines.append("No leak check from them: start the call by filling it in together.")
    top = [k for k, v in order if v][:2]
    if top:
        pk = r["leak_packages"].get(top[0])
        big = lk["parts"][top[0]] / lk["total"] if lk["total"] else 0
        fit = (f"Essential (plug {names.get(top[0], top[0])} first)" if big >= 0.5 or len(top) == 1
               else f"{r['packages'][pk]['title']} (biggest leaks: {', '.join(names.get(k, k) for k in top)})")
        lines.append(f"Likely fit: {fit}.")
    lines.append(r["price_note"])
    lines.append("Ask:")
    for k in (top or ["calls", "leads"]) + ["close"]:
        lines += [f"  - {q}" for q in r["questions"].get(k, [])]
    lines += [f"Close: the {r['offer'].replace('free 20-minute ', '')} is free; {setup_line(c=c) or 'setup is quoted'} Month-to-month. Never promise a guarantee or a refund.",
              f"After the call: /donna proposal {ctx.get('short_id')} <essential|front-desk|growth|ai-systems> <monthly $> | finding; finding"]
    return "\n".join(lines)[:7900]


# ------------------------------------------------------------------------------------------------------------------- runner modes (hq_donna dispatches here)
def _save_and_stage(ctx, lead: str, subject: str, body: str, purpose: str) -> dict:
    probs = hq_donna.casl_problems("follow_up_email", subject, body)
    if probs:
        return {"lead": lead, "refused": "; ".join(probs)[:300]}
    try:
        d = ctx.rpc("donna_save_draft", {"p_run": ctx.run_id, "p_kind": "follow_up_email", "p_channel": "email", "p_lead": lead, "p_subject": subject,
                                         "p_body": body, "p_casl": {"checked": "hq_donna.casl_problems", "footer": "fixed", "purpose": purpose}}) or {}
    except Exception as e:                                             # consent / suppression / CASL floor: recorded, never retried around
        return {"lead": lead, "refused": str(e)[:200]}
    out = {"lead": lead, "draft": d.get("draft"), "purpose": purpose}
    try:
        s = ctx.rpc("donna_stage_outbox", {"p_draft": d.get("draft"), "p_purpose": purpose}) or {}
        out["outbox"] = s.get("outbox")
        out["new"] = not s.get("duplicate")
    except Exception as e:                                             # e.g. no mailing address yet: the draft waits, the owner is told why
        out["not_staged"] = str(e)[:200]
    return out


def outreach_mode(ctx, inputs: dict, *, address_get=None, env: dict | None = None) -> dict:
    mode = inputs.get("mode")
    if mode not in MODES:
        raise hq_donna.DonnaRefused(f"unknown outreach mode {mode!r}")
    if mode == "client_report":                                       # Client Agents v1: the monthly report email to a client (hq_donna_agents)
        import hq_donna_agents
        return hq_donna_agents.client_report_run(ctx, inputs, env=env, address_get=address_get)
    ctx.check("draft_outreach")
    address = mailing_address(address_get)
    if address == PLACEHOLDER_ADDRESS:                                # no draft without the real address: it could never be sent, and it would block a later reply
        raise hq_donna.DonnaRefused("no mailing address yet: set it once with /setaddress donna <P.O. box> (CASL), then Donna drafts the replies")
    done = []
    if mode == "onboarding":
        lead = str(inputs.get("lead") or "")
        c = ctx.rpc("donna_lead_context", {"p_lead": lead}) or {}
        subject, body = onboarding_email(c, str(inputs.get("package") or ""), address)
        done.append(_save_and_stage(ctx, lead, subject, body, "onboarding"))
    elif mode == "proposal":
        lead = str(inputs.get("lead") or "")
        c = ctx.rpc("donna_lead_context", {"p_lead": lead}) or {}
        cents = int(inputs.get("monthly_cents") or 0)
        subject, body = proposal_email(c, str(inputs.get("package") or ""), cents, [str(x) for x in inputs.get("findings") or []], address)
        done.append(_save_and_stage(ctx, lead, subject, body, "proposal"))
    else:
        targets = inputs.get("targets") or [{"lead": x} for x in (inputs.get("lead_ids") or [])]
        for t in targets[:25]:
            lead = str(t.get("lead") or "")
            try:
                c = ctx.rpc("donna_lead_context", {"p_lead": lead}) or {}
            except Exception as e:
                done.append({"lead": lead, "refused": str(e)[:200]})
                continue
            if c.get("do_not_contact") or not c.get("has_email"):
                done.append({"lead": lead, "refused": "do-not-contact or no email"})
                continue
            if mode == "inbound_reply":
                subject, body = reply_email(c, address, env=env)
            else:
                subject, body = followup_email(c, int(t.get("step") or 2), address, env=env)
            done.append(_save_and_stage(ctx, lead, subject, body, mode))
    return {"mode": mode, "results": done, "sent": 0}


def audit_brief_run(ctx, inputs: dict) -> dict:
    ctx.check("draft_offer")
    out = []
    for lead in [str(x) for x in (inputs.get("lead_ids") or [])][:10]:
        try:
            c = ctx.rpc("donna_lead_context", {"p_lead": lead}) or {}
            text = audit_brief(c)
            b = ctx.rpc("donna_save_brief", {"p_run": ctx.run_id, "p_lead": lead, "p_body": text}) or {}
            out.append({"lead": lead, "brief": b.get("brief"), "text": text})
        except Exception as e:
            out.append({"lead": lead, "refused": str(e)[:200]})
    return {"mode": "audit_brief", "results": out}


# ------------------------------------------------------------------------------------------------------------------- the owner's Telegram
def post_for_approval(outbox_id: str, label: str, post=None) -> str | None:
    """One Approve / Reject message for a staged outbox draft (the same decision path as /drafts: hq_commands.apply_decision)."""
    import hq
    rows = hq._request("GET", f"/rest/v1/outbox?id=eq.{urllib.parse.quote(str(outbox_id))}&status=eq.draft&select=id,to_ref,subject,body&limit=1") or []
    if not rows:
        return None
    o = rows[0]
    text = f"{label}\nTo: {o.get('to_ref')}\nSubject: {o.get('subject') or ''}\n\n{o.get('body')}"[:3500]
    post = post or (lambda b: hq._request("POST", "/rest/v1/owner_messages", b, prefer="return=representation"))
    m = (post({"from_agent": "jarvis", "kind": "proposal", "channel": "telegram", "needs_decision": True, "ref_table": "outbox", "ref_id": o["id"],
               "body": text, "sent_at": dt.datetime.now(dt.timezone.utc).isoformat()}) or [{}])[0]
    return m.get("id")


def post_brief(text: str, post=None) -> None:
    import hq
    post = post or (lambda b: hq._request("POST", "/rest/v1/owner_messages", b, prefer="return=minimal"))
    post({"from_agent": "jarvis", "kind": "brief", "channel": "telegram", "body": text[:3900], "sent_at": dt.datetime.now(dt.timezone.utc).isoformat()})


LABELS = {"inbound_reply": "Donna drafted a reply to a new inquiry. Approve to send it.",
          "follow_up": "Donna drafted a follow-up. Approve to send it.",
          "proposal": "Donna drafted your proposal. Approve to send it.",
          "retry": "Donna drafted an email for a lead. Approve to send it.",
          "client_report": "Donna drafted the monthly report for your client. Approve to send it.",
          "onboarding": "Donna drafted the welcome email with the onboarding questions. Approve to send it.",
          "cold": "Donna drafted a first email to a prospect (contact published on their own website, CASL implied consent). Approve to send it."}


def announce(result: dict, *, approve=post_for_approval, brief=post_brief) -> int:
    """Post every NEWLY staged draft for approval and every new brief. Returns how many messages went to the owner."""
    n = 0
    for r in (result or {}).get("results") or []:
        if r.get("outbox") and r.get("new"):
            if approve(r["outbox"], LABELS.get(r.get("purpose"), "Donna drafted an email.")):
                n += 1
        elif r.get("brief") and r.get("text"):
            brief(r["text"])
            n += 1
    return n


def stage_cold(rpc, c: dict | None = None, *, approve=post_for_approval) -> dict:
    """Hand Donna's per-lead first emails (outreach-prep drafts for researched prospects) to the outbox for the owner's tap, at most
    revenue.cold_stage_per_day a day and cold_stage_per_tick at a time (the send side has its own daily caps too). Refusals stay as drafts with the reason."""
    r = rev(c)
    out = {"staged": 0, "refused": [], "posted": 0}
    q = rpc("donna_revenue_queue", {"p_limit": 1}) or {}
    room = max(0, min(int(r.get("cold_stage_per_tick", 5)), int(r.get("cold_stage_per_day", 20)) - int(q.get("cold_staged_today") or 0)))
    out["room"] = room
    if not q.get("active"):
        return out
    drafts = rpc("donna_drafts", {"p_status": "draft", "p_limit": 50}) or []
    for d in sorted(drafts, key=lambda x: str(x.get("created_at") or "")):
        cold = d.get("kind") == "cold_email"
        if d.get("kind") not in ("cold_email", "follow_up_email") or d.get("channel") != "email" or not d.get("lead"):
            continue
        if cold and out["staged"] >= room:
            continue
        try:                                                           # a follow_up_email here is one whose staging failed before: retried, never capped
            s = rpc("donna_stage_outbox", {"p_draft": d["id"], "p_purpose": "cold" if cold else "retry"}) or {}
        except Exception as e:
            out["refused"].append({"draft": d["id"], "reason": str(e)[:160]})
            continue
        if s.get("outbox") and not s.get("duplicate"):
            out["staged"] += 1 if cold else 0
            if approve(s["outbox"], LABELS["cold" if cold else "retry"]):
                out["posted"] += 1
    return out


def tick_once(rpc=None, env: dict | None = None, http=http_json, runner=None, approve=post_for_approval, brief=post_brief, status_rpc=None) -> dict:
    """One pass: inbound sync, then (DONNA_AUTODRAFT=1 and Donna active) replies, briefs and follow-ups. Never raises."""
    env = os.environ if env is None else env
    rpc = rpc or hq_donna._rpc_default
    out = {"inbound": sync(rpc, env, http), "messages": 0, "runs": []}
    if env.get(FLAG_AUTODRAFT) != "1":
        out["autodraft"] = f"{FLAG_AUTODRAFT} is not 1"
        return out
    runner = runner or (lambda mission, inputs: hq_donna.run(mission, inputs, rpc=rpc, status_rpc=status_rpc))
    try:
        q = rpc("donna_revenue_queue", {"p_limit": 10}) or {}
    except Exception as e:
        out["error"] = f"queue: {type(e).__name__}"
        return out
    if not q.get("active"):
        out["autodraft"] = "Donna is dormant"
        return out
    jobs = []
    if q.get("reply_needed"):
        jobs.append(("outreach-prep", {"mode": "inbound_reply", "lead_ids": q["reply_needed"][:10]}))
    if q.get("brief_needed"):
        jobs.append(("offer-pricing", {"mode": "audit_brief", "lead_ids": q["brief_needed"][:5]}))
    try:
        due = rpc("donna_followups_due", {"p_limit": 10}) or []
    except Exception:
        due = []
    if due:
        jobs.append(("outreach-prep", {"mode": "follow_up", "targets": due[:10]}))
    if dt.datetime.now(TZ).day <= 3:                                         # Client Agents v1: last month's report for each client, once
        try:
            import hq_donna_agents
            period = hq_donna_agents._period(dt.datetime.now(TZ).date())[0]
            if any(a.get("last_report") != period and a.get("lead") for a in (rpc("donna_client_agents", {}) or [])):
                jobs.append(("outreach-prep", {"mode": "client_report"}))
        except Exception:
            pass                                                              # not installed yet (migration 20261211) or no agents
    try:                                                                       # Prospects v1: once a day, Donna finds new prospects (DONNA_PROSPECTING=1)
        import hq_donna_prospects
        now = dt.datetime.now(TZ)
        if env.get(hq_donna_prospects.FLAG) == "1" and now.hour >= 8 and hq_donna_prospects.due_today(env, now):
            hq_donna_prospects.mark_today(env, now)
            jobs.insert(0, ("market-research", {"mode": "find_prospects"}))
    except Exception:
        pass
    if q.get("prospects_ready") and not q.get("cold_run_today"):           # once a day: first-email drafts for researched prospects (free brain, $0; drafts only)
        jobs.append(("outreach-prep", {"channels": ["email"], "lead_ids": q["prospects_ready"][:int(rev().get("cold_draft_per_day", 10))]}))
    for mission, inputs in jobs:
        try:
            r = runner(mission, inputs) or {}
        except Exception as e:
            out["runs"].append({"mission": mission, "error": type(e).__name__})
            continue
        out["runs"].append({"mission": mission, "mode": inputs.get("mode", "cold"), "ok": r.get("ok"), "refused": r.get("refused")})
        if r.get("ok"):
            try:
                out["messages"] += announce(r.get("result") or {}, approve=approve, brief=brief)
            except Exception as e:
                out["runs"][-1]["announce_error"] = type(e).__name__
    try:                                                                       # Donna Content v1: the weekly creative jobs (DONNA_CONTENT=1), owner approves each asset
        import hq_donna_content
        out["content"] = hq_donna_content.submit_week(rpc, env)
    except Exception as e:
        out["content"] = {"error": type(e).__name__}
    try:
        out["cold"] = stage_cold(rpc, approve=approve)
        out["messages"] += out["cold"]["posted"]
    except Exception as e:
        out["cold"] = {"error": type(e).__name__}
    return out


async def tick(context) -> None:
    """The bot's job (every 5 minutes). Blocking HTTP runs in a thread so the bot never stalls."""
    import asyncio
    try:
        r = await asyncio.to_thread(tick_once)
        if r["inbound"].get("new") or r.get("messages"):
            logger.info("donna revenue tick: %s new leads, %s owner messages", len(r["inbound"].get("new") or []), r.get("messages"))
    except Exception:
        logger.exception("donna revenue tick failed")


# ------------------------------------------------------------------------------------------------------------------- owner views
def inbound_text(rpc=None) -> str:
    rpc = rpc or hq_donna._rpc_default
    try:
        rows = rpc("donna_inbound_recent", {"p_limit": 10}) or []
        q = rpc("donna_revenue_queue", {"p_limit": 10}) or {}
    except Exception as e:
        return f"Donna revenue loop not installed yet (migration 20261210_donna_revenue_loop_v1): {type(e).__name__}."
    lines = [f"Inbound, last 7 days: {q.get('inbound_7d', 0)} ({q.get('booked_7d', 0)} booked). Waiting for your approval: {q.get('outbox_waiting', 0)} email(s). "
             f"Sent this week: {q.get('sent_7d', 0)}."]
    if not q.get("active"):
        lines.append("Donna is dormant: inquiries are recorded, but no replies are drafted until you activate her.")
    elif mailing_address() == PLACEHOLDER_ADDRESS:
        lines.append("Blocked: no mailing address. Set it once with /setaddress donna <P.O. box>; Donna drafts the waiting replies on the next pass.")
    for r in rows:
        when = str(r.get("received_at") or "")[:16].replace("T", " ")
        tag = "BOOKED " if r.get("booked") else ""
        lines.append(f"#{r.get('short_id') or '-'} {tag}{r.get('name') or 'no name'} · {str(r.get('source')).replace('_', ' ')} · {when} · {r.get('status') or 'no lead'}"
                     + (" · do-not-contact" if r.get("do_not_contact") else ""))
    if not rows:
        lines.append("No inquiries recorded yet. Inbound sync needs DONNA_INBOUND=1 plus NETLIFY_TOKEN / NETLIFY_SITE_ID and RETELL_API_KEY in Railway.")
    return "\n".join(lines)


def lead_by_short_id(short_id: int, get=None) -> str | None:
    import hq
    get = get or (lambda path: hq._request("GET", path))
    v = get("/rest/v1/ventures?slug=eq.donna&select=id&limit=1") or []
    if not v:
        return None
    rows = get(f"/rest/v1/leads?short_id=eq.{int(short_id)}&venture_id=eq.{urllib.parse.quote(str(v[0]['id']))}&select=id&limit=1") or []
    return rows[0]["id"] if rows else None


PROPOSAL_RX = re.compile(r"^\s*#?(\d{1,7})\s+(essential|front-desk|growth|ai-systems)\s+\$?([\d,]+(?:\.\d{1,2})?)\s*(?:\|\s*(.*))?$", re.I | re.S)


def parse_proposal(text: str) -> dict:
    """'/donna proposal 12 growth 797 | misses 6 calls a week; quotes never chased' -> runner inputs (lead resolved separately)."""
    m = PROPOSAL_RX.match(text or "")
    if not m:
        raise RevenueError("Use: /donna proposal <lead #> <essential|front-desk|growth|ai-systems> <monthly $> | finding; finding")
    cents = int(round(float(m.group(3).replace(",", "")) * 100))
    findings = [f.strip() for f in re.split(r"[;\n]", m.group(4) or "") if f.strip()][:6]
    return {"short_id": int(m.group(1)), "package": m.group(2).lower(), "monthly_cents": cents, "findings": findings}


def proposal_cmd(text: str, rpc=None, get=None, runner=None, approve=post_for_approval) -> str:
    try:
        p = parse_proposal(text)
    except RevenueError as e:
        return str(e)
    lead = lead_by_short_id(p["short_id"], get)
    if not lead:
        return f"No Donna lead #{p['short_id']}."
    runner = runner or (lambda mission, inputs: hq_donna.run(mission, inputs, rpc=rpc))
    r = runner("outreach-prep", {"mode": "proposal", "lead": lead, "package": p["package"], "monthly_cents": p["monthly_cents"], "findings": p["findings"]}) or {}
    if not r.get("ok"):
        return f"Proposal not drafted: {r.get('refused') or r.get('error') or 'refused'}"
    res = ((r.get("result") or {}).get("results") or [{}])[0]
    if res.get("refused"):
        return f"Proposal not drafted: {res['refused']}"
    if res.get("not_staged"):
        return f"Proposal drafted but not ready to send: {res['not_staged']}"
    if res.get("outbox") and res.get("new"):
        approve(res["outbox"], LABELS["proposal"])
    return "Proposal drafted. Approve it in the message above to send it."


def onboard_cmd(text: str, rpc=None, get=None, runner=None, approve=post_for_approval) -> str:
    """'/donna onboard 12 front-desk': the welcome email with the setup questions, for the owner's tap. Record the win with /deal won first."""
    m = re.match(r"^\s*#?(\d{1,7})\s+(essential|front-desk|growth|ai-systems)\s*$", text or "", re.I)
    if not m:
        return "Use: /donna onboard <lead #> <essential|front-desk|growth|ai-systems>"
    lead = lead_by_short_id(int(m.group(1)), get)
    if not lead:
        return f"No Donna lead #{m.group(1)}."
    runner = runner or (lambda mission, inputs: hq_donna.run(mission, inputs, rpc=rpc))
    r = runner("outreach-prep", {"mode": "onboarding", "lead": lead, "package": m.group(2).lower()}) or {}
    if not r.get("ok"):
        return f"Welcome email not drafted: {r.get('refused') or r.get('error') or 'refused'}"
    res = ((r.get("result") or {}).get("results") or [{}])[0]
    if res.get("refused") or res.get("not_staged"):
        return f"Welcome email not ready to send: {res.get('refused') or res.get('not_staged')}"
    if res.get("outbox") and res.get("new"):
        approve(res["outbox"], LABELS["onboarding"])
    return "Welcome email drafted. Approve it in the message above to send it."


def brief_cmd(short_id: str, rpc=None, get=None, runner=None) -> str:
    if not re.fullmatch(r"#?\d{1,7}", (short_id or "").strip()):
        return "Use: /donna brief <lead #>"
    lead = lead_by_short_id(int(short_id.strip().lstrip("#")), get)
    if not lead:
        return f"No Donna lead #{short_id}."
    runner = runner or (lambda mission, inputs: hq_donna.run(mission, inputs, rpc=rpc))
    r = runner("offer-pricing", {"mode": "audit_brief", "lead_ids": [lead]}) or {}
    if not r.get("ok"):
        return f"Brief not written: {r.get('refused') or r.get('error') or 'refused'}"
    res = ((r.get("result") or {}).get("results") or [{}])[0]
    return res.get("text") or f"Brief not written: {res.get('refused')}"

