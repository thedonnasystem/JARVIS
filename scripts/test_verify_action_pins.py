import os
import tempfile
import unittest

import verify_action_pins as v

SHA = "a" * 40
WF = f"""name: t
permissions:
  contents: read
jobs:
  a:
    steps:
      - uses: actions/checkout@{SHA} # v7.0.1
        with:
          persist-credentials: false
      - uses: ./local
      - uses: docker://alpine@sha256:{"b" * 64}
"""


class T(unittest.TestCase):
    def _items(self, text=WF):
        with tempfile.TemporaryDirectory() as d:
            os.makedirs(os.path.join(d, ".github", "workflows"))
            open(os.path.join(d, ".github", "workflows", "x.yml"), "w").write(text)
            return v.pins(d)

    def test_parse(self):
        self.assertEqual(self._items(), [("x.yml:7", "actions/checkout", SHA, "v7.0.1")])

    def test_ok_and_ancestry_warn(self):
        api = lambda p: {"default_branch": "main"} if p.count("/") == 2 else {"status": "diverged"}  # noqa: E731
        f, w = v.verify(self._items(), resolver=lambda r, t: SHA, apifn=api)
        self.assertEqual(f, [])
        self.assertEqual(len(w), 1)

    def test_tag_mismatch_fails(self):
        f, _ = v.verify(self._items(), resolver=lambda r, t: "c" * 40, apifn=lambda p: {"default_branch": "main", "status": "behind"})
        self.assertEqual(len(f), 1)

    def test_network_error_is_failure_not_success(self):
        def boom(r, t):
            raise RuntimeError("offline")
        f, _ = v.verify(self._items(), resolver=boom, apifn=lambda p: {})
        self.assertEqual(len(f), 1)

    def test_repo_pins_parse(self):
        root = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..")
        self.assertGreaterEqual(len(v.pins(root)), 1)
