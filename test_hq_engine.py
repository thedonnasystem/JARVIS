import unittest, urllib.error, io, json
from unittest import mock
import hq, hq_engine as E


def http_err(code, msg):
    return urllib.error.HTTPError("u", code, msg, {}, io.BytesIO(json.dumps({"message": msg}).encode()))


class Board:
    """Fake HQ database behind hq._request."""
    def __init__(self, tasks=None, escalations=None, kill=False, block=False):
        self.tasks = tasks or []; self.esc = escalations or []; self.kill = kill; self.block = block
        self.patches = []; self.inserts = []; self.rpcs = []

    def __call__(self, method, path, body=None, timeout=30, prefer=None):
        if path.startswith("/rest/v1/rpc/"):
            name = path.split("/")[-1]; self.rpcs.append((name, body))
            if name == "reserve_llm_budget" and self.block:
                raise http_err(400, "daily cap reached")
            return {"estimate_call_cents": 1}.get(name, 1 if name != "reserve_llm_budget" else "call-1")
        if method == "GET":
            if path.startswith("/rest/v1/system_state"): return [{"kill_switch": self.kill}]
            if path.startswith("/rest/v1/agents"): return [{"slug": "x", "title": "X", "model_tier": "cheap", "role": "r", "metric": "m", "charter": "c"}]
            if path.startswith("/rest/v1/handbook"): return [{"content": "rules"}]
            if path.startswith("/rest/v1/tasks"): return list(self.tasks)
            if path.startswith("/rest/v1/escalations"): return list(self.esc)
        if method == "PATCH":
            self.patches.append((path, body)); return [{"id": 1}] if prefer == "return=representation" else None
        if method == "POST":
            self.inserts.append((path, body)); return None


class T(unittest.TestCase):
    def run_tick(self, board, reply="done"):
        with mock.patch.object(hq, "_request", board), mock.patch.object(E, "_complete", return_value=(reply, 10, 5, 0)):
            E.tick_sync()

    def test_search_flag_and_cost(self):
        self.assertTrue(E.can_search("real-estate-researcher")); self.assertTrue(E.can_search("donna-auditor"))
        self.assertFalse(E.can_search("ceo")); self.assertFalse(E.can_search("jarvis"))
        b = Board(tasks=[{"id": "t1", "assigned_agent": "real-estate-researcher", "title": "T", "detail": ""}])
        with mock.patch.object(hq, "_request", b), mock.patch.object(E, "_complete", return_value=("ok", 10, 5, 2)) as c:
            E.tick_sync()
        self.assertTrue(c.call_args[0][4] is True)
        settle = [r for r in b.rpcs if r[0] == "settle_llm_call"][0][1]
        self.assertEqual(settle["p_actual_cents"], 1 + 2 * E.SEARCH_CENTS)

    def test_stale_doing_tasks_requeued(self):
        b = Board()
        self.run_tick(b)
        self.assertTrue(any("status=eq.doing" in p[0] and p[1].get("status") == "todo" for p in b.patches))

    def test_plan_creates_guarded_tasks(self):
        plan = '[{"agent":"donna-researcher","title":"A","detail":"d","expected_cad":500,"days_to_cash":10},{"agent":"ghost","title":"B","detail":"d","expected_cad":1,"days_to_cash":1},{"agent":"jarvis","title":"C","detail":"d","expected_cad":1,"days_to_cash":1},{"agent":"donna-researcher","title":"D","detail":"d"},{"agent":"donna-researcher","title":"E","detail":"d"}]'
        b = Board(tasks=[{"id": "t1", "assigned_agent": "jarvis", "title": "Daily planning 2026-11-02", "detail": ""}])
        orig = b.__call__
        def fake(method, path, body=None, timeout=30, prefer=None):
            if path.startswith("/rest/v1/agents?status=eq.active"): return [{"slug": "donna-researcher"}, {"slug": "jarvis"}]
            return orig(method, path, body, timeout, prefer)
        with mock.patch.object(hq, "_request", fake), mock.patch.object(E, "_complete", return_value=(plan, 10, 5, 0)):
            E.tick_sync()
        made = [i for i in b.inserts if i[0].endswith("/tasks")]
        self.assertEqual([m[1]["title"] for m in made], ["A"])  # only the first 3 proposals are read; ghost and self-assigned are skipped
        self.assertIn("No contacting anyone", made[0][1]["detail"])
        self.assertEqual(made[0][1]["priority"], 2)  # cash within 14 days runs first
        self.assertIn("$500 CAD within 10 days", made[0][1]["detail"])

    def test_plan_without_value_is_rejected(self):
        with mock.patch.object(hq, "_request", Board()):
            self.assertEqual(E._apply_plan('[{"agent":"x","title":"A","detail":"d"}]', "jarvis"), 0)

    def test_research_task_logs_prediction_and_queues_audit(self):
        b = Board(tasks=[{"id": "t1", "assigned_agent": "donna-researcher", "title": "Map", "detail": ""}])
        self.run_tick(b, "Found it. Source: https://example.com/page.")
        pred = [i for i in b.inserts if i[0].endswith("/predictions")][0][1]
        self.assertTrue(pred["correct"]); self.assertEqual(pred["action_ref"], "task:t1")
        audit = [i for i in b.inserts if i[0].endswith("/tasks")][0][1]
        self.assertEqual(audit["assigned_agent"], "donna-auditor"); self.assertTrue(audit["title"].startswith("Audit: "))
        self.assertIn("<<<", audit["detail"])

    def test_cut_off_or_unsourced_research_is_a_wrong_prediction(self):
        b = Board(tasks=[{"id": "t1", "assigned_agent": "donna-researcher", "title": "Map", "detail": ""}])
        self.run_tick(b, "Found it, and then the answer stops mid sen")
        self.assertFalse([i for i in b.inserts if i[0].endswith("/predictions")][0][1]["correct"])

    def test_audit_of_audit_not_queued_and_fail_escalates(self):
        b = Board(tasks=[{"id": "t2", "assigned_agent": "donna-auditor", "title": "Audit: Map", "detail": ""}])
        self.run_tick(b, "Claim 2 is wrong.\nVERDICT: FAIL, price outdated.")
        self.assertFalse([i for i in b.inserts if i[0].endswith("/tasks")])
        self.assertTrue([i for i in b.inserts if i[0].endswith("/escalations")])

    def test_task_done(self):
        b = Board(tasks=[{"id": "t1", "assigned_agent": "x", "title": "T", "detail": "d"}])
        self.run_tick(b)
        self.assertTrue(any(p[1].get("status") == "done" for p in b.patches))
        self.assertIn("settle_llm_call", [r[0] for r in b.rpcs])

    def test_escalate_creates_escalation(self):
        b = Board(tasks=[{"id": "t1", "assigned_agent": "x", "title": "T", "detail": ""}])
        self.run_tick(b, "ESCALATE needs contract")
        self.assertTrue(any("escalations" in p[0] for p in b.inserts))
        self.assertTrue(any(p[1].get("status") == "blocked" for p in b.patches))

    def test_gateway_block_returns_task(self):
        b = Board(tasks=[{"id": "t1", "assigned_agent": "x", "title": "T", "detail": ""}], block=True)
        self.run_tick(b)
        self.assertTrue(any(p[1].get("status") == "todo" for p in b.patches))

    def test_kill_switch_does_nothing(self):
        b = Board(tasks=[{"id": "t1", "assigned_agent": "x", "title": "T", "detail": ""}], kill=True)
        self.run_tick(b)
        self.assertEqual(b.patches, []); self.assertEqual(b.rpcs, [])

    def test_triage_send_to_owner(self):
        b = Board(escalations=[{"id": "e1", "from_agent": "x", "kind": "uncertain", "summary": "sign this"}])
        self.run_tick(b, '{"action":"send_to_owner","kind":"contract","message":"Sign X"}')
        om = [i for i in b.inserts if "owner_messages" in i[0]]
        self.assertEqual(om[0][1]["kind"], "contract")

    def test_triage_bad_kind_defaults_and_bad_json_surfaces(self):
        b = Board(escalations=[{"id": "e1", "from_agent": "x", "kind": "u", "summary": "s"}])
        self.run_tick(b, '{"action":"send_to_owner","kind":"weird","message":"m"}')
        self.assertEqual([i for i in b.inserts if "owner_messages" in i[0]][0][1]["kind"], "proposal")
        b2 = Board(escalations=[{"id": "e2", "from_agent": "x", "kind": "u", "summary": "s"}])
        self.run_tick(b2, "not json")
        self.assertFalse(any("owner_messages" in i[0] for i in b2.inserts))  # no raw dumps on the owner
        self.assertTrue(any(p[1].get("status") == "closed" for p in b2.patches))

    def test_parse_decision_handles_raw_newlines(self):
        d = E._parse_decision('{"action": "send_to_owner", "kind": "contract", "message": "line one\nline "two""}')
        self.assertEqual(d["action"], "send_to_owner")
        self.assertEqual(d["kind"], "contract")
        self.assertIn("line one", d["message"])

    def test_auditor_facts_saved_to_memory(self):
        b = Board()
        t = {"id": "a1", "assigned_agent": "real-estate-auditor", "title": "Audit: x", "venture_id": "v1"}
        text = ("VERDICT: PASS WITH FIXES. ok\nFACTS:\n"
                "- RECO registration is required to trade in real estate in Ontario | https://www.reco.on.ca/x | high\n"
                "- too short | https://a.b | high\n"
                "- No source on this one at all | medium\n")
        with mock.patch.object(hq, "_request", b):
            self.assertEqual(E._store_facts(t, text), 1)
        row = [i[1] for i in b.inserts if "memory" in i[0]][0]
        self.assertEqual((row["kind"], row["confidence"], row["venture_id"]), ("fact", "high", "v1"))
        self.assertTrue(row["source"].startswith("https://www.reco.on.ca"))

    def test_audit_fail_becomes_lesson_not_fact(self):
        b = Board()
        t = {"id": "a1", "assigned_agent": "donna-auditor", "title": "Audit: y", "venture_id": "v2"}
        with mock.patch.object(hq, "_request", b):
            E._store_facts(t, "VERDICT: FAIL prices were made up\nFACTS:\n- A fact that should not save | https://x.y/z | high")
        kinds = [i[1]["kind"] for i in b.inserts if "memory" in i[0]]
        self.assertEqual(kinds, ["lesson"])

    def test_non_auditor_never_writes_memory(self):
        b = Board()
        with mock.patch.object(hq, "_request", b):
            E._store_facts({"id": "r", "assigned_agent": "donna-researcher", "title": "t"}, "FACTS:\n- Something long enough here | https://x.y | high")
        self.assertFalse(b.inserts)

    def test_leads_saved_deduped_and_locked(self):
        b = Board()
        t = {"id": "r1", "assigned_agent": "donna-researcher", "title": "List HVAC", "venture_id": "v3"}
        text = ("Here you go.\nLEADS:\n"
                "- Cool Air Ottawa | https://coolair.example.ca | 8 trucks, web form only\n"
                "- Cool Air Ottawa | https://coolair.example.ca | duplicate\n"
                "- Warm Co | https://warm.example.ca | 40 reviews\n")
        with mock.patch.object(hq, "_request", b):
            self.assertEqual(E._store_leads(t, text), 2)
        rows = [i[1] for i in b.inserts if "leads" in i[0]]
        self.assertTrue(all(r["do_not_contact"] and r["status"] == "new" for r in rows))

    def test_complete_keeps_final_answer_and_flags_truncation(self):
        from types import SimpleNamespace as N
        resp = N(content=[N(type="text", text="I'll search now."), N(type="server_tool_use"), N(type="web_search_tool_result"),
                          N(type="text", text="VERDICT: PASS ok\nFACTS:")],
                 stop_reason="max_tokens", usage=N(input_tokens=1, output_tokens=2, server_tool_use=N(web_search_requests=1)))
        client = mock.Mock(); client.messages.create.return_value = resp
        with mock.patch.object(E, "_anthropic", return_value=client):
            text, _, _, s = E._complete("m", "sys", "u", 10, search=True)
        self.assertTrue(text.startswith("VERDICT: PASS"))
        self.assertIn("TRUNCATED", text)
        self.assertEqual(s, 1)

    def test_triage_contract_gets_decision_buttons(self):
        b = Board(escalations=[{"id": "e9", "from_agent": "x", "kind": "u", "summary": "s"}])
        self.run_tick(b, '{"action":"send_to_owner","kind":"contract","message":"Sign the pilot?"}')
        row = [i[1] for i in b.inserts if "owner_messages" in i[0]][0]
        self.assertEqual((row["needs_decision"], row["ref_table"], row["ref_id"]), (True, "escalations", "e9"))

    def test_weekly_review_proposals_get_buttons(self):
        b = Board()
        t = {"id": "w", "assigned_agent": "jarvis", "title": "Weekly company self-review"}
        text = ("1. ...\nPROPOSAL: Move auditors to the cheap model | gain: save $5/week | cost: none | risk: weaker audits\n"
                "- **PROPOSAL:** Add a lead scraper for Ottawa HVAC | gain: 50 leads | cost: $10 | risk: low\n"
                "PROPOSAL: a | b\nPROPOSAL: Fourth one should be dropped because max is three | gain: x | cost: y | risk: z\n"
                "PROPOSAL: Third valid proposal here | gain: g | cost: c | risk: r\n")
        with mock.patch.object(hq, "_request", b):
            self.assertEqual(E._send_proposals(t, text), 3)
        rows = [i[1] for i in b.inserts if "owner_messages" in i[0]]
        self.assertTrue(all(r["needs_decision"] and r["kind"] == "proposal" for r in rows))
        self.assertIn("cheap model", rows[0]["body"])

    def test_first_tick_after_start_releases_orphans(self):
        b = Board()
        E._started = False
        with mock.patch.object(hq, "_request", b):
            E._recover_stale()
            first = list(b.patches)
            E._recover_stale()
        self.assertTrue(any("llm_calls?status=eq.reserved" in p[0] and p[1]["status"] == "released" for p in first))
        self.assertEqual(sum("llm_calls" in p[0] for p in b.patches), 1)  # only on the first tick

    def test_unblock_matches_title_with_colons(self):
        b = Board(tasks=[{"id": "t1", "title": "Finish: call rules"}, {"id": "t2", "title": "Other"}])
        with mock.patch.object(hq, "_request", b):
            self.assertEqual(E.unblock_task_for("Finish: call rules: ESCALATE legal flag"), 1)
        self.assertTrue(any("tasks?id=eq.t1" in p[0] and p[1]["status"] == "done" for p in b.patches))

    def test_error_retries_once_then_blocks(self):
        b = Board(tasks=[{"id": "t1", "assigned_agent": "x", "title": "T", "detail": "", "result": None}])
        with mock.patch.object(hq, "_request", b), mock.patch.object(E, "_complete", side_effect=RuntimeError("overloaded")):
            E._work_tasks()
        last = [p[1] for p in b.patches if "tasks?id=eq.t1" in p[0]][-1]
        self.assertEqual(last["status"], "todo")
        self.assertTrue(last["result"].startswith(E.RETRY_MARK) and "due_at" in last)
        b2 = Board(tasks=[{"id": "t1", "assigned_agent": "x", "title": "T", "detail": "", "result": E.RETRY_MARK + " overloaded"}])
        with mock.patch.object(hq, "_request", b2), mock.patch.object(E, "_complete", side_effect=RuntimeError("overloaded")):
            E._work_tasks()
        self.assertEqual([p[1] for p in b2.patches if "tasks?id=eq.t1" in p[0]][-1]["status"], "blocked")

    def test_drafts_go_to_outbox_never_sent(self):
        class B(Board):
            def __call__(s, method, path, body=None, timeout=30, prefer=None):
                if method == "GET" and path.startswith("/rest/v1/leads"):
                    return [{"id": "L7", "source": "https://coolair.example.ca", "email": "info@coolair.example.ca"}]
                return Board.__call__(s, method, path, body, timeout, prefer)
        b = B()
        t = {"id": "d1", "assigned_agent": "donna-division", "title": "Draft outreach for 5 HVAC leads", "venture_id": "vd"}
        text = ("DRAFT #7\nSubject: Missed calls cost you jobs\nBody:\nHi team,\nWe answer every lead in 60 seconds.\n"
                "Reply STOP to opt out.\nEND DRAFT\n")
        with mock.patch.object(hq, "_request", b):
            self.assertEqual(E._store_drafts(t, text), 1)
        row = [i[1] for i in b.inserts if "outbox" in i[0]][0]
        self.assertEqual((row["status"], row["needs_owner"], row["lead_id"]), ("draft", True, "L7"))
        self.assertTrue(row["body"].startswith("Subject: Missed calls"))
        self.assertEqual(row["to_ref"], "info@coolair.example.ca")

    def test_ideas_parsed_and_clamped(self):
        b = Board()
        t = {"id": "i1", "assigned_agent": "new-ventures-researcher", "title": "Shortlist"}
        text = ("IDEA: Gutter guard installs | sell and install guards in Barrhaven | 4 | $350 | 3 | https://ex.ca/demand | under 3 quotes in 7 days\n"
                "IDEA: Bad row | missing fields | 3\n"
                "- **IDEA:** Pet waste pickup | weekly yard service | 9 | 120.50 | 0 | https://ex.ca/2 | fewer than 5 signups\n")
        with mock.patch.object(hq, "_request", b):
            self.assertEqual(E._store_ideas(t, text), 2)
        rows = [i[1] for i in b.inserts if "ideas" in i[0]]
        self.assertEqual((rows[0]["startup_cost_cents"], rows[1]["speed_to_cash"], rows[1]["effort"]), (35000, 5, 1))

    def test_next_lines_queue_followups_with_guards(self):
        class B(Board):
            def __call__(s, method, path, body=None, timeout=30, prefer=None):
                if method == "GET" and path.startswith("/rest/v1/agents"):
                    return [{"slug": "donna-researcher", "venture_id": "vd"}, {"slug": "jarvis", "venture_id": None}]
                if method == "GET" and path.startswith("/rest/v1/tasks"):
                    return [{"title": "Already queued thing"}]
                return Board.__call__(s, method, path, body, timeout, prefer)
        b = B()
        t = {"id": "x1", "assigned_agent": "donna-researcher", "title": "Competitor map", "detail": "do it"}
        text = ("NEXT: donna-researcher | Price check on Podium vendor pages | Open each vendor pricing page and list plan prices with URLs\n"
                "NEXT: jarvis | Plan things | jarvis should never get chained work here\n"
                "NEXT: donna-researcher | Already queued thing | duplicate title should be skipped entirely\n")
        with mock.patch.object(hq, "_request", b):
            self.assertEqual(E._queue_next(t, text), 1)
        row = [i[1] for i in b.inserts if "tasks" in i[0]][0]
        self.assertIn("[chain 1]", row["detail"])
        self.assertEqual(row["venture_id"], "vd")
        deep = dict(t, detail="x [chain 2] y")
        with mock.patch.object(hq, "_request", B()):
            self.assertEqual(E._queue_next(deep, text), 0)

    def test_lead_email_sets_casl_basis(self):
        b = Board()
        t = {"id": "r2", "assigned_agent": "donna-researcher", "title": "List HVAC", "venture_id": "v3"}
        text = ("LEADS:\n"
                "- Cool Air | https://coolair.example.ca | 8 trucks | info@coolair.example.ca | no\n"
                "- Quiet Co | https://quiet.example.ca | small | office@quiet.example.ca | yes\n"
                "- Form Only | https://form.example.ca | web form | https://form.example.ca/contact | no\n")
        with mock.patch.object(hq, "_request", b):
            self.assertEqual(E._store_leads(t, text), 3)
        rows = {r["name"]: r for r in [i[1] for i in b.inserts if "leads" in i[0]]}
        self.assertFalse(rows["Cool Air"]["do_not_contact"]); self.assertEqual(rows["Cool Air"]["email"], "info@coolair.example.ca")
        self.assertTrue(rows["Quiet Co"]["do_not_contact"])
        self.assertTrue(rows["Form Only"]["do_not_contact"]); self.assertIn("contact page", rows["Form Only"]["notes"])

    def test_fetch_rejected_falls_back_to_search_only(self):
        from types import SimpleNamespace as N
        ok = N(content=[N(type="text", text="answer")], stop_reason="end_turn",
               usage=N(input_tokens=1, output_tokens=1, server_tool_use=None))
        client = mock.Mock(); client.messages.create.side_effect = [RuntimeError("unknown tool type web_fetch_20260318"), ok]
        with mock.patch.object(E, "_anthropic", return_value=client):
            text, *_ = E._complete("m", "s", "u", 10, search=True)
        self.assertEqual(text, "answer")
        self.assertEqual(len(client.messages.create.call_args_list[1].kwargs["tools"]), 1)

    def test_valuations_parsed_sanity_checked_and_downgraded(self):
        lid = "11111111-2222-3333-4444-555555555555"
        text = (f"VALUATION: {lid} | ARV $310,000 | low 290,000 | high 330,000 | repairs 45,000 | medium | "
                "https://a.ca/1 https://a.ca/2 https://a.ca/3\n"
                f"VALUATION: {lid} | ARV 300000 | low 350000 | high 360000 | repairs 1 | high | https://a.ca/1\n"
                f"VALUATION: {lid} | ARV 200000 | low 190000 | high 210000 | repairs 30000 | high | https://a.ca/1 https://a.ca/1\n")
        vs = E.parse_valuations(text)
        self.assertEqual(len(vs), 2)  # low > ARV is dropped
        self.assertEqual((vs[0]["arv"], vs[0]["confidence"], len(vs[0]["comps"])), (310000, "medium", 3))
        self.assertEqual(vs[1]["confidence"], "low")  # one unique comp cannot be "high"

    def test_valuation_mao_uses_low_arv(self):
        import hq_wholesale as W
        self.assertEqual(W.mao(290000, 45000), 290000 * 0.70 - 45000 - 15000)

    def test_draft_with_placeholder_is_dropped(self):
        class B(Board):
            def __call__(s, method, path, body=None, timeout=30, prefer=None):
                if method == "GET" and path.startswith("/rest/v1/leads"):
                    return [{"id": "L7", "source": "x", "email": "info@x.ca"}]
                return Board.__call__(s, method, path, body, timeout, prefer)
        b = B()
        t = {"id": "d2", "assigned_agent": "donna-division", "title": "Draft outreach for new donna leads", "venture_id": "vd"}
        text = "DRAFT #7\nSubject: Hi\nBody:\nI'm [Name]. [OFFER]\nReply stop to opt out.\nEND DRAFT\n"
        with mock.patch.object(hq, "_request", b):
            self.assertEqual(E._store_drafts(t, text), 0)

    def test_knowledge_puts_decisions_first(self):
        seen = []
        def fake(method, path, body=None, timeout=30, prefer=None):
            seen.append(path)
            if "kind=in.(decision,lesson)" in path:
                return [{"kind": "decision", "content": "Offer: AI receptionist $297-397/mo", "confidence": "high"}]
            if "kind=eq.fact" in path:
                return [{"kind": "fact", "content": f"fact {len(seen)}", "source": "https://x", "confidence": "high"}]
            return []
        with mock.patch.object(hq, "_request", fake):
            out = E._company_knowledge("vd")
        self.assertLess(out.index("Offer: AI receptionist"), out.index("fact"))
        self.assertTrue(all("or=(" not in p for p in seen))  # no duplicate or= params

    def test_leads_dedupe_by_email(self):
        b = Board()
        t = {"id": "r3", "assigned_agent": "donna-researcher", "title": "List", "venture_id": "v3"}
        text = ("LEADS:\n- Brown's | https://b.ca | x | info@b.ca | no\n"
                "- Brown's Entrepreneur Specialise | https://b.ca/fr | y | INFO@b.ca | no\n")
        with mock.patch.object(hq, "_request", b):
            self.assertEqual(E._store_leads(t, text), 1)

    def test_fetch_budget_by_task(self):
        self.assertEqual(E.fetch_budget("Task: Find Donna prospects: HVAC, Kingston\n\nx"), E.FETCH_HEAVY)
        self.assertEqual(E.fetch_budget("Task: Value fixer leads 2026-11-02"), E.FETCH_HEAVY)
        self.assertEqual(E.fetch_budget("Task: Competitor map\nFind Donna prospects later"), E.MAX_FETCHES)

    def test_measured_cost_uses_recent_actuals(self):
        rows = [{"actual_cents": c} for c in (3, 20, 25, 30, 85, 178)]
        with mock.patch.object(hq, "_request", lambda *a, **k: rows):
            self.assertGreaterEqual(E.measured_cost("real-estate-researcher"), 85)
        with mock.patch.object(hq, "_request", lambda *a, **k: []):
            self.assertEqual(E.measured_cost("x"), 0)

    def test_planner_cannot_send_real_estate_house_hunting(self):
        b = Board()
        orig = b.__call__
        def fake(method, path, body=None, timeout=30, prefer=None):
            if path.startswith("/rest/v1/agents?status=eq.active"):
                return [{"slug": "real-estate-researcher", "venture_id": "vr"}]
            return orig(method, path, body, timeout, prefer)
        plan = ('[{"agent":"real-estate-researcher","title":"Find 5 distressed private-seller houses","detail":"d","expected_cad":15000,"days_to_cash":30},'
                '{"agent":"real-estate-researcher","title":"Build a cash buyer list for Ottawa","detail":"buyers","expected_cad":15000,"days_to_cash":30}]')
        with mock.patch.object(hq, "_request", fake):
            self.assertEqual(E._apply_plan(plan, "jarvis"), 1)

    def test_triage_close(self):
        b = Board(escalations=[{"id": "e1", "from_agent": "x", "kind": "u", "summary": "s"}])
        self.run_tick(b, '{"action":"close","message":"fine"}')
        self.assertTrue(any(p[1].get("status") == "closed" for p in b.patches))
        self.assertFalse(any("owner_messages" in i[0] for i in b.inserts))


if __name__ == "__main__":
    unittest.main()
