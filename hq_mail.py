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


def refusal(row: dict, lead: dict | None = None) -> str | None:
    """Why this draft must NOT be sent right now, or None if it may."""
    to = (row.get("to_ref") or "").strip()
    body = row.get("body") or ""
    if not EMAIL.match(to):
        return "no valid recipient address"
    if lead and lead.get("do_not_contact"):
        return "lead is marked do-not-contact"
    if "[ADD YOUR BUSINESS MAILING ADDRESS" in body or "unsubscribe" not in body.lower():
        return "missing the CASL footer (mailing address and unsubscribe line)"
    return None


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


def deliver_approved(limit: int = 5) -> dict:
    """Called each engine tick. Returns counts; never raises."""
    out = {"sent": 0, "skipped": 0, "failed": 0, "reason": None}
    try:
        if not configured():
            out["reason"] = "not configured"; return out
        if not live():
            out["reason"] = "not live"; return out
        rows = _get(f"outbox?status=eq.approved&channel=eq.email&sent_at=is.null&order=created_at.asc&limit={int(limit)}"
                    "&select=id,to_ref,body,subject,lead_id,agent")
        for row in rows:
            lead = None
            if row.get("lead_id"):
                leads = _get(f"leads?id=eq.{_q(row['lead_id'])}&select=do_not_contact&limit=1")
                lead = leads[0] if leads else None
            if refusal(row, lead):
                out["skipped"] += 1; continue
            d = hq_policy.authorize(row.get("agent") or "donna-ops", "send_email", ref=row["id"])
            if d.decision != "allow":
                out["skipped"] += 1; continue
            if _post(row):
                _mark_sent(row); out["sent"] += 1
            else:
                out["failed"] += 1
    except Exception as e:  # delivery must never break the engine tick
        out["reason"] = type(e).__name__
    return out
