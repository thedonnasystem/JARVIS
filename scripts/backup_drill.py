#!/usr/bin/env python3
"""End-to-end backup + restore drill on LOCAL scratch databases only (no production, no real storage).

  source DB  (drill_src)      = the replica schema, seeded with awkward data. Stands in for production.
  hq_backup.run()             = the real production code, talking to the source DB through the PostgREST stand-in and uploading to a fake B2 server.
  restore_backup.py           = the real restore tool, run as a separate process, downloading with a READ-only key into drill_restore.
Then the source and the restored database are compared directly, and negative controls prove the checks can fail.

Usage: REPLICA_URL=postgresql://postgres:pw@localhost:5432/drill_src_$$  RESTORE_URL=postgresql://postgres:pw@localhost:5432/drill_restore_$$  python3 scripts/backup_drill.py
What this proves: our code paths and the restore procedure. What it cannot prove: Backblaze's real behaviour, PostgREST's real JSON, production data volumes."""
import hashlib, json, os, subprocess, sys, tempfile
from unittest import mock

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
sys.path[:0] = [ROOT, os.path.join(HERE, "replica"), os.path.join(ROOT, "ops")]

import subprocess
import psycopg2
from cryptography.fernet import Fernet
import hq_consent

SRC = os.environ["REPLICA_URL"]
DST = os.environ["RESTORE_URL"]
DST_NAME = DST.rsplit("/", 1)[-1].split("?")[0]   # per-process name (scripts/backup_drill.sh suffixes it), never a fixed "drill_restore"
results = []
DRILL_SUPP_KEY = hashlib.sha256(b"drill-suppression-key").hexdigest()   # throwaway, scratch DBs only; deliberately NOT the BACKUP_KEY; derived so no key-shaped literal sits in the repository
DRILL_WRONG_KEY = hashlib.sha256(b"drill-wrong-key").hexdigest()
DRILL_OPTOUTS = ['optout1@example.com', 'optout2@example.com', 'optout3@example.com']
DRILL_OPTOUT_PHONES = ['+16135550911', '+16135550912']


def check(name, ok, detail=""):
    results.append((name, bool(ok), detail))
    print(("PASS  " if ok else "FAIL  ") + name + (f"  [{detail}]" if detail else ""))
    return ok


def seed(conn):
    cur = conn.cursor()
    cur.execute("select id from ventures order by slug limit 1")
    v = cur.fetchone()[0]
    cur.execute("select slug from agents where status='active' order by slug limit 1")
    ag = cur.fetchone()[0]
    big = ("Lorem ipsum éèê \U0001F600 line\nbreak \"quoted\" 'single' back\\slash tab\t " * 3000)
    for i in range(1, 41):
        cur.execute("insert into leads (venture_id, name, email, phone, source, score, status, notes, next_followup_at) values (%s,%s,%s,%s,%s,%s,'new',%s,%s)",
                    (v, f"Lead {i} Ñoño \U0001F680" if i % 3 == 0 else f"Lead {i}", f"lead{i}@example.com" if i % 5 else None, None if i % 2 else f"+1613555{i:04d}",
                     "scrape", i % 100, big[:500] if i % 7 == 0 else "", f"2026-12-{(i % 28) + 1:02d}"))
    # consent integrity: the owner's suppression key, three opted-out addresses and two opted-out numbers (client PII: must NOT reach the off-site file; only keyed hashes may)
    cur.execute("insert into public.ffm_secrets (name, value, set_by) values ('suppression_hmac_key', %s, 'drill')", (DRILL_SUPP_KEY,))
    for a in DRILL_OPTOUTS:
        cur.execute("insert into public.contact_suppressions (address, reason, recorded_by) values (%s, 'drill opt-out', 'drill')", (a,))
    for ph in DRILL_OPTOUT_PHONES:
        cur.execute("insert into public.ffm_phone_suppressions (phone, reason, recorded_by) values (%s, 'drill opt-out', 'drill')", (ph,))
    cur.execute("select id from leads order by short_id nulls last, name limit 20")
    for n, (lid,) in enumerate(cur.fetchall()):
        cur.execute("insert into outbox (venture_id, agent, channel, to_ref, body, status, lead_id, sources) values (%s,%s,'email',%s,%s,'draft',%s,%s)",
                    (v, ag, f"lead{n}@example.com", f"Hi À {n}\n\nDraft body \U0001F4E7 " + ("x" * (n * 50)), lid, json.dumps({"urls": ["https://example.com/a?b=1&c=é"], "n": n, "nested": {"f": 1.50, "z": None}})))
    for i in range(120):
        cur.execute("insert into memory (venture_id, agent, kind, content, source, confidence) values (%s,%s,%s,%s,'web','high')",
                    (v, ag, ["fact", "decision", "lesson"][i % 3], (big if i == 0 else f"Memory {i}: 美味 — “smart quotes”")))
    cur.execute("insert into handbook (version, content, active) values (99, %s, false)", (big,))
    for i in range(30):
        cur.execute("insert into ledger (venture_id, kind, amount_cents, currency, note, occurred_on, fx_rate, original_amount_cents) values (%s,%s,%s,'CAD',%s,'2026-11-12',%s,%s)",
                    (v, "revenue" if i % 2 else "expense", i * 137 - 900, f"entry {i} ¢", "1.23456789" if i % 4 == 0 else None, i * 100))
    for i in range(60):
        cur.execute("insert into tasks (venture_id, assigned_agent, created_by, title, detail, status, priority, result) values (%s,%s,'system',%s,%s,%s,2,%s)",
                    (v, ag, f"Task {i} \U0001F527", None if i % 4 == 0 else big[:300], ["todo", "done", "blocked", "cancelled"][i % 4], big if i == 5 else None))
    # schema features the review flagged: a unique INDEX (not a constraint) that a foreign key depends on, a security_invoker view, an identity sequence
    cur.execute("""create table public.drill_ref (id int not null, label text, seq int generated by default as identity);
                   create unique index drill_ref_id_uidx on public.drill_ref (id);
                   create table public.drill_child (id serial primary key, ref_id int references public.drill_ref (id));
                   create view public.drill_ref_v with (security_invoker = true) as select id, label from public.drill_ref;
                   insert into public.drill_ref (id, label) select g, 'ref ' || g from generate_series(1, 25) g;
                   insert into public.drill_child (ref_id) select g from generate_series(1, 25) g;
                   comment on table public.drill_ref is 'Reference table: it''s "quoted" 美味';
                   comment on column public.drill_ref.label is 'human label';
                   comment on view public.drill_ref_v is 'view comment';
                   comment on function public.capital_mode() is 'returns the capital mode';
                   grant usage on schema public to anon, authenticated, service_role;""")
    # scratch DB only: the drill's own fixture tables are not on the reviewed classification list, so by design (fail closed) they would not be exported.
    # Re-declare the classification here WITH them so the drill can prove restore fidelity on tables that are exported.
    cur.execute("alter function public.backup_classification() rename to __orig_backup_classification")
    cur.execute("""create function public.backup_classification() returns table (table_name text, data_class text, note text) language sql immutable set search_path to 'pg_catalog','public' as $f$
        select o.table_name, o.data_class, o.note from public.__orig_backup_classification() o
        union all select * from (values ('drill_ref','internal','drill fixture'),('drill_child','internal','drill fixture'),('drill_pair_a','internal','drill fixture'),('drill_pair_b','internal','drill fixture')) v $f$""")
    conn.commit()


# ---------------------------------------------------------------------------------------------------------------------------------------------------------------
# Consent and suppression integrity: the keyed-hash suppression list survives backup and restore, the restored database is default-deny, and ONLY an owner
# verification that matches the checkpoint opens it.
def _members(enc, key):
    import io, tarfile
    tar = tarfile.open(fileobj=io.BytesIO(Fernet(key.encode()).decrypt(enc)), mode="r:gz")
    return {m.name: tar.extractfile(m).read() for m in tar.getmembers() if m.isfile()}


def _build(members, key):
    import io, tarfile
    buf = io.BytesIO()
    with tarfile.open(fileobj=buf, mode="w:gz") as tar:
        for n, d in members.items():
            ti = tarfile.TarInfo(n); ti.size = len(d); ti.mtime = 0
            tar.addfile(ti, io.BytesIO(d))
    return Fernet(key.encode()).encrypt(buf.getvalue())


NSUP = 5      # set from the source database in consent_checks


def consent_checks(enc, key, rep, renv, work, out_sha):
    members = _members(enc, key)
    mf = json.loads(members["manifest.json"])
    sup_m = mf.get("suppression") or {}
    sup = json.loads(members.get("suppression/hashes.json", b"{}") or b"{}")
    # the expected list is computed from what the SOURCE database holds in plaintext (not from the drill constants), so another drill that seeds more opt-outs (the leak drill does) cannot desynchronise it
    with psycopg2.connect(SRC) as c0, c0.cursor() as k0:
        k0.execute("select address from public.contact_suppressions"); src_emails = [r[0] for r in k0.fetchall()]
        k0.execute("select phone from public.ffm_phone_suppressions"); src_phones = [r[0] for r in k0.fetchall()]
    global NSUP
    NSUP = len(src_emails) + len(src_phones)
    want = {("email", hq_consent.suppression_mac(DRILL_SUPP_KEY, "email", a)) for a in src_emails} | {("phone", hq_consent.suppression_mac(DRILL_SUPP_KEY, "phone", ph)) for ph in src_phones}
    got = {tuple(e) for e in sup.get("macs", [])}
    check("C1 the off-site file carries the suppression list as KEYED HASHES, equal to the independently computed HMACs (every opt-out in the source)", sup_m.get("included") and got == want and sup_m.get("count") == NSUP and NSUP >= 5 and not hq_consent.validate_suppression_export(sup), json.dumps({k: v for k, v in sup_m.items() if k != "macs"})[:200])
    blob = b"".join(members.values())
    leaked = [x for x in DRILL_OPTOUTS + DRILL_OPTOUT_PHONES + [DRILL_SUPP_KEY] if x.encode() in blob]
    check("C2 no opted-out address, no opted-out number and not the suppression key appear anywhere in the (decrypted) backup", not leaked, str(leaked))
    check("C3 the suppression key is a different secret from BACKUP_KEY", DRILL_SUPP_KEY != key and key.encode() not in blob, "")
    for t in ("contact_suppressions", "ffm_phone_suppressions", "ffm_secrets", "ffm_outreach_gate", "ffm_suppression_hashes", "ffm_suppression_expected"):
        if f"data/{t}.jsonl" in members:
            check(f"C4 {t} is not exported", False, "present in the backup")
    check("C4 contact_suppressions, ffm_phone_suppressions, ffm_secrets, ffm_outreach_gate and both hash tables have no data file", not any(n.startswith("data/") and n[5:].split(".")[0] in ("contact_suppressions", "ffm_phone_suppressions", "ffm_secrets", "ffm_outreach_gate", "ffm_suppression_hashes", "ffm_suppression_expected") for n in members), "")
    g = rep.get("outreach_gate") or {}
    check("C5 restore tool put the restored database into 'suppression unverified' (gate closed) and staged the checkpoint", g.get("state") == "unverified" and g.get("open") is False and g.get("checkpoint_staged") and (g.get("checkpoint") or {}).get("count") == NSUP, json.dumps(g)[:200])
    check("C6 restore tool prints the procedure and counts the closed gate as a pass criterion", len(rep.get("next_steps", [])) >= 4 and rep["steps"].get("outreach_gate_closed_default_deny") == "PASS", "")
    DST_ = psycopg2.connect(DST); cur = DST_.cursor()
    cur.execute("select (select count(*) from public.contact_suppressions), (select count(*) from public.ffm_phone_suppressions), (select count(*) from public.ffm_secrets), (select count(*) from public.ffm_suppression_hashes), (select count(*) from public.ffm_suppression_expected), public.ffm_outreach_gate_open()")
    row = cur.fetchone()
    check("C7 restored database: plaintext lists EMPTY (as designed), no key, no imported hashes, every expected entry staged, gate closed", row == (0, 0, 0, 0, NSUP, False), str(row))
    # attempted re-contact on the restored, empty-list database: a person who opted out is re-added, with consent evidence, in other written forms of the same address and number
    cur.execute("insert into public.client_workspaces (slug, name, vertical) values ('drill-ws', 'Drill Workspace Co', 'mortgage') returning id"); ws = cur.fetchone()[0]
    def add(name, em, ph):
        cur.execute("select public.ws_add_lead(%s, null, %s, %s, %s, 'import')", (ws, name, em, ph)); lid = cur.fetchone()[0]
        for ch in ("email", "sms"):
            ref = f"drill-{name.split()[0].lower()}-{ch}"
            cur.execute("""insert into public.ffm_consent_captures (workspace_id, capture_ref, channel, wording_version, wording_sha256, artifact_sha256, captured_at, lead_id, registered_via, registered_by)
                           values (%s, %s, %s, 'v1', %s, %s, now() - interval '1 day', %s, 'owner_attested', 'drill') returning id""", (ws, ref, ch, "b" * 64, "a" * 64, lid)); cap = cur.fetchone()[0]
            cur.execute("""insert into public.ffm_consent_log (workspace_id, lead_id, channel, basis, wording_version, source, captured_at, evidence_ref, recorded_by, capture_id, verification)
                           values (%s, %s, %s, 'express', 'v1', 'drill form', now() - interval '1 day', %s, 'drill', %s, 'ok')""", (ws, lid, ch, ref, cap))
        return lid
    l_out = add("Opted Out", "OptOut1+promo@Example.com", "613 555 0911")
    l_ok = add("Fine Person", "fine.person@example.com", "613 555 0999")
    def can(l, ch):
        cur.execute("select public.ffm_can_contact(%s, %s), public.ffm_contact_status(%s, %s) ->> 'reason'", (l, ch, l, ch)); return cur.fetchone()
    res = [can(l, ch) for l in (l_out, l_ok) for ch in ("email", "sms")]
    check("C8 RESTORE INTO AN EMPTY DATABASE THEN RE-CONTACT: refused for everyone (reason suppression_unverified), including the opted-out person re-added in other formats", all(r == (False, "suppression_unverified") for r in res), str(res))
    DST_.commit()

    # --- owner verification path (the restored scratch database needs the auth stub that Supabase provides; dropped again afterwards because the restore tool refuses a Supabase-looking server)
    cur.execute("""create schema auth; create table auth.users (id uuid primary key default gen_random_uuid(), email text, email_confirmed_at timestamptz default now());
                   create function auth.uid() returns uuid language sql as $$ select nullif(current_setting('app.uid', true), '')::uuid $$;
                   insert into auth.users (id, email) values ('99999999-9999-9999-9999-999999999994', 'drill-owner@example.com');
                   insert into public.app_owners (email) values ('drill-owner@example.com') on conflict do nothing""")
    DST_.commit()
    def owner(on):
        cur.execute("select set_config('app.uid', %s, false)", ("99999999-9999-9999-9999-999999999994" if on else "",))
    def sql(q, a=None):
        cur.execute(q, a); return cur.fetchone()[0] if cur.description else None
    def silent(q):
        cur.execute("set session_replication_role = replica"); cur.execute(q); cur.execute("set session_replication_role = origin")
    owner(False)
    try:
        sql("select public.ffm_verify_suppression('bot')"); bot_refused = False
    except Exception as e:
        bot_refused = "owner approval required" in str(e); DST_.rollback()
    owner(True)
    j = sql("select public.ffm_verify_suppression('owner')")
    check("C9 verification without the suppression key is refused and the bot cannot run it", bot_refused and j["verified"] is False and "key is not set" in j["reason"], f"bot_refused={bot_refused} {j}")
    sql("select public.ffm_set_key('suppression_hmac_key', %s, 'owner')", (DRILL_WRONG_KEY,))
    j = sql("select public.ffm_verify_suppression('owner')")
    check("C10 a WRONG suppression key is detected (does not match the checkpoint's key fingerprint)", j["verified"] is False and "differs" in j["reason"], str(j))
    silent("delete from public.ffm_secrets")
    sql("select public.ffm_set_key('suppression_hmac_key', %s, 'owner')", (DRILL_SUPP_KEY,))
    j = sql("select public.ffm_verify_suppression('owner')")
    owner(False)
    check("C11 right key but EMPTY list (nothing re-established yet): verification refused as incomplete, gate stays closed, outreach refused", j["verified"] is False and j["reason"].startswith(f"incomplete: {NSUP} of {NSUP}") and can(l_ok, "email")[0] is False, str(j))
    owner(True)
    n_imp = sql("select public.ffm_import_suppression_hashes()")
    j = sql("select public.ffm_verify_suppression('owner')")
    owner(False)
    check("C12 after re-establishing the list from the keyed hashes, OWNER verification succeeds exactly (all entries) and the gate opens", n_imp == NSUP and j["verified"] is True and j["mode"] == "exact" and sql("select public.ffm_outreach_gate_open()") is True, f"imported {n_imp} {j}")
    res = [can(l_out, "email"), can(l_out, "sms"), can(l_ok, "email"), can(l_ok, "sms")]
    check("C13 after verification: the opted-out person stays refused through hash-only suppression (email +tag/case form and phone form); the unrelated consented lead is allowed", res == [(False, "suppressed"), (False, "suppressed"), (True, "express"), (True, "express")], str(res))
    silent("delete from public.ffm_suppression_hashes where ctid = (select ctid from public.ffm_suppression_hashes where kind = 'email' limit 1)")
    check("C14 the list SHRANK after verification (a row removed under the triggers): the gate closes by itself", sql("select public.ffm_outreach_gate_open()") is False and can(l_ok, "email")[0] is False, "")
    owner(True)
    j = sql("select public.ffm_verify_suppression('owner')")
    check("C15 a PARTIAL live list (one hash missing) is refused with the exact count", j["verified"] is False and j["reason"].startswith(f"incomplete: 1 of {NSUP}"), str(j))
    sql("select public.ffm_import_suppression_hashes()")
    j = sql("select public.ffm_verify_suppression('owner')")
    owner(False)
    check("C16 restoring the missing entry and verifying again re-opens the gate", j["verified"] is True and sql("select public.ffm_outreach_gate_open()"), str(j))
    DST_.commit()
    v3_restore_closed_checks(DST_, cur, sql, owner, work)
    DST_.commit()
    # negative control for the restore tool's own pass criterion: if the restored database would ALLOW outreach, the tool must say so
    import restore_backup as R
    cur.execute("create or replace function public.ffm_outreach_gate_open() returns boolean language sql as 'select true'")
    ctl = {}
    gate_ok = R.apply_gate(cur, ctl, None)
    DST_.rollback()
    check("C17 negative control: a restored database that would allow outreach makes apply_gate() report failure", gate_ok is False, str(ctl.get("outreach_gate")))
    DST_.close()
    # drop the auth stub: restore_backup refuses a server that has an auth schema. (DST is wiped by the next restore anyway.)
    with psycopg2.connect(DST) as c2, c2.cursor() as c2c:
        c2c.execute("drop schema if exists auth cascade")

    # ---- tampered / partial / absent suppression sections in the FILE
    def tamper(label, mutate, extra=None, env=None):
        m = dict(members); mutate(m)
        path = os.path.join(work, f"tamper_{label}.enc"); open(path, "wb").write(_build(m, key))
        return restore_cmd(["--file", path, "--wipe"] + (extra or []), env or renv, os.path.join(work, f"tamper_{label}.json"))
    def drop_one(m):
        d = json.loads(m["suppression/hashes.json"]); d["macs"] = d["macs"][1:]; m["suppression/hashes.json"] = json.dumps(d, separators=(",", ":"), sort_keys=True).encode()
    code, r1 = tamper("partial", drop_one)
    check("T1 a suppression list with an entry removed (manifest unchanged) is refused by the restore tool", code != 0 and "suppression/hashes.json" in r1.get("error", ""), r1.get("error", "")[:120])
    def drop_one_fix_sha(m):
        drop_one(m); mm = json.loads(m["manifest.json"]); mm["suppression"]["sha256"] = hashlib.sha256(m["suppression/hashes.json"]).hexdigest(); m["manifest.json"] = json.dumps(mm, separators=(",", ":"), sort_keys=True).encode()
    code, r2 = tamper("partial2", drop_one_fix_sha)
    check("T2 an entry removed AND the file hash in the manifest fixed up is still refused (count/digest no longer match the list)", code != 0 and "inconsistent" in r2.get("error", ""), r2.get("error", "")[:140])
    def swap_mac(m):
        d = json.loads(m["suppression/hashes.json"]); d["macs"][0][1] = "0" * 64; m["suppression/hashes.json"] = json.dumps(d, separators=(",", ":"), sort_keys=True).encode()
        mm = json.loads(m["manifest.json"]); mm["suppression"]["sha256"] = hashlib.sha256(m["suppression/hashes.json"]).hexdigest(); m["manifest.json"] = json.dumps(mm, separators=(",", ":"), sort_keys=True).encode()
    code, r3 = tamper("altered", swap_mac)
    check("T3 an entry altered (file hash fixed up) is refused", code != 0 and "inconsistent" in r3.get("error", ""), r3.get("error", "")[:140])
    def smaller_consistent(m):
        d = json.loads(m["suppression/hashes.json"]); d["macs"] = d["macs"][1:]; dg = hq_consent.suppression_digest(d["macs"])
        d.update(count=dg["count"], email_count=dg["email_count"], phone_count=dg["phone_count"], hash=dg["hash"]); m["suppression/hashes.json"] = json.dumps(d, separators=(",", ":"), sort_keys=True).encode()
        mm = json.loads(m["manifest.json"]); mm["suppression"].update(sha256=hashlib.sha256(m["suppression/hashes.json"]).hexdigest(), count=dg["count"], hash=dg["hash"], email_count=dg["email_count"], phone_count=dg["phone_count"])
        m["manifest.json"] = json.dumps(mm, separators=(",", ":"), sort_keys=True).encode()
    code, r4 = tamper("smaller", smaller_consistent, ["--expect-sha256", out_sha])
    check("T4 a self-consistent but SMALLER list is caught by the expected file hash taken from the audit log (--expect-sha256): the file is not the one the bot wrote", code != 0 and "checksum mismatch" in r4.get("error", ""), r4.get("error", "")[:120])
    code, r5 = tamper("smaller2", smaller_consistent)
    g5 = r5.get("outreach_gate") or {}
    check("T5 without --expect-sha256 (explicit --i-accept-unverified-suppression) a self-consistent smaller list restores, but its checkpoint is NOT staged: the gate is closed with no checkpoint and says so", code == 0 and g5.get("open") is False and g5.get("checkpoint_staged") is False and "NOT staged" in str(g5.get("checkpoint_ignored", "")), str(g5)[:200])
    code, r5b = restore_cmd(["--file", os.path.join(work, "tamper_smaller2.enc"), "--wipe", "--no-default-flags"], renv, os.path.join(work, "tamper_noflag.json"))
    check("T5b a restore with neither --expect-sha256 nor --i-accept-unverified-suppression is refused before anything is touched", code == 2 and "--expect-sha256" in (r5b.get("error", "") or ""), (r5b.get("error", "") or "")[-140:])
    def no_suppression(m):
        del m["suppression/hashes.json"]; mm = json.loads(m["manifest.json"]); mm["suppression"] = {"included": False, "reason": "the owner has not set the suppression key, so no keyed hashes can be exported"}
        m["manifest.json"] = json.dumps(mm, separators=(",", ":"), sort_keys=True).encode()
    code, r6 = tamper("none", no_suppression)
    g6 = r6.get("outreach_gate") or {}
    with psycopg2.connect(DST) as c3, c3.cursor() as c3c:
        c3c.execute("select state, expected_hash is null, public.ffm_outreach_gate_open() from public.ffm_outreach_gate where id = 1"); st = c3c.fetchone()
    check("T6 a backup WITHOUT a suppression section (key never set) restores, but there is no checkpoint, the gate is closed and says so", code == 0 and g6.get("checkpoint_staged") is False and st == ("unverified", True, False) and "no checkpoint" in g6.get("note", ""), f"{g6} {st}")
    def undeclared(m):
        m["suppression/hashes.json"] = b"{}"; mm = json.loads(m["manifest.json"]); mm["suppression"] = {"included": False, "reason": "x"}; m["manifest.json"] = json.dumps(mm, separators=(",", ":"), sort_keys=True).encode()
    code, r7 = tamper("undeclared", undeclared)
    check("T7 a suppression file the manifest does not declare is refused", code != 0 and "not declared" in r7.get("error", ""), r7.get("error", "")[:120])


# ---------------------------------------------------------------------------------------------------------------------------------------------------------------
# v3: the RESTORE-CLOSED gate against a real second database, with the real hq_gatemark sender code talking to it. "Provider restore" = pg_dump of the live scratch database restored into a
# NEW database with no help from any of our tools (what a PITR / backup restore does to the data). Everything runs on this machine; nothing is production.
def _admin_url(dsn, name):
    base = dsn.rsplit("/", 1)[0]
    return f"{base}/{name}"


def v3_restore_closed_checks(DST_, cur, sql, owner, work):
    import hq, hq_gatemark as G
    from pg_adapter import PgAdapter
    sfx = DST_NAME.replace("drill_restore_", "") or str(os.getpid())
    cur.execute("select count(*) from public.ffm_restore_markers where source = 'restore_backup.py'"); n_marker = cur.fetchone()[0]
    cur.execute("select (select epoch from public.ffm_epoch where id = 1), (select verified_at > (select max(restored_at) from public.ffm_restore_markers) from public.ffm_outreach_gate where id = 1)"); ep0, after = cur.fetchone()
    check("V1 the restore tool wrote a restore marker (same transaction as the restore) and the owner's verification is NEWER than it", n_marker == 1 and after is True, f"markers={n_marker} epoch={ep0}")
    DST_.commit()
    hwm = os.path.join(work, "sender_hwm.jsonl")
    fp = sql("select public.ffm_instance_fp()")
    prov_names = []
    def mkdb(name, admin_dsn=None):
        admin = admin_dsn or _admin_url(DST, "postgres")
        c = psycopg2.connect(admin); c.autocommit = True
        c.cursor().execute(f'drop database if exists "{name}"'); c.cursor().execute(f'create database "{name}"'); c.close()
        prov_names.append((name, admin))
    def dump_to(dest_dsn, dump):
        r = subprocess.run(["pg_restore", "--no-owner", "-d", dest_dsn, dump], capture_output=True, text=True, timeout=300)
        bad = [l for l in r.stderr.splitlines() if l.startswith("pg_restore: error") and "already exists" not in l and "errors ignored" not in l]
        return not bad and "FATAL" not in r.stderr, "; ".join(bad)[-200:]
    with mock.patch.dict(os.environ, {"GATE_HWM_FILE": hwm}, clear=False):
        ad_live = PgAdapter(DST + ("&" if "?" in DST else "?") + "options=-c%20timezone%3DUTC")
        with mock.patch.object(hq, "_request", side_effect=ad_live):
            G._CACHE.update(at=0.0, rec=None)
            a0 = G.attest()
            check("V2 an UNANCHORED sender (no mark anywhere) refuses, and does not anchor itself to the database", a0.get("reason") == "sender_unanchored" and not os.path.exists(hwm), str(a0))
            r_anchor = G.anchor("drill")
            a1 = G.attest()
            check("V3 the owner anchors the sender once the gate is verified after the restore marker; the sender then attests ok and the gate stays open", r_anchor.get("ok") is True and a1.get("ok") is True and sql("select public.ffm_outreach_gate_open()") is True, f"{r_anchor} {a1}")
        DST_.commit()
        dump = os.path.join(work, "provider_snapshot.dump")
        subprocess.run(["pg_dump", "-Fc", "--no-owner", "-n", "public", "-n", "auth", "-d", DST, "-f", dump], check=True, timeout=300)       # t0: the "provider backup" (gate OPEN, checkpoint staged)
        # t1: a person opts out AFTER the snapshot; the sender sees it
        cur.execute("insert into public.contact_suppressions (address, reason, recorded_by) values ('latecomer-optout@example.com', 'drill: opted out after the provider snapshot', 'drill')"); DST_.commit()
        with mock.patch.object(hq, "_request", side_effect=ad_live):
            a2 = G.attest(); mark = G.read_mark()
        check("V4 after a new opt-out the sender's OUTSIDE mark advances with the database epoch", a2.get("ok") is True and mark["epoch"] > ep0, f"{a2} mark={mark}")
        # t2: PROVIDER-LEVEL RESTORE of the t0 snapshot into a NEW database (no tool of ours involved)
        prov = f"drill_prov_{sfx}"; mkdb(prov)
        ok, err = dump_to(_admin_url(DST, prov), dump)
        PROV = _admin_url(DST, prov)
        pc = psycopg2.connect(PROV); pcur = pc.cursor()
        pcur.execute("select public.ffm_outreach_gate_open(), public.is_suppressed('latecomer-optout@example.com'), public.outreach_recipient_problem('email', 'latecomer-optout@example.com', null)"); exposed = pcur.fetchone(); pc.rollback()
        check("V5 EXPOSURE, stated honestly: a provider-restored copy taken inside the attestation window shows the OLD gate OPEN and the LOST opt-out as not suppressed - the database alone cannot tell", ok and exposed == (True, False, None), f"restore_ok={ok} {exposed} {err[-80:]}")
        ad_prov = PgAdapter(PROV + ("&" if "?" in PROV else "?") + "options=-c%20timezone%3DUTC")
        with mock.patch.object(hq, "_request", side_effect=ad_prov):
            G._CACHE.update(at=0.0, rec=None)
            a3 = G.attest()
        pcur.execute("select public.ffm_outreach_gate_open(), (select state from public.ffm_outreach_gate where id = 1), public.outreach_recipient_problem('email', 'latecomer-optout@example.com', null), public.outreach_recipient_problem('email', 'anyone@example.com', null), (select count(*) from public.ffm_restore_markers where source = 'detected_by_sender')"); closed = pcur.fetchone(); pc.rollback()
        check("V6 the sender's FIRST attestation against the restored copy detects the rollback (its mark is ahead), the database closes ITSELF for everyone, and a marker is written", a3.get("ok") is False and a3.get("reason") == "rollback_detected" and closed == (False, "unverified", "suppression_unverified", "suppression_unverified", 1), f"{a3} {closed}")
        check("V7 the sender's mark did not move down", G.read_mark()["epoch"] == mark["epoch"], str(G.read_mark()))
        # the same restore with the sender DOWN: staleness closes it by itself once the window passes
        pcur.execute("select count(*) from pg_stat_activity where datname = current_database() and pid <> pg_backend_pid()"); pc.rollback(); pc.close()
        prov2 = f"drill_prov2_{sfx}"; mkdb(prov2); ok2, err2 = dump_to(_admin_url(DST, prov2), dump); PROV2 = _admin_url(DST, prov2)
        p2 = psycopg2.connect(PROV2); p2c = p2.cursor(); p2c.execute("select public.ffm_outreach_gate_open()"); open0 = p2c.fetchone()[0]
        # V8b THE EXACT PITR SCENARIO for /gate anchor: this restored copy was NOT detected (no sender attested against it), its gate is open and 'verified', and someone runs /gate anchor.
        # The database epoch is below the sender's mark and no owner restore was recorded: the anchor must refuse and the mark must not move.
        mark_before = G.read_mark()
        ad_prov2 = PgAdapter(PROV2 + ("&" if "?" in PROV2 else "?") + "options=-c%20timezone%3DUTC")
        with mock.patch.object(hq, "_request", side_effect=ad_prov2):
            r_lower = G.anchor("drill")
        check("V8b /gate anchor on an UNDETECTED provider restore (db epoch below the mark, no owner-recorded restore) is refused and the mark does not move", r_lower.get("ok") is False and r_lower.get("reason") == "restore_not_recorded" and G.read_mark() == mark_before, f"{r_lower}")
        p2c.execute("set session_replication_role = replica"); p2c.execute("update public.ffm_outreach_gate set attested_at = attested_at - interval '16 minutes'"); p2c.execute("set session_replication_role = origin")
        p2c.execute("select public.ffm_outreach_gate_open(), public.outreach_recipient_problem('email', 'anyone@example.com', null)"); late = p2c.fetchone(); p2.rollback(); p2.close()
        check("V8 restored OPEN gate with NO sender running: open inside the window, closed by itself 16 minutes after the last attestation", ok2 and open0 is True and late == (False, "suppression_unverified"), f"{open0} {late}")
        # OTHER CLUSTER: a dump restored into a different server has a different system identifier -> the stored fingerprint no longer matches, with no sender at all
        other = os.environ.get("DRILL_OTHER_CLUSTER_URL")
        if other:
            prov3 = f"drill_prov3_{sfx}"
            try:
                oc = psycopg2.connect(_admin_url(other, "postgres")); oc.autocommit = True; occ = oc.cursor()
                for r in ("anon", "authenticated", "service_role"):
                    occ.execute(f"do $$ begin create role {r} nologin; exception when duplicate_object then null; end $$")
                occ.execute(f'drop database if exists "{prov3}"'); occ.execute(f'create database "{prov3}"'); oc.close()
                prov_names.append((prov3, _admin_url(other, "postgres")))
                ok3, err3 = dump_to(_admin_url(other, prov3), dump)
                p3 = psycopg2.connect(_admin_url(other, prov3)); p3c = p3.cursor()
                p3c.execute("select public.ffm_outreach_gate_open(), (select instance_fp from public.ffm_outreach_gate where id = 1), public.ffm_instance_fp(), (public.ffm_outreach_gate_status() ->> 'instance_matches')::boolean"); o3 = p3c.fetchone(); p3.rollback(); p3.close()
                check("V9 a dump restored into ANOTHER CLUSTER (real second server, different system identifier) closes the gate by itself, no sender needed", ok3 and o3[0] is False and o3[1] != o3[2] and o3[3] is False, f"{o3} {err3[-80:]}")
            except Exception as e:
                check("V9 other-cluster restore", False, f"{type(e).__name__}: {str(e)[:160]}")
        else:
            if os.environ.get("DRILL_REQUIRE_OTHER_CLUSTER") == "1":
                check("V9 a dump restored into ANOTHER CLUSTER closes the gate by itself", False, "DRILL_REQUIRE_OTHER_CLUSTER=1 but DRILL_OTHER_CLUSTER_URL is not set (CI starts a second postgres service for this)")
            else:
                print("SKIP  V9 other-cluster restore (set DRILL_OTHER_CLUSTER_URL to a SECOND local Postgres server to run it; CI sets it and requires it; and it is documented in policy section 10)")
    for name, admin in prov_names:
        try:
            c = psycopg2.connect(admin); c.autocommit = True; c.cursor().execute(f'drop database if exists "{name}" with (force)'); c.close()
        except Exception:
            pass


WHERE = {"audit_log": " where action <> 'backup_ok'"}     # the backup writes its own audit row AFTER it has dumped the table


def counts(dsn, tables):
    out = {}
    with psycopg2.connect(dsn) as c, c.cursor() as cur:
        for t in tables:
            cur.execute(f'select count(*), md5(coalesce(string_agg(to_jsonb(x)::text, \'|\' order by to_jsonb(x)::text), \'\')) from public."{t}" x{WHERE.get(t, "")}')
            out[t] = cur.fetchone()
    return out


def restore_cmd(extra, env_extra, report):
    env = {**os.environ, **env_extra}
    if "--expect-sha256" not in extra and "--verify-only" not in extra and "--i-accept-unverified-suppression" not in extra and "--no-default-flags" not in extra:
        extra = extra + ["--i-accept-unverified-suppression"]    # a restore now REQUIRES one of the two (review finding 6); the cases that test other things take the explicit acceptance
    extra = [x for x in extra if x != "--no-default-flags"]
    p = subprocess.run([sys.executable, os.path.join(ROOT, "ops", "restore_backup.py"), "--report", report] + extra, env=env, capture_output=True, text=True, timeout=600)
    try:
        rep = json.load(open(report))
    except Exception:
        rep = {"error": p.stdout[-300:] + p.stderr[-300:]}
    return p.returncode, rep


def main():
    from fake_b2 import FakeB2
    from pg_adapter import PgAdapter
    import hq_backup as B

    src = psycopg2.connect(SRC); seed(src); src.close()
    key = Fernet.generate_key().decode()           # throwaway key for this drill only
    work = tempfile.mkdtemp(prefix="drill_")
    with FakeB2() as fake:
        ps = [mock.patch.object(B, "B2_AUTH_URL", fake.auth_url), mock.patch.object(B, "_b2_ok_url", lambda u: u.startswith(fake.url))]
        env = {"BACKUP_KEY": key, "BACKUP_PUT_URL": f"b2://{fake.bucket_id}/hq", "BACKUP_AUTH": "keyW:secretW"}
        adapter = PgAdapter(SRC + ("&" if "?" in SRC else "?") + "options=-c%20timezone%3DUTC")
        with mock.patch.dict(os.environ, env), mock.patch("hq._request", side_effect=adapter), ps[0], ps[1]:
            out = B.run(force=True)
        check("1 backup ran through hq_backup.run() and uploaded", out.get("ok"), f'{out.get("rows")} rows, sha256 {str(out.get("sha256"))[:16]}..., complete={out.get("complete")}')
        check("2 off-site store holds the encrypted file + sha256 sidecar", sorted(f["fileName"].rsplit(".", 1)[-1] for f in fake.files) == ["enc", "sha256"], ", ".join(f["fileName"] for f in fake.files))
        enc = next(f["bytes"] for f in fake.files if f["fileName"].endswith(".enc"))
        check("3 stored object is ciphertext (no plaintext leak)", b"Lead 3" not in enc and b"example.com" not in enc and b"caf\xc3\xa9" not in enc and Fernet(key.encode()).decrypt(enc) != enc)
        check("4 stored sha256 equals sha256 of stored bytes", out["sha256"] == hashlib.sha256(enc).hexdigest())
        audit = adapter("GET", "/rest/v1/audit_log?action=eq.backup_ok&select=detail&limit=1")
        check("5 audit_log recorded backup_ok with checksum and no secret", bool(audit) and audit[0]["detail"]["sha256"] == out["sha256"]
              and key not in json.dumps(audit) and "secretW" not in json.dumps(audit))

        renv = {"BACKUP_KEY": key, "RESTORE_B2_AUTH": "keyR:secretR", "RESTORE_B2_BUCKET_ID": fake.bucket_id, "RESTORE_B2_PREFIX": "hq/",
                "RESTORE_B2_AUTH_URL": fake.auth_url, "RESTORE_DB_URL": DST}
        rep_path = os.path.join(work, "report.json")
        code, rep = restore_cmd(["--b2-latest", "--wipe", "--expect-sha256", out["sha256"]], renv, rep_path)
        check("6 restore tool: download with READ-only key, sha256 sidecar + audit checksum match, decrypts", rep.get("file", {}).get("sidecar_sha256_ok") and rep.get("file", {}).get("expected_sha256_ok") and rep.get("file", {}).get("decrypts"), rep.get("error", ""))
        check("7 restore tool: overall result", code == 0 and rep.get("result") == "PASS", json.dumps(rep.get("steps", {})) + " " + rep.get("error", ""))
        for k, v in (rep.get("business_data") or {}).items():
            check(f"8 business data survives: {k}", v["all_identical"], json.dumps(v["tables"]))
        sc = rep.get("schema", {})
        for cat in ("functions", "triggers", "indexes", "constraints", "table_grants", "views", "tables"):
            if cat in sc:
                check(f"9 schema identical after restore: {cat}", sc[cat]["identical"], f'{sc[cat]["backup"]} -> {sc[cat]["restored"]}')
        for name, r in (rep.get("smoke") or {}).items():
            check(f"10 smoke test on restored DB: {name}", r["ok"], r.get("detail") or r.get("result") or "")
        check("11 constraint warnings (rows violating FKs)", not rep.get("constraint_warnings"), "; ".join(rep.get("constraint_warnings", [])[:3]))

        # independent comparison, not using the restore tool's own checks: source database vs restored database, row content hash per table
        names = [t for t in (rep.get("rows") or {})]
        a, b = counts(SRC, names), counts(DST, names)
        diff = [t for t in names if a[t] != b[t]]
        check("12 independent check: every table's content hash is identical in source and restored DB", names and not diff, f"{len(names)} tables, {sum(v[0] for v in a.values())} rows; differing: {diff[:5]}")

        with psycopg2.connect(DST) as dc, dc.cursor() as dcur:
            dcur.execute("insert into public.drill_child (ref_id) values (1) returning id")
            nid = dcur.fetchone()[0]
            dcur.execute("select count(*) from public.drill_child where id = %s", (nid,))
            dcur.execute("select option_value from pg_options_to_table((select reloptions from pg_class where relname = 'drill_ref_v'))")
            opts = dcur.fetchall()
            dc.rollback()
        with psycopg2.connect(DST) as dc, dc.cursor() as dcur:
            dcur.execute("select obj_description('public.drill_ref'::regclass), col_description('public.drill_ref'::regclass, 2), obj_description('public.drill_ref_v'::regclass), obj_description('public.capital_mode()'::regprocedure)")
            cm = dcur.fetchone()
            dcur.execute("select has_schema_privilege('anon','public','USAGE'), has_schema_privilege('service_role','public','USAGE')")
            sp = dcur.fetchone()
        check("14 comments (table, column, view, function) and schema USAGE grants are restored", cm == ("Reference table: it's \"quoted\" 美味", "human label", "view comment", "returns the capital mode") and sp == (True, True), f"{cm} {sp}")
        import io as _io, tarfile as _tf
        mf = json.loads(_tf.open(fileobj=_io.BytesIO(Fernet(key.encode()).decrypt(enc)), mode="r:gz").extractfile("manifest.json").read())
        _tar = _tf.open(fileobj=_io.BytesIO(Fernet(key.encode()).decrypt(enc)), mode="r:gz")
        _names = _tar.getnames(); _blob = b"".join(_tar.extractfile(n).read() for n in _names if n.startswith("data/"))
        _client = [n for n in _names if n.startswith("data/") and (n[5:].split(".")[0] in ("leads", "outbox", "lead_replies", "deals", "contact_suppressions", "setters", "setter_events", "setter_payouts", "client_workspaces") or n[5:].startswith(("ws_", "ffm_")))]
        check("P1 CLIENT PII IS NOT IN THE OFF-SITE FILE: no client table files, and none of the seeded lead names/emails/phones appear in any data file", not _client and b"lead1@example.com" not in _blob and b"Lead 3" not in _blob and b"+1613555" not in _blob and "schema.json" in _names, f"client files: {_client}")
        check("P2 the file carries the export policy (what was excluded and why) and the schema still rebuilds the empty client tables", any(t["name"] == "leads" for t in json.loads(_tar.extractfile("schema.json").read())["tables"]) and any(e[0] == "leads" for e in mf.get("excluded", [])), "")
        check("2b the backup used the single-statement database snapshot (consistent=True)", mf["consistency"]["consistent"] and "single SQL statement" in mf["consistency"]["method"], json.dumps(mf["consistency"]))
        # live-concurrency proof: a writer commits paired rows into two tables (one transaction each) while snapshots are taken; every snapshot must show matching pairs
        import threading, time
        ddl = psycopg2.connect(SRC); ddl.autocommit = True
        ddl.cursor().execute("create table if not exists public.drill_pair_a (id int primary key); create table if not exists public.drill_pair_b (id int primary key); truncate public.drill_pair_a, public.drill_pair_b")
        stop = threading.Event(); wrote = {"n": 0}
        def writer():
            w = psycopg2.connect(SRC)
            i = 0
            while not stop.is_set():
                i += 1
                with w.cursor() as wc:
                    wc.execute("insert into public.drill_pair_a values (%s)", (i,)); wc.execute("insert into public.drill_pair_b values (%s)", (i,))
                w.commit(); wrote["n"] = i
            w.close()
        th = threading.Thread(target=writer); th.start()
        bad, taken = 0, 0
        try:
            time.sleep(0.3)
            for _ in range(25):
                snap = adapter("POST", "/rest/v1/rpc/backup_snapshot", {}, exact=True)
                a = {r["id"] for r in snap["data"]["drill_pair_a"]}; b = {r["id"] for r in snap["data"]["drill_pair_b"]}
                taken += 1; bad += (a != b)
        finally:
            stop.set(); th.join()
        committed_2c = wrote["n"]   # the negative control below reuses the same writer/counter; capture this phase's count now
        ddl.cursor().execute("drop table public.drill_pair_a, public.drill_pair_b"); ddl.close()
        with psycopg2.connect(SRC) as sc, sc.cursor() as scur:
            scur.execute("select p.proname, p.provolatile, has_function_privilege('anon', p.oid, 'execute'), has_function_privilege('authenticated', p.oid, 'execute'), has_function_privilege('service_role', p.oid, 'execute') from pg_proc p where p.proname in ('backup_snapshot', 'backup_schema')")
            fr = scur.fetchall()
        check("2d backup_snapshot/backup_schema are STABLE (single-snapshot guarantee depends on it) and only service_role may execute", len(fr) == 2 and all(r[1] == "s" and not r[2] and not r[3] and r[4] for r in fr), str(fr))
        # negative control: reading the two tables in two SEPARATE statements while the writer runs MUST show mismatches (proves check 2c can fail)
        stop.clear(); th = threading.Thread(target=writer); ddl2 = psycopg2.connect(SRC); ddl2.autocommit = True
        ddl2.cursor().execute("create table if not exists public.drill_pair_a (id int primary key); create table if not exists public.drill_pair_b (id int primary key); truncate public.drill_pair_a, public.drill_pair_b")
        th.start(); split_bad = 0
        try:
            time.sleep(0.3)
            for _ in range(300):
                with ddl2.cursor() as xc:
                    xc.execute("select id from public.drill_pair_a"); a = {r[0] for r in xc.fetchall()}
                    time.sleep(0.003)
                    xc.execute("select id from public.drill_pair_b"); b = {r[0] for r in xc.fetchall()}
                split_bad += (a != b)
                if split_bad:
                    break
        finally:
            stop.set(); th.join()
        ddl2.cursor().execute("drop table public.drill_pair_a, public.drill_pair_b"); ddl2.close()
        check("2e negative control: two separate statements DO show cross-table skew under the same writer (so 2c can fail)", split_bad > 0, f"skewed reads seen: {split_bad}")
        check("2c under concurrent two-table transactions, every snapshot is internally consistent", bad == 0 and committed_2c > 50, f"{taken} snapshots while {committed_2c} paired transactions committed; inconsistent snapshots: {bad}")
        check("13 restored sequences continue after the data (next serial id does not collide) and view keeps security_invoker", nid > 25 and ("true",) in opts, f"next id {nid}, view options {opts}")
        consent_checks(enc, key, rep, renv, work, out["sha256"])
        # restore the plain full restore so the remaining checks see the same database as before
        code, rep = restore_cmd(["--b2-latest", "--wipe", "--expect-sha256", out["sha256"]], renv, os.path.join(work, "report_again.json"))
        check("C18 full restore again after the consent checks (state for the remaining checks)", code == 0, rep.get("error", ""))
        # ---- negative controls: the checks must be able to fail
        bad = bytearray(enc); bad[len(bad) // 2] ^= 1
        fake.files.append({"fileId": "4_zfake_bad", "fileName": "hq/hq-99990101T000000Z.tar.gz.enc", "bytes": bytes(bad), "sha1": hashlib.sha1(bytes(bad)).hexdigest()})
        fake.files.append({"fileId": "4_zfake_bad2", "fileName": "hq/hq-99990101T000000Z.tar.gz.enc.sha256", "bytes": f"{out['sha256']}  x\n".encode(), "sha1": hashlib.sha1(f"{out['sha256']}  x\n".encode()).hexdigest()})
        code, rep2 = restore_cmd(["--b2-latest", "--wipe"], renv, os.path.join(work, "neg1.json"))
        check("N1 corrupted object in storage is rejected by checksum", code != 0 and "checksum mismatch" in rep2.get("error", ""), rep2.get("error", "")[:100])
        fake.files[:] = [f for f in fake.files if "9999" not in f["fileName"]]
        code, rep3 = restore_cmd(["--b2-latest", "--wipe"], {**renv, "BACKUP_KEY": Fernet.generate_key().decode()}, os.path.join(work, "neg2.json"))
        check("N2 wrong BACKUP_KEY is rejected", code != 0 and "cannot decrypt" in rep3.get("error", ""), rep3.get("error", "")[:100])
        code, rep4 = restore_cmd(["--b2-latest", "--wipe"], {**renv, "RESTORE_DB_URL": "postgresql://postgres:pw@db.ihxzvpwbqydqtblvazbq.supabase.co:5432/postgres"}, os.path.join(work, "neg3.json"))
        check("N3 production-looking target is refused before any connection", code != 0 and "refusing" in rep4.get("error", ""), rep4.get("error", "")[:100])
        code, rep5 = restore_cmd(["--b2-latest", "--wipe"], {**renv, "RESTORE_DB_URL": "postgresql://postgres:pw@localhost:5432/postgres"}, os.path.join(work, "neg4.json"))
        check("N4 local database with a real-looking name is refused", code != 0 and "refusing" in rep5.get("error", ""), rep5.get("error", "")[:100])
        code, rep6 = restore_cmd(["--b2-latest"], renv, os.path.join(work, "neg5.json"))
        check("N5 non-empty scratch DB is not overwritten without --wipe", code != 0 and "not empty" in rep6.get("error", ""), rep6.get("error", "")[:100])
        code, rep7 = restore_cmd(["--b2-latest", "--wipe", "--expect-sha256", "0" * 64], renv, os.path.join(work, "neg6.json"))
        check("N6 mismatching expected checksum is rejected", code != 0 and "checksum mismatch" in rep7.get("error", ""), rep7.get("error", "")[:100])

        # row-level verifier must notice a damaged restore
        import restore_backup as R
        conn = psycopg2.connect(DST); conn.autocommit = False
        cur = conn.cursor()
        cur.execute("delete from public.ledger where ctid = (select ctid from public.ledger order by created_at, note limit 1)")
        cur.execute("update public.memory set content = content || 'X' where ctid = (select ctid from public.memory order by created_at limit 1)")
        data = {}
        import io, tarfile
        from cryptography.fernet import Fernet as F
        tar = tarfile.open(fileobj=io.BytesIO(F(key.encode()).decrypt(enc)), mode="r:gz")
        for t in ("ledger", "memory", "tasks"):
            data[t] = [json.loads(ln) for ln in tar.extractfile(f"data/{t}.jsonl").read().decode().split("\n") if ln.strip()]
        rr = {}
        ok_dmg = R.verify_rows(cur, data, rr)
        conn.rollback(); conn.close()
        check("N7 row verifier catches a deleted row and an altered value", (not ok_dmg) and not rr["rows"]["ledger"]["identical"] and not rr["rows"]["memory"]["identical"] and rr["rows"]["tasks"]["identical"],
              f'ledger={rr["rows"]["ledger"]}, memory={rr["rows"]["memory"]}')

        # schema verifier must notice a damaged restore (dropped index, edited function, revoked grant, dropped trigger)
        schema = json.loads(tar.extractfile("schema.json").read().decode())
        conn = psycopg2.connect(DST); conn.autocommit = False
        cur = conn.cursor()
        base = {}
        ok_clean = R.verify_schema(cur, schema, base)
        idx = schema["indexes"][0]
        cur.execute(f'drop index if exists public."{idx["name"]}"')
        cur.execute("create or replace function public.capital_mode() returns text language sql as $$ select 'tampered'::text $$")
        sr = {}
        ok_bad = R.verify_schema(cur, schema, sr)
        conn.rollback(); conn.close()
        check("N8 schema verifier passes clean restore and catches dropped index + edited function",
              ok_clean and (not ok_bad) and not sr["schema"]["indexes"]["identical"] and not sr["schema"]["functions"]["identical"],
              str({k: v.get("identical") for k, v in sr.get("schema", {}).items()})[:200])

        # ---- the owner's one-command local restore (Docker): isolated throwaway server, hidden-prompt secrets, no secret in outputs
        import shutil
        if shutil.which("docker") and subprocess.run(["docker", "info"], capture_output=True).returncode == 0 and os.environ.get("DRILL_SKIP_DOCKER") != "1":
            lf = os.path.join(work, "local_restore"); os.makedirs(lf, exist_ok=True)
            open(os.path.join(lf, "hq-local.tar.gz.enc"), "wb").write(enc)
            open(os.path.join(lf, "hq-local.tar.gz.enc.sha256"), "w").write(out["sha256"] + "  hq-local.tar.gz.enc\n")
            p = subprocess.run(["bash", os.path.join(ROOT, "ops", "restore_local.sh"), "--file", os.path.join(lf, "hq-local.tar.gz.enc"), "--expect-sha256", out["sha256"]],
                               cwd=lf, env={**os.environ, "BACKUP_KEY": key}, capture_output=True, text=True, timeout=600)
            files = [f for f in os.listdir(lf) if f.startswith("restore_")]
            blob_all = p.stdout + p.stderr + "".join(open(os.path.join(lf, f)).read() for f in files)
            left = subprocess.run(["docker", "ps", "-a", "--format", "{{.Names}}"], capture_output=True, text=True).stdout
            check("L1 ops/restore_local.sh: isolated restore passes, writes report + fingerprint, leaks no key, destroys its container",
                  p.returncode == 0 and "RESULT: PASS" in p.stdout and len(files) == 2 and key not in blob_all and "fendezy-restore" not in left,
                  f"exit {p.returncode}; files {sorted(files)}" + ("" if p.returncode == 0 else " | " + p.stdout[-900:].replace(chr(10), " / ")))
        else:
            print("SKIP  L1 ops/restore_local.sh (Docker not available here; CI runs it)")

        # ---- restore-guard bypass attempts (found by the independent review): none may reach a database
        base = DST.rsplit("/", 1)[0]
        code, g1 = restore_cmd(["--b2-latest", "--wipe"], {**renv, "RESTORE_DB_URL": f"dbname={DST_NAME} host=localhost hostaddr=10.1.2.3 user=postgres"}, os.path.join(work, "g1.json"))
        check("G1 hostaddr in the connection string is refused", code == 2 and "hostaddr" in g1.get("error", ""), g1.get("error", "")[:90])
        code, g2 = restore_cmd(["--b2-latest", "--wipe"], {**renv, "RESTORE_DB_URL": f"dbname={DST_NAME} user=postgres", "PGHOST": "db.ihxzvpwbqydqtblvazbq.supabase.co"}, os.path.join(work, "g2.json"))
        check("G2 empty host + PGHOST environment redirect is refused", code == 2 and "explicit local host" in g2.get("error", ""), g2.get("error", "")[:90])
        code, g3 = restore_cmd(["--b2-latest", "--wipe"], {**renv, "RESTORE_DB_URL": f"dbname={DST_NAME} host=localhost service=prod user=postgres"}, os.path.join(work, "g3.json"))
        check("G3 service= in the connection string is refused", code == 2 and "service" in g3.get("error", ""), g3.get("error", "")[:90])
        adm = psycopg2.connect(base + "/postgres"); adm.autocommit = True
        with adm.cursor() as ac:
            ac.execute("drop database if exists drill_fakesb"); ac.execute("create database drill_fakesb")
        fk = psycopg2.connect(base + "/drill_fakesb"); fk.autocommit = True
        with fk.cursor() as fc:
            fc.execute("create schema auth; create schema storage; create table public.keepme(x int); insert into public.keepme values (42)")
        fk.close()
        code, g4 = restore_cmd(["--b2-latest", "--wipe"], {**renv, "RESTORE_DB_URL": base + "/drill_fakesb"}, os.path.join(work, "g4.json"))
        fk = psycopg2.connect(base + "/drill_fakesb")
        with fk.cursor() as fc:
            fc.execute("select x from public.keepme"); kept = fc.fetchall()
        fk.close()
        with adm.cursor() as ac:
            ac.execute("drop database drill_fakesb")
        adm.close()
        check("G4 a scratch-named database that looks like Supabase is refused and left untouched", code == 2 and "looks like a Supabase" in g4.get("error", "") and kept == [(42,)], g4.get("error", "")[:90])

        # ---- retention / recovery selection: the bucket lifecycle removes old files; the restore must always use the newest SURVIVING backup
        good = [f for f in fake.files if "99990101" not in f["fileName"]]
        side_txt = next(f["bytes"] for f in good if f["fileName"].endswith(".sha256"))
        def put(name, data):
            return {"fileId": "4_z" + name[-20:], "fileName": "hq/" + name, "bytes": data, "sha1": hashlib.sha1(data).hexdigest()}
        fake.files[:] = []
        for day in ("20260801", "20260901", "20261001"):
            nm = f"hq-{day}T080000Z.tar.gz.enc"
            fake.files += [put(nm, enc), put(nm + ".sha256", f"{out['sha256']}  {nm}\n".encode())]
        code, rr1 = restore_cmd(["--b2-latest", "--wipe"], renv, os.path.join(work, "ret1.json"))
        check("R1 restore picks the newest backup in the bucket", code == 0 and rr1.get("file", {}).get("name", "").startswith("hq/hq-20261001"), rr1.get("file", {}).get("name", rr1.get("error", "")))
        fake.files[:] = [f for f in fake.files if "20261001" not in f["fileName"]]      # lifecycle deleted the newest (or it failed to upload)
        code, rr2 = restore_cmd(["--b2-latest", "--wipe"], renv, os.path.join(work, "ret2.json"))
        check("R2 after the newest object disappears, restore uses the next surviving backup", code == 0 and rr2.get("file", {}).get("name", "").startswith("hq/hq-20260901"), rr2.get("file", {}).get("name", rr2.get("error", "")))
        code, rr3 = restore_cmd(["--b2-name", "hq-20260801T080000Z.tar.gz.enc", "--wipe"], renv, os.path.join(work, "ret3.json"))
        check("R3 an older backup can be restored by name (point-in-time choice)", code == 0 and rr3.get("file", {}).get("name", "").startswith("hq/hq-20260801"), rr3.get("file", {}).get("name", rr3.get("error", "")))
        fake.files[:] = []
        code, rr4 = restore_cmd(["--b2-latest", "--wipe"], renv, os.path.join(work, "ret4.json"))
        check("R4 empty bucket fails loudly instead of restoring nothing", code != 0 and "no backups found" in rr4.get("error", ""), rr4.get("error", "")[:80])

    bad_n = [r for r in results if not r[1]]
    for n, ok, d in bad_n:      # failures are listed right above the total so a CI log tail (the gate shows only the last lines) always names them
        print(f"    FAILED CHECK  {n}  [{str(d)[:300]}]")
    print(f"\n{len(results) - len(bad_n)}/{len(results)} checks passed")
    open(os.path.join(work, "drill_results.json"), "w").write(json.dumps([{"check": n, "pass": ok, "detail": d} for n, ok, d in results], indent=1))
    print("results file:", os.path.join(work, "drill_results.json"))
    sys.exit(1 if bad_n else 0)


if __name__ == "__main__":
    main()
