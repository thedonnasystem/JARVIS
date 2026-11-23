"""M5 review LOW #7 (folded into M6): with scoped reads ON, a scoped read that returns FEWER rows never lets the mission engine act on an incomplete list."""

import os
import unittest
from unittest import mock

import hq
import hq_missions
import hq_services as svc

REPORT = {"scoped_reads_on": 1, "services": [
    {"service": "scheduler", "status": "active", "scoped_identity": "jarvis", "scoped_reads": True, "scoped_read_tables": ["missions", "tasks", "ventures", "agents"]}]}
LIVE5 = [{"id": f"m{i}"} for i in range(hq_missions.MAX_LIVE_MISSIONS)]


class _Scope:
    active = False

    def __init__(self, identity, require=False):
        self.identity = identity

    def __enter__(self):
        _Scope.active = True
        return self

    def __exit__(self, *a):
        _Scope.active = False
        return False


def fake_request(method, path, body=None, *a, **k):
    if path.endswith("fz_services_report"):
        return REPORT
    if method == "GET" and path.startswith("/rest/v1/missions?status=in."):
        return [] if _Scope.active else LIVE5        # the scoped read sees fewer rows than really exist
    if method == "POST" and path.startswith("/rest/v1/missions"):
        raise AssertionError("a mission was created from an incomplete list")
    return []


class ScopedReadIncompleteTests(unittest.TestCase):
    def setUp(self):
        svc.reset_cache()

    def test_live_cap_uses_the_complete_read(self):
        with mock.patch.dict(os.environ, {svc.FLAG: "1"}), mock.patch.object(hq, "_request", side_effect=fake_request), \
                mock.patch.object(hq, "as_identity", _Scope):
            self.assertEqual(svc.route("scheduler", "missions?status=in.(running)&select=id"), "jarvis")   # scoped reads really are on
            r = hq_missions.create_mission("A long enough objective for a new mission", venture="idea-lab")
        self.assertIn("error", r)
        self.assertIn("already live", r["error"])

    def test_scoped_partial_read_only_means_fewer_rows(self):
        with mock.patch.dict(os.environ, {svc.FLAG: "1"}), mock.patch.object(hq, "_request", side_effect=fake_request), \
                mock.patch.object(hq, "as_identity", _Scope):
            self.assertEqual(hq_missions._get("missions?status=in.(running)&select=id"), [])
            self.assertEqual(len(hq_missions._get_complete("missions?status=in.(running)&select=id")), len(LIVE5))


if __name__ == "__main__":
    unittest.main()
