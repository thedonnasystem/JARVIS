#!/bin/bash
# Emulates (WITHOUT Docker) the runtime conditions the hardened worker gets: uid 1001, empty capability bounding set,
# no_new_privs, read-only root filesystem (private mount namespace), tmpfs HOME/logs//tmp owned by 1001, workspace dir owned
# by 1001. Runs the REAL entrypoint-hardened.sh with stub bun/agent-swarm. This proves the entrypoint's own logic and that
# it needs no root/caps/writable rootfs. It does NOT prove the real image, the real harness, Docker's seccomp/cgroups, or
# named-volume ownership inheritance (those need a Docker host).
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"; EP="$HERE/../worker/entrypoint-hardened.sh"; STUBS="$HERE/entrypoint_stubs"
pass=0; failn=0
ok()   { echo "  [PASS] $1"; pass=$((pass+1)); }
bad()  { echo "  [FAIL] $1"; failn=$((failn+1)); }

# $1 = scenario env (string of VAR=val), runs inside the restricted sandbox; prints entrypoint output; returns its rc
sandboxed() {
  local envs="$1"
  unshare -m bash -c '
    set -e
    mount --make-rprivate /
    mount --bind / / && mount -o remount,ro,bind /
    mount -t tmpfs -o size=16m,mode=1777 tmpfs /tmp
    mkdir -p /tmp/home /tmp/ws /tmp/logs
    mount -t tmpfs -o size=16m,uid=1001,gid=1001,mode=0700 tmpfs /tmp/home
    mount -t tmpfs -o size=16m,uid=1001,gid=1001,mode=0755 tmpfs /tmp/ws
    mount -t tmpfs -o size=16m,uid=1001,gid=1001,mode=0700 tmpfs /tmp/logs
    mkdir -p /tmp/seed/.claude && echo "{}" > /tmp/seed/.claude/settings.json && echo "{}" > /tmp/seed/.claude.json && chmod -R a+rX /tmp/seed
    set +e
    exec setpriv --reuid=1001 --regid=1001 --clear-groups --bounding-set=-all --inh-caps=-all --no-new-privs \
      env -i PATH=/usr/bin:/bin HOME=/tmp/home WORKSPACE_DIR=/tmp/ws LOGS_DIR=/tmp/logs SEED_DIR=/tmp/seed \
      BUN_BIN='"$STUBS"'/bun READINESS_TS='"$STUBS"'/readiness.ts SWARM_BIN='"$STUBS"'/agent-swarm STUB_LOG=/tmp/stub.log '"$envs"' \
      bash '"$EP"'
  ' 2>&1
}
GOOD='AGENT_ID=pilot-worker-1 API_KEY=aseph_0123456789abcdef0123456789abcdef MCP_BASE_URL=http://worker-gate:3014 AGENT_ROLE=worker'

echo "== happy path (uid 1001, no caps, no_new_privs, read-only root)"
out="$(sandboxed "$GOOD")"; rc=$?; echo "$out" | sed 's/^/    | /'
[ $rc -eq 0 ] && ok "entrypoint reaches exec of the agent (rc=0)" || bad "rc=$rc"
echo "$out" | grep -q "uid=1001 gid=1001 cwd=/tmp/ws" && ok "agent runs as uid 1001 in the workspace" || bad "uid/cwd"
echo "$out" | grep -q "CapEff:.0000000000000000" && ok "CapEff is empty" || bad "CapEff"
echo "$out" | grep -q "CapBnd:.0000000000000000" && ok "CapBnd is empty" || bad "CapBnd"
echo "$out" | grep -q "NoNewPrivs:.1" && ok "NoNewPrivs=1" || bad "NoNewPrivs"
echo "$out" | grep -q "readonly /usr/bin/x" && echo "$out" | grep -q "readonly /etc/x" && echo "$out" | grep -q "readonly /usr/local/bin/x" && ok "rootfs read-only (/usr/bin, /etc, /usr/local/bin not writable)" || bad "rootfs ro"
echo "$out" | grep -q "writable /tmp/home/x" && echo "$out" | grep -q "writable /tmp/ws/x" && echo "$out" | grep -q "writable /tmp/logs/x" && ok "HOME, workspace, logs writable" || bad "writable dirs"
echo "$out" | grep -q "HOME-listing: .*\.claude" && ok "HOME seeded (.claude restored over the empty tmpfs)" || bad "seed"
echo "$out" | grep -q "mcp.json mode: 600" && ok ".mcp.json is mode 600" || bad "mcp.json mode"
echo "$out" | grep -q "WRITABLE" && bad "something outside the allowed dirs was writable" || ok "no write outside HOME/workspace/logs/tmp succeeded"
echo "$out" | grep -q "bun-stub" ; grep -q . /dev/null
echo "== fail-closed preconditions"
o="$(sandboxed "AGENT_ID=a API_KEY=op-key-not-a-session-token MCP_BASE_URL=http://worker-gate:3014")"; rc=$?
[ $rc -eq 64 ] && echo "$o" | grep -q "not a per-agent worker session token" && ok "operator-style key refused (rc 64)" || bad "operator key accepted ($rc)"
o="$(sandboxed "AGENT_ID=a API_KEY=aseph_0123456789abcdef MCP_BASE_URL=http://api:3013")"; rc=$?
[ $rc -eq 64 ] && echo "$o" | grep -q "must be exactly http://worker-gate" && ok "direct API URL refused (rc 64)" || bad "direct api accepted ($rc)"
o="$(sandboxed "AGENT_ID=a API_KEY=aseph_0123456789abcdef MCP_BASE_URL=http://worker-gate:3014@evil:80")"; rc=$?
[ $rc -eq 64 ] && ok "userinfo trick in URL refused (rc 64)" || bad "url trick accepted ($rc)"
o="$(sandboxed "AGENT_ID=a API_KEY=aseph_0123456789abcdef MCP_BASE_URL=http://worker-gate:3014 AGENT_ROLE=lead")"; rc=$?
[ $rc -eq 64 ] && ok "AGENT_ROLE=lead refused (rc 64)" || bad "lead accepted ($rc)"
o="$(sandboxed "API_KEY=aseph_0123456789abcdef MCP_BASE_URL=http://worker-gate:3014")"; rc=$?
[ $rc -eq 64 ] && ok "missing AGENT_ID refused (rc 64)" || bad "no agent id accepted ($rc)"
o="$(sandboxed "AGENT_ID=../x API_KEY=aseph_0123456789abcdef MCP_BASE_URL=http://worker-gate:3014")"; rc=$?
[ $rc -eq 64 ] && ok "path-like AGENT_ID refused (rc 64)" || bad "bad agent id accepted ($rc)"
# root refusal: run the same entrypoint as uid 0 (no setpriv drop)
o="$(env -i PATH=/usr/bin:/bin HOME=/tmp AGENT_ID=a API_KEY=aseph_0123456789abcdef MCP_BASE_URL=http://worker-gate:3014 bash "$EP" 2>&1)"; rc=$?
[ $rc -eq 64 ] && echo "$o" | grep -q "refusing to run as root" && ok "uid 0 refused (rc 64)" || bad "root accepted ($rc)"
# unwritable workspace (owned by root) must produce the explicit message, not a chown attempt
o="$(unshare -m bash -c '
  mount --make-rprivate /; mount -t tmpfs -o size=4m,mode=1777 tmpfs /tmp; mkdir -p /tmp/home /tmp/ws /tmp/logs
  mount -t tmpfs -o uid=1001,gid=1001,mode=0700 tmpfs /tmp/home; mount -t tmpfs -o uid=1001,gid=1001 tmpfs /tmp/logs
  mount -t tmpfs -o uid=0,gid=0,mode=0755 tmpfs /tmp/ws
  exec setpriv --reuid=1001 --regid=1001 --clear-groups --bounding-set=-all --no-new-privs env -i PATH=/usr/bin:/bin HOME=/tmp/home WORKSPACE_DIR=/tmp/ws LOGS_DIR=/tmp/logs AGENT_ID=a API_KEY=aseph_0123456789abcdef MCP_BASE_URL=http://worker-gate:3014 bash '"$EP"' 2>&1')"; rc=$?
[ $rc -eq 64 ] && echo "$o" | grep -q "never changes ownership" && ok "root-owned workspace volume fails with an explicit message (no ownership change attempted)" || bad "unwritable workspace ($rc): $o"
echo
echo "RESULT: pass=$pass fail=$failn"
[ $failn -eq 0 ]
