"""
Web push to the owner's installed app. Sent right after a message is delivered on Telegram, so Telegram stays the
reliable channel and push is the faster, optional one. Fails silent: missing keys, missing library, dead
subscriptions never break message delivery. Dead subscriptions (404/410) are removed.
Keys live in the push_config table (service key only), not in git or env.
"""

from __future__ import annotations

import asyncio
import json
import logging

import hq

logger = logging.getLogger(__name__)

TITLES = {"emergency": "EMERGENCY", "proposal": "Needs your decision", "contract": "Needs your signature",
          "money": "Money", "health": "Company health", "brief": "Daily brief"}


def _config() -> dict | None:
    rows = hq._request("GET", "/rest/v1/push_config?id=eq.1&select=vapid_public,vapid_private,subject") or []
    c = rows[0] if rows else None
    return c if c and c.get("vapid_private") and c.get("vapid_public") else None


def _send_all(payload: dict) -> int:
    try:
        from pywebpush import webpush, WebPushException
    except Exception:
        return 0
    cfg = _config()
    if not cfg:
        return 0
    subs = hq._request("GET", "/rest/v1/push_subscriptions?fail_count=lt.5&select=endpoint,p256dh,auth&limit=10") or []
    sent = 0
    for s in subs:
        try:
            webpush(subscription_info={"endpoint": s["endpoint"], "keys": {"p256dh": s["p256dh"], "auth": s["auth"]}},
                    data=json.dumps(payload), vapid_private_key=cfg["vapid_private"],
                    vapid_claims={"sub": cfg.get("subject") or "mailto:owner@example.invalid"}, ttl=3600, timeout=8)
            sent += 1
            hq._request("PATCH", f"/rest/v1/push_subscriptions?endpoint=eq.{_q(s['endpoint'])}",
                        {"fail_count": 0, "last_ok_at": _now()}, prefer="return=minimal")
        except WebPushException as e:
            code = getattr(getattr(e, "response", None), "status_code", None)
            if code in (404, 410):
                hq._request("DELETE", f"/rest/v1/push_subscriptions?endpoint=eq.{_q(s['endpoint'])}", None, prefer="return=minimal")
            else:
                logger.info("push failed (%s): %s", code, str(e)[:120])
        except Exception as e:
            logger.info("push error: %s", str(e)[:120])
    return sent


def _q(v: str) -> str:
    import urllib.parse
    return urllib.parse.quote(str(v), safe="")


def _now() -> str:
    from datetime import datetime, timezone
    return datetime.now(timezone.utc).isoformat()


def payload_for(msg: dict) -> dict:
    body = (msg.get("body") or "").strip().replace("\n", " ")
    return {"title": TITLES.get(msg.get("kind"), "Jarvis"), "body": body[:140], "tag": str(msg.get("id") or "hq"),
            "urgent": msg.get("kind") == "emergency"}


async def notify(msg: dict) -> None:
    try:
        await asyncio.to_thread(_send_all, payload_for(msg))
    except Exception as e:
        logger.info("push notify skipped: %s", str(e)[:120])
