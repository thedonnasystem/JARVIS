"""
Shared brain (FENDEZY GROUP Phase 1, M6) for Telegram /brain: read-only search, owner chat only.
The database decides what may be read (fz_brain_report -> fz_brain_read): group-wide facts only for the bot, plus per-office COUNTS (never another office's
text). Office facts reach the group only redacted, through an approval item in /approvals. No model call here (hq_llm is untouched).
"""

from __future__ import annotations

import logging
import re

import hq

logger = logging.getLogger(__name__)


def report(query: str | None = None) -> dict | None:
    q = re.sub(r"\s+", " ", (query or "")).strip()[:100] or None
    try:
        r = hq._request("POST", "/rest/v1/rpc/fz_brain_report", {"p_query": q})
    except Exception as e:
        logger.info("brain report unavailable: %s", e)
        return None
    return r if isinstance(r, dict) and isinstance(r.get("facts"), list) else None


def brain_text(query: str | None = None) -> str:
    r = report(query)
    if not r:
        return "Shared brain is not installed yet (migration pending)."
    facts = r["facts"]
    head = f"Shared brain{' search: ' + query.strip()[:60] if query and query.strip() else ''}: {len(facts)} group fact(s)"
    lines = [head]
    for f in facts[:10]:
        conf = f.get("confidence")
        lines.append(f"- [{f.get('topic')}] {str(f.get('fact') or '')[:200]} ({f.get('source')}, conf {conf}, from {f.get('created_by_office')})")
    by = r.get("by_office") or {}
    if by:
        lines.append("Facts by office: " + ", ".join(f"{k} {v}" for k, v in sorted(by.items())))
    lines.append(f"Promotions waiting: {int(r.get('promotions_pending') or 0)} (see /approvals); Jarvis may approve: {'yes' if r.get('jarvis_may_approve') else 'no'}")
    return "\n".join(lines)
