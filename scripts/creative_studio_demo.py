#!/usr/bin/env python3
"""FENDEZY AI CREATIVE STUDIO, M8a sandbox end-to-end demo (no network, no money, no providers).

Runs the REAL database gates (migrations/20261205_creative_studio_v1.sql on a scratch replica) and the REAL ffmpeg edit / render path with the sandbox adapter:
office request -> brief -> generate an image AND a video -> render platform files (9:16, 1:1, 16:9) -> QA -> owner approval -> draft post through the hands
pipeline -> cost tracked -> performance recorded -> the best asset reused by a new job.
Everything happens in ONE transaction that is ROLLED BACK at the end (pass --keep to commit on a scratch database). Never point it at production.

    python3 scripts/creative_studio_demo.py --db postgresql://postgres@localhost:5862/postgres [--out DIR] [--keep]
"""
from __future__ import annotations

import argparse
import json
import os
import sys
import tempfile

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
import hq_creative_studio as cs  # noqa: E402

OWNER = "99999999-9999-9999-9999-99999999c5de"


class PgRpc:
    """rpc(name, args) -> the function's jsonb, called with named arguments on one psycopg2 connection. as_owner sets the signed-in owner."""

    def __init__(self, url: str):
        import psycopg2
        import psycopg2.extras
        self._json = psycopg2.extras.Json
        self.conn = psycopg2.connect(url)
        self.cur = self.conn.cursor()

    def sql(self, q: str, args=None):
        self.cur.execute(q, args)
        return self.cur.fetchall() if self.cur.description else None

    def __call__(self, name: str, args: dict, as_owner: bool = False):
        self.sql("select set_config('app.uid', %s, true)", (OWNER if as_owner else "",))
        names = ", ".join(f"{k} => %s" for k in args)
        vals = [self._json(v) if isinstance(v, dict) else v for v in args.values()]
        self.sql("savepoint rpc")
        try:
            row = self.sql(f"select public.{name}({names})::text", vals)
        except Exception as e:
            self.sql("rollback to savepoint rpc")
            raise cs.StudioError(str(e).splitlines()[0]) from None
        self.sql("release savepoint rpc")
        return json.loads(row[0][0]) if row and row[0][0] else None


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--db", required=True)
    ap.add_argument("--out", default=None)
    ap.add_argument("--keep", action="store_true")
    a = ap.parse_args()
    out = a.out or tempfile.mkdtemp(prefix="creative-demo-")
    db = PgRpc(a.db)
    owner = lambda name, args: db(name, args, as_owner=True)
    log = lambda *x: print(*x, flush=True)
    env = {"CREATIVE_STUDIO_MODE": "sandbox"}
    # ---- sandbox setup (owner steps of ops/OWNER_CREATIVE_STUDIO.sql, done as a db session here)
    db.sql("insert into auth.users (id, email) values (%s, 'creative-demo@example.invalid') on conflict do nothing", (OWNER,))
    db.sql("insert into public.app_owners (email) values ('creative-demo@example.invalid') on conflict do nothing")
    db.sql("""insert into public.fz_services (service, title, owner_office, writes, reads, attribution, scoped_identity, modules, note)
              select 'creative_studio', 'FENDEZY AI CREATIVE STUDIO', id, '{hand_actions}', '{}', 'derived', 'jarvis', 'hq_creative_studio.py', 'sandbox demo'
                from public.fz_offices where slug = 'group' on conflict (service) do update set status = 'active'""")
    db.sql("select set_config('app.uid', %s, true)", (OWNER,))
    db.sql("select public.fz_owner_set_office_status('the-trap', 'active')")
    db.sql("update fz_office_os.fz_office_profiles set manager = coalesce(manager, 'demo manager'), status = 'active', activated_at = coalesce(activated_at, now()) where slug = 'the-trap'")
    owner("creative_owner_set_provider", {"p_slug": "sandbox", "p_enabled": True})
    owner("creative_owner_set_brand_kit", {"p_scope": "the-trap", "p_kit": {"tone": "bold streetwear", "colours": ["#111111", "#f4c430"], "dont": ["guaranteed"], "disclaimers": []}})
    acct = db.sql("""insert into public.hand_accounts (connector, division, handle, purpose, status) values ('tiktok', 'the-trap', 'trap_demo', 'sandbox demo account', 'connected')
                     returning id""")[0][0]
    # ---- 1. an office request -> brief
    img = db("creative_submit", {"p_office": "the-trap", "p_module": "image", "p_brief": "Product photo of the black hoodie on a concrete background, golden light.",
                                 "p_quality": "high", "p_platforms": ["1:1", "9:16"]})
    vid = db("creative_submit", {"p_office": "the-trap", "p_module": "video", "p_brief": "Five second product video of the black hoodie, slow orbit, street at dusk.",
                                 "p_quality": "standard", "p_platforms": ["9:16", "16:9"]})
    log("1. requests:", img["job"], vid["job"])
    # ---- 2-4. generate, edit / render, QA
    store = cs.LocalStore(os.path.join(out, "bucket"))
    results = [cs.run_job(j["job"], rpc=db, store=store, env=env, workdir=os.path.join(out, j["job"][:8])) for j in (img, vid)]
    for r in results:
        log(f"2-4. job {r['job'][:8]}: {r['status']}; attempts {[(x['provider'], x['model'], x['outcome']) for x in r['attempts']]}")
        for x in r.get("assets", []):
            log(f"     {x['platform']}: {x['path']} {cs.probe(os.path.join(out, 'bucket', x['path']))}")
        assert r["status"] == "awaiting_approval", r
    # ---- 5. submit for approval -> the owner decides
    for r in results:
        owner("creative_owner_decide", {"p_job": r["job"], "p_approved": True, "p_note": "demo approval"})
    log("5. owner approved both jobs")
    # ---- publishing: a DRAFT post through the existing hands pipeline (the owner approves it there)
    hands = lambda c, acc, action, payload, scheduled_at=None, ai_generated=True, by="jarvis": db("hands_submit_action", {
        "p_connector": c, "p_account": acc, "p_action": action, "p_payload": payload, "p_scheduled_at": scheduled_at, "p_ai_generated": ai_generated, "p_by": by})
    v_asset = results[1]["assets"][0]["asset"]
    post = cs.schedule_post(v_asset, "tiktok", str(acct), "2026-12-01T17:00:00-05:00", "New drop: the black hoodie.", store.url(results[1]["assets"][0]["path"]),
                            rpc=db, hands_submit=hands)
    status = db.sql("select status from public.hand_actions where id = %s", (post["hand_action"],))[0][0]
    log(f"   post drafted: entry {post['entry'][:8]}, hands action {post['hand_action'][:8]} status {status} (waits for the owner)")
    # ---- 6. cost, 7. performance
    db("creative_perf_record", {"p_asset": v_asset, "p_metric": "engagement", "p_value": 420, "p_source": "sandbox insights"})
    db("creative_perf_record", {"p_asset": v_asset, "p_metric": "leads", "p_value": 3, "p_source": "sandbox insights"})
    log("6-7. report:\n" + cs.report_text(rpc=db))
    # ---- 8. reuse the best asset
    best = db("creative_assets", {"p_office": "the-trap", "p_best": True, "p_limit": 1})[0]
    re_job = db("creative_submit", {"p_office": "the-trap", "p_module": "video", "p_brief": "Remix of the best hoodie video for a 16:9 banner.", "p_quality": "standard",
                                    "p_platforms": ["16:9"], "p_reuse_of": best["id"]})
    r3 = cs.run_job(re_job["job"], rpc=db, store=store, env=env, workdir=os.path.join(out, "reuse"))
    log(f"8. reused asset {best['id'][:8]} (score {best['score']}) -> job {r3['job'][:8]} {r3['status']}")
    assert r3["status"] == "awaiting_approval"
    if a.keep:
        db.conn.commit()
        log("committed (scratch database)")
    else:
        db.conn.rollback()
        log("rolled back: the database is unchanged")
    log(f"media: {out}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
