"""Client invoicing for an office (FENDEZY GROUP Phase 1, M7; first user: Donna). Drafts Stripe invoices and payment links; sends an invoice only after the
owner's per-invoice decision. OFF unless FZ_STRIPE_INVOICING=1.

Gates, in this order, on EVERY call that touches Stripe:
  1. FZ_STRIPE_INVOICING=1, else nothing is called at all (no Stripe request, no database call);
  2. STRIPE_SECRET_KEY: a test key (sk_test_ / rk_test_) works; a live key (sk_live_ / rk_live_) only when the owner set FZ_STRIPE_LIVE=1 in Railway
     (the bot cannot set environment variables); anything else is refused;
  3. the office is ACTIVE and in sync (office_os_status), and the database re-checks it (plus 'stripe' among the office's allowed integrations);
  4. sending: only an invoice the owner approved with office_os_invoice_decide (signed-in owner, amount echoed; the service key cannot write that decision),
     claimed once (office_os_invoice_claim_send), re-checked against Stripe (amount, currency, still a draft, same mode) right before finalize + send.
Drafting is free: a draft is not sent. A payment link is created and recorded but NEVER sent by the bot: the owner shares it himself.
Incoming money is revenue only. This module has no refund, payout, transfer, credit-note or balance call, and none may be added (test_hq_invoices checks).
Every invoice is recorded against its office (fz_office_os.fz_office_invoices) and audit-logged by the database functions. No new money path: nothing here
writes the ledger, reserves spend or changes a cap.
"""
from __future__ import annotations

import base64
import logging
import os
import re

import hq
import hq_office_os

logger = logging.getLogger(__name__)
FLAG, KEY, LIVE, FULL_KEY = "FZ_STRIPE_INVOICING", "STRIPE_SECRET_KEY", "FZ_STRIPE_LIVE", "FZ_STRIPE_ALLOW_FULL_KEY"
API = "https://api.stripe.com"
_CUS = re.compile(r"^cus_[A-Za-z0-9]{6,64}$")
_INV = re.compile(r"^in_[A-Za-z0-9]{6,64}$")
_UUID = re.compile(r"^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$")
ALLOWED_CALLS = (("POST", "/v1/invoices"), ("POST", "/v1/invoiceitems"), ("DELETE", "/v1/invoices/"), ("GET", "/v1/invoices/"), ("GET", "/v1/invoices?customer="),
                 ("POST", "/v1/invoices/{id}/finalize"), ("POST", "/v1/invoices/{id}/send"), ("POST", "/v1/prices"), ("POST", "/v1/payment_links"))


class InvoiceError(Exception):
    pass


def _env(env=None) -> dict:
    return os.environ if env is None else env


def mode(env=None) -> str:
    """'test' or 'live', or raises InvoiceError. Never returns or logs the key."""
    e = _env(env)
    if e.get(FLAG) != "1":
        raise InvoiceError("invoicing is off (FZ_STRIPE_INVOICING is not 1)")
    k = str(e.get(KEY) or "")
    if k.startswith(("sk_test_", "rk_test_")):
        return "test"
    if k.startswith(("sk_live_", "rk_live_")):
        if e.get(LIVE) != "1":
            raise InvoiceError("live Stripe key refused: the owner has not set FZ_STRIPE_LIVE=1")
        if k.startswith("sk_live_") and e.get(FULL_KEY) != "1":
            raise InvoiceError("full live secret key refused: use a restricted key (rk_live_) with only invoice, price and payment-link rights")
        return "live"
    raise InvoiceError("STRIPE_SECRET_KEY missing or not a Stripe secret key")


def _stripe(method: str, path: str, form: dict | None = None, env=None, http=None, idem: str | None = None) -> dict:
    if not any(method == m and (path == p or (p.endswith("/") and path.startswith(p) and "/" not in path[len(p):]) or
                                (p.endswith("=") and re.fullmatch(re.escape(p) + r"cus_[A-Za-z0-9]{6,64}&limit=\d{1,3}", path)) or
                                (("{id}" in p) and re.fullmatch(re.escape(p).replace(r"\{id\}", r"in_[A-Za-z0-9]+"), path)))
               for m, p in ALLOWED_CALLS):
        raise InvoiceError(f"Stripe call not allowed: {method} {path}")
    if http:
        return http(method, path, form or {}, idem)
    # the existing official-API transport (hq_hands_adapters.http: HTTPS only, ONE no-redirect opener, so the key never follows a redirect); no new outbound route
    import hq_hands_adapters
    auth = {"Authorization": "Basic " + base64.b64encode((str(_env(env).get(KEY)) + ":").encode()).decode()}
    if idem:
        auth["Idempotency-Key"] = idem[:255]            # Stripe returns the first result for a repeated key: a retry can never create or send twice
    try:
        status, body, _ = hq_hands_adapters.http(method, API + path, headers=auth, form=(form or {}) if method == "POST" else None, timeout=20)
    except hq_hands_adapters.HandError as e:
        raise InvoiceError(f"Stripe unreachable ({str(e)[:80]})") from None
    if not 200 <= int(status) < 300 or not isinstance(body, dict):
        raise InvoiceError(f"Stripe refused the call (HTTP {status})")
    return body


def _rpc(name: str, args: dict, rpc=None):
    return (rpc or hq._request)("POST", f"/rest/v1/rpc/{name}", args)


def _office(office: str, rpc=None) -> str:
    slug = hq_office_os.resolve(office)
    if not slug:
        raise InvoiceError(f"unknown office {office!r}")
    ok, why = hq_office_os._active(slug, rpc)
    if not ok:
        raise InvoiceError(why)
    return slug


def _amount(cents, currency) -> tuple[int, str]:
    try:
        c = int(cents)
    except (TypeError, ValueError):
        raise InvoiceError("amount must be whole cents") from None
    cur = str(currency or "").lower()
    if not 0 < c <= 10000000 or not re.fullmatch(r"[a-z]{3}", cur):
        raise InvoiceError("amount must be 1..10,000,000 cents and currency a 3-letter code")
    return c, cur


def draft_invoice(office: str, customer_id: str, cents: int, currency: str, description: str, days_until_due: int = 14, env=None, http=None, rpc=None) -> dict:
    """A DRAFT Stripe invoice (not finalized, not sent), recorded against the office. The customer is an existing Stripe customer id (no client details here)."""
    m = mode(env)
    slug = _office(office, rpc)
    c, cur = _amount(cents, currency)
    if not _CUS.fullmatch(str(customer_id or "")):
        raise InvoiceError("customer must be a Stripe customer id (cus_...)")
    desc = re.sub(r"[\x00-\x1f]+", " ", str(description or ""))[:300]
    inv = _stripe("POST", "/v1/invoices", {"customer": customer_id, "collection_method": "send_invoice", "days_until_due": max(1, min(int(days_until_due), 60)),
                                           "auto_advance": "false", "description": desc}, env, http)
    iid = str(inv.get("id") or "")
    if not _INV.fullmatch(iid):
        raise InvoiceError("Stripe returned no invoice id")
    _stripe("POST", "/v1/invoiceitems", {"customer": customer_id, "invoice": iid, "amount": c, "currency": cur, "description": desc}, env, http)
    try:
        r = _rpc("office_os_invoice_record", {"p_office": slug, "p_kind": "invoice", "p_customer": customer_id, "p_stripe_id": iid, "p_mode": m, "p_cents": c, "p_currency": cur, "p_description": desc}, rpc)
    except Exception as e:
        _stripe("DELETE", "/v1/invoices/" + iid, None, env, http)          # an unrecorded draft is deleted (a draft has no money on it)
        raise InvoiceError(f"not recorded, draft deleted ({type(e).__name__})") from None
    return {"ok": True, "invoice": r.get("invoice"), "stripe_id": iid, "mode": m, "status": "draft"}


def draft_payment_link(office: str, cents: int, currency: str, name: str, env=None, http=None, rpc=None) -> dict:
    """A Stripe payment link, recorded against the office. The bot never sends it; the owner shares the URL himself."""
    m = mode(env)
    slug = _office(office, rpc)
    c, cur = _amount(cents, currency)
    nm = re.sub(r"[\x00-\x1f]+", " ", str(name or ""))[:120].strip() or "Service"
    price = _stripe("POST", "/v1/prices", {"currency": cur, "unit_amount": c, "product_data[name]": nm}, env, http)
    link = _stripe("POST", "/v1/payment_links", {"line_items[0][price]": str(price.get("id") or ""), "line_items[0][quantity]": 1}, env, http)
    lid = str(link.get("id") or "")
    r = _rpc("office_os_invoice_record", {"p_office": slug, "p_kind": "payment_link", "p_customer": None, "p_stripe_id": lid, "p_mode": m, "p_cents": c, "p_currency": cur, "p_description": nm}, rpc)
    return {"ok": True, "invoice": r.get("invoice"), "stripe_id": lid, "url": link.get("url"), "mode": m, "note": "the owner shares this link; the bot never sends it"}


def request_send(invoice: str, env=None, rpc=None) -> dict:
    """Ask the owner to approve sending ONE invoice (approval item in /approvals; he decides with office_os_invoice_decide)."""
    mode(env)
    if not _UUID.fullmatch(str(invoice or "")):
        raise InvoiceError("invoice id must be the HQ invoice uuid")
    return _rpc("office_os_invoice_request_send", {"p_invoice": invoice}, rpc)


def send(invoice: str, env=None, http=None, rpc=None) -> dict:
    """Finalize + send an invoice the owner approved. Claimed once in the database, re-checked against Stripe first; any failure is recorded."""
    m = mode(env)
    if not _UUID.fullmatch(str(invoice or "")):
        raise InvoiceError("invoice id must be the HQ invoice uuid")
    c = _rpc("office_os_invoice_claim_send", {"p_invoice": invoice}, rpc)       # raises unless the owner approved it and the office is active
    if not isinstance(c, dict) or not _INV.fullmatch(str(c.get("stripe_id") or "")):
        raise InvoiceError("claim unreadable")
    ok = False
    try:
        if c.get("mode") != m:
            raise InvoiceError(f"recorded in {c.get('mode')} mode, current key is {m}: not sent")
        sid = c["stripe_id"]
        cur = _stripe("GET", "/v1/invoices/" + sid, None, env, http)
        if cur.get("status") != "draft" or int(cur.get("amount_due") or -1) != int(c["cents"]) or str(cur.get("currency")) != c["currency"]:
            raise InvoiceError("the Stripe invoice no longer matches what the owner approved: not sent")
        if not c.get("customer") or str(cur.get("customer") or "") != c["customer"]:
            raise InvoiceError("the Stripe invoice's customer is not the approved customer: not sent")
        md = cur.get("metadata") or {}
        if c.get("plan") and (md.get("fz_plan") != str(c["plan"]) or md.get("fz_period") != str(c.get("period"))):
            raise InvoiceError("the Stripe invoice is not this plan's invoice for this period: not sent")
        base = f"fz-{c['plan']}-{c['period']}" if c.get("plan") and c.get("period") else f"fz-inv-{invoice}"
        _stripe("POST", f"/v1/invoices/{sid}/finalize", {"auto_advance": "false"}, env, http, idem=base + "-finalize")
        _stripe("POST", f"/v1/invoices/{sid}/send", {}, env, http, idem=base + "-send")
        ok = True
    finally:
        if not ok:
            logger.warning("invoice %s not sent (recorded as failed in the billing log)", invoice)
        _rpc("office_os_invoice_mark_sent", {"p_invoice": invoice, "p_ok": ok}, rpc)
    return {"ok": True, "invoice": invoice, "sent": True, "mode": m}


def invoices_text(rpc=None) -> str:
    """The owner's /invoices: read-only list (works with invoicing off)."""
    try:
        rows = _rpc("office_os_invoices", {"p_limit": 20}, rpc) or []
    except Exception:
        return "Invoices are not installed yet (migration 20261203_office_os_v1)."
    if not rows:
        return "No invoices yet. Drafts appear here; sending one needs your decision (office_os_invoice_decide)."
    out = []
    for r in rows:
        out.append(f"{r.get('status')}  {r.get('office')}  {r.get('kind')}  {r.get('customer') or '-'}  {int(r.get('cents') or 0) / 100:,.2f} {str(r.get('currency')).upper()}  {r.get('mode')}  "
                   f"{str(r.get('description') or '')[:40]}  id {r.get('id')}")
    out.append("\n/invoices request <id>  asks you to approve a send; decide in the SQL editor: office_os_invoice_decide('<id>', <cents>, true).  /invoices send <id>  sends an approved one.")
    return "\n".join(out)


# ---------------------------------------------------------------------------------------------------------------- billing plans (owner approves once)
INTERVALS = ("month", "year")


def propose_plan(office: str, client_label: str, customer_id: str, cents: int, currency: str, interval: str, env=None, rpc=None) -> dict:
    """Ask the owner to approve a recurring billing plan once (office_os_plan_decide echoes amount and interval). Nothing is sent by proposing."""
    mode(env)
    slug = _office(office, rpc)
    c, cur = _amount(cents, currency)
    if interval not in INTERVALS:
        raise InvoiceError("interval must be month or year")
    if not _CUS.fullmatch(str(customer_id or "")):
        raise InvoiceError("customer must be a Stripe customer id (cus_...)")
    label = re.sub(r"[^A-Za-z0-9 &.,'-]", "", str(client_label or ""))[:80].strip()
    return _rpc("office_os_plan_propose", {"p_office": slug, "p_client_label": label, "p_customer": customer_id, "p_cents": c, "p_currency": cur, "p_interval": interval}, rpc)


def period(interval: str, now=None) -> str:
    """The billing period the database uses (Toronto calendar): 'YYYY-MM' for month, 'YYYY' for year."""
    from datetime import datetime
    from zoneinfo import ZoneInfo
    n = (now or datetime.now(ZoneInfo("America/Toronto"))).astimezone(ZoneInfo("America/Toronto"))
    return n.strftime("%Y-%m") if interval == "month" else n.strftime("%Y")


def _existing_in_stripe(p: dict, per: str, env, http) -> str | None:
    """An invoice Stripe already holds for this (plan, period): never create a second one."""
    r = _stripe("GET", f"/v1/invoices?customer={p['customer']}&limit=50", None, env, http)
    for inv in (r.get("data") or []):
        md = inv.get("metadata") or {}
        if md.get("fz_plan") == str(p["id"]) and md.get("fz_period") == per and inv.get("status") not in ("void", "deleted"):
            return str(inv.get("id"))
    return None


GRACE_DAYS = 7


def check_plans(office: str, grace_days: int | None = None, env=None, http=None, rpc=None, now=None) -> dict:
    """Payment-failure stop: for each approved plan, look at its last SENT invoice in Stripe. Paid: logged (revenue only). Uncollectible, or still unpaid
    grace_days (default 7, FZ_BILLING_GRACE_DAYS) after its due date: the plan goes past_due (no more auto-sends; the owner is alerted once; only he resumes)."""
    import time
    m = mode(env)
    slug = _office(office, rpc)
    g = int(grace_days if grace_days is not None else (_env(env).get("FZ_BILLING_GRACE_DAYS") or GRACE_DAYS))
    t = now if now is not None else time.time()
    stopped, paid = [], []
    for p in (_rpc("office_os_plans", {}, rpc) or []):
        li = p.get("last_invoice") or {}
        if p.get("office") != slug or p.get("status") != "approved" or li.get("status") != "sent" or li.get("mode") != m or not _INV.fullmatch(str(li.get("stripe_id") or "")):
            continue
        inv = _stripe("GET", "/v1/invoices/" + li["stripe_id"], None, env, http)
        st, due = inv.get("status"), inv.get("due_date")
        if st == "paid":
            _rpc("office_os_invoice_observe", {"p_invoice": li["id"], "p_stripe_status": "paid"}, rpc)
            paid.append(p["id"])
        elif st == "uncollectible" or (st == "open" and due and t > float(due) + g * 86400):
            reason = "uncollectible" if st == "uncollectible" else f"unpaid {g}+ days after due"
            _rpc("office_os_invoice_observe", {"p_invoice": li["id"], "p_stripe_status": "uncollectible" if st == "uncollectible" else "overdue"}, rpc)
            _rpc("office_os_plan_past_due", {"p_plan": p["id"], "p_reason": reason}, rpc)
            stopped.append(p["id"])
    return {"ok": True, "past_due": stopped, "paid": paid}


def bill_plans(office: str, env=None, http=None, rpc=None) -> dict:
    """This period's invoice for every APPROVED plan of the office, for exactly the plan's amount and interval, then sent without another tap.
    The database refuses anything else (another amount or interval, a second invoice this period, a revoked plan, a dormant office)."""
    m = mode(env)
    slug = _office(office, rpc)
    check = check_plans(slug, env=env, http=http, rpc=rpc)                 # a failed payment stops its plan BEFORE the next period is billed
    plans = [p for p in (_rpc("office_os_plans", {}, rpc) or []) if p.get("office") == slug and p.get("status") == "approved" and p.get("id") not in check["past_due"]]
    done, refused = [], []
    for p in plans:
        iid = ""
        per = period(p["interval"])
        key = f"fz-{p['id']}-{per}"
        try:
            dup = _existing_in_stripe(p, per, env, http)
            if dup:
                raise InvoiceError(f"Stripe already holds {dup} for {per}: not created again")
            inv = _stripe("POST", "/v1/invoices", {"customer": p["customer"], "collection_method": "send_invoice", "days_until_due": 14, "auto_advance": "false",
                                                   "description": f"{p['client']} ({p['interval']}ly plan)", "metadata[fz_plan]": str(p["id"]),
                                                   "metadata[fz_period]": per}, env, http, idem=key + "-create")
            iid = str(inv.get("id") or "")
            if not _INV.fullmatch(iid):
                raise InvoiceError("Stripe returned no invoice id")
            _stripe("POST", "/v1/invoiceitems", {"customer": p["customer"], "invoice": iid, "amount": int(p["cents"]), "currency": p["currency"],
                                                 "description": f"{p['client']} {p['interval']}ly plan"}, env, http, idem=key + "-item")
            r = _rpc("office_os_invoice_record_plan", {"p_plan": p["id"], "p_customer": str(inv.get("customer") or ""), "p_stripe_id": iid, "p_mode": m, "p_cents": int(p["cents"]), "p_currency": p["currency"],
                                                         "p_interval": p["interval"]}, rpc)
        except Exception as e:
            if iid:
                try:
                    _stripe("DELETE", "/v1/invoices/" + iid, None, env, http)
                except InvoiceError:
                    pass
            refused.append({"plan": p.get("id"), "reason": str(e)[:160]})
            continue
        try:
            send(r["invoice"], env, http, rpc)
            done.append({"plan": p["id"], "invoice": r["invoice"], "period": r.get("period")})
        except Exception as e:
            refused.append({"plan": p.get("id"), "reason": str(e)[:160]})
    return {"ok": True, "sent": done, "refused": refused, "past_due": check["past_due"]}


def plans_text(rpc=None) -> str:
    try:
        rows = _rpc("office_os_plans", {}, rpc) or []
    except Exception:
        return "Billing plans are not installed yet."
    if not rows:
        return "No billing plans. Donna proposes one; you approve it once with office_os_plan_decide('<id>', <cents>, '<interval>', true)."
    return "\n".join(f"{r.get('status')}  {r.get('office')}  {r.get('client')}  {int(r.get('cents') or 0) / 100:,.2f} {str(r.get('currency')).upper()}/{r.get('interval')}  id {r.get('id')}"
                     for r in rows) + "\n\nRevoke one: office_os_plan_revoke('<id>'). /invoices bill donna sends this period's plan invoices."


def cancel_plan(plan: str, rpc=None) -> dict:
    """The owner's /invoices cancel <plan> (Telegram, owner chat only): immediate, no future period, never a refund, logged. It uses the safety-only
    office_os_plan_revoke (the service path may only stop a plan); office_os_plan_cancel is the same for the SQL editor."""
    if not _UUID.fullmatch(str(plan or "")):
        raise InvoiceError("plan id must be the HQ plan uuid")
    return _rpc("office_os_plan_revoke", {"p_plan": plan}, rpc)


def log_text(rpc=None) -> str:
    try:
        rows = _rpc("office_os_billing_log", {"p_limit": 30}, rpc) or []
    except Exception:
        return "Billing log not installed yet."
    if not rows:
        return "Billing log is empty."
    return "\n".join(f"{str(r.get('at'))[:16]}  {r.get('event')}  {r.get('office')}  by {r.get('by')}  plan {str(r.get('plan') or '-')[:8]}  invoice {str(r.get('invoice') or '-')[:8]}"
                     for r in rows)


_LAST_RUN: dict = {}


def run_due(env=None, now=None) -> dict:
    """Schedule entry (ops/proposals/billing_schedule.md): once a day in the 09:00 Toronto hour, check payments, then bill this period of every approved plan.
    Returns at once when invoicing is off. Never raises (the engine tick must not stop for billing)."""
    try:
        mode(env)
    except InvoiceError as e:
        return {"ran": False, "reason": str(e)}
    from datetime import datetime
    from zoneinfo import ZoneInfo
    n = (now or datetime.now(ZoneInfo("America/Toronto"))).astimezone(ZoneInfo("America/Toronto"))
    day = n.strftime("%Y-%m-%d")
    if n.hour != 9 or _LAST_RUN.get("day") == day:
        return {"ran": False, "reason": "not due"}
    _LAST_RUN["day"] = day
    out = {}
    try:
        offices = sorted({p.get("office") for p in (_rpc("office_os_plans", {}) or []) if p.get("status") == "approved"})
        for o in offices:
            try:
                out[o] = bill_plans(o, env)
            except Exception as e:
                out[o] = {"ok": False, "reason": str(e)[:160]}
    except Exception as e:
        logger.warning("billing run failed: %s", str(e)[:160])
        return {"ran": False, "reason": "plans unreadable"}
    return {"ran": True, "offices": out}

