# Property check (round 4 item 2): for random pages sizes the PAGED export of every exported table equals the single-statement snapshot, for rows that spell erased / deleted / live names in adversarial ways.
# REPLICA_URL=... python3 scripts/replica/prop_paged_check.py [seed]   (exit 1 on any mismatch)
import psycopg2, json, random, re, sys
import os
exec(open(os.path.join(os.path.dirname(os.path.abspath(__file__)), 'adv_seed_lib.py')).read().split("cols = ['tasks.result'")[0].replace("con.rollback()",""))   # reuse seeding of people + variants()
random.seed(int(sys.argv[1]) if len(sys.argv)>1 else 1)
ops = ["Paid deal 12 of 2026-11-02, $1,250.00 CAD to Hydro Ottawa invoice INV-20481", "Commission payout for setter batch 7: 3 deals, total 450.00", "Hosting renewal Railway $20.00 monthly", "Meta ads spend 312.55 for venture acme campaign 4",
       "Agent finished: drafted 5 emails, 0 sent, reply rate unknown", "Followed up with 8 leads; 2 booked calls tomorrow at 10:30", "Stripe fee 3.2% on charge ch_1Nabc; net 96.80",
       "Quote #4412 for Smith Plumbing and Heating HVAC install 4,800 CAD", "Rent due 2026-12-01 amount 1,900.00", "Li Ng Wu Ali Lee Ho committee meeting minutes", "Invoice 1042 paid via e-transfer, ref 88421937", "weekly KPI: leads 41, replies 6, booked 2"]
names = list(CORES.values()) + leads
tabs = ['tasks.result','ledger.note','agent_runs.summary','escalations.summary','audit_log.v','audit_log.key_deep','tasks.title','tasks.detail','memory.content','ideas.name']
cur.execute(open(os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', '..', 'sqltests', 'include', 'legacy_spec.sql')).read())      # the pre-blanking classification (engine test, see the include)
q("set local session_replication_role = replica")
N=700; adv=0
for i in range(N):
    tag='pq%dz'%i
    if random.random()<0.09:
        nm=random.choice(names); vs=random.choice(list(variants(nm).values())); adv+=1
    else: vs=random.choice(ops)
    c=random.choice(tabs)
    if c=='tasks.result': q("insert into tasks (assigned_agent,title,detail,status,result,created_by) values (%s,%s,'x','done',%s,'owner')", ag, tag, vs)
    elif c=='tasks.title': q("insert into tasks (assigned_agent,title,detail,status,created_by) values (%s,%s,'x','done','owner')", ag, tag+' '+vs)
    elif c=='tasks.detail': q("insert into tasks (assigned_agent,title,detail,status,created_by) values (%s,%s,%s,'done','owner')", ag, tag, vs)
    elif c=='ledger.note': q("insert into ledger (kind,amount_cents,currency,note,status) values ('expense',%s,'CAD',%s,'received')", 200000+i, tag+' '+vs)
    elif c=='agent_runs.summary': q("insert into agent_runs (agent_id,status,summary) values (%s,'ok',%s)", agid, tag+' '+vs)
    elif c=='escalations.summary': q("insert into escalations (from_agent,kind,summary) values (%s,'failure',%s)", ag, tag+' '+vs)
    elif c=='audit_log.v': q("insert into audit_log (actor,action,target,detail) values ('pq','note',%s,%s)", tag, json.dumps({'v': vs}))
    elif c=='audit_log.key_deep': q("insert into audit_log (actor,action,target,detail) values ('pq','note',%s,%s)", tag, json.dumps({'a':[{vs:1,'n':3}]}))
    elif c=='memory.content': q("insert into memory (kind,content) values ('lesson',%s)", tag+' '+vs)
    elif c=='ideas.name': q("insert into ideas (name) values (%s)", tag+' '+vs)
q("set local session_replication_role = origin")
q("grant usage on schema public to service_role"); q("set local role service_role")
snap = q("select public.backup_snapshot()")[0][0]['data']
RUN = q("select public.backup_deny_prepare() ->> 'run'")[0][0]
bad=0
for t in snap:
    ps = random.choice([7,13,37,50])
    rows=[]; off=0
    while True:
        pg = q("select public.backup_snapshot_page(%s,%s,%s,%s::uuid)", t, off, ps, RUN)[0][0]['rows']
        if not pg: break
        rows+=pg; off+=len(pg)
    a=sorted(json.dumps(r,sort_keys=True) for r in rows); b=sorted(json.dumps(r,sort_keys=True) for r in snap[t])
    if a!=b:
        sa=set(a); sb=set(b)
        print("MISMATCH", t, "paged", len(a), "single", len(b), "only_paged", len(sa-sb), "only_single", len(sb-sa))
        for x in list(sa-sb)[:3]: print("  P:", x[:300])
        for x in list(sb-sa)[:3]: print("  S:", x[:300])
        bad+=1
print("tables", len(snap), "adversarial rows", adv, "mismatching tables", bad)
q("reset role"); con.rollback()
sys.exit(1 if bad else 0)
