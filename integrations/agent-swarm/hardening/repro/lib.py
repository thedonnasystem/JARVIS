"""Shared helpers for the local throwaway-server repros. Loopback only, no proxies, throwaway keys."""
import json, os, random, subprocess, sys, time, shutil, tempfile, urllib.request, urllib.error, secrets

SW = "/home/claude/sandbox/swarm"
NOPROXY = urllib.request.build_opener(urllib.request.ProxyHandler({}))

def call(base, m, path, tok=None, body=None, hdr=None, raw=False):
    h = {"Content-Type": "application/json"}
    if tok: h["Authorization"] = f"Bearer {tok}"
    h.update(hdr or {})
    r = urllib.request.Request(base + path, method=m, headers=h,
                               data=json.dumps(body).encode() if body is not None else None)
    try:
        with NOPROXY.open(r, timeout=20) as x: s, t = x.status, x.read().decode()
    except urllib.error.HTTPError as e: s, t = e.code, e.read().decode()
    except Exception as e: return -1, str(e)
    if raw: return s, t
    try: return s, json.loads(t)
    except Exception: return s, t

class Server:
    """Throwaway bun src/http.ts: random high port, clean env, telemetry off, temp dir deleted on exit."""
    def __init__(self, port=None, extra_env=None):
        self.extra_env = extra_env or {}
        self.port = port or random.randint(41000, 58000)
        self.key = "throwaway-op-" + secrets.token_hex(8)
        self.dir = tempfile.mkdtemp(prefix="swarm_repro_")
        self.proc = None
    def __enter__(self):
        os.makedirs(self.dir + "/home"); os.makedirs(self.dir + "/data")
        env = {"PATH": os.environ["PATH"], "HOME": self.dir + "/home", "PORT": str(self.port), "API_KEY": self.key,
               "DATABASE_PATH": self.dir + "/data/db.sqlite", "ANONYMIZED_TELEMETRY": "false",
               "HEARTBEAT_DISABLE": "true", "IMPROVEMENTS_ENABLED": "false", "SLACK_DISABLE": "true",
               "MEMORY_RATERS": "", "OAUTH_KEEPALIVE_DISABLE": "true", "OAUTH_REFRESH_SWEEP_DISABLE": "true",
               "CAPABILITIES": os.environ.get("REPRO_CAPS", "core,task-pool,config,mcp,profiles,memory,metrics,kv")}
        env.update(self.extra_env)
        self.log = open(self.dir + "/server.log", "w")
        self.proc = subprocess.Popen(["bun", "src/http.ts"], cwd=SW, env=env, stdout=self.log, stderr=subprocess.STDOUT)
        self.base = f"http://127.0.0.1:{self.port}"
        for _ in range(80):
            if call(self.base, "GET", "/health")[0] == 200: return self
            time.sleep(0.5)
        raise RuntimeError("server did not start: " + open(self.dir + "/server.log").read()[-500:])
    def __exit__(self, *a):
        if self.proc:
            self.proc.terminate()
            try: self.proc.wait(10)
            except Exception: self.proc.kill()
        self.log.close()
        shutil.rmtree(self.dir, ignore_errors=True)
        self.deleted = not os.path.exists(self.dir)
        print(f"[cleanup] server stopped, tempdir removed={self.deleted}")
