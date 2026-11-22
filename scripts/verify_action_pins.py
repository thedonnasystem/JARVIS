#!/usr/bin/env python3
"""Verify that every SHA-pinned GitHub Action really is the tag its `# vX.Y.Z` comment claims, and (when a token is available) that
the commit is part of the upstream repository's default-branch history. Complements check_workflow_pins.py, which only checks FORM.

  V1  `git ls-remote <repo> refs/tags/<comment tag>` resolves (peeling annotated tags) to exactly the pinned commit SHA  -> FAIL if not
  V2  GET /repos/<repo>/compare/<default>...<sha> reports the commit is behind/identical to the default branch           -> WARN if not
      (release-branch backports are legitimately off the default branch, so V2 is advisory; needs GITHUB_TOKEN or anonymous API quota)
Network: git over HTTPS to github.com and api.github.com only. Reads no secrets, installs nothing.
Usage: scripts/verify_action_pins.py [repo_root] [--offline]   exit 0 ok, 1 mismatch, 2 network/parse error (never silently passes).
"""
import json
import os
import re
import subprocess
import sys
import urllib.request

USES = re.compile(r"^\s*(?:-\s*)?uses:\s*(?P<repo>[\w.-]+/[\w.-]+)(?P<sub>/[^@\s]*)?@(?P<sha>[0-9a-f]{40})\s*#\s*(?P<tag>v?\d[\w.+-]*)")


def pins(root):
    out = []
    d = os.path.join(root, ".github", "workflows")
    for fn in sorted(os.listdir(d)) if os.path.isdir(d) else []:
        if fn.endswith((".yml", ".yaml")):
            for n, line in enumerate(open(os.path.join(d, fn), encoding="utf-8"), 1):
                m = USES.match(line)
                if m:
                    out.append((f"{fn}:{n}", m.group("repo"), m.group("sha"), m.group("tag")))
    return out


def ls_remote(repo, tag):
    r = subprocess.run(["git", "ls-remote", f"https://github.com/{repo}", f"refs/tags/{tag}", f"refs/tags/{tag}^{{}}"],
                       capture_output=True, text=True, timeout=60)
    if r.returncode != 0:
        raise RuntimeError(r.stderr.strip()[-200:])
    refs = {l.split()[1]: l.split()[0] for l in r.stdout.splitlines() if l.strip()}
    return refs.get(f"refs/tags/{tag}^{{}}") or refs.get(f"refs/tags/{tag}")   # peeled commit wins over the tag object


def api(path):
    req = urllib.request.Request("https://api.github.com" + path, headers={"Accept": "application/vnd.github+json", "User-Agent": "pin-verify"})
    if os.environ.get("GITHUB_TOKEN"):
        req.add_header("Authorization", "Bearer " + os.environ["GITHUB_TOKEN"])
    with urllib.request.urlopen(req, timeout=30) as f:
        return json.load(f)


def verify(items, resolver=ls_remote, apifn=api):
    fails, warns = [], []
    for where, repo, sha, tag in items:
        try:
            got = resolver(repo, tag)
        except Exception as e:  # network trouble must not read as success
            fails.append(f"{where}: cannot resolve {repo}@{tag}: {e}")
            continue
        if got != sha:
            fails.append(f"{where}: {repo} tag {tag} -> {got}, but pinned {sha}")
            continue
        try:
            default = apifn(f"/repos/{repo}")["default_branch"]
            st = apifn(f"/repos/{repo}/compare/{default}...{sha}")["status"]
            if st not in ("behind", "identical"):
                warns.append(f"{where}: {repo}@{sha[:12]} ({tag}) is {st} vs {default}: release-branch commit, confirm by hand")
        except Exception as e:
            warns.append(f"{where}: ancestry check skipped for {repo}@{sha[:12]} ({e})")
    return fails, warns


def main(argv):
    args = [a for a in argv[1:] if not a.startswith("--")]
    root = args[0] if args else os.path.join(os.path.dirname(os.path.abspath(__file__)), "..")
    items = pins(root)
    if not items:
        print("verify_action_pins: no pinned actions found")
        return 2
    if "--offline" in argv:
        for it in items:
            print("PIN", *it)
        return 0
    fails, warns = verify(items)
    for w in warns:
        print("WARN", w)
    for f in fails:
        print("FAIL", f)
    print(f"verify_action_pins: {len(items)} pin(s), {len(fails)} mismatch(es), {len(warns)} warning(s)")
    return 1 if fails else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
