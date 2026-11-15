#!/usr/bin/env python3
"""Isolated-per-variant leak matrix (round 4). Every case is its OWN transaction: the person is inserted, then ERASED (the [erased] overwrite) or DELETED, ONE exported row carries ONE spelling,
the snapshot is taken as service_role (single statement AND paged with page size 1), the transaction is rolled back. Batched tests hid cross-row contamination (a neighbouring row that spells a
name whole made the squashed check catch a glued spelling elsewhere); here nothing can help. Usage: REPLICA_URL=postgresql://... python3 scripts/replica/isolated_leak_check.py [quick]"""
import json, os, re, sys, unicodedata
import psycopg2

URL = os.environ["REPLICA_URL"]
LEGACY = open(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "sqltests", "include", "legacy_spec.sql")).read()   # the pre-blanking classification: this test exercises the redaction ENGINE on tasks.result etc.
QUICK = len(sys.argv) > 1 and sys.argv[1] == "quick"
# (full name, surname-ish fragment that must never reach the export, squashed)
PEOPLE = [("Corvin Ashgrove-Pellew", "ashgrovepellew"), ("Fenella D'Arcy-Fenwhistle", "darcyfenwhistle"), ("Ottoline Brackenridge", "brackenridge"),
          ("Wilhelmina Strathaven", "strathaven"), ("Thaddeus Mockridge", "mockridge"), ("Alaric Vandenbroeck", "vandenbroeck")]
MUST_NOT = {"ashgrovepellew": ["ashgrovepellew"], "darcyfenwhistle": ["darcy", "fenwhistle"], "brackenridge": ["brackenridge"], "strathaven": ["strathaven"], "mockridge": ["mockridge"], "vandenbroeck": ["vandenbroeck"]}


def variants(name):
    toks = [t for t in re.split(r"[^A-Za-z]+", name) if t]
    sur_parts = toks[1:]
    sur = "".join(sur_parts)
    first = toks[0]
    spaced = " ".join(sur)
    out = {"plain": " ".join(toks), "glued_surname": sur, "capitalised_glued": sur.capitalize(), "upper": sur.upper(), "initial_glued": first[0].lower() + sur, "digits": sur + "2024", "leading_digit": "2" + sur,
           "plural": sur + "s", "the_plural": "the " + sur.capitalize() + "s", "spaced": spaced, "dotted": ".".join(sur), "hyphen_glued_pair": "-".join(sur_parts) if len(sur_parts) > 1 else sur[:5] + "-" + sur[5:],
           "email_like": sur + "@mail.example", "url": "https://x.example/" + sur, "www": "www." + sur + ".ca", "full_glued": first.lower() + sur, "reversed": sur_parts[-1] + ", " + first,
           "accent": sur.replace("e", "é"), "cyrillic_a": sur.replace("a", "а"), "zero_width": sur[:4] + "​" + sur[4:], "apostrophe_removed": sur.replace("'", ""), "fullwidth": "".join(chr(ord(c) + 0xFEE0) for c in sur)}
    if QUICK:
        keep = ["glued_surname", "digits", "spaced", "hyphen_glued_pair", "full_glued"]
        out = {k: v for k, v in out.items() if k in keep}
    return out


# (label, insert sql with %s for the spelling, also tells which text is exported)
COLS = {
    "tasks.result": "insert into tasks (assigned_agent, title, detail, status, result, created_by) values ((select slug from agents order by slug limit 1), 'iso', 'x', 'done', %s, 'owner')",
    "ledger.note": "insert into ledger (kind, amount_cents, currency, note, status) values ('expense', 4242, 'CAD', %s, 'received')",
    "audit_log.detail.value": "insert into audit_log (actor, action, target, detail) values ('iso', 'note', 'iso/v', jsonb_build_object('v', %s::text))",
    "audit_log.detail.key": "insert into audit_log (actor, action, target, detail) values ('iso', 'note', 'iso/k', jsonb_build_object(%s::text, 1))",
    "audit_log.detail.array": "insert into audit_log (actor, action, target, detail) values ('iso', 'note', 'iso/a', jsonb_build_object('l', jsonb_build_array(%s::text)))",
    "agent_runs.summary": "insert into agent_runs (agent_id, status, summary) values ((select id from agents order by slug limit 1), 'ok', %s)",
    "escalations.summary": "insert into escalations (from_agent, kind, summary) values ((select slug from agents order by slug limit 1), 'failure', %s)",
    "ideas.result": "insert into ideas (name, result) values ('iso', %s)",
    "approval_requests.recommendation": "insert into approval_requests (actor, action, recommendation) values ('iso', 'x', %s)",
    "bank_transactions.description": "insert into bank_transactions (posted_on, description, amount_cents, dedupe_key) values (current_date, %s, 100, 'iso1')",
    "bank_transactions.note": "insert into bank_transactions (posted_on, description, amount_cents, dedupe_key, note) values (current_date, 'x', 100, 'iso2', %s)",
    "executor_runs.refusal_reason": "insert into executor_runs (executor, agent_slug, purpose, status, refusal_reason) values ('x', 'x', 'x', 'refused', %s)",
    "payment_instructions.payee": "insert into payment_instructions (payee, amount_cents, purpose, requested_by) values (%s, 100, 'xxxxxx', 'iso')",
    "reconciliation_flags.detail": "insert into reconciliation_flags (check_name, detail) values ('iso', %s)",
}


def squash(t):
    t = unicodedata.normalize("NFKD", t)
    return re.sub(r"[^a-z0-9]", "", "".join(c for c in t if not unicodedata.combining(c)).lower().replace("а", "a"))


def case(state, name, frag, label, spelling, col):
    con = psycopg2.connect(URL); con.autocommit = False
    cur = con.cursor()
    try:
        cur.execute(LEGACY)
        cur.execute("select id from ventures order by slug limit 1"); v = cur.fetchone()[0]
        cur.execute("insert into leads (venture_id, name, email, phone, status) values (%s, %s, %s, %s, 'new')", (v, name, "x@" + frag + "-iso.example", "613-555-0399"))
        if state == "erased":
            cur.execute("update leads set name = '[erased]', email = null, phone = null where name = %s", (name,))
        else:
            cur.execute("delete from leads where name = %s", (name,))
        cur.execute("set local session_replication_role = replica")
        cur.execute(COLS[col], (spelling,))
        cur.execute("set local session_replication_role = origin")
        cur.execute("grant usage on schema public to service_role"); cur.execute("set local role service_role")
        cur.execute("select public.backup_snapshot() -> 'data'"); single = cur.fetchone()[0]
        paged = {}
        cur.execute("select public.backup_deny_prepare() ->> 'run'"); run = cur.fetchone()[0]             # as the Python backup does: the whole-export scan once, pages reuse it
        for t in single:
            rows, off = [], 0
            while True:
                cur.execute("select public.backup_snapshot_page(%s, %s, %s, %s::uuid)", (t, off, 7 if QUICK else 1, run))   # quick: pages of 7 (the full matrix and prop_paged_check keep page size 1)
                got = cur.fetchone()[0]["rows"]
                if not got: break
                rows += got; off += len(got)
            paged[t] = rows
        bad = []
        for mode, data in (("single", single), ("paged", paged)):
            sq = squash(json.dumps(data, ensure_ascii=False))
            for frag2 in MUST_NOT[frag]:
                if frag2 in sq: bad.append(mode)
        if sorted(json.dumps(r, sort_keys=True) for r in single.get("tasks", [])) != sorted(json.dumps(r, sort_keys=True) for r in paged.get("tasks", [])): bad.append("paged!=single(tasks)")
        return bad
    finally:
        con.rollback(); con.close()


def main():
    fails, n = [], 0
    cols_main = ["tasks.result", "audit_log.detail.key", "ledger.note"]
    for pi, (name, frag) in enumerate(PEOPLE[: 3 if QUICK else None]):
        for state in ("erased", "deleted"):
            for vi, (label, sp) in enumerate(variants(name).items()):
                col = cols_main[vi % len(cols_main)]
                n += 1
                bad = case(state, name, frag, label, sp, col)
                if bad: fails.append((state, name, label, col, bad))
            if pi == 0 or not QUICK:
                for col in COLS:                                       # the hard spelling in every strict column
                    n += 1
                    sp = variants(name)["spaced"] if "key" not in col else variants(name)["glued_surname"]
                    bad = case(state, name, frag, "spaced-every-column", sp, col)
                    if bad: fails.append((state, name, "spaced-every-column", col, bad))
    print(f"isolated cases: {n}, failures: {len(fails)}")
    for f in fails[:40]: print("LEAK", f)
    sys.exit(1 if fails else 0)


main()
