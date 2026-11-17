#!/usr/bin/env python3
"""Never-edit enforcement (ops/PROTECTED_PATHS.json). Pure stdlib.

Fails when a change between BASE and HEAD
  - adds, modifies, deletes, renames or copies a protected path (rename / copy detection: the OLD path counts too, and a copy OF a protected file counts),
  - adds or changes a symlink that points into a protected path, out of the repository, or at an absolute path; adds a submodule,
  - adds a module that can shadow or monkey-patch a protected one: any NEW top-level .py file, any path whose first segment is named like a protected module,
    any __init__.py / sitecustomize / usercustomize / .pth / conftest.py, or a line that assigns into another module (hq_x.attr = ..., setattr(hq_x, ...), sys.modules[...]),
  - adds a deploy config (Dockerfile, railway.toml / .json, nixpacks.toml, Procfile, runtime.txt, ...) or a .gitattributes / .gitmodules,
  - adds a file the checker cannot scan (an extension outside code_extensions + data_extensions, or no extension),
  - in any other code file, adds a line (or a short run of lines, with string pieces joined) that writes a protected SQL object (name + a write verb, rpc included),
    a grant / revoke / RLS / role statement (.sql / .sh files), a destructive data statement (DROP / TRUNCATE / DELETE ...), dynamic SQL (EXECUTE ...,
    U&"..." identifiers), so split or concatenated statements count too,
UNLESS the pull request carries a valid owner approval marker for the exact head commit:
  (a) an APPROVED review by owner_login whose commit_id is the head SHA, or
  (b) the label  owner-ok-<the full 40-character head SHA>  whose latest 'labeled' event is by owner_login, still on the PR.
  owner_login must be an identity NO agent can use: when it is one of agent_logins or the PR author, nothing counts (fail closed).
A new push changes the head SHA, so every approval is void after any later commit.
Self-edit PRs (head OR base branch starting with a self_edit.zone_branch_prefixes entry, e.g. jarvis/auto-* and the jarvis/integration release PR, or
authored by a jarvis_logins account) in allowlist mode (ops/SELF_EDIT_MODE) also fail for ANY path outside self_edit.auto_ship_zone.
LIMIT (stated plainly): the line rules are a TRIPWIRE. No pattern list can enumerate every way code in the same process can change another module;
that is why every top-level runtime module is a locked path, and why the control is the independent review plus the owner's approval of the exact commit.

  python3 scripts/check_protected_paths.py --base origin/overnight-build          local: list findings, exit 1 if any
  python3 scripts/check_protected_paths.py --ci [--repo DIR]                     CI: findings without approval fail (pull requests AND pushes to protected branches)
  python3 scripts/check_protected_paths.py --paths a.py b.py [--selfedit]         path-only check of a file list (Jarvis's self-edit pipeline)

TRUST: in CI this file and its config come from the BASE branch (workflow protected-paths.yml runs on pull_request_target and never executes PR code; the
unit job checks the base out separately). The PR's own copy is never the judge, except for the one bootstrap PR that introduces it (stated in the log).
CI environment: GITHUB_EVENT_NAME, GITHUB_REPOSITORY, GITHUB_TOKEN (read-only), PR_NUMBER, HEAD_SHA, BASE_REF (the PR's base branch, fetched fresh as
origin/<BASE_REF>: the diff is against the CURRENT base, not the stale event base SHA), HEAD_REF, PUSH_REF, PUSH_BEFORE.
"""
import argparse
import json
import os
import posixpath
import re
import subprocess
import sys
import urllib.request

ROOT = os.path.normpath(os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))
CONFIG = os.path.join(ROOT, "ops", "PROTECTED_PATHS.json")
WRITE_VERB = re.compile(r"\b(create|alter|drop|replace|update|insert|delete|truncate|grant|revoke|comment\s+on|patch|upsert|rename|rpc|execute|merge|copy|call)\b", re.I)
MONKEY = [re.compile(r"(?<![\w.])(hq\w*|bot|check_protected_paths|builtins|importlib)\s*\.\s*[A-Za-z_]\w*(\s*\.\s*\w+)*\s*(\[[^\]]*\]\s*)?(?<![=!<>])=(?!=)"),
          re.compile(r"\bsetattr\s*\(\s*(hq\w*|bot|sys|builtins|importlib|check_protected_paths)\b"),
          re.compile(r"\bsys\s*\.\s*(modules|meta_path|path_hooks|path_importer_cache)\b"),
          re.compile(r"\bsys\s*\.\s*path\s*\.\s*(insert|append|extend)\b|\bsys\s*\.\s*path\s*(\[[^\]]*\])?\s*\+?="),
          re.compile(r"\b__import__\s*\(|\bimportlib\s*\.\s*(import_module|reload|util)\b|\bexec\s*\(|\beval\s*\("),
          # RVJC2 B3 variants (a tripwire, not a proof: see the owner guide): aliases of our modules, namespace dicts, mock.patch, code objects,
          # builtins reached by name, import_module under any name, compile + FunctionType, a second interpreter
          re.compile(r"\bimport\s+(hq\w*|bot|builtins|importlib)\s+as\b|\bfrom\s+(hq\w*|bot)\s+import\b[^#\n]*\bas\b|\bfrom\s+importlib\b"),
          re.compile(r"\b__dict__\b|\bvars\s*\(|\b__code__\b|\b__globals__\b|\b__builtins__\b|\b__closure__\b|\b__defaults__\b|\b__kwdefaults__\b"),
          re.compile(r"\bmock\s*\.\s*patch\b|\bpatch\s*(\.\s*object\s*)?\(\s*['\"](hq|bot)|\bmonkeypatch\b|\bimport_module\b|\bFunctionType\b|\bCodeType\b"),
          re.compile(r"(?<![\w.])compile\s*\(|\bbuiltins\s*\.\s*compile\b|\bgetattr\s*\(\s*(builtins|__builtins__|sys|importlib|hq\w*)\b|\bsetattr\s*\(|\bdelattr\s*\(|\bglobals\s*\(\s*\)"),
          re.compile(r"\b(subprocess|os\s*\.\s*(system|popen|exec\w*|spawn\w*)|pty\s*\.\s*spawn|runpy)\b|['\"]python3?['\"]|sys\s*\.\s*executable")]
COMMENT_SQL = re.compile(r"/\*.*?\*/", re.S)
DYNAMIC_SQL = [re.compile(r"\bexecute\s+(format\s*\(|'|\$|E'|[A-Za-z_][\w.]*\s*(\|\||;|using\b|$))", re.I),
               re.compile(r"\bU&\s*['\"]", re.I),
               re.compile(r"\.execute\s*\(\s*(f['\"]|[^)]*(\+|%\s*\(|\.format\s*\())")]
UNSAFE_PATH = re.compile(r"[#?%\\\x00-\x1f\x7f]|(^|/)\.\.?(/|$)|^/|//|\s$|^\s")


def _glob_rx(pat):
    """'**/' any directories (or none), '**' anything, '*' / '?' within one segment. Case-insensitive, whole path."""
    out, i = "", 0
    while i < len(pat):
        if pat.startswith("**/", i):
            out += "(?:.*/)?"; i += 3
        elif pat.startswith("**", i):
            out += ".*"; i += 2
        elif pat[i] == "*":
            out += "[^/]*"; i += 1
        elif pat[i] == "?":
            out += "[^/]"; i += 1
        else:
            out += re.escape(pat[i]); i += 1
    return re.compile(out + r"\Z", re.I | re.S)


def load(path=CONFIG):
    with open(path, encoding="utf-8") as f:
        cfg = json.load(f)
    paths, sql, prefixes, patterns = [], [], [], []
    for name, c in cfg["categories"].items():
        paths += [(p, name, _glob_rx(p) if any(ch in p for ch in "*?") else None) for p in c.get("paths", [])]
        sql += [(s, name) for s in c.get("sql", [])]
        prefixes += [(s, name) for s in c.get("sql_prefixes", [])]
        patterns += [(re.compile(p, re.I), name) for p in c.get("sql_patterns", [])]
    cfg["_paths"], cfg["_sql"], cfg["_prefixes"], cfg["_patterns"] = paths, sql, prefixes, patterns
    cfg["_destructive"] = [re.compile(p, re.I) for p in cfg.get("destructive_patterns", [])]
    wp = cfg.get("write_patterns") or {}
    cfg["_agents_status"] = [re.compile(p, re.I) for p in wp.get("agents_status", [])]
    cfg["_rest_dynamic"] = [re.compile(p) for p in wp.get("rest_dynamic", [])]
    cfg["_zone_prefixes"] = tuple((cfg.get("self_edit") or {}).get("zone_branch_prefixes") or [])
    cfg["_stems"] = sorted({p[:-3].casefold() for p, _, rx in paths if rx is None and "/" not in p and p.lower().endswith(".py")})
    cfg["_zone"] = [_glob_rx(z) for z in (cfg.get("self_edit") or {}).get("auto_ship_zone", [])]
    cfg["_root"] = os.path.normpath(os.path.join(os.path.dirname(os.path.abspath(path)), ".."))
    return cfg


def self_edit_mode(cfg):
    """'allowlist' or 'denylist' from the protected mode file next to the config. Missing / unreadable / unknown = allowlist (the safer mode)."""
    se = cfg.get("self_edit") or {}
    try:
        with open(os.path.join(cfg.get("_root", ROOT), se.get("mode_file", "ops/SELF_EDIT_MODE")), encoding="utf-8") as f:
            m = f.read().strip().lower()
    except OSError:
        m = ""
    return m if m in ("allowlist", "denylist") else "allowlist"


def norm(p):
    p = posixpath.normpath((p or "").replace("\\", "/")).lstrip("/")
    return "" if p == "." else p


def path_category(cfg, path):
    """The category protecting this path, or None. Case-insensitive (a case-only rename on a case-insensitive checkout is the same file)."""
    p = norm(path)
    if not p or p.startswith("../"):
        return None
    pc = p.casefold()
    for prot, cat, rx in cfg["_paths"]:
        if rx is not None:
            if rx.match(p):
                return cat
            continue
        q = prot.casefold()
        if (q.endswith("/") and (pc.startswith(q) or pc + "/" == q)) or pc == q:
            return cat
    return None


def in_zone(cfg, path):
    p = norm(path)
    return bool(p) and any(rx.match(p) for rx in cfg["_zone"])


def ext_problem(cfg, path):
    """A file type the line scan cannot judge: anything outside code_extensions + data_extensions (incl. no extension)."""
    base = posixpath.basename(norm(path)).lower()
    if base in {n.lower() for n in cfg.get("data_names", [])}:
        return None
    ext = os.path.splitext(base)[1]
    if ext and ext in tuple(cfg.get("code_extensions", [])) + tuple(cfg.get("data_extensions", [])):
        return None
    return f"file type the checker cannot scan ({ext or 'no extension'})"


def shadow_problem(cfg, path, added):
    """New modules that could replace or patch a protected one. Every top-level module of the base or head tree counts as protected (B3)."""
    p = norm(path)
    first = p.split("/", 1)[0].casefold()
    stem = first[:-3] if first.endswith(".py") else first.split(".", 1)[0]
    stems = set(cfg["_stems"]) | set(cfg.get("_tree_stems") or ())
    if "/" in p and (first in stems or stem in stems):
        return f"path named like protected module {first}"
    if "/" not in p and stem in stems and not p.casefold().endswith(".py"):
        return f"file named like protected module {stem} (could be imported instead of it)"
    if added and "/" not in p and p.lower().endswith(".py"):
        return "new top-level module (Python imports it from the repo root: it could shadow or monkey-patch a protected module)"
    return None


def resolve_link(link_path, target):
    """Repository-relative path a symlink points to; None when it escapes the repository or is absolute."""
    if not target or target.startswith("/") or re.match(r"^[A-Za-z]:", target):
        return None
    r = posixpath.normpath(posixpath.join(posixpath.dirname(norm(link_path)), target))
    return None if r == ".." or r.startswith("../") else norm(r)


STRING_JOIN = re.compile(r"""["']\s*(?:\+|\|\|)?\s*["']""")


def joined(text):
    """String pieces glued back together ('system_' + 'state', 'trun' || 'cate', "del" "ete") so the statement reads as it will run."""
    return STRING_JOIN.sub("", text)


SQL_EXTS = (".sql", ".psql", ".pgsql")


def uncomment(path, text):
    """Text with SQL comments removed: /* ... */ anywhere, and (SQL files) '--' to the end of the line when it is outside a '...' string."""
    t = COMMENT_SQL.sub(" ", text)
    if os.path.splitext(path)[1].lower() in SQL_EXTS:
        out, q, i = [], False, 0
        while i < len(t):
            ch = t[i]
            if ch == "'":
                q = not q
            elif not q and t.startswith("--", i):
                j = t.find("\n", i)
                i = len(t) if j < 0 else j
                out.append(" ")
                continue
            out.append(ch); i += 1
        t = "".join(out)
    return t


def line_findings(cfg, path, line):
    """Findings for one ADDED line of a non-protected file. Judged twice, as written and with SQL comments removed (delete/**/from reads as
    delete from), so a comment can neither hide a statement nor be used to hide one inside a string."""
    clean = uncomment(path, line)
    if clean == line:
        return _line_findings(cfg, path, line)
    seen, out = set(), []
    for f in _line_findings(cfg, path, line) + _line_findings(cfg, path, clean):
        if f not in seen:
            seen.add(f); out.append(f)
    return out


def _line_findings(cfg, path, line):
    ext = os.path.splitext(path)[1].lower()
    raw = line
    out, low = [], line.lower()
    for rx in cfg.get("_agents_status") or []:
        if rx.search(line) and (WRITE_VERB.search(line) or re.search(r"\b(POST|PUT|PATCH)\b|\bset\b", line, re.I)):
            out.append(("jarvis_permissions", "writes agents.status (a dormancy control: the paused agents stay paused without the owner)"))
            break
    for rx in cfg.get("_rest_dynamic") or []:
        if rx.search(raw) or rx.search(line):
            out.append(("jarvis_permissions", "REST / table access with a table name built at run time (treated as protected: the object cannot be read from the diff)"))
            break
    for rx in cfg["_destructive"]:
        if rx.search(line):
            out.append(("destructive", f"destructive data statement ({rx.pattern})"))
            break
    if WRITE_VERB.search(line):
        for name, cat in cfg["_sql"]:
            if re.search(r"(?<![A-Za-z0-9_])" + re.escape(name.lower()) + r"(?![A-Za-z0-9_])", low):
                out.append((cat, f"writes protected SQL object {name}"))
                break
        for pre, cat in cfg["_prefixes"]:
            if re.search(r"(?<![A-Za-z0-9_])(public\.)?" + re.escape(pre.lower()) + r"[a-z0-9_]*", low):
                out.append((cat, f"writes a protected SQL object ({pre}*)"))
                break
    if ext in (".sql", ".sh", ".psql", ".pgsql", ".bash"):
        for rx, cat in cfg["_patterns"]:
            if rx.search(line):
                out.append((cat, f"permission statement ({rx.pattern})"))
                break
    for rx in DYNAMIC_SQL:
        if rx.search(line) and (ext != ".py" or rx is not DYNAMIC_SQL[0]):
            out.append(("database", "dynamic SQL (treated as protected: the objects it touches cannot be read from the diff)"))
            break
    if ext == ".py":
        for rx in MONKEY:
            if rx.search(line):
                out.append(("jarvis_permissions", "patches or loads modules at run time (could replace a protected function)"))
                break
    return out


def window_findings(cfg, path, lines, width=4):
    """Statements split over lines or built from string pieces: join each run of `width` added lines (and the string pieces in it) and look again.
    The run is also judged with its SQL comments removed."""
    out = []
    for i in range(len(lines)):
        chunk = lines[i:i + width]
        for text in {joined(" ".join(chunk)), joined(uncomment(path, "\n".join(chunk)).replace("\n", " ")), joined(chunk[0])}:
            for c, why in line_findings(cfg, path, text):
                out.append((c, why + " (assembled across lines / string pieces)"))
    return out


def git(*args, root=ROOT):
    return subprocess.run(["git", *args], cwd=root, check=True, capture_output=True).stdout


def changes(base, head, root=ROOT):
    """[(status, old_path, new_path, old_mode, new_mode, new_blob)] with rename + copy detection."""
    raw = git("diff", "--raw", "-z", "-M50%", "-C50%", "--find-copies-harder", "--no-abbrev", "--no-ext-diff", "--no-textconv", f"{base}...{head}", root=root).decode("utf-8", "surrogateescape")
    parts, out, i = raw.split("\0"), [], 0
    while i < len(parts) and parts[i]:
        meta = parts[i].lstrip(":").split()
        old_mode, new_mode, _old_blob, new_blob, status = meta[0], meta[1], meta[2], meta[3], meta[4]
        if status[0] in "RC":
            out.append((status[0], parts[i + 1], parts[i + 2], old_mode, new_mode, new_blob)); i += 3
        else:
            out.append((status[0], parts[i + 1], parts[i + 1], old_mode, new_mode, new_blob)); i += 2
    return out


def parse_added(diff_text):
    """Added lines of a unified diff. Header lines are only those BEFORE the first hunk of each file, so a content line '++x' (shown as '+++x') counts."""
    out, in_hunk = [], False
    for l in diff_text.split("\n"):
        if l.startswith("diff --git "):
            in_hunk = False
            continue
        if l.startswith("@@"):
            in_hunk = True
            continue
        if in_hunk and l.startswith("+"):
            out.append(l[1:])
    return out


def added_lines(base, head, path, root=ROOT):
    """--text: a .gitattributes '-diff' / binary attribute cannot hide lines; --no-textconv / --no-ext-diff: no driver rewrites them."""
    try:
        d = git("-c", "core.attributesFile=/dev/null", "diff", "-U0", "--no-color", "--no-ext-diff", "--no-textconv", "--text", f"{base}...{head}", "--", path, root=root)
    except subprocess.CalledProcessError:
        return None
    return parse_added(d.decode("utf-8", "replace"))


def scan(cfg, base, head, root=ROOT, zone_only=False):
    """All findings: [(category, path, reason)]. zone_only: also report every path outside the auto-ship zone (self-edit PRs in allowlist mode)."""
    found = []
    exts = tuple(cfg.get("code_extensions", []))
    cfg["_tree_stems"] = tree_stems(base, head, root)
    for status, old, new, old_mode, new_mode, blob in changes(base, head, root):
        label = {"D": "deleted", "A": "added", "M": "modified", "T": "type changed", "R": "renamed", "C": "copied"}.get(status, status)
        if status in "RC" and path_category(cfg, old):
            found.append((path_category(cfg, old), new, ("rename" if status == "R" else "copy") + f" of protected file {old}"))
        cat = path_category(cfg, new)
        if cat:
            found.append((cat, new, label))
        if zone_only and not in_zone(cfg, new):
            found.append(("self_edit_zone", new, f"{label} outside the auto-ship zone (allowlist mode: owner approval needed)"))
        if zone_only and status in "RC" and not in_zone(cfg, old):
            found.append(("self_edit_zone", old, "renamed / copied from outside the auto-ship zone"))
        if status == "D":
            continue
        if new_mode == "120000":
            target = git("cat-file", "-p", blob, root=root).decode("utf-8", "replace").strip()
            r = resolve_link(new, target)
            if r is None:
                found.append(("jarvis_permissions", new, f"symlink to {target!r} leaves the repository"))
            elif path_category(cfg, r):
                found.append((path_category(cfg, r), new, f"symlink into protected path {r}"))
            elif r == "" or _is_tree(head, r, root):
                found.append(("jarvis_permissions", new, f"symlink to the directory {r or '.'!r} (could expose locked modules under a new import name)"))
            continue
        if new_mode == "160000":
            found.append(("jarvis_permissions", new, "submodule added or changed"))
            continue
        sh = shadow_problem(cfg, new, status in "ARC")
        if sh:
            found.append(("jarvis_permissions", new, sh))
        if cat:
            continue
        if UNSAFE_PATH.search(new):
            found.append(("jarvis_permissions", new, "path with characters the checker does not accept (# ? % \\ control, .. segments)"))
        if not new.lower().endswith(exts):
            prob = ext_problem(cfg, new)
            if prob:
                found.append(("jarvis_permissions", new, prob))
            continue
        lines = added_lines(base, head, new, root)
        if lines is None:
            found.append(("jarvis_permissions", new, "diff could not be read (treated as protected)"))
            continue
        cats = set()
        for line in lines:
            for c, why in line_findings(cfg, new, line):
                cats.add(c)
                found.append((c, new, why + ": " + line.strip()[:120]))
        for c, why in window_findings(cfg, new, lines):
            if c not in cats:           # one assembled finding per category the plain line scan missed
                cats.add(c)
                found.append((c, new, why))
    seen, out = set(), []
    for f in found:
        if f not in seen:
            seen.add(f); out.append(f)
    return out


def _is_tree(ref, path, root=ROOT):
    try:
        return git("cat-file", "-t", f"{ref}:{path}", root=root).decode().strip() == "tree"
    except subprocess.CalledProcessError:
        return False


def tree_stems(base, head, root=ROOT):
    """Names of every top-level Python module in the base and head trees (a directory named like one could shadow it)."""
    out = set()
    for ref in (base, head):
        try:
            names = git("ls-tree", "--name-only", ref, root=root).decode("utf-8", "replace").split("\n")
        except subprocess.CalledProcessError:
            continue
        out |= {n[:-3].casefold() for n in names if n.lower().endswith(".py") and "/" not in n}
    return out


def zone_branch(cfg, head_ref, base_ref=""):
    """B4: every pull request from or into a Jarvis branch (auto-* PRs AND the jarvis/integration release PR) is zone-checked."""
    pre = cfg.get("_zone_prefixes") or ((cfg.get("self_edit") or {}).get("branch_prefix", "jarvis/auto-"),)
    return any((head_ref or "").startswith(p) or (base_ref or "").startswith(p) for p in pre if p)


def path_findings(cfg, paths, selfedit=False, mode=None):
    """Path-only check (no git): what the self-edit pipeline refuses before writing anything.
    selfedit: also the path syntax rules, new-module / deploy / unscanned-type rules, and (allowlist mode) the auto-ship zone."""
    out = []
    mode = mode or self_edit_mode(cfg)
    for p in paths:
        raw = p or ""
        n = norm(raw)
        if not n or n.startswith("../") or "/../" in "/" + raw + "/":
            out.append(("jarvis_permissions", raw, "path leaves the repository")); continue
        if selfedit and (UNSAFE_PATH.search(raw) or n != raw):
            out.append(("jarvis_permissions", raw, "path with characters or segments the pipeline does not accept (# ? % \\ control characters, ., .., //, leading /)")); continue
        cat = path_category(cfg, n)
        if cat:
            out.append((cat, n, "protected path")); continue
        if selfedit:
            why = shadow_problem(cfg, n, True) or ext_problem(cfg, n)
            if why:
                out.append(("jarvis_permissions", n, why)); continue
            if mode == "allowlist" and not in_zone(cfg, n):
                out.append(("self_edit_zone", n, "outside the auto-ship zone (allowlist mode)"))
    return out


# ---------------------------------------------------------------------------------------------------------------- approval
class _NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, *a, **k):
        return None


def _api(url, token):
    if not url.startswith("https://api.github.com/"):
        raise ValueError("only api.github.com")
    req = urllib.request.Request(url, headers={"Accept": "application/vnd.github+json", "User-Agent": "protected-paths-check", "X-GitHub-Api-Version": "2022-11-28"})
    if token:
        req.add_header("Authorization", f"Bearer {token}")
    with urllib.request.build_opener(_NoRedirect).open(req, timeout=30) as r:
        return json.loads(r.read() or b"null")


class TooMany(Exception):
    pass


def _pages(fetch, url, max_pages=30):
    out = []
    for page in range(1, max_pages + 1):
        sep = "&" if "?" in url else "?"
        batch = fetch(f"{url}{sep}per_page=100&page={page}") or []
        out += batch
        if len(batch) < 100:
            return out
    raise TooMany(f"more than {max_pages * 100} entries at {url}: failing closed")


def identity_problem(cfg, author=None):
    """Why no owner approval can count, or None. owner_login must be an account no agent can use and must not be the PR's author."""
    owner = (cfg.get("owner_login") or "").strip().casefold()
    agents = {a.strip().casefold() for a in cfg.get("agent_logins") or [] if a}
    if not owner:
        return "owner_login is not set"
    if owner in agents:
        return (f"owner_login {cfg['owner_login']!r} is also an agent account (agent_logins): an agent session could produce the approval, so none counts. "
                "Owner decision: create a second GitHub account for the Chairman and set it as owner_login + in .github/CODEOWNERS")
    if author and owner == author.casefold():
        return "the pull request was opened by owner_login: the owner approval must come from a different account than the author"
    return None


def approval(cfg, repo, pr, head_sha, fetch, pr_info=None):
    """(approved: bool, how: str). fetch(url) -> parsed JSON. Only the exact head SHA counts. Fails closed on any identity problem."""
    api = f"https://api.github.com/repos/{repo}"
    info = pr_info if pr_info is not None else (fetch(f"{api}/pulls/{int(pr)}") or {})
    author = ((info.get("user") or {}).get("login") or "")
    prob = identity_problem(cfg, author)
    if prob:
        return False, "FAIL CLOSED: " + prob
    owner = cfg["owner_login"].strip().casefold()
    agents = {a.strip().casefold() for a in cfg.get("agent_logins") or [] if a}
    methods = set((cfg.get("approval") or {}).get("methods") or ["review"])
    if "review" in methods:
        latest = None
        for r in _pages(fetch, f"{api}/pulls/{int(pr)}/reviews"):   # the owner's latest decisive review on THIS commit
            if ((r.get("user") or {}).get("login") or "").casefold() == owner and r.get("commit_id") == head_sha and r.get("state") in ("APPROVED", "CHANGES_REQUESTED", "DISMISSED"):
                latest = r.get("state")
        if latest == "APPROVED":
            return True, f"owner review APPROVED on {head_sha}"
    label = cfg["approval"]["label_prefix"] + head_sha          # S5: the FULL 40-character SHA (a 12-character prefix could be collided)
    if "label" in methods:
        applied = False
        for e in _pages(fetch, f"{api}/issues/{int(pr)}/events"):
            if (e.get("label") or {}).get("name") != label:
                continue
            actor = ((e.get("actor") or {}).get("login") or "").casefold()
            if e.get("event") == "labeled":     # the LATEST labeling decides: by anyone else (an agent, the author) it does not count
                applied = actor == owner and actor not in agents and actor != author.casefold()
            elif e.get("event") == "unlabeled":
                applied = False
        if applied:
            issue = fetch(f"{api}/issues/{int(pr)}") or {}
            if any(l.get("name") == label for l in issue.get("labels") or []):
                return True, f"owner label {label}"
    how = " or ".join(m for m in ("review (Review -> Approve)" if "review" in methods else "", f"the label {label}" if "label" in methods else "") if m)
    return False, f"no owner approval for head {head_sha[:12]}: owner_login approves with {how}"


def push_approval(cfg, repo, branch, before, after, fetch, parent_of=None):
    """A push to a protected branch is approved only when it is exactly the merge of a pull request the owner approved (its first parent is the old tip)."""
    api = f"https://api.github.com/repos/{repo}"
    if parent_of is not None and parent_of(after) != before:
        return False, "push is not a single merge on top of the previous tip: unapproved protected changes"
    for p in fetch(f"{api}/commits/{after}/pulls") or []:
        if p.get("merged_at") and p.get("merge_commit_sha") == after and (p.get("base") or {}).get("ref") == branch:
            ok, how = approval(cfg, repo, p["number"], (p.get("head") or {}).get("sha") or "", fetch, pr_info=p)
            if ok:
                return True, f"merge of PR #{p['number']}: {how}"
            return False, f"merge of PR #{p['number']}: {how}"
    return False, "direct push (no approved pull request merged as this commit)"


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--base", default=None)
    ap.add_argument("--head", default="HEAD")
    ap.add_argument("--ci", action="store_true")
    ap.add_argument("--paths", nargs="*")
    ap.add_argument("--selfedit", action="store_true", help="with --paths: the self-edit rules (syntax, new modules, unscanned types, zone in allowlist mode)")
    ap.add_argument("--zone", action="store_true", help="also report every path outside the auto-ship zone")
    ap.add_argument("--config", default=CONFIG)
    ap.add_argument("--repo", default=None, help="repository to diff (default: this checker's own checkout)")
    a = ap.parse_args(argv)
    cfg = load(a.config)
    repo_root = os.path.abspath(a.repo) if a.repo else ROOT
    print(f"check_protected_paths: judge {os.path.abspath(__file__)}, config {os.path.abspath(a.config)}, self-edit mode {self_edit_mode(cfg)}")
    if a.paths is not None:
        f = path_findings(cfg, a.paths, selfedit=a.selfedit)
        for cat, p, why in f:
            print(f"PROTECTED [{cat}] {p}: {why}")
        print(f"check_protected_paths: {len(f)} protected path(s)")
        return 1 if f else 0
    env = os.environ
    event = env.get("GITHUB_EVENT_NAME", "") if a.ci else ""
    repo, token = env.get("GITHUB_REPOSITORY", ""), env.get("GITHUB_TOKEN", "")
    fetch = lambda u: _api(u, token)   # noqa: E731
    pr_event = event in ("pull_request", "pull_request_review", "pull_request_target")
    head = (env.get("HEAD_SHA") or a.head) if a.ci else a.head
    if a.ci and pr_event:
        base_ref = env.get("BASE_REF", "")
        if not re.fullmatch(r"[A-Za-z0-9._/-]{1,200}", base_ref or ""):
            print("FAIL: BASE_REF (the pull request's base branch) is missing"); return 1
        base = a.base or f"origin/{base_ref}"
    elif a.ci and event == "push":
        base = env.get("PUSH_BEFORE") or ""
        if not base or re.fullmatch(r"0{40}", base):
            base = a.base or "origin/overnight-build"    # a push that created the branch: compare with the deploy base
    else:
        base = a.base or "origin/overnight-build"
    try:
        git("rev-parse", "--verify", "--quiet", base + "^{commit}", root=repo_root)
        git("rev-parse", "--verify", "--quiet", head + "^{commit}", root=repo_root)
    except subprocess.CalledProcessError:
        print(f"FAIL: base {base!r} or head {head!r} is not a commit in {repo_root} (fetch the current base branch and the head)")
        return 1
    se = cfg.get("self_edit") or {}
    jl = {x.casefold() for x in cfg.get("jarvis_logins") or []}
    zone = a.zone or (a.ci and self_edit_mode(cfg) == "allowlist" and (zone_branch(cfg, env.get("HEAD_REF", ""), env.get("BASE_REF", ""))
                                                                       or env.get("HEAD_REF", "").startswith(se.get("branch_prefix", "jarvis/auto-"))
                                                                       or env.get("PR_AUTHOR", "").casefold() in jl))
    found = scan(cfg, base, head, root=repo_root, zone_only=bool(zone))
    for cat, p, why in found:
        print(f"PROTECTED [{cat}] {p}: {why}")
    mb = git("merge-base", base, head, root=repo_root).decode().strip()
    print(f"check_protected_paths: {len(found)} finding(s) between {base} (merge base {mb[:12]}) and {head[:12]}" + (" [self-edit PR: auto-ship zone enforced]" if zone else ""))
    if not found:
        return 0
    if not a.ci:
        return 1
    if event == "push":
        ref = env.get("PUSH_REF", "")
        if ref not in ((cfg.get("trusted") or {}).get("protected_branches") or []):
            print(f"NOTE: push to {ref!r}, not a protected branch: reported only (the pull request into a protected branch is judged).")
            return 0
        try:
            ok, how = push_approval(cfg, repo, ref, base, head, fetch, parent_of=lambda s: git("rev-parse", s + "^1", root=repo_root).decode().strip())
        except Exception as e:
            print(f"FAIL: could not read the approval from GitHub ({type(e).__name__}): failing closed"); return 1
        print(("OK: " if ok else "FAIL: ") + how)
        return 0 if ok else 1
    if not pr_event:
        print(f"FAIL: event {event!r} with protected changes: no approval path, failing closed"); return 1
    pr, sha = env.get("PR_NUMBER", ""), env.get("HEAD_SHA", "")
    if not (repo and pr.isdigit() and re.fullmatch(r"[0-9a-f]{40}", sha or "")):
        print("FAIL: protected changes and the pull request context (GITHUB_REPOSITORY, PR_NUMBER, HEAD_SHA) is missing, so no approval can be checked")
        return 1
    try:
        info = fetch(f"https://api.github.com/repos/{repo}/pulls/{int(pr)}") or {}
        live_base, live_head = (info.get("base") or {}).get("ref"), (info.get("head") or {}).get("sha")
        if live_base != env.get("BASE_REF") or live_head != sha:
            print(f"FAIL: the pull request moved (base {live_base}, head {str(live_head)[:12]}) since this run started: the newer run judges it"); return 1
        ok, how = approval(cfg, repo, pr, sha, fetch, pr_info=info)
    except Exception as e:
        print(f"FAIL: could not read the approval from GitHub ({type(e).__name__}): failing closed")
        return 1
    print(("OK: " if ok else "FAIL: ") + how)
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
