import unittest
from unittest import mock
import hq, hq_ventures as V, hq_commands as C


class Rec:
    def __init__(self, fail=None):
        self.calls = []; self.fail = fail

    def __call__(self, method, path, body=None, timeout=30, prefer=None):
        self.calls.append((method, path, body))
        if self.fail and self.fail in path:
            raise RuntimeError("nope")
        return None


class T(unittest.TestCase):
    def test_slugify(self):
        self.assertEqual(V.slugify("Ottawa Cleanouts Co."), "ottawa-cleanouts-co")
        self.assertEqual(V.slugify("24/7 Vending"), "v-24-7-vending")

    def test_start_creates_inert_venture_mission_and_activation_card(self):
        r = Rec()
        with mock.patch.object(hq, "_request", r), mock.patch.object(V.hq_missions, "create_mission", return_value={"id": "m", "title": "Validate venture: X"}) as cm:
            out = V.start("Ottawa Cleanouts", "Garage cleanouts for homeowners in Ottawa, flat price per load", budget_cents=900000)
        self.assertEqual(out["slug"], "ottawa-cleanouts")
        rpc = [c for c in r.calls if c[1].endswith("create_venture")][0][2]
        self.assertEqual(rpc["p_budget_cents"], 900000)  # the database clamps it to the $50 ceiling
        self.assertIn("planning only", cm.call_args[0][0])
        card = [c[2] for c in r.calls if c[1].endswith("owner_messages")][0]
        self.assertEqual((card["ref_table"], card["needs_decision"]), ("activate_venture:ottawa-cleanouts", True))
        self.assertIn("spends nothing", card["body"])

    def test_start_rejects_thin_input_and_reports_db_failure(self):
        self.assertIn("name", V.start("x", "short")["error"])
        with mock.patch.object(hq, "_request", Rec(fail="create_venture")):
            self.assertIn("error", V.start("Real Venture", "A long enough description of the idea"))

    def test_approving_the_card_activates_as_owner(self):
        calls = []

        def req(method, path, body=None, timeout=30, prefer=None):
            calls.append((method, path, body))
            if "owner_messages" in path and method == "PATCH":
                return [{"id": "m1", "ref_table": "activate_venture:ottawa-cleanouts", "ref_id": None, "body": "x"}]
        with mock.patch.object(hq, "_request", req):
            C.apply_decision("m1", True)
        act = [b for m, p, b in calls if p.endswith("activate_venture")][0]
        self.assertEqual((act["p_slug"], act["p_by"]), ("ottawa-cleanouts", "owner:telegram"))
        calls.clear()
        with mock.patch.object(hq, "_request", req):
            C.apply_decision("m1", False)
        self.assertFalse([1 for m, p, b in calls if p.endswith("activate_venture")])

    def test_workspace_text_and_missing(self):
        w = {"name": "OC", "status": "active", "stage": "validate", "manager": "oc-manager", "monthly_budget_cents": 5000, "ai_spend_30d_cents": 120,
             "in_cents": 0, "out_cents": 0, "agents": 1, "leads": 0, "memory": 2, "missions_live": 1,
             "goals": [{"status": "open", "metric": "jobs", "current": None, "target": 10, "unit": "jobs"}]}
        with mock.patch.object(hq, "_request", lambda *a, **k: w):
            t = V.workspace_text("oc")
        self.assertIn("$50.00/month", t); self.assertIn("Goal [open]: jobs", t)
        with mock.patch.object(hq, "_request", lambda *a, **k: None):
            self.assertIn("No venture", V.workspace_text("zzz"))

    def test_engine_waits_when_venture_is_over_budget(self):
        import hq_engine as E
        E._OVER_BUDGET_CACHE.clear()
        with mock.patch.object(E, "_rpc", return_value=True):
            self.assertTrue(E._venture_over_budget("v1"))
        E._OVER_BUDGET_CACHE.clear()
        with mock.patch.object(E, "_rpc", side_effect=RuntimeError("no fn")):
            self.assertFalse(E._venture_over_budget("v2"))


if __name__ == "__main__":
    unittest.main()
