"""FF Marketing OS helpers: build a client's onboarding plan and weekly report from database rows.
The database is the enforcement point (migrations/20261118_ffm_onboarding_v1.sql). Everything here is either a pure function over rows
or a thin _rpc wrapper. Nothing here sends a message, launches a campaign, calls an ad platform or spends money, and nothing here
supplies a value the owner or client has not supplied: a missing input is reported as 'unset', never guessed."""
import json
import urllib.error

import hq
from hq_workspace import SensitiveDataRefused, _msg, screen

UNSET = "unset"


class ActivationRefused(Exception):
    """The database refused to activate the workspace (missing inputs, no budget, or no current owner approval)."""


class OwnerActionRequired(Exception):
    """The action is owner-only; the bot may not perform it."""


def _rpc(name: str, args: dict):
    return hq._request("POST", f"/rest/v1/rpc/{name}", args)


def _get(path: str):
    return hq._request("GET", path) or []


def _translate(e: urllib.error.HTTPError):
    m = _msg(e)
    if "Sensitive data refused" in m:
        raise SensitiveDataRefused(m) from None
    if m.startswith("activation refused"):
        raise ActivationRefused(m) from None
    if "owner approval required" in m:
        raise OwnerActionRequired(m) from None
    raise e


def _call(name: str, args: dict):
    try:
        return _rpc(name, args)
    except urllib.error.HTTPError as e:
        _translate(e)


# ---------- pure functions ----------
def _val(item: dict) -> str:
    v = item.get("value_text")
    return v if item.get("status") == "provided" and v and str(v).strip() else UNSET


def onboarding_plan(workspace: dict, items: list, readiness: dict | None = None) -> dict:
    """Pure. workspace = client_workspaces row, items = ffm_onboarding_items rows, readiness = ffm_readiness() result (optional).
    Returns who must do what next. Never invents a value; the budget is 'unset' until the owner sets it."""
    budget = workspace.get("monthly_budget_cents")
    steps = []
    for it in sorted(items, key=lambda i: (i.get("provider") or "", i.get("template_key") or "")):
        done = it.get("status") == "provided" and _val(it) != UNSET
        steps.append({"key": it["template_key"], "title": it.get("title"), "provider": it.get("provider"), "required": bool(it.get("required", True)),
                      "status": "provided" if done else it.get("status", "pending") if it.get("status") == "blocked" else "pending",
                      "value": _val(it), "blocked_until": it.get("blocked_until")})
    missing_required = [s["key"] for s in steps if s["required"] and s["status"] != "provided"]
    owner_todo = [s for s in steps if s["provider"] == "owner" and s["status"] != "provided" and s["required"]]
    client_todo = [s for s in steps if s["provider"] == "client" and s["status"] != "provided" and s["required"]]
    actions = []
    if budget is None:
        actions.append({"who": "owner", "do": "set the monthly budget for this workspace (owner-only action)"})
    actions += [{"who": "owner", "do": s["title"], "key": s["key"]} for s in owner_todo]
    actions += [{"who": "client", "do": s["title"], "key": s["key"]} for s in client_todo]
    approved = bool(readiness and readiness.get("owner_approved"))
    if not missing_required and budget is not None and not approved:
        actions.append({"who": "owner", "do": "review the completed checklist and approve activation (owner-only action)"})
    if readiness and readiness.get("approval_stale"):
        actions.append({"who": "owner", "do": "re-approve: inputs or budget changed after the last approval"})
    ready = bool(readiness.get("ready")) if readiness else (not missing_required and budget is not None and approved)
    return {"workspace": workspace.get("slug"), "status": workspace.get("status", "draft"), "vertical": workspace.get("vertical"),
            "budget": UNSET if budget is None else budget, "steps": steps, "missing_required": missing_required,
            "next_actions": actions, "ready_to_activate": ready,
            "ai_may_not_touch": ["mortgage/loan applications", "banking details", "credit data", "ID documents", "sensitive financial data"]}


def _pct(x) -> str:
    return "n/a" if x is None else f"{float(x) * 100:.1f}%"


def _money(c) -> str:
    return UNSET if c is None else f"${c / 100:,.2f}"


def render_weekly_report(r: dict) -> str:
    """Pure. r = ffm_weekly_report() result. Plain text/markdown, numbers only, no lead-level data."""
    sp, fu, lb, rd = r.get("spend", {}), r.get("funnel", {}), r.get("lead_to_booked", {}), r.get("readiness", {})
    lines = [f"# Weekly report: {r.get('workspace')}", f"Period: {str(r.get('from'))[:10]} to {str(r.get('to'))[:10]}", ""]
    if rd.get("status") != "active":
        lines += [f"Status: {rd.get('status')} (not active). Missing required inputs: {', '.join(rd.get('missing_required') or []) or 'none'}", ""]
    stages = fu.get("by_stage") or {}
    lines += ["## Funnel", f"- New leads in period: {fu.get('leads', 0)}"]
    lines += [f"- {k}: {v}" for k, v in sorted(stages.items())]
    lines += [f"- Lead to booked rate: {_pct(lb.get('rate'))} ({lb.get('booked', 0)} of {lb.get('leads', 0)})", "", "## Spend"]
    lines += [f"- Monthly budget: {_money(sp.get('budget_cents'))}", f"- Spent in period: {_money(sp.get('spent_in_period_cents', 0))}",
              f"- Spent this month: {_money(sp.get('spent_cents', 0))} ({_pct(sp.get('pct_used'))} of budget)", f"- Remaining this month: {_money(sp.get('remaining_cents'))}"]
    cs = r.get("campaigns_by_status") or {}
    lines += ["", "## Campaigns", "- " + (", ".join(f"{k}: {v}" for k, v in sorted(cs.items())) or "none"), f"- Creatives awaiting review: {r.get('creatives_awaiting_review', 0)}"]
    if sp.get("budget") == UNSET:
        lines += ["", "Note: no budget has been set, so spend vs budget cannot be judged."]
    return "\n".join(lines) + "\n"


def cost_per_booked(report: dict):
    """Pure. Spend in period divided by booked leads in period, in cents; None if nothing booked (never divides by zero, never guesses)."""
    booked = (report.get("lead_to_booked") or {}).get("booked") or 0
    spent = (report.get("spend") or {}).get("spent_in_period_cents")
    return None if not booked or spent is None else round(spent / booked)


# ---------- database wrappers ----------
def readiness(ws: str) -> dict:
    return _call("ffm_readiness", {"p_ws": ws})


def start_onboarding(ws: str) -> int:
    return _call("ffm_instantiate_onboarding", {"p_ws": ws})


def provide_input(ws: str, key: str, value: str, by: str):
    screen(value)   # pre-check before the value goes anywhere else
    return _call("ffm_provide_input", {"p_ws": ws, "p_key": key, "p_value": value, "p_by": by})


def plan_for(ws_id: str) -> dict:
    w = _get(f"/rest/v1/client_workspaces?id=eq.{ws_id}&select=*")
    if not w:
        raise LookupError("workspace not found")
    items = _get(f"/rest/v1/ffm_onboarding_items?workspace_id=eq.{ws_id}&select=*")
    return onboarding_plan(w[0], items, readiness(ws_id))


def activate(ws: str):
    """Asks the database to activate. It refuses unless every required input, the budget and a current owner approval exist."""
    return _call("ffm_activate", {"p_ws": ws})


def weekly_report(ws: str, start=None, end=None) -> dict:
    return _call("ffm_weekly_report", {"p_ws": ws, "p_from": start, "p_to": end})


def weekly_report_text(ws: str, start=None, end=None) -> str:
    text = render_weekly_report(weekly_report(ws, start, end))
    screen(text)   # defence in depth: the text that leaves this module has passed the same detector
    return text


def route_preview(ws: str, lead: str):
    """Dry run: what WOULD be passed to the client's own system. Sends nothing."""
    return _call("ffm_route_preview", {"p_ws": ws, "p_lead": lead})
