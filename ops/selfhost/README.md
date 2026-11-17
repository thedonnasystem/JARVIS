# Self-hosted brain kit

Two options. Both expose an **OpenAI-compatible** endpoint that `hq_llm` already speaks. Nothing here has been created or paid for.

## A. Free fallback (default): small Hermes / Qwen on an always-free CPU VM ($0, slow)
1. Create an always-free ARM VM (for example 4 cores, ~24 GB RAM). Open only ports 443 and 80 in its firewall.
2. Install llama.cpp (`git clone`, `cmake -B build && cmake --build build -j`) and Caddy.
3. Download the GGUF model chosen in `models.json` (default: Hermes 3 8B, Q4_K_M). Record the exact file name and licence in `models.json`.
4. Create `/etc/jarvis-llm.env` (root-only, `chmod 600`): `MODEL=/opt/models/<file>.gguf`, `JARVIS_SELFHOST_API_KEY=<a long random key>`, `JARVIS_LLM_DOMAIN=<your domain>`.
5. Copy `start_llamacpp.sh` to `/opt/jarvis/`, install `jarvis-llm.service` (auto-restart, starts at boot), `systemctl enable --now jarvis-llm`.
6. Caddy with `Caddyfile`: TLS certificate and proxy to `127.0.0.1:8080`. The model server listens on localhost only and checks the key on every request.
7. Health: `JARVIS_SELFHOST_API_KEY=... ./healthcheck.sh https://<domain>/v1` prints `healthy`.
8. In Railway Variables: `JARVIS_SELFHOST_BASE_URL=https://<domain>/v1`, `JARVIS_SELFHOST_API_KEY=<same key>` (and `JARVIS_SELFHOST_MODEL_SMALL` if the alias differs).
9. Tool calls: run `hq_llm.check_tool_calling(<selfhost provider>)` once (it is free on this endpoint) and record the result in `models.json`.

Expect a few tokens per second. Good for queued work and for anything with client personal data (the only free provider allowed to see it).

## B. Optional paid GPU pod (off; only with the self-funded budget)
`Dockerfile.vllm` runs vLLM with `--api-key`, `--enable-auto-tool-choice` and the Hermes tool parser. Model matrix by GPU size in `models.json`
(about 14B class on 24-48 GB, 70B class 4-bit on 48-80 GB). Put the pod behind the provider's HTTPS proxy, never a public port without the key.
Railway: `JARVIS_GPU_BASE_URL`, `JARVIS_GPU_API_KEY`, `JARVIS_GPU_USD_PER_HOUR` (metering by GPU hour: cents = hourly price x seconds used).
It is used only when the Chairman switches `paid_providers_enabled` on AND the self-funded budget has money left.

## When the brain is down
Jarvis stays reachable on Telegram: plain-code commands (`/hq`, `/kill`, `/resume`, `/money`, `/missions`, `/core`, `/briefing`, `/report`) need no model.
Model work answers "My brain is offline right now, sir..." or is queued; there is no silent switch to a paid provider.
