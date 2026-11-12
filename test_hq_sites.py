import os, unittest
from unittest import mock
import hq_sites as S

IDX = '<!doctype html><title>Acme</title><h1>Hi</h1>'


class T(unittest.TestCase):
    def test_ok_repaths(self):
        f, p = S.check_site("acme", [{"path": "index.html", "content": IDX}, {"path": "s.css", "content": "a{}"}])
        self.assertEqual(p, []); self.assertEqual(f[0]["path"], "sites/acme/index.html")

    def test_refusals(self):
        for content, frag in [('<title>x</title><script src="https://cdn.x/a.js"></script>', "external"),
                              ('<title>x</title><iframe src=a>', "iframe"),
                              ('<title>x</title><meta http-equiv="refresh" content="0;url=x">', "redirect"),
                              ('<title>x</title><form action="//evil.com">', "post"),
                              ('<title>x</title><input type="password">', "password"),
                              ('<h1>no title</h1>', "title")]:
            _, p = S.check_site("acme", [{"path": "index.html", "content": content}])
            self.assertTrue(any(frag in x for x in p), (content, p))

    def test_paths_and_types(self):
        self.assertTrue(S.check_site("Bad Slug", [{"path": "index.html", "content": IDX}])[1])
        self.assertTrue(S.check_site("acme", [{"path": "../index.html", "content": IDX}])[1])
        self.assertTrue(S.check_site("acme", [{"path": "a/index.html", "content": IDX}])[1])
        self.assertTrue(S.check_site("acme", [{"path": "x.js", "content": "1"}])[1])
        self.assertTrue(S.check_site("acme", [{"path": "a.css", "content": "a{}"}])[1])  # no index

    def test_propose_goes_through_dev_checks(self):
        with mock.patch("hq_dev.propose_change", return_value="PR ok") as pc:
            self.assertEqual(S.propose_site("acme", "Landing", "why " * 10, [{"path": "index.html", "content": IDX}]), "PR ok")
            self.assertEqual(pc.call_args[0][2][0]["path"], "sites/acme/index.html")
        self.assertTrue(S.propose_site("acme", "Landing", "why", [{"path": "x.js", "content": "1"}]).startswith("Refused"))


if __name__ == "__main__":
    unittest.main()
