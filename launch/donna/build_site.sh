#!/usr/bin/env bash
# Build the Donna.AI site with the repo's Web Studio pipeline into launch/donna/.out/dist (Netlify publishes that folder).
#   bash launch/donna/build_site.sh            # build (Netlify runs this)
#   bash launch/donna/build_site.sh --clean    # build, then delete node_modules to save disk (local use)
#
# Why the two steps: hq_webstudio's QA counts any absolute link to another host as a "remote asset", including the page's own
# canonical link. So the site is built and QA'd with the placeholder host (https://example.invalid), and only then is that
# placeholder swapped for the real address Netlify gives the build (URL, or SITE_URL), in canonical, Open Graph, sitemap and
# robots. The QA is then run again on the final files, and only "remote asset from <our own host>" is accepted.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
OUT="$HERE/.out"
SITE_ADDR="${SITE_URL:-${URL:-}}"
cleanup() { if [[ "${1:-}" == "--clean" ]]; then rm -rf "$OUT/node_modules" "$OUT/.astro"; fi; }
trap 'cleanup "${1:-}"' EXIT

rm -rf "$OUT"
env -u URL -u SITE_URL python3 "$ROOT/hq_webstudio.py" build donna --out "$OUT"

if [[ "$SITE_ADDR" =~ ^https://[A-Za-z0-9.-]+$ ]]; then
  grep -rlZ "https://example.invalid" "$OUT/dist" --include='*.html' --include='*.xml' --include='*.txt' \
    | xargs -0 -r sed -i "s#https://example.invalid#${SITE_ADDR}#g"
  python3 - "$ROOT" "$OUT/dist" "$SITE_ADDR" <<'PY'
import importlib.util, sys
root, dist, addr = sys.argv[1:4]
spec = importlib.util.spec_from_file_location("hq_webstudio", f"{root}/hq_webstudio.py")
W = importlib.util.module_from_spec(spec); spec.loader.exec_module(W)
host = addr.split("://", 1)[1]
problems, _ = W.qa_dist(dist, W.load("donna"))
left = [p for p in problems if not p.endswith(f": remote asset from {host}")]
for p in left:
    print("PROBLEM:", p)
sys.exit(1 if left else 0)
PY
  echo "site address set to $SITE_ADDR"
fi
echo "site ready: $OUT/dist"
