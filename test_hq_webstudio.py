"""Web Studio (hq_webstudio): content rules, slot-only LLM fills, price lock, versioned edits, PRs, hands deploys, form leads, built-site QA.

The build test runs the real Astro build only when the template's node_modules exist (CI's site job installs them); the QA rules are also tested
on hand-made pages so they never depend on Node."""
import copy
import json
import os
import shutil
import tempfile
import unittest
from unittest import mock

os.environ.setdefault("TELEGRAM_BOT_TOKEN", "test")
os.environ.setdefault("JARVIS_OWNER_ID", "1")

import hq_webstudio as W  # noqa: E402

DONNA = W.load("donna")


def llm(payload):
    calls = []

    def complete(system, messages, **kw):
        calls.append((system, messages, kw))
        return {"text": json.dumps(payload) if not isinstance(payload, str) else payload}
    complete.calls = calls
    return complete


class Rules(unittest.TestCase):
    def test_donna_is_valid(self):
        self.assertEqual(W.validate(DONNA), [])

    def test_claims_and_cliches_refused(self):
        for bad in ("Guaranteed results or your money back", "Trusted by 200+ clients", "Unlock seamless growth", "5-star reviews from locals",
                    "Elevate your business in today's fast-paced world", "Revolutionize your front desk"):
            s = copy.deepcopy(DONNA)
            s["hero"]["subtitle"] = bad
            self.assertTrue(W.validate(s), bad)

    def test_no_testimonials_logos_or_stats_sections(self):
        for k in ("testimonials", "reviews", "clients", "logos", "stats"):
            s = copy.deepcopy(DONNA)
            s[k] = [{"text": "x"}]
            self.assertTrue(any("not allowed" in p for p in W.validate(s)), k)

    def test_no_html_and_safe_tokens(self):
        s = copy.deepcopy(DONNA)
        s["hero"]["title"] = "<script>alert(1)</script>"
        s["brand"]["primary"] = "red;}body{display:none"
        s["links"]["booking"] = "javascript:alert(1)"
        p = " ".join(W.validate(s))
        for want in ("no HTML", "brand.primary", "links.booking"):
            self.assertIn(want, p)

    def test_demo_must_be_labelled_an_illustration(self):
        s = copy.deepcopy(DONNA)
        s["demo"]["label"] = "Live call"
        self.assertTrue(any("illustration" in p for p in W.validate(s)))

    def test_consent_wording_is_fixed_and_branded(self):
        c = W.consent(DONNA)
        self.assertEqual(c["form_name"], "donna-contact")
        self.assertIn("Donna.AI", c["inquiry_notice"])
        self.assertIn("unsubscribe at any time", c["marketing_checkbox"])
        self.assertEqual(c["version"], W.CONSENT_VERSION)

    def test_template_library_is_licensed(self):
        for name, t in W.TEMPLATES.items():
            self.assertIn(t["license"], ("MIT", "Apache-2.0"))
            lic = os.path.join(W.ROOT, t["path"], "LICENSE.md")
            self.assertTrue(os.path.exists(lic), name)
            with open(lic, encoding="utf-8") as f:
                self.assertIn("MIT License", f.read())


class SlotFill(unittest.TestCase):
    BRAND = {"name": "Acme Roofing", "city": "Ottawa", "region": "Ontario", "primary": "#112233", "accent": "#44aaff"}
    PRICING = [{"id": "packages", "title": "Packages", "subtitle": "CAD", "items": [{"title": "Basic", "price": 500, "period": "one-time", "features": ["a"]}]}]

    def slots(self, **over):
        s = {k: copy.deepcopy(DONNA[k]) for k in W.SLOT_KEYS if k in DONNA}
        s["hero"]["title"] = "Roofs fixed fast."
        s.update(over)
        return s

    def test_draft_takes_only_slots(self):
        evil = self.slots(brand={"name": "Hacked", "primary": "#000000", "accent": "#000000"}, layout="<div>", consent={"marketing_checkbox": "pre-ticked"},
                          pricing=[{"id": "packages", "title": "P", "items": [{"title": "Basic", "price": 1}]}])
        site = W.draft("acme", "group", "astrowind", "local", self.BRAND, "Roofing in Ottawa", self.PRICING, complete=llm(evil))
        self.assertEqual(site["brand"]["name"], "Acme Roofing")
        self.assertEqual(site["pricing"], self.PRICING)                   # prices are the owner's
        self.assertNotIn("layout", site)
        self.assertNotIn("consent", site)
        self.assertEqual(site["hero"]["title"], "Roofs fixed fast.")
        self.assertEqual(W.validate(site), [])

    def test_draft_refuses_rule_breaking_copy(self):
        with self.assertRaises(W.StudioError):
            W.draft("acme", "group", "astrowind", "local", self.BRAND, "b", self.PRICING, complete=llm(self.slots(hero={"title": "Unlock seamless roofing", "subtitle": "x", "tagline": "", "title_accent": ""})))

    def test_draft_refuses_bad_json_and_unknown_template(self):
        with self.assertRaises(W.StudioError):
            W.draft("acme", "group", "astrowind", "local", self.BRAND, "b", complete=llm("no json here"))
        with self.assertRaises(W.StudioError):
            W.draft("acme", "group", "wix", "local", self.BRAND, "b", complete=llm(self.slots()))

    def test_llm_call_is_routed_as_owner_data(self):
        c = llm(self.slots())
        W.draft("acme", "group", "astrowind", "futuristic", self.BRAND, "b", complete=c)
        kw = c.calls[0][2]
        self.assertEqual(kw["sources"], ["owner_chat"])
        self.assertIn("EXAMPLE", c.calls[0][0])

    def test_edit_is_a_new_version_and_keeps_prices(self):
        new = W.edit(DONNA, "change the hero text", complete=llm({"hero": {**DONNA["hero"], "title": "No call goes to voicemail."}}))
        self.assertEqual(new["version"], DONNA["version"] + 1)
        self.assertEqual(new["hero"]["title"], "No call goes to voicemail.")
        self.assertEqual(W.prices(new), W.prices(DONNA))
        with self.assertRaises(W.StudioError):
            W.edit(DONNA, "nothing", complete=llm({}))


class Pipeline(unittest.TestCase):
    def test_propose_is_a_pr_of_site_json_only(self):
        got = []
        out = W.propose(DONNA, "new site", propose_change=lambda t, r, files: got.append((t, r, files)) or "PR #9")
        self.assertEqual(out, "PR #9")
        self.assertEqual([f["path"] for f in got[0][2]], ["sites/donna/site.json"])
        self.assertEqual(json.loads(got[0][2][0]["content"]), DONNA)

    def test_preview_and_publish_are_hands_deploys_for_approval(self):
        sent = []
        accounts = lambda: [{"id": "a1", "handle": "donna"}]                                           # noqa: E731
        submit = lambda c, a, act, payload, **k: sent.append((c, a, act, payload)) or {"ok": True}     # noqa: E731
        env = {"JARVIS_WEBSTUDIO_ZIP_BASE": "https://builds.example.org/sites"}
        with mock.patch.dict("sys.modules", {}):
            msg = W.deploy(DONNA, publish=False, accounts=accounts, submit=submit, env=env)
        self.assertIn("approval", msg)
        self.assertEqual(sent[0][:3], ("netlify", "a1", "deploy"))
        self.assertTrue(sent[0][3]["draft"])
        self.assertEqual(sent[0][3]["zip_url"], "https://builds.example.org/sites/donna-v1.zip")
        W.deploy(DONNA, publish=True, accounts=accounts, submit=submit, env=env)
        self.assertFalse(sent[1][3]["draft"])
        self.assertIn("No Netlify site", W.deploy(DONNA, publish=True, accounts=lambda: [], submit=submit, env=env))
        with self.assertRaises(W.StudioError):
            W.zip_url(DONNA, {"JARVIS_WEBSTUDIO_ZIP_BASE": "http://insecure"})

    def test_netlify_adapter_draft_flag(self):
        import hq_hands_adapters as A
        calls = []

        def http(method, url, **kw):
            calls.append(url)
            return 200, {"id": "d1", "deploy_ssl_url": "https://d1--donna.netlify.app"}, {}
        ctx = A.Ctx(action={"payload": {"html": "<title>x</title>", "draft": True}}, account={"external_id": "site1"}, connector={"slug": "netlify"},
                    token=lambda: {"api_key": "k"}, http=http)
        self.assertEqual(A.Netlify().execute(ctx), "https://d1--donna.netlify.app")
        self.assertTrue(calls[0].endswith("/sites/site1/deploys?draft=true"))
        ctx.action["payload"]["draft"] = False
        self.assertEqual(A.Netlify().execute(ctx), "d1")
        self.assertTrue(calls[1].endswith("/sites/site1/deploys"))

    def test_command_text(self):
        self.assertIn("donna v1", W.command_text(["list"]))
        self.assertIn("/site new", W.command_text([]))
        prs = []
        out = W.command_text(["edit", "donna", "|", "change", "the", "hero", "text"], complete=llm({"hero": {**DONNA["hero"], "title": "Answered."}}),
                             propose_change=lambda t, r, f: prs.append(f) or "PR #10")
        self.assertEqual(out, "PR #10")
        self.assertEqual(json.loads(prs[0][0]["content"])["version"], 2)
        self.assertIn("Web Studio:", W.command_text(["edit", "donna", "|", "x"], complete=llm({"hero": {**DONNA["hero"], "title": "Unlock it"}})))
        self.assertEqual(W.command_text(["preview", "donna"], deploy_fn=lambda s, publish: f"p{publish}"), "pFalse")


class Leads(unittest.TestCase):
    def sub(self, **d):
        base = {"form-name": "donna-contact", "name": "Pat Example", "phone": "613-555-0100", "email": "", "business": "Pat's HVAC", "message": "Missed calls",
                "consent_version": W.CONSENT_VERSION}
        base.update(d)
        return {"id": "abc123", "form_name": "donna-contact", "created_at": "2026-11-22T10:00:00Z", "data": base}

    def test_consent_recorded_as_stated(self):
        lead = W.lead_from_submission(self.sub(), DONNA)
        self.assertIn("implied consent to answer the inquiry", lead["consent_basis"])
        self.assertIn("express marketing consent: no", lead["consent_basis"])
        self.assertIn(W.wording_sha256(W.consent(DONNA))[:16], lead["consent_basis"])
        self.assertIn("YES", W.lead_from_submission(self.sub(marketing_consent="yes"), DONNA)["consent_basis"])
        self.assertEqual(lead["source"], "website:donna")

    def test_spam_wrong_form_and_no_contact_skipped(self):
        self.assertIsNone(W.lead_from_submission(self.sub(**{"bot-field": "buy"}), DONNA))
        self.assertIsNone(W.lead_from_submission({**self.sub(), "form_name": "other"}, DONNA))
        self.assertIsNone(W.lead_from_submission(self.sub(phone="", email=""), DONNA))

    def test_import_is_idempotent(self):
        saved = []
        get = lambda p: [{"id": "x"}] if saved and "abc123" in p else []                               # noqa: E731
        post = lambda p, row: saved.append(row)                                                       # noqa: E731
        self.assertIn("1 new lead", W.import_leads(DONNA, [self.sub()], "v1", get, post))
        self.assertIn("0 new lead", W.import_leads(DONNA, [self.sub()], "v1", get, post))
        self.assertEqual(saved[0]["venture_id"], "v1")
        self.assertFalse(saved[0]["do_not_contact"])


PAGE = ('<html><head><meta name="viewport" content="width=device-width"><title>{t}</title></head><body><main><h1>{h}</h1>{form}</main></body></html>')


def form(c, **over):
    attrs = over.get("attrs", f'name="{c["form_name"]}" method="POST" action="/thanks" data-netlify="true" netlify-honeypot="bot-field"')
    box = over.get("box", '<input id="marketing_consent" name="marketing_consent" type="checkbox" value="yes">')
    return (f'<form {attrs}><input name="bot-field"><input type="hidden" name="consent_version" value="{c["version"]}">'
            f'<p>{c["inquiry_notice"]}</p>{box}<label>{c["marketing_checkbox"]}</label></form>')


class QA(unittest.TestCase):
    def dist(self, h="Every call answered.", f=None, extra=""):
        d = tempfile.mkdtemp()
        self.addCleanup(shutil.rmtree, d)
        c = W.consent(DONNA)
        for p in W.PAGES:
            os.makedirs(os.path.dirname(os.path.join(d, p)) or d, exist_ok=True)
            body = PAGE.format(t="Donna.AI", h=h + extra, form=(f if f is not None else form(c)) if p == "index.html" else "DRAFT PLACEHOLDER")
            open(os.path.join(d, p), "w").write(body)
        return d

    def test_clean_page_passes(self):
        probs, review = W.qa_dist(self.dist(), DONNA)
        self.assertEqual(probs, [])
        self.assertTrue(any("placeholder" in r for r in review))

    def test_violations_are_caught(self):
        c = W.consent(DONNA)
        cases = {
            "external script": dict(extra='<script src="https://cdn.example.com/x.js"></script>'),
            "AI cliché": dict(h="Unlock seamless growth"),
            "claim not allowed": dict(h="Trusted by 500 businesses"),
            "template leftover": dict(h="Built with AstroWind"),
            "posts to another site": dict(f=form(c, attrs=f'name="{c["form_name"]}" method="POST" action="https://evil.example/x" data-netlify="true" netlify-honeypot="bot-field"')),
            "unticked and optional": dict(f=form(c, box='<input name="marketing_consent" type="checkbox" checked>')),
            "no contact form": dict(f=""),
        }
        for want, kw in cases.items():
            probs, _ = W.qa_dist(self.dist(**kw), DONNA)
            self.assertTrue(any(want in p for p in probs), (want, probs))


@unittest.skipUnless(os.path.isdir(os.path.join(W.ROOT, W.TEMPLATES["astrowind"]["path"], "node_modules")) and shutil.which("npm"),
                     "template dependencies not installed (CI's site job installs them)")
class RealBuild(unittest.TestCase):
    def test_donna_builds_and_passes_qa(self):
        out = tempfile.mkdtemp(prefix="ws-test-")
        self.addCleanup(shutil.rmtree, out, True)
        r = W.build("donna", out)
        self.assertEqual(r["problems"], [])
        self.assertTrue(os.path.exists(r["zip"]))


if __name__ == "__main__":
    unittest.main()
