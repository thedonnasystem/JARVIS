"""Fendezy HQ systems registry: every venture's systems stay separate, HQ just watches and wakes them.

Free Render services sleep after 15 minutes idle and get 750 free hours a month per account, so HQ does NOT ping
them all day. It checks each system only at its warm-up times (Toronto), e.g. the dialer just before the shift, so it is
awake when Moe needs it, and alerts him once if a system is down.
"""
from __future__ import annotations

import logging
import time
import urllib.error
import urllib.parse
import urllib.request
from datetime import datetime, timedelta
from zoneinfo import ZoneInfo

import hq

logger = logging.getLogger(__name__)
TZ = ZoneInfo("America/Toronto")
WINDOW_MINUTES = 6  # the engine ticks every 5 minutes; a warm-up time is "due" for this long
_done: set[str] = set()  # "slug@YYYY-MM-DD HH:MM" already checked by this process


def _q(v: str) -> str:
    return urllib.parse.quote(str(v), safe="")


def probe(url: str, timeout: int = 75) -> tuple[int, int]:
    """GET the URL (a sleeping free service can take ~30-60 s to wake). Returns (status, ms); status 0 = unreachable."""
    t0 = time.monotonic()
    try:
        req = urllib.request.Request(url, headers={"User-Agent": "FendezyHQ-health/1.0"})
        with urllib.request.urlopen(req, timeout=timeout) as r:
            return r.status, int((time.monotonic() - t0) * 1000)
    except urllib.error.HTTPError as e:
        return e.code, int((time.monotonic() - t0) * 1000)
    except Exception:
        return 0, int((time.monotonic() - t0) * 1000)


def due(warmups: list[str], now: datetime) -> list[str]:
    """Warm-up times (HH:MM Toronto) that fall inside the last WINDOW_MINUTES."""
    out = []
    for hhmm in warmups or []:
        try:
            h, m = (int(x) for x in hhmm.split(":"))
        except ValueError:
            continue
        at = now.replace(hour=h, minute=m, second=0, microsecond=0)
        if at <= now < at + timedelta(minutes=WINDOW_MINUTES):
            out.append(hhmm)
    return out


def run_due_checks(now: datetime | None = None) -> int:
    now = now or datetime.now(TZ)
    rows = hq._request("GET", "/rest/v1/systems?active=eq.true&health_url=not.is.null"
                              "&select=slug,name,health_url,warmup_local_times") or []
    checked = 0
    for s in rows:
        for hhmm in due(s.get("warmup_local_times") or [], now):
            key = f"{s['slug']}@{now:%Y-%m-%d} {hhmm}"
            if key in _done:
                continue
            _done.add(key)
            status, ms = probe(s["health_url"])
            if not 200 <= status < 400:  # one retry: the first hit often only wakes a sleeping service
                status, ms = probe(s["health_url"])
            hq._request("PATCH", f"/rest/v1/systems?slug=eq.{_q(s['slug'])}",
                        {"last_status": status, "last_ms": ms, "last_checked_at": datetime.now(TZ).isoformat()},
                        prefer="return=minimal")
            if not 200 <= status < 400:
                hq._request("POST", "/rest/v1/owner_messages", {
                    "from_agent": "jarvis", "kind": "health", "channel": "telegram",
                    "body": f"Health: {s['name']} is not responding (status {status or 'no answer'}) at its {hhmm} check.",
                }, prefer="return=minimal")
            checked += 1
    return checked


def status_lines() -> list[str]:
    rows = hq._request("GET", "/rest/v1/systems?active=eq.true&order=venture_slug.asc.nullsfirst"
                              "&select=name,venture_slug,host,last_status,last_ms,last_checked_at") or []
    out = []
    for r in rows:
        if r.get("last_checked_at"):
            ok = "up" if r.get("last_status") and 200 <= r["last_status"] < 400 else f"DOWN ({r.get('last_status')})"
            state = f"{ok}, {r.get('last_ms') or 0} ms, checked {str(r['last_checked_at'])[5:16].replace('T', ' ')}"
        else:
            state = "not monitored"
        out.append(f"- {r['name']} [{r.get('venture_slug') or 'company'}] {r.get('host') or ''}: {state}")
    return out
