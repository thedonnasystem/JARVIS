#!/usr/bin/env python3
"""Post-lockdown ACL manifest: EVERY function, table / view and sequence in schema public, with the effective privilege of anon, authenticated, service_role and backup_reader, read from the REPLICA's catalog after
every migration (lockdown, then the postlock migrations). The file is committed (ops/ACL_MANIFEST_post_lockdown.tsv) and the gate fails on drift, so a grant that appears (a new function that kept the
lockdown's default grant to service_role, a blanket re-grant, a table privilege on a key table) is a visible diff.

FORMAT: one tab-separated row per object, the first seven columns EXACTLY those of scripts/acl_manifest.py / ops/ACL_MANIFEST_consent_v3.tsv (PR #20):
    kind, name, anon, authenticated, service_role, security, note      then one more column:  backup_reader
so the two files merge with `cut -f1-7 | sort -u` (the consent rows are a subset of these rows: same kind/name/privileges) and nothing is duplicated by hand.
The privilege columns are what has_*_privilege answers (PUBLIC and role inheritance included), not what a migration says. Functions: `execute` or `-`. Tables: the privilege list. Sequences: usage,select,update.
The replica is NOT the live database (its seed approximates live functions), so this file proves the migrations, not production: run `--sql` against production read-only and diff the same columns after a release.

    REPLICA_URL=postgresql://postgres:pw@localhost:5432/<scratch> scripts/acl_manifest_post_lockdown.py --write | --check | --sql | (print)
"""
import argparse, os, subprocess, sys

OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "ops", "ACL_MANIFEST_post_lockdown.tsv")
ROLES = ("anon", "authenticated", "service_role", "backup_reader")
READER = ("backup_schema", "backup_export_policy", "backup_snapshot", "backup_snapshot_page", "backup_table_digest", "backup_snapshot_cost", "backup_redaction_meta", "backup_epoch",
          "backup_deny_prepare", "backup_deny_release", "backup_redaction_status", "redaction_denylist_status")

TBL = "array['select','insert','update','delete','truncate','references','trigger']"
def _tp(r, k):
    return f"coalesce((select string_agg(p, ',' order by p) from unnest({TBL}) p where has_table_privilege('{r}', c.oid, p)), '-')"
SQL = f"""
select kind, name, a, b, c_, sec, note, d from (
  select 'function' as kind, p.oid::regprocedure::text as name,
         case when has_function_privilege('anon', p.oid, 'execute') then 'execute' else '-' end as a,
         case when has_function_privilege('authenticated', p.oid, 'execute') then 'execute' else '-' end as b,
         case when has_function_privilege('service_role', p.oid, 'execute') then 'execute' else '-' end as c_,
         case when p.prosecdef then 'security_definer' else 'invoker' end as sec,
         case when p.proname ~ '^(backup_|redaction_)' or p.proname = 'agent_runs_scrub' then
                case when p.proname in ({", ".join("'" + r + "'" for r in READER)}) then 'backup identity: backup_reader only'
                     else 'internal: owner only' end
              when has_function_privilege('anon', p.oid, 'execute') or has_function_privilege('authenticated', p.oid, 'execute') then 'app-open (lockdown keep-open list)'
              else 'bot (service_role)' end as note,
         case when has_function_privilege('backup_reader', p.oid, 'execute') then 'execute' else '-' end as d
    from pg_proc p where p.pronamespace = 'public'::regnamespace and p.prokind in ('f', 'p')
     and not exists (select 1 from pg_depend dp where dp.objid = p.oid and dp.deptype = 'e')
  union all
  select 'table', 'public.' || c.relname,
         {_tp('anon', 'a')}, {_tp('authenticated', 'b')}, {_tp('service_role', 'c')},
         'rls=' || c.relrowsecurity::text, case when c.relname like 'ffm\\_redaction\\_%' then 'internal: owner only' else '' end,
         {_tp('backup_reader', 'd')}
    from pg_class c where c.relnamespace = 'public'::regnamespace and c.relkind in ('r', 'p', 'v', 'm')
     and not exists (select 1 from pg_depend dp where dp.objid = c.oid and dp.deptype = 'e')
  union all
  select 'sequence', 'public.' || c.relname,
         coalesce(nullif(concat_ws(',', case when has_sequence_privilege('anon', c.oid, 'select') then 'select' end, case when has_sequence_privilege('anon', c.oid, 'update') then 'update' end, case when has_sequence_privilege('anon', c.oid, 'usage') then 'usage' end), ''), '-'),
         coalesce(nullif(concat_ws(',', case when has_sequence_privilege('authenticated', c.oid, 'select') then 'select' end, case when has_sequence_privilege('authenticated', c.oid, 'update') then 'update' end, case when has_sequence_privilege('authenticated', c.oid, 'usage') then 'usage' end), ''), '-'),
         coalesce(nullif(concat_ws(',', case when has_sequence_privilege('service_role', c.oid, 'select') then 'select' end, case when has_sequence_privilege('service_role', c.oid, 'update') then 'update' end, case when has_sequence_privilege('service_role', c.oid, 'usage') then 'usage' end), ''), '-'),
         '', case when c.relname like 'ffm\\_redaction\\_%' then 'internal: owner only' else '' end,
         coalesce(nullif(concat_ws(',', case when has_sequence_privilege('backup_reader', c.oid, 'select') then 'select' end, case when has_sequence_privilege('backup_reader', c.oid, 'update') then 'update' end, case when has_sequence_privilege('backup_reader', c.oid, 'usage') then 'usage' end), ''), '-')
    from pg_class c where c.relnamespace = 'public'::regnamespace and c.relkind = 'S'
     and not exists (select 1 from pg_depend dp where dp.objid = c.oid and dp.deptype = 'e')
) q(kind, name, a, b, c_, sec, note, d) order by kind, name collate "C"
"""


def build(url):
    r = subprocess.run(["psql", url, "-X", "-At", "-F", "\t", "-v", "ON_ERROR_STOP=1", "-c", SQL], capture_output=True, text=True, timeout=300)
    if r.returncode:
        sys.exit("psql failed: " + r.stderr.strip()[:400])
    hdr = "kind\tname\tanon\tauthenticated\tservice_role\tsecurity\tnote\tbackup_reader"
    return hdr + "\n" + r.stdout


def violations(text):
    """Hard rules, independent of the committed file: the catalogue must hold in the generated manifest itself."""
    bad = []
    for line in text.splitlines()[1:]:
        k, name, an, au, sr, sec, note, br = line.split("\t")
        if note.startswith(("internal", "backup identity")):
            if (an, au, sr) != ("-", "-", "-"):
                bad.append(f"{k} {name}: an API role holds a privilege on a backup/internal object ({an}/{au}/{sr})")
        if note.startswith("internal") and br != "-":
            bad.append(f"{k} {name}: backup_reader holds a privilege on an owner-only object")
        if note.startswith("backup identity") and br != "execute":
            bad.append(f"{k} {name}: backup_reader cannot execute a reader function")
        if k in ("table", "sequence") and br != "-":
            bad.append(f"{k} {name}: backup_reader holds a table/sequence privilege (it needs none)")
    return bad


def main():
    ap = argparse.ArgumentParser(); ap.add_argument("--url", default=os.environ.get("REPLICA_URL")); ap.add_argument("--write", action="store_true"); ap.add_argument("--check", action="store_true"); ap.add_argument("--sql", action="store_true")
    a = ap.parse_args()
    if a.sql:
        print(SQL); return
    if not a.url:
        sys.exit("REPLICA_URL or --url required (a scratch database after every migration, lockdown and postlock included)")
    text = build(a.url)
    bad = violations(text)
    if bad:
        sys.exit("ACL catalogue violated:\n" + "\n".join(bad))
    if a.write:
        open(OUT, "w").write(text); print("wrote", os.path.relpath(OUT), f"({len(text.splitlines()) - 1} rows)"); return
    if a.check:
        cur = open(OUT).read() if os.path.exists(OUT) else ""
        if cur != text:
            import difflib
            d = list(difflib.unified_diff(cur.splitlines(), text.splitlines(), "committed", "replica", lineterm="", n=0))
            sys.exit("ops/ACL_MANIFEST_post_lockdown.tsv differs from the replica catalog (%d lines):\n%s\nfix: scripts/acl_manifest_post_lockdown.py --write, then REVIEW every changed row" % (len(d), "\n".join(d[:40])))
        print("acl manifest matches (%d rows)" % (len(text.splitlines()) - 1))
    else:
        print(text, end="")


main()
