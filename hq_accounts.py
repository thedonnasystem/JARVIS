"""
Account requests. Jarvis asks for a business account; the owner approves, signs up himself (captcha, codes, ID and payment
steps are always his), then confirms with the login email or username. Passwords are never stored or accepted.
"""

from __future__ import annotations

import logging
import re

import hq

logger = logging.getLogger(__name__)
NEEDS = ("captcha", "email_code", "sms_code", "id", "payment")


def _rpc(name: str, args: dict):
    return hq._request("POST", f"/rest/v1/rpc/{name}", args)


def request(actor: str, vendor: str, purpose: str, venture: str | None = None, url: str = "", monthly_cents: int = 0,
            needs: list[str] | None = None) -> str:
    if len((vendor or "").strip()) < 2 or len((purpose or "").strip()) < 5:
        return "An account request needs a vendor and a purpose (5+ characters)."
    if url and not re.match(r"^https://[^\s]+$", url):
        return "Sign-up URL must start with https://."
    needs = [n for n in (needs or []) if n in NEEDS]
    import hq_waterfall
    if hq_waterfall.coast():
        return hq_waterfall.COAST_REFUSAL
    try:
        r = _rpc("request_account", {"p_actor": actor, "p_vendor": vendor.strip()[:80], "p_purpose": purpose.strip()[:300], "p_venture_slug": venture or None,
                                     "p_url": url or None, "p_monthly_cents": max(int(monthly_cents or 0), 0), "p_needs": needs})
    except Exception as e:
        logger.warning("request_account failed: %s", e)
        return "Account requests are not available yet (migration pending); nothing was requested."
    if not isinstance(r, dict) or r.get("decision") == "deny":
        return f"Not requested: {(r or {}).get('reason', 'refused') if isinstance(r, dict) else 'unreadable reply'}"
    return f"Asked the owner to create the {vendor} account. I cannot sign up myself; he does the sign-up and tells me the login."


def decide(request_id: str, approved: bool, by: str = "owner:telegram") -> str:
    try:
        return str(_rpc("decide_account", {"p_id": request_id, "p_approved": bool(approved), "p_by": by}))
    except Exception as e:
        return f"Could not record the decision: {str(e)[:160]}"


def _resolve(short: str) -> str | None:
    short = re.sub(r"[^0-9a-f]", "", (short or "").lower())[:8]
    if len(short) < 6:
        return None
    rows = hq._request("GET", f"/rest/v1/account_requests?id=gte.{short.ljust(8, '0')}-0000-0000-0000-000000000000"
                              f"&id=lte.{short.ljust(8, 'f')}-ffff-ffff-ffff-ffffffffffff&select=id&limit=2") or []
    return rows[0]["id"] if len(rows) == 1 else None


def complete(short_id: str, login: str, by: str = "owner:telegram") -> str:
    rid = _resolve(short_id)
    if not rid:
        return "I could not find exactly one account request with that id. Send /account to list them."
    try:
        return str(_rpc("complete_account", {"p_id": rid, "p_login": (login or "").strip()[:120], "p_by": by}))
    except Exception as e:
        return f"Could not record the account: {str(e)[:160]}"


def open_text() -> str:
    try:
        return str(_rpc("accounts_text", {}))
    except Exception:
        return "Account requests are not available yet (migration pending)."
