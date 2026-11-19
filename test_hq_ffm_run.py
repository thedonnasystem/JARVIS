"""FF Marketing execution v1 (hq_ffm_run + migrations/20261126_ffm_run_v1.sql). Platform APIs are always mocked; nothing reaches the network.

Two layers:
  * pure tests (always run): plan building, landing page, Meta request shapes, lead parsing, reports, commands, migration static checks.
  * database tests (run when REPLICA_URL points at a scratch Postgres with every migration applied, as scripts/replica/run.sh does): the REAL engine and
    the REAL SQL through the PostgREST stand-in, each test inside one transaction that is rolled back. They prove: one approval -> launch -> post -> lead ->
    follow-up -> optimize -> report; the budget hard stop; the kill switch; dry run; opt-out; guard rejection.
"""
import hashlib
import io
import json
import os
import re
import sys
import unittest
import uuid
import zipfile
from datetime import date, datetime, timedelta
from unittest import mock

import hq
import hq_core
import hq_ffm_engine as E
import hq_ffm_run as R
import hq_hands_adapters as A

ROOT = os.path.dirname(os.path.abspath(__file__))
MIG = os.path.join(ROOT, "migrations", "20261126_ffm_run_v1.sql")
WS = {"id": "11111111-2222-4333-8444-555555555555", "slug": "maple", "name": "Maple Mortgage Team", "vertical": "mortgage"}


def pack():
    return {"schema": "ffm.pack.v1", "workspace": "maple", "vertical": "mortgage", "brief": {"offer": "Free renewal review call", "service_area": "Ottawa, Ontario"},
            "positioning": {"statement": "Calm renewals", "offer_angle": "A free review call", "differentiators": ["Local", "Clear"]},
            "audience_angles": [{"key": k, "name": f"Angle {k}", "description": "Owners renewing soon", "pain_point": "Renewal stress"} for k in "ABC"],
            "ad_sets": [{"angle": k, "name": f"Set {k}", "audience_description": "Owners renewing soon", "placement_note": ""} for k in "ABC"],
            "ad_variants": [{"id": f"V{i}", "angle": "ABC"[(i - 1) // 3], "headline": f"Renewal review {i}", "primary_text": "Book a free renewal review call.",
                             "cta": "Book Now" if i % 2 else "Learn More"} for i in range(1, 10)],
            "creative_briefs": [{"variant": f"V{i}", "format": "image", "prompt": "A calm kitchen table"} for i in range(1, 10)],
            "landing_page": {"headline": "Renew with a plan", "subheadline": "A free review call", "bullets": ["Local", "Fast", "Clear"], "cta_text": "Book my call",
                             "faq": [{"q": "How long?", "a": "About twenty minutes."}, {"q": "Cost?", "a": "Free."}], "trust_note": ""},
            "lead_form": {"fields": ["name", "email", "phone"]},
            "follow_up": [{"touch": i, "day": d, "channel": "email", "subject": "Your renewal review", "body": f"Hi {{{{first_name}}}}, {{{{business_name}}}} here, step {i}."}
                          for i, d in zip(range(1, 6), (0, 1, 3, 6, 10))],
            "organic_calendar": [{"day": i, "platform": ("facebook" if i % 2 else "instagram"), "format": "post", "hook": f"Tip {i}", "caption": f"Renewal tip number {i}."} for i in range(1, 15)],
            "kpi_targets": [{"metric": "Leads", "target": "20", "note": ""}] * 3, "status": "draft", "dry_run": True, "screened_out": []}


# ------------------------------------------------------------------------------------------------------------------- fakes
class Http:
    """Mocked Graph / Netlify API. Records every call; returns ids."""

    def __init__(self):
        self.calls, self.n = [], 0

    def __call__(self, method, url, headers=None, json_body=None, form=None, data=None, timeout=60):
        self.calls.append((method, url, dict(form or {})))
        self.n += 1
        if "/insights" in url:
            return 200, {"data": []}, {}
        if "/leads" in url:
            return 200, {"data": []}, {}
        if "search?" in url:
            return 200, {"data": [{"key": "296875", "name": "Ottawa"}]}, {}
        if "/submissions" in url:
            return 200, [], {}
        if method == "POST" and form and set(form) <= {"status", "access_token", "daily_budget"}:
            return 200, {"success": True}, {}
        return 200, {"id": f"{self.n}00{self.n}"}, {}

    def posts(self, tail):
        return [c for c in self.calls if c[0] == "POST" and c[1].endswith(tail)]


def run_exec(log):
    def run(executor, agent, task, cents, purpose, work):
        log.append((executor, agent, task, purpose))
        return {"status": "done", "dry_run": False, "result": work("run-1")[0]}
    return run


# ------------------------------------------------------------------------------------------------------------------- pure
class PlanTests(unittest.TestCase):
    def test_plan_from_pack(self):
        plan, page = R.build_plan(WS, {"pack": pack()}, {"consent_wording": "I agree to be contacted by email."}, "v1")
        self.assertEqual(len(plan["ads"]), 9)
        self.assertEqual({a["cta"] for a in plan["ads"]}, {"BOOK_NOW", "LEARN_MORE"})
        self.assertEqual(len(plan["posts"]), 14)
        self.assertEqual(len(plan["touches"]), 5)
        self.assertEqual(plan["touches"][0]["body"], "Hi there, Maple Mortgage Team here, step 1.")       # no lead data in a body, no leftover placeholder
        self.assertTrue(plan["landing"])
        self.assertEqual(plan["landing_sha256"], hashlib.sha256(page.encode()).hexdigest())
        self.assertEqual(plan["geo"], "Ottawa")

    def test_no_landing_without_consent_wording(self):
        plan, page = R.build_plan(WS, {"pack": pack()}, {}, None)
        self.assertFalse(plan["landing"])
        self.assertIsNone(page)
        self.assertNotIn("landing_sha256", plan)

    def test_blanked_copy_is_not_used(self):
        p = pack()
        p["ad_variants"][0]["headline"] = ""
        p["organic_calendar"][0]["caption"] = ""
        plan, _ = R.build_plan(WS, {"pack": p}, {}, None)
        self.assertEqual(len(plan["ads"]), 8)
        self.assertEqual(len(plan["posts"]), 13)

    def test_live_landing_page(self):
        full = E.expand(pack(), WS["name"])
        page = R.live_landing_html(full, "I agree to be contacted by email.", "v1")
        self.assertNotIn("DRAFT", page)
        self.assertIn('data-netlify="true"', page)
        self.assertIn('type="checkbox" name="consent" value="yes" required', page)
        self.assertIn('name="wording_version" value="v1"', page)
        self.assertIn("I agree to be contacted by email.", page)
        self.assertNotIn("<script", page)
        self.assertNotRegex(page, r"<form[^>]+action")
        self.assertEqual(page, R.live_landing_html(full, "I agree to be contacted by email.", "v1"))   # deterministic: the hash is what the owner approves


class MetaTests(unittest.TestCase):
    def test_everything_created_paused_with_the_cap(self):
        h = Http()
        m = R.MetaAds("s3cr3t-value", "123", h)
        self.assertEqual(m.account, "act_123")
        m.campaign("Launch", 50000, ["FINANCIAL_PRODUCTS_SERVICES"])
        m.ad_set("c1", "A", 1666, "2026-11-20T00:00:00-0500", "2026-12-19T23:59:00-0500", {"geo_locations": {"countries": ["CA"]}})
        m.ad("s1", "V1", "page1", "https://x.netlify.app", "Head", "Body", "BOOK_NOW")
        camp = h.posts("/campaigns")[0][2]
        self.assertEqual((camp["status"], camp["spend_cap"], camp["special_ad_categories"]), ("PAUSED", "50000", '["FINANCIAL_PRODUCTS_SERVICES"]'))
        s = h.posts("/adsets")[0][2]
        self.assertEqual((s["status"], s["daily_budget"]), ("PAUSED", "1666"))
        self.assertEqual(h.posts("/ads")[0][2]["status"], "PAUSED")
        self.assertTrue(all(c[1].startswith("https://graph.facebook.com/") for c in h.calls))
        self.assertNotIn("s3cr3t", repr(m.__dict__))      # the token is a Secret

    def test_token_in_header_with_appsecret_proof_never_in_the_url(self):
        import hmac as _h
        seen = []

        def h(method, url, headers=None, form=None, **kw):
            seen.append((url, headers, form))
            return 200, {"data": [], "id": "1"}, {}
        m = R.MetaAds("tok-123", "act_9", h, app_secret="shh")
        m.insights("c1", date(2026, 11, 20))
        m.set_status("c1", False)
        proof = _h.new(b"shh", b"tok-123", "sha256").hexdigest()
        for url, headers, form in seen:
            self.assertEqual(headers, {"Authorization": "Bearer tok-123"})
            self.assertNotIn("tok-123", url)
            self.assertNotIn("access_token", url + json.dumps(form or {}))
        self.assertIn("appsecret_proof=" + proof, seen[0][0])
        self.assertEqual(seen[1][2]["appsecret_proof"], proof)

    def test_insights_parsed_to_cents_and_leads(self):
        def h(method, url, **kw):
            return 200, {"data": [{"ad_id": "9", "spend": "12.34", "impressions": "1000", "clicks": "20",
                                   "actions": [{"action_type": "lead", "value": "2"}, {"action_type": "link_click", "value": "20"}]}]}, {}
        rows = R.MetaAds("t", "act_1", h).insights("c", date(2026, 11, 20))
        self.assertEqual(rows, [{"ad_id": "9", "spend_cents": 1234, "impressions": 1000, "clicks": 20, "leads": 2}])

    def test_refusal_is_a_safe_error(self):
        def h(method, url, **kw):
            return 400, {"error": {"message": "Invalid parameter"}}, {}
        with self.assertRaises(A.HandError) as c:
            R.MetaAds("secret-token", "1", h).campaign("x", 100, [])
        self.assertNotIn("secret-token", str(c.exception))

    def test_meta_lead_parsing(self):
        src, ref, fields, consent = R.meta_lead({"id": "777", "created_time": "2026-11-20T10:00:00+0000", "field_data": [
            {"name": "full_name", "values": ["Alex Doe"]}, {"name": "email", "values": ["alex@example.com"]}, {"name": "consent_email", "values": ["true"]},
            {"name": "annual_income", "values": ["90000"]}]}, "v1")
        self.assertEqual((src, ref), ("meta_form", "meta-777"))
        self.assertEqual(set(fields), {"name", "email", "phone"})          # anything else (income) is dropped unread
        self.assertTrue(consent["given"])
        self.assertEqual(consent["evidence_ref"], "meta-777")


class MiscTests(unittest.TestCase):
    def test_money(self):
        self.assertEqual(R.parse_money("$50"), 5000)
        self.assertEqual(R.parse_money("1,200.5"), 120050)
        for bad in ("0", "-3", "abc", "200000"):
            with self.assertRaises(ValueError):
                R.parse_money(bad)

    def test_sim_is_deterministic_and_has_a_loser(self):
        ads = [{"external_id": f"sim:ad:{i}", "ref": f"V{i}", "status": "active", "share_cents": 3000} for i in range(1, 10)]
        a, b = R.SimAds().insights("c", date(2026, 11, 20), ads), R.SimAds().insights("c", date(2026, 11, 20), ads)
        self.assertEqual(a, b)
        self.assertTrue(any(r["leads"] == 0 for r in a) and any(r["leads"] > 0 for r in a))

    def test_reports_label_dry_run(self):
        r = {"name": "Maple", "from": "2026-11-16", "to": "2026-11-22", "spend_cents": 4200, "spent_total_cents": 4200, "total_cap_cents": 50000, "leads": 3,
             "cpl_cents": 1400, "best_ads": [{"ref": "V1", "headline": "Renewal review 1", "leads": 2, "spend_cents": 1000, "cpl_cents": 500}], "simulated": True}
        o, c = R.owner_report(r), R.client_report(r)
        self.assertTrue(o.startswith("Sir,"))
        self.assertIn("DRY RUN", o)
        self.assertIn("$14.00", o)
        self.assertIn("do not send", c)
        self.assertIn("Renewal review 1", c)

    def test_one_idempotency_key_per_email_row(self):
        import hq_mail
        seen = []

        class Resp:
            status = 200
            def __enter__(self):
                return self
            def __exit__(self, *a):
                return False
        with mock.patch.dict(os.environ, {"RESEND_API_KEY": "k"}), mock.patch.object(hq_mail.urllib.request, "urlopen", lambda req, timeout=20: (seen.append(req), Resp())[1]):
            ok, _ = R.resend_post({"id": "e-1", "from": "a@b.example", "from_name": "A", "to": "c@d.example", "subject": "s", "body": "b", "unsubscribe": "mailto:a@b.example"})
            R.resend_post({"id": "e-1", "from": "a@b.example", "from_name": "A", "to": "c@d.example", "subject": "s", "body": "b", "unsubscribe": "mailto:a@b.example"})
        self.assertTrue(ok)
        self.assertEqual([r.get_header("Idempotency-key") for r in seen], ["ffm-email-e-1", "ffm-email-e-1"])     # a retry carries the same key
        self.assertIn('"List-Unsubscribe": "<mailto:a@b.example>"', seen[0].data.decode())

    def test_sms_is_a_stub(self):
        self.assertTrue(issubclass(R.SmsNotBuilt, A.HandError))

    def test_command_help(self):
        self.assertIn("/ffm launch", R.command("launch", [], get=lambda p: []))
        self.assertIn("not done", R.command("launch", ["maple", "abc", "10"], get=lambda p: []))

    def test_netlify_deploys_an_inline_page(self):
        sent = {}

        def http(method, url, headers=None, data=None, timeout=60, **kw):
            sent["data"], sent["url"] = data, url
            return 201, {"id": "D9"}, {}
        ctx = A.Ctx(action={"id": "a", "action": "deploy", "payload": {"html": "<!doctype html><p>hi</p>"}}, account={"external_id": "site-1"},
                    connector={"slug": "netlify"}, token=lambda: {"api_key": "k"}, http=http)
        self.assertEqual(A.ADAPTERS["netlify"].execute(ctx), "D9")
        self.assertEqual(zipfile.ZipFile(io.BytesIO(sent["data"])).read("index.html"), b"<!doctype html><p>hi</p>")
        self.assertIn("/sites/site-1/deploys", sent["url"])


class MigrationStaticTests(unittest.TestCase):
    def setUp(self):
        self.sql = open(MIG).read()

    def test_every_function_revoked_and_nothing_granted_to_api_roles(self):
        made = set(re.findall(r"create or replace function public\.(\w+)\(", self.sql))
        for f in made:
            self.assertRegex(self.sql, rf"revoke all on function public\.{f}\([^)]*\) from public, anon, authenticated", f)
        self.assertNotRegex(self.sql, r"grant [^;]* to [^;]*(anon|authenticated|public)\b")

    def test_meta_ads_connector_disabled_and_actionless(self):
        row = self.sql[self.sql.index("insert into public.hand_connectors"):self.sql.index("on conflict (slug) do nothing")]
        self.assertIn("'meta-ads'", row)
        self.assertIn("'{}'", row)
        self.assertNotIn("enabled", row)                 # column default: false

    def test_no_control_is_touched(self):
        body = re.sub(r"--[^\n]*", "", self.sql)
        for bad in ("update public.system_state", "update system_state", "executor_registry (", "daily_spend_cap", "kill_switch =", "app_owners", "ffm_set_budget(",
                    "drop function", "drop table", "alter table public.outbox", "update public.client_workspaces"):
            self.assertNotIn(bad, body, bad)


# ------------------------------------------------------------------------------------------------------------------- database (real SQL)
REPLICA = os.environ.get("REPLICA_URL")
try:
    import psycopg2  # noqa: F401
    HAVE_PG = True
except ImportError:
    HAVE_PG = False


@unittest.skipUnless(REPLICA and HAVE_PG, "needs REPLICA_URL (scratch Postgres with all migrations) and psycopg2; scripts/replica/run.sh runs these")
class DbTests(unittest.TestCase):
    """Real SQL, one transaction per test (rolled back). The owner's tap is simulated exactly as hq_commands.apply_decision records it."""

    @classmethod
    def setUpClass(cls):
        sys.path.insert(0, os.path.join(ROOT, "scripts", "replica"))
        from pg_adapter import PgAdapter
        import psycopg2.extensions as ext

        class Arr:              # a text[] argument (PostgREST turns a JSON array into a Postgres array; the test adapter would send JSON text)
            def __init__(self, items):
                self.items = items
        ext.register_adapter(Arr, lambda a: ext.adapt(a.items))

        class TxAdapter(PgAdapter):
            """Every statement in a savepoint, so an expected refusal does not abort the test's transaction."""
            def sql(self, query, params=None, dec=False):
                self.conn.cursor().execute("savepoint ffm_t")
                try:
                    r = super().sql(query, params, dec)
                except Exception:
                    self.conn.cursor().execute("rollback to savepoint ffm_t")
                    raise
                self.conn.cursor().execute("release savepoint ffm_t")
                return r

            def __call__(self, method, path, body=None, **kw):
                if "/rpc/" in path and isinstance(body, dict):
                    body = {k: (Arr(v) if isinstance(v, list) and all(isinstance(x, str) for x in v) else v) for k, v in body.items()}
                return super().__call__(method, path, body, **kw)
        cls.db = TxAdapter(REPLICA)
        cls.db.conn.autocommit = False

    @classmethod
    def tearDownClass(cls):
        cls.db.conn.rollback()
        cls.db.conn.close()

    def setUp(self):
        self.db.conn.rollback()
        self.p = mock.patch.object(hq, "_request", self.db)
        self.p.start()
        self.p2 = mock.patch.object(R, "REPORT_HOUR", 25)        # no automatic Monday report inside a test tick
        self.p2.start()
        self.sql("update public.system_state set kill_switch = false, mode = 'dry_run' where id = 1")
        self.today = datetime.now(hq_core.TZ).date()
        self.now = datetime.combine(self.today, datetime.min.time(), hq_core.TZ).replace(hour=11)
        self.slug = "maple-test"          # every test is rolled back, so one fixed slug is enough (letters only: a digit run would trip the guard)
        self.ws = E._call("ffm_engine_create_workspace", {"p_slug": self.slug, "p_name": "Maple Mortgage Team", "p_vertical": "mortgage", "p_by": "owner:telegram"})
        camp = E._call("ffm_add_campaign", {"p_ws": self.ws, "p_name": "Campaign draft", "p_channel": "meta"})
        p = pack()
        p["workspace"] = self.slug
        self.pack_id = E._call("ffm_engine_save_pack", {"p_ws": self.ws, "p_vertical": "mortgage", "p_pack": p, "p_campaign": camp, "p_cost_cents": 1,
                                                        "p_model": "claude-haiku-5-5", "p_by": "ffm-engine"})["id"]
        for k, v in (("consent_wording", "I agree to receive emails about my renewal review."), ("booking_link", "https://cal.example.com/maple")):
            E._call("ffm_provide_input", {"p_ws": self.ws, "p_key": k, "p_value": v, "p_by": "client"})
        self.sql("insert into public.ffm_consent_wordings (workspace_id, version, sha256, registered_by) values (%s, 'v1', %s, 'owner')", (self.ws, "b" * 64))
        self.sql("update public.client_workspaces set monthly_budget_cents = 500000 where id = %s", (self.ws,))       # (the owner-only ffm_set_budget in production)
        R.command("sender", [self.slug, "hello@maplemortgage.example", "|", "Sam", "Lee", "|", "Maple", "Mortgage", "Team", "|", "100", "Main", "Street,", "Ottawa", "ON"])
        self.sent, self.mails, self.attests = [], [], []

    def tearDown(self):
        self.p.stop()
        self.p2.stop()
        self.db.conn.rollback()

    def sql(self, q, params=None):
        return self.db.sql(q, params)

    def engine(self, **kw):
        kw.setdefault("now", self.now)
        kw.setdefault("send_owner", lambda body, kind="brief": self.sent.append((kind, body)))
        kw.setdefault("executor_run", run_exec([]))
        kw.setdefault("authorize", lambda ref: True)
        kw.setdefault("mail_post", lambda c: (self.mails.append(c) or True, f"re_{len(self.mails)}"))
        kw.setdefault("attest", lambda: (self.attests.append(1) or {"ok": True}))
        return R.Engine(**kw)

    def propose(self, daily="$30", total="$300", days="30"):
        return R.command("launch", [self.slug, daily, total, days], now=self.now)

    def msg(self, ref="ffm_run_budgets"):
        return self.sql("select * from public.owner_messages where ref_table = %s and decision is null order by created_at desc limit 1", (ref,))[0]

    def tap(self, approved=True, ref="ffm_run_budgets"):
        """The owner's real tap: hq_commands.apply_decision (the owner-only handler behind the Telegram button and the PWA's Approve)."""
        import hq_commands
        with mock.patch.object(hq_commands, "_record_decision_memory"):
            return hq_commands.apply_decision(self.msg(ref)["id"], approved)

    def launch(self):
        return self.sql("select * from public.ffm_run_launches where workspace_id = %s order by created_at desc limit 1", (self.ws,))[0]

    def receipts(self, step=None):
        return self.sql("select * from public.ffm_run_receipts where launch_id = %s" + (" and step = %s" if step else "") + " order by id",
                        (self.launch()["id"],) + ((step,) if step else ()))

    def consent_allowed(self):
        """Stand-in for a verified express capture + open outreach gate (that subsystem has its own tests): rolled back with the test."""
        self.sql("""create or replace function public.ffm_contact_status(p_lead uuid, p_channel text) returns jsonb language plpgsql stable security definer
                    set search_path to 'public' as $$ begin
                      if exists (select 1 from public.ffm_consent_log where lead_id = p_lead and basis = 'withdrawn') then return '{"allowed": false, "reason": "withdrawn"}'; end if;
                      return '{"allowed": true, "reason": "express"}'; end $$""")

    def go_live(self):
        self.sql("update public.system_state set mode = 'auto_in_caps' where id = 1")
        self.sql("update public.hand_connectors set enabled = true where slug in ('meta-ads', 'meta-facebook', 'netlify')")
        self.sql("update public.client_workspaces set status = 'active' where id = %s", (self.ws,))
        self.sql("insert into public.executor_registry (slug, kind, enabled, max_cents_per_run, max_runs_per_day, allowed_agents, note) values "
                 "('hands-actions', 'hands', true, 1, 100, array['jarvis-hands'], 'test') on conflict (slug) do update set enabled = true")
        ref = str(uuid.uuid4())
        for conn, handle, ext in (("meta-ads", "maple_ads", "act_42"), ("meta-facebook", "maple_page", "5150"), ("netlify", "maple-site", "site-77")):
            self.sql("insert into public.hand_accounts (connector, division, handle, purpose, status, token_vault_ref, external_id) values (%s, 'ffm', %s, 'connected by the owner', "
                     "'connected', %s, %s)", (conn, handle + uuid.uuid4().hex[:4], ref, ext))

    def live_launch(self, daily="$30", total="$300"):
        """go live, propose, tap, one tick with mocked Meta / Netlify -> (engine, http)"""
        self.consent_allowed()
        self.go_live()
        self.propose(daily, total)
        self.tap()
        h = Http()
        eng = self.engine(http=h, token=lambda ref: {"access_token": "tok-SECRET", "api_key": "k"})
        eng.tick()
        return eng, h

    def lead(self, eng, ref="nf-live1", email="sam@example.com"):
        return eng.intake(self.launch(), "landing", ref, {"name": "Sam Lee", "email": email},
                          {"given": True, "wording_version": "v1", "captured_at": self.now.isoformat(), "evidence_ref": ref})

    def objs(self):
        return self.sql("select * from public.ffm_run_objects where launch_id = %s", (self.launch()["id"],))

    # ---- B1: one approval, and only the real one
    def test_one_tap_approval_and_nothing_before_it(self):
        out = self.propose()
        self.assertIn("one tap", out)
        msg = self.msg()
        self.assertTrue(msg["needs_decision"])
        for t in ("Sir,", "Daily budget: $30.00 on average", "75% more", "Total cap: $300.00 = the hard stop", "Meta (Facebook + Instagram), 9 ads in 3 ad sets",
                  "Organic posts: 14 on facebook, instagram", "/ffm plan", "runs as DRY RUN", "launch again", str(self.today)):
            self.assertIn(t, msg["body"])
        plan = R.command("plan", [self.launch()["id"][:8]])
        self.assertEqual(plan.count("Renewal review "), 9)                 # every ad
        self.assertIn("P14 day 14", plan)                                 # every post
        self.assertIn("5 day 10", plan)                                   # every email
        self.engine().tick()
        self.assertEqual(self.launch()["status"], "proposed")
        self.assertEqual(self.receipts(), [])
        self.assertIn("Rejected", self.tap(False))
        self.engine().tick()
        self.assertEqual(self.launch()["status"], "rejected")
        self.assertEqual(self.receipts(), [])

    def test_forged_decision_is_not_an_approval(self):
        self.propose()
        self.sql("update public.owner_messages set decision = 'approved', decided_at = now() where ref_table = 'ffm_run_budgets'")   # a forged decision column
        self.engine().tick()
        self.assertEqual(self.launch()["status"], "proposed")
        self.assertEqual(self.receipts(), [])
        b = self.sql("select id, owner_message_id, approval_nonce from public.ffm_run_budgets where launch_id = %s", (self.launch()["id"],))[0]
        with self.assertRaisesRegex(RuntimeError, "wrong nonce"):
            E._call("ffm_run_owner_decide", {"p_message": b["owner_message_id"], "p_nonce": "0" * 64, "p_approved": True, "p_by": "owner:telegram"})
        self.assertIn("Approved", R.decide(b["owner_message_id"], True))
        self.assertEqual(self.launch()["status"], "approved")
        self.assertIn("already decided", R.decide(b["owner_message_id"], True))          # single use
        with self.assertRaisesRegex(RuntimeError, "monthly budget first"):
            self.sql("update public.client_workspaces set monthly_budget_cents = null where id = %s", (self.ws,))
            R.command("stop", [self.slug], now=self.now)
            E._call("ffm_run_propose", {"p_ws": self.ws, "p_pack": self.pack_id, "p_daily": 1000, "p_total": 20000, "p_starts": self.today.isoformat(),
                                        "p_ends": self.today.isoformat(), "p_paid": [], "p_organic": [], "p_plan": self.launch()["plan"], "p_by": "owner:telegram"})

    # ---- the whole loop in dry run
    def test_dry_run_full_loop(self):
        self.consent_allowed()
        self.propose()
        self.tap()
        eng = self.engine()
        eng.tick()
        l = self.launch()
        self.assertEqual(l["status"], "running")
        self.assertTrue(l["dry_run"])
        rec = {(r["step"], r["item"]): r for r in self.receipts()}
        self.assertTrue(rec[("launch", "ads")]["ok"] and rec[("launch", "ads")]["simulated"])
        self.assertIn("DRY RUN", rec[("launch", "ads")]["detail"])
        self.assertTrue(rec[("deploy", "landing")]["simulated"])
        self.assertIn("would post on facebook", rec[("post", "P1")]["detail"])
        objs = self.objs()
        self.assertEqual(sorted(o["level"] for o in objs).count("ad"), 9)
        self.assertTrue(all(o["status"] == "active" and o["simulated"] for o in objs))
        self.assertLessEqual(sum(o["daily_cents"] or 0 for o in objs), 3000)
        self.assertTrue(rec[("metrics", self.now.strftime("%Y-%m-%dT%H"))]["simulated"])
        r = eng.intake(l, "landing", "nf-abc123", {"name": "Alex Doe", "email": "alex@example.com", "phone": "613-555-0142", "income": "secret"},
                       {"given": True, "wording_version": "v1", "captured_at": self.now.isoformat(), "evidence_ref": "nf-abc123"})
        self.assertTrue(r["ok"])
        lead = r["lead_id"]
        self.assertEqual(self.sql("select status, email_id from public.ffm_run_touches where lead_id = %s", (lead,)), [{"status": "simulated", "email_id": None}])
        self.assertEqual(self.sql("select basis from public.ffm_consent_log where lead_id = %s", (lead,))[0]["basis"], "unverified")
        self.assertEqual(self.sql("select stage from public.ws_leads where id = %s", (lead,))[0]["stage"], "contacted")
        self.assertEqual(eng.intake(l, "landing", "nf-abc123", {"name": "Alex Doe", "email": "alex@example.com"}, {})["duplicate"], True)
        self.sql("update public.ffm_run_leads set next_due_at = least(now(), %s::timestamptz) - interval '1 minute' where lead_id = %s", (self.now, lead))
        self.engine().work_leads(l)
        self.assertEqual(self.sql("select count(*) c from public.ffm_run_touches where lead_id = %s", (lead,))[0]["c"], 2)
        ads = {o["plan_ref"]: o["id"] for o in objs if o["level"] == "ad"}
        y = (self.today - timedelta(days=1)).isoformat()
        for ref, spend, leads in (("V1", 2000, 4), ("V2", 2000, 0), ("V4", 2000, 1), ("V7", 2000, 1)):
            E._call("ffm_run_put_metrics", {"p_object": ads[ref], "p_day": y, "p_spend": spend, "p_impressions": 1, "p_clicks": 1, "p_leads": leads, "p_simulated": True})
        self.engine().optimize(self.launch(), self.today + timedelta(days=1))
        st = {o["plan_ref"]: o for o in self.objs() if o["level"] != "campaign"}
        self.assertEqual(st["V2"]["status"], "paused")
        self.assertEqual(st["V1"]["status"], "active")
        self.assertLessEqual(sum(s["daily_cents"] for s in st.values() if s["level"] == "ad_set" and s["status"] == "active"), 3000)
        self.assertGreater(st["A"]["daily_cents"], st["B"]["daily_cents"])
        self.assertIn("paused V2", self.receipts("optimize")[-1]["detail"])
        self.engine().weekly_report(l, self.today + timedelta(days=1))
        self.assertEqual([k for k, _ in self.sent], ["brief", "brief"])
        self.assertIn("DRY RUN", self.sent[0][1])
        self.assertIn("do not send", self.sent[1][1])
        self.assertTrue(all(r["simulated"] for r in self.receipts()))
        self.assertEqual(self.sql("select count(*) c from public.hand_actions where created_by = 'ffm-run'")[0]["c"], 0)
        self.assertEqual(self.sql("select count(*) c from public.ffm_run_emails")[0]["c"], 0)
        self.assertEqual(self.mails, [])
        # a dry-run launch stays simulated after the mode is switched: no real call, no email
        self.go_live()
        h = Http()
        self.engine(http=h, token=lambda ref: {"access_token": "t", "api_key": "k"}).tick()
        self.assertEqual([c for c in h.calls if c[0] == "POST"], [])
        self.assertEqual(self.mails, [])

    # ---- live mode with mocked platforms, and B5: the client's own sender
    def test_live_mode_mocked_platforms_and_client_sender(self):
        eng, h = self.live_launch()
        l = self.launch()
        self.assertFalse(l["dry_run"])
        self.assertTrue(l["landing_url"].startswith("https://maple-site") and l["landing_url"].endswith(".netlify.app"))
        self.assertEqual(self.sql("select action, status, approval_kind from public.hand_actions where created_by = 'ffm-run' order by action"),
                         [{"action": "deploy", "status": "approved", "approval_kind": "owner"}, {"action": "post", "status": "approved", "approval_kind": "owner"}])
        camp = h.posts("/campaigns")[0][2]
        self.assertEqual((camp["status"], camp["spend_cap"]), ("PAUSED", "30000"))
        self.assertEqual(sum(1 for c in h.calls if c[2].get("status") == "ACTIVE"), 13)
        self.assertFalse(any("access_token" in c[1] or "access_token" in c[2] or "tok-SECRET" in c[1] for c in h.calls))     # token only in the header
        self.assertFalse(self.receipts("launch")[0]["simulated"])
        r = self.lead(eng)
        em = self.sql("select * from public.ffm_run_emails where lead_id = %s", (r["lead_id"],))[0]
        self.assertEqual(em["status"], "queued")
        for t in ("Book a time: https://cal.example.com/maple", "Sam Lee, Maple Mortgage Team", "100 Main Street, Ottawa ON",
                  "Unsubscribe: mailto:hello@maplemortgage.example?subject=unsubscribe"):
            self.assertIn(t, em["body"])
        self.assertNotIn("Donna", em["body"])
        self.assertEqual(self.sql("select count(*) c from public.outbox where idempotency_key like 'ffm:%%'")[0]["c"], 0)       # not the legacy path
        # automatic sending is OFF by default: one owner message for the launch lists the waiting email; nothing goes before his tap
        eng = self.engine()
        self.assertEqual(eng.send_emails(), 0)
        self.assertEqual(self.mails, [])
        batch = self.msg("ffm_run_email_batches")
        self.assertEqual(batch["ref_table"], "ffm_run_email_batches")
        self.assertIn("1 follow-up email(s) for Maple Mortgage Team wait for your tap", batch["body"])
        self.assertIn("s***@example.com", batch["body"])
        self.assertNotIn("sam@example.com", batch["body"])
        self.assertEqual(eng.send_emails(), 0)                                                     # still one open batch, no second message
        self.assertEqual(self.sql("select count(*) c from public.owner_messages where ref_table = 'ffm_run_email_batches'")[0]["c"], 1)
        self.assertIn("Approved: 1 email", self.tap(ref="ffm_run_email_batches"))
        self.attests.clear()
        self.assertEqual(eng.send_emails(), 1)
        self.assertEqual(len(self.attests), 1)                                                     # the sender's gate mark: once per batch
        self.assertEqual(self.mails[0]["id"], em["id"])                                            # the Idempotency-Key is per email row
        self.assertEqual(self.mails[0]["from"], "hello@maplemortgage.example")
        self.assertEqual(self.mails[0]["unsubscribe"], "mailto:hello@maplemortgage.example?subject=unsubscribe")
        self.assertEqual(self.sql("select status from public.ffm_run_emails where id = %s", (em["id"],))[0]["status"], "sent")
        # the send-time re-check: a second lead opts out between queueing and sending -> nothing is sent
        r2 = self.lead(eng, "nf-live2", "kim@example.com")
        out = R.command("lead", [r2["lead_id"][:8], "stop"])
        self.assertIn("consent withdrawn", out)
        self.assertEqual(eng.send_emails(), 0)
        self.assertEqual(self.sql("select status from public.ffm_run_emails where lead_id = %s", (r2["lead_id"],))[0]["status"], "withdrawn")
        self.assertTrue(self.sql("select public.is_suppressed('kim@example.com') s")[0]["s"])
        # the owner switches automatic sending on: the next email goes without a tap; with the gate mark failing nothing goes at all
        self.assertIn("ON", R.command("autosend", [self.slug, "on"]))
        r4 = self.lead(eng, "nf-live4", "max@example.com")
        self.assertEqual(self.engine(attest=lambda: {"ok": False, "reason": "hwm_unavailable"}).send_emails(), 0)
        self.assertEqual(self.engine().send_emails(), 1)
        self.assertEqual(self.sql("select status from public.ffm_run_emails where lead_id = %s", (r4["lead_id"],))[0]["status"], "sent")
        with self.assertRaisesRegex(RuntimeError, "only the owner"):
            E._call("ffm_run_set_autosend", {"p_ws": self.ws, "p_on": True, "p_by": "jarvis"})
        # policy says no -> nothing sent
        r3 = self.lead(eng, "nf-live3", "lee@example.com")
        self.assertEqual(self.engine(authorize=lambda ref: False).send_emails(), 0)
        self.assertEqual(self.sql("select status from public.ffm_run_emails where lead_id = %s", (r3["lead_id"],))[0]["status"], "queued")

    # ---- B2: pause and stop really pause, whatever else is off; never claim it without Meta's answer
    def test_stop_pauses_real_ads_first_even_with_everything_off(self):
        eng, h = self.live_launch()
        self.sql("update public.system_state set mode = 'dry_run', kill_switch = true where id = 1")
        self.sql("update public.hand_connectors set enabled = false where slug = 'meta-ads'")
        self.sql("update public.executor_registry set enabled = false where slug = 'hands-actions'")
        self.sql("update public.client_workspaces set status = 'paused' where id = %s", (self.ws,))
        bad = Http()
        bad_calls = []

        def failing(method, url, **kw):
            bad_calls.append(url)
            return 500, {"error": {"message": "temporarily unavailable"}}, {}
        import hq_hands
        with mock.patch.object(A, "http", failing), mock.patch.object(hq_hands, "_load_token", return_value={"access_token": "t"}):
            out = R.command("stop", [self.slug], now=self.now)
        self.assertIn("did NOT confirm", out)
        self.assertNotIn("paused on Meta (confirmed)", out)
        self.assertEqual(self.launch()["status"], "done")
        self.assertTrue(any(o["status"] == "active" for o in self.objs() if not o["simulated"]))      # the books do not pretend
        self.assertFalse(self.receipts("pause")[-1]["ok"])
        # the next tick retries the pause for the stopped launch, and it works this time
        ok = Http()
        self.engine(http=ok, token=lambda ref: {"access_token": "t", "api_key": "k"}).tick()
        self.assertEqual([c[2].get("status") for c in ok.calls if c[0] == "POST"], ["PAUSED"])
        self.assertTrue(all(o["status"] == "paused" for o in self.objs()))
        self.assertTrue(self.receipts("pause")[-1]["ok"])
        self.assertIn("confirmed", self.receipts("pause")[-1]["detail"])

    def test_kill_switch(self):
        eng, h = self.live_launch()
        l = self.launch()
        n_rec = len(self.receipts())
        self.sql("update public.system_state set kill_switch = true where id = 1")
        h2 = Http()
        self.engine(http=h2, token=lambda ref: {"access_token": "t", "api_key": "k"}).tick()
        self.assertEqual([(c[0], c[2].get("status")) for c in h2.calls], [("POST", "PAUSED")])
        self.assertTrue(all(o["status"] == "paused" for o in self.objs()))
        self.assertEqual([r["step"] for r in self.receipts()[n_rec:]], ["pause"])
        self.assertEqual(E._call("ffm_run_gate", {"p_launch": l["id"], "p_step": "followup", "p_connector": None})["reason"], "kill switch is on")
        r = self.lead(self.engine(), "nf-kill1", "kim@example.com")
        self.assertEqual(self.sql("select count(*) c from public.ffm_run_touches where lead_id = %s", (r["lead_id"],))[0]["c"], 0)
        self.assertEqual(self.engine().send_emails(), 0)
        self.assertEqual(self.mails, [])

    def test_kill_switch_off_resumes_only_what_the_kill_switch_paused(self):
        eng, h = self.live_launch()
        self.sql("update public.system_state set kill_switch = true where id = 1")
        self.engine(http=Http(), token=lambda ref: {"access_token": "t", "api_key": "k"}).tick()
        self.assertTrue(all(o["status"] == "paused" for o in self.objs()))
        self.sql("update public.system_state set kill_switch = false where id = 1")
        h2 = Http()
        self.engine(http=h2, token=lambda ref: {"access_token": "t", "api_key": "k"}, now=self.now.replace(hour=12)).tick()
        self.assertTrue(all(o["status"] == "active" for o in self.objs()))
        self.assertEqual(sum(1 for c in h2.calls if c[2].get("status") == "ACTIVE"), 13)
        self.assertTrue(self.receipts("resume")[-1]["item"].startswith("kill:"))
        # a stop is never undone by this: pause by /ffm stop, then nothing resumes
        R.command("stop", [self.slug], now=self.now)
        h3 = Http()
        self.engine(http=h3, token=lambda ref: {"access_token": "t", "api_key": "k"}, now=self.now.replace(hour=13)).tick()
        self.assertFalse(any(c[2].get("status") == "ACTIVE" for c in h3.calls))

    def test_failed_decision_releases_the_tap(self):
        self.propose()
        m = self.msg()
        self.assertIn("Approved", self.tap())
        import hq_commands
        self.sql("update public.owner_messages set decision = null, decided_at = null where id = %s", (m["id"],))   # a second tap on the same message
        with mock.patch.object(hq_commands, "_record_decision_memory"):
            out = hq_commands.apply_decision(m["id"], True)
        self.assertIn("already decided", out)
        self.assertIsNone(self.sql("select decision from public.owner_messages where id = %s", (m["id"],))[0]["decision"])

    # ---- B3: a real campaign is never given simulated numbers
    def test_real_campaign_numbers_come_from_meta_even_when_not_live(self):
        eng, h = self.live_launch()
        self.sql("update public.system_state set mode = 'dry_run' where id = 1")                       # gate no longer live
        self.sql("delete from public.ffm_run_metrics where launch_id = %s", (self.launch()["id"],))
        ad = next(o for o in self.objs() if o["level"] == "ad")

        def insights(method, url, headers=None, **kw):
            if "/insights" in url:
                return 200, {"data": [{"ad_id": ad["external_id"], "spend": "7.50", "impressions": "100", "clicks": "3", "actions": []}]}, {}
            return 200, {"data": []}, {}
        later = self.now.replace(hour=12)
        self.engine(http=insights, token=lambda ref: {"access_token": "t"}, now=later).metrics(self.launch(), self.today)
        rows = self.sql("select spend_cents, simulated from public.ffm_run_metrics where launch_id = %s", (self.launch()["id"],))
        self.assertTrue(rows and all(not r["simulated"] for r in rows))
        self.assertEqual(sum(r["spend_cents"] for r in rows), 750 * len([d for d in (self.today - timedelta(days=1), self.today) if d >= self.today]))
        # no token to read with -> skipped, still nothing simulated
        self.sql("update public.hand_accounts set status = 'disabled' where connector = 'meta-ads'")
        self.engine(now=self.now.replace(hour=13)).metrics(self.launch(), self.today)
        self.assertFalse(any(r["simulated"] for r in self.sql("select simulated from public.ffm_run_metrics where launch_id = %s", (self.launch()["id"],))))

    # ---- B4: a new budget is applied on Meta (spend cap first, cuts) before anything resumes
    def test_new_budget_updates_spend_cap_and_cuts_before_resume(self):
        eng, h = self.live_launch(daily="$30", total="$300")
        l = self.launch()
        ad = next(o for o in self.objs() if o["level"] == "ad")
        E._call("ffm_run_put_metrics", {"p_object": ad["id"], "p_day": self.today.isoformat(), "p_spend": 30000, "p_impressions": 1, "p_clicks": 1, "p_leads": 0, "p_simulated": False})
        self.assertEqual(self.launch()["status"], "capped")
        self.engine(http=Http(), token=lambda ref: {"access_token": "t", "api_key": "k"}, now=self.now.replace(hour=12)).tick()
        self.assertTrue(all(o["status"] == "paused" for o in self.objs()))
        with self.assertRaisesRegex(RuntimeError, "above what is already spent"):
            E._call("ffm_run_request_budget", {"p_launch": l["id"], "p_daily": 1000, "p_total": 30000, "p_by": "owner:telegram"})
        R.command("budget", [self.slug, "$10", "$400"])
        self.tap()
        self.assertEqual(self.launch()["status"], "running")
        calls = []

        def meta(method, url, headers=None, form=None, **kw):
            calls.append((method, url.split("?")[0].rsplit("/", 1)[-1] if "?" in url else url.rsplit("/", 1)[-1], dict(form or {})))
            if "/insights" in url:
                return 200, {"data": [{"spend": "310.00"}]}, {}
            if method == "POST":
                return 200, {"success": True}, {}
            return 200, {"data": []}, {}
        self.engine(http=meta, token=lambda ref: {"access_token": "t", "api_key": "k"}, now=self.now.replace(hour=13)).tick()
        posts = [c for c in calls if c[0] == "POST"]
        self.assertEqual(posts[0][2].get("spend_cap"), "40000")                                  # 1. the cap first (above the $310 Meta reports)
        budget_cuts = [i for i, c in enumerate(posts) if "daily_budget" in c[2]]
        switch_on = [i for i, c in enumerate(posts) if c[2].get("status") == "ACTIVE"]
        self.assertTrue(budget_cuts and switch_on and max(budget_cuts) < min(switch_on))         # 2. cuts before any resume
        sets = [o for o in self.objs() if o["level"] == "ad_set" and o["status"] != "stopped"]
        self.assertLessEqual(sum(o["daily_cents"] for o in sets), 1000)
        self.assertTrue(all(int(c[2]["daily_budget"]) <= 1000 for c in posts if "daily_budget" in c[2]))
        self.assertTrue(any(o["status"] == "active" for o in self.objs()))                         # resumed, inside the new numbers

    def test_budget_hard_stop(self):
        self.propose(daily="$10", total="$100", days="10")
        self.tap()
        eng = self.engine()
        eng.launch_ads(self.launch())
        l = self.launch()
        objs = {o["plan_ref"]: o for o in self.objs()}
        with self.assertRaisesRegex(RuntimeError, "approved daily budget"):
            E._call("ffm_run_set_object", {"p_object": objs["A"]["id"], "p_status": "active", "p_daily": 900})
        with self.assertRaisesRegex(RuntimeError, "approved daily budget"):
            E._call("ffm_run_put_object", {"p_launch": l["id"], "p_level": "ad_set", "p_ref": "Z", "p_parent": objs["campaign"]["id"], "p_external": "sim:z", "p_status": "paused",
                                           "p_daily": 500, "p_simulated": True})
        with self.assertRaisesRegex(Exception, "immutable"):
            self.sql("update public.ffm_run_budgets set total_cap_cents = 999999 where launch_id = %s", (l["id"],))
        E._call("ffm_run_put_metrics", {"p_object": objs["V1"]["id"], "p_day": self.today.isoformat(), "p_spend": 10100, "p_impressions": 1, "p_clicks": 1, "p_leads": 0, "p_simulated": True})
        self.assertEqual(self.launch()["status"], "capped")
        self.engine().tick()
        self.assertTrue(all(o["status"] == "paused" for o in self.objs()))
        self.assertEqual([k for k, _ in self.sent], ["money"])
        self.assertIn("/ffm budget", self.sent[0][1])
        self.engine().tick()
        self.assertEqual(len(self.sent), 1)
        with self.assertRaisesRegex(RuntimeError, "launch is capped"):
            E._call("ffm_run_set_object", {"p_object": objs["A"]["id"], "p_status": "active", "p_daily": None})
        self.assertEqual(E._call("ffm_run_gate", {"p_launch": l["id"], "p_step": "post", "p_connector": None})["reason"], "launch is capped")
        R.command("budget", [self.slug, "$10", "$400"])
        self.assertEqual(self.launch()["status"], "capped")
        self.assertEqual(E._call("ffm_run_budget", {"p_launch": l["id"]})["total_cap_cents"], 10000)
        self.tap()
        self.engine().tick()
        self.assertEqual(E._call("ffm_run_budget", {"p_launch": l["id"]})["total_cap_cents"], 40000)
        self.assertEqual(self.launch()["status"], "running")
        self.assertTrue(any(o["status"] == "active" for o in self.objs()))

    def test_guard_rejection(self):
        self.propose()
        self.tap()
        self.engine().tick()
        l = self.launch()
        eng = self.engine()
        bad = eng.intake(l, "landing", "nf-bad1", {"name": "Alex, SIN 046 454 286", "email": "alex@example.com"},
                         {"given": True, "wording_version": "v1", "captured_at": self.now.isoformat(), "evidence_ref": "nf-bad1"})
        self.assertFalse(bad["ok"])
        self.assertEqual(self.sql("select count(*) c from public.ws_leads where workspace_id = %s", (self.ws,))[0]["c"], 0)
        self.assertIn("sensitive", self.receipts("intake")[-1]["detail"])
        self.assertTrue(eng.done(l, "intake", "nf-bad1"))                                            # recorded once; the poller skips it from now on
        no_consent = eng.intake(l, "landing", "nf-bad2", {"name": "Alex", "email": "alex@example.com"}, {"given": False})
        self.assertFalse(no_consent["ok"])
        self.assertIn("consent is required", no_consent["reason"])
        ok = eng.intake(l, "landing", "nf-ok1", {"name": "Alex", "email": "alex@example.com"},
                        {"given": True, "wording_version": "v1", "captured_at": self.now.isoformat(), "evidence_ref": "nf-ok1"})
        self.assertEqual(self.sql("select status from public.ffm_run_touches where lead_id = %s", (ok["lead_id"],))[0]["status"], "skipped")
        self.assertEqual(self.sql("select status from public.ffm_run_leads where lead_id = %s", (ok["lead_id"],))[0]["status"], "needs_consent")
        self.assertEqual(E._call("ffm_run_submit_hand", {"p_launch": l["id"], "p_item": "P1", "p_connector": "meta-facebook", "p_action": "post",
                                                         "p_payload": {"text": "Something else entirely"}})["ok"], False)
        R.command("stop", [self.slug], now=self.now)
        plan = json.loads(json.dumps(l["plan"]))
        plan["posts"][0]["text"] = "Send us your bank statement and credit report"
        with self.assertRaises(E.SensitiveDataRefused):
            E._call("ffm_run_propose", {"p_ws": self.ws, "p_pack": self.pack_id, "p_daily": 1000, "p_total": 20000, "p_starts": self.today.isoformat(),
                                        "p_ends": self.today.isoformat(), "p_paid": ["meta"], "p_organic": ["facebook"], "p_plan": plan, "p_by": "owner:telegram"})

    def test_only_owner_ends_early_and_one_launch_at_a_time(self):
        self.propose()
        self.tap()
        self.engine().tick()
        l = self.launch()
        with self.assertRaisesRegex(RuntimeError, "already has a launch"):
            E._call("ffm_run_propose", {"p_ws": self.ws, "p_pack": self.pack_id, "p_daily": 1000, "p_total": 20000, "p_starts": self.today.isoformat(),
                                        "p_ends": self.today.isoformat(), "p_paid": ["meta"], "p_organic": [], "p_plan": l["plan"], "p_by": "owner:telegram"})
        with self.assertRaisesRegex(RuntimeError, "only the owner"):
            E._call("ffm_run_stop", {"p_launch": l["id"], "p_by": "jarvis"})
        out = R.command("stop", [self.slug], now=self.now)
        self.assertIn("No live ads were running (dry run)", out)
        self.assertEqual(self.launch()["status"], "done")
        self.assertIn("at least $100.00", R.command("launch", [self.slug, "$10", "$50"], now=self.now))
        R.command("launch", [self.slug, "$10", "$200", "45"], now=self.now)                             # 45 days asked: one tap covers 30
        nl = self.launch()
        self.assertEqual((date.fromisoformat(nl["ends_on"]) - date.fromisoformat(nl["starts_on"])).days, 29)


if __name__ == "__main__":
    unittest.main()
