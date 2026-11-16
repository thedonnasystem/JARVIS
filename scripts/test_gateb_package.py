import datetime
import hashlib
import json
import os
import tempfile
import unittest

import gateb_package as g

HEAD = "a" * 40
OLD = "b" * 40
NOW = datetime.datetime(2026, 11, 16, 12, 0, 0, tzinfo=datetime.timezone.utc)


class FakeEnv(g.Env):
    """gh / git / files from dicts; no network, no subprocess."""

    def __init__(self, gh=None, blobs=None, files=None, moved=None):
        super().__init__(repo_dir="/nonexistent", now=lambda: NOW, no_fetch=True)
        self._gh, self._blobs, self._files = gh or {}, blobs or {}, files or {}
        self._moved = moved or {}
        self.calls = []

    def gh(self, path):
        self.calls.append(path)
        if path in self._moved and self.calls.count(path) > 1:
            return json.dumps(self._moved[path]).encode(), None
        if path not in self._gh:
            return None, "HTTP 404"
        return json.dumps(self._gh[path]).encode(), None

    def git(self, *a):
        if a[0] == "show":
            sha, _, path = a[1].partition(":")
            return self._blobs.get((sha, path))
        if a[0] == "ls-tree":
            sha = a[3]
            prefix = a[4] if len(a) > 4 else ""
            return "\n".join(sorted(p for (s, p) in self._blobs if s == sha and p.startswith(prefix))).encode()
        if a[0] == "cat-file":
            return b""
        return b""

    def git_grep(self, sha, pattern):
        import re
        out = []
        for (s, p), data in self._blobs.items():
            if s == sha and p.endswith(".py"):
                for i, line in enumerate(data.decode().splitlines(), 1):
                    if re.search(pattern, line):
                        out.append(f"{sha}:{p}:{i}:{line}")
        return "\n".join(out).encode()

    def read_file(self, path):
        return self._files.get(path)


def pr_json(n, sha=HEAD, ref="build/x"):
    return {"number": n, "html_url": f"https://github.com/x/y/pull/{n}", "head": {"ref": ref, "sha": sha}, "base": {"ref": "overnight-build"}, "title": "t", "state": "open", "draft": False, "merged": False}


def gh_base(n=20, sha=HEAD, checks=None):
    d = {
        f"pulls/{n}": pr_json(n, sha),
        "branches/overnight-build": {"commit": {"sha": "c" * 40}},
        "pulls?state=closed&base=overnight-build&sort=updated&direction=desc&per_page=30": [{"number": 19, "head": {"ref": "b"}, "merged_at": "2026-11-15T20:00:00Z", "merge_commit_sha": "d" * 40}],
        f"compare/overnight-build...{sha}": {"ahead_by": 3, "behind_by": 0, "status": "ahead"},
        f"commits/{sha}/check-runs?per_page=100": {"total_count": 3, "check_runs": checks if checks is not None else [{"name": n_, "status": "completed", "conclusion": "success", "html_url": "u"} for n_ in ("unit", "migrations", "secret-scan")]},
    }
    return d


ACL = "kind\tname\tanon\tauthenticated\tservice_role\tsecurity\tnote\nfunction\tf(text)\t-\t-\texecute\tsecurity_definer\t\ntable\tleads\t-\t-\tselect\trls=true\t\n"
OWNER = "# Owner\n## A. Gates\n| # | Decision | Default | Blocks release? |\n|---|---|---|---|\n| A1 | Merge it | Approve | Yes |\n"


def blobs(sha=HEAD, extra=None):
    b = {
        (sha, "migrations/APPLY_ORDER.txt"): b"# c\n20261112_a.sql\n20261112_lockdown_v1.sql\n",
        (sha, "migrations/20261112_a.sql"): b"x",
        (sha, "migrations/20261112_lockdown_v1.sql"): b"x",
        (sha, "ops/ACL_MANIFEST_public.tsv"): ACL.encode(),
        (sha, "ops/rollback_x.sql"): b"x",
        (sha, "OWNER_DECISIONS.md"): OWNER.encode(),
        (sha, ".github/workflows/tests.yml"): b"jobs:\n  unit:\n    runs-on: x\n  migrations:\n    steps:\n      - run: scripts/gate.sh --strict\n",
        (sha, "test_hq_backup.py"): b"class T:\n    def test_concurrent_run_is_refused(self):\n        pass\n",
    }
    b.update(extra or {})
    return b


def args(**kw):
    ns = g.argparse.Namespace(pr=[20], branch=[], manifest=None, gate_log=[], unit_log=[], drill_results=[], findings=[], rollback_result=[], differential_log=[], acl_manifest=[], resolutions=None, doc=None, prod_baseline="/nope", prod_compare=None, max_prod_age_hours=24, no_defaults=True, no_fetch=True, repo_dir=None)
    for k, v in kw.items():
        setattr(ns, k, v)
    return ns


def make(env, **kw):
    p, ts = g.build(args(**kw), env)
    text = g.render(p, ts, args(**kw))
    return p, ts, text


def lines(p, sec, bucket=None):
    return [(b, t) for b, t, _ in p.sec[sec] if bucket is None or b == bucket]


GOOD_LOG = """# gateb-binding: head=%s
>>> unit: python3 -m unittest discover -q (repo tests)
    Ran 5 tests in 0.1s

    OK
>>> replica: x
    rollback drill OK (and the migrations re-apply cleanly afterwards)
    REPLICA OK
================ GATE SUMMARY ================
STEP           RESULT   DETAIL
unit           PASS     python3 -m unittest
replica        PASS     replica run
manifest       PASS     acl manifest ok
backup         PASS     backup
GATE PASSED: 4 steps passed
    acl manifest matches
    82/82 checks passed
"""


class Parsers(unittest.TestCase):
    FIND = """# RV: PR #20 @ %s
## Verdict: NOT CLEAN (0 BLOCKER, 2 SHOULD-FIX, 1 NOTE)
## Findings
### F1 SHOULD-FIX: first thing
Status: fixed in abc123
body
### F2 SHOULD-FIX: owner call
A policy call for the owner.
### N1 NOTE: minor
text
### B2 transition triggers: PARTIAL
no severity here so it is not a finding
- NOTE B9 bullet-only note is not a heading finding
""" % OLD

    def test_findings(self):
        sha, verdict, vc, fl = g.parse_findings(self.FIND)
        self.assertEqual(sha, OLD)
        self.assertEqual(vc, {"BLOCKER": 0, "SHOULD-FIX": 2, "NOTE": 1})
        self.assertEqual([(f["id"], f["severity"], f["status"]) for f in fl], [("F1", "SHOULD-FIX", "fixed"), ("F2", "SHOULD-FIX", "status unknown"), ("N1", "NOTE", "status unknown")])
        self.assertTrue(fl[1]["owner_flag"])
        self.assertFalse(any(f["id"] == "B2" for f in fl))

    def test_verdict_line_is_not_a_finding(self):
        _, _, _, fl = g.parse_findings("## Verdict: NOT CLEAN (no BLOCKER; 5 SHOULD-FIX)\n")
        self.assertEqual(fl, [])

    def test_status_variants(self):
        for word, want in (("owner decision", "owner-decision"), ("open", "open"), ("not fixed yet", "open"), ("resolved", "fixed"), ("???", "status unknown")):
            _, _, _, fl = g.parse_findings(f"### F1 NOTE: t\nStatus: {word}\n")
            self.assertEqual(fl[0]["status"], want, word)

    def test_gate_log(self):
        r = g.parse_gate_log(GOOD_LOG % HEAD)
        self.assertEqual(r["steps"]["replica"][0], "PASS")
        self.assertTrue(r["has_summary"] and r["rollback_ok"] and r["acl_match"])
        self.assertEqual(r["ran"], [(5, "OK")])
        self.assertEqual(r["drill"], [(82, 82)])

    def test_truncated_gate_log_has_no_summary(self):
        r = g.parse_gate_log(">>> unit: x\n    Ran 3 tests in 1s\n\n    OK\n>>> replica: y\n")
        self.assertFalse(r["has_summary"])
        self.assertEqual(r["steps"], {})
        self.assertEqual(r["seen"], ["unit", "replica"])

    def test_unit_log_with_docstring_lines(self):
        t = "test_a (m.C.test_a) ... ok\ntest_b (m.C.test_b)\nDoc first line ... FAIL\ntest_c (m.C.test_c) ... skipped 'x'\n"
        r = g.parse_unit_log(t)
        self.assertEqual(r["test_a"], [("m.C.test_a", "ok")])
        self.assertEqual(r["test_b"][0][1], "FAIL")
        self.assertTrue(r["test_c"][0][1].startswith("skipped"))

    def test_owner_md_table_and_dedupe_text(self):
        its = g.parse_owner_md(OWNER + "## C. Para\nA long enough paragraph line about a decision here.\n")
        self.assertEqual(its[0]["text"], "A1 Merge it | default: Approve | blocks release: Yes")
        self.assertEqual(len(its), 2)

    def test_bind(self):
        self.assertEqual(g.bind(None, HEAD), "unbound")
        self.assertEqual(g.bind(HEAD[:9], HEAD), "head")
        self.assertEqual(g.bind(OLD, HEAD), "older")
        self.assertEqual(g.bind("abc", HEAD), "older")  # too short to bind

    def test_split_path_sha(self):
        self.assertEqual(g.split_path_sha("20=/a/b.log@" + OLD[:12]), ("20", "/a/b.log", OLD[:12]))
        self.assertEqual(g.split_path_sha("20=/a/b.log"), ("20", "/a/b.log", None))


class Core(unittest.TestCase):
    def test_add_refuses_unbacked_verified(self):
        p = g.Pkg(FakeEnv())
        with self.assertRaises(ValueError):
            p.add("s1", "VERIFIED", "claim", [])
        with self.assertRaises(ValueError):
            p.add("s1", "TESTED IN SCRATCH", "claim", [])
        with self.assertRaises(ValueError):
            p.add("s1", "VERIFIED", "claim", ["E99"])
        p.add("s1", "UNTESTED", "fine without evidence", [])

    def test_full_run_renders_and_passes_check(self):
        env = FakeEnv(gh=gh_base(), blobs=blobs())
        p, ts, text = make(env)
        self.assertEqual(g.check_package(text, recheck_files=False), [])
        for n, (k, title, _) in enumerate(g.SECTIONS, 1):
            self.assertIn(f"## {n}. {title}", text)
        b = {x for k in p.sec for x, _, _ in p.sec[k]}
        self.assertIn("VERIFIED", b)
        self.assertTrue(any(f"head `{HEAD}`" in t for _, t in lines(p, "s1", "VERIFIED")))
        self.assertTrue(any("all 3 check-runs" in t for _, t in lines(p, "s9", "VERIFIED")))
        self.assertTrue(any("lockdown is LAST" in t for _, t in lines(p, "s2", "VERIFIED")))
        self.assertTrue(any(b_ == "REQUIRES OWNER DECISION" and "A1 Merge it" in t for b_, t in lines(p, "s14")))

    def test_api_failure_is_untested_not_a_crash(self):
        p, ts, text = make(FakeEnv(gh={}, blobs={}))
        self.assertTrue(any("head SHA unknown" in t for _, t in lines(p, "s1", "UNTESTED")))
        self.assertEqual(g.check_package(text, recheck_files=False), [])

    def test_failing_ci_is_not_verified_green(self):
        checks = [{"name": "unit", "status": "completed", "conclusion": "failure", "html_url": "u"}, {"name": "migrations", "status": "in_progress", "conclusion": None, "html_url": "u"}]
        p, _, _ = make(FakeEnv(gh=gh_base(checks=checks), blobs=blobs()))
        self.assertFalse(any("all" in t and "success" in t for _, t in lines(p, "s9", "VERIFIED")))
        self.assertTrue(any("not success or still running" in t for _, t in lines(p, "s9", "UNTESTED")))

    def test_no_check_runs_is_untested(self):
        p, _, _ = make(FakeEnv(gh=gh_base(checks=[]), blobs=blobs()))
        self.assertTrue(any("NO check-runs" in t for _, t in lines(p, "s9", "UNTESTED")))

    def test_head_moving_during_run_is_reported(self):
        env = FakeEnv(gh=gh_base(), blobs=blobs(), moved={"pulls/20": pr_json(20, OLD)})
        p, _, _ = make(env)
        self.assertTrue(any("HEAD MOVED" in t for _, t in lines(p, "s1", "UNTESTED")))

    def test_pr_not_in_manifest_key_is_an_error(self):
        env = FakeEnv(gh=gh_base(), blobs=blobs())
        with self.assertRaises(SystemExit):
            g.build(args(gate_log=["99=/x"]), env)


class Binding(unittest.TestCase):
    def run_log(self, text, suffix=""):
        env = FakeEnv(gh=gh_base(), blobs=blobs(), files={"/l.log": text.encode()})
        p, _, _ = make(env, gate_log=["20=/l.log" + suffix])
        return p

    def test_log_bound_to_head_is_scratch(self):
        p = self.run_log(GOOD_LOG % HEAD)
        self.assertTrue(any("gate step replica = PASS" in t for _, t in lines(p, "s10", "TESTED IN SCRATCH")))
        self.assertTrue(any("rollback drill OK" in t for _, t in lines(p, "s11", "TESTED IN SCRATCH")))
        self.assertTrue(any("acl manifest" in t for _, t in lines(p, "s3", "TESTED IN SCRATCH")))

    def test_log_for_older_commit_is_never_scratch(self):
        p = self.run_log(GOOD_LOG % OLD)
        self.assertEqual(lines(p, "s10", "TESTED IN SCRATCH"), [])
        self.assertTrue(any("NOT the current head" in t for _, t in lines(p, "s10", "UNTESTED")))

    def test_unbound_log_is_never_scratch(self):
        p = self.run_log("\n".join(GOOD_LOG.splitlines()[1:]))
        self.assertEqual(lines(p, "s10", "TESTED IN SCRATCH"), [])
        self.assertTrue(any("not bound to a commit" in t for _, t in lines(p, "s10", "UNTESTED")))

    def test_binding_via_cli_suffix(self):
        p = self.run_log("\n".join(GOOD_LOG.splitlines()[1:]), "@" + HEAD[:12])
        self.assertTrue(lines(p, "s10", "TESTED IN SCRATCH"))

    def test_truncated_log_is_untested(self):
        p = self.run_log(f"# head={HEAD}\n>>> unit: x\n    Ran 3 tests in 1s\n\n    OK\n>>> replica: y\n")
        self.assertEqual(lines(p, "s10", "TESTED IN SCRATCH"), [])
        self.assertTrue(any("no GATE SUMMARY" in t for _, t in lines(p, "s10", "UNTESTED")))

    def test_failed_step_is_not_a_pass_line(self):
        bad = (GOOD_LOG % HEAD).replace("replica        PASS ", "replica        FAIL ")
        p = self.run_log(bad)
        self.assertTrue(any("replica = FAIL" in t for _, t in lines(p, "s10", "TESTED IN SCRATCH")))
        self.assertTrue(any("= FAIL" in t for _, t in lines(p, "s13", "UNTESTED")))


class Proofs(unittest.TestCase):
    def test_named_tests_results(self):
        log = f"# gateb-binding: head={HEAD}\ntest_concurrent_run_is_refused (test_hq_backup.T.test_concurrent_run_is_refused) ... ok\n"
        env = FakeEnv(gh=gh_base(), blobs=blobs(), files={"/u.log": log.encode()})
        p, _, _ = make(env, unit_log=["20=/u.log"])
        self.assertTrue(any("test_concurrent_run_is_refused" in t and ": ok" in t for _, t in lines(p, "s6", "TESTED IN SCRATCH")))
        self.assertTrue(any("NOT defined" in t for _, t in lines(p, "s6", "UNTESTED")))

    def test_failed_or_missing_test_result_is_untested(self):
        log = f"# gateb-binding: head={HEAD}\ntest_concurrent_run_is_refused (test_hq_backup.T.test_concurrent_run_is_refused) ... FAIL\n"
        p, _, _ = make(FakeEnv(gh=gh_base(), blobs=blobs(), files={"/u.log": log.encode()}), unit_log=["20=/u.log"])
        self.assertEqual(lines(p, "s6", "TESTED IN SCRATCH"), [])
        self.assertTrue(any("NOT a pass" in t for _, t in lines(p, "s6", "UNTESTED")))
        p2, _, _ = make(FakeEnv(gh=gh_base(), blobs=blobs(), files={"/u.log": f"# head={HEAD}\n".encode()}), unit_log=["20=/u.log"])
        self.assertTrue(any("not present in log" in t for _, t in lines(p2, "s6", "UNTESTED")))

    def test_no_log_means_unknown(self):
        p, _, _ = make(FakeEnv(gh=gh_base(), blobs=blobs()))
        self.assertTrue(any("no unittest -v log" in t for _, t in lines(p, "s6", "UNTESTED")))


class Findings(unittest.TestCase):
    def run_f(self, text, **kw):
        env = FakeEnv(gh=gh_base(), blobs=blobs(), files={"/f/RV_FINDINGS.md": text.encode(), **kw.pop("files", {})})
        return make(env, findings=["20=/f/RV_FINDINGS.md"], **kw)[0]

    def test_status_unknown_is_default_and_fixed_is_not_verified(self):
        text = f"# R @ {HEAD}\n## Verdict: x (0 BLOCKER, 2 SHOULD-FIX, 0 NOTE)\n### F1 SHOULD-FIX: a\nStatus: fixed in abc\n### F2 SHOULD-FIX: b\nnothing\n"
        p = self.run_f(text)
        s4 = lines(p, "s4")
        self.assertTrue(any(b == "UNTESTED" and "F1" in t and "status fixed as recorded" in t and "did not confirm" in t for b, t in s4))
        self.assertTrue(any(b == "UNTESTED" and "F2" in t and "status unknown" in t for b, t in s4))
        self.assertFalse(any(b == "VERIFIED" and "F1" in t.split(":")[0] for b, t in s4))

    def test_older_review_is_flagged_and_count_mismatch(self):
        p = self.run_f(f"# R @ {OLD}\n## Verdict: x (0 BLOCKER, 3 SHOULD-FIX, 0 NOTE)\n### F1 SHOULD-FIX: a\n")
        s4 = lines(p, "s4")
        self.assertTrue(any("does not cover the current head" in t for _, t in s4))
        self.assertTrue(any("differ from the verdict line" in t for _, t in s4))

    def test_owner_decision_status(self):
        p = self.run_f(f"# R @ {HEAD}\n### F1 SHOULD-FIX: a\nStatus: owner decision\n")
        self.assertTrue(any(b == "REQUIRES OWNER DECISION" and "F1" in t for b, t in lines(p, "s4")))
        self.assertTrue(any("(from review finding F1" in t for _, t in lines(p, "s14")))

    def test_resolutions_file_overrides_status(self):
        p = self.run_f(f"# R @ {HEAD}\n### F1 SHOULD-FIX: a\n", files={"/r.md": b"RV:F1 | open | still broken\n"}, resolutions="/r.md")
        self.assertTrue(any("F1" in t and "status open" in t for _, t in lines(p, "s4", "UNTESTED")))

    def test_no_findings_file_is_untested(self):
        p, _, _ = make(FakeEnv(gh=gh_base(), blobs=blobs()))
        self.assertTrue(any("no review findings file" in t for _, t in lines(p, "s4", "UNTESTED")))


class Prod(unittest.TestCase):
    BASE = {"generated_utc": "2026-11-16T11:00:00Z", "read_only": True, "counts": {"functions": 1}, "functions": [{"sig": "f(text)", "security": "definer", "execute": {"anon": True, "authenticated": False, "service_role": True}}, {"sig": "old()", "security": "invoker", "execute": {"anon": True, "authenticated": False, "service_role": True}}], "tables": [{"name": "leads", "anon": ["select"], "authenticated": [], "service_role": ["select"]}]}

    def run_prod(self, base, **kw):
        files = {"/b.json": json.dumps(base).encode()}
        files.update(kw.pop("files", {}))
        return make(FakeEnv(gh=gh_base(), blobs=blobs(), files=files), prod_baseline="/b.json", **kw)[0]

    def test_absent_baseline_is_untested(self):
        p, _, _ = make(FakeEnv(gh=gh_base(), blobs=blobs()))
        self.assertEqual(lines(p, "s12", "VERIFIED"), [])
        self.assertTrue(any("no LIVE production read-only comparison" in t for _, t in lines(p, "s12", "UNTESTED")))

    def test_fresh_baseline_compared_with_manifest(self):
        p = self.run_prod(self.BASE)
        v = [t for _, t in lines(p, "s12", "VERIFIED")]
        self.assertTrue(any("FUNCTIONS: 1 in both" in t and "1 only in production (old())" in t and "1 execute-privilege differences (f(text)[anon])" in t for t in v), v)
        self.assertTrue(any("TABLES: 1 in both" in t and "1 privilege differences" in t for t in v), v)

    def test_stale_baseline_cannot_be_verified(self):
        old = dict(self.BASE, generated_utc="2026-11-10T00:00:00Z")
        p = self.run_prod(old)
        self.assertFalse(any("FUNCTIONS" in t for _, t in lines(p, "s12", "VERIFIED")))
        self.assertTrue(any("not fresh" in t for _, t in lines(p, "s12", "UNTESTED")))

    def test_baseline_without_timestamp_is_not_fresh(self):
        b = dict(self.BASE)
        del b["generated_utc"]
        p = self.run_prod(b)
        self.assertTrue(any("no readable timestamp" in t for _, t in lines(p, "s12", "UNTESTED")))

    def test_compare_artifact(self):
        good = {"captured_at": "2026-11-16T11:30:00Z", "ok": True, "diffs": []}
        p = self.run_prod(self.BASE, files={"/c.json": json.dumps(good).encode()}, prod_compare="/c.json")
        self.assertTrue(any("fresh read-only production comparison artifact" in t for _, t in lines(p, "s12", "VERIFIED")))
        bad = dict(good, ok=False, diffs=["x"])
        p = self.run_prod(self.BASE, files={"/c.json": json.dumps(bad).encode()}, prod_compare="/c.json")
        self.assertTrue(any("not a clean fresh match" in t for _, t in lines(p, "s12", "UNTESTED")))


class Drill(unittest.TestCase):
    def test_drill_results_and_failures(self):
        d = [{"check": "1 restore tool works", "pass": True, "detail": ""}, {"check": "2 crash mid upload is not uploaded", "pass": False, "detail": "x"}, {"check": "3 unrelated", "pass": True, "detail": ""}]
        env = FakeEnv(gh=gh_base(), blobs=blobs(), files={"/d.json": json.dumps(d).encode()})
        p, _, _ = make(env, drill_results=["20=/d.json@" + HEAD])
        self.assertTrue(any("2/3 checks passed" in t and "FAILED" in t for _, t in lines(p, "s5", "TESTED IN SCRATCH")))
        self.assertTrue(any("FAIL 2 crash" in t for _, t in lines(p, "s5")))
        self.assertTrue(any("failing result in section 5" in t for _, t in lines(p, "s13", "UNTESTED")))

    def test_drill_for_older_commit_is_untested(self):
        d = [{"check": "1 restore", "pass": True, "detail": ""}]
        p, _, _ = make(FakeEnv(gh=gh_base(), blobs=blobs(), files={"/d.json": json.dumps(d).encode()}), drill_results=["20=/d.json@" + OLD])
        self.assertEqual(lines(p, "s5", "TESTED IN SCRATCH"), [])


class CheckMode(unittest.TestCase):
    """--check must fail on every kind of damage; each test breaks a good package one way."""

    @classmethod
    def setUpClass(cls):
        cls.tmp = tempfile.mkdtemp()
        cls.f = os.path.join(cls.tmp, "art.log")
        with open(cls.f, "w") as fh:
            fh.write(GOOD_LOG % HEAD)
        env = FakeEnv(gh=gh_base(), blobs=blobs(), files={cls.f: (GOOD_LOG % HEAD).encode()})
        cls.env = env
        cls.good = make(env, gate_log=["20=" + cls.f])[2]

    def errs(self, text, recheck=False):
        return g.check_package(text, recheck_files=recheck)

    def test_good_passes(self):
        self.assertEqual(self.errs(self.good), [])

    def test_summary_counts_match_recount(self):
        self.assertEqual(self.errs(self.good.replace("- UNTESTED: ", "- UNTESTED: 9")), [x for x in self.errs(self.good.replace("- UNTESTED: ", "- UNTESTED: 9"))])
        self.assertTrue(any("bucket summary for UNTESTED" in e for e in self.errs(self.good.replace("- UNTESTED: ", "- UNTESTED: 9"))))

    def test_missing_required_section(self):
        t = self.good.replace("## 6. Proof that inconsistent backups cannot upload", "## 6. Something else")
        self.assertTrue(any("required section 6" in e for e in self.errs(t)))

    def test_every_required_section_is_enforced(self):
        for n, (k, title, sub) in enumerate(g.SECTIONS, 1):
            t = self.good.replace(f"## {n}. {title}", f"## {n}. renamed")
            self.assertTrue(any(f"required section {n}" in e for e in self.errs(t)), title)

    def test_verified_without_evidence(self):
        line = next(l for l in self.good.splitlines() if l.startswith("- [VERIFIED]"))
        stripped = line[: line.rindex(" (evidence:")]
        self.assertTrue(any("VERIFIED line without an evidence reference" in e for e in self.errs(self.good.replace(line, stripped))))
        self.assertTrue(any("VERIFIED line without an evidence reference" in e for e in self.errs(self.good.replace(line, stripped + " (evidence: none)"))))

    def test_scratch_without_evidence(self):
        line = next(l for l in self.good.splitlines() if l.startswith("- [TESTED IN SCRATCH]"))
        stripped = line[: line.rindex(" (evidence:")]
        self.assertTrue(any("TESTED IN SCRATCH line without" in e for e in self.errs(self.good.replace(line, stripped))))

    def test_evidence_id_not_in_register(self):
        line = next(l for l in self.good.splitlines() if l.startswith("- [VERIFIED]"))
        bad = line[: line.rindex(" (evidence:")] + " (evidence: E999)"
        self.assertTrue(any("E999 is not in the register" in e for e in self.errs(self.good.replace(line, bad))))

    def test_unclassified_line(self):
        t = self.good.replace("## 12. Fresh production read-only comparison\n\n", "## 12. Fresh production read-only comparison\n\n- a line with no bucket\nloose prose\n")
        self.assertTrue(sum("is not '- [BUCKET] text'" in e for e in self.errs(t)) >= 2)

    def test_two_bucket_tags(self):
        line = next(l for l in self.good.splitlines() if l.startswith("- [UNTESTED]"))
        bad = line.replace("- [UNTESTED] ", "- [UNTESTED] [VERIFIED] ", 1)
        self.assertTrue(any("exactly one bucket" in e for e in self.errs(self.good.replace(line, bad))))

    def test_unknown_bucket_word(self):
        line = next(l for l in self.good.splitlines() if l.startswith("- [UNTESTED]"))
        self.assertTrue(any("is not '- [BUCKET]" in e for e in self.errs(self.good.replace(line, line.replace("[UNTESTED]", "[PROBABLY FINE]", 1)))))

    def test_empty_section(self):
        t = self.good.replace("## 12. Fresh production read-only comparison", "## 12. Fresh production read-only comparison\n\n## 12b. x\n", 1)
        import re
        i = t.index("## 12. Fresh")
        j = t.index("## 13.")
        t = t[:i] + "## 12. Fresh production read-only comparison\n\n" + t[j:]
        self.assertTrue(any("section '12. Fresh production read-only comparison' is empty" in e for e in self.errs(t)))

    def test_disclaimer_must_state_everything(self):
        for ph in g.REQUIRED_DISCLAIMER_PHRASES:
            i = self.good.index("## Standing disclaimer")
            j = self.good.index("## Bucket summary")
            seg = self.good[i:j].replace(ph, "xxxx")
            t = self.good[:i] + seg + self.good[j:]
            if ph == "not production proof":
                t = self.good[:i] + self.good[i:j].replace("NOT production proof", "xxxx").replace("not production proof", "xxxx") + self.good[j:]
            self.assertTrue(any("disclaimer lacks" in e for e in self.errs(t)), ph)

    def test_register_hash_must_match_file(self):
        with open(self.f, "w") as fh:
            fh.write("changed")
        try:
            # the register must name the file for the recheck to apply
            text = self.good.replace(f"file | {os.path.abspath(self.f)} |", f"file | {os.path.abspath(self.f)} |")
            self.assertTrue(any("has changed since it was hashed" in e for e in self.errs(text, recheck=True)))
        finally:
            with open(self.f, "w") as fh:
                fh.write(GOOD_LOG % HEAD)
        self.assertEqual([e for e in self.errs(self.good, recheck=True) if "changed" in e], [])

    def test_malformed_register_line(self):
        t = self.good.replace("sha256=", "sha=", 1)
        self.assertTrue(any("malformed evidence register" in e for e in self.errs(t)))

    def test_main_check_exit_codes(self):
        ok = os.path.join(self.tmp, "ok.md")
        bad = os.path.join(self.tmp, "bad.md")
        with open(ok, "w") as fh:
            fh.write(self.good)
        with open(bad, "w") as fh:
            fh.write(self.good.replace("## 4. Security review findings and their resolutions", "## 4. gone"))
        self.assertEqual(g.main(["--check", "--package", ok]), 0)
        self.assertEqual(g.main(["--check", "--package", bad]), 1)

    def test_every_generated_verified_line_has_evidence(self):
        for l in self.good.splitlines():
            if l.startswith("- [VERIFIED]") or l.startswith("- [TESTED IN SCRATCH]"):
                self.assertRegex(l, r"\(evidence: [EA]\d+(, [EA]\d+)*\)$")


class Hashes(unittest.TestCase):
    def test_register_hash_is_of_bytes_read(self):
        env = FakeEnv(gh=gh_base(), blobs=blobs(), files={"/x": b"hello"})
        p = g.Pkg(env)
        i, data = p.file("/x")
        self.assertEqual(p.ev[i]["sha256"], hashlib.sha256(b"hello").hexdigest())
        self.assertEqual(p.ev[i]["read_at"], "2026-11-16T12:00:00Z")
        self.assertEqual(p.file("/missing"), (None, None))

    def test_same_bytes_dedupe(self):
        p = g.Pkg(FakeEnv(files={"/x": b"a"}))
        self.assertEqual(p.file("/x")[0], p.file("/x")[0])


if __name__ == "__main__":
    unittest.main()
