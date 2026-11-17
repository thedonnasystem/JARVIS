"""
First mission, "Chairman briefing": Jarvis tells the Chairman who he is, who the Chairman is (from seeded memory), what he is ready to do, his capabilities
and limits, and what still needs the Chairman. Assembled by PLAIN CODE from the database and the environment (names only, never values): $0, no model call.
Delivered through a channel adapter (hq_channels): Telegram now; WhatsApp when the owner sets it up.
"""
from __future__ import annotations

import logging
import os

import hq

logger = logging.getLogger(__name__)

DIVISIONS = {"donna": "Donna (AI automation agency, HVAC first)", "wolf-squad": "Wolf Squad", "ffm": "FF Marketing (client marketing workspaces)"}
NEEDS = [  # (env var names, what it unlocks). Only presence is checked; values are never read out.
    (("GROQ_API_KEY", "OPENROUTER_API_KEY", "CEREBRAS_API_KEY", "GITHUB_MODELS_TOKEN", "NVIDIA_API_KEY"), "at least one free model provider key (my brain, $0)"),
    (("JARVIS_SELFHOST_BASE_URL", "JARVIS_SELFHOST_API_KEY"), "the free self-hosted model (needed for any task with client personal data)"),
    (("JARVIS_GITHUB_TOKEN",), "a fine-grained GitHub token for a SEPARATE machine account (self-edit pipeline)"),
    (("WHATSAPP_ACCESS_TOKEN", "WHATSAPP_PHONE_NUMBER_ID", "WHATSAPP_OWNER_NUMBER"), "WhatsApp Business Cloud API (second channel)"),
    (("TWILIO_ACCOUNT_SID", "TWILIO_AUTH_TOKEN", "TWILIO_FROM_NUMBER", "OWNER_PHONE_NUMBER"), "a telephony account for emergency calls"),
]


def _get(path: str) -> list:
    try:
        return hq._request("GET", f"/rest/v1/{path}") or []
    except Exception:
        return []


def _rpc(name: str, args: dict | None = None):
    try:
        return hq._request("POST", f"/rest/v1/rpc/{name}", args or {}) or {}
    except Exception:
        return {}


def gather(env: dict | None = None) -> dict:
    import hq_llm
    import hq_seed
    e = os.environ if env is None else env
    st = _rpc("jarvis_core_status")
    return {
        "status": st,
        "config": st.get("config") or {},
        "departments": _get("departments?select=slug,name,kind,status&order=slug"),
        "agents": _get("agents?select=slug,title,role,status,department_slug&status=eq.active&order=role,slug&limit=60"),
        "ventures": _get("ventures?select=slug,name,status&order=slug"),
        "owner": hq_seed.owner_profile(),
        "providers": [p.name for p in hq_llm.load_providers(e) if not p.problems()],
        "missing": [(names, why) for names, why in NEEDS if not all(e.get(n) for n in names)],
        "self_fund": _rpc("jarvis_self_fund_status"),
        "approvals": len(_get("owner_messages?needs_decision=is.true&decision=is.null&select=id&limit=50")),
    }


def build(data: dict | None = None) -> str:
    d = data if data is not None else gather()
    c = d.get("config") or {}
    st = d.get("status") or {}
    divs = c.get("active_divisions") or list(DIVISIONS)
    roles = {}
    for a in d.get("agents") or []:
        roles.setdefault(a.get("role") or "specialist", []).append(a.get("slug"))
    sf = d.get("self_fund") or {}
    out = ["Good morning, sir. This is my briefing.", "",
           "WHO I AM",
           "- Jarvis, chief of staff of Fendezy HQ. I report to you, sir, and I am the only agent allowed to contact you.",
           "- Divisions with an active queue: " + ", ".join(DIVISIONS.get(x, x) for x in divs) + ". Every other division is dormant until you activate it.",
           "- Offices and departments: " + (", ".join(f"{x.get('name') or x.get('slug')} ({x.get('status')})" for x in d.get("departments") or []) or "none recorded yet") + ".",
           "- Reporting lines: agents report to their department lead, leads report to me, I report to you. Active agents by role: "
           + ("; ".join(f"{r}: {', '.join(s[:6])}" for r, s in sorted(roles.items())) or "none active") + ".",
           "", "WHO YOU ARE (from my memory)"]
    owner = d.get("owner") or []
    out += [f"- {x}" for x in owner[:12]] if owner else ["- Not seeded yet, sir. Send me your private profile file with the caption /seedmemory (it is read in memory and never stored as a file)."]
    out += ["", "WHAT I AM READY TO DO",
            f"- Model providers ready: {', '.join(d.get('providers') or []) or 'none, so my brain is offline and only plain commands work'}.",
            "- Plain-code work at $0: status (/core, /hq), this briefing, the 07:00 daily report, the job queue, the cost meter.",
            f"- Core {'ON' if c.get('core_enabled') else 'off'}, worker {'ON' if c.get('worker_enabled') else 'off'}, self-edit {'ON' if c.get('self_edit_enabled') else 'off'}, "
            f"self-automation {'ON' if c.get('self_automation_enabled') else 'off'}, WhatsApp {'ON' if c.get('whatsapp_enabled') else 'off'}, emergency calls {'ON' if c.get('emergency_call_enabled') else 'off'}.",
            "", "MY LIMITS (I cannot change these)",
            f"- Spend gateway and caps (today {st.get('daily_cap_cents', '?')} cents/day), kill switch ({'ON' if st.get('kill_switch') else 'off'}), mode ({st.get('mode', '?')}).",
            "- The never-edit list: money controls, kill switch and mode, my own permissions, consent and privacy, the tests and CI that judge my work, audit history, destructive data changes.",
            "- Client personal data never goes to a free model provider. I never switch to a paid provider on my own.",
            "", "MY STANDING OBJECTIVE: FUND MYSELF",
            "- I run on the free model stack. Only revenue that you confirm after bank reconciliation counts as mine, and only your chosen share of it "
            f"(now {sf.get('pct', 0)}%) can pay for paid models or a GPU, still through the same gateway, caps and approvals. Available today: ${int(sf.get('available_cents') or 0) / 100:,.2f}.",
            "", "WHAT STILL NEEDS YOU, SIR"]
    miss = d.get("missing") or []
    out += [f"- {why}: set {', '.join(names)} in Railway Variables (names only here, never paste values in chat)." for names, why in miss] or ["- Nothing from the environment."]
    out += [f"- Approvals waiting: {d.get('approvals', 0)}.",
            "- Switches are yours only (SQL editor or the app): jarvis_set_config(...). See OWNER_GUIDE_JARVIS_V2.md."]
    return "\n".join(out)


def deliver(text: str, channel: str = "telegram") -> dict:
    import hq_channels
    return hq_channels.get(channel).send(text, urgency="low", kind="brief")
