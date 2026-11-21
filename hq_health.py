"""
Health report (FENDEZY GROUP Phase 1, M6) for Telegram /health: read-only, owner chat only.
The checks live in the database (fz_health_report): AI cap headroom (day / week), kill switch and mode, job backlog, failed jobs, the approval backlog, the audit
chain and security findings. The scheduled check (fz_health_check, cron) alerts on status CHANGES only, and only when the owner switched alerts on
(fz_owner_set_health_alerts; default off). This module only reads and formats.
"""

from __future__ import annotations

import logging

import hq

logger = logging.getLogger(__name__)

ICON = {"ok": "OK", "warn": "WARN", "bad": "BAD"}


def report() -> dict | None:
    try:
        r = hq._request("POST", "/rest/v1/rpc/fz_health_report", {})
    except Exception as e:
        logger.info("health report unavailable: %s", e)
        return None
    return r if isinstance(r, dict) and isinstance(r.get("checks"), list) else None


def _d(c) -> str:
    try:
        return f"${int(c) / 100:,.2f}"
    except (TypeError, ValueError):
        return "?"


def _line(c: dict) -> str:
    k, s = c.get("check"), ICON.get(c.get("status"), "?")
    if k in ("ai_cap_day", "spend_week"):
        label = "AI cap today" if k == "ai_cap_day" else "Spend this week"
        return f"{s} {label}: {_d(c.get('used_cents'))} of {_d(c.get('cap_cents'))} ({_d(c.get('headroom_cents'))} left)"
    if k == "kill_switch":
        return f"{s} Kill switch {'ON' if c.get('on') else 'off'}; mode {c.get('mode') or '?'}" + (f" ({c['pause_reason']})" if c.get("pause_reason") else "")
    if k == "job_backlog":
        return f"{s} Jobs: {c.get('queued', 0)} queued, {c.get('overdue', 0)} overdue, {c.get('stale_leases', 0)} stale leases"
    if k == "failed_jobs":
        return f"{s} Failed jobs (24h): {c.get('dead_24h', 0)}"
    if k == "approval_backlog":
        return f"{s} Waiting on you: {c.get('pending', 0)}"
    if k == "audit_chain":
        return f"{s} Audit chain: {c.get('checked', 0)} links, {c.get('breaks') or 0} break(s), {c.get('gaps') or 0} gap(s)"
    if k == "security":
        return f"{s} Security: {c.get('standing', 0)} standing, {c.get('unexpected', 0)} unexpected grant(s), {c.get('definer_changed', 0)} definer change(s)"
    return f"{s} {k}"


def health_text() -> str:
    r = report()
    if not r:
        return "Health report is not installed yet (migration pending)."
    lines = [f"Health: {ICON.get(r.get('overall'), '?')} (alerts {'on' if r.get('alerts_enabled') else 'off'})"]
    lines += [_line(c) for c in r["checks"] if isinstance(c, dict)]
    return "\n".join(lines)
