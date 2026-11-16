#!/usr/bin/env python3
"""Independent Oversight: mandatory-check engine (docs/oversight/CHARTER.md, docs/oversight/RUNBOOK.md). Stdlib only.

Given a PR number and/or a head SHA it gathers evidence mechanically and answers one question: may this change progress
through the internal workflow?  It never merges, pushes, comments, approves, or touches a database or production.

    ops/oversight/mandatory_checks.py --pr 16 --sha <40 hex> --author <author id> [--out result.json] [--summary summary.md]
    ops/oversight/mandatory_checks.py --sha <40 hex> --no-github                                (local evidence only)

Check status
    PASS            evidence was gathered and the rule holds
    FAIL            evidence was gathered and the rule is broken, or a protected control is touched (class owner_gate)
    UNVERIFIED      the check could not be run, its evidence is missing, or the change contains something the engine cannot
                    judge mechanically (finding class human_review). UNVERIFIED IS NEVER A PASS.
    NOT_APPLICABLE  the rule has no subject in this change (stated with the reason)
Finding class
    reject        a mandatory rule is broken. Nothing in the ledger releases it.
    owner_gate    a protected control is touched. Released only by a signed owner decision for this exact head (below).
    owner_only    the owner key list changed. Never released through the ledger: only the Owner can make that change himself.
    human_review  the engine cannot see what the change does (dynamic SQL, ...). Released like owner_gate.
Verdict
    REJECT             at least one FAIL (verdict_reason says whether a rule is broken or only an owner decision is missing)
    NEEDS_MORE_WORK    no FAIL but at least one UNVERIFIED
    RECOMMEND_APPROVE  every check PASS / NOT_APPLICABLE. A recommendation only: it authorises nothing.
Exit code: 0 RECOMMEND_APPROVE, 10 REJECT, 20 NEEDS_MORE_WORK. ANY other code (3 usage, 1 crash, ...) is an engine error:
    treat it as "nothing was verified", never as a verdict, and do not trust an output file left from an earlier run.

Trust rules
    * The only base the engine trusts is its own fixed ref, TRUSTED_REF below. The PR's base branch and --base are never
      used to pick tools or to take the diff; a PR that targets another branch is reported (check BASE), not trusted.
    * Code from the change under review is never executed. The lint and the bundle check are the TRUSTED_REF copies, written
      to a separate temp directory; the head is materialised as data in a throwaway repository (no hooks, no filters,
      symlinks never created) that the engine does not write into. A symlink or a path-escaping APPLY_ORDER entry in the
      tool inputs is refused before any tool runs.
    * The engine file itself is compared with the TRUSTED_REF copy (check ENGINE): a result produced by a different copy
      of the engine is never better than UNVERIFIED.
    * Owner keys are read from TRUSTED_REF, never from the head or the working tree.
    * Nothing is asserted without a recorded command or API call (the `commands` list holds argv, exit code, sha256 of output;
      the outputs themselves are not stored).
    * Matched secret-like text is never echoed (file, line and pattern name only).
"""
import argparse
import collections
import datetime
import hashlib
import io
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import tokenize
import ast

ENGINE_VERSION = "2.0"
PASS, FAIL, UNVERIFIED, NA = "PASS", "FAIL", "UNVERIFIED", "NOT_APPLICABLE"
TRUSTED_BRANCH = "overnight-build"                                    # the ONE protected base. Changing it is a PC-OVERSIGHT change.
TRUSTED_REF = "refs/remotes/origin/" + TRUSTED_BRANCH                 # full ref name: a tag or branch called "origin/..." cannot shadow it
ALLOWED_BASE_ARGS = (TRUSTED_REF, "origin/" + TRUSTED_BRANCH)
REQUIRED_CI_CHECKS = ("unit", "migrations", "secret-scan")           # job names in .github/workflows/tests.yml
CI_APP_SLUG = "github-actions"
REQUIRED_GATE_STEPS = ("unit", "scripts-tests", "lint", "bundle", "appcheck", "replica", "manifest")   # scripts/gate.sh
DEPLOY_BRANCHES = ("claude/telegram-claude-bot-59nusk",)             # Railway deploys every push (DEPLOY_RUNBOOK.md)
AUTO_PUBLISH = {"overnight-build": "webapp/"}                        # Render publishes webapp/ on every commit
RELEASABLE_CHECKS = ("PROTECTED", "PRODUCTION")                      # same list as ledger.RELEASABLE_CHECKS
HERE = os.path.dirname(os.path.abspath(__file__))
REPO_ROOT = os.path.normpath(os.path.join(HERE, "..", ".."))
FP_RE = re.compile(r"^[0-9a-f]{40}:[^:\s*?\[\]]+:[A-Za-z0-9_.-]+:[0-9]+$")       # same rule as scripts/check_gitleaks_ignore.py G1
SHA_RE = re.compile(r"^[0-9a-f]{40}$")
HEX64 = re.compile(r"^[0-9a-f]{64}$")
BLOCKING = ("reject", "owner_gate", "owner_only")


class Unavailable(Exception):
    """Evidence could not be obtained. Always becomes UNVERIFIED, never PASS."""


def sha256_text(s):
    return hashlib.sha256(s.encode("utf-8", "replace")).hexdigest()


def check(cid, title, status, findings=(), evidence=(), klass=None):
    """One check result. klass (for FAIL): 'reject' or 'owner_gate'."""
    findings = [f if isinstance(f, dict) else {"msg": str(f)} for f in findings]
    if status == FAIL and klass is None:
        klass = "owner_gate" if findings and not any(f.get("class") == "reject" for f in findings) \
            and any(f.get("class") in ("owner_gate", "owner_only") for f in findings) else "reject"
    return {"id": cid, "title": title, "status": status, "class": klass if status == FAIL else None,
            "findings": findings, "evidence": [str(e) for e in evidence]}


def status_of(findings):
    """Status of a finding-driven check (PROTECTED, PRODUCTION): any blocking class -> FAIL, else human_review -> UNVERIFIED."""
    classes = {f.get("class") for f in findings}
    return FAIL if classes & set(BLOCKING) else UNVERIFIED if "human_review" in classes else PASS


# ------------------------------------------------------------------------------------------------- diff parsing
def _unquote(s):
    """Undo git's C-style path quoting ("a/x\\303\\251\\ty")."""
    out, i = bytearray(), 0
    b = s.encode("utf-8", "surrogateescape")
    esc = {ord("n"): 10, ord("t"): 9, ord("r"): 13, ord("a"): 7, ord("b"): 8, ord("f"): 12, ord("v"): 11, ord('"'): 34, ord("\\"): 92}
    while i < len(b):
        if b[i] == 92 and i + 1 < len(b):
            if 48 <= b[i + 1] <= 55:
                out.append(int(b[i + 1:i + 4], 8) & 255)
                i += 4
                continue
            out.append(esc.get(b[i + 1], b[i + 1]))
            i += 2
            continue
        out.append(b[i])
        i += 1
    return out.decode("utf-8", "replace")


def _header_paths(line):
    """(old, new) path of a `diff --git` header line. Exact when both sides are the same path (the engine diffs with --no-renames)."""
    rest = line[len("diff --git "):]
    m = re.match(r'^"((?:[^"\\]|\\.)*)" "((?:[^"\\]|\\.)*)"$', rest)
    if m:
        a, b = _unquote(m.group(1)), _unquote(m.group(2))
    else:
        half = (len(rest) - 1) // 2
        if len(rest) % 2 == 1 and rest[half] == " " and rest[:half][2:] == rest[half + 1:][2:]:
            a, b = rest[:half], rest[half + 1:]
        else:
            m = re.match(r'^"?(a/.*?)"? "?(b/.*?)"?$', rest)
            a, b = (m.group(1), m.group(2)) if m else (rest, rest)
    return a[2:] if a.startswith("a/") else a, b[2:] if b.startswith("b/") else b


def _rec():
    return {"status": "M", "added": [], "removed": [], "removed_no": [], "old": None, "old_mode": None, "new_mode": None, "renamed_to": None}


def parse_diff(text):
    """`git diff --unified=0` text -> {path: {"status": A|M|D|T|R|C, "added": [(line_no, text)], "removed": [text], "removed_no": [old line_no],
    "old": path, "old_mode", "new_mode"}}. Hunk bodies are consumed BY COUNT from the @@ header, so an added line that
    itself starts with "++" or a removed line that starts with "--" is never mistaken for a file header. Lines end at "\\n" only."""
    files, cur, lines, i = {}, None, text.split("\n"), 0
    while i < len(lines):
        line = lines[i]
        i += 1
        if line.startswith("diff --git "):
            old, path = _header_paths(line)
            if path in files:                        # git prints a type change (file <-> symlink) as a delete block + an add block
                cur = files[path]
                cur["second_block"] = True
            else:
                cur = files[path] = _rec()
                cur["old"] = old
        elif cur is None:
            continue
        elif line.startswith("new file mode "):
            cur["status"] = "T" if cur.get("second_block") or cur["status"] == "D" else "A"
            cur["new_mode"] = line.split()[-1]
        elif line.startswith("deleted file mode "):
            cur["status"] = "T" if cur["status"] == "A" else "D"
            cur["old_mode"] = line.split()[-1]
        elif line.startswith("old mode "):
            cur["old_mode"] = line.split()[-1]
        elif line.startswith("new mode "):
            cur["new_mode"] = line.split()[-1]
        elif line.startswith("rename from ") or line.startswith("copy from "):
            cur["status"], cur["old"] = ("R" if line.startswith("rename") else "C"), _unquote(line.split(" from ", 1)[1].strip('"'))
        elif line.startswith("@@"):
            m = re.match(r"@@ -(\d+)(?:,(\d+))? \+(\d+)(?:,(\d+))? @@", line)
            if not m:
                continue
            old_no, n_old = int(m.group(1)), int(m.group(2) if m.group(2) is not None else 1)
            new_no, n_new = int(m.group(3)), int(m.group(4) if m.group(4) is not None else 1)
            while i < len(lines) and (n_old or n_new or lines[i].startswith("\\")):
                l = lines[i]
                if l.startswith("-") and n_old:
                    cur["removed"].append(l[1:])
                    cur["removed_no"].append(old_no)
                    old_no, n_old = old_no + 1, n_old - 1
                elif l.startswith("+") and n_new:
                    cur["added"].append((new_no, l[1:]))
                    new_no, n_new = new_no + 1, n_new - 1
                elif not l.startswith("\\"):
                    break
                i += 1
    for d in files.values():
        d.pop("second_block", None)
    return files


def parse_raw(raw):
    """`git diff --raw -z --no-abbrev` -> [(old_mode, new_mode, status_letter, score, path, new_path|None)]."""
    out, parts, i = [], raw.split("\0"), 0
    while i < len(parts):
        m = re.match(r"^:(\d{6}) (\d{6}) [0-9a-f]+ [0-9a-f]+ ([A-Z])(\d*)$", parts[i])
        if not m or i + 1 >= len(parts):
            i += 1
            continue
        two = m.group(3) in ("R", "C")
        out.append((m.group(1), m.group(2), m.group(3), m.group(4), parts[i + 1], parts[i + 2] if two and i + 2 < len(parts) else None))
        i += 3 if two else 2
    return out


def expand_renames(files):
    """A rename seen in patch text (status R) becomes what it is: the OLD path is gone and the NEW path is new."""
    out = {}
    for path, d in files.items():
        out[path] = d
        if d["status"] == "R" and d.get("old") and d["old"] != path and d["old"] not in files:
            gone = _rec()
            gone.update(status="D", old=d["old"], renamed_to=path)
            out[d["old"]] = gone
    return out


# ------------------------------------------------------------------------------------------------- file classes
EVIDENCE_RE = re.compile(r"^ops/oversight/(evidence/[^/]+\.(json|md)|ledger/reviews\.jsonl)$")      # the engine's own committed results and the ledger: data, not code


def is_test_or_doc(path, runtime_tests=()):
    """Files whose lines are not scanned by the control-NAME rules. A test-named file that runtime code refers to is code."""
    if path in runtime_tests:
        return False
    base = os.path.basename(path)
    return (base.startswith("test_") or path.startswith(("sqltests/", "webtests/", "docs/", "scripts/replica/", "scripts/repro/"))
            or "/tests/" in path or "/fixtures/" in path or path.endswith((".md", ".txt", ".tsv", ".log")) or path.startswith("ops/evidence")
            or bool(EVIDENCE_RE.match(path)) or path == "dist/APPLY_ALL.sql")


def is_test_file(path):
    base = os.path.basename(path)
    return (base.startswith("test_") and base.endswith(".py")) or path.startswith(("sqltests/", "webtests/")) or "/tests/" in path


def is_oversight_fixture(path):
    return path in ("scripts/test_oversight_checks.py", "scripts/test_oversight_ledger.py")


HASH_COMMENT_EXT = (".py", ".sh", ".bash", ".yml", ".yaml", ".toml", ".cfg", ".ini", ".in", ".lock", ".txt", ".rb", ".pl")
SLASH_COMMENT_EXT = (".js", ".mjs", ".cjs", ".ts", ".tsx", ".jsx", ".css", ".go", ".java", ".c", ".h", ".rs")


def _comment_guess(path, line):
    """Without the file text: is this single line a comment? '#' is a comment only where the language says so (never in SQL,
    where it is the XOR operator)."""
    s, base = line.lstrip(), os.path.basename(path)
    if path.endswith(".sql"):
        return s.startswith("--")
    if path.endswith(HASH_COMMENT_EXT) or base in ("Procfile", "Dockerfile", "Makefile", ".gitignore", "CODEOWNERS"):
        return s.startswith("#")
    if path.endswith(SLASH_COMMENT_EXT):
        return s.startswith("//")
    return False


def py_comment_lines(text):
    """1-based numbers of lines that hold nothing but a comment, by tokenising (no execution). A '#' line inside a string is code."""
    comment, code = set(), set()
    try:
        for tok in tokenize.generate_tokens(io.StringIO(text).readline):
            if tok.type == tokenize.COMMENT:
                comment.add(tok.start[0])
            elif tok.type not in (tokenize.NL, tokenize.NEWLINE, tokenize.INDENT, tokenize.DEDENT, tokenize.ENDMARKER):
                code.update(range(tok.start[0], tok.end[0] + 1))
    except (tokenize.TokenError, IndentationError, SyntaxError, ValueError):
        return set()                       # does not tokenise: treat nothing as a comment
    return comment - code


# --------------------------------------------------------------------------------------------------------- SQL
_DOLLAR = re.compile(r"\$([A-Za-z_][A-Za-z0-9_]*)?\$")
_IDENT = re.compile(r"^[A-Za-z_][A-Za-z0-9_$]*$")


def _uescape(body):
    """Decode a U&"..." / U&'...' body (default escape character)."""
    body = re.sub(r"\\\+([0-9A-Fa-f]{6})", lambda m: chr(int(m.group(1), 16)) if int(m.group(1), 16) < 0x110000 else "?", body)
    body = re.sub(r"\\([0-9A-Fa-f]{4})", lambda m: chr(int(m.group(1), 16)), body)
    return body.replace("\\\\", "\\")


def sql_scan(text):
    """Tokenise SQL far enough to judge it: returns (statements, code_lines, flags).
    statements  [(start_line, text)]: split at top-level ';', comments removed (also inside $$ bodies, which are kept as code),
                whitespace collapsed, quoted identifiers unquoted when plain ("x" -> x), U&"..." identifiers decoded.
    code_lines  1-based lines that hold something other than whitespace and comments.
    flags       'uescape' (a Unicode-escaped identifier or string is present), 'unterminated' (string/comment/body never closed)."""
    stmts, code_lines, flags, buf, dollars = [], set(), set(), [], []
    i, n, line, start = 0, len(text), 1, None

    def put(s, at):
        nonlocal start
        if s.strip():
            code_lines.add(at)
            if start is None:
                start = at
        buf.append(s)

    def emit():
        nonlocal start
        s = re.sub(r"\s+", " ", "".join(buf)).strip()
        if s:
            stmts.append((start or line, s))
        buf.clear()
        start = None

    while i < n:
        c, two = text[i], text[i:i + 2]
        if two == "--":
            j = text.find("\n", i)
            i = n if j < 0 else j
            buf.append(" ")
        elif two == "/*":
            depth, j = 1, i + 2
            while j < n and depth:
                if text[j:j + 2] == "/*":
                    depth, j = depth + 1, j + 2
                elif text[j:j + 2] == "*/":
                    depth, j = depth - 1, j + 2
                else:
                    line += text[j] == "\n"
                    j += 1
            if depth:
                flags.add("unterminated")
            i = j
            buf.append(" ")
        elif c == "'":
            prev = "".join(buf)[-2:]
            esc = prev[-1:] in ("e", "E") and not (prev[:-1][-1:].isalnum() or prev[:-1][-1:] == "_")
            if prev.lower() == "u&":
                flags.add("uescape")
            j, at = i + 1, line
            while j < n:
                if esc and text[j] == "\\":
                    j += 2
                    continue
                if text[j] == "'":
                    if text[j + 1:j + 2] == "'":
                        j += 2
                        continue
                    break
                line += text[j] == "\n"
                j += 1
            if j >= n:
                flags.add("unterminated")
            put(text[i:j + 1], at)
            i = j + 1
        elif c == '"':
            j, at = i + 1, line
            while j < n:
                if text[j] == '"':
                    if text[j + 1:j + 2] == '"':
                        j += 2
                        continue
                    break
                line += text[j] == "\n"
                j += 1
            if j >= n:
                flags.add("unterminated")
            name = text[i + 1:j].replace('""', '"')
            if "".join(buf)[-2:].lower() == "u&":
                flags.add("uescape")
                tail = "".join(buf)[:-2]
                buf.clear()
                buf.append(tail)
                name = _uescape(name)
            put(name if _IDENT.match(name) else '"' + name + '"', at)
            i = j + 1
        elif c == "$" and _DOLLAR.match(text, i) and not (i and (text[i - 1].isalnum() or text[i - 1] == "_")):
            tag = _DOLLAR.match(text, i).group(0)
            if dollars and dollars[-1] == tag:
                dollars.pop()
            else:
                dollars.append(tag)
            buf.append(" ")
            code_lines.add(line)
            i += len(tag)
        elif c == ";" and not dollars:
            emit()
            i += 1
        else:
            put(c, line)
            line += c == "\n"
            i += 1
    if dollars:
        flags.add("unterminated")
    emit()
    return stmts, code_lines, flags


def new_statements(base_stmts, head_stmts):
    """Statements of head that are not in base (multiset difference on the normalised text)."""
    left = collections.Counter(s for _, s in base_stmts)
    out = []
    for at, s in head_stmts:
        if left[s] > 0:
            left[s] -= 1
        else:
            out.append((at, s))
    return out


# --------------------------------------------------------------------------------------- protected controls (diff)
# NAME rules: (id, class, pattern, what). Tested on added AND removed lines of non-test code, and on new / removed SQL statements.
NAME_RULES = [
    ("PC-SPEND", "owner_gate", r"daily_spend_cap_cents|day_cap_cents|spend_cap|reserve_llm_budget|settle_spend|settle_llm|hard_max|budget_cents|cap_cents|limit_cents|max_cents",
     "spend cap / spend gateway / financial limit ($3.30 per day cap, budgets)"),
    ("PC-KILL", "owner_gate", r"kill_switch|killswitch", "kill switch"),
    ("PC-EXEC", "owner_gate", r"executor_registry", "executor registry / executor registration"),
    ("PC-DRYRUN", "owner_gate", r"\bdry_run\b|\bdry-run\b|mode\s*(=|in)\s*\(?\s*'live'|\bmode['\"]?\s*(=|:=|:|==|!=|<>)\s*['\"](?!dry_run['\"])[a-z_]{3,}['\"]"
                                r"|['\"](live|auto_in_caps|exceptions_only|approve_first)['\"]",
     "dry_run flag / operating mode (any value other than dry_run)"),
    ("PC-STATE", "owner_gate", r"(patch|post|put|delete|update|upsert|insert)\w*\b[^#\n]{0,80}\bsystem_state\b|\bsystem_state\b[^#\n]{0,40}\b(patch|update|upsert|insert|delete)",
     "system_state written (it holds the mode, the kill switch and the company cap)"),
    ("PC-OUTREACH", "owner_gate", r"outreach|\bconsent|suppress(ion|ed)|opt[_-]?out|unsubscrib|do[_-]not[_-]contact|smtplib|\bsmtp\b|twilio|sendgrid|mailgun|send_(email|mail|sms)"
                                  r"|\bchannels?\s+in\s*\(|\bchannel\b[^;]{0,60}\bcheck\s*\(",
     "outreach / consent / suppression / message channels (who may be contacted, and how)"),
]
# STATEMENT rules for SQL: (id, class, side, pattern, what). '+' = statements new on the head, '-' = statements gone from the base.
STMT_RULES = [
    ("PC-EXEC-WRITE", "reject", "+", r"(insert\s+into|update|delete\s+from|truncate(\s+table)?|grant\s+(?!select\b)[a-z, ]+\s+on(\s+table)?)\s+(only\s+)?(public\.)?executor_registry",
     "executor registry written or opened (it must stay empty and owner-only)"),
    ("PC-PERM-RELAX", "reject", "+", r"disable\s+row\s+level\s+security|no\s+force\s+row\s+level\s+security|\bbypassrls\b|using\s*\(\s*true\s*\)|with\s+check\s*\(\s*true\s*\)"
                                    r"|grant\s+all\b|grant\s+[^;]*\bto\s+[^;]*\bpublic\b|\bsuperuser\b",
     "permission relaxation (RLS off, bypassrls, policy 'true', grant all / to public)"),
    ("PC-PERM-OPEN", "owner_gate", "+", r"grant\s+[^;]*\bto\b[^;]*\b(anon|authenticated)\b", "grant to an API role (anon / authenticated)"),
    ("PC-PERM", "owner_gate", "+", r"\bgrant\s|security\s+definer|create\s+policy|alter\s+policy|alter\s+default\s+privileges|(create|alter|drop)\s+role\b"
                                  r"|\bset\s+(local\s+|session\s+)?role\b|\bowner\s+to\b|set\s+session\s+authorization",
     "permissions model (grant, SECURITY DEFINER, policy, role, default privileges)"),
    ("PC-STATE", "owner_gate", "+", r"(update|insert\s+into|delete\s+from|truncate(\s+table)?|alter\s+table(\s+if\s+exists)?)\s+(only\s+)?(public\.)?system_state\b",
     "system_state written or altered (it holds the mode, the kill switch and the company cap)"),
    ("PC-DRYRUN", "owner_gate", "+", r"\bset\s+mode\s*=\s*(?!'dry_run')|\bmode\b[^,;()]{0,60}\bdefault\b|alter\s+column\s+mode\b",
     "operating mode set or its default changed (anything other than dry_run)"),
    ("PC-DYNSQL", "human_review", "+", r"\bexecute\s+(?!on\b|function\b|procedure\b)|\bquote_(ident|literal|nullable)\s*\(|\bdblink|\bquery_to_xml|\bprepare\s+\w+",
     "dynamic SQL: the statement text is built at run time, so the rules above cannot see what it touches. A person must read it"),
    ("PC-PERM-REMOVED", "owner_gate", "-", r"\brevoke\s|enable\s+row\s+level\s+security|force\s+row\s+level\s+security", "a revoke / RLS statement was removed"),
]
SECRET_RULES = [   # never echo the match
    ("anthropic-key", r"sk-ant-[A-Za-z0-9_-]{20,}"), ("github-token", r"gh[pousr]_[A-Za-z0-9]{36,}|github_pat_[A-Za-z0-9_]{40,}"),
    ("aws-access-key", r"\bAKIA[0-9A-Z]{16}\b"), ("private-key", r"-----BEGIN [A-Z ]*PRIVATE KEY-----"),
    ("jwt", r"\beyJ[A-Za-z0-9_-]{15,}\.eyJ[A-Za-z0-9_-]{15,}\.[A-Za-z0-9_-]{10,}"), ("telegram-bot-token", r"\b\d{8,10}:AA[A-Za-z0-9_-]{33}\b"),
    ("supabase-token", r"\bsbp_[a-f0-9]{40}\b"), ("slack-token", r"\bxox[bap]-[A-Za-z0-9-]{20,}"), ("stripe-live-key", r"\b[sr]k_live_[A-Za-z0-9]{20,}"),
]
# files the gate runs or relies on (scripts/gate.sh, .github/workflows/tests.yml). A change is an owner gate; deletion or gutting is a reject.
GUARD_TOOLS = ("scripts/lint_migrations.py", "scripts/check_workflow_pins.py", "scripts/check_gitleaks_ignore.py", "scripts/check_app_rpcs.py",
               "scripts/function_manifest.py", "scripts/build_bundle.sh", "scripts/gate.sh", "scripts/gitleaks_ignore_audit.json",
               "scripts/backup_drill.sh", "scripts/backup_drill.py", "scripts/backup_put_e2e.py")
GUARD_PREFIXES = ("scripts/replica/",)
PROTECTED_TESTS = ("test_no_bypass.py", "test_spend_paths.py", "test_audit_paths.py")
CODEOWNERS_PATHS = (".github/CODEOWNERS", "CODEOWNERS", "docs/CODEOWNERS")
DEPLOY_SURFACE = re.compile(r"^(Procfile|requirements\.txt|runtime\.txt|\.python-version|nixpacks\.toml|railway\.(json|toml)|render\.ya?ml|Dockerfile)$")
OWNER_KEYS_PATH = "ops/oversight/owner_keys.json"
LEDGER_PATH = "ops/oversight/ledger/reviews.jsonl"
OVERSIGHT_PROTECTED = re.compile(r"^(ops/oversight/(?!ledger/reviews\.jsonl$|evidence/[^/]+\.(json|md)$)|docs/oversight/CHARTER\.md$|scripts/test_oversight_[^/]*\.py$)")
SKIP_RE = re.compile(r"@\s*(unittest\s*\.\s*)?(skip|skipIf|skipUnless|expectedFailure)\b|\bSkipTest\b|\.skipTest\s*\(|pytest\s*\.\s*(mark\s*\.\s*)?(skip|xfail)"
                     r"|\b(it|test|describe)\s*\.\s*(skip|todo|only)\s*\(|\bx(it|describe)\s*\(")
EXTERNAL_CODE_RE = re.compile(r"<script\b[^>]*\bsrc\s*=\s*[\"']?\s*(https?:)?//|<link\b[^>]*\bhref\s*=\s*[\"']?\s*(https?:)?//|\bimport\b[^;\n]*[\"']https?://"
                              r"|importScripts\s*\(\s*[\"']https?:", re.I)
GUT_MIN_LINES, GUT_SHARE = 10, 0.3


def _f(rule, klass, path, msg, line=None):
    d = {"rule": rule, "class": klass, "file": path, "msg": msg}
    if line:
        d["line"] = line
    return d


def is_guard(path):
    return path in GUARD_TOOLS or path.startswith(GUARD_PREFIXES)


def is_control_test(path):
    return os.path.basename(path) in PROTECTED_TESTS or path.startswith("sqltests/")


def _gutted(d, base_text):
    """A large NET deletion: the file lost at least GUT_MIN_LINES lines and at least GUT_SHARE of what it had."""
    net = len(d["removed"]) - len(d["added"])
    had = len(base_text.split("\n")) if base_text is not None else None
    return net >= GUT_MIN_LINES and (had is None or net >= GUT_SHARE * had)


def scan_diff(files, texts=None, runtime_tests=()):
    """Protected-control and secret findings from a parsed diff.
    texts: {path: (base_text|None, head_text|None)} when the caller has the file contents (the engine always does for code
    and SQL). Without them the added / removed lines stand in for the head / base text."""
    out, texts = [], texts or {}
    files = expand_renames(files)
    for path, d in sorted(files.items()):
        code = not is_test_or_doc(path, runtime_tests)
        sql = code and path.endswith(".sql")
        bt, ht = texts.get(path, (None, None))
        st = d["status"]
        gone = st == "D"
        moved = f" (moved to {d['renamed_to']})" if d.get("renamed_to") else ""

        # ---- lines: control names in non-test code, comment-aware per language
        if code:
            add_c = rem_c = None
            if path.endswith(".py"):
                add_c = py_comment_lines(ht) if ht is not None else None
                rem_c = py_comment_lines(bt) if bt is not None else None
            elif sql:
                add_c = (set(range(1, len(ht.split("\n")) + 2)) - sql_scan(ht)[1]) if ht is not None else None
                rem_c = (set(range(1, len(bt.split("\n")) + 2)) - sql_scan(bt)[1]) if bt is not None else None
            added = [(n, t) for n, t in d["added"] if (n not in add_c if add_c is not None else not _comment_guess(path, t))]
            removed = [t for n, t in zip(d["removed_no"] or [0] * len(d["removed"]), d["removed"])
                       if (n not in rem_c if rem_c is not None and n else not _comment_guess(path, t))]
            for rid, klass, pat, what in NAME_RULES:
                rx = re.compile(pat, re.I)
                hits = [n for n, t in added if rx.search(t)]
                gone_n = sum(1 for t in removed if rx.search(t))
                if hits or gone_n:
                    out.append(_f(rid, klass, path, f"{what}: {len(hits)} added line(s)" + (f", {gone_n} removed line(s)" if gone_n else ""), hits[0] if hits else None))

        # ---- SQL statements: structure rules on whole statements, so line breaks, comments and quoting do not matter
        if sql:
            first = d["added"][0][0] if d["added"] else None
            head_sql = ht if ht is not None else "\n".join(t for _, t in d["added"])
            base_sql = bt if bt is not None else "\n".join(d["removed"])
            hs, _, hflags = sql_scan(head_sql)
            bs, _, _ = sql_scan(base_sql)
            fresh, dropped = new_statements(bs, hs), new_statements(hs, bs)
            at = (lambda n: n) if ht is not None else (lambda n: first)
            for rid, klass, side, pat, what in STMT_RULES:
                rx = re.compile(pat, re.I)
                hit = [n for n, s in (fresh if side == "+" else dropped) if rx.search(s)]
                if hit:
                    out.append(_f(rid, klass, path, f"{what}: {len(hit)} {'new' if side == '+' else 'removed'} statement(s)", at(hit[0]) if side == "+" else None))
            for rid, klass, pat, what in NAME_RULES:       # names again on whole statements: catches "quoted" and U&"..." spellings
                rx = re.compile(pat, re.I)
                hit = [n for n, s in fresh if rx.search(s)]
                lost = sum(1 for _, s in dropped if rx.search(s))
                if (hit or lost) and not any(f["rule"] == rid and f["file"] == path for f in out):
                    out.append(_f(rid, klass, path, f"{what}: {len(hit)} new statement(s)" + (f", {lost} removed statement(s)" if lost else ""), at(hit[0]) if hit else None))
            if "uescape" in hflags and fresh:
                out.append(_f("PC-OBFUSCATION", "reject", path, "a Unicode-escaped identifier or string (U&\"...\" / U&'...') hides a name from review; write the plain name", first))
            if "unterminated" in hflags and fresh:
                out.append(_f("PC-UNPARSED", "human_review", path, "the SQL does not tokenise cleanly (a string, comment or $$ body never closes): the statement rules may have missed something", first))

        # ---- secrets, everywhere except the two fixture files that assemble look-alikes
        if not is_oversight_fixture(path):
            for name, pat in SECRET_RULES:
                lines = [n for n, t in d["added"] if re.search(pat, t)]
                if lines:
                    out.append(_f("PC-SECRET", "reject", path, f"secret-like value ({name}) on {len(lines)} added line(s); value not shown", lines[0]))

        # ---- file kind: symlinks, submodules, attributes
        if d.get("new_mode") == "120000":
            out.append(_f("PC-SYMLINK", "reject", path, "a symbolic link is added (or a file is turned into one): tools and CI would follow it out of the repository"))
        if d.get("new_mode") == "160000" or path == ".gitmodules":
            out.append(_f("PC-SUBMODULE", "owner_gate", path, "a git submodule is added or changed: code from another repository (supply chain)"))
        if os.path.basename(path) == ".gitattributes":
            out.append(_f("PC-GITATTR", "owner_gate", path, "git attributes changed (filters, diff and export rules decide what tools and reviewers see)"))

        # ---- gate / guard tools, CI, secret scan
        if is_guard(path):
            how = "DELETED" + moved if gone else "gutted (large net deletion)" if _gutted(d, bt) else {"A": "added", "T": "changed type"}.get(st, "modified")
            out.append(_f("PC-GUARD", "reject" if gone or _gutted(d, bt) else "owner_gate", path, "a lint / gate / guard tool is " + how))
        if path.startswith(".github/workflows/"):
            out.append(_f("PC-WORKFLOW", "reject" if gone else "owner_gate", path, "CI workflow " + ("deleted" + moved if gone else "changed")))
        elif path == ".github/dependabot.yml":
            out.append(_f("PC-DEPENDABOT", "reject" if gone else "owner_gate", path, "dependency update configuration " + ("deleted" + moved if gone else "changed")))
        elif path.startswith(".github/") and path not in CODEOWNERS_PATHS:
            out.append(_f("PC-GITHUB", "owner_gate", path, "a file under .github/ (actions, templates, settings) " + ("deleted" + moved if gone else "changed")))
        if path == ".gitleaks.toml":
            out.append(_f("PC-GITLEAKS", "reject" if gone else "owner_gate", path, "secret-scan configuration " + ("deleted" + moved if gone else "changed")))
            if any(re.search(r"^\s*(commits|disabledRules|stopwords)\s*=|useDefault\s*=\s*false", t) for _, t in d["added"]):
                out.append(_f("PC-GITLEAKS", "reject", path, "broad secret-scan suppression (commits / disabledRules / stopwords / useDefault=false)"))

        # ---- tests
        if is_test_file(path) or is_control_test(path):
            control = is_control_test(path)
            if gone:
                out.append(_f("PC-TESTS", "reject" if control else "owner_gate", path, ("a control test file is deleted" if control else "a test file is deleted") + moved))
            elif _gutted(d, bt):
                out.append(_f("PC-TESTS", "reject" if control else "owner_gate", path, f"a test file is gutted: {len(d['removed'])} line(s) removed, {len(d['added'])} added"))
            elif control and d["removed"]:
                out.append(_f("PC-TESTS", "owner_gate", path, f"{len(d['removed'])} line(s) removed from a spend / bypass / audit / SQL control test"))
            skips = [n for n, t in d["added"] if SKIP_RE.search(t)]
            if skips and not gone:
                out.append(_f("PC-TESTS", "reject" if control else "owner_gate", path, f"{len(skips)} added line(s) skip, disable or narrow tests (skip / skipIf / xfail / .only)", skips[0]))
            if path in runtime_tests:
                out.append(_f("PC-TESTS", "owner_gate", path, "this file is named like a test but runtime code refers to it, so it was scanned as code"))

        # ---- external code pulled into the web app
        if path.startswith("webapp/") or path.endswith((".html", ".htm")):
            ext = [(n, t) for n, t in d["added"] if EXTERNAL_CODE_RE.search(t)]
            if ext:
                bare = [n for n, t in ext if "integrity=" not in t]
                out.append(_f("PC-EXTERNAL", "reject" if bare else "owner_gate", path,
                              f"{len(ext)} added line(s) load code or styles from another origin" + (" without an integrity hash" if bare else " (integrity hash present)"), ext[0][0]))

        if DEPLOY_SURFACE.match(path):
            out.append(_f("PC-DEPLOY", "owner_gate", path, "deploy surface (what Railway / Render builds) " + ("deleted" + moved if gone else "changed")))
        if path == OWNER_KEYS_PATH:
            out.append(_f("PC-OWNER-KEYS", "owner_only", path, "the owner key list changed. No ledger entry can release this: only the Owner may make this change, "
                                                              "by committing it himself, and a key counts only once it is on the trusted branch"))
        elif OVERSIGHT_PROTECTED.search(path):
            out.append(_f("PC-OVERSIGHT", "owner_gate", path, "the oversight function's own rules, engine or tests changed (it cannot approve its own permission changes)"))
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


def codeowners_entries(text):
    """[(pattern, {owners})] in file order (GitHub applies the LAST matching pattern)."""
    out = []
    for l in (text or "").splitlines():
        l = l.split("#", 1)[0].split()
        if len(l) >= 2:
            out.append((l[0], set(l[1:])))
    return out


def parse_codeowners(text):
    return dict(codeowners_entries(text))


def check_codeowners(base_text, head_text):
    if base_text is None:
        return [] if head_text is None else [_f("PC-CODEOWNERS", "owner_gate", ".github/CODEOWNERS", "a CODEOWNERS file is added")]
    if head_text is None:
        return [_f("PC-CODEOWNERS", "reject", ".github/CODEOWNERS", "CODEOWNERS deleted or moved away")]
    base, head, out = parse_codeowners(base_text), parse_codeowners(head_text), []
    for p, owners in sorted(base.items()):
        if p not in head:
            out.append(_f("PC-CODEOWNERS", "reject", ".github/CODEOWNERS", f"protected path {p} removed"))
        elif not owners <= head[p]:
            out.append(_f("PC-CODEOWNERS", "reject", ".github/CODEOWNERS", f"owner(s) removed from {p}"))
        elif owners != head[p]:
            out.append(_f("PC-CODEOWNERS", "owner_gate", ".github/CODEOWNERS", f"owner(s) added to {p}"))
    for p in sorted(set(head) - set(base)):
        out.append(_f("PC-CODEOWNERS", "owner_gate", ".github/CODEOWNERS", f"new entry {p} (the last matching pattern wins: check that it does not override a protected path)"))
    kept = [p for p, _ in codeowners_entries(head_text) if p in base]
    if kept != [p for p, _ in codeowners_entries(base_text) if p in head] or len(kept) != len(set(kept)):
        out.append(_f("PC-CODEOWNERS", "reject", ".github/CODEOWNERS", "the order of existing entries changed or an entry is duplicated (the last matching pattern wins, so order is ownership)"))
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
            out.append(_f("PC-GATE", "reject", "scripts/gate.sh", "gate script deleted or moved away"))
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
    except (SyntaxError, ValueError):
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
        return [_f("PC-LINT", "reject", "scripts/lint_migrations.py", "migration linter deleted or moved away")]
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
    """check_runs: list of GitHub check-run objects for the commit, or None when the API could not be read.
    A required check counts only when GitHub Actions itself produced it (app slug), so another app cannot post a look-alike."""
    title = "CI green on the exact head SHA"
    if check_runs is None:
        return check("CI", title, UNVERIFIED, ["check-runs could not be read from GitHub"])
    findings, ev, latest = [], [], {}
    for r in check_runs:
        if r.get("head_sha") != sha:
            findings.append({"class": "reject", "msg": f"check-run {r.get('name')} belongs to {r.get('head_sha')}, not the reviewed SHA"})
            continue
        if r.get("name") in required and (r.get("app") or {}).get("slug") != CI_APP_SLUG:
            findings.append({"class": "note", "msg": f"a check-run named '{r.get('name')}' from app '{(r.get('app') or {}).get('slug')}' was ignored (only {CI_APP_SLUG} counts)"})
            continue
        if r.get("name") not in latest or (r.get("id") or 0) > (latest[r["name"]].get("id") or 0):
            latest[r["name"]] = r
    bad = False
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
            continue
        bad = True
    for name, r in sorted(latest.items()):
        if name not in required and r.get("status") == "completed" and r.get("conclusion") not in ("success", "neutral", "skipped"):
            findings.append({"class": "reject", "msg": f"check '{name}' concluded {r.get('conclusion')}"})
            bad = True
    bad = bad or any(f["class"] == "reject" for f in findings)
    return check("CI", title, FAIL if bad else PASS, findings, ev)


def latest_runs(check_runs, sha, names):
    """The newest GitHub Actions check-run per name for this SHA: the SAME run that check_ci judges is the one whose log is read."""
    out = {}
    for r in check_runs or []:
        if r.get("head_sha") == sha and r.get("name") in names and (r.get("app") or {}).get("slug") == CI_APP_SLUG:
            if r["name"] not in out or (r.get("id") or 0) > (out[r["name"]].get("id") or 0):
                out[r["name"]] = r
    return out


_TS = re.compile(r"^\d{4}-\d\d-\d\dT[\d:.]+Z\s?")


def parse_gate_summary(log):
    """GATE SUMMARY block(s) of scripts/gate.sh from a CI log -> ({step: result} of the last block, verdict line or None, number of blocks)."""
    steps, verdict, on, blocks = {}, None, False, 0
    for raw in (log or "").split("\n"):
        l = _TS.sub("", raw.rstrip("\r"))
        if "GATE SUMMARY" in l:
            on, steps, verdict, blocks = True, {}, None, blocks + 1
        elif on:
            m = re.match(r"^([a-z][a-z0-9-]*)\s+(PASS|FAIL|SKIPPED)\b\s*(.*)$", l)
            if m:
                steps[m.group(1)] = (m.group(2), m.group(3))
            elif l.startswith("GATE "):
                verdict, on = l.strip(), False
    return steps, verdict, blocks


def check_gate_evidence(log, required=REQUIRED_GATE_STEPS):
    title = "Full gate (scripts/gate.sh --strict) ran and passed in CI on this SHA"
    if log is None:
        return check("GATE-EVIDENCE", title, UNVERIFIED, ["the log of the CI job 'migrations' could not be read"])
    steps, verdict, blocks = parse_gate_summary(log)
    if not steps:
        return check("GATE-EVIDENCE", title, UNVERIFIED, ["no GATE SUMMARY block found in the CI log"])
    findings = []
    if blocks != 1:
        findings.append({"class": "reject", "msg": f"the CI log holds {blocks} GATE SUMMARY blocks; exactly one is expected (a second one can be printed by code under test)"})
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
RAN_RE = re.compile(r"^\s*Ran (\d+) tests? in\b")
RESULT_RE = re.compile(r"^\s*(OK|FAILED)\b\s*(?:\((.*)\))?\s*$")


def parse_test_runs(log):
    """unittest runs printed in a CI log -> [{"ran": N, "result": "OK"|"FAILED"|None, "skipped": K}]. The result line is the first
    non-empty line after "Ran N tests in"."""
    runs, lines = [], [_TS.sub("", l.rstrip("\r")) for l in (log or "").split("\n")]
    for i, l in enumerate(lines):
        m = RAN_RE.match(l)
        if not m:
            continue
        run = {"ran": int(m.group(1)), "result": None, "skipped": 0}
        for nxt in lines[i + 1:i + 6]:
            if nxt.strip():
                r = RESULT_RE.match(nxt)
                if r:
                    run["result"] = r.group(1)
                    sk = re.search(r"skipped=(\d+)", r.group(2) or "")
                    run["skipped"] = int(sk.group(1)) if sk else 0
                    run["detail"] = r.group(2) or ""
                break
        runs.append(run)
    return runs


def check_test_results(logs, jobs=("unit", "migrations")):
    """What the CI test runs actually did on this SHA: ran, none failed, none skipped. logs: {job: text} or None."""
    title = "CI ran the tests on this SHA: none failed, none skipped"
    if not logs:
        return check("TEST-RESULTS", title, UNVERIFIED, ["no CI log could be read"])
    findings, ev, unv = [], [], False
    for job in jobs:
        if job not in logs:
            findings.append({"class": "unverified", "msg": f"the log of CI job '{job}' was not read"})
            unv = True
            continue
        runs = parse_test_runs(logs[job])
        if not runs:
            findings.append({"class": "unverified", "msg": f"CI job '{job}': no 'Ran N tests' line in the log"})
            unv = True
        for r in runs:
            ev.append(f"{job}: Ran {r['ran']} tests: {r['result'] or 'no result line'}" + (f" ({r['detail']})" if r.get("detail") else ""))
            if r["result"] == "FAILED":
                findings.append({"class": "reject", "msg": f"CI job '{job}': a run of {r['ran']} tests FAILED ({r.get('detail', '')})"})
            elif r["result"] is None:
                findings.append({"class": "unverified", "msg": f"CI job '{job}': the run of {r['ran']} tests has no OK / FAILED line"})
                unv = True
            elif r["skipped"]:
                findings.append({"class": "unverified", "msg": f"CI job '{job}': {r['skipped']} of {r['ran']} tests were SKIPPED. 'OK (skipped=N)' is not a clean pass: "
                                                             "someone must confirm each skip is intended"})
                unv = True
            elif r["ran"] == 0:
                findings.append({"class": "unverified", "msg": f"CI job '{job}': a run of 0 tests"})
                unv = True
    if any(f["class"] == "reject" for f in findings):
        return check("TEST-RESULTS", title, FAIL, findings, ev)
    return check("TEST-RESULTS", title, UNVERIFIED if unv else PASS, findings, ev)


def check_test_claims(claim_text, logs):
    """Counts claimed in the PR text ("736 tests") vs the counts each CI job printed ("Ran 736 tests in"). logs: {job: text} or None.
    A claim matches a single run or the sum of one job's runs. A claim that matches nothing is UNVERIFIED, not PASS: either it
    is wrong or it is about a suite whose count CI does not print (scripts/test_*.py, sqltests, webtests)."""
    title = "Test counts claimed in the PR text match what CI printed"
    claims = sorted({int(n) for n in CLAIM_RE.findall(claim_text or "")})
    if not claims:
        return check("TEST-CLAIMS", title, NA, ["no 'N tests' claim in the PR title/body, so there is nothing to compare (the results themselves are check TEST-RESULTS)"])
    if not logs:
        return check("TEST-CLAIMS", title, UNVERIFIED, [f"claims {claims} found but no CI log could be read"])
    per_job = {job: [r["ran"] for r in parse_test_runs(t)] for job, t in sorted(logs.items())}
    if not any(per_job.values()):
        return check("TEST-CLAIMS", title, UNVERIFIED, [f"claims {claims} found but no 'Ran N tests' line in the CI logs"])
    known = {n for ns in per_job.values() for n in ns} | {sum(ns) for ns in per_job.values() if ns}
    ev = [f"CI job {job} printed: {ns}" for job, ns in per_job.items()] + [f"claimed in PR text: {claims}"]
    extra = [c for c in claims if c not in known]
    if extra:
        return check("TEST-CLAIMS", title, UNVERIFIED, [{"class": "unverified", "msg": f"claimed count(s) {extra} match no count printed by CI on this SHA ({sorted(known)}). "
                     "Either the claim is wrong or it is about a suite whose count CI does not print; a reviewer must check it"}], ev)
    return check("TEST-CLAIMS", title, PASS, [], ev)


# ------------------------------------------------------------------------------------------------- dependencies
def norm_pkg(name):
    return re.sub(r"[-_.]+", "-", name.strip().lower())


def req_names(text):
    out = set()
    for l in (text or "").splitlines():
        m = re.match(r"^([A-Za-z0-9][A-Za-z0-9_.-]*)\s*(\[[^\]]*\])?\s*(==|>=|<=|~=|!=|<|>|;|@|$|\\)", l)
        if m:
            out.add(norm_pkg(m.group(1)))
    return out


REQ_SOURCE_RE = re.compile(r"^(-i\b|--index-url|--extra-index-url|-f\b|--find-links|--trusted-host|-e\b|--editable|--pre\b|-r\b|--requirement|-c\b|--constraint)"
                           r"|://|^[A-Za-z0-9][A-Za-z0-9_.-]*\s*(\[[^\]]*\])?\s*@|^(\.{0,2}/|git\+|file:)", re.I)


def req_sources(text):
    """Requirement lines that change WHERE packages come from: another index, a URL, a VCS or local path, an include."""
    out = set()
    for l in (text or "").splitlines():
        l = re.sub(r"(^|\s)#.*$", "", l).strip()
        if l and REQ_SOURCE_RE.search(l):
            out.add(" ".join(l.split()))
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
    if not isinstance(j, dict):
        return None
    out = {}
    for k in ("dependencies", "devDependencies", "optionalDependencies", "peerDependencies"):
        if not isinstance(j.get(k) or {}, dict):
            return None
        out.update(j.get(k) or {})
    return out


USES_RE = re.compile(r"^\s*-?\s*uses:\s*[\"']?([^\s\"'#]+)", re.M)


def check_dependencies(files, registry):
    """files: {path: (base_text|None, head_text|None)} for changed dependency files. registry: provenance dict or None."""
    title = "New dependencies have a licence / provenance entry and are pinned"
    if not files:
        return check("DEPS", title, NA, ["no dependency, lock, image, action or workflow file changed"])
    entries = (registry or {}).get("entries", []) if isinstance(registry, dict) else []
    known = {(e.get("ecosystem"), norm_pkg(e.get("name", ""))) for e in entries if isinstance(e, dict) and e.get("license")}
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
            for src in sorted(req_sources(ht) - req_sources(bt)):
                findings.append(_f("DEP-SOURCE", "reject", path, f"a line changes where packages come from (other index, URL, VCS, local path or include): {src[:120]}"))
            if base.endswith(".lock"):
                for n in lock_unhashed(ht):
                    findings.append(_f("DEP-PIN", "reject", path, f"lock entry '{n}' has no --hash"))
        elif base == "package.json":
            b, h = npm_deps(bt) or {}, npm_deps(ht)
            if h is None:
                findings.append(_f("DEP-PROVENANCE", "reject", path, "package.json does not parse as an object with dependency maps"))
                continue
            for n in sorted(h):
                if n not in b and ("npm", norm_pkg(n)) not in known:
                    findings.append(_f("DEP-PROVENANCE", "reject", path, f"new npm dependency '{n}' has no licence/provenance entry"))
                elif n in b and b[n] != h[n]:
                    ev.append(f"{path}: {n} {b[n]} -> {h[n]} (version change; licence must be re-read by the reviewer)")
                if re.search(r"[\^~*xX>:/]|latest", str(h[n])) and (n not in b or b[n] != h[n]):
                    findings.append(_f("DEP-PIN", "reject", path, f"npm dependency '{n}' is a range, tag, URL or path ({str(h[n])[:60]}), not an exact version"))
        elif base == "package-lock.json":
            ev.append(f"{path}: lockfile changed (transitive npm packages are not individually checked: UNVERIFIED)")
            unverified.append(_f("DEP-PROVENANCE", "unverified", path, "npm lockfile changed; transitive packages not checked against the provenance register"))
        elif re.match(r"(Dockerfile.*|.*\.dockerfile|docker-compose.*\.ya?ml|compose.*\.ya?ml)$", base) and not fixture:
            old = set(re.findall(r"^\s*(?:FROM|image:)\s+(\S+)", bt or "", re.M | re.I))
            for img in sorted(set(re.findall(r"^\s*(?:FROM|image:)\s+(\S+)", ht, re.M | re.I)) - old):
                if "@sha256:" not in img and img.lower() != "scratch" and not img.startswith("$"):
                    findings.append(_f("DEP-PIN", "reject", path, f"image '{img}' is not pinned by digest"))
        elif path.startswith(".github/") and path.endswith((".yml", ".yaml")):
            old = set(USES_RE.findall(bt or ""))
            for u in sorted(set(USES_RE.findall(ht)) - old):
                if u.startswith("docker://"):
                    if "@sha256:" not in u:
                        findings.append(_f("DEP-PIN", "reject", path, f"action image '{u}' is not pinned by digest"))
                elif u.startswith("./"):
                    ev.append(f"{path}: uses the local action {u} (its own file is checked when it changes)")
                elif not re.search(r"@[0-9a-f]{40}$", u):
                    findings.append(_f("DEP-PIN", "reject", path, f"action '{u}' is not pinned by full commit SHA"))
    if findings:
        return check("DEPS", title, FAIL, findings + unverified, ev)
    if unverified:
        return check("DEPS", title, UNVERIFIED, unverified, ev)
    return check("DEPS", title, PASS, [], ev or ["dependency files changed; no new package, source, image or action"])


DEP_FILE_RE = re.compile(r"(^requirements\.txt$|^requirements/.*\.(in|lock)$|(^|/)package(-lock)?\.json$|(^|/)Dockerfile[^/]*$|\.dockerfile$|(^|/)(docker-)?compose[^/]*\.ya?ml$"
                         r"|^\.github/.*\.ya?ml$)")


# ------------------------------------------------------------------------------------------- reviewer independence
def norm_id(s):
    """Identity labels are compared case-insensitively with whitespace collapsed ("auth " == "Auth")."""
    return " ".join(s.split()).casefold() if isinstance(s, str) and s.strip() else None


def _has_evidence(e):
    ev = e.get("evidence")
    return isinstance(ev, list) and bool(ev) and all(isinstance(x, dict) and x.get("ref") and isinstance(x.get("sha256"), str) and HEX64.match(x["sha256"]) for x in ev)


def check_independent_review(entries, sha, author, author_ids=()):
    """entries: verified ledger entries (list of dicts) or None.
    author / author_ids: who wrote the change, as given to the engine (--author) and as read from the PR and git metadata.
    PASS needs all of: an APPROVE review of THIS exact head; with evidence (each item a ref and a sha256); by a reviewer who is
    none of the authors; and no open REJECT / NEEDS_MORE_WORK on this head. A negative review of a head stays open unless a
    LATER approving review that meets the same conditions names it in `supersedes`. The usual way out of a REJECT is a new head."""
    title = "Independent review recorded for this exact head (reviewer is not the author; no open rejection)"
    if entries is None:
        return check("INDEPENDENT-REVIEW", title, UNVERIFIED, ["the oversight ledger could not be read or did not verify"])
    entries = [e for e in entries if e.get("type") in ("review", "import")]      # mechanical_check entries are not reviews
    mine = [e for e in entries if (e.get("subject") or {}).get("sha") == sha]
    authors = {a for a in [norm_id(author)] + [norm_id(x) for x in author_ids] if a}
    if not mine:
        older = sorted({(e.get("subject") or {}).get("sha", "")[:12] for e in entries if norm_id((e.get("author") or {}).get("id")) in authors})
        note = f" Reviews exist for other heads by this author: {', '.join(older)}." if older else ""
        return check("INDEPENDENT-REVIEW", title, UNVERIFIED, [f"no review of {sha[:12]} is recorded in the ledger.{note} A new head needs a fresh independent review."])
    findings, ev, indep = [], [], []
    for e in mine:
        rid, aid = norm_id((e.get("reviewer") or {}).get("id")), norm_id((e.get("author") or {}).get("id"))
        if not rid or not aid or rid == aid or rid in authors:
            findings.append({"class": "reject", "msg": f"ledger entry {e.get('id')}: reviewer '{(e.get('reviewer') or {}).get('id')}' is the author (self-review)"})
        else:
            indep.append(e)
    if not indep:
        return check("INDEPENDENT-REVIEW", title, FAIL, findings, ev)
    good = [e for e in indep if e.get("recommendation") == "APPROVE" and not e.get("imported") and _has_evidence(e)]
    open_neg = []
    for e in indep:
        if e.get("recommendation") in ("REJECT", "NEEDS_MORE_WORK"):
            closed = [a for a in good if (a.get("seq") or 0) > (e.get("seq") or 0) and isinstance(a.get("supersedes"), list) and e.get("id") in a["supersedes"]]
            if not closed:
                open_neg.append(e)
            else:
                ev.append(f"negative review {e.get('id')} is superseded by {closed[-1].get('id')} (same head, with evidence)")
    for e in open_neg:
        n = len(e.get("findings") or [])
        findings.append({"class": "reject", "msg": f"review {e.get('id')} (seq {e.get('seq')}, reviewer {(e.get('reviewer') or {}).get('id')}) of this head recommends "
                         f"{e.get('recommendation')} ({n} finding(s) recorded) and is still open. A later APPROVE does not override it unless it is for this same head, "
                         "carries evidence, comes from a non-author and names this entry in `supersedes`; normally the fix is a new head and a fresh review"})
    if open_neg:
        return check("INDEPENDENT-REVIEW", title, FAIL, findings, ev)
    approvals = [e for e in indep if e.get("recommendation") == "APPROVE"]
    if not approvals:
        return check("INDEPENDENT-REVIEW", title, UNVERIFIED, ["no independent review of this head has a usable recommendation"], ev)
    if not good:
        why = "the approving review is an imported report that this function did not re-verify" if all(e.get("imported") for e in approvals) \
            else "the approving review carries no evidence (each evidence item needs a ref and the sha256 of what was looked at)"
        return check("INDEPENDENT-REVIEW", title, UNVERIFIED, [why], ev)
    if not authors:
        return check("INDEPENDENT-REVIEW", title, UNVERIFIED, ["the author's identity was not given to the engine (--author) and could not be read from the PR or git, "
                                                              "so 'reviewer is not the author' rests on the ledger entry's own label only"], ev)
    last = good[-1]
    ev.append(f"ledger entry {last.get('id')} seq {last.get('seq')}: reviewer {last['reviewer'].get('id')}, recommendation APPROVE, {len(last['evidence'])} evidence item(s)")
    ev.append(f"author identities compared: {', '.join(sorted(authors))}")
    for f in findings:
        f["class"] = "note"
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
    title = "Oversight ledger is append-only relative to the trusted base"
    if base_text is None and head_text is None:
        return check("LEDGER", title, NA, ["no oversight ledger on the base or the head"])
    if base_text is None:
        return check("LEDGER", title, PASS, [], ["ledger is new on this head"])
    if head_text is None:
        return check("LEDGER", title, FAIL, [{"class": "reject", "msg": "the ledger file is deleted or moved away"}])
    if not head_text.startswith(base_text):
        return check("LEDGER", title, FAIL, [{"class": "reject", "msg": "the ledger on the head does not start with the ledger on the base: an entry was edited, deleted or reordered"}])
    return check("LEDGER", title, PASS, [], [f"base ledger ({base_text.count(chr(10))} entries) is a prefix of the head ledger ({head_text.count(chr(10))} entries)"])


def check_base(pr, requested, local_sha, remote_sha, use_github):
    """Is this change judged against the one trusted base? pr: PR object or None. requested: the --base argument or None.
    local_sha: what TRUSTED_REF resolves to here. remote_sha: GitHub's current tip of the trusted branch (None = not read)."""
    title = f"The change targets the trusted base ({TRUSTED_BRANCH}) and the local copy of that base is current"
    f, ev = [], [f"trusted ref: {TRUSTED_REF} @ {local_sha or 'NOT FOUND LOCALLY'}"]
    if requested and requested not in ALLOWED_BASE_ARGS:
        f.append({"class": "unverified", "msg": f"--base {requested[:80]} was refused: the engine only trusts {TRUSTED_REF}. Nothing was read from or run from the requested ref"})
    if local_sha is None:
        f.append({"class": "unverified", "msg": f"{TRUSTED_REF} does not exist in the local repository (git fetch origin {TRUSTED_BRANCH}; the engine does not fetch)"})
    if not use_github or pr is None:
        f.append({"class": "unverified", "msg": "the PR's base branch was not read from GitHub, so it is not known that this change targets the trusted base"})
    else:
        ref = (pr.get("base") or {}).get("ref")
        ev.append(f"PR base: {ref}")
        if ref != TRUSTED_BRANCH:
            f.append({"class": "unverified", "msg": f"the PR targets '{str(ref)[:80]}', not {TRUSTED_BRANCH}. The checks below were still taken against {TRUSTED_BRANCH} with its tools; "
                                                    "a merge into another branch was not evaluated and nothing from that branch was trusted or run"})
    if use_github:
        if remote_sha is None:
            f.append({"class": "unverified", "msg": f"the current tip of {TRUSTED_BRANCH} could not be read from GitHub, so the local copy may be stale"})
        elif local_sha and remote_sha != local_sha:
            f.append({"class": "unverified", "msg": f"the local {TRUSTED_REF} ({local_sha[:12]}) is not GitHub's {TRUSTED_BRANCH} ({remote_sha[:12]}): fetch and run again"})
        else:
            ev.append(f"GitHub {TRUSTED_BRANCH} tip: {remote_sha}")
    return check("BASE", title, UNVERIFIED if f else PASS, f, ev)


def check_engine(trusted_copies):
    """trusted_copies: {rel_path: text on TRUSTED_REF or None}. The running engine and ledger code must be those copies."""
    title = "The running engine is the copy on the trusted base (not the change's own copy)"
    f, ev = [], []
    for rel, trusted in sorted(trusted_copies.items()):
        try:
            with open(os.path.join(HERE, os.path.basename(rel)), encoding="utf-8") as fh:
                mine = fh.read()
        except OSError:
            mine = None
        if trusted is None:
            f.append({"class": "unverified", "msg": f"{rel} does not exist on {TRUSTED_REF}: the engine is not yet adopted there, so this result comes from an unreviewed copy"})
        elif mine != trusted:
            f.append({"class": "unverified", "msg": f"the running {rel} differs from the copy on {TRUSTED_REF}: run the engine from a checkout of {TRUSTED_BRANCH}"})
        else:
            ev.append(f"{rel}: identical to {TRUSTED_REF} (sha256 {sha256_text(trusted)[:16]})")
    return check("ENGINE", title, UNVERIFIED if f else PASS, f, ev)


# ----------------------------------------------------------------------------------------------- owner decisions
def apply_owner_decisions(checks, entries, sha):
    """Release owner_gate / human_review findings of the checks an owner decision names, for THIS head only.
    entries: ledger entries that verified against the owner keys on TRUSTED_REF (signature, binding to a review of this SHA and
    key revocation are all enforced by ledger.verify_text), or None. Class reject and owner_only are never released."""
    title = "Owner decision recorded for this exact head"
    if entries is None:
        return check("OWNER-DECISION", title, NA, ["the ledger was not read or did not verify: no owner decision is taken into account"])
    mine = [e for e in entries if e.get("type") == "owner_decision" and (e.get("subject") or {}).get("sha") == sha]
    if not mine:
        return check("OWNER-DECISION", title, NA, ["no signed owner decision for this head is in the ledger"])
    last = mine[-1]
    ev = [f"ledger entry {last.get('id')} seq {last.get('seq')}: decision {last.get('decision')}, key {last.get('key_id')}, bound to entry {last.get('review_id')}, releases {last.get('releases')}"]
    if last.get("decision") == "reject":
        return check("OWNER-DECISION", title, FAIL, [{"class": "reject", "msg": f"the Owner rejected this head (ledger entry {last.get('id')})"}], ev)
    if last.get("decision") != "approve":
        return check("OWNER-DECISION", title, NA, ["the latest owner decision for this head is 'defer': nothing is released"], ev)
    n = 0
    for c in checks:
        if c["id"] in RELEASABLE_CHECKS and c["id"] in (last.get("releases") or []):
            for f in c["findings"]:
                if f.get("class") in ("owner_gate", "human_review"):
                    f["released_class"], f["class"], f["released_by"] = f["class"], "released", last.get("id")
                    n += 1
            c["status"] = status_of(c["findings"])
            c["class"] = None if c["status"] != FAIL else "reject" if any(f.get("class") == "reject" for f in c["findings"]) else "owner_gate"
    ev.append(f"{n} finding(s) released. Findings of class reject and owner_only are never released")
    return check("OWNER-DECISION", title, PASS, [], ev)


# ----------------------------------------------------------------------------------------------- evidence gathering
class Recorder:
    """Runs commands and records each one (argv, exit code, sha256 of stdout) as evidence. `git()` addresses the repository
    under review and allows ONLY the read sub-commands in READ_GIT; the engine's own temp directory is driven through `run()`."""
    READ_GIT = frozenset({"rev-parse", "merge-base", "diff", "show", "log", "ls-tree", "grep"})

    def __init__(self, repo):
        self.repo, self.commands = repo, []

    def run(self, argv, cwd=None, timeout=180, env=None, stdin=None):
        try:
            r = subprocess.run(argv, cwd=cwd, capture_output=True, text=True, timeout=timeout, env=env, errors="replace", input=stdin)
            rc, out, err = r.returncode, r.stdout, r.stderr
        except (OSError, subprocess.TimeoutExpired) as e:
            rc, out, err = -1, "", f"{type(e).__name__}: {e}"
        self.commands.append({"argv": [a if len(a) < 200 else a[:200] + "..." for a in argv], "exit": rc,
                              "stdout_sha256": hashlib.sha256(out.encode("utf-8", "replace")).hexdigest(), "stdout_bytes": len(out)})
        return rc, out, err

    def git(self, *args):
        if not args or args[0] not in self.READ_GIT:
            raise RuntimeError(f"engine is read-only on the reviewed repository: git {args[0] if args else ''} refused")
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


def gather_diff(rec, a, b):
    """Parsed diff a..b. Taken WITHOUT rename detection, so a moved file is what it is for a control: gone from the old path
    (deletion rules fire) and new at the new path (every line is scanned). A second, rename-aware listing only adds the
    'moved to' note. -a: binary-looking files are still read as text. Raises Unavailable when git's two listings disagree."""
    opts = ["--no-color", "--no-ext-diff", "--no-textconv", "--no-renames"]
    rc1, raw, _ = rec.git("diff", "--raw", "-z", "--no-abbrev", *opts, a, b)
    rc2, patch, _ = rec.git("diff", "-a", "--unified=0", *opts, a, b)
    rc3, ren, _ = rec.git("diff", "--raw", "-z", "--no-abbrev", "--no-color", "-M", "-C", a, b)
    if rc1 or rc2:
        raise Unavailable("git diff failed")
    files, listed = parse_diff(patch), parse_raw(raw)
    if {e[4] for e in listed} != set(files):
        raise Unavailable("git's file list and patch do not name the same files (unusual path names?): the diff was not scanned")
    for om, nm, st, _, path, _ in listed:
        d = files[path]
        d["status"], d["old_mode"], d["new_mode"] = st, (om if om != "000000" else None), (nm if nm != "000000" else None)
    for _, _, st, _, old, new in parse_raw(ren) if rc3 == 0 else []:
        if st == "R" and new and old in files and files[old]["status"] == "D":
            files[old]["renamed_to"] = new
    return files


def runtime_referenced_tests(rec, sha, files):
    """Test-named Python files of this change that non-test Python code imports (import / from / import_module / __import__)
    or that the Procfile names. A plain mention in a string or comment is not a use."""
    out = set()
    cands = [p for p in files if p.endswith(".py") and is_test_or_doc(p) and files[p]["status"] != "D"]
    for p in cands[:200]:
        mod = os.path.basename(p)[:-3]
        if not re.match(r"^[A-Za-z_][A-Za-z0-9_]*$", mod):
            continue
        imp = rf"(^|[^A-Za-z0-9_])(import|from)[ \t]+([A-Za-z0-9_., \t]*[ .,\t])?{mod}([^A-Za-z0-9_]|$)|(import_module|__import__)[ \t]*\([^)]*[^A-Za-z0-9_]{mod}[^A-Za-z0-9_]"
        rc1, hits, _ = rec.git("grep", "-l", "-E", "-e", imp, sha, "--", "*.py")
        rc2, proc, _ = rec.git("grep", "-l", "-w", "-F", "-e", mod, sha, "--", "Procfile")
        for h in (hits.splitlines() if rc1 == 0 else []) + (proc.splitlines() if rc2 == 0 else []):
            ref = h.split(":", 1)[1] if ":" in h else h
            if ref != p and not is_test_or_doc(ref):
                out.add(p)
                break
    return out, len(cands) > 200


def inside(root, path):
    r, p = os.path.realpath(root), os.path.realpath(path)
    return p == r or p.startswith(r + os.sep)


def safe_write(root, rel, text):
    """Create a NEW regular file under root. Refuses to follow or replace anything: no symlink component, no existing path."""
    dest = os.path.join(root, rel)
    parent = os.path.dirname(dest)
    os.makedirs(parent, exist_ok=True)
    if not inside(root, parent) or os.path.lexists(dest):
        raise Unavailable(f"refused to write {rel}: it would leave the engine's temp directory or replace an existing path")
    fd = os.open(dest, os.O_WRONLY | os.O_CREAT | os.O_EXCL | getattr(os, "O_NOFOLLOW", 0), 0o600)
    with os.fdopen(fd, "w", encoding="utf-8", newline="") as f:
        f.write(text)
    return dest


def safe_copy(src_root, rel, dst_root):
    """Copy one regular file that really lies inside src_root. A symlink (or anything else) is refused, never followed."""
    src = os.path.join(src_root, rel)
    if os.path.islink(src) or not os.path.isfile(src) or not inside(src_root, src):
        raise Unavailable(f"refused to read {rel}: not a regular file inside the head copy")
    with open(src, encoding="utf-8", errors="surrogateescape", newline="") as f:
        data = f.read()
    dest = os.path.join(dst_root, rel)
    os.makedirs(os.path.dirname(dest), exist_ok=True)
    if not inside(dst_root, os.path.dirname(dest)) or os.path.lexists(dest):
        raise Unavailable(f"refused to write {rel}")
    fd = os.open(dest, os.O_WRONLY | os.O_CREAT | os.O_EXCL | getattr(os, "O_NOFOLLOW", 0), 0o600)
    with os.fdopen(fd, "w", encoding="utf-8", errors="surrogateescape", newline="") as f:
        f.write(data)


TOOL_INPUT_DIRS = ("scripts", "migrations", "dist")
ORDER_ENTRY_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9_.-]*\.sql$")


def apply_order_problems(text):
    """Entries of migrations/APPLY_ORDER.txt that are not a plain file name (the bundle script word-splits and cats each one)."""
    bad = []
    for l in (text or "").split("\n"):
        if l.startswith("#"):
            continue
        bad += [tok for tok in l.split() if not ORDER_ENTRY_RE.match(tok) or ".." in tok]
    return bad


def run_trusted_tools(rec, sha, base_sha):
    """Lint + bundle check with the TRUSTED_REF copy of each tool, never the head's.
    Layout of the engine's own temp directory (removed afterwards; TMPDIR and HOME point inside it):
        head/    the head, materialised as data: a fresh `git init`, objects borrowed read-only from the reviewed repository,
                 no hooks, no filter drivers, core.symlinks=false (a symlink in the tree becomes a small text file, never a link).
                 The engine writes nothing into this work tree.
        tools/   the trusted lint, run as  python -I tools/lint_migrations.py --root head --base TRUSTED_REF
        bundle/  scripts/build_bundle.sh (trusted) + copies of the head's migrations/*.sql, APPLY_ORDER.txt and dist/APPLY_ALL.sql
    Refused before anything runs: a symlink or submodule under scripts/, migrations/ or dist/; an APPLY_ORDER entry that is not
    a plain file name."""
    results = {}
    refuse = lambda msg: {n: {"status": FAIL, "refused": msg} for n in ("lint", "bundle")}
    rc, tree, _ = rec.git("ls-tree", "-r", "-z", sha, "--", *TOOL_INPUT_DIRS)
    if rc != 0:
        raise Unavailable(f"could not list the tree of {sha[:12]}")
    odd = [e.split("\t", 1)[1] for e in tree.split("\0") if e and e.split(" ", 1)[0] in ("120000", "160000")]
    if odd:
        return refuse(f"{len(odd)} symlink / submodule entr{'y' if len(odd) == 1 else 'ies'} in the tool inputs (first: {odd[0][:100]}); no tool was run")
    order = rec.show(sha, "migrations/APPLY_ORDER.txt")
    bad = apply_order_problems(order)
    if bad:
        return refuse(f"migrations/APPLY_ORDER.txt has {len(bad)} entr{'y' if len(bad) == 1 else 'ies'} that are not a plain migration file name "
                      f"(path traversal or glob; first: {bad[0][:60]!r}); no tool was run")
    rc, common, _ = rec.git("rev-parse", "--git-common-dir")
    objects = os.path.join(os.path.abspath(os.path.join(rec.repo, common.strip())), "objects")
    if rc != 0 or not os.path.isdir(objects):
        raise Unavailable("could not locate the object store of the reviewed repository")
    tmp = os.path.realpath(tempfile.mkdtemp(prefix="oversight_"))
    try:
        for d in ("home", "tmpd", "tools", "bundle"):
            os.makedirs(os.path.join(tmp, d))
        head = os.path.join(tmp, "head")
        env = {"PATH": os.environ.get("PATH", "/usr/bin:/bin"), "HOME": os.path.join(tmp, "home"), "TMPDIR": os.path.join(tmp, "tmpd"), "LANG": "C.UTF-8",
               "GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_GLOBAL": os.devnull, "GIT_ATTR_NOSYSTEM": "1", "GIT_TERMINAL_PROMPT": "0", "GIT_LFS_SKIP_SMUDGE": "1"}
        g = ["git", "-C", head, "-c", "core.hooksPath=/dev/null", "-c", "advice.detachedHead=false"]
        rc, _, err = rec.run(["git", "init", "-q", head], env=env)
        if rc == 0:
            safe_write(tmp, "head/.git/objects/info/alternates", objects + "\n")
            rc, _, err = rec.run(g + ["config", "core.symlinks", "false"], env=env)
        if rc == 0:
            rc, _, err = rec.run(g + ["update-ref", TRUSTED_REF, base_sha], env=env)
        if rc == 0:
            rc, _, err = rec.run(g + ["checkout", "-q", "--detach", sha], env=env)
        if rc != 0:
            raise Unavailable(f"could not materialise {sha[:12]} in a throwaway repository: {err.strip()[:200]}")
        for d in TOOL_INPUT_DIRS:                              # defence in depth: nothing under the tool inputs may be a link
            for root, dirs, names in os.walk(os.path.join(head, d)):
                for n in dirs + names:
                    if os.path.islink(os.path.join(root, n)) or not inside(head, os.path.join(root, n)):
                        return refuse(f"a link was found under {d}/ in the head copy; no tool was run")

        lint = rec.show(TRUSTED_REF, "scripts/lint_migrations.py")
        if lint is None:
            results["lint"] = {"status": UNVERIFIED, "msg": f"scripts/lint_migrations.py does not exist on {TRUSTED_REF}, so there is no trusted copy to run"}
        else:
            tool = safe_write(tmp, "tools/lint_migrations.py", lint)
            rc, out, err = rec.run([sys.executable, "-I", tool, "--root", head, "--base", TRUSTED_REF], cwd=os.path.join(tmp, "tools"), env=env, timeout=300)
            results["lint"] = {"status": PASS if rc == 0 else FAIL, "exit": rc, "tail": [l for l in (out + "\n" + err).strip().splitlines() if l.strip()][-8:],
                               "tool_modified_by_head": rec.show(sha, "scripts/lint_migrations.py") != lint, "tool_sha256": sha256_text(lint)}

        bundle = rec.show(TRUSTED_REF, "scripts/build_bundle.sh")
        if bundle is None:
            results["bundle"] = {"status": UNVERIFIED, "msg": f"scripts/build_bundle.sh does not exist on {TRUSTED_REF}, so there is no trusted copy to run"}
        else:
            broot = os.path.join(tmp, "bundle")
            tool = safe_write(broot, "scripts/build_bundle.sh", bundle)
            mig = os.path.join(head, "migrations")
            for n in sorted(os.listdir(mig)) if os.path.isdir(mig) else []:
                if os.path.isfile(os.path.join(mig, n)) and (ORDER_ENTRY_RE.match(n) or n == "APPLY_ORDER.txt"):
                    safe_copy(head, os.path.join("migrations", n), broot)
            if os.path.isfile(os.path.join(head, "dist", "APPLY_ALL.sql")):
                safe_copy(head, os.path.join("dist", "APPLY_ALL.sql"), broot)
            rc, out, err = rec.run(["bash", tool, "--check"], cwd=broot, env=env, timeout=300)
            results["bundle"] = {"status": PASS if rc == 0 else FAIL, "exit": rc, "tail": [l for l in (out + "\n" + err).strip().splitlines() if l.strip()][-8:],
                                 "tool_modified_by_head": rec.show(sha, "scripts/build_bundle.sh") != bundle, "tool_sha256": sha256_text(bundle)}
    finally:
        shutil.rmtree(tmp, ignore_errors=True)
    return results


def tool_check(cid, title, res, what):
    if res is None:
        return check(cid, title, UNVERIFIED, [f"{what} was not run"])
    if res.get("refused"):
        return check(cid, title, FAIL, [{"class": "reject", "msg": res["refused"]}])
    if res["status"] == UNVERIFIED:
        return check(cid, title, UNVERIFIED, [res["msg"]])
    ev = [f"exit {res['exit']} (trusted-base copy of the tool, sha256 {res['tool_sha256'][:16]})"] + res["tail"]
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


def load_ledger(path, keys=None, anchor_text=None):
    """Verified ledger entries, or None when missing / not verifying / not an extension of the anchored (trusted-base) copy.
    keys: owner keys to trust ({} = none). A ledger holding a decision signed by any other key does not verify."""
    try:
        sys.path.insert(0, HERE)
        import ledger as L
        with open(path, encoding="utf-8", newline="") as f:
            text = f.read()
        if anchor_text is not None and not text.startswith(anchor_text):
            return None
        entries, errs = L.verify_text(text, {} if keys is None else keys)
        return entries if not errs else None
    except Exception:
        return None


def trusted_owner_keys(text):
    try:
        sys.path.insert(0, HERE)
        import ledger as L
        return L.parse_owner_keys(text) if text is not None else {}
    except Exception:
        return {}


def all_check_runs(rec, repo_slug, sha):
    runs = []
    for page in range(1, 11):
        got = rec.api(f"repos/{repo_slug}/commits/{sha}/check-runs?per_page=100&page={page}").get("check_runs") or []
        runs += got
        if len(got) < 100:
            return runs
    raise Unavailable("more than 1000 check-runs on the commit")


def evaluate(rec, sha, pr_number=None, base_ref=None, repo_slug=None, use_github=True, ledger_path=None, author=None, registry=None, authors=()):
    """Gather evidence and run every check. Returns the result dict. base_ref is only a REQUEST: anything but the trusted ref
    is refused and reported; it never changes what is read or run."""
    checks, not_inspected, owner_decisions = [], [], []
    pr, pr_err = None, None
    if use_github and pr_number is not None:
        try:
            pr = rec.api(f"repos/{repo_slug}/pulls/{pr_number}")
            if not isinstance(pr, dict):
                pr, pr_err = None, "PR response is not an object"
        except Unavailable as e:
            pr_err = str(e)

    # -- head identity
    if pr is not None:
        cur = (pr.get("head") or {}).get("sha")
        st = PASS if cur == sha else FAIL
        f = [] if st == PASS else [{"class": "reject", "msg": f"the reviewed SHA {sha[:12]} is not the PR's current head {str(cur)[:12]}: evidence would be stale"}]
        checks.append(check("HEAD", "Reviewed SHA is the PR's current head", st, f, [f"PR #{pr_number} head.sha = {cur}", f"PR state: {pr.get('state')}, draft: {pr.get('draft')}"]))
    else:
        checks.append(check("HEAD", "Reviewed SHA is the PR's current head", UNVERIFIED, [pr_err or "no PR number given or GitHub not consulted"]))

    # -- trusted base
    rc, out, _ = rec.git("rev-parse", "--verify", "-q", f"{TRUSTED_REF}^{{commit}}")
    base_sha = out.strip() if rc == 0 and SHA_RE.match(out.strip()) else None
    remote_sha = None
    if use_github:
        try:
            remote_sha = ((rec.api(f"repos/{repo_slug}/git/ref/heads/{TRUSTED_BRANCH}") or {}).get("object") or {}).get("sha")
        except (Unavailable, AttributeError):
            remote_sha = None
    checks.append(check_base(pr, base_ref, base_sha, remote_sha, use_github))
    checks.append(check_engine({p: (rec.show(TRUSTED_REF, p) if base_sha else None) for p in ("ops/oversight/mandatory_checks.py", "ops/oversight/ledger.py")}))

    # -- CI
    runs, logs, gate_seen = None, {}, {}
    if use_github:
        try:
            runs = all_check_runs(rec, repo_slug, sha)
        except Unavailable:
            runs = None
    checks.append(check_ci(runs, sha))
    for name, r in sorted(latest_runs(runs, sha, ("unit", "migrations")).items()):
        if r.get("status") == "completed":
            try:
                logs[name] = rec.api_text(f"repos/{repo_slug}/actions/jobs/{r['id']}/logs")
            except Unavailable:
                not_inspected.append(f"CI log of job {name} ({r['id']}) could not be downloaded")
    checks.append(check_gate_evidence(logs.get("migrations")))
    gate_seen = parse_gate_summary(logs.get("migrations"))[0] if logs.get("migrations") else {}

    # -- diff against the trusted base
    files, merge_base, why, git_authors = None, None, None, set()
    rc, _, _ = rec.git("rev-parse", "--verify", "-q", f"{sha}^{{commit}}")
    if rc != 0 or base_sha is None:
        why = f"commit {sha[:12]} or {TRUSTED_REF} is not in the local repository (run `git fetch origin <branch>` first; the engine does not fetch)"
    else:
        rc, mb, _ = rec.git("merge-base", base_sha, sha)
        if rc != 0:
            why = f"{sha[:12]} shares no history with {TRUSTED_REF}"
        else:
            merge_base = mb.strip()
            try:
                files = gather_diff(rec, merge_base, sha)
            except Unavailable as e:
                why = str(e)
    if files is None:
        for cid, title in (("PROTECTED", "No protected control is touched or weakened"), ("LINT", "Migrations follow the migration lint"),
                           ("BUNDLE", "dist/APPLY_ALL.sql was regenerated"), ("DEPS", "New dependencies have a licence / provenance entry and are pinned"),
                           ("ACL", "ACL manifest matches the database ACLs (no drift)"), ("LEDGER", "Oversight ledger is append-only relative to the trusted base")):
            checks.append(check(cid, title, UNVERIFIED, [why]))
        checks.append(check_production(pr, None))
    else:
        if merge_base != base_sha:
            not_inspected.append(f"the head is not rebased on the base tip: diff taken from merge-base {merge_base[:12]}, base tip is {base_sha[:12]}; "
                                 "interaction with the commits in between was not inspected")
        rc, log, _ = rec.git("log", "--format=%an%x00%ae%x00%cn%x00%ce", f"{merge_base}..{sha}")
        git_authors = {x for l in log.splitlines() for x in l.split("\0") if x.strip()} if rc == 0 else set()
        show_b = lambda p: None if files[p]["status"] == "A" else rec.show(merge_base, p)
        show_h = lambda p: None if files[p]["status"] == "D" else rec.show(sha, p)
        runtime_tests, too_many = runtime_referenced_tests(rec, sha, files)
        texts = {p: (show_b(p), show_h(p)) for p in files
                 if p.endswith((".sql", ".py")) and not is_test_or_doc(p, runtime_tests) or is_guard(p) or is_test_file(p) or is_control_test(p)}
        findings = scan_diff(files, texts, runtime_tests)
        if too_many:
            findings.append(_f("PC-TESTS", "human_review", "", "more than 200 test-named Python files change; only the first 200 were checked for use by runtime code"))
        if ".gitleaksignore" in files:
            findings += check_gitleaksignore(rec.show(merge_base, ".gitleaksignore"), rec.show(sha, ".gitleaksignore"))
        if any(p in files for p in CODEOWNERS_PATHS):
            findings += check_codeowners(rec.show(merge_base, ".github/CODEOWNERS"), rec.show(sha, ".github/CODEOWNERS"))
            findings += [_f("PC-CODEOWNERS", "owner_gate", p, "a CODEOWNERS file outside .github/ is added, changed or removed") for p in CODEOWNERS_PATHS[1:] if p in files]
        wf = [p for p in files if p.startswith(".github/workflows/")]
        if "scripts/gate.sh" in files or wf:
            findings += check_gate(rec.show(merge_base, "scripts/gate.sh"), rec.show(sha, "scripts/gate.sh"),
                                   {p: rec.show(merge_base, p) for p in wf if rec.show(merge_base, p) is not None},
                                   {p: rec.show(sha, p) for p in wf if files[p]["status"] != "D"})
        if "scripts/lint_migrations.py" in files:
            findings += check_lint_rules(rec.show(merge_base, "scripts/lint_migrations.py"), rec.show(sha, "scripts/lint_migrations.py"))
        ev = [f"diff {merge_base[:12]}..{sha[:12]} (no rename folding): {len(files)} file(s), {sum(len(d['added']) for d in files.values())} added line(s), "
              f"{sum(len(d['removed']) for d in files.values())} removed line(s)"]
        checks.append(check("PROTECTED", "No protected control is touched or weakened", status_of(findings), findings, ev))

        mig = [p for p in files if p.startswith("migrations/") or p == "dist/APPLY_ALL.sql"]
        tools = None
        try:
            tools = run_trusted_tools(rec, sha, base_sha)
        except Unavailable as e:
            not_inspected.append(str(e))
        checks.append(tool_check("LINT", "Migrations follow the migration lint", (tools or {}).get("lint"), "scripts/lint_migrations.py"))
        checks.append(tool_check("BUNDLE", "dist/APPLY_ALL.sql was regenerated", (tools or {}).get("bundle"), "scripts/build_bundle.sh --check"))
        dep_files = {p: (show_b(p), show_h(p)) for p in files if DEP_FILE_RE.search(p)}
        checks.append(check_dependencies(dep_files, registry))
        rc, ls, _ = rec.git("ls-tree", "--name-only", sha, "ops/")
        manifests = [l for l in ls.split() if re.match(r"ops/ACL_MANIFEST.*\.tsv$", l)] if rc == 0 else []
        checks.append(check_acl(files, manifests, gate_seen))
        checks.append(check_ledger_append_only(rec.show(merge_base, LEDGER_PATH), rec.show(sha, LEDGER_PATH)))
        checks.append(check_production(pr, files))
        if mig:
            owner_decisions.append(f"{len([p for p in mig if p.startswith('migrations/')])} migration file(s) change: applying them to production is a separate owner release authorization (merging does not apply them)")

    # -- test results, claims, reviewer independence, owner decision
    checks.append(check_test_results(logs) if use_github else check("TEST-RESULTS", "CI ran the tests on this SHA: none failed, none skipped", UNVERIFIED, ["GitHub not consulted"]))
    claim_text = ((pr or {}).get("title") or "") + "\n" + ((pr or {}).get("body") or "") if pr else None
    checks.append(check_test_claims(claim_text, logs) if pr else check("TEST-CLAIMS", "Test counts claimed in the PR text match what CI printed", UNVERIFIED, ["PR text could not be read"]))
    keys = trusted_owner_keys(rec.show(TRUSTED_REF, OWNER_KEYS_PATH) if base_sha else None)
    entries = load_ledger(ledger_path, keys, rec.show(TRUSTED_REF, LEDGER_PATH) if base_sha else None) if ledger_path else None
    author_ids = set(authors) | git_authors | ({((pr or {}).get("user") or {}).get("login")} - {None})
    checks.append(check_independent_review(entries, sha, author, sorted(a for a in author_ids if isinstance(a, str))))
    checks.append(apply_owner_decisions(checks, entries, sha))

    for c in checks:
        for f in c["findings"]:
            if f.get("class") in ("owner_gate", "owner_only", "human_review"):
                owner_decisions.append(f"{c['id']}: {f.get('file') + ': ' if f.get('file') else ''}{f['msg']}")
    fails = [c for c in checks if c["status"] == FAIL]
    unv = [c for c in checks if c["status"] == UNVERIFIED]
    verdict = "REJECT" if fails else "NEEDS_MORE_WORK" if unv else "RECOMMEND_APPROVE"
    n_reject = sum(1 for c in fails for f in c["findings"] if f.get("class") == "reject")
    n_gate = sum(1 for c in fails for f in c["findings"] if f.get("class") in ("owner_gate", "owner_only"))
    reason = {"RECOMMEND_APPROVE": "ALL_CHECKS_PASS", "NEEDS_MORE_WORK": "EVIDENCE_MISSING"}.get(verdict) or ("RULE_BROKEN" if n_reject else "OWNER_DECISION_REQUIRED")
    not_inspected += ["code behaviour, logic, design and test quality (this engine is mechanical; a human or agent reviewer must read the change)",
                      "what SQL built at run time, or SQL sent from Python, actually does (only its presence in migrations is flagged)",
                      "the database: no migration was applied and no ACL was read by this engine",
                      "production (Supabase, Railway, Render): never contacted",
                      "licence texts of dependencies (only the presence of a register entry is checked)"]
    with open(os.path.abspath(__file__), "rb") as fh:
        engine_sha = hashlib.sha256(fh.read()).hexdigest()
    return {"schema": "fendezy.oversight.mandatory_checks/2", "engine_version": ENGINE_VERSION, "engine_sha256": engine_sha,
            "generated_at": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
            "subject": {"repo": repo_slug, "pr": pr_number, "head_sha": sha, "base_ref": TRUSTED_REF, "base_sha": base_sha, "merge_base": merge_base,
                        "requested_base": base_ref, "pr_base": ((pr or {}).get("base") or {}).get("ref"), "author": author,
                        "author_ids_compared": sorted(a for a in author_ids if isinstance(a, str)), "github_author": ((pr or {}).get("user") or {}).get("login")},
            "verdict": verdict, "verdict_reason": reason,
            "counts": {s: sum(1 for c in checks if c["status"] == s) for s in (PASS, FAIL, UNVERIFIED, NA)},
            "reject_findings": n_reject, "owner_gate_findings": n_gate,
            "checks": checks, "owner_decisions_required": owner_decisions, "not_inspected": not_inspected, "commands": rec.commands,
            "authority": "This result can stop a change (REJECT). It cannot approve one: RECOMMEND_APPROVE is advice to the Owner and to an independent reviewer."}


REASON_TEXT = {"RULE_BROKEN": "a mandatory rule is broken", "OWNER_DECISION_REQUIRED": "no rule is broken; protected controls are touched and need a signed owner decision",
               "EVIDENCE_MISSING": "evidence is missing or something needs a person to read it", "ALL_CHECKS_PASS": "every check passed; advice only"}


def md(s, limit=300):
    """Text from the change (titles, paths, tool output) made inert for the owner-facing Markdown summary."""
    s = re.sub(r"[\x00-\x1f\x7f  \u0085]+", " ", str(s))[:limit]
    s = s.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")
    return re.sub(r"([\\`*_{}\[\]()#|!~])", r"\\\1", s)


def summary(res):
    s = res["subject"]
    out = [f"# Mandatory checks: {'PR #' + str(s['pr']) + ' ' if s.get('pr') else ''}@ {md(s['head_sha'])}",
           f"Verdict: **{res['verdict']}** ({REASON_TEXT.get(res.get('verdict_reason'), '')}). {res['counts'][PASS]} pass, {res['counts'][FAIL]} fail, "
           f"{res['counts'][UNVERIFIED]} unverified, {res['counts'][NA]} n/a; {res['reject_findings']} rule violation(s), {res['owner_gate_findings']} protected-control touch(es).",
           f"Trusted base {md(s['base_ref'])} @ {str(s['base_sha'])[:12]}, merge-base {str(s['merge_base'])[:12]}. Engine {res['engine_version']} sha256 {res['engine_sha256'][:16]}. Generated {res['generated_at']}.", ""]
    for c in res["checks"]:
        out.append(f"- **{c['status']}**{' (' + c['class'] + ')' if c['class'] else ''} {c['id']}: {md(c['title'])}")
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
                out.append(f"  - [{klass or 'info'}]{' ' + rule if rule else ''} {md(loc) + ': ' if loc else ''}{md(f['msg'], 500)}")
                shown += 1
                if shown >= 14:
                    break
        for e in c["evidence"][:6]:
            out.append(f"  - evidence: {md(e)}")
    if res["owner_decisions_required"]:
        out += ["", f"Owner decisions required ({len(res['owner_decisions_required'])}):"] + [f"- {md(d, 500)}" for d in res["owner_decisions_required"][:25]]
        if len(res["owner_decisions_required"]) > 25:
            out.append(f"- ... {len(res['owner_decisions_required']) - 25} more in the JSON")
    out += ["", "Not inspected by this engine:"] + [f"- {md(n, 500)}" for n in res["not_inspected"]]
    out += ["", f"{len(res['commands'])} command(s) recorded in the JSON (argv, exit code, sha256 of output; outputs are not stored).", res["authority"]]
    return "\n".join(out) + "\n"


def main(argv=None):
    ap = argparse.ArgumentParser(description="Independent Oversight mandatory checks (read-only).")
    ap.add_argument("--sha", required=True, help="exact 40-hex head SHA under review")
    ap.add_argument("--pr", type=int)
    ap.add_argument("--repo", default=os.environ.get("OVERSIGHT_REPO", "thedonnasystem/JARVIS"))
    ap.add_argument("--repo-dir", default=REPO_ROOT)
    ap.add_argument("--base", help=f"accepted only as {' or '.join(ALLOWED_BASE_ARGS)} (the engine's fixed trusted base); anything else is refused and reported")
    ap.add_argument("--author", action="append", default=[], help="identity of the author (agent or person id). Repeatable. Compared with reviewer ids")
    ap.add_argument("--ledger", default=os.path.join(HERE, "ledger", "reviews.jsonl"))
    ap.add_argument("--registry", default=os.path.join(HERE, "dependency_provenance.json"))
    ap.add_argument("--no-github", action="store_true", help="do not call the GitHub API (CI / PR checks become UNVERIFIED)")
    ap.add_argument("--out"), ap.add_argument("--summary")
    a = ap.parse_args(argv)
    if not SHA_RE.match(a.sha):
        print("--sha must be the full 40-hex commit SHA (a branch name or short SHA can move)", file=sys.stderr)
        return 3
    probe = subprocess.run(["git", "-C", a.repo_dir, "rev-parse", "--git-dir"], capture_output=True, text=True)
    if probe.returncode != 0:
        print(f"--repo-dir {a.repo_dir} is not a git repository", file=sys.stderr)
        return 3
    for stale in (a.out, a.summary):          # a crash must not leave an earlier run's file looking like this run's result
        if stale and os.path.islink(stale):
            print(f"{stale} is a symbolic link; refusing to write through it", file=sys.stderr)
            return 3
        if stale and os.path.exists(stale):
            os.remove(stale)
    registry = None
    try:
        with open(a.registry, encoding="utf-8") as f:
            registry = json.load(f)
    except (OSError, ValueError):
        pass
    res = evaluate(Recorder(a.repo_dir), a.sha, a.pr, a.base, a.repo, not a.no_github, a.ledger, a.author[0] if a.author else None, registry, a.author[1:])
    text = json.dumps(res, indent=1, sort_keys=True) + "\n"
    if a.out:
        with open(a.out, "w", encoding="utf-8") as f:
            f.write(text)
    md_text = summary(res)
    if a.summary:
        with open(a.summary, "w", encoding="utf-8") as f:
            f.write(md_text)
    print(md_text if a.out else text, end="")
    return {"RECOMMEND_APPROVE": 0, "REJECT": 10, "NEEDS_MORE_WORK": 20}[res["verdict"]]


if __name__ == "__main__":
    sys.exit(main())
