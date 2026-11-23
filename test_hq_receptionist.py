"""Donna Receptionist v1 (hq_receptionist.py, receptionist_server.py, receptionist_voice.py). Mocked Twilio / Cal.com / LLM, no network, no real calls or texts.
The database rules (demo dry-run, owner approval, STOP, suppression, consent) are proven in sqltests/donna_receptionist_check.sql."""
import copy
import datetime as dt
import json
import os
import unittest

import hq_receptionist as R
import receptionist_server as S
import receptionist_voice as V

HERE = os.path.dirname(os.path.abspath(__file__))
DEMO = json.load(open(os.path.join(HERE, "receptionist", "demo_client.json")))
TUE_10 = dt.datetime(2026, 11, 24, 15, 0, tzinfo=dt.timezone.utc)        # Tue 10:00 Toronto: open
SUN_10 = dt.datetime(2026, 11, 29, 15, 0, tzinfo=dt.timezone.utc)        # Sunday: closed


def _no_network(*a, **k):
    raise AssertionError("a test tried to reach the network")


R._rpc_default = _no_network


class FakeRpc:
    def __init__(self, live=False, text_back=False, twilio_number="+15555550199", claim=None, status="in_progress"):
        self.calls, self.live, self.text_back, self.num, self.claim, self.status = [], live, text_back, twilio_number, claim, status

    def __call__(self, name, args):
        self.calls.append((name, args))
        if name == "reception_client_config":
            return {"client": "dental", "status": "live" if self.live else "demo", "live": self.live, "config": copy.deepcopy(DEMO),
                    "twilio_number": self.num, "text_back_enabled": self.text_back}
        if name == "reception_call_event":
            return {"call": "c1", "status": args["p_status"], "mode": "live" if self.live else "demo"}
        if name == "reception_claim_sms":
            return self.claim
        if name == "reception_queue_sms":
            return {"message": "m1", "status": "pending_approval"}
        return {}

    def names(self):
        return [n for n, _ in self.calls]


class ConfigTest(unittest.TestCase):
    def test_demo_config_is_valid_and_template_is_complete(self):
        R.validate(copy.deepcopy(DEMO))
        self.assertEqual(set(R.REQUIRED) - set(R.template()), set())

    def test_validation_errors(self):
        for mut, msg in ((lambda c: c.pop("faqs"), "missing faqs"), (lambda c: c.update(timezone="Mars/Base"), "unknown timezone"),
                         (lambda c: c["hours"].update(mon=[["18:00", "09:00"]]), "bad span"), (lambda c: c.update(escalation_number="555-0100"), "E.164"),
                         (lambda c: c["services"].append({"name": "X", "price_cents": "free", "minutes": 10}), "price_cents"),
                         (lambda c: c.update(booking={"provider": "calcom"}), "event_type_ids"), (lambda c: c.update(voice={"tts": "robot"}), "voice.tts"), (lambda c: c.update(voice={"tts": "kokoro", "stt": "cloud"}), "voice.stt")):
            c = copy.deepcopy(DEMO)
            mut(c)
            with self.assertRaises(R.ReceptionError) as e:
                R.validate(c)
            self.assertIn(msg, str(e.exception))

    def test_hours(self):
        self.assertTrue(R.is_open(DEMO, TUE_10))
        self.assertFalse(R.is_open(DEMO, SUN_10))
        self.assertIn("Sun closed", R.hours_text(DEMO))

    def test_prompt_uses_config_facts_only_and_discloses_ai(self):
        p = R.system_prompt(DEMO)
        self.assertIn("AI assistant", p)
        self.assertIn("Cleaning: $150, 60 min", p)
        self.assertIn("Never ask for card numbers", p)


class TurnTest(unittest.TestCase):
    def test_rules(self):
        self.assertEqual(R.turn(DEMO, "can I talk to a real person", now=TUE_10)["action"], "transfer")
        closed = R.turn(DEMO, "can I talk to a real person", now=SUN_10)
        self.assertIsNone(closed["action"])
        self.assertIn("closed", closed["say"])
        self.assertIn("$150", R.turn(DEMO, "how much is a cleaning?", now=TUE_10)["say"])
        self.assertIn("Sat 09:00-13:00", R.turn(DEMO, "what are your hours", now=TUE_10)["say"])
        self.assertIn("free parking", R.turn(DEMO, "is there parking near you?", now=TUE_10)["say"])
        self.assertEqual(R.turn(DEMO, "I want to book an appointment", now=TUE_10)["action"], "book")

    def test_llm_only_when_rules_do_not_answer_and_marks_client_data(self):
        seen = []
        llm = lambda system, msgs, **kw: seen.append(kw) or {"text": "We see kids from age three."}
        r = R.turn(DEMO, "do you see children", now=TUE_10, llm=llm)
        self.assertEqual(r["say"], "We see kids from age three.")
        self.assertTrue(seen[0]["contains_client_data"])
        self.assertEqual((seen[0]["division"], seen[0]["tier"]), ("donna", "small"))
        R.turn(DEMO, "how much is a cleaning", now=TUE_10, llm=llm)
        self.assertEqual(len(seen), 1)                                          # the price rule answered: no LLM call


class FakeCal:
    def __init__(self, fail=False):
        self.fail, self.booked = fail, []

    def slots(self, et, start, end, tz):
        return ["2026-11-25T14:00:00Z", "2026-11-25T15:00:00Z", "2026-11-26T19:30:00Z"]

    def book(self, et, start, name, tz, phone=None, email=None):
        if self.fail:
            raise R.ReceptionError("down")
        self.booked.append((et, start))
        return "cal:bk_1"


class ConversationTest(unittest.TestCase):
    def cfg(self):
        c = copy.deepcopy(DEMO)
        c["booking"] = {"provider": "calcom", "event_type_ids": {"Cleaning": 111, "Checkup": 222}}
        return c

    def test_booking_flow(self):
        cal = FakeCal()
        conv = R.Conversation(self.cfg(), calcom=cal, now=TUE_10)
        r = conv.handle("I'd like to book")
        self.assertEqual(conv.state.get("stage"), "service")
        r = conv.handle("a cleaning please")
        self.assertIn("first: Wednesday at 9 AM", r["say"])
        self.assertIn("Please say first", conv.handle("whenever")["say"])
        r = conv.handle("the second one")
        self.assertEqual(r["action"], "booked")
        self.assertEqual(cal.booked, [(111, "2026-11-25T15:00:00Z")])
        self.assertEqual(conv.booking_ref, "cal:bk_1")

    def test_booking_failure_and_no_calendar(self):
        conv = R.Conversation(self.cfg(), calcom=FakeCal(fail=True), now=TUE_10)
        conv.handle("book a checkup")
        self.assertIn("couldn't complete", conv.handle("first")["say"])
        self.assertIsNone(conv.booking_ref)
        r = R.Conversation(copy.deepcopy(DEMO), now=TUE_10).handle("can I book a cleaning")
        self.assertEqual(r["action"], "send_link")


class TwimlTest(unittest.TestCase):
    def test_escaping(self):
        c = copy.deepcopy(DEMO)
        c["business_name"] = 'Bob & <Sons> "Dental"'
        x = R.twiml_demo_greeting(c, "https://h/twilio/turn/x?a=1&b=2")
        self.assertIn("Bob &amp; &lt;Sons&gt;", x)
        self.assertIn('action="https://h/twilio/turn/x?a=1&amp;b=2"', x)
        self.assertNotIn("<Sons>", x)

    def test_transfer_dials_escalation_number(self):
        x, r = R.twiml_turn(DEMO, "put me through to a person", "https://h/t", now=TUE_10)
        self.assertIn("<Dial timeout=\"20\">+15555550100</Dial>", x)

    def test_answer_routing(self):
        form = {"CallSid": "CA0000000001", "From": "+15555550111", "To": "+15555550199"}
        live = R.answer("dental", form, rpc=FakeRpc(live=True), base_url="https://h", demo_number="+15555550177", stream=True)
        self.assertIn('<Stream url="wss://h/twilio/media/dental">', live)
        self.assertIn("<Gather", R.answer("dental", form, rpc=FakeRpc(live=True), base_url="https://h", demo_number=None, stream=False))
        # not live: the client's number passes straight to the business; only the owner's demo line gets the AI
        passthrough = R.answer("dental", form, rpc=FakeRpc(live=False), base_url="https://h", demo_number="+15555550177", stream=True)
        self.assertEqual(passthrough, '<?xml version="1.0" encoding="UTF-8"?><Response><Dial>+15555550100</Dial></Response>')
        demo = R.answer("dental", dict(form, To="+15555550177"), rpc=FakeRpc(live=False), base_url="https://h", demo_number="+15555550177", stream=True)
        self.assertIn("<Gather", demo)
        self.assertNotIn("<Stream", demo)


class TwilioTest(unittest.TestCase):
    def test_signature(self):
        p = {"CallSid": "CA1234567890ABCDE", "From": "+15555550111", "To": "+15555550199"}
        sig = R.twilio_signature("tok", "https://h/twilio/voice/dental", p)
        self.assertTrue(R.verify_twilio("tok", "https://h/twilio/voice/dental", p, sig))
        self.assertFalse(R.verify_twilio("tok", "https://h/twilio/voice/dental", dict(p, From="+15555550112"), sig))
        self.assertFalse(R.verify_twilio("tok", "https://h/twilio/voice/other", p, sig))
        self.assertFalse(R.verify_twilio("", "https://h/twilio/voice/dental", p, sig))
        self.assertFalse(R.verify_twilio("tok", "https://h/twilio/voice/dental", p, None))

    def test_status_mapping(self):
        rpc = FakeRpc()
        self.assertEqual(R.status_event("dental", {"CallSid": "CA1", "CallStatus": "no-answer"}, rpc=rpc)["status"], "missed")
        self.assertEqual(R.status_event("dental", {"CallSid": "CA1", "CallStatus": "completed", "CallDuration": "3"}, rpc=rpc)["status"], "missed")
        self.assertEqual(R.status_event("dental", {"CallSid": "CA1", "CallStatus": "completed", "CallDuration": "95"}, rpc=rpc)["status"], "completed")
        self.assertGreater(rpc.calls[-1][1]["p_cost_est_cents"], 0)

    def test_text_back_body(self):
        b = R.text_back_body(DEMO)
        self.assertIn("Maple Street Dental", b)
        self.assertTrue(b.endswith("Reply STOP to opt out."))
        self.assertLessEqual(len(b), 320)

    def test_send_sms_needs_switch_credentials_and_claim(self):
        env = {"RECEPTION_SMS_LIVE": "1", "TWILIO_ACCOUNT_SID": "AC1", "TWILIO_AUTH_TOKEN": "t"}
        self.assertFalse(R.send_sms("m1", rpc=FakeRpc(), http=_no_network, env={})["sent"])
        self.assertFalse(R.send_sms("m1", rpc=FakeRpc(), http=_no_network, env={"RECEPTION_SMS_LIVE": "1"})["sent"])
        r = R.send_sms("m1", rpc=_no_network, http=_no_network, env={"TWILIO_ACCOUNT_SID": "AC1", "TWILIO_AUTH_TOKEN": "t"})
        self.assertIn("RECEPTION_SMS_LIVE", r["reason"])
        rpc = FakeRpc(claim={"message": "m1", "status": "cancelled", "refused": "the number opted out or is suppressed", "to": "+15555550111"})
        r = R.send_sms("m1", rpc=rpc, http=_no_network, env=env)
        self.assertEqual(r, {"sent": False, "reason": "the number opted out or is suppressed"})
        self.assertNotIn("reception_mark_sms", rpc.names())

    def test_send_sms_success_and_failures(self):
        env = {"RECEPTION_SMS_LIVE": "1", "TWILIO_ACCOUNT_SID": "AC1", "TWILIO_AUTH_TOKEN": "t"}
        claim = {"message": "m1", "to": "+15555550111", "from": "+15555550199", "body": "Maple Street Dental ... Reply STOP to opt out."}
        sent = []
        ok_http = lambda m, u, headers=None, form=None, **k: sent.append((u, headers, form)) or (201, {"sid": "SM" + "a" * 32}, {})
        rpc = FakeRpc(claim=claim)
        self.assertEqual(R.send_sms("m1", rpc=rpc, http=ok_http, env=env), {"sent": True})
        self.assertEqual(sent[0][0], "https://api.twilio.com/2010-04-01/Accounts/AC1/Messages.json")
        self.assertEqual(sent[0][2], {"To": "+15555550111", "From": "+15555550199", "Body": claim["body"]})
        self.assertEqual(rpc.calls[-1], ("reception_mark_sms", {"p_id": "m1", "p_ok": True, "p_provider_sid": "SM" + "a" * 32}))
        rpc = FakeRpc(claim=claim)
        self.assertFalse(R.send_sms("m1", rpc=rpc, http=lambda *a, **k: (400, {"code": 21610}, {}), env=env)["sent"])
        self.assertFalse(rpc.calls[-1][1]["p_ok"])
        rpc = FakeRpc(claim=claim)
        self.assertFalse(R.send_sms("m1", rpc=rpc, http=lambda *a, **k: (_ for _ in ()).throw(OSError()), env=env)["sent"])
        self.assertFalse(rpc.calls[-1][1]["p_ok"])

    def test_send_pending_only_with_switch(self):
        self.assertEqual(R.send_pending(rpc=_no_network, env={}), [])
        claim = {"message": "m1", "to": "+15555550111", "from": "+15555550199", "body": "x"}
        rpc = FakeRpc(claim=claim)
        rpc_list = lambda n, a: ["m1"] if n == "reception_pending_sends" else rpc(n, a)
        env = {"RECEPTION_SMS_LIVE": "1", "TWILIO_ACCOUNT_SID": "AC1", "TWILIO_AUTH_TOKEN": "t"}
        r = R.send_pending(rpc=rpc_list, http=lambda *a, **k: (201, {"sid": "SM" + "b" * 32}, {}), env=env)
        self.assertEqual(r, [{"sent": True, "message": "m1"}])

    def test_inbound_sms_goes_to_the_db(self):
        rpc = FakeRpc()
        self.assertEqual(R.inbound_sms("dental", {"From": "+15555550111", "Body": "STOP", "MessageSid": "SM1"}, rpc=rpc), '<?xml version="1.0" encoding="UTF-8"?><Response/>')
        self.assertEqual(rpc.calls[-1][0], "reception_inbound_sms")


class CalComTest(unittest.TestCase):
    def test_slots_and_book(self):
        seen = []
        def http(method, url, headers=None, json_body=None, **k):
            seen.append((method, url, headers, json_body))
            if method == "GET":
                return 200, {"status": "success", "data": {"2026-11-25": [{"start": "2026-11-25T14:00:00Z"}], "2026-11-26": [{"start": "2026-11-26T15:00:00Z"}]}}, {}
            return 201, {"status": "success", "data": {"uid": "abc123"}}, {}
        c = R.CalCom("cal_key", http=http)
        self.assertEqual(c.slots(111, "2026-11-24", "2026-12-01", "America/Toronto"), ["2026-11-25T14:00:00Z", "2026-11-26T15:00:00Z"])
        self.assertIn("eventTypeId=111", seen[0][1])
        self.assertEqual(seen[0][2]["Authorization"], "Bearer cal_key")
        self.assertEqual(c.book(111, "2026-11-25T14:00:00Z", "Caller", "America/Toronto", phone="+15555550111"), "cal:abc123")
        self.assertEqual(seen[1][3]["attendee"]["phoneNumber"], "+15555550111")
        with self.assertRaises(R.ReceptionError):
            R.CalCom("k", http=lambda *a, **k: (401, {}, {})).book(1, "x", "n", "UTC")
        with self.assertRaises(R.ReceptionError):
            R.CalCom("")


class CostTest(unittest.TestCase):
    def test_estimates(self):
        self.assertEqual(R.call_cost_cents(3, "stream"), 6)                     # 3 min x (0.0085 + 0.004) US$ x 1.40 = 5.25 -> 6 cents
        self.assertEqual(R.call_cost_cents(3, "stream", tts="piper"), 6)
        self.assertEqual(R.call_cost_cents(3, "gather"), 21)                    # + 6 speech turns x US$0.02
        self.assertEqual(R.sms_cost_cents(1), 2)
        self.assertEqual(R.call_cost_cents(0), 0)


class ServerTest(unittest.TestCase):
    def test_gather_turn_keeps_conversation_and_records_transfer(self):
        S.CONVS.clear()
        rpc = FakeRpc()
        x = S.handle_turn("dental", {"CallSid": "CA9", "SpeechResult": "how much is whitening"}, rpc=rpc, base_url="https://h")
        self.assertIn("$350", x)
        self.assertIn("CA9", S.CONVS)
        from unittest import mock
        with mock.patch.object(R, "is_open", return_value=True):
            x = S.handle_turn("dental", {"CallSid": "CA9", "SpeechResult": "I need to speak to a person, it's urgent"}, rpc=rpc, base_url="https://h")
        self.assertIn("<Dial", x)
        self.assertTrue(any(n == "reception_call_event" and a["p_status"] == "escalated" for n, a in rpc.calls))

    def test_missed_call_queues_text_back_only_when_enabled(self):
        rpc = FakeRpc(text_back=False)
        S.handle_status("dental", {"CallSid": "CA1", "CallStatus": "no-answer", "From": "+15555550111"}, rpc=rpc)
        self.assertNotIn("reception_queue_sms", rpc.names())
        rpc = FakeRpc(text_back=True)
        r = S.handle_status("dental", {"CallSid": "CA1", "CallStatus": "no-answer", "From": "+15555550111"}, rpc=rpc)
        self.assertEqual(r["text_back"]["status"], "pending_approval")
        q = [a for n, a in rpc.calls if n == "reception_queue_sms"][0]
        self.assertEqual(q["p_kind"], "text_back")
        rpc = FakeRpc(text_back=True)
        S.handle_status("dental", {"CallSid": "CA2", "CallStatus": "completed", "CallDuration": "80"}, rpc=rpc)
        self.assertNotIn("reception_queue_sms", rpc.names())


class CommandTest(unittest.TestCase):
    def test_reception_command_owner_only(self):
        import asyncio
        import types
        from unittest import mock
        import hq_commands
        out = []
        reply = mock.AsyncMock(side_effect=lambda m, t: out.append(t))
        with mock.patch.object(hq_commands, "_owner", return_value=False), mock.patch.object(hq_commands.hq_core, "reply_to", new=reply):
            asyncio.run(hq_commands.hq_reception_cmd(types.SimpleNamespace(message=object()), types.SimpleNamespace(args=[])))
        self.assertEqual(out, [])
        with mock.patch.object(hq_commands, "_owner", return_value=True), mock.patch.object(hq_commands.hq_core, "reply_to", new=reply), \
             mock.patch.object(R, "report_text", return_value="RECEPTION"):
            asyncio.run(hq_commands.hq_reception_cmd(types.SimpleNamespace(message=object()), types.SimpleNamespace(args=[])))
        self.assertEqual(out, ["RECEPTION"])

    def test_report_text(self):
        rows = [{"client": "dental", "status": "demo", "text_back": False, "calls_7d": 4, "missed_7d": 1, "booked_7d": 1, "minutes_7d": 6.5,
                 "cost_est_cents_7d": 42, "texts_pending": 0, "texts_sent_7d": 0}]
        t = R.report_text(rpc=lambda n, a: rows)
        self.assertIn("dental [demo]: 4 calls, 1 missed, 1 booked, 6.5 min, ~$0.42; texts 0 sent, 0 waiting for you; text-back off", t)
        self.assertIn("no clients", R.report_text(rpc=lambda n, a: []))


class VoiceTest(unittest.TestCase):
    def test_transfer_call_uses_twilio_rest(self):
        seen = []
        http = lambda m, u, headers=None, form=None, **k: seen.append((u, form)) or (200, {}, {})
        env = {"TWILIO_ACCOUNT_SID": "AC1", "TWILIO_AUTH_TOKEN": "t"}
        self.assertTrue(V.transfer_call("CA123", "+15555550100", env, http=http))
        self.assertEqual(seen[0], ("https://api.twilio.com/2010-04-01/Accounts/AC1/Calls/CA123.json", {"Twiml": "<Response><Dial>+15555550100</Dial></Response>"}))
        self.assertFalse(V.transfer_call("CA123", "not-a-number", env, http=_no_network))
        self.assertFalse(V.transfer_call("CA123", "+15555550100", {}, http=_no_network))

    def test_source_has_no_outbound_calls_or_direct_urlopen(self):
        import re
        for mod in (R, S, V):
            src = re.sub(r'"""[\s\S]*?"""', "", open(mod.__file__).read())
            self.assertNotIn("urlopen", src)
            self.assertNotIn("Calls.json", src)                                 # no call creation anywhere
            self.assertNotIn("anthropic", src.lower())


if __name__ == "__main__":
    unittest.main()
