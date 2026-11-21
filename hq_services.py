"""
Shared services registry (FENDEZY GROUP Phase 1, M5) for Telegram /services and for the services' own reads. Read-only.

The registry lives in the database (fz_services, report fz_services_report): each shared service, its owner office, the tables it writes and reads, their data
classes, how its rows are attributed to an office, the scoped identity its reads may use and whether that is switched on.

Scoped reads (get()): a service's GET of a table goes through its scoped identity ONLY when all three hold:
  1. the bot runs with FZ_SERVICES_SCOPED_READS=1 (default off: every read keeps the service key, exactly as before);
  2. the owner switched the service's scoped_reads on (fz_owner_set_service; default off);
  3. the M1 table registry lets a scoped role read that table (fz_read), as listed in the report's scoped_read_tables.
Then the read is sent with that identity's token or not at all (hq.as_identity(require=True)): never a silent fall back to the service key.
Anything else (flag off, service unknown, table not scoped-readable, report unavailable) keeps today's service-key read.
"""

from __future__ import annotations

import logging
import os
import time

import hq

logger = logging.getLogger(__name__)

FLAG = "FZ_SERVICES_SCOPED_READS"
_TTL = 300.0
_cache: dict = {"at": 0.0, "by": None}


def report() -> dict | None:
    try:
        r = hq._request("POST", "/rest/v1/rpc/fz_services_report", {})
    except Exception as e:
        logger.info("services report unavailable: %s", e)
        return None
    return r if isinstance(r, dict) and isinstance(r.get("services"), list) else None


def _flag_on() -> bool:
    return os.environ.get(FLAG, "").strip() == "1"


def _config(service: str) -> dict | None:
    now = time.monotonic()
    if _cache["by"] is None or now - _cache["at"] > _TTL:
        r = report()
        _cache["by"] = {s.get("service"): s for s in (r or {}).get("services", []) if isinstance(s, dict)} if r else {}
        _cache["at"] = now
    return (_cache["by"] or {}).get(service)


def reset_cache() -> None:
    _cache["at"], _cache["by"] = 0.0, None


def route(service: str, path: str) -> str | None:
    """The identity a GET of `path` by `service` uses, or None for the service key."""
    if not _flag_on():
        return None
    c = _config(service)
    if not c or not c.get("scoped_reads") or not c.get("scoped_identity") or c.get("status") != "active":
        return None
    table = path.split("?", 1)[0].strip("/")
    return c["scoped_identity"] if table in (c.get("scoped_read_tables") or []) else None


def get(service: str, path: str):
    """GET /rest/v1/<path> for a shared service. Flag off: identical to hq._request("GET", "/rest/v1/<path>")."""
    url = f"/rest/v1/{path}"
    ident = route(service, path)
    if ident is None:
        return hq._request("GET", url)
    with hq.as_identity(ident, require=True):
        return hq._request("GET", url)


def services_text() -> str:
    r = report()
    if not r:
        return "Services registry is not installed yet (migration pending)."
    lines = [f"Shared services: {len(r['services'])} (scoped reads on: {int(r.get('scoped_reads_on') or 0)}; bot flag {FLAG}={'1' if _flag_on() else 'off'})"]
    for s in r["services"]:
        rows = s.get("rows") or {}
        offices = s.get("offices") or {}
        lines.append(f"{s.get('service')} [{s.get('status')}] owner {s.get('owner_office')}: {s.get('title')}")
        lines.append(f"  writes {', '.join(s.get('writes') or []) or '-'}; reads {', '.join(s.get('reads') or []) or '-'}")
        lines.append(f"  data {', '.join(s.get('data_classes') or []) or '-'}; office stamp: {s.get('attribution')}"
                     + (f"; rows {', '.join(f'{k} {v}' for k, v in sorted(rows.items()))}" if rows else "")
                     + (f"; UNSTAMPED since start {s['unstamped_since_start']}" if s.get("unstamped_since_start") else ""))
        if offices:
            lines.append("  by office " + ", ".join(f"{k} {v}" for k, v in sorted(offices.items(), key=lambda kv: (-kv[1], kv[0]))[:6]))
        sc = s.get("scoped_read_tables") or []
        lines.append(f"  scoped reads {'ON' if s.get('scoped_reads') else 'off'} via {s.get('scoped_identity') or '-'}"
                     + (f" for {', '.join(sc)}" if sc else " (no table M1 lets a scoped role read)"))
    return "\n".join(lines)
