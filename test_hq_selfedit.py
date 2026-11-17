"""Self-edit pipeline: disabled by default; protected paths refused; independent reviewer; CI green; merge only into a jarvis/ branch; rollback."""
import unittest

import hq_selfedit as E

ON = {"JARVIS_SELFEDIT": "1", "JARVIS_GITHUB_TOKEN": "t", "GITHUB_REPO": "o/r"}


class FakeGH:
    def __init__(self, login="jarvis-bot", base="jarvis/integration", checks=None, files=None):
        self.calls, self.login, self.base = [], login, base
        self.checks = checks if checks is not None else [{"name": "unit", "status": "completed", "conclusion": "success"},
                                                          {"name": "migrations", "status": "completed", "conclusion": "success"}]
        self.files = files if files is not None else [{"filename": "automations/lead_followup.py", "status": "added"}]

    def __call__(self, method, url, body, accept):
        self.calls.append((method, url, body))
        if url.endswith("/user"):
            return {"login": self.login}
        if "/git/ref/heads/" in url:
            return {"object": {"sha": "b" * 40}}
        if "/contents/" in url and method == "GET":
            import urllib.error
            raise urllib.error.HTTPError(url, 404, "nf", {}, None)
        if url.endswith("/pulls") and method == "POST":
            return {"number": 7, "html_url": "https://example.invalid/pull/7"}
        if "/check-runs" in url:
            return {"check_runs": self.checks}
        if url.endswith("/pulls/7/files?per_page=100"):
            return self.files
        if url.endswith("/pulls/7") and accept.endswith("diff"):
            return "diff --git a/x b/x"
        if url.endswith("/pulls/7"):
            return {"base": {"ref": self.base}, "head": {"sha": "c" * 40}}
        return {}


def gh(fake):
    return E.GitHub("t", "o/r", opener=fake)


class SetupTests(unittest.TestCase):
    def test_disabled_by_default(self):
        with self.assertRaises(E.SelfEditRefused):
            E.setup(env={}, status=lambda: {"config": {"self_edit_enabled": True}})
        with self.assertRaises(E.SelfEditRefused):
            E.setup(env=ON, status=lambda: {"config": {"self_edit_enabled": False}})

    def test_owner_token_is_refused(self):
        with self.assertRaises(E.SelfEditRefused) as c:
            E.setup(env=ON, status=lambda: {"config": {"self_edit_enabled": True}}, opener=FakeGH(login="thedonnasystem"))
        self.assertIn("separate machine account", str(c.exception))
        self.assertIsNotNone(E.setup(env=ON, status=lambda: {"config": {"self_edit_enabled": True}}, opener=FakeGH()))

    def test_base_branch_rules(self):
        self.assertEqual(E.base_branch({}), "jarvis/integration")
        for b in ("overnight-build", "claude/telegram-claude-bot-59nusk", "main", "feature/x"):
            with self.assertRaises(E.SelfEditRefused):
                E.base_branch({"JARVIS_SELFEDIT_BASE": b})


class ScreenTests(unittest.TestCase):
    def test_protected_paths_and_lines_are_refused(self):
        for files in ([{"path": "hq_meter.py", "content": "x = 1\n"}], [{"path": "scripts/gate.sh", "content": "true\n"}],
                      [{"path": "migrations/x.sql", "content": "select 1;\n"}], [{"path": "ops/PROTECTED_PATHS.json", "content": "{}"}],
                      [{"path": "automations/a.py", "content": "cur.execute('update system_state set kill_switch=false')\n"}],
                      [{"path": "automations/b.py", "content": "cur.execute('delete from leads')\n"}],
                      [{"path": "automations/c.py", "content": "KEY='sk-ant-" + "a" * 30 + "'\n"}]):
            with self.assertRaises(E.SelfEditRefused, msg=files[0]["path"]):
                E.screen(files)
        self.assertEqual(len(E.screen([{"path": "automations/ok.py", "content": "def run(p):\n    return {}\n"}])), 1)

    def test_parse_files(self):
        t = "FILE: automations/a.py\ndef run(p):\n    return {}\nEND FILE\nFILE: automations/test_a.py\nimport unittest\nEND FILE"
        self.assertEqual([f["path"] for f in E.parse_files(t)], ["automations/a.py", "automations/test_a.py"])


class FlowTests(unittest.TestCase):
    def test_open_pr_targets_the_jarvis_branch(self):
        f = FakeGH()
        pr = E.open_pr(gh(f), "automate lead followup", "Because it repeats a lot and costs quota.", [{"path": "automations/a.py", "content": "x = 1\n"}],
                       {"provider": "groq", "model": "m1"}, env={})
        self.assertEqual(pr["base"], "jarvis/integration")
        post = [b for m, u, b in f.calls if u.endswith("/pulls") and m == "POST"][0]
        self.assertEqual(post["base"], "jarvis/integration")

    def test_reviewer_must_be_independent_and_approve(self):
        f = FakeGH()
        same = E.review(gh(f), {"number": 7}, {"provider": "groq", "model": "m1"}, complete=lambda s, m: {"text": "VERDICT: APPROVE", "provider": "groq", "model": "m1"})
        self.assertFalse(same["approved"]); self.assertIn("not independent", same["reason"])
        other = E.review(gh(f), {"number": 7}, {"provider": "groq", "model": "m1"}, complete=lambda s, m: {"text": "fine\nVERDICT: APPROVE", "provider": "openrouter", "model": "h"})
        self.assertTrue(other["approved"])
        rej = E.review(gh(f), {"number": 7}, {"provider": "groq", "model": "m1"}, complete=lambda s, m: {"text": "VERDICT: REJECT", "provider": "openrouter", "model": "h"})
        self.assertFalse(rej["approved"])

    def test_merge_only_when_everything_holds(self):
        log = []
        cl = lambda k, r, s: log.append((k, s))
        ok = {"approved": True, "reviewer": "openrouter/h"}
        f = FakeGH()
        self.assertTrue(E.maybe_merge(gh(f), {"number": 7}, ok, changelog=cl, env={})["merged"])
        merge = [b for m, u, b in f.calls if u.endswith("/merge")][0]
        self.assertEqual(merge["sha"], "c" * 40)                         # pinned to the reviewed head
        self.assertEqual(log[-1][0], "self_edit_merge")
        # not approved
        self.assertTrue(E.maybe_merge(gh(FakeGH()), {"number": 7}, {"approved": False}, changelog=cl, env={}).get("refused"))
        # CI not green: wait, no merge, no refusal
        r = E.maybe_merge(gh(FakeGH(checks=[{"name": "unit", "status": "in_progress"}])), {"number": 7}, ok, changelog=cl, env={})
        self.assertFalse(r["merged"]); self.assertNotIn("refused", r)
        # wrong base
        self.assertTrue(E.maybe_merge(gh(FakeGH(base="overnight-build")), {"number": 7}, ok, changelog=cl, env={}).get("refused"))
        # a protected file slipped into the PR (e.g. pushed by hand), or a rename out of a protected path
        self.assertTrue(E.maybe_merge(gh(FakeGH(files=[{"filename": "hq_capital.py", "status": "modified"}])), {"number": 7}, ok, changelog=cl, env={}).get("refused"))
        self.assertTrue(E.maybe_merge(gh(FakeGH(files=[{"filename": "free.py", "previous_filename": "hq_meter.py", "status": "renamed"}])), {"number": 7}, ok, changelog=cl, env={}).get("refused"))
        merges = [c for c in log if c[0] == "self_edit_merge"]
        self.assertEqual(len(merges), 1)

    def test_rollback_on_failed_health(self):
        log, reverted = [], []
        r = E.post_deploy_check(lambda: False, reverted.append, "d" * 40, attempts=3, sleep=lambda s: None, changelog=lambda k, ref, s: log.append(k))
        self.assertEqual(reverted, ["d" * 40]); self.assertFalse(r["healthy"]); self.assertEqual(log, ["rollback"])
        log.clear()
        self.assertTrue(E.post_deploy_check(lambda: True, reverted.append, "d" * 40, sleep=lambda s: None, changelog=lambda k, ref, s: log.append(k))["healthy"])

    def test_automation_never_for_protected_classes(self):
        for cls in ("money.transfer", "consent.capture", "backup.run", "kill.switch"):
            with self.assertRaises(E.SelfEditRefused):
                E.draft_automation({"task_class": cls}, gh=gh(FakeGH()), complete=lambda s, m: self.fail("model called"))
        url = E.draft_automation({"task_class": "lead.followup", "runs": 40, "cost_cents": 0}, gh=gh(FakeGH()),
                                 complete=lambda s, m: {"text": "FILE: automations/lead_followup.py\ndef run(p):\n    return {}\nEND FILE", "provider": "groq", "model": "m"})
        self.assertEqual(url, "https://example.invalid/pull/7")


if __name__ == "__main__":
    unittest.main()
