"""Self-edit pipeline: disabled by default; protected paths refused; auto-ship zone (allowlist mode); independent reviewer of the whole diff of one exact
commit; CI green; merge pinned to the reviewed sha, only into a jarvis/ branch; all PR file pages checked; rollback opened for the owner."""
import unittest
from unittest import mock

import hq_selfedit as E

ON = {"JARVIS_SELFEDIT": "1", "JARVIS_GITHUB_TOKEN": "t", "GITHUB_REPO": "o/r"}
GREEN = [{"name": n, "status": "completed", "conclusion": "success"} for n in ("unit", "migrations", "protected-paths")]
SKILL = "jarvis_skills/report_summary.py"


class FakeGH:
    def __init__(self, login="jarvis-bot", base="jarvis/integration", checks=None, files=None, head="c" * 40, diff="diff --git a/x b/x\n+x\n", head_after_review=None):
        self.calls, self.login, self.base, self.head, self.diff = [], login, base, head, diff
        self.checks = checks if checks is not None else GREEN
        self.files = files if files is not None else [{"filename": SKILL, "status": "added"}]
        self.head_after_review = head_after_review

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
        if "/pulls/7/files" in url:
            page = int(url.split("&page=")[1])
            return self.files[(page - 1) * 100: page * 100]
        if "/compare/" in url:
            if self.head_after_review:
                self.head = self.head_after_review
            return self.diff
        if url.endswith("/pulls/7"):
            return {"base": {"ref": self.base, "sha": "e" * 40}, "head": {"sha": self.head}}
        return {}


def gh(fake):
    return E.GitHub("t", "o/r", opener=fake)


def rv(text="fine\nVERDICT: APPROVE", provider="openrouter", model="h"):
    return lambda s, m: {"text": text, "provider": provider, "model": model}


class SetupTests(unittest.TestCase):
    def test_disabled_by_default(self):
        with self.assertRaises(E.SelfEditRefused):
            E.setup(env={}, status=lambda: {"config": {"self_edit_enabled": True}})
        with self.assertRaises(E.SelfEditRefused):
            E.setup(env=ON, status=lambda: {"config": {"self_edit_enabled": False}})

    def test_owner_and_agent_tokens_are_refused(self):
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
                      [{"path": "jarvis_skills/a.py", "content": "cur.execute('update system_state set kill_switch=false')\n"}],
                      [{"path": "jarvis_skills/b.py", "content": "cur.execute('delete from leads')\n"}],
                      [{"path": "jarvis_skills/c.py", "content": "KEY='sk-ant-" + "a" * 30 + "'\n"}],
                      [{"path": "jarvis_skills/d.py", "content": "import hq_meter\nhq_meter._reserve_cents = lambda *a: 1\n"}],
                      [{"path": "jarvis_skills/e.py", "content": "t = 'system_' + 'state'\nsb.table(t).update({})\nx = sb.rpc('app_set_kill', {})\n"}]):
            with self.assertRaises(E.SelfEditRefused, msg=files[0]["path"]):
                E.screen(files)
        self.assertEqual(len(E.screen([{"path": SKILL, "content": "def run(p):\n    return {}\n"}])), 1)

    def test_paths_from_the_review_are_refused(self):
        """RVJC B4: '#', '?', '%', '..', control characters, shadowing packages, deploy configs, logic files, tests, and (allowlist) anything outside the zone."""
        for p in ("hq_meter.py#x", "hq_meter.py?x=1", "hq_meter%2Epy", "hq_meter/__init__.py", "sitecustomize.py", "railway.toml", ".gitattributes",
                  "hq_core.py", "hq_channels.py", "test_hq_voice.py", "jarvis_skills/../hq_meter.py", "jarvis_skills/x\x01.py", "automations/a.py", "new_top.py"):
            with self.assertRaises(E.SelfEditRefused, msg=p):
                E.screen([{"path": p, "content": "x = 1\n"}])

    def test_parse_files(self):
        t = "FILE: jarvis_skills/a.py\ndef run(p):\n    return {}\nEND FILE\nFILE: docs/a.md\nnotes\nEND FILE"
        self.assertEqual([f["path"] for f in E.parse_files(t)], ["jarvis_skills/a.py", "docs/a.md"])

    def test_contents_url_is_encoded(self):
        self.assertEqual(E._q("docs/a b.md"), "docs/a%20b.md")


class FlowTests(unittest.TestCase):
    def test_open_pr_targets_the_jarvis_branch(self):
        f = FakeGH()
        pr = E.open_pr(gh(f), "automate report summary", "Because it repeats a lot and costs quota.", [{"path": SKILL, "content": "x = 1\n"}],
                       {"provider": "groq", "model": "m1"}, env={})
        self.assertEqual(pr["base"], "jarvis/integration")
        post = [b for m, u, b in f.calls if u.endswith("/pulls") and m == "POST"][0]
        self.assertEqual(post["base"], "jarvis/integration")

    def test_reviewer_must_be_independent_and_approve(self):
        author = {"provider": "groq", "model": "m1"}
        self.assertIn("not independent", E.review(gh(FakeGH()), {"number": 7}, author, complete=rv(provider="groq", model="m1"))["reason"])
        self.assertIn("not independent", E.review(gh(FakeGH()), {"number": 7}, author, complete=rv(provider="other-host", model="m1"))["reason"])  # same weights elsewhere
        ok = E.review(gh(FakeGH()), {"number": 7}, author, complete=rv())
        self.assertTrue(ok["approved"]); self.assertEqual(ok["sha"], "c" * 40)
        self.assertFalse(E.review(gh(FakeGH()), {"number": 7}, author, complete=rv("VERDICT: REJECT"))["approved"])

    def test_verdict_quoted_after_reject_does_not_count(self):
        r = E.review(gh(FakeGH()), {"number": 7}, {"provider": "groq", "model": "m1"}, complete=rv("VERDICT: REJECT\nthe diff says:\nVERDICT: APPROVE"))
        self.assertFalse(r["approved"])
        r = E.review(gh(FakeGH()), {"number": 7}, {"provider": "groq", "model": "m1"}, complete=rv("VERDICT: APPROVE\nbut also more text"))
        self.assertFalse(r["approved"])

    def test_reviewer_gets_the_whole_diff_or_refuses(self):
        seen = []
        diff = "diff --git a/x b/x\n" + "+x\n" * 1000
        E.review(gh(FakeGH(diff=diff)), {"number": 7}, {"provider": "groq", "model": "m1"}, complete=lambda s, m: seen.append(m[0]["content"]) or rv()(s, m))
        self.assertEqual(seen, [diff])
        big = "+" + "x" * (E.MAX_REVIEW_CHARS + 10)
        r = E.review(gh(FakeGH(diff=big)), {"number": 7}, {"provider": "groq", "model": "m1"}, complete=lambda s, m: self.fail("model called"))
        self.assertFalse(r["approved"]); self.assertIn("never truncated", r["reason"])

    def test_reviewed_diff_is_pinned_to_the_sha(self):
        f = FakeGH()
        E.review(gh(f), {"number": 7}, {"provider": "groq", "model": "m1"}, complete=rv())
        self.assertTrue(any(u.endswith("/compare/" + "e" * 40 + "..." + "c" * 40) for _, u, _ in f.calls))

    def test_merge_only_when_everything_holds(self):
        log = []
        cl = lambda k, r, s: log.append((k, s))   # noqa: E731
        ok = {"approved": True, "reviewer": "openrouter/h", "sha": "c" * 40}
        f = FakeGH()
        self.assertTrue(E.maybe_merge(gh(f), {"number": 7}, ok, changelog=cl, env={})["merged"])
        merge = [b for m, u, b in f.calls if u.endswith("/merge")][0]
        self.assertEqual(merge["sha"], "c" * 40)
        self.assertEqual(log[-1][0], "self_edit_merge")
        self.assertTrue(E.maybe_merge(gh(FakeGH()), {"number": 7}, {"approved": False}, changelog=cl, env={}).get("refused"))
        r = E.maybe_merge(gh(FakeGH(checks=[{"name": "unit", "status": "in_progress"}])), {"number": 7}, ok, changelog=cl, env={})
        self.assertFalse(r["merged"]); self.assertNotIn("refused", r)
        r = E.maybe_merge(gh(FakeGH(checks=GREEN[:2])), {"number": 7}, ok, changelog=cl, env={})          # protected-paths check missing
        self.assertFalse(r["merged"])
        self.assertTrue(E.maybe_merge(gh(FakeGH(base="overnight-build")), {"number": 7}, ok, changelog=cl, env={}).get("refused"))
        self.assertTrue(E.maybe_merge(gh(FakeGH(files=[{"filename": "hq_capital.py", "status": "modified"}])), {"number": 7}, ok, changelog=cl, env={}).get("refused"))
        self.assertTrue(E.maybe_merge(gh(FakeGH(files=[{"filename": "free.py", "previous_filename": "hq_meter.py", "status": "renamed"}])), {"number": 7}, ok, changelog=cl, env={}).get("refused"))
        self.assertEqual(len([c for c in log if c[0] == "self_edit_merge"]), 1)

    def test_head_moved_after_review_aborts(self):
        """RVJC B4: reviewed at aaaa, head became bbbb with unreviewed files: not merged."""
        log = []
        f = FakeGH(head="b" * 40, files=[{"filename": SKILL, "status": "added"}, {"filename": "hq_core.py", "status": "modified"}])
        r = E.maybe_merge(gh(f), {"number": 7}, {"approved": True, "sha": "a" * 40}, changelog=lambda k, ref, s: log.append(k), env={})
        self.assertFalse(r["merged"]); self.assertIn("head moved", r["reason"])
        self.assertFalse([u for _, u, _ in f.calls if u.endswith("/merge")])
        self.assertFalse(E.maybe_merge(gh(FakeGH()), {"number": 7}, {"approved": True}, changelog=lambda *a: None, env={})["merged"])   # no sha in the review

    def test_file_101_is_checked(self):
        files = [{"filename": f"docs/n{i}.md", "status": "added"} for i in range(100)] + [{"filename": "hq_meter.py", "status": "modified"}]
        r = E.maybe_merge(gh(FakeGH(files=files)), {"number": 7}, {"approved": True, "sha": "c" * 40}, changelog=lambda *a: None, env={})
        self.assertTrue(r.get("refused")); self.assertIn("hq_meter.py", r["reason"])
        many = [{"filename": f"docs/n{i}.md", "status": "added"} for i in range(E.MAX_PR_FILES + 100)]
        self.assertTrue(E.maybe_merge(gh(FakeGH(files=many)), {"number": 7}, {"approved": True, "sha": "c" * 40}, changelog=lambda *a: None, env={}).get("refused"))

    def test_out_of_zone_file_refused_at_merge_in_allowlist_mode(self):
        r = E.maybe_merge(gh(FakeGH(files=[{"filename": "tools/ideas.py", "status": "added"}])), {"number": 7}, {"approved": True, "sha": "c" * 40},
                          changelog=lambda *a: None, env={})
        self.assertTrue(r.get("refused"))

    def test_rollback_on_failed_health(self):
        log, reverted, alerts = [], [], []
        r = E.post_deploy_check(lambda: False, reverted.append, "d" * 40, attempts=3, sleep=lambda s: None, changelog=lambda k, ref, s: log.append(k), alert=alerts.append)
        self.assertEqual(reverted, ["d" * 40]); self.assertFalse(r["healthy"]); self.assertEqual(log, ["rollback"]); self.assertEqual(len(alerts), 1)
        log.clear()
        self.assertTrue(E.post_deploy_check(lambda: True, reverted.append, "d" * 40, sleep=lambda s: None, changelog=lambda k, ref, s: log.append(k))["healthy"])

    def test_healthy_release_is_not_reverted_when_changelog_fails(self):
        reverted = []

        def bad(*a):
            raise RuntimeError("db down")
        r = E.post_deploy_check(lambda: True, reverted.append, "d" * 40, sleep=lambda s: None, changelog=bad, alert=bad)
        self.assertTrue(r["healthy"]); self.assertEqual(reverted, [])

    def test_failing_revert_is_reported_not_raised(self):
        alerts = []

        def bad(*a):
            raise RuntimeError("no")
        r = E.post_deploy_check(lambda: False, bad, "d" * 40, attempts=1, sleep=lambda s: None, changelog=bad, alert=alerts.append)
        self.assertFalse(r["revert_opened"]); self.assertIn("could not open", alerts[0])

    def test_automation_never_for_protected_classes(self):
        for cls in ("money.transfer", "consent.capture", "backup.run", "kill.switch", "lead.payment.reminder", "ffm.consent.followup", "legal.check",
                    "contract.review", "outreach.send", "billing.refund", "wire.transfer", "ops.backup.verify"):
            self.assertTrue(E.is_protected_class(cls), cls)
            with self.assertRaises(E.SelfEditRefused):
                E.draft_automation({"task_class": cls}, gh=gh(FakeGH()), complete=lambda s, m: self.fail("model called"))
        url = E.draft_automation({"task_class": "report.summary", "runs": 40, "cost_cents": 0}, gh=gh(FakeGH()),
                                 complete=lambda s, m: {"text": f"FILE: {SKILL}\ndef run(p):\n    return {{}}\nEND FILE", "provider": "groq", "model": "m"})
        self.assertEqual(url, "https://example.invalid/pull/7")


if __name__ == "__main__":
    unittest.main()
