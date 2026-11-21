"""scripts/check_integrations.py: presence only, never a value (Phase 1 M7)."""
import contextlib
import io
import json
import os
import sys
import unittest

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import check_integrations as C  # noqa: E402

SECRET = "sk-test-NEVER-PRINT-ME-0123456789"


class T(unittest.TestCase):
    def run_main(self, env, *args):
        buf = io.StringIO()
        old = dict(os.environ)
        try:
            os.environ.clear()
            os.environ.update(env)
            with contextlib.redirect_stdout(buf):
                rc = C.main(list(args))
        finally:
            os.environ.clear()
            os.environ.update(old)
        return rc, buf.getvalue()

    def test_states(self):
        env = {"TELEGRAM_BOT_TOKEN": SECRET, "JARVIS_OWNER_ID": SECRET, "HQ_SUPABASE_URL": SECRET, "ANTHROPIC_API_KEY": "  "}
        s = {r["key"]: r for r in C.report(env=env)}
        self.assertEqual(s["telegram"]["state"], "present")
        self.assertEqual(s["supabase"]["state"], "partial")
        self.assertEqual(s["supabase"]["missing"], ["HQ_SUPABASE_SERVICE_KEY"])
        self.assertEqual(s["anthropic"]["state"], "missing")      # blank is not set
        self.assertEqual(s["rbc"]["state"], "manual")
        self.assertEqual(s["stripe"]["state"], "not-built")
        self.assertEqual(s["railway"]["state"], "missing")

    def test_never_prints_a_value(self):
        env = {n: SECRET for i in C.INTEGRATIONS for n in i[2] + i[3]}
        for args in ((), ("--json",), ("--office", "donna"), ("--strict",)):
            rc, out = self.run_main(env, *args)
            self.assertNotIn(SECRET, out)
            self.assertNotIn("NEVER-PRINT", out)
            self.assertEqual(rc, 0)

    def test_strict_and_office_filter(self):
        rc, _ = self.run_main({}, "--strict")
        self.assertEqual(rc, 1)
        rc, out = self.run_main({}, "--office", "monopoly", "--json")
        keys = {r["key"] for r in json.loads(out)}
        self.assertIn("wholesale_db", keys)
        self.assertNotIn("tiktok", keys)
        with self.assertRaises(SystemExit):
            C.report("nope")

    def test_inventory_is_well_formed(self):
        self.assertEqual(len(C.KEYS), len(set(C.KEYS)))
        for key, name, req, opt, offices, code, tier, core in C.INTEGRATIONS:
            self.assertIn(tier, ("green", "yellow", "red", "prohibited"))
            self.assertTrue(set(offices) <= set(C.ALL), key)
            if not code:
                self.assertEqual((req, opt), ([], []), key)

    def test_no_network_or_file_access(self):
        import ast
        tree = ast.parse(open(C.__file__).read())
        mods = {a.name for n in ast.walk(tree) if isinstance(n, ast.Import) for a in n.names} | {n.module for n in ast.walk(tree) if isinstance(n, ast.ImportFrom)}
        self.assertEqual(mods, {"argparse", "json", "os", "sys"})
        calls = {n.func.id for n in ast.walk(tree) if isinstance(n, ast.Call) and isinstance(n.func, ast.Name)}
        self.assertFalse(calls & {"open", "exec", "eval", "__import__"})


if __name__ == "__main__":
    unittest.main()
