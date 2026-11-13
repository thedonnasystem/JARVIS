"""Deals, reply tracking, do-not-contact, funnel and per-venture config (client for migrations/20261115_venture_deals_replies_v1.sql).

Nothing here sends anything. Every state change is an OWNER action (the database also refuses a non-owner actor), revenue is written
only by confirm_deal_won with an amount the owner typed, and an opt-out ('unsubscribe') is applied to every venture sharing the address.
Money-spending controls (caps, kill switch, capital) are not touched or imported here.
"""

from __future__ import annotations

import logging
import re
import urllib.error
import urllib.parse

import hq
import hq_mail
import hq_ventures

logger = logging.getLogger(__name__)

REPLY_KINDS = ("interested", "not_interested", "question", "unsubscribe", "booked")
# Canonical pipeline: 'pitched' is the table default; won-like names are what venture_kpis already counted. 'won' is reachable only via deal_won.
MOVE_STAGES = ("pitched", "negotiating", "lost")
CONFIG_KEYS = {"offer": "offer", "cta": "call_to_action", "call_to_action": "call_to_action", "sla": "reply_sla_hours", "reply_sla_hours": "reply_sla_hours"}
FUNNEL_ORDER = ("new", "drafted", "approved_to_send", "sent", "replied", "booked", "won", "lost", "do_not_contact", "other")
OWNER = "owner:telegram"
MAX_CENTS = 10_000_000  # CAD $100,000, same cap as create_deal / confirm_deal_won


def _q(v) -> str:
    return urllib.parse.quote(str(v), safe="")


def _get(path: str) -> list:
    return hq._request("GET", "/rest/v1/" + path) or []


def _rpc(name: str, args: dict):
    return hq._request("POST", f"/rest/v1/rpc/{name}", args)


def _d(cents) -> str:
    return f"${int(cents or 0) / 100:,.2f}"


def _parse_cents(text: str) -> int | None:
    m = re.fullmatch(r"\$?\s*([0-9][0-9,]*(?:\.[0-9]{1,2})?)", (text or "").strip())
    if not m:
        return None
    c = round(float(m.group(1).replace(",", "")) * 100)
    return c if 0 < c <= MAX_CENTS else None


def find_lead(ref: str) -> dict | None:
    """'#12' or '12' (the short id shown by /lead and /done) -> {id, venture_id, name, email, do_not_contact}."""
    ref = (ref or "").strip().lstrip("#")
    if not ref.isdigit():
        return None
    rows = _get(f"leads?short_id=eq.{int(ref)}&select=id,venture_id,name,email,do_not_contact,status&limit=1")
    return rows[0] if rows else None


def record_reply(ref: str, kind: str, note: str = "", by: str = OWNER) -> str:
    """/reply <lead#> <kind> [note]. 'unsubscribe' marks the lead and every other lead/draft on that address do-not-contact at once."""
    kind = (kind or "").lower().replace("-", "_")
    if kind not in REPLY_KINDS:
        return f"Reply kind must be one of: {', '.join(REPLY_KINDS)}."
    lead = find_lead(ref)
    if not lead:
        return f"No lead {ref}. Use the lead number (for example 12 or #12)."
    try:
        r = _rpc("record_lead_reply", {"p_lead": lead["id"], "p_kind": kind, "p_note": (note or "")[:500], "p_by": by})
    except Exception as e:
        return hq_ventures._err(e) or "Could not record the reply (migration pending?)."
    r = r if isinstance(r, dict) else {}
    name = lead.get("name") or "lead"
    if kind == "unsubscribe":
        return (f"#{ref.lstrip('#')} {name} is now do-not-contact. {r.get('leads_marked', 1)} lead(s) sharing the address marked across all ventures; "
                f"{r.get('drafts_rejected', 0)} open draft(s) rejected. Nothing more will be drafted or sent to them.")
    if r.get("unchanged"):
        return f"Reply recorded for #{ref.lstrip('#')} {name}. Status stays {r.get('status')} (a reply never lifts do-not-contact or demotes a win)."
    return f"Reply recorded for #{ref.lstrip('#')} {name}: {kind}. Lead status: {r.get('status')}."


def _find_deal(prefix: str) -> tuple[dict | None, str | None]:
    p = (prefix or "").strip().lower()
    if not re.fullmatch(r"[0-9a-f]{6,36}", p):
        return None, "Use the deal code from /deal list (first 8 characters)."
    hits = [d for d in _get("deals?select=id,venture_id,lead_id,stage,value_cents&order=created_at.desc&limit=500") if d["id"].startswith(p)]
    if len(hits) != 1:
        return None, "No deal with that code." if not hits else "That code matches more than one deal; use more characters."
    return hits[0], None


def deal_new(ref: str, value_text: str = "", note: str = "", by: str = OWNER) -> str:
    lead = find_lead(ref)
    if not lead:
        return f"No lead {ref}."
    cents = None
    if (value_text or "").strip():
        cents = _parse_cents(value_text)
        if cents is None:
            return "Deal value must look like 1500 or 1,250.50 (CAD), at most $100,000."
    try:
        d = _rpc("create_deal", {"p_lead": lead["id"], "p_value_cents": cents, "p_by": by, "p_note": (note or "")[:500] or None})
    except Exception as e:
        return hq_ventures._err(e) or "Could not open the deal."
    return f"Deal {str(d)[:8]} opened at pitched for {lead.get('name') or 'lead'}" + (f", value {_d(cents)}." if cents else ".")


def deal_move(prefix: str, stage: str, note: str = "", by: str = OWNER) -> str:
    stage = (stage or "").lower()
    if stage == "won":
        return "A win is confirmed with an amount: /deal won <code> <amount> received|expected. That is the only thing that records revenue."
    if stage not in MOVE_STAGES:
        return f"Stage must be one of: {', '.join(MOVE_STAGES)} (won goes through /deal won)."
    d, err = _find_deal(prefix)
    if err:
        return err
    try:
        _rpc("set_deal_stage", {"p_deal": d["id"], "p_stage": stage, "p_by": by, "p_note": (note or "")[:300] or None})
    except Exception as e:
        return hq_ventures._err(e) or "Stage change refused."
    return f"Deal {d['id'][:8]}: {d['stage']} -> {stage}."


def deal_won(prefix: str, amount_text: str, ledger_status: str, note: str = "", by: str = OWNER) -> str:
    """The owner confirms a win and the amount. Nothing is inferred; the ledger row exists only because of this call."""
    cents = _parse_cents(amount_text)
    if cents is None:
        return "Give the amount (positive, at most $100,000): /deal won <code> <amount> received|expected [note]"
    if (ledger_status or "").lower() not in ("received", "expected"):
        return "Say whether the money is received or expected: /deal won <code> <amount> received|expected [note]"
    d, err = _find_deal(prefix)
    if err:
        return err
    try:
        _rpc("confirm_deal_won", {"p_deal": d["id"], "p_amount_cents": cents, "p_ledger_status": ledger_status.lower(), "p_by": by,
                                  "p_note": (note or "")[:200] or None})
    except Exception as e:
        return hq_ventures._err(e) or "Could not confirm the win."
    return f"Deal {d['id'][:8]} won. Revenue {_d(cents)} CAD recorded as {ledger_status.lower()}."


def deals_text(slug: str | None = None, limit: int = 15) -> str:
    q = "deals?select=id,venture_id,stage,value_cents,updated_at&order=updated_at.desc&limit=%d" % int(limit)
    vid = None
    if slug:
        v = _get(f"ventures?slug=eq.{_q(slug)}&select=id&limit=1")
        if not v:
            return f"No venture '{slug}'."
        vid = v[0]["id"]
        q += f"&venture_id=eq.{_q(vid)}"
    rows = _get(q)
    if not rows:
        return "No deals yet. /deal new <lead#> [value] opens one."
    names = {v["id"]: v["slug"] for v in _get("ventures?select=id,slug&limit=500")}
    return "Deals:\n" + "\n".join(f"- {r['id'][:8]} {names.get(r.get('venture_id'), '?')} [{r['stage']}] {_d(r.get('value_cents')) if r.get('value_cents') else 'no value'}" for r in rows)


def funnel_lines(counts: dict) -> str:
    return " > ".join(f"{k} {int((counts or {}).get(k, 0))}" for k in FUNNEL_ORDER if k != "other" or (counts or {}).get("other"))


def funnel_text(slug: str) -> str:
    try:
        f = _rpc("lead_funnel", {"p_venture": re.sub(r"[^a-z0-9-]", "", (slug or "").lower())})
    except Exception:
        return "Lead funnel is not installed yet (migration pending)."
    if not isinstance(f, dict):
        return f"No venture '{slug}'."
    lines = [f"{f['venture']} lead funnel ({f['total']} leads):", funnel_lines(f.get("counts") or {})]
    rk = f.get("replies_by_kind") or {}
    lines.append("Replies recorded: " + (", ".join(f"{k} {n}" for k, n in sorted(rk.items())) if rk else "none"))
    lines.append(f"Replies waiting longer than the {f['reply_sla_hours']}h reply SLA: {f['replies_over_sla']}")
    return "\n".join(lines)


def config_text(slug: str) -> str:
    try:
        c = _rpc("venture_config_get", {"p_venture": re.sub(r"[^a-z0-9-]", "", (slug or "").lower())})
    except Exception:
        return "Venture config is not installed yet (migration pending)."
    if not isinstance(c, dict):
        return f"No venture '{slug}'."
    ready = c.get("drafts_ready")
    return "\n".join([
        f"{c['venture']} operating config:",
        f"Offer: {c.get('offer') or 'NOT SET'}",
        f"Call to action: {c.get('call_to_action') or 'NOT SET'}",
        f"Reply SLA: {c.get('reply_sla_hours')}h" + (" (default)" if c.get("reply_sla_is_default") else ""),
        f"Prospecting brief: {'set' if c.get('prospecting_brief_set') else 'NOT SET (prospecting stays off)'}",
        "Drafts can be approved: " + ("yes" if ready else "NO until both offer and call to action are set"),
        "Change: /venture config <venture> offer|cta|sla|brief <value>   ('clear' removes offer/cta/sla)"])


def set_config(slug: str, key: str, value: str, by: str = OWNER) -> str:
    key = (key or "").lower()
    value = (value or "").strip()
    if key == "brief":  # the prospecting brief keeps living in venture_procedures, which queue_prospect_task already reads
        return hq_ventures.save_procedure(slug, "prospecting brief", value, by=by)
    col = CONFIG_KEYS.get(key)
    if not col:
        return "Config key must be offer, cta, sla or brief."
    if not value:
        return "Give a value, or the word clear to remove it."
    try:
        _rpc("set_venture_config", {"p_venture": re.sub(r"[^a-z0-9-]", "", (slug or "").lower()), "p_key": col,
                                    "p_value": "" if value.lower() == "clear" else value, "p_by": by})
    except Exception as e:
        return hq_ventures._err(e) or "Could not save the config."
    return "Saved.\n" + config_text(slug)


def dnc_problem(outbox_id: str) -> str | None:
    """Why this draft must not be approved because of an opt-out, or None. Fails closed: if it cannot be verified it is NOT approved.
    A missing migration (HTTP 404 on the new table) is the only thing treated as 'not applicable'; the database trigger is the backstop."""
    ob = (_get(f"outbox?id=eq.{_q(outbox_id)}&select=lead_id,to_ref,channel&limit=1") or [{}])[0]
    if ob.get("lead_id"):
        lead = (_get(f"leads?id=eq.{_q(ob['lead_id'])}&select=do_not_contact&limit=1") or [{}])[0]
        if lead.get("do_not_contact"):
            return "Cannot approve: this lead is do-not-contact (opted out). The draft stays unsent."
    raw = (ob.get("to_ref") or "").strip()
    to = hq_mail.normalize_addr(raw)
    if raw and ob.get("channel", "email") == "email" and to is None:
        return "Cannot approve: the recipient is not one clean email address (a list or unreadable). Fix the draft's address first."
    try:
        if to and ob.get("channel", "email") == "email" and _get(f"contact_suppressions?address=eq.{_q(to)}&select=address&limit=1"):
            return "Cannot approve: that address opted out (do-not-contact in another venture or lead). The draft stays unsent."
    except urllib.error.HTTPError as e:
        if e.code != 404:
            return "Cannot approve: could not check the do-not-contact list. Try again."
    except Exception:
        return "Cannot approve: could not check the do-not-contact list. Try again."
    return None


def config_problem(slug: str | None) -> str | None:
    """Fail closed: a venture other than donna needs an offer AND a call to action on file before a draft for it can be approved."""
    if not slug or slug == "donna":
        return None
    try:
        c = _rpc("venture_config_get", {"p_venture": slug})
    except urllib.error.HTTPError as e:
        return None if e.code == 404 else "Cannot approve: could not read the venture config. Try again."
    except Exception:
        return "Cannot approve: could not read the venture config. Try again."
    if not isinstance(c, dict) or not c.get("drafts_ready"):
        return (f"Cannot approve yet: {slug} has no offer and call to action on file. Set them with /venture config {slug} offer <text> "
                f"and /venture config {slug} cta <text>, then tap Approve again.")
    return None
