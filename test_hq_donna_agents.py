"""Tests for hq_donna_agents (Donna Client Agents v1). Retell, database and Telegram are mocked; SQL rules: sqltests/donna_client_agents_check.sql."""
import datetime as dt
import unittest

import hq_donna
import hq_donna_agents as A

HOURS = {d: [["09:00", "17:00"]] for d in ("mon", "tue", "wed", "thu", "fri")} | {"sat": [], "sun": []}
INTAKE = {"intake": "I1", "client_label": "Pine Plumbing", "lead": "L1", "status": "draft", "open_items": ["faqs: confirm"], "agent": None,
          "reception_config": {"business_name": "Pine Plumbing", "timezone": "America/Toronto", "hours": HOURS,
                               "services": [{"name": "Drain cleaning", "price_cents": 14900}, {"name": "Water heater install", "price_cents": 0}],
                               "faqs": [{"q": "Do you do emergencies?", "a": "Yes, 24/7 for burst pipes."}],
                               "escalation_number": "+16135550111", "booking": {"provider": "none", "public_url": ""}, "voice": {}}}


class Spec(unittest.TestCase):
    def test_spec_from_intake_only(self):
        s = A.spec(INTAKE)
        p = s["llm"]["general_prompt"]
        self.assertIn("virtual receptionist for Pine Plumbing", p)
        self.assertIn("Drain cleaning (from $149)", p)
        self.assertIn("; Water heater install.", p, "no price shown when none was given")
        self.assertIn("Do you do emergencies?", p)
        self.assertIn("Never take card details", p)
        self.assertIn("I'm an AI", s["llm"]["begin_message"])
        tools = {t["name"]: t for t in s["llm"]["general_tools"]}
        self.assertEqual(tools["transfer_to_team"]["transfer_destination"]["number"], "+16135550111")
        self.assertEqual(s["agent"]["data_storage_retention_days"], 30)
        self.assertNotIn("webhook_url", s["agent"])

    def test_no_valid_escalation_means_no_transfer(self):
        i = {**INTAKE, "reception_config": {**INTAKE["reception_config"], "escalation_number": "[CLIENT: escalation number E.164]"}}
        self.assertNotIn("transfer_to_team", [t["name"] for t in A.spec(i)["llm"]["general_tools"]])

    def test_code_changes_with_the_intake(self):
        other = {**INTAKE, "reception_config": {**INTAKE["reception_config"], "faqs": []}}
        self.assertNotEqual(A.spec_sha(A.spec(INTAKE)), A.spec_sha(A.spec(other)))
        self.assertIn(A.spec_sha(A.spec(INTAKE))[:6], A.preview(INTAKE))


class Create(unittest.TestCase):
    def setUp(self):
        self.calls, self.recorded = [], []

    def rpc(self, name, args):
        if name == "donna_intake_for_agent":
            return INTAKE
        if name == "donna_record_client_agent":
            self.recorded.append(args)
            return {"agent": "A1"}
        raise AssertionError(name)

    def http(self, method, url, headers, body=None):
        self.calls.append((method, url, body))
        return {"llm_id": "llm_abc123"} if url.endswith("/create-retell-llm") else {"agent_id": "agent_xyz789"}

    def test_preview_never_creates(self):
        out = A.agent_cmd("Pine Plumbing", rpc=self.rpc, env={"RETELL_API_KEY": "k"}, http=self.http)
        self.assertIn("create", out)
        self.assertEqual(self.calls, [])

    def test_wrong_code_refused(self):
        out = A.agent_cmd("Pine Plumbing create 000000", rpc=self.rpc, env={"RETELL_API_KEY": "k"}, http=self.http)
        self.assertIn("doesn't match", out)
        self.assertEqual(self.calls, [])

    def test_create_with_the_code(self):
        code = A.spec_sha(A.spec(INTAKE))[:6]
        out = A.agent_cmd(f"Pine Plumbing create {code}", rpc=self.rpc, env={"RETELL_API_KEY": "k"}, http=self.http)
        self.assertIn("agent_xyz789", out)
        self.assertEqual([u.rsplit("/", 1)[-1] for _, u, _ in self.calls], ["create-retell-llm", "create-agent"])
        self.assertEqual(self.calls[1][2]["response_engine"], {"type": "retell-llm", "llm_id": "llm_abc123"})
        self.assertEqual(self.recorded[0]["p_spec_sha"], A.spec_sha(A.spec(INTAKE)))
        self.assertNotIn("phone-number", " ".join(u for _, u, _ in self.calls), "never buys a number")

    def test_needs_key(self):
        code = A.spec_sha(A.spec(INTAKE))[:6]
        self.assertIn("RETELL_API_KEY", A.agent_cmd(f"Pine Plumbing create {code}", rpc=self.rpc, env={}, http=self.http))


class Report(unittest.TestCase):
    def test_period_and_outside_hours(self):
        period, lo, hi = A._period(dt.date(2026, 12, 2))
        self.assertEqual(period, "2026-11")
        self.assertLess(lo, hi)
        sat = int(dt.datetime(2026, 11, 28, 11, 0, tzinfo=A.R.TZ).timestamp() * 1000)
        tue_night = int(dt.datetime(2026, 11, 24, 21, 0, tzinfo=A.R.TZ).timestamp() * 1000)
        tue_day = int(dt.datetime(2026, 11, 24, 10, 0, tzinfo=A.R.TZ).timestamp() * 1000)
        self.assertTrue(A._outside(sat, HOURS) and A._outside(tue_night, HOURS))
        self.assertFalse(A._outside(tue_day, HOURS))
        calls = [{"call_status": "ended", "start_timestamp": sat, "duration_ms": 120000, "call_analysis": {"custom_analysis_data": {"booked": True, "callback_number": "+1"}}},
                 {"call_status": "ended", "start_timestamp": tue_day, "duration_ms": 60000, "call_analysis": {"custom_analysis_data": {"urgent": True}}},
                 {"call_status": "error", "start_timestamp": tue_day}]
        self.assertEqual(A.stats(calls, HOURS), {"calls": 2, "outside_hours": 1, "booked": 1, "urgent": 1, "messages": 1, "minutes": 3})

    def test_report_email_passes_casl(self):
        s, b = A.report_email("Pine Plumbing", "Pat Lee", "2026-11", {"calls": 40, "outside_hours": 12, "booked": 9, "urgent": 2, "messages": 30, "minutes": 95},
                              "PO Box 1, Ottawa ON")
        self.assertEqual(hq_donna.casl_problems("follow_up_email", s, b), [])
        self.assertIn("November 2026", s)
        self.assertIn("Calls outside your business hours: 12", b)

    def test_run_once_per_month(self):
        class Ctx:
            run_id = "RUN"
            def __init__(s): s.saved = []
            def check(s, a): pass
            def rpc(s, name, args):
                if name == "donna_client_agents":
                    return [{"id": "A1", "client_label": "Pine Plumbing", "lead": "L1", "retell_agent_id": "agent_x", "reception_config": {"hours": HOURS}, "last_report": None},
                            {"id": "A2", "client_label": "Done Co", "lead": "L2", "retell_agent_id": "agent_y", "reception_config": {}, "last_report": "2026-11"}]
                if name == "donna_lead_context":
                    return {"person": "Pat"}
                if name == "donna_save_draft":
                    s.saved.append(args["p_lead"]); return {"draft": "D1"}
                if name == "donna_stage_outbox":
                    return {"outbox": "O1"}
                if name == "donna_record_client_report":
                    return {"report": "R1"}
                raise AssertionError(name)
        ctx = Ctx()
        r = A.client_report_run(ctx, {}, env={"RETELL_API_KEY": "k"}, http=lambda *a, **k: [], address_get=lambda: {"mailing_address": "PO Box 1"},
                                today=dt.date(2026, 12, 1))
        self.assertEqual(ctx.saved, ["L1"], "Done Co already has November's report")
        self.assertEqual(r["period"], "2026-11")
        with self.assertRaises(hq_donna.DonnaRefused):
            A.client_report_run(Ctx(), {}, env={}, http=lambda *a, **k: [])


if __name__ == "__main__":
    unittest.main()
