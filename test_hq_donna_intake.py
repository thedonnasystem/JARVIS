"""Tests for hq_donna_intake (Donna Intake v1): the client's setup answers -> the onboarding intake, in plain code. Database and missions are mocked."""
import unittest

import hq_donna
import hq_donna_intake as I


class Hours(unittest.TestCase):
    def test_ranges_and_closed(self):
        h = I.parse_hours("mon-fri 9-5, sat 10am-2pm, sun closed")
        self.assertEqual(h["mon"], [["09:00", "17:00"]])
        self.assertEqual(h["fri"], [["09:00", "17:00"]])
        self.assertEqual(h["sat"], [["10:00", "14:00"]])
        self.assertEqual(h["sun"], [])

    def test_24h_split_and_aliases(self):
        h = I.parse_hours("weekdays 08:30-12 & 13-17:30, saturday 9-12")
        self.assertEqual(h["wed"], [["08:30", "12:00"], ["13:00", "17:30"]])
        self.assertEqual(h["sat"], [["09:00", "12:00"]])
        self.assertEqual(h["sun"], [], "a day not named is closed")

    def test_lists_of_days(self):
        h = I.parse_hours("mon/wed/fri 7-15, tue to thu 10-18")
        self.assertEqual(h["mon"], [["07:00", "15:00"]])
        self.assertEqual(h["wed"], [["10:00", "18:00"]], "the later chunk wins")
        self.assertEqual(h["sat"], [])

    def test_comma_separated_days(self):
        h = I.parse_hours("mon, wed, fri 9-5, sat closed")
        self.assertEqual([d for d in I.DAYS if h[d]], ["mon", "wed", "fri"])
        with self.assertRaises(I.IntakeError):
            I.parse_hours("mon 9-5, tue")

    def test_refuses_what_it_cannot_read(self):
        for bad in ("", "sometimes", "mon-fri late", "fri-mon 9-5", "mon 10pm-2am", "funday 9-5", "mon 9"):
            with self.subTest(bad=bad), self.assertRaises(I.IntakeError):
                I.parse_hours(bad)

    def test_result_is_a_valid_receptionist_config(self):
        cfg, _ = hq_donna.reception_config({"business_name": "Pine", "hours": I.parse_hours("daily 7am-9pm"), "escalation_number": "+16135550111"})
        self.assertEqual(cfg["hours"]["sun"], [["07:00", "21:00"]])


class Services(unittest.TestCase):
    def test_price_and_length(self):
        s = I.parse_services("Oil change $89 30min, Brake check $120.50 1.5h, Free estimate")
        self.assertEqual(s[0], {"name": "Oil change", "price_cents": 8900, "minutes": 30})
        self.assertEqual(s[1], {"name": "Brake check", "price_cents": 12050, "minutes": 90})
        self.assertEqual(s[2], {"name": "Free estimate", "price_cents": 0, "minutes": 30})

    def test_thousands_separator_is_not_a_new_service(self):
        s = I.parse_services("Furnace install $4,500 4h, Tune-up $149")
        self.assertEqual([(x["name"], x["price_cents"], x["minutes"]) for x in s], [("Furnace install", 450000, 240), ("Tune-up", 14900, 30)])

    def test_refuses_nameless_or_silly_lengths(self):
        for bad in ("$40", "Detail 900min"):
            with self.subTest(bad=bad), self.assertRaises(I.IntakeError):
                I.parse_services(bad)


class Phone(unittest.TestCase):
    def test_north_american_forms(self):
        for raw in ("+1 613 555 0100", "613-555-0100", "(613) 555-0100", "1 613 555 0100"):
            self.assertEqual(I.parse_phone(raw), "+16135550100", raw)

    def test_refuses_short(self):
        with self.assertRaises(I.IntakeError):
            I.parse_phone("555-0100")


class Parse(unittest.TestCase):
    LINE = ("12 | name: Al's Diner; hours: mon-fri 9-17, sat 10-14; services: Breakfast special $12 45min, Catering; "
            "faq: Walk-ins? = Yes, before 3 pm; faq: Parking? = Free lot out back; urgent: 613 555 0100; booking: https://cal.com/als/visit; city: Kanata")

    def test_full_line(self):
        p = I.parse(self.LINE)
        self.assertEqual(p["short_id"], 12)
        i = p["intake"]
        self.assertEqual(i["business_name"], "Al's Diner")
        self.assertEqual(i["hours"]["sat"], [["10:00", "14:00"]])
        self.assertEqual([s["name"] for s in i["services"]], ["Breakfast special", "Catering"])
        self.assertEqual(i["faqs"][0], {"q": "Walk-ins?", "a": "Yes, before 3 pm"})
        self.assertEqual(len(i["faqs"]), 2)
        self.assertEqual(i["escalation_number"], "+16135550100")
        self.assertEqual(i["booking_url"], "https://cal.com/als/visit")
        self.assertEqual(i["city"], "Kanata")
        cfg, items = hq_donna.reception_config(i)
        self.assertEqual(cfg["business_name"], "Al's Diner")
        self.assertTrue(any("prices are 0" in x for x in items), "Catering has no price: an open item, never a guessed price")

    def test_multiline_message(self):
        p = I.parse("#7 |\nhours: weekdays 9-5\nfaq: Do you deliver? = No")
        self.assertEqual(p["short_id"], 7)
        self.assertEqual(p["intake"]["faqs"], [{"q": "Do you deliver?", "a": "No"}])

    def test_refusals(self):
        for bad in ("", "12", "x | name: A", "12 | colour: red", "12 | faq: no answer here", "12 | booking: http://insecure.example",
                    "12 | timezone: Mars/Base", "12 | name:"):
            with self.subTest(bad=bad), self.assertRaises(I.IntakeError):
                I.parse(bad)


class Command(unittest.TestCase):
    def setUp(self):
        self.calls = []

    def get(self, path):
        if path.startswith("/rest/v1/ventures"):
            return [{"id": "V1"}]
        if "short_id=eq.12" in path:
            return [{"id": "L12"}]
        if "id=eq.L12" in path:
            return [{"name": "Pine Plumbing"}]
        return []

    def runner(self, mission, inputs):
        self.calls.append((mission, inputs))
        cfg, items = hq_donna.reception_config(inputs["intake"])
        return {"ok": True, "result": {"reception_config": cfg, "open_items": items}}

    def test_saves_through_the_onboarding_mission(self):
        out = I.intake_cmd("12 | hours: mon-fri 8-4; urgent: +1 613 555 0111", get=self.get, runner=self.runner)
        mission, inputs = self.calls[0]
        self.assertEqual(mission, "delivery-onboarding")
        self.assertEqual(inputs["lead_id"], "L12")
        self.assertEqual(inputs["intake"]["business_name"], "Pine Plumbing", "the name defaults to the lead's")
        self.assertIn("Intake saved for Pine Plumbing", out)
        self.assertIn("open: mon, tue, wed, thu, fri", out)
        self.assertIn("urgent calls to: set", out)
        self.assertIn("/donna agent Pine Plumbing", out)
        self.assertIn("faqs: none given", out)

    def test_unknown_lead_and_refused_run(self):
        self.assertEqual(I.intake_cmd("99 | name: X", get=self.get, runner=self.runner), "No Donna lead #99.")
        out = I.intake_cmd("12 | name: X", get=self.get, runner=lambda m, i: {"ok": False, "refused": "Donna is dormant"})
        self.assertEqual(out, "Intake not saved: Donna is dormant")

    def test_bad_line_never_runs(self):
        out = I.intake_cmd("12 | hours: whenever", get=self.get, runner=self.runner)
        self.assertIn("hours:", out)
        self.assertEqual(self.calls, [])

    def test_no_model_and_no_provider_calls(self):
        import re
        src = open(I.__file__).read().lower()
        for word in ("llm", "urlopen", "openai", "groq", "gemini", "anthropic", "resend", "retell", "_chat", "complete"):
            self.assertIsNone(re.search(rf"\b{word}\b", src), word)


if __name__ == "__main__":
    unittest.main()
