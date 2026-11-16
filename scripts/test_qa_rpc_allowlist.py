"""Keeps the QA harness's RPC classification (scripts/qa/qa.config.json) tied to the source of truth the drift checker already uses:
the lockdown keep-open list (scripts/check_app_rpcs.py / migrations). A new function opened to signed-in users must be classified by the QA harness
(safe read, low-risk write, or known guard-changing write) before this test passes, so the harness's allow-list cannot silently go stale."""
import json
import os
import sys
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import check_app_rpcs as K  # noqa: E402
import lint_migrations as L  # noqa: E402

# Keep-open functions that can change a guard (kill switch, agent status). The harness must FAIL any UI that exposes them in demo mode.
GUARD_WRITES = {"app_set_kill", "app_set_agent"}


class QaAllowList(unittest.TestCase):
    def setUp(self):
        with open(os.path.join(HERE, "qa", "qa.config.json")) as f:
            self.cfg = json.load(f)["rpc"]
        self.keep = L.keep_open_names(K._read(K.ROOT, "migrations/" + L.LOCKDOWN))

    def test_every_keep_open_function_is_classified(self):
        classified = set(self.cfg["readOnly"]) | set(self.cfg["lowRiskWrite"]) | GUARD_WRITES | K.NOT_CALLED_BY_APP
        self.assertEqual(sorted(self.keep - classified), [], "classify these in scripts/qa/qa.config.json (rpc.readOnly / rpc.lowRiskWrite) or GUARD_WRITES here")

    def test_allow_list_only_names_real_functions(self):
        known = self.keep | set(K.PENDING_SIGNOFF)
        self.assertEqual(sorted((set(self.cfg["readOnly"]) | set(self.cfg["lowRiskWrite"])) - known), [])

    def test_guard_writes_are_never_allow_listed(self):
        self.assertEqual(sorted(GUARD_WRITES & (set(self.cfg["readOnly"]) | set(self.cfg["lowRiskWrite"]))), [])

    def test_deny_pattern_matches_guard_writes(self):
        import re
        for n in GUARD_WRITES:
            self.assertRegex(n, re.compile(self.cfg["denyRe"], re.I))


if __name__ == "__main__":
    unittest.main()
