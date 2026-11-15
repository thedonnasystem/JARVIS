#!/usr/bin/env python3
"""Fail if a GitHub workflow/action uses an unpinned third-party action. Stdlib only, line based (no YAML parser needed).

Rules, for every file under .github/workflows and .github/actions:
  P1  every `uses:` is a local path (./...), a docker:// image pinned by @sha256:<64 hex>, or owner/repo[/path]@<40 hex commit SHA>
  P2  a pinned `uses:` carries a trailing `# <version>` comment (so a human can see what the SHA is)
  P3  every workflow file declares a top-level `permissions:` block (least privilege; jobs may narrow or widen explicitly)
  P4  every actions/checkout step sets `persist-credentials: false` in its `with:` block
  P5  every service/job-container `image:` in a workflow is pinned by @sha256:<64 hex> (a moving tag such as postgres:16 is refused)
Usage: scripts/check_workflow_pins.py [repo_root]    exit 0 clean, 1 violations.
"""
import os
import re
import sys

SHA = re.compile(r"^[0-9a-f]{40}$")
IMAGE = re.compile(r"^\s*image:\s*(?P<ref>[^\s#]+)\s*(?:#.*)?$")
USES = re.compile(r"^\s*(?:-\s*)?uses:\s*(?P<ref>[^\s#]+)\s*(?P<comment>#.*)?$")


def check_text(path, text):
    errs = []
    lines = text.splitlines()
    is_workflow = "/workflows/" in path.replace(os.sep, "/")
    if is_workflow and not re.search(r"(?m)^permissions:", text):
        errs.append(f"{path}: P3 no top-level `permissions:` block")
    for i, line in enumerate(lines):
        if line.lstrip().startswith("#"):
            continue
        im = IMAGE.match(line) if is_workflow else None
        if im:
            iref = im.group("ref").strip("'\"")
            if not re.search(r"@sha256:[0-9a-f]{64}$", iref):
                errs.append(f"{path}:{i + 1}: P5 container image not pinned by @sha256 digest: {iref}")
            continue
        m = USES.match(line)
        if not m:
            continue
        ref, comment = m.group("ref").strip("'\""), m.group("comment")
        n = i + 1
        if ref.startswith("./"):
            continue
        if ref.startswith("docker://"):
            if not re.search(r"@sha256:[0-9a-f]{64}$", ref):
                errs.append(f"{path}:{n}: P1 docker action not pinned by @sha256 digest: {ref}")
            continue
        name, _, version = ref.partition("@")
        if not version or not SHA.match(version):
            errs.append(f"{path}:{n}: P1 action not pinned by 40-char commit SHA: {ref}")
            continue
        if not comment or not re.search(r"#\s*v?\d", comment):
            errs.append(f"{path}:{n}: P2 pinned action has no `# <version>` comment: {ref}")
        if name.lower().startswith("actions/checkout"):
            window = "\n".join(lines[i + 1 : i + 8])
            nxt = re.split(r"(?m)^\s*-\s", window)[0]  # stop at the next step
            if not re.search(r"persist-credentials:\s*false", nxt):
                errs.append(f"{path}:{n}: P4 actions/checkout without `persist-credentials: false`")
    return errs


def check_root(root):
    errs, files = [], []
    for sub in (".github/workflows", ".github/actions"):
        for dp, _, fns in os.walk(os.path.join(root, sub)):
            for fn in fns:
                if fn.endswith((".yml", ".yaml")):
                    files.append(os.path.join(dp, fn))
    for p in sorted(files):
        with open(p, encoding="utf-8") as f:
            errs += check_text(os.path.relpath(p, root), f.read())
    return errs, len(files)


def main(argv):
    root = argv[1] if len(argv) > 1 else os.path.join(os.path.dirname(os.path.abspath(__file__)), "..")
    errs, n = check_root(root)
    for e in errs:
        print("FAIL", e)
    print(f"check_workflow_pins: {n} file(s), {len(errs)} violation(s)")
    return 1 if errs else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
