"""Integration test: the REAL hq_engine / hq_missions Python runs against the replica Postgres (all migrations applied), with only the
model call itself scripted. Exercises the spend gateway, mission lifecycle triggers, step limit, mission budget, focus mode and the
no-external-action rule through the same hq._request calls production uses. Run by scripts/replica/run.sh (needs psycopg2)."""
import os
import sys
from unittest import mock

root = os.path.join(os.path.dirname(__file__), "..", "..")
sys.path.insert(0, root); sys.path.insert(0, os.path.dirname(__file__))
os.environ.setdefault("HQ_SUPABASE_URL", "http://localhost"); os.environ.setdefault("HQ_SUPABASE_SERVICE_KEY", "x")

import hq, hq_engine as E, hq_missions as M  # noqa: E402
from pg_adapter import PgAdapter  # noqa: E402

db = PgAdapter(os.environ["REPLICA_URL"])
fails = []


def check(name, cond, extra=""):
    print(("ok   " if cond else "FAIL ") + name + (f"  [{extra}]" if (extra and not cond) else ""))
    if not cond:
        fails.append(name)


# ---- scripted model: the only fake. Real parsers must accept this text.
EVAL = ("MISSION_VERDICT: GO — cheap to test, real demand\nNUMBERS: startup cost CAD 0 | expected profit CAD 1500 | days to first cash 21 | confidence low\n"
        "SUCCESS: three markets compared with sources and one recommendation\nRISKS: thin local data\n"
        + "".join(f"STEP: new-ventures-researcher | Research part {i} | investigate part {i} and cite sources\n" for i in range(1, 7)))
STEP = ("Findings with sources: three markets compared with prices https://example.ca/a and options compared with prices; "
        "recommendation supported by https://example.ca/b. Recommendation: option 2.")
VERIFY = "VERIFIED: YES\nEVIDENCE: three markets compared with prices | https://example.ca/a\nEVIDENCE: recommendation supported | https://example.ca/b\n"
script_log = []


SCRIPT = {"verify_calls": 0, "repairs": 0, "mode": "default"}
EVAL_SMALL = ("**MISSION_VERDICT:** GO — cheap to test\n1. **NUMBERS:** startup cost CAD 0 | expected profit CAD 900 | days to first cash 14\n"
              "**SUCCESS:** two options compared with sources\n**RISKS:** thin data\n"
              "**STEP 1:** new-ventures-researcher | Research option one | investigate option one and cite sources\n"
              "**STEP 2:** new-ventures-researcher | Research option two | investigate option two and cite sources\n")
VERIFY_FAKE = "VERIFIED: YES\nEVIDENCE: demand is proven | https://invented.example/report\n"
VERIFY_GOOD = "**Verified:** YES\n- **Evidence:** options compared with prices | https://example.ca/a.\n- Evidence: recommendation supported | https://example.ca/b\n"


def fake_complete(model, system, user, max_tokens, search=False, fetches=None):
    script_log.append(user[:60])
    if SCRIPT["mode"] == "resilience":
        if "FORMAT REPAIR" in user:
            SCRIPT["repairs"] += 1
            return (EVAL_SMALL if "MISSION_VERDICT" in user else VERIFY_GOOD), 800, 300, 0
        if "Re-plan this mission" in user or "MISSION OBJECTIVE" in user:
            first = not SCRIPT.get("eval_seen")
            SCRIPT["eval_seen"] = True
            return ("Sounds like a decent idea to me, let's go." if first else EVAL_SMALL), 1000, 400, 0
        if "Independently verify" in user:
            SCRIPT["verify_calls"] += 1
            return (VERIFY_FAKE if SCRIPT["verify_calls"] == 1 else "Looks fine, I re-checked the sources."), 3000, 300, 0
        return STEP, 1500, 500, 0
    if "Re-plan this mission" in user or "MISSION OBJECTIVE" in user:
        return EVAL, 1000, 400, 0
    if "Independently verify" in user:
        return VERIFY, 3000, 300, 0
    return STEP, 1500, 500, 0


# ---- seed: agents, venture, a fixed 25c-per-call price so budgets are easy to reason about
db.sql("""create or replace function public.estimate_call_cents(p_model text, p_input_tokens int, p_max_output_tokens int) returns int language sql as $$ select 25 $$""")
for slug in ("new-ventures-researcher", "new-ventures-auditor"):
    db.sql("insert into agents (slug, title, charter, metric, status, daily_spend_cap_cents) values (%s, %s, 'c', 'm', 'active', 100000) on conflict (slug) do update set status='active', daily_spend_cap_cents=100000", (slug, slug))
db.sql("update system_state set daily_spend_cap_cents = 100000, kill_switch = false, pause_reason = null, mode = 'dry_run', focus_mission = null where id = 1")
db.sql("insert into ventures (slug, name, kind, status) select 'idea-lab', 'Idea Lab', 'lab', 'active' where not exists (select 1 from ventures where slug = 'idea-lab')")
db.sql("delete from tasks where mission_id is not null or title like 'BACKLOG%'")
db.sql("delete from missions")


def run_cycles(n=14):
    with mock.patch.object(hq, "_request", db), mock.patch.object(E, "_complete", side_effect=fake_complete):
        for _ in range(n):
            E._FOCUS = db.sql("select focus_mission f from system_state where id = 1")[0]["f"]   # what tick_sync does at the start of every tick
            E._work_tasks()
            M.advance()


def mission(mid):
    return db.sql("select * from missions where id = %s", (mid,))[0]


# ===== A. the first-mission configuration: 4 steps, 200c, focus on, a backlog task that must not run
with mock.patch.object(hq, "_request", db):
    r = M.create_mission("Research three niche markets for a digital service that can be started with $0 upfront capital in Ottawa and recommend the strongest opportunity.",
                         budget_cents=200, max_steps=4)
mid = r["id"]
check("mission created with budget 200 and 4 strict steps", mission(mid)["budget_cents"] == 200 and mission(mid)["max_steps"] == 4 and mission(mid)["strict_steps"])
bk = db.sql("insert into tasks (title, assigned_agent, status, created_by, priority) values ('BACKLOG daily planning', 'new-ventures-researcher', 'todo', 'system', 1) returning id")[0]["id"]
db.sql("select set_focus_mission(%s, 'owner:integration')", (mid,))
sent0 = db.sql("select count(*) c from outbox where status = 'sent'")[0]["c"]
t0 = db.sql("select clock_timestamp() t")[0]["t"]
run_cycles(16)
m = mission(mid)
check("mission reaches completed with real parsers + real triggers", m["status"] == "completed", f"status={m['status']} next={m['next_action']}")
steps = db.sql("select * from tasks where mission_id = %s and mission_role = 'step'", (mid,))
check("exactly 4 step tasks despite the model proposing 6", len(steps) == 4, str(len(steps)))
check("every step has an assigned agent and stored output", all(s["assigned_agent"] and s["result"] and s["status"] == "done" for s in steps))
check("verification and evaluation are not counted as steps", len(db.sql("select 1 from tasks where mission_id = %s and mission_role in ('eval','verify')", (mid,))) == 2)
check("evidence stored with sources", len(m["evidence"]) >= 1 and "example.ca" in str(m["evidence"]))
spent = db.sql("select mission_spent_cents(%s) s", (mid,))[0]["s"]
check("mission spend recorded and within the 200c budget", 0 < spent <= 200, str(spent))
check("backlog task untouched in focus mode", db.sql("select status from tasks where id = %s", (bk,))[0]["status"] == "todo")
check("no non-mission AI calls were made", db.sql("select count(*) c from llm_calls where started_at >= %s and purpose not in (select 'task '||id from tasks where mission_id = %s)", (t0, mid))[0]["c"] == 0)
check("no outbox row was sent (dry run)", db.sql("select count(*) c from outbox where status = 'sent'")[0]["c"] == sent0)
check("mode still dry_run", db.sql("select mode from system_state where id = 1")[0]["mode"] == "dry_run")
check("state changes audited", db.sql("select count(*) c from audit_log where action in ('mission_captured','mission_planned','focus_set')")[0]["c"] >= 3)
db.sql("select set_focus_mission(null, 'owner:integration')")
check("focus cleared and audited", db.sql("select count(*) c from audit_log where action = 'focus_cleared'")[0]["c"] >= 1)
E._FOCUS = None
with mock.patch.object(hq, "_request", db), mock.patch.object(E, "_complete", side_effect=fake_complete):
    E._work_tasks()
check("after cleanup the backlog runs again", db.sql("select status from tasks where id = %s", (bk,))[0]["status"] == "done")

# ===== B. a mission whose budget runs out: the gateway refuses, the board is NOT stalled, the mission stops and says why
db.sql("delete from tasks where mission_id is not null"); db.sql("delete from missions")
with mock.patch.object(hq, "_request", db):
    mid2 = M.create_mission("Second mission with a very small AI budget to prove the hard stop", budget_cents=60)["id"]
other = db.sql("insert into tasks (title, assigned_agent, status, created_by, priority) values ('BACKLOG other work', 'new-ventures-researcher', 'todo', 'system', 3) returning id")[0]["id"]
run_cycles(14)
m2 = mission(mid2); spent2 = db.sql("select mission_spent_cents(%s) s", (mid2,))[0]["s"]
check("small-budget mission never exceeds its budget", spent2 <= 60, str(spent2))
check("the stopped task says why (mission budget)", bool(db.sql("select 1 from tasks where mission_id = %s and result like 'Stopped: Mission budget%%'", (mid2,))))
check("small-budget mission did not complete and is not silently running", m2["status"] in ("blocked", "paused", "failed"), m2["status"])
check("the rest of the board kept working", db.sql("select status from tasks where id = %s", (other,))[0]["status"] == "done")

# ===== C. the database refuses an extra step even if Python tried (direct insert against a strict 1-step mission)
with mock.patch.object(hq, "_request", db):
    mid3 = M.create_mission("Third mission used to prove the database step limit directly", max_steps=1)["id"]
db.sql("insert into tasks (title, status, mission_id, mission_role) values ('only step', 'todo', %s, 'step')", (mid3,))
try:
    db.sql("insert into tasks (title, status, mission_id, mission_role) values ('extra step', 'todo', %s, 'step')", (mid3,))
    check("extra step refused by the database", False)
except Exception as e:
    check("extra step refused by the database", "step limit" in str(e).lower(), str(e)[:120])

# ===== D. resilience + evidence check + recurrence against the real triggers (unlabeled eval -> repair; fabricated evidence ->
#         downgraded; unlabeled verifier -> repair -> pass; due date; owner-authorized recurrence)
db.sql("delete from tasks where mission_id is not null"); db.sql("delete from missions"); db.sql("delete from owner_messages")
SCRIPT["mode"] = "resilience"
with mock.patch.object(hq, "_request", db):
    mid4 = M.create_mission("Compare two options for a service business in Ottawa and recommend one with sources", budget_cents=1000)["id"]
    M.set_recurrence(mid4[:8], "weekly", 2)
run_cycles(60)
m4 = mission(mid4)
check("D: resilient mission reaches completed", m4["status"] == "completed", f"status={m4['status']} next={m4['next_action']} attempts={m4['attempts']}")
check("D: fabricated evidence cost exactly one counted attempt", m4["attempts"] == 1, str(m4["attempts"]))
check("D: evidence stored is traceable", "example.ca" in str(m4["evidence"]) and "invented" not in str(m4["evidence"]))
reps = db.sql("select mission_role from tasks where mission_id = %s and title like %s", (mid4, "%(format repair)%"))
check("D: exactly one eval repair and one verify repair, no loop", sorted(r["mission_role"] for r in reps) == ["eval", "verify"], str(reps))
check("D: evidence downgrade audited", db.sql("select count(*) c from audit_log where action = 'mission_evidence_downgraded' and target = %s", (mid4,))[0]["c"] == 1)
spent4 = db.sql("select mission_spent_cents(%s) s", (mid4,))[0]["s"]
check("D: repairs went through the mission budget", 0 < spent4 <= 1000, str(spent4))
check("D: repair calls are metered llm_calls", db.sql("select count(*) c from llm_calls where purpose in (select 'task '||id from tasks where mission_id = %s and title like %s)", (mid4, "%(format repair)%"))[0]["c"] == 2)
# recurrence: kill switch blocks, then the interval passing spawns exactly one successor with the same limits
db.sql("update missions set checkpoint = jsonb_set(checkpoint, '{recurrence,next_run_at}', to_jsonb((now() - interval '1 hour')::text)) where id = %s", (mid4,))
db.sql("update system_state set kill_switch = true where id = 1")
with mock.patch.object(hq, "_request", db):
    M.advance()
check("D: kill switch blocks recurrence", db.sql("select count(*) c from missions where created_by = 'recurrence'")[0]["c"] == 0)
db.sql("update system_state set kill_switch = false where id = 1")
with mock.patch.object(hq, "_request", db):
    M.advance(); M.advance()
kids = db.sql("select * from missions where created_by = 'recurrence'")
check("D: one successor, captured, same budget, runs decremented", len(kids) == 1 and kids[0]["status"] == "captured" and kids[0]["budget_cents"] == 1000
      and kids[0]["checkpoint"]["recurrence"]["runs_left"] == 1, str(kids))
# due date: overdue notice once
db.sql("update missions set checkpoint = checkpoint || jsonb_build_object('due_at', (now() - interval '1 day')::text) where id = %s", (kids[0]["id"],))
with mock.patch.object(hq, "_request", db):
    M.advance(); M.advance()
check("D: overdue owner message sent once", db.sql("select count(*) c from owner_messages where body like 'Mission overdue%%'")[0]["c"] == 1)
SCRIPT["mode"] = "default"

print("\nRESULT:", "ALL PASSED" if not fails else f"{len(fails)} FAILED: {fails}")
sys.exit(1 if fails else 0)
