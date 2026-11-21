"""
Security report (FENDEZY GROUP Phase 1, M4) for Telegram /security: read-only, owner chat only.
The checks live in the database (fz_security_report): privileged grants, SECURITY DEFINER functions without a pinned search_path,
tables with RLS off, identities, registered tokens near expiry, the audit hash chain. This module only reads and formats it.
"""

from __future__ import annotations

import logging

import hq

logger = logging.getLogger(__name__)


def report() -> dict | None:
    try:
        r = hq._request("POST", "/rest/v1/rpc/fz_security_report", {})
    except Exception as e:
        logger.info("security report unavailable: %s", e)
        return None
    return r if isinstance(r, dict) and "privileged" in r else None


def security_text() -> str:
    r = report()
    if not r:
        return "Security report is not installed yet (migration pending)."
    chain = r.get("chain") or {}
    priv = r.get("privileged") or []
    new = [p for p in priv if str(p.get("status", "")).startswith("NEW") or p.get("status") == "alerted"]
    lines = [f"Audit chain: {'OK' if chain.get('ok') else 'BROKEN'} ({int(chain.get('checked') or 0)} records checked"
             + (f", {chain.get('break_count')} finding(s)" if not chain.get("ok") else "") + ")"]
    lines.append(f"Privileged grants: {len(priv)} ({len(new)} new or not acknowledged)")
    lines += [f"- {p.get('item')} [{p.get('status')}]" for p in new[:10]]
    nsp = r.get("definer_without_search_path") or []
    if nsp:
        lines.append(f"Definer functions without a pinned search_path: {len(nsp)}: " + ", ".join(nsp[:5]))
    rls = r.get("rls_off") or []
    lines.append(f"Tables with RLS off: {len(rls)}" + (": " + ", ".join(rls[:8]) if rls else ""))
    ids = r.get("identities") or []
    active = [i.get("identity") for i in ids if i.get("status") == "active"]
    lines.append(f"Identities: {len(active)} active, {sum(1 for i in ids if i.get('status') == 'dormant')} dormant, {sum(1 for i in ids if i.get('status') == 'revoked')} revoked")
    for t in (r.get("tokens_expiring") or [])[:5]:
        lines.append(f"- token for {t.get('identity')} {'EXPIRED' if t.get('expired') else 'expires'} {str(t.get('expires_at') or '')[:10]}")
    for a in (r.get("alerts") or [])[:3]:
        lines.append(f"Alert {str(a.get('at') or '')[:16]}: {a.get('kind')} {a.get('item')}")
    lines.append("Read-only. Nothing here changes a grant or a token (runbook: ops/TOKEN_ROTATION_RUNBOOK.md).")
    return "\n".join(lines)
