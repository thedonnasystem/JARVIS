"""Tests for hq_venture_ops (deals, replies, do-not-contact, funnel, config) and the /reply /deal /venture config commands.
A tiny in-memory PostgREST + RPC stand-in records every call, so tests can prove what was NOT written (no ledger row, no send)."""
import asyncio, os, unittest, urllib.error
from types import SimpleNamespace
from unittest import mock
import hq, hq_commands as C, hq_venture_ops as V, hq_ventures


class Msg:
    def __init__(self): self.sent = []
    async def reply_text(self, t, **kw): self.sent.append(t)


def upd(uid="42"):
    return SimpleNamespace(effective_user=SimpleNamespace(id=uid), message=Msg())


def http(code):
    import io
    return urllib.error.HTTPError("u", code, "x", {}, io.BytesIO(b'{"message": "db says no"}'))


class World:
    def __init__(self, **kw):
        self.calls = []
        self.leads = kw.get("leads", [{"id": "L1", "short_id": 12, "venture_id": "v-cl", "name": "Acme", "email": "a@acme.co", "do_not_contact": False, "status": "sent"}])
        self.deals = kw.get("deals", [{"id": "d1234567-aaaa", "venture_id": "v-cl", "lead_id": "L1", "stage": "pitched", "value_cents": None}])
        self.outbox = kw.get("outbox", {})
        self.suppressed = kw.get("suppressed", [])
        self.config = kw.get("config", {"venture": "ottawa-cleanouts", "reply_sla_hours": 24, "reply_sla_is_default": True, "prospecting_brief_set": True, "drafts_ready": True})
        self.rpc_error = kw.get("rpc_error")
        self.rpc_reply = kw.get("rpc_reply", {})

    def writes(self):
        return [c for c in self.calls if c[0] != "GET" and not c[1].endswith("/rpc/owner_seen")]

    def __call__(self, method, path, body=None, timeout=30, prefer=None):
        self.calls.append((method, path, body))
        if path.startswith("/rest/v1/rpc/"):
            name = path.rsplit("/", 1)[1]
            if self.rpc_error: raise http(self.rpc_error)
            if name == "venture_config_get": return self.config
            if name == "record_lead_reply": return self.rpc_reply
            if name in ("create_deal",): return "d9999999-0000"
            if name == "lead_funnel":
                return {"venture": "ottawa-cleanouts", "total": 3, "counts": {"new": 1, "sent": 2}, "replies_by_kind": {"interested": 1},
                        "reply_sla_hours": 24, "replies_over_sla": 1}
            return {}
        if path.startswith("/rest/v1/leads?short_id="):
            n = int(path.split("short_id=eq.")[1].split("&")[0])
            return [l for l in self.leads if l["short_id"] == n][:1]
        if path.startswith("/rest/v1/leads?id="):
            return self.leads[:1]
        if path.startswith("/rest/v1/deals"): return self.deals
        if path.startswith("/rest/v1/contact_suppressions"): return self.suppressed
        if path.startswith("/rest/v1/outbox?id="): return [self.outbox] if self.outbox else []
        if path.startswith("/rest/v1/ventures"):
            vs = [{"id": "v-cl", "slug": "ottawa-cleanouts", "name": "Ottawa Cleanouts Co"}, {"id": "v-donna", "slug": "donna", "name": "Donna"}]
            if "slug=eq.donna" in path: return vs[1:]
            if "id=eq.v-donna" in path: return vs[1:]
            if "id=eq.v-cl" in path or "slug=eq.ottawa-cleanouts" in path: return vs[:1]
            if "slug=eq." in path or "id=eq." in path: return []
            return vs
        return []


class Ops(unittest.TestCase):
    def setUp(self): os.environ["JARVIS_OWNER_ID"] = "42"

    def rpc(self, w, name):
        return [c for c in w.calls if c[1] == "/rest/v1/rpc/" + name]

    def test_reply_kinds_and_lead_lookup(self):
        w = World()
        with mock.patch.object(hq, "_request", w):
            self.assertIn("must be one of", V.record_reply("12", "maybe"))
            self.assertIn("No lead", V.record_reply("99", "interested"))
            self.assertIn("No lead", V.record_reply("abc", "interested"))
            self.assertFalse(w.writes())  # nothing recorded for bad input
            w.rpc_reply = {"status": "replied"}
            self.assertIn("replied", V.record_reply("#12", "Interested", "call tues"))
        c = self.rpc(w, "record_lead_reply")[0][2]
        self.assertEqual((c["p_lead"], c["p_kind"], c["p_by"]), ("L1", "interested", "owner:telegram"))

    def test_unsubscribe_goes_through_the_db_function_and_says_so(self):
        w = World(rpc_reply={"leads_marked": 3, "drafts_rejected": 2})
        with mock.patch.object(hq, "_request", w):
            out = V.record_reply("12", "unsubscribe", "remove me")
        self.assertIn("do-not-contact", out); self.assertIn("3 lead(s)", out); self.assertIn("2 open draft", out)
        self.assertEqual(self.rpc(w, "record_lead_reply")[0][2]["p_kind"], "unsubscribe")

    def test_db_refusal_is_relayed_not_swallowed(self):
        w = World(rpc_error=400)
        with mock.patch.object(hq, "_request", w):
            self.assertIn("db says no", V.record_reply("12", "interested"))
            self.assertIn("db says no", V.deal_move("d1234567", "lost"))

    def test_deal_move_cannot_win_and_validates_stage(self):
        w = World()
        with mock.patch.object(hq, "_request", w):
            self.assertIn("amount", V.deal_move("d1234567", "won"))
            self.assertIn("Stage must be", V.deal_move("d1234567", "closed"))
            self.assertIn("No deal", V.deal_move("ffffffff", "lost"))
            self.assertIn("deal code", V.deal_move("zz", "lost"))
        self.assertFalse(w.writes())

    def test_deal_won_needs_explicit_amount_and_status_and_writes_nothing_otherwise(self):
        w = World()
        with mock.patch.object(hq, "_request", w):
            for args in (("d1234567", "", "received"), ("d1234567", "0", "received"), ("d1234567", "-5", "received"), ("d1234567", "abc", "received"),
                         ("d1234567", "100", ""), ("d1234567", "100", "paid")):
                self.assertNotIn("won. Revenue", V.deal_won(*args))
        self.assertFalse(w.writes())  # no ledger / rpc write without a typed amount and received|expected
        with mock.patch.object(hq, "_request", w):
            out = V.deal_won("d1234567", "$1,250.50", "Received", "inv 7")
        self.assertIn("$1,250.50", out)
        c = self.rpc(w, "confirm_deal_won")
        self.assertEqual(len(c), 1)
        self.assertEqual((c[0][2]["p_amount_cents"], c[0][2]["p_ledger_status"], c[0][2]["p_by"]), (125050, "received", "owner:telegram"))
        self.assertFalse([x for x in w.calls if "/ledger" in x[1]])  # revenue is written by the DB function only, never by the bot directly

    def test_funnel_and_config_text(self):
        with mock.patch.object(hq, "_request", World()):
            t = V.funnel_text("ottawa-cleanouts")
        self.assertIn("new 1 > drafted 0 > approved_to_send 0 > sent 2", t); self.assertIn("interested 1", t); self.assertIn("24h reply SLA: 1", t)
        w = World(config={"venture": "x", "offer": None, "call_to_action": "Book", "reply_sla_hours": 24, "reply_sla_is_default": True,
                          "prospecting_brief_set": False, "drafts_ready": False})
        with mock.patch.object(hq, "_request", w):
            t = V.config_text("ottawa-cleanouts")
        self.assertIn("Offer: NOT SET", t); self.assertIn("NO until both", t); self.assertIn("(default)", t); self.assertIn("NOT SET (prospecting", t)

    def test_set_config_keys(self):
        w = World()
        with mock.patch.object(hq, "_request", w):
            self.assertIn("key must be", V.set_config("ottawa-cleanouts", "price", "x"))
            self.assertIn("Give a value", V.set_config("ottawa-cleanouts", "offer", " "))
            V.set_config("ottawa-cleanouts", "cta", "Reply to book a call")
            V.set_config("ottawa-cleanouts", "offer", "clear")
        calls = [c[2] for c in self.rpc(w, "set_venture_config")]
        self.assertEqual((calls[0]["p_key"], calls[0]["p_value"], calls[0]["p_by"]), ("call_to_action", "Reply to book a call", "owner:telegram"))
        self.assertEqual((calls[1]["p_key"], calls[1]["p_value"]), ("offer", ""))
        with mock.patch.object(hq, "_request", w), mock.patch.object(hq_ventures, "save_procedure", return_value="saved") as sp:
            self.assertEqual(V.set_config("ottawa-cleanouts", "brief", "Find 3+ staff firms in Ottawa"), "saved")
        self.assertEqual(sp.call_args[0][1], "prospecting brief")  # stays in venture_procedures, where queue_prospect_task reads it


class Gate(unittest.TestCase):
    """Every approval path funnels through _outbox_casl_gate -> these checks."""
    OB = {"lead_id": "L1", "to_ref": "A@Acme.co", "channel": "email", "venture_id": "v-cl"}

    def test_dnc_lead_blocks(self):
        w = World(leads=[{"id": "L1", "short_id": 12, "venture_id": "v-cl", "do_not_contact": True}], outbox=self.OB)
        with mock.patch.object(hq, "_request", w):
            self.assertIn("do-not-contact", V.dnc_problem("ob1"))
            slug, problem = C._outbox_casl_gate("ob1")
        self.assertIsNone(slug); self.assertIn("do-not-contact", problem)

    def test_suppressed_address_blocks_even_when_this_lead_is_clean(self):
        w = World(outbox=self.OB, suppressed=[{"address": "a@acme.co"}])
        with mock.patch.object(hq, "_request", w):
            self.assertIn("opted out", V.dnc_problem("ob1"))
        q = [c[1] for c in w.calls if "contact_suppressions" in c[1]][0]
        self.assertIn("a%40acme.co", q)  # the address is lower-cased before the lookup

    def test_clean_lead_passes(self):
        with mock.patch.object(hq, "_request", World(outbox=self.OB)):
            self.assertIsNone(V.dnc_problem("ob1"))

    def test_fails_closed_when_the_list_cannot_be_read(self):
        class Boom(World):
            def __call__(s, method, path, *a, **k):
                if "contact_suppressions" in path: raise http(500)
                return World.__call__(s, method, path, *a, **k)
        with mock.patch.object(hq, "_request", Boom(outbox=self.OB)):
            self.assertIn("could not check", V.dnc_problem("ob1"))
        class Gone(World):
            def __call__(s, method, path, *a, **k):
                if "contact_suppressions" in path: raise http(404)
                return World.__call__(s, method, path, *a, **k)
        with mock.patch.object(hq, "_request", Gone(outbox=self.OB)):
            self.assertIsNone(V.dnc_problem("ob1"))  # migration not applied: the only tolerated failure

    def test_config_problem_fails_closed_except_donna(self):
        with mock.patch.object(hq, "_request", World(config={"drafts_ready": False})):
            self.assertIn("no offer and call to action", V.config_problem("ottawa-cleanouts"))
            self.assertIsNone(V.config_problem("donna")); self.assertIsNone(V.config_problem(None))
        with mock.patch.object(hq, "_request", World(config=[])):
            self.assertIn("no offer", V.config_problem("ottawa-cleanouts"))  # garbage answer = not ready
        with mock.patch.object(hq, "_request", World(rpc_error=500)):
            self.assertIn("could not read", V.config_problem("ottawa-cleanouts"))
        with mock.patch.object(hq, "_request", World(config={"drafts_ready": True})):
            self.assertIsNone(V.config_problem("ottawa-cleanouts"))

    def test_apply_decision_releases_the_tap_and_never_touches_the_draft_for_a_dnc_lead(self):
        # drive the real apply_decision with a world that returns the owner message and a DNC lead
        class W(World):
            def __call__(s, method, path, body=None, **k):
                if path.startswith("/rest/v1/owner_messages") and method == "PATCH":
                    s.calls.append((method, path, body))
                    return [{"id": "m9", "body": "draft", "ref_table": "outbox", "ref_id": "ob123456-0"}] if body and body.get("decision") == "approved" else []
                if path.startswith("/rest/v1/outbox?id=eq.ob123456-0&select"): s.calls.append((method, path, body)); return [s.outbox]
                return World.__call__(s, method, path, body, **k)
        w = W(leads=[{"id": "L1", "short_id": 12, "venture_id": "v-cl", "do_not_contact": True}], outbox=self.OB)
        with mock.patch.object(hq, "_request", w):
            out = C.apply_decision("m9", True)
        self.assertIn("do-not-contact", out)
        self.assertFalse([c for c in w.calls if c[0] == "PATCH" and "/outbox?id=" in c[1]])    # draft never moved
        self.assertFalse([c for c in w.calls if "approved_to_send" in str(c[2])])
        self.assertTrue([c for c in w.calls if "owner_messages" in c[1] and c[2] == {"decision": None, "decided_at": None}])  # tap released


    def test_apply_decision_refuses_a_venture_without_offer_and_cta_but_not_with_them(self):
        FULLP = {"sender_name": "Moe", "brand": "Ottawa Cleanouts Co", "mailing_address": "9 Elm St, Ottawa ON K1A 0A9"}
        class W(World):
            def __call__(s, method, path, body=None, **k):
                if path.startswith("/rest/v1/owner_messages") and method == "PATCH":
                    s.calls.append((method, path, body))
                    return [{"id": "m9", "body": "draft", "ref_table": "outbox", "ref_id": "ob123456-0"}] if body and body.get("decision") == "approved" else []
                if path.startswith("/rest/v1/company_profile"): s.calls.append((method, path, body)); return [FULLP]
                if path.startswith("/rest/v1/outbox?id=eq.ob123456-0&select"): s.calls.append((method, path, body)); return [{**s.outbox, "body": "Hi", "lead_id": "L1"}]
                return World.__call__(s, method, path, body, **k)
        notready = W(outbox=Gate.OB, config={"drafts_ready": False})
        with mock.patch.object(hq, "_request", notready):
            out = C.apply_decision("m9", True)
        self.assertIn("no offer and call to action", out)
        self.assertFalse([c for c in notready.calls if c[0] == "PATCH" and "/outbox?id=" in c[1]])
        self.assertTrue([c for c in notready.calls if "owner_messages" in c[1] and c[2] == {"decision": None, "decided_at": None}])
        ready = W(outbox=Gate.OB)
        with mock.patch.object(hq, "_request", ready):
            out = C.apply_decision("m9", True)
        self.assertIn("Approved. Send this", out)


class Cmds(unittest.TestCase):
    def setUp(self): os.environ["JARVIS_OWNER_ID"] = "42"

    def run_cmd(self, fn, args, uid="42", w=None):
        u = upd(uid); w = w or World()
        with mock.patch.object(hq, "_request", w):
            asyncio.run(fn(u, SimpleNamespace(args=args)))
        return u.message.sent, w

    def test_non_owner_is_ignored(self):
        for fn, args in ((C.hq_reply_cmd, ["12", "unsubscribe"]), (C.hq_deal_cmd, ["won", "d1234567", "100", "received"])):
            sent, w = self.run_cmd(fn, args, uid="7")
            self.assertEqual(sent, []); self.assertFalse(w.calls)

    def test_reply_usage_and_call(self):
        sent, w = self.run_cmd(C.hq_reply_cmd, ["12"])
        self.assertIn("Use: /reply", sent[0]); self.assertFalse(w.calls)
        sent, w = self.run_cmd(C.hq_reply_cmd, ["12", "unsubscribe", "stop", "emailing"], w=World(rpc_reply={"leads_marked": 1, "drafts_rejected": 0}))
        self.assertIn("do-not-contact", sent[0])
        self.assertEqual([c for c in w.calls if "record_lead_reply" in c[1]][0][2]["p_note"], "stop emailing")

    def test_deal_commands(self):
        sent, w = self.run_cmd(C.hq_deal_cmd, ["won", "d1234567"]); self.assertIn("only this records revenue", sent[0]); self.assertFalse(w.writes())
        sent, w = self.run_cmd(C.hq_deal_cmd, ["won", "d1234567", "500", "received", "paid", "by", "etransfer"])
        self.assertEqual([c for c in w.calls if "confirm_deal_won" in c[1]][0][2]["p_note"], "paid by etransfer")
        sent, w = self.run_cmd(C.hq_deal_cmd, ["move", "d1234567", "won"]); self.assertIn("amount", sent[0]); self.assertFalse(w.writes())
        sent, w = self.run_cmd(C.hq_deal_cmd, ["new", "12", "1500"]); self.assertIn("opened at pitched", sent[0])
        sent, w = self.run_cmd(C.hq_deal_cmd, ["list"]); self.assertIn("[pitched]", sent[0])
        sent, w = self.run_cmd(C.hq_deal_cmd, ["bogus"]); self.assertIn("/deal won", sent[0])

    def test_venture_config_funnel_deals_subcommands(self):
        sent, w = self.run_cmd(C.hq_venture_cmd, ["funnel", "ottawa-cleanouts"]); self.assertIn("lead funnel", sent[0])
        sent, w = self.run_cmd(C.hq_venture_cmd, ["config", "ottawa-cleanouts"]); self.assertIn("operating config", sent[0])
        sent, w = self.run_cmd(C.hq_venture_cmd, ["config", "ottawa-cleanouts", "offer", "Weekly", "garage", "cleanouts"])
        self.assertEqual([c for c in w.calls if "set_venture_config" in c[1]][0][2]["p_value"], "Weekly garage cleanouts")
        sent, w = self.run_cmd(C.hq_venture_cmd, ["config"]); self.assertIn("Use: /venture config", sent[0])
        sent, w = self.run_cmd(C.hq_venture_cmd, ["config", "nope-venture"]); self.assertIn("No venture", sent[0])
        sent, w = self.run_cmd(C.hq_venture_cmd, ["deals"]); self.assertIn("Deals:", sent[0])

    def test_registered_and_in_menu(self):
        names = []
        app = SimpleNamespace(add_handler=lambda h: names.append(h.args[0]), job_queue=None)
        C.register_venture2(app, lambda n, f: SimpleNamespace(args=(n, f)))
        self.assertEqual(names, ["reply", "deal"])
        self.assertTrue({"reply", "deal"} <= {m[0] for m in C.MENU})


class Kpis(unittest.TestCase):
    def test_kpis_text_includes_funnel_and_still_works_on_an_old_database(self):
        base = {"venture": "acme", "leads": 4, "emailable_leads": 2, "drafted": 3, "approved": 2, "sent": 1, "won_deals": 1,
                "deals_by_stage": {"won": 1}, "revenue_cents": 123456}
        new = {**base, "funnel": {"new": 1, "sent": 2, "won": 1, "other": 1}, "replies_by_kind": {"booked": 1}, "replies_over_sla": 2, "reply_sla_hours": 48}
        with mock.patch.object(hq_ventures, "kpis", return_value=new):
            t = hq_ventures.kpis_text("acme")
        self.assertIn("Funnel: new 1 > drafted 0", t); self.assertIn("(other 1)", t); self.assertIn("booked 1; over the 48h SLA: 2", t)
        with mock.patch.object(hq_ventures, "kpis", return_value=base):
            t = hq_ventures.kpis_text("acme")
        self.assertNotIn("Funnel", t); self.assertIn("Revenue received $1,234.56", t)


if __name__ == "__main__":
    unittest.main()
