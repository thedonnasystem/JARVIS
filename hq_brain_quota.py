"""
Free-provider quota counters that survive a restart (Nov 23 2026, docs/architecture/LINKED_MEMORY.md section 5).

hq_llm.TRACKER (requests per minute / day, tokens per minute, cool-downs) lives in memory. This module mirrors it to the database (jquota_record /
jquota_load, schema fz_memory, counts only: no prompt, no money) and loads it back at start, so a redeploy no longer resets "quota left today" to 100%
and the router does not hammer a provider that is still at its limit. hq_llm is not changed: the SAME tracker object is read and refilled through its
public state (req / tok / cool / fails), so every caller of hq_llm.complete shares one set of counts.

  * load once, lazily, before the first open-brain call (hydrate); then sync() at most every FLUSH_EVERY seconds, and at once when a cool-down changes.
  * Best-effort: database trouble never blocks a model call (the providers' own 429s still apply, as before).
  * On with the open brain (JARVIS_OPEN_BRAIN=1). Off with JARVIS_QUOTA_PERSIST=0, and whenever the HQ database is not configured.
  * A failed load is retried at most every RETRY_LOAD seconds (a database outage costs one quick failed request per few minutes, not one per call).
"""

from __future__ import annotations

import datetime
import logging
import os
import threading
import time

import hq
import hq_llm

logger = logging.getLogger(__name__)

FLUSH_EVERY = 15.0
RETRY_LOAD = 300.0
LOW_HEADROOM = 0.15              # below this on the best provider of a route, the owner gets one heads-up
NOTE_EVERY = 1800.0              # at most one heads-up per 30 minutes


def enabled() -> bool:
    return (os.environ.get("JARVIS_OPEN_BRAIN", "").strip() == "1" and os.environ.get("JARVIS_QUOTA_PERSIST", "1").strip() != "0"
            and hq.hq_enabled())


class QuotaStore:
    def __init__(self, tracker: "hq_llm.RateTracker | None" = None, request=None, clock=time.time):
        self.tracker = tracker or hq_llm.TRACKER
        self.request = request
        self.clock = clock
        self.loaded = False
        self.synced: dict[str, float] = {}       # provider -> newest request timestamp already in the database
        self.cool_seen: dict[str, tuple] = {}    # provider -> (cooling_until, fails) last written
        self.last_flush = 0.0
        self.retry_at = 0.0
        self.lock = threading.Lock()

    def _rpc(self, name, body):
        return (self.request or hq._request)("POST", f"/rest/v1/rpc/{name}", body)

    def hydrate(self) -> bool:
        """Refill the tracker from the last 24 hours in the database. A slot's requests are placed at the END of its hour (capped at now): they are
        never forgotten early (conservative: a provider may look a little busier than it is for up to an hour)."""
        with self.lock:
            if self.loaded:
                return True
            if self.clock() < self.retry_at:
                return False
            try:
                d = self._rpc("jquota_load", {}) or {}
            except Exception as e:
                self.retry_at = self.clock() + RETRY_LOAD
                logger.info("quota counters not loaded: %s", str(e)[:120])
                return False
            now = self.clock()
            t = self.tracker
            for h in d.get("hours") or []:
                p, n = str(h.get("provider") or ""), int(h.get("requests") or 0)
                if not p or n <= 0:
                    continue
                at = min(float(h.get("hour") or 0) + 3599.0, now)
                if at <= now - 86400:
                    continue
                t.req.setdefault(p, []).extend([at] * min(n, 100000))
                t.req[p].sort()
                self.synced[p] = max(self.synced.get(p, 0.0), at)
            for p, s in (d.get("state") or {}).items():
                until = s.get("cooling_until")
                if until and float(until) > now:
                    t.cool[p] = max(t.cool.get(p, 0.0), float(until))
                t.fails[p] = max(t.fails.get(p, 0), int(s.get("fails") or 0))
                c = t.cool.get(p)
                self.cool_seen[p] = (c if c and c > now else None, int(t.fails.get(p, 0) or 0))
            for p, stamps in t.req.items():             # anything recorded before the load is already counted locally; persist it on the next sync
                self.synced.setdefault(p, 0.0)
            self.loaded = True
            return True

    def sync(self, force: bool = False) -> int:
        """Write the new request / token counts and changed cool-downs. Returns how many providers were written."""
        if not self.loaded and not self.hydrate():
            return 0
        with self.lock:
            now = self.clock()
            t = self.tracker
            def cool_of(p):
                c = t.cool.get(p)
                return (c if c and c > now else None, int(t.fails.get(p, 0) or 0))
            changed_cool = [p for p in set(t.cool) | set(t.fails) if self.cool_seen.get(p, (None, 0)) != cool_of(p)]
            if not force and not changed_cool and now - self.last_flush < FLUSH_EVERY:
                return 0
            written = 0
            for p in sorted(set(t.req) | set(changed_cool)):
                since = self.synced.get(p, 0.0)
                new = [x for x in t.req.get(p, []) if x > since]
                toks = sum(n for x, n in t.tok.get(p, []) if x > since)
                cool = cool_of(p)
                if not new and self.cool_seen.get(p, (None, 0)) == cool:
                    continue
                until = cool[0]
                try:
                    self._rpc("jquota_record", {"p_provider": p, "p_requests": len(new), "p_tokens": int(toks),
                                                "p_cooling_until": datetime.datetime.fromtimestamp(min(until, now + 86000), datetime.timezone.utc).isoformat() if until else None,
                                                "p_fails": min(int(cool[1] or 0), 1000)})
                except Exception as e:
                    logger.info("quota counters not saved: %s", str(e)[:120])
                    return written
                if new:
                    self.synced[p] = max(new)
                self.cool_seen[p] = cool
                written += 1
            self.last_flush = now
            return written


STORE = QuotaStore()
_NOTE = {"at": 0.0}


def before_call() -> None:
    if enabled():
        STORE.hydrate()


def after_call() -> None:
    if enabled():
        try:
            STORE.sync()
        except Exception as e:
            logger.info("quota sync failed: %s", str(e)[:120])


def route_headroom(job: str = "chat", env: dict | None = None, tracker=None) -> float | None:
    """Best quota left today (0..1) among the configured free providers of a job's route; None when none is configured."""
    st = hq_llm.brain_status(env, tracker)
    chain = set((st.get("routes") or {}).get(job, {}).get("chain") or [])
    hs = [p["headroom"] for p in st["providers"] if p["configured"] and not p["paid"] and (not chain or p["name"] in chain)]
    return max(hs) if hs else None


def next_capacity_s(job: str = "chat", env: dict | None = None, tracker=None) -> int | None:
    """Seconds until the earliest free provider of the route can take a request again (cool-down end, or the oldest request of a full day leaving
    the 24-hour window, or a full minute passing). None when nothing is configured."""
    t = tracker or hq_llm.TRACKER
    chain = (hq_llm.ROUTES.get(job) or {}).get("chain")
    now = t.clock()
    best = None
    for p in hq_llm.load_providers(env):
        if p.paid or p.problems() or (chain and p.name not in chain):
            continue
        waits = [max(0.0, t.cool.get(p.name, 0.0) - now)]
        stamps = sorted(x for x in t.req.get(p.name, []) if x > now - 86400)
        if p.limits.get("rpd") and len(stamps) >= p.limits["rpd"]:
            waits.append(stamps[len(stamps) - p.limits["rpd"]] + 86400 - now)
        if p.limits.get("rpm") and sum(1 for x in stamps if x > now - 60) >= p.limits["rpm"]:
            waits.append(60.0)
        w = max(waits)
        best = w if best is None else min(best, w)
    return None if best is None else int(best)


def _human(s: int) -> str:
    return f"{max(1, s // 60)} min" if s < 3600 else f"{s // 3600} h {(s % 3600) // 60} min"


def exhausted_text(job: str = "chat", env: dict | None = None) -> str:
    """hq_llm.EXHAUSTED_REPLY plus when the earliest free capacity comes back (no ' (' in it: the bot cuts the reason off there)."""
    s = next_capacity_s(job, env)
    if s is None or s <= 0:
        return hq_llm.EXHAUSTED_REPLY
    return hq_llm.EXHAUSTED_REPLY + f" Earliest free capacity: in about {_human(s)}."


def degradation_note(job: str = "chat", env: dict | None = None, clock=time.time) -> str:
    """One short heads-up (at most every NOTE_EVERY seconds) when the best free provider of the route is low on today's quota. Empty otherwise."""
    h = route_headroom(job, env)
    if h is None or h >= LOW_HEADROOM or clock() - _NOTE["at"] < NOTE_EVERY:
        return ""
    _NOTE["at"] = clock()
    return f"\n\n(Heads-up, sir: free model quota is low today, about {int(h * 100)}% left on the best provider. I am keeping context lean; long jobs may queue.)"


def low() -> bool:
    try:
        h = route_headroom("chat")
    except Exception:
        return False
    return h is not None and h < LOW_HEADROOM


def status_line() -> str:
    if not enabled():
        return "Quota counters: in memory only (open brain off, JARVIS_QUOTA_PERSIST=0 or HQ database not set)"
    ok = STORE.hydrate()
    return "Quota counters: " + ("saved in the database, survive restarts" if ok else "database unreachable; in memory for now")
