#!/usr/bin/env python3
"""Migration linter (see MIGRATIONS.md). Pure stdlib. Exit 0 = clean, 1 = findings.

Rules
  R1 order   every migrations/*.sql is listed in APPLY_ORDER.txt exactly once, and every listed name exists
             (files in NOT_IN_ORDER are the documented "already live" exceptions)
  R2 name    NEW files match YYYYMMDD_<stream>_<topic>_vN.sql (existing files are grandfathered, explicit list below)
  R3 last    the lockdown migration is the last entry in APPLY_ORDER.txt
  R4 revoke  every `create [or replace] function` in a NEW migration (or one ordered after lockdown) is followed, in the
             same file, by `revoke ... on function <it> ... from public, anon, authenticated`
             (or one `revoke ... on all functions in schema public ...`). Functions the lockdown deliberately leaves
             open to the app (KEEP_OPEN, parsed from the lockdown file) may instead be granted explicitly.
  R5 grant   a NEW migration may not grant execute to public/anon/authenticated on anything outside KEEP_OPEN
  R6 applied no migration that exists on the base ref (default origin/overnight-build) may be modified, renamed or
             deleted, unless it is listed in MODIFIED_ALLOWLIST with a reason. Skipped with a notice if the base ref is
             unreachable (CI must fetch full history).
"""
import argparse
import os
import re
import subprocess
import sys

ROOT = os.path.normpath(os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))
LOCKDOWN = "20261112_lockdown_v1.sql"
NAME_RE = re.compile(r"^\d{8}_[a-z0-9]+(?:_[a-z0-9]+)+_v\d+\.sql$")

# Existing files, named before this convention. Never add to this list: new files must follow the convention.
GRANDFATHERED = frozenset("""
20261112_accounts_v1.sql 20261112_agents_v1.sql 20261112_allocation_v1.sql 20261112_assets_procedures_v1.sql
20261112_autonomy_v1.sql 20261112_bank_v1.sql 20261112_brief_missions.sql 20261112_brief_v3.sql 20261112_capital_v1.sql
20261112_chat_meter.sql 20261112_finance_rules_v1.sql 20261112_holding_v1.sql 20261112_learning_v1.sql
20261112_lockdown_v1.sql 20261112_missions_v1.sql 20261112_office_v1.sql 20261112_opportunity_v1.sql 20261112_org_v1.sql
20261112_payments_v1.sql 20261112_permissions_v1.sql 20261112_push_v1.sql 20261112_setter_apply_v1.sql
20261112_setters_v1.sql 20261112_venture_view_v1.sql 20261112_ventures_v1.sql 20261112_webapp_v1.sql
20261113_mission_guard_v1.sql 20261113_phase1_repair_v1.sql
""".split())
# Files that exist in migrations/ on purpose but are not in APPLY_ORDER.txt (header of APPLY_ORDER: "Already live").
NOT_IN_ORDER = frozenset({"20261112_missions_v1.sql", "20261112_brief_missions.sql"})
# {filename: reason}. An applied migration may only be edited with a reason recorded here (and owner sign-off).
MODIFIED_ALLOWLIST = {}


def strip_sql(text):
    """Blank out comments, dollar-quoted bodies and string literals (keeping offsets and newlines)."""
    out, i, n = [], 0, len(text)
    blank = lambda s: re.sub(r"[^\n]", " ", s)
    dollar = re.compile(r"\$[A-Za-z_]*\$")
    while i < n:
        c = text[i]
        if text.startswith("--", i):
            j = text.find("\n", i)
            j = n if j < 0 else j
            out.append(blank(text[i:j])); i = j
        elif text.startswith("/*", i):
            j = text.find("*/", i + 2)
            j = n if j < 0 else j + 2
            out.append(blank(text[i:j])); i = j
        elif c == "'":
            j = i + 1
            while j < n:
                if text[j] == "'" and text[j + 1:j + 2] == "'":
                    j += 2; continue
                if text[j] == "'":
                    break
                j += 1
            j = min(j + 1, n)
            out.append("'" + blank(text[i + 1:j - 1]) + "'" if j - i >= 2 else blank(text[i:j])); i = j
        elif c == "$" and dollar.match(text, i):
            tag = dollar.match(text, i).group(0)
            j = text.find(tag, i + len(tag))
            j = n if j < 0 else j + len(tag)
            out.append(blank(text[i:j])); i = j
        else:
            out.append(c); i += 1
    return "".join(out)


def split_args(s):
    parts, depth, cur = [], 0, []
    for ch in s:
        if ch == "(":
            depth += 1
        elif ch == ")":
            depth -= 1
        if ch == "," and depth == 0:
            parts.append("".join(cur)); cur = []
        else:
            cur.append(ch)
    parts.append("".join(cur))
    return [p for p in parts if p.strip()]


def _balanced(text, start):
    """text[start] == '('; returns the index just after the matching ')'."""
    depth = 0
    for k in range(start, len(text)):
        if text[k] == "(":
            depth += 1
        elif text[k] == ")":
            depth -= 1
            if depth == 0:
                return k + 1
    return len(text)


def _name(raw):
    return raw.strip().split(".")[-1].strip('"').lower()


CREATE_FN = re.compile(r"\bcreate\s+(?:or\s+replace\s+)?function\s+((?:\"?\w+\"?\.)?\"?\w+\"?)\s*\(", re.I)
REVOKE = re.compile(r"\brevoke\b(?P<body>[^;]*?)\bon\s+(?:(?P<all>all\s+functions\s+in\s+schema\s+\w+)|function\s+(?P<fn>[^;]*?))\s+from\s+(?P<roles>[^;]*);", re.I | re.S)
GRANT = re.compile(r"\bgrant\b(?P<body>[^;]*?)\bon\s+(?:(?P<all>all\s+functions\s+in\s+schema\s+\w+)|function\s+(?P<fn>[^;]*?))\s+to\s+(?P<roles>[^;]*);", re.I | re.S)
OPEN_ROLES = ("public", "anon", "authenticated")


def functions_created(sql):
    """[(name, argcount, offset)] for each create function in already-stripped sql. OUT params are not counted."""
    res = []
    for m in CREATE_FN.finditer(sql):
        end = _balanced(sql, m.end() - 1)
        args = split_args(sql[m.end():end - 1])
        res.append((_name(m.group(1)), sum(1 for a in args if not re.match(r"\s*out\b", a, re.I)), m.start()))
    return res


def _targets(fn_text):
    """Parse the `a(int, text), b()` list of a revoke/grant -> [(name, argcount or None)]."""
    out, i, s = [], 0, fn_text.strip()
    pat = re.compile(r"\s*,?\s*((?:\"?\w+\"?\.)?\"?\w+\"?)\s*")
    while i < len(s):
        m = pat.match(s, i)
        if not m or m.end() == i:
            break
        name, j = _name(m.group(1)), m.end()
        if s[j:j + 1] == "(":
            e = _balanced(s, j)
            out.append((name, len(split_args(s[j + 1:e - 1]))))
            i = e
        else:
            out.append((name, None)); i = j
    return out


def _roles(text):
    return {r.strip().strip('"').lower() for r in text.split(",") if r.strip()}


def keep_open_names(lockdown_text):
    m = re.search(r"proname\s+not\s+in\s*\(([^)]*)\)", lockdown_text, re.I)
    return set(re.findall(r"'([^']+)'", m.group(1))) if m else set()


def check_revokes(filename, text, keep_open):
    """R4/R5 for one file. Returns a list of error strings."""
    sql = strip_sql(text)
    errs = []
    revokes = []  # (offset, name|None, argc|None, is_all)
    for m in REVOKE.finditer(sql):
        if not set(OPEN_ROLES) <= _roles(m.group("roles")):
            continue
        if m.group("all"):
            revokes.append((m.start(), None, None, True))
        else:
            revokes += [(m.start(), n, a, False) for n, a in _targets(m.group("fn"))]
    grants = []  # (offset, name, argc|None) execute grants to authenticated on a named function
    for g in GRANT.finditer(sql):
        if g.group("fn") and "authenticated" in _roles(g.group("roles")):
            grants += [(g.start(), n, a) for n, a in _targets(g.group("fn"))]
    for name, argc, off in functions_created(sql):
        ok = any(o > off and (is_all or (n == name and (a is None or a == argc))) for o, n, a, is_all in revokes)
        if not ok and name in keep_open:
            ok = any(o > off and n == name and (a is None or a == argc) for o, n, a in grants)
        if not ok:
            errs.append(f"R4 {filename}: function {name}({argc} args) has no following `revoke ... on function {name}(...) from public, anon, authenticated` in the same file")
    for g in GRANT.finditer(sql):
        if not set(OPEN_ROLES) & _roles(g.group("roles")):
            continue
        if "execute" not in g.group("body").lower() and not re.search(r"\ball\b", g.group("body"), re.I):
            continue
        if g.group("all"):
            errs.append(f"R5 {filename}: grants execute on ALL functions to public/anon/authenticated")
            continue
        for n, _ in _targets(g.group("fn")):
            if n not in keep_open:
                errs.append(f"R5 {filename}: grants execute on {n} to public/anon/authenticated, but it is not in the lockdown keep-open list")
    return errs


def read_order(root):
    with open(os.path.join(root, "migrations", "APPLY_ORDER.txt")) as f:
        return [l.strip() for l in f if l.strip() and not l.lstrip().startswith("#")]


def git(root, *args):
    return subprocess.run(["git", "-C", root, *args], capture_output=True, text=True)


def applied_changes(root, base):
    """(changes, note). changes = [(status, filename)] for migrations/*.sql that exist on base and were altered."""
    if git(root, "rev-parse", "--verify", "-q", base + "^{commit}").returncode != 0:
        return None, f"base ref {base} not reachable; R6 skipped (git fetch origin; CI needs fetch-depth: 0)"
    mb = git(root, "merge-base", base, "HEAD")
    ref = mb.stdout.strip() if mb.returncode == 0 and mb.stdout.strip() else base
    d = git(root, "diff", "--name-status", "-M", ref, "--", "migrations/")
    ch = []
    for line in d.stdout.splitlines():
        p = line.split("\t")
        if p[0][0] in "MDR" and p[1].endswith(".sql"):
            ch.append((p[0][0], os.path.basename(p[1])))
    return ch, ""


def lint(root=ROOT, base="origin/overnight-build", grandfathered=GRANDFATHERED, not_in_order=NOT_IN_ORDER,
         allowlist=None, check_git=True):
    allowlist = MODIFIED_ALLOWLIST if allowlist is None else allowlist
    errs, notes = [], []
    mdir = os.path.join(root, "migrations")
    files = sorted(f for f in os.listdir(mdir) if f.endswith(".sql"))
    order = read_order(root)
    seen = set()
    for o in order:  # R1
        if o in seen:
            errs.append(f"R1 {o} is listed in APPLY_ORDER.txt more than once")
        seen.add(o)
        if o not in files:
            errs.append(f"R1 {o} is in APPLY_ORDER.txt but migrations/{o} does not exist")
    for f in files:
        if f not in seen and f not in not_in_order:
            errs.append(f"R1 migrations/{f} is not listed in APPLY_ORDER.txt")
    for f in sorted(not_in_order):
        if f in seen:
            errs.append(f"R1 {f} is a documented not-in-order exception but is listed in APPLY_ORDER.txt")
    for f in files:  # R2
        if f not in grandfathered and not NAME_RE.match(f):
            errs.append(f"R2 {f}: new migration names must match YYYYMMDD_<stream>_<topic>_vN.sql (lowercase, e.g. 20261114_infra_gate_v1.sql)")
    if LOCKDOWN not in order:  # R3
        errs.append(f"R3 {LOCKDOWN} is missing from APPLY_ORDER.txt")
    elif order[-1] != LOCKDOWN:
        errs.append(f"R3 {LOCKDOWN} must be the last entry in APPLY_ORDER.txt (last is {order[-1]}); insert new migrations BEFORE it")
    keep_open = set()
    lp = os.path.join(mdir, LOCKDOWN)
    if os.path.exists(lp):
        with open(lp) as fh:
            keep_open = keep_open_names(fh.read())
    after = set(order[order.index(LOCKDOWN) + 1:]) if LOCKDOWN in order else set()
    for f in files:  # R4/R5
        if f in grandfathered and f not in after:
            continue
        with open(os.path.join(mdir, f)) as fh:
            errs += check_revokes(f, fh.read(), keep_open)
    if check_git:  # R6
        ch, note = applied_changes(root, base)
        if note:
            notes.append(note)
        for st, f in ch or []:
            if f not in allowlist:
                what = {"M": "modified", "D": "deleted", "R": "renamed"}[st]
                errs.append(f"R6 migrations/{f} exists on {base} (applied or queued) and was {what}; add a NEW migration instead")
    return errs, notes


def main(argv=None):
    ap = argparse.ArgumentParser(description="Lint migrations/ (rules R1-R6, see module docstring and MIGRATIONS.md)")
    ap.add_argument("--base", default=os.environ.get("LINT_BASE", "origin/overnight-build"))
    ap.add_argument("--root", default=ROOT)
    ap.add_argument("--no-git", action="store_true", help="skip R6")
    a = ap.parse_args(argv)
    errs, notes = lint(a.root, a.base, check_git=not a.no_git)
    for n in notes:
        print("NOTE:", n)
    for e in errs:
        print("ERROR:", e)
    print(f"lint_migrations: {len(errs)} error(s)")
    return 1 if errs else 0


if __name__ == "__main__":
    sys.exit(main())
