"""Mandatory-check engine (ops/oversight/mandatory_checks.py): one positive and at least one negative synthetic case per rule.
Everything here is a fixture: no network, no database. Secret-like strings are assembled at run time so that no literal
secret pattern exists in this file. Runs in the existing `scripts-tests` gate step."""
import json
import os
import subprocess
import sys
import tempfile
import unittest

ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..")
sys.path.insert(0, os.path.join(ROOT, "ops", "oversight"))
import mandatory_checks as M  # noqa: E402

SHA, OTHER = "a" * 40, "b" * 40


def diff(path, added=(), removed=(), status="M"):
    head = [f"diff --git a/{path} b/{path}"]
    if status == "A":
        head.append("new file mode 100644")
    if status == "D":
        head.append("deleted file mode 100644")
    return "\n".join(head + [f"--- a/{path}", f"+++ b/{path}", f"@@ -1,{len(removed)} +10,{len(added)} @@"] + ["-" + r for r in removed] + ["+" + a for a in added]) + "\n"


def rules(text):
    return {(f["rule"], f["class"]) for f in M.scan_diff(M.parse_diff(text))}


def run(name, status="completed", conclusion="success", sha=SHA, rid=1):
    return {"id": rid, "name": name, "status": status, "conclusion": conclusion, "head_sha": sha, "details_url": "u"}


GREEN = [run("unit", rid=1), run("migrations", rid=2), run("secret-scan", rid=3)]
GATE_LOG = """2026-11-16T00:00:00.0Z ================ GATE SUMMARY ================
2026-11-16T00:00:00.0Z STEP           RESULT   DETAIL
2026-11-16T00:00:00.0Z unit           PASS     python3 -m unittest discover -q (repo tests)
2026-11-16T00:00:00.0Z scripts-tests  PASS     lint + manifest tests
2026-11-16T00:00:00.0Z lint           PASS     migration lint
2026-11-16T00:00:00.0Z bundle         PASS     dist
2026-11-16T00:00:00.0Z appcheck       PASS     PWA
2026-11-16T00:00:00.0Z webjs          SKIPPED  (optional) node missing
2026-11-16T00:00:00.0Z replica        PASS     replica
2026-11-16T00:00:00.0Z manifest       PASS     function manifest, and ops/ACL_MANIFEST_public.tsv matches the replica ACLs
2026-11-16T00:00:00.0Z backup         PASS     drill
2026-11-16T00:00:00.0Z ----------------------------------------------
2026-11-16T00:00:00.0Z GATE PASSED: 8 steps passed, 1 optional step(s) not available
"""


class ParseDiff(unittest.TestCase):
    def test_added_removed_status_and_line_numbers(self):
        f = M.parse_diff(diff("x.py", ["one", "two"], ["old"]) + diff("y.sql", ["z"], status="A") + diff("gone.py", removed=["q"], status="D"))
        self.assertEqual(f["x.py"]["added"], [(10, "one"), (11, "two")])
        self.assertEqual(f["x.py"]["removed"], ["old"])
        self.assertEqual((f["y.sql"]["status"], f["gone.py"]["status"]), ("A", "D"))


class ProtectedControls(unittest.TestCase):
    def test_clean_change_has_no_finding(self):
        self.assertEqual(rules(diff("hq_office.py", ["def greet():", "    return 'hi'"])), set())

    def test_spend_cap(self):
        self.assertIn(("PC-SPEND", "owner_gate"), rules(diff("hq_engine.py", ["    cap = st.get('daily_spend_cap_cents') or 9999"])))
        self.assertIn(("PC-SPEND", "owner_gate"), rules(diff("hq_engine.py", removed=["    call_id = _rpc('reserve_llm_budget', {})"])))
        self.assertIn(("PC-SPEND", "owner_gate"), rules(diff("migrations/20261201_x_y_v1.sql", ["update system_state set daily_spend_cap_cents = 100000;"])))

    def test_spend_cap_in_tests_and_docs_is_not_a_control_change(self):
        self.assertEqual(rules(diff("test_hq_engine.py", ["x = 'daily_spend_cap_cents'"]) + diff("HQ_RUNBOOK.md", ["the kill_switch and dry_run"])), set())
        self.assertEqual(rules(diff("hq_engine.py", ["    # reserve_llm_budget is called above"])), set())

    def test_committed_logs_and_evidence_are_not_code(self):
        self.assertEqual(rules(diff("ops/evidence_pr15_review/unit.log", ["reserve_llm_budget ... ok", "mode dry_run"])), set())

    def test_kill_switch(self):
        self.assertIn(("PC-KILL", "owner_gate"), rules(diff("hq_mail.py", removed=["    if state['kill_switch']: return"])))

    def test_executor_registry(self):
        self.assertIn(("PC-EXEC-WRITE", "reject"), rules(diff("migrations/20261201_x_y_v1.sql", ["insert into public.executor_registry (slug) values ('x');"])))
        self.assertIn(("PC-EXEC-WRITE", "reject"), rules(diff("migrations/20261201_x_y_v1.sql", ["grant insert, update on public.executor_registry to service_role;"])))
        r = rules(diff("hq_executor.py", ["    rows = _get('executor_registry?select=slug')"]))
        self.assertIn(("PC-EXEC", "owner_gate"), r)
        self.assertNotIn(("PC-EXEC-WRITE", "reject"), r)
        self.assertNotIn(("PC-EXEC-WRITE", "reject"), rules(diff("migrations/20261201_x_y_v1.sql", ["grant select on public.executor_registry to service_role;"])))

    def test_dry_run(self):
        self.assertIn(("PC-DRYRUN", "owner_gate"), rules(diff("hq_executor.py", removed=["    if d.get('dry_run'):"])))
        self.assertIn(("PC-DRYRUN", "owner_gate"), rules(diff("migrations/20261201_x_y_v1.sql", ["update system_state set mode = 'live';"])))

    def test_permission_relaxations_reject(self):
        for line in ("alter table public.leads disable row level security;", "alter role service_role bypassrls;", "create policy p on leads using (true);",
                     "grant all on public.leads to service_role;", "grant execute on function f() to public;"):
            self.assertIn(("PC-PERM-RELAX", "reject"), rules(diff("migrations/20261201_x_y_v1.sql", [line])), line)

    def test_permission_changes_owner_gate(self):
        self.assertIn(("PC-PERM-OPEN", "owner_gate"), rules(diff("migrations/20261201_x_y_v1.sql", ["grant execute on function app_x() to authenticated;"])))
        self.assertIn(("PC-PERM", "owner_gate"), rules(diff("migrations/20261201_x_y_v1.sql", ["create function f() returns void language sql security definer as $$ select 1 $$;"])))
        self.assertIn(("PC-PERM-REMOVED", "owner_gate"), rules(diff("migrations/20261201_x_y_v1.sql", removed=["revoke all on function f() from public, anon, authenticated;"])))

    def test_revoke_only_migration_is_clean(self):
        self.assertEqual(rules(diff("migrations/20261201_x_y_v1.sql", ["revoke all on function f() from public, anon, authenticated;", "create table t (id int);"])), set())

    def test_secret_patterns_reject_and_value_never_echoed(self):
        samples = {"anthropic-key": "sk-" + "ant-" + "A" * 30, "github-token": "gh" + "p_" + "A" * 36, "aws-access-key": "AK" + "IA" + "A" * 16,
                   "private-key": "-----BEGIN " + "RSA PRIVATE KEY-----", "jwt": "ey" + "J" + "a" * 20 + "." + "ey" + "J" + "b" * 20 + "." + "c" * 12,
                   "telegram-bot-token": "123456789" + ":AA" + "x" * 33, "stripe-live-key": "sk_" + "live_" + "a" * 24}
        for name, value in samples.items():
            fs = M.scan_diff(M.parse_diff(diff("hq_x.py", [f"KEY = '{value}'"])))
            hit = [f for f in fs if f["rule"] == "PC-SECRET"]
            self.assertTrue(hit and hit[0]["class"] == "reject", name)
            self.assertNotIn(value, json.dumps(fs), name)
        fs = M.scan_diff(M.parse_diff(diff("test_x.py", ["KEY = '" + samples["aws-access-key"] + "'"])))
        self.assertTrue([f for f in fs if f["rule"] == "PC-SECRET"], "secrets are scanned in test files too")

    def test_placeholder_is_not_a_secret(self):
        self.assertEqual(rules(diff("hq_x.py", ["KEY = os.environ['ANTHROPIC_API_KEY']", "token = 'sk-test'"])), set())

    def test_guard_tools_workflows_and_deploy_surface(self):
        self.assertIn(("PC-GUARD", "owner_gate"), rules(diff("scripts/lint_migrations.py", ["x = 1"])))
        self.assertIn(("PC-GUARD", "reject"), rules(diff("scripts/check_gitleaks_ignore.py", removed=["x"], status="D")))
        self.assertIn(("PC-WORKFLOW", "owner_gate"), rules(diff(".github/workflows/tests.yml", ["  x: y"])))
        self.assertIn(("PC-WORKFLOW", "reject"), rules(diff(".github/workflows/tests.yml", removed=["x"], status="D")))
        self.assertIn(("PC-DEPLOY", "owner_gate"), rules(diff("Procfile", ["worker: python3 other.py"])))
        self.assertIn(("PC-DEPLOY", "owner_gate"), rules(diff("requirements.txt", ["newpkg>=1"])))

    def test_gitleaks_config(self):
        self.assertEqual(rules(diff(".gitleaks.toml", ["description = 'x'"])), {("PC-GITLEAKS", "owner_gate")})
        for line in ('commits = ["abc"]', "useDefault = false", 'disabledRules = ["generic-api-key"]', 'stopwords = ["key"]'):
            self.assertIn(("PC-GITLEAKS", "reject"), rules(diff(".gitleaks.toml", [line])), line)

    def test_control_tests(self):
        self.assertIn(("PC-TESTS", "reject"), rules(diff("test_no_bypass.py", removed=["x"], status="D")))
        self.assertIn(("PC-TESTS", "reject"), rules(diff("sqltests/audit_paths_check.sql", removed=["x"], status="D")))
        self.assertIn(("PC-TESTS", "owner_gate"), rules(diff("test_spend_paths.py", removed=["    self.assertEqual(n, 0)"])))
        self.assertEqual(rules(diff("test_spend_paths.py", ["    self.assertEqual(n, 0)"])), set())

    def test_oversight_cannot_quietly_change_its_own_rules(self):
        for p in ("ops/oversight/mandatory_checks.py", "ops/oversight/owner_keys.json", "ops/oversight/ledger.py", "docs/oversight/CHARTER.md"):
            self.assertIn(("PC-OVERSIGHT", "owner_gate"), rules(diff(p, ["x"])), p)
        self.assertEqual(rules(diff("ops/oversight/ledger/reviews.jsonl", ["{}"]) + diff("ops/oversight/evidence/x.json", ["{}"])), set())


class GitleaksIgnore(unittest.TestCase):
    FP = "c" * 40 + ":sqltests/x.sql:generic-api-key:3"

    def test_unchanged_ok(self):
        self.assertEqual(M.check_gitleaksignore(self.FP + "\n", "# c\n" + self.FP + "\n"), [])

    def test_exact_fingerprint_needs_owner(self):
        f = M.check_gitleaksignore("", self.FP + "\n")
        self.assertEqual([(x["rule"], x["class"]) for x in f], [("PC-GITLEAKS", "owner_gate")])

    def test_wildcard_or_broad_entry_rejected(self):
        for bad in ("sqltests/*", "c" * 40, "*:sqltests/x.sql:generic-api-key:3", "c" * 40 + ":sqltests/*:generic-api-key:3", "abc123:f.sql:rule:1"):
            f = M.check_gitleaksignore("", bad + "\n")
            self.assertEqual([x["class"] for x in f], ["reject"], bad)
            self.assertNotIn(bad, json.dumps(f))


class Codeowners(unittest.TestCase):
    BASE = "/migrations/ @owner\n/ops/ @owner\n"

    def test_same_ok(self):
        self.assertEqual(M.check_codeowners(self.BASE, self.BASE), [])

    def test_path_removed_rejected(self):
        self.assertEqual([f["class"] for f in M.check_codeowners(self.BASE, "/migrations/ @owner\n")], ["reject"])

    def test_owner_swapped_rejected(self):
        self.assertEqual([f["class"] for f in M.check_codeowners(self.BASE, "/migrations/ @someone\n/ops/ @owner\n")], ["reject"])

    def test_file_deleted_rejected(self):
        self.assertEqual([f["class"] for f in M.check_codeowners(self.BASE, None)], ["reject"])

    def test_additions_need_owner(self):
        f = M.check_codeowners(self.BASE, self.BASE + "/docs/oversight/ @owner\n")
        self.assertEqual([x["class"] for x in f], ["owner_gate"])
        f = M.check_codeowners(self.BASE, "/migrations/ @owner @second\n/ops/ @owner\n")
        self.assertEqual([x["class"] for x in f], ["owner_gate"])


class GateAndLint(unittest.TestCase):
    GATE = 'run unit "u" python3 -m unittest\nrun lint "l" python3 scripts/lint_migrations.py\n  run replica "r" replica_check\n[ "$1" = --strict ]\n'
    WF = "name: tests\njobs:\n  unit:\n    steps:\n      - run: pip install --require-hashes -r requirements/dev.lock\n  migrations:\n    steps:\n      - run: scripts/gate.sh --strict\n  secret-scan:\n    steps:\n      - run: gitleaks git .\n"

    def test_unchanged_ok(self):
        self.assertEqual(M.check_gate(self.GATE, self.GATE, {"w": self.WF}, {"w": self.WF}), [])

    def test_added_step_ok(self):
        self.assertEqual(M.check_gate(self.GATE, self.GATE + 'run extra "e" true\n', {}, {}), [])

    def test_step_removed_rejected(self):
        f = M.check_gate(self.GATE, self.GATE.replace('run lint "l" python3 scripts/lint_migrations.py\n', ""), {}, {})
        self.assertEqual([(x["class"], "lint" in x["msg"]) for x in f], [("reject", True)])

    def test_strict_removed_and_gate_deleted(self):
        self.assertTrue(any("--strict" in x["msg"] for x in M.check_gate(self.GATE, self.GATE.replace("--strict", "--x"), {}, {})))
        self.assertEqual([x["class"] for x in M.check_gate(self.GATE, None, {}, {})], ["reject"])

    def test_ci_job_removed_or_weakened(self):
        no_scan = self.WF.split("  secret-scan:")[0]
        msgs = [x["msg"] for x in M.check_gate(None, None, {"w": self.WF}, {"w": no_scan})]
        self.assertTrue(any("secret-scan" in m for m in msgs) and any("gitleaks" in m for m in msgs))
        self.assertTrue(M.check_gate(None, None, {"w": self.WF}, {"w": self.WF.replace("gate.sh --strict", "gate.sh")}))
        self.assertTrue(M.check_gate(None, None, {"w": self.WF}, {"w": self.WF.replace(" --require-hashes", "")}))
        self.assertEqual([x["msg"] for x in M.check_gate(None, None, {"w": self.WF}, {})], ["workflow removed"])

    LINT = '"""Rules\n  R1 order   x\n  R4 revoke  y\n"""\nGRANDFATHERED = frozenset("""\na_v1.sql b_v1.sql\n""".split())\nNOT_IN_ORDER = frozenset({"c.sql"})\nMODIFIED_ALLOWLIST = {}\n'

    def test_lint_unchanged_or_refactored_ok(self):
        self.assertEqual(M.check_lint_rules(self.LINT, self.LINT), [])
        self.assertEqual(M.check_lint_rules(self.LINT, self.LINT + "\ndef helper():\n    return 1\n"), [])

    def test_lint_exception_added_rejected(self):
        for new in (self.LINT.replace("b_v1.sql", "b_v1.sql new_one.sql"), self.LINT.replace('{"c.sql"}', '{"c.sql", "d.sql"}'),
                    self.LINT.replace("MODIFIED_ALLOWLIST = {}", 'MODIFIED_ALLOWLIST = {"a_v1.sql": "because"}')):
            f = M.check_lint_rules(self.LINT, new)
            self.assertEqual([x["class"] for x in f], ["reject"], new)

    def test_lint_rule_dropped_or_broken_rejected(self):
        self.assertTrue(any("R4" in x["msg"] for x in M.check_lint_rules(self.LINT, self.LINT.replace("  R4 revoke  y\n", ""))))
        self.assertEqual([x["class"] for x in M.check_lint_rules(self.LINT, "def (")], ["reject"])
        self.assertEqual([x["class"] for x in M.check_lint_rules(self.LINT, None)], ["reject"])
        self.assertTrue(M.check_lint_rules(self.LINT, self.LINT.replace("GRANDFATHERED", "GF")))

    def test_real_linter_lists_parse(self):
        with open(os.path.join(ROOT, "scripts", "lint_migrations.py")) as f:
            lists = M.lint_allowlists(f.read())
        self.assertEqual(set(lists), {"GRANDFATHERED", "NOT_IN_ORDER", "MODIFIED_ALLOWLIST"})
        self.assertGreater(len(lists["GRANDFATHERED"]), 20)

    def test_real_gate_steps_parse(self):
        with open(os.path.join(ROOT, "scripts", "gate.sh")) as f:
            self.assertTrue({"unit", "scripts-tests", "lint", "bundle", "appcheck", "replica", "manifest", "backup"} <= M.gate_steps(f.read()))
        with open(os.path.join(ROOT, ".github", "workflows", "tests.yml")) as f:
            self.assertEqual(M.workflow_jobs(f.read()), {"unit", "migrations", "secret-scan"})


class CI(unittest.TestCase):
    def test_green(self):
        self.assertEqual(M.check_ci(GREEN, SHA)["status"], M.PASS)

    def test_api_unavailable_is_unverified_not_pass(self):
        self.assertEqual(M.check_ci(None, SHA)["status"], M.UNVERIFIED)

    def test_no_runs_at_all_fails(self):
        c = M.check_ci([], SHA)
        self.assertEqual(c["status"], M.FAIL)
        self.assertEqual(len(c["findings"]), 3)

    def test_missing_required_check_fails(self):
        self.assertEqual(M.check_ci(GREEN[:2], SHA)["status"], M.FAIL)

    def test_failed_pending_or_cancelled_fails(self):
        for bad in (run("migrations", conclusion="failure"), run("migrations", status="in_progress", conclusion=None), run("migrations", conclusion="cancelled"),
                    run("migrations", conclusion="skipped")):
            self.assertEqual(M.check_ci([GREEN[0], bad, GREEN[2]], SHA)["status"], M.FAIL, bad)

    def test_green_on_another_sha_does_not_count(self):
        runs = [run(n, sha=OTHER) for n in ("unit", "migrations", "secret-scan")]
        self.assertEqual(M.check_ci(runs, SHA)["status"], M.FAIL)

    def test_latest_rerun_wins(self):
        self.assertEqual(M.check_ci(GREEN + [run("unit", conclusion="failure", rid=99)], SHA)["status"], M.FAIL)
        self.assertEqual(M.check_ci([run("unit", conclusion="failure", rid=0)] + GREEN, SHA)["status"], M.PASS)

    def test_extra_failing_check_fails(self):
        self.assertEqual(M.check_ci(GREEN + [run("supply-chain", conclusion="failure", rid=9)], SHA)["status"], M.FAIL)


class GateEvidence(unittest.TestCase):
    def test_pass(self):
        c = M.check_gate_evidence(GATE_LOG)
        self.assertEqual(c["status"], M.PASS, c)

    def test_no_log_or_no_summary_unverified(self):
        self.assertEqual(M.check_gate_evidence(None)["status"], M.UNVERIFIED)
        self.assertEqual(M.check_gate_evidence("nothing here\n")["status"], M.UNVERIFIED)

    def test_required_step_skipped_failed_or_missing(self):
        self.assertEqual(M.check_gate_evidence(GATE_LOG.replace("replica        PASS", "replica        SKIPPED"))["status"], M.FAIL)
        self.assertEqual(M.check_gate_evidence(GATE_LOG.replace("lint           PASS", "lint           FAIL"))["status"], M.FAIL)
        no_manifest = "\n".join(l for l in GATE_LOG.splitlines() if " manifest " not in l) + "\n"
        self.assertEqual(M.check_gate_evidence(no_manifest)["status"], M.FAIL)

    def test_verdict_line_must_say_passed(self):
        self.assertEqual(M.check_gate_evidence(GATE_LOG.replace("GATE PASSED: 8 steps passed", "GATE INCOMPLETE: no failures"))["status"], M.FAIL)
        self.assertEqual(M.check_gate_evidence(GATE_LOG.split("2026-11-16T00:00:00.0Z GATE PASSED")[0])["status"], M.FAIL)


class TestClaims(unittest.TestCase):
    LOGS = {"unit": "x\n    Ran 731 tests in 8.9s\n    OK\n    Ran 86 tests in 1.0s\n"}

    def test_matching_claim(self):
        self.assertEqual(M.check_test_claims("All 731 tests pass.", self.LOGS)["status"], M.PASS)

    def test_mismatch_fails(self):
        c = M.check_test_claims("Verified: 900 unit tests OK", self.LOGS)
        self.assertEqual((c["status"], c["class"]), (M.FAIL, "reject"))

    def test_partial_match_passes_with_note(self):
        c = M.check_test_claims("was 671 tests, now 731 tests", self.LOGS)
        self.assertEqual(c["status"], M.PASS)
        self.assertTrue(any("671" in f["msg"] for f in c["findings"]))

    def test_no_claim_and_no_logs(self):
        self.assertEqual(M.check_test_claims("adds a table; 5 migrations; $3.30 cap", self.LOGS)["status"], M.NA)
        self.assertEqual(M.check_test_claims("731 tests", None)["status"], M.UNVERIFIED)
        self.assertEqual(M.check_test_claims("731 tests", {"unit": "no count here"})["status"], M.UNVERIFIED)


class Dependencies(unittest.TestCase):
    REG = {"entries": [{"ecosystem": "pypi", "name": "anthropic", "license": "Apache-2.0"}, {"ecosystem": "pypi", "name": "nolicense", "license": None},
                       {"ecosystem": "npm", "name": "jsdom", "license": "MIT"}]}
    LOCK = "anthropic==2.8.0 \\\n    --hash=sha256:aa\n"

    def test_nothing_changed(self):
        self.assertEqual(M.check_dependencies({}, self.REG)["status"], M.NA)

    def test_known_direct_dependency_passes(self):
        self.assertEqual(M.check_dependencies({"requirements/runtime.in": ("", "anthropic>=2\n")}, self.REG)["status"], M.PASS)

    def test_new_direct_dependency_without_entry_rejected(self):
        for name in ("leftpad>=1", "Left_Pad[extra]==1.0", "nolicense>=1"):
            c = M.check_dependencies({"requirements/runtime.in": ("anthropic>=2\n", "anthropic>=2\n" + name + "\n")}, self.REG)
            self.assertEqual((c["status"], c["class"]), (M.FAIL, "reject"), name)
        self.assertEqual(M.check_dependencies({"requirements.txt": ("", "leftpad\n")}, None)["status"], M.FAIL)

    def test_new_transitive_without_entry_is_unverified(self):
        c = M.check_dependencies({"requirements/runtime.lock": (self.LOCK, self.LOCK + "newdep==1.0 \\\n    --hash=sha256:bb\n")}, self.REG)
        self.assertEqual(c["status"], M.UNVERIFIED)

    def test_unhashed_lock_entry_rejected(self):
        c = M.check_dependencies({"requirements/runtime.lock": (self.LOCK, self.LOCK + "anthropic-extra==1.0\n")}, self.REG)
        self.assertEqual(c["status"], M.FAIL)
        self.assertTrue(any(f["rule"] == "DEP-PIN" for f in c["findings"]))

    def test_npm(self):
        pj = lambda d: json.dumps({"devDependencies": d})
        self.assertEqual(M.check_dependencies({"webtests/package.json": (pj({"jsdom": "24.1.3"}), pj({"jsdom": "29.1.1"}))}, self.REG)["status"], M.PASS)
        self.assertEqual(M.check_dependencies({"webtests/package.json": (pj({"jsdom": "24.1.3"}), pj({"jsdom": "24.1.3", "evil": "1.0.0"}))}, self.REG)["status"], M.FAIL)
        self.assertEqual(M.check_dependencies({"webtests/package.json": (pj({"jsdom": "24.1.3"}), pj({"jsdom": "^29.0.0"}))}, self.REG)["status"], M.FAIL)
        self.assertEqual(M.check_dependencies({"webtests/package.json": (pj({}), "{not json")}, self.REG)["status"], M.FAIL)
        self.assertEqual(M.check_dependencies({"webtests/package-lock.json": ("{}", '{"a":1}')}, self.REG)["status"], M.UNVERIFIED)

    def test_images_and_actions_must_be_pinned(self):
        d = "sha256:" + "d" * 64
        self.assertEqual(M.check_dependencies({"x/Dockerfile.worker": ("", f"FROM python:3.12@{d}\n")}, self.REG)["status"], M.PASS)
        self.assertEqual(M.check_dependencies({"x/Dockerfile.worker": ("", "FROM python:3.12\n")}, self.REG)["status"], M.FAIL)
        self.assertEqual(M.check_dependencies({"x/docker-compose.yml": ("", "services:\n  a:\n    image: squid:latest\n")}, self.REG)["status"], M.FAIL)
        self.assertEqual(M.check_dependencies({"x/tests/fixtures/bad/docker-compose.yml": ("", "    image: squid:latest\n")}, self.REG)["status"], M.PASS)
        self.assertEqual(M.check_dependencies({".github/workflows/t.yml": ("", "      - uses: actions/checkout@" + "e" * 40 + " # v4\n")}, self.REG)["status"], M.PASS)
        self.assertEqual(M.check_dependencies({".github/workflows/t.yml": ("", "      - uses: actions/checkout@v4\n")}, self.REG)["status"], M.FAIL)


def rev(i, sha=SHA, reviewer="rev-b", author="auth-a", rec="APPROVE", typ="review", **kw):
    e = {"type": typ, "id": f"R{i}", "seq": i, "subject": {"sha": sha}, "reviewer": {"id": reviewer}, "author": {"id": author}, "recommendation": rec, "findings": []}
    e.update(kw)
    return e


class IndependentReview(unittest.TestCase):
    def st(self, entries, author="auth-a"):
        return M.check_independent_review(entries, SHA, author)["status"]

    def test_independent_approval_passes(self):
        self.assertEqual(self.st([rev(1)]), M.PASS)

    def test_no_ledger_or_no_review_is_unverified(self):
        self.assertEqual(self.st(None), M.UNVERIFIED)
        self.assertEqual(self.st([]), M.UNVERIFIED)

    def test_review_of_an_older_head_does_not_count(self):
        c = M.check_independent_review([rev(1, sha=OTHER)], SHA, "auth-a")
        self.assertEqual(c["status"], M.UNVERIFIED)
        self.assertIn("other heads", c["findings"][0]["msg"])

    def test_self_review_fails(self):
        self.assertEqual(self.st([rev(1, reviewer="auth-a")]), M.FAIL)
        self.assertEqual(self.st([rev(1, reviewer="x", author="y")], author="x"), M.FAIL)

    def test_mechanical_run_is_not_a_review(self):
        self.assertEqual(self.st([rev(1, typ="mechanical_check", reviewer="engine")]), M.UNVERIFIED)

    def test_negative_review_blocks(self):
        for rec in ("REJECT", "NEEDS_MORE_WORK"):
            self.assertEqual(self.st([rev(1, rec=rec)]), M.FAIL, rec)
        self.assertEqual(self.st([rev(1), rev(2, rec="NEEDS_MORE_WORK", reviewer="rev-c")]), M.FAIL, "the LATEST review decides")
        self.assertEqual(self.st([rev(1, rec="REJECT"), rev(2, reviewer="rev-c")]), M.PASS)

    def test_imported_approval_is_unverified_but_imported_rejection_blocks(self):
        self.assertEqual(self.st([rev(1, typ="review", imported=True)]), M.UNVERIFIED)
        self.assertEqual(self.st([rev(1, rec="NEEDS_MORE_WORK", imported=True)]), M.FAIL)


class Production(unittest.TestCase):
    PR = {"title": "Add a helper", "labels": [], "base": {"ref": "overnight-build"}}

    def test_ordinary_pr_passes(self):
        self.assertEqual(M.check_production(self.PR, {"hq_x.py": {}})["status"], M.PASS)

    def test_unreadable_pr_is_unverified(self):
        self.assertEqual(M.check_production(None, {})["status"], M.UNVERIFIED)

    def test_label_title_and_deploy_branch(self):
        for pr in (dict(self.PR, labels=[{"name": "production-deploy"}]), dict(self.PR, labels=[{"name": "migration"}]),
                   dict(self.PR, title="Production migration: apply 20261120"), dict(self.PR, title="Deploy to Railway"),
                   dict(self.PR, base={"ref": "claude/telegram-claude-bot-59nusk"})):
            c = M.check_production(pr, {})
            self.assertEqual((c["status"], c["class"]), (M.FAIL, "owner_gate"), pr)

    def test_text_that_only_mentions_production_is_not_a_trigger(self):
        self.assertEqual(M.check_production(dict(self.PR, title="Nothing is applied to production; docs only"), {})["status"], M.PASS)

    def test_webapp_change_into_auto_published_branch(self):
        self.assertEqual(M.check_production(self.PR, {"webapp/app.js": {}})["status"], M.FAIL)
        self.assertEqual(M.check_production(dict(self.PR, base={"ref": "build/x"}), {"webapp/app.js": {}})["status"], M.PASS)


class LedgerAppendOnly(unittest.TestCase):
    def test_cases(self):
        self.assertEqual(M.check_ledger_append_only(None, None)["status"], M.NA)
        self.assertEqual(M.check_ledger_append_only(None, "a\n")["status"], M.PASS)
        self.assertEqual(M.check_ledger_append_only("a\n", "a\nb\n")["status"], M.PASS)
        self.assertEqual(M.check_ledger_append_only("a\nb\n", "a\n")["status"], M.FAIL)
        self.assertEqual(M.check_ledger_append_only("a\nb\n", "b\na\n")["status"], M.FAIL)
        self.assertEqual(M.check_ledger_append_only("a\nb\n", "a\nB\n")["status"], M.FAIL)
        self.assertEqual(M.check_ledger_append_only("a\n", None)["status"], M.FAIL)


class Acl(unittest.TestCase):
    SEEN = {"manifest": ("PASS", "function manifest ..., and ops/ACL_MANIFEST_public.tsv matches the replica ACLs")}

    def test_cases(self):
        mig = {"migrations/20261201_x_y_v1.sql": {}}
        self.assertEqual(M.check_acl({"hq_x.py": {}}, [], {})["status"], M.NA)
        self.assertEqual(M.check_acl(mig, [], self.SEEN)["status"], M.UNVERIFIED)
        self.assertEqual(M.check_acl(mig, ["ops/ACL_MANIFEST_public.tsv"], self.SEEN)["status"], M.PASS)
        self.assertEqual(M.check_acl(mig, ["ops/ACL_MANIFEST_public.tsv"], {})["status"], M.UNVERIFIED)
        self.assertEqual(M.check_acl(mig, ["ops/ACL_MANIFEST_public.tsv"], {"manifest": ("PASS", "function manifest only")})["status"], M.UNVERIFIED)
        self.assertEqual(M.check_acl(mig, ["ops/ACL_MANIFEST_public.tsv"], {"manifest": ("FAIL", "x")})["status"], M.FAIL)


def sh(cwd, *argv):
    env = dict(os.environ, GIT_AUTHOR_NAME="t", GIT_AUTHOR_EMAIL="t@example.invalid", GIT_COMMITTER_NAME="t", GIT_COMMITTER_EMAIL="t@example.invalid",
               GIT_CONFIG_GLOBAL="/dev/null", GIT_CONFIG_NOSYSTEM="1")
    r = subprocess.run(argv, cwd=cwd, capture_output=True, text=True, env=env)
    if r.returncode:
        raise AssertionError(f"{argv}: {r.stderr}")
    return r.stdout.strip()


class EndToEnd(unittest.TestCase):
    """A synthetic repository: the engine reads it, runs the BASE copy of the tools, and changes nothing."""

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        d = self.repo = os.path.join(self.tmp.name, "repo")
        os.makedirs(os.path.join(d, "scripts"))
        os.makedirs(os.path.join(d, "migrations"))
        def w(p, t):
            with open(os.path.join(d, p), "w") as f:
                f.write(t)
        w("scripts/lint_migrations.py", "import sys\nprint('lint_migrations: 0 error(s)')\nsys.exit(0)\n")
        w("scripts/build_bundle.sh", "echo 'bundle current'\n")
        w("hq_x.py", "x = 1\n")
        sh(d, "git", "init", "-q", "-b", "main")
        sh(d, "git", "add", "-A")
        sh(d, "git", "commit", "-q", "-m", "base")
        self.base = sh(d, "git", "rev-parse", "HEAD")
        sh(d, "git", "update-ref", "refs/remotes/origin/overnight-build", self.base)
        self.w = w

    def tearDown(self):
        self.tmp.cleanup()

    def commit(self, msg="head"):
        sh(self.repo, "git", "add", "-A")
        sh(self.repo, "git", "commit", "-q", "-m", msg)
        return sh(self.repo, "git", "rev-parse", "HEAD")

    def evaluate(self, sha, **kw):
        rec = M.Recorder(self.repo)
        return M.evaluate(rec, sha, None, "origin/overnight-build", "x/y", use_github=False, **kw), rec

    def by_id(self, res):
        return {c["id"]: c for c in res["checks"]}

    def test_clean_change_without_github_is_never_approved(self):
        self.w("hq_x.py", "x = 2\n")
        res, _ = self.evaluate(self.commit())
        c = self.by_id(res)
        self.assertEqual(res["verdict"], "NEEDS_MORE_WORK")
        for cid in ("HEAD", "CI", "GATE-EVIDENCE", "TEST-CLAIMS", "INDEPENDENT-REVIEW", "PRODUCTION"):
            self.assertEqual(c[cid]["status"], M.UNVERIFIED, cid)
        for cid in ("PROTECTED", "LINT", "BUNDLE"):
            self.assertEqual(c[cid]["status"], M.PASS, cid)
        self.assertTrue(res["not_inspected"] and res["commands"])
        self.assertIn("NEEDS_MORE_WORK", M.summary(res))

    def test_protected_touch_rejects(self):
        self.w("hq_x.py", "x = 1\nkill_switch = False\n")
        res, _ = self.evaluate(self.commit())
        self.assertEqual(res["verdict"], "REJECT")
        self.assertEqual(self.by_id(res)["PROTECTED"]["class"], "owner_gate")
        self.assertTrue(any("kill switch" in d for d in res["owner_decisions_required"]))

    def test_head_tools_are_never_executed(self):
        marker = os.path.join(self.tmp.name, "pwned")
        self.w("scripts/lint_migrations.py", f"open({marker!r}, 'w').write('x')\nprint('lint_migrations: 0 error(s)')\n")
        self.w("scripts/build_bundle.sh", f"touch {marker}\n")
        res, _ = self.evaluate(self.commit())
        self.assertFalse(os.path.exists(marker), "code from the reviewed head was executed")
        c = self.by_id(res)
        self.assertEqual(c["LINT"]["status"], M.PASS)
        self.assertTrue(any("BASE version" in f["msg"] for f in c["LINT"]["findings"]))
        self.assertEqual(c["PROTECTED"]["status"], M.FAIL)

    def test_failing_base_lint_fails(self):
        self.w("scripts/lint_migrations.py", "import sys\nprint('R2 bad name')\nsys.exit(1)\n")
        self.base = self.commit("base2")
        sh(self.repo, "git", "update-ref", "refs/remotes/origin/overnight-build", self.base)
        self.w("migrations/bad.sql", "select 1;\n")
        res, _ = self.evaluate(self.commit())
        self.assertEqual(self.by_id(res)["LINT"]["status"], M.FAIL)
        self.assertEqual(res["verdict"], "REJECT")

    def test_unknown_sha_is_unverified_not_pass(self):
        res, _ = self.evaluate("f" * 40)
        c = self.by_id(res)
        for cid in ("PROTECTED", "LINT", "BUNDLE", "DEPS", "ACL", "LEDGER"):
            self.assertEqual(c[cid]["status"], M.UNVERIFIED, cid)
        self.assertNotEqual(res["verdict"], "RECOMMEND_APPROVE")

    def test_engine_leaves_the_repository_untouched(self):
        self.w("hq_x.py", "x = 3\n")
        sha = self.commit()
        before = (sh(self.repo, "git", "for-each-ref"), sh(self.repo, "git", "status", "--porcelain"), sh(self.repo, "git", "worktree", "list"), sh(self.repo, "git", "stash", "list"))
        _, rec = self.evaluate(sha)
        after = (sh(self.repo, "git", "for-each-ref"), sh(self.repo, "git", "status", "--porcelain"), sh(self.repo, "git", "worktree", "list"), sh(self.repo, "git", "stash", "list"))
        self.assertEqual(before, after)
        for c in rec.commands:
            self.assertNotIn(c["argv"][0], ("psql", "curl", "railway", "supabase"))
            if c["argv"][:3] == ["git", "-C", self.repo]:
                self.assertNotIn(c["argv"][3], M.Recorder.WRITE_GIT, c["argv"])

    def test_recorder_refuses_write_commands(self):
        rec = M.Recorder(self.repo)
        for cmd in ("push", "merge", "commit", "reset", "stash", "fetch"):
            with self.assertRaises(RuntimeError):
                rec.git(cmd, "origin")

    def test_ledger_tamper_on_head_rejects(self):
        os.makedirs(os.path.join(self.repo, "ops", "oversight", "ledger"))
        self.w("ops/oversight/ledger/reviews.jsonl", '{"a":1}\n{"a":2}\n')
        self.base = self.commit("with ledger")
        sh(self.repo, "git", "update-ref", "refs/remotes/origin/overnight-build", self.base)
        self.w("ops/oversight/ledger/reviews.jsonl", '{"a":2}\n')
        res, _ = self.evaluate(self.commit())
        self.assertEqual(self.by_id(res)["LEDGER"]["status"], M.FAIL)

    def test_short_sha_refused_by_cli(self):
        self.assertEqual(M.main(["--sha", "abc1234", "--no-github", "--repo-dir", self.repo]), 3)

    def test_verdict_never_says_approved(self):
        self.w("hq_x.py", "x = 4\n")
        res, _ = self.evaluate(self.commit())
        self.assertIn(res["verdict"], ("REJECT", "NEEDS_MORE_WORK", "RECOMMEND_APPROVE"))
        self.assertNotIn("APPROVED", json.dumps(res).upper().replace("RECOMMEND_APPROVE", ""))


if __name__ == "__main__":
    unittest.main()
