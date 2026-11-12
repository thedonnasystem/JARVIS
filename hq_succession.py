"""Succession / continuity sheet (Master Plan: 'succession document', 'runbooks per venture', 'credentials in a vault').
One plain-text snapshot of what a trusted human would need if the owner were unavailable: ventures, who manages them, accounts and
where their logins live (the VAULT REFERENCE only, never a password), tools and monthly costs, assets and runbooks.
It never contains secrets. A lawyer and an accountant must still confirm the legal side (trust, will, trustee)."""
from __future__ import annotations

import logging

import hq

logger = logging.getLogger(__name__)
_SECRETISH = ("password", "passwd", "secret", "token", "api_key", "apikey", "pin ")


def _get(path: str) -> list:
    try:
        return hq._request("GET", f"/rest/v1/{path}") or []
    except Exception as e:
        logger.info("succession read %s failed: %s", path.split("?")[0], str(e)[:80])
        return None  # type: ignore[return-value]


def _clean(v, n: int = 120) -> str:
    s = str(v or "").strip().replace("\n", " ")
    if any(w in s.lower() for w in _SECRETISH):
        return "[withheld: looks like a secret]"
    return s[:n]


def _section(title: str, rows, fmt) -> str:
    if rows is None:
        return f"{title}\n- not available (migration pending)\n"
    if not rows:
        return f"{title}\n- none recorded\n"
    return title + "\n" + "\n".join("- " + fmt(r) for r in rows) + "\n"


def build() -> str:
    ventures = _get("ventures?select=slug,name,kind,status,stage,manager_agent,primary_metric&order=status,slug")
    if ventures is None:  # older schema without stage/manager
        ventures = _get("ventures?select=slug,name,kind,status,primary_metric&order=status,slug")
    accounts = _get("accounts_registry?select=service,purpose,login_email,vault_ref,status&order=service")
    tools = _get("tool_registry?select=slug,kind,purpose,monthly_cost_cents,status&order=slug")
    assets = _get("venture_assets?select=kind,name,url,status&order=kind,name")
    procs = _get("venture_procedures?select=title,venture_id&order=title")
    out = ["FENDEZY SUCCESSION AND CONTINUITY SHEET", "No passwords or keys are in this sheet. Logins live in the vault; this lists where.", ""]
    out.append(_section("Ventures (each can run, be sold or be handed over alone)", ventures,
                        lambda r: f"{r.get('name')} [{r.get('status')}{('/' + r['stage']) if r.get('stage') else ''}] kind {r.get('kind')}, manager {r.get('manager_agent') or 'Jarvis'}, metric: {_clean(r.get('primary_metric'), 60)}"))
    out.append(_section("Accounts and where the login is kept", accounts,
                        lambda r: f"{r.get('service')} ({_clean(r.get('purpose'), 60)}): login email {_clean(r.get('login_email'), 60)}, vault entry {_clean(r.get('vault_ref'), 60) or 'NOT IN VAULT'} [{r.get('status')}]"))
    out.append(_section("Tools and recurring costs", tools,
                        lambda r: f"{r.get('slug')} ({r.get('kind')}): {_clean(r.get('purpose'), 60)}; ${int(r.get('monthly_cost_cents') or 0) / 100:,.2f}/month [{r.get('status')}]"))
    out.append(_section("Websites, domains, repos and integrations", assets,
                        lambda r: f"{r.get('kind')}: {r.get('name')} {_clean(r.get('url'), 80)} [{r.get('status')}]"))
    out.append(_section("Runbooks / operating procedures on file", procs, lambda r: _clean(r.get("title"), 100)))
    total = sum(int(t.get("monthly_cost_cents") or 0) for t in (tools or []) if t.get("status") == "active")
    out.append(f"Active recurring tool cost: ${total / 100:,.2f}/month.\n")
    missing = [a.get("service") for a in (accounts or []) if not a.get("vault_ref")]
    if missing:
        out.append("GAPS: accounts with no vault entry: " + ", ".join(str(m) for m in missing) + "\n")
    out.append("STILL NEEDS A HUMAN AND PROFESSIONALS: holding-company shares in a will or family trust with a named trustee (lawyer + accountant); "
               "domains, numbers and bank in company names; a named trusted person with emergency access to the vault. Agents cannot own or sign; "
               "wholesaling licences and contractor status do not pass to heirs.")
    return "\n".join(out)
