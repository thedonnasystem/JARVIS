"""FF Marketing EXECUTION v1: after ONE owner approval per client launch, Jarvis runs the paid ads, posts the content, works the leads and reports, alone.

Owner flow (Telegram, owner only): /ffm sender (the client's CASL identity, once) -> /ffm launch <slug> <daily $> <total $> [days <= 30] [YYYY-MM-DD] -> one
message with Approve / Reject (numbers written by the database; /ffm plan <id> lists every ad, post and email) -> one tap, recorded ONLY through
ffm_run_owner_decide (message + single-use nonce, via hq_commands.apply_decision) -> Jarvis runs it. /ffm status | stop | budget | lead | plan | connectads.

Every tick (TICK_SECONDS, plain code, no model call):
  ads      Meta Marketing API: campaign (spend cap = the approved total) -> ad sets -> ads, all created PAUSED; the database approves each switch-on before it
           is made on Meta. Hourly numbers (a real campaign is always read from Meta, never simulated), daily optimizer (pause losers, shift budget). A new
           approved budget is applied on Meta first (spend cap, then ad-set cuts) before anything resumes. At the cap everything is paused.
  pause    cap / end / stop / kill switch: a REAL campaign is paused on Meta directly with the stored token whatever else is switched off; the books say paused
           only after Meta confirmed; a failure is retried every tick, also for launches that are already stopped or ended.
  content  posts on their calendar day and the landing page through the hands path (only the exact approved text / page hash).
  leads    Netlify form + Meta lead-form leads -> ffm_run_intake_lead (consent fields required, ws_guard) -> touch 1 at once, then the approved follow-ups.
           Emails are queued with the CLIENT's own sender profile and CASL footer and sent by send_emails() after ffm_run_claim_email re-checks everything
           at send time; the policy engine's send_email caps apply. Not the legacy outbox / Donna path. SMS: stub (SmsNotBuilt).
  report   Monday: owner brief ("sir") + client draft (never sent to the client).
A launch approved while the system is in dry-run mode runs SIMULATED to its end (receipts labelled DRY RUN); after going live, launch again.
Nothing here edits a money control, the kill switch, the mode, a cap, an executor, a permission or a privacy guard.
"""
from __future__ import annotations

import asyncio
import hashlib
import hmac
import json
import logging
import re
import urllib.parse
from datetime import date, datetime, timedelta

import hq
import hq_core
import hq_ffm_engine as E
import hq_hands_adapters as A

logger = logging.getLogger(__name__)
DIVISION = "ffm"
AGENT = "jarvis-hands"
EXECUTOR = "hands-actions"
TICK_SECONDS = 300
POST_HOUR, OPTIMIZE_HOUR, REPORT_HOUR = 10, 9, 8          # America/Toronto
MIN_SET_CENTS = 100                                       # Meta's smallest daily ad-set budget we use
LOSER_MIN_SPEND_CENTS = 1000                              # an ad is judged only after this much spend
PLATFORM_CONNECTOR = {"instagram": "meta-instagram", "facebook": "meta-facebook", "tiktok": "tiktok", "linkedin": "linkedin", "youtube": "youtube", "x": "x-twitter"}
TEXT_ONLY = frozenset({"facebook", "linkedin", "x"})       # the others need an image or video, which the pack does not have
CTA_CODES = {"Learn More": "LEARN_MORE", "Book Now": "BOOK_NOW", "Get Quote": "GET_QUOTE", "Contact Us": "CONTACT_US", "Sign Up": "SIGN_UP",
             "Call Now": "CALL_NOW", "Get Offer": "GET_OFFER", "Send Message": "SEND_MESSAGE"}
SPECIAL = {"mortgage": ["FINANCIAL_PRODUCTS_SERVICES"], "insurance": ["FINANCIAL_PRODUCTS_SERVICES"], "real_estate": ["HOUSING"]}   # Meta special ad categories
ADS_SCOPES = "ads_management,ads_read,leads_retrieval,pages_show_list,pages_read_engagement,pages_manage_ads,business_management"
SUBCOMMANDS = ("launch", "status", "stop", "budget", "lead", "plan", "sender", "autosend")
_UUID = re.compile(r"^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$")


class SmsNotBuilt(A.HandError):
    """STUB: there is no consent-checked SMS sender (the outbox 'text' channel is disabled until the owner enables it, and no SMS provider adapter exists).
    Every touch goes by email. To add SMS: a provider adapter in hq_hands_adapters + an outbox 'text' path that checks ffm_contact_status(lead, 'sms')."""


def _today(now: datetime) -> date:
    return now.astimezone(hq_core.TZ).date()


def money(cents) -> str:
    return f"${(int(cents or 0)) / 100:,.2f}"


def parse_money(s: str) -> int:
    v = float(str(s).replace("$", "").replace(",", "").strip())
    if v <= 0 or v > 100000:
        raise ValueError("amount out of range")
    return int(round(v * 100))


# ------------------------------------------------------------------------------------------------------------------- Meta Marketing API
class MetaAds:
    """Official Marketing API (Graph v21.0) on the owner-connected ad account. Every object is created PAUSED. The token goes in the Authorization header
    (never in a URL) together with appsecret_proof when META_APP_SECRET is set; it never leaves this object."""

    def __init__(self, token: str, account: str, call=A.http, app_secret: str | None = None):
        import os
        self._tok, self.call = A.Secret(token), call
        self.account = account if str(account).startswith("act_") else f"act_{account}"
        secret = app_secret if app_secret is not None else os.environ.get("META_APP_SECRET")
        self._proof = hmac.new(secret.encode(), token.encode(), hashlib.sha256).hexdigest() if secret else None

    def _auth(self) -> dict:
        return {"Authorization": "Bearer " + self._tok.reveal()}

    def _proofed(self, d: dict) -> dict:
        return {**d, "appsecret_proof": self._proof} if self._proof else dict(d)

    def _post(self, path: str, form: dict) -> dict:
        s, b, _ = self.call("POST", f"{A.GRAPH}/{path}", headers=self._auth(), form=self._proofed(form))
        if s != 200 or not isinstance(b, dict) or not (b.get("id") or b.get("success")):
            raise A._err("Meta Ads", s, b)
        return b

    def _get(self, path: str, params: dict) -> dict:
        s, b, _ = self.call("GET", f"{A.GRAPH}/{path}?" + urllib.parse.urlencode(self._proofed(params)), headers=self._auth())
        if s != 200 or not isinstance(b, dict):
            raise A._err("Meta Ads", s, b)
        return b

    def targeting(self, geo: str) -> dict:
        if geo:
            try:
                found = (self._get("search", {"type": "adgeolocation", "q": geo[:60], "location_types": json.dumps(["city"])}).get("data") or [])
                if found and found[0].get("key"):
                    return {"geo_locations": {"cities": [{"key": str(found[0]["key"]), "radius": 25, "distance_unit": "kilometer"}]}}
            except A.HandError:
                pass
        return {"geo_locations": {"countries": ["CA"]}}

    def campaign(self, name: str, cap_cents: int, special: list) -> str:
        return str(self._post(f"{self.account}/campaigns", {"name": name, "objective": "OUTCOME_TRAFFIC", "status": "PAUSED", "buying_type": "AUCTION",
                                                             "special_ad_categories": json.dumps(special), "spend_cap": str(int(cap_cents)),
                                                             "is_adset_budget_sharing_enabled": "false"})["id"])

    def set_spend_cap(self, campaign: str, cap_cents: int) -> None:
        self._post(campaign, {"spend_cap": str(int(cap_cents))})

    def lifetime_spend(self, campaign: str) -> int:
        rows = self._get(f"{campaign}/insights", {"fields": "spend", "date_preset": "maximum"}).get("data") or []
        return sum(int(round(float(r.get("spend") or 0) * 100)) for r in rows)

    def ad_set(self, campaign: str, name: str, daily_cents: int, start: str, end: str, targeting: dict) -> str:
        return str(self._post(f"{self.account}/adsets", {"name": name, "campaign_id": campaign, "daily_budget": str(int(daily_cents)), "billing_event": "IMPRESSIONS",
                                                          "optimization_goal": "LINK_CLICKS", "bid_strategy": "LOWEST_COST_WITHOUT_CAP", "targeting": json.dumps(targeting),
                                                          "start_time": start, "end_time": end, "status": "PAUSED"})["id"])

    def ad(self, ad_set: str, name: str, page_id: str, link: str, headline: str, body: str, cta: str) -> str:
        spec = {"page_id": page_id, "link_data": {"link": link, "message": body, "name": headline, "call_to_action": {"type": cta, "value": {"link": link}}}}
        cr = self._post(f"{self.account}/adcreatives", {"name": name, "object_story_spec": json.dumps(spec)})["id"]
        return str(self._post(f"{self.account}/ads", {"name": name, "adset_id": ad_set, "creative": json.dumps({"creative_id": cr}), "status": "PAUSED"})["id"])

    def set_status(self, obj: str, active: bool) -> None:
        self._post(obj, {"status": "ACTIVE" if active else "PAUSED"})

    def set_budget(self, ad_set: str, daily_cents: int) -> None:
        self._post(ad_set, {"daily_budget": str(int(daily_cents))})

    def insights(self, campaign: str, day: date, ads=None, fraction: float = 1.0) -> list[dict]:
        b = self._get(f"{campaign}/insights", {"level": "ad", "fields": "ad_id,spend,impressions,clicks,actions",
                                               "time_range": json.dumps({"since": day.isoformat(), "until": day.isoformat()}), "limit": "200"})
        out = []
        for r in b.get("data") or []:
            leads = sum(int(float(a.get("value") or 0)) for a in (r.get("actions") or []) if a.get("action_type") in ("lead", "onsite_conversion.lead_grouped", "offsite_conversion.fb_pixel_lead"))
            out.append({"ad_id": str(r.get("ad_id")), "spend_cents": int(round(float(r.get("spend") or 0) * 100)), "impressions": int(r.get("impressions") or 0),
                        "clicks": int(r.get("clicks") or 0), "leads": leads})
        return out

    def ad_leads(self, ad: str, since: datetime | None) -> list[dict]:
        """Meta lead-form leads of one ad (empty for website ads)."""
        params = {"fields": "id,created_time,field_data", "limit": "100"}
        if since:
            params["filtering"] = json.dumps([{"field": "time_created", "operator": "GREATER_THAN", "value": int(since.timestamp())}])
        return self._get(f"{ad}/leads", params).get("data") or []


class SimAds:
    """DRY RUN stand-in with the same interface: no network, ids 'sim:...', deterministic simulated delivery (spend follows the ad-set budgets and the hour
    of the day; an ad whose reference hashes to 0 mod 4 never converts, so the optimizer has a loser to find). Used ONLY for simulated objects."""
    simulated = True

    def __init__(self):
        self.n, self.calls = 0, []

    def _id(self, kind: str) -> str:
        self.n += 1
        return f"sim:{kind}:{self.n}"

    def targeting(self, geo):
        return {"geo_locations": {"countries": ["CA"]}}

    def campaign(self, name, cap_cents, special):
        self.calls.append(("campaign", cap_cents))
        return self._id("campaign")

    def set_spend_cap(self, campaign, cap_cents):
        self.calls.append(("spend_cap", campaign, cap_cents))

    def lifetime_spend(self, campaign):
        return 0

    def ad_set(self, campaign, name, daily_cents, start, end, targeting):
        self.calls.append(("ad_set", daily_cents))
        return self._id("adset")

    def ad(self, ad_set, name, page_id, link, headline, body, cta):
        self.calls.append(("ad", name))
        return self._id("ad")

    def set_status(self, obj, active):
        self.calls.append(("status", obj, active))

    def set_budget(self, ad_set, daily_cents):
        self.calls.append(("budget", ad_set, daily_cents))

    def insights(self, campaign, day, ads=None, fraction: float = 1.0):
        out = []
        for a in ads or []:
            if a.get("status") != "active":
                continue
            spend = int(a.get("share_cents", 0) * fraction)
            bad = int(hashlib.sha256(a["ref"].encode()).hexdigest(), 16) % 4 == 0
            out.append({"ad_id": a["external_id"], "spend_cents": spend, "impressions": spend * 4, "clicks": max(spend // 50, 0), "leads": 0 if bad else spend // 1500})
        return out

    def ad_leads(self, ad, since):
        return []


# ------------------------------------------------------------------------------------------------------------------- the plan the owner approves
def live_landing_html(full: dict, wording: str, version: str) -> str:
    """The pack's landing page made live: no draft banner, a Netlify form (same site; no external post, no script), a required consent checkbox with the
    client's exact wording, and the wording version the submission records. Deterministic (its sha256 is what the owner approves)."""
    import html as h
    full = json.loads(json.dumps(full))
    full["lead_form"]["consent_wording"] = wording
    page = E.render_landing_html(full)
    page = page.replace('<p class="draft">DRAFT for client review. Not published. The form is not connected.</p>\n', "")
    page = page.replace('<form onsubmit="return false">',
                        '<form name="lead" method="POST" data-netlify="true" netlify-honeypot="company"><input type="hidden" name="form-name" value="lead">'
                        f'<input type="hidden" name="wording_version" value="{h.escape(version, quote=True)}"><p hidden><label>Company<input name="company"></label></p>')
    page = page.replace('<p class="consent">', '<label class="consent"><input type="checkbox" name="consent" value="yes" required style="display:inline;width:auto"> ', 1)
    return page.replace('</p><button type="submit">', '</label><button type="submit">', 1)


def fill(text: str, ws: dict) -> str:
    """Template placeholders -> plain text. No lead data ever goes into a message body: the greeting stays generic."""
    t = str(text or "").replace("{{first_name}}", "there").replace("{{business_name}}", ws.get("name") or "our team")
    return re.sub(r"\{\{[^}]*\}\}", "", t).strip()


def build_plan(ws: dict, pack_row: dict, inputs: dict, consent_version: str | None) -> tuple[dict, str | None]:
    """-> (plan, landing html or None). Only copy that survived the pack's privacy screen; every string is screened again by ffm_run_propose."""
    pack = pack_row["pack"]
    ads = [{"ref": v["id"], "set": v["angle"], "headline": v["headline"], "body": v["primary_text"], "cta": CTA_CODES.get(v.get("cta"), "LEARN_MORE")}
           for v in pack.get("ad_variants", []) if len(v.get("headline") or "") >= 2 and len(v.get("primary_text") or "") >= 2]
    posts = [{"ref": f"P{p['day']}", "day": int(p["day"]), "platform": p["platform"], "text": p["caption"]}
             for p in pack.get("organic_calendar", []) if p.get("caption") and p.get("platform") in PLATFORM_CONNECTOR]
    touches = [{"touch": i + 1, "day": int(t.get("day", (0, 1, 3, 6, 10)[i])), "subject": fill(t.get("subject") or "", ws) or "Following up", "body": fill(t["body"], ws)}
               for i, t in enumerate([t for t in pack.get("follow_up", []) if t.get("body")][:5])]
    plan = {"ads": ads, "posts": posts, "touches": touches, "vertical": ws.get("vertical") or "generic", "landing": False}
    geo = ((pack.get("brief") or {}).get("service_area") or "").split(",")[0].strip()
    if geo:
        plan["geo"] = geo[:80]
    page = None
    wording = (inputs.get("consent_wording") or "").strip()
    if wording and consent_version:
        page = live_landing_html(E.expand(pack, ws["name"]), wording, consent_version)
        plan.update({"landing": True, "landing_sha256": hashlib.sha256(page.encode()).hexdigest(), "consent_version": consent_version})
    return plan, page


# ------------------------------------------------------------------------------------------------------------------- the engine
class NotLive(Exception):
    """The executor gate answered dry run for a live step: nothing was done; the step is retried."""


def resend_post(c: dict) -> tuple[bool, str | None]:
    """One email through the single provider call site (hq_mail), from the CLIENT's own address, with List-Unsubscribe."""
    import hq_mail
    ok = hq_mail.send_prepared(c["from"], c["from_name"], c["to"], c["subject"], c["body"], c["unsubscribe"], idempotency_key=f"ffm-email-{c['id']}")
    return ok, (None if ok else "provider refused or not configured")


class Engine:
    """One object per tick. Everything external is injectable (tests use fakes): rpc(name, args), get(path), http, token(vault_ref) -> dict,
    executor_run (hq_executor.run), send_owner(body, kind), authorize(email id) -> bool, mail_post(claim) -> (ok, ref), now."""

    def __init__(self, rpc=None, get=None, http=None, token=None, executor_run=None, send_owner=None, now=None, sim=None, authorize=None, mail_post=None, attest=None):
        import hq_executor
        self.rpc = rpc or E._rpc
        self.get = get or E._get
        self.http = http or A.http
        self.token = token or (lambda ref: __import__("hq_hands")._load_token(ref))
        self.executor_run = executor_run or hq_executor.run
        self.send_owner = send_owner or (lambda body, kind="brief": hq_core.send_owner(body, urgency="low", kind=kind, from_agent="jarvis"))
        self.authorize = authorize or (lambda ref: __import__("hq_policy").authorize(AGENT, "send_email", ref=ref).allowed)
        self._mail_injected = mail_post is not None
        self.attest = attest or (lambda: __import__("hq_gatemark").attest(force=True))
        self.mail_post = mail_post or resend_post
        self.now = now or datetime.now(hq_core.TZ)
        self.sim = sim or SimAds()
        self.log: list[str] = []

    # ---- database helpers
    def call(self, name, args):
        return E._call(name, args, self.rpc)

    def receipt(self, launch, step, item, simulated, ok, ref=None, detail=None, task=None) -> bool:
        if detail and simulated and not detail.startswith(("DRY RUN", "SKIPPED")):
            detail = "DRY RUN: " + detail
        self.log.append(f"{step}:{item}:{'sim' if simulated else 'live'}:{'ok' if ok else 'fail'}")
        return bool(self.call("ffm_run_receipt", {"p_launch": launch["id"], "p_step": step, "p_item": str(item)[:80], "p_simulated": bool(simulated), "p_ok": bool(ok),
                                                  "p_ref": ref, "p_detail": (detail or "")[:300] or None, "p_task": task}))

    def done(self, launch, step, item) -> bool:
        return bool(self.get(f"/rest/v1/ffm_run_receipts?launch_id=eq.{launch['id']}&step=eq.{step}&item=eq.{urllib.parse.quote(str(item))}&ok=is.true&select=id&limit=1"))

    def gate(self, launch, step, connector=None) -> dict:
        return self.call("ffm_run_gate", {"p_launch": launch["id"], "p_step": step, "p_connector": connector}) or {}

    def budget(self, launch) -> dict:
        return self.call("ffm_run_budget", {"p_launch": launch["id"]}) or {}

    def objects(self, launch) -> list[dict]:
        return self.get(f"/rest/v1/ffm_run_objects?launch_id=eq.{launch['id']}&select=id,level,plan_ref,parent_id,external_id,status,daily_cents,simulated&order=created_at") or []

    def account(self, connector) -> dict | None:
        rows = self.get(f"/rest/v1/hand_accounts?connector=eq.{connector}&division=eq.{DIVISION}&status=eq.connected&select=id,external_id,handle,token_vault_ref&order=updated_at.desc&limit=1")
        return rows[0] if rows else None

    def meta_direct(self):
        """The connected ad account with its stored token, for calls that must work whatever the gate says (pause, read real numbers). None if not connected."""
        acc = self.account("meta-ads")
        if not acc:
            return None
        return MetaAds(self.token(acc.get("token_vault_ref"))["access_token"], acc.get("external_id"), self.http)

    def ads_client(self, g: dict):
        acc = g.get("account") or {}
        return MetaAds(self.token(acc.get("token_vault_ref"))["access_token"], acc.get("external_id"), self.http)

    def live(self, l, step: str, purpose: str, work):
        """A live platform write through the existing executor gate (registry, caps, kill switch, mode). -> (result, task id). Raises NotLive (task closed)."""
        task = self.call("ffm_run_task", {"p_launch": l["id"], "p_step": step})
        self._task = task
        out = self.executor_run(EXECUTOR, AGENT, task, 1, purpose, lambda run_id: (work(), 0))
        if out.get("dry_run"):
            raise NotLive("the executor gate answered dry run; nothing was done")
        return out.get("result"), task

    @staticmethod
    def _camp(objs):
        return next((o for o in objs if o["level"] == "campaign"), None)

    # ---- the tick
    def tick(self) -> list[str]:
        launches = self.get("/rest/v1/ffm_run_launches?status=in.(approved,running,capped)&select=id,workspace_id,campaign_id,plan,status,starts_on,ends_on,landing_url,paid_platforms,organic_platforms") or []
        for l in launches:
            try:
                self.run_launch(l)
            except Exception as e:      # one launch never blocks the others; the next tick retries
                logger.warning("ffm run: launch %s step failed: %s", str(l["id"])[:8], str(e)[:200])
                self.log.append(f"error:{type(e).__name__}")
        # real ads of a launch that is no longer running (stopped, ended, a pause that Meta did not confirm): pause them, whatever else is switched off
        seen = {l["id"] for l in launches}
        stray = {r["launch_id"] for r in (self.get("/rest/v1/ffm_run_objects?simulated=is.false&status=eq.active&select=launch_id") or [])} - seen
        for lid in sorted(stray):
            try:
                l = (self.get(f"/rest/v1/ffm_run_launches?id=eq.{lid}&select=id,workspace_id,status") or [None])[0]
                if l:
                    self.pause_all(l, "stopped", notify=False)
            except Exception as e:
                logger.warning("ffm run: stray pause failed: %s", str(e)[:200])
        try:
            self.send_emails()
        except Exception as e:
            logger.warning("ffm run: email sender failed: %s", str(e)[:200])
        return self.log

    def run_launch(self, l: dict) -> None:
        probe = self.gate(l, "report")
        if probe.get("kill"):
            self.pause_all(l, "kill", notify=False)
            return
        if not probe.get("ok"):
            return
        today = _today(self.now)
        paid = "meta" in (l.get("paid_platforms") or [])
        if paid and not self.sync_budget(l):
            return                                  # a new approved budget is applied on Meta before anything else runs
        if paid and l["status"] in ("approved", "running"):
            if l["plan"].get("landing"):
                self.deploy_landing(l)
            self.launch_ads(l)
            self.resume_ads(l)
            self.resume_after_kill(l)
        if l["status"] in ("approved", "running"):
            self.post_due(l, today)
        self.poll_leads(l)
        self.work_leads(l)
        if any(o["level"] == "ad" for o in self.objects(l)):
            self.metrics(l, today)
            if self.now.hour >= OPTIMIZE_HOUR and not self.done(l, "optimize", today.isoformat()):
                self.optimize(l, today)
        if today > date.fromisoformat(str(l["ends_on"])):
            self.finish(l, "ended")
        if self.now.weekday() == 0 and self.now.hour >= REPORT_HOUR:
            self.weekly_report(l, today)

    # ---- RUN PAID ADS
    def launch_ads(self, l):
        if self.done(l, "launch", "ads"):
            return
        g = self.gate(l, "launch", "meta-ads")
        if not g.get("ok"):
            return
        live = bool(g.get("live"))
        link, page = l.get("landing_url"), None
        if live:
            page = (self.account("meta-facebook") or {}).get("external_id")
            if not link or not page:      # noted once a day, retried every tick
                return self.receipt(l, "launch", "waiting:" + _today(self.now).isoformat(), False, True,
                                    detail="waiting for " + ("the landing page url" if not link else "a connected Facebook Page for ffm"))
        plan, b = l["plan"], g["budget"]
        sets = sorted({a["set"] for a in plan["ads"]})
        sets = sets[: max(1, min(len(sets), b["daily_cents"] // MIN_SET_CENTS))]
        share = min(b["daily_cents"], b["remaining_cents"]) // len(sets)
        if share < MIN_SET_CENTS:
            return self.receipt(l, "launch", "ads", not live, False, detail="refused: less than $1.00 a day per ad set is left")
        client = self.ads_client(g) if live else self.sim
        have = {(o["level"], o["plan_ref"]): o for o in self.objects(l)}
        start, end = f"{l['starts_on']}T00:00:00-0500", f"{l['ends_on']}T23:59:00-0500"

        def work():
            sim = not live
            ws = (self.get(f"/rest/v1/client_workspaces?id=eq.{l['workspace_id']}&select=name,vertical") or [{}])[0]
            c = have.get(("campaign", "campaign"))
            if not (c and c.get("external_id")):
                ext = client.campaign(f"{ws.get('name', 'Client')} launch", b["total_cap_cents"], SPECIAL.get(plan.get("vertical"), []))
                cid = self.call("ffm_run_put_object", {"p_launch": l["id"], "p_level": "campaign", "p_ref": "campaign", "p_parent": None, "p_external": ext, "p_status": "paused", "p_daily": None, "p_simulated": sim})
                c = {"id": cid, "external_id": ext}
            tgt = client.targeting(plan.get("geo") or "")
            set_obj = {}
            for s in sets:
                o = have.get(("ad_set", s))
                if not (o and o.get("external_id")):
                    ext = client.ad_set(c["external_id"], f"Audience {s}", share, start, end, tgt)
                    oid = self.call("ffm_run_put_object", {"p_launch": l["id"], "p_level": "ad_set", "p_ref": s, "p_parent": c["id"], "p_external": ext, "p_status": "paused", "p_daily": share, "p_simulated": sim})
                    o = {"id": oid, "external_id": ext}
                set_obj[s] = o
            ad_obj = {}
            for a in plan["ads"]:
                if a["set"] not in set_obj:
                    continue
                o = have.get(("ad", a["ref"]))
                if not (o and o.get("external_id")):
                    ext = client.ad(set_obj[a["set"]]["external_id"], a["ref"], page or "sim-page", link or "https://example.invalid/landing", a["headline"], a["body"], a["cta"])
                    oid = self.call("ffm_run_put_object", {"p_launch": l["id"], "p_level": "ad", "p_ref": a["ref"], "p_parent": set_obj[a["set"]]["id"], "p_external": ext, "p_status": "paused", "p_daily": None, "p_simulated": sim})
                    o = {"id": oid, "external_id": ext}
                ad_obj[a["ref"]] = o
            # everything exists paused; the DATABASE approves each switch-on (budget rule) BEFORE it is made on Meta
            for o in list(ad_obj.values()) + list(set_obj.values()) + [c]:
                self.call("ffm_run_set_object", {"p_object": o["id"], "p_status": "active", "p_daily": None})
                client.set_status(o["external_id"], True)
            return c["external_id"]

        task = None
        try:
            if live:
                ref, task = self.live(l, "launch", "ffm launch ads", work)
            else:
                ref = work()
        except Exception as e:
            return self.receipt(l, "launch", "ads", not live, False, detail=f"failed: {type(e).__name__}: {str(e)[:160]}", task=getattr(self, "_task", None) if live else None)
        self.receipt(l, "launch", "ads", not live, True, ref=ref, task=task,
                     detail=f"created a campaign with spend cap {money(b['total_cap_cents'])}, then {len(sets)} ad sets at {money(share)} a day each, then {sum(1 for a in plan['ads'] if a['set'] in sets)} ads; all paused, then switched on")

    def sync_budget(self, l) -> bool:
        """A NEW approved budget (seq > 1) is applied on Meta before anything resumes: the campaign spend cap first (never below what Meta reports as spent),
        then every ad set cut to fit the new daily budget. True when nothing is pending."""
        b = self.budget(l)
        if not b or int(b.get("seq", 1)) <= 1:
            return True
        item = f"seq:{b['seq']}"
        if self.done(l, "budget", item):
            return True
        objs = self.objects(l)
        camp = self._camp(objs)
        if not camp:
            self.receipt(l, "budget", item, True, True, detail="no campaign yet: the new budget applies at launch")
            return True
        sets = [o for o in objs if o["level"] == "ad_set" and o["status"] != "stopped"]
        day = min(int(b["daily_cents"]), int(b["remaining_cents"]))
        total = sum(int(s["daily_cents"] or 0) for s in sets)
        cuts = {}
        if total > day:
            for s in sets:
                cuts[s["id"]] = max(MIN_SET_CENTS, int(int(s["daily_cents"] or 0) * day / total))
            keep = sorted(sets, key=lambda s: -(s["daily_cents"] or 0))
            while keep and sum(cuts[s["id"]] for s in keep) > day:
                keep.pop()                                   # smallest set out
            for s in sets:
                if s not in keep:
                    cuts[s["id"]] = None                     # stopped
        prev = (self.get(f"/rest/v1/ffm_run_budgets?launch_id=eq.{l['id']}&status=eq.superseded&nonce_used_at=not.is.null&select=total_cap_cents,seq&order=seq.desc&limit=1") or [{}])[0]
        raising = int(b["total_cap_cents"]) > int(prev.get("total_cap_cents") or 0)
        live_camp = not camp.get("simulated", True)
        if live_camp:
            g = self.gate(l, "optimize", "meta-ads")
            if raising and not g.get("live"):
                self.receipt(l, "budget", f"wait:{b['seq']}:{_today(self.now).isoformat()}", False, True, detail=f"new cap waits until live ({g.get('why_simulated') or g.get('reason')})")
                return False
            client = self.meta_direct()
            if client is None:
                self.receipt(l, "budget", f"{item}:try", False, False, detail="no connected ad account: the new budget cannot be applied on Meta")
                return False
        else:
            client = self.sim
        by_id = {s["id"]: s for s in sets}

        def work():
            spent = client.lifetime_spend(camp["external_id"])
            cap = max(int(b["total_cap_cents"]), spent)
            client.set_spend_cap(camp["external_id"], cap)                  # 1. the cap first
            for sid, cents in cuts.items():                                   # 2. cuts: Meta first, then the books (never the other way round)
                s = by_id[sid]
                if cents is None:
                    client.set_status(s["external_id"], False)
                    self.call("ffm_run_set_object", {"p_object": sid, "p_status": "stopped", "p_daily": None})
                elif cents < int(s["daily_cents"] or 0):
                    client.set_budget(s["external_id"], cents)
                    self.call("ffm_run_set_object", {"p_object": sid, "p_status": s["status"] if s["status"] != "active" or l["status"] in ("approved", "running") else "paused", "p_daily": cents})
            return cap

        task = None
        try:
            if live_camp and raising:
                cap, task = self.live(l, "budget", "ffm budget change", work)
            else:
                cap = work()
        except Exception as e:
            self.receipt(l, "budget", f"{item}:try", not live_camp, False, detail=f"failed: {str(e)[:160]}", task=task or (getattr(self, "_task", None) if live_camp and raising else None))
            return False
        self.receipt(l, "budget", item, not live_camp, True, task=task, ref=camp["external_id"],
                     detail=f"spend cap set to {money(cap)}; {sum(1 for v in cuts.values() if v)} ad sets cut and {sum(1 for v in cuts.values() if v is None)} stopped to fit {money(day)} a day")
        return True

    def resume_ads(self, l):
        """After a new approved budget for a capped launch (already applied on Meta by sync_budget): switch the paused campaign back on."""
        objs = self.objects(l)
        camp = self._camp(objs)
        if not camp or camp["status"] != "paused" or not self.done(l, "launch", "ads"):
            return
        b = self.budget(l)
        if int(b.get("seq", 1)) <= 1 or not self.done(l, "budget", f"seq:{b.get('seq')}"):
            return
        self._resume(l, objs, camp, b, f"budget:{b.get('seq', 1)}", f"after the new budget ({money(b.get('total_cap_cents'))} cap)")

    def resume_after_kill(self, l):
        """The kill switch is off again: a launch that the kill switch paused (and nothing else since) is switched back on, only through the same gate and
        budget checks as any switch-on (launch running, dates, approved budget with room left, live gate for a real campaign; the database re-checks the budget rule)."""
        objs = self.objects(l)
        camp = self._camp(objs)
        if not camp or camp["status"] != "paused":
            return
        last = (self.get(f"/rest/v1/ffm_run_receipts?launch_id=eq.{l['id']}&step=eq.pause&ok=is.true&select=id,item&order=id.desc&limit=1") or [None])[0]
        if not last or not str(last["item"]).startswith("kill:"):
            return                          # paused for another reason (cap, stop, end): never resumed here
        b = self.budget(l)
        if not b or int(b.get("remaining_cents") or 0) < MIN_SET_CENTS:
            return
        self._resume(l, objs, camp, b, f"kill:{last['id']}", "after the kill switch was switched off")

    def _resume(self, l, objs, camp, b, item, why):
        if self.done(l, "resume", item):
            return
        g = self.gate(l, "launch", "meta-ads")
        if not g.get("ok"):
            return
        live = not camp.get("simulated", True)
        if live and not g.get("live"):
            return
        client = self.ads_client(g) if live else self.sim

        def work():
            for o in [o for o in objs if o["level"] == "ad"] + [o for o in objs if o["level"] == "ad_set"] + [camp]:
                if o["status"] == "paused":
                    self.call("ffm_run_set_object", {"p_object": o["id"], "p_status": "active", "p_daily": None})
                    client.set_status(o["external_id"], True)
            return camp["external_id"]

        task = None
        try:
            if live:
                ref, task = self.live(l, "resume", "ffm resume", work)
            else:
                ref = work()
        except Exception as e:
            return self.receipt(l, "resume", item, not live, False, detail=f"failed: {str(e)[:160]}", task=getattr(self, "_task", None) if live else None)
        self.receipt(l, "resume", item, not live, True, ref=ref, task=task, detail=f"switched back on {why}")

    def _ad_rows(self, l):
        objs = self.objects(l)
        sets = {o["id"]: o for o in objs if o["level"] == "ad_set"}
        ads = [o for o in objs if o["level"] == "ad"]
        n_active = {sid: sum(1 for a in ads if a["parent_id"] == sid and a["status"] == "active") for sid in sets}
        for a in ads:
            s = sets.get(a["parent_id"]) or {}
            a["share_cents"] = (s.get("daily_cents") or 0) // max(n_active.get(a["parent_id"], 1), 1) if s.get("status") == "active" else 0
            a["ref"] = a["plan_ref"]
        return objs, sets, ads

    def metrics(self, l, today):
        """Hourly numbers (yesterday + today). A REAL campaign is read from Meta with the stored token (read-only, whatever the gate says) and is never given
        simulated numbers; a simulated campaign gets simulated numbers. The database caps the launch at the approved total."""
        hour_item = self.now.strftime("%Y-%m-%dT%H")
        if self.done(l, "metrics", hour_item):
            return
        g = self.gate(l, "optimize", "meta-ads")
        if not g.get("ok"):
            return
        objs, sets, ads = self._ad_rows(l)
        camp = self._camp(objs)
        if not camp:
            return
        real = not camp.get("simulated", True)
        client = self.meta_direct() if real else self.sim
        if client is None:
            return                              # real campaign, no token to read it with: skip (never simulate a real campaign)
        by_ext = {a["external_id"]: a for a in ads}
        capped = False
        try:
            for day, frac in ((today - timedelta(days=1), 1.0), (today, (self.now.hour * 60 + self.now.minute) / 1440)):
                if day < date.fromisoformat(str(l["starts_on"])):
                    continue
                rows = client.insights(camp["external_id"], day) if real else client.insights(camp["external_id"], day, ads=ads, fraction=frac)
                for r in rows:
                    a = by_ext.get(r["ad_id"])
                    if not a or bool(a.get("simulated", True)) == real:
                        continue
                    res = self.call("ffm_run_put_metrics", {"p_object": a["id"], "p_day": day.isoformat(), "p_spend": r["spend_cents"], "p_impressions": r["impressions"],
                                                            "p_clicks": r["clicks"], "p_leads": r["leads"], "p_simulated": not real}) or {}
                    capped = capped or bool(res.get("capped"))
        except Exception as e:
            return self.receipt(l, "metrics", hour_item, not real, False, detail=f"failed: {str(e)[:160]}")
        b = self.budget(l)
        self.receipt(l, "metrics", hour_item, not real, True, ref=camp["external_id"], detail=f"spent {money(b.get('spent_cents'))} of {money(b.get('total_cap_cents'))}")
        if capped or (b and b.get("remaining_cents", 0) < MIN_SET_CENTS):
            self.pause_all(l, "cap", b)

    def optimize(self, l, today):
        """Daily: pause losers, shift the approved daily budget to the winners. Never above the approved daily budget or the remaining cap (the database
        refuses it anyway); never pauses the last running ad. A real campaign is changed only through a live gate."""
        g = self.gate(l, "optimize", "meta-ads")
        if not g.get("ok"):
            return
        objs, sets, ads = self._ad_rows(l)
        camp = self._camp(objs)
        if not camp or g.get("status") != "running":          # the gate reads the launch status now (it may have been capped this tick)
            return
        live = not camp.get("simulated", True)
        if live and not g.get("live"):
            return self.receipt(l, "optimize", today.isoformat(), False, True, detail=f"SKIPPED: not live ({g.get('why_simulated')})")
        client = self.ads_client(g) if live else self.sim
        tot = {r["object_id"]: r for r in self._totals(l)}
        active = [a for a in ads if a["status"] == "active"]
        stats = {a["id"]: tot.get(a["id"], {"spend_cents": 0, "leads": 0}) for a in active}
        cpls = [s["spend_cents"] / s["leads"] for s in stats.values() if s["leads"] > 0]
        best = min(cpls) if cpls else None
        judge = max(LOSER_MIN_SPEND_CENTS, g["budget"]["daily_cents"] // 2)
        losers = [a for a in active if stats[a["id"]]["spend_cents"] >= judge and (stats[a["id"]]["leads"] == 0 or (best and stats[a["id"]]["spend_cents"] / stats[a["id"]]["leads"] > 2 * best))]
        losers = losers[: max(len(active) - 1, 0)]
        b = g["budget"]
        day_budget = min(b["daily_cents"], b["remaining_cents"])
        live_sets = [s for s in sets.values() if s["status"] == "active" and any(a["parent_id"] == s["id"] and a["status"] == "active" and a not in losers for a in ads)]
        live_sets = live_sets[: max(1, day_budget // MIN_SET_CENTS)]
        score = {}
        for s in live_sets:
            sp = sum(stats.get(a["id"], {}).get("spend_cents", 0) for a in ads if a["parent_id"] == s["id"])
            ld = sum(stats.get(a["id"], {}).get("leads", 0) for a in ads if a["parent_id"] == s["id"])
            score[s["id"]] = (ld / sp) if sp else 0.0
        top = max(score.values()) if score else 0.0
        weight = {sid: 1.0 + (sc / top if top else 0.0) for sid, sc in score.items()}
        wsum = sum(weight.values()) or 1.0
        alloc = {sid: max(MIN_SET_CENTS, int(day_budget * w / wsum)) for sid, w in weight.items()}
        while alloc and sum(alloc.values()) > day_budget:                 # rounding / floors: trim the biggest until inside the approved day
            k = max(alloc, key=alloc.get)
            alloc[k] -= 1
        dead_sets = [s for s in sets.values() if s["status"] == "active" and s["id"] not in alloc]
        changes = []

        def work():
            for a in losers:
                client.set_status(a["external_id"], False)
                self.call("ffm_run_set_object", {"p_object": a["id"], "p_status": "paused", "p_daily": None})
                changes.append(f"paused {a['plan_ref']}")
            for s in dead_sets:
                client.set_status(s["external_id"], False)
                self.call("ffm_run_set_object", {"p_object": s["id"], "p_status": "paused", "p_daily": None})
            # decreases first (Meta, then the books), then increases (the books approve first, then Meta): never above the approved day
            for sid, cents in sorted(alloc.items(), key=lambda kv: kv[1] - (sets[kv[0]]["daily_cents"] or 0)):
                old = sets[sid]["daily_cents"] or 0
                if cents == old:
                    continue
                if cents < old:
                    client.set_budget(sets[sid]["external_id"], cents)
                    self.call("ffm_run_set_object", {"p_object": sid, "p_status": "active", "p_daily": cents})
                else:
                    self.call("ffm_run_set_object", {"p_object": sid, "p_status": "active", "p_daily": cents})
                    client.set_budget(sets[sid]["external_id"], cents)
                changes.append(f"set {sets[sid]['plan_ref']} from {money(old)} to {money(cents)} a day")
            return camp["external_id"]

        task = None
        try:
            if live:
                ref, task = self.live(l, "optimize", "ffm optimize", work)
            else:
                ref = work()
        except Exception as e:
            return self.receipt(l, "optimize", today.isoformat(), not live, False, detail=f"failed: {str(e)[:160]}", task=getattr(self, "_task", None) if live else None)
        self.receipt(l, "optimize", today.isoformat(), not live, True, ref=ref, task=task, detail=("; ".join(changes) or "no change")[:250])

    def _totals(self, l):
        rows = self.get(f"/rest/v1/ffm_run_metrics?launch_id=eq.{l['id']}&select=object_id,spend_cents,leads,clicks") or []
        out = {}
        for r in rows:
            t = out.setdefault(r["object_id"], {"object_id": r["object_id"], "spend_cents": 0, "leads": 0, "clicks": 0})
            for k in ("spend_cents", "leads", "clicks"):
                t[k] += int(r.get(k) or 0)
        return list(out.values())

    def pause_all(self, l, why: str, b=None, notify=True) -> bool:
        """Cap, end, stop, kill switch: pause every running object. A REAL campaign is paused on Meta directly with the stored token, whatever the kill switch,
        mode, connector, executor or workspace say (pausing only stops spend); the books are marked paused only after Meta confirmed it. A failure is
        recorded as failed and retried next tick. -> True when nothing real is left running."""
        objs = self.objects(l)
        active = [o for o in objs if o["status"] == "active"]
        if not active:
            return True
        b = b or self.budget(l)
        item = f"{why}:{b.get('seq', 1)}:{self.now.strftime('%Y%m%dT%H%M')}"
        real = [o for o in active if not o.get("simulated", True)]
        if real:
            camp = self._camp(objs)
            try:
                client = self.meta_direct()
            except Exception:
                client = None
            if client is None or camp is None:
                self.receipt(l, "pause", item, False, False, detail=f"{why}: cannot pause on Meta (no connected ad account); retrying")
                return False
            try:
                client.set_status(camp["external_id"], False)        # one pause on the campaign stops every ad set and ad
            except Exception as e:
                self.receipt(l, "pause", item, False, False, ref=camp["external_id"], detail=f"{why}: Meta did not confirm the pause ({str(e)[:120]}); retrying")
                return False
        for o in active:
            self.call("ffm_run_set_object", {"p_object": o["id"], "p_status": "paused", "p_daily": None})
        self.receipt(l, "pause", item, not real, True, ref=(self._camp(objs) or {}).get("external_id"),
                     detail=f"{why}: all ads paused{' on Meta (confirmed)' if real else ''} at {money(b.get('spent_cents'))} spent")
        if why == "cap" and notify and self.receipt(l, "notice", f"cap:{b.get('seq', 1)}", not real, True, detail="owner told"):
            self.send_owner(f"Sir, {self._name(l)} reached its approved cap ({money(b.get('spent_cents'))} of {money(b.get('total_cap_cents'))}). "
                            f"All ads are paused{' on Meta' if real else ' (dry run)'}. To continue: /ffm budget {self._slug(l)} <daily $> <new total $> (one tap to approve).", "money")
        return True

    def finish(self, l, why):
        self.pause_all(l, why)
        self.call("ffm_run_stop", {"p_launch": l["id"], "p_by": "ffm-run:" + why})
        self.weekly_report(l, _today(self.now), final=True)

    # ---- POST CONTENT
    def post_due(self, l, today):
        start = date.fromisoformat(str(l["starts_on"]))
        if self.now.hour < POST_HOUR:
            return
        for p in l["plan"].get("posts", []):
            if start + timedelta(days=int(p["day"]) - 1) > today or self.done(l, "post", p["ref"]):
                continue
            conn = PLATFORM_CONNECTOR[p["platform"]]
            if p["platform"] not in TEXT_ONLY:
                self.receipt(l, "post", p["ref"], True, True, detail=f"SKIPPED: {p['platform']} needs an image or video and the plan has none")
                continue
            g = self.gate(l, "post", conn)
            if not g.get("ok"):
                return
            if not g.get("live"):
                self.receipt(l, "post", p["ref"], True, True, detail=f"would post on {p['platform']} ({g.get('why_simulated')}): {p['text'][:80]}")
                continue
            r = self.call("ffm_run_submit_hand", {"p_launch": l["id"], "p_item": p["ref"], "p_connector": conn, "p_action": "post", "p_payload": {"text": p["text"]}}) or {}
            self.receipt(l, "post", p["ref"], False, bool(r.get("ok")), ref=f"hand:{r['action_id']}" if r.get("action_id") else None,
                         detail=(f"queued in hands ({r.get('status')})" if r.get("ok") else f"refused: {r.get('reason')}"))

    def deploy_landing(self, l):
        if self.done(l, "deploy", "landing"):
            return
        g = self.gate(l, "deploy", "netlify")
        if not g.get("ok"):
            return
        page = self.landing_page(l)
        if page is None or hashlib.sha256(page.encode()).hexdigest() != l["plan"].get("landing_sha256"):
            return self.receipt(l, "deploy", "landing", not g.get("live"), False, detail="refused: the page no longer matches the approved one (pack or consent wording changed)")
        if not g.get("live"):
            return self.receipt(l, "deploy", "landing", True, True, detail=f"would deploy the landing page to Netlify ({g.get('why_simulated')})")
        r = self.call("ffm_run_submit_hand", {"p_launch": l["id"], "p_item": "landing", "p_connector": "netlify", "p_action": "deploy", "p_payload": {"html": page}}) or {}
        if r.get("ok"):
            acc = g.get("account") or {}
            h = str(acc.get("handle") or "")
            url = f"https://{h}" if "." in h else f"https://{h}.netlify.app"
            self.call("ffm_run_set_landing", {"p_launch": l["id"], "p_url": url})
            l["landing_url"] = url
        self.receipt(l, "deploy", "landing", False, bool(r.get("ok")), ref=f"hand:{r['action_id']}" if r.get("action_id") else None,
                     detail=(f"queued in hands ({r.get('status')})" if r.get("ok") else f"refused: {r.get('reason')}"))

    def landing_page(self, l):
        ws = (self.get(f"/rest/v1/client_workspaces?id=eq.{l['workspace_id']}&select=id,name,vertical") or [None])[0]
        rows = self.get(f"/rest/v1/ffm_engine_packs?workspace_id=eq.{l['workspace_id']}&status=eq.draft&select=pack&order=version.desc&limit=1")
        if not ws or not rows:
            return None
        wording = inputs_for(l["workspace_id"], self.get).get("consent_wording") or ""
        return live_landing_html(E.expand(rows[0]["pack"], ws["name"]), wording, l["plan"].get("consent_version") or "")

    # ---- WORK THE LEADS
    def intake(self, l, source: str, ref: str, fields: dict, consent: dict) -> dict:
        """THE lead intake (landing page form, Meta lead form, a future webhook). Only name, email and phone are kept; anything else in the
        submission is dropped unread. Consent fields are required by the database. The first touch goes out in the same call."""
        keep = {k: (str(fields.get(k)).strip()[:160] if fields.get(k) else None) for k in ("name", "email", "phone")}
        try:
            r = self.call("ffm_run_intake_lead", {"p_launch": l["id"], "p_source": source, "p_source_ref": ref, "p_name": keep["name"], "p_email": keep["email"],
                                                  "p_phone": keep["phone"], "p_consent": consent, "p_by": "ffm-run"}) or {}
        except Exception as e:      # recorded ONCE per submission: the poller skips a refused submission from then on
            self.receipt(l, "intake", re.sub(r"[^A-Za-z0-9_.:-]", "-", ref)[:80], False, True,
                         detail=f"REFUSED: {'sensitive data' if isinstance(e, E.SensitiveDataRefused) else str(e)[:150]}")
            return {"ok": False, "reason": str(e)[:200]}
        if r.get("ok") and not r.get("duplicate"):
            self.work_leads(l, only=r["lead_id"])
        return r

    def poll_leads(self, l):
        for conn in ("netlify", "meta-ads"):
            if conn == "meta-ads" and (self.now.minute >= 5 or not any(o["level"] == "ad" and not o.get("simulated", True) for o in self.objects(l))):
                continue             # Meta lead forms: about once an hour (the landing page form is read every tick)
            if conn == "netlify" and not l["plan"].get("landing"):
                continue
            g = self.gate(l, "leads", conn)
            if not (g.get("ok") and g.get("live")):
                continue             # dry run: leads only come from real forms; nothing is invented
            try:
                tok = self.token((g.get("account") or {}).get("token_vault_ref"))
                found = self._netlify_leads(g, tok) if conn == "netlify" else self._meta_leads(l, g, tok)
            except Exception as e:
                self.receipt(l, "leads", "poll:" + conn + ":" + self.now.strftime("%Y%m%dT%H"), False, False, detail=f"poll failed: {str(e)[:150]}")
                continue
            fresh = [f for f in found if not self.done(l, "intake", re.sub(r"[^A-Za-z0-9_.:-]", "-", f[1])[:80])]
            new = [r for r in (self.intake(l, *f) for f in fresh) if r.get("ok") and not r.get("duplicate")]
            if new:              # a receipt only when something arrived (polling every few minutes would otherwise fill the table)
                self.receipt(l, "leads", "poll:" + conn + ":" + self.now.strftime("%Y%m%dT%H%M"), False, True, detail=f"{len(new)} new lead(s)")

    def _netlify_leads(self, g, tok):
        site = (g.get("account") or {}).get("external_id")
        s, b, _ = self.http("GET", f"https://api.netlify.com/api/v1/sites/{urllib.parse.quote(str(site))}/submissions?per_page=100",
                            headers={"Authorization": "Bearer " + tok["api_key"]})
        if s != 200 or not isinstance(b, list):
            raise A._err("Netlify", s, b)
        out = []
        for sub in b:
            d = sub.get("data") or {}
            if d.get("company"):        # honeypot
                continue
            out.append(("landing", "nf-" + str(sub.get("id")), d, {"given": str(d.get("consent")).lower() in ("yes", "on", "true"), "wording_version": d.get("wording_version"),
                                                                    "captured_at": sub.get("created_at"), "evidence_ref": "nf-" + str(sub.get("id"))}))
        return out

    def _meta_leads(self, l, g, tok):
        client = MetaAds(tok["access_token"], (g.get("account") or {}).get("external_id"), self.http)
        out = []
        for o in self.objects(l):
            if o["level"] != "ad" or o.get("simulated", True):
                continue
            for lead in client.ad_leads(o["external_id"], None):
                out.append(meta_lead(lead, l["plan"].get("consent_version")))
        return out

    def work_leads(self, l, only: str | None = None):
        q = f"lead_id=eq.{only}" if only else f"next_due_at=lte.{urllib.parse.quote(self.now.isoformat())}"
        due = self.get(f"/rest/v1/ffm_run_leads?launch_id=eq.{l['id']}&status=eq.active&{q}&select=lead_id,next_touch&order=next_due_at&limit=50") or []
        if not due:
            return
        g = self.gate(l, "followup")
        if not g.get("ok"):
            return
        booking = inputs_for(l["workspace_id"], self.get).get("booking_link") or ""
        for d in due:
            n = int(d["next_touch"])
            t = next((t for t in l["plan"].get("touches", []) if int(t["touch"]) == n), None)
            if not t:
                continue
            body = t["body"] + (f"\n\nBook a time: {booking}" if booking.startswith("https://") else "")
            r = self.call("ffm_run_touch", {"p_lead": d["lead_id"], "p_touch": n, "p_subject": t["subject"], "p_body": body, "p_live": bool(g.get("live"))}) or {}
            if r.get("ok"):
                sim = r.get("status") != "queued"
                det = {"queued": "email queued from the client's sender (sent after the send-time checks)", "simulated": f"would email touch {n}",
                       "skipped": f"SKIPPED: not contactable ({r.get('reason')})"}.get(r.get("status"), r.get("status"))
                self.receipt(l, "followup", f"{d['lead_id'][:8]}:{n}", sim, True, ref=f"email:{r['email_id']}" if r.get("email_id") else None, detail=det)

    def send_emails(self, limit: int = 10) -> int:
        """The FF Marketing sender. Automatic sending is OFF per client by default: waiting emails are batched into ONE owner message per launch per tick
        (ffm_run_ask_emails) and go only after his tap. Each email is re-checked by ffm_run_claim_email at send time (kill switch, live mode, dry-run launch,
        the lead's sequence, consent / withdrawal / suppression / outreach gate, this client's CASL footer, the owner's approval while autosend is off) and
        allowed by the policy engine ('send_email' caps). The sender's external high-water mark is checked once per batch (hq_gatemark.attest(force=True)).
        One Idempotency-Key per email row. Nothing is sent without RESEND_API_KEY. -> emails sent."""
        import os
        waiting = self.get("/rest/v1/ffm_run_emails?status=eq.queued&batch_id=is.null&owner_ok_at=is.null&select=launch_id&limit=200") or []
        for lid in sorted({r["launch_id"] for r in waiting}):
            try:
                self.call("ffm_run_ask_emails", {"p_launch": lid})
            except Exception as e:
                logger.warning("ffm run: email batch not asked: %s", str(e)[:120])
        if not os.environ.get("RESEND_API_KEY") and not self._mail_injected:
            return 0
        rows = self.get(f"/rest/v1/ffm_run_emails?status=eq.queued&select=id&order=created_at&limit={int(limit)}") or []
        if not rows:
            return 0
        a = self.attest()
        if not a.get("ok"):
            logger.warning("ffm run: sender gate not attested (%s); nothing sent", a.get("reason"))
            return 0
        sent = 0
        for row in rows:
            if not self.authorize(row["id"]):
                continue
            c = self.call("ffm_run_claim_email", {"p_id": row["id"]}) or {}
            if not c.get("ok"):
                continue
            c["id"] = row["id"]
            try:
                ok, ref = self.mail_post(c)
            except Exception as e:
                ok, ref = False, type(e).__name__
            self.call("ffm_run_email_result", {"p_id": row["id"], "p_ok": bool(ok), "p_ref": ref if ok else None, "p_reason": None if ok else str(ref)[:120]})
            sent += 1 if ok else 0
        return sent

    # ---- REPORT RESULTS
    def weekly_report(self, l, today, final=False):
        week = "final" if final else f"{today.isocalendar()[0]}-W{today.isocalendar()[1]:02d}"
        if self.done(l, "report", week):
            return
        r = self.call("ffm_run_report", {"p_launch": l["id"], "p_from": (today - timedelta(days=7)).isoformat(), "p_to": (today - timedelta(days=1)).isoformat()}) or {}
        sim = bool(r.get("simulated"))
        self.send_owner(owner_report(r, final), "brief")
        self.send_owner(client_report(r), "brief")
        self.receipt(l, "report", week, sim, True, detail=f"{'final' if final else 'weekly'} report queued to the owner")

    def _name(self, l):
        return (self.get(f"/rest/v1/client_workspaces?id=eq.{l['workspace_id']}&select=name") or [{}])[0].get("name", "the client")

    def _slug(self, l):
        return (self.get(f"/rest/v1/client_workspaces?id=eq.{l['workspace_id']}&select=slug") or [{}])[0].get("slug", "<slug>")


def meta_lead(lead: dict, consent_version: str | None):
    """A Meta lead-form lead (Graph /{ad}/leads or a leadgen webhook fetch) -> intake tuple. The form's custom disclaimer checkbox is the consent."""
    fd = {f.get("name"): (f.get("values") or [None])[0] for f in lead.get("field_data") or []}
    fields = {"name": fd.get("full_name") or fd.get("first_name"), "email": fd.get("email"), "phone": fd.get("phone_number")}
    given = any(str(v).lower() in ("true", "yes", "1", "agree") for k, v in fd.items() if k and "consent" in k)
    ref = "meta-" + str(lead.get("id"))
    return ("meta_form", ref, fields, {"given": given, "wording_version": consent_version, "captured_at": lead.get("created_time"), "evidence_ref": ref})


def inputs_for(ws_id: str, get) -> dict:
    rows = get(f"/rest/v1/ffm_onboarding_items?workspace_id=eq.{ws_id}&template_key=in.(consent_wording,booking_link)&status=eq.provided&select=template_key,value_text") or []
    return {r["template_key"]: r["value_text"] for r in rows}


def owner_report(r: dict, final=False) -> str:
    tag = "DRY RUN (simulated numbers). " if r.get("simulated") else ""
    best = "\n".join(f"- {a.get('headline') or a['ref']}: {a.get('leads', 0)} leads, {money(a.get('spend_cents'))}"
                     + (f", {money(a['cpl_cents'])}/lead" if a.get("cpl_cents") is not None else "") for a in r.get("best_ads") or []) or "- no ad data yet"
    return (f"Sir, {'final' if final else 'weekly'} FF Marketing report, {r.get('name')} ({r.get('from')} to {r.get('to')}). {tag}\n"
            f"Spend: {money(r.get('spend_cents'))} this period, {money(r.get('spent_total_cents'))} of the {money(r.get('total_cap_cents'))} cap.\n"
            f"Leads: {r.get('leads', 0)}. Cost per lead: {money(r['cpl_cents']) if r.get('cpl_cents') is not None else '-'}.\n"
            f"Best ads:\n{best}\nLeads by status: {json.dumps(r.get('leads_by_status') or {})}. Follow-ups: {json.dumps(r.get('touches') or {})}.\n"
            f"Launch status: {r.get('status')}. The client draft follows in the next message (not sent to the client).")


def client_report(r: dict) -> str:
    tag = "[DRY RUN - simulated numbers, do not send] " if r.get("simulated") else ""
    best = "; ".join(f"\"{a.get('headline') or a['ref']}\" ({a.get('leads', 0)} leads)" for a in (r.get("best_ads") or [])[:3]) or "not enough data yet"
    return (f"Client report draft for {r.get('name')} - review before sending. {tag}\n\n"
            f"Hi, here is your campaign update for {r.get('from')} to {r.get('to')}.\n"
            f"Ad spend: {money(r.get('spend_cents'))} (total so far {money(r.get('spent_total_cents'))} of the agreed {money(r.get('total_cap_cents'))}).\n"
            f"New leads: {r.get('leads', 0)}. Cost per lead: {money(r['cpl_cents']) if r.get('cpl_cents') is not None else '-'}.\n"
            f"Best performing ads: {best}.\n"
            f"Every new lead got a reply within minutes and a follow-up sequence; anyone who replied or opted out was stopped right away.\n"
            f"Next week: more budget on the best audiences, weaker ads paused.")


# ------------------------------------------------------------------------------------------------------------------- owner commands
def propose(slug: str, daily_cents: int, total_cents: int, days: int = 30, start: date | None = None, rpc=None, get=None, now=None) -> str:
    get = get or E._get
    ws = E.workspace(slug, get)
    if not ws:
        return f"Sir, no workspace '{slug}'."
    rows = get(f"/rest/v1/ffm_engine_packs?workspace_id=eq.{ws['id']}&status=eq.draft&select=id,pack,campaign_id&order=version.desc&limit=1")
    if not rows:
        return f"Sir, no campaign pack for {slug} yet: /ffm pack {slug} first."
    inputs = inputs_for(ws["id"], get)
    ver = (get(f"/rest/v1/ffm_consent_wordings?workspace_id=eq.{ws['id']}&select=version&order=registered_at.desc&limit=1") or [{}])[0].get("version")
    plan, _ = build_plan(ws, rows[0], inputs, ver)
    start = start or _today(now or datetime.now(hq_core.TZ))
    end = start + timedelta(days=max(1, min(int(days), 30)) - 1)          # one tap covers at most 30 days
    organic = sorted({p["platform"] for p in plan["posts"]})
    r = E._call("ffm_run_propose", {"p_ws": ws["id"], "p_pack": rows[0]["id"], "p_daily": daily_cents, "p_total": total_cents, "p_starts": start.isoformat(),
                                    "p_ends": end.isoformat(), "p_paid": ["meta"] if plan["ads"] else [], "p_organic": organic, "p_plan": plan, "p_by": "owner:telegram"}, rpc) or {}
    missing = [] if plan.get("landing") else ["the client's consent wording (onboarding item consent_wording) and a registered wording version, for the landing page"]
    return (f"Sir, the launch for {ws['name']} is in your messages for one tap: {len(plan['ads'])} ads, {len(plan['posts'])} posts, {len(plan['touches'])} follow-ups, "
            f"{money(daily_cents)}/day, cap {money(total_cents)}, {start} to {end}." + (f" Not included until provided: {'; '.join(missing)}." if missing else "")
            + f" Everything that will run: /ffm plan {str(r.get('launch_id', ''))[:8]}.")


def current_launch(slug: str, get) -> tuple[dict | None, dict | None]:
    ws = E.workspace(slug, get)
    if not ws:
        return None, None
    rows = get(f"/rest/v1/ffm_run_launches?workspace_id=eq.{ws['id']}&status=in.(proposed,approved,running,capped)&select=id,status,starts_on,ends_on,landing_url&order=created_at.desc&limit=1")
    return ws, (rows[0] if rows else None)


def status_text(slug: str, rpc=None, get=None) -> str:
    get = get or E._get
    ws, l = current_launch(slug, get)
    if not ws:
        return f"Sir, no workspace '{slug}'."
    if not l:
        return f"Sir, {slug} has no launch in progress. /ffm launch {slug} <daily $> <total $> [days]."
    b = E._call("ffm_run_budget", {"p_launch": l["id"]}, rpc) or {}
    rec = get(f"/rest/v1/ffm_run_receipts?launch_id=eq.{l['id']}&select=step,item,simulated,ok,detail&order=id.desc&limit=6") or []
    leads = get(f"/rest/v1/ffm_run_leads?launch_id=eq.{l['id']}&select=status") or []
    by = {}
    for x in leads:
        by[x["status"]] = by.get(x["status"], 0) + 1
    lines = [f"Sir, {ws['name']} launch is {l['status']} ({l['starts_on']} to {l['ends_on']}).",
             f"Budget: {money(b.get('daily_cents'))}/day, spent {money(b.get('spent_cents'))} of {money(b.get('total_cap_cents'))}." if b else "Budget: waiting for your approval.",
             f"Leads: {len(leads)} {json.dumps(by) if by else ''}".strip(), "Latest:"]
    lines += [f"- {'DRY RUN ' if r['simulated'] else ''}{r['step']} {r['item']}: {'ok' if r['ok'] else 'failed'} {r.get('detail') or ''}"[:200] for r in rec]
    return "\n".join(lines)


def lead_event(short: str, event: str, rpc=None, get=None) -> str:
    get = get or E._get
    s = re.sub(r"[^0-9a-f]", "", (short or "").lower())[:8]
    if len(s) < 6:
        return "Sir, give the first 8 characters of the lead id (from /ffm status or the outbox)."
    rows = get(f"/rest/v1/ffm_run_leads?lead_id=gte.{s.ljust(8, '0')}-0000-0000-0000-000000000000&lead_id=lte.{s.ljust(8, 'f')}-ffff-ffff-ffff-ffffffffffff&select=lead_id&limit=2") or []
    if len(rows) != 1:
        return "Sir, I could not find exactly one lead with that id."
    ev = {"replied": "replied", "reply": "replied", "booked": "booked", "stop": "opted_out", "optout": "opted_out", "opt-out": "opted_out", "lost": "lost"}.get(event.lower())
    if not ev:
        return "Sir, use: /ffm lead <id> replied | booked | stop | lost."
    r = E._call("ffm_run_lead_event", {"p_lead": rows[0]["lead_id"], "p_event": ev, "p_by": "owner:telegram"}, rpc) or {}
    return f"Sir, lead marked {ev}; its follow-ups stopped" + (f" and {r['drafts_withdrawn']} pending draft(s) withdrawn" if r.get("drafts_withdrawn") else "") + (
        "; consent withdrawn and the contact suppressed." if ev == "opted_out" else ".")


def command(sub: str, args: list[str], rpc=None, get=None, now=None) -> str:
    """/ffm launch <slug> <daily $> <total $> [days] [YYYY-MM-DD] | status <slug> | stop <slug> | budget <slug> <daily $> <total $> | lead <id> <event>"""
    get = get or E._get
    try:
        if sub == "launch" and len(args) >= 3:
            days = int(args[3]) if len(args) > 3 else 30
            start = date.fromisoformat(args[4]) if len(args) > 4 else None
            return propose(args[0].lower(), parse_money(args[1]), parse_money(args[2]), days, start, rpc, get, now)
        if sub == "status" and args:
            return status_text(args[0].lower(), rpc, get)
        if sub == "stop" and args:
            ws, l = current_launch(args[0].lower(), get)
            if not l:
                return "Sir, no launch in progress there."
            eng = Engine(rpc=rpc, get=get, now=now)
            lw = {**l, "workspace_id": ws["id"]}
            real = any(not o.get("simulated", True) and o["status"] == "active" for o in eng.objects(lw))
            paused = eng.pause_all(lw, "stopped", notify=False)          # pause FIRST, then mark the launch stopped
            E._call("ffm_run_stop", {"p_launch": l["id"], "p_by": "owner:telegram"}, rpc)
            if real and not paused:
                return (f"Sir, the {ws['name']} launch is stopped, but Meta did NOT confirm the pause: its ads may still be spending. I retry every 5 minutes; "
                        "pause the campaign in Ads Manager if you want it off right now.")
            what = "Its ads are paused on Meta (confirmed)." if real else "No live ads were running (dry run)."
            return f"Sir, the {ws['name']} launch is stopped. {what} Leads already in follow-up keep their sequence; /ffm lead <id> stop ends one."
        if sub == "autosend" and len(args) >= 2 and args[1].lower() in ("on", "off"):
            ws = E.workspace(args[0].lower(), get)
            if not ws:
                return f"Sir, no workspace '{args[0]}'."
            on = args[1].lower() == "on"
            E._call("ffm_run_set_autosend", {"p_ws": ws["id"], "p_on": on, "p_by": "owner:telegram"}, rpc)
            return (f"Sir, automatic emails are ON for {ws['name']}: follow-ups to leads with verified consent go out without a tap (still re-checked at send time)."
                    if on else f"Sir, automatic emails are OFF for {ws['name']}: every follow-up waits for your tap (one message per launch lists them).")
        if sub == "plan" and args:
            return plan_text(args[0], get)
        if sub == "sender" and len(args) >= 2:
            parts = [x.strip() for x in " ".join(args[1:]).split("|")]
            if len(parts) != 4:
                return "Sir, use: /ffm sender <slug> <from email> | <sender name> | <brand> | <mailing address>"
            ws = E.workspace(args[0].lower(), get)
            if not ws:
                return f"Sir, no workspace '{args[0]}'."
            E._call("ffm_run_set_sender", {"p_ws": ws["id"], "p_from_email": parts[0], "p_sender_name": parts[1], "p_brand": parts[2], "p_mailing_address": parts[3],
                                           "p_by": "owner:telegram"}, rpc)
            return (f"Sir, {ws['name']}'s emails will come from {parts[0]} with its own CASL footer and unsubscribe link. "
                    "The client's sending domain must be verified in Resend before anything is sent.")
        if sub == "budget" and len(args) >= 3:
            ws, l = current_launch(args[0].lower(), get)
            if not l or l["status"] == "proposed":
                return "Sir, no approved launch there."
            E._call("ffm_run_request_budget", {"p_launch": l["id"], "p_daily": parse_money(args[1]), "p_total": parse_money(args[2]), "p_by": "owner:telegram"}, rpc)
            return "Sir, the budget change is in your messages for one tap. Nothing changes until you approve it."
        if sub == "lead" and len(args) >= 2:
            return lead_event(args[0], args[1], rpc, get)
    except E.SensitiveDataRefused as e:
        return f"Sir, refused by the privacy screen: {str(e)[:160]}"
    except (ValueError, RuntimeError) as e:
        return f"Sir, not done: {str(e)[:200]}"
    return ("Sir, FF Marketing execution: /ffm sender <slug> <from> | <name> | <brand> | <address>, /ffm launch <slug> <daily $> <total $> [days, max 30] [start YYYY-MM-DD], "
            "/ffm plan <launch id>, /ffm status <slug>, /ffm stop <slug>, /ffm budget <slug> <daily $> <total $>, /ffm lead <id> replied|booked|stop|lost.")


def plan_text(ref: str, get=None) -> str:
    """Everything a launch will run: every ad, post and email text, and the landing page hash (what the one tap approves)."""
    get = get or E._get
    s = re.sub(r"[^0-9a-f]", "", (ref or "").lower())[:8]
    rows = []
    if len(s) >= 6:
        rows = get(f"/rest/v1/ffm_run_launches?id=gte.{s.ljust(8, '0')}-0000-0000-0000-000000000000&id=lte.{s.ljust(8, 'f')}-ffff-ffff-ffff-ffffffffffff"
                   "&select=id,plan,plan_sha256,starts_on,ends_on,status&limit=2") or []
    if len(rows) != 1:
        ws = E.workspace(ref.lower(), get)
        rows = get(f"/rest/v1/ffm_run_launches?workspace_id=eq.{ws['id']}&select=id,plan,plan_sha256,starts_on,ends_on,status&order=created_at.desc&limit=1") if ws else []
    if not rows:
        return "Sir, I could not find that launch."
    l, p = rows[0], rows[0]["plan"]
    out = [f"Sir, launch {l['id'][:8]} ({l['status']}, {l['starts_on']} to {l['ends_on']}), plan {l['plan_sha256'][:12]}:", "ADS:"]
    out += [f"{a['ref']} [{a['set']}, {a['cta']}] {a['headline']} - {a['body']}" for a in p.get("ads", [])]
    out += ["POSTS:"] + [f"{x['ref']} day {x['day']} {x['platform']}: {x['text']}" for x in p.get("posts", [])]
    out += ["EMAILS (plus the client's CASL footer and the booking link):"] + [f"{t['touch']} day {t['day']}: {t['subject']} - {t['body']}" for t in p.get("touches", [])]
    out += [f"LANDING PAGE: {'sha256 ' + p['landing_sha256'] if p.get('landing') else 'none'}"]
    return "\n".join(out)


def decide(msg_id: str, approved: bool, rpc=None, get=None) -> str:
    return decide_status(msg_id, approved, rpc, get)[1]


def decide_status(msg_id: str, approved: bool, rpc=None, get=None) -> tuple[bool, str]:
    """The owner's tap on a launch / budget approval (called only by hq_commands.apply_decision, the owner-only handler that the Telegram button and the
    PWA's Approve both reach). The single-use nonce is read with the service key and presented to ffm_run_owner_decide, which checks it."""
    get = get or E._get
    if not _UUID.match(str(msg_id or "")):
        return False, "Not changed: bad message id."
    rows = get(f"/rest/v1/ffm_run_budgets?owner_message_id=eq.{msg_id}&select=id,approval_nonce&limit=1") or []
    if not rows:
        return False, "Not changed: no launch budget is waiting on this message."
    try:
        r = E._call("ffm_run_owner_decide", {"p_message": msg_id, "p_nonce": rows[0]["approval_nonce"], "p_approved": bool(approved), "p_by": "owner:telegram"}, rpc) or {}
    except Exception as e:
        return False, f"Not changed: {str(e)[:150]}"
    if not r.get("ok"):
        return False, f"Not changed: {r.get('reason')}."
    if r.get("status") == "rejected":
        return True, "Rejected. Nothing will run."
    return True, ("Approved. I run it from here, inside the approved numbers." + (" It runs as DRY RUN (simulated) because the system is in dry-run mode." if r.get("dry_run") else ""))


def decide_emails_status(msg_id: str, approved: bool, rpc=None, get=None) -> tuple[bool, str]:
    """The owner's tap on a batch of waiting client emails (automatic sending off). Same path and checks as decide()."""
    get = get or E._get
    if not _UUID.match(str(msg_id or "")):
        return False, "Not changed: bad message id."
    rows = get(f"/rest/v1/ffm_run_email_batches?owner_message_id=eq.{msg_id}&select=id,approval_nonce&limit=1") or []
    if not rows:
        return False, "Not changed: no email batch is waiting on this message."
    try:
        r = E._call("ffm_run_decide_emails", {"p_message": msg_id, "p_nonce": rows[0]["approval_nonce"], "p_approved": bool(approved), "p_by": "owner:telegram"}, rpc) or {}
    except Exception as e:
        return False, f"Not changed: {str(e)[:150]}"
    if not r.get("ok"):
        return False, f"Not changed: {r.get('reason')}."
    return True, (f"Approved: {r.get('emails')} email(s) go out after the send-time checks." if r.get("status") == "approved" else f"Rejected: {r.get('emails')} email(s) withdrawn.")


# ------------------------------------------------------------------------------------------------------------------- Meta ad account connection (official OAuth)
def connect_ads_start(env: dict | None = None) -> str:
    """The Meta OAuth link with the Marketing API scopes. The owner opens it, approves, and pastes the redirect back with /ffm connectads <url>."""
    import secrets as _s
    import time
    import hq_hands
    env = env if env is not None else hq_hands._env_for({})
    app_id, = A._need(env, "META_APP_ID")
    state = _s.token_urlsafe(24)
    hq_hands._STATES[state] = {"connector": "meta-ads", "division": DIVISION, "verifier": "", "expires": time.time() + hq_hands.OAUTH_TTL_S}
    return "https://www.facebook.com/v21.0/dialog/oauth?" + urllib.parse.urlencode({"client_id": app_id, "redirect_uri": A._redirect(env), "state": state,
                                                                                    "scope": ADS_SCOPES, "response_type": "code"})


def connect_ads_finish(pasted_url: str, env: dict | None = None, call=None, rpc=None) -> str:
    import time
    import hq_hands
    env = env if env is not None else hq_hands._env_for({})
    call = call or A.http
    q = urllib.parse.parse_qs(urllib.parse.urlparse(pasted_url.strip()).query)
    st = hq_hands._STATES.pop((q.get("state") or [""])[0], None)
    code = (q.get("code") or [""])[0]
    if not st or st["expires"] < time.time() or st["connector"] != "meta-ads" or not code:
        return "Sir, that link does not match a connection I started (or it expired). Send /ffm connectads again."
    app_id, secret = A._need(env, "META_APP_ID", "META_APP_SECRET")
    s, b, _ = call("GET", f"{A.GRAPH}/oauth/access_token?" + urllib.parse.urlencode({"client_id": app_id, "client_secret": secret, "redirect_uri": A._redirect(env), "code": code}))
    if s != 200 or not isinstance(b, dict) or "access_token" not in b:
        raise A._err("Meta", s, b)
    s, b, _ = call("GET", f"{A.GRAPH}/oauth/access_token?" + urllib.parse.urlencode({"grant_type": "fb_exchange_token", "client_id": app_id, "client_secret": secret,
                                                                                     "fb_exchange_token": b["access_token"]}))
    if s != 200 or not isinstance(b, dict) or "access_token" not in b:
        raise A._err("Meta", s, b)
    tok = b["access_token"]
    s, acc, _ = call("GET", f"{A.GRAPH}/me/adaccounts?" + urllib.parse.urlencode({"fields": "account_id,name", "access_token": tok}))
    if s != 200 or not isinstance(acc, dict) or not acc.get("data"):
        raise A.HandError("Meta returned no ad account for this login")
    names = []
    for a in acc["data"][:3]:
        handle = A._slug_handle(a.get("name") or a.get("account_id"))
        ref = hq_hands._store_token("meta-ads", handle, {"access_token": tok})
        r = (rpc or hq_hands._rpc)("hands_connect", {"p_connector": "meta-ads", "p_division": DIVISION, "p_handle": handle, "p_external_id": "act_" + str(a["account_id"]),
                                                     "p_token_vault_ref": ref, "p_expires_at": None, "p_scopes": ADS_SCOPES.split(","), "p_by": "owner:telegram"}) or {}
        names.append(handle + ("" if r.get("ok") else f" (not recorded: {r.get('reason')})"))
    return f"Sir, connected Meta ad account(s): {', '.join(names)}. The token is in the vault only."


# ------------------------------------------------------------------------------------------------------------------- scheduling
async def tick_job(context) -> None:
    if not hq.hq_enabled():
        return
    try:
        await asyncio.to_thread(lambda: Engine().tick())
    except Exception:
        logger.exception("ffm run tick failed")


def register(app) -> None:
    jq = getattr(app, "job_queue", None)
    if jq is not None:
        jq.run_repeating(tick_job, interval=TICK_SECONDS, first=90, name="ffm-run")
