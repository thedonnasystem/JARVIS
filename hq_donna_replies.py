"""Donna Replies v1: a lead who answers an email stops getting follow-ups, and "unsubscribe" is honoured on its own, with no typing from the owner.

Replies go to Donna's receiving address (MAIL_REPLY_TO = the <id>.resend.app address from the email provider's Receiving tab, or a receiving domain):
hq_mail already sets Reply-To from it. Every 10 minutes (bot job, DONNA_REPLIES=1) the received emails are listed with the SAME key that sends
(hq_mail.received), each new sender is matched to a Donna lead (donna_record_email_reply), and:
  * a reply moves the lead to 'replied', so donna_followups_due stops the sequence; the owner gets "📩 <business> replied: <first lines>";
  * an unsubscribe reply runs mark_do_not_contact (suppression list, drafts rejected): "🛑 <business> asked to unsubscribe. Done.";
  * a sender who is not a Donna lead is recorded once and nothing else.
Message text is never stored: only the message id, the lead and the kind (the first lines go to the owner's Telegram only). Nothing is sent from here.
"""
from __future__ import annotations

import os
import re

import hq_donna
import hq_donna_revenue as R
import hq_mail

FLAG = "DONNA_REPLIES"
UNSUB = re.compile(r"\b(unsubscribe|remove me|take me off|opt[ -]?out|stop (emailing|sending|contacting)|do not (email|contact)|don'?t (email|contact))\b", re.I)
ADDR = re.compile(r"<([^<>@\s]+@[^<>\s]+)>|([^\s<>\"]+@[^\s<>\"]+)")
QUOTE = re.compile(r"^(>|On .{4,120}wrote:$|-{2,}\s*Original Message|From: )", re.I)


def sender(from_header) -> str | None:
    if isinstance(from_header, dict):
        from_header = from_header.get("email") or ""
    m = ADDR.search(str(from_header or ""))
    return (m.group(1) or m.group(2)).strip().lower() if m else None


def own_text(text: str, n: int = 600) -> str:
    """Their own words: the body above the quoted original (our footer is in the quote, so it can never look like their unsubscribe)."""
    out = []
    for line in (text or "").splitlines():
        if QUOTE.match(line.strip()):
            break
        out.append(line)
    return re.sub(r"\s+", " ", " ".join(out)).strip()[:n]


def is_unsubscribe(subject: str, own: str) -> bool:
    subj = (subject or "").strip()
    return bool(UNSUB.search(own or "")) or (bool(UNSUB.search(subj)) and not subj.lower().startswith(("re:", "fw:", "fwd:")))


def check(rpc=None, post=None, limit: int = 50, list_fn=None, text_fn=None) -> dict:
    """The provider calls live in hq_mail (the one email-provider module): received() and received_text()."""
    if list_fn is None and not os.environ.get("RESEND_API_KEY"):
        return {"off": "the email key is not set"}
    rpc = rpc or hq_donna._rpc_default
    list_fn, text_fn = list_fn or hq_mail.received, text_fn or hq_mail.received_text
    rows = list_fn(limit) or []
    ids = [str(r.get("id")) for r in rows if re.fullmatch(r"[A-Za-z0-9_-]{6,120}", str(r.get("id") or ""))]
    fresh = set(rpc("donna_unseen_messages", {"p_ids": ids}) or []) if ids else set()
    out = {"listed": len(rows), "new": len(fresh), "replies": 0, "unsubscribes": 0, "unmatched": 0, "errors": 0}
    for r in rows:
        mid = str(r.get("id") or "")
        if mid not in fresh:
            continue
        try:
            own = own_text(text_fn(mid) or "")
            res = rpc("donna_record_email_reply", {"p_message_id": mid, "p_from": sender(r.get("from")), "p_received_at": r.get("created_at"),
                                                   "p_unsubscribe": is_unsubscribe(r.get("subject") or "", own)}) or {}
        except Exception:
            out["errors"] += 1
            continue
        if res.get("duplicate"):
            continue
        if not res.get("matched"):
            out["unmatched"] += 1
            continue
        name = res.get("name") or "A lead"
        if res.get("kind") == "unsubscribe":
            out["unsubscribes"] += 1
            text = f"🛑 {name} (#{res.get('short_id')}) asked to unsubscribe. Marked do-not-contact; nothing more goes to them."
        else:
            out["replies"] += 1
            text = f"📩 {name} (#{res.get('short_id')}) replied: “{own[:300]}”\nFollow-ups stopped. Answer from your email, or tell me what to say."
            if res.get("status") == "won":
                text += (f"\nA client: if these are the setup answers, /donna intake {res.get('short_id')} | hours: ...; services: ...; faq: q = a; urgent: +1...; booking: https://...")
        (post or R.post_brief)(text)
    return out


async def tick(context) -> None:
    """The bot's job (every 10 minutes, DONNA_REPLIES=1). Never raises."""
    import asyncio
    import logging
    if os.environ.get(FLAG) != "1":
        return
    try:
        await asyncio.to_thread(check)
    except Exception:
        logging.getLogger(__name__).exception("donna replies check failed")
