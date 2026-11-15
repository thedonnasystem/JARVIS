#!/usr/bin/env python3
"""ACL manifest of EVERY function, table, view and sequence in schema public, read from the REPLICA's catalog after every migration (lockdown last). The `note` column explains the consent-integrity functions (FUNCS below); other rows have an empty note.
One tab-separated row per object so another agent's global manifest can merge it with a plain concatenation / sort -u: kind, name, anon, authenticated, service_role, security, note.
    scripts/acl_manifest.py --write    regenerate ops/ACL_MANIFEST_public.tsv     scripts/acl_manifest.py --check    fail when the file differs from the replica's catalog
The privilege columns are what has_*_privilege answers (the effective ACL, including PUBLIC and role inheritance), not what a migration says."""
import argparse, os, subprocess, sys

OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "ops", "ACL_MANIFEST_public.tsv")
TABLES = ["ffm_epoch", "ffm_restore_markers", "ffm_gate_config", "ffm_sender_mark", "ffm_outreach_gate", "ffm_suppression_expected", "ffm_suppression_hashes", "ffm_phone_suppressions", "ffm_secrets", "ffm_consent_log", "ffm_consent_captures", "ffm_consent_wordings"]   # the consent-integrity tables: anon and authenticated must hold NOTHING on these (asserted)
FUNCS = {   # name -> why it is safe for service_role to hold execute (the lockdown blanket grant gives it)
    "ffm_epoch_guard": "trigger function: cannot be called directly",
    "ffm_epoch_bump": "trigger function (inlined update of the epoch row): cannot be called directly",
    "ffm_lead_identifier_guard": "trigger function: cannot be called directly",
    "ffm_instance_fp": "read-only",
    "ffm_gate_core_ok": "read-only decision",
    "ffm_outreach_gate_open": "read-only decision",
    "ffm_outreach_gate_status": "read-only, no key and no list",
    "ffm_gate_state": "read-only, no key and no list",
    "ffm_close_outreach_gate": "bot-callable BY DESIGN: it can only close (fail-closed); audited",
    "ffm_owner_record_restore": "owner only (ffm_require_owner in the body)",
    "ffm_set_gate_config": "owner only (ffm_require_owner in the body)",
    "ffm_verify_suppression": "owner only (ffm_require_owner in the body)",
    "ffm_sender_attest": "bot-callable BY DESIGN: monotonic against ffm_sender_mark, cannot open a closed gate, anchor needs an unconsumed owner marker",
    "outreach_channel_problem": "immutable policy function",
    "outreach_recipient_problem": "read-only decision",
    "outreach_send_allowed": "read-only decision",
    "ffm_withdraw_consent": "bot-callable BY DESIGN: it can only ADD a withdrawal and suppressions",
    "ffm_contact_status": "read-only decision",
    "ffm_can_contact": "read-only decision",
    "ffm_route_preview": "dry run only",
    "outbox_dnc_guard": "trigger function: cannot be called directly",
    "outreach_channel_disabled": "read-only decision (text/call disabled until the owner enables them)",
    "ffm_set_phone_outreach": "owner only (ffm_require_owner in the body)",
}


def psql(url, sql):
    r = subprocess.run(["psql", url, "-X", "-At", "-F", "\t", "-v", "ON_ERROR_STOP=1", "-c", sql], capture_output=True, text=True, timeout=120, env={**os.environ})
    if r.returncode:
        sys.exit("psql failed: " + r.stderr.strip()[:300])
    return r.stdout


def build(url):
    """EVERY function, table, view and sequence in schema public, one row each (the effective ACL per role, from has_*_privilege). Sorted, so any drift is a one-line diff."""
    rows = []
    tpriv = "array['select','insert','update','delete','truncate','references','trigger']"
    cols = ", ".join(f"coalesce((select string_agg(p, ',' order by p) from unnest({tpriv}) p where has_table_privilege('{r}', c.oid, p)), '-')" for r in ("anon", "authenticated", "service_role"))
    out = psql(url, f"select case c.relkind when 'v' then 'view' when 'm' then 'view' else 'table' end, c.relname, {cols}, 'rls=' || c.relrowsecurity::text from pg_class c where c.relnamespace = 'public'::regnamespace and c.relkind in ('r', 'p', 'v', 'm') and not exists (select 1 from pg_depend d where d.objid = c.oid and d.deptype = 'e') order by 1, 2")
    for line in out.strip("\n").splitlines():
        kind, name, a, b, c, rls = line.split("\t")
        rows.append((kind, name, a, b, c, rls, ""))
    spriv = "array['select','update','usage']"
    scols = ", ".join(f"coalesce((select string_agg(p, ',' order by p) from unnest({spriv}) p where has_sequence_privilege('{r}', c.oid, p)), '-')" for r in ("anon", "authenticated", "service_role"))
    out = psql(url, f"select c.relname, {scols} from pg_class c where c.relnamespace = 'public'::regnamespace and c.relkind = 'S' and not exists (select 1 from pg_depend d where d.objid = c.oid and d.deptype = 'e') order by 1")
    for line in out.strip("\n").splitlines():
        name, a, b, c = line.split("\t")
        rows.append(("sequence", name, a, b, c, "", ""))
    out = psql(url, "select p.oid::regprocedure::text, p.proname, p.prosecdef::text, (p.prorettype = 'trigger'::regtype)::text, has_function_privilege('anon', p.oid, 'execute')::text, has_function_privilege('authenticated', p.oid, 'execute')::text, has_function_privilege('service_role', p.oid, 'execute')::text "
                     "from pg_proc p where p.pronamespace = 'public'::regnamespace and p.prokind in ('f', 'p') and not exists (select 1 from pg_depend d where d.objid = p.oid and d.deptype = 'e') order by 1")
    for line in out.strip("\n").splitlines():
        sig, fn, secdef, trig, an, au, sr = line.split("\t")
        note = FUNCS.get(fn, "trigger function: cannot be called directly" if trig == "true" else "")
        rows.append(("function", sig, "execute" if an == "true" else "-", "execute" if au == "true" else "-", "execute" if sr == "true" else "-", "security_definer" if secdef == "true" else "invoker", note))
    rows.sort()
    hdr = "kind\tname\tanon\tauthenticated\tservice_role\tsecurity\tnote"
    return hdr + "\n" + "\n".join("\t".join(r) for r in rows) + "\n"


def main():
    ap = argparse.ArgumentParser(); ap.add_argument("--url", default=os.environ.get("REPLICA_URL")); ap.add_argument("--write", action="store_true"); ap.add_argument("--check", action="store_true")
    a = ap.parse_args()
    if not a.url:
        sys.exit("REPLICA_URL or --url required (a scratch database after every migration)")
    text = build(a.url)
    rows = [l.split("\t") for l in text.splitlines()[1:]]
    # asserted ONLY for the consent-integrity set (FUNCS, TABLES): the PWA's app_* functions are deliberately callable by `authenticated`, and other rows are reported, not judged here
    bad = [r for r in rows if r[0] == "function" and r[1].split("(")[0] in FUNCS and (r[2] != "-" or r[3] != "-")]
    bad += [r for r in rows if r[1] in TABLES and (r[2] != "-" or r[3] != "-")]
    if bad:
        sys.exit("API roles (anon/authenticated) hold privileges on consent-integrity functions or tables:\n" + "\n".join("\t".join(r) for r in bad))
    if a.write:
        open(OUT, "w").write(text); print("wrote", os.path.relpath(OUT)); return
    if a.check:
        cur = open(OUT).read() if os.path.exists(OUT) else ""
        if cur != text:
            sys.exit("ops/ACL_MANIFEST_public.tsv differs from the replica catalog: run scripts/acl_manifest.py --write and review the diff")
        print("acl manifest matches")
    else:
        print(text, end="")


main()
