import os
import unittest

import check_requirements_sync as c

H = "a" * 64
LOCK = f"foo==1.0 \\\n    --hash=sha256:{H}\n    # via bar\nbar==2.0 ; sys_platform != 'win32' \\\n    --hash=sha256:{H} \\\n    --hash=sha256:{'b' * 64}\n"
REQ = c.HEADER + LOCK
ROOT = os.path.normpath(os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))


class T(unittest.TestCase):
    def test_clean(self):
        self.assertEqual(c.check(REQ, LOCK), [])

    def test_drift(self):
        self.assertTrue(any(e.startswith("R1") for e in c.check(REQ.replace("foo==1.0", "foo==1.1"), LOCK)))

    def test_header_may_differ(self):
        self.assertEqual(c.check("# other header\n\n" + LOCK, LOCK), [])

    def test_unhashed_pin(self):
        lock = "foo==1.0\nbar==2.0 \\\n    --hash=sha256:" + H + "\n"
        self.assertTrue(any("foo has no sha256" in e for e in c.check(c.HEADER + lock, lock)))

    def test_range_rejected(self):
        lock = "foo>=1.0 \\\n    --hash=sha256:" + H + "\n"
        self.assertTrue(any(e.startswith("R2") for e in c.check(c.HEADER + lock, lock)))

    def test_index_override_rejected(self):
        lock = "--extra-index-url https://evil.example/simple\n" + LOCK
        self.assertTrue(any(e.startswith("R3") for e in c.check(c.HEADER + lock, lock)))

    def test_vcs_url_rejected(self):
        lock = "git+https://github.com/x/y@main#egg=y\n" + LOCK
        self.assertTrue(any(e.startswith("R3") for e in c.check(c.HEADER + lock, lock)))

    def test_repo_is_in_sync(self):
        lock = open(os.path.join(ROOT, "requirements", "runtime.lock")).read()
        self.assertEqual(c.check(open(os.path.join(ROOT, "requirements.txt")).read(), lock), [])


if __name__ == "__main__":
    unittest.main()
