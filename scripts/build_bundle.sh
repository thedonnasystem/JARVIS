#!/usr/bin/env bash
# Rebuilds dist/APPLY_ALL.sql from migrations/ in APPLY_ORDER.txt order. Use --check to fail if dist is stale (CI).
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"; out="$(mktemp)"
{ echo "-- Fendezy HQ: all migrations in order. Paste into Supabase SQL editor and Run. Idempotent."
  for f in $(grep -v '^#' "$root/migrations/APPLY_ORDER.txt"); do echo; echo "-- ===== $f ====="; cat "$root/migrations/$f"; done; } > "$out"
if [ "${1:-}" = "--check" ]; then cmp -s "$out" "$root/dist/APPLY_ALL.sql" || { echo "dist/APPLY_ALL.sql is stale: run scripts/build_bundle.sh"; exit 1; }; echo "bundle current"
else mv "$out" "$root/dist/APPLY_ALL.sql"; echo "bundle rebuilt"; fi
