#!/usr/bin/env python3
"""worker_gate.py: fail-closed allow-list reverse proxy between the pilot worker and the Agent Swarm API.

WHY (see SWARM_PILOT_GATE.md section 5): upstream scopes a per-agent worker token (`aseph_...`) only loosely.
Measured on v2.13.2 (evidence/route_sweep_worker_token.log, evidence/worker_token_powers.log): such a token reaches 313 of
509 documented operations and can, among others, create tasks (REST and MCP), set budgets, create schedules and skills,
upsert and run scripts, read the unmasked GLOBAL and own-agent secrets via GET /api/config/resolved?includeSecrets=true,
and reload config. Upstream has no switch to narrow that. This gate narrows it WITHOUT forking Swarm: the worker can only
reach this process, and this process forwards only the requests the worker harness needs. Everything else is 403.

Properties (all covered by tests/test_worker_gate.py and repro/test_gate_live.py):
  * default deny: a request is forwarded only if method + exact path shape match RULES below
  * only agent session tokens pass: a bearer that is not `aseph_*` (e.g. the operator key) is refused, so the operator key
    can never be used through the worker's door even if it leaks into the worker env
  * the agent id in paths is pinned to GATE_AGENT_ID; X-Agent-ID must match it
  * includeSecrets / resolveSecrets are forced to false on every forwarded query, so config secrets never reach the worker
  * no task creation: POST /api/tasks, POST /api/tasks/{id}/supersede (creates a resume task), MCP send-task and MCP
    task-action{action:create} are denied
  * MCP (/mcp, JSON-RPC over HTTP): only an allow-list of methods and tools; JSON-RPC batches are refused; a denied
    tools/call gets a JSON-RPC error body (HTTP 200) so the harness sees a tool error, not a transport failure
  * path hygiene: no encoded characters, no dot segments, no double slashes; duplicate query keys refused; bodies are
    size-capped and chunked request bodies are refused
  * never logs bearer tokens, query strings or bodies

Stdlib only. Run:  GATE_AGENT_ID=pilot-worker-1 GATE_UPSTREAM=api:3013 GATE_LISTEN=0.0.0.0:3014 python3 worker_gate.py
Config via env: GATE_AGENT_ID (required), GATE_UPSTREAM (host:port), GATE_LISTEN (host:port), GATE_MAX_BODY (bytes),
GATE_LOG (stdout|path).
"""
from __future__ import annotations

import http.client
import json
import os
import re
import sys
import threading
import time
from dataclasses import dataclass, field
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qsl, urlencode

UUID = r"[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}"
ID = r"[A-Za-z0-9_.-]{1,128}"
MAX_BODY_DEFAULT = 8 * 1024 * 1024
TOKEN_RE = re.compile(r"^Bearer aseph_[A-Za-z0-9_-]{8,256}$")
PATH_RE = re.compile(r"^/[A-Za-z0-9/_.-]*$")
QKEY_RE = re.compile(r"^[A-Za-z0-9_.-]{1,64}$")
FORCE_FALSE_QUERY = ("includeSecrets", "resolveSecrets")

# (method, path regex with {A}=pinned agent id, {T}=task uuid). Anything not listed is denied.
RULES: list[tuple[str, str]] = [
    # liveness / identity / lifecycle
    ("GET", r"/health"),
    ("GET", r"/me"),
    ("POST", r"/ping"),
    ("POST", r"/close"),
    ("GET", r"/cancelled-tasks"),
    ("GET", r"/api/poll"),
    # registration of ITSELF (body checked: isLead must not be true)
    ("POST", r"/api/agents"),
    ("GET", r"/api/agents/{A}"),
    ("PUT", r"/api/agents/{A}/(activity|profile|credential-status)"),
    ("GET", r"/api/agents/{A}/(credential-status|mcp-servers|skills|runtime)"),
    # its own task lifecycle (the server additionally enforces task ownership)
    ("GET", r"/api/tasks/{T}"),
    ("POST", r"/api/tasks/{T}/(progress|finish|context|request-composition|pause|resume|human-input)"),
    ("PUT", r"/api/tasks/{T}/session"),
    ("PATCH", r"/api/tasks/{T}/vcs"),
    ("GET", r"/api/tasks/{T}/(session-logs|steering-messages)"),
    ("GET", r"/api/paused-tasks"),
    ("GET", r"/api/concurrent-context"),
    ("GET", r"/api/steering-messages"),
    ("POST", r"/api/steering-messages/{T}/(delivered|undeliverable)"),
    # telemetry-to-self: logs, costs, sessions, hooks, events (all local to the API DB)
    ("POST", r"/api/session-logs"),
    ("POST", r"/api/session-costs"),
    ("POST", r"/api/active-sessions"),
    ("PUT", r"/api/active-sessions/(heartbeat|provider-session)/{ID}"),
    ("GET", r"/api/active-sessions/by-task/{ID}"),
    ("DELETE", r"/api/active-sessions/by-task/{ID}"),
    ("POST", r"/api/active-sessions/(cleanup|recover-orphaned-tasks)"),
    ("POST", r"/api/sessions/{ID}/close"),
    ("POST", r"/api/events"),
    ("POST", r"/api/events/batch"),
    ("GET", r"/api/events"),
    ("POST", r"/api/tool-hooks"),
    ("GET", r"/api/tool-hooks/status"),
    ("POST", r"/api/keys/(report-usage|report-rate-limit|report-rate-limit-windows|report-auth-failure|report-validation|report-seat-mismatch|clear-rate-limit)"),
    # read-mostly context
    ("GET", r"/api/repos"),
    ("POST", r"/api/scripts/(run|upsert)"),
    ("POST", r"/api/prompt-templates/render"),   # read-only template resolution ("used by workers via HTTP")
    ("GET", r"/api/models-catalog"),
    ("POST", r"/api/memory/(search|index)"),
    # config: ONLY the resolved view (includeSecrets forced to false); never /api/config, /api/config/reload, pool-keys
    ("GET", r"/api/config/resolved"),
    # MCP transport
    ("POST", r"/mcp"),
    ("GET", r"/mcp"),
    ("DELETE", r"/mcp"),
]

# Explicitly named so the audit trail and the verifier have something to assert. They are denied by default anyway.
MUST_DENY: list[tuple[str, str]] = [
    ("GET", "/api/config"),
    ("PUT", "/api/config"),
    ("DELETE", "/api/config/00000000-0000-0000-0000-000000000000"),
    ("GET", "/api/config/00000000-0000-0000-0000-000000000000"),
    ("POST", "/api/config/reload"),
    ("POST", "/internal/reload-config"),
    ("GET", "/api/config/pool-keys"),
    ("POST", "/api/tasks"),
    ("POST", "/api/tasks/00000000-0000-0000-0000-000000000000/supersede"),
    ("POST", "/api/tasks/00000000-0000-0000-0000-000000000000/cancel"),
    ("GET", "/api/tasks"),
    ("POST", "/api/agents/pilot-worker-1/token"),
    ("DELETE", "/api/agents/pilot-worker-1/token"),
    ("POST", "/api/agents/pilot-worker-1/token/rotate"),
    ("GET", "/api/agents"),
    ("PUT", "/api/budgets/global/_"),
    ("GET", "/api/budgets"),
    ("POST", "/api/schedules"),
    ("POST", "/api/scripts/upsert"),
    ("POST", "/api/scripts/run"),
    ("POST", "/api/skills"),
    ("POST", "/api/mcp-servers"),
    ("POST", "/api/db-query"),
    ("POST", "/api/users"),
    ("GET", "/api/users"),
    ("POST", "/api/internal/raw-llm"),
    ("POST", "/api/fs/agent-credentials"),
    ("PUT", "/api/kv/x"),
    ("GET", "/api/stats"),
    ("GET", "/api/keys/status"),
    ("PUT", "/api/models-catalog/overlay"),
]

# MCP: JSON-RPC methods and tools a pilot worker may use. Everything else is a JSON-RPC error.
MCP_METHODS = {"initialize", "notifications/initialized", "notifications/cancelled", "notifications/progress", "ping", "tools/list"}
MCP_TOOLS = {
    "my-agent-info": None,
    "get-task-details": None,
    "get-tasks": None,
    "store-progress": None,
    "poll-task": None,
    "get-repos": None,
    "memory-search": None,
    "memory-get": None,
    "memory-store": None,
    # task-action has a `create` action that creates tasks; only the claim-family is allowed
    "task-action": {"action": {"claim", "release", "accept", "reject"}},
}
# Named for audit; denied because they are not in MCP_TOOLS.
MCP_MUST_DENY = ["send-task", "db-query", "get-config", "list-config", "set-config", "delete-config", "skill-publish",
                 "script-run", "script-upsert", "launch-script-run", "manage-user", "mcp-server-create", "kv-set",
                 "cancel-task", "steer-task", "inject-learning", "join-swarm", "slack-post", "update-profile",
                 "submit-improvement", "runtime-pool-create-agent", "credential-bindings", "memory-delete"]


@dataclass
class Decision:
    allow: bool
    reason: str
    query: str = ""                       # query string to forward (rewritten)
    rewrites: list = field(default_factory=list)
    mcp_denied_id: object = None          # JSON-RPC id when the denial must be answered as a JSON-RPC error
    mcp_deny: bool = False
    status: int = 403


def _compile(agent_id: str):
    sub = {"A": re.escape(agent_id), "T": UUID, "ID": ID}
    out = []
    for m, p in RULES:
        rx = p
        for k, v in sub.items():
            rx = rx.replace("{" + k + "}", v)
        out.append((m, re.compile("^" + rx + "$")))
    return out


_COMPILED: dict[str, list] = {}


def rules_for(agent_id: str):
    if agent_id not in _COMPILED:
        _COMPILED[agent_id] = _compile(agent_id)
    return _COMPILED[agent_id]


def check_query(query: str):
    """Return (ok, reason, rewritten_query, rewrites)."""
    if not query:
        return True, "", "", []
    if len(query) > 4096:
        return False, "query too long", "", []
    pairs = parse_qsl(query, keep_blank_values=True, strict_parsing=False)
    seen = set()
    out, rewrites = [], []
    for k, v in pairs:
        if not QKEY_RE.match(k):
            return False, "bad query key", "", []
        if k in seen:
            return False, f"duplicate query key {k}", "", []
        seen.add(k)
        if k in FORCE_FALSE_QUERY:
            if v.lower() != "false":
                rewrites.append(f"{k}={v}->false")
            v = "false"
        out.append((k, v))
    return True, "", urlencode(out), rewrites


def check_mcp_body(body: bytes):
    """Return (ok, reason, rpc_id). Every JSON-RPC message in the body must be allowed."""
    try:
        msg = json.loads(body.decode("utf-8")) if body else None
    except Exception:
        return False, "mcp body is not JSON", None
    if not isinstance(msg, dict):
        return False, "mcp batch or non-object bodies are refused", None
    rid = msg.get("id")
    method = msg.get("method")
    if not isinstance(method, str):
        return False, "mcp message without method (responses from the worker are not forwarded)", rid
    if method == "tools/call":
        params = msg.get("params")
        if not isinstance(params, dict) or not isinstance(params.get("name"), str):
            return False, "mcp tools/call without a tool name", rid
        name = params["name"]
        if name not in MCP_TOOLS:
            return False, f"mcp tool '{name}' is not on the worker allow-list", rid
        constraint = MCP_TOOLS[name]
        if constraint:
            args = params.get("arguments")
            args = args if isinstance(args, dict) else {}
            for field_, allowed in constraint.items():
                val = args.get(field_)
                if not isinstance(val, str) or val not in allowed:
                    return False, f"mcp tool '{name}' argument {field_}={args.get(field_)!r} is not allowed", rid
        return True, "", rid
    if method in MCP_METHODS:
        return True, "", rid
    return False, f"mcp method '{method}' is not on the worker allow-list", rid


def decide(method: str, raw_path: str, headers: dict, body: bytes | None, agent_id: str, max_body: int = MAX_BODY_DEFAULT) -> Decision:
    """Pure policy function. `headers` keys are lower-case. Returns a Decision; never raises (an internal error is a deny)."""
    try:
        return _decide(method, raw_path, headers, body, agent_id, max_body)
    except Exception as e:  # fail closed
        return Decision(False, f"internal policy error ({type(e).__name__}); denied", status=400)


def _decide(method: str, raw_path: str, headers: dict, body: bytes | None, agent_id: str, max_body: int) -> Decision:
    method = method.upper()
    path, _, query = raw_path.partition("?")
    if not PATH_RE.match(path) or "//" in path or any(s in ("..", ".") for s in path.split("/")):
        return Decision(False, "path hygiene (encoded, dot-segment or double-slash path)", status=400)
    if method == "GET" and path == "/health" and not query:
        return Decision(True, "allowed (unauthenticated liveness, upstream returns status and version only)")
    auth = headers.get("authorization", "")
    if not TOKEN_RE.match(auth):
        return Decision(False, "only agent session tokens are accepted through the worker gate")
    xa = headers.get("x-agent-id")
    if xa is not None and xa != agent_id:
        return Decision(False, "X-Agent-ID does not match the pinned worker agent")
    if headers.get("x-page-id") is not None or headers.get("x-page-session") is not None:
        return Decision(False, "page headers are not accepted from the worker")
    if headers.get("transfer-encoding", "").lower() not in ("", "identity"):
        return Decision(False, "chunked request bodies are refused", status=411)
    if body is not None and len(body) > max_body:
        return Decision(False, "body too large", status=413)
    if not any(m == method and rx.match(path) for m, rx in rules_for(agent_id)):
        return Decision(False, f"{method} {path} is not on the worker allow-list")
    ok, why, q, rewrites = check_query(query)
    if not ok:
        return Decision(False, why, status=400)
    if path == "/api/config/resolved":
        qd = dict(parse_qsl(q))
        if qd.get("agentId", agent_id) != agent_id:
            return Decision(False, "resolved config of another agent")
    if method == "POST" and path == "/api/agents":
        try:
            b = json.loads((body or b"").decode("utf-8"))
        except Exception:
            return Decision(False, "register body is not JSON", status=400)
        if not isinstance(b, dict) or b.get("isLead") not in (None, False):
            return Decision(False, "a worker may not register as lead")
    if path == "/mcp" and method == "POST":
        ok, why, rid = check_mcp_body(body or b"")
        if not ok:
            return Decision(False, why, mcp_deny=True, mcp_denied_id=rid)
    return Decision(True, "allowed", query=q, rewrites=rewrites)


# ----------------------------------------------------------------------------- server
FORWARD_HEADERS = {"authorization", "x-agent-id", "x-runtime-instance-id", "x-source-task-id", "content-type", "accept",
                   "mcp-session-id", "mcp-protocol-version", "last-event-id", "user-agent", "content-length"}
HOP = {"connection", "keep-alive", "proxy-authenticate", "proxy-authorization", "te", "trailers", "transfer-encoding", "upgrade"}
_log_lock = threading.Lock()


def make_handler(agent_id: str, upstream: tuple[str, int], max_body: int, log):
    class H(BaseHTTPRequestHandler):
        protocol_version = "HTTP/1.0"   # one request per connection, stream until close (works for SSE)
        server_version = "worker-gate"
        sys_version = ""

        def log_message(self, *a):      # replaced by structured log
            pass

        def _emit(self, path, decision, status):
            rec = {"ts": round(time.time(), 3), "method": self.command, "path": path.split("?")[0][:200],
                   "decision": "ALLOW" if decision.allow else "DENY", "reason": decision.reason if not decision.allow else "",
                   "rewrites": decision.rewrites, "status": status}
            with _log_lock:
                log.write(json.dumps(rec) + "\n"); log.flush()

        def _send_json(self, status, obj):
            data = json.dumps(obj).encode()
            self.send_response(status)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(data)))
            self.end_headers()
            self.wfile.write(data)

        def _handle(self):
            headers = {k.lower(): v for k, v in self.headers.items()}
            body = None
            cl = headers.get("content-length")
            if cl is not None:
                try:
                    n = int(cl)
                except ValueError:
                    n = -1
                if n < 0 or n > max_body:
                    d = Decision(False, "bad or oversized content-length", status=413)
                    self._emit(self.path, d, 413); return self._send_json(413, {"error": d.reason})
                body = self.rfile.read(n) if n else b""
            d = decide(self.command, self.path, headers, body, agent_id, max_body)
            if not d.allow:
                if d.mcp_deny:
                    self._emit(self.path, d, 200)
                    return self._send_json(200, {"jsonrpc": "2.0", "id": d.mcp_denied_id,
                                                  "error": {"code": -32001, "message": "denied by worker-gate: " + d.reason}})
                self._emit(self.path, d, d.status)
                return self._send_json(d.status, {"error": "denied by worker-gate: " + d.reason})
            path = self.path.partition("?")[0]
            url = path + ("?" + d.query if d.query else "")
            fwd = {k: v for k, v in headers.items() if k in FORWARD_HEADERS and k != "content-length"}
            try:
                conn = http.client.HTTPConnection(upstream[0], upstream[1], timeout=330)
                conn.request(self.command, url, body=body, headers=fwd)
                resp = conn.getresponse()
            except Exception as e:
                d2 = Decision(False, f"upstream unreachable: {type(e).__name__}", status=502)
                self._emit(self.path, d2, 502)
                return self._send_json(502, {"error": "worker-gate: upstream unreachable"})
            self._emit(self.path, d, resp.status)
            self.send_response(resp.status)
            for k, v in resp.getheaders():
                if k.lower() not in HOP:
                    self.send_header(k, v)
            self.end_headers()
            try:
                while True:
                    chunk = resp.read(8192) if resp.getheader("content-length") else resp.read1(8192)
                    if not chunk:
                        break
                    self.wfile.write(chunk); self.wfile.flush()
            except (BrokenPipeError, ConnectionResetError):
                pass
            finally:
                conn.close()

        do_GET = do_POST = do_PUT = do_PATCH = do_DELETE = _handle

        def do_OPTIONS(self):
            d = Decision(False, "OPTIONS is not on the worker allow-list")
            self._emit(self.path, d, 403); self._send_json(403, {"error": d.reason})

        do_HEAD = do_TRACE = do_CONNECT = do_OPTIONS

    return H


def serve(agent_id, listen, upstream, max_body=MAX_BODY_DEFAULT, log=None):
    log = log or sys.stdout
    srv = ThreadingHTTPServer(listen, make_handler(agent_id, upstream, max_body, log))
    srv.daemon_threads = True
    return srv


def _hp(s, default_port):
    host, _, port = s.rpartition(":")
    return (host or s, int(port)) if host else (s, default_port)


def main():
    agent_id = os.environ.get("GATE_AGENT_ID", "")
    if not re.fullmatch(ID, agent_id):
        sys.stderr.write("GATE_AGENT_ID is required (the one agent id the worker token was minted for)\n"); return 2
    listen = _hp(os.environ.get("GATE_LISTEN", "0.0.0.0:3014"), 3014)
    up = _hp(os.environ.get("GATE_UPSTREAM", "api:3013"), 3013)
    lp = os.environ.get("GATE_LOG", "stdout")
    log = sys.stdout if lp == "stdout" else open(lp, "a")
    srv = serve(agent_id, listen, up, int(os.environ.get("GATE_MAX_BODY", MAX_BODY_DEFAULT)), log)
    sys.stderr.write(f"worker-gate listening on {listen[0]}:{listen[1]} -> {up[0]}:{up[1]} agent={agent_id}\n")
    try:
        srv.serve_forever()
    except KeyboardInterrupt:
        pass
    return 0


if __name__ == "__main__":
    sys.exit(main())
