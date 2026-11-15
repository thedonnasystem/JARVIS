#!/usr/bin/env python3
"""Fail if the repo-root requirements.txt (what Railway builds) is not byte-for-byte the hash-locked requirements/runtime.lock.

  R1  requirements.txt = a leading comment header + the exact text of requirements/runtime.lock
  R2  every pinned requirement in requirements.txt is `name==version` with at least one --hash=sha256:<64 hex> (no ranges, no unhashed pins)
  R3  no option lines that change where packages come from (--index-url, --extra-index-url, --find-links, -e, git+/http(s) URLs, --trusted-host)
Usage: scripts/check_requirements_sync.py [repo_root]   exit 0 clean, 1 violations.   --write regenerates requirements.txt from the lock.
Stdlib only.
"""
import os
import re
import sys

HEADER = (
    "# GENERATED FROM requirements/runtime.lock by scripts/check_requirements_sync.py --write. DO NOT EDIT BY HAND.\n"
    "# Fully pinned with sha256 hashes (pip enables --require-hashes automatically when any hash is present). Source of truth: requirements/runtime.in.\n"
    "# Railway (Railpack) builds THIS file: `pip install -r requirements.txt`. scripts/check_requirements_sync.py (gate step `reqsync`) fails if it drifts from the lock.\n"
    "# Regenerate the lock: see HARDENING_NOTES.md section 1, then run `python3 scripts/check_requirements_sync.py --write`.\n"
)
PIN = re.compile(r"^(?P<name>[A-Za-z0-9][A-Za-z0-9._-]*)(?:\[[^\]]*\])?==(?P<ver>[^\s;\\]+)")
BAD = re.compile(r"^\s*(--index-url|--extra-index-url|-i\s|--find-links|-f\s|--trusted-host|-e\s|--editable|git\+|https?://|-r\s|-c\s)", re.I)


def split_header(text):
    lines = text.splitlines(keepends=True)
    i = 0
    while i < len(lines) and (lines[i].startswith("#") or not lines[i].strip()):
        i += 1
    return "".join(lines[:i]), "".join(lines[i:])


def check(req_text, lock_text):
    errs = []
    _, body = split_header(req_text)
    _, lock_body = split_header(lock_text)
    if body != lock_body:
        errs.append("R1 requirements.txt body differs from requirements/runtime.lock (run: python3 scripts/check_requirements_sync.py --write)")
    # R2/R3 are evaluated on the requirements.txt that Railway would really read
    blocks, cur = [], None
    for line in body.splitlines():
        if not line.strip() or line.lstrip().startswith("#"):
            continue
        if BAD.match(line):
            errs.append(f"R3 forbidden line: {line.strip()[:80]}")
            continue
        m = PIN.match(line)
        if m:
            cur = {"name": m.group("name"), "hashes": 0}
            blocks.append(cur)
        if cur is not None:
            cur["hashes"] += len(re.findall(r"--hash=sha256:[0-9a-f]{64}", line))
        if not m and not line.strip().startswith("--hash") and not re.search(r"--hash=sha256:", line):
            errs.append(f"R2 not a pinned requirement: {line.strip()[:80]}")
    if not blocks:
        errs.append("R2 no requirements found")
    for b in blocks:
        if b["hashes"] == 0:
            errs.append(f"R2 {b['name']} has no sha256 hash")
    return errs


def main(argv):
    write = "--write" in argv
    args = [a for a in argv if not a.startswith("--")]
    root = args[0] if args else os.path.normpath(os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))
    lock = open(os.path.join(root, "requirements", "runtime.lock")).read()
    path = os.path.join(root, "requirements.txt")
    if write:
        open(path, "w").write(HEADER + lock)
        print("wrote requirements.txt from requirements/runtime.lock")
        return 0
    errs = check(open(path).read(), lock)
    for e in errs:
        print(e)
    print(f"check_requirements_sync: {len(errs)} violation(s)")
    return 1 if errs else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
