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
        self.sent = []

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
        return R.Engine(**kw)

    def propose(self, daily="$30", total="$300", days="30"):
        return R.command("launch", [self.slug, daily, total, days], now=self.now)

    def tap(self, approved=True):
        """What hq_commands.apply_decision writes when the owner taps (owner-only handler)."""
        self.sql("update public.owner_messages set decision = %s, decided_at = now() where ref_table = 'ffm_run_budgets' and decision is null",
                 ("approved" if approved else "rejected",))

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

    # ---- one approval
    def test_one_tap_approval_and_nothing_before_it(self):
        out = self.propose()
        self.assertIn("one tap", out)
        msg = self.sql("select * from public.owner_messages where ref_table = 'ffm_run_budgets' and decision is null")[0]
        self.assertTrue(msg["needs_decision"])
        for s in ("Sir,", "Daily budget: $30.00", "Total cap: $300.00", "Meta (Facebook + Instagram), 9 ads in 3 ad sets", "Organic posts: 14 on facebook, instagram",
                  "First ad:", "First post:", "dry-run mode", str(self.today)):
            self.assertIn(s, msg["body"])
        self.engine().tick()
        self.assertEqual(self.launch()["status"], "proposed")
        self.assertEqual(self.receipts(), [])
        self.tap(False)
        self.engine().tick()
        self.assertEqual(self.launch()["status"], "rejected")
        self.assertEqual(self.receipts(), [])

    # ---- the whole loop in dry run
    def test_dry_run_full_loop(self):
        self.consent_allowed()
        self.propose()
        self.tap()
        eng = self.engine()
        eng.tick()
        l = self.launch()
        self.assertEqual(l["status"], "running")
        rec = {(r["step"], r["item"]): r for r in self.receipts()}
        self.assertTrue(rec[("launch", "ads")]["ok"] and rec[("launch", "ads")]["simulated"])
        self.assertIn("DRY RUN", rec[("launch", "ads")]["detail"])
        self.assertTrue(rec[("deploy", "landing")]["simulated"])
        self.assertIn("would post on facebook", rec[("post", "P1")]["detail"])
        objs = self.sql("select level, status, daily_cents, simulated from public.ffm_run_objects where launch_id = %s", (l["id"],))
        self.assertEqual(sorted(o["level"] for o in objs).count("ad"), 9)
        self.assertTrue(all(o["status"] == "active" and o["simulated"] for o in objs))
        self.assertLessEqual(sum(o["daily_cents"] or 0 for o in objs), 3000)
        self.assertTrue(rec[("metrics", self.now.strftime("%Y-%m-%dT%H"))]["simulated"])
        # a lead from the landing page form: stored, consent recorded, touch 1 at once (simulated: dry run)
        r = eng.intake(l, "landing", "nf-abc123", {"name": "Alex Doe", "email": "alex@example.com", "phone": "613-555-0142", "income": "secret"},
                       {"given": True, "wording_version": "v1", "captured_at": self.now.isoformat(), "evidence_ref": "nf-abc123"})
        self.assertTrue(r["ok"])
        lead = r["lead_id"]
        self.assertEqual(self.sql("select status, outbox_id from public.ffm_run_touches where lead_id = %s", (lead,)), [{"status": "simulated", "outbox_id": None}])
        self.assertEqual(self.sql("select basis from public.ffm_consent_log where lead_id = %s", (lead,))[0]["basis"], "unverified")
        self.assertEqual(self.sql("select stage from public.ws_leads where id = %s", (lead,))[0]["stage"], "contacted")
        self.assertEqual(eng.intake(l, "landing", "nf-abc123", {"name": "Alex Doe", "email": "alex@example.com"}, {})["duplicate"], True)
        # touch 2 when due
        self.sql("update public.ffm_run_leads set next_due_at = least(now(), %s::timestamptz) - interval '1 minute' where lead_id = %s", (self.now, lead))
        self.engine().work_leads(l)
        self.assertEqual(self.sql("select count(*) c from public.ffm_run_touches where lead_id = %s", (lead,))[0]["c"], 2)
        # optimize: seeded history -> loser paused, budget shifted, never above the approved day
        ads = {o["plan_ref"]: o["id"] for o in self.sql("select id, plan_ref from public.ffm_run_objects where launch_id = %s and level = 'ad'", (l["id"],))}
        y = (self.today - timedelta(days=1)).isoformat()
        for ref, spend, leads in (("V1", 2000, 4), ("V2", 2000, 0), ("V4", 2000, 1), ("V7", 2000, 1)):
            E._call("ffm_run_put_metrics", {"p_object": ads[ref], "p_day": y, "p_spend": spend, "p_impressions": 1, "p_clicks": 1, "p_leads": leads, "p_simulated": True})
        self.engine(now=self.now).optimize(self.launch(), self.today + timedelta(days=1))
        st = {o["plan_ref"]: o for o in self.sql("select plan_ref, level, status, daily_cents from public.ffm_run_objects where launch_id = %s", (l["id"],))}
        self.assertEqual(st["V2"]["status"], "paused")
        self.assertEqual(st["V1"]["status"], "active")
        sets = [o for o in st.values() if o["level"] == "ad_set" and o["status"] == "active"]
        self.assertLessEqual(sum(s["daily_cents"] for s in sets), 3000)
        self.assertGreater(st["A"]["daily_cents"], st["B"]["daily_cents"])        # set A has the best cost per lead
        self.assertIn("paused V2", self.receipts("optimize")[-1]["detail"])
        # report
        self.engine(now=self.now).weekly_report(l, self.today + timedelta(days=1))
        kinds = [k for k, _ in self.sent]
        self.assertEqual(kinds, ["brief", "brief"])
        self.assertIn("DRY RUN", self.sent[0][1])
        self.assertIn("Cost per lead", self.sent[0][1])
        self.assertIn("do not send", self.sent[1][1])
        # dry run: nothing external at all
        self.assertTrue(all(r["simulated"] for r in self.receipts()))
        self.assertEqual(self.sql("select count(*) c from public.hand_actions where created_by = 'ffm-run'")[0]["c"], 0)
        self.assertEqual(self.sql("select count(*) c from public.outbox where idempotency_key like 'ffm:%%'")[0]["c"], 0)

    # ---- live mode with mocked platform APIs
    def test_live_mode_mocked_platforms(self):
        self.consent_allowed()
        self.go_live()
        self.propose()
        self.tap()
        h, ex = Http(), []
        eng = self.engine(http=h, token=lambda ref: {"access_token": "tok", "api_key": "k"}, executor_run=run_exec(ex))
        eng.tick()
        l = self.launch()
        self.assertTrue(l["landing_url"].startswith("https://maple-site") and l["landing_url"].endswith(".netlify.app"))
        self.assertEqual(self.sql("select action, status, approval_kind, approved_by like 'owner:launch:%%' as by_launch from public.hand_actions where created_by = 'ffm-run' order by action"),
                         [{"action": "deploy", "status": "approved", "approval_kind": "owner", "by_launch": True},
                          {"action": "post", "status": "approved", "approval_kind": "owner", "by_launch": True}])
        camp = h.posts("/campaigns")[0][2]
        self.assertEqual((camp["status"], camp["spend_cap"]), ("PAUSED", "30000"))
        self.assertEqual(len(h.posts("/adsets")), 3)
        self.assertTrue(all(c[2]["status"] == "PAUSED" for c in h.posts("/ads") if "status" in c[2] and "adset_id" in c[2]))
        self.assertEqual(sum(1 for c in h.calls if c[2].get("status") == "ACTIVE"), 13)            # 9 ads + 3 ad sets + 1 campaign switched on after creation
        self.assertFalse(self.receipts("launch")[0]["simulated"])
        self.assertTrue(any(e[3] == "ffm launch ads" for e in ex))                                  # through the executor gate
        r = eng.intake(l, "landing", "nf-live1", {"name": "Sam Lee", "email": "sam@example.com"},
                       {"given": True, "wording_version": "v1", "captured_at": self.now.isoformat(), "evidence_ref": "nf-live1"})
        ob = self.sql("select o.status, o.needs_owner, o.to_ref, o.body from public.outbox o join public.ffm_run_touches t on t.outbox_id = o.id where t.lead_id = %s", (r["lead_id"],))
        self.assertEqual((ob[0]["status"], ob[0]["needs_owner"], ob[0]["to_ref"]), ("draft", True, "sam@example.com"))
        self.assertIn("Book a time: https://cal.example.com/maple", ob[0]["body"])
        # opt-out: sequence stops, the pending draft is withdrawn, consent withdrawn, address suppressed
        out = R.command("lead", [r["lead_id"][:8], "stop"])
        self.assertIn("consent withdrawn", out)
        self.assertEqual(self.sql("select status from public.outbox where idempotency_key = %s", (f"ffm:{r['lead_id']}:1",))[0]["status"], "rejected")
        self.assertEqual(self.sql("select count(*) c from public.ffm_consent_log where lead_id = %s and basis = 'withdrawn'", (r["lead_id"],))[0]["c"], 1)
        self.assertTrue(self.sql("select public.is_suppressed('sam@example.com') s")[0]["s"])
        self.sql("update public.ffm_run_leads set next_due_at = now() - interval '1 minute' where lead_id = %s", (r["lead_id"],))
        self.assertEqual(E._call("ffm_run_touch", {"p_lead": r["lead_id"], "p_touch": 2, "p_subject": "Your renewal review", "p_body": "x", "p_live": True})["reason"], "lead is opted_out")

    # ---- budget hard stop
    def test_budget_hard_stop(self):
        self.propose(daily="$10", total="$15", days="10")
        self.tap()
        E._call("ffm_run_sync_decisions", {})
        eng = self.engine()
        eng.launch_ads(self.launch())
        l = self.launch()
        objs = {o["plan_ref"]: o for o in self.sql("select * from public.ffm_run_objects where launch_id = %s", (l["id"],))}
        # the database refuses any ad-set budget above the approved daily budget, however it is asked
        with self.assertRaisesRegex(RuntimeError, "approved daily budget"):
            E._call("ffm_run_set_object", {"p_object": objs["A"]["id"], "p_status": "active", "p_daily": 900})
        with self.assertRaisesRegex(RuntimeError, "approved daily budget"):
            E._call("ffm_run_put_object", {"p_launch": l["id"], "p_level": "ad_set", "p_ref": "Z", "p_parent": objs["campaign"]["id"], "p_external": "sim:z", "p_status": "paused",
                                           "p_daily": 500, "p_simulated": True})
        with self.assertRaisesRegex(Exception, "immutable"):
            self.sql("update public.ffm_run_budgets set total_cap_cents = 999999 where launch_id = %s", (l["id"],))
        # spend reaches the cap -> capped, everything paused, the owner told once, no more launching or posting
        E._call("ffm_run_put_metrics", {"p_object": objs["V1"]["id"], "p_day": self.today.isoformat(), "p_spend": 1600, "p_impressions": 1, "p_clicks": 1, "p_leads": 0, "p_simulated": True})
        self.assertEqual(self.launch()["status"], "capped")
        eng = self.engine()
        eng.tick()
        self.assertTrue(all(o["status"] == "paused" for o in self.sql("select status from public.ffm_run_objects where launch_id = %s", (l["id"],))))
        self.assertEqual([k for k, _ in self.sent], ["money"])
        self.assertIn("/ffm budget", self.sent[0][1])
        self.engine().tick()
        self.assertEqual(len(self.sent), 1)                                                         # told once
        with self.assertRaisesRegex(RuntimeError, "launch is capped"):
            E._call("ffm_run_set_object", {"p_object": objs["A"]["id"], "p_status": "active", "p_daily": None})
        self.assertEqual(E._call("ffm_run_gate", {"p_launch": l["id"], "p_step": "post", "p_connector": None})["reason"], "launch is capped")
        # more money is a new owner tap; nothing changes before it
        R.command("budget", [self.slug, "$10", "$40"])
        self.assertEqual(self.launch()["status"], "capped")
        self.assertEqual(E._call("ffm_run_budget", {"p_launch": l["id"]})["total_cap_cents"], 1500)
        self.tap()
        self.engine().tick()
        self.assertEqual(E._call("ffm_run_budget", {"p_launch": l["id"]})["total_cap_cents"], 4000)
        self.assertEqual(self.launch()["status"], "running")

    # ---- kill switch
    def test_kill_switch(self):
        self.consent_allowed()
        self.go_live()
        self.propose()
        self.tap()
        h = Http()
        self.engine(http=h, token=lambda ref: {"access_token": "tok", "api_key": "k"}).tick()
        l = self.launch()
        n_calls, n_rec = len(h.calls), len(self.receipts())
        self.sql("update public.system_state set kill_switch = true where id = 1")
        h2 = Http()
        self.engine(http=h2, token=lambda ref: {"access_token": "tok", "api_key": "k"}).tick()
        # the only external call is the pause of the live campaign; nothing created, posted, polled or sent
        self.assertEqual([(c[0], c[2].get("status")) for c in h2.calls], [("POST", "PAUSED")])
        self.assertTrue(all(o["status"] == "paused" for o in self.sql("select status from public.ffm_run_objects where launch_id = %s", (l["id"],))))
        self.assertEqual([r["step"] for r in self.receipts()[n_rec:]], ["pause"])
        self.assertEqual(E._call("ffm_run_gate", {"p_launch": l["id"], "p_step": "followup", "p_connector": None})["reason"], "kill switch is on")
        r = self.engine().intake(l, "landing", "nf-kill1", {"name": "Kim", "email": "kim@example.com"},
                                 {"given": True, "wording_version": "v1", "captured_at": self.now.isoformat(), "evidence_ref": "nf-kill1"})
        self.assertEqual(self.sql("select count(*) c from public.ffm_run_touches where lead_id = %s", (r["lead_id"],))[0]["c"], 0)
        self.assertEqual(E._call("ffm_run_touch", {"p_lead": r["lead_id"], "p_touch": 1, "p_subject": "Your renewal review", "p_body": "Hi there, Maple Mortgage Team here, step 1.",
                                                   "p_live": True})["reason"], "kill switch is on")
        self.assertGreater(n_calls, 0)

    # ---- privacy / guard
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
        self.assertIn("sensitive", self.receipts("leads")[-1]["detail"])
        no_consent = eng.intake(l, "landing", "nf-bad2", {"name": "Alex", "email": "alex@example.com"}, {"given": False})
        self.assertFalse(no_consent["ok"])
        self.assertIn("consent is required", no_consent["reason"])
        # without verified consent the follow-up is skipped, never sent
        ok = eng.intake(l, "landing", "nf-ok1", {"name": "Alex", "email": "alex@example.com"},
                        {"given": True, "wording_version": "v1", "captured_at": self.now.isoformat(), "evidence_ref": "nf-ok1"})
        self.assertEqual(self.sql("select status, reason from public.ffm_run_touches where lead_id = %s", (ok["lead_id"],))[0]["status"], "skipped")
        self.assertEqual(self.sql("select status from public.ffm_run_leads where lead_id = %s", (ok["lead_id"],))[0]["status"], "needs_consent")
        # nothing outside the approved plan can be posted under the launch approval
        self.assertEqual(E._call("ffm_run_submit_hand", {"p_launch": l["id"], "p_item": "P1", "p_connector": "meta-facebook", "p_action": "post",
                                                         "p_payload": {"text": "Something else entirely"}})["ok"], False)
        # a plan carrying sensitive text is refused before any owner message
        R.command("stop", [self.slug], now=self.now)
        plan = json.loads(json.dumps(l["plan"]))
        plan["posts"][0]["text"] = "Send us your bank statement and credit report"
        with self.assertRaises(E.SensitiveDataRefused):
            E._call("ffm_run_propose", {"p_ws": self.ws, "p_pack": self.pack_id, "p_daily": 1000, "p_total": 2000, "p_starts": self.today.isoformat(),
                                        "p_ends": self.today.isoformat(), "p_paid": ["meta"], "p_organic": ["facebook"], "p_plan": plan, "p_by": "owner:telegram"})

    def test_only_owner_ends_early_and_one_launch_at_a_time(self):
        self.propose()
        self.tap()
        self.engine().tick()
        l = self.launch()
        with self.assertRaisesRegex(RuntimeError, "already has a launch"):
            self.propose_raw()
        with self.assertRaisesRegex(RuntimeError, "only the owner"):
            E._call("ffm_run_stop", {"p_launch": l["id"], "p_by": "jarvis"})
        self.assertIn("stopped", R.command("stop", [self.slug], now=self.now))
        self.assertEqual(self.launch()["status"], "done")

    def propose_raw(self):
        l = self.launch()
        return E._call("ffm_run_propose", {"p_ws": self.ws, "p_pack": self.pack_id, "p_daily": 1000, "p_total": 2000, "p_starts": self.today.isoformat(),
                                           "p_ends": self.today.isoformat(), "p_paid": ["meta"], "p_organic": [], "p_plan": l["plan"], "p_by": "owner:telegram"})


if __name__ == "__main__":
    unittest.main()
