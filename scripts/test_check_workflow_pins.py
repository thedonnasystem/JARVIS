import os
import unittest

import check_workflow_pins as c

SHA = "a" * 40
OK = f"""name: t
permissions:
  contents: read
jobs:
  a:
    steps:
      - uses: actions/checkout@{SHA} # v4.4.0
        with:
          persist-credentials: false
      - uses: ./local/action
"""


class T(unittest.TestCase):
    def test_clean(self):
        self.assertEqual(c.check_text(".github/workflows/x.yml", OK), [])

    def test_tag_pin_rejected(self):
        e = c.check_text(".github/workflows/x.yml", OK.replace(SHA, "v4"))
        self.assertTrue(any("P1" in x for x in e))

    def test_branch_pin_rejected(self):
        self.assertTrue(any("P1" in x for x in c.check_text(".github/workflows/x.yml", OK.replace(SHA, "main"))))

    def test_short_sha_rejected(self):
        self.assertTrue(any("P1" in x for x in c.check_text(".github/workflows/x.yml", OK.replace(SHA, "abc1234"))))

    def test_missing_version_comment(self):
        self.assertTrue(any("P2" in x for x in c.check_text(".github/workflows/x.yml", OK.replace(" # v4.4.0", ""))))

    def test_missing_permissions(self):
        e = c.check_text(".github/workflows/x.yml", OK.replace("permissions:\n  contents: read\n", ""))
        self.assertTrue(any("P3" in x for x in e))

    def test_checkout_persist_credentials(self):
        e = c.check_text(".github/workflows/x.yml", OK.replace("persist-credentials: false", "fetch-depth: 0"))
        self.assertTrue(any("P4" in x for x in e))

    def test_docker_needs_digest(self):
        t = OK + "      - uses: docker://alpine:3\n"
        self.assertTrue(any("docker" in x for x in c.check_text(".github/workflows/x.yml", t)))
        t = OK + "      - uses: docker://alpine@sha256:" + "b" * 64 + "\n"
        self.assertEqual(c.check_text(".github/workflows/x.yml", t), [])

    def test_service_image_needs_digest(self):
        t = OK + "    services:\n      postgres:\n        image: postgres:16\n"
        e = c.check_text(".github/workflows/x.yml", t)
        self.assertTrue(any("P5" in x for x in e), e)
        t = OK + "    services:\n      postgres:\n        image: postgres:16@sha256:" + "c" * 64 + "   # 16.16\n"
        self.assertEqual(c.check_text(".github/workflows/x.yml", t), [])
        # a bare tag with a trailing comment is still refused; a non-workflow file is not scanned for images
        self.assertTrue(any("P5" in x for x in c.check_text(".github/workflows/x.yml", OK + "        image: ubuntu:24.04   # x\n")))
        self.assertEqual(c.check_text(".github/actions/y/action.yml", OK + "        image: ubuntu:24.04\n"), [])

    def test_commented_uses_ignored(self):
        self.assertEqual(c.check_text(".github/workflows/x.yml", OK + "      # uses: evil/x@v1\n"), [])

    def test_repo_workflows_are_clean(self):
        root = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..")
        errs, n = c.check_root(root)
        self.assertEqual(errs, [])
        self.assertGreaterEqual(n, 1)


if __name__ == "__main__":
    unittest.main()
