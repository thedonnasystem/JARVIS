# Proposal: self-hosted creative worker (owner decisions)

Status: built on `build/creative-selfhost`, OFF until the owner enables it. Design and costs: `docs/architecture/CREATIVE_SELFHOST.md`.

## Owner steps (no spending)
1. Merge, then apply `migrations/20261209_creative_selfhost_v1.sql`. It is additive and adds one provider row, which is OFF.
2. Start a Kaggle worker (see the doc, section "Start a worker"). In the notebook, uncomment the selftest cell once and confirm it prints `SELFTEST PASS`.
3. In Railway Variables:
   - set `CREATIVE_STUDIO_MODE=live`;
   - set `COMFYUI_SELFHOST_URL` and `COMFYUI_SELFHOST_TOKEN`;
   - leave `CREATIVE_FAL_FALLBACK` unset (fal.ai stays out of the router).
4. Run `select public.creative_owner_set_provider('comfyui-selfhost', true);`

## Decisions needed
- **Kaggle terms.** Is a Cloudflare quick tunnel from a Kaggle notebook acceptable to Kaggle? The AUP could not be reviewed here. If not, use batch mode (`--batch`, no tunnel), as the Colab notebook already does. Colab is batch-only because its FAQ forbids web services, remote proxies and remote workers.
- **Rented pods** (RunPod / Vast.ai) cost money per hour. Each start is the owner's decision. The worker stops a RunPod pod after 20 idle minutes or 3 hours. On Vast, destroy the instance by hand.
- **LTX-Video** stays off until `CREATIVE_LTX_LICENCE_OK=1` (licence check).

## Follow-ups that need protected files (not in this branch)
- **Queue list RPC.** A read-only `creative_queued(p_office, p_limit)` so `BatchQueue` can rebuild from the database after a redeploy. It needs a new function, plus `ops/EXPECTED_NEW_FUNCTIONS.txt` and the ACL manifest (`ops/` is out of scope here).
- **Worker registration.** An owner-only Telegram command `/creative worker <url>`, so Moe pastes the URL once into chat instead of into Railway. It needs `hq_commands.py` and a secret store entry.
- **`/creative` report line.** Show `hq_creative_selfhost.status_text()` there. It needs `hq_commands.py`.
- **The protected `test_no_bypass` allow-list is NOT changed.** The selfhost adapter uses the same `hq_hands_adapters.http` path as fal.ai and matches none of the provider patterns.
