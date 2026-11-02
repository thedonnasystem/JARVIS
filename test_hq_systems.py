import unittest
from datetime import datetime
from unittest import mock
import hq, hq_systems as S


class T(unittest.TestCase):
    def test_due_window(self):
        now = datetime(2026, 11, 2, 7, 52, tzinfo=S.TZ)
        self.assertEqual(S.due(["07:50", "18:55", "bad"], now), ["07:50"])
        self.assertEqual(S.due(["07:40"], now), [])

    def test_down_system_alerts_once(self):
        calls = []
        def fake(method, path, body=None, timeout=30, prefer=None):
            calls.append((method, path, body))
            if method == "GET":
                return [{"slug": "dialer", "name": "Parallel dialer", "health_url": "https://x", "warmup_local_times": ["07:50"]}]
        S._done.clear()
        now = datetime(2026, 11, 2, 7, 51, tzinfo=S.TZ)
        with mock.patch.object(hq, "_request", fake), mock.patch.object(S, "probe", return_value=(0, 100)):
            self.assertEqual(S.run_due_checks(now), 1)
            self.assertEqual(S.run_due_checks(now), 0)  # same slot not re-checked
        self.assertEqual(sum("owner_messages" in c[1] for c in calls), 1)


if __name__ == "__main__":
    unittest.main()
