"""FF Marketing engine v1 (hq_ffm_engine). No network: the model, the spend gateway and the database RPCs are mocked."""
import asyncio
import json
import os
import re
import unittest
from unittest import mock

import hq_ffm_engine as E
import hq_meter
from hq_workspace import SensitiveDataRefused

ROOT = os.path.dirname(os.path.abspath(__file__))
MIG = os.path.join(ROOT, "migrations", "20261125_ffm_engine_v1.sql")
WS = "11111111-2222-4333-8444-555555555555"
BRIEF_MSG = """/ffm new
name: Maple Heating Co
vertical: home_services
offer: Free furnace safety inspection with any tune-up
area: Barrhaven and Riverside South, as stated by the client
customer: Homeowners with furnaces older than ten years
goal: booked calls
budget: unset"""


def strategy_json():
    return {"positioning": {"statement": "Warm, safe homes before the first cold snap.", "offer_angle": "Inspection included with every tune-up.",
                            "differentiators": ["Local crew", "Clear checklist", "Same-week visits [CLIENT TO CONFIRM]"]},
            "audience_angles": [{"key": k, "name": f"Angle {k}", "description": "Homeowners in the stated area", "pain_point": "Worried about the furnace"} for k in "ABC"],
            "ad_sets": [{"angle": k, "name": f"Set {k}", "audience_description": "Homeowners, home improvement interests", "placement_note": "Feeds"} for k in "ABC"],
            "ad_variants": [{"id": f"V{i}", "angle": "ABC"[(i - 1) // 3], "headline": f"Furnace check {i}", "primary_text": "Book a tune-up and we include a safety inspection.",
                             "cta": "Book Now" if i % 2 else "Weird CTA"} for i in range(1, 10)],
            "creative_briefs": [{"variant": f"V{i}", "format": "image", "prompt": "A technician checking a furnace in a bright basement"} for i in range(1, 10)],
            "kpi_targets": [{"metric": "Click-through rate", "target": "1%+", "note": ""}, {"metric": "Landing conversion", "target": "10%", "note": ""},
                            {"metric": "Lead to booked", "target": "30%", "note": ""}]}


def funnel_json():
    return {"landing_page": {"headline": "Get your furnace ready", "subheadline": "Tune-up with a free inspection", "bullets": ["Local", "Fast", "Clear"],
                             "cta_text": "Book my visit", "faq": [{"q": "How long?", "a": "About an hour."}, {"q": "Where?", "a": "In the stated area."}], "trust_note": "[CLIENT TO CONFIRM]"},
            "follow_up": [{"touch": i, "day": 0, "channel": "sms" if i % 2 else "email", "subject": "Your furnace visit", "body": "Hi {{first_name}}, {{business_name}} here. Reply STOP to opt out."}
                          for i in range(1, 6)]}


def organic_json():
    return {"organic_calendar": [{"day": i, "platform": "instagram", "format": "reel", "hook": f"Tip {i}", "caption": "Change your filter."} for i in range(1, 15)]}


OUT = {"strategy": strategy_json, "funnel": funnel_json, "organic": organic_json}


class FakeLLM:
    def __init__(self, bad_first=None, cents=1):
        self.calls, self.bad_first, self.cents = [], set(bad_first or ()), cents

    def __call__(self, purpose, model, system, user, max_tokens):
        step = purpose.rsplit(" ", 1)[1]
        self.calls.append((step, model, system, user))
        if step in self.bad_first:
            self.bad_first.discard(step)
            return "Sure! here you go: not json", self.cents
        return "```json\n" + json.dumps(OUT[step]()) + "\n```", self.cents


class FakeDB:
    def __init__(self, flag=None):
        self.calls, self.flag = [], flag or (lambda t: False)
        self.n = 0

    def rpc(self, name, args):
        self.calls.append((name, args))
        if name == "ffm_engine_screen_texts":
            return [{"i": i, "reasons": ["x"]} for i, t in enumerate(args["p_texts"]) if self.flag(t)]
        if name == "ffm_engine_save_pack":
            return {"id": "p1", "version": 1, "status": "draft", "dry_run": True}
        self.n += 1
        return f"{self.n:08x}-0000-4000-8000-000000000000"

    def get(self, path):
        if path.startswith("/rest/v1/client_workspaces"):
            return [{"id": WS, "slug": "maple-heating-co", "name": "Maple Heating Co", "vertical": "home_services", "status": "draft"}]
        if path.startswith("/rest/v1/ffm_engine_briefs"):
            b = E.validate_brief(E.parse_brief(BRIEF_MSG))
            return [{"brief": {k: b[k] for k in ("offer", "service_area", "target_customer", "goal")}}]
        if path.startswith("/rest/v1/ws_marketing_vocab"):
            return [{"word": w} for w in ("book", "free", "home", "safety", "visit")]
        if path.startswith("/rest/v1/ws_approved_terms"):
            return [{"term": "Furnace tune-up"}]
        return []


def run(db=None, llm=None, **kw):
    db, llm = db or FakeDB(), llm or FakeLLM()
    with mock.patch.object(E.hq_llm, "has_personal_data", side_effect=kw.pop("pii", lambda t: False)):
        r = E.run_pack("maple-heating-co", call=llm, estimate=lambda m, i, o: 1, rpc=db.rpc, get=db.get, **kw)
    return r, db, llm


class BriefTests(unittest.TestCase):
    def test_parse_and_validate(self):
        b = E.validate_brief(E.parse_brief(BRIEF_MSG))
        self.assertEqual(b["slug"], "maple-heating-co")
        self.assertEqual(b["vertical"], "home_services")
        self.assertEqual(b["monthly_budget_stated"], "unset")

    def test_missing_and_bad_vertical(self):
        with self.assertRaises(E.BriefError):
            E.validate_brief({"business_name": "X Co"})
        with self.assertRaises(E.BriefError):
            E.validate_brief({**E.parse_brief(BRIEF_MSG), "vertical": "crypto"})

    def test_brief_with_personal_data_refused_before_any_model(self):
        raw = {**E.parse_brief(BRIEF_MSG), "target_customer": "Client Jane Roe, 12 King Street"}
        with self.assertRaises(SensitiveDataRefused):
            E.validate_brief(raw)


class PlaybookTests(unittest.TestCase):
    def test_every_vertical_has_a_playbook_with_items_to_confirm(self):
        for v in E.VERTICALS:
            self.assertTrue(E.playbook(v).startswith("# Playbook: generic"))
            self.assertGreaterEqual(len(E.confirm_items(v)), 5, v)
            if v != "generic":
                self.assertIn(f"{v.replace('_', ' ')}", E.playbook(v).lower().replace("_", " "))

    def test_vertical_specific_guardrails(self):
        self.assertTrue(any("FSRA" in c for c in E.confirm_items("mortgage")))
        self.assertTrue(any("special ad category" in c for c in E.confirm_items("mortgage")))
        self.assertTrue(any("guaranteed returns" in c for c in E.confirm_items("insurance")))
        self.assertTrue(any("housing" in c for c in E.confirm_items("real_estate")))
        self.assertFalse(any("FSRA" in c for c in E.confirm_items("generic")))

    def test_prompt_uses_the_selected_playbook(self):
        b = E.validate_brief({**E.parse_brief(BRIEF_MSG), "vertical": "mortgage"})
        system, user = E.build_prompt("strategy", b)
        self.assertIn("Playbook: mortgage", system)
        self.assertNotIn("Playbook: insurance", system)
        self.assertIn("Maple Heating Co", user)


class PackTests(unittest.TestCase):
    def test_full_pack_schema_and_drafts_only(self):
        r, db, llm = run()
        p = r["pack"]
        self.assertEqual([c[0] for c in llm.calls], ["strategy", "funnel", "organic"])
        self.assertTrue(all(c[1] == E.MODEL for c in llm.calls))
        self.assertEqual((len(p["ad_variants"]), len(p["creative_briefs"]), len(p["follow_up"]), len(p["organic_calendar"])), (9, 9, 5, 14))
        self.assertTrue(all(v["cta"] in E.CTAS for v in p["ad_variants"]))
        self.assertTrue(all("AI" in c["ai_disclosure"] for c in p["creative_briefs"]))          # added at show time
        self.assertTrue(all(t["opt_out_line"] for t in p["follow_up"]))
        self.assertGreaterEqual(len(p["compliance_to_confirm"]), 5)
        stored = [a["p_pack"] for n, a in db.calls if n == "ffm_engine_save_pack"][0]
        E.validate_pack(stored)
        for k in ("compliance_to_confirm", "owner_actions", "weekly_report", "business_name"):   # fixed text is never stored
            self.assertNotIn(k, stored)
        self.assertEqual(stored["lead_form"], {"fields": ["name", "email", "phone"]})
        self.assertNotIn("ai_disclosure", json.dumps(stored))
        # every stored non-free-text leaf is a short code (what ffm_engine_save_pack enforces)
        for path, key, val in E._leaves(stored):
            if key not in E.FREE_KEYS:
                self.assertRegex(val, r"^[A-Za-z0-9_.:+\[\]-]{0,60}$", path)
        self.assertEqual(p["status"], "draft")
        self.assertIs(p["dry_run"], True)
        names = [c[0] for c in db.calls]
        self.assertEqual(names.count("ffm_add_campaign"), 1)
        self.assertEqual(names.count("ffm_add_ad_set"), 3)
        self.assertEqual(names.count("ffm_add_creative"), 9)
        self.assertEqual(names[-1], "ffm_engine_save_pack")
        # nothing approves, activates, budgets, routes, sends or posts
        allowed = {"ffm_add_campaign", "ffm_add_ad_set", "ffm_add_creative", "ffm_engine_screen_texts", "ffm_engine_save_pack"}
        self.assertEqual(set(names) - allowed, set())
        self.assertTrue(all(a.get("p_daily_cents") is None for n, a in db.calls if n == "ffm_add_ad_set"))
        self.assertEqual((r["cents"], r["calls"]), (3, 3))

    def test_lead_form_allow_listed_fields_only(self):
        r, _, _ = run()
        self.assertEqual(r["pack"]["lead_form"]["fields"], ["name", "email", "phone"])
        self.assertIn("CLIENT TO PROVIDE", r["pack"]["lead_form"]["consent_wording"])
        inputs = re.findall(r'<input name="([a-z]+)"', r["html"])
        self.assertEqual(inputs, ["name", "email", "phone"])
        stored = E.assemble(E.validate_brief(E.parse_brief(BRIEF_MSG)), {s: E.normalise_part(s, OUT[s]()) for s in OUT})
        for bad in ({"fields": ["name", "email", "phone", "income"]}, {"fields": ["name", "email", "phone"], "extra": "x"}):
            with self.assertRaises(E.PackInvalid):
                E.validate_pack(dict(stored, lead_form=bad))

    def test_landing_page_is_self_contained_and_escaped(self):
        r, _, _ = run()
        h = r["html"]
        self.assertTrue(h.startswith("<!doctype html>"))
        self.assertIn("Maple Heating Co", h)
        self.assertNotRegex(h, r"(?i)<script|https?://|src=")
        self.assertIn('onsubmit="return false"', h)
        self.assertIn("DRAFT", h)
        p = r["pack"]
        p["landing_page"]["headline"] = "<script>x</script>"
        self.assertIn("&lt;script&gt;", E.render_landing_html(p))

    def test_screened_text_is_replaced_and_its_creative_not_written(self):
        db = FakeDB(flag=lambda t: t == "Furnace check 4")
        r, db, _ = run(db=db)
        self.assertEqual(r["pack"]["ad_variants"][3]["headline"], "")
        self.assertIn("ad_variants[3].headline", r["pack"]["screened_out"])
        self.assertEqual([c[0] for c in db.calls].count("ffm_add_creative"), 8)
        self.assertEqual(r["skipped"], ["V4"])
        r, db, _ = run(pii=lambda t: "Tip 2" == t)                  # the local detector (hq_llm.has_personal_data) also screens
        self.assertEqual(r["pack"]["organic_calendar"][1]["hook"], "")
        db = FakeDB(flag=lambda t: t == "Set A")                     # a blanked ad set name falls back to a name that passes every screen
        r, db, _ = run(db=db)
        self.assertEqual([a["p_name"] for n, a in db.calls if n == "ffm_add_ad_set"][0], E.AD_SET_FALLBACK[0])

    def test_repair_attempt_then_invalid(self):
        r, _, llm = run(llm=FakeLLM(bad_first={"funnel"}))
        self.assertEqual([c[0] for c in llm.calls], ["strategy", "funnel", "funnel", "organic"])
        llm_bad = lambda *a: ("nope", 1)   # noqa: E731
        with self.assertRaises(E.PackInvalid):
            run(llm=llm_bad)

    def test_cost_ceiling_stops_before_the_call_and_stores_nothing(self):
        db, llm = FakeDB(), FakeLLM(cents=4)
        with self.assertRaises(E.PackCostCeiling):
            run(db=db, llm=llm, ceiling=6)
        self.assertEqual([c[0] for c in llm.calls], ["strategy", "funnel"])     # 0+1 and 4+1 fit under 6; 8+1 does not: stopped before the third call
        self.assertEqual(db.calls, [])

    def test_ceiling_bounds(self):
        self.assertLessEqual(E.PACK_CEILING_CENTS, 30)
        self.assertLessEqual(E.MAX_CALLS, 5)

    def test_gateway_refusal_propagates_and_stores_nothing(self):
        db = FakeDB()

        def blocked(*a):
            raise hq_meter.MeterBlocked("Daily cap reached", "cap")
        with self.assertRaises(hq_meter.MeterBlocked):
            run(db=db, llm=blocked)
        self.assertEqual(db.calls, [])

    def test_default_call_goes_through_the_spend_gateway(self):
        resp = mock.Mock(content=[mock.Mock(type="text", text="{}")], usage=mock.Mock(input_tokens=100, output_tokens=50))
        with mock.patch.object(E.hq_meter, "metered_create", return_value=resp) as mc, mock.patch.object(E.hq_meter, "_estimate", return_value=1), \
                mock.patch.object(E, "_anthropic", return_value="client"):
            text, cents = E._call_llm("ffm engine pack strategy", "claude-haiku-5-5", "sys", "user", 100)
        mc.assert_called_once()
        self.assertEqual(mc.call_args.args[:2], ("client", "ffm engine pack strategy"))
        self.assertEqual((text, cents), ("{}", 1))

    def test_default_model_is_the_cheap_tier(self):
        with mock.patch.dict(os.environ, {}, clear=True):
            import importlib
            self.assertEqual(importlib.reload(E).MODEL, "claude-haiku-5-5")
        importlib.reload(E)


class VocabularyTests(unittest.TestCase):
    def test_vocabulary_goes_to_the_model_outside_mortgage(self):
        r, _, llm = run()
        self.assertIn("STRICT VOCABULARY", llm.calls[0][2])
        self.assertIn("Furnace tune-up", llm.calls[0][2])
        self.assertEqual(E.vocabulary({"id": WS, "vertical": "mortgage"}, get=lambda p: 1 / 0), "")

    def test_brief_refused_by_the_database_screen_names_the_fields(self):
        db = FakeDB(flag=lambda t: "furnace" in t.lower())
        with self.assertRaises(SensitiveDataRefused) as cm:
            E.save_brief(WS, E.validate_brief(E.parse_brief(BRIEF_MSG)), rpc=db.rpc)
        self.assertIn("offer", str(cm.exception))
        self.assertNotIn("ffm_engine_save_brief", [c[0] for c in db.calls])

    def test_existing_slug_updates_the_brief_only(self):
        db = FakeDB()
        E.create(E.validate_brief(E.parse_brief(BRIEF_MSG)), rpc=db.rpc, get=db.get)
        self.assertEqual([c[0] for c in db.calls], ["ffm_engine_screen_texts", "ffm_engine_save_brief"])
        with self.assertRaises(E.BriefError):
            E.create(E.validate_brief({**E.parse_brief(BRIEF_MSG), "vertical": "mortgage"}), rpc=db.rpc, get=db.get)


class OrganicQueueTests(unittest.TestCase):
    def _get(self, standing=()):
        db = FakeDB()

        def get(path):
            if path.startswith("/rest/v1/hand_accounts?id=eq."):
                return [{"id": "acc-1", "connector": "meta-instagram", "division": "ffm", "status": "connected", "handle": "maple"}]
            if path.startswith("/rest/v1/hand_accounts"):
                return [{"id": "acc-1"}]
            if path.startswith("/rest/v1/hand_standing"):
                return list(standing)
            if path.startswith("/rest/v1/ffm_engine_packs"):
                return [{"pack": {"organic_calendar": organic_json()["organic_calendar"]}}]
            return db.get(path)
        return get

    def test_posts_become_drafts(self):
        sub = mock.Mock(return_value={"ok": True, "status": "draft"})
        out = E.queue_organic("maple-heating-co", "acc1acc1", get=self._get(), submit=sub)
        self.assertEqual(sub.call_count, 14)
        self.assertTrue(all(c.args[2] == "post" and c.args[4] is None for c in sub.call_args_list))
        self.assertTrue(out.startswith("Sir"))

    def test_refused_under_a_standing_approval(self):
        sub = mock.Mock()
        out = E.queue_organic("maple-heating-co", "acc1acc1", get=self._get([{"scope_kind": "division", "scope_ref": "ffm"}]), submit=sub)
        sub.assert_not_called()
        self.assertIn("standing approval", out)


class Msg:
    def __init__(self, uid, text=""):
        self.chat = mock.Mock(id=uid)
        self.text, self.sent, self.docs = text, [], []

    async def reply_text(self, text, **kw):
        self.sent.append(text)

    async def reply_document(self, document=None, filename=None, caption=None, **kw):
        self.docs.append((filename, caption))


class TelegramTests(unittest.TestCase):
    def setUp(self):
        p = mock.patch.dict(os.environ, {"JARVIS_OWNER_ID": "100"})
        p.start()
        self.addCleanup(p.stop)

    def cmd(self, uid, args, text=""):
        m = Msg(uid, text)
        u = mock.Mock(effective_user=mock.Mock(id=uid), effective_chat=mock.Mock(id=uid), message=m)
        asyncio.run(E.ffm_cmd(u, mock.Mock(args=args)))
        return m

    def test_owner_only(self):
        with mock.patch.object(E, "run_pack") as rp, mock.patch.object(E, "create") as cr:
            for args in (["new"], ["pack", "x"], ["show", "x"], ["list"], ["queue", "x", "y"], []):
                self.assertEqual(self.cmd(999, args, BRIEF_MSG).sent, [])
        rp.assert_not_called()
        cr.assert_not_called()

    def test_new_without_fields_shows_the_template(self):
        m = self.cmd(100, ["new"], "/ffm new")
        self.assertTrue(m.sent[0].startswith("Sir"))
        self.assertIn("vertical:", m.sent[0])

    def test_new_creates_a_draft_workspace(self):
        with mock.patch.object(E, "create") as cr, mock.patch.object(E.hq_llm, "has_personal_data", return_value=False):
            m = self.cmd(100, ["new"], BRIEF_MSG)
        cr.assert_called_once()
        self.assertEqual(cr.call_args.args[0]["slug"], "maple-heating-co")
        self.assertTrue(m.sent[0].startswith("Sir"))
        self.assertIn("drafted", m.sent[0])

    def test_pack_replies_with_files_and_says_sir(self):
        r, _, _ = run()
        with mock.patch.object(E, "run_pack", return_value=r):
            m = self.cmd(100, ["pack", "maple-heating-co"])
        self.assertTrue(all(s.startswith("Sir") for s in m.sent))
        self.assertIn("Nothing was published, launched or sent", m.sent[-1])
        self.assertEqual([d[0] for d in m.docs], ["maple-heating-co-pack.json", "maple-heating-co-landing.html"])

    def test_cap_refusal_is_reported(self):
        with mock.patch.object(E, "run_pack", side_effect=hq_meter.MeterBlocked("Daily cap reached", "cap")):
            m = self.cmd(100, ["pack", "maple-heating-co"])
        self.assertIn("budget limit", m.sent[-1])
        with mock.patch.object(E, "run_pack", side_effect=E.PackCostCeiling("stopped")):
            m = self.cmd(100, ["pack", "maple-heating-co"])
        self.assertIn("cost ceiling", m.sent[-1])

    def test_show_sends_summary_and_files(self):
        r, _, _ = run()
        r2, db2, _l = run()
        stored = [a["p_pack"] for n, a in db2.calls if n == "ffm_engine_save_pack"][0]
        row = {"version": 1, "status": "draft", "pack": stored, "cost_cents": 3}
        with mock.patch.object(E, "show", return_value=({"id": WS, "slug": "maple-heating-co", "name": "Maple Heating Co"}, row)):
            m = self.cmd(100, ["show", "maple-heating-co"])
        self.assertIn("pack v1", m.sent[0])
        self.assertIn("Confirm with the client", m.sent[0])
        self.assertEqual(len(m.docs), 2)

    def test_registered(self):
        app, ch = mock.Mock(), mock.Mock(side_effect=lambda n, f: (n, f))
        E.register(app, ch)
        app.add_handler.assert_called_once_with(("ffm", E.ffm_cmd))
        with open(os.path.join(ROOT, "hq_commands.py"), encoding="utf-8") as f:
            self.assertIn("hq_ffm_engine.register(app, CommandHandler)", f.read())


class MigrationTextTests(unittest.TestCase):
    def setUp(self):
        with open(MIG, encoding="utf-8") as f:
            self.sql = f.read()

    def test_drafts_only_and_locked_down(self):
        self.assertIn("dry_run boolean not null default true check (dry_run)", self.sql)
        self.assertIn("check (status in ('draft', 'superseded'))", self.sql)
        self.assertIn("enable row level security", self.sql)
        self.assertIn("revoke insert, update, delete, truncate, trigger, references", self.sql)
        for fn in re.findall(r"create or replace function public\.(\w+)\(", self.sql):
            self.assertRegex(self.sql, rf"revoke all on function public\.{fn}\([^)]*\) from public, anon, authenticated")
            self.assertNotRegex(self.sql, rf"grant execute on function public\.{fn}\([^)]*\) to (anon|authenticated|public)")

    def test_touches_no_control(self):
        low = self.sql.lower()
        for word in ("kill_switch", "system_state", "monthly_budget_cents =", "ffm_set_budget(", "ffm_owner_approve(", "ffm_activate(", "reserve_llm_budget", "executor_registry",
                     "paid_providers", "jarvis_core_config", "outbox", "ws_vertical_insurance(", "ws_marketing_vocab", "ffm_guard()"):
            self.assertNotIn(word, low)


if __name__ == "__main__":
    unittest.main()
