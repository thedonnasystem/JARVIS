#!/usr/bin/env python3
"""Drift checker for everything the PWA depends on that is kept in several hand-written places.

The owner app calls database functions by name, and the same list of "functions the signed-in owner (or anon) may call" is kept in:
  1. webapp/app.js and webapp/apply/apply.js  (what the browser actually calls)
  2. migrations/20261112_lockdown_v1.sql       (the keep-open list: the source of truth for what survives the lockdown)
  3. ops/verify_live.sql                       (production verification, 2 copies)
  4. ops/preflight_live.sql                    (pre-flight, 2 copies)
  5. scripts/replica/e2e.sql                   (replica regression)
  6. the grants inside the migrations themselves
It also checks the app's message kinds (app_send kinds the app uses vs the web_messages check constraint vs what hq_web.py handles) and
that the service worker's offline cache lists every shipped asset.  Fails (exit 1) with one line per drift.

  python3 scripts/check_app_rpcs.py            check the repo
"""
import json
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import lint_migrations as L  # noqa: E402

ROOT = os.path.normpath(os.path.join(HERE, ".."))
# {function name: patch that opens it}. The app calls these but the lockdown keep-open list (an applied migration) does not name them yet, so
# they are deliberately closed until the owner signs off the patch. Anything listed here must be called by the app, defined by a migration,
# closed in the lockdown, and its patch must exist. Remove the entry when the patch is applied.
PENDING_SIGNOFF = {"app_needs_you": "ops/pending_signoff/inbox_open_app_needs_you.txt"}
# Files under webapp/ that are intentionally not in the offline shell.
SHELL_EXEMPT = ("sw.js", "vendor/README.txt")
SHELL_EXEMPT_PREFIX = ("apply/",)   # the public setter-signup page: not part of the owner app, must not be cached into it
# Things in a keep-open list that the browser app does not call (the bot, the setter page, or the owner check itself).
NOT_CALLED_BY_APP = {"is_app_owner", "setter_apply"}


def _read(root, rel):
    with open(os.path.join(root, rel)) as f:
        return f.read()


def js_rpc_names(text):
    return set(re.findall(r"""\brpc\(\s*['"]([A-Za-z_][\w]*)['"]""", text)) | set(re.findall(r"/rpc/([A-Za-z_]\w*)", text))


def sql_name_lists(text):
    """Every parenthesised/array list of quoted names that contains app_snapshot (the keep-open list as pasted into ops/ and replica scripts)."""
    out = []
    for m in re.finditer(r"(?:\bin\s*\(|array\s*\[)([^)\]]*)[)\]]", text, re.I):
        names = re.findall(r"'([^']+)'", m.group(1))
        if "app_snapshot" in names:
            out.append(set(names))
    return out


def migration_grants(root):
    """({name: roles granted execute in a migration}, {names created in a migration})."""
    order = L.read_order(root)
    granted, created = {}, set()
    for f in order:
        sql = L.strip_sql(_read(root, os.path.join("migrations", f)))
        created |= {n for n, _a, _o in L.functions_created(sql)}
        for g in L.GRANT.finditer(sql):
            if g.group("fn") and "execute" in g.group("body").lower():
                roles = L._roles(g.group("roles")) & {"anon", "authenticated", "public"}
                for n, _a in L._targets(g.group("fn")):
                    if roles:
                        granted.setdefault(n, set()).update(roles)
    return granted, created


def web_message_kinds(root):
    kinds = None
    for f in L.read_order(root):
        t = _read(root, os.path.join("migrations", f))
        for m in re.finditer(r"web_messages", t):
            w = re.search(r"kind\s+in\s*\(([^)]*)\)", t[m.start():m.start() + 700], re.I)
            if w:
                kinds = set(re.findall(r"'([^']+)'", w.group(1)))
    return kinds


def app_kinds(js):
    ks = set(re.findall(r"\bact\(\s*'(\w+)'", js)) | set(re.findall(r"\bsend\(\s*[^,()]*,\s*'(\w+)'", js))
    m = re.search(r"INBOX_KINDS\s*=\s*\{([^}]*)\}", js)
    if m:
        ks |= set(re.findall(r"(\w+)\s*:", m.group(1)))
    return ks


def hq_web_kinds(py):
    return set(re.findall(r'kind == "(\w+)"', py))


def shell_list(sw):
    m = re.search(r"SHELL\s*=\s*\[([^\]]*)\]", sw)
    return re.findall(r"""['"]([^'"]+)['"]""", m.group(1)) if m else []


def shipped_assets(root):
    out = set()
    for d, _dirs, files in os.walk(os.path.join(root, "webapp")):
        for fn in files:
            rel = os.path.relpath(os.path.join(d, fn), os.path.join(root, "webapp")).replace(os.sep, "/")
            if rel not in SHELL_EXEMPT and not rel.startswith(SHELL_EXEMPT_PREFIX):
                out.add(rel)
    return out


def check(root=ROOT):
    errs = []
    app = _read(root, "webapp/app.js")
    called = js_rpc_names(app)
    apply_called = js_rpc_names(_read(root, "webapp/apply/apply.js")) if os.path.exists(os.path.join(root, "webapp/apply/apply.js")) else set()
    keep = L.keep_open_names(_read(root, "migrations/" + L.LOCKDOWN))
    granted, created = migration_grants(root)

    if not keep:
        errs.append("A0 could not read the keep-open list from the lockdown migration")
    # A1: the app may only call functions the lockdown leaves open (or that are knowingly pending sign-off)
    for n in sorted(called | apply_called):
        if n in PENDING_SIGNOFF:
            continue
        if n not in keep:
            errs.append(f"A1 the app calls {n}() but it is not in the lockdown keep-open list, so production would refuse it")
        if n not in created:
            errs.append(f"A2 the app calls {n}() but no migration in APPLY_ORDER.txt creates it")
    # A3: pending entries must be real and still closed
    for n, patch in PENDING_SIGNOFF.items():
        if n in keep:
            errs.append(f"A3 {n} is in the lockdown keep-open list now: remove it from PENDING_SIGNOFF in this script")
        if n not in called:
            errs.append(f"A3 {n} is marked pending sign-off but the app no longer calls it")
        if n not in created:
            errs.append(f"A3 {n} is marked pending sign-off but no migration creates it")
        if n in granted:
            errs.append(f"A3 {n} is granted to {sorted(granted[n])} by a migration but is not in the keep-open list; the lockdown would revoke it")
        if not os.path.exists(os.path.join(root, patch)):
            errs.append(f"A3 {n}: the sign-off patch {patch} is missing")
    # A4: everything the keep-open list names exists, is granted in a migration, and every migration grant to anon/authenticated is listed
    for n in sorted(keep):
        if n not in created:
            errs.append(f"A4 {n} is in the keep-open list but no migration creates it")
        if n not in granted:
            errs.append(f"A4 {n} is in the keep-open list but no migration grants it to authenticated/anon")
    for n, roles in sorted(granted.items()):
        if n not in keep:
            errs.append(f"A5 a migration grants {n} to {sorted(roles)} but it is not in the keep-open list (the lockdown would revoke it)")
    # A6: keep-open functions the app never calls are fine only if known
    for n in sorted(keep - called - apply_called - NOT_CALLED_BY_APP):
        errs.append(f"A6 {n} is open to signed-in users but nothing in webapp/ calls it: close it or add it to NOT_CALLED_BY_APP with a reason")
    # A7: the pasted copies
    for rel in ("ops/verify_live.sql", "ops/preflight_live.sql", "scripts/replica/e2e.sql"):
        lists = sql_name_lists(_read(root, rel))
        if not lists:
            errs.append(f"A7 {rel}: no keep-open list found (did the file change shape?)")
        for names in lists:
            if names != keep:
                errs.append(f"A7 {rel}: its keep-open list differs from the lockdown: missing {sorted(keep - names)}, extra {sorted(names - keep)}")

    # message kinds
    kinds_app = app_kinds(app)
    kinds_db = web_message_kinds(root)
    py = hq_web_kinds(_read(root, "hq_web.py"))
    if kinds_db is None:
        errs.append("K0 could not read the web_messages kind constraint")
    else:
        for k in sorted(kinds_app - kinds_db):
            errs.append(f"K1 the app sends message kind '{k}' but the web_messages check constraint refuses it")
    for k in sorted(kinds_app - py):
        errs.append(f"K2 the app sends message kind '{k}' but hq_web.handle() has no branch for it, so it would be answered 'I didn't understand'")
    if kinds_db is not None:
        for k in sorted(py - kinds_db):
            errs.append(f"K3 hq_web.handle() handles kind '{k}' but the web_messages constraint can never store it")

    # offline shell
    sw = _read(root, "webapp/sw.js")
    shell = shell_list(sw)
    if not shell:
        errs.append("S0 could not read SHELL from sw.js")
    norm = {("index.html" if s in ("./", ".", "") else s) for s in shell}
    if len(set(shell)) != len(shell):
        errs.append("S1 sw.js SHELL has duplicate entries")
    for s in sorted(norm):
        if not os.path.exists(os.path.join(root, "webapp", s)):
            errs.append(f"S2 sw.js SHELL lists {s} but it does not exist (cache.addAll would fail and the app would never install offline)")
    for a in sorted(shipped_assets(root) - norm):
        errs.append(f"S3 {a} ships in webapp/ but is not in the sw.js SHELL, so it is missing offline")
    html = _read(root, "webapp/index.html")
    for ref in re.findall(r"""(?:href|src)=["']([^"'#?]+)["']""", html):
        if not re.match(r"^(?:[a-z]+:|/)", ref) and ref not in norm and ref.rstrip("/") not in norm:
            errs.append(f"S4 index.html references {ref} but sw.js does not cache it")
    if os.path.exists(os.path.join(root, "webapp/manifest.webmanifest")):
        for ic in json.loads(_read(root, "webapp/manifest.webmanifest")).get("icons", []):
            if ic["src"] not in norm:
                errs.append(f"S5 the manifest icon {ic['src']} is not in the sw.js SHELL")
    return errs


def main():
    errs = check()
    for e in errs:
        print("DRIFT:", e)
    print(f"check_app_rpcs: {len(errs)} problem(s)")
    return 1 if errs else 0


if __name__ == "__main__":
    sys.exit(main())
