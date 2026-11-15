"""Unit tests for config/worker_gate.py decide(): pure policy, no network. Run: python3 -m unittest discover -s tests -v"""
import json, os, sys, unittest
HERE = os.path.dirname(os.path.abspath(__file__)); ROOT = os.path.dirname(HERE)
sys.path.insert(0, os.path.join(ROOT, "config"))
import worker_gate as g  # noqa: E402

A = "pilot-worker-1"; U = "11111111-2222-3333-4444-555555555555"
H = {"authorization": "Bearer aseph_" + "x" * 40, "x-agent-id": A}


def d(method, path, body=None, headers=None, agent=A):
    b = json.dumps(body).encode() if isinstance(body, (dict, list)) else body
    return g.decide(method, path, {**H, **(headers or {})}, b, agent)


def rpc(method, params=None, i=1):
    m = {"jsonrpc": "2.0", "id": i, "method": method}
    if params is not None: m["params"] = params
    return m


class Allow(unittest.TestCase):
    def test_required_worker_flow(self):
        for m, p, b in [("GET", "/health", None), ("GET", "/me", None), ("POST", "/ping", {}), ("POST", "/close", {}),
                        ("GET", "/api/poll", None), ("POST", "/api/agents", {"name": "w", "isLead": False}),
                        ("GET", f"/api/tasks/{U}", None), ("POST", f"/api/tasks/{U}/progress", {"progress": "x"}),
                        ("POST", f"/api/tasks/{U}/finish", {"status": "completed"}), ("PUT", f"/api/tasks/{U}/session", {}),
                        ("PUT", f"/api/agents/{A}/profile", {}), ("PUT", f"/api/agents/{A}/activity", {}),
                        ("POST", "/api/session-logs", {}), ("POST", "/api/session-costs", {}), ("POST", "/api/tool-hooks", {}),
                        ("GET", "/api/config/resolved?agentId=pilot-worker-1&includeSecrets=true", None),
                        ("POST", "/api/prompt-templates/render", {"eventType": "x"}), ("POST", "/mcp", rpc("initialize", {}))]:
            with self.subTest(m=m, p=p):
                self.assertTrue(d(m, p, b).allow, d(m, p, b).reason)

    def test_health_is_unauthenticated(self):
        self.assertTrue(g.decide("GET", "/health", {}, None, A).allow)
        self.assertFalse(g.decide("GET", "/health?x=1", {}, None, A).allow)
        self.assertFalse(g.decide("GET", "/api/poll", {}, None, A).allow)


class Deny(unittest.TestCase):
    def test_must_deny_list(self):
        for m, p in g.MUST_DENY:
            with self.subTest(m=m, p=p):
                self.assertFalse(d(m, p, {}).allow)

    def test_secrets_forced_false(self):
        r = d("GET", "/api/config/resolved?agentId=pilot-worker-1&includeSecrets=true")
        self.assertTrue(r.allow); self.assertIn("includeSecrets=false", r.query); self.assertNotIn("true", r.query)
        r = d("GET", f"/api/agents/{A}/mcp-servers?resolveSecrets=true")
        self.assertTrue(r.allow); self.assertIn("resolveSecrets=false", r.query)
        r = d("GET", "/api/config/resolved?includeSecrets=TRUE"); self.assertIn("includeSecrets=false", r.query)

    def test_duplicate_and_bad_query(self):
        self.assertFalse(d("GET", "/api/config/resolved?includeSecrets=true&includeSecrets=false").allow)
        self.assertFalse(d("GET", "/api/poll?a b=1").allow)
        self.assertFalse(d("GET", "/api/poll?" + "a=" + "x" * 5000).allow)

    def test_other_agent_scope(self):
        self.assertFalse(d("GET", "/api/config/resolved?agentId=other-agent").allow)
        self.assertFalse(d("PUT", "/api/agents/other-agent/profile", {}).allow)
        self.assertFalse(d("GET", "/api/agents/other-agent").allow)
        self.assertFalse(d("GET", "/api/poll", headers={"x-agent-id": "other-agent"}).allow)
        self.assertFalse(d("PUT", f"/api/agents/{A}x/profile", {}).allow)       # no prefix match
        self.assertFalse(d("PUT", f"/api/agents/{A}/profile/x", {}).allow)      # no suffix match

    def test_credentials(self):
        for tok in ("Bearer operator-key-12345678", "Bearer aseph_", "aseph_" + "x" * 20, "Bearer  aseph_" + "x" * 20, "", "Basic abc"):
            with self.subTest(tok=tok):
                self.assertFalse(g.decide("GET", "/api/poll", {"authorization": tok}, None, A).allow)
        self.assertFalse(g.decide("GET", "/api/poll", {}, None, A).allow)

    def test_path_hygiene(self):
        for p in ("/api//tasks", "/api/tasks/../config", "/api/./poll", "/api%2Fpoll", "/api/poll%00", "/api/poll;x", "/api/pol\\l", "api/poll", "/api/poll/", "/API/poll"):
            with self.subTest(p=p):
                self.assertFalse(d("GET", p).allow)

    def test_methods(self):
        for m in ("HEAD", "OPTIONS", "TRACE", "CONNECT", "PATCH", "DELETE"):
            self.assertFalse(d(m, "/api/poll").allow)
        self.assertFalse(d("PUT", "/api/poll", {}).allow)
        self.assertFalse(d("GET", f"/api/tasks/{U}/finish").allow)              # wrong method for a known path

    def test_page_headers_and_chunked(self):
        self.assertFalse(d("GET", "/api/poll", headers={"x-page-id": "p"}).allow)
        self.assertFalse(d("GET", "/api/poll", headers={"x-page-session": "p"}).allow)
        self.assertFalse(d("POST", f"/api/tasks/{U}/progress", {}, headers={"transfer-encoding": "chunked"}).allow)

    def test_body_size(self):
        self.assertFalse(g.decide("POST", "/api/session-logs", H, b"x" * 100, A, max_body=50).allow)

    def test_lead_registration(self):
        self.assertFalse(d("POST", "/api/agents", {"name": "w", "isLead": True}).allow)
        self.assertFalse(d("POST", "/api/agents", b"not json").allow)
        self.assertFalse(d("POST", "/api/agents", [1]).allow)
        self.assertTrue(d("POST", "/api/agents", {"name": "w"}).allow)

    def test_task_creation_paths_all_closed(self):
        for m, p in [("POST", "/api/tasks"), ("POST", f"/api/tasks/{U}/supersede"), ("POST", "/api/schedules"), ("POST", "/api/workflows"),
                     ("POST", "/api/approval-requests"), ("POST", f"/api/tasks/{U}/steer"), ("POST", "/api/scripts/run"),
                     ("POST", "/api/internal/script-runs/x/agent-task"), ("POST", "/api/improvements")]:
            with self.subTest(p=p):
                self.assertFalse(d(m, p, {"task": "x"}).allow)


class Mcp(unittest.TestCase):
    def call(self, name, args=None):
        return d("POST", "/mcp", rpc("tools/call", {"name": name, "arguments": args or {}}))

    def test_allowed_tools(self):
        for n in ("my-agent-info", "get-task-details", "store-progress", "memory-search"):
            self.assertTrue(self.call(n).allow, n)

    def test_denied_tools(self):
        for n in g.MCP_MUST_DENY + ["nonexistent"]:
            r = self.call(n)
            self.assertFalse(r.allow, n); self.assertTrue(r.mcp_deny, n)

    def test_task_action_create_denied(self):
        self.assertFalse(self.call("task-action", {"action": "create", "task": "x"}).allow)
        self.assertFalse(self.call("task-action", {"action": "to_backlog", "taskId": U}).allow)
        self.assertFalse(self.call("task-action", {}).allow)
        self.assertFalse(self.call("task-action", {"action": ["claim"]}).allow)
        self.assertTrue(self.call("task-action", {"action": "claim", "taskId": U}).allow)

    def test_denial_carries_rpc_id(self):
        r = d("POST", "/mcp", rpc("tools/call", {"name": "send-task", "arguments": {}}, i=77))
        self.assertEqual(r.mcp_denied_id, 77)

    def test_batch_and_malformed(self):
        self.assertFalse(d("POST", "/mcp", [rpc("tools/list"), rpc("tools/call", {"name": "send-task"})]).allow)
        self.assertFalse(d("POST", "/mcp", b"{").allow)
        self.assertFalse(d("POST", "/mcp", {"jsonrpc": "2.0", "id": 1, "result": {}}).allow)         # a response, not a request
        self.assertFalse(d("POST", "/mcp", rpc("tools/call", {"arguments": {}})).allow)
        self.assertFalse(d("POST", "/mcp", rpc("tools/call", {"name": ["send-task"]})).allow)
        self.assertFalse(d("POST", "/mcp", rpc("resources/read", {"uri": "x"})).allow)
        self.assertFalse(d("POST", "/mcp", rpc("sampling/createMessage", {})).allow)

    def test_methods_allowed(self):
        for m in ("initialize", "tools/list", "ping", "notifications/initialized"):
            self.assertTrue(d("POST", "/mcp", rpc(m, {})).allow, m)


class Policy(unittest.TestCase):
    def test_rules_never_include_write_to_config(self):
        self.assertFalse([1 for m, p in g.RULES if p.startswith("/api/config") and (m != "GET" or p != "/api/config/resolved")])


if __name__ == "__main__":
    unittest.main(verbosity=2)
