"""
Web app bridge. The owner's PWA can't reach Jarvis directly (Jarvis has no public URL, on purpose), so the
app writes to web_messages through owner-only database functions and this poller picks the rows up:

  kind 'chat'     -> the same Jarvis turn as Telegram (shared history, tools, spend meter); reply row for the app
  kind 'decision' -> hq_commands.apply_decision (Approve / Reject)
  kind 'answer'   -> hq_commands.apply_answer   (Task Brief option)
  kind 'mission'  -> pause / resume / abandon / budget / new
  kind 'bank'     -> record the real bank balance, or import statement rows parsed in the browser
  kind 'draft'    -> approve / reject a drafted email, or mark an approved one sent (you send it yourself)
  kind 'day'      -> log today's dials/pitches/submissions, or a paid deal (day job)
  kind 'venture'  -> start a new (inactive) venture, or activate one the owner approved

Only rows the database accepted from the verified owner ever land here. Inert until the migration exists.
"""

import logging
import os
import urllib.error
import urllib.parse

import hq
import hq_bank
import hq_commands
import hq_missions
import hq_ventures

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


def _bank(payload: dict) -> str:
    verb = str(payload.get("verb") or "")
    if verb == "balance":
        return hq_bank.set_balance(str(payload.get("amount") or ""), payload.get("date") or None, by="owner:app")
    if verb == "rows":
        return hq_bank.import_rows(hq_bank.clean_rows(payload.get("rows")))
    if verb == "reconcile":
        return hq_bank.reconcile()
    return "Unknown bank action."


def _lead(payload: dict) -> str:
    if payload.get("new"):
        lead = hq_commands.parse_lead(" | ".join(str(payload.get(k) or "").replace("|", "/") for k in ("name", "phone", "note", "days")).rstrip(" |"))
        return hq_commands.add_lead(lead) if lead else "Bad lead: need a name and a valid phone."
    try:
        sid, days = int(payload.get("sid")), max(0, min(int(payload.get("days") if payload.get("days") is not None else 3), 60))
    except (TypeError, ValueError):
        return "Bad lead action."
    return hq_commands.log_contact(sid, days, str(payload.get("outcome") or "")[:200])


def _idea(payload: dict) -> str:
    verb = str(payload.get("verb") or "")
    return hq_commands.set_idea_status_by_id(str(payload.get("id") or ""), {"test": "testing", "park": "parked"}.get(verb, ""))


def _draft(payload: dict) -> str:
    verb, oid = str(payload.get("verb") or ""), str(payload.get("id") or "")
    if verb in ("approve", "reject"):
        return hq_commands.draft_decision(oid, verb == "approve")
    if verb == "sent":
        return hq_commands.mark_sent(oid)
    return "Unknown draft action."


def _day(payload: dict) -> str:
    verb = str(payload.get("verb") or "")
    if verb == "log":
        try:
            d, p, sub = (max(0, min(int(payload.get(k) or 0), 5000)) for k in ("dials", "pitches", "submissions"))
        except (TypeError, ValueError):
            return "Dials, pitches and submissions must be numbers."
        return hq_commands.log_day(d, p, sub)
    if verb == "paid":
        return hq_commands.log_paid(str(payload.get("who") or ""))
    return "Unknown day-job action."


def _venture(payload: dict) -> str:
    verb = str(payload.get("verb") or "")
    if verb == "new":
        r = hq_ventures.start(str(payload.get("name") or ""), str(payload.get("idea") or ""), by="owner")
        return r.get("error") or f"Venture {r['slug']} set up inactive. Validation mission: {r['mission']}. Approve it under Needs you when ready."
    if verb == "activate":
        return hq_ventures.activate(str(payload.get("slug") or "").lower(), by="owner:app")
    return "Unknown venture action."


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
    elif kind == "bank":
        _say(_bank(payload), row["id"], "system")
    elif kind == "venture":
        _say(_venture(payload), row["id"], "system")
    elif kind == "lead":
        _say(_lead(payload), row["id"], "system")
    elif kind == "idea":
        _say(_idea(payload), row["id"], "system")
    elif kind == "draft":
        _say(_draft(payload), row["id"], "system")
    elif kind == "day":
        _say(_day(payload), row["id"], "system")
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
