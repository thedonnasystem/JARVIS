"""Checks for the Donna.AI launch kit: python3 -m unittest launch/donna/test_launch_kit.py (from the repo root) or run it directly."""
import csv
import json
import os
import re
import shutil
import subprocess
import sys
import tomllib
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))
sys.path.insert(0, os.path.join(HERE, "voice"))
import retell_push as R  # noqa: E402


def _read(*parts):
    with open(os.path.join(*parts), encoding="utf-8") as f:
        return f.read()


SITE = json.loads(_read(ROOT, "sites", "donna", "site.json"))
PROMPTS = {n: _read(HERE, "voice", "prompts", f"{n}.txt") for n in ("demo_line", "client_template", "web_qualify")}


class Voice(unittest.TestCase):
    def test_built_files_match_source(self):
        for name, spec in R.load_source().items():
            llm, agent = R.bodies(name, spec)
            for kind, body in (("llm", llm), ("agent", agent)):
                with open(os.path.join(HERE, "voice", "retell", f"{name}.{kind}.json"), encoding="utf-8") as f:
                    self.assertEqual(json.load(f), body, f"{name}.{kind}.json is stale: run retell_push.py build")

    def test_configs_match_retell_schema(self):
        for k, problems in R.validate().items():
            self.assertEqual(problems, [], k)

    def test_validator_catches_bad_values(self):
        with open(os.path.join(HERE, "voice", "retell", "demo_line.agent.json"), encoding="utf-8") as f:
            a = json.load(f)
        self.assertTrue(R.problems({**a, "voice_speed": 5}, "CreateAgentBody"))
        self.assertTrue(R.problems({**a, "langauge": "en-US"}, "CreateAgentBody"))
        self.assertTrue(R.problems({k: v for k, v in a.items() if k != "voice_id"}, "CreateAgentBody"))

    def test_agents_disclose_ai_and_recording_first(self):
        src = R.load_source()
        self.assertEqual(sorted(src), ["demo_line", "web_qualify"])
        for name in src:
            msg = src[name]["llm"]["begin_message"]
            self.assertIn("AI", msg)
            self.assertIn("recorded", msg)
            self.assertIn("what kind of business do you run", msg)

    def test_prompts_keep_the_honesty_rules(self):
        for name, p in PROMPTS.items():
            self.assertRegex(p, r"(?i)you are (the )?(an )?ai", name)
            self.assertIn("card numbers", p, name)
            self.assertIn("911", p, name)
            self.assertRegex(p, r"(?i)never give medical, dental, legal", name)
        d = PROMPTS["demo_line"]
        self.assertIn("MADE UP", d)
        self.assertIn("Never claim to be a real business", d)
        self.assertIn("Never claim clients, results, reviews", d)

    def test_demo_covers_every_industry_without_centering_one(self):
        d = PROMPTS["demo_line"]
        for company in ("Northbeam Home Services", "Willow & Ash Studio", "Larkfield Family Dental & Wellness", "Hollis & Grey Law",
                        "Ironclad Auto Care", "Keystone Home Team", "Fresh Slate Property Care", "Example & Co."):
            self.assertIn(company, d)
        self.assertIn("No legal advice", d)
        self.assertIn("no medical or dental advice", d)
        self.assertNotIn("agent_swap", json.dumps(R.load_source()))

    def test_prices_stay_off_the_calls(self):
        items = {i["title"]: i for g in SITE["pricing"] if g["id"] == "packages" for i in g["items"]}
        self.assertEqual(items["Essential"]["price_label"], "From $197")
        self.assertFalse(any("price" in i for i in items.values()), "the site shows no package prices")
        for name in ("demo_line", "web_qualify"):
            p = PROMPTS[name]
            self.assertIn("Plans start at $197 a month", p)
            self.assertIn("December 31", p)
            self.assertIn("our AI specialist", p)
            for amount in ("$497", "$797", "$1,297", "$697", "$1,097", "$1,797"):
                self.assertNotIn(amount, p, f"{name} quotes {amount}")
            self.assertNotIn("founding", p.lower())

    def test_web_agent(self):
        src = R.load_source()
        self.assertIn("web_qualify", src)
        llm, agent = R.bodies("web_qualify", src["web_qualify"])
        self.assertEqual([t["type"] for t in llm["general_tools"]], ["end_call"])
        self.assertIn("I'm an AI", llm["begin_message"])
        w = PROMPTS["web_qualify"]
        for k in ("Never promise a number of customers", "Never name or criticize another company", "Give a taste, not the blueprint"):
            self.assertIn(k, w)

    def test_no_secrets_or_ids_in_the_kit(self):
        for base, _, files in os.walk(HERE):
            for n in files:
                if n.endswith((".json", ".txt", ".md", ".py", ".toml", ".html", ".sh", ".csv")) and "schema" not in base:
                    t = _read(base, n)
                    self.assertNotRegex(t, r"key_[A-Za-z0-9]{20,}|agent_[0-9a-f]{20,}|llm_[0-9a-f]{20,}|hook\.[a-z0-9]+\.make\.com/[A-Za-z0-9]{10,}", n)

    def test_fill_drops_optional_tools_and_fields(self):
        llm, agent = R.bodies("demo_line", R.load_source()["demo_line"])
        self.assertEqual([x["name"] for x in R.fill(llm, {}, set())["general_tools"]], ["end_call"])
        full = R.fill(llm, {"DONNA_FOUNDER_MOBILE": "+15555550100"}, set())
        self.assertEqual(full["general_tools"][1]["transfer_destination"]["number"], "+15555550100")
        self.assertNotIn("webhook_url", R.fill(agent, {}, set()))
        with self.assertRaises(SystemExit):
            R.fill(llm, {}, {"DONNA_FOUNDER_MOBILE"})


class Site(unittest.TestCase):
    def test_demo_line_on_site_and_valid(self):
        import importlib.util
        spec = importlib.util.spec_from_file_location("hq_webstudio", os.path.join(ROOT, "hq_webstudio.py"))
        W = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(W)
        self.assertEqual(W.validate(SITE), [])
        self.assertEqual(SITE["links"]["demo_phone"], "+1 (825) 462-1250")

    def test_netlify_config(self):
        with open(os.path.join(HERE, "netlify.toml"), "rb") as f:
            b = tomllib.load(f)["build"]
        self.assertEqual(b["command"], "bash build_site.sh")
        self.assertEqual(b["publish"], ".out/dist")
        self.assertEqual(b["ignore"], "exit 1", "always build: Netlify skips builds when only files outside the base directory changed")
        self.assertIn("build donna --out", _read(HERE, "build_site.sh"))


class Offer(unittest.TestCase):
    html = _read(HERE, "offer_sheet.html")

    def test_prices_and_december_offer(self):
        self.assertIn('<span class="amt gold">$197</span>', self.html)
        self.assertEqual(self.html.count('<span class="amt gold">Tailored</span>'), 3, "Front Desk, Growth, AI Systems: quoted from the audit, like the site")
        for name in ("Essential", "Front Desk", "Growth", "AI Systems"):
            self.assertIn(f"<h2>{name}</h2>", self.html)
        self.assertIn("Start here", self.html)
        for k in ("Free 20-min Revenue Leak Audit", "Setup free until Dec 31", "Month-to-month", "Test line first", "+1 (825) 462-1250",
                  "We turn your missed calls and missed leads"):
            self.assertIn(k, self.html)
        self.assertNotIn("founding", self.html.lower())

    def test_industry_neutral(self):
        text = re.sub(r"<!--.*?-->", " ", self.html, flags=re.S)
        self.assertNotRegex(text, r"(?i)furnace|heating company|hvac")
        self.assertIn("what kind of business you run", text)
        self.assertIn('class="example"', text)

    def test_no_reference_price_or_claim_words(self):
        text = re.sub(r"<[^>]+>", " ", re.sub(r"<style.*?</style>", " ", self.html, flags=re.S))
        self.assertNotRegex(text, r"(?i)\b(regular price|was \$|normally|guarantee|refund|testimonial|trusted by|reviews?(?! requests))\b")
        self.assertNotIn("<s>", self.html)
        self.assertNotIn("line-through", self.html)


class Sheets(unittest.TestCase):
    def test_log_sheets_have_headers(self):
        with open(os.path.join(HERE, "audit_log.csv"), encoding="utf-8") as f:
            head = next(csv.reader(f))
        for col in ("published_email", "email_seen_at_url", "email_seen_date", "night_outcome", "do_not_contact"):
            self.assertIn(col, head)
        with open(os.path.join(HERE, "scoreboard.csv"), encoding="utf-8") as f:
            self.assertIn("founding_spots_sold", next(csv.reader(f)))


if __name__ == "__main__":
    unittest.main()


class LeadAlerts(unittest.TestCase):
    def test_functions_and_config(self):
        toml = _read(HERE, "netlify.toml")
        self.assertIn('directory = "netlify/functions"', toml)
        fns = sorted(os.listdir(os.path.join(HERE, "netlify", "functions")))
        self.assertEqual(fns, ["retell-webhook.mjs", "submission-created.mjs"], "only real functions live in the functions folder")
        src = _read(HERE, "netlify", "lib", "alert.mjs")
        self.assertIn("timingSafeEqual", src)
        self.assertNotRegex(src, r"(?i)(bot\d{6,}:|key_[a-z0-9]{10,})", "no secrets in code")

    @unittest.skipUnless(shutil.which("node"), "node not installed")
    def test_node_suite(self):
        r = subprocess.run(["node", "--test", os.path.join(HERE, "netlify", "alert.test.mjs")], capture_output=True, text=True, timeout=120)
        self.assertEqual(r.returncode, 0, r.stdout[-2000:] + r.stderr[-2000:])
