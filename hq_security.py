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
    return r if isinstance(r, dict) and "standing" in r else None


def security_text() -> str:
    r = report()
    if not r:
        return "Security report is not installed yet (migration pending)."
    chain = r.get("chain") or {}
    lines = [f"Audit chain: {'OK' if chain.get('ok') else 'BROKEN'} ({int(chain.get('checked') or 0)} links checked"
             + (f", {chain.get('break_count')} finding(s)" if not chain.get("ok") else "") + (f", {chain.get('gaps')} gap(s)" if chain.get("gaps") else "") + ")"]
    if chain.get("reinitialised_at"):
        lines.append(f"Chain re-initialised {str(chain['reinitialised_at'])[:16]} (after a rollback)")
    std = r.get("standing") or []
    lines.append(f"STANDING findings: {len(std)} (API-role writes; fix them or apply ops/proposals/audit_ledger_append_only.sql)")
    lines += [f"- {x}" for x in std[:8]] + ([f"- ... and {len(std) - 8} more"] if len(std) > 8 else [])
    unexp = r.get("unexpected") or []
    lines.append(f"Grants not on the reviewed list: {len(unexp)} (list has {int(r.get('expected_count') or 0)})")
    lines += [f"- {p.get('item')} [{p.get('status')}]" for p in unexp[:8]] + ([f"- ... and {len(unexp) - 8} more"] if len(unexp) > 8 else [])
    for c in (r.get("definer_changed") or [])[:3]:
        lines.append(f"Definer function changed: {c.get('function')} at {str(c.get('changed_at') or '')[:16]}")
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
