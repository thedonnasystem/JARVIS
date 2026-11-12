#!/usr/bin/env python3
"""Rank day-job leads from a CSV export. Runs LOCALLY on the file you give it; nothing is uploaded or stored in HQ.
Usage: python scripts/rank_leads.py leads.csv [--top 200] [--out ranked.csv]
Column names are auto-detected (case-insensitive, partial match): name, phone, status/notes/disposition, last contact date,
annual usage/kWh, sign-up/created date. Missing columns are fine; the score just uses what exists. Every row shows WHY it scored.
Hard exclusions (never ranked, listed in the summary): do-not-call/not-interested/wrong-number/deceased flags and rows with no phone.
This is a transparent heuristic, not a model: check the top 20 by eye and tell me what it got wrong so the weights can be tuned."""
import argparse, csv, re, sys
from datetime import date, datetime

EXCLUDE = re.compile(r"do not call|dnc|not interested|wrong number|deceased|disconnected|unsubscribe|remove me|hostile", re.I)
WARM = re.compile(r"interested|call ?back|quote|follow ?up|maybe|think about|send info|appointment|booked|warm", re.I)
FIND = {"name": ("name",), "phone": ("phone", "mobile", "cell", "tel"), "status": ("status", "disposition", "outcome", "notes", "comment"),
        "last": ("last contact", "last call", "last_contact", "last_called", "last activity", "updated"),
        "usage": ("kwh", "usage", "consumption", "annual"), "created": ("created", "signed", "lead date", "date added", "added")}


def pick(headers: list[str]) -> dict:
    cols = {}
    for key, needles in FIND.items():
        for h in headers:
            if any(n in h.lower() for n in needles):
                cols[key] = h; break
    return cols


def parse_date(s: str):
    for f in ("%Y-%m-%d", "%m/%d/%Y", "%d/%m/%Y", "%Y/%m/%d", "%b %d, %Y"):
        try:
            return datetime.strptime(s.strip(), f).date()
        except ValueError:
            pass
    return None


def parse_num(s: str):
    m = re.search(r"[\d,]+(\.\d+)?", (s or "").replace(" ", ""))
    return float(m.group(0).replace(",", "")) if m else None


def score(row: dict, cols: dict, today: date) -> tuple[int, list[str]] | None:
    status = row.get(cols.get("status", ""), "") or ""
    phone = re.sub(r"\D", "", row.get(cols.get("phone", ""), "") or "")
    if EXCLUDE.search(status) or len(phone) < 10:
        return None
    pts, why = 10, ["has a phone number"]
    if WARM.search(status):
        pts += 40; why.append("showed interest before")
    last = parse_date(row.get(cols.get("last", ""), "") or "")
    if last:
        days = (today - last).days
        if days < 0: pass
        elif days <= 14: pts -= 15; why.append("contacted in the last 2 weeks (give it space)")
        elif days <= 90: pts += 20; why.append("contacted 2-13 weeks ago (good follow-up window)")
        elif days <= 365: pts += 10; why.append("contacted 3-12 months ago")
        else: pts += 3; why.append("cold, over a year")
    else:
        pts += 5; why.append("never contacted or no date")
    use = parse_num(row.get(cols.get("usage", ""), "") or "")
    if use:
        bump = 15 if use >= 12000 else 8 if use >= 6000 else 0
        if bump: pts += bump; why.append(f"high usage ({use:,.0f})")
    return max(pts, 0), why


def main() -> int:
    ap = argparse.ArgumentParser(); ap.add_argument("csv"); ap.add_argument("--top", type=int, default=200); ap.add_argument("--out", default="ranked_leads.csv")
    a = ap.parse_args()
    with open(a.csv, newline="", encoding="utf-8-sig") as f:
        rd = csv.DictReader(f); rows = list(rd); cols = pick(rd.fieldnames or [])
    if "phone" not in cols:
        print("No phone column found. Columns seen:", rd.fieldnames); return 1
    today, ranked, dropped = date.today(), [], 0
    for r in rows:
        s = score(r, cols, today)
        if s is None: dropped += 1; continue
        ranked.append((s[0], "; ".join(s[1]), r))
    ranked.sort(key=lambda x: -x[0])
    keep = ranked[: a.top]
    with open(a.out, "w", newline="", encoding="utf-8") as f:
        w = csv.writer(f); w.writerow(["rank", "score", "why"] + list(rows[0].keys() if rows else []))
        for i, (sc, why, r) in enumerate(keep, 1): w.writerow([i, sc, why] + list(r.values()))
    print(f"Read {len(rows)} rows. Columns used: {cols}. Excluded {dropped} (DNC/not interested/no phone). Wrote top {len(keep)} to {a.out}.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
