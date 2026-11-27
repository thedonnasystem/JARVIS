"""Donna Content v1: the weekly organic content push for Donna.AI, through the existing FENDEZY AI CREATIVE STUDIO.

Once a week (Monday from 9 am Ottawa time, the bot's 5-minute tick) it submits this week's posts as creative jobs for the 'donna' office: short 9:16 videos and
1:1 images, rotating through the themes in donna_ops/runners.json "content" (the owner's own hook line first). The studio does the rest with its own gates:
templates and hooks, generation (sandbox = $0; paid models only where the owner enabled them, reserved through the office spend gate), QA with the AI
label, then the OWNER's approval before anything is scheduled or published. Nothing is posted from here.

Switch: DONNA_CONTENT=1, and Donna must be active (creative_submit refuses a dormant office). One week is marked in DONNA_STATE_DIR (default /data, the
bot's Railway volume) so a restart never submits twice. Briefs carry the honesty rules: no statistics, no client results or testimonials, no "was" prices,
the Dec 31 setup offer only while it is true.
"""
from __future__ import annotations

import datetime as dt
import logging
import os

import hq_donna
import hq_donna_revenue as R

logger = logging.getLogger(__name__)
FLAG = "DONNA_CONTENT"
RULES = ("Audience: owners of local service businesses in Canada. Brand: Donna.AI, AI solutions and infrastructure integration. CTA: the free 20-minute "
         "Revenue Leak Audit. Rules: no statistics or numbers about other businesses, no client results, testimonials or reviews, no guarantees, no 'was' "
         "prices; label AI-generated media; plain, confident, short.")


def cfg() -> dict:
    return hq_donna.config().get("content") or {}


def week_key(today: dt.date) -> str:
    y, w, _ = today.isocalendar()
    return f"{y}-W{w:02d}"


def plan(today: dt.date, c: dict | None = None) -> list[dict]:
    """This week's posts: `per_week` themes in rotation (by ISO week), each with its module and platform. Offer lines only while the offer is true."""
    c = c or cfg()
    until = dt.date.fromisoformat(R.rev()["setup_free_until"])
    themes = [t for t in c.get("themes") or [] if not t.get("offer") or today <= until]
    if not themes:
        return []
    n = min(int(c.get("per_week", 5)), len(themes))
    start = (today.isocalendar()[1] * n) % len(themes)
    pick = [themes[(start + i) % len(themes)] for i in range(n)]
    if c.get("pin_first"):                                               # the owner's hook line leads every week
        pick = [themes[0]] + [t for t in pick if t is not themes[0]][:n - 1]
    return [{"module": t.get("module", "video"), "platforms": [t.get("platform", "9:16")],
             "brief": f"{t['brief']} Hook: \"{t['hook']}\". {RULES}"[:1900], "theme": t["id"]} for t in pick]


def _state_path(env: dict) -> str:
    return os.path.join(env.get("DONNA_STATE_DIR") or "/data", "donna_content_week.txt")


def due(today_dt: dt.datetime, env: dict) -> bool:
    if today_dt.weekday() != 0 or today_dt.hour < 9:
        return False
    try:
        with open(_state_path(env)) as f:
            return f.read().strip() != week_key(today_dt.date())
    except OSError:
        return True


def submit_week(rpc=None, env: dict | None = None, now: dt.datetime | None = None) -> dict:
    """Submit this week's creative jobs once. Never raises."""
    env = os.environ if env is None else env
    rpc = rpc or hq_donna._rpc_default
    now = now or dt.datetime.now(R.TZ)
    out = {"submitted": [], "refused": []}
    if env.get(FLAG) != "1":
        out["off"] = f"{FLAG} is not 1"
        return out
    if not due(now, env):
        out["not_due"] = True
        return out
    for p in plan(now.date()):
        try:
            r = rpc("creative_submit", {"p_office": "donna", "p_module": p["module"], "p_brief": p["brief"], "p_quality": "standard",
                                        "p_platforms": p["platforms"], "p_by": "donna:content"}) or {}
            out["submitted"].append({"theme": p["theme"], "job": r.get("job")})
        except Exception as e:
            out["refused"].append({"theme": p["theme"], "reason": str(e)[:160]})
    if out["submitted"]:
        try:
            os.makedirs(os.path.dirname(_state_path(env)), exist_ok=True)
            with open(_state_path(env), "w") as f:
                f.write(week_key(now.date()))
        except OSError as e:
            out["state_error"] = type(e).__name__
    return out
