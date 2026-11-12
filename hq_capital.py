"""
Capital controller client (Phase 5). The money rules live in the database (capital_policy, reserve_spend,
settle_spend, capital_snapshot); this module asks, settles and reports. CAD cents throughout.

Every paid non-AI action:
    r = hq_capital.reserve(actor, action, vendor, purpose, expected_benefit, alternatives, cents, ...)
    if r["decision"] == "allow": pay; then hq_capital.settle(r["reservation_id"], actual_cents, receipt)
    elif r["decision"] == "ask_owner": hq_policy.request_approval(...)
    else: stop, r["reason"] says why
Projected revenue is never cash: only ledger rows with status 'received' count toward the fund.
"""

from __future__ import annotations

import logging
import urllib.error

import hq

logger = logging.getLogger(__name__)

FIELDS = {  # /capital set <field> <dollars|percent>
    "fund": "operating_fund_cents", "reserve": "min_reserve_cents", "lowcost": "low_cost_threshold_cents",
    "hardstop": "hard_stop_cents", "weekly": "weekly_limit_cents", "txn": "per_transaction_limit_cents",
    "aicap": "low_cost_ai_cap_cents", "reinvest": "reinvest_pct",
}


def _rpc(name: str, args: dict):
    return hq._request("POST", f"/rest/v1/rpc/{name}", args)


def snapshot() -> dict | None:
    try:
        s = _rpc("capital_snapshot", {})
        return s if isinstance(s, dict) else None
    except Exception as e:
        logger.info("capital snapshot unavailable: %s", e)
        return None


def mode() -> str:
    s = snapshot()
    return (s or {}).get("mode") or "normal"


def reserve(actor: str, action: str, vendor: str, purpose: str, expected_benefit: str, alternatives: str, cents: int,
            recurring: bool = False, monthly_cents: int | None = None, days_to_benefit: int | None = None,
            venture_id: str | None = None, mission_id: str | None = None) -> dict:
    try:
        r = _rpc("reserve_spend", {
            "p_actor": actor, "p_action": action, "p_vendor": vendor, "p_purpose": purpose,
            "p_expected_benefit": expected_benefit, "p_alternatives": alternatives, "p_cents": int(cents),
            "p_recurring": bool(recurring), "p_monthly_cents": monthly_cents, "p_days_to_benefit": days_to_benefit,
            "p_venture": venture_id, "p_mission": mission_id,
        })
    except Exception as e:  # fail closed: no reservation, no spending
        return {"decision": "deny", "reason": f"Capital controller unavailable ({type(e).__name__}); nothing is spent."}
    return r if isinstance(r, dict) and r.get("decision") else {"decision": "deny", "reason": "Unreadable capital reply."}


def settle(reservation_id: str, actual_cents: int, receipt: str) -> dict:
    return _rpc("settle_spend", {"p_id": reservation_id, "p_actual_cents": int(actual_cents), "p_receipt": receipt or ""}) or {}


def release(reservation_id: str) -> None:
    _rpc("release_spend", {"p_id": reservation_id})


def _d(cents) -> str:
    return f"${(int(cents or 0)) / 100:,.2f}"


def status_text() -> str:
    s = snapshot()
    if not s:
        return "Capital controller not installed yet (migration pending)."
    lines = [
        f"Operating fund: {_d(s['available_cents'])} available — {str(s['mode']).upper()}",
        f"Started with {_d(s['fund_cents'])} on {s.get('since')}",
        f"Money in (received only): {_d(s['revenue_cents'])}",
        f"Spent: AI {_d(s['ai_spend_cents'])}, other {_d(s['expense_cents'])}, reserved {_d(s['reserved_cents'])}",
        f"Recurring: {_d(s['recurring_monthly_cents'])}/month",
        f"This week: {_d(s['week_spend_cents'])} of {_d(s['weekly_limit_cents'])} weekly limit",
        f"Per purchase limit {_d(s['per_transaction_limit_cents'])}; never below {_d(s['min_reserve_cents'])} reserve",
        f"Reinvest {s.get('reinvest_pct')}% of profit",
    ]
    return "\n".join(lines) + "\n\nChange: /capital set fund|reserve|lowcost|hardstop|weekly|txn|aicap <$> or reinvest <%>"


def set_field(field: str, value: str) -> str:
    col = FIELDS.get((field or "").lower())
    if not col:
        return "Fields: " + ", ".join(FIELDS)
    try:
        if col == "reinvest_pct":
            v = int(value.rstrip("%"))
            if not 0 <= v <= 100:
                return "Reinvest must be 0-100%."
        else:
            v = int(round(float(value.replace("$", "").replace(",", "")) * 100))
            if v < 0:
                return "Must be zero or more."
    except ValueError:
        return "Give a number."
    hq._request("PATCH", "/rest/v1/capital_policy?id=eq.1", {col: v, "updated_by": "owner:telegram"}, prefer="return=minimal")
    return f"Capital {field} set to {value}."
