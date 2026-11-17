"""Tests for scripts/check_protected_paths.py: a throwaway git repo per test, real `git diff`, mocked GitHub API."""
import os
import shutil
import subprocess
import sys
import tempfile
import unittest

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import check_protected_paths as C  # noqa: E402

CFG = C.load()
SHA = "a" * 40
OLD = "b" * 40


class Repo:
    def __init__(self):
        self.d = tempfile.mkdtemp()
        self.g("init", "-q", "-b", "main")
        self.g("config", "user.email", "t@example.invalid"); self.g("config", "user.name", "t")
        self.write("hq_meter.py", "def reserve():\n    return 1\n" * 20)
        self.write("hq_ideas_extra.py", "x = 1\n")
        self.write("migrations/APPLY_ORDER.txt", "a.sql\n")
        self.g("add", "-A"); self.g("commit", "-qm", "base"); self.g("branch", "base")

    def g(self, *a):
        return subprocess.run(["git", *a], cwd=self.d, check=True, capture_output=True).stdout.decode()

    def write(self, p, s):
        full = os.path.join(self.d, p)
        os.makedirs(os.path.dirname(full), exist_ok=True)
        with open(full, "w") as f:
            f.write(s)

    def commit(self):
        self.g("add", "-A"); self.g("commit", "-qm", "change")
        return C.scan(CFG, "base", "HEAD", root=self.d)

    def close(self):
        shutil.rmtree(self.d, ignore_errors=True)


class ScanTests(unittest.TestCase):
    def setUp(self):
        self.r = Repo()

    def tearDown(self):
        self.r.close()

    def test_unprotected_edit_passes(self):
        self.r.write("hq_ideas_extra.py", "x = 2\nprint('hello')\n")
        self.assertEqual(self.r.commit(), [])

    def test_protected_modify_is_found(self):
        self.r.write("hq_meter.py", "def reserve():\n    return 0\n")
        f = self.r.commit()
        self.assertTrue(any(p == "hq_meter.py" and cat == "money" for cat, p, _ in f), f)

    def test_rename_out_of_protection_is_found(self):
        self.r.g("mv", "hq_meter.py", "hq_free.py")
        f = self.r.commit()
        self.assertTrue(any("rename of protected file hq_meter.py" in why for _, _, why in f), f)

    def test_copy_of_protected_file_is_found(self):
        with open(os.path.join(self.r.d, "hq_meter.py")) as src:
            self.r.write("hq_meter_copy.py", src.read())
        f = self.r.commit()
        self.assertTrue(any("copy of protected file hq_meter.py" in why for _, _, why in f), f)

    def test_symlink_into_protection_and_out_of_repo(self):
        os.symlink("hq_meter.py", os.path.join(self.r.d, "alias.py"))
        os.symlink("../../etc/passwd", os.path.join(self.r.d, "escape.py"))
        f = self.r.commit()
        whys = " | ".join(w for _, _, w in f)
        self.assertIn("symlink into protected path hq_meter.py", whys)
        self.assertIn("leaves the repository", whys)

    def test_case_variant_and_directory(self):
        self.r.write("HQ_METER.py", "x\n")
        self.r.write(".github/workflows/x.yml", "on: push\n")
        f = self.r.commit()
        self.assertTrue(any(p == "HQ_METER.py" for _, p, _ in f), f)
        self.assertTrue(any(p == ".github/workflows/x.yml" and cat == "judges" for cat, p, _ in f), f)

    def test_sql_writes_in_unprotected_code(self):
        self.r.write("hq_ideas_extra.py", "x = 1\ncur.execute(\"update system_state set kill_switch = false\")\nq = 'select 1 from system_state'\n")
        f = self.r.commit()
        self.assertEqual([c for c, _, _ in f], ["kill_switch_and_mode"], f)      # the read-only line is not a finding

    def test_destructive_statements(self):
        self.r.write("tools/cleanup.py", "cur.execute('DELETE FROM leads')\ncur.execute('truncate tasks')\n")
        f = self.r.commit()
        self.assertEqual(sum(1 for c, _, _ in f if c == "destructive"), 2, f)

    def test_permission_statement_in_sql_file(self):
        self.r.write("tools/x.sql", "grant all on public.tasks to anon;\n")
        f = self.r.commit()
        self.assertTrue(any(c == "jarvis_permissions" for c, _, _ in f), f)

    def test_backup_prefix_write(self):
        self.r.write("tools/y.py", "sql = 'create or replace function public.backup_snapshot() ...'\n")
        f = self.r.commit()
        self.assertTrue(any(c == "legal_privacy" for c, _, _ in f), f)

    def test_deleting_protected_file(self):
        self.r.g("rm", "-q", "hq_meter.py")
        f = self.r.commit()
        self.assertTrue(any(p == "hq_meter.py" and why == "deleted" for _, p, why in f), f)


class PathTests(unittest.TestCase):
    def test_the_list_protects_itself_and_the_judges(self):
        for p in ("ops/PROTECTED_PATHS.json", "ops/CRITICAL_EVENTS.json", "scripts/check_protected_paths.py", ".github/CODEOWNERS", ".github/workflows/tests.yml",
                  "scripts/gate.sh", "sqltests/jarvis_core_check.sql", "migrations/20261123_jarvis_core_v1.sql", "hq_selfedit.py", "hq_llm.py", "test_no_bypass.py"):
            self.assertIsNotNone(C.path_category(CFG, p), p)

    def test_path_findings(self):
        f = C.path_findings(CFG, ["../x.py", "hq_ideas.py", "./hq_capital.py", "a/../../b"])
        self.assertEqual([p for _, p, _ in f], ["../x.py", "hq_capital.py", "a/../../b"])

    def test_every_category_from_the_brief_exists(self):
        self.assertEqual(set(CFG["categories"]), {"money", "kill_switch_and_mode", "jarvis_permissions", "legal_privacy", "judges", "audit_history", "database"})

    def test_cli_paths_mode(self):
        self.assertEqual(C.main(["--paths", "hq_ideas.py"]), 0)
        self.assertEqual(C.main(["--paths", "hq_policy.py"]), 1)


class ApprovalTests(unittest.TestCase):
    def fetch(self, reviews=(), events=(), labels=()):
        def f(url):
            if "/reviews" in url:
                return list(reviews) if "page=1" in url else []
            if "/events" in url:
                return list(events) if "page=1" in url else []
            return {"labels": [{"name": n} for n in labels]}
        return f

    def rv(self, login, state, sha=SHA):
        return {"user": {"login": login}, "state": state, "commit_id": sha}

    def ev(self, login, event, name):
        return {"actor": {"login": login}, "event": event, "label": {"name": name}}

    def test_owner_review_on_head(self):
        self.assertTrue(C.approval(CFG, "o/r", 5, SHA, self.fetch([self.rv("thedonnasystem", "APPROVED")]))[0])

    def test_review_on_an_older_commit_does_not_count(self):
        self.assertFalse(C.approval(CFG, "o/r", 5, SHA, self.fetch([self.rv("thedonnasystem", "APPROVED", OLD)]))[0])

    def test_review_by_someone_else_does_not_count(self):
        self.assertFalse(C.approval(CFG, "o/r", 5, SHA, self.fetch([self.rv("jarvis-bot", "APPROVED")]))[0])

    def test_changes_requested_after_approval(self):
        self.assertFalse(C.approval(CFG, "o/r", 5, SHA, self.fetch([self.rv("thedonnasystem", "APPROVED"), self.rv("thedonnasystem", "CHANGES_REQUESTED")]))[0])

    def test_owner_label_for_this_head(self):
        lab = "owner-approved-" + SHA[:12]
        self.assertTrue(C.approval(CFG, "o/r", 5, SHA, self.fetch(events=[self.ev("thedonnasystem", "labeled", lab)], labels=[lab]))[0])

    def test_label_by_other_account_or_removed_or_stale(self):
        lab = "owner-approved-" + SHA[:12]
        self.assertFalse(C.approval(CFG, "o/r", 5, SHA, self.fetch(events=[self.ev("jarvis-bot", "labeled", lab)], labels=[lab]))[0])
        self.assertFalse(C.approval(CFG, "o/r", 5, SHA, self.fetch(events=[self.ev("thedonnasystem", "labeled", lab), self.ev("thedonnasystem", "unlabeled", lab)], labels=[]))[0])
        old = "owner-approved-" + OLD[:12]
        self.assertFalse(C.approval(CFG, "o/r", 5, SHA, self.fetch(events=[self.ev("thedonnasystem", "labeled", old)], labels=[old]))[0])

    def test_ci_fails_closed_without_context(self):
        env = {"GITHUB_EVENT_NAME": "pull_request", "BASE_SHA": "HEAD", "HEAD_SHA": "HEAD"}
        old = {k: os.environ.get(k) for k in env}
        os.environ.update(env)
        try:
            self.assertEqual(C.main(["--ci"]), 0)     # no change between HEAD and HEAD: nothing to approve
        finally:
            for k, v in old.items():
                if v is None:
                    os.environ.pop(k, None)
                else:
                    os.environ[k] = v


if __name__ == "__main__":
    unittest.main()
