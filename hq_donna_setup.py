"""/donna setup: every switch Donna's money loop needs, ticked live from the environment and the database. Read-only; values are never shown."""
from __future__ import annotations

import os

import hq_donna
from hq_donna_revenue import FLAG_AUTODRAFT, FLAG_INBOUND, PLACEHOLDER_ADDRESS, mailing_address, rev
def setup_text(env: dict | None = None, rpc=None, get=None) -> str:
    """One checklist of every switch the money loop needs, ticked from the live environment and database. Read-only; values are never shown."""
    env = os.environ if env is None else env
    rpc = rpc or hq_donna._rpc_default
    def has(k):
        return bool(env.get(k))
    rows = []
    def row(ok, what, fix):
        rows.append(("✅ " if ok else "❌ ") + what + ("" if ok else f": {fix}"))
    try:
        q = rpc("donna_revenue_queue", {"p_limit": 1}) or {}
        installed = True
    except Exception:
        q, installed = {}, False
    row(installed, "Revenue loop installed in the database", "the release (#62) is not applied yet")
    row(bool(q.get("active")), "Donna active", "activate the Donna office")
    addr = mailing_address(get)
    row(addr != PLACEHOLDER_ADDRESS, "Mailing address for emails (CASL)", "/setaddress donna <P.O. box>")
    row(has("RETELL_API_KEY"), "Retell key in Railway (calls in, client agents)", "copy RETELL_API_KEY from Netlify to Railway")
    row(has("NETLIFY_TOKEN") and has("NETLIFY_SITE_ID"), "Netlify access (website form in)", "NETLIFY_TOKEN + NETLIFY_SITE_ID in Railway")
    row(env.get(FLAG_INBOUND) == "1", "Inbound sync on", "DONNA_INBOUND=1")
    row(env.get(FLAG_AUTODRAFT) == "1", "Drafting on (replies, briefs, follow-ups, cold)", "DONNA_AUTODRAFT=1")
    row(env.get("DONNA_PROSPECTING") == "1", "Donna finds prospects daily", "DONNA_PROSPECTING=1")
    row(env.get("DONNA_CONTENT") == "1", "Weekly content jobs", "DONNA_CONTENT=1")
    row(env.get(rev().get("booking_url_env") or "DONNA_BOOKING_URL", "").startswith("https://"), "Booking link in replies", "DONNA_BOOKING_URL (Cal.com audit link)")
    import hq_donna_revenue as _R
    row(has("CALCOM_API_KEY") and any(_R._calcom_filter(env)), "Website calendar bookings come in (Cal.com)",
        "CALCOM_API_KEY (Cal.com Settings > Developer > API keys) + DONNA_BOOKING_URL = your cal.com audit link")
    row(has("RESEND_API_KEY") and has("MAIL_FROM"), "Email sender", "RESEND_API_KEY + MAIL_FROM on your domain")
    row(env.get("DONNA_REPLIES") == "1" and has("MAIL_REPLY_TO"), "Replies stop follow-ups, unsubscribes honoured",
        "MAIL_REPLY_TO = your receiving address (email provider, Receiving tab) + DONNA_REPLIES=1")
    stripe_key = str(env.get("STRIPE_SECRET_KEY") or "")
    row(env.get("FZ_STRIPE_INVOICING") == "1" and stripe_key.startswith(("sk_", "rk_")), "Payment links (/invoices link) (optional)",
        "FZ_STRIPE_INVOICING=1 + a restricted STRIPE_SECRET_KEY (rk_), or keep using Helcim")
    try:
        import hq
        st = (hq._request("GET", "/rest/v1/system_state?select=mode,kill_switch&limit=1") or [{}])[0]
        row(st.get("mode") == "auto_in_caps" and not st.get("kill_switch"), "Sending mode (auto within caps, kill switch off)",
            f"now {st.get('mode')}{' + kill switch' if st.get('kill_switch') else ''}; approve_first never sends an outbox email")
        gate = rpc("ffm_outreach_gate_open", {})
        row(bool(gate), "Outreach gate verified (suppression list)", "run the suppression-list verification (runbook)")
    except Exception:
        row(False, "Sending mode / outreach gate", "could not read them")
    done = sum(r.startswith("✅") for r in rows)
    return f"Donna money loop: {done}/{len(rows)} ready\n" + "\n".join(rows)
