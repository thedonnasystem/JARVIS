"""
Self-edit pipeline (Jarvis changes his own code). DESIGNED AND TESTED, DISABLED: every entry point refuses unless JARVIS_SELFEDIT=1, the owner has
switched jarvis_core_config.self_edit_enabled on, and the token belongs to a machine account that is NOT the owner.

  1. author   a model call writes 1-5 files; hq_dev.check_files refuses secrets, keys, git internals, unapproved dependencies; the never-edit list
              (ops/PROTECTED_PATHS.json via scripts/check_protected_paths.py) refuses protected paths and destructive / protected-SQL lines OUTRIGHT.
  2. branch   jarvis/auto-<slug>-<n> from the Jarvis-owned integration branch (JARVIS_SELFEDIT_BASE, default jarvis/integration); PR opened against it.
  3. CI       every check run on the head commit must be completed + success (the repo's tests.yml: unit incl. the protected-path check, migrations, secret-scan).
  4. review   an INDEPENDENT reviewer: a different model call with the reviewer prompt; refused when it would be the same provider+model as the author.
              It must answer "VERDICT: APPROVE".
              The reviewer gets the WHOLE diff of the exact commit it reviews (compare base...sha); a diff over MAX_REVIEW_CHARS is refused, never cut.
              The verdict must be exactly one VERDICT line, and it must be the last line.
  5. re-check the PR's real file list (ALL pages, including old names of renames) against the never-edit list and, in allowlist mode
              (ops/SELF_EDIT_MODE), the auto-ship zone.
  6. merge    squash-merge into the Jarvis integration branch ONLY, pinned to the REVIEWED commit SHA: if the head moved since the review, abort.
              Never overnight-build, never the Railway branch, never the default branch (FORBIDDEN_BASES).
  7. release  production only through the existing release path (DEPLOY_RUNBOOK.md: the owner merges into overnight-build / the Railway branch).
              Rollback: keep the previous release SHA, health-check after the deploy; on failure post_deploy_check OPENS the revert for the owner's
              one-tap approval (it never deploys by itself) and alerts him.
  8. log      every merge / refusal / rollback is a jarvis_changelog row, which the 07:00 report lists.

Env (names only): JARVIS_GITHUB_TOKEN (fine-grained, this repo only: Contents read/write, Pull requests read/write, Checks read), GITHUB_REPO (owner/name),
JARVIS_SELFEDIT_BASE, JARVIS_SELFEDIT=1.
"""
from __future__ import annotations

import base64
import json
import logging
import os
import re
import sys
import time
import urllib.error
import urllib.request

import hq
import hq_dev

logger = logging.getLogger(__name__)
sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "scripts"))
import check_protected_paths as CPP  # noqa: E402

API = "https://api.github.com"
FORBIDDEN_BASES = frozenset({"overnight-build", "claude/telegram-claude-bot-59nusk", "main", "master"})
MAX_REVIEW_CHARS = 60_000          # the reviewer sees the whole diff or nothing: larger changes are refused, never truncated
MAX_PR_FILES = 300
REVIEWER_PROMPT = """You are an independent code reviewer for Fendezy HQ. You did NOT write this change. Review the diff for correctness, security,
cost, and whether it touches money, permissions, consent, privacy, backups, tests or CI (it must not). Reply with your findings, then exactly one line:
VERDICT: APPROVE   or   VERDICT: REJECT"""
AUTHOR_PROMPT = """You write small, plain, tested Python changes for Fendezy HQ. Never touch money controls, permissions, consent, privacy, backups,
tests that guard them, CI, or migrations. Output files as:
FILE: <path>
<content>
END FILE"""


class SelfEditRefused(Exception):
    pass


class GitHub:
    def __init__(self, token: str, repo: str, opener=None):
        self.token, self.repo, self.opener = token, repo, opener

    def call(self, method: str, path: str, body: dict | None = None, accept: str = "application/vnd.github+json", full: bool = False):
        url = path if path.startswith("http") else (f"{API}{path}" if path.startswith("/user") else f"{API}/repos/{self.repo}{path}")
        if self.opener:
            return self.opener(method, url, body, accept)
        req = urllib.request.Request(url, method=method, data=json.dumps(body).encode() if body is not None else None)
        req.add_header("Authorization", f"Bearer {self.token}")
        req.add_header("Accept", accept)
        req.add_header("User-Agent", "jarvis-selfedit")
        with urllib.request.urlopen(req, timeout=30) as r:
            raw = r.read()
            return raw.decode() if accept.endswith("diff") else (json.loads(raw) if raw else None)


def _cfg_enabled(status=None) -> bool:
    try:
        st = status() if status else (hq._request("POST", "/rest/v1/rpc/jarvis_core_status", {}) or {})
    except Exception:
        return False
    return bool((st.get("config") or {}).get("self_edit_enabled"))


def setup(env=None, status=None, opener=None) -> GitHub:
    """Refuses unless the pipeline is switched on in BOTH places and the token is not the owner's."""
    e = os.environ if env is None else env
    if e.get("JARVIS_SELFEDIT") != "1":
        raise SelfEditRefused("self-edit is disabled (JARVIS_SELFEDIT is not 1)")
    if not (e.get("JARVIS_GITHUB_TOKEN") and e.get("GITHUB_REPO")):
        raise SelfEditRefused("JARVIS_GITHUB_TOKEN / GITHUB_REPO not set")
    if not _cfg_enabled(status):
        raise SelfEditRefused("self-edit is switched off in jarvis_core_config (owner only)")
    gh = GitHub(e["JARVIS_GITHUB_TOKEN"], e["GITHUB_REPO"], opener)
    me = ((gh.call("GET", "/user") or {}).get("login") or "").casefold()
    cfg = CPP.load()
    if not me or me == (cfg.get("owner_login") or "").casefold() or me in {a.casefold() for a in cfg.get("agent_logins") or []}:
        raise SelfEditRefused("the self-edit token must belong to a separate machine account, not the owner (the owner's approval marker would be forgeable)")
    return gh


def base_branch(env=None) -> str:
    e = os.environ if env is None else env
    b = (e.get("JARVIS_SELFEDIT_BASE") or "jarvis/integration").strip()
    if b in FORBIDDEN_BASES or not b.startswith("jarvis/"):
        raise SelfEditRefused(f"refusing to target {b!r}: Jarvis merges only into a jarvis/ integration branch")
    return b


def screen(files: list[dict]) -> list[dict]:
    """hq_dev's checks + the never-edit list + path syntax + (allowlist mode) the auto-ship zone + destructive / protected-SQL / monkey-patch lines.
    Any finding refuses the whole change."""
    cfg = CPP.load()
    prot = CPP.path_findings(cfg, [str(f.get("path") or "") for f in files], selfedit=True)
    if prot:
        raise SelfEditRefused("refused: " + "; ".join(f"{p}: {why}" for _, p, why in prot)[:900])
    clean, problems, _touched = hq_dev.check_files(files)
    if problems:
        raise SelfEditRefused("refused: " + " ".join(problems))
    if [f["path"] for f in clean] != [f["path"] for f in files]:
        raise SelfEditRefused("refused: hq_dev changed the file list")
    for f in clean:
        lines = f["content"].splitlines()
        for line in lines:
            hits = CPP.line_findings(cfg, f["path"], line)
            if hits:
                raise SelfEditRefused(f"refused: {f['path']}: {hits[0][1]}")
        hits = CPP.window_findings(cfg, f["path"], lines)
        if hits:
            raise SelfEditRefused(f"refused: {f['path']}: {hits[0][1]}")
    return clean


def parse_files(text: str) -> list[dict]:
    return [{"path": m.group(1).strip(), "content": m.group(2)} for m in re.finditer(r"(?ms)^FILE:\s*(\S+)\s*\n(.*?)\nEND FILE\s*$", text or "")]


def open_pr(gh: GitHub, title: str, rationale: str, files: list[dict], author: dict, env=None) -> dict:
    clean = screen(files)
    base = base_branch(env)
    sha = gh.call("GET", f"/git/ref/heads/{base}")["object"]["sha"]
    branch = f"jarvis/auto-{re.sub(r'[^a-z0-9]+', '-', title.lower()).strip('-')[:40]}-{int(time.time()) % 100000}"
    gh.call("POST", "/git/refs", {"ref": f"refs/heads/{branch}", "sha": sha})
    for f in clean:
        body = {"message": f"Jarvis: {title[:70]}", "branch": branch, "content": base64.b64encode(f["content"].encode()).decode()}
        try:
            cur = gh.call("GET", f"/contents/{_q(f['path'])}?ref={_q(branch)}")
            if isinstance(cur, dict) and cur.get("sha"):
                body["sha"] = cur["sha"]
        except urllib.error.HTTPError as e:
            if e.code != 404:
                raise
        gh.call("PUT", f"/contents/{_q(f['path'])}", body)
    pr = gh.call("POST", "/pulls", {"title": f"[Jarvis] {title[:80]}", "head": branch, "base": base, "draft": False,
                                    "body": f"{rationale.strip()[:3000]}\n\nAuthor model: {author.get('provider')}/{author.get('model')}. Auto-merge only into `{base}` after CI, "
                                            "the independent reviewer and the protected-path check pass. Rollback: revert this PR."})
    return {"number": pr["number"], "url": pr.get("html_url"), "branch": branch, "base": base, "author": author}


def _q(path: str) -> str:
    """Percent-encode each path segment (screen() already refused '#', '?', '%', '..' and control characters; this is the second wall)."""
    import urllib.parse
    return "/".join(urllib.parse.quote(seg, safe="") for seg in path.split("/"))


REQUIRED_CHECKS = {"unit", "migrations", "protected-paths"}


def ci_green(gh: GitHub, sha: str) -> tuple[bool, str]:
    runs = (gh.call("GET", f"/commits/{sha}/check-runs?per_page=100") or {}).get("check_runs") or []
    if not runs:
        return False, "no check runs yet"
    bad = [r.get("name") for r in runs if r.get("status") != "completed" or r.get("conclusion") != "success"]
    names = {r.get("name") for r in runs}
    if not REQUIRED_CHECKS <= names:
        return False, "required checks not all present: " + ", ".join(sorted(REQUIRED_CHECKS - names))
    return (not bad), ("" if not bad else "not green: " + ", ".join(map(str, bad)))


def review(gh: GitHub, pr: dict, author: dict, complete=None) -> dict:
    """Independent reviewer of ONE exact commit. Refuses to use the same provider+model as the author. Returns {"approved", "sha", ...}:
    maybe_merge merges only that sha."""
    import hq_llm
    info = gh.call("GET", f"/pulls/{pr['number']}")
    sha, base_sha = info["head"]["sha"], info["base"]["sha"]
    if not (re.fullmatch(r"[0-9a-f]{40}", sha or "") and re.fullmatch(r"[0-9a-f]{40}", base_sha or "")):
        return {"approved": False, "reason": "no head / base sha"}
    diff = str(gh.call("GET", f"/compare/{base_sha}...{sha}", accept="application/vnd.github.v3.diff") or "")
    if not diff.strip():
        return {"approved": False, "sha": sha, "reason": "empty diff"}
    if len(diff) > MAX_REVIEW_CHARS:
        return {"approved": False, "sha": sha, "reason": f"diff is {len(diff)} characters, over the reviewer limit {MAX_REVIEW_CHARS}: refused (never truncated)"}
    complete = complete or (lambda system, msgs: hq_llm.complete(system, msgs, division="donna", task_class="selfedit.review", tier="medium",
                                                                 sources=["repo_code"]))
    r = complete(REVIEWER_PROMPT, [{"role": "user", "content": diff}])
    if (r.get("provider"), r.get("model")) == (author.get("provider"), author.get("model")) or r.get("model") == author.get("model"):
        return {"approved": False, "sha": sha, "reason": "the reviewer was the same model as the author: not independent"}
    text = (r.get("text") or "").strip()
    v = re.findall(r"(?im)^\s*VERDICT:\s*(APPROVE|REJECT)\s*$", text)
    last = text.splitlines()[-1].strip() if text else ""
    if len(v) != 1 or not re.fullmatch(r"(?i)VERDICT:\s*(APPROVE|REJECT)", last):
        return {"approved": False, "sha": sha, "reason": "the review must end with exactly one VERDICT line"}
    return {"approved": v[0].upper() == "APPROVE", "sha": sha, "reason": "" if v[0].upper() == "APPROVE" else "reviewer rejected",
            "reviewer": f"{r.get('provider')}/{r.get('model')}"}


def pr_files(gh: GitHub, number: int) -> list[dict]:
    """Every file of the PR (all pages). More than MAX_PR_FILES: refused by the caller."""
    out = []
    for page in range(1, MAX_PR_FILES // 100 + 2):
        batch = gh.call("GET", f"/pulls/{number}/files?per_page=100&page={page}") or []
        out += batch
        if len(batch) < 100:
            return out
    raise SelfEditRefused(f"more than {MAX_PR_FILES} files: refused")


def maybe_merge(gh: GitHub, pr: dict, reviewed: dict, changelog=None, env=None) -> dict:
    """Merge only when everything holds, and only the commit the reviewer saw: a head that moved after the review aborts the merge."""
    changelog = changelog or (lambda kind, ref, summary: hq._request("POST", "/rest/v1/rpc/jarvis_changelog_add", {"p_kind": kind, "p_ref": ref, "p_summary": summary}))
    info = gh.call("GET", f"/pulls/{pr['number']}")
    base, head = info["base"]["ref"], info["head"]["sha"]
    if base in FORBIDDEN_BASES or base != base_branch(env):
        return _refuse(changelog, pr, f"base {base} is not the Jarvis integration branch")
    if not reviewed.get("approved"):
        return _refuse(changelog, pr, "independent review did not approve: " + str(reviewed.get("reason")))
    sha = reviewed.get("sha") or ""
    if not re.fullmatch(r"[0-9a-f]{40}", sha):
        return _refuse(changelog, pr, "the review names no commit")
    if head != sha:
        return _refuse(changelog, pr, f"head moved after the review ({sha[:12]} reviewed, {head[:12]} now): not merged, review again")
    ok, why = ci_green(gh, sha)
    if not ok:
        return {"merged": False, "reason": why}          # not a refusal: CI may still be running
    try:
        files = pr_files(gh, pr["number"])
    except SelfEditRefused as e:
        return _refuse(changelog, pr, str(e))
    paths = [f.get("filename") for f in files] + [f.get("previous_filename") for f in files if f.get("previous_filename")]
    prot = CPP.path_findings(CPP.load(), paths, selfedit=True)
    if prot or any(f.get("status") == "removed" for f in files):
        return _refuse(changelog, pr, "protected, out-of-zone or deleted path in the PR: " + ", ".join(f"{p} ({why})" for _, p, why in prot)[:800])
    gh.call("PUT", f"/pulls/{pr['number']}/merge", {"merge_method": "squash", "sha": sha, "commit_title": f"[Jarvis] auto-merge #{pr['number']}"})
    changelog("self_edit_merge", pr.get("url") or f"#{pr['number']}", f"merged #{pr['number']} at {sha[:12]} into {base} (reviewer {reviewed.get('reviewer')})")
    return {"merged": True, "sha": sha}


def _refuse(changelog, pr, why):
    try:
        changelog("self_edit_refused", pr.get("url") or f"#{pr['number']}", why[:900])
    except Exception:
        logger.warning("changelog write failed")
    return {"merged": False, "refused": True, "reason": why}


def post_deploy_check(health, open_revert, previous_sha: str, attempts: int = 3, wait_s: float = 20.0, sleep=None, changelog=None, alert=None) -> dict:
    """After a release: health() -> bool, up to `attempts` times. Healthy = healthy, whatever happens to the changelog write.
    Unhealthy: open_revert(previous_sha) OPENS the revert for the owner's one-tap approval (owner guide section 6; it never deploys by itself),
    then a rollback changelog row and an owner alert. A failing open_revert / changelog / alert is reported, never raised."""
    changelog = changelog or (lambda kind, ref, summary: hq._request("POST", "/rest/v1/rpc/jarvis_changelog_add", {"p_kind": kind, "p_ref": ref, "p_summary": summary}))
    sleep = sleep or time.sleep
    if alert is None:
        def alert(text):
            import hq_core
            hq_core.send_owner(text, urgency="critical", kind="emergency")

    def _safe(fn, *a):
        try:
            fn(*a)
            return True
        except Exception:
            logger.warning("post_deploy_check: %s failed", getattr(fn, "__name__", "step"))
            return False
    for i in range(attempts):
        try:
            ok = bool(health())
        except Exception:
            ok = False
        if ok:
            _safe(changelog, "deploy", None, "release healthy")
            return {"healthy": True}
        if i < attempts - 1:
            sleep(wait_s)
    opened = _safe(open_revert, previous_sha)
    _safe(changelog, "rollback", previous_sha, f"health check failed {attempts} times: revert to {previous_sha[:12]} " + ("opened for the owner's approval" if opened else "could NOT be opened"))
    _safe(alert, f"Sir, the release failed its health check {attempts} times. " + (f"A revert to {previous_sha[:12]} is waiting for your approval." if opened
                 else f"I could not open the revert to {previous_sha[:12]}: please roll back by hand (DEPLOY_RUNBOOK.md)."))
    return {"healthy": False, "revert_opened": opened, "rollback_to": previous_sha}


def is_protected_class(cls: str, prot: list[str] | None = None) -> bool:
    """By CATEGORY, not prefix: any dot / dash / underscore separated word of the class that is a protected word (lead.payment.reminder: 'payment')."""
    prot = [p.lower() for p in (prot if prot is not None else (CPP.load().get("protected_task_classes") or []))]
    c = (cls or "").lower()
    words = [w for w in re.split(r"[._\-]+", c) if w]
    return not words or any(w in prot for w in words) or any(c.startswith(p) for p in prot)


def draft_automation(candidate: dict, gh: GitHub | None = None, complete=None) -> str | None:
    """Self-automation (E): ask the author model for plain code that replaces a repeated AI task class, then send it through this pipeline.
    Never for protected classes (the database and hq_core already filter; checked again here). Returns the PR url or None."""
    cls = str(candidate.get("task_class") or "")
    if not cls or is_protected_class(cls):
        raise SelfEditRefused(f"task class {cls!r} is protected")
    gh = gh or setup()
    import hq_llm
    complete = complete or (lambda system, msgs: hq_llm.complete(system, msgs, division="donna", task_class="selfedit.author", tier="medium", sources=["task_stats"]))
    r = complete(AUTHOR_PROMPT, [{"role": "user", "content": f"Task class '{cls}' ran {candidate.get('runs')} times with a model. Write a plain-Python handler "
                                                              f"`jarvis_skills/{re.sub(r'[^a-z0-9_]', '_', cls.lower())}.py` with a function run(payload) -> dict, standard library only "
                                                              f"(json, math, re, datetime, statistics, collections, itertools, functools, string, textwrap, decimal), no I/O."}])
    files = parse_files(r.get("text") or "")
    if not files:
        return None
    pr = open_pr(gh, f"automate {cls}", f"Replaces the model for repeated task class {cls} ({candidate.get('runs')} runs, {candidate.get('cost_cents')} cents).",
                 files, {"provider": r.get("provider"), "model": r.get("model")})
    return pr.get("url")
