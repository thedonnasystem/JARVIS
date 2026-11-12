"""
Payment instructions (Section 10, manual-approval path). Jarvis prepares; the OWNER pays in RBC and confirms.
Funds are reserved first by the capital controller (limits and minimum reserve apply). Nothing here moves money,
stores credentials or touches a bank session. All checks live in the database functions (migration payments_v1).
"""

from __future__ import annotations

import logging
import re

import hq

logger = logging.getLogger(__name__)


def _rpc(name: str, args: dict):
    return hq._request("POST", f"/rest/v1/rpc/{name}", args)


def _d(cents: int) -> str:
    return f"${cents / 100:,.2f}"


def parse_amount(text: str) -> int | None:
    m = re.fullmatch(r"\$?\s*([0-9][0-9,]*(?:\.[0-9]{1,2})?)", (text or "").strip())
    if not m:
        return None
    cents = round(float(m.group(1).replace(",", "")) * 100)
    return cents if cents > 0 else None


def prepare(actor: str, payee: str, cents: int, purpose: str, alternatives: str = "", due_on: str | None = None,
            venture: str | None = None) -> str:
    """Reserve funds and ask the owner. Returns a plain sentence for the caller to relay."""
    if not (payee or "").strip() or len(purpose or "") < 5 or int(cents or 0) <= 0:
        return "A payment needs a payee, a purpose (5+ characters) and an amount above zero."
    import hq_waterfall
    if hq_waterfall.coast():
        return hq_waterfall.COAST_REFUSAL
    try:
        r = _rpc("prepare_payment", {"p_actor": actor, "p_payee": payee.strip()[:120], "p_cents": int(cents), "p_purpose": purpose.strip()[:300],
                                     "p_alternatives": (alternatives or "")[:300], "p_due": due_on, "p_venture_slug": venture})
    except Exception as e:  # fail closed
        logger.warning("prepare_payment failed: %s", e)
        return "Payments are not available yet (migration pending); nothing was reserved."
    if not isinstance(r, dict):
        return "Unreadable reply from the capital controller; nothing was reserved."
    if r.get("decision") == "allow":
        return f"Payment of {_d(int(cents))} to {payee} is reserved and waiting for the owner's approval. I will not pay it; the owner pays in RBC."
    return f"Not prepared: {r.get('reason', 'refused')}"


def decide(instruction_id: str, approved: bool, by: str = "owner:telegram") -> str:
    try:
        return str(_rpc("decide_payment", {"p_id": instruction_id, "p_approved": bool(approved), "p_by": by}))
    except Exception as e:
        return f"Could not record the decision: {str(e)[:160]}"


def _resolve(short: str) -> str | None:
    short = re.sub(r"[^0-9a-f]", "", (short or "").lower())[:8]
    if len(short) < 6:
        return None
    rows = hq._request("GET", f"/rest/v1/payment_instructions?id=gte.{short.ljust(8, '0')}-0000-0000-0000-000000000000"
                              f"&id=lte.{short.ljust(8, 'f')}-ffff-ffff-ffff-ffffffffffff&select=id&limit=2") or []
    return rows[0]["id"] if len(rows) == 1 else None


def confirm(short_id: str, amount_text: str, reference: str, by: str = "owner:telegram") -> str:
    pid, cents = _resolve(short_id), parse_amount(amount_text)
    if not pid:
        return "I could not find exactly one payment with that id. Send /pay to list them."
    if cents is None:
        return "Amount must look like 15 or 1,250.50."
    if len((reference or "").strip()) < 3:
        return "Include the bank reference or confirmation number from RBC."
    try:
        return str(_rpc("confirm_payment", {"p_id": pid, "p_paid_cents": cents, "p_receipt": reference.strip()[:120], "p_by": by}))
    except Exception as e:
        return f"Could not record the payment: {str(e)[:160]}"


def open_text() -> str:
    try:
        return str(_rpc("payments_text", {}))
    except Exception:
        return "Payments are not available yet (migration pending)."
