# Proposal: Lighthouse budget in the sites workflow (owner approval: `.github/` is protected)

Status: proposal only. Nothing here is applied.

## Why
The Donna.AI v2 build was measured locally (mobile preset, Lighthouse 12.8, served with gzip and the template's cache headers):
see the PR body for the scores. A CI check keeps future sites (and template edits) from regressing.

## Exact change (`.github/workflows/sites.yml`, after the existing build + QA step for each site)
```yaml
      - name: Lighthouse budget (mobile)
        run: |
          npx --yes lighthouse@12.8.2 --version
          npx --yes http-server@14.1.1 "$OUT/dist" -p 8080 -g -s &
          sleep 2
          npx --yes lighthouse@12.8.2 http://localhost:8080/ --quiet --chrome-flags="--headless=new --no-sandbox" \
            --output=json --output-path=lh.json
          python3 - <<'PY'
          import json, sys
          r = json.load(open("lh.json"))["categories"]
          need = {"performance": 0.90, "accessibility": 0.95, "best-practices": 0.95, "seo": 0.95}
          bad = {k: r[k]["score"] for k, v in need.items() if (r[k]["score"] or 0) < v}
          print({k: r[k]["score"] for k in need}); sys.exit(1 if bad else 0)
          PY
```
Pin the action versions as `scripts/check_workflow_pins.py` requires (the npx packages are pinned above). No secrets, no deploys.
Note: CI runners have no GPU; the maison orb then stays a CSS sphere by design, so the score reflects real low-end devices.

## Rollback
Delete the step.
