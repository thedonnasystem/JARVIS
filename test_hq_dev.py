import base64, io, json, os, unittest, urllib.error
from unittest import mock
import hq_dev as D

OK = [{"path": "hq_extra.py", "content": "print('hi')\n"}]


class Gh:
    def __init__(self, fail_on=None, existing=False):
        self.calls = []; self.fail_on = fail_on; self.existing = existing

    def __call__(self, method, path, body=None):
        self.calls.append((method, path, body))
        if self.fail_on and self.fail_on in path:
            raise urllib.error.HTTPError("u", 403, "no", {}, io.BytesIO(b"{}"))
        if path.startswith("/git/ref/heads/"):
            return {"object": {"sha": "base123"}}
        if method == "GET" and path.startswith("/contents/"):
            if self.existing:
                return {"sha": "old1"}
            raise urllib.error.HTTPError("u", 404, "nf", {}, io.BytesIO(b"{}"))
        if path == "/pulls":
            return {"html_url": "https://github.com/o/r/pull/7"}
        return {}


class T(unittest.TestCase):
    def setUp(self):
        os.environ["GITHUB_TOKEN"] = "t"; os.environ["GITHUB_REPO"] = "o/r"

    def test_not_configured_is_plain(self):
        os.environ.pop("GITHUB_TOKEN")
        self.assertIn("not set up", D.propose_change("A good title here", "x" * 40, OK))

    def test_refuses_secrets_traversal_blocked_big_and_too_many(self):
        for f in ([{"path": "a.py", "content": "k='sk-ant-" + "a" * 30 + "'"}], [{"path": "../x.py", "content": "1"}],
                  [{"path": ".env", "content": "A=1"}], [{"path": "big.py", "content": "x" * 70000}], OK * 6, []):
            self.assertIn("Refused", D.propose_change("A good title here", "Because the reason is long enough.", f))

    def test_opens_pr_on_new_branch_never_touches_base(self):
        g = Gh()
        with mock.patch.object(D, "_call", g):
            out = D.propose_change("Add extra helper module", "Needed because the weekly review wants a helper.", OK)
        self.assertIn("pull/7", out)
        ref = [b for m, p, b in g.calls if p == "/git/refs"][0]
        self.assertTrue(ref["ref"].startswith("refs/heads/jarvis/"))
        put = [(p, b) for m, p, b in g.calls if m == "PUT"][0]
        self.assertEqual(base64.b64decode(put[1]["content"]).decode(), "print('hi')\n")
        self.assertNotEqual(put[1]["branch"], D.BASE_BRANCH)
        self.assertFalse([1 for m, p, b in g.calls if "merge" in p])

    def test_existing_file_gets_sha_and_protected_is_flagged(self):
        g = Gh(existing=True)
        with mock.patch.object(D, "_call", g):
            out = D.propose_change("Tweak the capital limits code", "Reason that is long enough to count.", [{"path": "hq_capital.py", "content": "x = 1\n"}])
        self.assertIn("protected", out)
        self.assertEqual([b for m, p, b in g.calls if m == "PUT"][0]["sha"], "old1")
        self.assertIn("PROTECTED PATHS", [b for m, p, b in g.calls if p == "/pulls"][0]["body"])

    def test_github_error_is_reported_without_details(self):
        with mock.patch.object(D, "_call", Gh(fail_on="/git/refs")):
            out = D.propose_change("Add extra helper module", "Needed because the weekly review wants a helper.", OK)
        self.assertIn("HTTP 403", out); self.assertIn("Nothing was merged", out)


if __name__ == "__main__":
    unittest.main()
