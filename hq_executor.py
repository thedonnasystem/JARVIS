"""Thin adapter between Jarvis and any external executor (e.g. an Agent Swarm worker).

HQ stays the only authority for money, permissions and the kill switch. An executor may do work ONLY inside run():
  1. executor_request  -> HQ decides (default-deny, kill switch, pause, caps, budget reservation)
  2. the work callable runs ONLY if HQ said yes AND dry_run is false
  3. executor_complete -> HQ settles the real cost; a crash is settled as failed, never left reserved
The work callable is injected, so the executor is replaceable and this module can be tested without one.
"""
import asyncio
import hashlib
import json
import logging
import urllib.error

import hq

logger = logging.getLogger(__name__)
EXPIRE_EVERY_SECONDS = 600   # how often the bot settles stale executor runs
_warned_missing = False


class ExecutorRefused(Exception):
    """HQ said no. Nothing was executed and nothing was reserved."""


def _rpc(name: str, args: dict):
    return hq._request("POST", f"/rest/v1/rpc/{name}", args)


def result_sha256(result) -> str:
    raw = result if isinstance(result, (bytes, str)) else json.dumps(result, sort_keys=True, default=str)
    return hashlib.sha256(raw.encode() if isinstance(raw, str) else raw).hexdigest()


def run(executor: str, agent: str, task_id: str, est_cents: int, purpose: str, work):
    """work(run_id) -> (result, actual_cents). Returns {'status', 'dry_run', 'run_id', 'result'}."""
    d = _rpc("executor_request", {"p_executor": executor, "p_agent": agent, "p_task": task_id,
                                  "p_est_cents": int(est_cents), "p_purpose": purpose})
    if not d.get("ok"):
        raise ExecutorRefused(d.get("reason") or "refused")
    if d.get("dry_run"):
        return {"status": "dry_run", "dry_run": True, "run_id": d["run_id"], "result": None}
    run_id = d["run_id"]
    try:
        result, actual = work(run_id)
        actual = max(0, int(actual))
    except BaseException:
        # settle at the full reservation: a crash must not look free, and must not stay reserved.
        # If settling itself fails, keep the ORIGINAL error visible; expire_stale() will charge the reservation later.
        try:
            _rpc("executor_complete", {"p_run": run_id, "p_actual_cents": int(est_cents), "p_status": "failed"})
        except Exception:
            pass
        raise
    args = {"p_run": run_id, "p_actual_cents": actual, "p_status": "done", "p_result_sha256": result_sha256(result)}
    try:
        _rpc("executor_complete", args)
    except Exception:
        _rpc("executor_complete", args)   # one retry; if it still fails the error surfaces and expire_stale() settles the run
    return {"status": "done", "dry_run": False, "run_id": run_id, "result": result}


def expire_stale(minutes: int = 60) -> int:
    return int(_rpc("executor_expire_stale", {"p_minutes": int(minutes)}))


def expire_stale_sync(minutes: int = 60):
    """Settle executor runs stuck in 'running' (charges the full reservation, so a hung worker cannot hide spend).
    Never raises. Returns the number settled, or None if it could not run (HQ off, migration not applied, network)."""
    global _warned_missing
    if not hq.hq_enabled():
        return None
    try:
        n = expire_stale(minutes)
    except urllib.error.HTTPError as e:
        if e.code in (400, 404):   # executor_expire_stale not installed yet (migration 20261117_executor_gate_v1 not applied): a quiet no-op
            if not _warned_missing:
                logger.info("executor_expire_stale is not installed yet; skipping (HTTP %s)", e.code)
                _warned_missing = True
        else:
            logger.warning("executor_expire_stale failed: HTTP %s", e.code)
        return None
    except Exception:
        logger.exception("executor_expire_stale failed")
        return None
    if n:
        logger.warning("settled %s stale executor run(s) at their full reservation", n)
    return n


async def expire_stale_job(context) -> None:
    """Repeating job (python-telegram-bot job_queue). Deliberately NOT part of hq_engine.tick: that returns early when the kill switch
    or a credits pause is on, and settling stale reservations must keep working then."""
    await asyncio.to_thread(expire_stale_sync)
