import json
import os
import unittest

import check_gitleaks_ignore as g

ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..")
FP1 = "a" * 40 + ":sqltests/x.sql:generic-api-key:3"
FP2 = "b" * 40 + ":sqltests/y.sql:generic-api-key:4"


def audit(fps, **kw):
    a = {"count": len(fps), "sha256": g.digest(fps), "entries": {f: {"why": "w", "origin": "o", "reviewed": "d"} for f in fps}}
    a.update(kw)
    return a


GOOD_TOML = '[extend]\nuseDefault = true\n[[allowlists]]\ndescription = "x"\ncondition = "AND"\npaths = [\'\'\'^a/b\\.sql$\'\'\']\nregexTarget = "line"\nregexes = [\'\'\'FIXTURE_VALUE\'\'\']\n'


class T(unittest.TestCase):
    def test_repo_is_clean(self):
        self.assertEqual(g.main(ROOT), 0)

    def test_matching_list_ok(self):
        self.assertEqual(g.check_ignore(FP1 + "\n# c\n", audit([FP1])), [])

    def test_added_fingerprint_fails(self):
        self.assertTrue(any("G2" in e for e in g.check_ignore(FP1 + "\n" + FP2 + "\n", audit([FP1]))))

    def test_swapped_fingerprint_same_count_fails(self):
        self.assertTrue(any("sha256" in e for e in g.check_ignore(FP2 + "\n", audit([FP1], entries={FP2: {"why": "w", "origin": "o", "reviewed": "d"}}))))

    def test_undocumented_entry_fails(self):
        a = audit([FP1])
        a["entries"] = {}
        self.assertTrue(any("no documented" in e for e in g.check_ignore(FP1 + "\n", a)))

    def test_wildcard_fingerprint_fails(self):
        bad = "a" * 40 + ":sqltests/*.sql:generic-api-key:3"
        self.assertTrue(any("G1" in e for e in g.check_ignore(bad + "\n", audit([bad]))))

    def test_toml_good(self):
        self.assertEqual(g.check_toml(GOOD_TOML), [])

    def test_commits_forbidden(self):
        self.assertTrue(any("commits" in e for e in g.check_toml(GOOD_TOML + 'commits = ["abc"]\n')))

    def test_dir_wide_forbidden(self):
        t = GOOD_TOML.replace("^a/b\\.sql$", "^sqltests/")
        self.assertTrue(any("G4" in e for e in g.check_toml(t)))
        t = GOOD_TOML.replace("^a/b\\.sql$", "^sqltests/.*\\.sql$")
        self.assertTrue(any("G4" in e for e in g.check_toml(t)))

    def test_rule_wide_and_path_only_forbidden(self):
        self.assertTrue(any("G4" in e for e in g.check_toml('[extend]\nuseDefault = true\n[[allowlists]]\ndescription="r"\nregexes=["FIXTURE_VALUE"]\n')))
        self.assertTrue(any("G4" in e for e in g.check_toml('[extend]\nuseDefault = true\n[[allowlists]]\ndescription="p"\ncondition="AND"\npaths=["^a\\\\.sql$"]\n')))

    def test_default_rules_must_stay_on(self):
        self.assertTrue(any("useDefault" in e for e in g.check_toml(GOOD_TOML.replace("true", "false", 1))))
        self.assertTrue(any("disabledRules" in e for e in g.check_toml(GOOD_TOML.replace("useDefault = true", 'useDefault = true\ndisabledRules = ["generic-api-key"]'))))


if __name__ == "__main__":
    unittest.main()
