"""Corporate office view (Section 11) for Telegram and chat: the nine functions, each computed from real agents and data."""

from __future__ import annotations

import hq


def office_text() -> str:
    try:
        data = hq._request("POST", "/rest/v1/rpc/office_data", {}) or []
    except Exception:
        return "Corporate office view is not installed yet (migration pending)."
    if not data:
        return "No office data yet."
    lines = []
    for f in data:
        staff = [a.get("title") or a.get("slug") for a in f.get("agents") or [] if a.get("status") == "active"]
        head = f"{f['name']}: " + (", ".join(staff[:6]) + (f" +{len(staff) - 6}" if len(staff) > 6 else "") if staff else "UNSTAFFED")
        lines.append(head)
        lines.append(f"  {f.get('headline', '')} | {f.get('open', 0)} open, {f.get('blocked', 0)} blocked, {f.get('done_7d', 0)} done this week, AI 7d ${f.get('spent_7d', 0) / 100:,.2f}")
    return "\n".join(lines)
