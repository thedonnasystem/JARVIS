"""Tests for hq_donna_revenue (Donna Revenue Loop v1). Network, database and Telegram are mocked; the SQL rules are in sqltests/donna_revenue_loop_check.sql."""
import datetime as dt
import os
import re
import unittest

import hq_donna
import hq_donna_revenue as R

ADDR = "PO Box 123, Ottawa ON K1A 0A1"
LEAK = ("Leak estimate $3,428/month, $41,136/year. Avg value $250, close rate 30%. calls: $1,624/mo (5); leads: $300/mo (4); quotes: $225/mo (3); "
        "noshows: $500/mo (2); admin: $779/mo (6)")


def ctx_lead(**k):
    base = {"lead": "L1", "short_id": 12, "business": "Al's Diner", "person": "Al Smith", "status": "new", "source": "donna:website_form", "has_email": True,
            "do_not_contact": False, "consent_basis": "implied_inquiry", "sent": 0,
            "inbound": {"source": "website_form", "booked": False, "appointment": None, "leak_estimate": LEAK, "summary": "wants calls answered"}}
    base.update(k)
    return base


class FakeCtx:
    def __init__(self, contexts=None, stage_error=None, save_error=None):
        self.run_id, self.calls, self.checked = "RUN", [], []
        self.contexts, self.stage_error, self.save_error = contexts or {}, stage_error, save_error

    def check(self, action):
        self.checked.append(action)

    def rpc(self, name, args):
        self.calls.append((name, args))
        if name == "donna_lead_context":
            return self.contexts[args["p_lead"]]
        if name == "donna_save_draft":
            if self.save_error:
                raise RuntimeError(self.save_error)
            return {"draft": "D-" + args["p_lead"]}
        if name == "donna_stage_outbox":
            if self.stage_error:
                raise RuntimeError(self.stage_error)
            return {"outbox": "O-" + args["p_draft"], "duplicate": False}
        if name == "donna_save_brief":
            return {"brief": "B-" + args["p_lead"]}
        raise AssertionError(name)


class InboundSources(unittest.TestCase):
    def test_netlify_mapping_spam_and_other_forms(self):
        rows = [
            {"id": "abc123", "form_name": "donna-contact", "created_at": "2026-11-26T15:00:00Z",
             "data": {"name": "Al Smith", "business": "Al's Diner", "email": "al@alsdiner.example", "phone": "613-555-0101", "message": "help",
                      "marketing_consent": "yes", "consent_version": "webstudio-consent-v1", "leak_estimate": LEAK}},
            {"id": "spam1", "form_name": "donna-contact", "created_at": "2026-11-26T15:00:00Z", "data": {"name": "x", "bot-field": "http://spam"}},
            {"id": "other1", "form_name": "newsletter", "created_at": "2026-11-26T15:00:00Z", "data": {"email": "a@b.example"}},
            {"id": "noconsent", "form_name": "donna-contact", "created_at": "2026-11-26T15:00:00Z", "data": {"name": "B", "email": "b@b.example", "consent_version": "v9"}},
        ]
        seen = {}
        def http(method, url, headers, body=None):
            seen.update(method=method, url=url, auth=headers.get("Authorization"))
            return rows
        out = R.netlify_items({"NETLIFY_TOKEN": "tok", "NETLIFY_SITE_ID": "site-1"}, http)
        self.assertEqual(seen["url"], "https://api.netlify.com/api/v1/sites/site-1/submissions?per_page=100")
        self.assertEqual(seen["auth"], "Bearer tok")
        self.assertEqual([o["p_ref"] for o in out], ["nf-abc123", "nf-noconsent"])
        a, b = out
        self.assertTrue(a["p_marketing_consent"])
        self.assertEqual(a["p_consent_version"], "webstudio-consent-v1")
        self.assertEqual((a["p_source"], a["p_person"], a["p_business"], a["p_booked"]), ("website_form", "Al Smith", "Al's Diner", False))
        self.assertEqual(a["p_leak_estimate"], LEAK)
        self.assertFalse(b["p_marketing_consent"])
        self.assertIsNone(b["p_consent_version"], "a version without the ticked box is never sent as consent")

    def test_netlify_needs_credentials(self):
        self.assertEqual(R.netlify_items({}, lambda *a, **k: self.fail("no call without credentials")), [])

    def test_retell_mapping_and_filters(self):
        calls = [
            {"call_id": "call_1", "agent_id": "agent_web", "call_type": "web_call", "call_status": "ended", "start_timestamp": 1764169200000,
             "call_analysis": {"call_summary": "Owner of a plumbing shop.", "custom_analysis_data": {"caller_name": "Pat", "business_name": "Pine Plumbing",
                               "email": "pat@pine.example", "booked": True, "appointment_time": "Thu 2 pm", "main_problem": "misses calls on jobs"}}},
            {"call_id": "call_2", "agent_id": "agent_demo", "call_type": "phone_call", "call_status": "ended", "from_number": "+16135550199", "start_timestamp": 1764169200000,
             "call_analysis": {"call_summary": "Asked about prices.", "custom_analysis_data": {"caller_name": "Sam"}}},
            {"call_id": "call_3", "agent_id": "agent_web", "call_type": "web_call", "call_status": "ongoing", "call_analysis": {}},
            {"call_id": "call_4", "agent_id": "someone_else", "call_type": "phone_call", "call_status": "ended", "call_analysis": {"call_summary": "x"}},
        ]
        sent = {}
        def http(method, url, headers, body=None):
            sent.update(method=method, url=url, body=body)
            return calls
        out = R.retell_items({"RETELL_API_KEY": "k", "DONNA_AGENT_IDS": "agent_web, agent_demo"}, http)
        self.assertEqual((sent["method"], sent["url"]), ("POST", "https://api.retellai.com/v2/list-calls"))
        self.assertEqual(sent["body"]["filter_criteria"], {"agent_id": ["agent_web", "agent_demo"]})
        self.assertEqual([o["p_ref"] for o in out], ["rc-call_1", "rc-call_2"])
        web, phone = out
        self.assertEqual((web["p_source"], web["p_booked"], web["p_appointment"], web["p_phone"]), ("web_call", True, "Thu 2 pm", None))
        self.assertIn("misses calls on jobs", web["p_summary"])
        self.assertEqual((phone["p_source"], phone["p_phone"], phone["p_booked"]), ("phone_call", "+16135550199", False))
        self.assertFalse(any(o["p_marketing_consent"] for o in out), "a call is never express consent")
        self.assertTrue(web["p_received_at"].startswith("2025-11-26") or web["p_received_at"].startswith("2026-"))

    def test_http_only_two_hosts(self):
        for url in ("https://evil.example/x", "http://api.netlify.com/api", "https://api.netlify.com.evil.example/"):
            with self.assertRaises(R.RevenueError):
                R.http_json("GET", url, {})

    def test_sync_off_by_default_and_one_source_down(self):
        self.assertIn("off", R.sync(rpc=lambda *a: self.fail("off means no database call"), env={}))
        got = []
        def http(method, url, headers, body=None):
            if "netlify" in url:
                raise OSError("down")
            return [{"call_id": "c9", "call_type": "phone_call", "call_status": "ended", "from_number": "+16135550100", "start_timestamp": 1764169200000,
                     "call_analysis": {"call_summary": "hi"}}]
        def rpc(name, args):
            got.append(args)
            return {"new_lead": True, "lead": "L9", "status": "new", "contactable": True}
        r = R.sync(rpc=rpc, env={"DONNA_INBOUND": "1", "NETLIFY_TOKEN": "t", "NETLIFY_SITE_ID": "s", "RETELL_API_KEY": "k"}, http=http)
        self.assertEqual(r["errors"], ["netlify: OSError"])
        self.assertEqual(len(r["new"]), 1)
        self.assertEqual(got[0]["p_ref"], "rc-c9")

    def test_sync_counts_duplicates_and_updates(self):
        answers = iter([{"duplicate": True}, {"new_lead": False, "lead": "L1"}, RuntimeError("refused: bad inbound ref")])
        def rpc(name, args):
            a = next(answers)
            if isinstance(a, Exception):
                raise a
            return a
        items = [{"p_received_at": "2026-11-26T15:00:00Z", "p_ref": f"nf-{i}"} for i in range(3)] + [{"p_received_at": None, "p_ref": "nf-x"}]
        orig = R.netlify_items
        R.netlify_items = lambda env, http: items
        try:
            r = R.sync(rpc=rpc, env={"DONNA_INBOUND": "1"})
        finally:
            R.netlify_items = orig
        self.assertEqual((r["duplicate"], r["updated"], r["skipped"], len(r["errors"])), (1, 1, 1, 1))


class Templates(unittest.TestCase):
    def test_leaks_parse_only_their_numbers(self):
        lk = R.leaks(LEAK)
        self.assertEqual(lk["total"], 342800)
        self.assertEqual(lk["parts"], {"calls": 162400, "leads": 30000, "quotes": 22500, "noshows": 50000, "admin": 77900})
        self.assertEqual(R.leaks(None), {"total": None, "parts": {}})

    def test_reply_not_booked_passes_casl_and_keeps_the_hook(self):
        s, b = R.reply_email(ctx_lead(), ADDR, env={}, today=dt.date(2026, 11, 26))
        self.assertEqual(hq_donna.casl_problems("follow_up_email", s, b), [])
        self.assertIn("We turn your missed calls and missed leads into booked appointments.", b)
        self.assertIn("about $3,428 a month", b)
        self.assertIn("Hi Al,", b)
        self.assertIn(ADDR, b)
        self.assertIn("setup is free", b)
        self.assertIn("Reply with two or three times", b)

    def test_reply_booked_and_booking_link(self):
        c = ctx_lead(inbound={"source": "web_call", "booked": True, "appointment": "Thu 2 pm", "leak_estimate": None})
        s, b = R.reply_email(c, ADDR, env={"DONNA_BOOKING_URL": "https://cal.com/donna/audit"}, today=dt.date(2026, 11, 26))
        self.assertIn("Thu 2 pm", s)
        self.assertIn("Thanks for booking", b)
        self.assertEqual(hq_donna.casl_problems("follow_up_email", s, b), [])
        s2, b2 = R.reply_email(ctx_lead(), ADDR, env={"DONNA_BOOKING_URL": "https://cal.com/donna/audit"}, today=dt.date(2026, 11, 26))
        self.assertIn("https://cal.com/donna/audit", b2)
        _, b3 = R.reply_email(ctx_lead(), ADDR, env={"DONNA_BOOKING_URL": "javascript:alert(1)"}, today=dt.date(2026, 11, 26))
        self.assertNotIn("javascript:", b3)

    def test_deadline_is_real(self):
        _, b = R.reply_email(ctx_lead(), ADDR, env={}, today=dt.date(2027, 1, 1))
        self.assertNotIn("setup is free", b.lower())
        _, p = R.proposal_email(ctx_lead(), "growth", 79700, [], ADDR, today=dt.date(2027, 1, 1))
        self.assertNotIn("Setup is free", p)

    def test_placeholder_without_address(self):
        _, b = R.reply_email(ctx_lead(), R.mailing_address(lambda: None), env={})
        self.assertIn("[OWNER: mailing address]", b)

    def test_followups_pass_casl_and_stop_at_three(self):
        for step in (2, 3):
            s, b = R.followup_email(ctx_lead(), step, ADDR, env={}, today=dt.date(2026, 11, 26))
            self.assertEqual(hq_donna.casl_problems("follow_up_email", s, b), [], (step, b))
        self.assertIn("last note", R.followup_email(ctx_lead(), 3, ADDR, env={})[1])

    def test_proposal_owner_price_and_no_payment_or_signature(self):
        s, b = R.proposal_email(ctx_lead(), "front-desk", 49700, ["Misses about 6 calls a week", "No after-hours answering"], ADDR, today=dt.date(2026, 11, 26))
        self.assertEqual(hq_donna.casl_problems("follow_up_email", s, b), [])
        self.assertIn("$497 a month, month-to-month", b)
        self.assertIn("- Misses about 6 calls a week", b)
        self.assertIn("AI receptionist that answers every call", b)
        self.assertEqual(hq_donna.casl_problems("cold_email", s, b), [], "the strict first-touch rules pass too")
        with self.assertRaises(R.RevenueError):
            R.proposal_email(ctx_lead(), "platinum", 49700, [], ADDR)
        with self.assertRaises(R.RevenueError):
            R.proposal_email(ctx_lead(), "essential", 9900, [], ADDR)
        with self.assertRaises(R.RevenueError):
            R.proposal_email(ctx_lead(), "growth", 99, [], ADDR)

    def test_brief_fit_and_questions(self):
        t = R.audit_brief(ctx_lead(inbound={"source": "website_form", "booked": True, "appointment": "Thu 2 pm", "leak_estimate": LEAK, "summary": "s"}))
        self.assertIn("$3,428/month", t)
        self.assertIn("Likely fit: Front Desk (biggest leaks: missed calls, busywork)", t)
        self.assertIn("How many calls a week", t)
        self.assertIn("/donna proposal 12", t)
        self.assertIn("Their numbers, not ours", t)
        one = R.audit_brief(ctx_lead(inbound={"booked": True, "leak_estimate": "Leak estimate $900/month. admin: $900/mo (6)"}))
        self.assertIn("Likely fit: Essential (plug busywork first)", one)
        none = R.audit_brief(ctx_lead(inbound={"booked": True}))
        self.assertIn("No leak check from them", none)


class Modes(unittest.TestCase):
    def test_inbound_reply_saves_and_stages(self):
        ctx = FakeCtx({"L1": ctx_lead(), "L2": ctx_lead(lead="L2", do_not_contact=True)})
        r = R.outreach_mode(ctx, {"mode": "inbound_reply", "lead_ids": ["L1", "L2"]}, address_get=lambda: {"mailing_address": ADDR}, env={})
        self.assertEqual(ctx.checked, ["draft_outreach"])
        ok, dnc = r["results"]
        self.assertEqual((ok["draft"], ok["outbox"], ok["new"], ok["purpose"]), ("D-L1", "O-D-L1", True, "inbound_reply"))
        self.assertIn("do-not-contact", dnc["refused"])
        save = [a for n, a in ctx.calls if n == "donna_save_draft"][0]
        self.assertEqual((save["p_kind"], save["p_channel"]), ("follow_up_email", "email"))
        self.assertEqual(r["sent"], 0)

    def test_not_staged_is_reported(self):
        ctx = FakeCtx({"L1": ctx_lead()}, stage_error="refused: the draft still has an [OWNER: ...] placeholder")
        r = R.outreach_mode(ctx, {"mode": "follow_up", "targets": [{"lead": "L1", "step": 2}]}, address_get=lambda: None, env={})
        self.assertIn("placeholder", r["results"][0]["not_staged"])
        self.assertNotIn("outbox", r["results"][0])

    def test_proposal_mode_and_unknown_mode(self):
        ctx = FakeCtx({"L1": ctx_lead()})
        r = R.outreach_mode(ctx, {"mode": "proposal", "lead": "L1", "package": "growth", "monthly_cents": 79700, "findings": ["x"]},
                            address_get=lambda: {"mailing_address": ADDR}, env={})
        self.assertEqual(r["results"][0]["purpose"], "proposal")
        with self.assertRaises(hq_donna.DonnaRefused):
            R.outreach_mode(FakeCtx(), {"mode": "blast"})

    def test_brief_mode(self):
        ctx = FakeCtx({"L1": ctx_lead()})
        r = R.audit_brief_run(ctx, {"lead_ids": ["L1"]})
        self.assertEqual(ctx.checked, ["draft_offer"])
        self.assertEqual(r["results"][0]["brief"], "B-L1")

    def test_hq_donna_dispatches_modes(self):
        seen = []
        orig_o, orig_b = R.outreach_mode, R.audit_brief_run
        R.outreach_mode = lambda ctx, inputs: seen.append(("o", inputs["mode"])) or {}
        R.audit_brief_run = lambda ctx, inputs: seen.append(("b", inputs["mode"])) or {}
        try:
            hq_donna.outreach_prep(FakeCtx(), {"mode": "follow_up"})
            hq_donna.offer_pricing(FakeCtx(), {"mode": "audit_brief"})
        finally:
            R.outreach_mode, R.audit_brief_run = orig_o, orig_b
        self.assertEqual(seen, [("o", "follow_up"), ("b", "audit_brief")])


class Tick(unittest.TestCase):
    def test_autodraft_off_and_dormant(self):
        quiet = {"DONNA_INBOUND": "0"}
        self.assertIn("autodraft", R.tick_once(rpc=lambda *a: {}, env=quiet))
        r = R.tick_once(rpc=lambda n, a: {"active": False} if n == "donna_revenue_queue" else [], env={"DONNA_AUTODRAFT": "1"},
                        runner=lambda *a: self.fail("dormant: no run"))
        self.assertEqual(r["autodraft"], "Donna is dormant")

    def test_active_runs_and_announces(self):
        def rpc(name, args):
            if name == "donna_revenue_queue":
                return {"active": True, "reply_needed": ["L1"], "brief_needed": ["L2"]}
            if name == "donna_followups_due":
                return [{"lead": "L3", "step": 2}]
            raise AssertionError(name)
        runs = []
        def runner(mission, inputs):
            runs.append((mission, inputs["mode"]))
            if inputs["mode"] == "audit_brief":
                return {"ok": True, "result": {"results": [{"lead": "L2", "brief": "B", "text": "Audit brief: x"}]}}
            return {"ok": True, "result": {"results": [{"lead": "L", "outbox": "O1", "new": True, "purpose": inputs["mode"]},
                                                       {"lead": "L", "outbox": "O0", "new": False, "purpose": inputs["mode"]}]}}
        approved, briefs = [], []
        r = R.tick_once(rpc=rpc, env={"DONNA_AUTODRAFT": "1"}, runner=runner, approve=lambda o, label: approved.append((o, label)) or "M",
                        brief=lambda t: briefs.append(t))
        self.assertEqual(runs, [("outreach-prep", "inbound_reply"), ("offer-pricing", "audit_brief"), ("outreach-prep", "follow_up")])
        self.assertEqual(len(approved), 2, "only NEWLY staged drafts are posted")
        self.assertEqual(briefs, ["Audit brief: x"])
        self.assertEqual(r["messages"], 3)

    def test_tick_never_raises(self):
        r = R.tick_once(rpc=lambda n, a: (_ for _ in ()).throw(RuntimeError("db down")), env={"DONNA_AUTODRAFT": "1"})
        self.assertIn("queue", r["error"])


class Commands(unittest.TestCase):
    def test_parse_proposal(self):
        p = R.parse_proposal("#12 growth $797 | misses 6 calls a week; quotes never chased")
        self.assertEqual(p, {"short_id": 12, "package": "growth", "monthly_cents": 79700, "findings": ["misses 6 calls a week", "quotes never chased"]})
        with self.assertRaises(R.RevenueError):
            R.parse_proposal("12 gold 797")

    def test_proposal_cmd(self):
        get = lambda path: [{"id": "L12", "ventures": {"slug": "donna"}}]
        posted = []
        runner = lambda m, i: {"ok": True, "result": {"results": [{"outbox": "O9", "new": True, "purpose": "proposal"}]}}
        out = R.proposal_cmd("12 essential 197 | one leak", get=get, runner=runner, approve=lambda o, l: posted.append(o))
        self.assertIn("Proposal drafted", out)
        self.assertEqual(posted, ["O9"])
        other = R.proposal_cmd("12 essential 197", get=lambda p: [{"id": "X", "ventures": {"slug": "wolf-squad"}}], runner=runner)
        self.assertIn("No Donna lead", other)
        blocked = R.proposal_cmd("12 essential 197", get=get, runner=lambda m, i: {"ok": True, "result": {"results": [{"not_staged": "no address"}]}})
        self.assertIn("not ready to send: no address", blocked)

    def test_brief_cmd_validates(self):
        self.assertIn("Use:", R.brief_cmd("abc"))


class Static(unittest.TestCase):
    def test_no_send_pay_sign_or_deploy_path(self):
        with open(os.path.join(os.path.dirname(__file__), "hq_donna_revenue.py")) as f:
            src = f.read()
        for bad in ("resend", "stripe", "deliver_approved", "send_prepared", "hq_invoices", "hq_payments", "hq_webstudio.deploy", "twilio", "status\": \"approved",
                    "app_set_kill", "office_os_activate", "hq_llm"):
            self.assertNotIn(bad, src.lower(), bad)
        self.assertFalse(re.search(r"PATCH[^\n]*outbox", src), "never changes an outbox row: the owner's decision does")


if __name__ == "__main__":
    unittest.main()
