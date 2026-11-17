"""
Self-edit pipeline (Jarvis changes his own code). DESIGNED AND TESTED, DISABLED: every entry point refuses unless JARVIS_SELFEDIT=1, the owner has
switched jarvis_core_config.self_edit_enabled on, and the token belongs to a machine account that is NOT the owner.

  1. author   a model call writes 1-5 files; hq_dev.check_files refuses secrets, keys, git internals, unapproved dependencies; the never-edit list
              (ops/PROTECTED_PATHS.json via scripts/check_protected_paths.py) refuses protected paths and destructive / protected-SQL lines OUTRIGHT.
  2. branch   jarvis/auto-<slug>-<n> from the Jarvis-owned integration branch (JARVIS_SELFEDIT_BASE, default jarvis/integration); PR opened against it.
  3. CI       every check run on the head commit must be completed + success (the repo's tests.yml: unit incl. the protected-path check, migrations, secret-scan).
  4. review   an INDEPENDENT reviewer: a different model call with the reviewer prompt; refused when it would be the same provider+model as the author.
              It must answer "VERDICT: APPROVE".
  5. re-check the PR's real file list (including old names of renames) against the never-edit list.
  6. merge    squash-merge into the Jarvis integration branch ONLY, pinned to the reviewed head SHA. Never overnight-build, never the Railway branch,
              never the default branch (FORBIDDEN_BASES).
  7. release  production only through the existing release path (DEPLOY_RUNBOOK.md: the owner merges into overnight-build / the Railway branch).
              Rollback: keep the previous release SHA, health-check after the deploy, revert automatically on failure (post_deploy_check).
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
    if not me or me == CPP.load()["owner_login"].casefold():
        raise SelfEditRefused("the self-edit token must belong to a separate machine account, not the owner (the owner's approval marker would be forgeable)")
    return gh


def base_branch(env=None) -> str:
    e = os.environ if env is None else env
    b = (e.get("JARVIS_SELFEDIT_BASE") or "jarvis/integration").strip()
    if b in FORBIDDEN_BASES or not b.startswith("jarvis/"):
        raise SelfEditRefused(f"refusing to target {b!r}: Jarvis merges only into a jarvis/ integration branch")
    return b


def screen(files: list[dict]) -> list[dict]:
    """hq_dev's checks + the never-edit list + destructive / protected-SQL lines. Any finding refuses the whole change."""
    clean, problems, _touched = hq_dev.check_files(files)
    if problems:
        raise SelfEditRefused("refused: " + " ".join(problems))
    cfg = CPP.load()
    prot = CPP.path_findings(cfg, [f["path"] for f in clean])
    if prot:
        raise SelfEditRefused("refused: protected path(s) " + ", ".join(p for _, p, _ in prot))
    for f in clean:
        for line in f["content"].splitlines():
            hits = CPP.line_findings(cfg, f["path"], line)
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
            cur = gh.call("GET", f"/contents/{f['path']}?ref={branch}")
            if isinstance(cur, dict) and cur.get("sha"):
                body["sha"] = cur["sha"]
        except urllib.error.HTTPError as e:
            if e.code != 404:
                raise
        gh.call("PUT", f"/contents/{f['path']}", body)
    pr = gh.call("POST", "/pulls", {"title": f"[Jarvis] {title[:80]}", "head": branch, "base": base, "draft": False,
                                    "body": f"{rationale.strip()[:3000]}\n\nAuthor model: {author.get('provider')}/{author.get('model')}. Auto-merge only into `{base}` after CI, "
                                            "the independent reviewer and the protected-path check pass. Rollback: revert this PR."})
    return {"number": pr["number"], "url": pr.get("html_url"), "branch": branch, "base": base, "author": author}


def ci_green(gh: GitHub, sha: str) -> tuple[bool, str]:
    runs = (gh.call("GET", f"/commits/{sha}/check-runs?per_page=100") or {}).get("check_runs") or []
    if not runs:
        return False, "no check runs yet"
    bad = [r.get("name") for r in runs if r.get("status") != "completed" or r.get("conclusion") != "success"]
    names = {r.get("name") for r in runs}
    if not {"unit", "migrations"} <= names:
        return False, "required checks unit + migrations not both present"
    return (not bad), ("" if not bad else "not green: " + ", ".join(map(str, bad)))


def review(gh: GitHub, pr: dict, author: dict, complete=None) -> dict:
    """Independent reviewer. Refuses to use the same provider+model as the author."""
    import hq_llm
    diff = gh.call("GET", f"/pulls/{pr['number']}", accept="application/vnd.github.v3.diff")
    complete = complete or (lambda system, msgs: hq_llm.complete(system, msgs, division="donna", task_class="selfedit.review", tier="medium"))
    r = complete(REVIEWER_PROMPT, [{"role": "user", "content": str(diff)[:20000]}])
    if (r.get("provider"), r.get("model")) == (author.get("provider"), author.get("model")):
        return {"approved": False, "reason": "the reviewer was the same model as the author: not independent"}
    v = re.findall(r"(?im)^\s*VERDICT:\s*(APPROVE|REJECT)\s*$", r.get("text") or "")
    return {"approved": bool(v) and v[-1].upper() == "APPROVE", "reason": "" if v else "no verdict line", "reviewer": f"{r.get('provider')}/{r.get('model')}"}


def maybe_merge(gh: GitHub, pr: dict, reviewed: dict, changelog=None, env=None) -> dict:
    """Merge only when everything holds; pinned to the reviewed head SHA so a later push cannot ride along."""
    changelog = changelog or (lambda kind, ref, summary: hq._request("POST", "/rest/v1/rpc/jarvis_changelog_add", {"p_kind": kind, "p_ref": ref, "p_summary": summary}))
    info = gh.call("GET", f"/pulls/{pr['number']}")
    base, head = info["base"]["ref"], info["head"]["sha"]
    if base in FORBIDDEN_BASES or base != base_branch(env):
        return _refuse(changelog, pr, f"base {base} is not the Jarvis integration branch")
    if not reviewed.get("approved"):
        return _refuse(changelog, pr, "independent review did not approve: " + str(reviewed.get("reason")))
    ok, why = ci_green(gh, head)
    if not ok:
        return {"merged": False, "reason": why}          # not a refusal: CI may still be running
    files = gh.call("GET", f"/pulls/{pr['number']}/files?per_page=100") or []
    paths = [f.get("filename") for f in files] + [f.get("previous_filename") for f in files if f.get("previous_filename")]
    prot = CPP.path_findings(CPP.load(), paths)
    if prot or any(f.get("status") == "removed" for f in files):
        return _refuse(changelog, pr, "protected or deleted path in the PR: " + ", ".join(p for _, p, _ in prot))
    gh.call("PUT", f"/pulls/{pr['number']}/merge", {"merge_method": "squash", "sha": head, "commit_title": f"[Jarvis] auto-merge #{pr['number']}"})
    changelog("self_edit_merge", pr.get("url") or f"#{pr['number']}", f"merged #{pr['number']} into {base} (reviewer {reviewed.get('reviewer')})")
    return {"merged": True, "sha": head}


def _refuse(changelog, pr, why):
    try:
        changelog("self_edit_refused", pr.get("url") or f"#{pr['number']}", why[:900])
    except Exception:
        logger.warning("changelog write failed")
    return {"merged": False, "refused": True, "reason": why}


def post_deploy_check(health, revert, previous_sha: str, attempts: int = 3, wait_s: float = 20.0, sleep=time.sleep, changelog=None) -> dict:
    """After a release: health() -> bool, up to `attempts` times. On failure revert(previous_sha) and log a rollback. Production deploys themselves
    happen only through the existing release path; this is the automatic safety net the release runner calls."""
    changelog = changelog or (lambda kind, ref, summary: hq._request("POST", "/rest/v1/rpc/jarvis_changelog_add", {"p_kind": kind, "p_ref": ref, "p_summary": summary}))
    for i in range(attempts):
        try:
            if health():
                changelog("deploy", None, "release healthy")
                return {"healthy": True}
        except Exception:
            pass
        if i < attempts - 1:
            sleep(wait_s)
    revert(previous_sha)
    changelog("rollback", previous_sha, f"health check failed {attempts} times: reverted to {previous_sha[:12]}")
    return {"healthy": False, "rolled_back_to": previous_sha}


def draft_automation(candidate: dict, gh: GitHub | None = None, complete=None) -> str | None:
    """Self-automation (E): ask the author model for plain code that replaces a repeated AI task class, then send it through this pipeline.
    Never for protected classes (the database and hq_core already filter; checked again here). Returns the PR url or None."""
    cls = str(candidate.get("task_class") or "")
    prot = CPP.load().get("protected_task_classes") or []
    if not cls or any(cls.startswith(p) for p in prot):
        raise SelfEditRefused(f"task class {cls!r} is protected")
    gh = gh or setup()
    import hq_llm
    complete = complete or (lambda system, msgs: hq_llm.complete(system, msgs, division="donna", task_class="selfedit.author", tier="medium"))
    r = complete(AUTHOR_PROMPT, [{"role": "user", "content": f"Task class '{cls}' ran {candidate.get('runs')} times with a model. Write a plain-Python handler "
                                                              f"`automations/{cls.replace('.', '_')}.py` with a function run(payload) -> dict and a unittest file for it."}])
    files = parse_files(r.get("text") or "")
    if not files:
        return None
    pr = open_pr(gh, f"automate {cls}", f"Replaces the model for repeated task class {cls} ({candidate.get('runs')} runs, {candidate.get('cost_cents')} cents).",
                 files, {"provider": r.get("provider"), "model": r.get("model")})
    return pr.get("url")
