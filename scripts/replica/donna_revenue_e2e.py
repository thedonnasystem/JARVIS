"""Donna Revenue Loop v1, end to end: the REAL hq_donna_revenue / hq_donna / hq_commands / hq_mail Python against a SCRATCH Postgres with every migration
applied once (PostgREST stood in by pg_adapter.PgAdapter). Faked: the two inbound APIs, the email provider, the sender's outside gate mark, and the owner's own
preconditions (outreach gate verified, mode auto_in_caps, Donna activated, /setaddress). It CHANGES the database (mode, gate, office status): scratch only.
  REPLICA_URL=postgresql://postgres:pw@localhost:5432/<fresh scratch db with all migrations> python3 scripts/replica/donna_revenue_e2e.py"""
import os, sys, json
WT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
sys.path.insert(0, WT); sys.path.insert(0, os.path.join(WT, "scripts", "replica"))
os.environ.update(HQ_SUPABASE_URL="http://localhost", HQ_SUPABASE_SERVICE_KEY="x")
import hq
from pg_adapter import PgAdapter
url = os.environ["REPLICA_URL"]
if "supabase" in url.lower():
    sys.exit("refused: scratch databases only")
db = PgAdapter(url)
hq._request = db
import hq_donna, hq_donna_revenue as R, hq_commands, hq_mail
fails = []
def check(name, cond, extra=""):
    print(("ok   " if cond else "FAIL ") + name + ("" if cond else f"  [{extra}]")); fails.append(name) if not cond else None

OWNER = "99999999-9999-9999-9999-99999999e2e0"
def owner_sql(q):
    db.sql("select set_config('app.uid', %s, false)", (OWNER,)); r = db.sql(q); db.sql("select set_config('app.uid', '', false)"); return r
db.sql("insert into auth.users (id, email) values (%s, 'e2e-owner@example.invalid') on conflict do nothing", (OWNER,))
db.sql("insert into public.app_owners (email) values ('e2e-owner@example.invalid') on conflict do nothing")

NETLIFY = [{"id": "6750aa01", "form_name": "donna-contact", "created_at": __import__("datetime").datetime.now(__import__("datetime").timezone.utc).isoformat(),
            "data": {"name": "Al Smith", "business": "Al's Diner", "email": "al@alsdiner.example", "phone": "613-555-0101", "message": "We miss calls at lunch.",
                     "marketing_consent": "yes", "consent_version": "webstudio-consent-v1",
                     "leak_estimate": "Leak estimate $3,428/month, $41,136/year. Avg value $250, close rate 30%. calls: $1,624/mo (5); leads: $300/mo (4); quotes: $225/mo (3); noshows: $500/mo (2); admin: $779/mo (6)"}}]
RETELL = [{"call_id": "call_e2e_1", "agent_id": "ag_web", "call_type": "web_call", "call_status": "ended", "start_timestamp": int(__import__("time").time() * 1000) - 3600000,
           "call_analysis": {"call_summary": "Plumber, misses calls on jobs, booked the audit.", "custom_analysis_data": {"caller_name": "Pat Lee", "business_name": "Pine Plumbing",
                             "email": "pat@pineplumbing.example", "booked": True, "appointment_time": "Thu Nov 27, 2 pm"}}}]
def http(method, url, headers, body=None):
    return NETLIFY if "netlify" in url else RETELL
ENV = {"DONNA_INBOUND": "1", "NETLIFY_TOKEN": "t", "NETLIFY_SITE_ID": "s", "RETELL_API_KEY": "k", "DONNA_AGENT_IDS": "ag_web", "DONNA_AUTODRAFT": "1"}

# 1. dormant: inbound lands, nothing drafted
r = R.tick_once(env=ENV, http=http)
check("dormant: 2 new leads", len(r["inbound"]["new"]) == 2, r)
check("dormant: no drafting", r.get("autodraft") == "Donna is dormant", r)
al = db.sql("select * from public.leads where email = 'al@alsdiner.example'")[0]
pat = db.sql("select * from public.leads where email = 'pat@pineplumbing.example'")[0]
check("Al: express consent from the ticked box", al["consent_basis"] == "express_web_form" and al["status"] == "new", al)
check("Pat: implied inquiry, booked", pat["consent_basis"] == "implied_inquiry" and pat["status"] == "booked", pat)
r2 = R.sync(env=ENV, http=http)
check("second sync: duplicates only", r2["duplicate"] == 2 and not r2["new"], r2)

# 2. owner activates Donna and sets the mailing address (his /setaddress)
owner_sql("select public.fz_owner_set_office_status('donna', 'active')")
db.sql("update fz_office_os.fz_office_profiles set manager = coalesce(manager, 'e2e'), status = 'active', activated_at = now() where slug = 'donna'")
# no address yet: drafts are written but cannot reach the outbox
r = R.tick_once(env=ENV, http=http)
ns = [x for run in r["runs"] for x in [run]]
check("no address: replies refused with the /setaddress instruction", any(x.get("mode") == "inbound_reply" and "/setaddress" in str(x.get("refused")) for x in r["runs"]), r)
check("no address: /donna inbound says what blocks", "Blocked: no mailing address" in R.inbound_text())
check("no address: nothing staged", db.sql("select count(*) n from fz_donna_rl.staged")[0]["n"] == 0)
db.sql("update public.company_profile set mailing_address = 'PO Box 4521, Station A, Ottawa ON K1N 0A1' where venture_slug = 'donna'")
if not db.sql("select 1 from public.company_profile where venture_slug = 'donna' and mailing_address is not null"):
    db.sql("insert into public.company_profile (venture_slug, sender_name, brand, mailing_address) values ('donna', 'Moe', 'The Donna System', 'PO Box 4521, Station A, Ottawa ON K1N 0A1')")
# the stale placeholder drafts block the reply until superseded: the next tick writes fresh ones (save_draft supersedes the old draft for the same lead)
r = R.tick_once(env=ENV, http=http)
staged = db.sql("select s.purpose, o.status, o.to_ref, o.subject, o.body, o.needs_owner from fz_donna_rl.staged s join public.outbox o on o.id = s.outbox_id order by o.to_ref")
check("address set: both replies staged", len(staged) == 2 and all(s["status"] == "draft" and s["needs_owner"] for s in staged), staged)
check("reply to Al carries his leak number and the P.O. box", any("$3,428 a month" in s["body"] and "PO Box 4521" in s["body"] for s in staged))
check("reply to Pat is the booked version", any("Thanks for booking" in s["body"] and "Thu Nov 27" in s["subject"] for s in staged))
msgs = db.sql("select id, body, ref_id from public.owner_messages where ref_table = 'outbox' and needs_decision")
check("owner got Approve / Reject messages", len(msgs) == 2, msgs)
briefs = db.sql("select body from fz_donna_rl.briefs")
check("audit brief for Pat's booked audit", len(briefs) == 1 and "Pine Plumbing" in briefs[0]["body"], briefs)
check("brief posted to the owner", bool(db.sql("select 1 from public.owner_messages where kind = 'brief' and body like 'Audit brief: Pine Plumbing%'")))
r = R.tick_once(env=ENV, http=http)
check("next tick: nothing new to do", r["messages"] == 0 and db.sql("select count(*) n from fz_donna_rl.staged")[0]["n"] == 2, r)

# 3. the owner taps Approve on Al's reply: the existing decision path (CASL gate etc.)
al_msg = [m for m in msgs if "al@alsdiner.example" in m["body"]][0]
import hq_gatemark; hq_gatemark.attest = lambda *a, **k: {"ok": True}      # the sender's OUTSIDE high-water mark: production infra, faked here only
# the owner's existing precondition for any send (runbook): the suppression list verified, so the outreach gate is open (fixture as sqltests/venture_deals_replies_check.sql)
db.sql("set session_replication_role = replica")
db.sql("insert into public.ffm_secrets (name, value, set_by) values ('suppression_hmac_key', repeat('fixture-key-', 4), 'fixture') on conflict do nothing")
db.sql("update public.ffm_outreach_gate set state = 'verified', verified_raw_count = 0, reason = 'e2e fixture', verified_at = clock_timestamp(), verified_epoch = 1, verified_marker_id = (select coalesce(max(id),0) from public.ffm_restore_markers), instance_fp = public.ffm_instance_fp(), attested_at = clock_timestamp() where id = 1")
db.sql("update public.system_state set mode = 'auto_in_caps'")          # the owner's go-live switch (production: his decision)
db.sql("set session_replication_role = origin")
out = hq_commands.apply_decision(al_msg["id"], True)
st = db.sql("select status from public.outbox where to_ref = 'al@alsdiner.example'")[0]["status"]
check("Approve -> outbox approved", st == "approved", f"{out} / {st}")

# 4. hq_mail sends it (provider faked): proves the subject column fix end to end
sent = []
hq_mail.configured = lambda: True
hq_mail.hq_gatemark.attest = lambda **k: {"ok": True}
hq_mail._post = lambda row: sent.append(row) or True
class D: decision = "allow"
hq_mail.hq_policy.authorize = lambda *a, **k: D()
hq_mail.send_allowed = lambda oid: True
res = hq_mail.deliver_approved()
check("hq_mail delivered the approved reply", res.get("sent") == 1 and sent and sent[0].get("subject", "").startswith("Your free Revenue Leak Audit"), res)
lead = db.sql("select status, next_followup_at from public.leads where email = 'al@alsdiner.example'")[0]
check("lead contacted, follow-up scheduled", lead["status"] == "contacted" and lead["next_followup_at"], lead)

# 5. follow-up due three days later
db.sql("update public.leads set next_followup_at = current_date - 1, last_contact_at = now() - interval '3 days' where email = 'al@alsdiner.example'")
db.sql("update public.outbox set sent_at = now() - interval '3 days' where to_ref = 'al@alsdiner.example' and status = 'sent'")
r = R.tick_once(env=ENV, http=http)
fu = db.sql("select o.subject from fz_donna_rl.staged s join public.outbox o on o.id = s.outbox_id where s.purpose = 'follow_up'")
check("follow-up 2 staged", len(fu) == 1 and "losing revenue" in fu[0]["subject"], (r, fu))

# 6. after Pat's audit: the owner's proposal
sid = db.sql("select short_id from public.leads where email = 'pat@pineplumbing.example'")[0]["short_id"]
txt0 = R.proposal_cmd(f"{sid} front-desk 497 | misses about 6 calls a week on jobs; no after-hours answering")
check("proposal waits while the reply to Pat is undecided", "already waiting" in txt0, txt0)
pat_msg = [m for m in msgs if "pat@pineplumbing.example" in m["body"]][0]
hq_commands.apply_decision(pat_msg["id"], False)                          # the owner rejects the reply (or approves it): either way the proposal can go
R.tick_once(env=ENV, http=http)                                           # the retry stages the waiting proposal draft
txt = "Proposal drafted"
pr = db.sql("select o.subject, o.body from fz_donna_rl.staged s join public.outbox o on o.id = s.outbox_id where o.subject like 'Your Donna.AI plan%'")
check("proposal staged for approval", "Proposal drafted" in txt and len(pr) == 1 and "$497 a month" in pr[0]["body"], (txt, pr))
check("/donna inbound renders", "Inbound, last 7 days" in R.inbound_text())

# 7. Pat says yes and emails the setup answers: one line becomes the intake, then the client's own agent previews from it (no model, nothing created)
import hq_donna_intake, hq_donna_agents
it = hq_donna_intake.intake_cmd(f"{sid} | hours: mon-fri 7-6, sat 8-12; services: Drain cleaning $149 60min, Water heater install; "
                                f"faq: Do you do emergencies? = Yes, 24/7 for burst pipes; urgent: 613 555 0111; city: Kanata")
check("/donna intake saves the intake under the lead", "Intake saved for Pine Plumbing" in it and "open: mon, tue, wed, thu, fri, sat" in it, it)
row = db.sql("select client_label, reception_config, open_items from fz_donna.intakes where lead_id = (select id from public.leads where email = 'pat@pineplumbing.example')")
check("intake row: hours, prices, urgent number", len(row) == 1 and row[0]["reception_config"]["hours"]["fri"] == [["07:00", "18:00"]]
      and row[0]["reception_config"]["services"][0]["price_cents"] == 14900 and row[0]["reception_config"]["escalation_number"] == "+16135550111", row)
pv = hq_donna_agents.agent_cmd("Pine Plumbing")
check("/donna agent previews from the saved intake", "Donna agent for Pine Plumbing" in pv and "create" in pv, pv)
# 8. the owner closes Pat: the stuck list moves her from "audit, no proposal" to "intake saved, agent not created" (one command each)
won = R.won_cmd(f"{sid} front-desk 497")
check("/donna won records the deal", won.startswith("Won: Pine Plumbing"), won)
ob = db.sql("select m.id from public.owner_messages m join public.outbox o on o.id = m.ref_id where m.ref_table = 'outbox' and m.needs_decision "
            "and o.to_ref = 'pat@pineplumbing.example' and o.status = 'draft' order by m.created_at desc limit 1")
check("won: the welcome email waits for the owner's tap", len(ob) == 1, ob)
if ob:
    hq_commands.apply_decision(ob[0]["id"], True)
    res = hq_mail.deliver_approved()
    pl = db.sql("select status from public.leads where email = 'pat@pineplumbing.example'")[0]
    check("a sent welcome email never drags a won client back to 'contacted' (no audit follow-ups to a client)", res.get("sent") == 1 and pl["status"] == "won", (res, pl))
st = R.stuck_rows(hq_donna._rpc_default)
check("stuck list: Pat's phone agent is the next step", any(r["kind"] == "intake_no_agent" and r["client_label"] == "Pine Plumbing" for r in st)
      and not any(r["kind"] in ("won_no_intake", "audit_no_proposal") and r["name"] == "Pine Plumbing" for r in st), st)
check("/donna stuck text names the command", "/donna agent Pine Plumbing" in (R.stuck_text(st) or ""), R.stuck_text(st))
print("E2E RESULT:", "ALL PASSED" if not fails else f"FAILED {fails}")
sys.exit(1 if fails else 0)
