# Proposal: add fastembed for better memory embeddings (owner decision)

**Why.** Linked memory works today with the built-in hashed embedder, which has no dependency. A small neural embedder finds paraphrases far better. For example, "Donna is aiming at furnace companies" would match "Donna targets HVAC contractors".

**What.** `fastembed` (Apache-2.0, Qdrant) with `BAAI/bge-small-en-v1.5` (MIT; 384 dimensions, about 130 MB of ONNX weights, CPU). The text stays in the bot process.

**Cost.** $0. It adds roughly 150-250 MB of RAM in the Railway container and about 30-60 ms per message on CPU.

**Supply chain (same review as LiteLLM, OPEN_BRAIN.md 6a).**
- New wheels: fastembed, onnxruntime (native), tokenizers (native), huggingface-hub, numpy, pillow, mmh3, loguru, tqdm, requests, py-rust-stemmers.
  - That is about 10 packages, 60 MB of wheels.
  - It adds no telemetry and no import-time network.
- **Network at first use:** the model file is downloaded once from Hugging Face.
  - Safer: bake it into the image, or set `JARVIS_MEMORY_MODEL_DIR` to a volume and pre-fetch it.
  - Then set `HF_HUB_OFFLINE=1` so no further network access happens.
- Pin exact versions with `--require-hashes` in `requirements/` (protected path: owner approval).

**Steps (after approval; an agent prepares the PR).**
1. Add pinned, hashed lines for fastembed and its dependencies to the runtime lock.
2. Railway variables: `JARVIS_MEMORY_EMBEDDER=fastembed`, `JARVIS_MEMORY_MODEL_DIR=/data/models`, `HF_HUB_OFFLINE=1` (after the first download).
3. Optional: re-embed the existing memories. The old rows still match on lexical, entity and recency until they are seen again.

**Rollback.** Unset `JARVIS_MEMORY_EMBEDDER`. The hashed embedder takes over at once.
