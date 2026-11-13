#!/usr/bin/env python3
"""Prints the checkable facts of the production approval package: PR heads, ancestry, migration order and sha256 of each file as stored
in git at the PR head (not the working tree), bundle checksum, and which migrations are new relative to overnight-build.
Read-only. Usage: scripts/approval_facts.py [--pr2 SHA --pr3 SHA --pr4 SHA]  (defaults: the GitHub heads via git ls-remote)"""
import argparse, hashlib, subprocess, sys

def git(*a, check=True):
    r = subprocess.run(["git", *a], capture_output=True, text=True)
    if check and r.returncode:
        sys.exit(f"git {' '.join(a)} failed: {r.stderr.strip()}")
    return r.stdout

def remote_head(ref):
    out = git("ls-remote", "origin", f"refs/heads/{ref}", check=False).split()
    return out[0] if out else None

def blob_sha256(rev, path):
    r = subprocess.run(["git", "show", f"{rev}:{path}"], capture_output=True)
    return hashlib.sha256(r.stdout).hexdigest() if r.returncode == 0 else None

def is_ancestor(a, b):
    return subprocess.run(["git", "merge-base", "--is-ancestor", a, b]).returncode == 0

ap = argparse.ArgumentParser()
ap.add_argument("--pr2"); ap.add_argument("--pr3"); ap.add_argument("--pr4")
a = ap.parse_args()
pr2 = a.pr2 or remote_head("phase1-5-backup")
pr3 = a.pr3 or remote_head("integration/sprint1")
pr4 = a.pr4 or remote_head("integration/sprint2")
base = remote_head("overnight-build") or git("rev-parse", "origin/overnight-build").strip()
print(f"overnight-build (merge target) = {base}")
print(f"PR #2 head phase1-5-backup      = {pr2}")
print(f"PR #3 head integration/sprint1  = {pr3}")
print(f"PR #4 head integration/sprint2  = {pr4}")
print(f"PR2 head is ancestor of PR3 head: {is_ancestor(pr2, pr3)}")
print(f"PR3 head is ancestor of PR4 head: {is_ancestor(pr3, pr4)}")
print(f"overnight-build is ancestor of PR2/PR3/PR4: {is_ancestor(base, pr2)}/{is_ancestor(base, pr3)}/{is_ancestor(base, pr4)}")
for n, (x, y) in {"PR #2 vs base": (base, pr2), "PR #3 vs base": (base, pr3), "PR #4 vs PR #3": (pr3, pr4), "PR #4 vs base": (base, pr4)}.items():
    stat = git("diff", "--shortstat", f"{x}...{y}").strip()
    print(f"{n}: {stat}")
print("\nMigrations added by each PR (relative to its base):")
for n, (x, y) in {"PR #2": (base, pr2), "PR #3 (adds beyond PR #2)": (pr2, pr3), "PR #4": (pr3, pr4)}.items():
    adds = [l.split("\t")[1] for l in git("diff", "--name-status", f"{x}..{y}", "--", "migrations/").splitlines() if l.startswith("A")]
    mods = [l.split("\t")[1] for l in git("diff", "--name-status", f"{x}..{y}", "--", "migrations/").splitlines() if l.startswith("M") and "APPLY_ORDER" not in l]
    print(f"  {n}: added={adds or 'none'} modified-existing={mods or 'none'}")
print("\nApply order at PR #4 head (migrations/APPLY_ORDER.txt) with sha256 of the file as stored in git:")
order = [l.strip() for l in git("show", f"{pr4}:migrations/APPLY_ORDER.txt").splitlines() if l.strip() and not l.startswith("#")]
new = set(l.split("/", 1)[1] for l in git("diff", "--name-only", f"{base}..{pr4}", "--", "migrations/").splitlines() if l.endswith(".sql"))
for i, f in enumerate(order, 1):
    tag = "NEW (pending)" if f in new else "in base"
    print(f"  {i:2d}. {f}  {blob_sha256(pr4, 'migrations/' + f)}  [{tag}]")
print("\nOther artifacts at PR #4 head:")
for p in ["dist/APPLY_ALL.sql", "ops/rollback_phase1.sql", "ops/EXPECTED_NEW_FUNCTIONS.txt", "ops/verify_live.sql", "ops/preflight_live.sql",
          "ops/pending_signoff/send_policy_single_authorization.sql", "ops/pending_signoff/inbox_open_app_needs_you.txt"]:
    print(f"  {p}  {blob_sha256(pr4, p)}")
