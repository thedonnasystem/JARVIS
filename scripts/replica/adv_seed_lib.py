# Seeding + spelling generator for prop_paged_check.py (round 4; reviewer-style adversarial people: live, erased, deleted). Every transaction is rolled back by the caller.
import psycopg2, json, unicodedata, re, sys, uuid
import os
DSN = os.environ["REPLICA_URL"]
con = psycopg2.connect(DSN); con.autocommit = False
cur = con.cursor()
def q(sql, *a):
    cur.execute(sql, a); 
    try: return cur.fetchall()
    except psycopg2.ProgrammingError: return None
v = q("select id from ventures order by slug limit 1")[0][0]
ag = q("select slug from agents order by slug limit 1")[0][0]
agid = q("select id from agents order by slug limit 1")[0][0]
# --- seed live + erased + deleted people
leads = ["Luc Picardeau", "Anne-Marie O'Brien-Tremblay", "Zoë Müller", "Wu Li", "Ng Ho", "Ali Lee", "Jean-François Gagné", "Marie Dupont-Roy"]
for n in leads:
    q("insert into leads (venture_id,name,status) values (%s,%s,'new')", v, n)
q("insert into leads (venture_id,name,email,phone,status) values (%s,'Ravi Chandrasekaran','ravi.c@chandra.example','613-555-0111','new')", v)
q("update leads set name='[erased]', email=null, phone=null where name='Ravi Chandrasekaran'")
q("insert into leads (venture_id,name,status) values (%s,'Odile Vandenbroeck','new')", v)
q("delete from leads where name='Odile Vandenbroeck'")
q("select public.setter_add('Marcus Zzyxwell','marcus.zzyxwell@setters.example','salons')")
q("insert into client_workspaces (slug,name,vertical) values ('zz-x','Wexcombe Holdings Ltd','mortgage')")
ws = q("select id from client_workspaces where slug='zz-x'")[0][0]
q("insert into ws_campaigns (workspace_id,name) values (%s,'zz camp')", ws)
cp = q("select id from ws_campaigns where workspace_id=%s", ws)[0][0]
q("select public.ws_add_lead(%s,%s,'Odalys Quenneville','odalys.q@quenneville-co.example','819-555-0123','web form')", ws, cp)
CORES = {"picardeau":"Picardeau","tremblay":"Tremblay","muller":"Müller","gagne":"Gagné","dupontroy":"Dupont-Roy","brien":"O'Brien",
         "chandrasekaran":"Chandrasekaran","vandenbroeck":"Vandenbroeck","zzyxwell":"Zzyxwell","quenneville":"Quenneville"}
def homog(s):
    m = {'a':'а','e':'е','o':'о','c':'с','p':'р','x':'х','y':'у','i':'і'}
    return ''.join(m.get(c.lower(), c) for c in s)
def fw(s): return ''.join(chr(ord(c)+0xFEE0) if c.isalpha() and c.isascii() else c for c in s)
def spaced(s): return ' '.join(s)
def variants(name):
    w = name.lower()
    base = re.sub(r"[^a-z]", "", unicodedata.normalize("NFKD", name.lower()).encode('ascii','ignore').decode())
    return {
      'plain': name, 'upper': name.upper(), 'spaced': spaced(base), 'dotted': '.'.join(base), 'underscored': '_'.join(base),
      'glued_j': 'j'+base, 'glued_first': 'Luc'+base.title(), 'digit': base+'1', 'plural': 'the '+name+'s', 'url': 'www.j'+base+'.ca',
      'homoglyph': homog(base), 'homoglyph_title': homog(base.title()), 'zw': base[:3]+'​'+base[3:], 'zwj': base[:2]+'‍'+base[2:5]+'⁠'+base[5:],
      'diacritic': base[:2]+'́'+base[2:], 'fullwidth': fw(base), 'hyph': base[:4]+'-'+base[4:], 'apos': name+"'s",
      'email_local': base+'@gmail.com', 'handle': '@'+base, 'rot13': base.translate(str.maketrans('abcdefghijklmnopqrstuvwxyz','nopqrstuvwxyzabcdefghijklm')),
      'rev': base[::-1], 'pct': ''.join('%%%02x'%b for b in base.encode()), 'ent': ''.join('&#%d;'%ord(c) for c in base),
      'b64': __import__('base64').b64encode(('contact '+name+' now please').encode()).decode(),
      'sentence': 'Paid deal for %s of invoice 1042, $1,250.00 to Hydro Ottawa' % name,
    }
cols = ['tasks.result','ledger.note','agent_runs.summary','escalations.summary','audit_log.v','audit_log.key_deep','audit_log.arr','audit_log.val_deep',
        'tasks.title','tasks.detail','memory.content','ideas.name','missions?']
cols = cols[:-1]
q("set local session_replication_role = replica")
rows = []   # (id, core, variant, col)
n = 0
for core, disp in CORES.items():
    for vn, vs in variants(disp).items():
        for c in cols:
            n += 1; tag = 'zq%dz' % n
            rows.append((tag, core, vn, c, vs))
            if c=='tasks.result': q("insert into tasks (assigned_agent,title,detail,status,result,created_by) values (%s,%s,'x','done',%s,'owner')", ag, tag, vs)
            elif c=='tasks.title': q("insert into tasks (assigned_agent,title,detail,status,created_by) values (%s,%s,'x','done','owner')", ag, tag+' '+vs)
            elif c=='tasks.detail': q("insert into tasks (assigned_agent,title,detail,status,created_by) values (%s,%s,%s,'done','owner')", ag, tag, vs)
            elif c=='ledger.note': q("insert into ledger (kind,amount_cents,currency,note,status) values ('expense',%s,'CAD',%s,'received')", 100000+n, tag+' '+vs)
            elif c=='agent_runs.summary': q("insert into agent_runs (agent_id,status,summary) values (%s,'ok',%s)", agid, tag+' '+vs)
            elif c=='escalations.summary': q("insert into escalations (from_agent,kind,summary) values (%s,'failure',%s)", ag, tag+' '+vs)
            elif c=='audit_log.v': q("insert into audit_log (actor,action,target,detail) values ('zq','note',%s,%s)", tag, json.dumps({'v': vs}))
            elif c=='audit_log.key_deep': q("insert into audit_log (actor,action,target,detail) values ('zq','note',%s,%s)", tag, json.dumps({'a':{'b':[{'c':{vs:1}}]}}))
            elif c=='audit_log.arr': q("insert into audit_log (actor,action,target,detail) values ('zq','note',%s,%s)", tag, json.dumps({'list':['ok', vs, {'z':[vs]}]}))
            elif c=='audit_log.val_deep': q("insert into audit_log (actor,action,target,detail) values ('zq','note',%s,%s)", tag, json.dumps({'a':{'b':[{'c':{'reason':vs}}]}}))
            elif c=='memory.content': q("insert into memory (kind,content) values ('lesson',%s)", tag+' '+vs)
            elif c=='ideas.name': q("insert into ideas (name) values (%s)", tag+' '+vs)
q("set local session_replication_role = origin")
q("set local role backup_reader")
snap = q("select public.backup_snapshot()")[0][0]
q("reset role")
data = snap['data']
def fold(s):
    s = unicodedata.normalize('NFKD', s)
    s = ''.join(ch for ch in s if not unicodedata.combining(ch) and unicodedata.category(ch) not in ('Cf',))
    mp = {'а':'a','е':'e','о':'o','с':'c','р':'p','х':'x','у':'y','і':'i'}
    s = ''.join(mp.get(c,c) for c in s.lower())
    return re.sub(r'[^a-z0-9]','',s)
def lookup(c, tag):
    t, col = c.split('.')[0], c
    tab = {'tasks.result':('tasks','title'),'tasks.title':('tasks','title'),'tasks.detail':('tasks','title'),'ledger.note':('ledger','note'),'agent_runs.summary':('agent_runs','summary'),'escalations.summary':('escalations','summary'),
           'memory.content':('memory','content'),'ideas.name':('ideas','name')}
    if c.startswith('audit_log'):
        return [r for r in data['audit_log'] if r.get('target')==tag]
    tname, key = tab[c]
    out=[]
    for r in data[tname]:
        if c in ('tasks.result','tasks.detail') and r.get('title')==tag: out.append(r)
        elif c=='tasks.title' and (r.get('title') or '').startswith(tag) : out.append(r)
        elif c=='tasks.title' and r.get('title')=='[redacted:uncertain]': pass
        elif c not in ('tasks.result','tasks.detail','tasks.title') and tag in json.dumps(r, ensure_ascii=False): out.append(r)
    return out
# rows whose marker was blanked can't be found by marker for ledger etc.; use global leakage by core instead, per-variant by unique combos
alltxt = {t: [fold(json.dumps(r, ensure_ascii=False)) for r in rs] for t, rs in data.items()}
leaks = {}
for tag, core, vn, c, vs in rows:
    rs = lookup(c, tag)
    found = False
    if not rs:   # marker lost (fail closed) => safe
        continue
    for r in rs:
        s = fold(json.dumps(r, ensure_ascii=False))
        if core in s: found = True
    if found: leaks.setdefault((core, vn), []).append(c)
res = {}
for (core, vn), cs in sorted(leaks.items()): res.setdefault(vn, {})[core] = cs

STRICT={'tasks.result','ledger.note','agent_runs.summary','escalations.summary','audit_log.v','audit_log.key_deep','audit_log.arr','audit_log.val_deep'}
print('--- STRICT leaks (core: variants)')
bycore={}
for (core,vn),cs in leaks.items():
    sc=[c for c in cs if c in STRICT]
    if sc: bycore.setdefault(core,{})[vn]=sc
for core,d in bycore.items(): print(core, sorted(d.keys()), 'cols', sorted({c for v in d.values() for c in v}))
print('--- LIGHT leaks (core: variants)')
bl={}
for (core,vn),cs in leaks.items():
    sc=[c for c in cs if c not in STRICT]
    if sc: bl.setdefault(core,[]).append(vn)
for core,d in bl.items(): print(core, sorted(d))

print("TOTAL leaking (core,variant) pairs:", len(leaks), "of", len(CORES)*len(variants('x')))
con.rollback()
