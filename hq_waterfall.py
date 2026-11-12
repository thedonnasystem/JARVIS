"""Master Plan money rules: reinvestment waterfall, HST watch, and coast mode when the owner is away.
Numbers are proposals the owner sets (tax %, buffer months, monthly draw); only RECEIVED cash counts. Not financial advice:
an accountant confirms the tax rate and HST. Nothing here moves money."""
from __future__ import annotations

import logging
import time

import hq

logger = logging.getLogger(__name__)
_last_touch: float | None = None
TOUCH_EVERY = 600  # seconds


def _d(cents) -> str:
    return f"${int(cents or 0) / 100:,.2f}"


def _rpc(name: str, args: dict | None = None):
    return hq._request("POST", f"/rest/v1/rpc/{name}", args or {})


def touch() -> None:
    """Record that the owner is around (throttled). Never raises."""
    global _last_touch
    if _last_touch is not None and time.monotonic() - _last_touch < TOUCH_EVERY:
        return
    _last_touch = time.monotonic()
    try:
        _rpc("owner_seen")
    except Exception as e:
        logger.info("owner_seen skipped: %s", str(e)[:100])


def coast() -> bool:
    """True when the owner has been silent past the coast limit. Fails open (False) so a hiccup never freezes the company."""
    try:
        r = _rpc("coast_state")
        return bool(isinstance(r, dict) and r.get("coast"))
    except Exception:
        return False


COAST_REFUSAL = "Coast mode: the owner has been away, so no new payments, accounts or initiatives until he checks in."


def text(days: int = 30) -> str:
    try:
        w = _rpc("waterfall", {"p_days": int(days)})
    except Exception as e:
        logger.warning("waterfall failed: %s", str(e)[:100])
        return "Waterfall is not available yet (migration finance_rules_v1 may not be applied)."
    if not isinstance(w, dict):
        return "Waterfall unreadable."
    lines = [f"Where received cash goes, last {w['days']} days:",
             f"- Cash received: {_d(w['revenue_cents'])}",
             f"- Tax set-aside ({w['tax_pct']:g}%): {_d(w['tax_setaside_cents'])}",
             f"- Running costs (tools, AI, expenses): {_d(w['running_costs_cents'])}",
             f"- Living buffer: {_d(w['buffer_have_cents'])} of {_d(w['buffer_target_cents'])} target (topping up {_d(w['buffer_fill_cents'])})",
             f"- Your draw: {_d(w['owner_draw_cents'])}",
             f"- Reinvestment pool: {_d(w['pool_cents'])} (best venture {_d(w['pool_best_cents'])}, research and systems {_d(w['pool_research_cents'])}, held for a deal {_d(w['pool_deal_cents'])})"]
    if w.get("shortfall_cents"):
        lines.append(f"- Shortfall: costs and tax exceed cash by {_d(w['shortfall_cents'])}. Nothing to reinvest.")
    lines.append(f"- HST: {w['hst']} (trailing 12 months {_d(w['trailing_12m_revenue_cents'])})")
    lines.append("A structure to test, not financial advice; your accountant confirms tax and HST.")
    return "\n".join(lines)
