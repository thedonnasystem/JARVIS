"""
Web app bridge. The owner's PWA can't reach Jarvis directly (Jarvis has no public URL, on purpose), so the
app writes to web_messages through owner-only database functions and this poller picks the rows up:

  kind 'chat'     -> the same Jarvis turn as Telegram (shared history, tools, spend meter); reply row for the app
  kind 'decision' -> hq_commands.apply_decision (Approve / Reject)
  kind 'answer'   -> hq_commands.apply_answer   (Task Brief option)
  kind 'mission'  -> pause / resume / abandon / budget / new

Only rows the database accepted from the verified owner ever land here. Inert until the migration exists.
"""

import logging
import os
import urllib.error
import urllib.parse

import hq
import hq_commands
import hq_missions

logger = logging.getLogger(__name__)
POLL_SECONDS = 3
MAX_PER_POLL = 3
_reply_fn = None      # bot.jarvis_reply, injected at startup
_missing_logged = False


def configure(reply_fn) -> None:
    global _reply_fn
    _reply_fn = reply_fn


def _q(v) -> str:
    return urllib.parse.quote(str(v), safe="")


def _say(body: str, reply_to: str | None, kind: str = "chat") -> None:
    hq._request("POST", "/rest/v1/web_messages", {"role": "jarvis", "kind": kind, "body": (body or "")[:12000],
                                                  "status": "done", "reply_to": reply_to}, prefer="return=minimal")


def _mission(payload: dict) -> str:
    verb, mid = str(payload.get("verb") or ""), str(payload.get("id") or "")
    if verb == "new":
        r = hq_missions.create_mission(str(payload.get("objective") or ""), payload.get("venture"), created_by="owner-app")
        return r.get("error") or f"Mission opened: {r['title']}. I'll evaluate it within a few minutes."
    if verb in ("pause", "resume", "abandon"):
        return hq_missions.set_status(mid, verb)
    if verb == "budget":
        return hq_missions.set_budget(mid, int(payload.get("cents") or 0))
    return "Unknown mission action."


async def handle(row: dict, context) -> None:
    kind, payload, body = row.get("kind"), row.get("payload") or {}, row.get("body") or ""
    if kind == "chat":
        if _reply_fn is None:
            _say("Jarvis chat isn't wired up on this deploy yet.", row["id"])
            return
        owner = int(os.environ.get("JARVIS_OWNER_ID") or 0)
        text = await _reply_fn(owner, body[:6000], context, typing=False)
        _say(text, row["id"])
    elif kind == "decision":
        _say(hq_commands.apply_decision(str(payload.get("msg_id")), bool(payload.get("approved"))), row["id"], "system")
    elif kind == "answer":
        _say(hq_commands.apply_answer(str(payload.get("msg_id")), int(payload.get("idx") or 0)), row["id"], "system")
    elif kind == "mission":
        _say(_mission(payload), row["id"], "system")
    else:
        _say("I didn't understand that request.", row["id"], "system")


async def poll(context) -> None:
    global _missing_logged
    if not hq.hq_enabled():
        return
    try:
        rows = hq._request("GET", "/rest/v1/web_messages?role=eq.owner&status=eq.new&order=created_at.asc"
                                  f"&limit={MAX_PER_POLL}&select=id,kind,body,payload") or []
    except urllib.error.HTTPError as e:
        if e.code in (400, 404) and not _missing_logged:
            _missing_logged = True
            logger.info("web app tables not installed yet; web poller idle")
        return
    except Exception as e:
        logger.warning("web poll failed: %s", e)
        return
    for row in rows:
        claimed = hq._request("PATCH", f"/rest/v1/web_messages?id=eq.{_q(row['id'])}&status=eq.new",
                              {"status": "processing"}, prefer="return=representation") or []
        if not claimed:
            continue
        status = "done"
        try:
            await handle(row, context)
        except Exception as e:
            logger.exception("web message %s failed", row.get("id"))
            status = "failed"
            try:
                _say(f"That didn't go through: {str(e)[:200]}", row["id"], "system")
            except Exception:
                pass
        try:
            hq._request("PATCH", f"/rest/v1/web_messages?id=eq.{_q(row['id'])}", {"status": status}, prefer="return=minimal")
        except Exception:
            logger.exception("could not close web message %s", row.get("id"))
