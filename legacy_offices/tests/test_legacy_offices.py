"""Legacy offices: registry, redaction, runner isolation, Office Doctor, Quality Control. Stdlib only, no network (GitHub is a fake).
Run from the repo root:  python3 -m unittest legacy_offices.tests.test_legacy_offices
All data here is SYNTHETIC: these tests prove the logic, not production results."""
import asyncio
import json
import os
import re
import sqlite3
import tempfile
import unittest
from datetime import datetime, timedelta, timezone

from legacy_offices import commands, doctor, qc, redact, registry, runner

NOW = datetime(2026, 11, 23, 18, 0, tzinfo=timezone.utc)
TEMPLATE = json.load(open(os.path.join(os.path.dirname(registry.HERE), "offices", "TEMPLATE.json")))


def iso(dt):
    return dt.strftime("%Y-%m-%dT%H:%M:%SZ")


class FakeGH:
    """Answers the doctor's GET paths from a dict of prefixes; records the paths asked."""
    def __init__(self, routes):
        self.routes, self.asked = routes, []

    def __call__(self, path):
        self.asked.append(path)
        for k, v in self.routes.items():
            if path.startswith(k):
                return v
        return None, "GitHub 404"


def runs(days_ok=1, fail_last=False, minutes=100, n=28):
    out = []
    if fail_last:
        out.append({"id": 99, "status": "completed", "conclusion": "failure", "run_started_at": iso(NOW - timedelta(hours=20)), "updated_at": iso(NOW - timedelta(hours=20))})
    for i in range(n):
        start = NOW - timedelta(days=days_ok + i, minutes=minutes)
        out.append({"id": i, "status": "completed", "conclusion": "success", "run_started_at": iso(start), "updated_at": iso(start + timedelta(minutes=minutes))})
    return {"workflow_runs": out}


def commit(dt):
    return [{"commit": {"committer": {"date": iso(dt)}}}]


class Registry(unittest.TestCase):
    def test_offices_follow_template_and_resolve(self):
        self.assertEqual(sorted(registry.slugs()), ["freelance-hunter", "paper-trading", "power-dialer", "realestate-ca"])
        for slug in registry.slugs():
            o = registry.office(slug)
            self.assertEqual(o["office"], slug)
            self.assertEqual(o["brain_scope"], ["group", slug])
            self.assertTrue(o["agents"])
            for a in o["agents"]:
                self.assertTrue(set(a) <= set(TEMPLATE["agent_fields"]) | {"role"}, a)
                self.assertIn(a["model_tier"], ("small", "medium"))
                self.assertGreater(len(a["prompt"]), 40)
            lg = o["legacy"]
            self.assertTrue(lg["repo"].startswith("thedonnasystem/") and lg["private"])
            self.assertTrue(all(re.fullmatch(r"[A-Z][A-Z0-9_]*", e) for e in lg["env"]), "env lists NAMES only")
            self.assertEqual(len(sorted(o["qc"]["changes"], key=lambda c: -c["impact"])[:3]), 3)
        for k, v in {"wholesale": "realestate-ca", "Real Estate": "realestate-ca", "dialer": "power-dialer", "freelance": "freelance-hunter",
                     "trading": "paper-trading", "n8n": "n8n-railway"}.items():
            self.assertEqual(registry.resolve(k), v, k)
        self.assertIsNone(registry.resolve("donna"))
        self.assertFalse(registry.office("n8n-railway")["viable"])

    def test_no_private_data_or_values_in_public_files(self):
        blob = ""
        for root, _, files in os.walk(registry.HERE):
            for f in files:
                if f.endswith(".json"):
                    with open(os.path.join(root, f), encoding="utf-8") as fh:
                        blob += fh.read()
        self.assertFalse(redact.looks_private(blob), "office files must hold no email, phone, address, postal code, key or token")
        self.assertNotRegex(blob, r"(?i)(\bsk-[a-z0-9]|ghp_|eyJ[A-Za-z0-9_-]{10})")


class Redaction(unittest.TestCase):
    def test_secrets_and_personal_data_removed(self):
        t = ("ANTHROPIC_API_KEY=sk-ant-abc123def456ghi789 Bearer abcdefghijklmnop token ghp_" + "a" * 30 +
             " mail jo@example.com call 613-555-0142 at 12 Main Street, K2J 4B1 https://x.invalid/a?id=5 bot 123456789:" + "b" * 35)
        out = redact.text(t)
        for leak in ("sk-ant", "abcdefghijklmnop", "ghp_", "jo@example.com", "613-555-0142", "Main Street", "K2J 4B1", "?id=5", "bbbbbbbbbb"):
            self.assertNotIn(leak, out)
        self.assertFalse(redact.looks_private(out))
        self.assertIn("PIPELINE_TOKEN", redact.text("needs PIPELINE_TOKEN, ANTHROPIC_API_KEY"), "bare variable NAMES survive")


class Runner(unittest.TestCase):
    def test_child_env_is_empty_but_for_safe_keys(self):
        env = runner.child_env({"MOCK_TELNYX": "1"}, base={"PATH": "/bin", "SUPABASE_SERVICE_KEY": "x", "TELEGRAM_BOT_TOKEN": "y", "HOME": "/h"})
        self.assertEqual(env, {"PATH": "/bin", "HOME": "/h", "MOCK_TELNYX": "1"})
        with self.assertRaises(ValueError):
            runner.child_env({"TELNYX_API_KEY": "x"})

    def test_run_contained(self):
        d = tempfile.mkdtemp()
        self.assertTrue(runner.run(["true"], d)["ok"])
        self.assertFalse(runner.run(["false"], d)["ok"])
        with self.assertRaises(ValueError):
            runner.run(["true"], d, cwd="../..")
        with self.assertRaises(ValueError):
            runner.run("true", d)


class Doctor(unittest.TestCase):
    def gh_wholesale(self, fail=True, minutes=100):
        return FakeGH({
            "/repos/thedonnasystem/canada-wholesale-pipeline/commits?path=": (commit(NOW - timedelta(days=2.8)), None),
            "/repos/thedonnasystem/canada-wholesale-pipeline/commits": (commit(NOW - timedelta(days=2)), None),
            "/repos/thedonnasystem/canada-wholesale-pipeline/actions/runs/99/jobs": ({"jobs": [{"id": 7, "steps": []}]}, None),
            "/repos/thedonnasystem/canada-wholesale-pipeline/actions/runs": (runs(fail_last=fail, minutes=minutes), None),
            "/repos/thedonnasystem/canada-wholesale-pipeline/check-runs/7/annotations": (
                [{"message": "The job was not started because recent account payments have failed or your spending limit needs to be increased."}], None),
            "/repos/thedonnasystem/canada-wholesale-pipeline/actions/secrets": (None, "GitHub 403"),
        })

    def test_billing_stop_is_diagnosed_and_ranked_first(self):
        rep = doctor.examine("realestate-ca", gh=self.gh_wholesale(), src_dir="", now=NOW)
        self.assertEqual(rep["status"], "broken")
        self.assertIn("payments have failed", rep["diagnosis"])
        self.assertTrue(rep["fixes"][0].startswith("owner: GitHub Settings > Billing"))
        spend = next(f for f in rep["findings"] if f["check"] == "spend")
        self.assertEqual(spend["status"], "fail")
        self.assertGreater(spend["minutes_month"], 2000)
        data = next(f for f in rep["findings"] if f["check"] == "data")
        self.assertEqual(data["status"], "fail")
        self.assertEqual(next(f for f in rep["findings"] if f["check"] == "env")["status"], "unknown")

    def test_healthy_actions_office(self):
        gh = self.gh_wholesale(fail=False, minutes=20)
        gh.routes["/repos/thedonnasystem/canada-wholesale-pipeline/commits?path="] = (commit(NOW - timedelta(hours=5)), None)
        rep = doctor.examine("realestate-ca", gh=gh, src_dir="", now=NOW)
        by = {f["check"]: f["status"] for f in rep["findings"]}
        self.assertEqual((by["last_run"], by["spend"], by["data"]), ("ok", "ok", "ok"))

    def test_railway_office_without_telemetry_and_with_host_state(self):
        gh = FakeGH({"/repos/thedonnasystem/freelance-pipeline/commits": (commit(NOW - timedelta(days=117)), None)})
        rep = doctor.examine("freelance-hunter", gh=gh, src_dir="", now=NOW)
        by = {f["check"]: f for f in rep["findings"]}
        self.assertEqual(by["last_run"]["status"], "unknown")
        self.assertEqual(by["activity"]["status"], "warn")
        self.assertEqual(by["tests"]["status"], "warn")       # the repo has no tests
        p = os.path.join(tempfile.mkdtemp(), "h.json")
        json.dump({"freelance-hunter": {"deployed": False, "note": "deployment removed", "checked": "2026-11-23"}}, open(p, "w"))
        os.environ["LEGACY_HOST_STATE"] = p
        try:
            rep = doctor.examine("freelance-hunter", gh=gh, src_dir="", now=NOW)
        finally:
            del os.environ["LEGACY_HOST_STATE"]
        self.assertEqual(rep["status"], "broken")
        self.assertIn("redeploy", rep["fixes"][0])

    def test_tests_run_in_clone_and_missing_deps_are_not_failures(self):
        src = tempfile.mkdtemp()
        os.makedirs(os.path.join(src, "mss-ifvg-paper"))
        gh = FakeGH({"/repos/thedonnasystem/mss-ifvg-paper/commits": (commit(NOW), None)})
        seen = []
        ok = lambda argv, root, cwd, env, t: seen.append((argv, root)) or {"ok": True, "out": ""}  # noqa: E731
        rep = doctor.examine("paper-trading", gh=gh, run=ok, src_dir=src, now=NOW)
        self.assertEqual(next(f for f in rep["findings"] if f["check"] == "tests")["status"], "ok")
        self.assertTrue(seen and seen[0][1].endswith("mss-ifvg-paper"))
        nodeps = lambda *a: {"ok": False, "out": "ModuleNotFoundError: No module named 'fastapi'"}  # noqa: E731
        rep = doctor.examine("paper-trading", gh=gh, run=nodeps, src_dir=src, now=NOW)
        self.assertEqual(next(f for f in rep["findings"] if f["check"] == "tests")["status"], "unknown")
        bad = lambda *a: {"ok": False, "out": "AssertionError token=sk-ant-secretsecret123"}  # noqa: E731
        rep = doctor.examine("paper-trading", gh=gh, run=bad, src_dir=src, now=NOW)
        t = next(f for f in rep["findings"] if f["check"] == "tests")
        self.assertEqual(t["status"], "fail")

    def test_deps_check(self):
        src = tempfile.mkdtemp()
        os.makedirs(os.path.join(src, "freelance-pipeline"))
        open(os.path.join(src, "freelance-pipeline", "requirements.txt"), "w").write("a>=1\nb>=2\nc\nd==1.0\n")
        gh = FakeGH({"/repos/thedonnasystem/freelance-pipeline/commits": (commit(NOW), None)})
        rep = doctor.examine("freelance-hunter", gh=gh, src_dir=src, now=NOW)
        self.assertEqual(next(f for f in rep["findings"] if f["check"] == "deps")["status"], "warn")

    def test_not_viable(self):
        rep = doctor.examine("n8n-railway", gh=FakeGH({}), now=NOW)
        self.assertEqual(rep["status"], "not viable")

    def test_plan_sends_only_redacted_structure_with_public_sources(self):
        rep = doctor.examine("realestate-ca", gh=self.gh_wholesale(), src_dir="", now=NOW)
        rep["findings"].append({"check": "tests", "status": "fail", "detail": "x", "reason": "owner jo@example.com key=sk-ant-zzzzzzzzzzzzzz"})
        got = {}

        def fake_complete(system, messages, **kw):
            got.update(kw, prompt=messages[0]["content"])
            return {"text": "1. pay"}
        self.assertEqual(doctor.plan("realestate-ca", rep, complete=fake_complete), "1. pay")
        self.assertEqual(got["sources"], ["system", "repo_code"])
        self.assertEqual(got["tier"], "small")
        self.assertNotIn("jo@example.com", got["prompt"])
        self.assertNotIn("sk-ant", got["prompt"])
        self.assertFalse(redact.looks_private(got["prompt"]))

        def offline(*a, **k):
            raise RuntimeError("no provider")
        self.assertIn("Plan not drafted", doctor.plan("realestate-ca", rep, complete=offline))


def wholesale_clone(with_outcomes=False):
    """A SYNTHETIC clone: funnel_latest.json, corpus.jsonl and optionally outcomes.jsonl with made-up rows."""
    src = tempfile.mkdtemp()
    sd = os.path.join(src, "canada-wholesale-pipeline", "scraper")
    os.makedirs(sd)
    leads = [{"tier": "B" if i < 4 else "C", "priced": i < 6, "buyer_matches": [1] if i < 3 else [], "contact_band": "HOT" if i < 2 else "WARM",
              "market_pos": "INSUFFICIENT_COMPS" if i >= 8 else "MARGIN PASS", "new_today": i == 0} for i in range(10)]
    json.dump({"date": "2026-11-22", "leads": leads}, open(os.path.join(sd, "funnel_latest.json"), "w"))
    with open(os.path.join(sd, "corpus.jsonl"), "w") as f:
        for i in range(50):
            f.write(json.dumps({"norm_address": f"a{i % 45}", "price": 1, "fsa": "X", "first_seen": "2026-11-20" if i < 20 else "2026-10-01"}) + "\n")
    if with_outcomes:
        with open(os.path.join(sd, "outcomes.jsonl"), "w") as f:
            for st, fee in (("contacted", 0), ("contacted", 0), ("replied", 0), ("booked", 0), ("closed", 15000)):
                f.write(json.dumps({"ts": iso(NOW - timedelta(days=1)), "lead": "x", "stage": st, "fee_cad": fee}) + "\n")
    return src


class QualityControl(unittest.TestCase):
    def test_message_rubric(self):
        good = "Your Shopify order sync in n8n is a 2-day build: webhook in, Airtable out, with retries. I built the same flow for a retailer last month. Want a 15-minute call Thursday?"
        bad = "Dear Sir, I hope this message finds you well. I am passionate about AI and I guarantee 10x results."
        self.assertGreaterEqual(qc.score_message(good, ["shopify", "airtable"])["score"], 4)
        self.assertLessEqual(qc.score_message(bad, ["shopify"])["score"], 2)

    def test_wholesale_without_outcomes_says_so_and_finds_the_gap(self):
        r = qc.review("realestate-ca", src_dir=wholesale_clone(), now=NOW)
        self.assertEqual(r["verdict"], "fix")
        self.assertFalse(r["outcome_data"])
        self.assertEqual(r["funnel"]["found"], 20)
        self.assertEqual((r["funnel"]["qualified"], r["funnel"]["priced"], r["funnel"]["buyer_matched"]), (10, 6, 3))
        self.assertIsNone(r["funnel"]["contacted"])
        self.assertIn("cannot be measured past 'buyer_matched'", r["bottleneck"])
        self.assertTrue(any(g.startswith("priced") for g in r["gaps"]))
        self.assertEqual([c["impact"] for c in r["changes"]], sorted([c["impact"] for c in r["changes"]], reverse=True))
        t = qc.text(r)
        self.assertIn("No real outcome data yet", t)
        self.assertFalse(redact.looks_private(t))

    def test_wholesale_with_outcomes_before_after(self):
        before = qc.review("realestate-ca", src_dir=wholesale_clone(False), now=NOW)
        after = qc.review("realestate-ca", src_dir=wholesale_clone(True), now=NOW, state={"realestate-ca": {"funnel": before["funnel"]}})
        self.assertTrue(after["outcome_data"])
        self.assertEqual((after["funnel"]["contacted"], after["funnel"]["replied"], after["funnel"]["booked"], after["funnel"]["closed"]), (2, 1, 1, 1))
        self.assertEqual(after["funnel"]["revenue_week"], 15000.0)
        self.assertIn("no leak", after["bottleneck"])
        self.assertEqual(after["delta"], {"found": 0, "qualified": 0, "priced": 0, "buyer_matched": 0})

    def test_dialer_abandon_rate_from_events(self):
        p = os.path.join(tempfile.mkdtemp(), "events.csv")
        rows = [[iso(NOW - timedelta(hours=1)), t, "n", "p", "", o, ""] for t, o in
                [("answered", "")] * 18 + [("second_answer", "")] * 2 + [("no_answer", "")] * 80 + [("outcome", "pitched")] * 5 + [("outcome", "closed")]]
        rows.append([iso(NOW - timedelta(days=30)), "answered", "n", "p", "", "", ""])
        import csv
        with open(p, "w", newline="") as f:
            csv.writer(f).writerows(rows)
        r = qc.review("power-dialer", now=NOW, events_csv=p)
        self.assertEqual((r["funnel"]["contacted"], r["funnel"]["replied"], r["funnel"]["closed"]), (100, 18, 1))
        self.assertAlmostEqual(r["sizes"]["abandon_rate"], 0.1)
        self.assertTrue(any("abandon rate" in g for g in r["gaps"]))
        self.assertEqual(r["rubric"]["deliverability"][0], 0)
        self.assertNotIn("n,p", qc.text(r))

    def test_freelance_db_and_trading_db_counts_only(self):
        d = tempfile.mkdtemp()
        fp = os.path.join(d, "f.db")
        con = sqlite3.connect(fp)
        con.executescript("create table jobs_seen(job_key text, first_seen_at text); create table proposals(status text, outcome text, sent_at text);")
        con.executemany("insert into jobs_seen values (?, ?)", [(str(i), iso(NOW - timedelta(days=1))) for i in range(5)])
        con.executemany("insert into proposals values (?, ?, ?)", [("sent_for_review", "applied", iso(NOW)), ("sent_for_review", "replied", iso(NOW)),
                                                                    ("sent_for_review", "pending", iso(NOW))])
        con.commit(); con.close()
        r = qc.review("freelance-hunter", now=NOW, db_path=fp)
        self.assertEqual((r["funnel"]["found"], r["funnel"]["qualified"], r["funnel"]["contacted"], r["funnel"]["replied"]), (5, 3, 1, 1))
        tp = os.path.join(d, "p.db")
        con = sqlite3.connect(tp)
        con.executescript("create table signals(key text, ts real); create table kv(k text, v text); "
                          "create table trades(close_ts real, pnl real, r_mult real); insert into kv values ('dashboard_token', 'zzz');")
        con.executemany("insert into trades values (?, ?, ?)", [(1, 10, 1.0), (1, -5, -0.5), (None, None, None)])
        con.execute("insert into signals values ('a', 1)")
        con.commit(); con.close()
        r = qc.review("paper-trading", now=NOW, db_path=tp)
        self.assertEqual(r["verdict"], "keep")
        self.assertEqual((r["funnel"]["found"], r["funnel"]["qualified"], r["funnel"]["closed"]), (1, 3, 2))
        self.assertAlmostEqual(r["sizes"]["win_rate"], 0.5)
        self.assertNotIn("zzz", json.dumps(r))

    def test_kill_and_state_round_trip(self):
        self.assertEqual(qc.review("n8n-railway", now=NOW)["verdict"], "kill")
        p = os.path.join(tempfile.mkdtemp(), "s.json")
        qc.save_state(p, [{"office": "x", "funnel": {"found": 3}}])
        self.assertEqual(qc.load_state(p)["x"]["funnel"], {"found": 3})

    def test_judge_synthetic_only(self):
        self.assertIn("refused", qc.judge([{"id": 1, "post": "p", "draft": "d"}]))
        got = {}

        def fake(system, messages, **kw):
            got.update(kw)
            return {"text": '[{"id": 1, "score": 4, "why": "ok"}]'}
        out = qc.judge([{"id": 1, "post": "Need an n8n flow", "draft": "Happy to help, call?", "synthetic": True}], complete=fake)
        self.assertEqual(out[0]["score"], 4)
        self.assertEqual(got["sources"], ["system"])
        sent = []
        qc.judge([{"id": 1, "post": "call 613-555-0142", "draft": "x", "synthetic": True}], complete=lambda s_, m, **k: sent.append(m[0]["content"]) or {"text": "[]"})
        self.assertNotIn("613-555-0142", sent[0])


class Commands(unittest.TestCase):
    def test_text_and_usage(self):
        self.assertIn("Usage: /doctor", commands.doctor_text([]))
        self.assertIn("Usage: /qc", commands.qc_text(["nope"]))
        self.assertIn("KILL", commands.qc_text(["n8n"]))

    def test_owner_only_and_register(self):
        class U:  # minimal Telegram update
            def __init__(self, uid):
                self.effective_user = type("u", (), {"id": uid})()
                self.message = None
        os.environ["JARVIS_OWNER_ID"] = "1"
        try:
            self.assertTrue(commands._owner(U(1)))
            self.assertFalse(commands._owner(U(2)))
            asyncio.run(commands.doctor_cmd(U(2), type("c", (), {"args": ["all"]})()))   # stranger: returns silently, nothing runs
        finally:
            del os.environ["JARVIS_OWNER_ID"]
        added = []

        class App:
            def add_handler(self, h):
                added.append(h)
        commands.register(App(), lambda name, fn: (name, fn))
        self.assertEqual([a[0] for a in added], ["doctor", "qc"])


if __name__ == "__main__":
    unittest.main()
