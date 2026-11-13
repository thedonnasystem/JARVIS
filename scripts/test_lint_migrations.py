"""Tests for scripts/lint_migrations.py. Run: python3 -m unittest discover -s scripts -p 'test_*.py'
Each rule has a positive case and a negative case proving it can fail."""
import contextlib
import io
import os
import shutil
import subprocess
import sys
import tempfile
import unittest

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import lint_migrations as L  # noqa: E402

LOCK = "do $$ begin perform 1; end $$;\n-- keep open\nselect proname from pg_proc where proname not in ('app_snapshot','app_send');\n"
GOOD_FN = ("create or replace function public.foo_bar(p_by text, n int default 1) returns int language sql security definer as $$ select 1 $$;\n"
           "revoke all on function public.foo_bar(text, int) from public, anon, authenticated;\n"
           "grant execute on function public.foo_bar(text, int) to service_role;\n")


class Repo:
    """Throwaway migrations/ tree (optionally a git repo)."""

    def __init__(self, files, order):
        self.root = tempfile.mkdtemp(prefix="lintm_")
        os.makedirs(os.path.join(self.root, "migrations"))
        for n, c in files.items():
            self.write(n, c)
        self.set_order(order)

    def write(self, name, content):
        with open(os.path.join(self.root, "migrations", name), "w") as f:
            f.write(content)

    def set_order(self, order):
        with open(os.path.join(self.root, "migrations", "APPLY_ORDER.txt"), "w") as f:
            f.write("# comment\n" + "\n".join(order) + "\n")

    def git(self, *a):
        subprocess.run(["git", "-C", self.root, "-c", "user.email=t@t", "-c", "user.name=t", *a], check=True, capture_output=True)

    def cleanup(self):
        shutil.rmtree(self.root, ignore_errors=True)


def run(repo, **kw):
    kw.setdefault("grandfathered", frozenset({"20261112_lockdown_v1.sql", "20261112_old_v1.sql"}))
    kw.setdefault("not_in_order", frozenset())
    kw.setdefault("check_git", False)
    return L.lint(repo.root, **kw)[0]


def base_repo(extra_files=None, extra_order=()):
    files = {"20261112_lockdown_v1.sql": LOCK, "20261112_old_v1.sql": "select 1;\n"}
    files.update(extra_files or {})
    return Repo(files, ["20261112_old_v1.sql", *extra_order, "20261112_lockdown_v1.sql"])


class Rules(unittest.TestCase):
    def tearDown(self):
        for r in getattr(self, "repos", []):
            r.cleanup()

    def mk(self, *a, **k):
        r = base_repo(*a, **k)
        self.repos = getattr(self, "repos", []) + [r]
        return r

    def has(self, errs, rule):
        return any(e.startswith(rule + " ") for e in errs)

    # baseline
    def test_clean_repo_passes(self):
        r = self.mk({"20261114_infra_gate_v1.sql": GOOD_FN}, ["20261114_infra_gate_v1.sql"])
        self.assertEqual(run(r), [])

    def test_real_repo_is_clean(self):
        errs, _ = L.lint(L.ROOT, check_git=False)
        self.assertEqual(errs, [])

    # R1
    def test_r1_file_not_in_order_fails(self):
        r = self.mk({"20261114_infra_gate_v1.sql": "select 1;\n"}, [])
        self.assertTrue(self.has(run(r), "R1"))

    def test_r1_order_entry_without_file_fails(self):
        r = self.mk({}, ["20261114_infra_ghost_v1.sql"])
        self.assertTrue(self.has(run(r), "R1"))

    def test_r1_duplicate_entry_fails(self):
        r = self.mk({"20261114_infra_gate_v1.sql": "select 1;\n"}, ["20261114_infra_gate_v1.sql", "20261114_infra_gate_v1.sql"])
        self.assertTrue(any("more than once" in e for e in run(r)))

    def test_r1_documented_exception_allowed_but_not_if_listed(self):
        r = self.mk({"20261112_live_v1.sql": "select 1;\n"}, [])
        self.assertEqual(run(r, grandfathered=frozenset({"20261112_lockdown_v1.sql", "20261112_old_v1.sql", "20261112_live_v1.sql"}),
                             not_in_order=frozenset({"20261112_live_v1.sql"})), [])
        r.set_order(["20261112_old_v1.sql", "20261112_live_v1.sql", "20261112_lockdown_v1.sql"])
        self.assertTrue(self.has(run(r, grandfathered=frozenset({"20261112_lockdown_v1.sql", "20261112_old_v1.sql", "20261112_live_v1.sql"}),
                                     not_in_order=frozenset({"20261112_live_v1.sql"})), "R1"))

    # R2
    def test_r2_bad_names_fail(self):
        for bad in ["20261114_gate.sql", "20261114_infra_gate.sql", "20261114_Infra_gate_v1.sql", "gate_v1.sql", "20261114_infra_v1.sql"]:
            r = self.mk({bad: "select 1;\n"}, [bad])
            self.assertTrue(self.has(run(r), "R2"), bad)

    def test_r2_grandfathered_name_ok_new_name_ok(self):
        r = self.mk({"20261114_infra_gate_v2.sql": "select 1;\n"}, ["20261114_infra_gate_v2.sql"])
        self.assertFalse(self.has(run(r), "R2"))

    # R3
    def test_r3_lockdown_not_last_fails(self):
        r = self.mk({"20261114_infra_gate_v1.sql": "select 1;\n"}, [])
        r.set_order(["20261112_old_v1.sql", "20261112_lockdown_v1.sql", "20261114_infra_gate_v1.sql"])
        self.assertTrue(self.has(run(r), "R3"))

    def test_r3_lockdown_missing_fails(self):
        r = self.mk()
        r.set_order(["20261112_old_v1.sql"])
        self.assertTrue(self.has(run(r), "R3"))

    # R4
    def test_r4_missing_revoke_fails(self):
        r = self.mk({"20261114_infra_gate_v1.sql": "create function public.foo_bar() returns int language sql as $$ select 1 $$;\n"},
                    ["20261114_infra_gate_v1.sql"])
        self.assertTrue(self.has(run(r), "R4"))

    def test_r4_revoke_before_create_fails(self):
        sql = "revoke all on function public.foo_bar() from public, anon, authenticated;\ncreate function public.foo_bar() returns int language sql as $$ select 1 $$;\n"
        r = self.mk({"20261114_infra_gate_v1.sql": sql}, ["20261114_infra_gate_v1.sql"])
        self.assertTrue(self.has(run(r), "R4"))

    def test_r4_partial_roles_fails(self):
        sql = "create function public.foo_bar() returns int language sql as $$ select 1 $$;\nrevoke all on function public.foo_bar() from public;\n"
        r = self.mk({"20261114_infra_gate_v1.sql": sql}, ["20261114_infra_gate_v1.sql"])
        self.assertTrue(self.has(run(r), "R4"))

    def test_r4_wrong_function_or_arity_fails(self):
        sql = ("create function public.foo_bar(a int) returns int language sql as $$ select 1 $$;\n"
               "revoke all on function public.foo_bar(int, int) from public, anon, authenticated;\n"
               "revoke all on function public.other() from public, anon, authenticated;\n")
        r = self.mk({"20261114_infra_gate_v1.sql": sql}, ["20261114_infra_gate_v1.sql"])
        self.assertTrue(self.has(run(r), "R4"))

    def test_r4_second_overload_unrevoked_fails(self):
        sql = ("create function public.f(a int) returns int language sql as $$ select 1 $$;\n"
               "create function public.f(a int, b int) returns int language sql as $$ select 1 $$;\n"
               "revoke all on function public.f(int) from public, anon, authenticated;\n")
        r = self.mk({"20261114_infra_gate_v1.sql": sql}, ["20261114_infra_gate_v1.sql"])
        errs = run(r)
        self.assertEqual(sum(e.startswith("R4") for e in errs), 1, errs)

    def test_r4_comment_or_body_mentions_are_not_functions_or_revokes(self):
        sql = ("-- create function public.ghost() fake\n"
               "create function public.real_fn() returns text language sql as $$ select 'create function public.inner() ' $$;\n"
               "-- revoke all on function public.real_fn() from public, anon, authenticated;\n")
        r = self.mk({"20261114_infra_gate_v1.sql": sql}, ["20261114_infra_gate_v1.sql"])
        errs = run(r)
        self.assertEqual([e for e in errs if e.startswith("R4")], [e for e in errs if "real_fn" in e])
        self.assertEqual(len([e for e in errs if e.startswith("R4")]), 1, errs)

    def test_r4_variants_pass(self):
        ok = [
            "create function f() returns int language sql as $$ select 1 $$;\nrevoke execute on function f() from public, anon, authenticated;\n",
            "create or replace function public.\"F\"(a int, OUT b int) language sql as $$ select 1 $$;\nREVOKE ALL ON FUNCTION public.\"F\"(int) FROM PUBLIC, ANON, AUTHENTICATED, extra;\n",
            "create function f() returns int language sql as $$ select 1 $$;\nrevoke all on all functions in schema public from public, anon, authenticated;\n",
            "create function f() returns int language sql as $$ select 1 $$;\nrevoke all on function f from public, anon, authenticated;\n",
        ]
        for i, sql in enumerate(ok):
            r = self.mk({"20261114_infra_gate_v1.sql": sql}, ["20261114_infra_gate_v1.sql"])
            self.assertEqual(run(r), [], sql)

    def test_r4_applies_to_grandfathered_file_ordered_after_lockdown(self):
        r = self.mk()
        r.write("20261112_old_v1.sql", "create function g() returns int language sql as $$ select 1 $$;\n")
        r.set_order(["20261112_lockdown_v1.sql", "20261112_old_v1.sql"])
        errs = run(r)
        self.assertTrue(self.has(errs, "R4") and self.has(errs, "R3"))

    def test_r4_grandfathered_before_lockdown_not_checked(self):
        r = self.mk()
        r.write("20261112_old_v1.sql", "create function g() returns int language sql as $$ select 1 $$;\n")
        self.assertEqual(run(r), [])

    def test_r4_keep_open_function_may_grant_instead(self):
        sql = "create function public.app_send(t text) returns int language sql as $$ select 1 $$;\ngrant execute on function public.app_send(text) to authenticated;\n"
        r = self.mk({"20261114_infra_gate_v1.sql": sql}, ["20261114_infra_gate_v1.sql"])
        self.assertEqual(run(r), [])

    # R5
    def test_r5_grant_to_anon_outside_keep_open_fails(self):
        sql = GOOD_FN + "grant execute on function public.foo_bar(text, int) to anon;\n"
        r = self.mk({"20261114_infra_gate_v1.sql": sql}, ["20261114_infra_gate_v1.sql"])
        self.assertTrue(self.has(run(r), "R5"))

    def test_r5_grant_all_functions_to_authenticated_fails(self):
        r = self.mk({"20261114_infra_gate_v1.sql": "grant all on all functions in schema public to authenticated;\n"}, ["20261114_infra_gate_v1.sql"])
        self.assertTrue(self.has(run(r), "R5"))

    def test_r5_grant_service_role_is_fine(self):
        self.assertEqual(L.check_revokes("x", "grant execute on function foo() to service_role;", set()), [])

    # parser units
    def test_strip_sql_keeps_offsets(self):
        s = "a -- c\n/* x\ny */ 'it''s' $t$ body $t$ b"
        out = L.strip_sql(s)
        self.assertEqual(len(out), len(s))
        self.assertNotIn("body", out)
        self.assertNotIn("it", out.replace("'", ""))
        self.assertTrue(out.rstrip().endswith("b"))

    def test_keep_open_names_parsed_from_real_lockdown(self):
        with open(os.path.join(L.ROOT, "migrations", L.LOCKDOWN)) as f:
            names = L.keep_open_names(f.read())
        self.assertIn("app_snapshot", names)
        self.assertIn("setter_apply", names)
        self.assertEqual(len(names), 13)


class R6Git(unittest.TestCase):
    def setUp(self):
        self.r = base_repo({"20261114_infra_gate_v1.sql": GOOD_FN}, ["20261114_infra_gate_v1.sql"])
        self.r.git("init", "-q", "-b", "main")
        self.r.git("add", "-A")
        self.r.git("commit", "-q", "-m", "base")
        self.r.git("branch", "basebranch")
        self.r.git("checkout", "-q", "-b", "feature")

    def tearDown(self):
        self.r.cleanup()

    def lint(self, allow=None):
        return L.lint(self.r.root, base="basebranch", grandfathered=frozenset({"20261112_lockdown_v1.sql", "20261112_old_v1.sql"}),
                      not_in_order=frozenset(), allowlist=allow)

    def test_unmodified_passes(self):
        errs, notes = self.lint()
        self.assertEqual((errs, notes), ([], []))

    def test_adding_new_file_is_allowed(self):
        self.r.write("20261115_infra_more_v1.sql", "select 1;\n")
        self.r.set_order(["20261112_old_v1.sql", "20261114_infra_gate_v1.sql", "20261115_infra_more_v1.sql", "20261112_lockdown_v1.sql"])
        self.assertEqual(self.lint()[0], [])

    def test_committed_edit_of_applied_migration_fails(self):
        self.r.write("20261114_infra_gate_v1.sql", GOOD_FN + "-- tweak\n")
        self.r.git("commit", "-qam", "edit")
        errs, _ = self.lint()
        self.assertTrue(any(e.startswith("R6") and "modified" in e for e in errs), errs)

    def test_uncommitted_edit_fails(self):
        self.r.write("20261112_old_v1.sql", "select 2;\n")
        self.assertTrue(any(e.startswith("R6") for e in self.lint()[0]))

    def test_delete_fails(self):
        os.remove(os.path.join(self.r.root, "migrations", "20261112_old_v1.sql"))
        self.r.set_order(["20261114_infra_gate_v1.sql", "20261112_lockdown_v1.sql"])
        self.assertTrue(any(e.startswith("R6") and "deleted" in e for e in self.lint()[0]))

    def test_rename_fails(self):
        self.r.git("mv", "migrations/20261114_infra_gate_v1.sql", "migrations/20261114_infra_renamed_v1.sql")
        self.r.set_order(["20261112_old_v1.sql", "20261114_infra_renamed_v1.sql", "20261112_lockdown_v1.sql"])
        self.assertTrue(any(e.startswith("R6") and "renamed" in e for e in self.lint()[0]))

    def test_allowlist_permits_edit(self):
        self.r.write("20261112_old_v1.sql", "select 2;\n")
        self.assertEqual(self.lint(allow={"20261112_old_v1.sql": "owner-approved typo fix"})[0], [])

    def test_unreachable_base_is_a_visible_note_not_silent(self):
        errs, notes = L.lint(self.r.root, base="origin/nope", grandfathered=frozenset({"20261112_lockdown_v1.sql", "20261112_old_v1.sql"}), not_in_order=frozenset())
        self.assertEqual(errs, [])
        self.assertTrue(notes and "R6 skipped" in notes[0])


class Cli(unittest.TestCase):
    def test_exit_codes(self):
        r = base_repo({"bad.sql": "select 1;\n"}, [])
        try:
            with contextlib.redirect_stdout(io.StringIO()):
                self.assertEqual(L.main(["--root", r.root, "--no-git"]), 1)
                self.assertEqual(L.main(["--no-git"]), 0)
        finally:
            r.cleanup()


if __name__ == "__main__":
    unittest.main()
