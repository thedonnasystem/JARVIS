#!/usr/bin/env bash
# healthcheck.sh <base url ending in /v1>   exit 0 when the endpoint answers /models with the key (no generation, costs nothing)
set -euo pipefail
: "${JARVIS_SELFHOST_API_KEY:?}"
curl -fsS --max-time 10 -H "Authorization: Bearer $JARVIS_SELFHOST_API_KEY" "${1:?base url}/models" >/dev/null && echo "healthy" || { echo "UNHEALTHY"; exit 1; }
