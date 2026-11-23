"""Office Doctor: why is a legacy office broken or idle, and what fixes it first.  /doctor <office>  and  /doctor all

Checks (each -> ok / warn / fail / unknown, with a plain fix):
  activity      last commit on the legacy repo
  last_run      last successful run, recent failures and the failure reason GitHub gives (Actions-hosted offices); Railway-hosted offices
                have no telemetry Jarvis can read, which is itself a finding
  env           the env / secret NAMES the system needs (never values); Actions secrets are compared when GitHub lets us list names
  tests         the repo's own tests in a local clone (runner.py: empty environment, timeout); missing tests are a finding
  data          age of the office's data file (last commit that touched it)
  spend         spend vs cap: GitHub Actions minutes over the last 30 days vs the free quota; declared caps
  deps          unpinned / unlocked dependencies in the clone
Read-only. Nothing is deployed, sent, bought or changed. The optional improvement plan (plan()) goes through hq_llm's free-brain routing with
code structure and redacted error text only; it is refused if anything still looks personal.
"""
from __future__ import annotations

import json
import os
import re
from datetime import datetime, timedelta, timezone

from legacy_offices import ghapi, redact, registry

SEV = {"fail": 3, "warn": 2, "unknown": 1, "ok": 0}
BILLING = re.compile(r"(?i)payments have failed|spending limit|billing")


def _f(check, status, detail, fix=""):
    return {"check": check, "status": status, "detail": detail, "fix": fix}


def _ts(s):
    try:
        return datetime.fromisoformat(str(s).replace("Z", "+00:00"))
    except (TypeError, ValueError):
        return None


def _days(then, now):
    return (now - then).total_seconds() / 86400 if then else None


# ------------------------------------------------------------------------------------------------------------------- checks
def check_activity(o, gh, now):
    repo = o["legacy"]["repo"]
    data, err = gh(f"/repos/{repo}/commits?per_page=1")
    if err or not data:
        return _f("activity", "unknown", f"could not read the last commit ({err or 'empty'})", "give Jarvis a read-only GitHub token on the legacy repos (LEGACY_GITHUB_TOKEN)")
    when = _ts(((data[0].get("commit") or {}).get("committer") or {}).get("date"))
    age = _days(when, now)
    if age is not None and age > 60:
        return _f("activity", "warn", f"last commit {when:%Y-%m-%d} ({age:.0f} days ago): nobody has touched it in two months", "decide keep / fix / kill (/qc)")
    return _f("activity", "ok", f"last commit {when:%Y-%m-%d}" if when else "last commit date unknown")


def host_state() -> dict:
    """Optional host observations {slug: {deployed, note, checked}} from LEGACY_HOST_STATE (a JSON file an operator or a read-only Railway check
    writes). Jarvis cannot read Railway itself; without this file Railway-hosted offices stay 'unknown'."""
    path = os.environ.get("LEGACY_HOST_STATE", "")
    try:
        return json.load(open(path, encoding="utf-8")) if path else {}
    except (OSError, ValueError):
        return {}


def _run_minutes(r):
    a, b = _ts(r.get("run_started_at")), _ts(r.get("updated_at"))
    return max((b - a).total_seconds() / 60, 0) if a and b else 0.0


def check_runs(o, gh, now):
    """-> list of findings (last_run, spend)."""
    lg = o["legacy"]
    if lg.get("hosting") != "github-actions":
        where = lg.get("railway_project") or lg.get("hosting") or "unknown host"
        seen = host_state().get(o["office"])
        if seen:
            dep = seen.get("deployed")
            return [_f("last_run", "ok" if dep else "fail", f"{where}: {seen.get('note', '')} (host checked {seen.get('checked', '?')})",
                       "" if dep else "redeploy the service once its keys are set (owner authorizes the deploy)")]
        return [_f("last_run", "unknown", f"runs on Railway ({where}); Jarvis has no run telemetry for it, so a silent stop would go unnoticed",
                   "add a heartbeat: the service posts a daily 'alive + counts' line Jarvis can read, or give Jarvis a read-only Railway token")]
    repo = lg["repo"]
    data, err = gh(f"/repos/{repo}/actions/runs?per_page=40")
    if err or not data:
        return [_f("last_run", "unknown", f"could not read the Actions runs ({err or 'empty'})", "give Jarvis a read-only GitHub token (LEGACY_GITHUB_TOKEN)")]
    runs = data.get("workflow_runs") or []
    done = [r for r in runs if r.get("status") == "completed"]
    ok = [r for r in done if r.get("conclusion") == "success"]
    last_ok = _ts(ok[0].get("updated_at")) if ok else None
    fails = 0
    for r in done:
        if r.get("conclusion") == "success":
            break
        fails += 1
    out = []
    if fails:
        why = ""
        rid = done[0].get("id")
        jobs, _ = gh(f"/repos/{repo}/actions/runs/{rid}/jobs")
        for j in (jobs or {}).get("jobs", [])[:2]:
            ann, _ = gh(f"/repos/{repo}/check-runs/{j.get('id')}/annotations")
            msgs = [a.get("message", "") for a in (ann or []) if isinstance(a, dict)]
            if msgs:
                why = redact.text(msgs[0])[:240]
                break
            failed = [s.get("name") for s in j.get("steps", []) if s.get("conclusion") == "failure"]
            if failed:
                why = f"step '{failed[0]}' failed"
                break
        fix = "owner: GitHub Settings > Billing: fix the failed payment or raise the Actions spending limit (see spend below)" if BILLING.search(why) \
            else "read the failed step's log and fix it; the run is red until then"
        out.append(_f("last_run", "fail", f"{fails} failed run(s) in a row; last success {last_ok:%Y-%m-%d}" if last_ok else f"{fails} failed run(s), no success in view",
                      fix) | {"reason": why or "no reason given"})
    else:
        age = _days(last_ok, now)
        out.append(_f("last_run", "ok" if age is not None and age < 2 else "warn", f"last success {last_ok:%Y-%m-%d %H:%M} UTC" if last_ok else "no completed run in view",
                      "" if age is not None and age < 2 else "the schedule has not produced a run lately: check the cron and the Actions tab"))
    # spend vs cap: Actions minutes, last 30 days, projected to a month
    cut = now - timedelta(days=30)
    recent = [r for r in done if (_ts(r.get("run_started_at")) or now) >= cut]
    mins = sum(_run_minutes(r) for r in recent)
    span = max(min(30.0, _days(min((_ts(r.get("run_started_at")) for r in recent), default=now), now) or 1.0), 1.0)
    month = mins / span * 30
    quota = float(lg.get("actions_free_minutes") or 2000)
    status = "fail" if month > quota else "warn" if month > 0.8 * quota else "ok"
    out.append(_f("spend", status, f"GitHub Actions: about {mins:.0f} min in the last {span:.0f} days, {month:.0f} min/month projected vs {quota:.0f} free",
                  "" if status == "ok" else f"over the free tier by about {max(month - quota, 0):.0f} min/month: owner pays for the overage, or the run gets shorter / less frequent")
               | {"minutes_month": round(month), "quota": quota})
    return out


def check_env(o, gh):
    lg = o["legacy"]
    need = list(lg.get("env") or [])
    secrets = lg.get("secrets") or []
    if lg.get("hosting") == "github-actions" and secrets:
        data, err = gh(f"/repos/{lg['repo']}/actions/secrets")
        if data and not err:
            have = {s.get("name") for s in data.get("secrets", [])}
            miss = [s for s in secrets if s not in have]
            return _f("env", "fail" if miss else "ok", f"Actions secrets missing: {', '.join(miss)}" if miss else f"Actions secrets present: {', '.join(secrets)}",
                      "owner: add them under the repo's Settings > Secrets" if miss else "")
    return _f("env", "unknown", f"needs (names only): {', '.join(need)}" if need else "no variables declared",
              "owner: confirm these are set on the host; Jarvis cannot read another service's variables" if need else "")


def check_tests(o, root, run):
    lg = o["legacy"]
    cmds = lg.get("tests") or []
    if not cmds:
        return _f("tests", "warn", "the repo has no automated tests", "add a small test suite (filters, parsing, dedupe) so a change cannot silently break it")
    if not root:
        return _f("tests", "unknown", f"{len(cmds)} test command(s) declared; no local clone here (LEGACY_SRC_DIR)", "")
    if run is None:
        from legacy_offices import runner
        run = runner.run
    bad, tails, nodeps = [], [], []
    for c in cmds:
        r = run(c, root, lg.get("tests_cwd", "."), {}, 600)
        if not r.get("ok") and re.search(r"ModuleNotFoundError|Cannot find module|No module named", r.get("out", "")):
            nodeps.append(" ".join(c))
        elif not r.get("ok"):
            bad.append(" ".join(c))
            tails.append(r.get("out", "")[-300:])
    if nodeps and not bad:
        return _f("tests", "unknown", f"{len(nodeps)} test command(s) could not run here: the repo's dependencies are not installed in this environment",
                  "run the tests where the repo's requirements are installed (its own CI or host)")
    if bad:
        return _f("tests", "fail", f"{len(bad)} of {len(cmds)} test command(s) fail: {'; '.join(bad)}", "fix the failing tests before the next run") | {"output": tails[0]}
    return _f("tests", "ok", f"{len(cmds)} test command(s) pass")


def check_data(o, gh, now):
    lg = o["legacy"]
    path = lg.get("data_freshness_path")
    if not path:
        return None
    data, err = gh(f"/repos/{lg['repo']}/commits?path={path}&per_page=1")
    if err or not data:
        return _f("data", "unknown", f"could not date {path} ({err or 'never committed'})")
    when = _ts(((data[0].get("commit") or {}).get("committer") or {}).get("date"))
    age = _days(when, now) or 0
    limit = float(lg.get("fresh_days") or 2)
    return _f("data", "ok" if age <= limit else "fail", f"{path} last updated {when:%Y-%m-%d} ({age:.1f} days)",
              "" if age <= limit else "data is stale: the daily run is not landing (see last_run)")


UNPINNED = re.compile(r"^\s*([A-Za-z0-9_.\-\[\]]+)\s*(>=|>|~=)?\s*([^;#\s]*)")


def check_deps(o, root):
    lg = o["legacy"]
    files = lg.get("dependency_files") or []
    if not root or not files:
        return None
    loose, notes = [], []
    for rel in files:
        p = os.path.join(root, rel)
        if not os.path.isfile(p):
            continue
        if rel.endswith(".txt"):
            for line in open(p, encoding="utf-8", errors="replace"):
                line = line.split("#", 1)[0].strip()
                if line and "==" not in line:
                    loose.append(line.split(";")[0].strip())
        elif rel.endswith("package.json"):
            lock = os.path.join(os.path.dirname(p), "package-lock.json")
            if not os.path.isfile(lock):
                notes.append(f"{rel} has no package-lock.json")
    if notes or len(loose) > 2:
        return _f("deps", "warn", "; ".join(filter(None, [f"{len(loose)} unpinned Python dependencies ({', '.join(loose[:4])})" if loose else "", *notes])),
                  "pin exact versions (pip freeze > requirements.lock) so a new upstream release cannot break the daily run")
    return _f("deps", "ok", "dependencies pinned or locked")


# ------------------------------------------------------------------------------------------------------------------- diagnosis
def examine(slug: str, *, gh=None, run=None, src_dir=None, now=None) -> dict:
    """All checks for one office -> {office, title, status, diagnosis, findings, fixes}."""
    gh = gh or ghapi.get
    now = now or datetime.now(timezone.utc)
    o = registry.office(slug)
    if not o.get("viable"):
        return {"office": slug, "title": slug, "status": "not viable", "diagnosis": o.get("why_not", ""), "findings": [], "fixes": ["kill it as an office (owner decision)"]}
    root = registry.checkout(slug, src_dir)
    fs = [check_activity(o, gh, now), *check_runs(o, gh, now), check_env(o, gh), check_tests(o, root, run), check_data(o, gh, now), check_deps(o, root)]
    fs = [f for f in fs if f]
    worst = max((SEV[f["status"]] for f in fs), default=0)
    status = {3: "broken", 2: "degraded", 1: "unverified", 0: "healthy"}[worst]
    ranked = sorted([f for f in fs if f.get("fix")], key=lambda f: -SEV[f["status"]])
    return {"office": slug, "title": o["title"], "status": status, "diagnosis": diagnose(o["title"], status, fs), "findings": fs,
            "fixes": [f["fix"] for f in ranked]}


def diagnose(title: str, status: str, fs: list[dict]) -> str:
    bad = [f for f in fs if f["status"] == "fail"]
    soft = [f for f in fs if f["status"] == "warn"]
    if status == "healthy":
        return f"{title} is technically healthy: every check passed."
    parts = [f"{title} is {status}."]
    if bad:
        parts.append("Broken: " + "; ".join(f"{f['check']}: {f['detail']}" + (f" ({f['reason']})" if f.get("reason") else "") for f in bad) + ".")
    if soft:
        parts.append("Weak: " + "; ".join(f"{f['check']}: {f['detail']}" for f in soft) + ".")
    unk = [f["check"] for f in fs if f["status"] == "unknown"]
    if unk:
        parts.append("Not verifiable from here: " + ", ".join(unk) + ".")
    return " ".join(parts)


def text(rep: dict) -> str:
    lines = [f"Doctor: {rep['title']} ({rep['office']}) - {rep['status'].upper()}", rep["diagnosis"]]
    if rep["fixes"]:
        lines.append("Fix first:")
        lines += [f"{i}. {x}" for i, x in enumerate(rep["fixes"][:5], 1)]
    return "\n".join(lines)


def all_text(reports: list[dict]) -> str:
    head = ["Doctor: all legacy offices"] + [f"- {r['title']}: {r['status']}" + (f" -> {r['fixes'][0]}" if r["fixes"] else "") for r in reports]
    return "\n".join(head)


# ------------------------------------------------------------------------------------------------------------------- optional plan (free brain)
PLAN_SYSTEM = ("You are a principal engineer. From the office's stack, entry points and redacted health findings, write a short improvement plan: "
               "5 numbered steps, cheapest first, each with the expected effect and effort. No secrets, no personal data, no spending, no deploys.")


def plan_prompt(slug: str, rep: dict) -> str:
    o = registry.office(slug)
    lg = o.get("legacy", {})
    body = {"office": o.get("title"), "stack": lg.get("stack"), "entry_points": lg.get("entry_points"), "hosting": lg.get("hosting"),
            "findings": [{k: f.get(k) for k in ("check", "status", "detail", "reason", "fix") if f.get(k)} for f in rep.get("findings", [])]}
    return redact.text(json.dumps(body, ensure_ascii=False))


def plan(slug: str, rep: dict, complete=None) -> str:
    """Draft an improvement plan with the free brain. Only code structure + redacted errors are sent (sources: system, repo_code)."""
    prompt = plan_prompt(slug, rep)
    if redact.looks_private(prompt):
        return "Plan not drafted: the findings still look like they hold private data, so nothing was sent to a model."
    if complete is None:
        import hq_llm
        complete = hq_llm.complete
    try:
        r = complete(PLAN_SYSTEM, [{"role": "user", "content": prompt}], division="doctor", task_class="office_doctor_plan", tier="small",
                     sources=["system", "repo_code"], max_output=600)
        return (r or {}).get("text") or "The model returned nothing."
    except Exception as e:  # BrainOffline / exhausted / refused / meter: say so plainly, never crash the command
        return f"Plan not drafted: {type(e).__name__}: {redact.text(str(e))[:200]}"
