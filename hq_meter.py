"""
Spend meter for Jarvis's own model calls (chat, research agent, content agent).

Before this, those calls went straight to Anthropic: uncapped, unlogged, invisible to the daily cap.
Now each one reserves budget through the HQ spend gateway (reserve_llm_budget -> llm_calls) as the
'jarvis-chat' agent, and settles the real cost afterwards, exactly like the engine's agent calls.

Fail behaviour, on purpose:
- The gateway says NO (company cap, chat cap): raise MeterBlocked. The caller tells the owner in one line.
- The kill switch is on: the owner's own chat still runs (it's how he talks to his company), metered as
  best we can, never blocked.
- HQ unreachable, migration not applied, or no verified price: the call runs unmetered and it's logged.
  The owner's control channel never goes dark because a database is down.
"""

from __future__ import annotations

import json
import logging
import urllib.error

import hq

logger = logging.getLogger(__name__)

CHAT_AGENT = "jarvis-chat"
SEARCH_CENTS = 1          # per web search, same as the engine
PRICE_FALLBACK_MODEL = "claude-opus-5-5"  # an unknown model is priced like the strong tier (over-estimate, safe side)


class MeterBlocked(Exception):
    """The spend gateway refused the call (a budget cap). The message is safe to show the owner."""


def _rpc(name: str, args: dict):
    return hq._request("POST", f"/rest/v1/rpc/{name}", args)


def _err_text(e: urllib.error.HTTPError) -> str:
    try:
        body = json.loads(e.read().decode() or "{}")
        return str(body.get("message") or body)
    except Exception:
        return f"HTTP {e.code}"


def _estimate(model: str, in_tokens: int, out_tokens: int) -> int:
    for m in (model, PRICE_FALLBACK_MODEL):
        try:
            return int(_rpc("estimate_call_cents", {"p_model": m, "p_input_tokens": int(in_tokens),
                                                    "p_max_output_tokens": int(out_tokens)}))
        except urllib.error.HTTPError:
            continue
    raise RuntimeError("no price available")


def _input_tokens_guess(kwargs: dict) -> int:
    text = json.dumps(kwargs.get("messages", []), default=str) + str(kwargs.get("system", "")) + \
        json.dumps(kwargs.get("tools", []), default=str)
    return max(1, len(text) // 3)


def _searches_allowed(kwargs: dict) -> int:
    for t in kwargs.get("tools") or []:
        if isinstance(t, dict) and str(t.get("type", "")).startswith("web_search"):
            return int(t.get("max_uses") or 5)
    return 0


def reserve(model: str, kwargs: dict, purpose: str) -> str | None:
    """Returns a call id to settle, or None when running unmetered. Raises MeterBlocked on a cap."""
    if not hq.hq_enabled():
        return None
    try:
        est = _estimate(model, _input_tokens_guess(kwargs), int(kwargs.get("max_tokens") or 1024))
        est += _searches_allowed(kwargs) * SEARCH_CENTS
        return _rpc("reserve_llm_budget", {"p_agent": CHAT_AGENT, "p_est_cents": est, "p_model": model,
                                           "p_purpose": purpose[:120]})
    except urllib.error.HTTPError as e:
        msg = _err_text(e)
        if "Kill switch" in msg or "Unknown agent" in msg:
            logger.info("meter: running unmetered (%s)", msg)
            return None
        low = msg.lower()
        if "cap" in low or "paused" in low or "focus mode" in low or "mission budget" in low:
            raise MeterBlocked(msg) from None  # focus-mode and mission-budget refusals must never fall through to "unmetered"
        logger.warning("meter: gateway error, running unmetered: %s", msg)
        return None
    except Exception as e:
        logger.warning("meter: HQ unreachable, running unmetered: %s", e)
        return None


def settle(call_id: str | None, model: str, response=None, failed: bool = False) -> None:
    if not call_id:
        return
    try:
        if failed or response is None:
            _rpc("settle_llm_call", {"p_id": call_id, "p_actual_cents": 0, "p_status": "failed"})
            return
        usage = getattr(response, "usage", None)
        tin = int(getattr(usage, "input_tokens", 0) or 0)
        tout = int(getattr(usage, "output_tokens", 0) or 0)
        stu = getattr(usage, "server_tool_use", None)
        searches = int(getattr(stu, "web_search_requests", 0) or 0) if stu else 0
        cents = _estimate(model, tin, tout) + searches * SEARCH_CENTS
        _rpc("settle_llm_call", {"p_id": call_id, "p_actual_cents": cents, "p_status": "done"})
    except Exception as e:  # never break a reply over bookkeeping; the reservation stays as the record
        logger.warning("meter: settle failed for %s: %s", call_id, e)


def metered_create(client, purpose: str, **kwargs):
    """Drop-in for client.messages.create(**kwargs) that goes through the spend gateway."""
    model = kwargs.get("model", "")
    call_id = reserve(model, kwargs, purpose)
    try:
        resp = client.messages.create(**kwargs)
    except Exception:
        settle(call_id, model, failed=True)
        raise
    settle(call_id, model, resp)
    return resp


def record_spent_usd(agent: str, usd: float | None, purpose: str, model: str = "claude-agent-sdk") -> None:
    """Record money already spent outside the gateway (e.g. a /build coding session that reports its own
    total cost). It's reality, so it is written even past a cap; the caps then see it for the rest of the day."""
    if not usd or usd <= 0 or not hq.hq_enabled():
        return
    try:
        st = hq._request("GET", "/rest/v1/system_state?id=eq.1&select=usd_to_cad") or [{}]
        fx = float(st[0].get("usd_to_cad") or 1.45)
        cents = max(1, int(round(usd * fx * 100)))
        from datetime import datetime, timezone
        now = datetime.now(timezone.utc).isoformat()
        hq._request("POST", "/rest/v1/llm_calls", {"agent_slug": agent, "model": model, "purpose": purpose[:120],
                                                   "reserved_cents": cents, "actual_cents": cents, "status": "done",
                                                   "finished_at": now}, prefer="return=minimal")
    except Exception as e:
        logger.warning("meter: could not record %s spend: %s", agent, e)
