#!/bin/bash
# Fendezy hardened worker entrypoint. Replaces the stock /docker-entrypoint.sh (1215 lines, starts as root, drops with gosu).
# Runs as a fixed non-root uid from the first instruction: no chown, no useradd, no gosu, no sudo, no writes outside
# $HOME (tmpfs), /workspace (volume), /logs (tmpfs) and /tmp (tmpfs). Fails closed on every precondition.
#
# Deliberately NOT done (each is something the stock entrypoint does that the pilot must not):
#   - fetch config rows from the API and export them into the environment (secrets must come from worker.env only)
#   - download and execute the agent "setup script" / /workspace/start-up.* from the API database (remote code at boot)
#   - GitHub / GitLab / Azure DevOps / Bitbucket credential setup, repo auto-clone, codex login, skill sync from the API
#   - write /etc/gitconfig, /usr/local/bin/gh, /usr/local/share/agent-swarm (all need root and a writable rootfs)
set -euo pipefail
umask 077

die() { echo "entrypoint-hardened: $*" >&2; exit 64; }

WORKSPACE_DIR="${WORKSPACE_DIR:-/workspace}"
LOGS_DIR="${LOGS_DIR:-/logs}"
SEED_DIR="${SEED_DIR:-/opt/worker-home-seed}"
BUN_BIN="${BUN_BIN:-/usr/local/bin/bun}"
READINESS_TS="${READINESS_TS:-/usr/local/lib/agent-swarm/entrypoint-api-readiness.ts}"
SWARM_BIN="${SWARM_BIN:-/usr/local/bin/agent-swarm}"
GATE_HOST="${WORKER_GATE_HOST:-worker-gate}"

# 1. Never root. (The Dockerfile sets USER 1001:1001 and compose sets user: "1001:1001"; this is the belt.)
[ "$(id -u)" -ne 0 ] || die "refusing to run as root (uid 0)"

# 2. Credentials: the per-agent worker session token only. The operator key must never be in a worker.
[ -n "${API_KEY:-}" ] || die "API_KEY (per-agent worker token) is required"
case "$API_KEY" in
  aseph_*) ;;
  *) die "API_KEY is not a per-agent worker session token (aseph_...). Refusing: it may be the operator key" ;;
esac
[ -n "${AGENT_ID:-}" ] || die "AGENT_ID is required"
case "$AGENT_ID" in
  *[!A-Za-z0-9_.-]*) die "AGENT_ID has unexpected characters" ;;
esac
[ "${AGENT_ROLE:-worker}" = "worker" ] || die "AGENT_ROLE must be worker (no lead in the pilot)"

# 3. The worker may only talk to the filtering gate, never to the API directly.
MCP_URL="${MCP_BASE_URL:-}"
GATE_URL_RE="^http://${GATE_HOST}:[0-9]{2,5}$"
[[ "$MCP_URL" =~ $GATE_URL_RE ]] || die "MCP_BASE_URL must be exactly http://${GATE_HOST}:<port> (the worker gate); got a different value"

# 4. Writable places must be writable by this uid without any chown (pre-owned tmpfs / pre-owned volume).
for d in "$HOME" "$WORKSPACE_DIR" "$LOGS_DIR" /tmp; do
  [ -d "$d" ] && [ -w "$d" ] || die "$d is not writable by uid $(id -u). Fix the mount (tmpfs uid/gid or recreate the named volume); the entrypoint never changes ownership"
done

# 5. HOME is a tmpfs that hides the image's baked-in /home/worker; restore the small baked config from the seed.
if [ ! -e "$HOME/.claude/settings.json" ]; then
  [ -d "$SEED_DIR" ] || die "seed dir $SEED_DIR missing (image not built from Dockerfile.worker-hardened)"
  cp -a --no-preserve=ownership "$SEED_DIR"/. "$HOME"/
fi
[ -f "$HOME/.claude/settings.json" ] || die "seeded HOME has no .claude/settings.json (hooks would be missing)"

# 6. Workspace layout (subset of what the stock entrypoint creates).
mkdir -p "$WORKSPACE_DIR/personal/memory"
for category in thoughts memory downloads misc; do
  mkdir -p "$WORKSPACE_DIR/shared/$category/$AGENT_ID"
done

# 7. API readiness, bounded. Goes through the gate (/health is the only unauthenticated path it forwards).
"$BUN_BIN" --no-orphans "$READINESS_TS" "$MCP_URL" "${WORKER_API_READY_TIMEOUT_SECONDS:-90}"

# 8. Project-level MCP config for the harness: the gate URL and the worker token. Mode 0600 (umask 077).
jq -n --arg url "${MCP_URL}/mcp" --arg auth "Bearer ${API_KEY}" --arg agent "$AGENT_ID" \
  '{mcpServers: {"agent-swarm": {type: "http", url: $url, headers: {Authorization: $auth, "X-Agent-ID": $agent}}}}' \
  > "$WORKSPACE_DIR/.mcp.json"

cd "$WORKSPACE_DIR"
# docker `init: true` is PID 1 (reaps orphans), so exec the agent directly.
exec gosu worker "$SWARM_BIN" worker "$@"
