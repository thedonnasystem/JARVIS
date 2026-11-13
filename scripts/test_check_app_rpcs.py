import os
import shutil
import sys
import tempfile
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import check_app_rpcs as K  # noqa: E402

REAL = K.ROOT


def rd(rel):
    return K._read(REAL, rel)


class Copy(unittest.TestCase):
    """Each test mutates a private copy of the files the checker reads and expects the checker to name the drift."""

    def setUp(self):
        self.root = tempfile.mkdtemp(prefix="appcheck.")
        for d in ("webapp", "migrations", "ops"):
            shutil.copytree(os.path.join(REAL, d), os.path.join(self.root, d), ignore=shutil.ignore_patterns("node_modules", "*.png"))
        # png bytes are never read by the checker, only their existence is: recreate as empty files
        for d, _s, fs in os.walk(os.path.join(REAL, "webapp")):
            for f in fs:
                if f.endswith(".png"):
                    rel = os.path.relpath(os.path.join(d, f), REAL)
                    with open(os.path.join(self.root, rel), "w"):
                        pass
        os.makedirs(os.path.join(self.root, "scripts", "replica"))
        shutil.copy(os.path.join(REAL, "scripts", "replica", "e2e.sql"), os.path.join(self.root, "scripts", "replica", "e2e.sql"))
        shutil.copy(os.path.join(REAL, "hq_web.py"), self.root)

    def tearDown(self):
        shutil.rmtree(self.root, ignore_errors=True)

    def edit(self, rel, old, new, count=None):
        p = os.path.join(self.root, rel)
        with open(p) as f:
            s = f.read()
        self.assertIn(old, s, f"test setup: {old!r} not in {rel}")
        with open(p, "w") as f:
            f.write(s.replace(old, new) if count is None else s.replace(old, new, count))

    def errs(self):
        return K.check(self.root)

    def codes(self):
        return {e.split()[0] for e in self.errs()}

    def has(self, code, text=""):
        return any(e.startswith(code) and text in e for e in self.errs())


class RealRepo(unittest.TestCase):
    def test_the_repo_has_no_drift(self):
        self.assertEqual(K.check(REAL), [])

    def test_it_really_parses_what_it_claims(self):
        js = rd("webapp/app.js")
        self.assertTrue({"app_snapshot", "app_send", "app_messages", "app_set_kill", "app_office"} <= K.js_rpc_names(js))
        self.assertTrue({"decision", "answer", "mission", "bank", "draft"} <= K.app_kinds(js))
        self.assertGreaterEqual(len(K.shell_list(rd("webapp/sw.js"))), 7)
        self.assertTrue({"chat", "decision", "answer", "mission", "bank", "venture", "payment", "lead", "idea", "draft", "day"} <= K.hq_web_kinds(rd("hq_web.py")))


class Mutations(Copy):
    def test_copy_is_clean_before_any_mutation(self):
        self.assertEqual(self.errs(), [])

    def test_app_calls_a_function_nobody_defined_or_opened(self):
        self.edit("webapp/app.js", "rpc('app_office')", "rpc('app_ghost')")
        self.assertTrue(self.has("A1", "app_ghost"))
        self.assertTrue(self.has("A2", "app_ghost"))

    def test_app_calls_a_defined_but_closed_function(self):
        self.edit("webapp/app.js", "rpc('app_office')", "rpc('app_snapshot_data')")
        self.assertTrue(self.has("A1", "app_snapshot_data"))

    def test_name_missing_from_one_pasted_copy(self):
        self.edit("ops/verify_live.sql", "'app_office',", "", count=1)
        self.assertTrue(self.has("A7", "ops/verify_live.sql"))
        self.assertIn("app_office", [e for e in self.errs() if "verify_live" in e][0])

    def test_extra_name_in_replica_copy(self):
        self.edit("scripts/replica/e2e.sql", "'app_snapshot',", "'app_snapshot','app_extra',", count=1)
        self.assertTrue(self.has("A7", "app_extra"))

    def test_name_missing_from_lockdown(self):
        self.edit("migrations/20261112_lockdown_v1.sql", "'app_payments',", "")
        self.assertTrue(self.has("A1", "app_payments"))
        self.assertTrue(self.has("A5", "app_payments"))
        self.assertTrue(self.has("A7"))

    def test_migration_grants_a_function_the_lockdown_would_revoke(self):
        with open(os.path.join(self.root, "migrations", "20261115_inbox_needs_you_v1.sql"), "a") as f:
            f.write("\ncreate or replace function public.app_sneaky() returns int language sql as $$ select 1 $$;\n"
                    "revoke all on function public.app_sneaky() from public, anon;\ngrant execute on function public.app_sneaky() to authenticated;\n")
        self.assertTrue(self.has("A5", "app_sneaky"))

    def test_open_function_nobody_calls(self):
        self.edit("webapp/app.js", "rpc('app_push_public_key')", "rpc('app_messages')")
        self.edit("webapp/app.js", "rpc('app_save_push'", "rpc('app_messages'")
        self.assertTrue(self.has("A6", "app_push_public_key"))

    def test_pending_signoff_must_stay_closed_and_documented(self):
        self.edit("migrations/20261112_lockdown_v1.sql", "'app_payments',", "'app_payments','app_needs_you',")
        self.assertTrue(self.has("A3", "now"))                       # stale pending entry
        os.remove(os.path.join(self.root, "ops/pending_signoff/inbox_open_app_needs_you.txt"))
        self.assertTrue(self.has("A3", "sign-off patch"))

    def test_pending_function_granted_without_lockdown_entry(self):
        with open(os.path.join(self.root, "migrations", "20261115_inbox_needs_you_v1.sql"), "a") as f:
            f.write("\ngrant execute on function public.app_needs_you() to authenticated;\n")
        self.assertTrue(self.has("A3", "granted"))

    def test_message_kind_missing_in_constraint(self):
        self.edit("webapp/app.js", "act('bank', { verb: 'balance'", "act('teleport', { verb: 'balance'")
        self.assertTrue(self.has("K1", "teleport"))
        self.assertTrue(self.has("K2", "teleport"))

    def test_bot_branch_removed(self):
        self.edit("hq_web.py", 'elif kind == "draft":', 'elif kind == "drafty":')
        self.assertTrue(self.has("K2", "'draft'"))

    def test_service_worker_misses_an_asset(self):
        self.edit("webapp/sw.js", ",'icon-512.png'", "")
        self.assertTrue(self.has("S3", "icon-512.png"))
        self.assertTrue(self.has("S5", "icon-512.png"))

    def test_service_worker_misses_a_page_dependency(self):
        self.edit("webapp/sw.js", ",'styles.css'", "")
        self.assertTrue(self.has("S4", "styles.css"))

    def test_service_worker_lists_a_file_that_does_not_exist(self):
        self.edit("webapp/sw.js", "'icon-192.png'", "'icon-192.png','nope.png'")
        self.assertTrue(self.has("S2", "nope.png"))

    def test_a_new_shipped_file_must_be_cached(self):
        with open(os.path.join(self.root, "webapp", "extra.js"), "w") as f:
            f.write("1")
        self.assertTrue(self.has("S3", "extra.js"))

    def test_apply_page_is_exempt(self):
        self.assertFalse(self.has("S3", "apply/"))


if __name__ == "__main__":
    unittest.main()
