#!/usr/bin/env python3
"""verify_swarm_controls.py: fail-closed verifier for the Fendezy Agent Swarm pilot stack.

Static layer  : parses the compose file (+ config/squid.conf, config/worker_gate.py, worker/Dockerfile.worker-hardened,
                worker/entrypoint-hardened.sh) and FAILS unless every required control is present (C01-C21).
Runtime layer : if a Docker daemon is reachable, inspects the running containers and checks the same controls
                as actually applied (HostConfig). With no daemon it reports NOT VERIFIED (never PASS).

Exit codes: 0 = all static controls present (and runtime verified if --require-runtime), 1 = a control failed,
            2 = usage/parse error. Needs PyYAML (only third-party import). Touches no network, reads no secrets.

    python3 verify_swarm_controls.py docker-compose.hardened.yml [--strict] [--require-runtime]
        [--model-host api.anthropic.com] [--entrypoint-exception] [--json]
"""
from __future__ import annotations

import argparse
import json
import os
import re
import shutil
import subprocess
import sys

try:
    import yaml
except ImportError:  # pragma: no cover
    sys.stderr.write("PyYAML is required: pip install pyyaml\n")
    sys.exit(2)

BLOCKED_HOSTS = ["models.dev", "proxy.desplega.sh", "templates.agent-swarm.dev", "app.agent-swarm.dev"]
LIMIT_KEYS = ("mem_limit", "cpus", "pids_limit")
SECRET_NAME = re.compile(r"(KEY|TOKEN|SECRET|PASSWORD|CREDENTIAL)", re.I)
MODEL_KEYS = ("ANTHROPIC_API_KEY", "CLAUDE_CODE_OAUTH_TOKEN", "OPENAI_API_KEY", "OPENROUTER_API_KEY")
ENTRYPOINT_EXCEPTION_CAPS = {"CHOWN", "DAC_OVERRIDE", "FOWNER", "SETUID", "SETGID"}
PLACEHOLDER_DIGEST = re.compile(r"@sha256:(0{64}|[0-9a-f]{0,6}x*|REPLACE.*)$", re.I)


# ----------------------------------------------------------------------------- helpers
def interpolate(s):
    """Resolve compose ${VAR:-d} / ${VAR-d} to d, ${VAR:?m} / ${VAR} to a <VAR> marker. Non-strings pass through."""
    if not isinstance(s, str):
        return s

    def sub(m):
        name, op, arg = m.group(1), m.group(2), m.group(3)
        if op in (":-", "-"):
            return arg
        return f"<{name}>"

    return re.sub(r"\$\{([A-Za-z_][A-Za-z0-9_]*)(?:(:-|-|:\?|\?)([^}]*))?\}", sub, s)


def env_map(svc):
    e = svc.get("environment") or {}
    out = {}
    if isinstance(e, dict):
        for k, v in e.items():
            out[str(k)] = "" if v is None else str(v)
    else:
        for item in e:
            k, _, v = str(item).partition("=")
            out[k] = v
    return out


def truthy(v):
    return str(v).strip().lower() in ("true", "1", "yes")


def falsy(v):
    return str(v).strip().lower() in ("false", "0", "no")


def env_files(svc):
    ef = svc.get("env_file") or []
    if isinstance(ef, (str, dict)):
        ef = [ef]
    out = []
    for item in ef:
        out.append(item.get("path") if isinstance(item, dict) else item)
    return [str(x) for x in out if x]


def published(svc):
    res = []
    for p in svc.get("ports") or []:
        if isinstance(p, dict):
            res.append((interpolate(str(p.get("host_ip", ""))), str(p.get("published", "")), str(p.get("target", ""))))
        else:
            parts = interpolate(str(p)).split(":")
            if len(parts) == 3:
                res.append((parts[0], parts[1], parts[2]))
            elif len(parts) == 2:
                res.append(("", parts[0], parts[1]))
            else:
                res.append(("", "", parts[0]))
    return res


def volume_specs(svc):
    out = []
    for v in svc.get("volumes") or []:
        if isinstance(v, dict):
            out.append({"type": v.get("type", "volume"), "source": str(v.get("source", "")), "target": str(v.get("target", ""))})
        else:
            parts = str(v).split(":")
            src = parts[0]
            kind = "bind" if (src.startswith(("/", ".", "~")) or "${" in src and "/" in src) else "volume"
            out.append({"type": kind, "source": src, "target": parts[1] if len(parts) > 1 else ""})
    return out


class Report:
    def __init__(self):
        self.rows = []

    def add(self, cid, status, title, detail=""):
        self.rows.append({"id": cid, "status": status, "title": title, "detail": detail})

    def ok(self, cid, title, detail=""):
        self.add(cid, "PASS", title, detail)

    def fail(self, cid, title, detail):
        self.add(cid, "FAIL", title, detail)

    def warn(self, cid, title, detail):
        self.add(cid, "WARN", title, detail)

    def check(self, cid, title, problems, ok_detail=""):
        if problems:
            self.fail(cid, title, "; ".join(problems))
        else:
            self.ok(cid, title, ok_detail)

    @property
    def failed(self):
        return any(r["status"] == "FAIL" for r in self.rows)


# ----------------------------------------------------------------------------- static layer
def parse_squid(path):
    """Return (allowed_domains, ends_with_deny_all, text). allowed = dstdomain values of acls used by an `allow` rule."""
    if not path or not os.path.isfile(path):
        return None
    with open(path) as fh:
        text = fh.read()
    acls = {}
    for line in text.splitlines():
        t = line.split("#")[0].strip().split()
        if len(t) >= 4 and t[0] == "acl" and t[2] == "dstdomain":
            acls.setdefault(t[1], []).extend(t[3:])
    allowed, last_access = [], None
    for line in text.splitlines():
        t = line.split("#")[0].strip().split()
        if len(t) >= 3 and t[0] == "http_access":
            last_access = " ".join(t[1:])
            if t[1] == "allow":
                for name in t[2:]:
                    allowed.extend(acls.get(name.lstrip("!"), []))
    return sorted(set(allowed)), (last_access == "deny all"), text


def static_checks(compose, base_dir, model_host, strict, entry_exc, rep):
    services = compose.get("services") or {}
    nets = compose.get("networks") or {}
    internal = {n for n, d in nets.items() if isinstance(d, dict) and truthy(d.get("internal", False))}
    if not services:
        rep.fail("S00", "compose has services", "no services parsed")
        return
    api = services.get("api") or {}
    workers = {n: s for n, s in services.items() if re.fullmatch(r"worker(-\d+)?", n)}
    worker = next(iter(workers.values()), {})
    proxy_name = next((n for n in services if "proxy" in n and "ingress" not in n), None)
    proxy = services.get(proxy_name or "", {})

    # C01 image pinning
    probs, warns = [], []
    for n, s in services.items():
        img = interpolate(str(s.get("image", "")))
        if n in workers and re.fullmatch(r"sha256:[0-9a-f]{64}", img):
            if re.fullmatch(r"sha256:0{64}", img):
                warns.append(n)          # placeholder image id of the locally built derived image
            continue
        if not img:
            probs.append(f"{n}: no image")
        elif img.endswith(":latest") or ":" not in img.split("/")[-1].split("@")[0] and "@sha256:" not in img:
            probs.append(f"{n}: unpinned/latest ({img})")
        elif "@sha256:" not in img:
            probs.append(f"{n}: tag without digest ({img})")
        elif PLACEHOLDER_DIGEST.search(img):
            warns.append(n)
        if ":latest" in img:
            probs.append(f"{n}: contains :latest")
    if strict and warns:
        probs.append("placeholder digest still present in " + ",".join(warns) + " (--strict)")
    rep.check("C01", "images pinned by digest, never :latest", sorted(set(probs)))
    if warns and not strict:
        rep.warn("C01w", "digests are PLACEHOLDERS", "replace in " + ",".join(warns) + " before any real run (--strict fails on this)")

    # C02 pull policy
    probs = [f"{n}: pull_policy={s.get('pull_policy')!r}" for n, s in services.items() if s.get("pull_policy") not in ("never", "if_not_present", "missing")]
    rep.check("C02", "pull_policy never/if_not_present (no always, no default)", probs)

    # C03 read-only root + tmpfs
    probs = []
    for n, s in services.items():
        if not truthy(s.get("read_only", False)):
            probs.append(f"{n}: read_only not true")
        if not s.get("tmpfs"):
            probs.append(f"{n}: no tmpfs")
    rep.check("C03", "read_only root fs + tmpfs", probs)

    # C04 caps
    probs = []
    for n, s in services.items():
        cd = [str(c).upper() for c in (s.get("cap_drop") or [])]
        if "ALL" not in cd:
            probs.append(f"{n}: cap_drop lacks ALL")
        add = {str(c).upper() for c in (s.get("cap_add") or [])}
        if add and not (entry_exc and n in workers and add <= ENTRYPOINT_EXCEPTION_CAPS):
            probs.append(f"{n}: cap_add {sorted(add)}")
    rep.check("C04", "cap_drop ALL, no cap_add", probs)

    # C05 no-new-privileges, no unconfined
    probs = []
    for n, s in services.items():
        so = [str(x).replace("=", ":").lower() for x in (s.get("security_opt") or [])]
        if "no-new-privileges:true" not in so:
            probs.append(f"{n}: no-new-privileges missing")
        if any("unconfined" in x for x in so):
            probs.append(f"{n}: unconfined profile")
    rep.check("C05", "no-new-privileges, no unconfined seccomp/apparmor", probs)

    # C06 non-root
    probs = []
    for n, s in services.items():
        u = interpolate(str(s.get("user", ""))).strip()
        uid = u.split(":")[0]
        if not u or uid in ("0", "root"):
            if not (entry_exc and n in workers):
                probs.append(f"{n}: user={u!r} (root or unset)")
        elif not uid.isdigit() and not uid.startswith("<"):
            probs.append(f"{n}: user={u!r} is not numeric (a name can resolve to root or differ between image and host)")
    rep.check("C06", "non-root user on every service", probs)

    # C07 privileged / host namespaces / devices
    probs = []
    for n, s in services.items():
        if truthy(s.get("privileged", False)):
            probs.append(f"{n}: privileged")
        for k in ("pid", "ipc", "uts", "userns_mode", "cgroup", "network_mode"):
            if str(s.get(k, "")).lower() == "host" or (k == "network_mode" and s.get(k)):
                probs.append(f"{n}: {k}={s.get(k)}")
        if s.get("devices"):
            probs.append(f"{n}: devices")
    rep.check("C07", "not privileged, no host namespaces/devices/network_mode", probs)

    # C08 limits
    probs = []
    for n, s in services.items():
        lim = (s.get("deploy") or {}).get("resources", {}).get("limits", {})
        have = {k: s.get(k) for k in LIMIT_KEYS if s.get(k) not in (None, "", 0, "0")}
        if "mem_limit" not in have and lim.get("memory"):
            have["mem_limit"] = lim["memory"]
        if "cpus" not in have and lim.get("cpus"):
            have["cpus"] = lim["cpus"]
        if "pids_limit" not in have and lim.get("pids"):
            have["pids_limit"] = lim["pids"]
        miss = [k for k in LIMIT_KEYS if k not in have]
        if miss:
            probs.append(f"{n}: missing {miss}")
    rep.check("C08", "memory + cpu + pids limits on every service", probs)

    # C09 mounts
    probs, named = [], {}
    for n, s in services.items():
        for v in volume_specs(s):
            blob = (v["source"] + v["target"]).lower()
            if "docker.sock" in blob or "/var/run/docker" in blob:
                probs.append(f"{n}: docker socket mount ({v['source']})")
            elif v["type"] == "bind":
                probs.append(f"{n}: host bind mount {v['source']}")
            else:
                named.setdefault(v["source"], []).append(n)
    if len(named) > 1:
        probs.append(f"more than one volume: {sorted(named)}")
    for vol, users in named.items():
        if users != list(workers)[:1] and not set(users) <= set(workers):
            probs.append(f"volume {vol} mounted by non-worker {users}")
    rep.check("C09", "no docker.sock, no host mounts, <= 1 scratch volume (worker only)", probs,
              "scratch volume: " + (",".join(named) or "none"))

    # C10 ports
    probs = []
    for n, s in services.items():
        for host_ip, pub, tgt in published(s):
            if n in workers:
                probs.append(f"{n}: publishes port {pub or tgt}")
            elif host_ip not in ("127.0.0.1", "::1", "[::1]"):
                probs.append(f"{n}: port {pub or tgt} bound to {host_ip or '0.0.0.0 (implicit)'}")
    rep.check("C10", "published ports bound to loopback only; none on worker", probs)

    # C11 telemetry
    probs = []
    for n, s in services.items():
        if n in ("api",) or n in workers:
            v = env_map(s).get("ANONYMIZED_TELEMETRY")
            if v is None or not falsy(interpolate(v)):
                probs.append(f"{n}: ANONYMIZED_TELEMETRY={v!r}")
    rep.check("C11", "ANONYMIZED_TELEMETRY=false on api and worker", probs)

    # C12 worker count, no lead, key separation
    probs = []
    if len(workers) != 1:
        probs.append(f"expected exactly one worker service, found {len(workers)}")
    for n, s in services.items():
        e = env_map(s)
        if e.get("AGENT_ROLE", "").lower() == "lead" or "lead" in e.get("TEMPLATE_ID", "").lower() or n == "lead":
            probs.append(f"{n}: is a lead")
    api_ef, w_ef = set(env_files(api)), set(env_files(worker))
    if not api_ef or not w_ef:
        probs.append("api and worker must each have their own env_file")
    elif api_ef & w_ef:
        probs.append(f"api and worker share env_file {sorted(api_ef & w_ef)} (shared admin key)")
    ae, we = env_map(api), env_map(worker)
    if "API_KEY" in we and "API_KEY" in ae and we["API_KEY"] == ae["API_KEY"]:
        probs.append("worker inline API_KEY identical to api API_KEY (shared admin key)")
    rep.check("C12", "one worker, no lead, per-worker key separate from operator key", probs)

    # C13 networks
    probs = []
    egress_services = []
    for n, s in services.items():
        nl = s.get("networks") or []
        names = list(nl) if isinstance(nl, (list, dict)) else []
        if not names:
            probs.append(f"{n}: no explicit networks (default bridge has egress)")
        ext = [x for x in names if x not in internal]
        if ext:
            egress_services.append((n, ext))
    for n, ext in egress_services:
        if n in ("api",) or n in workers:
            probs.append(f"{n}: attached to non-internal network {ext}")
    if len([n for n, _ in egress_services if "proxy" in n and "ingress" not in n]) != 1:
        probs.append("expected exactly one egress-proxy service on a non-internal network")
    rep.check("C13", "api and worker only on internal:true networks", probs)

    # C14 egress allow-list
    probs = []
    squid_path = None
    for c in (compose.get("configs") or {}).values():
        f = c.get("file") if isinstance(c, dict) else None
        if f and "squid" in str(f):
            squid_path = os.path.normpath(os.path.join(base_dir, str(f)))
    parsed = parse_squid(squid_path)
    if parsed is None:
        probs.append("squid config not found (egress allow-list undefined)")
    else:
        allowed, deny_last, _ = parsed
        if allowed != [model_host]:
            probs.append(f"allow-list is {allowed}, must be exactly [{model_host!r}]")
        if not deny_last:
            probs.append("squid config does not end with `http_access deny all`")
        for b in BLOCKED_HOSTS:
            if any(b in a for a in allowed):
                probs.append(f"blocked host {b} is allowed")
    wenv = we
    hp = interpolate(wenv.get("HTTPS_PROXY", ""))
    if not proxy_name or proxy_name not in hp:
        probs.append(f"worker HTTPS_PROXY={hp!r} does not point at the proxy service")
    for b in BLOCKED_HOSTS:
        if b in wenv.get("NO_PROXY", ""):
            probs.append(f"NO_PROXY bypasses proxy for {b}")
    rep.check("C14", f"egress allow-list = only {model_host}; blocked hosts denied", probs)

    # C15 template registry / vendor channels
    probs = []
    if we.get("TEMPLATE_ID", "") not in ("",):
        probs.append(f"worker TEMPLATE_ID={we.get('TEMPLATE_ID')!r} (registry fetch)")
    if "templates.agent-swarm.dev" in we.get("TEMPLATE_REGISTRY_URL", ""):
        probs.append("TEMPLATE_REGISTRY_URL points at templates.agent-swarm.dev")
    for n in ["api"] + list(workers):
        e = env_map(services.get(n, {}))
        if not falsy(e.get("IMPROVEMENTS_ENABLED", "")):
            probs.append(f"{n}: IMPROVEMENTS_ENABLED not false")
        for k in ("BUSINESS_USE_API_KEY", "BUSINESS_USE_URL"):
            if e.get(k, "x") != "":
                probs.append(f"{n}: {k} not explicitly empty")
    for k in ("DISABLE_TELEMETRY", "DISABLE_ERROR_REPORTING", "CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC", "DISABLE_AUTOUPDATER"):
        if not truthy(we.get(k, "")):
            probs.append(f"worker: {k} not set")
    rep.check("C15", "vendor/phone-home channels off (templates, improvements, business-use, CLI telemetry)", probs)

    # C16 auto lead-review and autonomous task sources disabled
    probs = []
    ae_caps = {c.strip() for c in ae.get("CAPABILITIES", "").split(",") if c.strip()}
    if not ae_caps:
        probs.append("api CAPABILITIES unset (defaults include scheduling, workflows, slack, tracker, scripts)")
    for bad in ("scheduling", "workflows", "slack", "tracker", "scripts", "pages", "skills", "repo", "agentmail", "kapso", "chat-sdk", "messaging"):
        if bad in ae_caps:
            probs.append(f"api CAPABILITIES includes {bad}")
    if not truthy(ae.get("HEARTBEAT_DISABLE", "")):
        probs.append("api HEARTBEAT_DISABLE not true")
    if ae.get("MEMORY_RATERS", "x") != "" or we.get("MEMORY_RATERS", "x") != "":
        probs.append("MEMORY_RATERS not explicitly empty on api and worker")
    rep.check("C16", "no lead (no auto review task), no schedules/heartbeat/integrations", probs)

    # C17 secrets handling
    probs = []
    for n, s in services.items():
        for ef in env_files(s):
            r = interpolate(ef)
            if not (r.startswith("/") or r.startswith("<")):
                probs.append(f"{n}: env_file {ef!r} is relative (inside repo)")
            elif r.startswith("/") and os.path.commonpath([os.path.abspath(r), os.path.abspath(base_dir)]) == os.path.abspath(base_dir):
                probs.append(f"{n}: env_file {ef!r} is inside the repo dir")
        for k, v in env_map(s).items():
            if SECRET_NAME.search(k) and v.strip() and not v.strip().startswith("${"):
                probs.append(f"{n}: inline secret-looking value for {k}")
    for k in MODEL_KEYS:
        if k in ae:
            probs.append(f"api holds model credential {k}")
    for k in ("GITHUB_TOKEN", "SLACK_BOT_TOKEN", "AWS_ACCESS_KEY_ID"):
        if k in we or k in ae:
            probs.append(f"{k} present in env")
    rep.check("C17", "secrets via env_file outside repo, none inline, no model key on api", probs)
    gate_checks(compose, services, workers, worker, api, base_dir, entry_exc, rep)


# ---- worker gate / topology / non-root image (C18-C21) ----
GATE_PROBE = r"""
import importlib.util, json, sys
spec = importlib.util.spec_from_file_location("wg", sys.argv[1]); m = importlib.util.module_from_spec(spec); sys.modules["wg"] = m; spec.loader.exec_module(m)
A = sys.argv[2]; U = "00000000-0000-0000-0000-000000000000"
H = {"authorization": "Bearer aseph_" + "x" * 40, "x-agent-id": A}
def rpc(method, params=None):
    return json.dumps({"jsonrpc": "2.0", "id": 1, "method": method, "params": params or {}}).encode()
def dec(method, path, body=None, headers=None):
    return m.decide(method, path, {**H, **(headers or {})}, body, A)
deny = [("GET", "/api/config?scope=global&includeSecrets=true"), ("PUT", "/api/config"), ("POST", "/api/config/reload"), ("POST", "/internal/reload-config"),
        ("POST", "/api/tasks"), ("POST", f"/api/tasks/{U}/supersede"), ("POST", f"/api/agents/{A}/token"), ("DELETE", f"/api/agents/{A}/token"),
        ("POST", f"/api/agents/{A}/token/rotate"), ("PUT", "/api/budgets/global/_"), ("POST", "/api/schedules"), ("POST", "/api/scripts/run"),
        ("POST", "/api/scripts/upsert"), ("POST", "/api/skills"), ("POST", "/api/db-query"), ("GET", "/api/agents"), ("GET", "/api/users"),
        ("GET", "/api/tasks"), ("PUT", "/api/kv/x"), ("POST", "/api/internal/raw-llm"), ("GET", "/api/config/resolved?agentId=other-agent"),
        ("POST", "/api/tasks/../tasks"), ("POST", "/api//tasks"), ("POST", "/api/%74asks"),
        ("PUT", "/api/active-sessions/heartbeat/.."), ("POST", "/api/sessions/./close"), ("PUT", "/api/active-sessions/heartbeat/%2e%2e")]
allow = [("GET", "/api/poll"), ("POST", "/ping"), ("POST", "/close"), ("GET", f"/api/tasks/{U}"), ("POST", f"/api/tasks/{U}/progress"),
         ("POST", f"/api/tasks/{U}/finish"), ("POST", "/api/agents"), ("GET", "/api/config/resolved?agentId=" + A), ("POST", "/mcp")]
out = {"deny_but_allowed": [f"{a} {b}" for a, b in deny if dec(a, b, b"{}").allow],
       "allow_but_denied": [f"{a} {b}" for a, b in allow if not dec(a, b, rpc("initialize") if b == "/mcp" else (b'{"name":"w"}' if b == "/api/agents" else b"{}")).allow]}
q = dec("GET", "/api/config/resolved?agentId=" + A + "&includeSecrets=true")
out["secrets_not_forced_false"] = (not q.allow) or ("includeSecrets=false" not in q.query)
for tool, args in (("send-task", {"task": "x"}), ("db-query", {"sql": "select 1"}), ("set-config", {}), ("get-config", {"includeSecrets": True}),
                   ("task-action", {"action": "create", "task": "x"}), ("skill-publish", {})):
    if dec("POST", "/mcp", rpc("tools/call", {"name": tool, "arguments": args})).allow:
        out["deny_but_allowed"].append("mcp " + tool + " " + json.dumps(args))
if dec("POST", "/mcp", json.dumps([{"jsonrpc": "2.0", "id": 1, "method": "tools/call", "params": {"name": "send-task"}}]).encode()).allow:
    out["deny_but_allowed"].append("mcp batch")
if m.decide("GET", "/api/poll", {"authorization": "Bearer operator-key-123456789"}, None, A).allow:
    out["deny_but_allowed"].append("operator-style bearer")
if dec("POST", "/api/agents", json.dumps({"name": "x", "isLead": True}).encode()).allow:
    out["deny_but_allowed"].append("register as lead")
print(json.dumps(out))
"""

ENTRYPOINT_FORBIDDEN = [r"\bgosu\b", r"\bsudo\b", r"\bsu\s+-?\w", r"\bchown\b", r"\bchgrp\b", r"\buseradd\b", r"\busermod\b", r"\badduser\b",
                        r"\bsetcap\b", r"chmod\s+[ugoa]*\+s", r"\bapt(-get)?\b", r"/etc/gitconfig", r"git\s+config\s+--system",
                        r"/api/config", r"setup-script", r"swarm_config", r"\bcurl\s"]


def _nets(svc):
    n = svc.get("networks") or []
    return set(n.keys()) if isinstance(n, dict) else set(n)


def gate_checks(compose, services, workers, worker, api, base_dir, entry_exc, rep):
    gate = services.get("worker-gate")
    wn, an = _nets(worker), _nets(api)
    we = env_map(worker)

    # C18 topology: the worker cannot reach the API except through worker-gate
    probs = []
    if not gate:
        probs.append("no worker-gate service")
    if wn & an:
        probs.append(f"worker and api share network(s) {sorted(wn & an)}: the worker could bypass the gate")
    both = sorted(n for n, s in services.items() if n not in workers and n != "api" and (_nets(s) & wn) and (_nets(s) & an))
    if both != ["worker-gate"]:
        probs.append(f"services attached to both the worker side and the api side: {both} (must be exactly ['worker-gate'])")
    mcp = interpolate(we.get("MCP_BASE_URL", ""))
    gate_port = None
    if gate:
        gl = interpolate(env_map(gate).get("GATE_LISTEN", ""))
        gate_port = gl.rsplit(":", 1)[-1] if ":" in gl else None
    if not re.fullmatch(r"http://worker-gate:\d+", mcp) or (gate_port and not mcp.endswith(":" + gate_port)):
        probs.append(f"worker MCP_BASE_URL={mcp!r} must be http://worker-gate:<gate port {gate_port}>")
    for k, v in we.items():
        if re.search(r"(^|[/@])api(:\d+|/|$)", interpolate(v)) and k != "NO_PROXY":
            probs.append(f"worker env {k} points at the api service directly")
    if re.search(r"(^|,)api(,|$)", we.get("NO_PROXY", "")):
        probs.append("worker NO_PROXY lists api")
    for n, s in services.items():
        if n == "api-ingress" and (_nets(s) & wn):
            probs.append("api-ingress (operator door) is reachable from the worker network")
        if n.startswith("egress-proxy") and (_nets(s) & an):
            probs.append("egress-proxy is on the api network")
        if n == "worker-gate" and s.get("ports"):
            probs.append("worker-gate publishes ports")
    rep.check("C18", "worker reaches the API only through worker-gate (disjoint networks, gate URL)", probs)

    # C19 gate service + policy behaviour (executes the referenced gate file in an isolated subprocess)
    probs = []
    if gate:
        ge = env_map(gate)
        if interpolate(ge.get("GATE_AGENT_ID", "")) != interpolate(we.get("AGENT_ID", "x")):
            probs.append(f"GATE_AGENT_ID={ge.get('GATE_AGENT_ID')!r} != worker AGENT_ID={we.get('AGENT_ID')!r}")
        if not re.fullmatch(r"api:\d+", interpolate(ge.get("GATE_UPSTREAM", ""))):
            probs.append(f"GATE_UPSTREAM={ge.get('GATE_UPSTREAM')!r} must be api:<port>")
        if "worker_gate.py" not in json.dumps(gate.get("command", "")):
            probs.append("worker-gate command does not run worker_gate.py")
        cfgs = compose.get("configs") or {}
        gate_file = None
        for c in gate.get("configs") or []:
            src = c.get("source") if isinstance(c, dict) else c
            f = (cfgs.get(src) or {}).get("file")
            if f and str(f).endswith("worker_gate.py"):
                gate_file = os.path.normpath(os.path.join(base_dir, str(f)))
        if not gate_file or not os.path.isfile(gate_file):
            probs.append("worker_gate.py not mounted from an existing file")
        else:
            try:
                r = subprocess.run([sys.executable, "-I", "-c", GATE_PROBE, gate_file, interpolate(we.get("AGENT_ID", "pilot-worker-1"))],
                                   capture_output=True, text=True, timeout=30)
                res = json.loads(r.stdout.strip().splitlines()[-1]) if r.returncode == 0 and r.stdout.strip() else {"error": (r.stderr or "no output")[-200:]}
            except Exception as e:  # pragma: no cover
                res = {"error": str(e)}
            if "error" in res:
                probs.append("gate policy probe failed: " + str(res["error"]))
            else:
                if res["deny_but_allowed"]:
                    probs.append("gate ALLOWS: " + "; ".join(res["deny_but_allowed"][:6]))
                if res["allow_but_denied"]:
                    probs.append("gate DENIES required worker calls: " + "; ".join(res["allow_but_denied"][:6]))
                if res["secrets_not_forced_false"]:
                    probs.append("gate does not force includeSecrets=false on /api/config/resolved")
    rep.check("C19", "worker-gate policy: default deny, no task create/config/token/secrets, worker flow allowed", probs,
              "behaviour probed: 27 deny cases, 9 allow cases, MCP tool/batch/secrets rewrites")

    # C20 non-root worker image/entrypoint (no gosu, no chown, numeric uid consistent everywhere)
    if entry_exc:
        rep.warn("C20", "non-root worker image NOT checked", "--entrypoint-exception: stock root entrypoint accepted by owner")
    else:
        rep.check("C20", "worker needs no root at runtime: derived image, numeric uid, no gosu/chown, pre-owned tmpfs",
                  _c20(worker, base_dir))

    # C21 secrets are env-only: nothing in compose seeds swarm config rows; example files are separated
    probs = []
    for n in ["api"] + list(workers):
        for k in env_map(services.get(n, {})):
            if k.startswith("CONFIG_") or k in ("SWARM_CONFIG_SEED", "GLOBAL_CONFIG_JSON"):
                probs.append(f"{n}: {k} seeds swarm config")
    wx, ax = os.path.join(base_dir, "secrets.example", "worker.env.example"), os.path.join(base_dir, "secrets.example", "api.env.example")
    if os.path.isfile(wx):
        wcode = "\n".join(l for l in open(wx).read().splitlines() if not l.startswith("#"))
        if "ANTHROPIC_API_KEY" not in wcode:
            probs.append("worker.env.example lacks an ANTHROPIC_API_KEY placeholder (the model key belongs in worker env only)")
        if "SECRETS_ENCRYPTION_KEY" in wcode:
            probs.append("worker.env.example carries the API encryption key")
    if os.path.isfile(ax) and "ANTHROPIC_API_KEY" in "\n".join(l for l in open(ax).read().splitlines() if not l.startswith("#")):
        probs.append("api.env.example carries a model key")
    rep.check("C21", "env-only secrets: model key only in worker env, nothing seeds swarm config", probs,
              "by hand: operator `GET /api/config?includeSecrets=true` must show zero isSecret rows (gate doc 2.1)")


def _c20(worker, base_dir):
    probs = []
    wdir = os.path.join(base_dir, "worker")
    df, ep = os.path.join(wdir, "Dockerfile.worker-hardened"), os.path.join(wdir, "entrypoint-hardened.sh")
    usr = interpolate(str(worker.get("user", ""))).strip()
    uid, _, gid = usr.partition(":")
    img = interpolate(str(worker.get("image", "")))
    if "agent-swarm-worker" in img:
        probs.append(f"worker uses the stock image {img!r} (root entrypoint); use the derived image")
    if worker.get("entrypoint") or worker.get("command"):
        probs.append("worker overrides entrypoint/command (must use the image's hardened entrypoint)")
    if not uid.isdigit():
        probs.append("worker user is not numeric")
    tm = [interpolate(str(t)) for t in worker.get("tmpfs") or []]
    for t in tm:
        if t.split(":")[0] in ("/home/worker", "/logs"):
            opts = dict(o.split("=", 1) for o in t.split(":", 1)[1].split(",") if "=" in o) if ":" in t else {}
            if opts.get("uid") != uid or opts.get("gid") != gid:
                probs.append(f"tmpfs {t.split(':')[0]} is not owned by the runtime uid:gid ({uid}:{gid}); a non-root process could not write it")
    if not any(t.split(":")[0] == "/home/worker" for t in tm):
        probs.append("no /home/worker tmpfs (HOME must be writable on a read-only rootfs)")
    if not (os.path.isfile(df) and os.path.isfile(ep)):
        probs.append("worker/Dockerfile.worker-hardened or worker/entrypoint-hardened.sh missing")
        return probs
    dtxt, etxt = open(df).read(), open(ep).read()
    lines = [l.strip() for l in dtxt.splitlines() if l.strip() and not l.strip().startswith("#")]
    users = [l.split(None, 1)[1] for l in lines if l.upper().startswith("USER ")]
    if not users or not re.fullmatch(r"\d+(:\d+)?", users[-1]) or users[-1].split(":")[0] == "0":
        probs.append(f"Dockerfile final USER is {users[-1] if users else 'unset'!r} (must be numeric non-root)")
    elif uid.isdigit() and users[-1].split(":")[0] != uid:
        probs.append(f"Dockerfile USER {users[-1]} != compose user {uid}")
    if not any(l.upper().startswith("FROM ") and "${BASE_IMAGE}" in l for l in lines) or not re.search(r"ARG BASE_IMAGE=\S+@sha256:[0-9a-f]{64}", dtxt):
        probs.append("Dockerfile base is not an ARG BASE_IMAGE pinned by sha256 digest")
    if not any(l.upper().startswith("ENTRYPOINT") and "entrypoint-hardened.sh" in l for l in lines):
        probs.append("Dockerfile ENTRYPOINT is not entrypoint-hardened.sh")
    if "worker-home-seed" not in dtxt:
        probs.append("Dockerfile does not create the HOME seed (a tmpfs HOME would hide the hook settings)")
    if any(re.search(r"\bgosu\b", l) for l in lines if l.upper().startswith(("CMD", "ENTRYPOINT"))):
        probs.append("Dockerfile CMD/ENTRYPOINT uses gosu")
    if uid.isdigit() and f'test "$(id -u worker)" = "{uid}"' not in dtxt:
        probs.append("Dockerfile does not assert the worker uid at build time")
    code = "\n".join(l for l in etxt.splitlines() if not l.strip().startswith("#"))
    for pat in ENTRYPOINT_FORBIDDEN:
        m = re.search(pat, code)
        if m:
            probs.append(f"entrypoint contains forbidden construct {m.group(0).strip()!r}")
    if not re.search(r'id -u\)" -ne 0', etxt):
        probs.append("entrypoint does not refuse to run as root")
    if not re.search(r"aseph_\*\)\s*;;", code) or not re.search(r"\*\)\s*die ", code):
        probs.append("entrypoint does not refuse a non-session-token API_KEY")
    if not re.search(r"^exec ", code, re.M):
        probs.append("entrypoint does not exec the agent")
    return probs


# ----------------------------------------------------------------------------- runtime layer
def runtime_checks_from_inspect(items, rep):
    probs = []
    for c in items:
        name = c.get("Name", "?").lstrip("/")
        hc = c.get("HostConfig", {})
        if hc.get("Privileged"):
            probs.append(f"{name}: privileged")
        if not hc.get("ReadonlyRootfs"):
            probs.append(f"{name}: rootfs writable")
        if "ALL" not in [x.upper() for x in (hc.get("CapDrop") or [])]:
            probs.append(f"{name}: CapDrop lacks ALL")
        if hc.get("CapAdd"):
            probs.append(f"{name}: CapAdd {hc['CapAdd']}")
        if not any("no-new-privileges" in x for x in (hc.get("SecurityOpt") or [])):
            probs.append(f"{name}: no-new-privileges not applied")
        if (c.get("Config", {}).get("User") or "0").split(":")[0] in ("", "0", "root"):
            probs.append(f"{name}: running as root")
        if not hc.get("Memory"):
            probs.append(f"{name}: no memory limit")
        if not hc.get("NanoCpus") and not hc.get("CpuQuota"):
            probs.append(f"{name}: no cpu limit")
        if not hc.get("PidsLimit") or hc.get("PidsLimit") < 0:
            probs.append(f"{name}: no pids limit")
        for b in hc.get("Binds") or []:
            probs.append(f"{name}: bind mount {b}")
        for m in c.get("Mounts") or []:
            if m.get("Type") == "bind" or "docker.sock" in str(m.get("Source", "")):
                probs.append(f"{name}: mount {m.get('Source')}")
        for port, binds in (hc.get("PortBindings") or {}).items():
            for b in binds or []:
                if b.get("HostIp") not in ("127.0.0.1", "::1"):
                    probs.append(f"{name}: {port} bound to {b.get('HostIp') or '0.0.0.0'}")
        if hc.get("NetworkMode") == "host":
            probs.append(f"{name}: host network")
        env = {e.split("=", 1)[0]: e.split("=", 1)[-1] for e in (c.get("Config", {}).get("Env") or [])}
        if name.endswith("api-1") or name.endswith("worker-1") or "worker" in name or name.endswith("api"):
            if not falsy(env.get("ANONYMIZED_TELEMETRY", "")):
                probs.append(f"{name}: ANONYMIZED_TELEMETRY={env.get('ANONYMIZED_TELEMETRY')!r}")
    rep.check("R01", "running containers carry the same controls (docker inspect)", probs, f"{len(items)} containers")


def runtime_layer(project, rep):
    if not shutil.which("docker"):
        rep.warn("R00", "runtime NOT VERIFIED", "docker CLI not found")
        return False
    try:
        r = subprocess.run(["docker", "info", "--format", "{{.ServerVersion}}"], capture_output=True, text=True, timeout=20)
    except Exception as e:  # pragma: no cover
        rep.warn("R00", "runtime NOT VERIFIED", f"docker info failed: {e}")
        return False
    if r.returncode != 0 or not r.stdout.strip():
        rep.warn("R00", "runtime NOT VERIFIED", "no reachable Docker daemon")
        return False
    ids = subprocess.run(["docker", "compose", "-p", project, "ps", "-q"], capture_output=True, text=True).stdout.split()
    if not ids:
        rep.warn("R00", "runtime NOT VERIFIED", f"no running containers for project {project!r}")
        return False
    insp = json.loads(subprocess.run(["docker", "inspect", *ids], capture_output=True, text=True).stdout)
    runtime_checks_from_inspect(insp, rep)
    rep.warn("R02", "isolation probes are NOT automated here", "run the tests in SWARM_PILOT_GATE.md section 3 and record results")
    return True


# ----------------------------------------------------------------------------- main
def load_compose(path):
    with open(path) as f:
        raw = yaml.safe_load(f)
    return raw


def run(path, strict=False, require_runtime=False, model_host="api.anthropic.com", entry_exc=False, project="swarm-pilot", do_runtime=True):
    rep = Report()
    compose = load_compose(path)
    static_checks(compose, os.path.dirname(os.path.abspath(path)), model_host, strict, entry_exc, rep)
    verified = runtime_layer(project, rep) if do_runtime else False
    if not do_runtime:
        rep.warn("R00", "runtime NOT VERIFIED", "runtime layer disabled (--no-runtime)")
    if require_runtime and not verified:
        rep.fail("R99", "runtime verification required", "--require-runtime set but runtime layer did not verify")
    return rep


def print_report(rep):
    w = max(len(r["title"]) for r in rep.rows)
    for r in rep.rows:
        print(f"[{r['status']:<4}] {r['id']:<4} {r['title']:<{w}}  {r['detail']}")
    n_fail = sum(r["status"] == "FAIL" for r in rep.rows)
    n_warn = sum(r["status"] == "WARN" for r in rep.rows)
    print(f"\nRESULT: {'FAIL' if rep.failed else 'PASS (static)'}  failed={n_fail} warnings={n_warn}")


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("compose")
    ap.add_argument("--strict", action="store_true", help="fail on placeholder digests")
    ap.add_argument("--require-runtime", action="store_true", help="fail unless running containers were inspected")
    ap.add_argument("--no-runtime", action="store_true")
    ap.add_argument("--model-host", default="api.anthropic.com")
    ap.add_argument("--entrypoint-exception", action="store_true", help="owner-reviewed FALLBACK ONLY (stock root entrypoint): allow worker root start with CHOWN/DAC_OVERRIDE/FOWNER/SETUID/SETGID; skips C20. Not needed with the derived non-root image")
    ap.add_argument("--project", default="swarm-pilot")
    ap.add_argument("--json", action="store_true")
    a = ap.parse_args(argv)
    try:
        rep = run(a.compose, a.strict, a.require_runtime, a.model_host, a.entrypoint_exception, a.project, not a.no_runtime)
    except Exception as e:
        sys.stderr.write(f"cannot parse {a.compose}: {e}\n")
        return 2
    if a.json:
        print(json.dumps({"failed": rep.failed, "checks": rep.rows}, indent=2))
    else:
        print_report(rep)
    return 1 if rep.failed else 0


if __name__ == "__main__":
    sys.exit(main())
