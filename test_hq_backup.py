import os, unittest
from unittest import mock
from cryptography.fernet import Fernet
import hq_backup as B

ENV = {"BACKUP_KEY": Fernet.generate_key().decode(), "BACKUP_PUT_URL": "https://store.example.com/b/{name}"}


def fake_request(method, path, body=None, prefer=None):
    if method == "GET" and "/audit_log" in path:
        return []
    if method == "GET":
        t = path.split("/rest/v1/")[1].split("?")[0]
        return [{"id": i, "v": f"{t}{i}"} for i in range(3)] if t in ("leads", "ledger") else []
    return None


class T(unittest.TestCase):
    def test_off_without_config(self):
        with mock.patch.dict(os.environ, {}, clear=True):
            self.assertEqual(B.run()["reason"], "not configured")

    def test_dump_encrypt_verify_roundtrip(self):
        with mock.patch.dict(os.environ, ENV), mock.patch("hq._request", side_effect=fake_request):
            blob, counts = B.dump()
            self.assertEqual(counts["leads"], 3); self.assertNotIn("push_config", counts)
            enc = B.encrypt(blob)
            self.assertNotIn(b"leads0", enc)
            self.assertEqual(B.verify(enc, counts), [])
            self.assertTrue(B.verify(enc, {**counts, "leads": 4}))
            self.assertTrue(B.verify(b"garbage", counts))

    def test_wrong_key_detected(self):
        with mock.patch.dict(os.environ, ENV), mock.patch("hq._request", side_effect=fake_request):
            blob, counts = B.dump(); enc = B.encrypt(blob)
        with mock.patch.dict(os.environ, {"BACKUP_KEY": Fernet.generate_key().decode(), "BACKUP_PUT_URL": "x"}):
            self.assertTrue(B.verify(enc, counts))

    def test_run_success_and_failure_paths(self):
        with mock.patch.dict(os.environ, ENV), mock.patch("hq._request", side_effect=fake_request):
            with mock.patch.object(B, "upload", return_value=True):
                r = B.run(force=True); self.assertTrue(r["ok"]); self.assertEqual(r["rows"], 6)
            with mock.patch.object(B, "upload", return_value=False):
                r = B.run(force=True); self.assertFalse(r["ok"]); self.assertIn("upload failed", r["reason"])

    def test_unordered_fallback_when_sort_column_missing(self):
        import urllib.error
        def req(method, path, body=None, prefer=None):
            if "order=" in path:
                raise urllib.error.HTTPError(path, 400, "bad", {}, None)
            return fake_request(method, path)
        with mock.patch("hq._request", side_effect=req):
            blob, counts = B.dump()
        self.assertEqual(counts["leads"], 3)

    def test_rejects_non_https_target(self):
        with mock.patch.dict(os.environ, {**ENV, "BACKUP_PUT_URL": "http://insecure/{name}"}):
            self.assertFalse(B.upload("x", b"y"))

    def test_due_window(self):
        from datetime import datetime, timezone
        with mock.patch("hq._request", return_value=[]):
            self.assertTrue(B.due(datetime(2026, 11, 13, 8, 0, tzinfo=timezone.utc)))    # 03:00 Toronto
            self.assertFalse(B.due(datetime(2026, 11, 13, 18, 0, tzinfo=timezone.utc)))  # 13:00 Toronto
        with mock.patch("hq._request", return_value=[{"id": 1}]):
            self.assertFalse(B.due(datetime(2026, 11, 13, 8, 0, tzinfo=timezone.utc)))   # already done


if __name__ == "__main__":
    unittest.main()
