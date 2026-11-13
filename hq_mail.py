"""Email delivery for owner-approved drafts. DORMANT until RESEND_API_KEY and MAIL_FROM are set in Railway.
Rules (all enforced here, not in prompts): only drafts the owner approved; never in dry_run or with the kill switch on; the policy
engine must allow 'send_email' (daily caps); the body must carry the CASL footer with a real mailing address and an unsubscribe line;
never to a do-not-contact lead. A failed send leaves the draft approved so it retries next tick; nothing is marked sent unless the
provider accepted it."""
import json, os, re, urllib.error, urllib.parse, urllib.request
from datetime import datetime, timedelta, timezone

import hq
import hq_policy

API = "https://api.resend.com/emails"
EMAIL = re.compile(r"^[^@\s]+@[^@\s]+\.[^@\s]+$")


def configured() -> bool:
    return bool(os.environ.get("RESEND_API_KEY") and os.environ.get("MAIL_FROM"))


def _q(v) -> str:
    return urllib.parse.quote(str(v), safe="")


def _get(path: str):
    return hq._request("GET", "/rest/v1/" + path) or []


def live() -> bool:
    rows = _get("system_state?id=eq.1&select=mode,kill_switch&limit=1")
    s = rows[0] if rows else {}
    return s.get("mode") == "live" and not s.get("kill_switch")


DONNA = "donna"
PLACEHOLDER = "[ADD YOUR BUSINESS MAILING ADDRESS - required by CASL]"


class ProfileMissing(Exception):
    """A venture has no complete CASL sender profile (sender, brand, mailing address). Nothing may be queued or sent for it."""


def venture_slug(venture_id) -> str | None:
    if not venture_id:
        return None
    rows = _get(f"ventures?id=eq.{_q(venture_id)}&select=slug&limit=1")
    return rows[0]["slug"] if rows else None


def profile(slug: str | None) -> dict | None:
    """The venture's CASL profile as {sender_name, brand, mailing_address}, or None when it is incomplete.
    Donna keeps its long-standing defaults for sender and brand (address is still required); every other venture needs all three,
    so a new venture can never go out under Donna's brand or without a real address."""
    if not slug:
        return None
    rows = _get(f"company_profile?venture_slug=eq.{_q(slug)}&select=sender_name,brand,mailing_address&limit=1")
    p = (rows or [{}])[0] if isinstance(rows, list) else {}
    sender, brand, addr = (p.get("sender_name") or "").strip(), (p.get("brand") or "").strip(), (p.get("mailing_address") or "").strip()
    if slug == DONNA:
        sender, brand = sender or "Moe", brand or "The Donna System"
    if not (sender and brand and addr) or PLACEHOLDER in addr:
        return None
    return {"sender_name": sender, "brand": brand, "mailing_address": addr}


def footer(slug: str) -> str:
    """CASL footer for a venture. Raises ProfileMissing for a venture without a complete profile (fail closed)."""
    p = profile(slug)
    if not p:
        raise ProfileMissing(slug)
    return (f"\n\n--\n{p['sender_name']}, {p['brand']}\n{p['mailing_address']}\n"
            "To stop receiving emails from us, reply \"unsubscribe\" and we will remove you within 10 business days.")


def profile_refusal(row: dict, prof: dict | None, slug: str | None) -> str | None:
    """Per-venture CASL gate, on top of refusal(): the draft must belong to a venture, that venture needs a complete profile, and the
    footer in the body must carry THAT venture's mailing address (so one venture's footer can never ride on another's email)."""
    if not slug:
        return "draft has no venture, so no CASL sender profile applies"
    if not prof:
        return f"venture {slug} has no complete CASL profile (sender, brand, mailing address)"
    if prof["mailing_address"] not in (row.get("body") or ""):
        return f"email footer does not carry the mailing address of venture {slug}"
    return None


def refusal(row: dict, lead: dict | None = None) -> str | None:
    """Why this draft must NOT be sent right now, or None if it may."""
    to = (row.get("to_ref") or "").strip()
    body = row.get("body") or ""
    if not EMAIL.match(to) or normalize_addr(to) is None:
        return "no valid recipient address"
    if lead and lead.get("do_not_contact"):
        return "lead is marked do-not-contact"
    if "[ADD YOUR BUSINESS MAILING ADDRESS" in body or "unsubscribe" not in body.lower():
        return "missing the CASL footer (mailing address and unsubscribe line)"
    return None


_LOCAL_OK = re.compile(r"[a-z0-9.!#$%&'*+/=?^_`{|}~-]+")
_DOMAIN_OK = re.compile(r"[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)*")


def normalize_addr(p) -> str | None:
    """Mirror of SQL public.normalize_addr (a test runs one table of inputs through both). ONE strict form or None:
    printable ASCII only (tabs, NBSP, zero-width and fullwidth characters are refused, not folded), at most one <...> pair with nothing
    after it, address inside <...> if present, lowercased, +tag dropped from the local part, trailing dots dropped from the domain,
    dots in the local part untouched. A quoted local part, a comment, a list (';' or ',') or anything else odd gives None, which every
    caller treats as 'not one clean address: do not send'."""
    if p is None:
        return None
    s = str(p)
    if re.search(r"[;,]", s) or re.search(r"[^\x20-\x7e]", s) or s.count("<") > 1 or s.count(">") > 1:
        return None
    s = s.strip(" ")
    m = re.search(r"<([^<>]*)>", s)
    if m and s[m.end():].strip(" ") and re.match(r"^[^<]*<[^<>]*>", s):
        return None
    a = (m.group(1) if m else s).strip(" ").lower()
    if not re.fullmatch(r"[^@]+@[^@]+", a):
        return None
    local, domain = a.split("@")
    local = re.sub(r"\+.*$", "", local)
    domain = re.sub(r"\.+$", "", domain)
    if not local or not _LOCAL_OK.fullmatch(local) or not _DOMAIN_OK.fullmatch(domain):
        return None
    return f"{local}@{domain}"


def suppressed(address) -> bool:
    """True when the address is on the do-not-contact list, or when that cannot be checked (fail closed: never send on doubt)."""
    if not (address or "").strip():
        return False
    a = normalize_addr(address)
    if a is None:
        return True  # not one clean address (a list, or unparseable): never send on doubt
    try:
        return bool(_get(f"contact_suppressions?address=eq.{_q(a)}&select=address&limit=1"))
    except urllib.error.HTTPError as e:
        return e.code != 404  # table absent = migration not applied, nothing suppressed yet; any other failure blocks
    except Exception:
        return True


def _post(row: dict) -> bool:
    payload = {"from": os.environ["MAIL_FROM"], "to": [row["to_ref"].strip()], "subject": (row.get("subject") or "Quick question")[:200],
               "text": row["body"]}
    reply_to = os.environ.get("MAIL_REPLY_TO")
    if reply_to:
        payload["reply_to"] = reply_to
    req = urllib.request.Request(API, data=json.dumps(payload).encode(), method="POST", headers={
        "Authorization": "Bearer " + os.environ["RESEND_API_KEY"], "Content-Type": "application/json"})
    try:
        with urllib.request.urlopen(req, timeout=20) as r:
            return 200 <= r.status < 300
    except (urllib.error.URLError, OSError, ValueError):
        return False


def _mark_sent(row: dict) -> None:
    now = datetime.now(timezone.utc).isoformat()
    body = {"status": "sent", "sent_at": now, "sent_by": "system"}
    try:
        hq._request("PATCH", f"/rest/v1/outbox?id=eq.{_q(row['id'])}&status=eq.approved", body, prefer="return=minimal")
    except Exception:
        body.pop("sent_by")
        hq._request("PATCH", f"/rest/v1/outbox?id=eq.{_q(row['id'])}&status=eq.approved", body, prefer="return=minimal")
    if row.get("lead_id"):
        due = (datetime.now(timezone.utc) + timedelta(days=3)).date().isoformat()
        hq._request("PATCH", f"/rest/v1/leads?id=eq.{_q(row['lead_id'])}",
                    {"status": "contacted", "last_contact_at": now, "next_followup_at": due}, prefer="return=minimal")


def _claim(row: dict) -> bool:
    """At-most-once: stamp sent_at on the still-approved, unsent row BEFORE posting. Only the caller that gets the row back may post, so two
    overlapping engines (a deploy overlap) or a retry after a failed bookkeeping write can never send the same email twice. Any error: no claim."""
    try:
        got = hq._request("PATCH", f"/rest/v1/outbox?id=eq.{_q(row['id'])}&status=eq.approved&sent_at=is.null",
                          {"sent_at": datetime.now(timezone.utc).isoformat()}, prefer="return=representation")
        return bool(got)
    except Exception:
        return False


def _release(row: dict) -> None:
    """The provider did not accept it: give the claim back so the next tick retries."""
    try:
        hq._request("PATCH", f"/rest/v1/outbox?id=eq.{_q(row['id'])}&status=eq.approved", {"sent_at": None}, prefer="return=minimal")
    except Exception:
        pass


def _flag_unrecorded(row: dict, why: str) -> None:
    """The provider accepted the email but the database refused to record it as sent (policy limit, trigger, outage). The claim stays, so it
    is NEVER posted again; the owner can see it in the audit log and mark it sent."""
    try:
        hq._request("POST", "/rest/v1/audit_log", {"actor": "system", "action": "email_sent_unrecorded", "target": f"outbox/{row.get('id')}",
                                                    "detail": {"why": why[:200]}}, prefer="return=minimal")
    except Exception:
        pass


def deliver_approved(limit: int = 5) -> dict:
    """Called each engine tick. Returns counts; never raises."""
    out = {"sent": 0, "skipped": 0, "failed": 0, "unrecorded": 0, "reason": None}
    try:
        if not configured():
            out["reason"] = "not configured"; return out
        if not live():
            out["reason"] = "not live"; return out
        rows = _get(f"outbox?status=eq.approved&channel=eq.email&sent_at=is.null&order=created_at.asc&limit={int(limit)}"
                    "&select=id,to_ref,body,subject,lead_id,agent,venture_id")
        for row in rows:
            lead = None
            if row.get("lead_id"):
                leads = _get(f"leads?id=eq.{_q(row['lead_id'])}&select=do_not_contact&limit=1")
                lead = leads[0] if leads else None
            if refusal(row, lead):
                out["skipped"] += 1; continue
            if suppressed(row.get("to_ref")):  # opt-out is per ADDRESS, across ventures (CASL); fails closed on any error
                out["skipped"] += 1; continue
            slug = venture_slug(row.get("venture_id"))
            if profile_refusal(row, profile(slug), slug):
                out["skipped"] += 1; continue
            d = hq_policy.authorize(row.get("agent") or "donna-ops", "send_email", ref=row["id"])
            if d.decision != "allow":
                out["skipped"] += 1; continue
            if not _claim(row):  # someone else has it, it was just sent, or the database refused (do-not-contact, kill switch)
                out["skipped"] += 1; continue
            posted = False
            try:
                posted = _post(row)
            finally:
                if not posted:
                    _release(row)
            if not posted:
                out["failed"] += 1; continue
            try:
                _mark_sent(row); out["sent"] += 1
            except Exception as e:  # the email is out: never retry it, tell the owner's audit trail instead
                _flag_unrecorded(row, f"{type(e).__name__}: {e}")
                out["sent"] += 1; out["unrecorded"] += 1
    except Exception as e:  # delivery must never break the engine tick
        out["reason"] = type(e).__name__
    return out
