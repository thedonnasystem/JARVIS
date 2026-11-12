"""
Bank integration, manual-first (Section 10). The real bank balance is the source of truth: the database caps
spendable cash at what the bank supports (capital_snapshot). This module records the owner's balance, imports
statement CSVs, reconciles them against the ledger, and reports gaps.

Never stored: full account numbers, card numbers, passwords, PINs. Only the last 4 digits of an account.
Only the owner records balances (database trigger). Agents cannot raise their own cash.
"""

from __future__ import annotations

import csv
import io
import logging
import re
from datetime import date, datetime

import hq

logger = logging.getLogger(__name__)
MAX_ROWS = 2000


def _rpc(name: str, args: dict | None = None):
    return hq._request("POST", f"/rest/v1/rpc/{name}", args or {})


def _d(cents) -> str:
    c = int(cents or 0)
    return f"{'-' if c < 0 else ''}${abs(c) / 100:,.2f}"


def to_cents(text: str) -> int | None:
    t = (text or "").strip().replace("$", "").replace(",", "").replace(" ", "")
    if not t:
        return None
    neg = t.startswith("(") and t.endswith(")")
    t = t.strip("()")
    try:
        v = int(round(float(t) * 100))
    except ValueError:
        return None
    return -v if neg else v


def _parse_date(s: str) -> str | None:
    s = (s or "").strip()
    for fmt in ("%Y-%m-%d", "%m/%d/%Y", "%d/%m/%Y", "%Y/%m/%d", "%b %d, %Y"):
        try:
            return datetime.strptime(s, fmt).date().isoformat()
        except ValueError:
            continue
    return None


def parse_statement(raw: str) -> tuple[list[dict], str | None, list[str]]:
    """Statement CSV -> ([{date, description, cents}], last4 or None, problems).
    Understands RBC's export (Account Number, Transaction Date, Description 1/2, CAD$) and generic
    Date / Description / Amount or Debit / Credit files. Account numbers are cut down to 4 digits here."""
    problems: list[str] = []
    rows: list[dict] = []
    last4 = None
    reader = csv.reader(io.StringIO(raw.lstrip("﻿")))
    header = None
    for rec in reader:
        if not any(c.strip() for c in rec):
            continue
        low = [c.strip().lower() for c in rec]
        if header is None:
            if any("date" in c for c in low) and any(("cad" in c or "amount" in c or "debit" in c or "credit" in c) for c in low):
                header = low
                continue
            continue
        def col(*names):
            for n in names:
                for i, h in enumerate(header):
                    if n in h and i < len(rec):
                        return rec[i]
            return ""
        d = _parse_date(col("transaction date", "date"))
        if not d:
            problems.append(f"bad date: {rec[:3]}")
            continue
        amt = col("cad$", "amount")
        cents = to_cents(amt)
        if cents is None:
            deb, cred = to_cents(col("debit", "withdraw")), to_cents(col("credit", "deposit"))
            if deb is None and cred is None:
                problems.append(f"no amount: {rec[:4]}")
                continue
            cents = (cred or 0) - abs(deb or 0)
        desc = " ".join(x.strip() for x in (col("description 1"), col("description 2")) if x.strip()) or col("description").strip()
        acct = re.sub(r"\D", "", col("account number"))
        if acct and not last4:
            last4 = acct[-4:]
        rows.append({"date": d, "description": re.sub(r"\s+", " ", desc)[:200] or "(no description)", "cents": cents})
    if header is None:
        problems.append("No header row found (need a Date column and an amount column).")
    if len(rows) > MAX_ROWS:
        problems.append(f"Only the first {MAX_ROWS} rows were used.")
        rows = rows[:MAX_ROWS]
    return rows, last4, problems


def ensure_account(last4: str | None = None) -> str:
    accts = hq._request("GET", "/rest/v1/bank_accounts?active=eq.true&order=created_at.asc&limit=5&select=id,last4") or []
    for a in accts:
        if not last4 or a.get("last4") == last4:
            return a["id"]
    body = {"label": "RBC operating", "institution": "RBC"}
    if last4 and re.fullmatch(r"\d{4}", last4):
        body["last4"] = last4
    made = hq._request("POST", "/rest/v1/bank_accounts", body, prefer="return=representation")
    return made[0]["id"]


def set_balance(amount_text: str, as_of: str | None = None, by: str = "owner:telegram") -> str:
    cents = to_cents(amount_text)
    if cents is None:
        return "Give the balance as a number, e.g. /bank balance 412.50"
    d = _parse_date(as_of) if as_of else date.today().isoformat()
    if not d:
        return "Date must look like 2026-11-12."
    acct = ensure_account()
    hq._request("POST", "/rest/v1/bank_balances", {"account_id": acct, "as_of": d, "balance_cents": cents, "source": "manual", "entered_by": by},
                prefer="return=minimal")
    return f"Bank balance recorded: {_d(cents)} as of {d}. Spending is now capped at what the bank supports."


def import_statement(raw: str, by: str = "owner:telegram") -> str:
    rows, last4, problems = parse_statement(raw)
    if not rows:
        return "No transactions found. " + (problems[0] if problems else "")
    acct = ensure_account(last4)
    res = _rpc("bank_import", {"p_account": acct, "p_rows": rows}) or {}
    rec = _rpc("bank_reconcile") or {}
    msg = (f"Imported {res.get('new', 0)} new of {res.get('rows', len(rows))} rows ({res.get('duplicates', 0)} already seen). "
           f"Matched to your records: {rec.get('matched_ledger', 0)} ledger, {rec.get('matched_spend', 0)} spend. "
           f"Unmatched: {rec.get('unmatched', 0)}.")
    if problems:
        msg += f" Skipped {len(problems)} row(s): {problems[0]}"
    return msg


def reconcile() -> str:
    r = _rpc("bank_reconcile") or {}
    return f"Matched {r.get('matched_ledger', 0)} to the ledger and {r.get('matched_spend', 0)} to settled spend. Unmatched: {r.get('unmatched', 0)}."


def unmatched_text(limit: int = 15) -> str:
    rows = hq._request("GET", f"/rest/v1/bank_transactions?status=eq.unmatched&order=posted_on.desc&limit={limit}"
                              "&select=posted_on,description,amount_cents") or []
    if not rows:
        return "Every bank transaction is matched."
    return "Unmatched bank rows (no record on our side):\n" + "\n".join(
        f"{r['posted_on']}  {_d(r['amount_cents']):>10}  {r['description'][:40]}" for r in rows)


def alerts() -> list[str]:
    try:
        a = _rpc("bank_alerts")
        return [str(x) for x in a] if isinstance(a, list) else []
    except Exception as e:
        logger.info("bank alerts unavailable: %s", e)
        return []


def status_text() -> str:
    try:
        s = _rpc("capital_snapshot")
    except Exception:
        s = None
    if not isinstance(s, dict) or "bank_balance_cents" not in s:
        return "Bank module not installed yet (migration pending)."
    lines = []
    if s.get("bank_balance_cents") is None:
        lines.append("Bank balance: none recorded. Send /bank balance <amount>.")
    else:
        lines.append(f"Bank balance: {_d(s['bank_balance_cents'])} as of {s['bank_as_of']} ({s['bank_age_days']}d ago)")
        lines.append(f"Spendable (after reservations and unsettled spend): {_d(s['available_cents'])}")
        lines.append(f"Ledger says {_d(s['ledger_available_cents'])}; the lower number rules.")
    for a in alerts():
        lines.append("! " + a)
    lines.append("\n/bank balance <amt> [date] | /bank unmatched | /bank reconcile | send a statement CSV with caption 'bank'")
    return "\n".join(lines)
