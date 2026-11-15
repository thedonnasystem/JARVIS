#!/usr/bin/env bash
# Local, loopback-only proof for worker telemetry. No LLM, no model key, no real external host contacted:
# the worker is given HTTPS_PROXY/HTTP_PROXY=<loopback refusing sink>, so even an attempt gets logged and refused.
# strace -f records every connect() the worker makes, independent of proxy settings.
set -u
SW=/home/claude/sandbox/swarm
H=/home/claude/sandbox/swarm_hardening/telemetry_proof
R=$H/run; rm -rf "$R"; mkdir -p "$R"/{data,home,ws}
SINK=13996; APIP=13997
KEY="tp-$(head -c12 /dev/urandom | od -An -tx1 | tr -d ' \n')"   # throwaway, never stored outside $R
python3 $H/sink_proxy.py $SINK $R/sink.jsonl & SINKPID=$!
sleep 1
api() { # $1 = telemetry flag value or "UNSET"
  local tel=(); [ "$1" != UNSET ] && tel=(ANONYMIZED_TELEMETRY=$1)
  ( cd $SW && env -i PATH="$PATH" HOME=$R/home PORT=$APIP API_KEY=$KEY DATABASE_PATH=$R/data/db.sqlite \
      DESPLEGA_TELEMETRY_ENDPOINT=http://127.0.0.1:$SINK/v1/events HTTPS_PROXY=http://127.0.0.1:$SINK HTTP_PROXY=http://127.0.0.1:$SINK \
      NO_PROXY=127.0.0.1,localhost "${tel[@]}" BUSINESS_USE_API_KEY= HEARTBEAT_DISABLE=true IMPROVEMENTS_ENABLED=false SLACK_DISABLE=true \
      CAPABILITIES=core,task-pool,config,mcp,profiles,memory,metrics,kv MEMORY_RATERS= \
      bun src/http.ts > $R/api_$2.log 2>&1 & echo $! > $R/api.pid )
  for i in $(seq 1 40); do curl -s --noproxy '*' -o /dev/null http://127.0.0.1:$APIP/health && break; sleep 0.5; done
}
stop_api() { kill $(cat $R/api.pid) 2>/dev/null; pkill -f "src/http.ts"; sleep 1; }
echo "== Phase A: API telemetry ON (to loopback sink) so an install id exists in the DB"
api UNSET A; sleep 3; stop_api
echo "   sink events so far: $(grep -c DIRECT_LOOPBACK $R/sink.jsonl 2>/dev/null)"
: > $R/sink.jsonl
echo "== Phase B: API restarted with ANONYMIZED_TELEMETRY=false (same DB); mint per-agent worker token"
api false B; sleep 1
TOK_JSON=$(curl -s --noproxy '*' -X POST -H "Authorization: Bearer $KEY" -H 'Content-Type: application/json' \
  -d '{"name":"pilot-worker"}' http://127.0.0.1:$APIP/api/agents/pilot-worker-1/token)
echo "$TOK_JSON" | python3 -c 'import json,sys; d=json.load(sys.stdin); print("   mint response keys:", sorted(d.keys())); open("'$R'/tok","w").write(d.get("plaintext",""))'
TOK=$(cat $R/tok); echo "   worker token present: $([ -n "$TOK" ] && echo yes || echo NO), prefix=${TOK:0:5}"
# does the per-agent token act as admin? (it must not)
echo "   worker token on admin-only route /api/agents/pilot-worker-1/token (POST) -> $(curl -s --noproxy '*' -o /dev/null -w '%{http_code}' -X POST -H "Authorization: Bearer $TOK" http://127.0.0.1:$APIP/api/agents/other/token)"
echo "   worker token on /api/config?scope=global&includeSecrets=true -> $(curl -s --noproxy '*' -o /dev/null -w '%{http_code}' -H "Authorization: Bearer $TOK" "http://127.0.0.1:$APIP/api/config?scope=global&includeSecrets=true")"
echo "   no key -> $(curl -s --noproxy '*' -o /dev/null -w '%{http_code}' http://127.0.0.1:$APIP/api/agents)"
worker() { # $1 label  $2 telemetry flag or UNSET  $3 extra env (e.g. TEMPLATE_ID=official/coder)
  local tel=(); [ "$2" != UNSET ] && tel=(ANONYMIZED_TELEMETRY=$2)
  : > $R/sink.jsonl
  ( cd $SW && timeout 30 env -i PATH="$PATH" HOME=$R/home AGENT_ID=pilot-worker-1 AGENT_ROLE=worker HARNESS_PROVIDER=claude \
      MCP_BASE_URL=http://127.0.0.1:$APIP API_KEY=$TOK \
      DESPLEGA_TELEMETRY_ENDPOINT=http://127.0.0.1:$SINK/v1/events HTTPS_PROXY=http://127.0.0.1:$SINK HTTP_PROXY=http://127.0.0.1:$SINK \
      NO_PROXY=127.0.0.1,localhost "${tel[@]}" $3 \
      strace -f -qq -e trace=connect -o $R/strace_$1.txt bun src/cli.tsx worker > $R/worker_$1.log 2>&1 )
  cp $R/sink.jsonl $R/sink_$1.jsonl
  python3 $H/summarize_connects.py $R/strace_$1.txt $R/sink_$1.jsonl $1
}
echo "== B1 CONTROL: worker flag UNSET, TEMPLATE_ID=official/coder (expect attempts to leave)"
worker control UNSET TEMPLATE_ID=official/coder
echo "== B2 HARDENED: worker ANONYMIZED_TELEMETRY=false, no TEMPLATE_ID, TEMPLATE_REGISTRY_URL blank"
worker hardened false "TEMPLATE_REGISTRY_URL=http://127.0.0.1:1"
stop_api; kill $SINKPID 2>/dev/null
echo "worker boot log tail (hardened):"; tail -15 $R/worker_hardened.log
