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
import copy  # noqa: E402
ACFG = copy.deepcopy(CFG)              # approval tests: a Chairman account that no agent uses (what the owner decision B1 sets up)
ACFG["owner_login"], ACFG["agent_logins"] = "chairman-second", ["thedonnasystem"]
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
            if url.endswith("/pulls/5"):
                return {"user": {"login": "thedonnasystem"}}
            return {"labels": [{"name": n} for n in labels]}
        return f

    def rv(self, login, state, sha=SHA):
        return {"user": {"login": login}, "state": state, "commit_id": sha}

    def ev(self, login, event, name):
        return {"actor": {"login": login}, "event": event, "label": {"name": name}}

    def test_owner_review_on_head(self):
        self.assertTrue(C.approval(ACFG, "o/r", 5, SHA, self.fetch([self.rv("chairman-second", "APPROVED")]))[0])

    def test_review_on_an_older_commit_does_not_count(self):
        self.assertFalse(C.approval(ACFG, "o/r", 5, SHA, self.fetch([self.rv("chairman-second", "APPROVED", OLD)]))[0])

    def test_review_by_someone_else_does_not_count(self):
        self.assertFalse(C.approval(ACFG, "o/r", 5, SHA, self.fetch([self.rv("jarvis-bot", "APPROVED")]))[0])

    def test_changes_requested_after_approval(self):
        self.assertFalse(C.approval(ACFG, "o/r", 5, SHA, self.fetch([self.rv("chairman-second", "APPROVED"), self.rv("chairman-second", "CHANGES_REQUESTED")]))[0])

    def test_owner_label_for_this_head(self):
        lab = "owner-approved-" + SHA[:12]
        self.assertTrue(C.approval(ACFG, "o/r", 5, SHA, self.fetch(events=[self.ev("chairman-second", "labeled", lab)], labels=[lab]))[0])

    def test_label_by_other_account_or_removed_or_stale(self):
        lab = "owner-approved-" + SHA[:12]
        self.assertFalse(C.approval(ACFG, "o/r", 5, SHA, self.fetch(events=[self.ev("jarvis-bot", "labeled", lab)], labels=[lab]))[0])
        self.assertFalse(C.approval(ACFG, "o/r", 5, SHA, self.fetch(events=[self.ev("chairman-second", "labeled", lab), self.ev("chairman-second", "unlabeled", lab)], labels=[]))[0])
        old = "owner-approved-" + OLD[:12]
        self.assertFalse(C.approval(ACFG, "o/r", 5, SHA, self.fetch(events=[self.ev("chairman-second", "labeled", old)], labels=[old]))[0])

    def test_ci_fails_closed_without_context(self):
        env = {"GITHUB_EVENT_NAME": "pull_request", "BASE_REF": "x", "HEAD_SHA": "HEAD"}
        old = {k: os.environ.get(k) for k in env}
        os.environ.update(env)
        try:
            self.assertEqual(C.main(["--ci", "--base", "HEAD"]), 0)     # no change between HEAD and HEAD: nothing to approve
        finally:
            for k, v in old.items():
                if v is None:
                    os.environ.pop(k, None)
                else:
                    os.environ[k] = v


class IdentityTests(unittest.TestCase):
    """B1: the approval must come from an identity agents cannot use."""
    def fetch(self, author="thedonnasystem", events=(), reviews=(), labels=()):
        def f(url):
            if "/reviews" in url:
                return list(reviews) if "page=1" in url else []
            if "/events" in url:
                return list(events) if "page=1" in url else []
            if url.endswith("/pulls/5"):
                return {"user": {"login": author}}
            return {"labels": [{"name": n} for n in labels]}
        return f

    def test_shipped_config_fails_closed_today(self):
        lab = "owner-approved-" + SHA[:12]
        ev = [{"actor": {"login": "thedonnasystem"}, "event": "labeled", "label": {"name": lab}}]
        ok, how = C.approval(CFG, "o/r", 5, SHA, self.fetch(events=ev, labels=[lab]))
        self.assertFalse(ok); self.assertIn("FAIL CLOSED", how); self.assertIn("second GitHub account", how)
        ok, how = C.approval(CFG, "o/r", 5, SHA, self.fetch(reviews=[{"user": {"login": "thedonnasystem"}, "state": "APPROVED", "commit_id": SHA}]))
        self.assertFalse(ok)

    def test_owner_equal_to_author_fails_closed(self):
        ok, how = C.approval(ACFG, "o/r", 5, SHA, self.fetch(author="chairman-second", reviews=[{"user": {"login": "chairman-second"}, "state": "APPROVED", "commit_id": SHA}]))
        self.assertFalse(ok); self.assertIn("author", how)

    def test_label_must_be_applied_by_owner_not_agent(self):
        lab = "owner-approved-" + SHA[:12]
        ev = [{"actor": {"login": "chairman-second"}, "event": "labeled", "label": {"name": lab}},
              {"actor": {"login": "thedonnasystem"}, "event": "unlabeled", "label": {"name": lab}},
              {"actor": {"login": "thedonnasystem"}, "event": "labeled", "label": {"name": lab}}]
        self.assertFalse(C.approval(ACFG, "o/r", 5, SHA, self.fetch(events=ev, labels=[lab]))[0])
        self.assertTrue(C.approval(ACFG, "o/r", 5, SHA, self.fetch(events=ev[:1], labels=[lab]))[0])

    def test_label_method_can_be_switched_off(self):
        cfg = copy.deepcopy(ACFG); cfg["approval"]["methods"] = ["review"]
        lab = "owner-approved-" + SHA[:12]
        ev = [{"actor": {"login": "chairman-second"}, "event": "labeled", "label": {"name": lab}}]
        self.assertFalse(C.approval(cfg, "o/r", 5, SHA, self.fetch(events=ev, labels=[lab]))[0])

    def test_event_pages_beyond_the_limit_fail_closed(self):
        full = [{"event": "commented"}] * 100
        with self.assertRaises(C.TooMany):
            C._pages(lambda u: full, "https://api.github.com/x", max_pages=3)

    def test_push_approval(self):
        merged = {"number": 9, "merged_at": "x", "merge_commit_sha": SHA, "base": {"ref": "overnight-build"}, "head": {"sha": OLD}, "user": {"login": "thedonnasystem"}}

        def f(url):
            if url.endswith(f"/commits/{SHA}/pulls"):
                return [merged]
            if "/reviews" in url:
                return [{"user": {"login": "chairman-second"}, "state": "APPROVED", "commit_id": OLD}] if "page=1" in url else []
            return []
        self.assertTrue(C.push_approval(ACFG, "o/r", "overnight-build", "c" * 40, SHA, f, parent_of=lambda s: "c" * 40)[0])
        self.assertFalse(C.push_approval(ACFG, "o/r", "overnight-build", "d" * 40, SHA, f, parent_of=lambda s: "c" * 40)[0])   # extra commits rode along
        self.assertFalse(C.push_approval(ACFG, "o/r", "main", "c" * 40, SHA, f, parent_of=lambda s: "c" * 40)[0])             # PR merged elsewhere
        self.assertFalse(C.push_approval(CFG, "o/r", "overnight-build", "c" * 40, SHA, f, parent_of=lambda s: "c" * 40)[0])    # shipped config: fail closed


class BypassTests(unittest.TestCase):
    """B3: each bypass from the review (RVJC) is now a finding."""
    def setUp(self):
        self.r = Repo()

    def tearDown(self):
        self.r.close()

    def cats(self, f):
        return [c for c, _, _ in f]

    def test_package_shadowing_a_protected_module(self):
        self.r.write("hq_meter/__init__.py", "def reserve():\n    return 0\n")
        f = self.r.commit()
        self.assertTrue(any(p == "hq_meter/__init__.py" for _, p, _ in f), f)

    def test_new_top_level_module_and_sitecustomize(self):
        self.r.write("hq_helpers.py", "x = 1\n")
        self.r.write("sitecustomize.py", "x = 1\n")
        self.r.write("lib/usercustomize.py", "x = 1\n")
        self.r.write("lib/evil.pth", "import os\n")
        f = self.r.commit()
        paths = {p for _, p, _ in f}
        self.assertTrue({"hq_helpers.py", "sitecustomize.py", "lib/usercustomize.py", "lib/evil.pth"} <= paths, f)

    def test_monkey_patch_line_in_existing_module(self):
        self.r.write("hq_ideas_extra.py", "x = 1\nimport hq_meter\nhq_meter._reserve_cents = lambda *a: 1\nsetattr(hq_llm, 'eligible', None)\n")
        f = self.r.commit()
        self.assertGreaterEqual(sum(1 for c, _, w in f if c == "jarvis_permissions" and "patches" in w), 2, f)

    def test_deploy_configs_and_gitattributes(self):
        for p in ("railway.toml", "nixpacks.toml", "Dockerfile", "Procfile.web", ".gitattributes", "sub/.gitattributes", "sub/railway.json"):
            self.r.write(p, "x\n")
        f = self.r.commit()
        self.assertTrue({"railway.toml", "nixpacks.toml", "Dockerfile", "Procfile.web", ".gitattributes", "sub/.gitattributes", "sub/railway.json"} <= {p for _, p, _ in f}, f)

    def test_gitattributes_cannot_blind_the_line_scan(self):
        self.r.write(".gitattributes", "*.py -diff\n")
        self.r.write("tools/clean.py", "cur.execute('delete from public.audit_log')\n")
        f = self.r.commit()
        self.assertTrue(any(p == "tools/clean.py" and c == "destructive" for c, p, _ in f), f)

    def test_logic_files_and_tests_are_protected(self):
        for p in ("hq_core.py", "hq_channels.py", "test_hq_missions.py", "test_hq_voice.py"):
            self.assertIsNotNone(C.path_category(CFG, p), p)

    def test_double_plus_line(self):
        self.r.write("hq_ideas_extra.py", "x = 1\n++sb.table('system_state').update({'kill_switch': False})\n")
        f = self.r.commit()
        self.assertIn("kill_switch_and_mode", self.cats(f), f)

    def test_split_and_concatenated_statements(self):
        cases = {
            "a.py": 't = sb.table("system_" + "state")\nt.update({"kill_switch": False})\n',
            "b.py": 'q = "del" "ete from public." + "audit" + "_log"\n',
            "c.sql": "delete\nfrom\npublic.action_log;\n",
            "d.sql": "do $$ begin execute format('trun' || 'cate %I', 'audit_log'); end $$;\n",
            "e.sql": 'update U&"\\0073ystem_state" set kill_switch = false;\n',
            "f.py": 'sb.rpc("app_set_kill", {"p_on": False})\nsb.rpc("jarvis_set_config", {})\n',
        }
        for p, body in cases.items():
            self.r.write("tools/" + p, body)
        f = self.r.commit()
        hit = {p for _, p, _ in f}
        self.assertEqual({"tools/" + p for p in cases} - hit, set(), f)

    def test_unscanned_file_types(self):
        self.r.write("tools/cleanup.psql", "truncate audit_log;\n")
        self.r.write("tools/runme", "#!/bin/sh\npsql -c 'truncate audit_log'\n")
        self.r.write("tools/blob.bin", "x\n")
        self.r.write("docs/readme.md", "notes\n")
        f = self.r.commit()
        hit = {p for _, p, _ in f}
        self.assertTrue({"tools/cleanup.psql", "tools/runme", "tools/blob.bin"} <= hit, f)
        self.assertNotIn("docs/readme.md", hit)

    def test_zone_only_flags_everything_outside_the_zone(self):
        self.r.write("jarvis_skills/greet.py", "def run(p):\n    return {}\n")
        self.r.write("docs/a.md", "x\n")
        self.r.write("hq_ideas_extra.py", "x = 3\n")
        self.r.g("add", "-A"); self.r.g("commit", "-qm", "c")
        f = C.scan(CFG, "base", "HEAD", root=self.r.d, zone_only=True)
        self.assertEqual({p for c, p, _ in f if c == "self_edit_zone"}, {"hq_ideas_extra.py"}, f)


class ModeTests(unittest.TestCase):
    def test_default_mode_is_allowlist(self):
        self.assertEqual(C.self_edit_mode(CFG), "allowlist")
        cfg = copy.deepcopy(CFG); cfg["_root"] = tempfile.mkdtemp()
        self.assertEqual(C.self_edit_mode(cfg), "allowlist")          # missing file = the safer mode

    def test_selfedit_paths(self):
        bad = ["hq_meter.py#x", "hq_meter.py?x=1", "hq_meter%2Epy", "hq_meter/__init__.py", "sitecustomize.py", "railway.toml", ".gitattributes", "hq_core.py",
               "hq_channels.py", "test_hq_voice.py", "a/../hq_meter.py", "./x.py", "x\x01.py", "/abs.py", "new_top.py", "tools/runme"]
        for p in bad:
            self.assertTrue(C.path_findings(CFG, [p], selfedit=True, mode="denylist"), p)
        self.assertTrue(C.path_findings(CFG, ["hq_ideas.py"], selfedit=True, mode="allowlist"))
        self.assertFalse(C.path_findings(CFG, ["tools/ideas.py"], selfedit=True, mode="denylist"))
        self.assertTrue(C.path_findings(CFG, ["tools/ideas.py"], selfedit=True, mode="allowlist"))
        for ok in ("jarvis_skills/greet.py", "docs/notes.md", "prompts/brief.txt", "webapp/hq/view.js"):
            self.assertEqual(C.path_findings(CFG, [ok], selfedit=True, mode="allowlist"), [], ok)


if __name__ == "__main__":
    unittest.main()
