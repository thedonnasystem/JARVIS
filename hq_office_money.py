"""
Office money (FENDEZY GROUP Phase 1, M2): virtual sub-ledgers per office, read and proposed from the bot.
The rules live in the database (migrations/20261128_office_money_v1.sql); this module only reads, proposes and asks.

    hq_office_money.offices_text()                        # /offices: per office allocated, spent, revenue, profit, available
    hq_office_money.propose("donna", "allocate", 5000, rationale="...")   # the owner executes it (or not); the bot never can
    r = hq_office_money.reserve("donna", actor, action, vendor, purpose, benefit, alternatives, cents)
        # office layer in front of the capital controller: refused if the office is dormant or short, otherwise exactly
        # what reserve_spend() decides. Fails CLOSED: any error is a refusal, nothing is spent.

There is ONE real bank account (the group's). Office balances are accounting attribution, not cash. Allocation, clawback
and the reinvestment rule are owner-only (signed-in owner session); nothing here can change them.
"""

from __future__ import annotations

import logging

import hq

logger = logging.getLogger(__name__)

KINDS = ("allocate", "clawback", "reinvest")


def _rpc(name: str, args: dict):
    return hq._request("POST", f"/rest/v1/rpc/{name}", args)


def _d(cents) -> str:
    c = int(cents or 0)
    return f"{'-' if c < 0 else ''}${abs(c) / 100:,.2f}"


def report() -> dict | None:
    try:
        r = _rpc("fz_money_report", {})
    except Exception as e:  # not installed yet, or unreachable
        logger.info("office money report unavailable: %s", e)
        return None
    return r if isinstance(r, dict) and "offices" in r else None


def offices_text() -> str:
    r = report()
    if not r:
        return "Office money is not installed yet (migration pending)."
    lines = ["Offices (virtual sub-ledgers; one real bank account, the group's)"]
    for o in r.get("offices") or []:
        status = str(o.get("status") or "?")
        flag = "" if status == "active" else f" [{status.upper()}]"
        lines.append(f"{o.get('title') or o.get('office')}{flag}: available {_d(o.get('available_cents'))} | allocated {_d(o.get('allocated_cents'))}, "
                     f"spent {_d(o.get('spent_cents'))}" + (f" (+{_d(o.get('reserved_cents'))} reserved)" if o.get("reserved_cents") else "")
                     + f", revenue {_d(o.get('revenue_cents'))}, profit {_d(o.get('profit_cents'))}, reinvest {int(o.get('reinvest_pct') or 0)}%")
    g = r.get("group") or {}
    t = r.get("totals") or {}
    lines.append(f"Group (not in an office): spent {_d(g.get('spent_cents'))}, revenue {_d(g.get('revenue_cents'))}")
    lines.append(f"TOTAL allocated {_d(t.get('allocated_cents'))}, spent {_d(t.get('spent_cents'))}, revenue {_d(t.get('revenue_cents'))}, profit {_d(t.get('profit_cents'))}")
    lines.append(f"Capital available {_d(r.get('capital_available_cents'))} ({str(r.get('capital_mode') or '?').upper()}); "
                 f"not allocated to an office {_d(r.get('unallocated_cents'))}")
    pend = r.get("pending_proposals") or []
    if pend:
        lines.append(f"Waiting on you: {len(pend)} money proposal(s)")
        for p in pend[:5]:
            what = f"reinvest {p.get('reinvest_pct')}%" if p.get("kind") == "reinvest" else f"{p.get('kind')} {_d(p.get('cents'))}"
            lines.append(f"- {p.get('office')}: {what} (by {p.get('by')}) id {p.get('id')}")
    lines.append("Allocation, clawback and reinvestment: only you, in your owner session (ops/OWNER_OFFICE_MONEY.sql).")
    if r.get("since"):
        lines.append(f"Counting from {str(r['since'])[:10]}; earlier money is the group's.")
    return "\n".join(lines)


def propose(office: str, kind: str, cents: int | None = None, reinvest_pct: int | None = None, rationale: str = "", by: str = "jarvis") -> dict:
    """Put a money proposal in front of the owner. Never moves money: only the owner can execute it."""
    if kind not in KINDS:
        return {"ok": False, "reason": f"kind must be one of {', '.join(KINDS)}"}
    if kind == "reinvest":
        if reinvest_pct is None or not 0 <= int(reinvest_pct) <= 100:
            return {"ok": False, "reason": "reinvestment must be 0-100%"}
        cents = None
    elif cents is None or int(cents) <= 0:
        return {"ok": False, "reason": "amount must be above $0"}
    if len((rationale or "").strip()) < 10:
        return {"ok": False, "reason": "give the owner a rationale (10+ characters)"}
    try:
        r = _rpc("fz_propose_office_money", {"p_office": office, "p_kind": kind, "p_cents": None if cents is None else int(cents),
                                             "p_reinvest_pct": None if reinvest_pct is None else int(reinvest_pct),
                                             "p_rationale": rationale.strip()[:2000], "p_by": by})
    except Exception as e:
        return {"ok": False, "reason": f"proposal not recorded ({type(e).__name__})"}
    if not isinstance(r, dict) or not r.get("proposal"):
        return {"ok": False, "reason": "unreadable reply"}
    return {"ok": True, **r}


def reserve(office: str, actor: str, action: str, vendor: str, purpose: str, expected_benefit: str, alternatives: str, cents: int,
            recurring: bool = False, monthly_cents: int | None = None, days_to_benefit: int | None = None,
            venture_id: str | None = None, mission_id: str | None = None) -> dict:
    """Office spend gate (in front of the capital controller). Fails closed: any error is a refusal."""
    try:
        r = _rpc("fz_reserve_office_spend", {
            "p_office": office, "p_actor": actor, "p_action": action, "p_vendor": vendor, "p_purpose": purpose,
            "p_expected_benefit": expected_benefit, "p_alternatives": alternatives, "p_cents": int(cents),
            "p_recurring": bool(recurring), "p_monthly_cents": monthly_cents, "p_days_to_benefit": days_to_benefit,
            "p_venture": venture_id, "p_mission": mission_id,
        })
    except Exception as e:
        return {"decision": "deny", "reason": f"Office spend gate unavailable ({type(e).__name__}); nothing is spent.", "office": office}
    if not isinstance(r, dict) or r.get("decision") not in ("allow", "deny", "ask_owner"):
        return {"decision": "deny", "reason": "Unreadable office gate reply; nothing is spent.", "office": office}
    return r
