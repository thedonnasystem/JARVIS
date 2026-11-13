"""
Fendezy HQ bridge for Jarvis.

Jarvis is the only agent allowed to contact the owner. Other agents write to the
HQ database; this module delivers the owner-bound messages that Jarvis is cleared
to send, and lets Jarvis run any HQ agent through the spend gateway.

Everything here is inert unless BOTH of these are set (see .env.example):
    HQ_SUPABASE_URL           e.g. https://<project>.supabase.co
    HQ_SUPABASE_SERVICE_KEY   the HQ project's service key (keep it in Railway Variables)
Messages only ever go to JARVIS_OWNER_ID.
"""

import json
import logging
import os
import urllib.error
import urllib.parse
import urllib.request
from datetime import datetime, timezone
from decimal import Decimal

logger = logging.getLogger(__name__)

HQ_SUPABASE_URL = (os.environ.get("HQ_SUPABASE_URL") or "").rstrip("/")
HQ_SUPABASE_SERVICE_KEY = os.environ.get("HQ_SUPABASE_SERVICE_KEY") or ""
JARVIS_OWNER_ID = os.environ.get("JARVIS_OWNER_ID") or ""

KIND_LABEL = {
    "brief": "Daily brief",
    "money": "Money",
    "health": "Company health",
    "contract": "Contract needs your signature",
    "proposal": "Improvement proposal",
    "emergency": "EMERGENCY",
}


def hq_enabled() -> bool:
    return bool(HQ_SUPABASE_URL and HQ_SUPABASE_SERVICE_KEY and JARVIS_OWNER_ID)


def _request(method: str, path: str, body: dict | None = None, timeout: int = 30, prefer: str | None = None, exact: bool = False):
    url = f"{HQ_SUPABASE_URL}{path}"
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(url, data=data, method=method)
    req.add_header("apikey", HQ_SUPABASE_SERVICE_KEY)
    req.add_header("Authorization", f"Bearer {HQ_SUPABASE_SERVICE_KEY}")
    req.add_header("Content-Type", "application/json")
    if prefer:
        req.add_header("Prefer", prefer)
    with urllib.request.urlopen(req, timeout=timeout) as resp:
        raw = resp.read()
        if not raw:
            return None
        # exact=True keeps decimal numbers as Decimal (scale and precision intact); used by the backup so money columns are not rounded through float
        return json.loads(raw, parse_float=Decimal) if exact else json.loads(raw)


def format_owner_message(msg: dict) -> str:
    label = KIND_LABEL.get(msg.get("kind", ""), "Message")
    prefix = "\U0001F6A8 " if msg.get("kind") == "emergency" else ""
    note = ""
    if msg.get("channel") in ("text", "call"):
        note = f"\n\n(Sent by Telegram: the {msg['channel']} channel is not connected yet.)"
    return f"{prefix}{label}\n\n{msg.get('body', '')}{note}"


QUIET_START, QUIET_END = 22, 7  # Toronto hours; non-emergency messages wait until morning


def in_quiet_hours(now: datetime | None = None) -> bool:
    from zoneinfo import ZoneInfo
    h = (now or datetime.now(ZoneInfo("America/Toronto"))).hour
    return h >= QUIET_START or h < QUIET_END


def decision_buttons(msg_id: str):
    from telegram import InlineKeyboardButton, InlineKeyboardMarkup
    return InlineKeyboardMarkup([[
        InlineKeyboardButton("Approve", callback_data=f"hqd:ok:{msg_id}"),
        InlineKeyboardButton("Reject", callback_data=f"hqd:no:{msg_id}"),
    ]])


def option_buttons(msg_id: str, options: list):
    """Task Brief: one button per option (max 4), each on its own row so long labels stay readable."""
    from telegram import InlineKeyboardButton, InlineKeyboardMarkup
    return InlineKeyboardMarkup([[InlineKeyboardButton(str(o)[:60], callback_data=f"hqq:{i}:{msg_id}")]
                                 for i, o in enumerate(options[:4])])


async def deliver_owner_messages(context) -> None:
    """Repeating job: send unsent owner messages to the owner on Telegram, oldest first."""
    if not hq_enabled():
        return
    try:
        rows = _request(
            "GET",
            "/rest/v1/owner_messages?sent_at=is.null"
            f"&or=(deliver_after.is.null,deliver_after.lte.{datetime.now(timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ')})"
            "&order=created_at.asc&limit=10"
            "&select=id,kind,channel,body,needs_decision,options",
        ) or []
    except (urllib.error.URLError, TimeoutError, ValueError) as e:
        logger.warning("HQ: could not read owner_messages: %s", e)
        return
    quiet = in_quiet_hours()
    for msg in rows:
        if quiet and msg.get("kind") != "emergency":
            continue  # held until 7am Toronto; only emergencies wake the owner
        try:
            # Plain text on purpose: no parse_mode, so message content cannot inject formatting.
            if msg.get("options"):
                markup = option_buttons(msg["id"], msg["options"])
            else:
                markup = decision_buttons(msg["id"]) if msg.get("needs_decision") else None
            text = format_owner_message(msg)
            # --- hqui begin: the morning/evening brief carries the inbox count (read-only; '' if unreadable) ---
            if msg.get("kind") == "brief":
                import hq_inbox
                text = hq_inbox.append_to_brief(text)
            # --- hqui end ---
            await context.bot.send_message(int(JARVIS_OWNER_ID), text, reply_markup=markup)
            try:
                import hq_push
                await hq_push.notify(msg)
            except Exception:  # push is a bonus channel; Telegram already delivered
                pass
        except Exception as e:  # leave unsent so it is retried next minute
            logger.warning("HQ: Telegram send failed for %s: %s", msg.get("id"), e)
            return
        try:
            _request(
                "PATCH",
                f"/rest/v1/owner_messages?id=eq.{urllib.parse.quote(str(msg['id']))}",
                {"sent_at": datetime.now(timezone.utc).isoformat()},
                prefer="return=minimal",
            )
        except (urllib.error.URLError, TimeoutError) as e:
            logger.error("HQ: sent %s but could not mark it sent: %s", msg.get("id"), e)
            return


def run_agent(agent: str, task: str, max_output_tokens: int = 1000) -> dict:
    """Run one HQ agent turn through the spend gateway. Returns the function's JSON."""
    if not (HQ_SUPABASE_URL and HQ_SUPABASE_SERVICE_KEY):
        return {"error": "HQ is not configured"}
    try:
        return _request(
            "POST",
            "/functions/v1/hq-run",
            {"agent": agent, "task": task, "max_output_tokens": max_output_tokens},
            timeout=100,
        ) or {}
    except urllib.error.HTTPError as e:
        try:
            return json.loads(e.read().decode())
        except Exception:
            return {"error": f"HQ returned HTTP {e.code}"}
    except (urllib.error.URLError, TimeoutError) as e:
        return {"error": f"HQ unreachable: {e}"}
