#!/usr/bin/env bash
# THE pre-merge / pre-deploy gate. CI (.github/workflows/tests.yml) calls exactly this, so local and CI cannot diverge.
#
#   scripts/gate.sh                 run everything; SKIPPED steps are loud and the verdict says so
#   scripts/gate.sh --strict        any SKIPPED step (except '(optional)' ones, e.g. no backup drill on the branch) is a failure (CI uses this; use it before a deploy)
#   scripts/gate.sh --only lint,bundle   run only the named steps (unit scripts-tests lint bundle appcheck webjs replica manifest backup)
#
# Environment
#   REPLICA_URL   scratch Postgres, e.g. postgresql://postgres:pw@localhost:5432/infra_scratch. THE `public` SCHEMA OF THAT
#                 DATABASE IS WIPED. Without it (or if unreachable) replica+manifest+backup are SKIPPED, never silently passed.
#                 Non-local hosts and anything containing "supabase" are refused unless GATE_ALLOW_WIPE=1 (never for supabase).
#   LINT_BASE     ref that holds already-applied migrations (default origin/overnight-build)
#   REQUIRE_INTEGRATION=1   make the real-engine integration run mandatory (needs psycopg2); set by --strict
# Exit: 0 = no FAIL (and, with --strict, no SKIPPED); 1 = at least one FAIL or strict SKIPPED.
set -uo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"; cd "$root"
strict=0; only=""
while [ $# -gt 0 ]; do case "$1" in --strict) strict=1;; --only) only="${2:-}"; shift;; -h|--help) sed -n 2,16p "$0"; exit 0;; *) echo "unknown arg $1"; exit 2;; esac; shift; done
[ "$strict" = 1 ] && export REQUIRE_INTEGRATION=1
logs="$(mktemp -d "${TMPDIR:-/tmp}/gate.XXXXXX")"
names=(); results=(); notes=()
record() { names+=("$1"); results+=("$2"); notes+=("$3"); }
want() { [ -z "$only" ] || case ",$only," in *",$1,"*) true;; *) false;; esac; }

# run <step> <description> <command...>: PASS iff exit 0
run() { local s="$1" d="$2"; shift 2; want "$s" || return 0
  echo ">>> $s: $d"
  if "$@" >"$logs/$s.log" 2>&1; then record "$s" PASS "$d"; tail -n 3 "$logs/$s.log" | sed 's/^/    /'
  else record "$s" FAIL "$d (log: $logs/$s.log)"; tail -n 25 "$logs/$s.log" | sed 's/^/    /'; fi; }
skip() { want "$1" || return 0; echo ">>> $1: SKIPPED - $2"; record "$1" SKIPPED "$2"; }

run unit "python3 -m unittest discover -q (repo tests)" python3 -m unittest discover -q
run scripts-tests "lint + manifest tests (scripts/test_*.py)" python3 -m unittest discover -q -s scripts -p 'test_*.py'
run lint "migration lint (scripts/lint_migrations.py)" python3 scripts/lint_migrations.py --base "${LINT_BASE:-origin/overnight-build}"
run bundle "dist/APPLY_ALL.sql matches migrations/ (build_bundle.sh --check)" scripts/build_bundle.sh --check
run appcheck "PWA vs database drift: RPC names, message kinds, offline cache (scripts/check_app_rpcs.py)" python3 scripts/check_app_rpcs.py
# OPTIONAL: browser-less PWA smoke tests (node + jsdom, webtests/). Dev-only dependency, never part of the Python runtime. SKIPPED (not failed) without node/jsdom.
if want webjs; then
  if ! command -v node >/dev/null 2>&1 || ! command -v npm >/dev/null 2>&1; then skip webjs "(optional) node/npm not installed: PWA smoke tests not run"
  elif [ "$(node -p 'process.versions.node.split(".")[0]' 2>/dev/null || echo 0)" -lt 20 ]; then skip webjs "(optional) node >= 20 needed for the PWA smoke tests"
  elif [ ! -d webtests/node_modules/jsdom ] && ! (cd webtests && npm ci --ignore-scripts --no-audit --no-fund >"$logs/webjs-install.log" 2>&1); then skip webjs "(optional) could not install jsdom (offline? see $logs/webjs-install.log)"
  else run webjs "PWA smoke tests (webtests/: node --test, jsdom, no browser)" bash -c 'cd webtests && node --test'; fi
fi

# ---- steps that need a scratch Postgres -------------------------------------------------------------------------------
replica_ok=0; reason=""; reason_fail=0
if [ -z "${REPLICA_URL:-}" ]; then reason="REPLICA_URL not set (export REPLICA_URL=postgresql://postgres:pw@localhost:5432/<scratch db>)"
elif ! command -v psql >/dev/null 2>&1; then reason="psql not installed"
elif echo "$REPLICA_URL" | grep -qi supabase; then reason="REPLICA_URL looks like Supabase; refusing (the replica run wipes the public schema)"; reason_fail=1
elif ! echo "$REPLICA_URL" | grep -Eq '@(localhost|127\.0\.0\.1|\[::1\]|postgres)([:/]|$)' && [ "${GATE_ALLOW_WIPE:-}" != 1 ]; then reason="REPLICA_URL host is not local; set GATE_ALLOW_WIPE=1 only for a throwaway database"
elif ! psql "$REPLICA_URL" -Atqc 'select 1' >/dev/null 2>&1; then reason="no Postgres reachable at REPLICA_URL"
else replica_ok=1; fi

if [ "$replica_ok" = 1 ]; then
  replica_check() { scripts/replica/run.sh; local rc=$?; [ $rc = 0 ] && grep -q '^REPLICA OK' "$logs/replica.log" && grep -q 'RESULT: ALL PASSED' "$logs/replica.log" && ! grep -q '^FAIL ' "$logs/replica.log"; }
  run replica "replica: all migrations + e2e + integration + rollback drill on a scratch DB" replica_check
  if want manifest; then
    if grep -q '^REPLICA OK' "$logs/replica.log" 2>/dev/null; then
      run manifest "function manifest vs live baseline matches ops/EXPECTED_NEW_FUNCTIONS.txt" python3 scripts/function_manifest.py --check --manifest-out "$logs/function_manifest.txt"
    else skip manifest "replica step did not pass, so there is nothing to compare"; fi
  fi
  if want backup; then
    if [ -x scripts/backup_drill.sh ] && python3 -c "import cryptography, psycopg2" 2>/dev/null; then
      hostport="$(echo "$REPLICA_URL" | sed -E 's#^[a-z]+://[^@]*@([^/]*)/.*#\1#')"
      run backup "backup + restore drill (scripts/backup_drill.sh; uses its own scratch DBs)" env PGHOST="${hostport%%:*}" PGPORT="$( [[ "$hostport" == *:* ]] && echo "${hostport##*:}" || echo 5432)" scripts/backup_drill.sh
    elif [ -x scripts/backup_drill.sh ]; then skip backup "scripts/backup_drill.sh present but cryptography/psycopg2 missing (pip install cryptography psycopg2-binary)"
    else skip backup "(optional) scripts/backup_drill.sh not present on this branch"; fi
  fi
else
  for s in replica manifest backup; do
    if [ "$reason_fail" = 1 ]; then want "$s" && { echo ">>> $s: FAIL - $reason"; record "$s" FAIL "$reason"; }; else skip "$s" "$reason"; fi
  done
fi

# ---- summary ----------------------------------------------------------------------------------------------------------
echo; echo "================ GATE SUMMARY ================"
printf '%-14s %-8s %s\n' STEP RESULT DETAIL
fail=0; skipped=0; optional=0
for i in "${!names[@]}"; do printf '%-14s %-8s %s\n' "${names[$i]}" "${results[$i]}" "${notes[$i]}"
  [ "${results[$i]}" = FAIL ] && fail=$((fail+1)); [ "${results[$i]}" = SKIPPED ] && skipped=$((skipped+1))
  [ "${results[$i]}" = SKIPPED ] && case "${notes[$i]}" in "(optional)"*) optional=$((optional+1));; esac; done
echo "----------------------------------------------"
echo "logs: $logs"
if [ "${#names[@]}" = 0 ]; then echo "GATE FAILED: no step ran (bad --only?)"; exit 1; fi
if [ "$fail" -gt 0 ]; then echo "GATE FAILED: $fail step(s) failed"; exit 1; fi
if [ "$((skipped-optional))" -gt 0 ]; then
  skipped=$((skipped-optional))
  if [ "$strict" = 1 ]; then echo "GATE FAILED (--strict): $skipped required step(s) SKIPPED"; exit 1; fi
  echo "GATE INCOMPLETE: no failures, but $skipped step(s) SKIPPED. This is NOT a full pre-deploy pass; rerun with a scratch REPLICA_URL and --strict."; exit 0
fi
extra=""; [ "$optional" -gt 0 ] && extra=", $optional optional step(s) not available (see SKIPPED above)"
echo "GATE PASSED: $((${#names[@]}-optional)) steps passed$extra"
