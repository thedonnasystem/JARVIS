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
        self.assertEqual(sent["body"]["filter_criteria"]["agent_id"], ["agent_web", "agent_demo"])
        self.assertIn("lower_threshold", sent["body"]["filter_criteria"]["start_timestamp"], "only the last 3 days are pulled")
        self.assertEqual([o["p_ref"] for o in out], ["rc-call_1", "rc-call_2"])
        web, phone = out
        self.assertEqual((web["p_source"], web["p_booked"], web["p_appointment"], web["p_phone"]), ("web_call", True, "Thu 2 pm", None))
        self.assertIn("misses calls on jobs", web["p_summary"])
        self.assertEqual((phone["p_source"], phone["p_phone"], phone["p_booked"]), ("phone_call", "+16135550199", False))
        self.assertFalse(any(o["p_marketing_consent"] for o in out), "a call is never express consent")
        self.assertTrue(web["p_received_at"].startswith("2025-11-26") or web["p_received_at"].startswith("2026-"))

    def test_calcom_only_the_audit_event_type(self):
        bookings = {"status": "success", "data": [
            {"uid": "aud1", "status": "accepted", "eventTypeId": 77, "eventType": {"id": 77, "slug": "revenue-leak-audit"}, "start": "2026-12-03T15:00:00.000Z",
             "createdAt": "2026-11-27T14:00:00.000Z", "attendees": [{"name": "Pat Lee", "email": "pat@pine.example", "phoneNumber": "613 555 0142"}],
             "bookingFieldsResponses": {"name": "Pat Lee", "email": "pat@pine.example", "business": "Pine Plumbing", "notes": "We miss calls on jobs"}},
            {"uid": "dentist", "status": "accepted", "eventTypeId": 5, "eventType": {"id": 5, "slug": "personal"}, "start": "2026-12-04T15:00:00Z",
             "createdAt": "2026-11-27T14:00:00Z", "attendees": [{"name": "Me", "email": "me@example.com"}]},
            {"uid": "gone", "status": "cancelled", "eventTypeId": 77, "eventType": {"id": 77, "slug": "revenue-leak-audit"}, "start": "2026-12-05T15:00:00Z",
             "createdAt": "2026-11-27T14:00:00Z", "attendees": [{"name": "X", "email": "x@example.com"}]},
            {"uid": "", "status": "accepted", "eventTypeId": 77, "createdAt": "2026-11-27T14:00:00Z"}]}
        sent = {}
        def http(method, url, headers, body=None):
            sent.update(method=method, url=url, headers=headers)
            return bookings
        env = {"CALCOM_API_KEY": "cal_live_x", "DONNA_BOOKING_URL": "https://cal.com/donna-ai/revenue-leak-audit"}
        out = R.calcom_items(env, http)
        self.assertEqual((sent["method"], sent["url"]), ("GET", "https://api.cal.com/v2/bookings?status=upcoming&take=100"))
        self.assertEqual(sent["headers"]["cal-api-version"], "2024-08-13")
        self.assertEqual([o["p_ref"] for o in out], ["cal-aud1"], "only the audit event type, never the owner's other bookings or a cancelled one")
        b = out[0]
        self.assertEqual((b["p_source"], b["p_booked"], b["p_marketing_consent"], b["p_consent_version"]), ("booking", True, False, None))
        self.assertEqual((b["p_person"], b["p_business"], b["p_email"], b["p_phone"]), ("Pat Lee", "Pine Plumbing", "pat@pine.example", "613 555 0142"))
        self.assertEqual(b["p_appointment"], "Thu Dec 3, 10 AM")
        self.assertEqual(b["p_summary"], "We miss calls on jobs")
        self.assertEqual([o["p_ref"] for o in R.calcom_items({"CALCOM_API_KEY": "k", "DONNA_CALCOM_EVENT_TYPE_IDS": "5"}, http)], ["cal-dentist"])
        self.assertEqual(R.calcom_items({"CALCOM_API_KEY": "k"}, http), [], "no audit event type known: nothing is pulled")
        self.assertEqual(R.calcom_items({"CALCOM_API_KEY": "k", "DONNA_BOOKING_URL": "https://calendly.com/x/y"}, http), [])
        self.assertEqual(R.calcom_items({"DONNA_BOOKING_URL": env["DONNA_BOOKING_URL"]}, http), [], "no key: nothing")
        self.assertIn("api.cal.com", R.HOSTS)

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
            return [{"call_id": "c9", "call_type": "phone_call", "call_status": "ended", "from_number": "+16135550100",
                     "start_timestamp": int(dt.datetime.now(dt.timezone.utc).timestamp() * 1000) - 3600000,
                     "call_analysis": {"call_summary": "hi"}}]
        def rpc(name, args):
            got.append(args)
            return {"new_lead": True, "lead": "L9", "status": "new", "contactable": True}
        r = R.sync(rpc=rpc, env={"DONNA_INBOUND": "1", "NETLIFY_TOKEN": "t", "NETLIFY_SITE_ID": "s", "RETELL_API_KEY": "k"}, http=http)
        self.assertEqual(r["errors"], ["netlify: OSError"])
        self.assertEqual(len(r["new"]), 1)
        self.assertEqual(got[0]["p_ref"], "rc-c9")

    def test_sync_skips_old_and_remembers_seen(self):
        R._SEEN.clear()
        now = dt.datetime(2026, 11, 27, 12, tzinfo=dt.timezone.utc)
        items = [{"p_source": "website_form", "p_ref": "nf-new1", "p_received_at": "2026-11-27T10:00:00Z"},
                 {"p_source": "website_form", "p_ref": "nf-old1", "p_received_at": "2026-11-01T10:00:00Z"}]
        calls = []
        orig = R.netlify_items
        R.netlify_items = lambda env, http: items
        try:
            R.sync(rpc=lambda n, a: calls.append(a["p_ref"]) or {"duplicate": True}, env={"DONNA_INBOUND": "1"}, now=now)
            R.sync(rpc=lambda n, a: calls.append(a["p_ref"]) or {"duplicate": True}, env={"DONNA_INBOUND": "1"}, now=now)
        finally:
            R.netlify_items = orig
            R._SEEN.clear()
        self.assertEqual(calls, ["nf-new1"], "old items skipped; a seen ref is never sent to the database twice")

    def test_sync_counts_duplicates_and_updates(self):
        answers = iter([{"duplicate": True}, {"new_lead": False, "lead": "L1"}, RuntimeError("refused: bad inbound ref")])
        def rpc(name, args):
            a = next(answers)
            if isinstance(a, Exception):
                raise a
            return a
        R._SEEN.clear()
        recent = dt.datetime.now(dt.timezone.utc).isoformat()
        items = [{"p_source": "website_form", "p_received_at": recent, "p_ref": f"nf-{i}"} for i in range(3)] + [{"p_source": "website_form", "p_received_at": None, "p_ref": "nf-x"}]
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
        ctx = FakeCtx({"L1": ctx_lead()}, stage_error="refused: the lead is do-not-contact")
        r = R.outreach_mode(ctx, {"mode": "follow_up", "targets": [{"lead": "L1", "step": 2}]}, address_get=lambda: {"mailing_address": ADDR}, env={})
        self.assertIn("do-not-contact", r["results"][0]["not_staged"])
        self.assertNotIn("outbox", r["results"][0])

    def test_no_address_no_draft(self):
        ctx = FakeCtx({"L1": ctx_lead()})
        with self.assertRaises(hq_donna.DonnaRefused) as e:
            R.outreach_mode(ctx, {"mode": "inbound_reply", "lead_ids": ["L1"]}, address_get=lambda: None, env={})
        self.assertIn("/setaddress", str(e.exception))
        self.assertFalse([n for n, _ in ctx.calls if n == "donna_save_draft"], "no draft that could block a later reply")

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

    def test_cold_drafting_once_a_day(self):
        runs = []
        def rpc(name, args):
            if name == "donna_revenue_queue":
                return {"active": True, "prospects_ready": ["P1", "P2"], "cold_run_today": False}
            return []
        R.tick_once(rpc=rpc, env={"DONNA_AUTODRAFT": "1"}, runner=lambda m, i: runs.append((m, i)) or {"ok": True, "result": {}})
        (m, inp), = runs
        self.assertEqual((m, inp["channels"], inp["lead_ids"]), ("outreach-prep", ["email"], ["P1", "P2"]))
        self.assertTrue(inp["offer"].startswith(R.rev()["hook"]), "the first email is about the owner's own hook, not the old receptionist-only line")
        runs.clear()
        def rpc2(name, args):
            if name == "donna_revenue_queue":
                return {"active": True, "prospects_ready": ["P1"], "cold_run_today": True}
            return []
        R.tick_once(rpc=rpc2, env={"DONNA_AUTODRAFT": "1"}, runner=lambda m, i: runs.append((m, i)) or {"ok": True})
        self.assertEqual(runs, [], "already drafted today")

    def test_tick_never_raises(self):
        r = R.tick_once(rpc=lambda n, a: (_ for _ in ()).throw(RuntimeError("db down")), env={"DONNA_AUTODRAFT": "1"})
        self.assertIn("queue", r["error"])


class ColdOffer(unittest.TestCase):
    def test_hook_leaks_audit_real_price_and_real_deadline(self):
        before = R.cold_offer(dt.date(2026, 12, 31))
        self.assertIn("We turn your missed calls and missed leads into booked appointments.", before)
        self.assertIn("Not every business needs an AI receptionist", before)
        self.assertIn("Revenue Leak Audit", before)
        self.assertIn("Plans from $197 a month", before)
        self.assertIn("setup is free", before)
        self.assertNotIn("setup is free", R.cold_offer(dt.date(2027, 1, 1)), "the deadline is real: gone the day after")
        self.assertLessEqual(len(before), 600)


class Cold(unittest.TestCase):
    def test_stage_cold_caps_and_filters(self):
        drafts = [{"id": f"D{i}", "kind": "cold_email", "channel": "email", "lead": f"L{i}", "created_at": f"2026-11-26T10:0{i}"} for i in range(8)]
        drafts += [{"id": "DM", "kind": "dm", "channel": "dm", "lead": "LX", "created_at": "2026-11-26T09:00"},
                   {"id": "TPL", "kind": "cold_email", "channel": "email", "lead": None, "created_at": "2026-11-26T09:00"}]
        staged = []
        def rpc(name, args):
            if name == "donna_revenue_queue":
                return {"active": True, "cold_staged_today": 17}
            if name == "donna_drafts":
                return drafts
            if name == "donna_stage_outbox":
                staged.append(args["p_draft"])
                if args["p_draft"] == "D0":
                    raise RuntimeError("refused: the lead is do-not-contact")
                return {"outbox": "O" + args["p_draft"], "duplicate": False}
            raise AssertionError(name)
        posted = []
        r = R.stage_cold(rpc, approve=lambda o, label: posted.append((o, label)) or "M")
        self.assertEqual(r["staged"], 3, "20 a day, 17 already staged today")
        self.assertEqual(staged, ["D0", "D1", "D2", "D3"], "oldest first; dm and lead-less templates are never staged")
        self.assertEqual(len(r["refused"]), 1)
        self.assertTrue(all("first email to a prospect" in l for _, l in posted))

    def test_unstaged_follow_ups_are_retried_without_cap(self):
        drafts = [{"id": "F1", "kind": "follow_up_email", "channel": "email", "lead": "L1", "created_at": "2026-11-26T10:00"}]
        def rpc(name, args):
            if name == "donna_revenue_queue":
                return {"active": True, "cold_staged_today": 20}
            if name == "donna_drafts":
                return drafts
            return {"outbox": "OF1", "duplicate": False}
        posted = []
        r = R.stage_cold(rpc, approve=lambda o, label: posted.append(label) or "M")
        self.assertEqual((r["staged"], r["posted"]), (0, 1))
        self.assertIn("Donna drafted an email", posted[0])

    def test_stage_cold_dormant_or_full(self):
        self.assertEqual(R.stage_cold(lambda n, a: {"active": False})["staged"], 0)
        self.assertEqual(R.stage_cold(lambda n, a: {"active": True, "cold_staged_today": 20} if n == "donna_revenue_queue" else [])["room"], 0)

    def test_fill_footer(self):
        c = hq_donna.config()
        body = "Hi.\n\n" + hq_donna.casl_footer("cold_email", c)
        self.assertIn("[OWNER: mailing address]", R.fill_footer(body, c, get=lambda: None))
        filled = R.fill_footer(body, c, get=lambda: {"mailing_address": ADDR})
        self.assertIn(f"Mailing address: {ADDR}", filled)
        self.assertIn("Contact: thedonnasystem@gmail.com", filled)
        self.assertNotIn("[OWNER:", filled)
        self.assertEqual(hq_donna.casl_problems("cold_email", "Missed calls at Al's Diner", filled), [])


class Commands(unittest.TestCase):
    def test_parse_proposal(self):
        p = R.parse_proposal("#12 growth $797 | misses 6 calls a week; quotes never chased")
        self.assertEqual(p, {"short_id": 12, "package": "growth", "monthly_cents": 79700, "findings": ["misses 6 calls a week", "quotes never chased"]})
        with self.assertRaises(R.RevenueError):
            R.parse_proposal("12 gold 797")

    def test_proposal_cmd(self):
        get = lambda path: [{"id": "VD"}] if "ventures" in path else ([{"id": "L12"}] if "venture_id=eq.VD" in path else [])
        posted = []
        runner = lambda m, i: {"ok": True, "result": {"results": [{"outbox": "O9", "new": True, "purpose": "proposal"}]}}
        out = R.proposal_cmd("12 essential 197 | one leak", get=get, runner=runner, approve=lambda o, l: posted.append(o))
        self.assertIn("Proposal drafted", out)
        self.assertEqual(posted, ["O9"])
        other = R.proposal_cmd("12 essential 197", get=lambda p: [{"id": "VD"}] if "ventures" in p else [], runner=runner)
        self.assertIn("No Donna lead", other)
        blocked = R.proposal_cmd("12 essential 197", get=get, runner=lambda m, i: {"ok": True, "result": {"results": [{"not_staged": "no address"}]}})
        self.assertIn("not ready to send: no address", blocked)

    def test_onboarding(self):
        s, b = R.onboarding_email(ctx_lead(), "front-desk", ADDR)
        self.assertEqual(hq_donna.casl_problems("follow_up_email", s, b), [])
        self.assertIn("Front Desk", s)
        self.assertIn("number we should text or transfer urgent calls to", b)
        get = lambda path: [{"id": "VD"}] if "ventures" in path else [{"id": "L12"}]
        posted = []
        runner = lambda m, i: {"ok": True, "result": {"results": [{"outbox": "O7", "new": True, "purpose": i["mode"]}]}}
        self.assertIn("Welcome email drafted", R.onboard_cmd("12 front-desk", get=get, runner=runner, approve=lambda o, l: posted.append(l)))
        self.assertIn("onboarding questions", posted[0])
        self.assertIn("Use:", R.onboard_cmd("12 gold"))

    def test_brief_cmd_validates(self):
        self.assertIn("Use:", R.brief_cmd("abc"))


class Won(unittest.TestCase):
    def test_won_records_the_owner_deal_then_drafts_onboarding(self):
        calls, posted = [], []
        class VO:
            OWNER = "owner"
            @staticmethod
            def find_lead(ref): return {"id": "L12", "name": "Pine Plumbing", "do_not_contact": False} if ref == "12" else None
            @staticmethod
            def _parse_cents(t): return int(float(t.replace(",", "")) * 100)
            @staticmethod
            def _rpc(name, args):
                calls.append((name, args)); return "D1" if name == "create_deal" else {}
        runner = lambda m, i: {"ok": True, "result": {"results": [{"outbox": "O1", "new": True, "purpose": "onboarding"}]}}
        out = R.won_cmd("12 front-desk 497", runner=runner, approve=lambda o, l: posted.append(o), vo=VO)
        self.assertEqual([n for n, _ in calls], ["create_deal", "confirm_deal_won"])
        self.assertEqual(calls[1][1]["p_ledger_status"], "expected")
        self.assertEqual(calls[1][1]["p_by"], "owner", "the owner's own command records revenue, nothing else does")
        self.assertIn("$497 a month", out)
        self.assertEqual(posted, ["O1"])
        self.assertIn("Use:", R.won_cmd("12 gold 497", vo=VO))
        self.assertIn("starts at $197", R.won_cmd("12 essential 99", vo=VO))
        self.assertIn("No contactable lead", R.won_cmd("99 growth 797", vo=VO))
        self.assertIn("/invoices link donna 497 ", out, "an expected first month points to the payment link the owner shares")
        self.assertIn("/donna intake 12 |", out)
        got = R.won_cmd("12 front-desk 497 received", runner=runner, approve=lambda o, l: None, vo=VO)
        self.assertNotIn("/invoices link", got, "already paid: no link")

    def test_invoices_link_command_is_owner_typed_and_never_sends(self):
        import asyncio, types
        from unittest import mock
        import hq_commands, hq_invoices
        out, seen = [], []
        def link(office, cents, cur, name, **k):
            seen.append((office, cents, cur, name)); return {"url": "https://buy.example/abc", "mode": "test"}
        upd = types.SimpleNamespace(message=types.SimpleNamespace(text="/invoices link donna 1,297 Growth, Pine Plumbing"))
        with mock.patch.object(hq_commands, "_owner", return_value=True), mock.patch.object(hq_invoices, "draft_payment_link", side_effect=link), \
             mock.patch.object(hq_commands.hq_core, "reply_to", new=mock.AsyncMock(side_effect=lambda m, t: out.append(t))):
            asyncio.run(hq_commands.hq_invoices_cmd(upd, types.SimpleNamespace(args=["link", "donna", "1,297", "Growth,", "Pine", "Plumbing"])))
            asyncio.run(hq_commands.hq_invoices_cmd(upd, types.SimpleNamespace(args=["link", "donna", "lots", "x"])))
        self.assertEqual(seen, [("donna", 129700, "cad", "Growth, Pine Plumbing")])
        self.assertIn("https://buy.example/abc", out[0])
        self.assertIn("Share it with the client yourself", out[0])
        self.assertIn("Use: /invoices link", out[1])


class Digest(unittest.TestCase):
    def test_once_a_day_after_six_and_quiet_days_stay_quiet(self):
        import tempfile
        with tempfile.TemporaryDirectory() as d:
            env, posted = {"DONNA_STATE_DIR": d}, []
            q = {"staged_today": 3, "outbox_waiting": 2, "inbound_7d": 5, "booked_7d": 1, "sent_7d": 4}
            five = dt.datetime(2026, 11, 27, 17, 0, tzinfo=R.TZ)
            self.assertFalse(R.post_digest(lambda n, a: q, env, now=five, brief=posted.append))
            six = five.replace(hour=18, minute=5)
            self.assertTrue(R.post_digest(lambda n, a: q, env, now=six, brief=posted.append))
            self.assertFalse(R.post_digest(lambda n, a: q, env, now=six.replace(minute=30), brief=posted.append), "once a day")
            self.assertIn("Waiting for your tap: 2", posted[0])
        self.assertIsNone(R.digest_text({"staged_today": 0, "outbox_waiting": 0, "inbound_7d": 9}))


class Stuck(unittest.TestCase):
    def test_each_stuck_deal_has_its_next_command(self):
        old = (dt.datetime.now(dt.timezone.utc) - dt.timedelta(days=3)).isoformat()
        rows = [{"kind": "audit_no_proposal", "short_id": 7, "name": "Pine Plumbing", "since": old},
                {"kind": "won_no_intake", "short_id": 9, "name": "Elm Auto", "since": old},
                {"kind": "intake_no_agent", "short_id": 9, "name": "Elm Auto", "client_label": "Elm Auto", "since": "bad"},
                {"kind": "unknown", "short_id": 1}]
        t = R.stuck_text(rows)
        self.assertIn("#7 Pine Plumbing: audit done, no proposal yet, 3 days", t)
        self.assertIn("/donna proposal 7 <package>", t)
        self.assertIn("/donna intake 9 |", t)
        self.assertIn("/donna agent Elm Auto", t)
        self.assertEqual(t.count("\n- "), 3, "three known kinds; the unknown one is skipped")
        self.assertIsNone(R.stuck_text([]))

    def test_digest_carries_stuck_deals_even_on_a_quiet_day_and_survives_an_old_database(self):
        import tempfile
        six = dt.datetime(2026, 11, 27, 18, 5, tzinfo=R.TZ)
        def rpc(name, args):
            if name == "donna_stuck_deals":
                return [{"kind": "won_no_intake", "short_id": 9, "name": "Elm Auto", "since": six.isoformat()}]
            return {"staged_today": 0, "outbox_waiting": 0}
        with tempfile.TemporaryDirectory() as d:
            posted = []
            self.assertTrue(R.post_digest(rpc, {"DONNA_STATE_DIR": d}, now=six, brief=posted.append))
            self.assertIn("Waiting on you", posted[0])
        def old_db(name, args):
            if name == "donna_stuck_deals":
                raise RuntimeError("function does not exist")
            return {"staged_today": 1, "outbox_waiting": 1}
        with tempfile.TemporaryDirectory() as d:
            posted = []
            self.assertTrue(R.post_digest(old_db, {"DONNA_STATE_DIR": d}, now=six, brief=posted.append))
            self.assertNotIn("Waiting on you", posted[0])


class Setup(unittest.TestCase):
    def test_checklist_never_shows_values(self):
        env = {"RETELL_API_KEY": "sk_secret_value", "DONNA_INBOUND": "1"}
        import hq_donna_setup
        t = hq_donna_setup.setup_text(env=env, rpc=lambda n, a: {"active": True} if n == "donna_revenue_queue" else True, get=lambda: None)
        self.assertNotIn("sk_secret_value", t)
        self.assertIn("✅ Retell key", t)
        self.assertIn("❌ Mailing address", t)
        self.assertIn("/setaddress donna", t)
        self.assertIn("❌ Payment links (/invoices link) (optional)", t)
        t2 = hq_donna_setup.setup_text(env={**env, "FZ_STRIPE_INVOICING": "1", "STRIPE_SECRET_KEY": "rk_test_value123"},
                                       rpc=lambda n, a: {"active": True} if n == "donna_revenue_queue" else True, get=lambda: None)
        self.assertIn("✅ Payment links", t2)
        self.assertNotIn("rk_test_value123", t2)
        self.assertRegex(t, r"^Donna money loop: \d+/\d+ ready")


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
