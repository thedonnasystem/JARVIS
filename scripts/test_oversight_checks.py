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


def run(name, status="completed", conclusion="success", sha=SHA, rid=1, app="github-actions"):
    return {"id": rid, "name": name, "status": status, "conclusion": conclusion, "head_sha": sha, "details_url": "u", "app": {"slug": app}}


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
        for p in ("ops/oversight/mandatory_checks.py", "ops/oversight/ledger.py", "docs/oversight/CHARTER.md", "ops/oversight/dependency_provenance.json",
                  "scripts/test_oversight_checks.py", "ops/oversight/evidence/x.py", "ops/oversight/ledger/other.jsonl"):
            self.assertIn(("PC-OVERSIGHT", "owner_gate"), rules(diff(p, ["x"])), p)
        # S2: the owner key list is its own class. Expected: never releasable. (Before: an ordinary owner gate.)
        self.assertEqual(rules(diff("ops/oversight/owner_keys.json", ["x"])), {("PC-OWNER-KEYS", "owner_only")})
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

    def test_mismatch_is_never_a_pass(self):
        """S5. A claimed count CI did not print cannot be confirmed: UNVERIFIED (it used to be a FAIL that also hit true claims
        about suites whose count CI does not print, e.g. PR #28's own "112 tests")."""
        c = M.check_test_claims("Verified: 900 unit tests OK", self.LOGS)
        self.assertEqual(c["status"], M.UNVERIFIED)
        self.assertIn("900", c["findings"][0]["msg"])

    def test_every_claim_must_match(self):
        c = M.check_test_claims("was 671 tests, now 731 tests", self.LOGS)
        self.assertEqual(c["status"], M.UNVERIFIED, "one matching number must not carry an unmatched one (before: PASS with a note)")
        self.assertTrue(any("671" in f["msg"] for f in c["findings"]))

    def test_per_job_counts_and_sums(self):
        logs = {"unit": "Ran 671 tests in 1s\n\nOK\n", "migrations": "Ran 671 tests in 1s\n\nOK\nRan 40 tests in 1s\n\nOK\n"}
        self.assertEqual(M.check_test_claims("671 tests", logs)["status"], M.PASS)
        self.assertEqual(M.check_test_claims("711 tests in the full gate", logs)["status"], M.PASS, "sum of one job's runs")
        self.assertEqual(M.check_test_claims("1382 tests", logs)["status"], M.UNVERIFIED, "runs of different jobs are the same tests, never added up")
        self.assertEqual(M.check_test_claims("112 tests", logs)["status"], M.UNVERIFIED)

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
    e = {"type": typ, "id": f"R{i}", "seq": i, "subject": {"sha": sha}, "reviewer": {"id": reviewer}, "author": {"id": author}, "recommendation": rec, "findings": [],
         "evidence": [{"ref": "cmd: python3 -m unittest", "sha256": "e" * 64}]}
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

    def test_later_approve_does_not_override_a_reject(self):
        """S4. Before: any later self-labelled APPROVE turned a REJECT into PASS."""
        rej = rev(1, rec="REJECT")
        self.assertEqual(self.st([rej, rev(2, reviewer="rev-c")]), M.FAIL, "approve that does not name the rejection")
        self.assertEqual(self.st([rej, rev(2, reviewer="rev-c", supersedes=["R1"], evidence=[])]), M.FAIL, "no evidence")
        self.assertEqual(self.st([rej, rev(2, reviewer="rev-c", supersedes=["R1"], evidence=[{"ref": "x"}])]), M.FAIL, "evidence without a hash")
        self.assertEqual(self.st([rej, rev(2, reviewer="rev-c", supersedes=["R1"], sha=OTHER)]), M.FAIL, "approve of another head")
        self.assertEqual(self.st([rej, rev(2, reviewer="auth-a", author="someone", supersedes=["R1"])]), M.FAIL, "approve by the author")
        self.assertEqual(self.st([rej, rev(2, reviewer="rev-c", supersedes=["R1"], imported=True)]), M.FAIL, "imported approve")
        self.assertEqual(self.st([rev(2, reviewer="rev-c", supersedes=["R1"]), dict(rej, seq=3)]), M.FAIL, "approve recorded BEFORE the rejection")
        self.assertEqual(self.st([rej, rev(2, reviewer="rev-c", supersedes=["R1"])]), M.PASS, "same head, evidence, non-author, names the rejection")

    def test_approval_needs_evidence_and_a_known_author(self):
        self.assertEqual(self.st([rev(1, evidence=[])]), M.UNVERIFIED, "an approval with no evidence is a label, not a review")
        self.assertEqual(self.st([rev(1)], author=None), M.UNVERIFIED, "no --author and no PR / git identity: independence is unknown")
        self.assertEqual(M.check_independent_review([rev(1)], SHA, None, ["someone-else"])["status"], M.PASS)

    def test_author_identity_from_metadata_and_label_normalisation(self):
        self.assertEqual(self.st([rev(1, reviewer="Auth-A ")]), M.FAIL, "'Auth-A ' is the same identity as 'auth-a'")
        self.assertEqual(M.check_independent_review([rev(1, reviewer="octocat")], SHA, "auth-a", ["Octocat"])["status"], M.FAIL, "reviewer equals the PR / git author")

    def test_import_type_entries_count_as_reviews(self):
        self.assertEqual(self.st([rev(1, typ="import", rec="NEEDS_MORE_WORK", imported=True)]), M.FAIL)
        self.assertEqual(self.st([rev(1, typ="import", imported=True)]), M.UNVERIFIED)

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
                self.assertIn(c["argv"][3], M.Recorder.READ_GIT, c["argv"])

    def test_recorder_refuses_write_commands(self):
        rec = M.Recorder(self.repo)
        for cmd in ("push", "merge", "commit", "reset", "stash", "fetch", "checkout", "update-ref", "config", "init", "clone", "worktree", "-c", "--exec-path", "lfs", "gc"):
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


SQLF = "migrations/20261201_x_y_v1.sql"
SK = "@unittest." + "skip"            # assembled so this file adds no literal skip marker of its own


class DiffParsing(unittest.TestCase):
    """S1 (parser bugs). Before: an added line starting with "++" and a removed line starting with "--" were dropped as headers."""

    def test_plus_plus_and_minus_minus_lines_are_content(self):
        f = M.parse_diff(diff(SQLF, ["++ 0; update system_state set kill_switch = false;", "+x"], ["-- old comment", "--- three"]))
        self.assertEqual([t for _, t in f[SQLF]["added"]], ["++ 0; update system_state set kill_switch = false;", "+x"])
        self.assertEqual(f[SQLF]["removed"], ["-- old comment", "--- three"])
        self.assertIn(("PC-KILL", "owner_gate"), rules(diff(SQLF, ["++ 0; update system_state set kill_switch = false;"])))

    def test_hash_is_not_a_comment_in_sql_but_is_in_python(self):
        self.assertIn(("PC-KILL", "owner_gate"), rules(diff(SQLF, ["select 1", "# 0; update system_state set kill_switch = false;"])))
        self.assertEqual(rules(diff("hq_x.py", ["# kill_switch is checked above"])), set())

    def test_hash_line_inside_a_python_string_is_code(self):
        src = 'Q = """\nselect 1\n# 0; update system_state set kill_switch = false\n"""\n# kill_switch note\n'
        f = M.scan_diff(M.parse_diff(diff("hq_x.py", src.split("\n")[:-1], status="A").replace("+10,", "+1,")), {"hq_x.py": (None, src)})
        self.assertEqual([(x["rule"], x["line"]) for x in f if x["rule"] == "PC-KILL"], [("PC-KILL", 3)])

    def test_form_feed_and_cr_do_not_split_lines(self):
        f = M.parse_diff(diff("hq_x.py", ["a = 1\x0ckill_switch = 0", "b = 2\rc = 3"]))
        self.assertEqual(len(f["hq_x.py"]["added"]), 2)

    def test_quoted_and_spaced_paths(self):
        t = 'diff --git "a/we\\303\\251 x.py" "b/we\\303\\251 x.py"\n--- "a/we\\303\\251 x.py"\n+++ "b/we\\303\\251 x.py"\n@@ -0,0 +1 @@\n+x\n' + diff("a b/c d.py", ["y"])
        self.assertEqual(set(M.parse_diff(t)), {"weé x.py", "a b/c d.py"})

    def test_raw_listing(self):
        z = "0" * 40
        raw = f":100644 000000 {z} {z} D\0old.py\0:000000 120000 {z} {z} A\0link\0:100644 100644 {z} {z} R087\0a.py\0b.py\0"
        self.assertEqual([(e[2], e[4], e[5]) for e in M.parse_raw(raw)], [("D", "old.py", None), ("A", "link", None), ("R", "a.py", "b.py")])


class SqlStatements(unittest.TestCase):
    """S1. Expected: the structure rules see whole statements, so line breaks, comments and quoting do not hide anything."""

    def r(self, *lines):
        return rules(diff(SQLF, list(lines)))

    def test_multi_line_grant(self):
        self.assertIn(("PC-PERM-OPEN", "owner_gate"), self.r("grant", "  all privileges on public.leads", "  to anon, authenticated;"))
        self.assertIn(("PC-PERM-RELAX", "reject"), self.r("grant select on public.leads", "to", "PUBLIC;"))

    def test_comment_split_and_second_statement_on_a_line(self):
        self.assertIn(("PC-PERM-RELAX", "reject"), self.r("select 1; grant/**/select on public.leads to/**/PUBLIC;"))
        self.assertIn(("PC-PERM-RELAX", "reject"), self.r("grant select on public.leads to -- harmless", "  public;"))

    def test_security_definer_and_rls_split_over_lines(self):
        self.assertIn(("PC-PERM", "owner_gate"), self.r("create function f() returns void language sql security", "definer as $$ select 1 $$;"))
        self.assertIn(("PC-PERM-RELAX", "reject"), self.r("alter table public.leads disable", "row level", "security;"))

    def test_text_in_comments_is_not_a_statement(self):
        self.assertEqual(self.r("-- grant all on x to public", "/* disable row level security */", "create table t (id int);"), set())

    def test_statement_inside_a_function_body(self):
        self.assertIn(("PC-PERM-RELAX", "reject"), self.r("create function f() returns void language plpgsql as $fn$", "begin", "  alter table public.leads disable row level security;", "end $fn$;"))

    def test_quoted_and_unicode_escaped_identifiers(self):
        self.assertIn(("PC-SPEND", "owner_gate"), self.r('update t set "daily_spend_cap_cents" = 99999;'))
        r = self.r('update system_state set U&"daily\\005Fspend\\005Fcap\\005Fcents" = 99999;')
        self.assertTrue({("PC-SPEND", "owner_gate"), ("PC-OBFUSCATION", "reject"), ("PC-STATE", "owner_gate")} <= r, r)
        self.assertIn(("PC-KILL", "owner_gate"), self.r('update system_state set U&"kill\\005Fswitch" = false;'))

    def test_dynamic_sql_is_unverified_never_pass(self):
        for stmt in ("do $$ begin execute 'update system_state set daily_' || 'spend_' || 'cap_cents = 9'; end $$;",
                     "do $$ begin execute format('insert into %I values (1)', 'executor_' || 'registry'); end $$;",
                     "prepare p as select 1;"):
            fs = M.scan_diff(M.parse_diff(diff(SQLF, [stmt])))
            self.assertIn(("PC-DYNSQL", "human_review"), {(f["rule"], f["class"]) for f in fs}, stmt)
            self.assertNotEqual(M.status_of(fs), M.PASS, stmt)
        self.assertEqual(M.status_of([f for f in M.scan_diff(M.parse_diff(diff(SQLF, ["do $$ begin execute v_sql; end $$;"]))) if f["rule"] == "PC-DYNSQL"]), M.UNVERIFIED)

    def test_grant_execute_and_trigger_execute_are_not_dynamic_sql(self):
        r = self.r("grant execute on function f() to service_role;", "create trigger t before insert on x for each row execute function g();")
        self.assertNotIn("PC-DYNSQL", {x[0] for x in r})

    def test_mode_and_system_state(self):
        for stmt in ("update system_state set mode = 'auto_in_caps';", "update public.system_state set mode = v_mode;", "alter table system_state alter column mode set default 'approve_first';",
                     "insert into system_state (id, mode) values (1, 'exceptions_only');", "create table s2 (mode text not null default 'auto_in_caps');"):
            r = self.r(stmt)
            self.assertTrue(r & {("PC-DRYRUN", "owner_gate"), ("PC-STATE", "owner_gate")}, stmt)
        self.assertIn(("PC-DRYRUN", "owner_gate"), rules(diff("hq_x.py", ["    _patch(st, {'mode': 'auto_in_caps'})"])))
        self.assertEqual(rules(diff("hq_x.py", ["    with open(p, mode='w') as f:"])), set())

    def test_outreach_channels_and_consent(self):
        self.assertIn(("PC-OUTREACH", "owner_gate"), self.r("alter table c add constraint c_ch check (channel in ('email', 'sms', 'telegram'));"))
        self.assertIn(("PC-OUTREACH", "owner_gate"), rules(diff("hq_mail.py", ["    if not consent_ok(lead): return"])))
        self.assertIn(("PC-OUTREACH", "owner_gate"), rules(diff("hq_mail.py", removed=["    if lead in suppression_list: return"])))

    def test_executor_registry_writes(self):
        for stmt in ("delete from public.executor_registry;", "insert\n into\n executor_registry (slug) values ('x');", 'insert into public."executor_registry" (slug) values (1);'):
            self.assertIn(("PC-EXEC-WRITE", "reject"), self.r(*stmt.split("\n")), stmt)

    def test_only_changed_statements_count_when_the_file_text_is_known(self):
        base = "grant select on t to anon;\ncreate table a (id int);\n"
        head = base + "create table b (id int);\n"
        d = M.parse_diff(diff(SQLF, ["create table b (id int);"]).replace("+10,", "+3,"))
        self.assertEqual(M.scan_diff(d, {SQLF: (base, head)}), [])
        head2 = "grant select on t\n  to anon, authenticated;\ncreate table a (id int);\n"       # a line added INSIDE an old statement
        d = M.parse_diff(diff(SQLF, ["  to anon, authenticated;"], ["grant select on t to anon;"]))
        self.assertIn("PC-PERM-OPEN", {f["rule"] for f in M.scan_diff(d, {SQLF: (base, head2)})})

    def test_unterminated_sql_is_flagged(self):
        self.assertIn(("PC-UNPARSED", "human_review"), self.r("select 'never closed;"))

    def test_revoke_removed_as_a_statement(self):
        self.assertIn(("PC-PERM-REMOVED", "owner_gate"), rules(diff(SQLF, removed=["revoke all on function f()", "  from public, anon;"])))


class RenamesAndFileClasses(unittest.TestCase):
    """B3 at rule level (the end-to-end cases are in Blockers). A rename is a deletion of the old path."""

    def ren(self, old, new):
        return f"diff --git a/{old} b/{new}\nsimilarity index 100%\nrename from {old}\nrename to {new}\n"

    def test_rename_in_patch_text_counts_as_deletion_of_the_old_path(self):
        for old, new, rule in (("scripts/gate.sh", "scripts/gate_legacy.sh", "PC-GUARD"), (".github/workflows/tests.yml", ".github/tests.yml.disabled", "PC-WORKFLOW"),
                               ("test_no_bypass.py", "no_bypass_checks_disabled.py", "PC-TESTS"), ("sqltests/executor_gate_check.sql", "ops/executor_gate_check.sql.disabled", "PC-TESTS"),
                               (".gitleaks.toml", "gitleaks.old", "PC-GITLEAKS"), (".github/dependabot.yml", "dependabot.off", "PC-DEPENDABOT"),
                               ("scripts/replica/run.sh", "scripts/replica_run.sh", "PC-GUARD")):
            self.assertIn((rule, "reject"), rules(self.ren(old, new)), old)
        for old, rule in (("Procfile", "PC-DEPLOY"), ("ops/oversight/ledger.py", "PC-OVERSIGHT"), ("test_hq_engine.py", "PC-TESTS")):
            self.assertIn((rule, "owner_gate"), rules(self.ren(old, "elsewhere.txt")), old)
        self.assertIn(("PC-OWNER-KEYS", "owner_only"), rules(self.ren("ops/oversight/owner_keys.json", "keys.json")))

    def test_symlink_submodule_gitattributes(self):
        link = "diff --git a/scripts/x b/scripts/x\nnew file mode 120000\n--- /dev/null\n+++ b/scripts/x\n@@ -0,0 +1 @@\n+/etc/passwd\n"
        self.assertIn(("PC-SYMLINK", "reject"), rules(link))
        sub = "diff --git a/vendor/lib b/vendor/lib\nnew file mode 160000\n--- /dev/null\n+++ b/vendor/lib\n@@ -0,0 +1 @@\n+Subproject commit " + "a" * 40 + "\n"
        self.assertIn(("PC-SUBMODULE", "owner_gate"), rules(sub))
        self.assertIn(("PC-SUBMODULE", "owner_gate"), rules(diff(".gitmodules", ['[submodule "x"]'], status="A")))
        self.assertIn(("PC-GITATTR", "owner_gate"), rules(diff(".gitattributes", ["*.sql filter=x"], status="A")))

    def test_guard_list_matches_what_the_gate_runs(self):
        for p in M.GUARD_TOOLS:
            self.assertTrue(os.path.exists(os.path.join(ROOT, p)), p + " is listed as a guard tool but does not exist")
        self.assertIn(("PC-GUARD", "owner_gate"), rules(diff("scripts/replica/run.sh", ["echo x"])))
        self.assertIn(("PC-GUARD", "owner_gate"), rules(diff("scripts/backup_drill.sh", ["echo x"])))

    def test_gutting_a_gate_or_test_file(self):
        gut = diff("scripts/replica/run.sh", ["echo REPLICA OK; echo RESULT: ALL PASSED"], [f"step {i}" for i in range(40)])
        self.assertIn(("PC-GUARD", "reject"), rules(gut))
        self.assertIn(("PC-TESTS", "reject"), rules(diff("sqltests/audit_paths_check.sql", ["select 1;"], [f"assert {i}" for i in range(30)])))
        self.assertIn(("PC-TESTS", "reject"), rules(diff("test_spend_paths.py", ["pass"], [f"assert {i}" for i in range(30)])))
        self.assertIn(("PC-TESTS", "owner_gate"), rules(diff("test_hq_engine.py", ["pass"], [f"assert {i}" for i in range(30)])))
        small = M.parse_diff(diff("test_hq_engine.py", ["a"], [f"l{i}" for i in range(12)]))
        self.assertEqual(M.scan_diff(small, {"test_hq_engine.py": ("\n" * 2000, "x")}), [], "11 net lines out of 2000 is an edit, not a gutting")
        self.assertIn(("PC-TESTS", "owner_gate"), rules(diff("sqltests/audit_paths_check.sql", removed=["select assert_x();"])))

    def test_added_skips(self):
        for line in (SK + '("later")', SK + "If(True, 'x')", "@" + "skipUnless(HAVE, 'x')", "        self." + "skipTest('x')", "        raise unittest.Skip" + "Test()",
                     "@pytest.mark." + "skip", "@unittest." + "expectedFailure"):
            self.assertIn(("PC-TESTS", "owner_gate"), rules(diff("test_hq_engine.py", [line])), line)
            self.assertIn(("PC-TESTS", "reject"), rules(diff("test_spend_paths.py", [line])), line)
        self.assertIn(("PC-TESTS", "owner_gate"), rules(diff("webtests/app.test.js", ["it." + "skip('x', () => {})"])))
        self.assertEqual(rules(diff("test_hq_engine.py", ["    self.assertTrue(x)"])), set())

    def test_test_named_file_used_by_runtime_code_is_scanned_as_code(self):
        d = M.parse_diff(diff("test_helpers.py", ["kill_switch = False"], status="A"))
        self.assertEqual(M.scan_diff(d), [])
        got = {(f["rule"], f["class"]) for f in M.scan_diff(d, None, {"test_helpers.py"})}
        self.assertEqual(got, {("PC-KILL", "owner_gate"), ("PC-TESTS", "owner_gate")})

    def test_engine_evidence_files_are_data_not_code(self):
        """S6. Before: ops/oversight/evidence/PR20_1899251.json tripped PC-DRYRUN on the PR that committed it."""
        self.assertEqual(rules(diff("ops/oversight/evidence/PR20_1899251.json", ['"msg": "dry_run flag / kill_switch / daily_spend_cap_cents"'], status="A")), set())
        self.assertEqual(rules(diff("ops/oversight/evidence/PR20_1899251.md", ["dry_run"], status="A")), set())
        self.assertEqual(rules(diff("ops/oversight/ledger/reviews.jsonl", ['{"findings":[{"title":"consent check on kill_switch"}]}'])), set(), "the ledger is data too")
        for p in ("ops/oversight/evidence/run.py", "ops/oversight/evidence/sub/x.json", "ops/oversight_evidence/x.json", "ops/oversight/evidence.json"):
            self.assertTrue(rules(diff(p, ["kill_switch = 1"], status="A")), p + " must not ride on the evidence exemption")
        key = "AK" + "IA" + "B" * 16
        self.assertIn(("PC-SECRET", "reject"), rules(diff("ops/oversight/evidence/x.json", [key], status="A")), "secrets are still scanned there")

    def test_github_dir_and_external_code(self):
        self.assertIn(("PC-GITHUB", "owner_gate"), rules(diff(".github/actions/x/action.yml", ["runs:"], status="A")))
        self.assertIn(("PC-DEPENDABOT", "reject"), rules(diff(".github/dependabot.yml", removed=["version: 2"], status="D")))
        self.assertIn(("PC-DEPENDABOT", "owner_gate"), rules(diff(".github/dependabot.yml", ["  x: y"])))
        self.assertIn(("PC-EXTERNAL", "reject"), rules(diff("webapp/index.html", ['<script src="https://cdn.example.invalid/x.js"></script>'])))
        self.assertIn(("PC-EXTERNAL", "owner_gate"), rules(diff("webapp/index.html", ['<script src="https://cdn.example.invalid/x.js" integrity="sha384-x"></script>'])))
        self.assertEqual(rules(diff("webapp/index.html", ['<script src="app.js"></script>'])), set())

    def test_codeowners_reorder_and_new_file(self):
        base = "/migrations/ @owner\n/ops/ @owner\n"
        self.assertIn("reject", [f["class"] for f in M.check_codeowners(base, "/ops/ @owner\n/migrations/ @owner\n")])
        self.assertIn("reject", [f["class"] for f in M.check_codeowners(base, base + "/ops/ @owner\n")])
        self.assertEqual([f["class"] for f in M.check_codeowners(None, base)], ["owner_gate"])


class MoreDependencies(unittest.TestCase):
    REG = Dependencies.REG

    def test_other_index_url_or_vcs_requirement_rejected(self):
        for line in ("--extra-index-url https://pypi.example.invalid/simple", "--index-url https://x.invalid/", "-i https://x.invalid/", "-f https://x.invalid/wheels",
                     "anthropic @ https://x.invalid/anthropic.whl", "https://x.invalid/pkg.tar.gz", "git+https://x.invalid/r.git#egg=anthropic", "-e ./local", "./wheels/x.whl",
                     "--trusted-host x.invalid", "-r other.txt"):
            c = M.check_dependencies({"requirements/runtime.in": ("anthropic>=2\n", "anthropic>=2\n" + line + "\n")}, self.REG)
            self.assertEqual(c["status"], M.FAIL, line)
            self.assertIn("DEP-SOURCE", {f["rule"] for f in c["findings"]}, line)
        ok = "anthropic>=2  # see https://docs.example.invalid\n"
        self.assertEqual(M.check_dependencies({"requirements/runtime.in": ("", ok)}, self.REG)["status"], M.PASS)
        self.assertEqual(M.check_dependencies({"requirements/runtime.in": ("-r base.in\n", "-r base.in\nanthropic>=2\n")}, self.REG)["status"], M.PASS, "an old include is not new")

    def test_package_json_that_is_not_an_object(self):
        """N2. Before: AttributeError, exit 1."""
        for bad in ("[1, 2]", '"x"', '{"dependencies": ["a"]}'):
            self.assertEqual(M.check_dependencies({"webtests/package.json": ("{}", bad)}, self.REG)["status"], M.FAIL, bad)
        self.assertEqual(M.check_dependencies({"webtests/package.json": ("[]", '{"devDependencies": {"jsdom": "1.0.0"}}')}, self.REG)["status"], M.PASS)
        url = json.dumps({"devDependencies": {"jsdom": "https://x.invalid/j.tgz"}})
        self.assertEqual(M.check_dependencies({"webtests/package.json": ("{}", url)}, self.REG)["status"], M.FAIL)

    def test_composite_action_must_be_pinned(self):
        p = ".github/actions/setup/action.yml"
        self.assertTrue(M.DEP_FILE_RE.search(p))
        self.assertEqual(M.check_dependencies({p: (None, "runs:\n  steps:\n    - uses: evil/action@main\n")}, self.REG)["status"], M.FAIL)
        self.assertEqual(M.check_dependencies({p: (None, "runs:\n  steps:\n    - uses: good/action@" + "f" * 40 + "\n")}, self.REG)["status"], M.PASS)
        self.assertEqual(M.check_dependencies({p: (None, "    - uses: docker://alpine:3\n")}, self.REG)["status"], M.FAIL)


class CiAndLogs(unittest.TestCase):
    def test_required_check_from_another_app_does_not_count(self):
        """N3."""
        fake = [run("unit", rid=1, app="some-other-app"), run("migrations", rid=2), run("secret-scan", rid=3)]
        self.assertEqual(M.check_ci(fake, SHA)["status"], M.FAIL)
        self.assertEqual(M.check_ci(GREEN + [run("unit", conclusion="failure", rid=99, app="some-other-app")], SHA)["status"], M.PASS)
        self.assertEqual(M.latest_runs(GREEN + [run("unit", rid=50), run("unit", rid=70, app="x")], SHA, ("unit", "migrations"))["unit"]["id"], 50, "the log read is of the run judged")

    def test_two_gate_summaries_fail(self):
        """N4."""
        self.assertEqual(M.check_gate_evidence(GATE_LOG + GATE_LOG)["status"], M.FAIL)
        forged = GATE_LOG.replace("lint           PASS", "lint           FAIL") + GATE_LOG
        self.assertEqual(M.check_gate_evidence(forged)["status"], M.FAIL)

    def test_test_results(self):
        """S5. Before: nothing looked at the result line; 'OK (skipped=600)' passed."""
        ok = "2026-11-16T02:14:11.7Z     Ran 671 tests in 8.9s\n2026-11-16T02:14:11.7Z     \n2026-11-16T02:14:11.7Z     OK\n"
        self.assertEqual(M.check_test_results({"unit": ok, "migrations": ok})["status"], M.PASS)
        skipped = ok.replace("    OK\n", "    OK (skipped=600)\n")
        c = M.check_test_results({"unit": skipped, "migrations": ok})
        self.assertEqual(c["status"], M.UNVERIFIED)
        self.assertTrue(any("600" in f["msg"] for f in c["findings"]))
        failed = ok.replace("    OK\n", "    FAILED (failures=2, skipped=1)\n")
        self.assertEqual(M.check_test_results({"unit": ok, "migrations": failed})["status"], M.FAIL)
        self.assertEqual(M.check_test_results({"unit": ok})["status"], M.UNVERIFIED, "a job whose log was not read")
        self.assertEqual(M.check_test_results({"unit": ok, "migrations": "Ran 5 tests in 1s\n"})["status"], M.UNVERIFIED, "no result line")
        self.assertEqual(M.check_test_results({"unit": ok, "migrations": "nothing\n"})["status"], M.UNVERIFIED)
        self.assertEqual(M.check_test_results(None)["status"], M.UNVERIFIED)
        self.assertEqual(M.check_test_results({"unit": ok, "migrations": ok.replace("671", "0")})["status"], M.UNVERIFIED)


class BaseAndEngine(unittest.TestCase):
    PR = {"base": {"ref": "overnight-build"}}

    def test_trusted_base_current_passes(self):
        self.assertEqual(M.check_base(self.PR, None, SHA, SHA, True)["status"], M.PASS)
        self.assertEqual(M.check_base(self.PR, "origin/overnight-build", SHA, SHA, True)["status"], M.PASS)

    def test_pr_chosen_base_is_never_trusted(self):
        """B1."""
        for pr in ({"base": {"ref": "evil-base"}}, {"base": {"ref": "claude/telegram-claude-bot-59nusk"}}, {"base": {}}, None):
            self.assertEqual(M.check_base(pr, None, SHA, SHA, True)["status"], M.UNVERIFIED, pr)
        for req in ("origin/evil-base", "evil-base", "HEAD", "refs/tags/origin/overnight-build", OTHER):
            self.assertEqual(M.check_base(self.PR, req, SHA, SHA, True)["status"], M.UNVERIFIED, req)

    def test_stale_or_missing_local_base_is_unverified(self):
        self.assertEqual(M.check_base(self.PR, None, SHA, OTHER, True)["status"], M.UNVERIFIED)
        self.assertEqual(M.check_base(self.PR, None, SHA, None, True)["status"], M.UNVERIFIED)
        self.assertEqual(M.check_base(self.PR, None, None, SHA, True)["status"], M.UNVERIFIED)
        self.assertEqual(M.check_base(None, None, SHA, None, False)["status"], M.UNVERIFIED)

    def test_trusted_ref_is_a_full_ref_name(self):
        self.assertEqual(M.TRUSTED_REF, "refs/remotes/origin/overnight-build")

    def test_engine_copy_must_equal_the_trusted_copy(self):
        with open(os.path.join(ROOT, "ops", "oversight", "mandatory_checks.py")) as f:
            eng = f.read()
        with open(os.path.join(ROOT, "ops", "oversight", "ledger.py")) as f:
            led = f.read()
        ok = {"ops/oversight/mandatory_checks.py": eng, "ops/oversight/ledger.py": led}
        self.assertEqual(M.check_engine(ok)["status"], M.PASS)
        self.assertEqual(M.check_engine(dict(ok, **{"ops/oversight/ledger.py": led + "#"}))["status"], M.UNVERIFIED)
        self.assertEqual(M.check_engine(dict(ok, **{"ops/oversight/mandatory_checks.py": None}))["status"], M.UNVERIFIED)


class SafeFiles(unittest.TestCase):
    """B2: the engine's two write helpers refuse links and anything outside their root."""

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = os.path.join(self.tmp.name, "root")
        os.makedirs(self.root)
        self.victim = os.path.join(self.tmp.name, "victim")
        with open(self.victim, "w") as f:
            f.write("precious")

    def tearDown(self):
        self.tmp.cleanup()

    def victim_text(self):
        with open(self.victim) as f:
            return f.read()

    def test_write_refuses_symlinked_file_dir_and_existing_path(self):
        os.symlink(self.victim, os.path.join(self.root, "tool.sh"))
        os.symlink(self.tmp.name, os.path.join(self.root, "scripts"))
        for rel in ("tool.sh", "scripts/victim", "scripts/new.sh", "../victim"):
            with self.assertRaises((M.Unavailable, OSError), msg=rel):
                M.safe_write(self.root, rel, "overwritten")
        self.assertEqual(self.victim_text(), "precious")
        self.assertFalse(os.path.exists(os.path.join(self.tmp.name, "new.sh")))
        M.safe_write(self.root, "ok/a.txt", "x")
        with self.assertRaises(M.Unavailable):
            M.safe_write(self.root, "ok/a.txt", "y")

    def test_copy_refuses_links_and_escapes(self):
        src, dst = os.path.join(self.tmp.name, "src"), os.path.join(self.tmp.name, "dst")
        os.makedirs(os.path.join(src, "migrations"))
        os.makedirs(dst)
        os.symlink(self.victim, os.path.join(src, "migrations", "a.sql"))
        with self.assertRaises(M.Unavailable):
            M.safe_copy(src, "migrations/a.sql", dst)
        with self.assertRaises(M.Unavailable):
            M.safe_copy(src, "../victim", dst)
        self.assertEqual(os.listdir(dst), [])

    def test_apply_order_entries(self):
        self.assertEqual(M.apply_order_problems("# c\n20261112_a_v1.sql\n20261113_b.sql\n"), [])
        for bad in ("../../etc/passwd", "/abs/x.sql", "a/b.sql", "*.sql", "x.sql y", "..sql", "$(id).sql", "x.txt"):
            self.assertTrue(M.apply_order_problems("ok.sql\n" + bad + "\n"), bad)


class SummaryText(unittest.TestCase):
    def test_text_from_the_change_is_inert_in_markdown(self):
        """N9."""
        evil = "x](http://evil.invalid) <img src=x> `code` | **bold**\n# heading"
        out = M.md(evil)
        self.assertNotIn("\n", out)
        for raw in ("](", "<", ">", "`code`", "**bold**", " | ", " # "):
            self.assertNotIn(raw, out)

    def test_verdict_reason_is_spelled_out(self):
        """N10."""
        self.assertEqual(set(M.REASON_TEXT), {"RULE_BROKEN", "OWNER_DECISION_REQUIRED", "EVIDENCE_MISSING", "ALL_CHECKS_PASS"})


class OwnerRelease(unittest.TestCase):
    """S2 at engine level: only findings of class owner_gate / human_review, only in the named checks, only for this head."""

    def checks(self):
        return [M.check("PROTECTED", "t", M.FAIL, [{"class": "owner_gate", "msg": "g"}, {"class": "human_review", "msg": "h"}]),
                M.check("PRODUCTION", "t", M.FAIL, [{"class": "owner_gate", "msg": "p"}]),
                M.check("CI", "t", M.FAIL, [{"class": "reject", "msg": "c"}])]

    def od(self, decision="approve", releases=("PROTECTED",), sha=SHA, seq=2):
        return {"type": "owner_decision", "id": f"OD-{seq}", "seq": seq, "subject": {"sha": sha}, "decision": decision, "releases": list(releases), "key_id": "k", "review_id": "M1"}

    def st(self, checks):
        return {c["id"]: c["status"] for c in checks}

    def test_no_ledger_or_no_decision_releases_nothing(self):
        for entries in (None, [], [self.od(sha=OTHER)]):
            cs = self.checks()
            self.assertEqual(M.apply_owner_decisions(cs, entries, SHA)["status"], M.NA)
            self.assertEqual(self.st(cs), {"PROTECTED": M.FAIL, "PRODUCTION": M.FAIL, "CI": M.FAIL})

    def test_approve_releases_only_the_named_checks(self):
        cs = self.checks()
        self.assertEqual(M.apply_owner_decisions(cs, [self.od()], SHA)["status"], M.PASS)
        self.assertEqual(self.st(cs), {"PROTECTED": M.PASS, "PRODUCTION": M.FAIL, "CI": M.FAIL})
        cs = self.checks()
        M.apply_owner_decisions(cs, [self.od(releases=("PROTECTED", "PRODUCTION", "CI"))], SHA)
        self.assertEqual(self.st(cs)["CI"], M.FAIL, "a broken rule is never released")

    def test_reject_and_owner_only_findings_survive_an_approval(self):
        cs = [M.check("PROTECTED", "t", M.FAIL, [{"class": "owner_gate", "msg": "g"}, {"class": "reject", "msg": "r"}]),
              M.check("PRODUCTION", "t", M.FAIL, [{"class": "owner_only", "msg": "k"}])]
        M.apply_owner_decisions(cs, [self.od(releases=("PROTECTED", "PRODUCTION"))], SHA)
        self.assertEqual([(c["status"], c["class"]) for c in cs], [(M.FAIL, "reject"), (M.FAIL, "owner_gate")])

    def test_latest_decision_wins_and_owner_reject_fails(self):
        cs = self.checks()
        c = M.apply_owner_decisions(cs, [self.od(), self.od("reject", (), seq=3)], SHA)
        self.assertEqual((c["status"], self.st(cs)["PROTECTED"]), (M.FAIL, M.FAIL))
        cs = self.checks()
        self.assertEqual(M.apply_owner_decisions(cs, [self.od(), self.od("defer", (), seq=3)], SHA)["status"], M.NA)
        self.assertEqual(self.st(cs)["PROTECTED"], M.FAIL)


class RepoFixture(unittest.TestCase):
    """A synthetic repository with every protected file class on its trusted base (no network, no database)."""

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        d = self.repo = os.path.join(self.tmp.name, "repo")
        for sub in ("scripts/replica", "migrations", "dist", "sqltests", ".github/workflows"):
            os.makedirs(os.path.join(d, sub))
        self.marker = os.path.join(self.tmp.name, "pwned")
        self.victim = os.path.join(self.tmp.name, "victim.txt")
        with open(self.victim, "w") as f:
            f.write("precious")
        self.w("scripts/lint_migrations.py", "import sys\nprint('lint_migrations: 0 error(s)')\nsys.exit(0)\n")
        self.w("scripts/build_bundle.sh", BUNDLE_SH)
        self.w("scripts/gate.sh", 'run unit "u" true\n')
        self.w("scripts/replica/run.sh", "echo replica\n")
        self.w(".github/workflows/tests.yml", "name: tests\njobs:\n  unit:\n    steps: []\n")
        self.w(".github/CODEOWNERS", "/ops/ @owner\n")
        self.w(".github/dependabot.yml", "version: 2\n")
        self.w(".gitleaks.toml", "title = 'x'\n")
        self.w("test_no_bypass.py", "import unittest\n" * 12)
        self.w("sqltests/executor_gate_check.sql", "select 1;\n" * 12)
        self.w("Procfile", "worker: python3 bot.py\n")
        self.w("migrations/APPLY_ORDER.txt", "# order\n20261112_a_v1.sql\n")
        self.w("migrations/20261112_a_v1.sql", "create table a (id int);\n")
        self.w("dist/APPLY_ALL.sql", "-- Fendezy HQ: all migrations in order. Paste into Supabase SQL editor and Run. Idempotent.\n\n-- ===== 20261112_a_v1.sql =====\ncreate table a (id int);\n")
        self.w("hq_x.py", "x = 1\n")
        sh(d, "git", "init", "-q", "-b", "main")
        self.base = self.commit("base")
        sh(d, "git", "update-ref", M.TRUSTED_REF, self.base)

    def tearDown(self):
        self.tmp.cleanup()

    def w(self, p, t):
        full = os.path.join(self.repo, p)
        os.makedirs(os.path.dirname(full), exist_ok=True)
        with open(full, "w") as f:
            f.write(t)

    def commit(self, msg="head"):
        sh(self.repo, "git", "add", "-A")
        sh(self.repo, "git", "commit", "-q", "-m", msg)
        return sh(self.repo, "git", "rev-parse", "HEAD")

    def evaluate(self, sha, base_ref=None, **kw):
        res = M.evaluate(M.Recorder(self.repo), sha, None, base_ref, "x/y", use_github=False, **kw)
        return res, {c["id"]: c for c in res["checks"]}

    def found(self, c, rule, klass=None):
        return [f for f in c["PROTECTED"]["findings"] if f.get("rule") == rule and (klass is None or f["class"] == klass)]

    def victim_text(self):
        with open(self.victim) as f:
            return f.read()

    def tmp_entries(self):
        t = tempfile.gettempdir()
        return {n for n in os.listdir(t) if n.startswith(("tmp.", "oversight_"))}



class Blockers(RepoFixture):
    """End-to-end reproductions of B1, B2, B3 and S7."""

    # ---- B1
    def evil_base(self):
        """A branch `evil-base` whose lint and bundle tools write a marker file, plus a protected change parked on it."""
        self.w("scripts/lint_migrations.py", f"open({self.marker!r}, 'w').write('x')\nprint('lint_migrations: 0 error(s)')\n")
        self.w("scripts/build_bundle.sh", f"touch {self.marker}\necho bundle current\n")
        self.w("hq_x.py", "x = 1\nkill_switch = False\n")
        evil = self.commit("evil base")
        sh(self.repo, "git", "update-ref", "refs/remotes/origin/evil-base", evil)
        self.w("hq_y.py", "y = 1\n")
        return self.commit("innocent head on top of the evil base")

    def test_b1_base_named_by_the_caller_is_never_read_or_run(self):
        head = self.evil_base()
        before = self.tmp_entries()
        for req in ("origin/evil-base", "refs/remotes/origin/evil-base"):
            res, c = self.evaluate(head, req)
            self.assertFalse(os.path.exists(self.marker), "a tool from the caller-chosen base was executed")
            self.assertEqual(c["BASE"]["status"], M.UNVERIFIED)
            self.assertEqual(res["subject"]["base_sha"], self.base, "the diff and the tools must come from the trusted ref")
            self.assertTrue(self.found(c, "PC-KILL"), "what was parked on the other base is part of the diff against the trusted base")
            self.assertTrue(self.found(c, "PC-GUARD"))
            self.assertEqual((c["LINT"]["status"], c["BUNDLE"]["status"]), (M.PASS, M.PASS), "trusted tools ran instead")
            self.assertNotEqual(res["verdict"], "RECOMMEND_APPROVE")
        self.assertEqual(self.tmp_entries(), before)

    def test_b1_a_tag_named_like_the_trusted_branch_cannot_shadow_it(self):
        head = self.evil_base()
        sh(self.repo, "git", "update-ref", "refs/tags/origin/overnight-build", sh(self.repo, "git", "rev-parse", "refs/remotes/origin/evil-base"))
        sh(self.repo, "git", "update-ref", "refs/heads/origin/overnight-build", sh(self.repo, "git", "rev-parse", "refs/remotes/origin/evil-base"))
        res, c = self.evaluate(head, "origin/overnight-build")
        self.assertFalse(os.path.exists(self.marker))
        self.assertEqual(res["subject"]["base_sha"], self.base)

    def test_b1_no_trusted_ref_means_nothing_runs(self):
        head = self.evil_base()
        sh(self.repo, "git", "update-ref", "-d", M.TRUSTED_REF)
        res, c = self.evaluate(head, "origin/evil-base")
        self.assertFalse(os.path.exists(self.marker))
        for cid in ("BASE", "PROTECTED", "LINT", "BUNDLE"):
            self.assertEqual(c[cid]["status"], M.UNVERIFIED, cid)

    def test_b1_cli_reports_the_refused_base(self):
        head = self.evil_base()
        out = os.path.join(self.tmp.name, "r.json")
        self.assertEqual(M.main(["--sha", head, "--base", "origin/evil-base", "--no-github", "--repo-dir", self.repo, "--out", out, "--ledger", os.path.join(self.tmp.name, "none")]), 10)
        with open(out) as f:
            res = json.load(f)
        self.assertEqual((res["subject"]["requested_base"], res["subject"]["base_ref"]), ("origin/evil-base", M.TRUSTED_REF))
        self.assertFalse(os.path.exists(self.marker))

    # ---- B2
    def test_b2_symlinked_tool_is_refused_and_nothing_is_written_through_it(self):
        for target in ("scripts/build_bundle.sh", "scripts/lint_migrations.py"):
            sh(self.repo, "git", "checkout", "-q", "-f", self.base)
            os.remove(os.path.join(self.repo, target))
            os.symlink(self.victim, os.path.join(self.repo, target))
            res, c = self.evaluate(self.commit("tool is a symlink"))
            self.assertEqual(self.victim_text(), "precious", target)
            self.assertEqual((c["LINT"]["status"], c["BUNDLE"]["status"]), (M.FAIL, M.FAIL), "refused before any tool ran")
            self.assertIn("symlink", c["LINT"]["findings"][0]["msg"])
            self.assertTrue(self.found(c, "PC-SYMLINK", "reject"))
            self.assertEqual(res["verdict"], "REJECT")

    def test_b2_symlinked_directory_is_refused(self):
        import shutil
        shutil.rmtree(os.path.join(self.repo, "scripts"))
        os.symlink(self.tmp.name, os.path.join(self.repo, "scripts"))
        before = set(os.listdir(self.tmp.name))
        res, c = self.evaluate(self.commit("scripts is a symlink"))
        self.assertEqual(self.victim_text(), "precious")
        self.assertEqual(set(os.listdir(self.tmp.name)), before, "nothing was created through the link")
        self.assertEqual(c["LINT"]["status"], M.FAIL)
        self.assertTrue(self.found(c, "PC-SYMLINK", "reject") and self.found(c, "PC-GUARD", "reject"))

    def test_b2_symlinks_elsewhere_are_never_materialised_as_links(self):
        os.symlink(self.victim, os.path.join(self.repo, "notes_link"))
        res, c = self.evaluate(self.commit("a link outside the tool inputs"))
        self.assertEqual(self.victim_text(), "precious")
        self.assertTrue(self.found(c, "PC-SYMLINK", "reject"))
        self.assertEqual((c["LINT"]["status"], c["BUNDLE"]["status"]), (M.PASS, M.PASS))

    def test_b2_engine_writes_nothing_into_the_reviewed_repository(self):
        self.w("hq_x.py", "x = 2\n")
        head = self.commit()
        snap = lambda: (sh(self.repo, "git", "for-each-ref"), sh(self.repo, "git", "status", "--porcelain", "--ignored"), sh(self.repo, "git", "config", "--local", "-l"),
                        sorted(os.listdir(os.path.join(self.repo, ".git", "objects", "info"))) if os.path.isdir(os.path.join(self.repo, ".git", "objects", "info")) else [])
        before = snap()
        rec = M.Recorder(self.repo)
        M.evaluate(rec, head, None, None, "x/y", use_github=False)
        self.assertEqual(snap(), before)
        for cmd in rec.commands:
            if cmd["argv"][:3] == ["git", "-C", self.repo]:
                self.assertIn(cmd["argv"][3], M.Recorder.READ_GIT, cmd["argv"])

    # ---- S7
    def test_s7_apply_order_traversal_is_refused_and_no_temp_file_is_left(self):
        secret = os.path.join(self.tmp.name, "secret.txt")
        with open(secret, "w") as f:
            f.write("TOP-SECRET-CONTENT")
        self.w("migrations/APPLY_ORDER.txt", "# order\n20261112_a_v1.sql\n" + "../" * 12 + secret.lstrip("/") + "\n")
        before = self.tmp_entries()
        res, c = self.evaluate(self.commit("traversal"))
        self.assertEqual((c["LINT"]["status"], c["BUNDLE"]["status"]), (M.FAIL, M.FAIL))
        self.assertIn("APPLY_ORDER", c["BUNDLE"]["findings"][0]["msg"])
        self.assertNotIn("TOP-SECRET-CONTENT", json.dumps(res))
        self.assertEqual(self.tmp_entries(), before, "a temp file was left outside the engine's own directory")

    def test_s7_real_bundle_script_runs_inside_the_engine_temp_dir_only(self):
        """The base script calls mktemp: before the fix one /tmp/tmp.* file was left per run."""
        self.w("migrations/20261113_b_v1.sql", "create table b (id int);\n")
        self.w("migrations/APPLY_ORDER.txt", "# order\n20261112_a_v1.sql\n20261113_b_v1.sql\n")
        before = self.tmp_entries()
        res, c = self.evaluate(self.commit("stale bundle"))
        self.assertEqual(c["BUNDLE"]["status"], M.FAIL, "dist/APPLY_ALL.sql was not regenerated")
        self.assertTrue(any("stale" in e for e in c["BUNDLE"]["evidence"]))
        with open(os.path.join(self.repo, "dist", "APPLY_ALL.sql"), "a") as f:
            f.write("\n-- ===== 20261113_b_v1.sql =====\ncreate table b (id int);\n")
        res, c = self.evaluate(self.commit("fresh bundle"))
        self.assertEqual(c["BUNDLE"]["status"], M.PASS, c["BUNDLE"])
        self.assertEqual(self.tmp_entries(), before)

    # ---- B3
    def mv(self, old, new):
        sh(self.repo, "git", "checkout", "-q", "-f", self.base)
        os.makedirs(os.path.dirname(os.path.join(self.repo, new)) or self.repo, exist_ok=True)
        sh(self.repo, "git", "mv", old, new)
        return self.evaluate(self.commit(f"mv {old}"))

    def test_b3_renaming_a_protected_file_is_a_deletion(self):
        cases = ((".github/CODEOWNERS", "docs_CODEOWNERS.old", "PC-CODEOWNERS", "reject"),
                 ("test_no_bypass.py", "no_bypass_checks_disabled.py", "PC-TESTS", "reject"),
                 ("sqltests/executor_gate_check.sql", "ops/executor_gate_check.sql.disabled", "PC-TESTS", "reject"),
                 ("scripts/gate.sh", "scripts/gate_legacy.sh", "PC-GUARD", "reject"),
                 ("scripts/gate.sh", "scripts/gate_legacy.sh", "PC-GATE", "reject"),
                 (".github/workflows/tests.yml", ".github/tests.yml.disabled", "PC-WORKFLOW", "reject"),
                 (".github/workflows/tests.yml", ".github/tests.yml.disabled", "PC-GATE", "reject"),
                 ("scripts/lint_migrations.py", "scripts/lint_old.py", "PC-LINT", "reject"),
                 ("scripts/replica/run.sh", "scripts/replica_run.sh.off", "PC-GUARD", "reject"),
                 (".gitleaks.toml", "gitleaks.toml.off", "PC-GITLEAKS", "reject"),
                 (".github/dependabot.yml", "dependabot.yml.off", "PC-DEPENDABOT", "reject"),
                 ("Procfile", "Procfile.old", "PC-DEPLOY", "owner_gate"))
        for old, new, rule, klass in cases:
            res, c = self.mv(old, new)
            self.assertTrue(self.found(c, rule, klass), f"{old} -> {new}: expected {rule}/{klass}, got {[(f.get('rule'), f['class']) for f in c['PROTECTED']['findings']]}")
            self.assertEqual(res["verdict"], "REJECT", old)

    def test_b3_rename_of_oversight_files_and_ledger(self):
        os.makedirs(os.path.join(self.repo, "ops", "oversight", "ledger"))
        self.w("ops/oversight/owner_keys.json", '{"keys": []}\n')
        self.w("ops/oversight/ledger/reviews.jsonl", '{"a":1}\n')
        self.base = self.commit("oversight files on base")
        sh(self.repo, "git", "update-ref", M.TRUSTED_REF, self.base)
        res, c = self.mv("ops/oversight/owner_keys.json", "ops/keys.json")
        self.assertTrue(self.found(c, "PC-OWNER-KEYS", "owner_only"))
        res, c = self.mv("ops/oversight/ledger/reviews.jsonl", "ops/oversight/ledger/reviews.old")
        self.assertEqual(c["LEDGER"]["status"], M.FAIL)

    def test_b3_rename_with_edit_scans_every_line_at_the_new_path(self):
        self.w("hq_spend.py", "\n".join(f"line_{i} = {i}" for i in range(40)) + "\ncap = daily_spend_cap_cents\n")
        self.base = self.commit("spend module on base")
        sh(self.repo, "git", "update-ref", M.TRUSTED_REF, self.base)
        res, c = self.mv("hq_spend.py", "hq_money.py")
        hit = self.found(c, "PC-SPEND")
        self.assertEqual({f["file"] for f in hit}, {"hq_spend.py", "hq_money.py"}, "a pure move shows no changed line with rename folding; both paths must be reported")

    def test_b3_type_change_file_to_symlink(self):
        os.remove(os.path.join(self.repo, "hq_x.py"))
        os.symlink(self.victim, os.path.join(self.repo, "hq_x.py"))
        res, c = self.evaluate(self.commit("file becomes a link"))
        self.assertTrue(self.found(c, "PC-SYMLINK", "reject"))

    # ---- S1 end to end (file text available: statements, comments, runtime use of test-named files)
    def test_s1_runtime_code_hidden_in_a_test_named_file(self):
        self.w("test_helpers.py", "def go():\n    kill_switch = False\n")
        self.w("hq_x.py", "import test_helpers\nx = 1\n")
        res, c = self.evaluate(self.commit("runtime code in a test-named file"))
        self.assertTrue(self.found(c, "PC-KILL") and self.found(c, "PC-TESTS"))
        for how in ("from test_helpers import go\n", "import os, test_helpers as t\n", "import importlib\nm = importlib.import_module('test_helpers')\n", "m = __import__('test_helpers')\n"):
            sh(self.repo, "git", "checkout", "-q", "-f", self.base)
            self.w("test_helpers.py", "def go():\n    kill_switch = False\n")
            self.w("hq_x.py", how + "x = 1\n")
            res, c = self.evaluate(self.commit("import form"))
            self.assertTrue(self.found(c, "PC-KILL"), how)
        sh(self.repo, "git", "checkout", "-q", "-f", self.base)
        self.w("test_helpers.py", "def go():\n    kill_switch = False\n")
        self.w("Procfile", "worker: python3 test_helpers.py\n")
        res, c = self.evaluate(self.commit("started by the Procfile"))
        self.assertTrue(self.found(c, "PC-KILL"))
        sh(self.repo, "git", "checkout", "-q", "-f", self.base)
        self.w("test_real.py", "def test():\n    kill_switch = False\n")
        self.w("hq_x.py", "FIXTURES = ('test_real.py',)  # mentions test_real, does not import it\nx = 1\n")
        res, c = self.evaluate(self.commit("an ordinary test, only mentioned by name"))
        self.assertFalse(self.found(c, "PC-KILL"))
        self.assertFalse(self.found(c, "PC-TESTS"))

    def test_s1_dynamic_sql_makes_protected_unverified(self):
        self.w("migrations/20261113_b_v1.sql", "do $$ begin execute 'select ' || '1'; end $$;\n")
        res, c = self.evaluate(self.commit("dynamic sql"))
        self.assertEqual(c["PROTECTED"]["status"], M.UNVERIFIED)
        self.assertNotEqual(res["verdict"], "RECOMMEND_APPROVE")

    def test_n8_missing_repository_is_a_usage_error_not_a_verdict(self):
        self.assertEqual(M.main(["--sha", "a" * 40, "--no-github", "--repo-dir", os.path.join(self.tmp.name, "nope")]), 3)

    def test_out_file_that_is_a_symlink_is_refused(self):
        link = os.path.join(self.tmp.name, "out.json")
        os.symlink(self.victim, link)
        self.assertEqual(M.main(["--sha", self.base, "--no-github", "--repo-dir", self.repo, "--out", link]), 3)
        self.assertEqual(self.victim_text(), "precious")


class OwnerDecisionEndToEnd(RepoFixture):
    """S2 end to end: a real Ed25519 signature, keys read from the trusted ref only, release bound to one head."""

    def setUp(self):
        super().setUp()
        import base64
        from cryptography.hazmat.primitives import serialization
        from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey
        sys.path.insert(0, os.path.join(ROOT, "ops", "oversight"))
        import ledger as L
        self.L, self.b64 = L, base64
        self.sk = Ed25519PrivateKey.generate()            # per test run; never stored
        self.pub = base64.b64encode(self.sk.public_key().public_bytes(serialization.Encoding.Raw, serialization.PublicFormat.Raw)).decode()
        self.keyfile = json.dumps({"keys": [{"key_id": "owner-test", "ed25519_public_b64": self.pub}]}) + "\n"
        self.w("ops/oversight/owner_keys.json", self.keyfile)
        self.base = self.commit("owner key registered on the trusted base")
        sh(self.repo, "git", "update-ref", M.TRUSTED_REF, self.base)
        self.keys = L.parse_owner_keys(self.keyfile)
        self.ledger = os.path.join(self.tmp.name, "ledger", "reviews.jsonl")
        self.w("hq_x.py", "x = 1\nkill_switch = False\n")
        self.head = self.commit("touches the kill switch")

    def mech(self, sha, i=1):
        return self.L.append({"type": "mechanical_check", "id": f"MC-{i}", "ts": "2026-11-16T00:00:00Z", "subject": {"sha": sha}, "reviewer": {"id": "engine"},
                              "verdict": "REJECT", "evidence": [{"ref": "result.json", "sha256": "c" * 64}]}, self.ledger, keys=self.keys)

    def decide(self, ref, sha, decision="approve", releases=("PROTECTED",), sk=None, key_id="owner-test", i=1, keys=None):
        e = {"type": "owner_decision", "id": f"OD-{i}", "ts": "2026-11-16T01:00:00Z", "subject": {"sha": sha}, "review_id": ref["id"], "review_hash": ref["entry_hash"],
             "decision": decision, "decision_text": "Release the kill-switch touch on this head.", "releases": list(releases), "key_id": key_id}
        e["signature"] = self.b64.b64encode((sk or self.sk).sign(self.L.owner_payload(e))).decode()
        return self.L.append(e, self.ledger, keys=keys or self.keys)

    def run_engine(self, sha):
        return self.evaluate(sha, ledger_path=self.ledger)

    def test_without_a_decision_the_owner_gate_stands(self):
        self.mech(self.head)
        res, c = self.run_engine(self.head)
        self.assertEqual((c["PROTECTED"]["status"], c["PROTECTED"]["class"], c["OWNER-DECISION"]["status"]), (M.FAIL, "owner_gate", M.NA))
        self.assertEqual((res["verdict"], res["verdict_reason"]), ("REJECT", "OWNER_DECISION_REQUIRED"))

    def test_signed_decision_for_this_head_releases_the_gate(self):
        self.decide(self.mech(self.head), self.head)
        res, c = self.run_engine(self.head)
        self.assertEqual((c["PROTECTED"]["status"], c["OWNER-DECISION"]["status"]), (M.PASS, M.PASS))
        self.assertTrue(all(f["class"] == "released" and f["released_by"] == "OD-1" for f in c["PROTECTED"]["findings"]))
        self.assertEqual(res["owner_gate_findings"], 0)
        self.assertNotEqual(res["verdict"], "RECOMMEND_APPROVE", "the other evidence (CI, review, engine copy) is still missing")

    def test_decision_for_another_head_releases_nothing(self):
        self.decide(self.mech(self.head), self.head)
        self.w("hq_x.py", "x = 1\nkill_switch = False\nspend_cap = 10 ** 9\n")
        newer = self.commit("one more commit after the Owner signed")
        res, c = self.run_engine(newer)
        self.assertEqual((c["PROTECTED"]["status"], c["OWNER-DECISION"]["status"]), (M.FAIL, M.NA), "a signature is for one exact SHA")

    def test_decision_does_not_release_a_broken_rule_or_another_check(self):
        self.w("migrations/20261113_b_v1.sql", "grant all on public.a to public;\n")
        head = self.commit("rule broken")
        self.decide(self.mech(head), head, releases=("PROTECTED", "PRODUCTION"))
        res, c = self.run_engine(head)
        self.assertEqual((c["PROTECTED"]["status"], c["PROTECTED"]["class"]), (M.FAIL, "reject"))
        self.assertEqual(res["verdict_reason"], "RULE_BROKEN")

    def test_key_that_is_only_on_the_head_or_in_the_working_tree_does_not_count(self):
        """Before: any agent with push could add its own key to owner_keys.json and sign."""
        from cryptography.hazmat.primitives import serialization
        from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey
        agent = Ed25519PrivateKey.generate()
        apub = self.b64.b64encode(agent.public_key().public_bytes(serialization.Encoding.Raw, serialization.PublicFormat.Raw)).decode()
        both = json.dumps({"keys": [{"key_id": "owner-test", "ed25519_public_b64": self.pub}, {"key_id": "agent", "ed25519_public_b64": apub}]}) + "\n"
        self.w("ops/oversight/owner_keys.json", both)                       # on the head AND in the working tree
        head = self.commit("agent adds its own key")
        allk = self.L.parse_owner_keys(both)
        self.decide(self.L.append({"type": "mechanical_check", "id": "MC-1", "ts": "2026-11-16T00:00:00Z", "subject": {"sha": head}, "reviewer": {"id": "engine"},
                                   "verdict": "REJECT", "evidence": []}, self.ledger, keys=allk), head, sk=agent, key_id="agent", keys=allk)
        res, c = self.run_engine(head)
        self.assertEqual(c["PROTECTED"]["status"], M.FAIL)
        self.assertTrue(self.found(c, "PC-OWNER-KEYS", "owner_only"))
        self.assertEqual(c["OWNER-DECISION"]["status"], M.NA, "the ledger does not verify against the trusted keys, so nothing in it is used")
        self.assertEqual(c["INDEPENDENT-REVIEW"]["status"], M.UNVERIFIED)

    def test_owner_key_change_is_not_released_even_by_a_valid_owner_signature(self):
        self.w("ops/oversight/owner_keys.json", self.keyfile.replace("owner-test", "owner-test-2"))
        head = self.commit("key list edited")
        self.decide(self.mech(head), head)
        res, c = self.run_engine(head)
        self.assertEqual((c["PROTECTED"]["status"], c["PROTECTED"]["class"]), (M.FAIL, "owner_gate"))
        self.assertTrue(self.found(c, "PC-OWNER-KEYS", "owner_only"))
        self.assertEqual(res["verdict"], "REJECT")

    def test_owner_reject_and_revoked_key(self):
        m = self.mech(self.head)
        self.decide(m, self.head)
        self.decide(m, self.head, decision="reject", releases=(), i=2)
        res, c = self.run_engine(self.head)
        self.assertEqual((c["OWNER-DECISION"]["status"], c["PROTECTED"]["status"]), (M.FAIL, M.FAIL), "the latest decision wins")
        # the key is revoked on the trusted base as of seq 1: the two decisions (seq 2, 3) are no longer valid, so nothing is released
        self.w("ops/oversight/owner_keys.json", json.dumps({"keys": [{"key_id": "owner-test", "ed25519_public_b64": self.pub, "revoked_after_seq": 1}]}) + "\n")
        sh(self.repo, "git", "stash", "-q")
        sh(self.repo, "git", "checkout", "-q", "-f", self.base)
        sh(self.repo, "git", "stash", "pop", "-q")
        revoked_base = self.commit("revoke")
        sh(self.repo, "git", "update-ref", M.TRUSTED_REF, revoked_base)
        res, c = self.run_engine(self.head)
        self.assertEqual(c["OWNER-DECISION"]["status"], M.NA)

    def test_ledger_that_does_not_extend_the_trusted_copy_is_not_used(self):
        """Replay / rewrite: the ledger handed to the engine must start with the ledger on the trusted base."""
        os.makedirs(os.path.join(self.repo, "ops", "oversight", "ledger"), exist_ok=True)
        sh(self.repo, "git", "checkout", "-q", "-f", self.base)
        self.w("ops/oversight/ledger/reviews.jsonl", '{"some":"other history"}\n')
        anchored = self.commit("a ledger exists on the trusted base")
        sh(self.repo, "git", "update-ref", M.TRUSTED_REF, anchored)
        self.decide(self.mech(self.head), self.head)
        res, c = self.run_engine(self.head)
        self.assertEqual((c["OWNER-DECISION"]["status"], c["INDEPENDENT-REVIEW"]["status"]), (M.NA, M.UNVERIFIED))
        self.assertEqual(c["PROTECTED"]["status"], M.FAIL)

    def test_review_by_the_git_author_is_a_self_review(self):
        self.L.append({"type": "review", "id": "R-1", "ts": "2026-11-16T00:00:00Z", "subject": {"sha": self.head}, "reviewer": {"id": "T"}, "author": {"id": "someone"},
                       "recommendation": "APPROVE", "findings": [], "evidence": [{"ref": "x", "sha256": "d" * 64}]}, self.ledger, keys=self.keys)
        res, c = self.run_engine(self.head)                # the fixture commits as author "t"
        self.assertEqual(c["INDEPENDENT-REVIEW"]["status"], M.FAIL)
        self.assertIn("t", res["subject"]["author_ids_compared"])


class Proposals(unittest.TestCase):
    """S8: the workflow proposal as text (it has never run in GitHub Actions; these tests cannot replace a run)."""

    def setUp(self):
        with open(os.path.join(ROOT, "docs", "oversight", "proposals", "oversight-check.workflow.yml.txt")) as f:
            self.text = f.read()
        self.code = "\n".join(l.split(" # ")[0].rstrip() for l in self.text.splitlines() if not l.lstrip().startswith("#"))

    def test_trusted_ref_is_a_literal_and_nothing_comes_from_the_pr_base(self):
        self.assertIn("ref: overnight-build", self.code)
        for bad in ("pull_request.base", "base.sha", "base.ref", "--base ", "pull_request_target", "BASE_REF"):
            self.assertNotIn(bad, self.code, bad)

    def test_engine_ledger_keys_and_register_come_from_the_trusted_checkout(self):
        self.assertIn("python3 _trusted/ops/oversight/mandatory_checks.py", self.code)
        self.assertIn("--ledger _trusted/ops/oversight/ledger/reviews.jsonl", self.code)
        self.assertIn("--registry _trusted/ops/oversight/dependency_provenance.json", self.code)
        self.assertNotIn("python3 ops/oversight", self.code, "nothing from the PR's own tree is executed")
        self.assertIn('--author "$PR_AUTHOR"', self.code)
        self.assertIn("--base-file _trusted/ops/oversight/ledger/reviews.jsonl", self.code, "a real append-only check, not only `verify`")

    def test_job_cannot_be_skipped_into_a_pass_and_has_no_write_scope(self):
        self.assertIn("always()", self.code)
        self.assertNotIn("write", self.code)
        self.assertEqual(self.code.count("persist-credentials: false"), 2)

    def test_pins_are_the_ones_the_real_workflow_uses_and_pass_the_pin_checker(self):
        with open(os.path.join(ROOT, ".github", "workflows", "tests.yml")) as f:
            real = set(M.USES_RE.findall(f.read()))
        mine = set(M.USES_RE.findall(self.code))
        self.assertTrue(mine and mine <= real, mine - real)
        sys.path.insert(0, os.path.join(ROOT, "scripts"))
        import check_workflow_pins as P
        self.assertEqual(P.check_text(".github/workflows/proposal.yml", "permissions:\n  contents: read\njobs:\n" + self.text), [])
        self.assertEqual(M.check_dependencies({".github/workflows/tests.yml": ("", self.text)}, None)["status"], M.PASS)

    def test_no_proposal_is_live(self):
        for d in (".github/workflows", "migrations"):
            self.assertFalse([n for n in os.listdir(os.path.join(ROOT, d)) if "oversight" in n], d)
        names = os.listdir(os.path.join(ROOT, "docs", "oversight", "proposals"))
        self.assertTrue(all(n.endswith((".txt", ".md")) for n in names), names)


BUNDLE_SH = """#!/usr/bin/env bash
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"; out="$(mktemp)"
{ echo "-- Fendezy HQ: all migrations in order. Paste into Supabase SQL editor and Run. Idempotent."
  for f in $(grep -v '^#' "$root/migrations/APPLY_ORDER.txt"); do echo; echo "-- ===== $f ====="; cat "$root/migrations/$f"; done; } > "$out"
if [ "${1:-}" = "--check" ]; then cmp -s "$out" "$root/dist/APPLY_ALL.sql" || { echo "dist/APPLY_ALL.sql is stale: run scripts/build_bundle.sh"; exit 1; }; echo "bundle current"
else mv "$out" "$root/dist/APPLY_ALL.sql"; echo "bundle rebuilt"; fi
"""


class RealTools(unittest.TestCase):
    def test_fixture_bundle_script_is_the_repository_one(self):
        """The S7 tests above must exercise the script CI really runs (same body, comment line aside)."""
        with open(os.path.join(ROOT, "scripts", "build_bundle.sh")) as f:
            real = [l for l in f.read().splitlines() if not l.startswith("# ")]
        self.assertEqual(real, BUNDLE_SH.splitlines())

    def test_real_lint_accepts_root_and_a_full_ref_as_base(self):
        with open(os.path.join(ROOT, "scripts", "lint_migrations.py")) as f:
            src = f.read()
        self.assertIn('"--root"', src)
        self.assertIn('"--base"', src)

    def test_real_apply_order_is_clean(self):
        with open(os.path.join(ROOT, "migrations", "APPLY_ORDER.txt")) as f:
            self.assertEqual(M.apply_order_problems(f.read()), [])

    def test_no_symlinks_in_this_repository(self):
        out = subprocess.run(["git", "-C", ROOT, "ls-files", "-s"], capture_output=True, text=True).stdout
        self.assertEqual([l for l in out.splitlines() if l.startswith(("120000", "160000"))], [])


if __name__ == "__main__":
    unittest.main()
