import io, json, unittest, urllib.error
from unittest import mock
import hq, hq_org as O


def http_err(msg):
    return urllib.error.HTTPError("u", 400, msg, {}, io.BytesIO(json.dumps({"message": msg}).encode()))


class T(unittest.TestCase):
    def test_create_agent_passes_limits_through_and_reports(self):
        calls = []

        def req(method, path, body=None, timeout=30, prefer=None):
            calls.append((path, body)); return "active"
        with mock.patch.object(hq, "_request", req):
            out = O.create_agent("Mkt-Writer", "Writer", "marketing", "specialist", "cheap", 500, "c" * 40, "drafts accepted", by="owner-chat")
        self.assertEqual(calls[0][1]["p_slug"], "mkt-writer")
        self.assertIn("cap 50c/day", out); self.assertIn("cannot contact the owner", out)

    def test_asleep_and_database_refusals_are_readable(self):
        with mock.patch.object(hq, "_request", lambda *a, **k: "paused"):
            self.assertIn("ASLEEP", O.create_agent("a-b-c", "T", "d", "ops", "cheap", 10, "c" * 40, "m"))
        with mock.patch.object(hq, "_request", side_effect=http_err("Already created 3 agents this week (max 3). Ask the owner to approve more.")):
            self.assertIn("max 3", O.create_agent("a-b-c", "T", "d", "ops", "cheap", 10, "c" * 40, "m"))
        with mock.patch.object(hq, "_request", side_effect=RuntimeError("down")):
            self.assertIn("migration pending", O.create_department("mkt", "Marketing"))


if __name__ == "__main__":
    unittest.main()
