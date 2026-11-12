import asyncio
import unittest
from unittest import mock

import hq
import hq_commands as C
import hq_office as O

DATA = [{"fn": "executive", "name": "Executive Office", "headline": "1 live missions", "open": 2, "blocked": 0, "done_7d": 9, "spent_7d": 140,
         "agents": [{"title": "Jarvis", "status": "active"}, {"title": "Old", "status": "paused"}]},
        {"fn": "engineering", "name": "Engineering & Technology", "headline": "0 shipped", "open": 0, "blocked": 0, "done_7d": 0, "spent_7d": 0, "agents": []}]


class Office(unittest.TestCase):
    def test_text_lists_staff_and_flags_unstaffed(self):
        with mock.patch.object(hq, "_request", lambda *a, **k: DATA):
            out = O.office_text()
        self.assertIn("Executive Office: Jarvis", out)
        self.assertNotIn("Old", out)
        self.assertIn("Engineering & Technology: UNSTAFFED", out)
        self.assertIn("AI 7d $1.40", out)

    def test_missing_migration_and_chat_tool(self):
        with mock.patch.object(hq, "_request", lambda *a, **k: (_ for _ in ()).throw(RuntimeError("404"))):
            self.assertIn("not installed", O.office_text())
        self.assertIn("hq_office", [t["name"] for t in C.HQ_CHAT_TOOLS])
        with mock.patch.object(hq, "_request", lambda *a, **k: DATA):
            self.assertIn("UNSTAFFED", asyncio.run(C.handle_chat_tool("hq_office", {})))


if __name__ == "__main__":
    unittest.main()
