# Creative Studio: reused components, licences, versions

Rule: reuse proven open source and keep our own code thin (adapters plus governance). This page lists, for each component, whether v1 uses it now
or later, its licence for commercial use, and the version pinned.

**Verify every licence on the source before adoption.** The licence notes below were checked in Nov 2026; they are not legal advice.

## Used in this milestone

| Component | Repo / source | Licence | Version pinned | Why |
|---|---|---|---|---|
| ffmpeg / ffprobe | ffmpeg.org (system package) | LGPL-2.1+ / GPL build; we run the binary and link nothing | 6.1.1 (Ubuntu 6.1.1-3ubuntu5) | cuts, platform renders, soft captions, test media |
| fal.ai queue API | fal.ai (hosted) | provider terms; weights licences pass through (below) | endpoint ids pinned in `creative_studio/hosted_models.json` | v1 generation without GPU infrastructure |
| Replicate predictions API | replicate.com (hosted) | provider terms | not used yet: registry slot only | adapter waits for the owner to allow-list it in the protected `test_no_bypass` |
| Jarvis hands pipeline | this repo (`hq_hands`, `hands_submit_action`) | ours | n/a | calendar and publishing with the existing owner approval. **Chosen over Postiz**: there is no second scheduler to run, and Postiz is AGPL-3.0 |

## Added in M8c (templates, editing, analytics)

| Component | Repo / source | Licence | Version pinned | How it is used |
|---|---|---|---|---|
| faster-whisper | github.com/SYSTRAN/faster-whisper | MIT | 1.2.1 (CTranslate2 4.9.1) | CPU int8 transcription with word timestamps for burned captions and SRT (`hq_creative_media.speech_words`, run in a separate process: `creative_studio/tools/whisper_words.py`). Optional: without it captions fall back to script timing. Model `tiny` (Whisper weights, MIT) is read from `CREATIVE_WHISPER_DIR`; no download unless `CREATIVE_WHISPER_DOWNLOAD=1`. Not in `requirements.txt` yet (protected): `ops/proposals/creative_media_deps.md` |
| librosa | github.com/librosa/librosa | ISC | 1.0.1 tested (`beats()` imports it when present; audio decoded by our ffmpeg) | beat tracking for beat-synced cuts. Optional: without it an onset-energy autocorrelation tracker in pure Python is used (tested 121 BPM on a 120 BPM kick) |
| aubio | github.com/aubio/aubio | **GPL-3.0** | not used | flagged: GPL; librosa (ISC) chosen instead |
| MoviePy | github.com/Zulko/moviepy | MIT | not used | ffmpeg filtergraphs cover cuts, crossfades, reframe, overlays and loudness without a second media stack (less to install, faster) |
| ffmpeg filters `ass` (libass), `loudnorm`, `xfade`, `showwaves`, `showspectrum`, `crop` | ffmpeg.org | LGPL-2.1+ / GPL build; binary only | 6.1.1 | burned captions + AI label, EBU R128 loudness (-14 LUFS, true-peak -1.5 dB), crossfades, visualizers, auto-reframe |
| Open-Higgsfield / Open Generative AI | github.com/Anil-matcha/Open-Higgsfield-AI | MIT (LICENSE checked: "Copyright (c) 2026 Open Generative AI Contributors") | commit 6f726e6539b06bb2f4288f20480c116e7173a06d | PORTED as data: camera bodies, lenses, focal perspectives, aperture effects, lighting / mood / quality tags, quick prompts, the prompt-compiler order (`src/lib/promptUtils.js`), UGC format names (`MarketingStudio.jsx`) and video workflow kinds (`videoWorkflows.js`) into `creative_studio/presets/library.json`. Its "Product Review" format is renamed "product demo"; its Muapi cloud path and "no guardrails" stance are not adopted. It ships no real camera-move presets (those are Higgsfield's closed product); our camera moves are written from standard cinematography terms |
| ComfyUI workflow templates | github.com/Comfy-Org/workflow_templates | MIT | commit 8305a7d4008c64ed52e480d553bd5784011d7b11 | node graphs and sampler defaults of `flux_schnell`, `video_wan2_2_5B_ti2v`, `video_wan2_2_14B_t2v`, `ltxv_text_to_video` re-expressed in ComfyUI API format in `creative_studio/comfyui/` (+ a FLUX schnell LoRA variant with the core `LoraLoader`) |
| worker-comfyui (RunPod) | github.com/runpod-workers/worker-comfyui | AGPL-3.0 | owner picks the image tag at endpoint creation (5.x API assumed: `input.workflow`, output `images[]` base64 / s3_url) | `ComfyUIAdapter` only calls it over HTTPS; we do not modify or redistribute it. **Verify the output format against the tag you deploy** |
| espeak-ng | github.com/espeak-ng/espeak-ng | GPL-3.0 | 1.51 (system package) | **demo / test fixture only** (makes a test voice-over in `scripts/creative_studio_demo.py`); never shipped or called by the studio |

Weights used by the ComfyUI templates (self-hosted, so the weights' own licence applies to us):

| Weights | Licence | Routed when self-hosted? |
|---|---|---|
| FLUX.1 [schnell] (`flux1-schnell-fp8`) | Apache-2.0 | yes |
| FLUX.1 [dev] and LoRAs on it | FLUX.1 [dev] Non-Commercial | **no**: removed from the self-host provider rows by `20261207_creative_studio_v2.sql`; hosted fal.ai only |
| Wan 2.2 TI2V-5B, T2V-A14B, umt5-xxl encoder, Wan VAEs (Comfy-Org repackaged) | Apache-2.0 | yes |
| Wan 2.2 lightx2v 4-step LoRA | not verified | not included |
| LTX-Video 2B v0.9 (`ltxv_t2v`) | LTX-Video open-weights licence: **verify before enabling** (LTX-2 uses the LTX-2 Community License, free under US$10M group revenue) | listed as `ltx-video`; flagged |
| HunyuanVideo 1.5 | Tencent Hunyuan Community (territory excludes EU/UK/KR) | removed from the self-host rows |
| T5-XXL encoder (LTX) | Apache-2.0 | yes |
| Whisper `tiny` (faster-whisper CTranslate2 conversion) | MIT | yes (local CPU) |

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
| ComfyUI | github.com/comfyanonymous/ComfyUI | GPL-3.0 | runs as a separate unmodified service. M8c ships the workflow JSONs and the RunPod adapter; enabling it is an owner step (`ops/proposals/creative_comfyui_selfhost.md`). IP-adapter product-reference and relight workflows are still to come |
| worker-comfyui (RunPod) | github.com/runpod-workers/worker-comfyui | AGPL-3.0 (per its repository metadata) | run unmodified as our own endpoint; any modification we serve over a network must be published |
| Modal ComfyUI example | github.com/modal-labs/modal-examples | MIT (verify) | the alternative to RunPod |
| ostris/ai-toolkit | github.com/ostris/ai-toolkit | MIT | FLUX LoRA training on our own GPU (v1 uses fal's hosted LoRA trainer) |
| kohya_ss / sd-scripts | github.com/bmaltais/kohya_ss | Apache-2.0 | alternative trainer |
| IP-Adapter | github.com/tencent-ailab/IP-Adapter | Apache-2.0 | product-reference shots in ComfyUI |
| Postiz | github.com/gitroomhq/postiz-app | AGPL-3.0 | not adopted: the hands pipeline already covers the calendar |
