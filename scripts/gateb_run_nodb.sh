#!/usr/bin/env bash
# Run the no-database gate steps and a VERBOSE unit run against an exact commit, in a throwaway detached worktree of THIS clone, and write two
# logs whose first line binds them to that commit (scripts/gateb_package.py reads the binding):
#   scripts/gateb_run_nodb.sh <commit-sha> <label> <out-dir>
#   -> <out-dir>/<label>_gate_nodb.log   (scripts/gate.sh --only unit,scripts-tests,lint,bundle,appcheck)
#   -> <out-dir>/<label>_unit_v.log      (python3 -m unittest discover -v, repo root then scripts/)
# No database, no network, no secrets. The worktree is removed afterwards. Exit 0 only if both runs passed.
set -uo pipefail
sha="${1:?commit sha}"; label="${2:?label}"; out="${3:?out dir}"
root="$(cd "$(dirname "$0")/.." && pwd)"; mkdir -p "$out"; out="$(cd "$out" && pwd)"
full="$(git -C "$root" rev-parse --verify "$sha^{commit}")" || { echo "unknown commit $sha (fetch it first)"; exit 2; }
wt="$(mktemp -d "${TMPDIR:-/tmp}/gateb_wt.XXXXXX")"; rmdir "$wt"
git -C "$root" worktree add -q --detach "$wt" "$full" || exit 2
trap 'git -C "$root" worktree remove --force "$wt" >/dev/null 2>&1' EXIT
stamp="$(date -u +%Y-%m-%dT%H:%M:%SZ)"; rc=0
{ echo "# gateb-binding: head=$full label=$label ran_at=$stamp cmd=scripts/gate.sh --only unit,scripts-tests,lint,bundle,appcheck (no database)"
  (cd "$wt" && scripts/gate.sh --only unit,scripts-tests,lint,bundle,appcheck); } >"$out/${label}_gate_nodb.log" 2>&1 || rc=1
{ echo "# gateb-binding: head=$full label=$label ran_at=$stamp cmd=python3 -m unittest discover -v (root, then scripts/)"
  (cd "$wt" && python3 -m unittest discover -v 2>&1; python3 -m unittest discover -v -s scripts -p 'test_*.py' 2>&1); } >"$out/${label}_unit_v.log" 2>&1 || rc=1
grep -q '^GATE PASSED' "$out/${label}_gate_nodb.log" || rc=1
echo "$label $full gate_rc_ok=$([ $rc = 0 ] && echo yes || echo no) logs in $out"; exit $rc
