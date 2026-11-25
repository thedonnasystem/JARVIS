#!/usr/bin/env python3
"""FENDEZY AI CREATIVE STUDIO, M8 sandbox end-to-end demo (no network, no money, no providers).

Runs the REAL database gates (migrations/20261205_creative_studio_v1.sql on a scratch replica) and the REAL ffmpeg edit / render path with the sandbox adapter:
office request -> brief -> generate an image AND a video -> render platform files (9:16, 1:1, 16:9) -> QA -> owner approval -> draft post through the hands
pipeline -> cost tracked -> performance recorded -> the best asset reused by a new job.
M8c adds: templates chosen per office, a voice-over UGC video with word-timed burned captions (faster-whisper when installed, script timing otherwise;
espeak-ng makes the test voice when present), a beat-synced B-roll edit on the free local-edit provider, a lyric video for B2B Records, a metrics import
and the ranking that picks the next job's template.
Everything happens in ONE transaction that is ROLLED BACK at the end (pass --keep to commit on a scratch database). Never point it at production.

    python3 scripts/creative_studio_demo.py --db postgresql://postgres@localhost:5862/postgres [--out DIR] [--keep] [--save DIR]
"""
from __future__ import annotations

import argparse
import json
import os
import shutil
import subprocess
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
        names = ", ".join(f"{k} => %s" + ("::uuid[]" if k == "p_inputs" else "") for k in args)
        vals = [self._json(v) if isinstance(v, dict) or (isinstance(v, list) and v and isinstance(v[0], dict)) else v for v in args.values()]
        self.sql("savepoint rpc")
        try:
            row = self.sql(f"select public.{name}({names})::text", vals)
        except Exception as e:
            self.sql("rollback to savepoint rpc")
            raise cs.StudioError(str(e).splitlines()[0]) from None
        self.sql("release savepoint rpc")
        return json.loads(row[0][0]) if row and row[0][0] else None


class VoiceSandbox(cs.SandboxAdapter):
    """Sandbox test media WITH a spoken track: espeak-ng (GPL, a system test tool only; never shipped) reads the prompt's first sentence, so the captions
    step has real speech to transcribe. Falls back to the plain sandbox tone when espeak-ng is missing."""

    def __init__(self, text_for):
        self.text_for = text_for

    def generate(self, module, model, spec, workdir):
        out = super().generate(module, model, spec, workdir)
        text = self.text_for(spec)
        if not text or not shutil.which("espeak-ng") or module not in ("video", "ugc", "music", "voice"):
            return out
        wav = os.path.join(workdir, "voice.wav")
        subprocess.run(["espeak-ng", "-s", "150", "-w", wav, text], check=True, capture_output=True, timeout=60)
        dur = cs.probe(wav)["duration"]
        if module in ("music", "voice"):
            dst = os.path.join(workdir, "raw-voice.m4a")
            cs._ff(["-i", wav, "-c:a", "aac", dst])
            return {"file": dst, "mime": "audio/mp4", "actual_cents": 0}
        dst = os.path.join(workdir, "raw-voice.mp4")
        cs._ff(["-f", "lavfi", "-i", f"testsrc2=size=1280x720:rate=24:duration={dur:.2f}", "-i", wav, "-map", "0:v", "-map", "1:a", "-c:v", "libx264",
                "-preset", "ultrafast", "-pix_fmt", "yuv420p", "-c:a", "aac", "-shortest", dst])
        return {"file": dst, "mime": "video/mp4", "actual_cents": 0}


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--db", required=True)
    ap.add_argument("--out", default=None)
    ap.add_argument("--keep", action="store_true")
    ap.add_argument("--save", default=None, help="copy the sample captioned videos here")
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
    # ---- M8c 9. UGC with a voice-over: template + hook, word-timed burned captions, AI label, -14 LUFS
    voices = {}
    speak = lambda spec: voices.get("text")
    vs = {"sandbox": VoiceSandbox(speak)}
    voices["text"] = "New drop. The black hoodie is here. Heavy cotton, gold stitching, made for the street."
    ugc = db("creative_submit", {"p_office": "the-trap", "p_module": "ugc", "p_brief": voices["text"], "p_quality": "standard", "p_platforms": ["9:16", "1:1"]})
    db("creative_job_set_template", {"p_job": ugc["job"], "p_template": "trap-unboxing-ugc", "p_hook": "drop-reveal", "p_hook_text": "New drop: the black hoodie",
                                     "p_inputs": [], "p_chosen_by": "request"})
    r9 = cs.run_job(ugc["job"], rpc=db, store=store, env=env, workdir=os.path.join(out, "ugc"), extra_adapters=vs)
    assert r9["status"] == "awaiting_approval", r9
    meta9 = db.sql("select meta from fz_creative.assets where job_id = %s and platform = '9:16'", (ugc["job"],))[0][0]
    log(f"9. UGC {r9['job'][:8]}: template {r9['template']}, hook '{r9['hook']}', captions {meta9['captions']}, loudness in {meta9.get('loudness_in')} -> -14 LUFS")
    owner("creative_owner_decide", {"p_job": ugc["job"], "p_approved": True, "p_note": "demo approval"})
    # ---- 10. beat-synced B-roll edit (free local-edit provider) from the approved clips + a music bed the office uploaded
    owner("creative_owner_set_provider", {"p_slug": "local-edit", "p_enabled": True})
    bed = os.path.join(out, "bed.m4a")
    cs._ff(["-f", "lavfi", "-i", "aevalsrc='0.8*sin(2*PI*60*t)*exp(-12*mod(t,0.5))+0.08*sin(2*PI*220*t)*exp(-6*mod(t+0.25,0.5))':d=10:s=44100",
            "-c:a", "aac", bed])                                                 # a 120 BPM kick + off-beat pattern
    store.put("the-trap/library/bed.m4a", bed, "audio/mp4")
    with open(bed, "rb") as f:
        import hashlib
        bed_sha = hashlib.sha256(f.read()).hexdigest()
    bed_asset = db("creative_asset_add", {"p_office": "the-trap", "p_job": None, "p_kind": "campaign", "p_name": "music-bed", "p_path": "the-trap/library/bed.m4a",
                                          "p_mime": "audio/mp4", "p_bytes": os.path.getsize(bed), "p_sha256": bed_sha})["asset"]
    clips = [a["asset"] for a in results[1]["assets"]] + [a["asset"] for a in r9["assets"] if a["platform"] == "9:16"]
    ed = db("creative_submit", {"p_office": "the-trap", "p_module": "edit", "p_brief": "Hyper motion beat cut of the black hoodie clips.", "p_quality": "standard",
                                "p_platforms": ["9:16"]})
    db("creative_job_set_template", {"p_job": ed["job"], "p_template": "trap-hyper-motion-edit", "p_hook": "drop-reveal", "p_hook_text": "New drop: the black hoodie",
                                     "p_inputs": clips + [bed_asset], "p_chosen_by": "request"})
    r10 = cs.run_job(ed["job"], rpc=db, store=store, env=env, workdir=os.path.join(out, "edit"))
    assert r10["status"] == "awaiting_approval", r10
    meta10 = db.sql("select meta from fz_creative.assets where job_id = %s", (ed["job"],))[0][0]
    log(f"10. edit {r10['job'][:8]}: {meta10['edit']} via {r10['attempts'][0]['provider']}")
    # ---- 11. B2B Records lyric video (word-timed lyrics over a spectrum visualizer)
    db.sql("select set_config('app.uid', %s, true)", (OWNER,))
    db.sql("select public.fz_owner_set_office_status('b2b-records', 'active')")
    db.sql("update fz_office_os.fz_office_profiles set manager = coalesce(manager, 'demo manager'), status = 'active', activated_at = coalesce(activated_at, now()) where slug = 'b2b-records'")
    voices["text"] = "City lights are calling, we keep on rising, money on my mind and the night is young."
    mus = db("creative_submit", {"p_office": "b2b-records", "p_module": "music", "p_brief": voices["text"], "p_quality": "high", "p_platforms": ["9:16"]})
    db("creative_job_set_template", {"p_job": mus["job"], "p_template": "b2b-lyric-video", "p_hook": "lyric-first-line", "p_hook_text": "City lights are calling",
                                     "p_inputs": [], "p_chosen_by": "request"})
    r11 = cs.run_job(mus["job"], rpc=db, store=store, env=env, workdir=os.path.join(out, "lyric"), extra_adapters=vs)
    assert r11["status"] == "awaiting_approval", r11
    log(f"11. lyric video {r11['job'][:8]}: {[(a['platform'], a['path']) for a in r11['assets']]}")
    # ---- 12. metrics (CSV import) -> ranking -> the next job's template
    csv_text = "asset,connector,window_end,views,likes,shares,leads\n" + "\n".join(
        f"{a},tiktok,2026-11-30,{v},{l},{s},{ld}" for a, v, l, s, ld in ((results[1]["assets"][0]["asset"], 1200, 60, 5, 1), (r9["assets"][0]["asset"], 900, 140, 30, 4)))
    imp = cs.import_metrics("the-trap", cs.parse_metrics_csv(csv_text), "manual", "demo.csv", rpc=db)
    log(f"12. metrics import {imp['inserted']} rows, rejected {imp['rejected']}; " + cs.rank_text("the-trap", rpc=db))
    nxt = db("creative_submit", {"p_office": "the-trap", "p_module": "ugc", "p_brief": "Second drop: the gold chain hoodie.", "p_quality": "standard", "p_platforms": ["9:16"]})
    claim_n = db("creative_claim", {"p_job": nxt["job"]})
    hp, lib = cs._library()
    t = cs.choose_template(claim_n, nxt["job"], db, hp, lib)
    log(f"    next UGC job picks template {t and t['template']} ({t and t['chosen_by']}), hook '{t and t['hook_text']}'")
    if a.save:
        os.makedirs(a.save, exist_ok=True)
        for r, name in ((r9, "ugc_captioned"), (r10, "beat_cut_edit"), (r11, "lyric_video")):
            for x in r["assets"]:
                if x["path"].endswith(".mp4"):
                    dst = os.path.join(a.save, f"{name}_{x['platform'].replace(':', 'x')}.mp4")
                    shutil.copyfile(os.path.join(out, "bucket", x["path"]), dst)
                    if os.path.exists(os.path.join(out, "bucket", x["path"] + ".srt")):
                        shutil.copyfile(os.path.join(out, "bucket", x["path"] + ".srt"), dst[:-4] + ".srt")
        log(f"samples saved to {a.save}")
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
