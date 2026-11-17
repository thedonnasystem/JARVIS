"""Channel adapters: WhatsApp and emergency call are disabled by default, gated by env + the database, never call a vendor in tests; voice is design-only."""
import json
import unittest
import urllib.parse

import hq_channels as H

CRIT = H.load_criteria()


class WhatsAppTests(unittest.TestCase):
    ENV = {"JARVIS_WHATSAPP": "1", "WHATSAPP_ACCESS_TOKEN": "t", "WHATSAPP_PHONE_NUMBER_ID": "123", "WHATSAPP_OWNER_NUMBER": "+1 555 000 0000"}

    def test_disabled_by_default(self):
        w = H.WhatsAppChannel(env={}, http=lambda *a: self.fail("vendor called"), config=lambda: {})
        self.assertFalse(w.enabled())
        self.assertEqual(w.send("x")["reason"], "disabled")
        w = H.WhatsAppChannel(env=self.ENV, http=lambda *a: self.fail("vendor called"), config=lambda: {"whatsapp_enabled": False})
        self.assertFalse(w.enabled())                          # env ready but the owner switch is off

    def test_text_message_shape(self):
        sent = {}

        def http(method, url, data, headers):
            sent.update(url=url, body=json.loads(data), headers=headers)
            return {"messages": [{"id": "wamid.1"}]}
        r = H.WhatsAppChannel(env=self.ENV, http=http, config=lambda: {"whatsapp_enabled": True}).send("briefing ready")
        self.assertTrue(r["ok"])
        self.assertTrue(sent["url"].endswith("/123/messages"))
        self.assertEqual(sent["body"]["to"], "15550000000")
        self.assertEqual(sent["body"]["type"], "text")
        self.assertTrue(sent["body"]["text"]["body"].startswith("Sir, "))


class EmergencyCallTests(unittest.TestCase):
    ENV = {"JARVIS_EMERGENCY_CALL": "1", "TWILIO_ACCOUNT_SID": "AC1", "TWILIO_AUTH_TOKEN": "tok", "TWILIO_FROM_NUMBER": "+15550000001", "OWNER_PHONE_NUMBER": "+15550000002"}

    def rpc(self, allowed=True, outcome="allowed"):
        log = []

        def f(name, args):
            log.append((name, args))
            return {"allowed": allowed, "outcome": outcome} if name == "jarvis_call_allowed" else None
        return f, log

    def test_criteria_file_lists_only_critical_events(self):
        self.assertEqual(set(CRIT["events"]), {"kill_switch_tripped", "security_incident", "spend_anomaly", "production_down", "deadline_critical"})
        self.assertIn("sir", CRIT["script"].lower())
        self.assertIn("check Telegram", CRIT["script"])

    def test_not_a_listed_event_is_refused_by_criteria(self):
        rpc, log = self.rpc(allowed=False, outcome="refused_criteria")
        r = H.EmergencyCall(env=self.ENV, http=lambda *a: self.fail("called"), rpc=rpc, criteria=CRIT).call("lunch_ready", "x")
        self.assertEqual(r["outcome"], "refused_criteria")
        self.assertFalse(log[0][1]["p_criteria_ok"])
        self.assertEqual(log[0][1]["p_event_kind"], "lunch_ready")

    def test_database_refusal_means_no_call(self):
        rpc, _ = self.rpc(allowed=False, outcome="refused_limit")
        r = H.EmergencyCall(env=self.ENV, http=lambda *a: self.fail("called"), rpc=rpc, criteria=CRIT).call("production_down", "pd")
        self.assertEqual(r["outcome"], "refused_limit")

    def test_env_not_set_is_a_logged_dry_run(self):
        rpc, log = self.rpc()
        r = H.EmergencyCall(env={}, http=lambda *a: self.fail("called"), rpc=rpc, criteria=CRIT).call("kill_switch_tripped", "k")
        self.assertEqual(r["outcome"], "dry_run")
        self.assertEqual(log[-1][0], "jarvis_call_result")
        self.assertEqual(log[-1][1]["p_outcome"], "dry_run")

    def test_allowed_call_speaks_the_script_and_logs_without_numbers(self):
        rpc, log = self.rpc()
        sent = {}

        def http(method, url, data, headers):
            sent.update(url=url, form=urllib.parse.parse_qs(data.decode()))
            return {"sid": "CA123"}
        r = H.EmergencyCall(env=self.ENV, http=http, rpc=rpc, criteria=CRIT).call("spend_anomaly", "s1")
        self.assertTrue(r["ok"])
        self.assertIn("/Accounts/AC1/Calls.json", sent["url"])
        self.assertIn("Hello sir", sent["form"]["Twiml"][0])
        self.assertIn("check Telegram", sent["form"]["Twiml"][0])
        res = [a for n, a in log if n == "jarvis_call_result"][0]
        self.assertEqual(res["p_outcome"], "placed")
        self.assertNotIn("+1555", json.dumps(res))

    def test_unreachable_database_means_no_call(self):
        def rpc(name, args):
            raise OSError("down")
        r = H.EmergencyCall(env=self.ENV, http=lambda *a: self.fail("called"), rpc=rpc, criteria=CRIT).call("production_down", "x")
        self.assertEqual(r["outcome"], "refused_unreachable")


class VoiceTests(unittest.TestCase):
    def test_design_only(self):
        v = H.VoiceConversation()
        self.assertFalse(v.enabled())
        with self.assertRaises(NotImplementedError):
            v.converse([b""])


if __name__ == "__main__":
    unittest.main()
