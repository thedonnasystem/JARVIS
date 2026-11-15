"""Unit tests for verify_swarm_controls.py. Good fixture = the real hardened compose; bad fixtures are single-fault
mutations of it, written to tests/fixtures/ (kept on disk for inspection). Run: python3 -m unittest discover -s tests -v"""
import copy, json, os, shutil, subprocess, sys, unittest
import yaml

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
sys.path.insert(0, ROOT)
import verify_swarm_controls as v  # noqa: E402

FIX = os.path.join(HERE, "fixtures")
GOOD = os.path.join(ROOT, "docker-compose.hardened.yml")


def load():
    with open(GOOD) as f:
        return yaml.safe_load(f)


def write(name, data, squid=None, patch=None):
    """Fixture dir = compose + full copies of config/, worker/, secrets.example/. `patch` = {relpath: fn(text)->text} applied after the copy."""
    d = os.path.join(FIX, name)
    shutil.rmtree(d, ignore_errors=True)
    os.makedirs(d)
    for sub in ("config", "worker", "secrets.example"):
        shutil.copytree(os.path.join(ROOT, sub), os.path.join(d, sub), ignore=shutil.ignore_patterns("__pycache__"))
    for rel, fn in (patch or {}).items():
        fp = os.path.join(d, rel)
        with open(fp) as f:
            txt = f.read()
        new = fn(txt)
        assert new != txt, f"patch for {rel} changed nothing"
        with open(fp, "w") as f:
            f.write(new)
    if squid is not None:
        with open(os.path.join(d, "config", "squid.conf"), "w") as f:
            f.write(squid)
    p = os.path.join(d, "docker-compose.yml")
    with open(p, "w") as f:
        yaml.safe_dump(data, f, sort_keys=False)
    return p


def run(p, **kw):
    kw.setdefault("do_runtime", False)
    return v.run(p, **kw)


def status(rep, cid):
    return next(r["status"] for r in rep.rows if r["id"] == cid)


def mutate(fn):
    d = load()
    fn(d["services"])
    return d


def setenv(svc, k, val):
    e = svc["environment"]
    if val is None:
        e.pop(k, None)
    else:
        e[k] = val


class Good(unittest.TestCase):
    def test_good_passes_static(self):
        rep = run(GOOD)
        self.assertFalse(rep.failed, [r for r in rep.rows if r["status"] == "FAIL"])
        self.assertEqual(sum(r["id"].startswith("C") and r["id"][1:].isdigit() and r["status"] == "PASS" for r in rep.rows), 21)

    def test_cli_exit_codes(self):
        self.assertEqual(v.main([GOOD, "--no-runtime"]), 0)
        self.assertEqual(v.main([GOOD, "--no-runtime", "--strict"]), 1)          # placeholder digests
        self.assertEqual(v.main([GOOD, "--require-runtime"]), 1)                 # no daemon here => not verified => fail
        self.assertEqual(v.main([os.path.join(HERE, "nope.yml")]), 2)

    def test_wrong_model_host_fails(self):
        self.assertTrue(run(GOOD, model_host="openrouter.ai").failed)


# (name, mutation, expected failing check id)
def bad_cases():
    c = []
    c.append(("latest_tag", mutate(lambda s: s["api"].update(image="ghcr.io/desplega-ai/agent-swarm:latest")), "C01"))
    c.append(("no_tag", mutate(lambda s: s["worker"].update(image="ghcr.io/desplega-ai/agent-swarm-worker")), "C01"))
    c.append(("tag_no_digest", mutate(lambda s: s["worker"].update(image="ghcr.io/desplega-ai/agent-swarm-worker:2.13.2")), "C01"))
    c.append(("pull_always", mutate(lambda s: s["api"].update(pull_policy="always")), "C02"))
    c.append(("writable_rootfs", mutate(lambda s: s["worker"].update(read_only=False)), "C03"))
    c.append(("no_tmpfs", mutate(lambda s: s["worker"].pop("tmpfs")), "C03"))
    c.append(("no_cap_drop", mutate(lambda s: s["worker"].pop("cap_drop")), "C04"))
    c.append(("cap_add_sysadmin", mutate(lambda s: s["worker"].update(cap_add=["SYS_ADMIN"])), "C04"))
    c.append(("no_new_privs_missing", mutate(lambda s: s["worker"].update(security_opt=[])), "C05"))
    c.append(("seccomp_unconfined", mutate(lambda s: s["worker"].update(security_opt=["no-new-privileges:true", "seccomp:unconfined"])), "C05"))
    c.append(("root_user", mutate(lambda s: s["worker"].update(user="0:0")), "C06"))
    c.append(("no_user", mutate(lambda s: s["api"].pop("user")), "C06"))
    c.append(("privileged", mutate(lambda s: s["worker"].update(privileged=True)), "C07"))
    c.append(("host_network", mutate(lambda s: s["worker"].update(network_mode="host")), "C07"))
    c.append(("no_limits_worker", mutate(lambda s: [s["worker"].pop(k) for k in ("mem_limit", "cpus", "pids_limit")]), "C08"))
    c.append(("no_pids_limit_api", mutate(lambda s: s["api"].pop("pids_limit")), "C08"))
    c.append(("docker_sock", mutate(lambda s: s["worker"]["volumes"].append("/var/run/docker.sock:/var/run/docker.sock")), "C09"))
    c.append(("docker_sock_long", mutate(lambda s: s["worker"]["volumes"].append({"type": "bind", "source": "/var/run/docker.sock", "target": "/s"})), "C09"))
    c.append(("host_mount_home", mutate(lambda s: s["worker"]["volumes"].append("/home/moe:/host:ro")), "C09"))
    c.append(("two_volumes", mutate(lambda s: s["api"].update(volumes=["swarm_api_data:/app/data"])), "C09"))
    c.append(("port_implicit_0000", mutate(lambda s: s["api-ingress"].update(ports=["13013:8080"])), "C10"))
    c.append(("port_explicit_0000", mutate(lambda s: s["api-ingress"].update(ports=["0.0.0.0:13013:8080"])), "C10"))
    c.append(("port_on_worker", mutate(lambda s: s["worker"].update(ports=["127.0.0.1:3021:3000"])), "C10"))
    c.append(("telemetry_missing_worker", mutate(lambda s: setenv(s["worker"], "ANONYMIZED_TELEMETRY", None)), "C11"))
    c.append(("telemetry_true_api", mutate(lambda s: setenv(s["api"], "ANONYMIZED_TELEMETRY", "true")), "C11"))
    c.append(("shared_env_file", mutate(lambda s: s["worker"].update(env_file=list(s["api"]["env_file"]))), "C12"))
    c.append(("shared_inline_key", mutate(lambda s: (setenv(s["api"], "API_KEY", "${API_KEY}"), setenv(s["worker"], "API_KEY", "${API_KEY}"))), "C12"))
    c.append(("lead_present", mutate(lambda s: s.update(lead=copy.deepcopy(s["worker"]) | {"environment": {**s["worker"]["environment"], "AGENT_ROLE": "lead"}})), "C12"))
    c.append(("two_workers", mutate(lambda s: s.update({"worker-2": copy.deepcopy(s["worker"])})), "C12"))
    c.append(("worker_on_egress", mutate(lambda s: s["worker"].update(networks=["worker_net", "egress"])), "C13"))
    c.append(("no_networks", mutate(lambda s: s["api"].pop("networks")), "C13"))
    c.append(("no_proxy_env", mutate(lambda s: setenv(s["worker"], "HTTPS_PROXY", None)), "C14"))
    c.append(("template_id_set", mutate(lambda s: setenv(s["worker"], "TEMPLATE_ID", "official/coder")), "C15"))
    c.append(("improvements_on", mutate(lambda s: setenv(s["api"], "IMPROVEMENTS_ENABLED", None)), "C15"))
    c.append(("cli_telemetry_on", mutate(lambda s: setenv(s["worker"], "DISABLE_TELEMETRY", None)), "C15"))
    c.append(("scheduling_enabled", mutate(lambda s: setenv(s["api"], "CAPABILITIES", "core,task-pool,scheduling,workflows")), "C16"))
    c.append(("capabilities_default", mutate(lambda s: setenv(s["api"], "CAPABILITIES", None)), "C16"))
    c.append(("heartbeat_on", mutate(lambda s: setenv(s["api"], "HEARTBEAT_DISABLE", "false")), "C16"))
    c.append(("relative_env_file", mutate(lambda s: s["worker"].update(env_file=["./worker.env"])), "C17"))
    c.append(("inline_secret", mutate(lambda s: setenv(s["worker"], "ANTHROPIC_API_KEY", "sk-FAKE")), "C17"))
    c.append(("model_key_on_api", mutate(lambda s: setenv(s["api"], "ANTHROPIC_API_KEY", "${ANTHROPIC_API_KEY}")), "C17"))
    # ---- C06 numeric uid
    c.append(("user_by_name", mutate(lambda s: s["worker"].update(user="worker")), "C06"))
    # ---- C18 topology
    c.append(("worker_on_api_net", mutate(lambda s: s["worker"].update(networks=["worker_net", "api_net"])), "C18"))
    c.append(("worker_direct_api_url", mutate(lambda s: setenv(s["worker"], "MCP_BASE_URL", "http://api:3013")), "C18"))
    c.append(("worker_api_in_other_env", mutate(lambda s: setenv(s["worker"], "SWARM_API", "http://api:3013")), "C18"))
    c.append(("no_gate_service", mutate(lambda s: (s.pop("worker-gate"), s["worker"].pop("depends_on"))), "C18"))
    c.append(("proxy_bridges_api_net", mutate(lambda s: s["egress-proxy"].update(networks=["worker_net", "api_net", "egress"])), "C18"))
    c.append(("ingress_on_worker_net", mutate(lambda s: s["api-ingress"].update(networks=["api_net", "worker_net", "hq_edge"])), "C18"))
    c.append(("gate_publishes_port", mutate(lambda s: s["worker-gate"].update(ports=["127.0.0.1:3014:3014"])), "C18"))
    # ---- C19 gate service wiring
    c.append(("gate_agent_mismatch", mutate(lambda s: setenv(s["worker-gate"], "GATE_AGENT_ID", "someone-else")), "C19"))
    c.append(("gate_upstream_wrong", mutate(lambda s: setenv(s["worker-gate"], "GATE_UPSTREAM", "evil:80")), "C19"))
    # ---- C20 non-root image
    c.append(("stock_worker_image", mutate(lambda s: s["worker"].update(image="ghcr.io/desplega-ai/agent-swarm-worker:2.13.2@sha256:" + "ab12" * 16)), "C20"))
    c.append(("worker_entrypoint_override", mutate(lambda s: s["worker"].update(entrypoint=["/docker-entrypoint.sh"])), "C20"))
    c.append(("home_tmpfs_wrong_uid", mutate(lambda s: s["worker"].update(tmpfs=[t.replace("uid=${WORKER_UID:-1001}", "uid=0") for t in s["worker"]["tmpfs"]])), "C20"))
    c.append(("no_home_tmpfs", mutate(lambda s: s["worker"].update(tmpfs=[t for t in s["worker"]["tmpfs"] if not t.startswith("/home/worker")])), "C20"))
    # ---- C21
    c.append(("config_seed_env", mutate(lambda s: setenv(s["api"], "CONFIG_SEED", "x")), "C21"))
    return c


def patched_cases():
    """(name, patch dict, expected failing check). The compose is untouched; a file next to it is weakened."""
    rep_ = lambda a, b: (lambda t: t.replace(a, b, 1))
    gate = "config/worker_gate.py"; ent = "worker/entrypoint-hardened.sh"; dock = "worker/Dockerfile.worker-hardened"
    return [
        ("gate_allows_task_create", {gate: rep_('    ("POST", r"/api/tasks/{T}/(progress', '    ("POST", r"/api/tasks"),\n    ("POST", r"/api/tasks/{T}/(progress')}, "C19"),
        ("gate_allows_config_write", {gate: rep_('    ("GET", r"/api/config/resolved"),', '    ("GET", r"/api/config/resolved"),\n    ("PUT", r"/api/config"),')}, "C19"),
        ("gate_allows_token_mint", {gate: rep_('    ("GET", r"/api/agents/{A}"),', '    ("GET", r"/api/agents/{A}"),\n    ("POST", r"/api/agents/{A}/token"),')}, "C19"),
        ("gate_allows_scripts", {gate: rep_('    ("GET", r"/api/repos"),', '    ("GET", r"/api/repos"),\n    ("POST", r"/api/scripts/(run|upsert)"),')}, "C19"),
        ("gate_secrets_not_forced", {gate: rep_('FORCE_FALSE_QUERY = ("includeSecrets", "resolveSecrets")', 'FORCE_FALSE_QUERY = ()')}, "C19"),
        ("gate_mcp_send_task", {gate: rep_('"my-agent-info": None,', '"my-agent-info": None,\n    "send-task": None,')}, "C19"),
        ("gate_mcp_task_action_create", {gate: rep_('{"action": {"claim", "release", "accept", "reject"}}', '{"action": {"claim", "release", "accept", "reject", "create"}}')}, "C19"),
        ("gate_mcp_batch_ok", {gate: rep_('if not isinstance(msg, dict):', 'if isinstance(msg, list):\n        return True, "", None\n    if not isinstance(msg, dict):')}, "C19"),
        ("gate_accepts_operator_key", {gate: rep_('TOKEN_RE = re.compile(r"^Bearer aseph_[A-Za-z0-9_-]{8,256}$")', 'TOKEN_RE = re.compile(r"^Bearer .+$")')}, "C19"),
        ("gate_default_allow", {gate: rep_('    if not any(m == method and rx.match(path) for m, rx in rules_for(agent_id)):', '    if False:')}, "C19"),
        ("gate_no_path_hygiene", {gate: rep_('    if not PATH_RE.match(path) or "//" in path or any(s in ("..", ".") for s in path.split("/")):', '    if False:')}, "C19"),
        ("gate_lead_register_ok", {gate: rep_('b.get("isLead") not in (None, False)', 'False')}, "C19"),
        ("gate_other_agent_config", {gate: rep_('qd.get("agentId", agent_id) != agent_id', 'False')}, "C19"),
        ("gate_missing_file", {gate: lambda t: "syntax error (((\n"}, "C19"),
        ("entrypoint_uses_gosu", {ent: rep_('exec "$SWARM_BIN" worker "$@"', 'exec gosu worker "$SWARM_BIN" worker "$@"')}, "C20"),
        ("entrypoint_chowns", {ent: rep_('mkdir -p "$WORKSPACE_DIR/personal/memory"', 'chown -R 1001 "$WORKSPACE_DIR"\nmkdir -p "$WORKSPACE_DIR/personal/memory"')}, "C20"),
        ("entrypoint_fetches_config", {ent: rep_('cd "$WORKSPACE_DIR"', 'curl -s "$MCP_URL/api/config/resolved?includeSecrets=true" > /tmp/c\ncd "$WORKSPACE_DIR"')}, "C20"),
        ("entrypoint_allows_root", {ent: rep_('[ "$(id -u)" -ne 0 ] || die "refusing to run as root (uid 0)"', ':')}, "C20"),
        ("entrypoint_accepts_any_key", {ent: rep_('aseph_*) ;;', '*) ;;')}, "C20"),
        ("dockerfile_user_root", {dock: rep_('USER 1001:1001\nRUN HOME', 'USER 0:0\nRUN HOME')}, "C20"),
        ("dockerfile_uid_drift", {dock: rep_('"$(id -u worker)" = "1001"', '"$(id -u worker)" = "1002"')}, "C20"),
        ("dockerfile_unpinned_base", {dock: rep_('@sha256:0000000000000000000000000000000000000000000000000000000000000000', '')}, "C20"),
        ("dockerfile_no_seed", {dock: lambda t: t.replace("worker-home-seed", "x-seed")}, "C20"),
        ("dockerfile_gosu_entry", {dock: rep_('ENTRYPOINT ["/usr/local/bin/entrypoint-hardened.sh"]', 'ENTRYPOINT ["gosu", "worker", "/docker-entrypoint.sh"]')}, "C20"),
        ("api_env_has_model_key", {"secrets.example/api.env.example": lambda t: t + "\nANTHROPIC_API_KEY=x\n"}, "C21"),
        ("worker_env_has_encryption_key", {"secrets.example/worker.env.example": lambda t: t + "\nSECRETS_ENCRYPTION_KEY=x\n"}, "C21"),
    ]


class Bad(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        os.makedirs(FIX, exist_ok=True)

    def test_each_bad_fixture_fails_expected_check(self):
        cases = bad_cases()
        self.assertGreaterEqual(len(cases), 55)
        for name, data, cid in cases:
            with self.subTest(case=name):
                rep = run(write("bad_" + name, data))
                self.assertTrue(rep.failed, f"{name} should fail overall")
                self.assertEqual(status(rep, cid), "FAIL", f"{name}: expected {cid} FAIL, got {[(r['id'], r['status']) for r in rep.rows if r['status']=='FAIL']}")

    def test_each_weakened_file_fails_expected_check(self):
        cases = patched_cases()
        self.assertGreaterEqual(len(cases), 25)
        for name, patch, cid in cases:
            with self.subTest(case=name):
                rep = run(write("bad_" + name, load(), patch=patch))
                self.assertTrue(rep.failed, f"{name} should fail overall")
                self.assertEqual(status(rep, cid), "FAIL", f"{name}: expected {cid} FAIL, got {[(r['id'], r['status']) for r in rep.rows if r['status']=='FAIL']}")

    def test_bad_squid_variants(self):
        with open(os.path.join(ROOT, "config", "squid.conf")) as f:
            base = f.read()
        variants = {
            "squid_allows_models_dev": base.replace("acl model_api dstdomain api.anthropic.com", "acl model_api dstdomain api.anthropic.com models.dev"),
            "squid_allows_templates": base.replace("acl model_api dstdomain api.anthropic.com", "acl model_api dstdomain api.anthropic.com templates.agent-swarm.dev proxy.desplega.sh"),
            "squid_no_deny_all": base.replace("http_access deny all", "http_access allow all"),
            "squid_wrong_host": base.replace("api.anthropic.com", "evil.example.com"),
        }
        for name, sq in variants.items():
            with self.subTest(case=name):
                rep = run(write("bad_" + name, load(), squid=sq))
                self.assertEqual(status(rep, "C14"), "FAIL")

    def test_missing_squid_fails(self):
        d = load(); p = write("bad_no_squid", d); os.remove(os.path.join(os.path.dirname(p), "config", "squid.conf"))
        self.assertEqual(status(run(p), "C14"), "FAIL")


class Options(unittest.TestCase):
    def test_entrypoint_exception_only_allows_listed_caps(self):
        d = mutate(lambda s: s["worker"].update(user="root", cap_add=["CHOWN", "SETUID", "SETGID", "DAC_OVERRIDE"]))
        p = write("exc_ok", d)
        self.assertTrue(run(p).failed)                                   # without the flag: refused
        self.assertFalse(run(p, entry_exc=True).failed)                  # with owner flag: accepted
        d2 = mutate(lambda s: s["worker"].update(user="root", cap_add=["CHOWN", "SYS_ADMIN"]))
        self.assertTrue(run(write("exc_bad", d2), entry_exc=True).failed)  # flag never allows other caps

    def test_strict_rejects_placeholder_digest(self):
        self.assertTrue(run(GOOD, strict=True).failed)
        d = mutate(lambda s: [s[n].update(image=("sha256:" + "ab12" * 16) if n == "worker" else s[n]["image"].split("@")[0] + "@sha256:" + "ab12" * 16) for n in s])
        self.assertFalse(run(write("real_digests", d), strict=True).failed)

    def test_require_runtime_without_daemon_fails(self):
        self.assertTrue(v.run(GOOD, require_runtime=True, do_runtime=True).failed)


def inspect_ok(name="swarm-pilot-worker-1"):
    return {"Name": "/" + name, "Config": {"User": "worker", "Env": ["ANONYMIZED_TELEMETRY=false"]},
            "Mounts": [{"Type": "volume", "Source": "scratch"}],
            "HostConfig": {"Privileged": False, "ReadonlyRootfs": True, "CapDrop": ["ALL"], "CapAdd": None,
                           "SecurityOpt": ["no-new-privileges:true"], "Memory": 2 << 30, "NanoCpus": 1_500_000_000,
                           "PidsLimit": 512, "Binds": None, "NetworkMode": "swarm-pilot_swarm_internal",
                           "PortBindings": {}}}


class RuntimeInspect(unittest.TestCase):
    def check(self, mut):
        item = inspect_ok(); mut(item); rep = v.Report(); v.runtime_checks_from_inspect([item], rep); return rep

    def test_good(self):
        self.assertFalse(self.check(lambda i: None).failed)

    def test_bad_runtime_states(self):
        muts = {
            "privileged": lambda i: i["HostConfig"].update(Privileged=True),
            "rw_rootfs": lambda i: i["HostConfig"].update(ReadonlyRootfs=False),
            "caps": lambda i: i["HostConfig"].update(CapDrop=[]),
            "root": lambda i: i["Config"].update(User=""),
            "sock": lambda i: i["Mounts"].append({"Type": "bind", "Source": "/var/run/docker.sock"}),
            "no_mem": lambda i: i["HostConfig"].update(Memory=0),
            "no_pids": lambda i: i["HostConfig"].update(PidsLimit=0),
            "public_port": lambda i: i["HostConfig"].update(PortBindings={"8080/tcp": [{"HostIp": "0.0.0.0", "HostPort": "1"}]}),
            "telemetry": lambda i: i["Config"].update(Env=["ANONYMIZED_TELEMETRY=true"]),
            "no_nnp": lambda i: i["HostConfig"].update(SecurityOpt=[]),
        }
        for n, m in muts.items():
            with self.subTest(case=n):
                self.assertTrue(self.check(m).failed)


if __name__ == "__main__":
    unittest.main(verbosity=2)
