import io, json, unittest, urllib.error
from unittest import mock
import hq_ffm as F
from hq_workspace import SensitiveDataRefused


def http_err(msg):
    return urllib.error.HTTPError("u", 400, msg, {}, io.BytesIO(json.dumps({"message": msg}).encode()))


WS = {"slug": "t-mortgage", "status": "draft", "vertical": "mortgage", "monthly_budget_cents": None}
ITEMS = [
    {"template_key": "service_geography", "title": "Service geography", "provider": "client", "required": True, "status": "pending", "value_text": None},
    {"template_key": "monthly_budget", "title": "Budget", "provider": "owner", "required": True, "status": "pending", "value_text": None},
    {"template_key": "brand_assets", "title": "Logo", "provider": "client", "required": False, "status": "pending", "value_text": None},
    {"template_key": "booking_link", "title": "Booking link", "provider": "client", "required": True, "status": "provided", "value_text": "https://x.example/book"},
]


class Plan(unittest.TestCase):
    def test_nothing_is_invented(self):
        p = F.onboarding_plan(WS, ITEMS)
        self.assertEqual(p["budget"], "unset")
        vals = {s["key"]: s["value"] for s in p["steps"]}
        self.assertEqual(vals["service_geography"], "unset")
        self.assertEqual(vals["booking_link"], "https://x.example/book")
        self.assertFalse(p["ready_to_activate"])
        self.assertEqual(sorted(p["missing_required"]), ["monthly_budget", "service_geography"])

    def test_actions_split_by_who_and_budget_first(self):
        p = F.onboarding_plan(WS, ITEMS)
        self.assertEqual(p["next_actions"][0]["who"], "owner")
        self.assertIn("budget", p["next_actions"][0]["do"])
        self.assertIn(("client", "Service geography"), [(a["who"], a["do"]) for a in p["next_actions"]])
        self.assertNotIn("Logo", [a["do"] for a in p["next_actions"]])   # optional items are not demanded

    def test_complete_but_unapproved_asks_owner_to_approve(self):
        items = [dict(i, status="provided", value_text="v") for i in ITEMS]
        ws = dict(WS, monthly_budget_cents=1000)
        p = F.onboarding_plan(ws, items, {"owner_approved": False, "ready": False})
        self.assertFalse(p["ready_to_activate"])
        self.assertTrue(any("approve activation" in a["do"] for a in p["next_actions"]))
        p2 = F.onboarding_plan(ws, items, {"owner_approved": True, "ready": True})
        self.assertTrue(p2["ready_to_activate"])
        self.assertEqual(p2["next_actions"], [])

    def test_stale_approval_requests_reapproval(self):
        items = [dict(i, status="provided", value_text="v") for i in ITEMS]
        p = F.onboarding_plan(dict(WS, monthly_budget_cents=1), items, {"owner_approved": False, "approval_stale": True, "ready": False})
        self.assertTrue(any("re-approve" in a["do"] for a in p["next_actions"]))

    def test_placeholder_value_is_not_provided(self):
        it = [dict(ITEMS[0], status="provided", value_text="  ")]
        self.assertEqual(F.onboarding_plan(WS, it)["steps"][0]["status"], "pending")

    def test_plan_lists_what_ai_may_not_touch(self):
        self.assertIn("banking details", F.onboarding_plan(WS, [])["ai_may_not_touch"])


REPORT = {"workspace": "t-mortgage", "from": "2026-11-09T05:00:00+00:00", "to": "2026-11-16T05:00:00+00:00",
          "readiness": {"status": "active", "missing_required": []},
          "funnel": {"leads": 4, "by_stage": {"new": 2, "booked": 1, "lost": 1}},
          "lead_to_booked": {"leads": 4, "booked": 1, "rate": 0.25},
          "spend": {"budget": "set", "budget_cents": 100000, "spent_cents": 25000, "spent_in_period_cents": 10000, "remaining_cents": 75000, "pct_used": 0.25},
          "campaigns_by_status": {"approved": 1, "draft": 2}, "creatives_awaiting_review": 3}


class Report(unittest.TestCase):
    def test_render(self):
        t = F.render_weekly_report(REPORT)
        for s in ["t-mortgage", "New leads in period: 4", "25.0%", "$1,000.00", "$100.00", "$750.00", "approved: 1", "awaiting review: 3"]:
            self.assertIn(s, t)

    def test_unset_budget_is_said_plainly(self):
        r = json.loads(json.dumps(REPORT))
        r["spend"].update(budget="unset", budget_cents=None, remaining_cents=None, pct_used=None)
        r["readiness"] = {"status": "draft", "missing_required": ["booking_link"]}
        t = F.render_weekly_report(r)
        self.assertIn("unset", t)
        self.assertIn("no budget has been set", t)
        self.assertIn("booking_link", t)
        self.assertIn("n/a", t)

    def test_no_leads_no_division(self):
        r = json.loads(json.dumps(REPORT))
        r["lead_to_booked"] = {"leads": 0, "booked": 0, "rate": None}
        r["funnel"] = {"leads": 0, "by_stage": {}}
        self.assertIn("n/a (0 of 0)", F.render_weekly_report(r))
        self.assertIsNone(F.cost_per_booked(r))

    def test_cost_per_booked(self):
        self.assertEqual(F.cost_per_booked(REPORT), 10000)

    def test_report_has_no_lead_level_fields(self):
        t = F.render_weekly_report(REPORT)
        self.assertNotIn("@", t)


class Wrappers(unittest.TestCase):
    def test_activation_refusal_is_typed(self):
        with mock.patch.object(F, "_rpc", side_effect=http_err("activation refused: no owner approval")):
            with self.assertRaises(F.ActivationRefused):
                F.activate("w")

    def test_owner_only_is_typed(self):
        with mock.patch.object(F, "_rpc", side_effect=http_err("owner approval required: this action is refused for the bot")):
            with self.assertRaises(F.OwnerActionRequired):
                F._call("ffm_set_budget", {})

    def test_sensitive_value_stopped_before_database(self):
        with mock.patch("hq_ffm.screen", side_effect=SensitiveDataRefused("banking")), mock.patch.object(F, "_rpc") as m:
            with self.assertRaises(SensitiveDataRefused):
                F.provide_input("w", "crm_destination", "bank statement", "moe")
        m.assert_not_called()

    def test_database_sensitive_refusal_is_typed(self):
        with mock.patch("hq_ffm.screen"), mock.patch.object(F, "_rpc", side_effect=http_err("Sensitive data refused in ffm_onboarding_items.value_text (banking)")):
            with self.assertRaises(SensitiveDataRefused):
                F.provide_input("w", "k", "v", "moe")

    def test_other_errors_not_swallowed(self):
        with mock.patch.object(F, "_rpc", side_effect=http_err("workspace not found or not open")):
            with self.assertRaises(urllib.error.HTTPError):
                F.start_onboarding("w")

    def test_weekly_text_is_screened(self):
        with mock.patch.object(F, "_rpc", return_value=REPORT), mock.patch("hq_ffm.screen") as sc:
            t = F.weekly_report_text("w")
        sc.assert_called_once_with(t)

    def test_plan_for_uses_rows(self):
        def get(path):
            return [WS] if "client_workspaces" in path else ITEMS
        with mock.patch.object(F, "_get", side_effect=get), mock.patch.object(F, "_rpc", return_value={"owner_approved": False, "ready": False}):
            self.assertEqual(F.plan_for("w")["workspace"], "t-mortgage")
        with mock.patch.object(F, "_get", return_value=[]):
            with self.assertRaises(LookupError):
                F.plan_for("w")


if __name__ == "__main__":
    unittest.main()
