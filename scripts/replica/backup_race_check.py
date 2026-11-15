#!/usr/bin/env python3
"""Backup race test (owner directive B). The REAL hq_backup.run() runs against the replica database through the PostgREST stand-in, in PAGED mode, and a source of the redaction changes
between two pages (committed from a second connection): a lead is renamed / erased / deleted, a deny-list entry is added, a suppression is added. Expected: the archive is discarded, NOTHING is
uploaded, a backup_failed audit row is written, the owner is told, and the run reports failure. A control without a change uploads exactly once. Needs psycopg2. Run by scripts/replica/run.sh
(after the sqltests; it commits a few rows into the scratch database and removes the lead rows again; deny-list and suppression entries are append-only by design)."""
import os, sys
from unittest import mock

root = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..")
sys.path.insert(0, root); sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
os.environ.setdefault("HQ_SUPABASE_URL", "http://localhost"); os.environ.setdefault("HQ_SUPABASE_SERVICE_KEY", "x")
import psycopg2
from cryptography.fernet import Fernet
import hq, hq_backup as B
from pg_adapter import PgAdapter

URL = os.environ["REPLICA_URL"]
db = PgAdapter(URL)
mut = psycopg2.connect(URL); mut.autocommit = True
os.environ.update({"BACKUP_READER_JWT": "scratch-reader-token", "BACKUP_KEY": Fernet.generate_key().decode(), "BACKUP_PUT_URL": "https://store.example.com/b/{name}", "BACKUP_AUTH": "x:y"})
B.SNAPSHOT_BUDGET_S = -1            # force the paged mode: the many page calls are where the change lands
fails = []


def m(sql, *a):
    with mut.cursor() as c:
        c.execute(sql, a or None)


def reset():
    m("delete from public.leads where name in ('Racelynn Quillfeather', 'Renamed Racelynn', '[erased]') and email like 'race-%'")
    m("insert into public.leads (venture_id, name, email, phone, status) select id, 'Racelynn Quillfeather', 'race-1@example.test', '613-555-0388', 'new' from public.ventures order by slug limit 1")


def case(label, change, expect_ok, every=True):
    reset()
    state = {"pages": 0}
    audits, owner, puts = [], [], []
    def req(method, path, body=None, prefer=None, timeout=30, exact=False):
        if path.endswith("/rpc/backup_snapshot_page"):
            state["pages"] += 1
            if change and ((state["pages"] % 25 == 3) if every else state["pages"] == 3):
                change()                    # every=True: the change lands on EVERY attempt (so the bounded retries run out); every=False: once, the retry then sees a quiet database
        if method == "POST" and path.endswith("/audit_log"):
            audits.append(body["action"])
        if method == "POST" and path.endswith("/owner_messages"):
            owner.append(body["body"])
        return db(method, path, body, prefer=prefer, timeout=timeout, exact=exact)
    def put(files):
        puts.append(sorted(files)); return {"target": "t", "files": {}}
    seen = {}
    real_dump = B.dump
    def dump():
        blob, man = real_dump(); seen["attempts"] = man["consistency"].get("attempts"); seen["consistent"] = man["consistency"].get("consistent"); return blob, man
    with mock.patch("hq._request", side_effect=req), mock.patch.object(B, "put_files", side_effect=put), mock.patch.object(B, "dump", dump):
        r = B.run(force=True)
    r["_attempts"] = seen.get("attempts")
    ok = bool(r["ok"]) == expect_ok and (len(puts) == (1 if expect_ok else 0)) and (("backup_ok" in audits) if expect_ok else ("backup_failed" in audits and "backup_ok" not in audits))
    print(("ok   " if ok else "FAIL ") + f"{label}: run ok={r['ok']} uploads={len(puts)} audits={audits} attempts={r.get('_attempts')} reason={str(r.get('reason'))[:80]}")
    if not ok:
        fails.append(label)
    return r


case("control: nothing changes -> uploaded once", None, True)
import itertools
K = itertools.count(1)
case("a lead is renamed between pages (every attempt)", lambda: m("update public.leads set name = %s where email = 'race-1@example.test'", "Renamed Racelynn %d" % next(K)), False)
r1 = case("one rename between pages: the first archive is discarded, the retry is consistent and is the one uploaded", lambda: m("update public.leads set name = %s where email = 'race-1@example.test'", "Renamed Racelynn %d" % next(K)), True, every=False)
if r1.get("_attempts") != 2:
    print("FAIL the retry attempt count is not 2:", r1.get("_attempts")); fails.append("attempts")
def fresh_lead():
    e = "race-f%d@example.test" % next(K)
    m("insert into public.leads (venture_id, name, email, phone, status) select id, 'Racelynn Fresh', %s, '613-555-0399', 'new' from public.ventures order by slug limit 1", e)    # a fresh row per attempt: the change must really change something every time
    return e
def erase_one():
    e = fresh_lead(); m("update public.leads set name = '[erased]', email = null, phone = null where email = %s", e)
def delete_one():
    e = fresh_lead(); m("delete from public.leads where email = %s", e)
case("a lead is erased between pages", erase_one, False)
case("a lead is deleted between pages", delete_one, False)
case("a deny-list entry is added between pages", lambda: m("select public.redaction_capture('n', %s)", "Zzracename Fixture%d" % next(K)), False)
case("a suppression is added between pages", lambda: m("insert into public.contact_suppressions (address, reason, recorded_by) values (%s, 'unsubscribe', 'race') on conflict do nothing", "race-s%d@example.test" % next(K)), False)
case("a lead is added between pages", lambda: m("insert into public.leads (venture_id, name, email, status) select id, 'Racelynn Another', %s, 'new' from public.ventures order by slug limit 1", "race-a%d@example.test" % next(K)), False)
r2 = case("a write that bypasses the triggers (replica role) is seen through the row count: the first archive is discarded, the retry (the row is gone) is the one uploaded", lambda: (m("set session_replication_role = replica"), m("delete from public.leads where email = 'race-1@example.test'"), m("set session_replication_role = origin")), True)
if r2.get("_attempts") != 2:
    print("FAIL replica-role write was not detected on the first attempt:", r2.get("_attempts")); fails.append("replica-role")
# ---- round 6: noise writes must not starve the backup; a redefined redactor / spec function must discard the archive
case("noise: 0-row updates and non-source-column updates between pages (every attempt) do not disturb the backup", lambda: (m("update public.leads set name = 'x' where false"), m("update public.leads set score = coalesce(score, 0) + 1, status = 'contacted' where email = 'race-1@example.test'"), m("update public.leads set name = name where email = 'race-1@example.test'")), True)
r3 = case("noise: still ONE attempt", None, True)
with mut.cursor() as c:
    c.execute("select pg_get_functiondef('public.backup_redact_patterns(text,jsonb)'::regprocedure)"); orig_def = c.fetchone()[0]
    c.execute("select pg_get_functiondef('public.backup_redaction_spec()'::regprocedure)"); orig_spec = c.fetchone()[0]
def redefine(d):
    m(d.replace("AS $function$", "AS $function$ /* race %d */" % next(K), 1))
try:
    case("the redactor function (backup_redact_patterns) is replaced between pages (every attempt): discarded, not uploaded", lambda: redefine(orig_def), False)
    case("the spec function (backup_redaction_spec) is replaced between pages (every attempt): discarded, not uploaded", lambda: redefine(orig_spec), False)
    r4 = case("one redefinition of the redactor: the first archive is discarded, the retry is the one uploaded", (lambda st={"n": 0}: (st.__setitem__("n", st["n"] + 1), redefine(orig_def) if st["n"] == 1 else None)), True, every=False)
    if r4.get("_attempts") != 2:
        print("FAIL a redefined redactor was not detected on the first attempt:", r4.get("_attempts")); fails.append("redactor-redefinition")
finally:
    m(orig_def); m(orig_spec)
reset(); m("delete from public.leads where email like 'race-%@example.test' or name in ('Racelynn Fresh', '[erased]')");
mut.close()
print("backup race check:", "FAILED " + ", ".join(fails) if fails else "all cases passed")
sys.exit(1 if fails else 0)
