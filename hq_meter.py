"""
Spend meter for every model call Jarvis makes outside the engine (owner chat, research agent, content agent,
/build sessions, voice transcription). Each one reserves budget through the HQ spend gateway (reserve_llm_budget ->
llm_calls) BEFORE the provider is touched, and settles the real cost afterwards, exactly like the engine's agent calls.

Fail behaviour (changed Nov 12 2026, pre-deployment audit): the meter fails CLOSED. If the gateway cannot say yes, the
call does not happen:
- cap / focus / mission budget / paused agent / kill switch  -> MeterBlocked
- database unreachable, gateway error, no price, HQ not configured -> MeterBlocked
The owner is told in one deterministic, non-AI line (status_reply). Commands such as /hq, /kill, /resume do not use AI,
so the owner can always see state and flip the kill switch.
"""

from __future__ import annotations

import json
import logging
import math
import time
import urllib.error

import hq

logger = logging.getLogger(__name__)

CHAT_AGENT = "jarvis-chat"
SEARCH_CENTS = 1          # per web search, same as the engine
PRICE_FALLBACK_MODEL = "claude-opus-5-5"  # an unknown model is priced like the strong tier (over-estimate, safe side)


class MeterBlocked(Exception):
    """No AI call may be made. The message is safe to show the owner. kind: kill|cap|focus|mission|unreachable|unconfigured|error."""

    def __init__(self, message: str = "", kind: str = "error"):
        super().__init__(message)
        self.kind = kind


def _kind(msg: str) -> str:
    low = msg.lower()
    if "kill switch" in low:
        return "kill"
    if "focus mode" in low:
        return "focus"
    if "mission budget" in low:
        return "mission"
    if "cap" in low or "paused" in low or "hard stop" in low:
        return "cap"
    return "error"


def status_reply(e: "MeterBlocked") -> str:
    """Deterministic status text for the owner when AI is off. No model is involved in producing it."""
    k = getattr(e, "kind", "error")
    head = {
        "kill": "Kill switch is ON, so AI is off. Send /resume to turn it back on.",
        "cap": f"AI is paused by a budget limit ({e}).",
        "focus": f"AI is limited to the focused mission right now ({e}). /mission focus off clears it.",
        "mission": f"The mission budget is used up ({e}).",
        "unreachable": "I can't reach my database, so AI is off until it's back.",
        "unconfigured": "The spend gateway is not configured, so AI is off.",
    }.get(k, f"AI is off because the spend gateway said no ({e}).")
    return head + " No AI call was made and nothing was spent. Commands that need no AI still work: /hq, /kill, /resume, /cancelbuild."


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


def _reserve_cents(agent: str, est_cents: int, model: str, purpose: str) -> str:
    """Reserve budget at the gateway. Returns the call id. Raises MeterBlocked for ANY failure (fail closed)."""
    if not hq.hq_enabled():
        raise MeterBlocked("HQ is not configured", "unconfigured")
    try:
        cid = _rpc("reserve_llm_budget", {"p_agent": agent, "p_est_cents": int(est_cents), "p_model": model,
                                          "p_purpose": purpose[:120]})
    except urllib.error.HTTPError as e:
        msg = _err_text(e)
        raise MeterBlocked(msg, _kind(msg)) from None
    except Exception as e:
        logger.warning("meter: spend gateway unreachable, refusing the AI call: %s", e)
        raise MeterBlocked("spend gateway unreachable", "unreachable") from None
    if not cid:
        raise MeterBlocked("spend gateway returned no reservation", "error")
    return cid


def reserve(model: str, kwargs: dict, purpose: str) -> str:
    """Returns a call id to settle. Raises MeterBlocked if the call may not be made, for any reason."""
    if not hq.hq_enabled():
        raise MeterBlocked("HQ is not configured", "unconfigured")
    try:
        est = _estimate(model, _input_tokens_guess(kwargs), int(kwargs.get("max_tokens") or 1024))
        est += _searches_allowed(kwargs) * SEARCH_CENTS
    except urllib.error.HTTPError as e:
        msg = _err_text(e)
        raise MeterBlocked(msg, _kind(msg)) from None
    except RuntimeError as e:
        raise MeterBlocked(str(e), "error") from None
    except Exception as e:
        logger.warning("meter: could not price the call, refusing it: %s", e)
        raise MeterBlocked("spend gateway unreachable", "unreachable") from None
    return _reserve_cents(CHAT_AGENT, est, model, purpose)


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


_kill_cache = {"at": 0.0, "val": False}


def kill_switch_on(ttl: float = 5.0) -> bool:
    """Live kill-switch read for long-running work. Cached a few seconds. Unreachable counts as ON (fail closed)."""
    now = time.monotonic()
    if now - _kill_cache["at"] < ttl:
        return _kill_cache["val"]
    try:
        rows = hq._request("GET", "/rest/v1/system_state?id=eq.1&select=kill_switch") or [{}]
        val = bool(rows[0].get("kill_switch"))
    except Exception:
        val = True
    _kill_cache.update(at=now, val=val)
    return val


def metered_call(agent: str, est_cents: int, model_label: str, purpose: str, fn):
    """Run fn() (a non-Anthropic provider call such as voice transcription) only after the gateway reserves est_cents.
    Flat-priced calls settle at the estimate. Raises MeterBlocked if the gateway says no."""
    call_id = _reserve_cents(agent, max(1, int(est_cents)), model_label, purpose)
    try:
        out = fn()
    except Exception:
        settle(call_id, model_label, failed=True)
        raise
    try:
        _rpc("settle_llm_call", {"p_id": call_id, "p_actual_cents": max(1, int(est_cents)), "p_status": "done"})
    except Exception as e:
        logger.warning("meter: settle failed for %s: %s", call_id, e)
    return out


def _fx() -> float:
    try:
        st = hq._request("GET", "/rest/v1/system_state?id=eq.1&select=usd_to_cad") or [{}]
        return max(1.0, float(st[0].get("usd_to_cad") or 1.5))
    except Exception:
        return 1.5  # higher than the stored rate, so the dollar ceiling derived from it can only be smaller


class Session:
    """A budget-reserved, hard-capped AI work session (the /build plan and build phases)."""

    def __init__(self, call_id: str, ceiling_cents: int, fx: float):
        self.call_id, self.ceiling_cents, self.fx = call_id, int(ceiling_cents), fx
        self.max_usd = round(self.ceiling_cents / 100.0 / fx, 4)  # passed to the SDK as max_budget_usd


def begin_session(agent: str, purpose: str, ceiling_cents: int) -> Session:
    """Reserve the WHOLE ceiling at the gateway first. Kill switch, daily caps, agent cap, focus mode and mission budget
    all apply; the ceiling can never exceed what the gateway would allow. Raises MeterBlocked."""
    if ceiling_cents < 1:
        raise MeterBlocked("no budget left for this session", "cap")
    call_id = _reserve_cents(agent, int(ceiling_cents), "claude-agent-sdk", purpose)
    return Session(call_id, ceiling_cents, _fx())


def end_session(s: Session, usd: float | None) -> int:
    """Settle with the real cost (USD -> CAD cents, rounded up). Unknown cost settles at the full reservation, never at 0.
    Returns the cents recorded."""
    if usd is None or usd < 0:
        cents = s.ceiling_cents
    else:
        cents = max(1, int(math.ceil(usd * s.fx * 100)))
    try:
        _rpc("settle_llm_call", {"p_id": s.call_id, "p_actual_cents": cents, "p_status": "done"})
    except Exception as e:
        logger.warning("meter: settle failed for session %s: %s", s.call_id, e)
    return cents


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
