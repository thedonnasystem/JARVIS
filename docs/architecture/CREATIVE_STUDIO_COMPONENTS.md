# Creative Studio: reused components, licences, versions

Rule: reuse proven open source and keep our own code thin (adapters plus governance). This page lists, for each component, whether v1 uses it now
or later, its licence for commercial use, and the version pinned.

**Verify every licence on the source before adoption.** The licence notes below were checked in Nov 2026; they are not legal advice.

## Used in this milestone

| Component | Repo / source | Licence | Version pinned | Why |
|---|---|---|---|---|
| ffmpeg / ffprobe | ffmpeg.org (system package) | LGPL-2.1+ / GPL build; we run the binary and link nothing | 6.1.1 (Ubuntu 6.1.1-3ubuntu5) | cuts, platform renders, soft captions, test media |
| fal.ai queue API | fal.ai (hosted) | provider terms; weights licences pass through (below) | endpoint ids pinned in `creative_studio/hosted_models.json` | v1 generation without GPU infrastructure |
| Replicate predictions API | replicate.com (hosted) | provider terms | endpoint ids pinned in `creative_studio/hosted_models.json` | second v1 path |
| Jarvis hands pipeline | this repo (`hq_hands`, `hands_submit_action`) | ours | n/a | calendar and publishing with the existing owner approval. **Chosen over Postiz**: there is no second scheduler to run, and Postiz is AGPL-3.0 |

## Models (through the hosted APIs in v1)

| Model | Licence | Commercial use | Flag |
|---|---|---|---|
| Wan 2.2 (TI2V-5B, T2V-A14B) | Apache-2.0 | yes | primary video |
| LTX-2 / LTX-2.5 (Lightricks) | LTX-2 Community License | free under US$10M annual revenue, counted across the whole group including affiliates; above that a paid agreement | **track group revenue (owner note)**. LTX-2.5 open weights are on Hugging Face with official ComfyUI templates. v1 routes LTX-2 (hosted on fal); switch to 2.5 when fal or Replicate host it |
| HunyuanVideo 1.5 | Tencent Hunyuan Community License | territory excludes the EU, UK and South Korea | **fine in Canada, but not for EU/UK/KR audiences**. Registered as a model name only; not in the hosted table, so it is not routed |
| FLUX.1 [schnell] | Apache-2.0 | yes | cheapest image |
| FLUX.1 [dev] (and LoRAs on it) | FLUX.1 [dev] Non-Commercial License | outputs may be used; running the weights commercially needs a BFL licence | **use through fal / Replicate, which serve it under their own arrangement (verify); self-hosting needs a BFL commercial licence** |
| SDXL 1.0 | CreativeML Open RAIL++-M | yes, with use restrictions | fallback image |
| Kokoro-82M (TTS) | Apache-2.0 | yes | default open voice (adapter later) |
| F5-TTS | code MIT, weights CC-BY-NC-4.0 | **no** (weights) | not used |
| ACE-Step (music) | Apache-2.0 (verify) | yes | music slot. **Ownership of generated music differs per provider: read each provider's terms before releasing tracks** |

## Later (cost optimisation and fine control); not used in v1

| Component | Repo | Licence | Note |
|---|---|---|---|
| ComfyUI | github.com/comfyanonymous/ComfyUI | GPL-3.0 | runs as a separate unmodified service; vendor community workflows (FLUX, Wan 2.2, LTX, IP-adapter product shots) as JSON when we move off hosted APIs |
| worker-comfyui (RunPod) | github.com/runpod-workers/worker-comfyui | AGPL-3.0 (per its repository metadata) | run unmodified as our own endpoint; any modification we serve over a network must be published |
| Modal ComfyUI example | github.com/modal-labs/modal-examples | MIT (verify) | the alternative to RunPod |
| ostris/ai-toolkit | github.com/ostris/ai-toolkit | MIT | FLUX LoRA training on our own GPU (v1 uses fal's hosted LoRA trainer) |
| kohya_ss / sd-scripts | github.com/bmaltais/kohya_ss | Apache-2.0 | alternative trainer |
| faster-whisper | github.com/SYSTRAN/faster-whisper | MIT | word-timed captions (v1 times captions evenly from the script) |
| IP-Adapter | github.com/tencent-ailab/IP-Adapter | Apache-2.0 | product-reference shots in ComfyUI |
| Open-Higgsfield / Open Generative AI | github.com/Anil-matcha/Open-Higgsfield-AI | MIT (per the coordinator; verify) | model presets and camera-motion prompt templates only. We do NOT use its Muapi cloud path and do NOT adopt its "no guardrails" stance |
| Postiz | github.com/gitroomhq/postiz-app | AGPL-3.0 | not adopted: the hands pipeline already covers the calendar |
