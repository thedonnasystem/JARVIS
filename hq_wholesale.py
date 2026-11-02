"""Bridge from Fendezy HQ to the separate wholesale deal-funnel system (its own Supabase project).

HQ never rebuilds the deal funnel. It only:
  - reads valuation candidates through the funnel's `hq_valuation_candidates` function, and
  - writes AI valuation fields back through the funnel's own `rows_merge` function (merge, never replace).

Dormant until WHOLESALE_SUPABASE_SERVICE_KEY is set on the bot (the URL is not secret and has a default).
"""
from __future__ import annotations

import json
import logging
import os
import urllib.error
import urllib.request

logger = logging.getLogger(__name__)

WHOLESALE_URL = os.environ.get("WHOLESALE_SUPABASE_URL", "https://ojjxtdapusncwdrdybhy.supabase.co").rstrip("/")
FEE_TARGET = 15000  # owner: ~$15k typical assignment fee, $7k floor
ARV_FACTOR = 0.70   # owner: MAO = ARV x 70% - repairs - fee


def enabled() -> bool:
    return bool(os.environ.get("WHOLESALE_SUPABASE_SERVICE_KEY"))


def _rpc(name: str, args: dict, timeout: int = 30):
    key = os.environ.get("WHOLESALE_SUPABASE_SERVICE_KEY", "")
    req = urllib.request.Request(
        f"{WHOLESALE_URL}/rest/v1/rpc/{name}", data=json.dumps(args).encode(), method="POST",
        headers={"apikey": key, "Authorization": f"Bearer {key}", "Content-Type": "application/json"},
    )
    with urllib.request.urlopen(req, timeout=timeout) as r:
        body = r.read().decode()
        return json.loads(body) if body else None


def candidates(limit: int = 3) -> list[dict]:
    if not enabled():
        return []
    try:
        return _rpc("hq_valuation_candidates", {"p_limit": limit}) or []
    except (urllib.error.URLError, TimeoutError, ValueError) as e:
        logger.warning("Wholesale bridge: could not read candidates: %s", e)
        return []


def mao(arv: float, repairs: float, fee: float = FEE_TARGET) -> float:
    return arv * ARV_FACTOR - repairs - fee


def save_valuation(lead_id: str, v: dict, valued_at: str, task_id: str) -> bool:
    """Merge AI fields into the lead. The funnel app decides what they mean (same opportunity rules)."""
    if not enabled():
        return False
    fields = {
        "AI ARV (CAD)": v["arv"], "AI ARV Low (CAD)": v["low"], "AI ARV High (CAD)": v["high"],
        "AI Repairs (CAD)": v["repairs"], "AI ARV Confidence": v["confidence"].upper(),
        "AI ARV Comps": " ".join(v["comps"][:5]), "AI Valued At": valued_at,
        "AI MAO (CAD)": round(mao(v["low"], v["repairs"])),
        "AI Valuation Notes": f"Fendezy HQ real-estate researcher, task {task_id}. MAO uses the LOW ARV: "
                              f"low x {ARV_FACTOR:.0%} - repairs - ${FEE_TARGET:,} fee.",
    }
    try:
        _rpc("rows_merge", {"p_table": "pipeline", "p_patches": [{"id": lead_id, "fields": fields}]})
        return True
    except (urllib.error.URLError, TimeoutError, ValueError) as e:
        logger.warning("Wholesale bridge: could not save valuation for %s: %s", lead_id, e)
        return False
