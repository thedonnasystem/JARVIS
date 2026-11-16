#!/usr/bin/env python3
"""Guard for the secret-scan suppressions. Stdlib only (tomllib: Python >= 3.11).

Rules
  G1  .gitleaksignore holds only exact fingerprints `<40-hex commit>:<path>:<rule>:<line>` (no wildcards, no duplicates)
  G2  the fingerprint list equals the audited list in scripts/gitleaks_ignore_audit.json: same count, same sha256, and every
      fingerprint has a documented entry (why / origin / reviewed). Growing the list therefore needs a reviewed edit of the audit file.
  G3  .gitleaks.toml has no `commits =` (commit-wide), no `disabledRules`, keeps `useDefault = true`
  G4  every [[allowlists]] / [[rules.allowlists]] entry is `condition = "AND"`, has `paths` AND `regexes`, regexTarget "line",
      every path an anchored exact file (^...$, no wildcards or char classes, no directory), every regex non-trivial; no
      `stopwords`, no `rules`/`targetRules` wildcard use, no `commits`.
Usage: scripts/check_gitleaks_ignore.py [repo_root]    exit 0 clean, 1 violations.
"""
import hashlib
import json
import os
import re
import sys
import tomllib

FP = re.compile(r"^[0-9a-f]{40}:[^:\s*?\[\]]+:[A-Za-z0-9_.-]+:[0-9]+$")
# after unescaping `\.` a path must be literal characters only
LITERAL_PATH = re.compile(r"^\^[A-Za-z0-9_./\\@-]+\$$")


def _read(path):
    with open(path) as f:
        return f.read()


def fingerprints(text):
    return [l.strip() for l in text.splitlines() if l.strip() and not l.lstrip().startswith("#")]


def digest(fps):
    return hashlib.sha256(("\n".join(sorted(fps)) + "\n").encode()).hexdigest()


def check_ignore(text, audit):
    errs = []
    fps = fingerprints(text)
    for f in fps:
        if not FP.match(f):
            errs.append(f"G1 malformed or wildcard fingerprint: {f}")
    if len(set(fps)) != len(fps):
        errs.append("G1 duplicate fingerprint in .gitleaksignore")
    if len(fps) != audit.get("count"):
        errs.append(f"G2 .gitleaksignore has {len(fps)} fingerprints, audit file documents {audit.get('count')}")
    if digest(fps) != audit.get("sha256"):
        errs.append(f"G2 .gitleaksignore sha256 {digest(fps)} != audited {audit.get('sha256')}")
    ent = audit.get("entries", {})
    for f in fps:
        e = ent.get(f)
        if not e or not all(e.get(k) for k in ("why", "origin", "reviewed")):
            errs.append(f"G2 no documented audit entry (why/origin/reviewed) for {f}")
    for f in ent:
        if f not in fps:
            errs.append(f"G2 audit entry without a matching .gitleaksignore line: {f}")
    return errs


def check_toml(text):
    errs = []
    if re.search(r"(?m)^\s*commits\s*=", text):
        errs.append("G3 `commits =` allowlist (commit-wide suppression) is forbidden")
    try:
        cfg = tomllib.loads(text)
    except tomllib.TOMLDecodeError as e:
        return errs + [f"G3 .gitleaks.toml does not parse: {e}"]
    if cfg.get("extend", {}).get("useDefault") is not True:
        errs.append("G3 [extend] useDefault must be true (default ruleset stays on)")
    if "disabledRules" in cfg.get("extend", {}):
        errs.append("G3 extend.disabledRules is forbidden (rule-wide suppression)")
    lists = list(cfg.get("allowlists", []))
    if "allowlist" in cfg:
        lists.append(cfg["allowlist"])
    for r in cfg.get("rules", []):
        lists += r.get("allowlists", [])
        if "allowlist" in r:
            lists.append(r["allowlist"])
    for i, a in enumerate(lists):
        d = a.get("description", f"#{i}")
        for bad in ("commits", "stopwords", "targetRules"):
            if bad in a:
                errs.append(f"G4 allowlist '{d}': `{bad}` is forbidden")
        if a.get("condition") != "AND":
            errs.append(f"G4 allowlist '{d}': condition must be \"AND\"")
        paths, regexes = a.get("paths") or [], a.get("regexes") or []
        if not paths or not regexes:
            errs.append(f"G4 allowlist '{d}': needs both exact `paths` and line `regexes` (no path-only or rule-wide entries)")
        if a.get("regexTarget") != "line":
            errs.append(f"G4 allowlist '{d}': regexTarget must be \"line\"")
        for p in paths:
            if not LITERAL_PATH.match(p):
                errs.append(f"G4 allowlist '{d}': path {p!r} is not an anchored exact file path")
            elif p.endswith("/$"):
                errs.append(f"G4 allowlist '{d}': path {p!r} is a directory")
        for rx in regexes:
            if len(rx.strip()) < 6 or rx.strip() in (".*", ".+", "(?s).*"):
                errs.append(f"G4 allowlist '{d}': regex {rx!r} is too broad")
    return errs


def main(root):
    errs = []
    audit_p = os.path.join(root, "scripts", "gitleaks_ignore_audit.json")
    ign_p = os.path.join(root, ".gitleaksignore")
    toml_p = os.path.join(root, ".gitleaks.toml")
    audit = json.loads(_read(audit_p)) if os.path.exists(audit_p) else {}
    if not audit:
        errs.append("G2 scripts/gitleaks_ignore_audit.json missing")
    if os.path.exists(ign_p):
        errs += check_ignore(_read(ign_p), audit)
    elif audit.get("count"):
        errs.append("G2 .gitleaksignore missing but audit lists fingerprints")
    errs += check_toml(_read(toml_p))
    for e in errs:
        print(e)
    n = len(fingerprints(_read(ign_p))) if os.path.exists(ign_p) else 0
    print(("FAIL" if errs else "OK") + f": {n} audited fingerprints, {len(errs)} violation(s)")
    return 1 if errs else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1] if len(sys.argv) > 1 else os.path.join(os.path.dirname(os.path.abspath(__file__)), "..")))
