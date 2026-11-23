"""Donna Ops v1 (hq_donna.py): mission runners, CASL drafts, prohibited actions, dormancy, research tools, onboarding, owner views and the deploy kit.
Network, database and brain are all fakes: no request leaves the process. The database rules are proven in sqltests/donna_ops_check.sql."""
import json
import os
import re
import unittest
from unittest import mock

import hq_donna as D
import hq_receptionist as R

HERE = os.path.dirname(os.path.abspath(__file__))
GOOD = ("Hi {business}, missed calls cost local trades jobs. Donna is an AI receptionist that answers calls, texts back missed callers and books visits. "
        "Want a 10 minute demo?")


def _read(path):
    with open(path, encoding="utf-8") as f:
        return f.read()


def _no_network(*a, **k):
    raise AssertionError("a test tried to reach the network or the database")


D._rpc_default = _no_network
R._rpc_default = _no_network


class FakeDb:
    """Name-based RPC fake. active: Donna's office status. prohibited / green mirror fz_donna; every call is recorded."""

    def __init__(self, active=True, drift=False, m1="active", green=("research", "draft_proposal", "build_in_sandbox", "draft_outreach", "market_validation", "draft_offer")):
        self.active, self.drift, self.m1, self.green, self.calls, self.n = active, drift, m1, set(green), [], 0

    def __call__(self, name, args):
        self.calls.append((name, args))
        if name == "office_os_status":
            return {"office": "donna", "status": "active" if self.active else "dormant", "m1_status": self.m1 if self.active else "dormant", "drift": self.drift}
        if name == "donna_run_begin":
            return {"run": "run-1", "mission": args["p_mission"], "action": {"market-research": "market_validation", "offer-pricing": "draft_offer",
                    "outreach-prep": "draft_outreach", "delivery-onboarding": "build_in_sandbox", "weekly-report": "research"}[args["p_mission"]]}
        if name == "donna_check_action":
            a = args["p_action"]
            if a in D.PROHIBITED:
                return {"allowed": False, "reason": "prohibited for Donna: " + a}
            return {"allowed": True} if a in self.green else {"allowed": False, "reason": a + " is not in Donna's green tier"}
        if name == "donna_save_draft":
            self.n += 1
            return {"draft": f"d{self.n}", "status": "draft"}
        if name == "donna_lead_label":
            return {"lead": args["p_lead"], "business": "Spruce Heating"}
        if name == "donna_add_prospect":
            return {"lead": "l1", "duplicate": False}
        if name == "donna_save_intake":
            return {"intake": "i1", "status": "draft"}
        if name == "donna_weekly_report":
            return {"week": "2026-W48", "message": "m1"}
        return {}

    def names(self):
        return [n for n, _ in self.calls]

    def args(self, name):
        return [a for n, a in self.calls if n == name]


class FakeLlm:
    def __init__(self, *texts, cents=0):
        self.texts, self.cents, self.calls = list(texts), cents, []

    def __call__(self, system, messages, **kw):
        self.calls.append({"system": system, "messages": messages, **kw})
        t = self.texts.pop(0) if self.texts else "{}"
        return {"text": t, "cents": self.cents, "provider": "groq"}


class FakeWeb:
    """pages: url -> html. robots: host -> robots.txt text (default: allow all)."""

    def __init__(self, pages=None, robots=None):
        self.pages, self.robots, self.calls = dict(pages or {}), dict(robots or {}), []

    def __call__(self, method, url, headers=None, timeout=60, **k):
        self.calls.append((method, url, dict(headers or {})))
        assert method == "GET" and url.startswith("https://")
        if url.endswith("/robots.txt"):
            host = url.split("/")[2]
            return (200, self.robots[host].encode(), {}) if host in self.robots else (404, b"", {})
        if url in self.pages:
            return 200, self.pages[url].encode(), {"Content-Type": "text/html"}
        return 404, b"", {}


def run(mission, inputs=None, db=None, llm=None, web=None):
    db = db or FakeDb()
    return D.run(mission, inputs or {}, rpc=db, llm=llm or FakeLlm(), http=web or FakeWeb()), db


# ------------------------------------------------------------------------------------------------------------------- dormancy and prohibited actions
class Gating(unittest.TestCase):
    def test_dormant_refuses_before_anything_runs(self):
        for db in (FakeDb(active=False), FakeDb(drift=True), FakeDb(m1="dormant")):
            llm, web = FakeLlm(), FakeWeb()
            for m in D.MISSIONS:
                r, _ = run(m, {}, db, llm, web)
                self.assertFalse(r["ok"])
                self.assertIn("refused", r)
            self.assertNotIn("donna_run_begin", db.names())
            self.assertEqual(llm.calls, [])
            self.assertEqual(web.calls, [])

    def test_status_error_fails_closed(self):
        def boom(name, args):
            if name == "office_os_status":
                raise OSError("down")
            raise AssertionError("nothing else may run")
        r = D.run("weekly-report", {}, rpc=boom)
        self.assertFalse(r["ok"])

    def test_each_prohibited_action_is_refused_in_code(self):
        self.assertEqual(D.PROHIBITED, {"sign_contract", "financial_transfer", "deceptive_communication", "fabricate", "evade_platform_restrictions",
                                        "spend_outside_budget", "deploy_website", "modify_own_permissions"})
        for a in D.PROHIBITED:
            with self.assertRaises(D.DonnaRefused):
                D.guard_action(a)
            with self.assertRaises(D.DonnaRefused):
                D.guard_action(a.upper() + " ")
        D.guard_action("research")

    def test_ctx_check_refuses_prohibited_even_if_db_says_allowed(self):
        db = FakeDb()
        db.green |= D.PROHIBITED
        ctx = D.Ctx("run-1", "research", db, None, None, D.config())
        for a in D.PROHIBITED:
            with self.assertRaises(D.DonnaRefused):
                ctx.check(a)
        self.assertNotIn("donna_check_action", db.names())                 # refused in code first
        with self.assertRaises(D.DonnaRefused):
            ctx.check("send_email")                                         # red: the database says no

    def test_inputs_cannot_carry_actions_or_permissions(self):
        for k in ("action", "actions", "tool", "permissions", "send", "deploy", "pay", "sign"):
            with self.assertRaises(D.DonnaRefused):
                D.run("outreach-prep", {k: "deploy_website"}, rpc=FakeDb())

    def test_unknown_mission_and_mission_keys(self):
        with self.assertRaises(D.DonnaRefused):
            D.resolve("send-everything")
        self.assertEqual(D.resolve("donna-m1-validation"), "market-research")
        self.assertEqual(D.resolve("donna-m4-weekly-report"), "weekly-report")

    def test_a_brain_call_that_costs_money_fails_the_run(self):
        r, db = run("outreach-prep", {"channels": ["email"]}, llm=FakeLlm(json.dumps({"subject": "Missed calls", "body": GOOD}), cents=3))
        self.assertFalse(r["ok"])
        self.assertIn("spend_outside_budget", r["refused"])
        self.assertEqual(db.args("donna_run_finish")[0]["p_status"], "failed")
        self.assertNotIn("donna_save_draft", db.names())

    def test_brain_is_small_tier_free_and_division_donna(self):
        llm = FakeLlm(json.dumps({"subject": "Missed calls", "body": GOOD}))
        run("outreach-prep", {"channels": ["email"]}, llm=llm)
        self.assertEqual({c["tier"] for c in llm.calls}, {"small"})
        self.assertEqual({c["division"] for c in llm.calls}, {"donna"})


class StaticSurface(unittest.TestCase):
    """There is no code path to send, pay, sign, deploy or change a permission in hq_donna.py."""
    SRC = _read(os.path.join(HERE, "hq_donna.py"))

    def test_only_donna_rpcs_and_office_status(self):
        names = set(re.findall(r'rpc\(\s*"([a-z_]+)"', self.SRC))
        self.assertTrue(names)
        self.assertTrue(all(n.startswith("donna_") for n in names), names)
        self.assertNotIn("/rest/v1/", self.SRC.replace('f"/rest/v1/rpc/{name}"', ""))

    def test_no_send_pay_deploy_or_permission_paths(self):
        import io
        import tokenize
        toks = tokenize.generate_tokens(io.StringIO(self.SRC).readline)            # code only: owner-facing instruction strings are text, not calls
        code = " ".join(t.string for t in toks if t.type not in (tokenize.STRING, tokenize.COMMENT, getattr(tokenize, "FSTRING_MIDDLE", -1)))
        for bad in ("reception_owner_", "office_os_activate", "office_os_set", "fz_set_office_policy", "fz_owner_", "authorize_action", "hq_mail", "hq_payments", "hq_bank",
                    "hq_webstudio", "hq_hands ", "hq_hands_adapters . http (\"POST", "send_sms", "deploy (", "jarvis_set_config"):
            self.assertNotIn(bad, code, bad)
        self.assertEqual(re.findall(r'self\.http\("(\w+)"', self.SRC), ["GET", "GET", "GET"])     # robots.txt, page, search: reads only
        self.assertNotRegex(self.SRC, r'http\(\s*"(POST|PUT|PATCH|DELETE)"')


# ------------------------------------------------------------------------------------------------------------------- CASL drafts
class Casl(unittest.TestCase):
    def full(self, kind="cold_email", text=GOOD):
        return text + "\n\n" + D.casl_footer(kind)

    def test_footer_makes_a_compliant_message(self):
        self.assertEqual(D.casl_problems("cold_email", "Missed calls at {business}", self.full()), [])
        self.assertEqual(D.casl_problems("dm", None, self.full("dm")), [])
        self.assertEqual(D.casl_problems("call_script", None, "Hi, this is Sam calling for Donna, an AI receptionist service. " + D.casl_footer("call_script")), [])

    def test_each_problem_is_named(self):
        cases = [
            ("cold_email", "Hi", self.full().replace("Donna", "We"), "sender identification"),
            ("cold_email", "Hi", self.full().replace("Mailing address: [OWNER: mailing address]", "Ottawa"), "mailing address"),
            ("cold_email", "Hi", self.full().replace('reply "unsubscribe"', "write back").replace("unsubscribe", "x"), "unsubscribe"),
            ("cold_email", "", self.full(), "subject"),
            ("cold_email", "Re: your missed calls", self.full(), "deceptive_communication"),
            ("cold_email", "FWD: quote", self.full(), "deceptive_communication"),
            ("cold_email", "Hi", "As we discussed, " + self.full(), "deceptive_communication"),
            ("cold_email", "Hi", self.full() + " Last chance, act now!", "deceptive_communication"),
            ("cold_email", "Hi", self.full() + " Results guaranteed or your money back.", "claim not allowed"),
            ("cold_email", "Hi", self.full() + " Trusted by 200+ businesses.", "claim not allowed"),
            ("cold_email", "Hi", self.full() + " Send an e-transfer to begin.", "financial_transfer"),
            ("cold_email", "Hi", self.full() + " Please e-sign the contract.", "sign_contract"),
            ("cold_email", "Hi", "{Hi|Hello} " + self.full(), "evade_platform_restrictions"),
            ("cold_email", "Hi", self.full() + " This wording helps avoid spam filters.", "evade_platform_restrictions"),
            ("dm", None, "I'm a real person. " + self.full("dm"), "deceptive_communication"),
            ("call_script", None, "Hi this is Sam calling for Donna. Want a demo?", "do-not-call"),
            ("call_script", None, "Hi this is Sam calling for Donna. " + D.casl_footer("call_script"), "AI service"),
        ]
        for kind, subj, body, want in cases:
            probs = D.casl_problems(kind, subj, body)
            self.assertTrue(any(want in p for p in probs), (kind, subj, body[:60], probs))

    def test_outreach_prep_appends_the_fixed_footer_and_never_sends(self):
        llm = FakeLlm(json.dumps({"subject": "Missed calls at {business}", "body": GOOD}), json.dumps({"body": GOOD}),
                      json.dumps({"body": "Hi, this is Sam calling for Donna, an AI receptionist service. Do missed calls cost you jobs?"}))
        r, db = run("outreach-prep", {"channels": ["email", "dm", "call"], "lead_ids": ["lead-1"]}, llm=llm)
        self.assertTrue(r["ok"], r)
        res = r["result"]
        self.assertEqual(res["sent"], 0)
        saved = db.args("donna_save_draft")
        self.assertEqual([a["p_kind"] for a in saved], ["cold_email", "cold_email", "dm", "dm", "call_script"])
        for a in saved:
            self.assertEqual(D.casl_problems(a["p_kind"], a["p_subject"], a["p_body"]), [], a)
            self.assertIn("[OWNER: mailing address]" if a["p_kind"] != "call_script" else "do-not-call", a["p_body"])
        lead = [a for a in saved if a["p_lead"]][0]
        self.assertIn("Spruce Heating", lead["p_body"])
        self.assertNotIn("{business}", lead["p_body"])
        # no lead data reached the brain
        self.assertFalse(any("Spruce" in json.dumps(c["messages"]) for c in llm.calls))
        self.assertEqual({tuple(c["sources"]) for c in llm.calls}, {("system",)})
        self.assertNotIn("send", " ".join(db.names()).replace("donna_save_draft", ""))

    def test_a_non_compliant_model_draft_is_refused_not_saved(self):
        for bad in ({"subject": "Re: our call", "body": GOOD}, {"subject": "Hi", "body": GOOD + " Guaranteed results."},
                    {"subject": "Hi", "body": "{Hey|Hi} " + GOOD}):
            r, db = run("outreach-prep", {"channels": ["email"]}, llm=FakeLlm(json.dumps(bad)))
            self.assertTrue(r["ok"])
            self.assertEqual(db.args("donna_save_draft"), [])
            self.assertEqual(len(r["result"]["refused"]), 1)

    def test_database_refusal_is_recorded_not_worked_around(self):
        db = FakeDb()
        orig = db.__call__

        def refusing(name, args):
            if name == "donna_save_draft" and args.get("p_lead"):
                raise RuntimeError("refused: no consent basis recorded for this lead (CASL)")
            return orig(name, args)
        r = D.run("outreach-prep", {"channels": ["email"], "lead_ids": ["l9"]}, rpc=refusing, llm=FakeLlm(json.dumps({"subject": "Hi", "body": GOOD})), http=FakeWeb())
        self.assertTrue(r["ok"])
        self.assertEqual(len(r["result"]["saved"]), 1)                          # the template
        self.assertIn("consent basis", r["result"]["refused"][0]["reason"])


# ------------------------------------------------------------------------------------------------------------------- market research
PAGE_A = ("<html><title>Ottawa trades</title><body><p>Ottawa has more than 1,200 heating and air conditioning contractors registered with the city.</p>"
          "<p>Call 613-555-0101 or email info@example-a.ca.</p></body></html>")
PAGE_B = "<html><body><p>Ottawa households spent an average of 2,400 dollars on home heating repairs in 2025.</p></body></html>"
UA = "https://www150.statcan.gc.ca/t1/a"
UB = "https://open.ottawa.ca/datasets/b"


class MarketResearch(unittest.TestCase):
    def facts(self):
        return json.dumps({"niches": [{"niche": "hvac", "scores": {"demand": 5, "ability_to_pay": 4, "competition": 2, "ease_of_delivery": 4, "recurring_potential": 5},
                                       "facts": [{"fact": "Ottawa has more than 1,200 heating and air conditioning contractors registered with the city.", "url": UA},
                                                 {"fact": "Ottawa households spent an average of 2,400 dollars on home heating repairs in 2025.", "url": UB},
                                                 {"fact": "92% of HVAC calls in Ottawa go unanswered.", "url": UA}]},
                                      {"niche": "dental clinics", "scores": {"demand": 3}, "facts": [{"fact": "Dentists earn the most.", "url": UB}]},
                                      {"niche": "crypto", "scores": {"demand": 5}, "facts": []}]})

    def test_facts_are_verified_and_fabrications_dropped(self):
        web = FakeWeb({UA: PAGE_A, UB: PAGE_B})
        llm = FakeLlm(self.facts())
        r, db = run("market-research", {"urls": [UA, UB, "https://evil.example/x"]}, llm=llm, web=web)
        self.assertTrue(r["ok"], r)
        res = r["result"]
        hvac = [x for x in res["ranking"] if x["niche"] == "hvac"][0]
        self.assertTrue(hvac["validated"])
        self.assertEqual(len(hvac["supported_facts"]), 2)
        self.assertTrue(any("92%" in x["fact"] for x in res["dropped"]))
        self.assertFalse([x for x in res["ranking"] if x["niche"] == "dental clinics"][0]["validated"])
        self.assertNotIn("crypto", [x["niche"] for x in res["ranking"]])               # not an asked niche
        self.assertTrue(any("evil.example" in s for s in res["skipped"]))
        self.assertNotIn("https://evil.example/x", [u for _, u, _ in web.calls])
        # contact data never reaches the brain; sources are public_web
        sent = json.dumps(llm.calls[0]["messages"])
        self.assertNotIn("613-555-0101", sent)
        self.assertNotIn("info@example-a.ca", sent)
        self.assertEqual(llm.calls[0]["sources"], ["public_web"])
        rep = db.args("donna_save_draft")[0]
        self.assertEqual(rep["p_kind"], "niche_report")
        self.assertIn("VALIDATED", rep["p_body"])
        self.assertIn("Dropped", rep["p_body"])
        # the run records its sources with hashes
        fin = db.args("donna_run_finish")[0]
        self.assertEqual(len(fin["p_sources"]), 2)
        self.assertTrue(all(len(s["sha256"]) == 64 for s in fin["p_sources"]))

    def test_robots_and_honest_user_agent(self):
        web = FakeWeb({UA: PAGE_A, UB: PAGE_B}, robots={"www150.statcan.gc.ca": "User-agent: *\nDisallow: /t1/"})
        r, db = run("market-research", {"urls": [UA, UB]}, llm=FakeLlm(self.facts()), web=web)
        self.assertTrue(any("robots.txt" in s for s in r["result"]["skipped"]))
        self.assertNotIn(UA, [u for _, u, _ in web.calls])
        self.assertTrue(all(h.get("User-Agent", "").startswith("DonnaResearchBot") for _, _, h in web.calls))
        hvac = [x for x in r["result"]["ranking"] if x["niche"] == "hvac"][0]
        self.assertFalse(hvac["validated"])                                            # one host only

    def test_no_pages_means_nothing_validated_and_no_brain_call(self):
        llm = FakeLlm()
        r, db = run("market-research", {}, llm=llm)
        self.assertTrue(r["ok"])
        self.assertEqual(llm.calls, [])
        self.assertIn("nothing was estimated", db.args("donna_save_draft")[0]["p_body"])

    def test_research_refuses_non_https_login_and_ports(self):
        res = D.Research(http=FakeWeb())
        for u in ("http://ottawa.ca/x", "https://ottawa.ca:8443/x", "https://user:pw@ottawa.ca/x", "https://ottawa.ca/login", "https://example.com/x"):
            self.assertIsNotNone(res.allowed(u), u)
            with self.assertRaises(D.DonnaRefused):
                res.fetch(u)
        self.assertIsNone(res.allowed("https://example.com/contact", citable=False))

    def test_search_needs_the_owners_searxng(self):
        self.assertEqual(D.Research(http=_no_network, env={}).search("hvac ottawa"), [])
        web = mock.Mock(return_value=(200, {"results": [{"url": "https://open.ottawa.ca/d", "title": "x"}, {"url": "http://bad"}]}, {}))
        out = D.Research(http=web, env={"DONNA_SEARXNG_URL": "https://searx.example"}).search("hvac ottawa")
        self.assertEqual(out, [{"url": "https://open.ottawa.ca/d", "title": "x"}])

    def test_prospects_need_a_published_contact_and_no_notice(self):
        pages = {"https://a-heating.example/contact": "<p>A Heating. Email jobs@a-heating.example</p>",
                 "https://b-plumbing.example/contact": "<p>B Plumbing 613-555-0177. No unsolicited emails please.</p>",
                 "https://c-roofing.example/": "<p>C Roofing, family owned.</p>"}
        r, db = run("market-research", {"prospects": [{"business": "A Heating", "url": "https://a-heating.example/contact"},
                                                      {"business": "B Plumbing", "url": "https://b-plumbing.example/contact"},
                                                      {"business": "C Roofing", "url": "https://c-roofing.example/"},
                                                      {"business": "D", "url": "http://d.example"}]}, web=FakeWeb(pages))
        res = {p["business"]: p for p in r["result"]["prospects"]}
        self.assertTrue(res["A Heating"]["recorded"])
        self.assertIn("no unsolicited", res["B Plumbing"]["reason"])
        self.assertIn("no published contact", res["C Roofing"]["reason"])
        self.assertFalse(res["D"]["recorded"])
        add = db.args("donna_add_prospect")
        self.assertEqual(len(add), 1)
        self.assertEqual((add[0]["p_email"], add[0]["p_source_url"], add[0]["p_no_solicit_notice"]), ("jobs@a-heating.example", "https://a-heating.example/contact", False))


# ------------------------------------------------------------------------------------------------------------------- offer, onboarding, report
class OfferPricing(unittest.TestCase):
    PRICES = [{"title": "Answer", "price_cents": 49700, "period": "per month"}, {"title": "Capture", "price_cents": 79700, "period": "per month"}]

    def test_margins_from_the_cost_model(self):
        c = D.delivery_cost()
        self.assertEqual(c["total_cents"], 150 * R.call_cost_cents(3.0, mode="stream") + 60 * R.sms_cost_cents(1) + int(round(R.COST_USD["number_month"] * R.FX_CAD * 100)))
        llm = FakeLlm(json.dumps({"packages": [{"title": "Answer", "must_be_tested": ["demo line"], "risk": "after-hours"}], "suggestions": ["keep three tiers"]}))
        r, db = run("offer-pricing", {"prices": self.PRICES}, llm=llm)
        self.assertTrue(r["ok"], r)
        self.assertEqual(r["result"]["prices"][0]["margin_cents"], 49700 - c["total_cents"])
        self.assertEqual(db.args("donna_save_draft")[0]["p_kind"], "offer_review")

    def test_a_review_promising_a_refund_is_refused(self):
        r, db = run("offer-pricing", {"prices": self.PRICES}, llm=FakeLlm(json.dumps({"suggestions": ["offer a full refund in month one"]})))
        self.assertFalse(r["ok"])
        self.assertNotIn("donna_save_draft", db.names())

    def test_prices_are_read_never_written(self):
        code = _read(os.path.join(HERE, "hq_donna.py"))
        self.assertNotRegex(code, r"open\([^)]*site\.json[^)]*['\"]w")


class Onboarding(unittest.TestCase):
    INTAKE = {"business_name": "Spruce Heating", "city": "Ottawa", "services": [{"name": "Furnace repair", "price_cents": 14900, "minutes": 60}],
              "faqs": [{"q": "Do you do weekends?", "a": "Saturdays 9 to 1."}], "escalation_number": "+16135550100"}

    def test_intake_makes_a_valid_config_and_a_site_draft(self):
        r, db = run("delivery-onboarding", {"intake": self.INTAKE})
        self.assertTrue(r["ok"], r)
        res = r["result"]
        self.assertFalse(res["deployed"])
        R.validate(res["reception_config"])
        args = db.args("donna_save_intake")[0]
        site = args["p_site_json"]
        self.assertEqual(site["office"], "donna")
        self.assertTrue({"meta", "hero", "services", "steps", "contact", "legal"} <= set(site))
        self.assertFalse({"testimonials", "reviews", "clients", "logos", "stats"} & set(site))
        self.assertRegex(site["slug"], r"^[a-z][a-z0-9-]{1,40}$")
        self.assertTrue(any("booking" in x for x in args["p_open_items"]))

    def test_missing_escalation_is_an_open_item_not_a_guess(self):
        intake = dict(self.INTAKE)
        intake.pop("escalation_number")
        cfg, items = D.reception_config(intake)
        self.assertTrue(cfg["escalation_number"].startswith("[CLIENT:"))
        self.assertTrue(any("escalation_number" in x for x in items))

    def test_no_llm_and_no_network_for_client_data(self):
        llm, web = FakeLlm(), FakeWeb()
        run("delivery-onboarding", {"intake": self.INTAKE}, llm=llm, web=web)
        self.assertEqual(llm.calls, [])
        self.assertEqual(web.calls, [])

    def test_bad_intake_refused(self):
        r, _ = run("delivery-onboarding", {"intake": {"city": "Ottawa"}})
        self.assertFalse(r["ok"])
        r, _ = run("delivery-onboarding", {"intake": dict(self.INTAKE, timezone="Mars/Base")})
        self.assertFalse(r["ok"])


class WeeklyReport(unittest.TestCase):
    def test_report_is_plain_sql(self):
        llm, web = FakeLlm(), FakeWeb()
        r, db = run("donna-m4-weekly-report", {}, llm=llm, web=web)
        self.assertTrue(r["ok"])
        self.assertIn("donna_weekly_report", db.names())
        self.assertEqual(llm.calls, [])
        self.assertEqual(web.calls, [])


# ------------------------------------------------------------------------------------------------------------------- owner views and the deploy kit
class OwnerViews(unittest.TestCase):
    def test_digest(self):
        p = {"active": False, "funnel": {"counts": {"new": 2, "drafted": 1}}, "deals": {}, "clients": [{"slug": "spruce", "receptionist": "demo"}],
             "drafts": {"waiting": 3, "approved": 0}, "intakes_waiting": 1, "runs_7d": 4,
             "next_actions": [{"ref": "draft 1", "who": "owner", "action": "review the cold email draft"}]}
        t = D.digest_text(lambda n, a: p)
        self.assertIn("DORMANT", t)
        self.assertIn("new 2", t)
        self.assertIn("spruce [demo]", t)
        self.assertIn("nothing is ever sent", t)
        self.assertIn("- draft 1 [owner]", t)
        self.assertIn("not installed", D.digest_text(_no_network))

    def test_golive_lists_owner_sql_steps(self):
        c = {"client": "spruce", "status": "demo", "ready": False, "steps": [{"step": "Donna office active", "who": "owner", "done": True},
                                                                              {"step": "live", "who": "owner", "done": False}]}
        t = D.golive_text("spruce", lambda n, a: c)
        self.assertIn("[x] Donna office active", t)
        self.assertIn("[ ] live", t)
        self.assertIn("donna_owner_golive_signoff('spruce'", t)
        self.assertIn("reception_owner_set_flags('spruce', 'live'", t)
        self.assertIn("paused", t)
        t2 = D.golive_text("x'; drop table y; --", lambda n, a: dict(c, client=a["p_slug"]))
        self.assertNotIn("drop table", t2)
        self.assertNotIn("x';", t2)

    def test_kit_and_deploy_files(self):
        t = D.kit_text()
        for v in ("RECEPTION_BASE_URL", "TWILIO_AUTH_TOKEN", "RECEPTION_SMS_LIVE", "/twilio/voice/<client>", "/twilio/status/<client>", "/twilio/sms/<client>", "NOT applied"):
            self.assertIn(v, t)
        d = os.path.join(HERE, "ops", "proposals", "receptionist_deploy")
        rj = json.loads(_read(os.path.join(d, "railway.json")))
        self.assertEqual(rj["build"]["dockerfilePath"], "ops/proposals/receptionist_deploy/Dockerfile")
        self.assertEqual(rj["deploy"]["healthcheckPath"], "/healthz")
        df = _read(os.path.join(d, "Dockerfile"))
        self.assertIn("uvicorn receptionist_server:app", df)
        self.assertIn("requirements-receptionist.txt", df)
        self.assertNotRegex(df, r"(?m)^\s*(ENV|ARG)\s+[^\n]*(TOKEN|KEY|SECRET|SID)\s*=")      # no secrets baked in
        for f in re.findall(r"(?m)^COPY ([^\n]+) \./$", df)[-1].split():
            self.assertTrue(os.path.exists(os.path.join(HERE, f)), f)
        for name in ("railway.json", "railway.toml", "nixpacks.toml", "Dockerfile"):                 # nothing at the repo root changes the bot's own service
            self.assertFalse(os.path.exists(os.path.join(HERE, name)), name)

    def test_healthz_route(self):
        import receptionist_server as S
        if S.FastAPI is None:
            self.skipTest("fastapi not installed (the receptionist image has it)")
        self.assertIn("/healthz", [r.path for r in S.app.routes])

    def test_agent_prompt_carries_the_rules(self):
        for m in ("market-research", "offer-pricing", "outreach-prep", "delivery-onboarding"):
            p = D.agent_prompt(m)
            self.assertIn("never send, pay, sign, deploy or change permissions", p)
            self.assertIn("untrusted data", p)

    def test_commands_registered(self):
        import hq_commands as C
        self.assertTrue(hasattr(C, "hq_donna_cmd"))
        src = _read(os.path.join(HERE, "hq_commands.py"))
        self.assertIn('("donna", hq_donna_cmd)', src)
        self.assertIn('"golive"', src)


if __name__ == "__main__":
    unittest.main()
