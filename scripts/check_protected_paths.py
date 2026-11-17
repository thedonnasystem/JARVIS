#!/usr/bin/env python3
"""Never-edit enforcement (ops/PROTECTED_PATHS.json). Pure stdlib.

Fails when a change between BASE and HEAD
  - adds, modifies, deletes, renames or copies a protected path (rename / copy detection: the OLD path counts too, and a copy OF a protected file counts),
  - adds or changes a symlink that points into a protected path, out of the repository, or at an absolute path; adds a submodule,
  - in any other code file, adds a line that writes a protected SQL object (name + a write verb), a grant / revoke / RLS / role statement (.sql / .sh files),
    or a destructive data statement (DROP / TRUNCATE / DELETE ...),
UNLESS the pull request carries a valid owner approval marker for the exact head commit:
  (a) an APPROVED review by the owner account whose commit_id is the head SHA, or
  (b) the label  owner-approved-<first 12 chars of the head SHA>  applied by the owner account (issue events) and still on the PR.
A new push changes the head SHA, so every approval is void after any later commit.

  python3 scripts/check_protected_paths.py --base origin/overnight-build          local: list findings, exit 1 if any
  python3 scripts/check_protected_paths.py --ci                                  CI: on a pull request, findings without approval fail; on a push, report only
  python3 scripts/check_protected_paths.py --paths a.py b.py                     path-only check of a file list (used by Jarvis's self-edit pipeline)

CI environment: GITHUB_EVENT_NAME, GITHUB_REPOSITORY, GITHUB_TOKEN (read-only is enough), PR_NUMBER, BASE_SHA, HEAD_SHA.
This is a tripwire plus an approval gate, not a proof: branch protection (owner setting) must require this job, or a direct push to the branch skips it.
"""
import argparse
import json
import os
import posixpath
import re
import subprocess
import sys
import urllib.parse
import urllib.request

ROOT = os.path.normpath(os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))
CONFIG = os.path.join(ROOT, "ops", "PROTECTED_PATHS.json")
WRITE_VERB = re.compile(r"\b(create|alter|drop|replace|update|insert|delete|truncate|grant|revoke|comment\s+on|patch|upsert|rename)\b", re.I)


def load(path=CONFIG):
    with open(path, encoding="utf-8") as f:
        cfg = json.load(f)
    paths, sql, prefixes, patterns = [], [], [], []
    for name, c in cfg["categories"].items():
        paths += [(p, name) for p in c.get("paths", [])]
        sql += [(s, name) for s in c.get("sql", [])]
        prefixes += [(s, name) for s in c.get("sql_prefixes", [])]
        patterns += [(re.compile(p, re.I), name) for p in c.get("sql_patterns", [])]
    cfg["_paths"], cfg["_sql"], cfg["_prefixes"], cfg["_patterns"] = paths, sql, prefixes, patterns
    cfg["_destructive"] = [re.compile(p, re.I) for p in cfg.get("destructive_patterns", [])]
    return cfg


def norm(p):
    p = posixpath.normpath((p or "").replace("\\", "/")).lstrip("/")
    return "" if p == "." else p


def path_category(cfg, path):
    """The category protecting this path, or None. Case-insensitive (a case-only rename on a case-insensitive checkout is the same file)."""
    p = norm(path).casefold()
    if not p or p.startswith("../"):
        return None
    for prot, cat in cfg["_paths"]:
        q = prot.casefold()
        if (q.endswith("/") and (p.startswith(q) or p + "/" == q)) or p == q:
            return cat
    return None


def resolve_link(link_path, target):
    """Repository-relative path a symlink points to; None when it escapes the repository or is absolute."""
    if not target or target.startswith("/") or re.match(r"^[A-Za-z]:", target):
        return None
    r = posixpath.normpath(posixpath.join(posixpath.dirname(norm(link_path)), target))
    return None if r == ".." or r.startswith("../") else norm(r)


def line_findings(cfg, path, line):
    """Findings for one ADDED line of a non-protected file."""
    out, low, ext = [], line.lower(), os.path.splitext(path)[1].lower()
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
    if ext in (".sql", ".sh"):
        for rx, cat in cfg["_patterns"]:
            if rx.search(line):
                out.append((cat, f"permission statement ({rx.pattern})"))
                break
    return out


def git(*args, root=ROOT):
    return subprocess.run(["git", *args], cwd=root, check=True, capture_output=True).stdout


def changes(base, head, root=ROOT):
    """[(status, old_path, new_path, old_mode, new_mode, new_blob)] with rename + copy detection."""
    raw = git("diff", "--raw", "-z", "-M50%", "-C50%", "--find-copies-harder", "--no-abbrev", f"{base}...{head}", root=root).decode("utf-8", "surrogateescape")
    parts, out, i = raw.split("\0"), [], 0
    while i < len(parts) and parts[i]:
        meta = parts[i].lstrip(":").split()
        old_mode, new_mode, _old_blob, new_blob, status = meta[0], meta[1], meta[2], meta[3], meta[4]
        if status[0] in "RC":
            out.append((status[0], parts[i + 1], parts[i + 2], old_mode, new_mode, new_blob)); i += 3
        else:
            out.append((status[0], parts[i + 1], parts[i + 1], old_mode, new_mode, new_blob)); i += 2
    return out


def added_lines(base, head, path, root=ROOT):
    try:
        d = git("diff", "-U0", "--no-color", "--no-ext-diff", f"{base}...{head}", "--", path, root=root).decode("utf-8", "replace")
    except subprocess.CalledProcessError:
        return []
    return [l[1:] for l in d.splitlines() if l.startswith("+") and not l.startswith("+++")]


def scan(cfg, base, head, root=ROOT):
    """All findings: [(category, path, reason)]."""
    found = []
    exts = tuple(cfg.get("code_extensions", []))
    for status, old, new, old_mode, new_mode, blob in changes(base, head, root):
        label = {"D": "deleted", "A": "added", "M": "modified", "T": "type changed", "R": "renamed", "C": "copied"}.get(status, status)
        if status in "RC" and path_category(cfg, old):
            found.append((path_category(cfg, old), new, ("rename" if status == "R" else "copy") + f" of protected file {old}"))
        if path_category(cfg, new):
            found.append((path_category(cfg, new), new, label))
        if new_mode == "120000" and status != "D":
            target = git("cat-file", "-p", blob, root=root).decode("utf-8", "replace").strip()
            r = resolve_link(new, target)
            if r is None:
                found.append(("jarvis_permissions", new, f"symlink to {target!r} leaves the repository"))
            elif path_category(cfg, r):
                found.append((path_category(cfg, r), new, f"symlink into protected path {r}"))
        if new_mode == "160000" and status != "D":
            found.append(("jarvis_permissions", new, "submodule added or changed"))
        if status != "D" and new_mode not in ("120000", "160000") and not path_category(cfg, new) and new.lower().endswith(exts):
            for line in added_lines(base, head, new, root):
                for cat, why in line_findings(cfg, new, line):
                    found.append((cat, new, why + ": " + line.strip()[:120]))
    seen, out = set(), []
    for f in found:
        if f not in seen:
            seen.add(f); out.append(f)
    return out


def path_findings(cfg, paths):
    """Path-only check (no git): what the self-edit pipeline refuses before writing anything."""
    out = []
    for p in paths:
        n = norm(p)
        if not n or n.startswith("../") or "/../" in "/" + (p or "") + "/":
            out.append(("jarvis_permissions", p, "path leaves the repository"))
            continue
        cat = path_category(cfg, n)
        if cat:
            out.append((cat, n, "protected path"))
    return out


# ---------------------------------------------------------------------------------------------------------------- approval
def _api(url, token):
    req = urllib.request.Request(url, headers={"Accept": "application/vnd.github+json", "User-Agent": "protected-paths-check", "X-GitHub-Api-Version": "2022-11-28"})
    if token:
        req.add_header("Authorization", f"Bearer {token}")
    with urllib.request.urlopen(req, timeout=30) as r:
        return json.loads(r.read() or b"null")


def _pages(fetch, url):
    out = []
    for page in range(1, 11):
        sep = "&" if "?" in url else "?"
        batch = fetch(f"{url}{sep}per_page=100&page={page}") or []
        out += batch
        if len(batch) < 100:
            break
    return out


def approval(cfg, repo, pr, head_sha, fetch):
    """(approved: bool, how: str). fetch(url) -> parsed JSON. Only the exact head SHA counts."""
    owner = cfg["owner_login"].casefold()
    api = f"https://api.github.com/repos/{repo}"
    reviews = _pages(fetch, f"{api}/pulls/{int(pr)}/reviews")
    latest = None
    for r in reviews:   # the owner's latest decisive review on THIS commit
        if ((r.get("user") or {}).get("login") or "").casefold() == owner and r.get("commit_id") == head_sha and r.get("state") in ("APPROVED", "CHANGES_REQUESTED", "DISMISSED"):
            latest = r.get("state")
    if latest == "APPROVED":
        return True, f"owner review APPROVED on {head_sha[:12]}"
    label = cfg["approval"]["label_prefix"] + head_sha[:12]
    events = _pages(fetch, f"{api}/issues/{int(pr)}/events")
    applied = False
    for e in events:
        if (e.get("label") or {}).get("name") != label:
            continue
        actor = ((e.get("actor") or {}).get("login") or "").casefold()
        if e.get("event") == "labeled":
            applied = actor == owner        # a later label by someone else does not count; the owner's own latest action decides
        elif e.get("event") == "unlabeled":
            applied = False
    if applied:
        issue = fetch(f"{api}/issues/{int(pr)}") or {}
        if any(l.get("name") == label for l in issue.get("labels") or []):
            return True, f"owner label {label}"
    return False, f"no owner approval for head {head_sha[:12]}: the owner approves the PR in GitHub (Review -> Approve) or adds the label {label}"


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--base", default=None)
    ap.add_argument("--head", default="HEAD")
    ap.add_argument("--ci", action="store_true")
    ap.add_argument("--paths", nargs="*")
    ap.add_argument("--config", default=CONFIG)
    a = ap.parse_args(argv)
    cfg = load(a.config)
    if a.paths is not None:
        f = path_findings(cfg, a.paths)
        for cat, p, why in f:
            print(f"PROTECTED [{cat}] {p}: {why}")
        print(f"check_protected_paths: {len(f)} protected path(s)")
        return 1 if f else 0
    event = os.environ.get("GITHUB_EVENT_NAME", "")
    base = a.base or os.environ.get("BASE_SHA") or "origin/overnight-build"
    head = os.environ.get("HEAD_SHA") or a.head if a.ci else a.head
    if re.fullmatch(r"0{40}", base or ""):          # a push that created the branch: compare with the deploy base instead
        base = "origin/overnight-build"
    try:
        git("rev-parse", "--verify", "--quiet", base + "^{commit}")
    except subprocess.CalledProcessError:
        print(f"FAIL: base {base!r} is not a commit in this checkout (fetch full history)")
        return 1
    found = scan(cfg, base, head)
    for cat, p, why in found:
        print(f"PROTECTED [{cat}] {p}: {why}")
    print(f"check_protected_paths: {len(found)} finding(s) between {base[:12]} and {head[:12]}")
    if not found:
        return 0
    if not a.ci:
        return 1
    if event not in ("pull_request", "pull_request_review", "pull_request_target"):
        print("NOTE: not a pull request: reported only. Owner approval is enforced on pull requests; branch protection must require pull requests (OWNER_GUIDE_JARVIS_V2.md).")
        return 0
    repo, pr, sha = os.environ.get("GITHUB_REPOSITORY", ""), os.environ.get("PR_NUMBER", ""), os.environ.get("HEAD_SHA", "")
    if not (repo and pr.isdigit() and re.fullmatch(r"[0-9a-f]{40}", sha or "")):
        print("FAIL: protected changes and the pull request context (GITHUB_REPOSITORY, PR_NUMBER, HEAD_SHA) is missing, so no approval can be checked")
        return 1
    token = os.environ.get("GITHUB_TOKEN", "")
    try:
        ok, how = approval(cfg, repo, pr, sha, lambda u: _api(u, token))
    except Exception as e:
        print(f"FAIL: could not read the approval from GitHub ({type(e).__name__}): failing closed")
        return 1
    print(("OK: " if ok else "FAIL: ") + how)
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
