#!/usr/bin/env python3
"""FENDEZY creative GPU worker: one command on any NVIDIA GPU box (Kaggle notebook, RunPod / Vast.ai pod, an owned PC with Linux or WSL2).

  python3 fz_worker.py --profile t4                      # Kaggle T4: ComfyUI + models + token proxy + Cloudflare quick tunnel, prints the two Railway values
  python3 fz_worker.py --profile 24gb --tunnel runpod    # RunPod pod: uses the pod's own https proxy (expose port 8189/http)
  python3 fz_worker.py --profile t4 --batch jobs.json    # no tunnel at all: runs a batch file locally and writes outputs + metadata to --out (Colab)
  python3 fz_worker.py --profile t4 --selftest           # one tiny generation per workflow: proves the graphs on THIS worker

What it does: clones ComfyUI (--comfy-ref), installs it, downloads only the weights of the profile (creative_studio/selfhost/manifest.json: licences listed
there), starts ComfyUI on 127.0.0.1:8188, and puts a bearer-token proxy in front (port 8189) that forwards ONLY the API routes the studio uses plus
/fz/tts (Kokoro-82M) and /fz/health. The token comes from FZ_WORKER_TOKEN (Kaggle secret / pod env) or is generated and printed once.
Cost control: the worker stops itself after --idle-minutes without requests and after --max-hours in any case (on RunPod it stops the pod with runpodctl;
elsewhere it exits). Nothing here spends money by itself; a rented pod is billed by its provider while it runs.
Content rules: batch and selftest jobs go through the same checks as the studio (hq_creative_selfhost: no minors, no sexual content, no impersonation).
"""
import argparse
import asyncio
import hmac
import io
import json
import os
import re
import secrets
import shutil
import subprocess
import sys
import threading
import time
import urllib.error
import urllib.request

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.normpath(os.path.join(HERE, "..", "..", ".."))
COMFY_PORT, PROXY_PORT = 8188, 8189
ROUTES = re.compile(r"^/(system_stats|object_info|prompt|queue|interrupt|upload/image|view|history/[A-Za-z0-9-]{8,80}|fz/health|fz/tts)$")
MAX_BODY = 60 * 1024 * 1024
STATE = {"last": time.time(), "started": time.time()}


def log(*a):
    print("[fz-worker]", *a, flush=True)


def sh(args, **k):
    log("$", " ".join(args) if isinstance(args, list) else args)
    return subprocess.run(args, check=True, **k)


# ------------------------------------------------------------------------------------------------------------------- install
def manifest():
    with open(os.path.join(REPO, "creative_studio", "selfhost", "manifest.json")) as f:
        return json.load(f)


def profile_files(m, profile):
    p = m["profiles"][profile]
    names = []
    for wid in p["workflows"]:
        w = m["workflows"].get(wid) or m["shared"].get(wid) or {}
        names += [n for n in w.get("files", []) if n not in names]
    return names


def install(root, ref, profile, skip_models=False):
    comfy = os.path.join(root, "ComfyUI")
    if not os.path.isdir(comfy):
        sh(["git", "clone", "--depth", "50", "https://github.com/comfyanonymous/ComfyUI", comfy])
    if ref and ref != "master":
        sh(["git", "-C", comfy, "fetch", "--depth", "50", "origin", ref])
        sh(["git", "-C", comfy, "checkout", "-q", ref])
    commit = subprocess.run(["git", "-C", comfy, "rev-parse", "HEAD"], capture_output=True, text=True).stdout.strip()
    log("ComfyUI commit", commit, "(pin it with --comfy-ref once the selftest passes)")
    sh([sys.executable, "-m", "pip", "install", "-q", "-r", os.path.join(comfy, "requirements.txt")])
    sh([sys.executable, "-m", "pip", "install", "-q", "huggingface_hub", "kokoro>=0.9", "soundfile", "aiohttp"])
    if not shutil.which("ffmpeg") or not shutil.which("espeak-ng"):
        subprocess.run("(apt-get update -qq && apt-get install -y -qq ffmpeg espeak-ng) >/dev/null 2>&1 || true", shell=True)
    if skip_models:
        return comfy, commit
    from huggingface_hub import hf_hub_download
    m = manifest()
    for name in profile_files(m, profile):
        d = m["downloads"][name]
        dst = os.path.join(comfy, "models", d["dir"], name)
        if os.path.exists(dst):
            continue
        log(f"download {name} ({d['gb']} GB, {d['licence']})")
        src = hf_hub_download(d["repo"], d["path"], local_dir=os.path.join(root, "hf"))
        os.makedirs(os.path.dirname(dst), exist_ok=True)
        os.symlink(src, dst)
    return comfy, commit


def start_comfy(comfy):
    p = subprocess.Popen([sys.executable, "main.py", "--listen", "127.0.0.1", "--port", str(COMFY_PORT), "--disable-auto-launch"], cwd=comfy)
    for _ in range(300):
        try:
            urllib.request.urlopen(f"http://127.0.0.1:{COMFY_PORT}/system_stats", timeout=3).read()
            return p
        except Exception:
            if p.poll() is not None:
                raise SystemExit("ComfyUI exited during start-up")
            time.sleep(2)
    raise SystemExit("ComfyUI did not answer in 10 minutes")


# ------------------------------------------------------------------------------------------------------------------- token proxy + TTS
_KOKORO = {}


def tts_wav(text, voice):
    import numpy as np
    import soundfile as sf
    from kokoro import KPipeline
    lang = voice[0] if voice[:1] in ("a", "b") else "a"
    if lang not in _KOKORO:
        _KOKORO[lang] = KPipeline(lang_code=lang)
    chunks = [a for _, _, a in _KOKORO[lang](text, voice=voice)]
    if not chunks:
        raise ValueError("no audio")
    buf = io.BytesIO()
    sf.write(buf, np.concatenate([np.asarray(c) for c in chunks]), 24000, format="WAV")
    return buf.getvalue()


def make_proxy(token):
    from aiohttp import ClientSession, ClientTimeout, web

    async def handle(req):
        if not hmac.compare_digest(req.headers.get("Authorization", ""), f"Bearer {token}"):
            return web.Response(status=401, text="unauthorized")
        if not ROUTES.match(req.path):
            return web.Response(status=404, text="not here")
        STATE["last"] = time.time()
        body = await req.read()
        if len(body) > MAX_BODY:
            return web.Response(status=413, text="too large")
        if req.path == "/fz/health":
            return web.json_response({"ok": True, "uptime_s": int(time.time() - STATE["started"])})
        if req.path == "/fz/tts":
            try:
                j = json.loads(body or b"{}")
                text, voice = str(j.get("text") or "")[:3000], str(j.get("voice") or "af_heart")
                if not text.strip() or not re.fullmatch(r"[a-z]{2}_[a-z]{2,20}", voice):
                    return web.Response(status=400, text="text and a stock voice id are required")
                wav = await asyncio.get_running_loop().run_in_executor(None, tts_wav, text, voice)
                return web.Response(body=wav, content_type="audio/wav")
            except Exception as e:
                return web.Response(status=500, text=f"tts failed: {type(e).__name__}")
        headers = {k: v for k, v in req.headers.items() if k.lower() in ("content-type",)}
        async with ClientSession(timeout=ClientTimeout(total=600)) as s:
            async with s.request(req.method, f"http://127.0.0.1:{COMFY_PORT}{req.path_qs}", data=body or None, headers=headers) as r:
                data = await r.read()
                return web.Response(status=r.status, body=data, content_type=r.content_type)

    app = web.Application(client_max_size=MAX_BODY)
    app.router.add_route("*", "/{tail:.*}", handle)
    return app


def run_proxy(token, bind):
    from aiohttp import web
    loop = asyncio.new_event_loop()
    asyncio.set_event_loop(loop)
    runner = web.AppRunner(make_proxy(token))
    loop.run_until_complete(runner.setup())
    loop.run_until_complete(web.TCPSite(runner, bind, PROXY_PORT).start())
    loop.run_forever()


# ------------------------------------------------------------------------------------------------------------------- tunnel
def cloudflared(root):
    exe = os.path.join(root, "cloudflared")
    if not os.path.exists(exe):
        urllib.request.urlretrieve("https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64", exe)
        os.chmod(exe, 0o755)
    p = subprocess.Popen([exe, "tunnel", "--no-autoupdate", "--url", f"http://127.0.0.1:{PROXY_PORT}"], stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
    t_end = time.time() + 120
    for line in p.stdout:
        m = re.search(r"https://[a-z0-9-]+\.trycloudflare\.com", line)
        if m:
            threading.Thread(target=lambda: [None for _ in p.stdout], daemon=True).start()
            return m.group(0)
        if time.time() > t_end:
            break
    raise SystemExit("cloudflared did not print a tunnel URL")


def public_url(kind, root):
    if kind == "cloudflared":
        return cloudflared(root)
    if kind == "runpod":
        pod = os.environ.get("RUNPOD_POD_ID")
        if not pod:
            raise SystemExit("--tunnel runpod needs RUNPOD_POD_ID (set inside RunPod pods)")
        return f"https://{pod}-{PROXY_PORT}.proxy.runpod.net"
    return None


# ------------------------------------------------------------------------------------------------------------------- self-stop
def watchdog(idle_min, max_hours, procs):
    while True:
        time.sleep(30)
        idle = time.time() - STATE["last"] > idle_min * 60
        over = time.time() - STATE["started"] > max_hours * 3600
        if idle or over:
            log("stopping:", "idle" if idle else "max hours reached")
            for p in procs:
                p.terminate()
            pod = os.environ.get("RUNPOD_POD_ID")
            if pod and shutil.which("runpodctl"):
                subprocess.run(["runpodctl", "stop", "pod", pod])
            os._exit(0)


# ------------------------------------------------------------------------------------------------------------------- local jobs (selftest / batch)
def local_http(method, url, headers=None, json_body=None, form=None, data=None, timeout=60):
    """Same contract as hq_hands_adapters.http, for http://127.0.0.1 only (the worker talking to its own ComfyUI)."""
    if not url.startswith(f"http://127.0.0.1:{COMFY_PORT}/"):
        raise ValueError("local_http is for the worker's own ComfyUI only")
    h = dict(headers or {})
    h.pop("Authorization", None)
    if json_body is not None:
        data, h["Content-Type"] = json.dumps(json_body).encode(), "application/json"
    req = urllib.request.Request(url, data=data, method=method, headers=h)
    try:
        with urllib.request.urlopen(req, timeout=timeout) as r:
            raw, st, hd = r.read(), r.status, dict(r.headers)
    except urllib.error.HTTPError as e:
        raw, st, hd = e.read() or b"", e.code, dict(e.headers or {})
    try:
        return st, json.loads(raw.decode() or "null"), hd
    except (ValueError, UnicodeDecodeError):
        return st, raw, hd


def local_adapter():
    sys.path.insert(0, REPO)
    import hq_creative_selfhost as sh_
    env = {"COMFYUI_SELFHOST_URL": f"http://127.0.0.1:{COMFY_PORT}", "COMFYUI_SELFHOST_TOKEN": "local"}

    class LocalTTS(sh_.SelfhostAdapter):
        def tts(self, text, voice, workdir):
            out = os.path.join(workdir, "voice.wav")
            with open(out, "wb") as f:
                f.write(tts_wav(text, voice))
            return out
    return sh_, LocalTTS(env, http=local_http, local=True)


def run_local(jobs, out_dir):
    sh_, ad = local_adapter()
    os.makedirs(out_dir, exist_ok=True)
    ad.health(force=True)
    results = []
    for i, j in enumerate(jobs):
        wd = os.path.join(out_dir, f"job{i:03d}")
        os.makedirs(wd, exist_ok=True)
        persona = None
        if j.get("persona"):
            persona = sh_.load_persona_file(j["persona"])
            problems = sh_.persona_problems(persona)
            if problems:
                results.append({"job": i, "status": "refused", "reason": "; ".join(problems)})
                continue
        refusal = sh_.content_refusal(" ".join([j.get("prompt") or "", j.get("script") or ""]))
        if refusal:
            results.append({"job": i, "status": "refused", "reason": refusal})
            continue
        spec = {"prompt": j.get("prompt") or "", "script": j.get("script"), "aspect": j.get("aspect") or "9:16", "seconds": j.get("seconds") or 5,
                "persona": persona, "reference_url": ("file://" + os.path.abspath(j["reference"])) if j.get("reference") else None,
                "lora_name": j.get("lora_name")}
        try:
            r = ad.generate(j["module"], j["model"], spec, wd)
            meta = dict(r["meta"], model=j["model"], module=j["module"], prompt=spec["prompt"][:500], caption_disclosure=sh_.DISCLOSURE)
            with open(r["file"] + ".json", "w") as f:
                json.dump(meta, f, indent=1)
            results.append({"job": i, "status": "ok", "file": r["file"], "seconds": round(r["gpu_ms"] / 1000, 1)})
        except Exception as e:
            results.append({"job": i, "status": "failed", "reason": f"{type(e).__name__}: {str(e)[:200]}"})
        log(json.dumps(results[-1]))
    with open(os.path.join(out_dir, "results.json"), "w") as f:
        json.dump(results, f, indent=1)
    return results


SELFTEST = {
    "z-image-turbo-t2i": {"module": "image", "model": "z-image-turbo", "prompt": "a ceramic coffee mug on a wooden table, soft daylight", "aspect": "1:1"},
    "wan22-ti2v-5b": {"module": "video", "model": "wan-2.2-ti2v-5b", "prompt": "slow pan over a city skyline at dusk", "seconds": 1},
    "wan22-t2v-a14b": {"module": "video", "model": "wan-2.2-t2v-a14b", "prompt": "waves rolling onto a beach", "seconds": 1},
    "kokoro-82m": {"module": "voice", "model": "kokoro-82m", "script": "This is a test of the Fendezy voice worker."},
}


def selftest(profile, out_dir):
    m = manifest()
    p = m["profiles"][profile]
    jobs = [SELFTEST[w] for w in p["workflows"] + p.get("services", []) if w in SELFTEST]
    res = run_local(jobs, out_dir)
    if "wan22-s2v-14b" in p["workflows"]:
        img = next((r["file"] for r in res if r.get("status") == "ok" and r["file"].endswith((".png", ".jpg", ".webp"))), None)
        if img:
            res += run_local([{"module": "ugc", "model": "wan-2.2-s2v-14b", "prompt": "a person talking to the camera, studio light", "seconds": 2,
                               "script": "Hi, this is a short test.", "reference": img}], os.path.join(out_dir, "s2v"))
    ok = all(r["status"] == "ok" for r in res)
    log("SELFTEST", "PASS" if ok else "FAIL", json.dumps(res))
    return ok


# ------------------------------------------------------------------------------------------------------------------- main
def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--profile", default="t4", choices=["t4", "24gb", "48gb"])
    ap.add_argument("--root", default=os.environ.get("FZ_ROOT") or "/tmp/fz")
    ap.add_argument("--comfy-ref", default=os.environ.get("FZ_COMFY_REF") or "master")
    ap.add_argument("--tunnel", default="cloudflared", choices=["cloudflared", "runpod", "none"])
    ap.add_argument("--bind", default="127.0.0.1", help="0.0.0.0 on RunPod / Vast (their proxy reaches the port)")
    ap.add_argument("--idle-minutes", type=float, default=float(os.environ.get("FZ_IDLE_MINUTES") or 30))
    ap.add_argument("--max-hours", type=float, default=float(os.environ.get("FZ_MAX_HOURS") or 6))
    ap.add_argument("--batch", help="a JSON list of jobs to run locally (no tunnel)")
    ap.add_argument("--selftest", action="store_true")
    ap.add_argument("--out", default="/tmp/fz/out")
    a = ap.parse_args()
    os.makedirs(a.root, exist_ok=True)
    comfy, commit = install(a.root, a.comfy_ref, a.profile)
    procs = [start_comfy(comfy)]
    if a.batch or a.selftest:
        if a.selftest:
            ok = selftest(a.profile, a.out)
        else:
            with open(a.batch) as f:
                ok = all(r["status"] == "ok" for r in run_local(json.load(f), a.out))
        procs[0].terminate()
        log("outputs and their .json metadata (ai_generated: true) are in", a.out)
        return 0 if ok else 1
    token = os.environ.get("FZ_WORKER_TOKEN") or ""
    from_secret = len(token) >= 24
    token = token if from_secret else secrets.token_urlsafe(32)
    bind = "0.0.0.0" if a.tunnel == "runpod" else a.bind
    threading.Thread(target=run_proxy, args=(token, bind), daemon=True).start()
    url = public_url(a.tunnel, a.root)
    threading.Thread(target=watchdog, args=(a.idle_minutes, a.max_hours, procs), daemon=True).start()
    print("\n================ FENDEZY WORKER READY ================", flush=True)
    print(f"COMFYUI_SELFHOST_URL={url or f'http://{bind}:{PROXY_PORT} (no tunnel)'}")
    print("COMFYUI_SELFHOST_TOKEN=" + ("(your FZ_WORKER_TOKEN secret: unchanged)" if from_secret else token))
    print(f"Paste these into Railway > Variables. Stops after {a.idle_minutes:g} idle minutes or {a.max_hours:g} hours. ComfyUI {commit[:12]}.")
    print("=======================================================\n", flush=True)
    procs[0].wait()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
