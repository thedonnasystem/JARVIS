"""Donna Intake v1: the client's setup answers become the onboarding intake in one Telegram line, with no model and no retyping into JSON.

  /donna intake <lead #> | name: Al's Diner; hours: mon-fri 9-17, sat 10-14; services: Oil change $89 30min, Brake check $120 60min;
                faq: Walk-ins? = Yes, before 3 pm; faq: Parking? = Free lot out back; urgent: +1 613 555 0100; booking: https://cal.com/als/visit; city: Kanata

Every field except the name is optional (the name defaults to the lead's). The parser is plain code (lead and client data never go to a model), it refuses what it
cannot read instead of guessing, and the result goes through the existing delivery-onboarding mission (reception_config validates it, donna_save_intake stores
it with its open items). Then /donna agent <client> previews the client's own phone agent. Nothing here sends, pays or deploys.
"""
from __future__ import annotations

import re

import hq_donna
import hq_donna_revenue as R

DAYS = ("mon", "tue", "wed", "thu", "fri", "sat", "sun")
DAY_ALIASES = {"monday": "mon", "tuesday": "tue", "tues": "tue", "wednesday": "wed", "thursday": "thu", "thur": "thu", "thurs": "thu", "friday": "fri",
               "saturday": "sat", "sunday": "sun", "weekdays": "mon-fri", "weekends": "sat-sun", "daily": "mon-sun", "everyday": "mon-sun"}
KEYS = {"name": "name", "business": "name", "hours": "hours", "services": "services", "service": "services", "faq": "faq", "faqs": "faq",
        "urgent": "urgent", "escalation": "urgent", "phone": "urgent", "booking": "booking", "book": "booking", "city": "city", "timezone": "timezone", "tz": "timezone"}
TIME = re.compile(r"^(\d{1,2})(?::(\d{2}))?\s*(am|pm)?$", re.I)
CMD = re.compile(r"^\s*#?(\d{1,7})\s*\|\s*(.+)$", re.S)
TZ = re.compile(r"^America/[A-Za-z_]{3,30}$")


class IntakeError(ValueError):
    pass


def _day(tok: str) -> str:
    t = tok.strip().lower().rstrip(".")
    t = DAY_ALIASES.get(t, t)
    t = t[:3] if t[:3] in DAYS and len(t) <= 9 else t
    if t not in DAYS:
        raise IntakeError(f"hours: unknown day {tok.strip()!r} (use mon tue wed thu fri sat sun)")
    return t


def _days(spec: str) -> list[str]:
    spec = DAY_ALIASES.get(spec.strip().lower(), spec.strip().lower())
    out: list[str] = []
    for part in re.split(r"[/&+]|\band\b", spec):
        part = part.strip()
        if not part:
            continue
        if "-" in part or " to " in part:
            a, b = re.split(r"\s*(?:-|to)\s*", part, maxsplit=1)
            i, j = DAYS.index(_day(a)), DAYS.index(_day(b))
            if j < i:
                raise IntakeError(f"hours: day range {part!r} runs backwards")
            out += list(DAYS[i:j + 1])
        else:
            out.append(_day(part))
    return out


def _time(tok: str, *, end: bool = False, start_h: int | None = None) -> str:
    m = TIME.match(tok.strip())
    if not m:
        raise IntakeError(f"hours: cannot read the time {tok.strip()!r} (use 9-17, 9am-5pm or 09:00-17:30)")
    h, mi, ap = int(m.group(1)), int(m.group(2) or 0), (m.group(3) or "").lower()
    if ap:
        if not 1 <= h <= 12:
            raise IntakeError(f"hours: {tok.strip()!r} is not a clock time")
        h = (h % 12) + (12 if ap == "pm" else 0)
    elif end and start_h is not None and h <= start_h and h <= 12:
        h += 12  # "9-5" means 09:00-17:00
    if h == 24 and mi == 0 and end:
        return "23:59"
    if not (0 <= h <= 23 and 0 <= mi <= 59):
        raise IntakeError(f"hours: {tok.strip()!r} is not a clock time")
    return f"{h:02d}:{mi:02d}"


def parse_hours(text: str) -> dict:
    """'mon-fri 9-17, sat 10am-2pm, sun closed' -> {"mon": [["09:00","17:00"]], ..., "sun": []}. Days not named are closed."""
    hours = {d: [] for d in DAYS}
    named = False
    chunks, pending = [], []
    for c in [c.strip() for c in re.split(r",", text or "") if c.strip()]:
        if re.fullmatch(r"[A-Za-z.]+", c) and c.lower() not in ("closed",):           # "mon, wed, fri 9-5": a bare day joins the next chunk
            pending.append(c)
            continue
        chunks.append("/".join(pending + [c]) if pending else c)
        pending = []
    if pending:
        raise IntakeError(f"hours: {', '.join(pending)!r} has no times (use e.g. mon, wed, fri 9-5)")
    for chunk in chunks:
        m = re.match(r"^([A-Za-z/&+. -]+?)\s+(closed|[0-9].*)$", chunk, re.I)
        if not m:
            raise IntakeError(f"hours: cannot read {chunk!r} (use e.g. mon-fri 9-17, sat 10-14, sun closed)")
        days = _days(m.group(1))
        named = True
        if m.group(2).lower() == "closed":
            for d in days:
                hours[d] = []
            continue
        spans = []
        for span in re.split(r"\s*(?:&|\band\b|/)\s*", m.group(2)):
            ab = re.split(r"\s*(?:-|–|to)\s*", span.strip(), maxsplit=1)
            if len(ab) != 2:
                raise IntakeError(f"hours: {span!r} needs a start and an end (9-17)")
            a = _time(ab[0])
            b = _time(ab[1], end=True, start_h=int(a[:2]))
            if not a < b:
                raise IntakeError(f"hours: {span!r} ends before it starts")
            spans.append([a, b])
        for d in days:
            hours[d] = spans
    if not named:
        raise IntakeError("hours: nothing to read")
    return hours


def parse_services(text: str) -> list[dict]:
    """'Oil change $89 30min, Brake check $120.50 1h, Free estimate' -> [{"name", "price_cents", "minutes"}]. No price means 0 (an open item)."""
    out = []
    for chunk in [c.strip() for c in re.split(r",(?!\d{3}\b)", text or "") if c.strip()][:30]:      # "$1,200" keeps its comma
        chunk = re.sub(r"(?<=\d),(?=\d{3}\b)", "", chunk)
        price = re.search(r"\$\s*([\d]+(?:\.\d{1,2})?)", chunk)
        mins = re.search(r"\b(\d{1,3})\s*(?:min|mins|minutes|m)\b", chunk, re.I)
        hrs = re.search(r"\b(\d(?:\.\d)?)\s*(?:h|hr|hrs|hour|hours)\b", chunk, re.I)
        name = re.sub(r"\$\s*[\d]+(?:\.\d{1,2})?|\b\d{1,3}\s*(?:min|mins|minutes|m)\b|\b\d(?:\.\d)?\s*(?:h|hr|hrs|hour|hours)\b", "", chunk, flags=re.I)
        name = re.sub(r"\s{2,}", " ", name).strip(" -:()")
        if not name:
            raise IntakeError(f"services: {chunk!r} has no service name")
        minutes = int(mins.group(1)) if mins else int(round(float(hrs.group(1)) * 60)) if hrs else 30
        if not 5 <= minutes <= 600:
            raise IntakeError(f"services: {chunk!r} has a length outside 5 minutes to 10 hours")
        out.append({"name": name[:60], "price_cents": int(round(float(price.group(1)) * 100)) if price else 0, "minutes": minutes})
    return out


def parse_phone(text: str) -> str:
    digits = re.sub(r"[^\d+]", "", text or "")
    if digits.startswith("+"):
        e = "+" + re.sub(r"\D", "", digits)
    elif len(digits) == 10:
        e = "+1" + digits
    elif len(digits) == 11 and digits.startswith("1"):
        e = "+" + digits
    else:
        raise IntakeError(f"urgent: {text.strip()!r} is not a phone number (use +1 613 555 0100)")
    if not re.fullmatch(r"\+[1-9]\d{7,14}", e):
        raise IntakeError(f"urgent: {text.strip()!r} is not a phone number (use +1 613 555 0100)")
    return e


def parse(text: str) -> dict:
    """The part after '|': 'key: value; key: value'. Returns {"short_id", "intake"}; refuses what it cannot read."""
    m = CMD.match(text or "")
    if not m:
        raise IntakeError("Use: /donna intake <lead #> | name: ...; hours: mon-fri 9-17, sat 10-14; services: Oil change $89 30min, ...; "
                          "faq: question = answer; urgent: +1 613 555 0100; booking: https://...; city: Ottawa")
    intake: dict = {}
    faqs = []
    for field in [f.strip() for f in re.split(r";|\n", m.group(2)) if f.strip()]:
        km = re.match(r"^([A-Za-z]+)\s*[:=]\s*(.*)$", field, re.S)
        if not km or km.group(1).lower() not in KEYS:
            raise IntakeError(f"cannot read {field[:60]!r}: start each part with name:, hours:, services:, faq:, urgent:, booking:, city: or timezone:")
        key, val = KEYS[km.group(1).lower()], km.group(2).strip()
        if not val:
            raise IntakeError(f"{key}: is empty")
        if key == "name":
            intake["business_name"] = re.sub(r"\s+", " ", val)[:80]
        elif key == "hours":
            intake["hours"] = parse_hours(val)
        elif key == "services":
            intake["services"] = parse_services(val)
        elif key == "faq":
            if "=" not in val:
                raise IntakeError(f"faq: {val[:60]!r} needs 'question = answer'")
            q, a = (s.strip() for s in val.split("=", 1))
            if not q or not a:
                raise IntakeError(f"faq: {val[:60]!r} needs both a question and an answer")
            faqs.append({"q": q[:200], "a": a[:400]})
        elif key == "urgent":
            intake["escalation_number"] = parse_phone(val)
        elif key == "booking":
            if not re.fullmatch(r"https://[A-Za-z0-9.-]+\.[A-Za-z]{2,}(/[^\s]*)?", val):
                raise IntakeError("booking: use the full https:// booking link")
            intake["booking_url"] = val[:200]
        elif key == "city":
            intake["city"] = re.sub(r"[^A-Za-z .'-]", "", val)[:40]
        elif key == "timezone":
            if not TZ.match(val):
                raise IntakeError("timezone: use e.g. America/Toronto")
            intake["timezone"] = val
    if faqs:
        intake["faqs"] = faqs[:30]
    return {"short_id": int(m.group(1)), "intake": intake}


def lead_name(lead_id: str, get=None) -> str | None:
    import urllib.parse

    import hq
    get = get or (lambda path: hq._request("GET", path))
    rows = get(f"/rest/v1/leads?id=eq.{urllib.parse.quote(str(lead_id))}&select=name&limit=1") or []
    return (rows[0].get("name") or None) if rows else None


def intake_cmd(text: str, rpc=None, get=None, runner=None) -> str:
    try:
        p = parse(text)
    except IntakeError as e:
        return str(e)
    lead = R.lead_by_short_id(p["short_id"], get)
    if not lead:
        return f"No Donna lead #{p['short_id']}."
    intake = p["intake"]
    if not intake.get("business_name"):
        intake["business_name"] = (lead_name(lead, get) or "")[:80]
        if not intake["business_name"]:
            return "Lead has no name on file: add name: <business> to the line."
    runner = runner or (lambda mission, inputs: hq_donna.run(mission, inputs, rpc=rpc))
    r = runner("delivery-onboarding", {"intake": intake, "lead_id": lead}) or {}
    if not r.get("ok"):
        return f"Intake not saved: {r.get('refused') or r.get('error') or 'refused'}"
    res = r.get("result") or {}
    cfg = res.get("reception_config") or {}
    open_days = [d for d in DAYS if (cfg.get("hours") or {}).get(d)]
    lines = [f"Intake saved for {cfg.get('business_name') or intake['business_name']}:",
             f"- open: {', '.join(open_days) or 'no days'}",
             f"- services: {len(cfg.get('services') or [])}; FAQs: {len(cfg.get('faqs') or [])}",
             f"- urgent calls to: {'set' if re.fullmatch(r'[+][1-9][0-9]{7,14}', str(cfg.get('escalation_number') or '')) else 'not set'}"]
    items = [str(x) for x in (res.get("open_items") or [])][:6]
    if items:
        lines.append("Still open: " + "; ".join(items))
    label = re.sub(r"[^A-Za-z0-9 &.,'-]", "", str(cfg.get("business_name") or intake["business_name"]))[:79]
    lines.append(f"Next: /donna agent {label}  (preview of the client's phone agent)")
    return "\n".join(lines)
