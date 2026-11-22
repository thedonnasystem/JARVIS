"""hq_mission_gate (M7 review): missions follow their office: refused while dormant, paused (not failed) on deactivation, resumed when active."""
import unittest
from unittest import mock

import hq_mission_gate as G
import hq_missions as M

DONNA_V, GROUP_V = "v-donna", "v-lab"
OFFICES = {"o-donna": {"slug": "donna", "kind": "office", "status": "dormant"}, "o-group": {"slug": "group", "kind": "group", "status": "active"}}
VENTURES = {DONNA_V: "o-donna", GROUP_V: "o-group"}


class FakeDB:
    def __init__(self, missions=None):
        self.missions = missions or []
        self.tasks = [{"id": "t1", "mission_id": "m1", "status": "todo"}, {"id": "t2", "mission_id": "m1", "status": "done"}]
        self.patches = []

    def get(self, path):
        if path.startswith("ventures?id=eq."):
            vid = path.split("eq.", 1)[1].split("&", 1)[0]
            return [{"office_id": VENTURES.get(vid)}] if vid in VENTURES else []
        if path.startswith("fz_offices?id=eq."):
            oid = path.split("eq.", 1)[1].split("&", 1)[0]
            return [OFFICES[oid]] if oid in OFFICES else []
        if path.startswith("missions?"):
            return self.missions
        if path.startswith("tasks?mission_id=eq."):
            mid = path.split("eq.", 1)[1].split("&", 1)[0]
            return [t for t in self.tasks if t["mission_id"] == mid and t["status"] == "todo"]
        return []

    def patch(self, path, body):
        self.patches.append((path, body))
        if path.startswith("missions?id=eq."):
            mid = path.split("eq.", 1)[1].split("&", 1)[0]
            for m in self.missions:
                if m["id"] == mid:
                    m.update(body)
        if path.startswith("tasks?id=eq."):
            tid = path.split("eq.", 1)[1].split("&", 1)[0]
            for t in self.tasks:
                if t["id"] == tid:
                    t.update(body)


class Gate(unittest.TestCase):
    def setUp(self):
        OFFICES["o-donna"]["status"] = "dormant"

    def test_create_refused_while_dormant(self):
        db = FakeDB()
        self.assertIn("office donna is not active", G.create_refusal(DONNA_V, get=db.get))
        self.assertIsNone(G.create_refusal(GROUP_V, get=db.get))
        self.assertIsNone(G.create_refusal(None, get=db.get))
        self.assertIn("not active", G.create_refusal("v-unknown-office", get=lambda p: [{"office_id": "o-missing"}] if p.startswith("ventures") else []))
        self.assertIn("could not be checked", G.create_refusal(DONNA_V, get=mock.Mock(side_effect=RuntimeError("x"))))
        OFFICES["o-donna"]["status"] = "active"
        self.assertIsNone(G.create_refusal(DONNA_V, get=db.get))

    def test_create_mission_refuses_dormant_office(self):
        inserted = []
        def get(path):
            if path.startswith("missions?status=in."):
                return []
            if path.startswith("ventures?slug=eq.donna"):
                return [{"id": DONNA_V, "slug": "donna", "status": "active"}]
            return FakeDB().get(path)
        with mock.patch.object(M, "_get", side_effect=get), mock.patch.object(M, "_get_complete", return_value=[]), \
             mock.patch.object(M, "_insert", side_effect=lambda *a, **k: inserted.append(a) or {"id": "m"}), mock.patch.object(M, "_audit"), \
             mock.patch.object(G, "_get", side_effect=lambda p, g=None: FakeDB().get(p)):
            r = M.create_mission("Validate the Ottawa trades market for Donna before any niche commitment.", venture="donna")
        self.assertIn("office donna is not active", r.get("error", ""))
        self.assertEqual(inserted, [])

    def test_running_mission_pauses_after_deactivation_and_resumes(self):
        db = FakeDB([{"id": "m1", "title": "x", "status": "executing", "venture_id": DONNA_V, "checkpoint": {"budget_marks": [1]},
                      "plan": [{"status": "done"}, {"status": "pending"}]},
                     {"id": "m2", "title": "y", "status": "executing", "venture_id": GROUP_V, "checkpoint": {}, "plan": []}])
        r = G.sweep(get=db.get, patch=db.patch)
        self.assertEqual(r, {"paused": ["m1"], "resumed": []})
        m1 = db.missions[0]
        self.assertEqual((m1["status"], m1["checkpoint"]["office_paused"], m1["checkpoint"]["budget_marks"]), ("paused", "donna", [1]))
        self.assertNotIn("failed", m1["status"])
        self.assertEqual([t["status"] for t in db.tasks], ["cancelled", "done"])     # its waiting task is cancelled, history kept
        self.assertEqual(db.missions[1]["status"], "executing")                       # the group's mission keeps running
        self.assertEqual(G.sweep(get=db.get, patch=db.patch), {"paused": [], "resumed": []})   # still dormant: stays paused
        m1["plan"][1]["status"] = "cancelled"
        OFFICES["o-donna"]["status"] = "active"
        self.assertEqual(G.sweep(get=db.get, patch=db.patch)["resumed"], ["m1"])
        self.assertEqual((m1["status"], m1["plan"][1]["status"]), ("executing", "pending"))
        self.assertNotIn("office_paused", m1["checkpoint"])

    def test_owner_pause_is_never_undone(self):
        OFFICES["o-donna"]["status"] = "active"
        db = FakeDB([{"id": "m1", "title": "x", "status": "paused", "venture_id": DONNA_V, "checkpoint": {}, "plan": []}])
        self.assertEqual(G.sweep(get=db.get, patch=db.patch), {"paused": [], "resumed": []})
        self.assertEqual(db.patches, [])

    def test_advance_moves_no_paused_mission(self):
        rows = [{"id": "m1", "status": "executing", "venture_id": DONNA_V}]
        with mock.patch.object(M, "_get", return_value=rows), mock.patch.object(G, "sweep", return_value={"paused": ["m1"], "resumed": []}), \
             mock.patch.object(M, "_check_due") as due, mock.patch.object(M, "spawn_recurring"):
            self.assertEqual(M.advance(), 0)
        due.assert_not_called()
        with mock.patch.object(M, "_get", return_value=rows), mock.patch.object(G, "sweep", side_effect=RuntimeError("db")), \
             mock.patch.object(M, "_check_due") as due:
            self.assertEqual(M.advance(), 0)                                           # gate unreadable: nothing moves (fail closed)
        due.assert_not_called()


if __name__ == "__main__":
    unittest.main()
