"""Unified "Needs you" inbox for Telegram: one ranked list of everything waiting on the owner.

The ranking is done once, in the database (`needs_you()`, migration 20261115_inbox_needs_you_v1.sql); this module only fetches
and formats it. It READS only. Approve / Reject / answer still go through the existing decision path
(hq_commands.apply_decision / apply_answer via the inline buttons, or the PWA's app_send), so there is no second way to approve.

  fetch()              -> list[dict] from needs_you(); raises on a database error so callers can say so honestly
  format_inbox(items)  -> Telegram text for /needs
  brief_line(items)    -> one line for the daily brief ("Needs you: 3 waiting, oldest 2d: ...")
  weekly_digest(items) -> counts by kind, oldest item, what is expiring (cheap text; no AI call)
"""
from __future__ import annotations

import logging

import hq

logger = logging.getLogger(__name__)

KIND_LABEL = {
    "approval": "Approve/Reject", "question": "Question", "alert": "Alert", "mission": "Blocked mission", "escalation": "Escalation",
    "proposal": "Proposal", "payment": "Payment", "account": "Account", "draft": "Draft", "task": "Blocked task", "expiring": "Expiring",
}
VERB_HINT = {
    "approve_or_reject": "tap Approve or Reject", "answer": "pick an option", "resume_or_abandon": "Resume or Abandon (/mission)",
    "pay": "pay it, then confirm", "send": "send it, then /sent", "create": "create it, then confirm", "review": "take a look",
}
TG_LIMIT = 3800


FETCH_TIMEOUT = 5  # seconds: hq._request is synchronous and runs inside the async delivery job; a slow database must not hold messages back


def fetch(limit: int = 50) -> list[dict]:
    rows = hq._request("POST", "/rest/v1/rpc/needs_you", {"p_limit": int(limit)}, timeout=FETCH_TIMEOUT)
    if not isinstance(rows, list):
        raise ValueError("needs_you() returned something that is not a list")
    return [r for r in rows if isinstance(r, dict)]


def age_text(minutes) -> str:
    try:
        m = int(minutes or 0)
    except (TypeError, ValueError):
        return ""
    if m < 2:
        return "now"
    if m < 90:
        return f"{m}m"
    if m < 36 * 60:
        return f"{round(m / 60)}h"
    return f"{round(m / 1440)}d"


def _line(i: int, it: dict) -> str:
    kind = KIND_LABEL.get(it.get("kind"), str(it.get("kind") or "Item"))
    head = f"{i}. [{kind}] {str(it.get('title') or '').strip()} ({age_text(it.get('age_minutes'))})"
    why = str(it.get("why") or "").strip()
    todo = it.get("command") or VERB_HINT.get(it.get("action"), "")
    tail = f"   {why}" if why else ""
    if todo:
        tail += f"\n   Do: {todo}"
    return head + ("\n" + tail if tail else "")


def format_inbox(items: list[dict], limit: int = 10) -> str:
    if not items:
        return "Nothing is waiting on you."
    shown = items[:limit]
    out = [f"Needs you: {len(items)} waiting" + (f" (top {len(shown)})" if len(items) > len(shown) else "")]
    out += [_line(i, it) for i, it in enumerate(shown, 1)]
    if len(items) > len(shown):
        out.append(f"...and {len(items) - len(shown)} more. They are all in the app's Inbox tab.")
    text = "\n\n".join(out)
    return text if len(text) <= TG_LIMIT else text[:TG_LIMIT - 20].rstrip() + "\n...(trimmed)"


def brief_line(items: list[dict] | None = None) -> str:
    """One line for the brief. Returns '' when the inbox cannot be read, so a brief is never blocked or made wrong."""
    try:
        items = fetch() if items is None else items
        if not items:
            return "Needs you: nothing waiting."
        oldest = max(items, key=lambda x: int(x.get("age_minutes") or 0))
        top = items[0]
        return (f"Needs you: {len(items)} waiting, oldest {age_text(oldest.get('age_minutes'))}. "
                f"Top: {str(top.get('title') or '')[:80]}. /needs lists them.")
    except Exception as e:  # the brief is more important than the count: any problem, including malformed rows, means no line
        logger.warning("inbox count unavailable for the brief: %s", e)
        return ""


def append_to_brief(text: str, items: list[dict] | None = None) -> str:
    """The brief text plus the inbox line. Never raises and never drops the brief."""
    line = brief_line(items)
    return f"{text}\n\n{line}" if line else text


def weekly_digest(items: list[dict]) -> str:
    if not items:
        return "Weekly digest: nothing is waiting on you."
    counts: dict[str, int] = {}
    for it in items:
        counts[it.get("kind") or "other"] = counts.get(it.get("kind") or "other", 0) + 1
    parts = ", ".join(f"{n} {KIND_LABEL.get(k, k).lower()}" for k, n in sorted(counts.items(), key=lambda kv: (-kv[1], kv[0])))
    oldest = max(items, key=lambda x: int(x.get("age_minutes") or 0))
    exp = [it for it in items if it.get("expires_at")]
    lines = [f"Weekly digest: {len(items)} item(s) waiting on you ({parts}).",
             f"Oldest: {str(oldest.get('title') or '')[:80]} ({age_text(oldest.get('age_minutes'))})."]
    if exp:
        lines.append(f"Expiring: {len(exp)} (soonest: {str(sorted(exp, key=lambda x: str(x['expires_at']))[0].get('title') or '')[:60]}).")
    return "\n".join(lines)


def action_buttons(it: dict):
    """Inline buttons for one item through the EXISTING callbacks (hqd: decision, hqq: answer). None when the item has no tap action."""
    if it.get("action") == "approve_or_reject" and it.get("ref_table") == "owner_messages" and it.get("ref_id"):
        return hq.decision_buttons(it["ref_id"])
    if it.get("action") == "answer" and it.get("ref_table") == "owner_messages" and it.get("ref_id"):
        labels = [a.get("label") or f"Option {i + 1}" for i, a in enumerate(it.get("actions") or [])]
        return hq.option_buttons(it["ref_id"], labels) if labels else None
    return None
