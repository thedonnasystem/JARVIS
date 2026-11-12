#!/usr/bin/env bash
# READ-ONLY. Shows what Railway and Render are running and whether it matches the branch tips. Needs `gh` (GitHub REST) only.
# Railway reports every deployment to GitHub (deployments API): the newest 'success' status that has no later 'inactive' is the live one.
# Render: use the Render MCP/dashboard (list_deploys) for fendezy-hq-app; this prints the branch tip it should match.
set -euo pipefail
repo="${1:-thedonnasystem/JARVIS}"; deploy_branch="${2:-claude/telegram-claude-bot-59nusk}"; web_branch="${3:-overnight-build}"
tip() { gh api "repos/$repo/branches/$1" --jq .commit.sha; }
echo "Railway deploy branch  $deploy_branch tip: $(tip "$deploy_branch")"
echo "Render publish branch  $web_branch tip: $(tip "$web_branch")"
echo "--- recent Railway deployments (newest first)"
gh api "repos/$repo/deployments?per_page=5" --jq '.[]|[.id,.sha[0:7],.created_at]|@tsv' | while IFS=$'\t' read -r id sha at; do
  st=$(gh api "repos/$repo/deployments/$id/statuses" --jq '.[0].state')
  echo "$at  $sha  status=$st"
done
live=$(for id in $(gh api "repos/$repo/deployments?per_page=5" --jq '.[].id'); do
  s=$(gh api "repos/$repo/deployments/$id/statuses" --jq '.[0].state'); if [ "$s" = success ]; then gh api "repos/$repo/deployments/$id" --jq .sha; break; fi; done)
echo "Railway LIVE commit (per Railway): ${live:-none}"
[ "${live:-}" = "$(tip "$deploy_branch")" ] && echo "MATCHES deploy branch tip" || echo "DIFFERS from deploy branch tip (deploy pending, failed, or branch moved)"
echo "Cross-check from inside the running bot: select detail, checked_at from integration_status where key='engine_build';  (ops/verify_live.sql prints it)"
