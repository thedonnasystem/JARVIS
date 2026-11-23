#!/usr/bin/env python3
"""FENDEZY AI CREATIVE STUDIO: the FIRST REAL RUN (owner only). Never run by an agent.

Without --run it only CHECKS and prints the plan (no request leaves the machine). With --run it submits ONE image job and ONE short video job for one
office and runs them through the hosted open-weight path (fal.ai or Replicate). Every paid call still goes through the office spend gate
(hq_office_money.reserve -> caps, per-transaction and weekly limits, owner approval rules), and this script refuses any single attempt above --max-cents.

Prerequisites (ops/OWNER_CREATIVE_STUDIO.sql + docs/architecture/PHASE1_M8_CREATIVE_STUDIO.md "First real run"):
  the studio registered (fz_services creative_studio active), the office active, the provider enabled by the owner, its key in the environment,
  CREATIVE_STUDIO_MODE=live, the private bucket 'creative-studio' created, HQ_SUPABASE_URL / HQ_SUPABASE_SERVICE_KEY set.

    python3 scripts/creative_studio_first_run.py --office ff-marketing                     # checks only
    python3 scripts/creative_studio_first_run.py --office ff-marketing --run --max-cents 50  # real, small, owner-approved spend
"""
from __future__ import annotations

import argparse
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
import hq_creative_studio as cs  # noqa: E402

KEYS = ("FAL_KEY", "REPLICATE_API_TOKEN")
PLAN = [("image", "Hero still of the product on a clean studio background, soft key light.", ["1:1", "9:16"]),
        ("video", "Five second product shot, slow orbit, soft key light.", ["9:16"])]


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--office", required=True)
    ap.add_argument("--run", action="store_true")
    ap.add_argument("--max-cents", type=int, default=50)
    a = ap.parse_args()
    env = dict(os.environ)
    print("Mode:", cs.mode(env), "| keys present:", ", ".join(k for k in KEYS if env.get(k)) or "none")
    fal = {"slug": "fal-hosted", "est_cents": 0, "unit": "output"}
    print("Estimates (CAD, ESTIMATES): image flux.1-schnell", cs.estimate_cents(fal, "flux.1-schnell", "image", {}), "c;",
          "video wan-2.2-ti2v-5b 5s", cs.estimate_cents(fal, "wan-2.2-ti2v-5b", "video", {"seconds": 5}), "c. Cap per attempt:", a.max_cents, "c")
    if not a.run:
        print("Checks only. Nothing was sent. Re-run with --run after the owner steps.")
        return 0
    if cs.mode(env) != "live" or not any(env.get(k) for k in KEYS):
        print("Refused: set CREATIVE_STUDIO_MODE=live and a provider key first.")
        return 2
    import hq
    import hq_office_os
    store = cs.SupabaseStore(hq.HQ_SUPABASE_URL, hq.HQ_SUPABASE_SERVICE_KEY)

    def capped(office, cand, job):
        if cand["est"] > a.max_cents:
            return {"decision": "deny", "reason": f"over the first-run cap ({cand['est']} > {a.max_cents} cents)"}
        return cs._reserve(office, cand, job)

    for module, brief, platforms in PLAN:
        j = cs._rpc_default("creative_submit", {"p_office": a.office, "p_module": module, "p_brief": brief, "p_quality": "standard", "p_platforms": platforms,
                                                "p_by": "owner:first-run"})
        r = cs.run_job(j["job"], store=store, env=env, money=capped, brain=hq_office_os.brain_facts)
        print(module, r["status"], r.get("reason", ""), [(x["provider"], x["model"], x["outcome"]) for x in r.get("attempts", [])])
    print(cs.report_text())
    print("Approve or reject in SQL: select public.creative_owner_decide('<job>', true);")
    return 0


if __name__ == "__main__":
    sys.exit(main())
