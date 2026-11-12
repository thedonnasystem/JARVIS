import unittest
from unittest import mock
import hq_verify as V


class T(unittest.TestCase):
    def test_refuses_unsafe(self):
        for u in ["http://example.com", "https://user:p@example.com", "https://example.com:8443", "ftp://x", "", "https://localhost/"]:
            self.assertIsNotNone(V.check_url(u), u)
        with mock.patch("socket.getaddrinfo", return_value=[(2, 1, 6, "", ("10.0.0.5", 0))]):
            self.assertIn("public", V.check_url("https://internal.example.com"))
        with mock.patch("socket.getaddrinfo", return_value=[(2, 1, 6, "", ("169.254.169.254", 0))]):
            self.assertIsNotNone(V.check_url("https://meta.example.com"))
        with mock.patch("socket.getaddrinfo", return_value=[(2, 1, 6, "", ("93.184.216.34", 0))]):
            self.assertIsNone(V.check_url("https://example.com/a"))

    def _run(self, pages, expect=None):
        calls = iter(pages)
        with mock.patch("socket.getaddrinfo", return_value=[(2, 1, 6, "", ("93.184.216.34", 0))]), mock.patch("hq_verify._get", side_effect=lambda u: next(calls)):
            return V.verify("https://example.com", expect)

    def test_ok_and_missing_text(self):
        page = (200, {}, b"<title>Acme</title><h1>Book now</h1>")
        self.assertTrue(self._run([page], ["book now"])["ok"])
        r = self._run([page], ["pricing"]); self.assertFalse(r["ok"]); self.assertEqual(r["missing"], ["pricing"])

    def test_redirect_to_private_is_blocked_and_404(self):
        with mock.patch("socket.getaddrinfo", side_effect=lambda h, p: [(2, 1, 6, "", ("127.0.0.1" if h == "evil.internal" else "93.184.216.34", 0))]):
            with mock.patch("hq_verify._get", side_effect=[(302, {"Location": "https://evil.internal/"}, b"")]):
                r = V.verify("https://example.com"); self.assertFalse(r["ok"]); self.assertIn("public", r["problems"][0])
        r = self._run([(404, {}, b"<title>x</title>")]); self.assertFalse(r["ok"]); self.assertIn("HTTP 404.", r["problems"])

    def test_report(self):
        with mock.patch("hq_verify.verify", return_value={"ok": True, "status": 200, "final_url": "https://a.com", "title": "A"}):
            self.assertIn("VERIFIED", V.report("https://a.com"))


if __name__ == "__main__":
    unittest.main()
