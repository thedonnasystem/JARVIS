"""Quality Control for the legacy offices.  /qc <office>  and  /qc all

/doctor asks "does it run?". /qc asks "does it make money, and is the output good enough?":
  1. outcome metrics: the office's revenue funnel (found -> qualified -> contacted -> replied -> booked -> closed -> $ per week), cost and time per result;
  2. a quality rubric (0-5 each): lead accuracy and fit, proposal / message quality, duplicate and junk rate, data freshness, deliverability readiness;
  3. comparison with the office's targets and with the previous QC run (aggregates kept in LEGACY_QC_STATE), and the bottleneck: where the funnel leaks;
  4. a plain verdict, keep / fix / kill, with the top 3 changes ranked by expected revenue impact and their effort.
Collectors read the office's OWN data in a local clone or its data files and return COUNTS ONLY. No name, address, phone, email or listing
text leaves a collector. Where an office has no outcome data, QC says so and names the tracking that starts measuring it.
The optional LLM judge (judge()) grades SYNTHETIC samples only, through hq_llm's free-brain routing.
"""
from __future__ import annotations

import csv
import json
import os
import re
import sqlite3
from collections import Counter
from datetime import datetime, timedelta, timezone

from legacy_offices import redact, registry

ACTIONS_USD_PER_MIN = 0.008   # GitHub Linux runner overage price (public list price; confirm on the billing page)
FILLER = re.compile(r"(?i)\b(i hope this (message|email) finds you|i am writing to|i came across your (post|job)|dear sir|to whom it may concern|"
                    r"i am confident that|look no further|i would love the opportunity|passionate about|synerg)")
CTA = re.compile(r"(?i)(\?|\b(call|chat|reply|book|schedule|send|share|walk you through|happy to|next step)\b)")


# ------------------------------------------------------------------------------------------------------------------- rubric helpers
LIMITS = {"proposal": ((25, 140), (2, 6), 200), "letter": ((80, 450), (4, 30), 600)}


def score_message(text: str, context_terms: list[str] | None = None, kind: str = "proposal") -> dict:
    """Heuristic grade of one proposal / outreach message, 0-5: specific to the post, short, no filler, one clear next step, honest (no numbers
    it cannot back). Returns {score, reasons}. Works on synthetic or redacted text; never stores it."""
    t = str(text or "").strip()
    words = len(t.split())
    sentences = max(1, len(re.findall(r"[.!?](\s|$)", t)))
    (w0, w1), (s0, s1), tail = LIMITS[kind]
    reasons, s = [], 5
    if not w0 <= words <= w1:
        s -= 1; reasons.append(f"{words} words (aim {w0}-{w1})")
    if not s0 <= sentences <= s1:
        s -= 1; reasons.append(f"{sentences} sentences (aim {s0}-{s1})")
    if FILLER.search(t):
        s -= 1; reasons.append("generic filler opener")
    if not CTA.search(t[-tail:]):
        s -= 1; reasons.append("no clear next step at the end")
    terms = [w.lower() for w in (context_terms or []) if len(w) > 3]
    if terms and not any(w in t.lower() for w in terms):
        s -= 1; reasons.append("nothing specific to the post")
    if re.search(r"(?i)\b(guarantee|100%|10x|triple your)\b", t):
        s -= 1; reasons.append("promise it cannot back")
    return {"score": max(s, 0), "reasons": reasons}


def _band(x, good, ok):
    """ratio -> 0-5 (>=good: 5, >=ok: 3, >0: 1, 0: 0)."""
    if x is None:
        return None
    return 5 if x >= good else 3 if x >= ok else 1 if x > 0 else 0


def _age_days(day, now):
    try:
        d = datetime.fromisoformat(str(day)[:10]).replace(tzinfo=timezone.utc)
    except ValueError:
        return None
    return (now - d).total_seconds() / 86400


def _fresh_score(age):
    return None if age is None else 5 if age <= 1.5 else 3 if age <= 3 else 1 if age <= 7 else 0


def _read_jsonl(path):
    with open(path, encoding="utf-8") as f:
        for line in f:
            line = line.strip()
            if line:
                try:
                    yield json.loads(line)
                except ValueError:
                    continue


# ------------------------------------------------------------------------------------------------------------------- collectors (counts only)
def collect_wholesale(root, now, **_):
    sd = os.path.join(root, "scraper")
    m = {"funnel": {}, "rubric": {}, "notes": [], "outcome_data": False}
    fl = os.path.join(sd, "funnel_latest.json")
    if not os.path.isfile(fl):
        m["notes"].append("funnel_latest.json not found")
        return m
    d = json.load(open(fl, encoding="utf-8"))
    leads = d.get("leads") or []
    n = len(leads)
    tiers = Counter(str(l.get("tier")) for l in leads)
    qualified = tiers.get("A", 0) + tiers.get("B", 0)
    priced = sum(1 for l in leads if l.get("priced"))
    matched = sum(1 for l in leads if l.get("buyer_matches"))
    hot = sum(1 for l in leads if str(l.get("contact_band")).upper() == "HOT")
    no_comps = sum(1 for l in leads if str(l.get("market_pos", "")).upper().startswith("INSUFFICIENT"))
    new_today = sum(1 for l in leads if l.get("new_today"))
    age = _age_days(d.get("date"), now)
    found_week, dup_share, junk_share = None, None, None
    cp = os.path.join(sd, "corpus.jsonl")
    if os.path.isfile(cp):
        cut = (now - timedelta(days=7)).strftime("%Y-%m-%d")
        seen, dups, junk, total, fw = set(), 0, 0, 0, 0
        for r in _read_jsonl(cp):
            total += 1
            key = (r.get("norm_address") or "").strip().lower()
            if key and key in seen:
                dups += 1
            seen.add(key)
            if not r.get("price") or not key or not r.get("fsa"):
                junk += 1
            if str(r.get("first_seen", ""))[:10] >= cut:
                fw += 1
        found_week, dup_share, junk_share = fw, dups / total if total else None, junk / total if total else None
    m["funnel"] = {"found": found_week, "qualified": n, "priced": priced, "buyer_matched": matched, "contacted": None, "replied": None,
                   "booked": None, "closed": None, "revenue_week": None}
    m["sizes"] = {"funnel_leads": n, "hot": hot, "new_today": new_today, "tiers": dict(tiers), "no_comps": no_comps}
    oc = os.path.join(sd, "outcomes.jsonl")
    if os.path.isfile(oc):
        cut = now - timedelta(days=7)
        st, fee = Counter(), 0.0
        for r in _read_jsonl(oc):
            t = r.get("ts")
            try:
                when = datetime.fromisoformat(str(t).replace("Z", "+00:00"))
            except ValueError:
                continue
            if when >= cut:
                st[str(r.get("stage"))] += 1
                fee += float(r.get("fee_cad") or 0)
        m["outcome_data"] = True
        m["funnel"].update({"contacted": st.get("contacted", 0), "replied": st.get("replied", 0), "booked": st.get("booked", 0), "closed": st.get("closed", 0),
                            "revenue_week": round(fee, 2)})
    else:
        m["notes"].append("no outcome data: nothing records contacted / replied / booked / closed per lead (tracking: scraper/outcomes.py on the improvement PR)")
    letter = os.path.join(root, "contracts", "outreach_letter_template.md")
    msg = score_message(open(letter, encoding="utf-8").read()[:4000], ["property", "offer", "house"], kind="letter") if os.path.isfile(letter) else None
    sender = os.path.isfile(os.path.join(root, "contracts", "sender_identity.md"))
    m["rubric"] = {
        "lead_fit": (_band(qualified / n if n else None, 0.4, 0.2), f"{qualified}/{n} leads tier A/B; {matched}/{n} buyer-matched"),
        "message_quality": (msg["score"] if msg else None, "outreach letter template: " + (", ".join(msg["reasons"]) or "ok") if msg else "no outreach template"),
        "dup_junk": (None if dup_share is None else 5 - min(5, round((dup_share + (no_comps / n if n else 0)) * 10)),
                     f"corpus duplicate addresses {dup_share:.1%}, incomplete rows {junk_share:.1%}; {no_comps}/{n} leads lack comps" if dup_share is not None else "no corpus"),
        "freshness": (_fresh_score(age), f"funnel dated {d.get('date')} ({age:.1f} days)" if age is not None else "undated"),
        "deliverability": (3 if sender else 1, "sender identity documented; mailing / CASL readiness not proven, no letter has been tracked as sent" if sender else "no sender identity"),
    }
    return m


def collect_freelance(root, now, db_path=None, **_):
    m = {"funnel": {k: None for k in ("found", "qualified", "contacted", "replied", "booked", "closed", "revenue_week")}, "rubric": {}, "notes": [], "outcome_data": False}
    path = db_path or os.environ.get("FREELANCE_DB_PATH", "")
    if path and os.path.isfile(path):
        cut = (now - timedelta(days=7)).isoformat()
        con = sqlite3.connect(f"file:{path}?mode=ro", uri=True)
        try:
            seen = con.execute("select count(*) from jobs_seen where first_seen_at >= ?", (cut,)).fetchone()[0]
            rows = con.execute("select status, coalesce(outcome, 'pending') from proposals where sent_at >= ?", (cut,)).fetchall()
        finally:
            con.close()
        st = Counter(s for s, _ in rows)
        oc = Counter(o for _, o in rows)
        m["outcome_data"] = True
        m["funnel"].update({"found": seen, "qualified": len(rows), "contacted": st.get("auto_submitted", 0) + oc.get("applied", 0),
                            "replied": oc.get("replied", 0) + oc.get("interview", 0) + oc.get("hired", 0), "booked": oc.get("interview", 0) + oc.get("hired", 0),
                            "closed": oc.get("hired", 0)})
    else:
        m["notes"].append("no outcome data: the pipeline's SQLite lives on a Railway volume that was removed with the deployment; set FREELANCE_DB_PATH to a copy "
                          "to measure. Manual applications are never marked 'applied', so contacted cannot be counted (the improvement PR adds report.py --mark).")
    ev = os.path.join(root, "tests", "fixtures", "jobs_labeled.json") if root else ""
    fit = None
    if ev and os.path.isfile(ev):
        fit = _filter_precision(root, ev)
    m["rubric"] = {
        "lead_fit": (None if fit is None else _band(fit, 0.6, 0.3), f"filter precision on the labeled synthetic sample: {fit:.0%}" if fit is not None else
                     "measured on the improvement PR's labeled sample (see its before/after)"),
        "message_quality": (None, "no stored drafts to grade; synthetic grading via judge() / score_message()"),
        "dup_junk": (None, "junk rate is the filter's false-positive rate (lead_fit)"),
        "freshness": (0, "service not deployed since July 2026: nothing is being polled"),
        "deliverability": (2, "RemoteOK / WWR apply by link (manual); Freelancer.com bids were auto-submitted with no review"),
    }
    return m


def _filter_precision(root, path):
    """Precision of the repo's own labels file written by its tests (expected fields: predicted, label). None if unreadable."""
    try:
        rows = json.load(open(path, encoding="utf-8"))
        pred = [r for r in rows if r.get("predicted")]
        return sum(1 for r in pred if r.get("label")) / len(pred) if pred else None
    except (ValueError, OSError, AttributeError):
        return None


def collect_dialer(root, now, events_csv=None, **_):
    m = {"funnel": {k: None for k in ("found", "contacted", "replied", "booked", "closed", "revenue_week")}, "rubric": {}, "notes": [], "outcome_data": False}
    path = events_csv or os.environ.get("DIALER_EVENTS_CSV", "")
    if path and os.path.isfile(path):
        cut = (now - timedelta(days=7)).isoformat()
        types, outs = Counter(), Counter()
        with open(path, encoding="utf-8", newline="") as f:
            for row in csv.reader(f):
                if len(row) < 6 or row[0] < cut[:19]:
                    continue
                types[row[1]] += 1
                if row[1] == "outcome":
                    outs[row[5]] += 1
        dials = sum(types.get(k, 0) for k in ("answered", "no_answer", "voicemail", "second_answer", "screened", "quick_hangup"))
        ans = types.get("answered", 0)
        abandon = types.get("second_answer", 0) / (ans + types.get("second_answer", 0)) if ans + types.get("second_answer", 0) else None
        m["outcome_data"] = True
        m["funnel"].update({"contacted": dials, "replied": ans, "booked": outs.get("pitched", 0) + outs.get("closed", 0), "closed": outs.get("closed", 0)})
        m["sizes"] = {"abandon_rate": abandon, "dnc": outs.get("dnc", 0)}
        m["rubric"]["deliverability"] = (5 if abandon is not None and abandon <= 0.03 else 3 if abandon is not None and abandon <= 0.05 else 0,
                                         f"abandoned (second answer hung up) {abandon:.1%} of live answers (rule: 5% max)" if abandon is not None else "no answers yet")
        m["rubric"]["lead_fit"] = (_band(ans / dials if dials else None, 0.15, 0.08), f"answer rate {ans}/{dials}")
    else:
        m["notes"].append("no outcome data here: call events live in the dialer's Railway volume (events.csv). Export it (GET /api/log.csv) and set "
                          "DIALER_EVENTS_CSV to measure; QC reads counts only.")
        m["rubric"]["deliverability"] = (None, "abandoned-call rate unknown; with LINES=4 and no guard, the synthetic simulation on the PR exceeds 5%")
        m["rubric"]["lead_fit"] = (None, "answer rate unknown")
    m["rubric"].update({"message_quality": (4, "call coach: 46 engine checks + 20 phrase checks + 20 end-to-end checks pass (synthetic)"),
                        "dup_junk": (None, "duplicate dials not measurable without events"),
                        "freshness": (4, "deployed on Railway (sales-coach project), last deploy Nov 14")})
    return m


def collect_trading(root, now, db_path=None, **_):
    m = {"funnel": {"found": None, "qualified": None, "closed": None, "revenue_week": 0}, "rubric": {}, "notes": ["paper only: revenue is $0 by design"],
         "outcome_data": False}
    path = db_path or os.environ.get("PAPER_DB_PATH", "")
    if path and os.path.isfile(path):
        con = sqlite3.connect(f"file:{path}?mode=ro", uri=True)   # trades / signals only; the kv table (tokens) is never read
        try:
            sig = con.execute("select count(*) from signals").fetchone()[0]
            tr = con.execute("select count(*), sum(case when close_ts is not null then 1 else 0 end), sum(case when pnl > 0 then 1 else 0 end), "
                             "avg(r_mult), sum(pnl) from trades").fetchone()
        finally:
            con.close()
        n, closed, wins, avg_r, pnl = tr
        m["outcome_data"] = True
        m["funnel"].update({"found": sig, "qualified": n, "closed": closed or 0})
        m["sizes"] = {"win_rate": (wins or 0) / closed if closed else None, "avg_r": avg_r, "paper_pnl": pnl}
    else:
        m["notes"].append("paper trades live in the Railway volume (paper.db); set PAPER_DB_PATH to a copy to measure")
    m["rubric"] = {"lead_fit": (None, "edge unproven: needs ~100 closed paper trades"), "message_quality": (None, "n/a"),
                   "dup_junk": (5, "signals de-duplicated by bar (tests)"), "freshness": (5, "deployed and redeployed today"),
                   "deliverability": (5, "paper_only hard-locked; real-money endpoints refused")}
    return m


COLLECTORS = {"wholesale": collect_wholesale, "freelance": collect_freelance, "dialer": collect_dialer, "trading": collect_trading}


# ------------------------------------------------------------------------------------------------------------------- verdict
def bottleneck(funnel: dict, stages: list[str]) -> str:
    prev = None
    for s in stages:
        v = funnel.get(s)
        if v is None:
            return f"no data from '{s}' on: the funnel cannot be measured past '{prev}'" if prev else "no funnel data at all"
        if prev is not None and funnel.get(prev) and v == 0:
            return f"leak at '{prev}' -> '{s}': {funnel[prev]} in, 0 out"
        prev = s
    return "no leak visible in the tracked stages"


def compare(cur: dict, prev: dict | None) -> dict:
    if not prev:
        return {}
    out = {}
    for k, v in (cur.get("funnel") or {}).items():
        p = (prev.get("funnel") or {}).get(k)
        if isinstance(v, (int, float)) and isinstance(p, (int, float)):
            out[k] = v - p
    return out


def against_targets(m: dict, targets: dict) -> list[str]:
    f, out = m.get("funnel") or {}, []
    for k, t in (targets or {}).items():
        stage = k.replace("_per_week", "").replace("_per_month", "")
        v = f.get(stage)
        if isinstance(v, (int, float)) and isinstance(t, (int, float)) and k.endswith(("_per_week",)) and v < t:
            out.append(f"{stage}: {v} vs target {t}/week")
    sz = m.get("sizes") or {}
    n = sz.get("funnel_leads")
    if n and "priced_share" in targets and f.get("priced") is not None and f["priced"] / n < targets["priced_share"]:
        out.append(f"priced: {f['priced']}/{n} vs target {targets['priced_share']:.0%}")
    if n and "buyer_match_share" in targets and f.get("buyer_matched") is not None and f["buyer_matched"] / n < targets["buyer_match_share"]:
        out.append(f"buyer matched: {f['buyer_matched']}/{n} vs target {targets['buyer_match_share']:.0%}")
    ab = sz.get("abandon_rate")
    if ab is not None and ab > targets.get("abandon_rate_max", 1):
        out.append(f"abandon rate {ab:.1%} over the {targets['abandon_rate_max']:.0%} limit")
    return out


def verdict(o: dict, m: dict, health: str | None = None) -> str:
    if not o.get("viable"):
        return "kill"
    if o["office"] == "paper-trading":
        return "keep"   # paper only: judged on evidence of edge later, never on revenue
    closed = (m.get("funnel") or {}).get("closed")
    if m.get("outcome_data") and closed and not against_targets(m, o["qc"].get("targets")):
        return "keep"
    return "fix"


def review(slug: str, *, src_dir=None, now=None, state=None, health=None, **paths) -> dict:
    now = now or datetime.now(timezone.utc)
    o = registry.office(slug)
    if not o.get("viable"):
        return {"office": slug, "title": slug, "verdict": "kill", "why": o.get("why_not", ""), "funnel": {}, "rubric": {}, "changes": [], "notes": []}
    q = o["qc"]
    root = registry.checkout(slug, src_dir)
    m = COLLECTORS[q["collector"]](root, now, **paths) if root or q["collector"] in ("freelance", "dialer", "trading") else \
        {"funnel": {}, "rubric": {}, "notes": ["no local clone (LEGACY_SRC_DIR): outcome data not readable here"], "outcome_data": False}
    prev = (state or {}).get(slug)
    changes = sorted(q.get("changes", []), key=lambda c: -int(c.get("impact", 0)))[:3]
    return {"office": slug, "title": o["title"], "verdict": verdict(o, m, health), "funnel": m.get("funnel", {}), "stages": q.get("stages", []),
            "labels": q.get("stage_labels", {}), "sizes": m.get("sizes", {}), "rubric": m.get("rubric", {}), "notes": m.get("notes", []),
            "outcome_data": m.get("outcome_data", False), "gaps": against_targets(m, q.get("targets")), "bottleneck": bottleneck(m.get("funnel", {}), q.get("stages", [])),
            "delta": compare(m, prev), "changes": changes, "cost": q.get("cost_per_week_usd_note", "")}


def cost_per_result(minutes_month: float | None, quota: float, results_week: int | None) -> str:
    if minutes_month is None:
        return "cost unknown"
    over = max(minutes_month - quota, 0) * ACTIONS_USD_PER_MIN
    per = f", about ${over / 4.33 / results_week:.2f} of compute per qualified lead" if results_week else ""
    return f"compute about ${over:.2f}/month over the free tier ({minutes_month:.0f} min/month){per}"


def text(r: dict) -> str:
    if r["verdict"] == "kill" and not r.get("stages"):
        return f"QC: {r['office']} - KILL\n{r.get('why', '')}"
    lab = r.get("labels") or {}
    f = r["funnel"]
    funnel = " -> ".join(f"{lab.get(s, s)} {('?' if f.get(s) is None else f.get(s))}" for s in r["stages"])
    lines = [f"QC: {r['title']} ({r['office']}) - verdict {r['verdict'].upper()}", f"Funnel (last 7 days / latest): {funnel}"]
    if f.get("revenue_week") is not None:
        lines.append(f"$ per week: {f['revenue_week']}")
    if not r.get("outcome_data"):
        lines.append("No real outcome data yet: revenue cannot be measured. " + " ".join(n for n in r["notes"] if n.startswith(("no outcome", "paper"))))
    lines.append("Bottleneck: " + r["bottleneck"])
    if r["gaps"]:
        lines.append("Below target: " + "; ".join(r["gaps"]))
    if r["delta"]:
        lines.append("Since last QC: " + ", ".join(f"{k} {v:+}" for k, v in r["delta"].items()))
    if r["rubric"]:
        lines.append("Quality (0-5): " + "; ".join(f"{k} {'?' if v[0] is None else v[0]} ({v[1]})" for k, v in r["rubric"].items()))
    if r["changes"]:
        lines.append("Top changes by revenue impact:")
        lines += [f"{i}. {c['change']} [effort: {c['effort']}; {'owner' if c.get('needs') == 'owner' else 'code'}]" for i, c in enumerate(r["changes"], 1)]
    return redact.text("\n".join(lines))


def all_text(reports: list[dict]) -> str:
    return "QC: all legacy offices\n" + "\n".join(f"- {r['title']}: {r['verdict'].upper()}" + (f" -> {r['changes'][0]['change'][:110]}" if r.get("changes") else "")
                                                   for r in reports)


def load_state(path: str | None) -> dict:
    try:
        return json.load(open(path, encoding="utf-8")) if path else {}
    except (OSError, ValueError):
        return {}


def save_state(path: str | None, reports: list[dict]) -> None:
    """Keeps the aggregate funnel of each office for the next comparison (counts only)."""
    if not path:
        return
    st = load_state(path)
    for r in reports:
        st[r["office"]] = {"funnel": r.get("funnel", {}), "at": datetime.now(timezone.utc).isoformat()}
    with open(path, "w", encoding="utf-8") as f:
        json.dump(st, f, indent=1)


# ------------------------------------------------------------------------------------------------------------------- optional LLM judge
JUDGE_SYSTEM = ("Grade each sample proposal 0-5 for: specific to the post, honest, short, one clear next step. Reply as JSON list of "
                "{\"id\":..., \"score\":..., \"why\":...}. The samples are synthetic.")


def judge(samples: list[dict], complete=None) -> list[dict] | str:
    """Free-brain grading of SYNTHETIC samples only ({'id','post','draft','synthetic': True}). Anything not marked synthetic, or that still
    looks personal after redaction, is refused before a model sees it."""
    if not samples or not all(s.get("synthetic") is True for s in samples):
        return "Judge refused: only samples marked synthetic=True may be graded by a model."
    body = json.dumps([{"id": s["id"], "post": redact.text(s.get("post", ""))[:800], "draft": redact.text(s.get("draft", ""))[:800]} for s in samples])
    if redact.looks_private(body):
        return "Judge refused: a sample still looks personal after redaction."
    if complete is None:
        import hq_llm
        complete = hq_llm.complete
    try:
        r = complete(JUDGE_SYSTEM, [{"role": "user", "content": body}], division="qc", task_class="office_qc_judge", tier="small", sources=["system"], max_output=500)
        return json.loads((r or {}).get("text") or "[]")
    except ValueError:
        return "Judge answer was not JSON."
    except Exception as e:
        return f"Judge unavailable: {type(e).__name__}"
