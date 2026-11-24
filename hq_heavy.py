"""
Heavy bridge: the Chairman hands a heavy job (build a site, fix an office, review quality, research) to a SCHEDULED Claude Code session that runs on
his own Claude subscription (docs/architecture/HEAVY_BRIDGE.md). This module is only the owner's side of the queue:

    /heavy <kind> | <instructions>     add a job (kinds: site-build, office-fix, qc-review, research, other)
    /heavy list                        the queue and the latest results
    /heavy cancel <id>                 cancel a job that has not started
    /heavy on | off                    THE switch (off by default)

Rules that live here and in the database (migrations/20261208_heavy_bridge_v1.sql):
  * Only the owner-only /heavy command adds a job. There is no agent tool, no job handler and no office path that calls enqueue(); Jarvis may SUGGEST a
    job in chat (suggestion()), which is only text the Chairman can send himself. test_hq_heavy.py pins the callers.
  * A job never carries client data, contacts, keys or personal info: text_problem() refuses e-mail addresses, phone numbers and anything that looks
    like a secret before anything is sent, and the database checks again.
  * No AI call, no spend, no external message. This module never touches a Claude credential: the scheduled session is Anthropic's own product,
    signed in by the Chairman, and reads the queue with his own Supabase connector.
  * The result message to the Chairman is queued by the database (heavy_finish) as Jarvis, through the existing owner_messages path.
"""
from __future__ import annotations

import json
import logging
import re
import urllib.error

import hq

logger = logging.getLogger(__name__)

KINDS = ("site-build", "office-fix", "qc-review", "research", "other")
MIN_LEN, MAX_LEN = 10, 4000
USAGE = ("Use:\n/heavy <kind> | <what to do>\n/heavy list\n/heavy cancel <id>\n/heavy on | off\n"
         "Kinds: " + ", ".join(KINDS) + ".\nExample: /heavy research | Compare three open-source booking widgets for the Donna site and recommend one.\n"
         "Never put client data, contacts, keys or personal info in a job.")

# The same checks as public.heavy_text_problem (the database is the authority; this copy gives the Chairman the answer before anything is sent).
_EMAIL = (re.compile(r"[a-z0-9._%+-]+@[a-z0-9-]+(\.[a-z0-9-]+)+", re.I), re.compile(r"[a-z0-9._%+-]+\s*[\[(]\s*at\s*[\])]\s*[a-z0-9-]+", re.I))
_PHONE = (re.compile(r"(^|[^0-9A-Za-z_/#.-])(\+?1[ .-]?)?\(?[0-9]{3}\)?[ .-]?[0-9]{3}[ .-]?[0-9]{4}([^0-9A-Za-z_-]|$)"), re.compile(r"\+[0-9][0-9 ().-]{7,}[0-9]"))
_SECRET = (re.compile(r"(sk-[A-Za-z0-9_-]{16,}|sk_(live|test)_|rk_(live|test)_|pk_live_|gh[pousr]_[A-Za-z0-9]{20,}|github_pat_|xox[abprs]-|AKIA[0-9A-Z]{16}"
                      r"|AIza[0-9A-Za-z_-]{30,}|sbp_[a-f0-9]{20,}|sb_secret_|eyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}|-----BEGIN|[0-9]{8,10}:[A-Za-z0-9_-]{30,})"),
           re.compile(r"(password|passwd|pwd|secret|token|api[ _-]?key)\s*[:=]\s*\S{6,}", re.I), re.compile(r"bearer\s+[a-z0-9._~+/=-]{20,}", re.I))
_RUN_A = re.compile(r"[A-Za-z0-9_-]{40,}")
_RUN_B = re.compile(r"[A-Za-z0-9+/]{40,}")


def text_problem(text) -> str | None:
    """None when the text is clean; otherwise what was found (never the text itself)."""
    t = str(text or "")
    if any(p.search(t) for p in _EMAIL):
        return "an e-mail address"
    if any(p.search(t) for p in _PHONE):
        return "a phone number"
    if any(p.search(t) for p in _SECRET):
        return "something that looks like a key or password"
    if any(re.search(r"[0-9]", m) and re.search(r"[A-Za-z]", m) for m in _RUN_A.findall(t)) or \
       any(re.search(r"[0-9]", m) and re.search(r"[A-Z]", m) and re.search(r"[a-z]", m) for m in _RUN_B.findall(t)):
        return "a long random-looking string (possible key)"
    return None


def _rpc(name: str, args: dict | None = None):
    return hq._request("POST", f"/rest/v1/rpc/{name}", args or {})


def _db_message(e: Exception) -> str:
    """The database's own refusal text (it never repeats the job text), or a short generic line."""
    if isinstance(e, urllib.error.HTTPError):
        try:
            msg = str((json.loads(e.read().decode("utf-8", "replace")) or {}).get("message") or "")
        except Exception:
            msg = ""
        if msg.startswith("heavy bridge:"):
            return "Heavy bridge: " + msg[len("heavy bridge:"):].strip()[:300]
        if e.code == 404:
            return "The heavy bridge is not installed in the database yet (migration 20261208_heavy_bridge_v1)."
    return f"Heavy bridge unavailable: {type(e).__name__}"


def parse(raw: str) -> tuple[str, str] | None:
    """'<kind> | <instructions>' -> (kind, instructions); None when it is not that shape."""
    head, sep, rest = str(raw or "").partition("|")
    kind = head.strip().lower().replace("_", "-").replace(" ", "-")
    if not sep or kind not in KINDS:
        return None
    return kind, rest.strip()


def suggestion(kind: str, instructions: str) -> str:
    """What Jarvis may show in chat: the exact command for the Chairman to send himself. Showing it adds nothing to the queue."""
    k = kind if kind in KINDS else "other"
    return f"/heavy {k} | {' '.join(str(instructions or '').split())[:600]}"


def enqueue(kind: str, instructions: str) -> str:
    """OWNER COMMAND ONLY (command_text). Validates, then asks the database to add the job."""
    if kind not in KINDS:
        return "Kind must be one of: " + ", ".join(KINDS) + "."
    ins = str(instructions or "").strip()
    if not MIN_LEN <= len(ins) <= MAX_LEN:
        return f"The instructions need {MIN_LEN} to {MAX_LEN} characters."
    bad = text_problem(ins)
    if bad:
        return f"Refused: the text contains {bad}. Jobs never carry client data, contacts, keys or personal info. Reword it and send again."
    try:
        j = _rpc("heavy_enqueue", {"p_kind": kind, "p_instructions": ins}) or {}
    except Exception as e:
        return _db_message(e)
    return (f"Heavy job #{j.get('id')} queued ({kind}): {str(j.get('title') or '')[:120]}\n"
            "The next scheduled Claude Code run picks it up, opens a pull request and I report back. Nothing is merged without you.")


def _line(j: dict) -> str:
    out = f"#{j.get('id')} {j.get('status')} · {j.get('kind')} · {str(j.get('title') or '')[:80]}"
    if j.get("result_summary"):
        out += f"\n   {str(j['result_summary'])[:300]}"
    if j.get("result_link"):
        out += f"\n   {j['result_link']}"
    return out


def list_text(limit: int = 10) -> str:
    try:
        r = _rpc("heavy_list", {"p_limit": limit}) or {}
    except Exception as e:
        return _db_message(e)
    head = (f"Heavy bridge: {'ON' if r.get('enabled') else 'OFF (send /heavy on)'} · waiting {r.get('queued', 0)} · in progress {r.get('claimed', 0)}"
            f" · at most {r.get('max_per_day', 2)} a day")
    jobs = r.get("jobs") or []
    return head + ("\n" + "\n".join(_line(j) for j in jobs) if jobs else "\nNo jobs yet.")


def cancel(job_id: str) -> str:
    if not re.fullmatch(r"#?[0-9]{1,12}", str(job_id or "").strip()):
        return "Use: /heavy cancel <id>   (the number from /heavy list)"
    n = int(str(job_id).strip().lstrip("#"))
    try:
        _rpc("heavy_cancel", {"p_id": n})
    except Exception as e:
        return _db_message(e)
    return f"Heavy job #{n} cancelled."


def set_enabled(on: bool) -> str:
    try:
        _rpc("heavy_set_enabled", {"p_on": bool(on)})
    except Exception as e:
        return _db_message(e)
    return ("Heavy bridge ON. Add a job with /heavy <kind> | <what to do>. The scheduled Claude Code run must exist on your account for jobs to be picked up."
            if on else "Heavy bridge OFF. Nothing can be added and nothing is handed out. Jobs already queued are kept.")


def command_text(raw: str) -> str:
    """The text after '/heavy'. The caller (hq_commands.hq_heavy_cmd) has already checked that the sender is the owner."""
    raw = str(raw or "").strip()
    low = raw.lower()
    if not raw or low in ("help", "?"):
        return USAGE
    if low == "list":
        return list_text()
    if low in ("on", "off"):
        return set_enabled(low == "on")
    if low == "cancel" or low.startswith("cancel "):
        return cancel(raw[6:].strip())
    parsed = parse(raw)
    if parsed is None:
        return USAGE
    return enqueue(*parsed)
