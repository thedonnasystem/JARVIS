#!/usr/bin/env bash
# FREE fallback brain: a small quantized model on a CPU-only always-free VM (e.g. an ARM VM with ~24 GB RAM), served by llama.cpp's OpenAI-compatible server.
# Slow (a few tokens per second on 4 ARM cores) but $0. Run as a systemd service (jarvis-llm.service below) so it restarts on failure and at boot.
# Requires: llama.cpp built on the VM (cmake -B build && cmake --build build -j), a GGUF file in $MODEL (see models.json; confirm id + licence at activation),
# and JARVIS_SELFHOST_API_KEY in /etc/jarvis-llm.env (never in this repo). The key is checked on every request (--api-key).
set -euo pipefail
: "${MODEL:?path to the .gguf file}"; : "${JARVIS_SELFHOST_API_KEY:?set in /etc/jarvis-llm.env}"
PORT="${PORT:-8080}"; THREADS="${THREADS:-$(nproc)}"; CTX="${CTX:-8192}"
# Bind to localhost only: the public side is the TLS reverse proxy (Caddy, Caddyfile below). Never expose this port directly.
exec "${LLAMA_DIR:-$HOME/llama.cpp}/build/bin/llama-server" -m "$MODEL" --host 127.0.0.1 --port "$PORT" -t "$THREADS" -c "$CTX" \
  --api-key "$JARVIS_SELFHOST_API_KEY" --alias "${ALIAS:-hermes-8b-q4}" --jinja --parallel 1 --metrics
