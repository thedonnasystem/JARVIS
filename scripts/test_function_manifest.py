"""Tests for scripts/function_manifest.py (pure logic; the DB path is exercised by scripts/gate.sh)."""
import os
import sys
import unittest

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import function_manifest as F  # noqa: E402

M = lambda c: c * 32  # fake md5


class Diff(unittest.TestCase):
    def test_added_changed_removed_unverifiable_scaffolding(self):
        base = {"keep()": M("a"), "chg()": M("b"), "gone()": M("c"), "unv()": M("d")}
        seed = {"chg()": M("b"), "unv()": M("z"), "scaf()": M("e"), "keep()": M("a")}
        final = {"keep()": M("a"), "chg()": M("x"), "unv()": M("y"), "scaf()": M("e"), "new()": M("f")}
        d = F.diff(base, final, seed)
        self.assertEqual(d["added"], ["new()"])
        self.assertEqual(d["changed"], ["chg()"])
        self.assertEqual(d["removed"], ["gone()"])
        self.assertEqual(d["unverifiable"], ["unv()"])
        self.assertEqual(d["scaffolding"], ["scaf()"])

    def test_identical_is_empty(self):
        m = {"a()": M("1")}
        d = F.diff(m, dict(m), dict(m))
        self.assertEqual((d["added"], d["changed"], d["removed"], d["unverifiable"]), ([], [], [], []))


class Formats(unittest.TestCase):
    def test_parse_manifest_and_bad_line(self):
        self.assertEqual(F.parse_manifest("# c\n\nf(text,integer) " + M("a") + "\n"), {"f(text,integer)": M("a")})
        with self.assertRaises(ValueError):
            F.parse_manifest("f() nothex\n")

    def test_roundtrip_generated_file(self):
        d = {"added": ["a()", "b(text)"], "changed": ["c()"], "removed": ["r()"]}
        got = F.parse_expected(F.render_expected(d))
        self.assertEqual(got, {"ADD": {"a()", "b(text)"}, "CHANGE": {"c()"}, "REMOVE": {"r()"}})

    def test_existing_hand_written_file_still_parses(self):
        with open(F.EXPECTED) as f:
            got = F.parse_expected(f.read())
        self.assertIn("mission_guard(text,text,integer)", got["ADD"])
        self.assertIn("reserve_llm_budget(text,integer,text,text)", got["CHANGE"])
        self.assertNotIn("enforce_build_rules()", got["CHANGE"] | got["ADD"])
        self.assertEqual(got["REMOVE"], set())

    def test_compare_flags_each_direction(self):
        d = {"added": ["a()"], "changed": [], "removed": []}
        self.assertEqual(F.compare_expected(d, {"ADD": {"a()"}, "CHANGE": set(), "REMOVE": set()}), [])
        self.assertEqual(len(F.compare_expected(d, {"ADD": set(), "CHANGE": set(), "REMOVE": set()})), 1)  # produced, not listed
        self.assertEqual(len(F.compare_expected(d, {"ADD": {"a()", "b()"}, "CHANGE": set(), "REMOVE": set()})), 1)  # listed, not produced
        self.assertEqual(len(F.compare_expected({"added": [], "changed": [], "removed": ["r()"]}, {"ADD": set(), "CHANGE": set(), "REMOVE": set()})), 1)

    def test_baseline_file_parses_and_has_expected_rollback_functions(self):
        with open(F.latest_baseline()) as f:
            b = F.parse_manifest(f.read())
        self.assertGreater(len(b), 50)
        self.assertIn("enforce_build_rules()", b)


class Cli(unittest.TestCase):
    def test_no_url_exits_2_not_0(self):
        old = os.environ.pop("REPLICA_URL", None)
        try:
            import contextlib, io
            with contextlib.redirect_stdout(io.StringIO()):
                self.assertEqual(F.main([]), 2)
        finally:
            if old is not None:
                os.environ["REPLICA_URL"] = old


if __name__ == "__main__":
    unittest.main()
