#!/usr/bin/env python3
"""Independent Oversight: mandatory-check engine (docs/oversight/CHARTER.md, docs/oversight/RUNBOOK.md). Stdlib only.

Given a PR number and/or a head SHA it gathers evidence mechanically and answers one question: may this change progress
through the internal workflow?  It never merges, pushes, comments, approves, or touches a database or production.

    ops/oversight/mandatory_checks.py --pr 16 --sha <40 hex> [--out result.json] [--summary summary.md]
    ops/oversight/mandatory_checks.py --sha <40 hex> --base origin/overnight-build --no-github      (local evidence only)

Check status
    PASS            evidence was gathered and the rule holds
    FAIL            evidence was gathered and the rule is broken, or a protected control is touched (class owner_gate)
    UNVERIFIED      the check could not be run or its evidence is missing. UNVERIFIED IS NEVER A PASS.
    NOT_APPLICABLE  the rule has no subject in this change (stated with the reason)
Verdict
    REJECT             at least one FAIL. class "reject" = a mandatory rule is broken; class "owner_gate" = a protected
                       control is touched, which only a recorded Owner decision can release (the engine cannot)
    NEEDS_MORE_WORK    no FAIL but at least one UNVERIFIED
    RECOMMEND_APPROVE  every check PASS / NOT_APPLICABLE. A recommendation only: it authorises nothing.
Exit code: 0 RECOMMEND_APPROVE, 1 REJECT, 2 NEEDS_MORE_WORK, 3 usage/engine error.

Rules about evidence
    * nothing is asserted without a recorded command or API call (the `commands` list holds argv, exit code, sha256 of output)
    * code from the change under review is never executed: tools (lint, bundle check) are taken from the BASE ref and run
      on a throwaway clone of the head
    * matched secret-like text is never echoed (file, line and pattern name only)
"""
import argparse
import ast
import datetime
import hashlib
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile

ENGINE_VERSION = "1.0"
PASS, FAIL, UNVERIFIED, NA = "PASS", "FAIL", "UNVERIFIED", "NOT_APPLICABLE"
REQUIRED_CI_CHECKS = ("unit", "migrations", "secret-scan")           # job names in .github/workflows/tests.yml
REQUIRED_GATE_STEPS = ("unit", "scripts-tests", "lint", "bundle", "appcheck", "replica", "manifest")   # scripts/gate.sh
DEPLOY_BRANCHES = ("claude/telegram-claude-bot-59nusk",)             # Railway deploys every push (DEPLOY_RUNBOOK.md)
AUTO_PUBLISH = {"overnight-build": "webapp/"}                        # Render publishes webapp/ on every commit
HERE = os.path.dirname(os.path.abspath(__file__))
REPO_ROOT = os.path.normpath(os.path.join(HERE, "..", ".."))
FP_RE = re.compile(r"^[0-9a-f]{40}:[^:\s*?\[\]]+:[A-Za-z0-9_.-]+:[0-9]+$")       # same rule as scripts/check_gitleaks_ignore.py G1
SHA_RE = re.compile(r"^[0-9a-f]{40}$")


class Unavailable(Exception):
    """Evidence could not be obtained. Always becomes UNVERIFIED, never PASS."""


def sha256_text(s):
    return hashlib.sha256(s.encode("utf-8", "replace")).hexdigest()


def check(cid, title, status, findings=(), evidence=(), klass=None):
    """One check result. klass (for FAIL): 'reject' or 'owner_gate'."""
    findings = [f if isinstance(f, dict) else {"msg": str(f)} for f in findings]
    if status == FAIL and klass is None:
        klass = "owner_gate" if findings and all(f.get("class") == "owner_gate" for f in findings) else "reject"
    return {"id": cid, "title": title, "status": status, "class": klass if status == FAIL else None,
            "findings": findings, "evidence": [str(e) for e in evidence]}


# ------------------------------------------------------------------------------------------------- diff parsing
def parse_diff(text):
    """`git diff --unified=0 -M` -> {path: {"status": A|M|D|R, "added": [(line_no, text)], "removed": [text], "old": path}}."""
    files, cur, new_no = {}, None, 0
    for line in text.splitlines():
        if line.startswith("diff --git "):
            cur = {"status": "M", "added": [], "removed": [], "old": None}
            m = re.match(r'diff --git "?a/(.*?)"? "?b/(.*?)"?$', line)
            path = m.group(2) if m else line.split(" b/", 1)[-1]
            cur["old"] = m.group(1) if m else path
            files[path] = cur
        elif cur is None:
            continue
        elif line.startswith("new file mode"):
            cur["status"] = "A"
        elif line.startswith("deleted file mode"):
            cur["status"] = "D"
        elif line.startswith("rename from "):
            cur["status"] = "R"
        elif line.startswith("@@"):
            m = re.match(r"@@ -\d+(?:,\d+)? \+(\d+)", line)
            new_no = int(m.group(1)) if m else 0
        elif line.startswith("+++") or line.startswith("---"):
            continue
        elif line.startswith("+"):
            cur["added"].append((new_no, line[1:]))
            new_no += 1
        elif line.startswith("-"):
            cur["removed"].append(line[1:])
    return files


def is_test_or_doc(path):
    base = os.path.basename(path)
    return (base.startswith("test_") or path.startswith(("sqltests/", "webtests/", "docs/", "scripts/replica/", "scripts/repro/"))
            or "/tests/" in path or "/fixtures/" in path or path.endswith((".md", ".txt", ".tsv", ".log")) or path.startswith("ops/evidence")
            or path == "dist/APPLY_ALL.sql")


def is_oversight_fixture(path):
    return path in ("scripts/test_oversight_checks.py", "scripts/test_oversight_ledger.py")


# --------------------------------------------------------------------------------------- protected controls (diff)
# (id, class, where, pattern, what). where: 'code' = non-test code/SQL, 'sql' = non-test .sql, 'any' = every file.
# 'both' patterns are tested on added AND removed lines; '+' on added lines only; '-' on removed lines only.
LINE_RULES = [
    ("PC-SPEND", "owner_gate", "code", "both", r"daily_spend_cap_cents|day_cap_cents|spend_cap|reserve_llm_budget|settle_spend|settle_llm|hard_max|budget_cents|cap_cents|limit_cents|max_cents",
     "spend cap / spend gateway / financial limit ($3.30 per day cap, budgets)"),
    ("PC-KILL", "owner_gate", "code", "both", r"kill_switch|killswitch", "kill switch"),
    ("PC-EXEC-WRITE", "reject", "code", "+", r"(insert\s+into|update|grant\s+(?!select\b)[a-z, ]+\s+on)\s+(table\s+)?(public\.)?executor_registry",
     "executor registry written or opened (it must stay empty and owner-only)"),
    ("PC-EXEC", "owner_gate", "code", "both", r"executor_registry", "executor registry / executor registration"),
    ("PC-DRYRUN", "owner_gate", "code", "both", r"\bdry_run\b|\bdry-run\b|mode\s*(=|in)\s*\(?\s*'live'", "dry_run flag / live mode"),
    ("PC-PERM-RELAX", "reject", "sql", "+", r"disable\s+row\s+level\s+security|\bbypassrls\b|using\s*\(\s*true\s*\)|with\s+check\s*\(\s*true\s*\)|grant\s+all\b|grant\s+[^;]*\bto\s+public\b",
     "permission relaxation (RLS off, bypassrls, policy 'true', grant all / to public)"),
    ("PC-PERM-OPEN", "owner_gate", "sql", "+", r"grant\s+.*\bto\b.*\b(anon|authenticated)\b", "grant to an API role (anon / authenticated)"),
    ("PC-PERM", "owner_gate", "sql", "+", r"^\s*grant\s|security\s+definer|create\s+policy|alter\s+policy|alter\s+default\s+privileges|(create|alter)\s+role|\bset\s+role\b|\bowner\s+to\b",
     "permissions model (grant, SECURITY DEFINER, policy, role, default privileges)"),
    ("PC-PERM-REMOVED", "owner_gate", "sql", "-", r"^\s*revoke\s|enable\s+row\s+level\s+security|force\s+row\s+level\s+security", "a revoke / RLS line was removed"),
]
SECRET_RULES = [   # never echo the match
    ("anthropic-key", r"sk-ant-[A-Za-z0-9_-]{20,}"), ("github-token", r"gh[pousr]_[A-Za-z0-9]{36,}|github_pat_[A-Za-z0-9_]{40,}"),
    ("aws-access-key", r"\bAKIA[0-9A-Z]{16}\b"), ("private-key", r"-----BEGIN [A-Z ]*PRIVATE KEY-----"),
    ("jwt", r"\beyJ[A-Za-z0-9_-]{15,}\.eyJ[A-Za-z0-9_-]{15,}\.[A-Za-z0-9_-]{10,}"), ("telegram-bot-token", r"\b\d{8,10}:AA[A-Za-z0-9_-]{33}\b"),
    ("supabase-token", r"\bsbp_[a-f0-9]{40}\b"), ("slack-token", r"\bxox[bap]-[A-Za-z0-9-]{20,}"), ("stripe-live-key", r"\b[sr]k_live_[A-Za-z0-9]{20,}"),
]
GUARD_TOOLS = ("scripts/lint_migrations.py", "scripts/check_workflow_pins.py", "scripts/check_gitleaks_ignore.py", "scripts/check_app_rpcs.py",
               "scripts/function_manifest.py", "scripts/acl_manifest.py", "scripts/build_bundle.sh", "scripts/gate.sh", "scripts/gitleaks_ignore_audit.json")
PROTECTED_TESTS = ("test_no_bypass.py", "test_spend_paths.py", "test_audit_paths.py")
DEPLOY_SURFACE = re.compile(r"^(Procfile|requirements\.txt|runtime\.txt|\.python-version|nixpacks\.toml|railway\.(json|toml)|render\.ya?ml|Dockerfile)$")
OVERSIGHT_PROTECTED = re.compile(r"^(ops/oversight/(?!ledger/|evidence/)|docs/oversight/CHARTER\.md$)")


def _f(rule, klass, path, msg, line=None):
    d = {"rule": rule, "class": klass, "file": path, "msg": msg}
    if line:
        d["line"] = line
    return d


def scan_diff(files):
    """Line-level protected-control and secret findings from a parsed diff."""
    out = []
    for path, d in sorted(files.items()):
        code = not is_test_or_doc(path)
        sql = code and path.endswith(".sql")
        for rid, klass, where, side, pat, what in LINE_RULES:
            if (where == "code" and not code) or (where == "sql" and not sql):
                continue
            rx = re.compile(pat, re.I)
            hits = []
            if side in ("both", "+"):
                hits += [n for n, t in d["added"] if rx.search(t) and not t.lstrip().startswith(("--", "#"))]
            removed = sum(1 for t in d["removed"] if rx.search(t) and not t.lstrip().startswith(("--", "#"))) if side in ("both", "-") else 0
            if hits or removed:
                msg = f"{what}: {len(hits)} added line(s)" + (f", {removed} removed line(s)" if removed else "")
                out.append(_f(rid, klass, path, msg, hits[0] if hits else None))
        if not is_oversight_fixture(path):
            for name, pat in SECRET_RULES:
                lines = [n for n, t in d["added"] if re.search(pat, t)]
                if lines:
                    out.append(_f("PC-SECRET", "reject", path, f"secret-like value ({name}) on {len(lines)} added line(s); value not shown", lines[0]))
        if path in GUARD_TOOLS:
            out.append(_f("PC-GUARD", "owner_gate", path, "a lint / gate / guard tool is " + ("DELETED" if d["status"] == "D" else "modified"),))
            if d["status"] == "D":
                out[-1]["class"] = "reject"
        if path.startswith(".github/workflows/"):
            out.append(_f("PC-WORKFLOW", "reject" if d["status"] == "D" else "owner_gate", path, "CI workflow " + ("deleted" if d["status"] == "D" else "changed")))
        if path == ".gitleaks.toml":
            out.append(_f("PC-GITLEAKS", "owner_gate", path, "secret-scan configuration changed"))
            if any(re.search(r"^\s*(commits|disabledRules|stopwords)\s*=|useDefault\s*=\s*false", t) for _, t in d["added"]):
                out.append(_f("PC-GITLEAKS", "reject", path, "broad secret-scan suppression (commits / disabledRules / stopwords / useDefault=false)"))
        if os.path.basename(path) in PROTECTED_TESTS or path.startswith("sqltests/"):
            if d["status"] == "D":
                out.append(_f("PC-TESTS", "reject", path, "a control test file is deleted"))
            elif os.path.basename(path) in PROTECTED_TESTS and d["removed"]:
                out.append(_f("PC-TESTS", "owner_gate", path, f"{len(d['removed'])} line(s) removed from a spend / bypass / audit control test"))
        if DEPLOY_SURFACE.match(path):
            out.append(_f("PC-DEPLOY", "owner_gate", path, "deploy surface (what Railway / Render builds) changed"))
        if OVERSIGHT_PROTECTED.search(path):
            out.append(_f("PC-OVERSIGHT", "owner_gate", path, "the oversight function's own rules, engine or owner keys changed (it cannot approve its own permission changes)"))
    return out


def check_gitleaksignore(base_text, head_text):
    """Additions to .gitleaksignore: malformed / wildcard -> reject, exact fingerprints -> owner_gate."""
    lines = lambda t: [l.strip() for l in (t or "").splitlines() if l.strip() and not l.lstrip().startswith("#")]
    base, out = set(lines(base_text)), []
    for l in lines(head_text):
        if l in base:
            continue
        if not FP_RE.match(l):
            out.append(_f("PC-GITLEAKS", "reject", ".gitleaksignore", "added entry is not an exact fingerprint <40 hex>:<path>:<rule>:<line> (broad or wildcard); entry not shown"))
        else:
            out.append(_f("PC-GITLEAKS", "owner_gate", ".gitleaksignore", f"new suppression for {l.split(':')[1]} (rule {l.split(':')[2]})"))
    return out


def parse_codeowners(text):
    out = {}
    for l in (text or "").splitlines():
        l = l.split("#", 1)[0].split()
        if len(l) >= 2:
            out[l[0]] = set(l[1:])
    return out


def check_codeowners(base_text, head_text):
    if base_text is None:
        return []
    if head_text is None:
        return [_f("PC-CODEOWNERS", "reject", ".github/CODEOWNERS", "CODEOWNERS deleted")]
    base, head, out = parse_codeowners(base_text), parse_codeowners(head_text), []
    for p, owners in sorted(base.items()):
        if p not in head:
            out.append(_f("PC-CODEOWNERS", "reject", ".github/CODEOWNERS", f"protected path {p} removed"))
        elif not owners <= head[p]:
            out.append(_f("PC-CODEOWNERS", "reject", ".github/CODEOWNERS", f"owner(s) removed from {p}"))
        elif owners != head[p]:
            out.append(_f("PC-CODEOWNERS", "owner_gate", ".github/CODEOWNERS", f"owner(s) added to {p}"))
    for p in sorted(set(head) - set(base)):
        out.append(_f("PC-CODEOWNERS", "owner_gate", ".github/CODEOWNERS", f"new entry {p}"))
    return out


def gate_steps(text):
    return set(re.findall(r"^\s*(?:else\s+)?run\s+([a-z][a-z0-9-]*)\s+\"", text or "", re.M))


def workflow_jobs(text):
    jobs, on = set(), False
    for l in (text or "").splitlines():
        if re.match(r"^jobs:\s*$", l):
            on = True
        elif on and re.match(r"^\S", l):
            on = False
        elif on:
            m = re.match(r"^  ([A-Za-z0-9_-]+):\s*(#.*)?$", l)
            if m:
                jobs.add(m.group(1))
    return jobs


def check_gate(base_gate, head_gate, base_wf, head_wf):
    """Gate step / CI job removal. base_wf/head_wf: {path: text}."""
    out = []
    if base_gate is not None:
        if head_gate is None:
            out.append(_f("PC-GATE", "reject", "scripts/gate.sh", "gate script deleted"))
        else:
            for s in sorted(gate_steps(base_gate) - gate_steps(head_gate)):
                out.append(_f("PC-GATE", "reject", "scripts/gate.sh", f"gate step '{s}' removed"))
            if "--strict" in base_gate and "--strict" not in head_gate:
                out.append(_f("PC-GATE", "reject", "scripts/gate.sh", "--strict mode removed"))
    for path, bt in sorted((base_wf or {}).items()):
        ht = (head_wf or {}).get(path)
        if ht is None:
            out.append(_f("PC-GATE", "reject", path, "workflow removed"))
            continue
        for j in sorted(workflow_jobs(bt) - workflow_jobs(ht)):
            out.append(_f("PC-GATE", "reject", path, f"CI job '{j}' removed"))
        for needle in ("gate.sh --strict", "gitleaks git", "check_gitleaks_ignore.py", "check_workflow_pins.py", "--require-hashes"):
            if bt.count(needle) > ht.count(needle):
                out.append(_f("PC-GATE", "reject", path, f"CI step using '{needle}' removed"))
    return out


def lint_allowlists(text):
    """Names in the migration linter's exception lists (GRANDFATHERED, NOT_IN_ORDER, MODIFIED_ALLOWLIST), via ast (no exec)."""
    out = {}
    try:
        tree = ast.parse(text or "")
    except SyntaxError:
        return None
    for node in tree.body:
        if isinstance(node, ast.Assign) and len(node.targets) == 1 and isinstance(node.targets[0], ast.Name) \
                and node.targets[0].id in ("GRANDFATHERED", "NOT_IN_ORDER", "MODIFIED_ALLOWLIST"):
            names = set()
            for n in ast.walk(node.value):
                if isinstance(n, ast.Constant) and isinstance(n.value, str):
                    names.update(w for w in n.value.split() if w.endswith(".sql"))
            out[node.targets[0].id] = names
    return out


def check_lint_rules(base_text, head_text):
    if base_text is None or base_text == head_text:
        return []
    if head_text is None:
        return [_f("PC-LINT", "reject", "scripts/lint_migrations.py", "migration linter deleted")]
    b, h, out = lint_allowlists(base_text), lint_allowlists(head_text), []
    if b is None or h is None:
        return [_f("PC-LINT", "reject", "scripts/lint_migrations.py", "linter does not parse; exception lists cannot be compared")]
    for k in sorted(b):
        if k not in h:
            out.append(_f("PC-LINT", "reject", "scripts/lint_migrations.py", f"{k} removed or renamed"))
        elif h[k] - b[k]:
            out.append(_f("PC-LINT", "reject", "scripts/lint_migrations.py", f"{k} grew by {len(h[k] - b[k])}: {', '.join(sorted(h[k] - b[k]))} (a lint exception was added)"))
    rules = lambda t: set(re.findall(r"^\s{2}(R\d+)\s", t, re.M))
    for r in sorted(rules(base_text) - rules(head_text)):
        out.append(_f("PC-LINT", "reject", "scripts/lint_migrations.py", f"lint rule {r} no longer documented (removed?)"))
    return out


# ------------------------------------------------------------------------------------------------------------ CI
def check_ci(check_runs, sha, required=REQUIRED_CI_CHECKS):
    """check_runs: list of GitHub check-run objects for the commit, or None when the API could not be read."""
    title = "CI green on the exact head SHA"
    if check_runs is None:
        return check("CI", title, UNVERIFIED, ["check-runs could not be read from GitHub"])
    findings, ev, latest = [], [], {}
    for r in check_runs:
        if r.get("head_sha") != sha:
            findings.append({"class": "reject", "msg": f"check-run {r.get('name')} belongs to {r.get('head_sha')}, not the reviewed SHA"})
            continue
        if r.get("name") not in latest or (r.get("id") or 0) > (latest[r["name"]].get("id") or 0):
            latest[r["name"]] = r
    for name in required:
        r = latest.get(name)
        if r is None:
            findings.append({"class": "reject", "msg": f"required check '{name}' is missing on {sha[:12]}"})
        elif r.get("status") != "completed":
            findings.append({"class": "reject", "msg": f"required check '{name}' is {r.get('status')}, not completed"})
        elif r.get("conclusion") != "success":
            findings.append({"class": "reject", "msg": f"required check '{name}' concluded {r.get('conclusion')}"})
        else:
            ev.append(f"{name}: success, check-run {r.get('id')} {r.get('details_url') or ''}".strip())
    for name, r in sorted(latest.items()):
        if name not in required and r.get("status") == "completed" and r.get("conclusion") not in ("success", "neutral", "skipped"):
            findings.append({"class": "reject", "msg": f"check '{name}' concluded {r.get('conclusion')}"})
    return check("CI", title, FAIL if findings else PASS, findings, ev)


def parse_gate_summary(log):
    """GATE SUMMARY block of scripts/gate.sh from a CI log -> ({step: result}, verdict line or None)."""
    steps, verdict, on = {}, None, False
    for raw in (log or "").splitlines():
        l = re.sub(r"^\d{4}-\d\d-\d\dT[\d:.]+Z\s?", "", raw)
        if "GATE SUMMARY" in l:
            on, steps, verdict = True, {}, None
        elif on:
            m = re.match(r"^([a-z][a-z0-9-]*)\s+(PASS|FAIL|SKIPPED)\b\s*(.*)$", l)
            if m:
                steps[m.group(1)] = (m.group(2), m.group(3))
            elif l.startswith("GATE "):
                verdict, on = l.strip(), False
    return steps, verdict


def check_gate_evidence(log, required=REQUIRED_GATE_STEPS):
    title = "Full gate (scripts/gate.sh --strict) ran and passed in CI on this SHA"
    if log is None:
        return check("GATE-EVIDENCE", title, UNVERIFIED, ["the log of the CI job 'migrations' could not be read"])
    steps, verdict = parse_gate_summary(log)
    if not steps:
        return check("GATE-EVIDENCE", title, UNVERIFIED, ["no GATE SUMMARY block found in the CI log"])
    findings = []
    for s in required:
        if s not in steps:
            findings.append({"class": "reject", "msg": f"gate step '{s}' did not run (missing from the summary)"})
        elif steps[s][0] != "PASS":
            findings.append({"class": "reject", "msg": f"gate step '{s}' is {steps[s][0]}"})
    for s, (res, note) in sorted(steps.items()):
        if s not in required and res == "FAIL":
            findings.append({"class": "reject", "msg": f"gate step '{s}' FAILED"})
    if not (verdict or "").startswith("GATE PASSED"):
        findings.append({"class": "reject", "msg": f"gate verdict line is: {verdict or 'missing'}"})
    ev = [f"{s}: {r[0]}" for s, r in sorted(steps.items())] + [verdict or ""]
    return check("GATE-EVIDENCE", title, FAIL if findings else PASS, findings, ev)


CLAIM_RE = re.compile(r"(?<![\d./$-])(\d{2,5})\s+(?:unit\s+|python\s+|repo\s+)?tests\b(?!\s*(?:files|dirs))", re.I)
RAN_RE = re.compile(r"\bRan (\d+) tests? in\b")


def check_test_claims(claim_text, logs):
    """Counts claimed in the PR text ("736 tests") vs what CI actually ran ("Ran 736 tests in"). logs: {job: text} or None."""
    title = "Claimed test counts match what CI ran"
    claims = sorted({int(n) for n in CLAIM_RE.findall(claim_text or "")})
    if not claims:
        return check("TEST-CLAIMS", title, NA, ["no parseable 'N tests' claim in the PR title/body"])
    if not logs:
        return check("TEST-CLAIMS", title, UNVERIFIED, [f"claims {claims} found but no CI log could be read"])
    ran = sorted({int(n) for t in logs.values() for n in RAN_RE.findall(t or "")})
    if not ran:
        return check("TEST-CLAIMS", title, UNVERIFIED, [f"claims {claims} found but no 'Ran N tests' line in the CI logs"])
    ev = [f"CI ran: {ran}", f"claimed in PR text: {claims}"]
    matched = [c for c in claims if c in ran]
    if not matched:
        return check("TEST-CLAIMS", title, FAIL, [{"class": "reject", "msg": f"PR text claims {claims} tests; CI on this SHA ran {ran}. No claim matches."}], ev)
    extra = [c for c in claims if c not in ran]
    notes = [{"class": "note", "msg": f"claim(s) {extra} match no CI count (may be historic numbers or other suites; read the PR text)"}] if extra else []
    return check("TEST-CLAIMS", title, PASS, notes, ev)


# ------------------------------------------------------------------------------------------------- dependencies
def norm_pkg(name):
    return re.sub(r"[-_.]+", "-", name.strip().lower())


def req_names(text):
    out = set()
    for l in (text or "").splitlines():
        m = re.match(r"^([A-Za-z0-9][A-Za-z0-9_.-]*)\s*(\[[^\]]*\])?\s*(==|>=|<=|~=|!=|<|>|;|$|\\)", l)
        if m:
            out.add(norm_pkg(m.group(1)))
    return out


def lock_unhashed(text):
    """Entries of a pip lock that have no --hash."""
    bad, cur, has = [], None, False
    for l in (text or "").splitlines() + ["end==0"]:
        if re.match(r"^[A-Za-z0-9]", l):
            if cur and not has:
                bad.append(cur)
            cur, has = l.split("==")[0].strip(), "--hash=" in l
        elif "--hash=" in l:
            has = True
    return bad


def npm_deps(text):
    try:
        j = json.loads(text or "{}")
    except ValueError:
        return None
    out = {}
    for k in ("dependencies", "devDependencies", "optionalDependencies", "peerDependencies"):
        out.update(j.get(k) or {})
    return out


def check_dependencies(files, registry):
    """files: {path: (base_text|None, head_text|None)} for changed dependency files. registry: provenance dict or None."""
    title = "New dependencies have a licence / provenance entry and are pinned"
    if not files:
        return check("DEPS", title, NA, ["no dependency, lock, image or workflow file changed"])
    known = {(e.get("ecosystem"), norm_pkg(e.get("name", ""))) for e in (registry or {}).get("entries", []) if e.get("license")}
    findings, ev, unverified = [], [], []
    for path, (bt, ht) in sorted(files.items()):
        base = os.path.basename(path)
        fixture = "/fixtures/" in path or "/tests/" in path
        if ht is None:
            ev.append(f"{path}: deleted")
            continue
        if base.endswith(".lock") and path.startswith("requirements/") or base == "requirements.txt" or base.endswith(".in"):
            new = req_names(ht) - req_names(bt)
            direct = not base.endswith(".lock")
            for n in sorted(new):
                if ("pypi", n) in known:
                    ev.append(f"{path}: new package {n} has a provenance entry")
                elif direct:
                    findings.append(_f("DEP-PROVENANCE", "reject", path, f"new direct dependency '{n}' has no licence/provenance entry in ops/oversight/dependency_provenance.json"))
                else:
                    unverified.append(_f("DEP-PROVENANCE", "unverified", path, f"new locked (transitive) package '{n}' has no licence/provenance entry"))
            if base.endswith(".lock"):
                for n in lock_unhashed(ht):
                    findings.append(_f("DEP-PIN", "reject", path, f"lock entry '{n}' has no --hash"))
        elif base == "package.json":
            b, h = npm_deps(bt) or {}, npm_deps(ht)
            if h is None:
                findings.append(_f("DEP-PROVENANCE", "reject", path, "package.json does not parse"))
                continue
            for n in sorted(h):
                if n not in b and ("npm", norm_pkg(n)) not in known:
                    findings.append(_f("DEP-PROVENANCE", "reject", path, f"new npm dependency '{n}' has no licence/provenance entry"))
                elif n in b and b[n] != h[n]:
                    ev.append(f"{path}: {n} {b[n]} -> {h[n]} (version change; licence must be re-read by the reviewer)")
                if re.search(r"[\^~*xX>]|latest", str(h[n])) and (n not in b or b[n] != h[n]):
                    findings.append(_f("DEP-PIN", "reject", path, f"npm dependency '{n}' is a range ({h[n]}), not an exact version"))
        elif base == "package-lock.json":
            ev.append(f"{path}: lockfile changed (transitive npm packages are not individually checked: UNVERIFIED)")
            unverified.append(_f("DEP-PROVENANCE", "unverified", path, "npm lockfile changed; transitive packages not checked against the provenance register"))
        elif re.match(r"(Dockerfile.*|.*\.dockerfile|docker-compose.*\.ya?ml|compose.*\.ya?ml)$", base) and not fixture:
            old = set(re.findall(r"^\s*(?:FROM|image:)\s+(\S+)", bt or "", re.M | re.I))
            for img in sorted(set(re.findall(r"^\s*(?:FROM|image:)\s+(\S+)", ht, re.M | re.I)) - old):
                if "@sha256:" not in img and img.lower() != "scratch" and not img.startswith("$"):
                    findings.append(_f("DEP-PIN", "reject", path, f"image '{img}' is not pinned by digest"))
        elif path.startswith(".github/workflows/"):
            old = set(re.findall(r"uses:\s*(\S+)", bt or ""))
            for u in sorted(set(re.findall(r"uses:\s*(\S+)", ht)) - old):
                if not u.startswith("./") and not re.search(r"@[0-9a-f]{40}$", u):
                    findings.append(_f("DEP-PIN", "reject", path, f"action '{u}' is not pinned by full commit SHA"))
    if findings:
        return check("DEPS", title, FAIL, findings + unverified, ev)
    if unverified:
        return check("DEPS", title, UNVERIFIED, unverified, ev)
    return check("DEPS", title, PASS, [], ev or ["dependency files changed; no new package, image or action"])


DEP_FILE_RE = re.compile(r"(^requirements\.txt$|^requirements/.*\.(in|lock)$|(^|/)package(-lock)?\.json$|(^|/)Dockerfile[^/]*$|\.dockerfile$|(^|/)(docker-)?compose[^/]*\.ya?ml$|^\.github/workflows/)")


# ------------------------------------------------------------------------------------------- reviewer independence
def check_independent_review(entries, sha, author):
    """entries: verified ledger entries (list of dicts) or None. Rule: a review of THIS head by someone who is not the author."""
    title = "Independent review recorded for this exact head (reviewer is not the author)"
    if entries is None:
        return check("INDEPENDENT-REVIEW", title, UNVERIFIED, ["the oversight ledger could not be read or did not verify"])
    mine = [e for e in entries if e.get("type") == "review" and (e.get("subject") or {}).get("sha") == sha]
    if not mine:
        older = sorted({(e.get("subject") or {}).get("sha", "")[:12] for e in entries if e.get("type") == "review"
                        and author and (e.get("author") or {}).get("id") == author})
        note = f" Reviews exist for other heads by this author: {', '.join(older)}." if older else ""
        return check("INDEPENDENT-REVIEW", title, UNVERIFIED, [f"no review of {sha[:12]} is recorded in the ledger.{note} A new head needs a fresh independent review."])
    findings, ev = [], []
    for e in mine:
        rid, aid = (e.get("reviewer") or {}).get("id"), (e.get("author") or {}).get("id")
        if not rid or not aid or rid == aid or (author and rid == author):
            findings.append({"class": "reject", "msg": f"ledger entry {e.get('id')}: reviewer '{rid}' is the author (self-review)"})
    indep = [e for e in mine if (e.get("reviewer") or {}).get("id") not in (None, (e.get("author") or {}).get("id"), author)]
    if findings and not indep:
        return check("INDEPENDENT-REVIEW", title, FAIL, findings, ev)
    last = indep[-1]
    rec = last.get("recommendation")
    ev.append(f"ledger entry {last.get('id')} seq {last.get('seq')}: reviewer {last['reviewer'].get('id')}, recommendation {rec}"
              + (", IMPORTED (not re-verified)" if last.get("imported") else ""))
    if rec in ("REJECT", "NEEDS_MORE_WORK"):
        n = len(last.get("findings") or [])
        findings.append({"class": "reject", "msg": f"the latest independent review of this head recommends {rec} ({n} finding(s) recorded); they must be fixed or answered, then re-reviewed"})
        return check("INDEPENDENT-REVIEW", title, FAIL, findings, ev)
    if rec != "APPROVE":
        return check("INDEPENDENT-REVIEW", title, UNVERIFIED, [f"latest independent review has no usable recommendation ({rec})"], ev)
    if last.get("imported"):
        return check("INDEPENDENT-REVIEW", title, UNVERIFIED, ["the approving review is an imported report that this function did not re-verify"], ev)
    return check("INDEPENDENT-REVIEW", title, PASS, findings, ev)


def check_production(pr, files):
    """Anything labelled or routed as a production deploy / migration is an owner-reserved decision."""
    title = "Not a production deploy / production migration (owner-reserved)"
    if pr is None:
        return check("PRODUCTION", title, UNVERIFIED, ["PR metadata (labels, base branch, title) could not be read"])
    findings = []
    labels = [l.get("name", "") if isinstance(l, dict) else str(l) for l in pr.get("labels") or []]
    for l in labels:
        if re.search(r"prod|deploy|release|migration", l, re.I):
            findings.append({"class": "owner_gate", "msg": f"label '{l}'"})
    if re.search(r"\b(production|prod)\s+(deploy\w*|migration\w*|release)\b|\bdeploy\s+to\s+(production|prod|railway|render)\b|\bapply\s+to\s+production\b", pr.get("title") or "", re.I):
        findings.append({"class": "owner_gate", "msg": "the PR title announces a production deploy / migration"})
    base = (pr.get("base") or {}).get("ref") or ""
    if base in DEPLOY_BRANCHES:
        findings.append({"class": "owner_gate", "msg": f"base branch {base} is the Railway deploy branch: merging IS a production deploy"})
    pub = AUTO_PUBLISH.get(base)
    if pub and files is not None and any(p.startswith(pub) for p in files):
        n = sum(1 for p in files if p.startswith(pub))
        findings.append({"class": "owner_gate", "msg": f"{n} file(s) under {pub} change and every commit to {base} is published automatically (Render): merging IS a production deploy of the PWA"})
    ev = [f"labels: {labels or 'none'}", f"base: {base}", f"title: {(pr.get('title') or '')[:120]}"]
    return check("PRODUCTION", title, FAIL if findings else PASS, findings, ev)


def check_ledger_append_only(base_text, head_text):
    title = "Oversight ledger is append-only relative to the base"
    if base_text is None and head_text is None:
        return check("LEDGER", title, NA, ["no oversight ledger on the base or the head"])
    if base_text is None:
        return check("LEDGER", title, PASS, [], ["ledger is new on this head"])
    if head_text is None:
        return check("LEDGER", title, FAIL, [{"class": "reject", "msg": "the ledger file is deleted"}])
    if not head_text.startswith(base_text):
        return check("LEDGER", title, FAIL, [{"class": "reject", "msg": "the ledger on the head does not start with the ledger on the base: an entry was edited, deleted or reordered"}])
    return check("LEDGER", title, PASS, [], [f"base ledger ({len(base_text.splitlines())} entries) is a prefix of the head ledger ({len(head_text.splitlines())} entries)"])


# ----------------------------------------------------------------------------------------------- evidence gathering
class Recorder:
    """Runs read-only commands and records each one (argv, exit code, sha256 of stdout) as evidence."""
    WRITE_GIT = {"push", "commit", "merge", "rebase", "reset", "checkout", "switch", "stash", "tag", "branch", "am", "apply", "cherry-pick", "revert", "gc", "prune", "fetch", "pull"}

    def __init__(self, repo):
        self.repo, self.commands = repo, []

    def run(self, argv, cwd=None, timeout=180, env=None):
        try:
            r = subprocess.run(argv, cwd=cwd, capture_output=True, text=True, timeout=timeout, env=env, errors="replace")
            rc, out, err = r.returncode, r.stdout, r.stderr
        except (OSError, subprocess.TimeoutExpired) as e:
            rc, out, err = -1, "", f"{type(e).__name__}: {e}"
        self.commands.append({"argv": [a if len(a) < 200 else a[:200] + "..." for a in argv], "exit": rc,
                              "stdout_sha256": hashlib.sha256(out.encode("utf-8", "replace")).hexdigest(), "stdout_bytes": len(out)})
        return rc, out, err

    def git(self, *args):
        if args and args[0] in self.WRITE_GIT:
            raise RuntimeError(f"engine is read-only: git {args[0]} refused")
        return self.run(["git", "-C", self.repo, *args])

    def show(self, ref, path):
        rc, out, _ = self.git("show", f"{ref}:{path}")
        return out if rc == 0 else None

    def api(self, path):
        """GET only."""
        rc, out, err = self.run(["gh", "api", "-X", "GET", path], timeout=120)
        if rc != 0:
            raise Unavailable(f"gh api {path}: {(err or out).strip()[:200]}")
        try:
            return json.loads(out)
        except ValueError:
            raise Unavailable(f"gh api {path}: not JSON")

    def api_text(self, path):
        rc, out, err = self.run(["gh", "api", "-X", "GET", path], timeout=180)
        if rc != 0:
            raise Unavailable(f"gh api {path}: {(err or out).strip()[:200]}")
        return out


def run_trusted_tools(rec, sha, base_ref, base_sha, base_branch):
    """Lint + bundle check on a throwaway clone of the head, using the BASE ref's copy of each tool (never the head's)."""
    results = {}
    tmp = tempfile.mkdtemp(prefix="oversight_")
    try:
        clone = os.path.join(tmp, "head")
        rc, _, err = rec.run(["git", "clone", "-q", "--shared", "--no-checkout", rec.repo, clone])
        if rc == 0:
            rc, _, err = rec.run(["git", "-C", clone, "-c", "advice.detachedHead=false", "checkout", "-q", "--detach", sha])
        if rc == 0:
            rc, _, err = rec.run(["git", "-C", clone, "update-ref", f"refs/remotes/origin/{base_branch}", base_sha])
        if rc != 0:
            raise Unavailable(f"could not prepare a throwaway clone of {sha[:12]}: {err.strip()[:200]}")
        env = {"PATH": os.environ.get("PATH", "/usr/bin:/bin"), "HOME": tmp, "LANG": "C.UTF-8", "GIT_CONFIG_NOSYSTEM": "1"}
        for name, rel, argv in (("lint", "scripts/lint_migrations.py", [sys.executable, "-I", "scripts/lint_migrations.py", "--base", f"origin/{base_branch}"]),
                                ("bundle", "scripts/build_bundle.sh", ["bash", "scripts/build_bundle.sh", "--check"])):
            trusted = rec.show(base_ref, rel)
            if trusted is None:
                results[name] = {"status": UNVERIFIED, "msg": f"{rel} does not exist on the base ref, so there is no trusted copy to run"}
                continue
            head_copy = rec.show(sha, rel)
            with open(os.path.join(clone, rel), "w") as f:
                f.write(trusted)
            rc, out, err = rec.run(argv, cwd=clone, env=env, timeout=300)
            tail = [l for l in (out + "\n" + err).strip().splitlines() if l.strip()][-8:]
            results[name] = {"status": PASS if rc == 0 else FAIL, "exit": rc, "tail": tail, "tool_modified_by_head": head_copy != trusted,
                             "tool_sha256": sha256_text(trusted)}
    finally:
        shutil.rmtree(tmp, ignore_errors=True)
    return results


def tool_check(cid, title, res, what):
    if res is None:
        return check(cid, title, UNVERIFIED, [f"{what} was not run"])
    if res["status"] == UNVERIFIED:
        return check(cid, title, UNVERIFIED, [res["msg"]])
    ev = [f"exit {res['exit']} (base-ref copy of the tool, sha256 {res['tool_sha256'][:16]})"] + res["tail"]
    notes = []
    if res.get("tool_modified_by_head"):
        notes.append({"class": "note", "msg": "the head modifies this tool; the result above is from the BASE version (the head's own version was not executed)"})
    if res["status"] == FAIL:
        return check(cid, title, FAIL, [{"class": "reject", "msg": f"{what} failed on the head (exit {res['exit']})"}] + notes, ev)
    return check(cid, title, PASS, notes, ev)


def check_acl(files, head_manifests, gate_steps_seen):
    title = "ACL manifest matches the database ACLs (no drift)"
    touches_sql = any(p.startswith("migrations/") and p.endswith(".sql") for p in files or {})
    if not head_manifests:
        if touches_sql:
            return check("ACL", title, UNVERIFIED, ["migrations change but this head has no ops/ACL_MANIFEST*.tsv, so ACL drift cannot be checked mechanically"])
        return check("ACL", title, NA, ["no migration changed and no ACL manifest exists on this head"])
    step = (gate_steps_seen or {}).get("manifest")
    ev = [f"manifest file(s) on head: {', '.join(head_manifests)}"]
    if step and step[0] == "PASS" and "ACL_MANIFEST" in step[1]:
        ev.append("CI gate step 'manifest' PASS: " + step[1][:200])
        return check("ACL", title, PASS, [], ev)
    if step and step[0] != "PASS":
        return check("ACL", title, FAIL, [{"class": "reject", "msg": f"CI gate step 'manifest' is {step[0]}"}], ev)
    return check("ACL", title, UNVERIFIED, ["a manifest exists but no CI evidence that it was compared with a database on this SHA (the engine itself never connects to a database)"], ev)


def load_ledger(path):
    """Verified ledger entries, or None when missing / not verifying."""
    try:
        sys.path.insert(0, HERE)
        import ledger as L
        entries, errs = L.verify_file(path)
        return entries if not errs else None
    except Exception:
        return None


def evaluate(rec, sha, pr_number=None, base_ref=None, repo_slug=None, use_github=True, ledger_path=None, author=None, registry=None):
    """Gather evidence and run every check. Returns the result dict."""
    checks, not_inspected, owner_decisions = [], [], []
    pr, pr_err = None, None
    if use_github and pr_number is not None:
        try:
            pr = rec.api(f"repos/{repo_slug}/pulls/{pr_number}")
        except Unavailable as e:
            pr_err = str(e)
    base_branch = (pr or {}).get("base", {}).get("ref") or (base_ref or "origin/overnight-build").split("/", 1)[-1]
    base_ref = base_ref or f"origin/{base_branch}"

    # -- head identity
    if pr is not None:
        cur = (pr.get("head") or {}).get("sha")
        st = PASS if cur == sha else FAIL
        f = [] if st == PASS else [{"class": "reject", "msg": f"the reviewed SHA {sha[:12]} is not the PR's current head {str(cur)[:12]}: evidence would be stale"}]
        checks.append(check("HEAD", "Reviewed SHA is the PR's current head", st, f, [f"PR #{pr_number} head.sha = {cur}", f"PR state: {pr.get('state')}, draft: {pr.get('draft')}"]))
    else:
        checks.append(check("HEAD", "Reviewed SHA is the PR's current head", UNVERIFIED, [pr_err or "no PR number given or GitHub not consulted"]))

    # -- CI
    runs, logs, gate_seen = None, {}, {}
    if use_github:
        try:
            runs = rec.api(f"repos/{repo_slug}/commits/{sha}/check-runs?per_page=100").get("check_runs")
        except Unavailable:
            runs = None
    checks.append(check_ci(runs, sha))
    for r in runs or []:
        if r.get("head_sha") == sha and r.get("name") in ("unit", "migrations") and r.get("status") == "completed":
            try:
                logs[r["name"]] = rec.api_text(f"repos/{repo_slug}/actions/jobs/{r['id']}/logs")
            except Unavailable:
                not_inspected.append(f"CI log of job {r['name']} ({r['id']}) could not be downloaded")
    g = check_gate_evidence(logs.get("migrations"))
    gate_seen = parse_gate_summary(logs.get("migrations"))[0] if logs.get("migrations") else {}
    checks.append(g)

    # -- diff
    files, diff_ok, merge_base, base_sha = None, False, None, None
    rc, out, _ = rec.git("rev-parse", "--verify", "-q", f"{sha}^{{commit}}")
    rc2, out2, _ = rec.git("rev-parse", "--verify", "-q", f"{base_ref}^{{commit}}")
    if rc == 0 and rc2 == 0:
        base_sha = out2.strip()
        rc, mb, _ = rec.git("merge-base", base_ref, sha)
        if rc == 0:
            merge_base = mb.strip()
            rc, diff, _ = rec.git("diff", "--unified=0", "-M", "--no-color", merge_base, sha)
            if rc == 0:
                files, diff_ok = parse_diff(diff), True
    if not diff_ok:
        why = f"commit {sha[:12]} or base {base_ref} is not in the local repository (run `git fetch origin <branch>` first; the engine does not fetch)"
        for cid, title in (("PROTECTED", "No protected control is touched or weakened"), ("LINT", "Migrations follow the migration lint"),
                           ("BUNDLE", "dist/APPLY_ALL.sql was regenerated"), ("DEPS", "New dependencies have a licence / provenance entry and are pinned"),
                           ("ACL", "ACL manifest matches the database ACLs (no drift)"), ("LEDGER", "Oversight ledger is append-only relative to the base")):
            checks.append(check(cid, title, UNVERIFIED, [why]))
        checks.append(check_production(pr, None))
    else:
        if merge_base != base_sha:
            not_inspected.append(f"the head is not rebased on the base tip: diff taken from merge-base {merge_base[:12]}, base tip is {base_sha[:12]}; "
                                 "interaction with the commits in between was not inspected")
        findings = scan_diff(files)
        findings += check_gitleaksignore(rec.show(merge_base, ".gitleaksignore"), rec.show(sha, ".gitleaksignore")) if ".gitleaksignore" in files else []
        if ".github/CODEOWNERS" in files or "CODEOWNERS" in files:
            findings += check_codeowners(rec.show(merge_base, ".github/CODEOWNERS"), rec.show(sha, ".github/CODEOWNERS"))
        wf = [p for p in files if p.startswith(".github/workflows/")]
        if "scripts/gate.sh" in files or wf:
            findings += check_gate(rec.show(merge_base, "scripts/gate.sh"), rec.show(sha, "scripts/gate.sh"),
                                   {(files[p]["old"] or p): rec.show(merge_base, files[p]["old"] or p) for p in wf if rec.show(merge_base, files[p]["old"] or p) is not None},
                                   {p: rec.show(sha, p) for p in wf if files[p]["status"] != "D"})
        if "scripts/lint_migrations.py" in files:
            findings += check_lint_rules(rec.show(merge_base, "scripts/lint_migrations.py"), rec.show(sha, "scripts/lint_migrations.py"))
        ev = [f"diff {merge_base[:12]}..{sha[:12]}: {len(files)} file(s), {sum(len(d['added']) for d in files.values())} added line(s), {sum(len(d['removed']) for d in files.values())} removed line(s)"]
        checks.append(check("PROTECTED", "No protected control is touched or weakened", FAIL if findings else PASS, findings, ev))

        mig = [p for p in files if p.startswith("migrations/") or p == "dist/APPLY_ALL.sql"]
        tools = None
        try:
            tools = run_trusted_tools(rec, sha, base_ref, base_sha, base_branch)
        except Unavailable as e:
            not_inspected.append(str(e))
        checks.append(tool_check("LINT", "Migrations follow the migration lint", (tools or {}).get("lint"), "scripts/lint_migrations.py"))
        checks.append(tool_check("BUNDLE", "dist/APPLY_ALL.sql was regenerated", (tools or {}).get("bundle"), "scripts/build_bundle.sh --check"))
        dep_files = {p: (None if files[p]["status"] == "A" else rec.show(merge_base, files[p]["old"] or p), None if files[p]["status"] == "D" else rec.show(sha, p))
                     for p in files if DEP_FILE_RE.search(p)}
        checks.append(check_dependencies(dep_files, registry))
        rc, ls, _ = rec.git("ls-tree", "--name-only", sha, "ops/")
        manifests = [l for l in ls.split() if re.match(r"ops/ACL_MANIFEST.*\.tsv$", l)] if rc == 0 else []
        checks.append(check_acl(files, manifests, gate_seen))
        lp = "ops/oversight/ledger/reviews.jsonl"
        checks.append(check_ledger_append_only(rec.show(merge_base, lp), rec.show(sha, lp)))
        checks.append(check_production(pr, files))
        if mig:
            owner_decisions.append(f"{len([p for p in mig if p.startswith('migrations/')])} migration file(s) change: applying them to production is a separate owner release authorization (merging does not apply them)")

    # -- claims and reviewer independence
    claim_text = ((pr or {}).get("title") or "") + "\n" + ((pr or {}).get("body") or "") if pr else None
    checks.append(check_test_claims(claim_text, logs) if pr else check("TEST-CLAIMS", "Claimed test counts match what CI ran", UNVERIFIED, ["PR text could not be read"]))
    entries = load_ledger(ledger_path) if ledger_path else None
    checks.append(check_independent_review(entries, sha, author))

    for c in checks:
        for f in c["findings"]:
            if f.get("class") == "owner_gate":
                owner_decisions.append(f"{c['id']}: {f.get('file') + ': ' if f.get('file') else ''}{f['msg']}")
    fails = [c for c in checks if c["status"] == FAIL]
    unv = [c for c in checks if c["status"] == UNVERIFIED]
    verdict = "REJECT" if fails else "NEEDS_MORE_WORK" if unv else "RECOMMEND_APPROVE"
    not_inspected += ["code behaviour, logic, design and test quality (this engine is mechanical; a human or agent reviewer must read the change)",
                      "the database: no migration was applied and no ACL was read by this engine",
                      "production (Supabase, Railway, Render): never contacted",
                      "licence texts of dependencies (only the presence of a register entry is checked)"]
    with open(os.path.abspath(__file__), "rb") as fh:
        engine_sha = hashlib.sha256(fh.read()).hexdigest()
    return {"schema": "fendezy.oversight.mandatory_checks/1", "engine_version": ENGINE_VERSION, "engine_sha256": engine_sha,
            "generated_at": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
            "subject": {"repo": repo_slug, "pr": pr_number, "head_sha": sha, "base_ref": base_ref, "base_sha": base_sha, "merge_base": merge_base,
                        "author": author, "github_author": ((pr or {}).get("user") or {}).get("login")},
            "verdict": verdict,
            "counts": {s: sum(1 for c in checks if c["status"] == s) for s in (PASS, FAIL, UNVERIFIED, NA)},
            "reject_findings": sum(1 for c in fails for f in c["findings"] if f.get("class") == "reject"),
            "owner_gate_findings": sum(1 for c in fails for f in c["findings"] if f.get("class") == "owner_gate"),
            "checks": checks, "owner_decisions_required": owner_decisions, "not_inspected": not_inspected, "commands": rec.commands,
            "authority": "This result can stop a change (REJECT). It cannot approve one: RECOMMEND_APPROVE is advice to the Owner and to an independent reviewer."}


def summary(res):
    s = res["subject"]
    out = [f"# Mandatory checks: {'PR #' + str(s['pr']) + ' ' if s.get('pr') else ''}@ {s['head_sha']}",
           f"Verdict: **{res['verdict']}**  ({res['counts'][PASS]} pass, {res['counts'][FAIL]} fail, {res['counts'][UNVERIFIED]} unverified, {res['counts'][NA]} n/a; "
           f"{res['reject_findings']} rule violation(s), {res['owner_gate_findings']} protected-control touch(es))",
           f"Base {s['base_ref']} @ {str(s['base_sha'])[:12]}, merge-base {str(s['merge_base'])[:12]}. Engine {res['engine_version']} sha256 {res['engine_sha256'][:16]}. Generated {res['generated_at']}.", ""]
    for c in res["checks"]:
        out.append(f"- **{c['status']}**{' (' + c['class'] + ')' if c['class'] else ''} {c['id']}: {c['title']}")
        by = {}
        for f in c["findings"]:
            by.setdefault((f.get("rule") or "", f.get("class") or "", f["msg"] if not f.get("file") else None), []).append(f)
        shown = 0
        for (rule, klass, msg), fs in by.items():
            if shown >= 14:
                out.append(f"  - ... {len(c['findings']) - shown} more finding(s) in the JSON")
                break
            for f in fs if msg is None else fs[:1]:
                loc = (f.get("file") or "") + (f":{f['line']}" if f.get("line") else "")
                out.append(f"  - [{klass or 'info'}]{' ' + rule if rule else ''} {loc + ': ' if loc else ''}{f['msg']}")
                shown += 1
                if shown >= 14:
                    break
        for e in c["evidence"][:6]:
            out.append(f"  - evidence: {e}")
    if res["owner_decisions_required"]:
        out += ["", f"Owner decisions required ({len(res['owner_decisions_required'])}):"] + [f"- {d}" for d in res["owner_decisions_required"][:25]]
        if len(res["owner_decisions_required"]) > 25:
            out.append(f"- ... {len(res['owner_decisions_required']) - 25} more in the JSON")
    out += ["", "Not inspected by this engine:"] + [f"- {n}" for n in res["not_inspected"]]
    out += ["", f"{len(res['commands'])} read-only command(s) recorded in the JSON (argv, exit code, sha256 of output).", res["authority"]]
    return "\n".join(out) + "\n"


def main(argv=None):
    ap = argparse.ArgumentParser(description="Independent Oversight mandatory checks (read-only).")
    ap.add_argument("--sha", required=True, help="exact 40-hex head SHA under review")
    ap.add_argument("--pr", type=int)
    ap.add_argument("--repo", default=os.environ.get("OVERSIGHT_REPO", "thedonnasystem/JARVIS"))
    ap.add_argument("--repo-dir", default=REPO_ROOT)
    ap.add_argument("--base", help="base ref (default: origin/<PR base branch>, else origin/overnight-build)")
    ap.add_argument("--author", help="identity of the author as recorded in the ledger (agent or person id)")
    ap.add_argument("--ledger", default=os.path.join(HERE, "ledger", "reviews.jsonl"))
    ap.add_argument("--registry", default=os.path.join(HERE, "dependency_provenance.json"))
    ap.add_argument("--no-github", action="store_true", help="do not call the GitHub API (CI / PR checks become UNVERIFIED)")
    ap.add_argument("--out"), ap.add_argument("--summary")
    a = ap.parse_args(argv)
    if not SHA_RE.match(a.sha):
        print("--sha must be the full 40-hex commit SHA (a branch name or short SHA can move)", file=sys.stderr)
        return 3
    registry = None
    try:
        with open(a.registry) as f:
            registry = json.load(f)
    except (OSError, ValueError):
        pass
    res = evaluate(Recorder(a.repo_dir), a.sha, a.pr, a.base, a.repo, not a.no_github, a.ledger, a.author, registry)
    text = json.dumps(res, indent=1, sort_keys=True) + "\n"
    if a.out:
        with open(a.out, "w") as f:
            f.write(text)
    md = summary(res)
    if a.summary:
        with open(a.summary, "w") as f:
            f.write(md)
    print(md if a.out else text, end="")
    return {"RECOMMEND_APPROVE": 0, "REJECT": 1, "NEEDS_MORE_WORK": 2}[res["verdict"]]


if __name__ == "__main__":
    sys.exit(main())
